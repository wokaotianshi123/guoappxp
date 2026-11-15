package core

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

// 听书章节的本地明文流：地址必须带容器扩展名，上游请求头由 Go 侧注入，
// Range 原样透传。这三条是 Windows 上「进度在走但没声音」修复的关键。
func TestNativeAudiobookStreamProxiesHeadersAndRange(t *testing.T) {
	var mu sync.Mutex
	var gotReferer, gotAgent, gotRange string
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		gotReferer = r.Header.Get("Referer")
		gotAgent = r.Header.Get("User-Agent")
		gotRange = r.Header.Get("Range")
		mu.Unlock()
		w.Header().Set("Content-Type", "audio/mp4")
		if gotRange != "" {
			w.Header().Set("Content-Range", "bytes 0-3/8")
			w.WriteHeader(http.StatusPartialContent)
			_, _ = io.WriteString(w, "half")
			return
		}
		_, _ = io.WriteString(w, "audio-bytes")
	}))
	defer upstream.Close()

	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	stream, err := newNativeStreamServer(engine.downloader)
	if err != nil {
		t.Fatal(err)
	}
	defer stream.server.Close()

	plan := map[string]any{
		"url":           upstream.URL + "/audio/playinfo",
		"decryptionKey": "00112233445566778899aabbccddeeff",
		"headers": map[string]string{
			"Referer":    "https://novel.snssdk.com/",
			"User-Agent": "com.dragon.read",
		},
	}
	address := stream.nativeOpenAudiobook(plan)
	if !strings.HasSuffix(address, ".m4a") {
		t.Fatalf("本地流地址缺少容器扩展名：%s", address)
	}
	// 同一章重复登记应复用同一个地址，避免切章时无限堆积条目。
	if again := stream.nativeOpenAudiobook(plan); again != address {
		t.Fatalf("同一章地址不稳定：%s != %s", address, again)
	}

	response, err := http.Get(address)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(response.Body)
	response.Body.Close()
	if response.StatusCode != http.StatusOK || string(body) != "audio-bytes" {
		t.Fatalf("本地流转发失败：status=%d body=%q", response.StatusCode, body)
	}
	mu.Lock()
	referer, agent := gotReferer, gotAgent
	mu.Unlock()
	if referer != "https://novel.snssdk.com/" || agent != "com.dragon.read" {
		t.Fatalf("上游请求头未注入：Referer=%q UA=%q", referer, agent)
	}

	request, _ := http.NewRequest(http.MethodGet, address, nil)
	request.Header.Set("Range", "bytes=0-3")
	partial, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	partial.Body.Close()
	mu.Lock()
	rng := gotRange
	mu.Unlock()
	if rng != "bytes=0-3" || partial.StatusCode != http.StatusPartialContent {
		t.Fatalf("Range 未透传：range=%q status=%d", rng, partial.StatusCode)
	}

	// 未登记的章不应被当成短剧会话的 token/asset 而误命中。
	missing, err := http.Get(stream.address + "/audiobook/deadbeef.m4a")
	if err != nil {
		t.Fatal(err)
	}
	missing.Body.Close()
	if missing.StatusCode != http.StatusGone {
		t.Fatalf("未知听书条目状态 = %d, want 410", missing.StatusCode)
	}
}

// withAudiobookStream 是 RPC 出口：plan 里必须出现 streamUrl，且原有字段
// 一个都不能丢（本地服务版网页听书仍要读 url / decryptionKey / headers）。
func TestWithAudiobookStreamKeepsOriginalPlan(t *testing.T) {
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if engine.stream != nil {
		defer engine.stream.server.Close()
	}
	plan := map[string]any{
		"url":           "https://cdn.example/audio/playinfo",
		"decryptionKey": "aabbccddeeff00112233445566778899",
		"duration":      120,
		"headers":       map[string]string{"Referer": "https://novel.snssdk.com/"},
	}
	got := engine.withAudiobookStream(plan)
	if url, _ := got["streamUrl"].(string); !strings.HasSuffix(url, ".m4a") {
		t.Fatalf("streamUrl 未生成或扩展名不对：%v", got["streamUrl"])
	}
	if got["url"] != plan["url"] || got["decryptionKey"] != plan["decryptionKey"] || got["duration"] != 120 {
		t.Fatalf("原始播放计划字段被破坏：%v", got)
	}
	if engine.stream == nil {
		t.Fatal("流服务器未初始化")
	}
	defer engine.stream.server.Close()
}

package core

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestNativeMetadataPreservesIdentityAndCover(t *testing.T) {
	value := true
	drama := nativeNormalize(Drama{ID: "hongguo:7399988776655443322", Title: "合成测试剧",
		Cover: map[string]any{"url": "https://example.test/poster.webp"}, TotalEpisode: json.Number("24"), VIP: &value})
	if drama.ID != "hongguo:7399988776655443322" || drama.SourceID != "7399988776655443322" ||
		drama.Cover != "https://example.test/poster.webp" || drama.Episodes != 24 || drama.VIP == nil || !*drama.VIP {
		t.Fatalf("metadata lost: %+v", drama)
	}
}

func TestNativeBoundaryRejectsInvalidInput(t *testing.T) {
	for _, input := range []string{"{", strings.Repeat("x", 1<<20+1)} {
		var result map[string]any
		if err := json.Unmarshal([]byte(NativeRequest(input)), &result); err != nil || result["ok"] != false {
			t.Fatal("invalid request accepted")
		}
	}
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := engine.nativeCatalog(context.Background(), nativeInput{Source: "invalid"}); err == nil {
		t.Fatal("invalid source accepted")
	}
	if _, err := engine.nativeDetail(context.Background(), nativeDrama{ID: "invalid"}); err == nil {
		t.Fatal("invalid drama accepted")
	}
}

func TestNativeHLSReadsNestedPlaylistKeyAndRanges(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Referer") != "https://example.test/watch" {
			t.Error("media referer missing")
			w.WriteHeader(http.StatusForbidden)
			return
		}
		switch r.URL.Path {
		case "/master.m3u8":
			w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
			io.WriteString(w, "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=200000\nvideo/media.m3u8\n")
		case "/video/media.m3u8":
			w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
			io.WriteString(w, "#EXTM3U\n#EXT-X-TARGETDURATION:3\n#EXT-X-KEY:METHOD=AES-128,URI=\"secret.key\",IV=0x00000000000000000000000000000001\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:3.0,\nsegment.ts\n#EXT-X-ENDLIST\n")
		case "/video/secret.key":
			t.Error("the source key should be replaced by the resolved key")
			w.WriteHeader(http.StatusForbidden)
		case "/video/segment.ts":
			if r.Header.Get("Range") != "bytes=1-3" {
				t.Error("range missing")
			}
			w.Header().Set("Content-Range", "bytes 1-3/7")
			w.Header().Set("Accept-Ranges", "bytes")
			w.WriteHeader(http.StatusPartialContent)
			io.WriteString(w, "123")
		default:
			io.WriteString(w, "init")
		}
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
	address, token := stream.nativeOpen(providerMedia{URL: upstream.URL + "/master.m3u8",
		Referer: "https://example.test/watch", HLSKey: []byte("0123456789abcdef")}, false)
	defer stream.nativeRelease(token)
	read := func(address string) string {
		t.Helper()
		response, err := http.Get(address)
		if err != nil {
			t.Fatal(err)
		}
		defer response.Body.Close()
		if response.StatusCode != 200 {
			t.Fatalf("HTTP %d", response.StatusCode)
		}
		body, err := io.ReadAll(response.Body)
		if err != nil {
			t.Fatal(err)
		}
		return string(body)
	}
	master := read(address)
	child := ""
	for _, line := range strings.Split(master, "\n") {
		if strings.HasPrefix(line, "http:") {
			child = line
		}
	}
	if child == "" || strings.Contains(master, upstream.URL) {
		t.Fatal("master playlist not rewritten")
	}
	media := read(child)
	matches := nativePlaylistURI.FindAllStringSubmatch(media, -1)
	if len(matches) != 2 {
		t.Fatalf("missing rewritten key or init: %s", media)
	}
	if key := read(matches[0][1]); key != "0123456789abcdef" {
		t.Fatal("wrong key")
	}
	segment := ""
	for _, line := range strings.Split(media, "\n") {
		if strings.HasPrefix(line, "http:") {
			segment = line
		}
	}
	request, _ := http.NewRequest(http.MethodGet, segment, nil)
	request.Header.Set("Range", "bytes=1-3")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(response.Body)
	response.Body.Close()
	if response.StatusCode != 206 || string(body) != "123" || response.Header.Get("Content-Range") != "bytes 1-3/7" {
		t.Fatal("range was not preserved")
	}
	stream.nativeRelease(token)
	response, err = http.Get(address)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusGone {
		t.Fatal("released stream remained accessible")
	}
}

func TestNativeStreamDirectMP4WithHLSKeyPreservesRangeResponse(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Range") != "bytes=1-3" {
			t.Errorf("range header = %q, want bytes=1-3", r.Header.Get("Range"))
		}
		w.Header().Set("Content-Type", "video/mp4")
		w.Header().Set("Content-Range", "bytes 1-3/7")
		w.Header().Set("Accept-Ranges", "bytes")
		w.WriteHeader(http.StatusPartialContent)
		_, _ = io.WriteString(w, "123")
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

	address, token := stream.nativeOpen(providerMedia{
		URL:    upstream.URL + "/episode.mp4?format=hls",
		HLSKey: []byte("0123456789abcdef"),
	}, false)
	defer stream.nativeRelease(token)

	stream.mu.Lock()
	session := stream.sessions[token]
	stream.mu.Unlock()
	session.mu.Lock()
	for _, asset := range session.assets {
		if asset.kind == "entry_playlist" || asset.contentType != "video/mp4" {
			session.mu.Unlock()
			t.Fatalf("direct MP4 entry was classified as playlist: %+v", asset)
		}
	}
	session.mu.Unlock()

	request, err := http.NewRequest(http.MethodGet, address, nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Range", "bytes=1-3")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != http.StatusPartialContent || response.Header.Get("Content-Type") != "video/mp4" ||
		response.Header.Get("Content-Range") != "bytes 1-3/7" || string(body) != "123" {
		t.Fatalf("direct MP4 range response status=%d type=%q range=%q body=%q", response.StatusCode,
			response.Header.Get("Content-Type"), response.Header.Get("Content-Range"), body)
	}
}

func TestNativeStreamDowngradesPredictedPlaylistForMP4Response(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Range") != "bytes=1-3" {
			t.Errorf("range header = %q, want bytes=1-3", r.Header.Get("Range"))
		}
		w.Header().Set("Content-Type", "video/mp4")
		w.Header().Set("Content-Range", "bytes 1-3/7")
		w.Header().Set("Accept-Ranges", "bytes")
		w.WriteHeader(http.StatusPartialContent)
		_, _ = io.WriteString(w, "123")
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

	_, token := stream.nativeOpen(providerMedia{URL: upstream.URL + "/episode.mp4?format=hls"}, false)
	defer stream.nativeRelease(token)
	stream.mu.Lock()
	session := stream.sessions[token]
	stream.mu.Unlock()
	address := stream.nativeAsset(token, session, nativeStreamAsset{
		kind:        "entry_playlist",
		address:     upstream.URL + "/episode.mp4?format=hls",
		contentType: "application/vnd.apple.mpegurl",
	})

	request, err := http.NewRequest(http.MethodGet, address, nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Range", "bytes=1-3")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != http.StatusPartialContent || response.Header.Get("Content-Type") != "video/mp4" ||
		response.Header.Get("Content-Range") != "bytes 1-3/7" || string(body) != "123" {
		t.Fatalf("predicted playlist did not downgrade to MP4: status=%d type=%q range=%q body=%q",
			response.StatusCode, response.Header.Get("Content-Type"), response.Header.Get("Content-Range"), body)
	}
}

func TestHongguoDetailAndPlayableQuality(t *testing.T) {
	detail := map[string]any{"series_id": "700001", "series_title": "合成测试", "episode_cnt": 2,
		"video_list": []any{
			map[string]any{"vid": "800002", "vid_index": 2, "series_id": "700001", "vertical": false},
			map[string]any{"vid": "800001", "vid_index": 1, "series_id": "700001"},
		}}
	result := map[string]any{"data": map[string]any{"video_data": detail}}
	entry, err := parseHongguoAppDetail(result, "700001")
	if err != nil || len(entry.Chapters) != 2 || entry.Chapters[0].VideoURL != "hongguo-cenc://800001" {
		t.Fatalf("wrong episode ordering: %v", err)
	}
	if entry.Chapters[0].Vertical != nil || entry.Chapters[1].Vertical == nil || *entry.Chapters[1].Vertical {
		t.Fatal("episode orientation was not carried over")
	}
	if _, err := parseHongguoAppDetail(result, "700002"); err == nil {
		t.Fatal("wrong drama accepted")
	}
	detail["episode_cnt"] = 3
	if _, err := parseHongguoAppDetail(result, "700001"); err == nil {
		t.Fatal("incomplete details accepted")
	}
	media, err := selectHongguoAppMedia(map[string]any{"video_list": []any{
		map[string]any{"main_url": "https://media.example.test/new.mp4", "video_meta": map[string]any{"codec_type": "bytevc2", "definition": "2160p"}},
		map[string]any{"main_url": "https://media.example.test/low.mp4", "video_meta": map[string]any{"codec_type": "h264", "definition": "720p"}},
		map[string]any{"main_url": "https://media.example.test/high.mp4", "video_meta": map[string]any{"codec_type": "hevc", "definition": "1080p"}},
	}})
	if err != nil || media.Quality != 1080 || !strings.HasSuffix(media.URL, "high.mp4") {
		t.Fatalf("wrong playable quality: %v", err)
	}
}

// 网页源（含 XBPQ 自定义源）/ 爱看机器人 / A123 都走 nativeDetail 的
// default 分支。以前这条分支只从 GetHuangguoChapters 拿标题，详情层已经
// 解析出的简介被丢掉，播放页「简介」与详情页资料区一直是「暂无简介」。
// 站源外置后这条分支改由注册表转入站源实现，这里用一个假站源盯住透传。
func TestNativeDetailKeepsWebSourceDescription(t *testing.T) {
	d, _ := duanjuFixtureDownloader(t, func(writer http.ResponseWriter, request *http.Request) {})
	Register(SourceDescriptor{ID: sourceWuguo, Name: "伍果", ValidCategory: func(string) bool { return true }},
		func(Host) Provider {
			return stubDetailProvider{
				drama: Drama{
					ID: providerDramaID(sourceWuguo, "100"), Source: sourceWuguo, SourceID: "100",
					Title: "五五样本", Name: "五五样本", Desc: "网页源剧情简介",
				},
				chapters: []Chapter{
					{ID: providerChapterID(sourceWuguo, "100", "1"), Source: sourceWuguo, Title: "第1集", VideoURL: "https://media.example.test/1.mp4"},
					{ID: providerChapterID(sourceWuguo, "100", "2"), Source: sourceWuguo, Title: "第2集", VideoURL: "https://media.example.test/2.mp4"},
				},
			}
		})
	t.Cleanup(func() { unregisterSource(sourceWuguo) })
	engine := &nativeEngine{
		downloader: d,
		directory:  t.TempDir(),
		catalogs:   map[string][]nativeDrama{},
	}
	reply, err := engine.nativeDetail(context.Background(), nativeDrama{
		ID: "wuguo:100", Source: sourceWuguo, SourceID: "100", Title: "五五样本",
	})
	if err != nil {
		t.Fatalf("网页源详情失败: %v", err)
	}
	result, ok := reply.(map[string]any)
	if !ok {
		t.Fatalf("详情返回类型 = %T", reply)
	}
	drama, ok := result["drama"].(nativeDrama)
	if !ok {
		t.Fatalf("drama 字段类型 = %T", result["drama"])
	}
	if drama.Description != "网页源剧情简介" {
		t.Fatalf("详情简介没传出来: %q", drama.Description)
	}
	if drama.Title != "五五样本" || drama.ID != "wuguo:100" {
		t.Fatalf("详情身份被破坏: %+v", drama)
	}
	chapters, ok := result["chapters"].([]Chapter)
	if !ok || len(chapters) != 2 {
		t.Fatalf("分集丢失: %T %d", result["chapters"], len(chapters))
	}
	// 取流侧的旧接口仍然只要标题，不能被这次改造弄坏。
	title, _, err := d.GetHuangguoChapters(context.Background(), sourceWuguo, "100")
	if err != nil || title != "五五样本" {
		t.Fatalf("GetHuangguoChapters 回归: %q %v", title, err)
	}
}

// stubDetailProvider 是测试用站源：只实现详情，其余方法不参与断言。
type stubDetailProvider struct {
	drama    Drama
	chapters []Chapter
}

func (s stubDetailProvider) Descriptor() SourceDescriptor {
	return SourceDescriptor{ID: sourceWuguo, Name: "伍果", ValidCategory: func(string) bool { return true }}
}

func (s stubDetailProvider) Categories(context.Context, bool) ([]Category, error) { return nil, nil }

func (s stubDetailProvider) CatalogPage(context.Context, int, string) ([]Drama, bool, error) {
	return nil, false, nil
}

func (s stubDetailProvider) Detail(context.Context, string) (Drama, []Chapter, error) {
	return s.drama, s.chapters, nil
}

func (s stubDetailProvider) ResolveMedia(context.Context, Task) (ProviderMedia, error) {
	return ProviderMedia{}, nil
}

// XBPQ 规则里的「简介」等详情字段必须落到 Drama.Desc / Intro，
// 否则 nativeNormalize 拿不到内容，播放器显示层再怎么改也没用。
func TestXBPQDetailIntroFeedsDrama(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = io.WriteString(writer, `<html><body><h1>规则样本</h1>`+
			`<div class="intro">这是规则里的剧情简介</div>`+
			`<ul class="playlist">`+
			`<li><a href="/play/1.html">第1集</a></li>`+
			`<li><a href="/play/2.html">第2集</a></li>`+
			`</ul></body></html>`)
	}))
	t.Cleanup(server.Close)
	d := xbpqHeadersTestDownloader(t, server.Client())
	rule, ok := parseXBPQRule(`{"主页url":"` + server.URL + `",` +
		`"详情url":"` + server.URL + `/detail/{id}.html",` +
		`"影片名称":"<h1>&&</h1>","简介":"<div class=\"intro\">&&</div>",` +
		`"播放数组":"<ul class=\"playlist\">&&</ul>","播放列表":"</li>",` +
		`"播放标题":">&&</a>","播放链接":"href=\"&&\""}`)
	if !ok {
		t.Fatal("测试规则解析失败")
	}
	drama, chapters, err := d.xbpqDetail(context.Background(), "custom:test", server.URL, "100", rule)
	if err != nil {
		t.Fatalf("XBPQ 详情失败: %v", err)
	}
	if len(chapters) != 2 {
		t.Fatalf("XBPQ 分集数 = %d, 期望 2", len(chapters))
	}
	if drama.Desc != "这是规则里的剧情简介" || drama.Intro != drama.Desc {
		t.Fatalf("规则「简介」没落到 Drama: Desc=%q Intro=%q", drama.Desc, drama.Intro)
	}
	if got := nativeNormalize(drama).Description; got != "这是规则里的剧情简介" {
		t.Fatalf("nativeNormalize 丢掉简介: %q", got)
	}
}

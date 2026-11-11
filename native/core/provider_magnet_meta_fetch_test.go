package core

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/anacrolix/torrent/metainfo"
)

func magnetTestMetaBytes(t *testing.T, info metainfo.MetaInfo) []byte {
	t.Helper()
	var buffer bytes.Buffer
	if err := info.Write(&buffer); err != nil {
		t.Fatalf("序列化种子失败: %v", err)
	}
	return buffer.Bytes()
}

// 用本地 httptest 顶替公开端点，测试既不联网也能验证 URL / UA / 落盘行为。
func withMagnetOnlineMetaServer(t *testing.T, handler http.HandlerFunc, run func()) {
	t.Helper()
	server := httptest.NewServer(handler)
	defer server.Close()
	oldURLs, oldClient := magnetOnlineMetaURLs, magnetOnlineMetaHTTP
	magnetOnlineMetaURLs = []string{server.URL + "/torrent/%s.torrent"}
	magnetOnlineMetaHTTP = server.Client()
	defer func() {
		magnetOnlineMetaURLs, magnetOnlineMetaHTTP = oldURLs, oldClient
	}()
	run()
}

func TestMagnetParseOnlineMetaOnlyAcceptsMatchingTorrent(t *testing.T) {
	info := magnetTestMetaInfo(t)
	hash := info.HashInfoBytes().HexString()
	body := magnetTestMetaBytes(t, info)

	if magnetParseOnlineMeta(body, hash) == nil {
		t.Fatal("合法的 bencode 种子应被接受")
	}
	if magnetParseOnlineMeta(body, strings.ToUpper(hash)) == nil {
		t.Fatal("infohash 大小写不应影响匹配")
	}
	invalid := map[string][]byte{
		"空响应":       {},
		"HTML 页面":   []byte("<!DOCTYPE html><html>not a torrent</html>"),
		"截断的种子":     body[:len(body)-4],
		"超过大小上限":    bytes.Repeat([]byte("x"), magnetOnlineMetaMaxBody+1),
		"非 bencode": []byte("http://example.com/"),
	}
	for name, bad := range invalid {
		if got := magnetParseOnlineMeta(bad, hash); got != nil {
			t.Errorf("%s 不应被写入缓存", name)
		}
	}
	if magnetParseOnlineMeta(body, "0000000000000000000000000000000000000000") != nil {
		t.Fatal("infohash 不匹配的种子必须拒绝，防止串种子")
	}
	if magnetFetchOnlineMeta(context.Background(), "not-a-hash") != nil {
		t.Fatal("非法 infohash 不该发起任何请求")
	}
}

func TestMagnetCacheOnlineMetaSkipsNetworkWhenCached(t *testing.T) {
	info := magnetTestMetaInfo(t)
	hash := info.HashInfoBytes().HexString()
	dir := t.TempDir()
	magnetSaveMeta(dir, hash, info)

	var hits atomic.Int32
	withMagnetOnlineMetaServer(t, func(writer http.ResponseWriter, _ *http.Request) {
		hits.Add(1)
		_, _ = writer.Write(magnetTestMetaBytes(t, info))
	}, func() {
		// 返回 false 表示「本次没有新写入缓存」：已有本地种子时不应该联网。
		if magnetCacheOnlineMeta(context.Background(), hash, dir) {
			t.Fatal("已有本地元数据时不应再写一次缓存")
		}
	})
	if hits.Load() != 0 {
		t.Fatalf("本地命中却发了 %d 次网络请求", hits.Load())
	}
}

func TestMagnetCacheOnlineMetaFetchesAndCaches(t *testing.T) {
	info := magnetTestMetaInfo(t)
	hash := info.HashInfoBytes().HexString()
	body := magnetTestMetaBytes(t, info)
	dir := t.TempDir()

	var hits atomic.Int32
	var agent, path string
	withMagnetOnlineMetaServer(t, func(writer http.ResponseWriter, request *http.Request) {
		hits.Add(1)
		agent, path = request.UserAgent(), request.URL.Path
		_, _ = writer.Write(body)
	}, func() {
		if !magnetCacheOnlineMeta(context.Background(), hash, dir) {
			t.Fatal("端点返回合法种子时应落盘")
		}
		if magnetLoadMeta(dir, hash) == nil {
			t.Fatal("落盘后应能读回元数据")
		}
		// 第二次调用直接命中本地缓存，不再请求端点。
		if magnetCacheOnlineMeta(context.Background(), hash, dir) {
			t.Fatal("第二次不应重新写缓存")
		}
	})
	if hits.Load() != 1 {
		t.Fatalf("请求次数 = %d，期望 1（第二次走本地缓存）", hits.Load())
	}
	if !strings.Contains(agent, "Mozilla/") {
		t.Fatalf("端点要求浏览器 UA，实际 = %q", agent)
	}
	if !strings.Contains(path, hash) {
		t.Fatalf("请求路径没带 infohash: %q", path)
	}
}

func TestMagnetCacheOnlineMetaRejectsHtmlAndCancelledContext(t *testing.T) {
	info := magnetTestMetaInfo(t)
	hash := info.HashInfoBytes().HexString()
	dir := t.TempDir()

	var hits atomic.Int32
	withMagnetOnlineMetaServer(t, func(writer http.ResponseWriter, _ *http.Request) {
		hits.Add(1)
		writer.WriteHeader(http.StatusOK)
		_, _ = writer.Write([]byte("<!DOCTYPE html><html>slow or missing</html>"))
	}, func() {
		if magnetCacheOnlineMeta(context.Background(), hash, dir) {
			t.Fatal("HTML 页面不能当成种子")
		}
		if magnetLoadMeta(dir, hash) != nil {
			t.Fatal("失败的响应不该留下缓存文件")
		}
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		if magnetCacheOnlineMeta(ctx, hash, dir) {
			t.Fatal("已取消的加载不该继续写缓存")
		}
	})
	if hits.Load() > 1 {
		t.Fatalf("取消后仍发了新请求: %d", hits.Load())
	}
}

func TestMagnetMetaFetchSettingDefaultsOnAndCanBeDisabled(t *testing.T) {
	if !defaultResourceSettings().magnetMetaFetchEnabled() {
		t.Fatal("默认应开启云端种子缓存")
	}
	// 旧版 resource-settings.json 没有该字段：保持开启，不要静默降级。
	var stored nativeResourceSettings
	if err := json.Unmarshal([]byte(`{"proxyMode":"auto","downloadBySource":true}`), &stored); err != nil {
		t.Fatal(err)
	}
	if !stored.magnetMetaFetchEnabled() {
		t.Fatal("旧配置文件缺字段时应默认开启")
	}
	disabled := false
	stored.MagnetMetaFetch = &disabled
	if stored.magnetMetaFetchEnabled() {
		t.Fatal("用户关闭后必须真的关掉")
	}
	data, err := json.Marshal(stored)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `"magnetMetaFetch":false`) {
		t.Fatalf("关闭状态必须持久化，实际 = %s", data)
	}
	enabled := true
	stored.MagnetMetaFetch = &enabled
	if !stored.magnetMetaFetchEnabled() {
		t.Fatal("用户重新打开后必须生效")
	}
}

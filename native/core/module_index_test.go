package core

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"testing/fstest"
)

func TestModuleIndexInstallFallsBackAndVerifies(t *testing.T) {
	example := filepath.Join("..", "module_example", "jsexample")
	files := map[string][]byte{}
	sums := map[string]string{}
	for _, name := range []string{moduleManifest, moduleEntry} {
		data, err := os.ReadFile(filepath.Join(example, name))
		if err != nil {
			t.Fatal(err)
		}
		sum := sha256.Sum256(data)
		files[name], sums[name] = data, hex.EncodeToString(sum[:])
	}
	entry := func(id, repo string, api int, hashes map[string]string) moduleIndexEntry {
		return moduleIndexEntry{ID: id, Name: id, Version: "1.0.0", API: api, Repo: repo, Tag: "v1.0.0", SHA256: hashes}
	}
	wrong := map[string]string{moduleManifest: strings.Repeat("0", 64), moduleEntry: strings.Repeat("0", 64)}
	index, err := json.Marshal(map[string]any{"format": moduleIndexFormat, "modules": []moduleIndexEntry{
		entry("jsexample", "owner/jsexample", moduleAPIVersion, sums),
		entry("future", "owner/jsexample", moduleAPIVersion+1, sums),
		entry("renamed", "owner/jsexample", moduleAPIVersion, sums),
		entry("tampered", "owner/jsexample", moduleAPIVersion, wrong),
		entry("bad-repo", "../jsexample", moduleAPIVersion, sums),
	}})
	if err != nil {
		t.Fatal(err)
	}
	var staleHits atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch {
		case request.URL.Path == "/broken/index.json":
			http.Error(writer, "down", http.StatusBadGateway)
		case request.URL.Path == "/index.json":
			_, _ = writer.Write(index)
		case strings.HasPrefix(request.URL.Path, "/stale/"):
			staleHits.Add(1)
			_, _ = writer.Write([]byte("stale"))
		case strings.HasPrefix(request.URL.Path, "/files/owner/jsexample/v1.0.0/"):
			_, _ = writer.Write(files[filepath.Base(request.URL.Path)])
		default:
			http.NotFound(writer, request)
		}
	}))
	t.Cleanup(server.Close)
	addresses, patterns := moduleIndexAddresses, moduleFileAddresses
	api := moduleRepositoryAPI
	moduleIndexAddresses = []string{server.URL + "/broken/index.json", server.URL + "/index.json"}
	moduleFileAddresses = []string{server.URL + "/stale/%s/%s/%s", server.URL + "/files/%s/%s/%s"}
	// 镜像全灭时的 api.github.com 兜底也指到本地（会 404 快速失败），
	// 测试不碰外网。
	moduleRepositoryAPI = server.URL
	t.Cleanup(func() { moduleIndexAddresses, moduleFileAddresses, moduleRepositoryAPI = addresses, patterns, api })

	engine := &nativeEngine{downloader: &Downloader{cfg: Config{dataDir: t.TempDir()}, client: server.Client()}, cacheDirectory: t.TempDir()}
	ctx := context.Background()
	entries, err := engine.moduleIndex(ctx)
	if err != nil || len(entries) != 3 || entries[0].ID != "jsexample" || entries[1].ID != "renamed" || entries[2].ID != "tampered" {
		t.Fatalf("index = %+v, %v", entries, err)
	}
	// 模板顺序即镜像顺序：manifest.json 与 main.js 各先试一次 /stale/，
	// 内容与 sha256 不符再退到 /files/。
	info, err := engine.prepareModule(ctx, "", "", "jsexample", false)
	if err != nil || info.ID != "jsexample" || info.Token == "" || staleHits.Load() != 2 {
		t.Fatalf("prepare = %+v, %v, stale hits %d", info, err, staleHits.Load())
	}
	moduleFileAddresses = []string{server.URL + "/files/%s/%s/%s", server.URL + "/stale/%s/%s/%s"}
	before := staleHits.Load()
	if info, err := engine.prepareModule(ctx, "", "", "jsexample", false); err != nil || info.ID != "jsexample" || staleHits.Load() != before {
		t.Fatalf("fallback prepare = %+v, %v, stale hits %d", info, err, staleHits.Load()-before)
	}
	if _, err := engine.prepareModule(ctx, "", "", "renamed", false); err == nil || !strings.Contains(err.Error(), "实际是模块 jsexample") {
		t.Fatalf("renamed error = %v", err)
	}
	if _, err := engine.prepareModule(ctx, "", "", "tampered", false); err == nil || !strings.Contains(err.Error(), "校验不符") {
		t.Fatalf("tampered error = %v", err)
	}
	if _, err := engine.prepareModule(ctx, "", "", "future", false); err == nil || !strings.Contains(err.Error(), "没有 future") {
		t.Fatalf("future error = %v", err)
	}

	previous := bundledModules
	bundledModules = fstest.MapFS{
		"jsexample/" + moduleManifest: {Data: []byte(strings.Replace(string(files[moduleManifest]), `"version": "1.0.0"`, `"version": "0.9.0"`, 1))},
		"jsexample/" + moduleEntry:    {Data: files[moduleEntry]},
	}
	t.Cleanup(func() { bundledModules = previous })
	store, err := engine.moduleStore(ctx)
	items, _ := store["items"].([]moduleIndexEntry)
	if err != nil || len(items) != 4 || !items[0].Bundled || items[0].Version != "0.9.0" || items[1].Bundled || items[1].ID != "jsexample" {
		t.Fatalf("store with bundled and indexed copies = %+v, %v", items, err)
	}
	if info, err := engine.prepareModule(ctx, "", "", "jsexample", true); err != nil || info.Version != "0.9.0" {
		t.Fatalf("bundled prepare = %+v, %v", info, err)
	}
	if info, err := engine.prepareModule(ctx, "", "", "jsexample", false); err != nil || info.Version != "1.0.0" {
		t.Fatalf("indexed prepare beside bundled = %+v, %v", info, err)
	}
	if _, err := engine.prepareModule(ctx, "", "", "renamed", true); err == nil || !strings.Contains(err.Error(), "没有内置 renamed") {
		t.Fatalf("missing bundled error = %v", err)
	}
	if _, err := parseModuleIndex([]byte(`{"format": 2, "modules": []}`)); err == nil || !strings.Contains(err.Error(), "更新应用") {
		t.Fatalf("format error = %v", err)
	}
}

// TestModuleIndexMirrorsFromGitHubAddress 校验「一份索引三处镜像」的展开规则：
// raw、带 refs/heads 的 raw、jsDelivr 与 github.com/blob 四种写法都归到同一组
// jsDelivr / fastly / raw 地址。
func TestModuleIndexMirrorsFromGitHubAddress(t *testing.T) {
	want := []string{
		"https://cdn.jsdelivr.net/gh/jqk4388/guoapp-modules-private@main/index.json",
		"https://fastly.jsdelivr.net/gh/jqk4388/guoapp-modules-private@main/index.json",
		"https://raw.githubusercontent.com/jqk4388/guoapp-modules-private/main/index.json",
	}
	for _, address := range []string{
		"https://raw.githubusercontent.com/jqk4388/guoapp-modules-private/main/index.json",
		"https://raw.githubusercontent.com/jqk4388/guoapp-modules-private/refs/heads/main/index.json",
		"https://cdn.jsdelivr.net/gh/jqk4388/guoapp-modules-private@main/index.json",
		"https://github.com/jqk4388/guoapp-modules-private/blob/main/index.json",
	} {
		if got := moduleIndexMirrors(address); len(got) != 3 || got[0] != want[0] || got[1] != want[1] || got[2] != want[2] {
			t.Fatalf("mirrors(%q) = %v", address, got)
		}
	}
	// 自建镜像原样返回，不硬套 GitHub 的地址模板。
	custom := "https://mirror.example.com/index.json"
	if got := moduleIndexMirrors(custom); len(got) != 1 || got[0] != custom {
		t.Fatalf("custom mirrors = %v", got)
	}
}

// TestParseModuleIndexAcceptsStoreVariants 覆盖两家商店的写法差异：
// guoappcheng 的索引没有 format、guoappjqk 的条目带 path 且标签带模块前缀。
func TestParseModuleIndexAcceptsStoreVariants(t *testing.T) {
	sum := strings.Repeat("a", 64)
	raw := []byte(`{"modules":[
		{"id":"fullboys","name":"FullBoys","version":"0.1.0","api":1,"adult":true,
		 "repo":"jqk4388/guoapp-modules-private","tag":"fullboys-v0.1.0","path":"fullboys",
		 "sha256":{"manifest.json":"` + sum + `","main.js":"` + sum + `"}},
		{"id":"escape","name":"越界","version":"1.0.0","api":1,
		 "repo":"owner/repo","tag":"v1.0.0","path":"../secret",
		 "sha256":{"manifest.json":"` + sum + `","main.js":"` + sum + `"}}
	]}`)
	entries, err := parseModuleIndex(raw)
	if err != nil {
		t.Fatalf("legacy format rejected: %v", err)
	}
	if len(entries) != 1 || entries[0].ID != "fullboys" || entries[0].Path != "fullboys" {
		t.Fatalf("entries = %+v", entries)
	}
}

// TestFetchIndexGroupMergesNewestVersion 校验多镜像并发取回后按版本合并：
// 同一模块只留一条，且取版本较新的那份。
func TestFetchIndexGroupMergesNewestVersion(t *testing.T) {
	sum := strings.Repeat("b", 64)
	index := func(version string) []byte {
		return []byte(`{"format":1,"modules":[{"id":"hongguo","name":"红果","version":"` + version + `","api":1,
			"repo":"owner/hongguo","tag":"v1.0.0","sha256":{"manifest.json":"` + sum + `","main.js":"` + sum + `"}}]}`)
	}
	old := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write(index("1.0.3"))
	}))
	defer old.Close()
	fresh := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write(index("1.0.4"))
	}))
	defer fresh.Close()
	engine := &nativeEngine{downloader: &Downloader{cfg: Config{dataDir: t.TempDir()}, client: old.Client()}}
	entries, ok, failures := engine.fetchIndexGroup(context.Background(), []string{old.URL + "/index.json", fresh.URL + "/index.json"})
	if !ok || len(failures) != 0 {
		t.Fatalf("ok=%v failures=%v", ok, failures)
	}
	if len(entries) != 1 || entries[0].Version != "1.0.4" {
		t.Fatalf("merged = %+v", entries)
	}
}

// TestFetchIndexedFileUsesModulePath 校验带 path 的条目会去 <tag>/<path>/ 下取文件。
func TestFetchIndexedFileUsesModulePath(t *testing.T) {
	manifest := []byte(`{"id":"packed"}`)
	code := []byte("module.exports = {};")
	manifestSum := sha256.Sum256(manifest)
	codeSum := sha256.Sum256(code)
	var gotPath atomic.Value
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath.Store(r.URL.Path)
		switch filepath.Base(r.URL.Path) {
		case moduleManifest:
			_, _ = w.Write(manifest)
		case moduleEntry:
			_, _ = w.Write(code)
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	patterns := moduleFileAddresses
	moduleFileAddresses = []string{server.URL + "/files/%s/%s/%s"}
	t.Cleanup(func() { moduleFileAddresses = patterns })
	engine := &nativeEngine{downloader: &Downloader{cfg: Config{dataDir: t.TempDir()}, client: server.Client()}}
	entry := moduleIndexEntry{
		ID: "packed", Name: "packed", Version: "1.0.0", API: moduleAPIVersion,
		Repo: "owner/pack", Tag: "packed-v1.0.0", Path: "modules/packed",
		SHA256: map[string]string{
			moduleManifest: hex.EncodeToString(manifestSum[:]),
			moduleEntry:    hex.EncodeToString(codeSum[:]),
		},
	}
	data, err := engine.fetchIndexedFile(context.Background(), entry, moduleEntry, moduleEntryBytes)
	if err != nil || string(data) != string(code) {
		t.Fatalf("fetchIndexedFile = %q, %v", data, err)
	}
	if path, _ := gotPath.Load().(string); path != "/files/owner/pack/packed-v1.0.0/modules/packed/main.js" {
		t.Fatalf("requested path = %q", path)
	}
}

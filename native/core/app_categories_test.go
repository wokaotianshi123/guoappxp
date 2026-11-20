package core

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

// TestNativeCategoriesDedupeAll 锁住分类菜单不出现两个「全部」：
// 商店里的 maccmsweb 模板模块 categories() 返回 [{id:"", name:"全部"}]，
// 应用自己也预置了「全部」。同时保证「模块只给一条全部」不被当成错误。
func TestNativeCategoriesDedupeAll(t *testing.T) {
	cases := []struct {
		name     string
		manifest string
		code     string
		wantIDs  []string
	}{
		{
			name:     "模块只给一条全部",
			manifest: `{"id":"allonly","name":"只有全部","runtime":"js","api":1,"adult":false}`,
			code: `
module.exports = {
  categories() { return [{ id: "", name: "全部" }]; },
  catalogPage() { return { items: [], hasMore: false }; },
  detail() { return { drama: { sourceId: "x", title: "x" }, chapters: [] }; },
  search() { return { items: [], hasMore: false }; }
};`,
			wantIDs: []string{""},
		},
		{
			name:     "全部加真实分类",
			manifest: `{"id":"allplus","name":"全部加分类","runtime":"js","api":1,"adult":false}`,
			code: `
module.exports = {
  categories() { return [{ id: "", name: "全部" }, { id: "27", name: "短剧" }]; },
  catalogPage() { return { items: [], hasMore: false }; },
  detail() { return { drama: { sourceId: "x", title: "x" }, chapters: [] }; },
  search() { return { items: [], hasMore: false }; }
};`,
			wantIDs: []string{"", "27"},
		},
		{
			name:     "重复分类只留一份",
			manifest: `{"id":"dupcat","name":"重复分类","runtime":"js","api":1,"adult":false}`,
			code: `
module.exports = {
  categories() { return [{ id: "27", name: "短剧" }, { id: "27", name: "短剧" }, { id: "31", name: "动漫" }]; },
  catalogPage() { return { items: [], hasMore: false }; },
  detail() { return { drama: { sourceId: "x", title: "x" }, chapters: [] }; },
  search() { return { items: [], hasMore: false }; }
};`,
			wantIDs: []string{"", "27", "31"},
		},
	}

	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			directory := writeTestModule(t, testCase.manifest, testCase.code)
			module, err := readModule(directory)
			if err != nil {
				t.Fatal(err)
			}
			engine := &nativeEngine{
				downloader: &Downloader{cfg: Config{dataDir: t.TempDir()}},
				catalogs:   map[string][]LibraryDrama{}, catalogStates: map[string]nativeCatalogState{},
			}
			Unregister(module.manifest.ID)
			Register(module.descriptor(), module.provider)
			t.Cleanup(func() { Unregister(module.manifest.ID) })

			categories, err := engine.nativeCategories(context.Background(), module.manifest.ID, true)
			if err != nil {
				t.Fatalf("nativeCategories: %v", err)
			}
			got := make([]string, 0, len(categories))
			for _, category := range categories {
				got = append(got, category.ID)
			}
			if len(got) != len(testCase.wantIDs) {
				t.Fatalf("分类 = %v，期望 %v", got, testCase.wantIDs)
			}
			for index := range got {
				if got[index] != testCase.wantIDs[index] {
					t.Fatalf("分类 = %v，期望 %v", got, testCase.wantIDs)
				}
			}
		})
	}
}

// TestProviderBaseURLFallsBackToManifestBase 锁住 providerBaseURL 的清单基址回退：
// 商店里的 maccmsweb 模板模块只写 base、baseUrl 留空，providerBaseURL 返回空串
// 会让 RehostProviderURL 拼不出地址，表现为「站源暂未返回剧集」。
func TestProviderBaseURLFallsBackToManifestBase(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = writer.Write([]byte(`<html><body></body></html>`))
	}))
	defer server.Close()

	directory := t.TempDir()
	manifest, err := json.Marshal(map[string]any{
		"id": "basefallback", "name": "基址回退", "runtime": "js", "api": 1,
		"adult": false, "base": server.URL,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, moduleManifest), manifest, 0o600); err != nil {
		t.Fatal(err)
	}
	code := `
module.exports = {
  categories() { return []; },
  catalogPage() { return { items: [], hasMore: false }; },
  detail() { return { drama: { sourceId: "x", title: "x" }, chapters: [] }; },
  search() { return { items: [], hasMore: false }; }
};`
	if err := os.WriteFile(filepath.Join(directory, moduleEntry), []byte(code), 0o600); err != nil {
		t.Fatal(err)
	}
	module, err := readModule(directory)
	if err != nil {
		t.Fatal(err)
	}
	if got := module.descriptor().BaseURL; got != server.URL {
		t.Fatalf("descriptor().BaseURL = %q，期望 %q", got, server.URL)
	}

	downloader := &Downloader{cfg: Config{dataDir: t.TempDir()}}
	Unregister(module.manifest.ID)
	Register(module.descriptor(), module.provider)
	t.Cleanup(func() { Unregister(module.manifest.ID) })
	if got := downloader.providerBaseURL(module.manifest.ID); got != server.URL {
		t.Fatalf("providerBaseURL = %q，期望 %q", got, server.URL)
	}
	candidates := downloader.providerURLCandidates(context.Background(), server.URL+"/list/1.html")
	if len(candidates) == 0 {
		t.Fatal("候选地址不能为空")
	}
}

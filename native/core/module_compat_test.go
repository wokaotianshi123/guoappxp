package core

import (
	"context"
	"reflect"
	"strings"
	"testing"
)

// TestParseModuleAcceptsStoreCapabilities 覆盖 guoappcheng 商店的清单口径：
// 能力名里带 catalog / detail / media（基础三件套）时不再报「未知的模块能力」，
// 扩展能力（search 等）照旧登记。
func TestParseModuleAcceptsStoreCapabilities(t *testing.T) {
	manifest := []byte(`{
		"id": "huangdou", "name": "黄豆", "version": "1.1.0", "runtime": "js", "api": 1,
		"adult": false, "category": "shortDrama",
		"capabilities": ["catalog", "detail", "search", "media"],
		"hosts": ["example.com"]
	}`)
	module, err := parseModule(manifest, []byte("module.exports = {};"))
	if err != nil {
		t.Fatalf("parseModule: %v", err)
	}
	if !module.capabilities[reflect.TypeFor[Searcher]()] {
		t.Fatal("search capability not registered")
	}
	if descriptor := module.descriptor(); descriptor.Category != "shortDrama" {
		t.Fatalf("category = %q", descriptor.Category)
	}
	// 真正的拼写错误仍然要拦下来，不能因为放行基础名就什么都能装。
	bad := []byte(`{
		"id": "typo", "name": "typo", "version": "1.0.0", "runtime": "js", "api": 1,
		"adult": false, "capabilities": ["catlog"]
	}`)
	if _, err := parseModule(bad, []byte("module.exports = {};")); err == nil || !strings.Contains(err.Error(), "未知的模块能力") {
		t.Fatalf("typo capability error = %v", err)
	}
}

// TestModuleSourceClass 校验 family/category 到站源类目的推导，以及显式
// group/groupName 的原有行为没有被覆盖。
func TestModuleSourceClass(t *testing.T) {
	cases := []struct {
		name    string
		extra   string
		class   string
		group   string
		groupAs string
	}{
		{"category 优先于 family", `"family": "huangguo", "category": "video"`, "video", "", ""},
		{"只写 family 时按 family", `"family": "huangguo"`, "huangguo", "", ""},
		{"短剧类大小写归一", `"category": "shortDrama"`, "shortDrama", "", ""},
		{"小写写法也认", `"category": "shortdrama"`, "shortDrama", "", ""},
		{"视频类", `"category": "video"`, "video", "", ""},
		{"没写类目", ``, "", "", ""},
		{"显式分组保持原义", `"group": "huangguo-family", "groupName": "黄果系", "category": "video"`, "video", "huangguo-family", "黄果系"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			extra := tc.extra
			if extra != "" {
				extra = "," + extra
			}
			manifest := []byte(`{"id": "demo", "name": "示例", "version": "1.0.0", "runtime": "js",
				"api": 1, "adult": false, "hosts": ["example.com"]` + extra + `}`)
			module, err := parseModule(manifest, []byte("module.exports = {};"))
			if err != nil {
				t.Fatalf("parseModule: %v", err)
			}
			descriptor := module.descriptor()
			if descriptor.Category != tc.class {
				t.Fatalf("category = %q, want %q", descriptor.Category, tc.class)
			}
			if descriptor.Group != tc.group || descriptor.GroupName != tc.groupAs {
				t.Fatalf("group = %q/%q, want %q/%q", descriptor.Group, descriptor.GroupName, tc.group, tc.groupAs)
			}
			info := moduleInfo(module.manifest)
			if info.Category != tc.class || info.Group != tc.group || info.GroupName != tc.groupAs {
				t.Fatalf("moduleInfo = %+v", info)
			}
		})
	}
}

// TestParseModuleAcceptsStoreCapabilityAliases 覆盖 guoappcheng 清单里的两种写法：
// 「搜索联想」写 suggest（本站叫 suggestions），以及 routes / homefeed /
// calendar / skippreset 这些本站没有接口的能力——都按已知处理，不拦安装。
func TestParseModuleAcceptsStoreCapabilityAliases(t *testing.T) {
	manifest := []byte(`{
		"id": "dongpiandi", "name": "真果鉴", "version": "1.5.0", "runtime": "js", "api": 1,
		"adult": false, "category": "shortDrama",
		"capabilities": ["catalog", "detail", "search", "suggest", "routes",
			"homefeed", "calendar", "skippreset"]
	}`)
	module, err := parseModule(manifest, []byte("module.exports = {};"))
	if err != nil {
		t.Fatalf("parseModule: %v", err)
	}
	if !module.capabilities[reflect.TypeFor[Suggester]()] {
		t.Fatal("suggest 应折回 suggestions 能力")
	}
	if !module.capabilities[reflect.TypeFor[Searcher]()] {
		t.Fatal("search 能力丢失")
	}
}

// TestModuleReadsManifestThroughHost 校验 host.manifest() / host.baseUrl()：
// guoappcheng 的 maccms 模块族在脚本开头就读这两个成员，缺了会报
// "object has no member 'manifest'"。
func TestModuleReadsManifestThroughHost(t *testing.T) {
	directory := writeTestModule(t, `{
		"id": "manifesttest", "name": "清单测试", "runtime": "js", "api": 1, "adult": false,
		"base": "https://api.example.invalid/v1",
		"config": {"site": "demo", "pages": 3}
	}`, `
module.exports = {
  categories() {
    var manifest = host.manifest();
    return [{ id: manifest.config.site, name: manifest.config.pages + "@" + host.baseUrl() }];
  },
  catalogPage() { return { items: [], hasMore: false }; },
  detail() { return { drama: { sourceId: "x", title: "x" }, chapters: [] }; },
  search() { return { items: [], hasMore: false }; }
};`)
	module, err := readModule(directory)
	if err != nil {
		t.Fatal(err)
	}
	categories, err := module.provider(&moduleTestHost{}).Categories(context.Background(), false)
	if err != nil {
		t.Fatalf("categories: %v", err)
	}
	if len(categories) != 1 || categories[0].ID != "demo" || categories[0].Name != "3@https://api.example.invalid/v1" {
		t.Fatalf("categories = %+v", categories)
	}
	// baseUrl 留空时退回清单的 base：descriptor().BaseURL 应是归一后的地址，
	// 否则 providerBaseURL 会返回空串，轮换逻辑拼不出地址，表现为「站源暂未返回剧集」。
	if descriptor := module.descriptor(); descriptor.BaseURL != "https://api.example.invalid/v1" {
		t.Fatalf("baseUrl 应退回清单的 base，得到 %q", descriptor.BaseURL)
	}
}

// TestModuleWithoutValidCategoryAcceptsDeclaredCategory 锁住商店里 maccmsweb
// 模板模块的分类行为：这些模块只导出 categories/catalogPage/detail/search，
// 没有 validCategory。若此时判 false，模块自己 categories() 报的分类会被应用
// 判成「内容分类无效」。
func TestModuleWithoutValidCategoryAcceptsDeclaredCategory(t *testing.T) {
	directory := writeTestModule(t, `{
		"id": "novalidcategory", "name": "无分类校验", "runtime": "js", "api": 1, "adult": false,
		"base": "https://api.example.invalid",
		"config": {"categories": [{"id": "27", "name": "短剧"}]}
	}`, `
module.exports = {
  categories() { return [{ id: "27", name: "短剧" }]; },
  catalogPage() { return { items: [], hasMore: false }; },
  detail() { return { drama: { sourceId: "x", title: "x" }, chapters: [] }; },
  search() { return { items: [], hasMore: false }; }
};`)
	module, err := readModule(directory)
	if err != nil {
		t.Fatal(err)
	}
	// provider 还没创建时也要放行（应用首次点分类可能早于任何 provider 调用）。
	if !module.validCategory("27") {
		t.Fatal("provider 未创建时，模块声明过的分类应放行")
	}
	_ = module.provider(&moduleTestHost{})
	if !module.validCategory("27") {
		t.Fatal("模块没有 validCategory 时，应交给 catalogPage 自己兜底，不能判无效")
	}
	if !module.validCategory("") {
		t.Fatal("空分类（全部）永远有效")
	}
	// 形态非法仍然要拦。
	if module.validCategory("a|b") {
		t.Fatal("含缓存键分隔符的分类应被拒绝")
	}
}

// TestProviderURLCandidatesKeepRaw 锁住候选地址兜底：镜像地址缺失时
// RehostProviderURL 返回空串，候选列表不能因此变空。
func TestProviderURLCandidatesKeepRaw(t *testing.T) {
	downloader := &Downloader{cfg: Config{dataDir: t.TempDir()}}
	raw := "https://unknown.invalid/list/1.html"
	candidates := downloader.providerURLCandidates(context.Background(), raw)
	if len(candidates) != 1 || candidates[0] != raw {
		t.Fatalf("候选地址 = %v，期望只保留原始地址", candidates)
	}
}

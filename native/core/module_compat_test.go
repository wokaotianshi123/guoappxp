package core

import (
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

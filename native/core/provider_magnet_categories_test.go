package core

import (
	"context"
	"testing"
)

func magnetTestCategorySite() magnetSite {
	return magnetSite{
		ID:    10001,
		Name:  "SOBT",
		State: true,
		Request: magnetSiteRequest{
			MainURL:   "https://sobt.test/",
			SearchURL: "https://sobt.test/s?keyword=[keyword]&page=[page]",
		},
	}
}

func TestMagnetParseCategoriesFromNav(t *testing.T) {
	const body = `<html><body>
<nav>
  <a href="/">首页</a>
  <a href="/list/1.html">电影</a>
  <a href="/list/2.html">电视剧</a>
  <a href="/list/3.html">动漫</a>
  <a href="/download.html">下载APP</a>
  <a href="/detail/123.html">流浪地球 2026 4K 蓝光原盘 未删减</a>
  <a href="javascript:void(0)">更多</a>
  <a href="/list/1.html">电影</a>
</nav>
<div><a href="/movie/999.html">某部片名很长很长很长</a></div>
</body></html>`
	items := magnetParseCategories(magnetTestCategorySite(), body)
	if len(items) != 3 {
		t.Fatalf("导航分类应抽到 3 项（电影/电视剧/动漫），实际 %d: %+v", len(items), items)
	}
	want := map[string]string{
		"电影":  "https://sobt.test/list/1.html",
		"电视剧": "https://sobt.test/list/2.html",
		"动漫":  "https://sobt.test/list/3.html",
	}
	for _, item := range items {
		if item.URL != want[item.Name] {
			t.Errorf("分类 %q 地址错误: %q", item.Name, item.URL)
		}
		if item.SiteID != 10001 || item.SiteName != "SOBT" {
			t.Errorf("分类未带上所属站源: %+v", item)
		}
	}
}

func TestMagnetParseCategoriesWithoutNavUsesLinkHint(t *testing.T) {
	const body = `<html><body>
<a href="/list/1.html">电影</a>
<a href="/detail/123.html">片名</a>
<a href="/about.html">关于</a>
</body></html>`
	items := magnetParseCategories(magnetTestCategorySite(), body)
	if len(items) != 1 || items[0].Name != "电影" {
		t.Fatalf("无导航容器时应只挑带分类特征的链接，实际: %+v", items)
	}
}

func TestMagnetParseCategoriesEmptyWhenSiteHasNone(t *testing.T) {
	const body = `<html><body><a href="/detail/1.html">随便一个片名</a></body></html>`
	items := magnetParseCategories(magnetTestCategorySite(), body)
	if len(items) != 0 {
		t.Fatalf("站点没有分类时应返回空，由界面回退「全部」，实际: %+v", items)
	}
}

func TestMagnetCategoryAddressPaging(t *testing.T) {
	cases := []struct {
		raw  string
		page int
		want string
	}{
		{"https://a.test/cate/[page].html", 3, "https://a.test/cate/3.html"},
		{"https://a.test/list/1.html?page=1", 3, "https://a.test/list/1.html?page=3"},
		{"https://a.test/cate/3.html", 1, "https://a.test/cate/3.html"},
		{"https://a.test/cate/3.html", 2, "https://a.test/cate/3.html?page=2"},
		{"", 2, ""},
	}
	for _, tc := range cases {
		if got := magnetCategoryAddress(tc.raw, tc.page); got != tc.want {
			t.Errorf("magnetCategoryAddress(%q, %d) = %q, 期望 %q", tc.raw, tc.page, got, tc.want)
		}
	}
}

func TestMagnetCategoriesRespectsSelectedSites(t *testing.T) {
	// 传入一个不存在的站源 id：不应该去抓任何站点首页，直接返回空分类。
	result, err := magnetCategories(context.Background(), false, []int{999999})
	if err != nil {
		t.Fatalf("magnetCategories 出错: %v", err)
	}
	items, ok := result["items"].([]magnetCategory)
	if !ok || len(items) != 0 {
		t.Fatalf("未匹配到站源时应返回空分类，实际: %+v", result["items"])
	}
}

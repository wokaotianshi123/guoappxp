package core

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// 磁力源注册表是包级全局，每个用例结束都还原，避免与既有 35 站内嵌规则测试互相污染。
func withFreshMagnetSources(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	magnetSources.Lock()
	magnetSources.path = filepath.Join(dir, "magnet_sources.json")
	magnetSources.custom = nil
	magnetSources.disabled = map[int]bool{}
	magnetSources.loaded = true
	magnetSources.Unlock()
	t.Cleanup(func() {
		magnetSources.Lock()
		magnetSources.path = ""
		magnetSources.custom = nil
		magnetSources.disabled = map[int]bool{}
		magnetSources.loaded = false
		magnetSources.Unlock()
		// 热词缓存也可能被下面的用例写过，一并清掉。
		magnetHotWordCache.Lock()
		magnetHotWordCache.items = nil
		magnetHotWordCache.source = ""
		magnetHotWordCache.at = time.Time{}
		magnetHotWordCache.Unlock()
	})
	return magnetSourcesPath()
}

func magnetSourcesPath() string {
	magnetSources.RLock()
	defer magnetSources.RUnlock()
	return magnetSources.path
}

const flatMagnetRule = `{
  "name": "测试磁力站",
  "mainUrl": "https://a.test",
  "searchUrl": "https://a.test/s?keyword=[keyword]&page=[page]",
  "expressionModel": {
    "group": "//li[contains(@class,'item')]",
    "title": ".//a[1]",
    "url": ".//a[1]/@href",
    "magnet": ".//a[1]/@href"
  }
}`

func TestMagnetCustomSourcesRoundTrip(t *testing.T) {
	path := withFreshMagnetSources(t)
	builtin, err := loadMagnetSites()
	if err != nil {
		t.Fatalf("内置站源加载失败: %v", err)
	}
	if len(builtin) != 35 {
		t.Fatalf("内置站源应为 35 个，实际 %d", len(builtin))
	}

	record, err := magnetAddCustomSite("我的磁力站", "https://a.test", flatMagnetRule)
	if err != nil {
		t.Fatalf("新增自定义源失败: %v", err)
	}
	if record.ID < magnetCustomIDBase || !record.Custom {
		t.Fatalf("自定义源 ID / 标记不对: %+v", record)
	}
	all, err := loadMagnetSites()
	if err != nil || len(all) != 36 {
		t.Fatalf("合并后应有 36 个站源，实际 %d, err=%v", len(all), err)
	}
	if !all[len(all)-1].Custom {
		t.Fatal("新增的站源没有打上 custom 标记")
	}
	if all[len(all)-1].Request.SearchURL == "" {
		t.Fatal("扁平规则里的 searchUrl 没有归一化")
	}

	list, err := magnetSiteList()
	if err != nil {
		t.Fatal(err)
	}
	items := list["items"].([]magnetSiteItem)
	if len(items) != 36 || items[len(items)-1].Rule == "" {
		t.Fatal("magnetSites 返回里缺少可编辑的规则文本")
	}

	// 规则确实落盘，重启后还能读回来。
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("自定义源没有写入磁盘: %v", err)
	}
	var stored magnetSourceFile
	if json.Unmarshal(body, &stored) != nil || len(stored.Custom) != 1 {
		t.Fatalf("落盘内容异常: %s", body)
	}

	// 删自定义源 + 删内置站 + 恢复默认。
	if err := magnetRemoveSite(record.ID); err != nil {
		t.Fatal(err)
	}
	if err := magnetRemoveSite(10001); err != nil {
		t.Fatal(err)
	}
	afterRemoval, _ := loadMagnetSites()
	if len(afterRemoval) != 34 {
		t.Fatalf("删除后应剩 34 个站源，实际 %d", len(afterRemoval))
	}
	for _, site := range afterRemoval {
		if site.ID == 10001 {
			t.Fatal("内置站 10001 删除后仍出现在列表里")
		}
	}
	removed, err := magnetResetSites()
	if err != nil {
		t.Fatal(err)
	}
	// 自定义源被真正删除，注册表里只剩一条「禁用内置站」的覆盖记录。
	if removed != 1 {
		t.Fatalf("恢复默认应清掉 1 条覆盖记录，实际 %d", removed)
	}
	restored, _ := loadMagnetSites()
	if len(restored) != 35 {
		t.Fatalf("恢复默认后应回到 35 个站源，实际 %d", len(restored))
	}
}

func TestMagnetParseCustomRuleRejectsBadRule(t *testing.T) {
	for _, rule := range []string{"", "not-json", `{"mainUrl":"https://a.test"}`} {
		if _, err := magnetParseCustomRule("", "https://a.test", rule); err == nil {
			t.Errorf("非法规则 %q 应被拒绝", rule)
		}
	}
	site, err := magnetParseCustomRule("手工命名", "https://a.test", flatMagnetRule)
	if err != nil {
		t.Fatalf("合法扁平规则解析失败: %v", err)
	}
	if site.Name != "手工命名" || site.Expression.Group == "" {
		t.Fatalf("扁平规则字段丢失: %+v", site)
	}
}

func TestMagnetBrowseAllowsEmptyQuery(t *testing.T) {
	if word := magnetDefaultBrowseWord(); strings.TrimSpace(word) == "" {
		t.Fatal("分类浏览的默认词不能为空")
	}
	// 空关键词在 browse 模式下会补默认词，而不是直接报「请输入搜索关键词」。
	// 不真的发网络请求（站点不可达），只验证不会在参数校验阶段被拒。
	result, err := magnetBrowse(context.Background(), "", 1, []int{-1})
	if err != nil {
		t.Fatalf("browse 不应因空关键词报错: %v", err)
	}
	if len(result.Items) != 0 {
		t.Fatalf("没有匹配站源时应返回空列表，实际 %d 条", len(result.Items))
	}
	if _, err := magnetSearch(context.Background(), "", 1, nil); err == nil {
		t.Fatal("普通搜索仍应拒绝空关键词")
	}
}

func TestMagnetHotWordsAlwaysTwenty(t *testing.T) {
	withFreshMagnetSources(t)
	// 预置缓存，避免测试真的去抓外网站点。
	pool := append([]string(nil), magnetHotWordPool...)
	magnetHotWordCache.Lock()
	magnetHotWordCache.items = pool[:magnetHotWordCount]
	magnetHotWordCache.source = "内置热词"
	magnetHotWordCache.at = time.Now()
	magnetHotWordCache.Unlock()
	result, err := magnetHotWords(context.Background(), false)
	if err != nil {
		t.Fatal(err)
	}
	items := result["items"].([]string)
	if len(items) != magnetHotWordCount {
		t.Fatalf("热词应为 20 个，实际 %d", len(items))
	}
	seen := map[string]bool{}
	for _, word := range items {
		if seen[word] || strings.TrimSpace(word) == "" {
			t.Fatalf("热词重复或为空: %q", word)
		}
		seen[word] = true
	}
	for word, usable := range map[string]bool{
		"三体": true, "Avatar 4K": true, "下载": false,
		"首页": false, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa": false, "www.test.com": false,
	} {
		if got := magnetHotWordUsable(word); got != usable {
			t.Errorf("magnetHotWordUsable(%q)=%v, want %v", word, got, usable)
		}
	}
}

func TestMagnetAnalyzeSiteBuildsRuleFromHTML(t *testing.T) {
	const page = `<html><head><title>测试磁力站 - 首页</title></head><body>
<form action="/search"><input type="text" name="keyword"><input type="hidden" name="x" value="1"></form>
<ul>
<li class="search-item"><a href="/hash/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa">三体 第一季 2026 HD</a><span class="size">1.2GB</span></li>
<li class="search-item"><a href="/hash/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb">流浪地球 4K 蓝光</a><span class="size">8.4GB</span></li>
<li class="search-item"><a href="/hash/cccccccccccccccccccccccccccccccccccccccc">繁花 全集</a><span class="size">12GB</span></li>
</ul></body></html>`
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write([]byte(page))
	}))
	defer server.Close()

	result, err := magnetAnalyzeSite(context.Background(), server.URL)
	if err != nil {
		t.Fatalf("自动识别失败: %v", err)
	}
	rule := result["rule"].(string)
	if !strings.Contains(rule, "keyword=[keyword]") || !strings.Contains(rule, "page=[page]") {
		t.Fatalf("搜索地址模板没拼出来: %s", rule)
	}
	if !strings.Contains(rule, "expressionModel") || !strings.Contains(rule, "search-item") {
		t.Fatalf("列表 XPath 没识别出来: %s", rule)
	}
	if result["name"].(string) != "测试磁力站" {
		t.Fatalf("站名没从 title 取到: %v", result["name"])
	}
	// 生成的规则要能被 magnetParseCustomRule 直接吃下并保存。
	if _, err := magnetParseCustomRule("", server.URL, rule); err != nil {
		t.Fatalf("识别结果不是可保存的规则: %v", err)
	}
	if _, err := magnetAnalyzeSite(context.Background(), "not a url"); err == nil {
		t.Fatal("非法网址应被拒绝")
	}
}

func TestMagnetSourceStoreConcurrentRead(t *testing.T) {
	withFreshMagnetSources(t)
	var wait sync.WaitGroup
	for i := 0; i < 8; i++ {
		wait.Add(1)
		go func() {
			defer wait.Done()
			_, _ = loadMagnetSites()
			_, _ = magnetSiteList()
		}()
	}
	wait.Wait()
}

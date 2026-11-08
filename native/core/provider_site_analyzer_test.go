package core

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestSiteAnalyzerMakeCategoryURL(t *testing.T) {
	a := &siteAnalyzer{site: "https://example.com"}
	cases := []struct {
		href string
		want string
	}{
		{"/vodtype/2.html", "https://example.com/vodtype/{cateId}-{catePg}.html"},
		{"/index.php/vod/show/id/3/page/2.html", "https://example.com/index.php/vod/show/id/{cateId}/page/{catePg}.html"},
		{"https://example.com/vodshow/20-----------.html", "https://example.com/vodshow/{cateId}------------{catePg}.html"},
		{"/type/movie/", "https://example.com/type/movie/{cateId}/{catePg}.html"},
	}
	for _, item := range cases {
		if got := a.makeCategoryURL(item.href); got != item.want {
			t.Errorf("makeCategoryURL(%q) = %q, want %q", item.href, got, item.want)
		}
	}
	filled := siteFillCategoryURL(cases[1].want, "7", "3")
	if filled != "https://example.com/index.php/vod/show/id/7/page/3.html" {
		t.Fatalf("占位符填充错误: %s", filled)
	}
}

func TestSiteAnalyzerRuleJSONOnlyWritesEngineFields(t *testing.T) {
	fields := map[string]string{
		"主页url": "https://example.com",
		"分类url": "https://example.com/vodtype/{cateId}-{catePg}.html",
		// jar 专属字段不该出现在给 guoappxp 引擎的规则里。
		"搜索模式": "0",
		"嗅探词":  ".m3u8#.mp4",
	}
	text := siteRuleJSON(fields)
	if strings.Contains(text, "搜索模式") || strings.Contains(text, "嗅探词") {
		t.Fatalf("规则里混入了引擎不识别的 jar 字段: %s", text)
	}
	rule, ok := parseXBPQRule(text)
	if !ok {
		t.Fatalf("生成的规则无法被引擎解析: %s", text)
	}
	if rule.homeURL() != "https://example.com" {
		t.Fatalf("主页url 解析错误: %s", rule.homeURL())
	}
}

func TestSiteAnalyzerKnownRuleIsEngineCompatible(t *testing.T) {
	known := siteKnownRules["dmdy3.com"]
	if known == nil {
		t.Fatal("缺少 dmdy3.com 实测预设")
	}
	rule, ok := parseXBPQRule(siteRuleJSON(known))
	if !ok || rule.homeURL() == "" {
		t.Fatal("站点专属预设无法被引擎解析")
	}
	if !strings.Contains(known["播放列表"], "&&") {
		// 播放列表必须是字面分隔符，不能是截取串。
		return
	}
	t.Fatalf("播放列表写成了截取串会塌成 1 集: %q", known["播放列表"])
}

func TestSiteAnalyzerJSONKeysAndShield(t *testing.T) {
	array, id, title, picture := siteJSONKeys(`{"list":[{"vod_id":7,"vod_name":"测试剧","vod_pic":"a.jpg"}]}`)
	if array != "list" || id != "vod_id" || title != "vod_name" || picture != "vod_pic" {
		t.Fatalf("JSON 字段名探测错误: %s/%s/%s/%s", array, id, title, picture)
	}
	if !siteIsShield("<html><body>Just a moment... cf-turnstile</body></html>") {
		t.Fatal("未识别 Cloudflare 盾页")
	}
	if siteIsShield("<html><body>正常影视站首页</body></html>") {
		t.Fatal("正常页面被误判为盾页")
	}
}

func TestAnalyzeCustomSourceSiteActionIsWired(t *testing.T) {
	var input nativeInput
	if err := json.Unmarshal([]byte(`{"action":"analyzeCustomSourceSite","base":"https://example.com"}`), &input); err != nil {
		t.Fatal(err)
	}
	if input.Base != "https://example.com" {
		t.Fatalf("nativeInput.Base 未接收到网址: %q", input.Base)
	}
	if err := nativeAuthorizeInput(input); err != nil {
		t.Fatalf("自动识别动作被构建授权误拦: %v", err)
	}
}

// 一台本地 MacCMS 风格站点：首页给分类导航、分类页给影片卡片、
// 详情页给分集列表、搜索走 JSON 接口。整条自动识别链路都在这里跑通。
func newSiteAnalyzerFixture() http.Handler {
	return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Type", "text/html; charset=utf-8")
		path := request.URL.Path
		switch {
		case strings.HasPrefix(path, "/index.php/ajax/suggest"):
			writer.Header().Set("Content-Type", "application/json; charset=utf-8")
			fmt.Fprint(writer, `{"list":[{"id":101,"name":"测试剧一","pic":"https://img.example.com/a.jpg"}]}`)
			return
		case strings.HasPrefix(path, "/voddetail/"):
			fmt.Fprint(writer, `<!doctype html><html><head><title>测试剧一 - 在线播放</title></head><body>`+
				`<h1>测试剧一 全集</h1>`+
				`<div class="detail-content">这是一段足够长的剧情简介内容，用于验证详情字段反推。</div>`+
				`<ul class="stui-content__playlist">`+
				`<li><a href="/vodplay/101-1-1.html">第1集</a></li>`+
				`<li><a href="/vodplay/101-1-2.html">第2集</a></li>`+
				`<li><a href="/vodplay/101-1-3.html">第3集</a></li>`+
				`</ul>`+strings.Repeat(`<p>详情正文占位</p>`, 12)+`</body></html>`)
			return
		case strings.HasPrefix(path, "/vodtype/"):
			var cards strings.Builder
			for index := 101; index <= 104; index++ {
				fmt.Fprintf(&cards, `<li class="stui-vodlist__box">`+
					`<a href="/voddetail/%d.html" title="测试剧%d">`+
					`<img data-original="https://img.example.com/%d.jpg"></a>`+
					`<span class="pic-text text-right">更新至10集</span></li>`, index, index-100, index)
			}
			fmt.Fprint(writer, `<!doctype html><html><body><div class="stui-vodlist">`+
				cards.String()+`</div>`+strings.Repeat(`<p>列表页占位</p>`, 10)+`</body></html>`)
			return
		default:
			fmt.Fprint(writer, `<!doctype html><html><body><nav>`+
				`<a href="/vodtype/1.html">电影</a>`+
				`<a href="/vodtype/2.html">电视剧</a>`+
				`<a href="/vodtype/3.html">综艺</a>`+
				`<a href="/vodtype/4.html">动漫</a>`+
				`<a href="/voddetail/101.html">随便一部剧</a>`+
				`</nav>`+strings.Repeat(`<p>首页推荐占位内容</p>`, 20)+`</body></html>`)
			return
		}
	})
}

func TestAnalyzeCustomSourceSiteBuildsRuleFromHTML(t *testing.T) {
	server := httptest.NewServer(newSiteAnalyzerFixture())
	defer server.Close()
	d := &Downloader{
		cfg:           Config{Retries: 1},
		client:        server.Client(),
		limiter:       newRequestLimiter(20, 0),
		providerHosts: map[string]string{},
	}
	result, err := d.analyzeCustomSourceSite(context.Background(), server.URL)
	if err != nil {
		t.Fatalf("自动识别失败: %v", err)
	}
	if result.Mode != "规则" || result.Rule == "" {
		t.Fatalf("未生成规则（mode=%s）：%v", result.Mode, result.Notes)
	}
	rule, ok := parseXBPQRule(result.Rule)
	if !ok {
		t.Fatalf("生成的规则无法被引擎解析: %s", result.Rule)
	}
	category := rule.field("分类url")
	if !strings.Contains(category, "{cateId}") || !strings.Contains(category, "{catePg}") {
		t.Fatalf("分类url 缺少占位符: %s", category)
	}
	if !strings.Contains(rule.field("分类"), "电影$1") {
		t.Fatalf("分类串未按站点导航生成: %s", rule.field("分类"))
	}
	if !strings.Contains(rule.field("搜索url"), "{wd}") || rule.field("搜索数组") != "j:list" {
		t.Fatalf("JSON 搜索接口未转成引擎的 j: 路径: %s / %s",
			rule.field("搜索url"), rule.field("搜索数组"))
	}
	if !strings.Contains(rule.field("搜索链接"), "+j:id+") {
		t.Fatalf("搜索链接未拼接详情地址: %s", rule.field("搜索链接"))
	}
	// 播放列表在本引擎是分隔符，绝不能是 XBPQ jar 的 A&&B 截取串。
	if split := rule.field("播放列表"); split == "" || strings.Contains(split, "&&") {
		t.Fatalf("播放列表不是分集分隔符: %q", split)
	}
	if array := rule.field("数组"); array == "" {
		t.Fatal("列表数组字段未反推出来")
	} else {
		// 拿真实分类页 HTML 再试截一次，确认这个数组锚点真能出条目。
		body, fetchErr := d.fetchProviderText(context.Background(), server.URL+"/vodtype/1-1.html", server.URL)
		if fetchErr != nil {
			t.Fatalf("取分类页样本失败: %v", fetchErr)
		}
		if got := len(xbpqList(body, array)); got < 2 {
			t.Fatalf("生成的数组锚点只截出 %d 条: %s", got, array)
		}
	}
	if rule.field("播放数组") == "" || rule.field("播放链接") != `href="&&"` {
		t.Fatalf("播放字段未反推: %s / %s", rule.field("播放数组"), rule.field("播放链接"))
	}
	if len(result.Notes) == 0 {
		t.Fatal("缺少诊断说明")
	}
}

func TestAnalyzeCustomSourceSiteFallsBackOnShield(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		fmt.Fprint(writer, "<html><body>Just a moment... cf-turnstile 人机身份验证 "+
			strings.Repeat("checking your browser ", 30)+"</body></html>")
	}))
	defer server.Close()
	d := &Downloader{
		cfg:           Config{Retries: 1},
		client:        server.Client(),
		limiter:       newRequestLimiter(20, 0),
		providerHosts: map[string]string{},
	}
	result, err := d.analyzeCustomSourceSite(context.Background(), server.URL)
	if err != nil {
		t.Fatalf("盾页不该让自动识别报错: %v", err)
	}
	if result.Mode != "网址" || result.Rule != "" {
		t.Fatalf("盾页时应退回普通网页源且不产生坏规则，实际 mode=%s rule=%q", result.Mode, result.Rule)
	}
	if !strings.Contains(strings.Join(result.Notes, ""), "盾页") {
		t.Fatalf("诊断里没有说明盾页原因: %v", result.Notes)
	}
}

func TestAnalyzeCustomSourceSiteRejectsInvalidAddress(t *testing.T) {
	d := &Downloader{cfg: defaultConfig(), providerHosts: map[string]string{}}
	for _, address := range []string{"", "ftp://example.com", "not a url"} {
		if _, err := d.analyzeCustomSourceSite(context.Background(), address); err == nil {
			t.Errorf("非法网址 %q 应该被拒绝", address)
		}
	}
}

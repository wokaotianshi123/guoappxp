package core

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/anacrolix/torrent"
	"github.com/antchfx/htmlquery"
	"golang.org/x/net/html"
)

// 这些测试不碰真实网络：站源表是嵌进二进制的 cisou 快照，HTTP 用假 Transport
// 或 httptest 顶掉。这样 DHT / tracker / 站源可用性变化都不会让回归测试抖动。

type magnetRoundTripFunc func(*http.Request) (*http.Response, error)

func (fn magnetRoundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return fn(request)
}

func magnetResponse(body string) *http.Response {
	return &http.Response{
		StatusCode: http.StatusOK,
		Status:     "200 OK",
		Header:     make(http.Header),
		Body:       io.NopCloser(strings.NewReader(body)),
	}
}

func magnetDoc(t *testing.T, body string) *html.Node {
	t.Helper()
	doc, err := htmlquery.Parse(strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	return doc
}

func TestMagnetSitesEmbedded(t *testing.T) {
	sites, err := loadMagnetSites()
	if err != nil {
		t.Fatalf("嵌入的磁力站源表解析失败: %v", err)
	}
	if len(sites) != 35 {
		t.Fatalf("站源数量 = %d, want 35", len(sites))
	}
	seen := map[int]bool{}
	for _, site := range sites {
		if seen[site.ID] {
			t.Fatalf("站源 id 重复: %d", site.ID)
		}
		seen[site.ID] = true
		if !site.State || site.Request.SearchURL == "" ||
			site.Expression.Group == "" || site.Expression.Title == "" {
			t.Errorf("站源 %s 缺少必要字段", site.Name)
		}
	}
	list, err := magnetSiteList()
	if err != nil {
		t.Fatal(err)
	}
	if got := len(list["items"].([]magnetSiteItem)); got != 35 {
		t.Fatalf("magnetSites 返回 %d 个站源, want 35", got)
	}
}

func TestMagnetSearchAddress(t *testing.T) {
	site := magnetSite{Request: magnetSiteRequest{
		SearchURL: "https://a.test/[keyword].html?sort=rel&page=[page]",
	}}
	got := magnetSearchAddress(site, "三体 第一季", 3)
	want := "https://a.test/%E4%B8%89%E4%BD%93+%E7%AC%AC%E4%B8%80%E5%AD%A3.html?sort=rel&page=3"
	if got != want {
		t.Fatalf("搜索地址 = %q, want %q", got, want)
	}
}

func TestMagnetAbsoluteURL(t *testing.T) {
	site := magnetSite{Request: magnetSiteRequest{MainURL: "https://a.test/root/"}}
	cases := []struct{ in, want string }{
		{"/hash/abc", "https://a.test/hash/abc"},
		{"detail/1.html", "https://a.test/root/detail/1.html"},
		{"//cdn.test/x", "https://cdn.test/x"},
		{"https://b.test/x", "https://b.test/x"},
		{"magnet:?xt=urn:btih:abc", "magnet:?xt=urn:btih:abc"},
		{"", ""},
	}
	for _, item := range cases {
		if got := magnetAbsoluteURL(site, item.in); got != item.want {
			t.Errorf("magnetAbsoluteURL(%q) = %q, want %q", item.in, got, item.want)
		}
	}
}

func TestMagnetInfoHash(t *testing.T) {
	hex40 := "0123456789abcdef0123456789abcdef01234567"
	cases := []struct{ in, want string }{
		{"magnet:?xt=urn:btih:" + strings.ToUpper(hex40) + "&dn=x", hex40},
		{"https://a.test/hash/" + hex40 + ".html", hex40},
		{hex40, hex40},
		{"https://a.test/hash/ABCDEFGHIJKLMNOPQRSTUVWXYZ234567", "abcdefghijklmnopqrstuvwxyz234567"},
		{"https://a.test/index.html", ""},
		{"", ""},
	}
	for _, item := range cases {
		if got := magnetInfoHash(item.in); got != item.want {
			t.Errorf("magnetInfoHash(%q) = %q, want %q", item.in, got, item.want)
		}
	}
	if link := magnetCanonical(hex40, "测试 资源"); !strings.HasPrefix(link, "magnet:?xt=urn:btih:"+hex40+"&dn=") {
		t.Fatalf("magnetCanonical = %q", link)
	}
	if magnetCanonical("", "x") != "" {
		t.Fatal("空 infohash 不应生成磁力链接")
	}
}

func TestMagnetQueryAttribute(t *testing.T) {
	doc := magnetDoc(t, "<div><a href=\"/hash/abc\" title=\"资源\">名称</a></div>")
	if got := magnetText(doc, "//a/@href"); got != "/hash/abc" {
		t.Fatalf("属性抽取 = %q", got)
	}
	if got := magnetText(doc, "//a/@title"); got != "资源" {
		t.Fatalf("title 属性 = %q", got)
	}
	if got := magnetText(doc, "//a"); got != "名称" {
		t.Fatalf("文本抽取 = %q", got)
	}
	// 非法 XPath 不该让整个站点崩掉。
	if got := magnetText(doc, "//a["); got != "" {
		t.Fatalf("非法 XPath 应返回空，得到 %q", got)
	}
}

func TestMagnetParseListRelativeMagnet(t *testing.T) {
	hex1 := "1111111111111111111111111111111111111111"
	hex2 := "2222222222222222222222222222222222222222"
	site := magnetSite{
		ID: 90001, Name: "测试站",
		Request: magnetSiteRequest{MainURL: "https://a.test"},
		Expression: magnetSiteExpression{
			Group:  "//div[@class='item']",
			Title:  ".//h3/a",
			Size:   ".//span[@class='size']",
			Date:   ".//span[@class='date']",
			Magnet: ".//h3/a/@href",
		},
	}
	body := "<div class='item'><h3><a href='/hash/" + hex1 + "'>资源一</a></h3>" +
		"<span class='size'>1.2 GB</span><span class='date'>2026-11-08</span></div>" +
		"<div class='item'><h3><a href='/hash/" + hex2 + "'>资源二</a></h3></div>"
	items := magnetParseList(site, body)
	if len(items) != 2 {
		t.Fatalf("解析出 %d 条, want 2", len(items))
	}
	if items[0].ID != hex1 || !strings.HasPrefix(items[0].Magnet, "magnet:?xt=urn:btih:"+hex1) {
		t.Fatalf("首条结果 = %+v", items[0])
	}
	if items[0].Size != "1.2 GB" || items[0].Date != "2026-11-08" || items[0].Site != "测试站" {
		t.Fatalf("元数据 = %+v", items[0])
	}
	if !strings.Contains(items[0].Detail, hex1) {
		t.Fatalf("详情地址 = %q", items[0].Detail)
	}
}

func TestMagnetFromDetailAbsoluteXPath(t *testing.T) {
	hex40 := "abcdefabcdefabcdefabcdefabcdefabcdefabcd"
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, "<html><input id='m_link' value='magnet:?xt=urn:btih:"+hex40+"'></html>")
	}))
	defer server.Close()
	site := magnetSite{
		Request:    magnetSiteRequest{MainURL: server.URL},
		Expression: magnetSiteExpression{Magnet: "//input[@id='m_link']/@value"},
	}
	got := magnetFromDetail(context.Background(), site, server.URL+"/detail/1.html", "资源")
	if !strings.Contains(got, hex40) || !strings.Contains(got, "dn=") {
		t.Fatalf("详情补磁力 = %q", got)
	}
}

func TestMagnetSearchDeduplicatesAndHonorsSelection(t *testing.T) {
	hex40 := "3333333333333333333333333333333333333333"
	body := "<div class='search-item'><div class='item-title'><h3>" +
		"<a href='magnet:?xt=urn:btih:" + hex40 + "'>重复资源</a></h3></div></div>"
	original := magnetHTTP.Transport
	defer func() { magnetHTTP.Transport = original }()
	var mu sync.Mutex
	requests := 0
	magnetHTTP.Transport = magnetRoundTripFunc(func(_ *http.Request) (*http.Response, error) {
		mu.Lock()
		requests++
		mu.Unlock()
		return magnetResponse(body), nil
	})
	sites, err := loadMagnetSites()
	if err != nil {
		t.Fatal(err)
	}
	selected := []int{sites[0].ID, sites[1].ID}
	result, err := magnetSearch(context.Background(), "重复资源", 1, selected)
	if err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	got := requests
	mu.Unlock()
	if got != 2 {
		t.Fatalf("实际请求 %d 个站源, want 2", got)
	}
	if len(result.Items) != 1 {
		t.Fatalf("跨站去重后剩 %d 条, want 1", len(result.Items))
	}
	if !result.Items[0].Playable || result.Items[0].ID != hex40 {
		t.Fatalf("去重结果 = %+v", result.Items[0])
	}
	if result.Page != 1 || !result.HasMore || len(result.Sites) != 35 {
		t.Fatalf("分页 / 站源清单 = %+v", result)
	}
	if _, err := magnetSearch(context.Background(), "", 1, nil); err == nil {
		t.Fatal("空关键词应报错")
	}
}

func TestMagnetSearchSingleSiteFailureIsWarning(t *testing.T) {
	original := magnetHTTP.Transport
	defer func() { magnetHTTP.Transport = original }()
	magnetHTTP.Transport = magnetRoundTripFunc(func(_ *http.Request) (*http.Response, error) {
		return nil, io.EOF
	})
	sites, err := loadMagnetSites()
	if err != nil {
		t.Fatal(err)
	}
	result, err := magnetSearch(context.Background(), "关键词", 1, []int{sites[0].ID})
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Items) != 0 || result.Warning == "" {
		t.Fatalf("单站失败应给 warning，得到 %+v", result)
	}
}

func TestMagnetVideoExtensionAndPickFile(t *testing.T) {
	for _, name := range []string{"a.MP4", "b.mkv", "c.ts", "d.rmvb"} {
		if !magnetVideoExtension(name) {
			t.Errorf("%q 应识别为视频", name)
		}
	}
	for _, name := range []string{"a.txt", "b.nfo", "c"} {
		if magnetVideoExtension(name) {
			t.Errorf("%q 不应识别为视频", name)
		}
	}
	files := []magnetFileItem{
		{Index: 0, Name: "readme.txt", Size: 10},
		{Index: 1, Name: "sample.mp4", Size: 100, Video: true},
		{Index: 2, Name: "movie.mkv", Size: 900, Video: true},
	}
	if got, err := magnetPickFile(files, 1); err != nil || got != 1 {
		t.Fatalf("指定文件 = %d, %v", got, err)
	}
	if got, err := magnetPickFile(files, -1); err != nil || got != 2 {
		t.Fatalf("自动挑最大视频 = %d, %v", got, err)
	}
	if got, err := magnetPickFile([]magnetFileItem{{Index: 0, Name: "a.bin", Size: 5}}, -1); err != nil || got != 0 {
		t.Fatalf("无视频后缀时挑最大文件 = %d, %v", got, err)
	}
	if _, err := magnetPickFile(nil, -1); err == nil {
		t.Fatal("空文件列表应报错")
	}
}

func TestMagnetWithTrackers(t *testing.T) {
	link := "magnet:?xt=urn:btih:3333333333333333333333333333333333333333"
	got := magnetWithTrackers(link)
	for _, tracker := range magnetPublicTrackers {
		if !strings.Contains(got, "tr="+tracker) {
			t.Fatalf("缺少 tracker %s: %q", tracker, got)
		}
	}
	if got := magnetWithTrackers(link + "&tr=" + magnetPublicTrackers[0]); strings.Count(got, magnetPublicTrackers[0]) != 1 {
		t.Fatalf("已有 tracker 不应重复追加: %q", got)
	}
	if got := magnetWithTrackers("https://a.test/x"); got != "https://a.test/x" {
		t.Fatalf("非磁力链接应原样返回: %q", got)
	}
}

func TestMagnetActionsBypassSourceWhitelist(t *testing.T) {
	// 磁力不属于任何站源，两个构建变体都要能用；防止以后往白名单里加分支时误拦。
	for _, action := range []string{
		"magnetSites", "magnetSearch", "magnetBrowse", "magnetFiles", "magnetPlay",
		"magnetPeers", "magnetCancel", "magnetHotWords", "magnetAnalyzeSite",
		"magnetAddSite", "magnetUpdateSite", "magnetRemoveSite", "magnetResetSites",
	} {
		if err := nativeAuthorizeInput(nativeInput{Action: action}); err != nil {
			t.Errorf("%s 被站源白名单拦下: %v", action, err)
		}
	}
}

func TestMagnetServeRejectsUnknownTask(t *testing.T) {
	// 不启动真实 BT 客户端，只构造空的 files 表来验证 HTTP 语义。
	state := &magnetStreamEngineState{files: map[string]map[int]*torrent.File{}}
	recorder := httptest.NewRecorder()
	state.serve(recorder, httptest.NewRequest(http.MethodGet, "/magnet/deadbeef/0", nil))
	if recorder.Code != http.StatusServiceUnavailable {
		t.Fatalf("未知任务状态 = %d, want 503", recorder.Code)
	}
	bad := httptest.NewRecorder()
	state.serve(bad, httptest.NewRequest(http.MethodGet, "/magnet/only-one-part", nil))
	if bad.Code != http.StatusBadRequest {
		t.Fatalf("非法路径状态 = %d, want 400", bad.Code)
	}
}

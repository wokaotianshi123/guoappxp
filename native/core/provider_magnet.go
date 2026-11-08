package core

import (
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/antchfx/htmlquery"
	"golang.org/x/net/html"
)

// magnet_sites.json 来自 cisou.apk 的 assets/site-1.0.1.json，是它的站源规则表：
// 每个站给出搜索地址模板（[keyword] / [page]）、请求头，以及用 XPath 描述的结果字段。
// 直接嵌入二进制，Flutter FFI 与本地服务版都能用，不依赖运行时外部文件。
//
//go:embed magnet_sites.json
var magnetSitesJSON []byte

type magnetSiteRequest struct {
	Method    string            `json:"method"`
	MainURL   string            `json:"mainUrl"`
	SearchURL string            `json:"searchUrl"`
	Header    map[string]string `json:"header"`
}

type magnetSiteExpression struct {
	Group  string `json:"group"`
	Title  string `json:"title"`
	Date   string `json:"date"`
	Size   string `json:"size"`
	URL    string `json:"url"`
	Magnet string `json:"magnet"`
}

type magnetSite struct {
	ID         int                  `json:"id"`
	Name       string               `json:"name"`
	Info       string               `json:"info"`
	State      bool                 `json:"state"`
	Request    magnetSiteRequest    `json:"request"`
	Expression magnetSiteExpression `json:"expressionModel"`
}

type magnetSiteItem struct {
	ID    int    `json:"id"`
	Name  string `json:"name"`
	Info  string `json:"info"`
	State bool   `json:"state"`
}

// magnetResult 是归一化后的搜索结果。ID 用 infohash，方便跨站去重。
type magnetResult struct {
	ID       string `json:"id"`
	Title    string `json:"title"`
	Magnet   string `json:"magnet"`
	Size     string `json:"size"`
	Date     string `json:"date"`
	Site     string `json:"site"`
	SiteID   int    `json:"siteId"`
	Detail   string `json:"detail,omitempty"`
	Playable bool   `json:"playable"`
}

type magnetSearchResult struct {
	Items   []magnetResult   `json:"items"`
	Sites   []magnetSiteItem `json:"sites"`
	HasMore bool             `json:"hasMore"`
	Page    int              `json:"page"`
	Warning string           `json:"warning,omitempty"`
}

const (
	magnetMaxPage       = 10
	magnetSiteWorkers   = 6
	magnetDetailWorkers = 4
	magnetFetchTimeout  = 12 * time.Second
	magnetSearchBudget  = 40 * time.Second
)

var (
	magnetSitesOnce sync.Once
	magnetSitesData []magnetSite
	magnetSitesErr  error

	magnetHTTP = &http.Client{Timeout: magnetFetchTimeout}

	magnetXTHash   = regexp.MustCompile(`(?i)xt=urn:btih:([a-z0-9]+)`)
	magnetHex40    = regexp.MustCompile(`(?i)\b([0-9a-f]{40})\b`)
	magnetBase32   = regexp.MustCompile(`(?i)\b([a-z2-7]{32})\b`)
	magnetFullLink = regexp.MustCompile(`(?i)magnet:\?xt=urn:btih:[^"'\s<>\\]+`)
	magnetLinkVal  = regexp.MustCompile(`(?i)(?:id=["'](?:m_link|magnet|down-url|input-magnet)["'][^>]*value=["']|value=["'])([^"']*magnet:\?xt=[^"']+)`)
)

func loadMagnetSites() ([]magnetSite, error) {
	magnetSitesOnce.Do(func() {
		magnetSitesErr = json.Unmarshal(magnetSitesJSON, &magnetSitesData)
	})
	return magnetSitesData, magnetSitesErr
}

func magnetSiteList() (map[string]any, error) {
	sites, err := loadMagnetSites()
	if err != nil {
		return nil, err
	}
	items := make([]magnetSiteItem, 0, len(sites))
	for _, site := range sites {
		items = append(items, magnetSiteItem{
			ID: site.ID, Name: site.Name, Info: site.Info, State: site.State,
		})
	}
	return map[string]any{"items": items}, nil
}

// magnetFetch 带规则里的请求头抓 HTML。站点 header 里带的是 cisou 快照里的
// Cookie / Referer / UA，过期了也不影响其它站；编码交给 xbpqDecodeBody 处理 GBK。
func magnetFetch(ctx context.Context, rawURL string, header map[string]string) (string, error) {
	if rawURL == "" {
		return "", errors.New("搜索地址为空")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return "", err
	}
	for key, value := range header {
		if strings.TrimSpace(key) == "" || strings.TrimSpace(value) == "" {
			continue
		}
		// Host 由 net/http 通过 req.Host 设置，直接写 Header 不生效。
		if strings.EqualFold(key, "host") {
			continue
		}
		req.Header.Set(key, value)
	}
	if req.Header.Get("User-Agent") == "" {
		req.Header.Set("User-Agent", userAgent)
	}
	req.Header.Set("Accept-Language", "zh-CN,zh;q=0.9")
	response, err := magnetHTTP.Do(req)
	if err != nil {
		return "", err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return "", fmt.Errorf("HTTP %d", response.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, 4<<20))
	if err != nil {
		return "", err
	}
	return xbpqDecodeBody(string(body)), nil
}

func magnetSearchAddress(site magnetSite, query string, page int) string {
	address := site.Request.SearchURL
	address = strings.ReplaceAll(address, "[keyword]", url.QueryEscape(query))
	address = strings.ReplaceAll(address, "[page]", strconv.Itoa(page))
	return address
}

// magnetAbsoluteURL 把列表页里取到的相对链接补全成可抓的绝对地址。
func magnetAbsoluteURL(site magnetSite, href string) string {
	href = strings.TrimSpace(href)
	if href == "" || strings.HasPrefix(href, "magnet:") {
		return href
	}
	if strings.HasPrefix(href, "http://") || strings.HasPrefix(href, "https://") {
		return href
	}
	root := strings.TrimSpace(site.Request.MainURL)
	if root == "" {
		root = site.Request.SearchURL
	}
	base, err := url.Parse(root)
	if err != nil || base.Scheme == "" {
		return ""
	}
	if strings.HasPrefix(href, "//") {
		return base.Scheme + ":" + href
	}
	ref, err := url.Parse(href)
	if err != nil {
		return ""
	}
	return base.ResolveReference(ref).String()
}

// magnetQuery 解析站源规则里的 XPath。规则末尾的 /@href、/@value、/@title
// 单独取属性，避免依赖 XPath 引擎的属性节点表示；非法表达式直接忽略而不是让整个站点崩掉。
func magnetQuery(node *html.Node, expression string) (nodes []*html.Node, attribute string) {
	if node == nil || strings.TrimSpace(expression) == "" {
		return nil, ""
	}
	if index := strings.LastIndex(expression, "/@"); index >= 0 {
		attribute = expression[index+2:]
		expression = expression[:index]
	}
	if expression == "" {
		return nil, attribute
	}
	defer func() { _ = recover() }()
	nodes = htmlquery.Find(node, expression)
	return nodes, attribute
}

func magnetText(node *html.Node, expression string) string {
	nodes, attribute := magnetQuery(node, expression)
	for _, found := range nodes {
		if found == nil {
			continue
		}
		value := ""
		if attribute != "" {
			value = htmlquery.SelectAttr(found, attribute)
		} else {
			value = strings.TrimSpace(htmlquery.InnerText(found))
		}
		value = strings.TrimSpace(value)
		if value != "" {
			return value
		}
	}
	return ""
}

// magnetInfoHash 从磁力链接、/hash/<infohash>、/doc/<infohash> 或裸 40 位 hex
// 里提取 infohash。cisou 的很多站源把 infohash 直接放在详情链接路径里。
func magnetInfoHash(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return ""
	}
	if match := magnetXTHash.FindStringSubmatch(raw); len(match) > 1 {
		return strings.ToLower(match[1])
	}
	if match := magnetHex40.FindStringSubmatch(raw); len(match) > 1 {
		return strings.ToLower(match[1])
	}
	// 32 位 base32 infohash 只认独立词，避免把普通英文单词误判成种子。
	if strings.Contains(raw, "/hash/") || strings.Contains(raw, "/doc/") ||
		strings.Contains(raw, "/detail/") || strings.Contains(raw, "/bt/") {
		if match := magnetBase32.FindStringSubmatch(raw); len(match) > 1 {
			return strings.ToLower(match[1])
		}
	}
	return ""
}

func magnetCanonical(infoHash, title string) string {
	if infoHash == "" {
		return ""
	}
	link := "magnet:?xt=urn:btih:" + infoHash
	if title != "" {
		link += "&dn=" + url.QueryEscape(title)
	}
	return link
}

// magnetFromDetail 详情页兜底：站点常把磁力放在隐藏 input、下载按钮或页面正文里。
// 规则里的绝对 XPath（如 //input[@id='m_link']/@value）也在这里生效。
func magnetFromDetail(ctx context.Context, site magnetSite, address, title string) string {
	if address == "" {
		return ""
	}
	body, err := magnetFetch(ctx, address, site.Request.Header)
	if err != nil {
		return ""
	}
	if expression := site.Expression.Magnet; strings.HasPrefix(expression, "//") {
		if doc, err := htmlquery.Parse(strings.NewReader(body)); err == nil {
			if value := magnetText(doc, expression); magnetInfoHash(value) != "" {
				return magnetCanonical(magnetInfoHash(value), title)
			}
		}
	}
	if link := magnetFullLink.FindString(body); link != "" {
		if hash := magnetInfoHash(link); hash != "" {
			return magnetCanonical(hash, title)
		}
	}
	if match := magnetLinkVal.FindStringSubmatch(body); len(match) > 1 {
		if hash := magnetInfoHash(match[1]); hash != "" {
			return magnetCanonical(hash, title)
		}
	}
	if hash := magnetInfoHash(body); hash != "" {
		return magnetCanonical(hash, title)
	}
	return ""
}

func magnetParseList(site magnetSite, body string) []magnetResult {
	doc, err := htmlquery.Parse(strings.NewReader(body))
	if err != nil {
		return nil
	}
	// 绝对 XPath 的 group 用整份文档；相对 XPath 也从文档根开始找，语义一致。
	groups, _ := magnetQuery(doc, site.Expression.Group)
	if len(groups) == 0 {
		return nil
	}
	items := make([]magnetResult, 0, len(groups))
	for _, group := range groups {
		title := magnetText(group, site.Expression.Title)
		if title == "" {
			continue
		}
		href := ""
		// magnet 表达式是相对路径时，它本身往往就是详情链接（/hash/xxx、/doc/xxx）。
		if expression := site.Expression.Magnet; expression != "" && !strings.HasPrefix(expression, "//") {
			href = magnetText(group, expression)
		}
		if href == "" {
			href = magnetText(group, site.Expression.URL)
		}
		detail := magnetAbsoluteURL(site, href)
		hash := magnetInfoHash(href)
		items = append(items, magnetResult{
			ID:     hash,
			Title:  title,
			Magnet: magnetCanonical(hash, title),
			Size:   magnetText(group, site.Expression.Size),
			Date:   magnetText(group, site.Expression.Date),
			Site:   site.Name,
			SiteID: site.ID,
			Detail: detail,
		})
	}
	return items
}

// magnetSearch 并发跑选中的站源，按 infohash 去重；单个站失败只记账，不影响其它站。
func magnetSearch(ctx context.Context, query string, page int, selected []int) (magnetSearchResult, error) {
	query = strings.TrimSpace(query)
	if query == "" {
		return magnetSearchResult{}, errors.New("请输入搜索关键词")
	}
	if page < 1 {
		page = 1
	}
	if page > magnetMaxPage {
		page = magnetMaxPage
	}
	sites, err := loadMagnetSites()
	if err != nil {
		return magnetSearchResult{}, err
	}
	allowed := map[int]bool{}
	for _, id := range selected {
		allowed[id] = true
	}
	targets := make([]magnetSite, 0, len(sites))
	for _, site := range sites {
		if !site.State || site.Request.SearchURL == "" {
			continue
		}
		if len(allowed) > 0 && !allowed[site.ID] {
			continue
		}
		targets = append(targets, site)
	}
	result := magnetSearchResult{Items: []magnetResult{}, Page: page}
	result.Sites = make([]magnetSiteItem, 0, len(sites))
	for _, site := range sites {
		result.Sites = append(result.Sites, magnetSiteItem{
			ID: site.ID, Name: site.Name, Info: site.Info, State: site.State,
		})
	}
	if len(targets) == 0 {
		return result, nil
	}

	budget, cancel := context.WithTimeout(ctx, magnetSearchBudget)
	defer cancel()

	type siteOutcome struct {
		items []magnetResult
		err   error
	}
	outcomes := make([]siteOutcome, len(targets))
	var wait sync.WaitGroup
	limit := make(chan struct{}, magnetSiteWorkers)
	for i := range targets {
		wait.Add(1)
		go func(index int) {
			defer wait.Done()
			select {
			case limit <- struct{}{}:
			case <-budget.Done():
				outcomes[index] = siteOutcome{err: budget.Err()}
				return
			}
			defer func() { <-limit }()
			site := targets[index]
			body, err := magnetFetch(budget, magnetSearchAddress(site, query, page), site.Request.Header)
			if err != nil {
				outcomes[index] = siteOutcome{err: err}
				return
			}
			outcomes[index] = siteOutcome{items: magnetParseList(site, body)}
		}(i)
	}
	wait.Wait()

	// 列表里没直接给出 infohash 的结果，再抓一次详情页补磁力。
	var pending []struct {
		index  int
		site   magnetSite
		detail string
		title  string
	}
	var list []magnetResult
	failures := 0
	for i, outcome := range outcomes {
		if outcome.err != nil {
			failures++
			continue
		}
		for _, item := range outcome.items {
			if item.Magnet == "" && item.Detail != "" {
				pending = append(pending, struct {
					index  int
					site   magnetSite
					detail string
					title  string
				}{len(list), targets[i], item.Detail, item.Title})
			}
			list = append(list, item)
		}
	}
	if len(pending) > 0 {
		resolved := make([]string, len(list))
		var detailWait sync.WaitGroup
		detailLimit := make(chan struct{}, magnetDetailWorkers)
		for _, job := range pending {
			detailWait.Add(1)
			go func(j struct {
				index  int
				site   magnetSite
				detail string
				title  string
			}) {
				defer detailWait.Done()
				select {
				case detailLimit <- struct{}{}:
				case <-budget.Done():
					return
				}
				defer func() { <-detailLimit }()
				resolved[j.index] = magnetFromDetail(budget, j.site, j.detail, j.title)
			}(job)
		}
		detailWait.Wait()
		for index, link := range resolved {
			if link == "" || list[index].Magnet != "" {
				continue
			}
			list[index].Magnet = link
			list[index].ID = magnetInfoHash(link)
		}
	}

	seen := map[string]bool{}
	for _, item := range list {
		key := item.ID
		if key == "" {
			// 没解析出磁力也保留条目（用户可复制详情地址），但不参与去重。
			key = item.Site + "|" + item.Title
		}
		if seen[key] {
			continue
		}
		seen[key] = true
		item.Playable = strings.HasPrefix(item.Magnet, "magnet:")
		result.Items = append(result.Items, item)
	}
	result.HasMore = len(result.Items) > 0 && page < magnetMaxPage
	if failures > 0 && len(result.Items) == 0 {
		result.Warning = fmt.Sprintf("%d 个站源未能返回结果，可稍后重试或换一批站源", failures)
	}
	return result, nil
}

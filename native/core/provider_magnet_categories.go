package core

import (
	"context"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/antchfx/htmlquery"
	"golang.org/x/net/html"
)

// 「磁力播放」页的分类不能写死：每个磁力站首页的导航里有什么分类，就展示什么。
// 抓到的是「分类名 + 该分类的真实列表地址」，点分类时直接按这个地址拉列表，
// 而不是拿固定词去当搜索关键词。
type magnetCategory struct {
	SiteID   int    `json:"siteId"`
	SiteName string `json:"siteName"`
	Name     string `json:"name"`
	URL      string `json:"url"`
}

const (
	magnetCategoryMaxPerSite = 12
	magnetCategoryTTL        = 10 * time.Minute
	magnetCategoryBudget     = 10 * time.Second
	magnetCategoryWorkers    = 6
)

var magnetCategoryCache = struct {
	sync.RWMutex
	items map[int][]magnetCategory
	at    map[int]time.Time
}{
	items: map[int][]magnetCategory{},
	at:    map[int]time.Time{},
}

// 分类导航通常落在这些容器里；命中容器就只认容器内的链接，能过滤掉首页里
// 大量片名/资源链接。一个容器都没命中时退回全页，但要求 href 带分类特征。
var magnetCategoryNavXPath = []string{
	"//nav//a",
	"//header//a",
	"//*[contains(@class,'nav')]//a",
	"//*[contains(@class,'menu')]//a",
	"//*[contains(@class,'cate')]//a",
	"//*[contains(@class,'channel')]//a",
	"//*[contains(@class,'class')]//a",
	"//*[contains(@class,'sort')]//a",
	"//*[contains(@class,'type')]//a",
	"//*[contains(@id,'nav')]//a",
}

var (
	magnetCategoryNoise = regexp.MustCompile(`(?i)(首页|下载|登录|注册|搜索|更多|联系|关于|版权|备案|帮助|反馈|收藏|分享|评论|上一页|下一页|末页|尾页|详情|播放|站内|友情|广告|客服|会员|充值|客户端|扫码|关注|订阅|导航|标签|网站地图|播放器|发布|提交|返回|顶部|底部|magnet|http|www\.|\.com|\.cn)`)
	magnetCategoryHint  = regexp.MustCompile(`(?i)(class|cate|category|type|sort|channel|genre|tag|list|vod|video|movie|tv|area|year|/c/|/s/|/t/|-\d+\.html)`)
	magnetCategoryDigit = regexp.MustCompile(`[0-9]{4}`)
)

// magnetCategories 返回指定站源（空表示全部启用站）实际抓到的分类。
// 按站点缓存 10 分钟，界面上的「刷新分类」用 force=true 重新抓。
func magnetCategories(ctx context.Context, force bool, selected []int) (map[string]any, error) {
	sites, err := loadMagnetSites()
	if err != nil {
		return nil, err
	}
	allowed := map[int]bool{}
	for _, id := range selected {
		allowed[id] = true
	}
	var targets []magnetSite
	for _, site := range sites {
		if !site.State || strings.TrimSpace(site.Request.MainURL) == "" {
			continue
		}
		if len(allowed) > 0 && !allowed[site.ID] {
			continue
		}
		targets = append(targets, site)
	}
	if len(targets) == 0 {
		return map[string]any{"items": []magnetCategory{}}, nil
	}

	bySite := make(map[int][]magnetCategory, len(targets))
	var pending []magnetSite
	magnetCategoryCache.RLock()
	for _, site := range targets {
		cached, ok := magnetCategoryCache.items[site.ID]
		if ok && !force && time.Since(magnetCategoryCache.at[site.ID]) < magnetCategoryTTL {
			bySite[site.ID] = append([]magnetCategory(nil), cached...)
			continue
		}
		pending = append(pending, site)
	}
	magnetCategoryCache.RUnlock()

	if len(pending) > 0 {
		budget, cancel := context.WithTimeout(ctx, magnetCategoryBudget)
		defer cancel()
		outcomes := make([][]magnetCategory, len(pending))
		var wait sync.WaitGroup
		limit := make(chan struct{}, magnetCategoryWorkers)
		for i := range pending {
			wait.Add(1)
			go func(index int) {
				defer wait.Done()
				select {
				case limit <- struct{}{}:
				case <-budget.Done():
					return
				}
				defer func() { <-limit }()
				site := pending[index]
				body, err := magnetFetch(budget, site.Request.MainURL, site.Request.Header)
				if err != nil {
					return
				}
				outcomes[index] = magnetParseCategories(site, body)
			}(i)
		}
		wait.Wait()

		magnetCategoryCache.Lock()
		for i, site := range pending {
			items := outcomes[i]
			if items == nil {
				items = []magnetCategory{}
			}
			magnetCategoryCache.items[site.ID] = items
			magnetCategoryCache.at[site.ID] = time.Now()
			bySite[site.ID] = append([]magnetCategory(nil), items...)
		}
		magnetCategoryCache.Unlock()
	}

	items := make([]magnetCategory, 0, len(targets)*4)
	for _, site := range targets {
		items = append(items, bySite[site.ID]...)
	}
	return map[string]any{"items": items}, nil
}

// magnetParseCategories 从站点首页 HTML 里抽分类导航（纯函数，便于测试）。
func magnetParseCategories(site magnetSite, body string) []magnetCategory {
	doc, err := htmlquery.Parse(strings.NewReader(body))
	if err != nil {
		return nil
	}
	var anchors []*html.Node
	for _, expression := range magnetCategoryNavXPath {
		nodes, _ := magnetQuery(doc, expression)
		anchors = append(anchors, nodes...)
	}
	fromNav := len(anchors) > 0
	if !fromNav {
		anchors, _ = magnetQuery(doc, "//a")
	}

	seen := map[string]bool{}
	items := make([]magnetCategory, 0, magnetCategoryMaxPerSite)
	for _, anchor := range anchors {
		name := strings.TrimSpace(htmlquery.InnerText(anchor))
		href := strings.TrimSpace(htmlquery.SelectAttr(anchor, "href"))
		if !magnetCategoryUsable(name, href, fromNav) {
			continue
		}
		address := magnetAbsoluteURL(site, href)
		if !strings.HasPrefix(address, "http://") && !strings.HasPrefix(address, "https://") {
			continue
		}
		if seen[name] {
			continue
		}
		seen[name] = true
		items = append(items, magnetCategory{
			SiteID: site.ID, SiteName: site.Name, Name: name, URL: address,
		})
		if len(items) >= magnetCategoryMaxPerSite {
			break
		}
	}
	return items
}

func magnetCategoryUsable(name, href string, fromNav bool) bool {
	length := utf8.RuneCountInString(name)
	if length < 1 || length > 8 || magnetCategoryNoise.MatchString(name) {
		return false
	}
	// 带四位年份/分辨率的短词更像资源标题，不是分类。
	if magnetCategoryDigit.MatchString(name) {
		return false
	}
	lower := strings.ToLower(strings.TrimSpace(href))
	if lower == "" || lower == "/" || lower == "#" ||
		strings.HasPrefix(lower, "javascript:") || strings.HasPrefix(lower, "magnet:") ||
		strings.HasPrefix(lower, "mailto:") || strings.HasPrefix(lower, "tel:") ||
		strings.HasPrefix(lower, "index.html") {
		return false
	}
	if !fromNav && !magnetCategoryHint.MatchString(href) {
		return false
	}
	return true
}

// magnetCategoryAddress 把分类链接翻到指定页：带 [page] 占位符时直接替换，
// 否则在常见页码参数上改值，实在没有就补一个 page 参数。
func magnetCategoryAddress(raw string, page int) string {
	address := strings.TrimSpace(raw)
	if address == "" {
		return address
	}
	if strings.Contains(address, "[page]") {
		return strings.ReplaceAll(address, "[page]", strconv.Itoa(page))
	}
	if page <= 1 {
		return address
	}
	parsed, err := url.Parse(address)
	if err != nil {
		return address
	}
	query := parsed.Query()
	for _, key := range []string{"page", "p", "pageIndex", "pageNo", "pageNum"} {
		if query.Get(key) != "" {
			query.Set(key, strconv.Itoa(page))
			parsed.RawQuery = query.Encode()
			return parsed.String()
		}
	}
	query.Set("page", strconv.Itoa(page))
	parsed.RawQuery = query.Encode()
	return parsed.String()
}

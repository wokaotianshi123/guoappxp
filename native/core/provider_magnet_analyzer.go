package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"sort"
	"strings"

	"github.com/antchfx/htmlquery"
	"golang.org/x/net/html"
)

// magnetAnalyzeSite 对应「磁力源管理 → 自动识别」：输入一个网址，抓首页 HTML
// 反推搜索地址模板与列表 XPath，回填到编辑弹窗里。只返回规则文本，不写盘，
// 与网页源的 analyzeCustomSourceSite 保持同一种「先预览再保存」的交互。
func magnetAnalyzeSite(ctx context.Context, raw string) (map[string]any, error) {
	base, err := normalizeMagnetSiteAddress(raw)
	if err != nil {
		return nil, err
	}
	body, err := magnetFetch(ctx, base, map[string]string{"User-Agent": userAgent})
	if err != nil {
		return nil, fmt.Errorf("站点无法访问：%v", err)
	}
	doc, err := htmlquery.Parse(strings.NewReader(body))
	if err != nil {
		return nil, errors.New("站点返回的 HTML 无法解析")
	}
	notes := []string{}
	name := ""
	if titleNode := htmlquery.FindOne(doc, "//title"); titleNode != nil {
		name = strings.TrimSpace(htmlquery.InnerText(titleNode))
	}
	name = cleanMagnetSiteName(name)
	if name == "" {
		name = mustURL(base).Host
	}

	searchURL, formNotes := guessMagnetSearchAddress(doc, base)
	notes = append(notes, formNotes...)
	group, titleExpr, urlExpr, listNotes := guessMagnetListExpression(doc)
	notes = append(notes, listNotes...)
	magnetExpr, magnetNotes := guessMagnetExpression(doc, body)
	notes = append(notes, magnetNotes...)
	sizeExpr := guessMagnetFieldExpression(doc, "size", "大小", "容量")
	dateExpr := guessMagnetFieldExpression(doc, "date", "time", "日期", "时间")

	origin := magnetSiteOrigin(base)
	if origin == "" {
		origin = strings.TrimRight(base, "/")
	}
	rule := map[string]any{
		"name":    name,
		"info":    "自动识别的磁力搜索源",
		"state":   true,
		"mainUrl": origin,
		"searchUrl": searchURL,
		"header": map[string]string{
			"Referer":    origin + "/",
			"User-Agent": userAgent,
		},
		"expressionModel": map[string]string{
			"group":  group,
			"title":  titleExpr,
			"url":    urlExpr,
			"magnet": magnetExpr,
			"size":   sizeExpr,
			"date":   dateExpr,
		},
	}
	encoded, err := json.MarshalIndent(rule, "", "  ")
	if err != nil {
		return nil, err
	}

	// 拿生成的规则在首页上试截一次，能截出条目说明锚点大概率可用。
	trial := magnetSite{
		Name: name,
		Request: magnetSiteRequest{
			Method: "GET", MainURL: origin, SearchURL: searchURL,
		},
		Expression: magnetSiteExpression{
			Group: group, Title: titleExpr, URL: urlExpr,
			Magnet: magnetExpr, Size: sizeExpr, Date: dateExpr,
		},
	}
	parsed := magnetParseList(trial, body)
	if len(parsed) > 0 {
		notes = append(notes, fmt.Sprintf("已用首页试解析出 %d 条条目，锚点可用", len(parsed)))
	} else {
		notes = append(notes, "首页未试截到条目：该站列表通常在搜索结果页，请在搜索一次后按需微调 group/title 锚点")
	}
	return map[string]any{
		"rule":  string(encoded),
		"name":  name,
		"base":  origin,
		"notes": notes,
	}, nil
}

func normalizeMagnetSiteAddress(raw string) (string, error) {
	address := strings.TrimSpace(raw)
	if address == "" {
		return "", errors.New("请先填写磁力源网址")
	}
	if !strings.Contains(address, "://") {
		address = "https://" + address
	}
	parsed, err := url.Parse(address)
	if err != nil || parsed.Scheme == "" || parsed.Host == "" {
		return "", errors.New("网址不是合法的 http(s) 地址")
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return "", errors.New("只支持 http / https 网址")
	}
	return strings.TrimRight(address, "/"), nil
}

func mustURL(raw string) *url.URL {
	parsed, _ := url.Parse(raw)
	if parsed == nil {
		parsed = &url.URL{}
	}
	return parsed
}

func cleanMagnetSiteName(title string) string {
	// 站点 <title> 常带「- 最新电影 - XXX磁力搜索」这类尾巴，取第一段即可。
	for _, separator := range []string{" - ", " _ ", "｜", "|", "，", " – "} {
		if index := strings.Index(title, separator); index > 1 {
			title = title[:index]
		}
	}
	return strings.TrimSpace(title)
}

// guessMagnetSearchAddress 优先用站内 <form> 的 action + 文本输入框 name 拼搜索模板；
// 找不到表单时给一个常见的 MacCMS/BT 站默认值，并在 notes 里说明需要人工核对。
func guessMagnetSearchAddress(doc *html.Node, base string) (string, []string) {
	keywordNames := []string{"keyword", "kw", "wd", "q", "search", "key", "word", "s", "k"}
	pageNames := []string{"page", "p", "pg", "pageno", "p"}
	for _, form := range htmlquery.Find(doc, "//form") {
		inputs := htmlquery.Find(form, ".//input[@name]")
		chosen := ""
		for _, candidate := range keywordNames {
			for _, input := range inputs {
				kind := strings.ToLower(htmlquery.SelectAttr(input, "type"))
				if kind == "hidden" || kind == "submit" {
					continue
				}
				if strings.EqualFold(htmlquery.SelectAttr(input, "name"), candidate) {
					chosen = htmlquery.SelectAttr(input, "name")
					break
				}
			}
			if chosen != "" {
				break
			}
		}
		if chosen == "" {
			for _, input := range inputs {
				kind := strings.ToLower(htmlquery.SelectAttr(input, "type"))
				name := htmlquery.SelectAttr(input, "name")
				if name != "" && kind != "hidden" && kind != "submit" {
					chosen = name
					break
				}
			}
		}
		if chosen == "" {
			continue
		}
		action := strings.TrimSpace(htmlquery.SelectAttr(form, "action"))
		address := action
		if address == "" {
			address = base
		} else if parsed, err := url.Parse(base); err == nil {
			if ref, err := url.Parse(action); err == nil {
				address = parsed.ResolveReference(ref).String()
			}
		}
		if strings.Contains(address, "[keyword]") || strings.Contains(address, "{keyword}") {
			address = strings.ReplaceAll(address, "{keyword}", "[keyword]")
		} else {
			separator := "?"
			if strings.Contains(address, "?") {
				separator = "&"
			}
			address += separator + chosen + "=[keyword]"
		}
		pageKey := pageNames[0]
		for _, input := range inputs {
			for _, candidate := range pageNames {
				if strings.EqualFold(htmlquery.SelectAttr(input, "name"), candidate) {
					pageKey = htmlquery.SelectAttr(input, "name")
				}
			}
		}
		if strings.Contains(address, "[page]") || strings.Contains(address, "{page}") {
			address = strings.ReplaceAll(address, "{page}", "[page]")
		} else {
			separator := "&"
			if !strings.Contains(address, "?") {
				separator = "?"
			}
			address += separator + pageKey + "=[page]"
		}
		return address, []string{
			fmt.Sprintf("已从搜索表单识别出关键词参数 %s，搜索地址 %s", chosen, address),
		}
	}
	// 没有表单：给一个通用猜测，用户可在规则框里直接改。
	fallback := strings.TrimRight(base, "/") + "/search?keyword=[keyword]&page=[page]"
	return fallback, []string{
		"首页没找到搜索表单，已填入通用搜索地址；请按站点实际搜索 URL 修改 searchUrl",
	}
}

// guessMagnetListExpression 统计首页里重复出现的 class，挑最像「结果条目」的容器。
// 与 provider_site_analyzer.go 的 guessListRule 思路一致，但输出 XPath 而非截取串。
func guessMagnetListExpression(doc *html.Node) (string, string, string, []string) {
	type candidate struct {
		token string
		tag   string
		count int
		score int
	}
	counts := map[string]*candidate{}
	for _, node := range htmlquery.Find(doc, "//*[@class]") {
		if node.Data == "html" || node.Data == "body" {
			continue
		}
		class := strings.TrimSpace(htmlquery.SelectAttr(node, "class"))
		if class == "" {
			continue
		}
		text := strings.TrimSpace(htmlquery.InnerText(node))
		length := len([]rune(text))
		links := len(htmlquery.Find(node, ".//a"))
		if links == 0 || length < 8 || length > 300 {
			continue
		}
		for _, token := range strings.Fields(class) {
			token = strings.TrimSpace(token)
			if len(token) < 3 || strings.Contains(token, ":") {
				continue
			}
			entry := counts[token]
			if entry == nil {
				entry = &candidate{token: token, tag: node.Data}
				counts[token] = entry
			}
			entry.count++
			entry.score += 1 + links
			if length > 12 && length < 120 {
				entry.score++
			}
		}
	}
	list := make([]*candidate, 0, len(counts))
	for _, entry := range counts {
		if entry.count >= 2 {
			list = append(list, entry)
		}
	}
	sort.Slice(list, func(i, j int) bool {
		if list[i].count != list[j].count {
			return list[i].count > list[j].count
		}
		return list[i].score > list[j].score
	})
	if len(list) == 0 {
		return "//li", ".//a[1]", ".//a[1]/@href",
			[]string{"首页没找到重复的结果容器，先用 //li 兜底，请在规则里改 group"}
	}
	best := list[0]
	tag := best.tag
	if tag == "" || tag == "html" {
		tag = "div"
	}
	group := fmt.Sprintf("//%s[contains(@class,'%s')]", tag, best.token)
	notes := []string{
		fmt.Sprintf("列表容器取重复 %d 次的 class「%s」，锚点 %s", best.count, best.token, group),
	}
	return group, ".//a[1]", ".//a[1]/@href", notes
}

func guessMagnetExpression(doc *html.Node, body string) (string, []string) {
	if nodes := htmlquery.Find(doc, "//a[starts-with(@href,'magnet:')]"); len(nodes) > 0 {
		return ".//a[starts-with(@href,'magnet:')]/@href",
			[]string{"列表里直接带 magnet: 链接，磁力争点优先取它"}
	}
	if nodes := htmlquery.Find(doc, "//input[contains(@id,'magnet')]"); len(nodes) > 0 {
		return "//input[contains(@id,'magnet')]/@value",
			[]string{"检测到隐藏磁力输入框，改用详情页的 input value"}
	}
	if strings.Contains(body, "magnet:?xt=urn:btih:") {
		return "//input[contains(@id,'m_link')]/@value",
			[]string{"页面含 magnet: 链接，规则按详情页取流兜底"}
	}
	// 不少 BT 站把 infohash 放在 /hash/ /detail/ 详情链接里，magnetInfoHash 能直接从
	// 链接文本提取，无需再抓详情页。
	return ".//a[1]/@href",
		[]string{"磁力链接取详情链接里的 infohash（/hash/、/detail/ 形态），必要时改 magnet 锚点"}
}

func guessMagnetFieldExpression(doc *html.Node, keywords ...string) string {
	for _, node := range htmlquery.Find(doc, "//*[@class]") {
		class := strings.ToLower(htmlquery.SelectAttr(node, "class"))
		for _, keyword := range keywords {
			if strings.Contains(class, keyword) {
				return fmt.Sprintf(".//*[contains(@class,'%s')]", keyword)
			}
		}
	}
	return ""
}

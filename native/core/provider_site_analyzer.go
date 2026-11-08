package core

// 「新增自定义源 › 自动识别」的站点分析器。
//
// 算法移植自用户提供的「一键写XBPQ源.py」（凯少爷）：抓首页 → 反推分类url →
// 抓分类页反推列表五字段 → 探测搜索 → 抓详情页反推播放字段。原脚本是给
// TVBox / OK影视 的 XBPQ.jar 写规则的，带了一整套 jar 专属字段与安卓 UI/落盘外壳，
// 这里只移植「站点探测」部分，并在输出前做一次「引擎语义适配」：
//
//   - 只写 guoappxp 的 provider_xbpq.go 真正读取的字段（见 siteRuleKeyOrder）；
//     站名/编码/搜索模式/搜索后缀/链接前缀/嗅探词/图片代理/首页 等 jar 字段一律不写。
//   - 「播放列表」在本引擎里是 strings.Split 的**分集分隔符**（provider_xbpq.go:1902），
//     不是 XBPQ jar 的截取串；照抄 ">&&</a>" 会把整段塌成 1 集，必须换成 <li / <a / </a>。
//   - JSON 搜索接口改成 j: 路径（搜索数组=j:list、搜索链接=/voddetail/+j:id+.html），
//     引擎不认「搜索模式」「搜索后缀」。
//   - 认不准的字段宁可不写，交给 parseXBPQRule → xbpqApplyTemplate 按 分类url 形态兜底，
//     避免一条写错的「数组」把引擎自带的模板备选链盖掉。
//   - 生成的列表/播放字段都会拿刚抓到的真实 HTML 用 xbpqList / xbpqCutOnce 试截，
//     截不出条目就整组丢弃，并把实测条数写进诊断说明。

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"regexp"
	"sort"
	"strings"
	"time"
)

const (
	siteAnalyzerMobileUA = "Mozilla/5.0 (Linux; Android 14; Pixel 8 Build/UQ1A.240205.002) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/124.0.0.0 Mobile Safari/537.36"
	siteAnalyzerPCUA     = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
	// 单个探测请求最多等这么久；fetchProviderText 自己的重试/退避也受这个 ctx 约束。
	siteAnalyzerRequestTimeout = 4 * time.Second
	// 一次自动识别的总预算，防止探测候选路径时把 RPC 拖死。
	siteAnalyzerBudget = 45 * time.Second
	// 最多发这么多请求（首页 4 + 分类/兜底 10 + 搜索 7 + 详情 1 + 若干余量）。
	siteAnalyzerMaxRequests = 26
)

// siteAnalysis 是 analyzeCustomSourceSite RPC 的返回体。
// mode=规则 时 rule 是完整规则 JSON；mode=网址 时 rule 为空，表示这次没能可靠
// 识别出站点结构，保留用户填的网址走现有的 MacCMS 自动适配（不产生坏规则）。
type siteAnalysis struct {
	Rule  string   `json:"rule"`
	Name  string   `json:"name"`
	Base  string   `json:"base"`
	Kind  string   `json:"kind"`
	Mode  string   `json:"mode"`
	Notes []string `json:"notes"`
}

type siteCategory struct {
	ID   string
	Name string
}

type siteAnalyzer struct {
	d        *Downloader
	ctx      context.Context
	site     string
	origin   string
	deadline time.Time
	fetched  int
	notes    []string

	homeHTML     string
	cats         []siteCategory
	catURL       string
	catHTML      string
	detailURL    string
	detailHTML   string
	detailPrefix string
	detailSuffix string
	listRule     map[string]string
	searchRule   map[string]string
	playRule     map[string]string
	infoRule     map[string]string
}

var siteShieldMarks = []string{
	"just a moment", "attention required", "cf-chl-widget", "cf-turnstile",
	"window._cf_chl_opt", "滑动验证", "slidebox", "人机身份验证",
	"安全验证", "正在验证", "请稍候",
}

var (
	siteCharsetGBK     = regexp.MustCompile(`(?i)charset=["']?(gb2312|gbk|gb18030)`)
	siteSafeNameStrip  = regexp.MustCompile(`[^0-9A-Za-z\x{4e00}-\x{9fa5}]+`)
	siteDetailHref     = regexp.MustCompile(`(?i)href="([^"]*(?:voddetail|/detail/|/vod/|/movie/|/post/|/v/)[^"]*)"`)
	siteAnchorHref     = regexp.MustCompile(`(?i)<a[^>]+href="([^"]+)"[^>]*>\s*([^<]{1,20})\s*</a>`)
	siteAnyHref        = regexp.MustCompile(`(?i)href="([^"]+)"`)
	siteSPAMarks       = regexp.MustCompile(`(?i)src="[^"]*/assets/index-[^"]*\.js"|id="app"|__NUXT__|__vite|src="[^"]*app(\.[0-9a-f]+)?\.js"`)
	siteH1Title        = regexp.MustCompile(`(?i)<h1[^>]*>\s*([^<]{2,60})\s*</h1>`)
	siteDetailIntroCls = regexp.MustCompile(`(?i)class="([^"]*(?:detail-content|video-info|vod-content|intro|desc|summary|剧情)[^"]*)"`)
)

// siteRuleKeyOrder 既是输出顺序，也是「引擎支持的字段白名单」。
// 排序按规则书写习惯：站点 → 分类 → 列表 → 搜索 → 详情 → 播放。
var siteRuleKeyOrder = []string{
	"主页url", "分类url", "分类",
	"数组", "二次截取", "标题", "链接", "图片", "副标题",
	"搜索url", "搜索数组", "搜索标题", "搜索链接", "搜索图片",
	"影片名称", "封面", "简介", "详情url",
	"播放数组", "线路数组", "线路标题", "播放列表", "播放标题", "播放链接", "跳转播放链接",
	"请求头",
}

// 站点专属实测预设（原脚本 XBQ_KNOWN_SITES 的引擎语义版）。
// 命中裸域名时直接采用，跳过猜测；jar 专属字段已去掉。
var siteKnownRules = map[string]map[string]string{
	"dmdy3.com": {
		"分类url": "https://www.dmdy3.com/vodshow/{cateId}-{area}-{by}-{class}-{lang}-{letter}---{catePg}---{year}.html",
		"分类":    "电影$20#电视剧$21#综艺$22#动漫$23",
		"搜索url": "https://www.dmdy3.com/index.php/ajax/suggest?mid=1&wd={wd}",
		"搜索数组":  "j:list",
		"搜索标题":  "j:name",
		"搜索图片":  "j:pic",
		"搜索链接":  "/voddetail/+j:id+.html",
		"数组":    `<a &&</a>[包含:module-poster-item module-item]`,
		"标题":    `alt="&&"`,
		"图片":    `data-original="&&"`,
		"链接":    `href="&&"`,
		"副标题":   `class="module-item-note">&&</div>`,
		"播放数组":  `class="module-play-list-content&&</div>`,
		"线路数组":  `class="module-play-list-content&&</div>`,
		"播放列表":  `</a>`,
		"播放标题":  `>&&</a>`,
		"播放链接":  `href="&&"`,
		"请求头":   siteAnalyzerMobileUA,
	},
}

func (a *siteAnalyzer) note(format string, args ...any) {
	a.notes = append(a.notes, fmt.Sprintf(format, args...))
}

// fetch 抓一页并做编码归一。失败返回空串，不往上抛错——自动识别是「尽力而为」，
// 任何一次探测失败都不该让整个新增源流程报错。
func (a *siteAnalyzer) fetch(address, agent string) string {
	if address == "" || a.fetched >= siteAnalyzerMaxRequests {
		return ""
	}
	remaining := time.Until(a.deadline)
	if remaining <= 0 {
		return ""
	}
	timeout := siteAnalyzerRequestTimeout
	if remaining < timeout {
		timeout = remaining
	}
	a.fetched++
	ctx, cancel := context.WithTimeout(a.ctx, timeout)
	defer cancel()
	if agent != "" {
		ctx = context.WithValue(ctx, providerTextUserAgentKey{}, agent)
	}
	text, err := a.d.fetchProviderText(ctx, address, a.site)
	if err != nil || text == "" {
		return ""
	}
	// fetchProviderText 不做 GBK 转码，XBPQ 引擎里由 xbpqDecodeBody 负责；
	// 分析阶段也必须转成 UTF-8，否则中文分类名/片名全是乱码。
	return xbpqDecodeBody(text)
}

// fetchHome 手机 UA → 电脑 UA → http 兜底（对齐原脚本 _xbq_fetch_retry）。
func (a *siteAnalyzer) fetchHome() string {
	parsed, err := url.Parse(a.site)
	if err != nil {
		return ""
	}
	targets := []string{a.site}
	if parsed.Scheme == "https" {
		targets = append(targets, "http://"+parsed.Host+parsed.Path)
	}
	for _, agent := range []string{siteAnalyzerMobileUA, siteAnalyzerPCUA} {
		for _, target := range targets {
			address := strings.TrimRight(target, "/")
			if parsed.Path == "" {
				address += "/"
			}
			if body := a.fetch(address, agent); len(body) > 300 {
				return body
			}
		}
	}
	return ""
}

func siteIsShield(body string) bool {
	if body == "" {
		return false
	}
	head := strings.ToLower(body)
	if len(head) > 3000 {
		head = head[:3000]
	}
	for _, mark := range siteShieldMarks {
		if strings.Contains(head, mark) {
			return true
		}
	}
	return false
}

func normalizeSiteAnalyzerAddress(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", errors.New("请先填写源网址")
	}
	if !strings.Contains(raw, "://") {
		raw = "https://" + raw
	}
	parsed, err := url.Parse(raw)
	if err != nil || parsed.Host == "" {
		return "", errors.New("源网址不是合法的 http/https 地址")
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return "", errors.New("源网址只支持 http/https")
	}
	parsed.Path = strings.TrimRight(parsed.Path, "/")
	parsed.RawQuery = ""
	parsed.Fragment = ""
	return parsed.String(), nil
}

func siteSafeName(site string) string {
	parsed, err := url.Parse(site)
	host := site
	if err == nil && parsed.Host != "" {
		host = parsed.Host
	}
	host = strings.TrimPrefix(strings.ToLower(host), "www.")
	if index := strings.LastIndex(host, ":"); index > 0 {
		host = host[:index]
	}
	name := siteSafeNameStrip.ReplaceAllString(host, "")
	if name == "" {
		return "XBPQ源"
	}
	return name
}

// siteFillCategoryURL 把模板里的占位符填成可请求的真实地址（筛选位一律留空）。
func siteFillCategoryURL(template, id, page string) string {
	replacer := strings.NewReplacer(
		"{cateId}", id,
		"{catePg}", page,
		"{area}", "",
		"{by}", "",
		"{class}", "",
		"{lang}", "",
		"{letter}", "",
		"{year}", "",
	)
	return replacer.Replace(template)
}

func siteFirstDetailURL(site, body string) string {
	for _, match := range siteDetailHref.FindAllStringSubmatch(body, 24) {
		href := strings.TrimSpace(match[1])
		lower := strings.ToLower(href)
		if href == "" || strings.Contains(lower, "play") || strings.Contains(lower, "search") {
			continue
		}
		if strings.HasPrefix(href, "http") {
			return href
		}
		if strings.HasPrefix(href, "//") {
			return "https:" + href
		}
		return site + "/" + strings.TrimLeft(href, "/")
	}
	return ""
}

func (a *siteAnalyzer) fetchCategoryPage() (string, string) {
	id := "1"
	if len(a.cats) > 0 && a.cats[0].ID != "" {
		id = a.cats[0].ID
	}
	first := siteFillCategoryURL(a.catURL, id, "1")
	candidates := []string{first}
	// 页码拼接形态不被站点接受时，退回「纯分类ID页」与 /vodshow/ 横线链首页。
	noPage := regexp.MustCompile(`[-_]+1\.html$`).ReplaceAllString(first, ".html")
	if noPage != first {
		candidates = append(candidates, noPage)
	}
	if strings.Contains(first, "/vodshow/") {
		candidates = append(candidates, a.site+"/vodshow/"+id+"-----------.html")
	}
	seen := map[string]bool{}
	for _, address := range candidates {
		if seen[address] {
			continue
		}
		seen[address] = true
		body := a.fetch(address, siteAnalyzerMobileUA)
		if len(body) < 200 {
			continue
		}
		return body, siteFirstDetailURL(a.site, body)
	}
	return "", ""
}

// siteRuleJSON 按固定顺序输出缩进 JSON，方便用户直接在表单里阅读/微调。
func siteRuleJSON(fields map[string]string) string {
	parts := make([]string, 0, len(fields))
	appendField := func(key string) {
		value := strings.TrimSpace(fields[key])
		if value == "" {
			return
		}
		encodedKey, _ := json.Marshal(key)
		encodedValue, _ := json.Marshal(value)
		parts = append(parts, "  "+string(encodedKey)+": "+string(encodedValue))
	}
	for _, key := range siteRuleKeyOrder {
		appendField(key)
	}
	// 白名单之外的字段不写进规则（站点预设里若混入了 jar 字段会被丢掉）。
	return "{\n" + strings.Join(parts, ",\n") + "\n}"
}

// siteValidateListFields 用真实分类页 HTML 试截：数组切出的段里必须至少有一条
// 能同时截出标题与链接，否则整组列表字段判为不可靠（交给引擎模板兜底）。
func siteValidateListFields(body string, fields map[string]string) int {
	array := fields["数组"]
	if array == "" || body == "" {
		return 0
	}
	segments := xbpqList(body, array)
	if len(segments) < 2 {
		return len(segments)
	}
	matched := 0
	for _, segment := range segments[:min(len(segments), 8)] {
		title := xbpqCutOnce(segment, fields["标题"])
		link := xbpqCutOnce(segment, fields["链接"])
		if strings.TrimSpace(title) != "" && strings.TrimSpace(link) != "" {
			matched++
		}
	}
	return matched
}

// analyzeCustomSourceSite 是「自动识别」的 Go 侧入口。
func (d *Downloader) analyzeCustomSourceSite(ctx context.Context, raw string) (siteAnalysis, error) {
	site, err := normalizeSiteAnalyzerAddress(raw)
	if err != nil {
		return siteAnalysis{}, err
	}
	parsed, _ := url.Parse(site)
	a := &siteAnalyzer{
		d:          d,
		ctx:        ctx,
		site:       site,
		origin:     parsed.Scheme + "://" + parsed.Host,
		deadline:   time.Now().Add(siteAnalyzerBudget),
		listRule:   map[string]string{},
		searchRule: map[string]string{},
		playRule:   map[string]string{},
		infoRule:   map[string]string{},
	}
	result := siteAnalysis{
		Name:  siteSafeName(site),
		Base:  site,
		Kind:  "web",
		Mode:  "网址",
		Notes: a.notes,
	}
	finish := func() (siteAnalysis, error) {
		result.Notes = a.notes
		return result, nil
	}

	a.homeHTML = a.fetchHome()
	if a.homeHTML == "" {
		a.note("首页抓取失败（已试手机/电脑 UA 与 http/https），保留为普通网页源，可手动粘贴规则")
		return finish()
	}
	if siteIsShield(a.homeHTML) {
		a.note("首页疑似盾页 / 人机验证页，纯采集规则无法识别，保留为普通网页源")
		return finish()
	}
	if siteCharsetGBK.MatchString(a.homeHTML[:min(len(a.homeHTML), 4096)]) {
		a.note("检测到 GBK/GB2312 编码，引擎会自动转码，规则无需写「编码」字段")
	}

	a.catURL, a.cats = a.detectCategoryTemplate(a.homeHTML)
	if a.catURL == "" {
		if siteSPAMarks.MatchString(a.homeHTML) {
			a.note("该站是前端渲染（SPA）站：分类由 JS / 签名 API 加载，静态规则写不了，保留为普通网页源")
		} else {
			a.note("未识别到分类链接（首页 %d 字节 / %d 个链接），保留为普通网页源，不生成坏规则",
				len(a.homeHTML), len(siteAnyHref.FindAllString(a.homeHTML, -1)))
		}
		return finish()
	}

	a.catHTML, a.detailURL = a.fetchCategoryPage()
	if a.catHTML != "" {
		a.listRule = a.guessListRule(a.catHTML)
	}
	a.searchRule = a.guessSearchRule()
	if a.detailURL != "" {
		a.detailHTML = a.fetch(a.detailURL, siteAnalyzerMobileUA)
		if len(a.detailHTML) > 120 {
			a.infoRule = a.guessDetailRule(a.detailHTML)
			a.playRule = a.guessPlayRule(a.detailHTML)
		}
	}

	fields := a.assembleRule()
	// 命中站点专属预设时直接替换整份规则，但仍保留本次抓取的诊断说明。
	if known := siteKnownRules[strings.TrimPrefix(strings.ToLower(parsed.Host), "www.")]; known != nil {
		for key := range fields {
			delete(fields, key)
		}
		for key, value := range known {
			fields[key] = value
		}
		a.note("命中站点专属实测规则，已直接套用")
	}
	ruleText := siteRuleJSON(fields)
	if _, ok := parseXBPQRule(ruleText); !ok {
		a.note("生成的规则未通过引擎解析校验，保留为普通网页源")
		return finish()
	}
	result.Rule = ruleText
	result.Mode = "规则"
	result.Kind = "web"
	a.note("规则已通过引擎解析校验，保存后会自动套用对应模板家族补齐未识别字段")
	return finish()
}

func (a *siteAnalyzer) assembleRule() map[string]string {
	fields := map[string]string{
		"主页url": a.site,
		"分类url": a.catURL,
	}
	if len(a.cats) > 0 {
		labels := make([]string, 0, len(a.cats))
		for _, category := range a.cats {
			if category.ID != "" && category.Name != "" {
				labels = append(labels, category.Name+"$"+category.ID)
			}
		}
		if len(labels) > 0 {
			fields["分类"] = strings.Join(labels, "#")
		}
	}

	// 列表字段：只有实测能截出条目才写进规则，避免盖掉引擎模板的备选链。
	if len(a.listRule) > 0 {
		matched := siteValidateListFields(a.catHTML, a.listRule)
		if matched >= 1 {
			for key, value := range a.listRule {
				fields[key] = value
			}
			a.note("列表字段已反推并用分类页实测（抽样截出 %d 条）", matched)
		} else {
			a.note("列表字段实测截不出条目，已省略，交由引擎模板按分类url 形态兜底")
		}
	} else {
		a.note("列表字段未自动识别，交由引擎模板按分类url 形态兜底")
	}
	for key, value := range a.searchRule {
		fields[key] = value
	}
	for key, value := range a.infoRule {
		fields[key] = value
	}
	for key, value := range a.playRule {
		fields[key] = value
	}
	return fields
}

// guessDetailRule 只写能在详情页真实截到值的字段（模板没有的详情字段才补）。
func (a *siteAnalyzer) guessDetailRule(body string) map[string]string {
	rule := map[string]string{}
	if match := siteH1Title.FindStringSubmatch(body); len(match) > 1 {
		want := strings.TrimSpace(match[1])
		candidate := `<h1&&</h1>`
		// 截出的片段必须真的包含站点的片名，避免把导航/横幅当成片名锚点。
		if want != "" && strings.Contains(xbpqCutOnce(body, candidate), want) {
			rule["影片名称"] = candidate
		}
	}
	if match := siteDetailIntroCls.FindStringSubmatch(body); len(match) > 1 {
		candidate := `class="` + strings.Join(strings.Fields(match[1]), " ") + `"&&</div>`
		if cut := xbpqCutOnce(body, candidate); len(strings.TrimSpace(cut)) > 8 {
			rule["简介"] = candidate
		}
	}
	if len(rule) > 0 {
		keys := make([]string, 0, len(rule))
		for key := range rule {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		a.note("详情字段已反推并实测：%s", strings.Join(keys, "/"))
	}
	return rule
}

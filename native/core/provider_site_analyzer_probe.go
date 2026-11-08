package core

// 「自动识别」的四组探测：分类url / 列表五字段 / 搜索 / 播放。
// 全部对齐「一键写XBPQ源.py」的判定顺序与兜底层次，但输出是 guoappxp 引擎语义。

import (
	"encoding/json"
	"regexp"
	"sort"
	"strings"
)

// 常见影视站分类链接前缀（原脚本 CAT_PREFIX_RE；那里把正则字符串当子串用，
// 带反斜杠的两条永远匹配不上，这里修正成普通路径片段）。
var siteCatPrefixes = []string{
	"/index.php/vod/show/id/", "/index.php/vod/type/id/",
	"/vodshow/", "/vod/type/id/", "/vodtype/", "/type/",
	"/show/", "/v_show/", "/kind/", "/v/",
}

var (
	siteCatWords = []string{
		"电影", "电视剧", "剧集", "连续剧", "综艺", "动漫", "动画",
		"短剧", "纪录片", "体育", "直播", "福利", "伦理",
	}
	siteRankWords = []string{
		"排行", "榜单", "榜", "本周", "今日", "热门", "推荐",
		"最新", "专题", "热搜", "评分最高", "人气", "收藏",
	}
	siteExcludeTitles = map[string]bool{"首页": true, "留言": true, "APP": true, "更多": true}
	siteDigits        = regexp.MustCompile(`\d+`)
	siteBadCatPath    = regexp.MustCompile(`(?i)play|detail|search|topic`)
	// 列表反推时不能排除含 detail 的链接——/voddetail/ 正是我们要找的卡片链接。
	sitePlaySearchPath = regexp.MustCompile(`(?i)play|search|topic`)
	siteLinkKeys       = regexp.MustCompile(`(?i)voddetail|/detail/|/vod/|/movie/|/post/|/v/`)
	siteOpenTag        = regexp.MustCompile(`(?i)<(li|dd|dl|div|article)\b[^>]*>`)
	siteTagClass       = regexp.MustCompile(`(?i)class="([^"]+)"`)
	sitePictureAttr    = regexp.MustCompile(`(?i)(data-original|data-src|data-lazy|src)="([^"]+\.(?:jpg|jpeg|png|webp|gif)[^"]*)"`)
	siteTitleAttr      = regexp.MustCompile(`(?i)(alt|title)="([^"]{2,40})"`)
	siteRemarkClass    = regexp.MustCompile(`(?i)class="([^"]*(?:pic-text|remarks|note|state|status)[^"]*)"[^>]*>\s*([^<]{1,20})<`)
	sitePlayHref       = regexp.MustCompile(`(?i)href="([^"]*(?:vodplay|/play/|/vplay/)[^"]*)"[^>]*>\s*([^<]{0,24})\s*<`)
	siteVodshowHref    = regexp.MustCompile(`(?i)href="([^"]*vodshow/[^"]{5,200}\.html)"`)
	siteFilterWord     = regexp.MustCompile(`(?i)[/&?](area|region|year|class|type|genre|by|order|sort|lang|language|letter|initial)/([^/&#?]+)|[?&](area|region|year|class|type|genre|by|order|sort|lang|language|letter|initial)=([^&#]+)`)
	siteFilterKeyOf    = map[string]string{
		"area": "area", "region": "area", "year": "year",
		"class": "class", "type": "class", "genre": "class",
		"by": "by", "order": "by", "sort": "by",
		"lang": "lang", "language": "lang",
		"letter": "letter", "initial": "letter",
	}
)

// 苹果CMS 常见分类路径（原脚本兜底 B）。逐个请求，哪个返回「像列表页」就用哪个。
var siteCategoryCandidates = []string{
	"/vodshow/{cateId}-----------.html",
	"/vodtype/{cateId}.html",
	"/index.php/vodtype/{cateId}.html",
	"/index.php/vod/type/id/{cateId}.html",
	"/index.php/vod/show/id/{cateId}.html",
	"/type/{cateId}.html",
	"/show/{cateId}.html",
	"/v_show/{cateId}-----------.html",
	"/v_type/{cateId}.html",
	"/kind/{cateId}.html",
}

var siteSearchAPIs = []string{
	"/index.php/ajax/suggest?mid=1&wd={wd}",
	"/api.php/provide/vod/?ac=list&wd={wd}",
	"/index.php/ajax/suggest?mid=1&wd={wd}&limit=20",
}

var siteSearchPages = []string{
	"/index.php/vod/search.html?wd={wd}",
	"/index.php/vod/search/page/1/wd/{wd}.html",
	"/search.php?searchword={wd}",
	"/vodsearch/{wd}----------1---.html",
}

// 引擎模板里经过实测的播放列表容器锚（provider_xbpq_template.go）。
// 逐个拿真实详情页试截，选能切出最多分集的一个。
var sitePlayArrayAnchors = []string{
	`<ul class="stui-content__playlist&&</ul>`,
	`<ul class="myui-content__list&&</ul>`,
	`<ul class="content-list&&</ul>`,
	`class="module-play-list-content&&</div>`,
	`class="module-list module-player-list tab-list sort-list&&</div>`,
	`id="hl-plays-list"&&</ul>`,
	`class="play_box&&</div>`,
	`class="module-play-list&&</div>`,
}

var sitePlaySplitCandidates = []string{"<li", "<a", "</a>", "</li>"}

func siteIsRankTitle(title string) bool {
	for _, word := range siteRankWords {
		if strings.Contains(title, word) {
			return true
		}
	}
	return false
}

func siteIsCatTitle(title string) bool {
	for _, word := range siteCatWords {
		if title == word {
			return true
		}
	}
	return false
}

func siteLinkForm(address string) string {
	return siteDigits.ReplaceAllString(address, "#")
}

func siteCatID(address, title string) string {
	if match := siteDigits.FindString(address); match != "" {
		return match
	}
	segments := strings.Split(strings.Trim(address, "/"), "/")
	for i := len(segments) - 1; i >= 0; i-- {
		if segments[i] != "" && !strings.Contains(segments[i], ".") {
			return segments[i]
		}
	}
	return title
}

// makeCategoryURL 把一条真实分类 href 改写成含 {cateId}/{catePg} 的模板
// （原脚本 _xbq_mk_cat_url）。
func (a *siteAnalyzer) makeCategoryURL(href string) string {
	href = strings.TrimSpace(strings.TrimRight(href, "/"))
	if href == "" {
		return ""
	}
	indices := siteDigits.FindAllStringIndex(href, -1)
	var out string
	switch {
	case len(indices) >= 2:
		first := indices[0]
		out = href[:first[0]] + "{cateId}" + href[first[1]:]
		last := siteDigits.FindAllStringIndex(out, -1)
		if len(last) > 0 {
			tail := last[len(last)-1]
			out = out[:tail[0]] + "{catePg}" + out[tail[1]:]
		}
	case len(indices) == 1:
		one := indices[0]
		out = href[:one[0]] + "{cateId}" + href[one[1]:]
		switch {
		case strings.Contains(out, "index.php"):
			out = strings.ReplaceAll(out, ".html", "") + "/page/{catePg}.html"
		case strings.HasSuffix(out, ".html"):
			out = strings.TrimSuffix(out, ".html") + "-{catePg}.html"
		default:
			out += "-{catePg}.html"
		}
	default:
		out = href + "/{cateId}/{catePg}.html"
	}
	switch {
	case strings.HasPrefix(out, "./"):
		return a.site + "/" + strings.TrimPrefix(out, "./")
	case strings.HasPrefix(out, "/"):
		return a.site + out
	case strings.HasPrefix(out, "http"):
		return out
	default:
		return a.site + "/" + out
	}
}

func (a *siteAnalyzer) collectCategories(links [][]string, prefix string) (string, []siteCategory) {
	sample := ""
	cats := make([]siteCategory, 0, 24)
	seen := map[string]bool{}
	for _, match := range links {
		if len(match) < 3 {
			continue
		}
		href, title := strings.TrimSpace(match[1]), strings.TrimSpace(match[2])
		if href == "" || title == "" || len(href) > 60 {
			continue
		}
		if prefix != "" && !strings.Contains(href, prefix) {
			continue
		}
		if siteBadCatPath.MatchString(href) || siteIsRankTitle(title) || siteExcludeTitles[title] {
			continue
		}
		if sample == "" {
			sample = href
		}
		if seen[href] {
			continue
		}
		seen[href] = true
		id := siteCatID(href, title)
		if id != "" {
			cats = append(cats, siteCategory{ID: id, Name: title})
		}
	}
	if len(cats) > 24 {
		cats = cats[:24]
	}
	return sample, cats
}

// detectCategoryTemplate 四层兜底：前缀白名单 → 分类名文字 → 链接形态聚类
// → 苹果CMS 候选路径探测。对齐原脚本 _xbq_analyze 的顺序。
func (a *siteAnalyzer) detectCategoryTemplate(home string) (string, []siteCategory) {
	anchors := siteAnchorHref.FindAllStringSubmatch(home, -1)
	hrefs := siteAnyHref.FindAllStringSubmatch(home, -1)

	// ① 同前缀分类链接 >= 2 个即认定。
	counts := map[string]int{}
	for _, match := range hrefs {
		href := match[1]
		if len(href) >= 60 || !siteDigits.MatchString(href) || siteBadCatPath.MatchString(href) {
			continue
		}
		for _, prefix := range siteCatPrefixes {
			if strings.Contains(href, prefix) {
				counts[prefix]++
				break
			}
		}
	}
	bestPrefix, bestCount := "", 0
	for prefix, count := range counts {
		if count >= 2 && (bestPrefix == "" || count > bestCount) {
			bestPrefix, bestCount = prefix, count
		}
	}
	if bestPrefix != "" {
		sample, cats := a.collectCategories(anchors, bestPrefix)
		if sample != "" && len(cats) >= 2 {
			template := a.makeCategoryURL(sample)
			a.note("识别到分类模式 %s（%d 个分类）",
				strings.NewReplacer("{cateId}", "X", "{catePg}", "P").Replace(template), len(cats))
			return a.refineCategoryURL(template), cats
		}
	}

	// ② 按分类名文字找导航链接（URL 形态不限）。
	var byText [][]string
	for _, match := range anchors {
		if len(match) < 3 {
			continue
		}
		href, title := strings.TrimSpace(match[1]), strings.TrimSpace(match[2])
		if !siteIsCatTitle(title) || href == "" ||
			strings.HasPrefix(href, "#") || strings.HasPrefix(href, "javascript") ||
			strings.Contains(strings.ToLower(href), "play") ||
			strings.Contains(strings.ToLower(href), "search") {
			continue
		}
		byText = append(byText, []string{"", href, title})
	}
	if len(byText) >= 2 {
		sample, cats := a.collectCategories(byText, "")
		if sample != "" && len(cats) >= 2 {
			template := a.makeCategoryURL(sample)
			a.note("按分类名文字识别到 %d 个分类（URL 形态较特殊，准确率有限）", len(cats))
			return a.refineCategoryURL(template), cats
		}
	}

	// ③ 任意形态聚类：同形态（数字归一后）重复 >= 3 次且标题各不相同才算分类。
	forms := map[string][][]string{}
	for _, match := range anchors {
		if len(match) < 3 {
			continue
		}
		href, title := strings.TrimSpace(match[1]), strings.TrimSpace(match[2])
		if title == "" || len(href) > 60 || siteBadCatPath.MatchString(href) || !siteDigits.MatchString(href) {
			continue
		}
		key := siteLinkForm(href)
		forms[key] = append(forms[key], []string{"", href, title})
	}
	formKeys := make([]string, 0, len(forms))
	for key := range forms {
		formKeys = append(formKeys, key)
	}
	sort.Slice(formKeys, func(i, j int) bool { return len(forms[formKeys[i]]) > len(forms[formKeys[j]]) })
	for _, key := range formKeys {
		items := forms[key]
		if len(items) < 3 {
			break
		}
		titles := map[string]bool{}
		for _, item := range items {
			titles[item[2]] = true
		}
		if len(titles) < 3 {
			continue
		}
		sample, cats := a.collectCategories(items, "")
		if sample == "" || len(cats) < 2 {
			continue
		}
		template := a.makeCategoryURL(sample)
		a.note("按链接形态聚类识别到 %d 个分类（样本 %s）", len(cats), sample[:min(len(sample), 40)])
		return a.refineCategoryURL(template), cats
	}

	// ④ 苹果CMS 候选路径探测：哪个返回 200 且像列表页就用哪个。
	homeSignature := home[:min(len(home), 200)]
	for _, candidate := range siteCategoryCandidates {
		probe := a.site + strings.ReplaceAll(candidate, "{cateId}", "1")
		body := a.fetch(probe, siteAnalyzerMobileUA)
		if len(body) < 300 || siteIsShield(body) || body[:min(len(body), 200)] == homeSignature {
			continue
		}
		if !siteDetailHref.MatchString(body) && !regexp.MustCompile(`href="[^"]*\d{3,}`).MatchString(body) {
			continue
		}
		template := a.site + candidate
		if !strings.Contains(template, "{catePg}") {
			switch {
			case strings.Contains(template, "-----------"):
				template = strings.Replace(template, "-----------.html", "-----------{catePg}.html", 1)
			case strings.Contains(template, ".html"):
				template = strings.ReplaceAll(template, ".html", "-{catePg}.html")
			default:
				template = strings.TrimRight(template, "/") + "/page/{catePg}.html"
			}
		}
		a.note("首页没有分类链接，按苹果CMS 候选路径探测成功：%s", strings.ReplaceAll(candidate, "{cateId}", "1"))
		if strings.Contains(template, "/vodshow/") || strings.Contains(template, "/v_show/") {
			if probed := a.vodshowTemplate(); probed != "" {
				template = probed
				a.note("已按站点真实筛选链接还原 vodshow 横线链模板")
			}
		}
		cats := []siteCategory{
			{ID: "1", Name: "电影"}, {ID: "2", Name: "电视剧"},
			{ID: "3", Name: "综艺"}, {ID: "4", Name: "动漫"},
		}
		a.note("分类使用通杀值（1电影 / 2电视剧 / 3综艺 / 4动漫），如与站点不符请在规则里改「分类」")
		return a.refineCategoryURL(template), cats
	}
	return "", nil
}

// refineCategoryURL 只采纳「真实探测到」的筛选占位符，绝不凭空拼一串可能 404 的空段。
func (a *siteAnalyzer) refineCategoryURL(template string) string {
	if !strings.Contains(template, "{cateId}") || !strings.Contains(template, "{catePg}") {
		return template
	}
	if !strings.Contains(template, "/vodshow/") && !strings.Contains(template, "index.php/vod/show") {
		return template
	}
	id := "1"
	if len(a.cats) > 0 && a.cats[0].ID != "" {
		id = a.cats[0].ID
	}
	page := a.fetch(siteFillCategoryURL(template, id, "1"), siteAnalyzerMobileUA)
	if len(page) < 200 {
		return template
	}
	// 找同时含 >=2 个筛选关键词的链接，按它们在 URL 中的实际出现顺序还原占位符。
	best, bestHits := "", 0
	for _, match := range siteAnyHref.FindAllStringSubmatch(page, -1) {
		href := match[1]
		if len(href) < 10 || len(href) > 220 || strings.HasPrefix(href, "./") {
			continue
		}
		hits := map[string]bool{}
		for _, group := range siteFilterWord.FindAllStringSubmatch(href, -1) {
			key := strings.ToLower(group[1])
			if key == "" {
				key = strings.ToLower(group[3])
			}
			if mapped := siteFilterKeyOf[key]; mapped != "" {
				hits[mapped] = true
			}
		}
		if len(hits) >= 2 && len(hits) > bestHits {
			best, bestHits = href, len(hits)
		}
	}
	if best == "" {
		return template
	}
	if strings.HasPrefix(best, "/") {
		best = a.site + best
	}
	out := best
	// 从后往前替换，前面的 SubmatchIndex 才不会因长度变化而失效。
	// 正则有 4 个捕获组：路径式 (1=key,2=value)、查询式 (3=key,4=value)，
	// 对应 loc[2..5] 与 loc[6..9]；未参与的组为 -1。
	matches := siteFilterWord.FindAllStringSubmatchIndex(out, -1)
	for i := len(matches) - 1; i >= 0; i-- {
		loc := matches[i]
		var key string
		valueStart, valueEnd := -1, -1
		if loc[2] >= 0 && loc[4] >= 0 {
			key = siteFilterKeyOf[strings.ToLower(out[loc[2]:loc[3]])]
			valueStart, valueEnd = loc[4], loc[5]
		} else if loc[6] >= 0 && loc[8] >= 0 {
			key = siteFilterKeyOf[strings.ToLower(out[loc[6]:loc[7]])]
			valueStart, valueEnd = loc[8], loc[9]
		}
		if key == "" || valueStart < 0 || valueEnd > len(out) {
			continue
		}
		value := out[valueStart:valueEnd]
		if value == "" || strings.Contains(value, "{") {
			continue
		}
		out = out[:valueStart] + "{" + key + "}" + out[valueEnd:]
	}
	if !strings.Contains(out, "{cateId}") {
		idPattern := regexp.MustCompile(`(?i)(/(?:vodshow|v_show|vodtype|type|show|kind|id|vod)/)` + regexp.QuoteMeta(id) + `(?=[-/.]|$)`)
		out = idPattern.ReplaceAllString(out, "${1}{cateId}")
	}
	if !strings.Contains(out, "{catePg}") {
		out = strings.Replace(out, "/page/1", "/page/{catePg}", 1)
		if !strings.Contains(out, "{catePg}") && strings.Contains(out, "-") {
			parts := strings.Split(out, "-")
			for index := len(parts) - 1; index >= 0; index-- {
				value := strings.TrimSuffix(parts[index], ".html")
				if siteDigits.MatchString(value) && value == strings.TrimSpace(value) &&
					len(value) <= 2 && value != id && !strings.Contains(parts[index], "{") {
					parts[index] = strings.Replace(parts[index], value, "{catePg}", 1)
					out = strings.Join(parts, "-")
					break
				}
			}
		}
	}
	if strings.Contains(out, "{cateId}") && strings.Contains(out, "{catePg}") && len(out) < 260 {
		a.note("已按实际网址顺序补全筛选占位符（顺序与站点一致）")
		return out
	}
	return template
}

// vodshowTemplate 从站点真实筛选链接还原横线链模板（原脚本 _xbq_vodshow_template）。
func (a *siteAnalyzer) vodshowTemplate() string {
	body := a.fetch(a.site+"/vodshow/1-----------.html", siteAnalyzerMobileUA)
	if len(body) < 300 {
		return ""
	}
	best, bestSegments := "", 0
	for _, match := range siteVodshowHref.FindAllStringSubmatch(body, -1) {
		href := match[1]
		index := strings.Index(href, "/vodshow/")
		if index < 0 || !strings.HasSuffix(href, ".html") {
			continue
		}
		segment := href[index+len("/vodshow/") : len(href)-len(".html")]
		count := 0
		for _, part := range strings.Split(segment, "-") {
			if strings.TrimSpace(part) != "" {
				count++
			}
		}
		if count >= 3 && count > bestSegments {
			best, bestSegments = segment, count
		}
	}
	if best == "" {
		return ""
	}
	parts := strings.Split(best, "-")
	out := append([]string(nil), parts...)
	used := map[string]bool{}
	var chinese []int
	for index, raw := range parts {
		value := strings.TrimSpace(raw)
		if value == "" {
			continue
		}
		lower := strings.ToLower(value)
		switch {
		case siteDigits.MatchString(value) && len(value) == 4:
			out[index], used["year"] = "{year}", true
		case lower == "time" || lower == "hits" || lower == "score" || lower == "addtime" || lower == "hot":
			out[index], used["by"] = "{by}", true
		case value == "1":
			out[index], used["cateId"] = "{cateId}", true
		case siteDigits.MatchString(value):
			out[index], used["catePg"] = "{catePg}", true
		case regexp.MustCompile(`^[a-z]{1,10}$`).MatchString(lower):
			if len(lower) <= 1 || used["lang"] {
				out[index], used["letter"] = "{letter}", true
			} else {
				out[index], used["lang"] = "{lang}", true
			}
		default:
			chinese = append(chinese, index)
		}
	}
	for _, key := range []string{"area", "class", "lang"} {
		if used[key] || len(chinese) == 0 {
			continue
		}
		out[chinese[0]] = "{" + key + "}"
		used[key] = true
		chinese = chinese[1:]
	}
	if !used["cateId"] {
		out[0] = "{cateId}"
	}
	if !used["catePg"] {
		empties := []int{}
		for index, value := range out {
			if strings.TrimSpace(value) == "" {
				empties = append(empties, index)
			}
		}
		if len(empties) > 0 {
			out[empties[len(empties)-1]] = "{catePg}"
		} else {
			out = append(out, "{catePg}")
		}
	}
	return a.site + "/vodshow/" + strings.Join(out, "-") + ".html"
}

// guessListRule 从分类页反推「数组/标题/图片/链接/副标题」，对齐原脚本
// _xbq_guess_list_rule；输出已转成引擎语义（链接一律 href="&&"）。
func (a *siteAnalyzer) guessListRule(body string) map[string]string {
	rule := map[string]string{}
	// mxone「module-poster-items」皮肤：数组必须从 <a 起手，否则 href 被挡在块外。
	if strings.Contains(body, "module-poster-item") || strings.Contains(body, "module-item-pic") {
		rule["数组"] = `<a &&</a>[包含:module-poster-item module-item]`
		rule["标题"] = `alt="&&"`
		rule["图片"] = `data-original="&&"`
		rule["链接"] = `href="&&"`
		rule["副标题"] = `class="module-item-note">&&</div>`
		a.note("命中 mxone poster-items 皮肤，采用实测列表模板")
	}

	forms := map[string][]string{}
	for _, match := range siteAnyHref.FindAllStringSubmatch(body, -1) {
		href := match[1]
		lower := strings.ToLower(href)
		if !siteLinkKeys.MatchString(lower) || sitePlaySearchPath.MatchString(lower) {
			continue
		}
		key := siteLinkForm(href)
		forms[key] = append(forms[key], href)
	}
	bestKey, bestLinks := "", []string(nil)
	for key, links := range forms {
		if len(links) > len(bestLinks) {
			bestKey, bestLinks = key, links
		}
	}
	if len(bestLinks) < 2 {
		return rule
	}
	_ = bestKey
	sample := bestLinks[0]
	if positions := siteDigits.FindAllStringIndex(sample, -1); len(positions) > 0 {
		first := positions[0]
		a.detailPrefix = sample[:first[0]]
		a.detailSuffix = sample[first[1]:]
	}
	if len(rule) == 0 {
		rule["链接"] = `href="&&"`
	}

	// 数组：以详情链接为锚向前回溯，挑最贴近链接的卡片级容器开标签。
	position := strings.Index(body, sample)
	if position >= 0 {
		start := position - 1500
		if start < 0 {
			start = 0
		}
		segment := body[start:position]
		type candidate struct {
			score  int
			offset int
			tag    string
			class  string
		}
		var candidates []candidate
		for _, match := range siteOpenTag.FindAllStringSubmatchIndex(segment, -1) {
			raw := segment[match[0]:match[1]]
			tag := strings.ToLower(raw[1:min(len(raw), 5)])
			if index := strings.IndexAny(raw, " \t>"); index > 0 {
				tag = strings.ToLower(raw[1:index])
			}
			score := 0
			class := ""
			if classMatch := siteTagClass.FindStringSubmatch(raw); len(classMatch) > 1 {
				class = strings.Join(strings.Fields(classMatch[1]), " ")
				lower := strings.ToLower(class)
				switch {
				case strings.Contains(lower, "__box") || strings.Contains(lower, "item") ||
					strings.Contains(lower, "thumb") || strings.Contains(lower, "card"):
					score = 3
				case strings.Contains(lower, "__list") || strings.Contains(lower, "list"):
					score = 1
				}
			}
			if tag == "li" || tag == "dd" || tag == "dl" {
				score++
			}
			candidates = append(candidates, candidate{score: score, offset: match[0], tag: tag, class: class})
		}
		if len(candidates) > 0 {
			sort.SliceStable(candidates, func(i, j int) bool {
				if candidates[i].score != candidates[j].score {
					return candidates[i].score < candidates[j].score
				}
				return candidates[i].offset < candidates[j].offset
			})
			chosen := candidates[len(candidates)-1]
			if chosen.class != "" {
				rule["数组"] = `class="` + chosen.class + `"&&</a>`
			} else {
				rule["数组"] = "<" + chosen.tag + "&&</" + chosen.tag + ">"
			}
		}
	}

	// 标题 / 图片 / 副标题：只看样本链接附近的标签块。
	blockStart := max(position-600, 0)
	block := body[blockStart:min(len(body), position+1200)]
	if picture := sitePictureAttr.FindStringSubmatch(block); len(picture) > 1 {
		rule["图片"] = picture[1] + `="&&"`
	}
	if title := siteTitleAttr.FindStringSubmatch(block); len(title) > 1 {
		rule["标题"] = title[1] + `="&&"`
	}
	if remark := siteRemarkClass.FindStringSubmatch(block); len(remark) > 1 {
		rule["副标题"] = `class="` + strings.Join(strings.Fields(remark[1]), " ") + `"&&</span>`
	}
	return rule
}

// guessSearchRule 先探 JSON 接口，再探网页搜索页；输出全部转成引擎语义。
func (a *siteAnalyzer) guessSearchRule() map[string]string {
	rule := map[string]string{}
	for _, api := range siteSearchAPIs {
		body := a.fetch(a.site+strings.ReplaceAll(api, "{wd}", "test"), siteAnalyzerMobileUA)
		trimmed := strings.TrimSpace(body)
		if trimmed == "" || (trimmed[0] != '{' && trimmed[0] != '[') {
			continue
		}
		arrayKey, idKey, titleKey, pictureKey := siteJSONKeys(trimmed)
		if idKey == "" {
			continue
		}
		rule["搜索url"] = a.site + api
		rule["搜索数组"] = "j:" + arrayKey
		rule["搜索标题"] = "j:" + titleKey
		rule["搜索图片"] = "j:" + pictureKey
		rule["搜索链接"] = a.jsonSearchLink(idKey)
		a.note("探测到 JSON 搜索接口 %s，已转成 j: 路径", api)
		return rule
	}
	for _, template := range siteSearchPages {
		address := a.site + strings.NewReplacer("{wd}", "test").Replace(template)
		body := a.fetch(address, siteAnalyzerMobileUA)
		if len(body) < 200 || !siteDetailHref.MatchString(body) {
			continue
		}
		rule["搜索url"] = a.site + template
		// 搜索结果一般与分类列表同构，复用实测过的列表字段。
		if len(a.listRule) > 0 && siteValidateListFields(a.catHTML, a.listRule) >= 1 {
			rule["搜索数组"] = a.listRule["数组"]
			rule["搜索标题"] = a.listRule["标题"]
			rule["搜索链接"] = a.listRule["链接"]
			if picture := a.listRule["图片"]; picture != "" {
				rule["搜索图片"] = picture
			}
			a.note("探测到网页搜索页，复用已实测的列表字段")
		} else {
			rule["搜索数组"] = `class="stui-vodlist&&</a>`
			rule["搜索标题"] = `title="&&"`
			rule["搜索链接"] = `href="&&"`
			rule["搜索图片"] = `data-original="&&"`
			a.note("探测到网页搜索页，采用 MacCMS 通用搜索模板")
		}
		return rule
	}
	a.note("搜索接口未探测到，交由引擎模板按分类url 形态兜底")
	return rule
}

// siteJSONKeys 从搜索接口响应里找出「数组键 / ID / 标题 / 封面」的真实字段名。
func siteJSONKeys(body string) (arrayKey, idKey, titleKey, pictureKey string) {
	var payload any
	if json.Unmarshal([]byte(body), &payload) != nil {
		return "list", "", "", ""
	}
	object, ok := payload.(map[string]any)
	if !ok {
		return "list", "", "", ""
	}
	arrayKey = "list"
	var first map[string]any
	for _, key := range []string{"list", "data", "result", "rows", "items"} {
		items, ok := object[key].([]any)
		if !ok || len(items) == 0 {
			continue
		}
		arrayKey = key
		if row, ok := items[0].(map[string]any); ok {
			first = row
		}
		break
	}
	if first == nil {
		return arrayKey, "", "", ""
	}
	for key := range first {
		lower := strings.ToLower(key)
		if idKey == "" && (lower == "id" || strings.HasSuffix(lower, "_id") || lower == "vodid") {
			idKey = key
		}
		if titleKey == "" && (lower == "name" || strings.Contains(lower, "name") || lower == "title") {
			titleKey = key
		}
		if pictureKey == "" && (lower == "pic" || strings.Contains(lower, "pic") || strings.Contains(lower, "cover")) {
			pictureKey = key
		}
	}
	if titleKey == "" {
		titleKey = "name"
	}
	if pictureKey == "" {
		pictureKey = "pic"
	}
	return arrayKey, idKey, titleKey, pictureKey
}

func (a *siteAnalyzer) jsonSearchLink(idKey string) string {
	prefix, suffix := a.detailPrefix, a.detailSuffix
	if prefix == "" || strings.Contains(prefix, "{") {
		prefix = "/voddetail/"
	}
	if suffix == "" {
		suffix = ".html"
	}
	if !strings.HasPrefix(prefix, "/") && !strings.HasPrefix(prefix, "http") {
		prefix = "/" + prefix
	}
	return prefix + "+j:" + idKey + "+" + suffix
}

// guessPlayRule 在真实详情页上逐个试引擎模板的播放容器锚，选分集切得最多的一组。
// 关键：播放列表输出的是**分隔符**，不是 XBPQ jar 的截取串。
func (a *siteAnalyzer) guessPlayRule(body string) map[string]string {
	rule := map[string]string{}
	if len(sitePlayHref.FindAllString(body, -1)) == 0 {
		a.note("详情页未发现分集链接，播放字段交由引擎模板兜底")
		return rule
	}
	bestAnchor, bestSplit := "", ""
	bestScore := 0
	for _, anchor := range sitePlayArrayAnchors {
		segments := xbpqList(body, anchor)
		if len(segments) == 0 {
			continue
		}
		raw := xbpqCutOnce(body, anchor)
		if raw == "" {
			continue
		}
		for _, split := range sitePlaySplitCandidates {
			parts := strings.Split(raw, split)
			usable := 0
			for _, part := range parts {
				if xbpqCutOnce(part, `href="&&"`) != "" {
					usable++
				}
			}
			if usable == 0 {
				continue
			}
			score := usable*10 + len(segments)
			if score > bestScore {
				bestAnchor, bestSplit, bestScore = anchor, split, score
			}
		}
	}
	if bestAnchor == "" {
		a.note("播放容器未识别，交由引擎模板按分类url 形态兜底")
		return rule
	}
	rule["播放数组"] = bestAnchor
	segments := xbpqList(body, bestAnchor)
	if len(segments) >= 2 {
		// 同锚点切出的多段 = 多条线路，交给 xbpqEpisodes 按 $$$ 合并。
		rule["线路数组"] = bestAnchor
	}
	rule["播放列表"] = bestSplit
	rule["播放标题"] = `>&&</a>`
	rule["播放链接"] = `href="&&"`
	a.note("播放字段已按详情页实测（容器 %s，分隔符 %q，%d 段）",
		strings.Split(bestAnchor, "&&")[0], bestSplit, len(strings.Split(xbpqCutOnce(body, bestAnchor), bestSplit)))
	return rule
}

package core

import (
	"context"
	"encoding/json"
	"encoding/xml"
	"errors"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"golang.org/x/text/encoding/simplifiedchinese"
	"golang.org/x/text/transform"
)

// ---------------------------------------------------------------------------
// MacCMS 标准 JSON API（/api.php/provide/vod/）
//
// 苹果 CMS / MacCMS 系站点普遍内置这套接口，返回结构固定：
//
//	{"code":1,"list":[{"vod_id":1,"vod_name":"...","vod_pic":"...","vod_remarks":"...",
//	 "vod_content":"...","vod_play_from":"m3u8$$$","vod_play_url":"第1集$url#第2集$url$$$...",
//	 "type_id":1,"type_name":"电影"}],"class":[{"type_id":1,"type_name":"电影"}]}
//
// 相比抓 HTML 模板，它有三个决定性优势：
//  1. 不依赖页面模板（indexphp / myui / 自定义前缀全都走同一套接口）；
//  2. 列表、搜索、详情、分类、播放地址一次拿全，不怕模板改版或反爬遮挡；
//  3. vod_play_from 直接给出多条线路，与播放页线路列表等价且更全。
//
// 因此自定义站源统一「API 优先、HTML 兜底」：探测到 API 就走这里，
// 探测不到或调用失败再退回原有模板解析，已接入的站点行为不变。
// ---------------------------------------------------------------------------

var maccmsAPIEndpointCache sync.Map // source -> maccmsAPIEndpointEntry（正面长期缓存，负面短 TTL）

// maccmsAPIEndpointEntry 缓存一次 API 探测结果：
// endpoint 非空为正面结论（长期有效）；endpoint 为空且 expires 非零为
// 确定性负面结论（TTL 内不再探测）；临时性失败不写缓存。
// 避免站点瞬时 503 限流把自定义源永久锁死在 HTML 兜底路径。
type maccmsAPIEndpointEntry struct {
	endpoint string
	expires  time.Time
}

// maccmsAPIStatusPattern 从 fetchProviderText 的错误串提取 HTTP 状态码。
var maccmsAPIStatusPattern = regexp.MustCompile(`HTTP (\d{3})`)

// maccmsAPIEndpointCandidates 罗列常见的 API 挂载位置，逐个探测。
// 若 base 本身已是完整采集端点（含 /provide/vod 或 /api.php，如导入保留下来的
// .../provide/vod/at/xml），base 原样排在最前并补 JSON/XML 格式变体，
// 站点根形态才走通用挂载位置探测。
func maccmsAPIEndpointCandidates(base string) []string {
	base = strings.TrimRight(strings.TrimSpace(base), "/")
	if base == "" {
		return nil
	}
	candidates := make([]string, 0, 8)
	if strings.Contains(base, "/provide/vod") || strings.Contains(base, "/api.php") {
		candidates = append(candidates, base)
		if !strings.Contains(base, "/at/") {
			candidates = append(candidates, base+"/at/json", base+"/at/xml")
		}
	}
	candidates = append(candidates,
		base+"/api.php/provide/vod/",
		base+"/api.php/provide/vod",
		base+"/inc/api.php/provide/vod/",
		base+"/api.php/provide/vod/at/json",
		base+"/api.php/provide/vod/at/xml",
		base+"/api.php/provide/vod/from/m3u8/",
		base+"/api.php/app/vod/",
	)
	seen := map[string]bool{}
	unique := make([]string, 0, len(candidates))
	for _, candidate := range candidates {
		if candidate == "" || seen[candidate] {
			continue
		}
		seen[candidate] = true
		unique = append(unique, candidate)
	}
	return unique
}

// maccmsAPIEndpointFor 返回该站源可用的 API 地址，空串表示当前判定不支持。
// 正面结果长期缓存；临时性失败（5xx、网络错误）不缓存，
// 确定性负面结论（响应不是 JSON API）缓存 60 秒后过期重试。
func maccmsAPIEndpointFor(ctx context.Context, d *Downloader, source, base string) string {
	if cached, found := maccmsAPIEndpointCache.Load(source); found {
		entry := cached.(maccmsAPIEndpointEntry)
		if entry.endpoint != "" || time.Now().Before(entry.expires) {
			return entry.endpoint
		}
	}
	provisional := false
	found := ""
	for _, candidate := range maccmsAPIEndpointCandidates(base) {
		endpoint, permanent := d.maccmsAPIProbeOnce(ctx, candidate, base)
		if endpoint != "" {
			found = candidate
			break
		}
		if !permanent {
			provisional = true
		}
	}
	switch {
	case found != "":
		maccmsAPIEndpointCache.Store(source, maccmsAPIEndpointEntry{endpoint: found})
	case provisional:
		// 站点可能只是临时限流/抖动：短 TTL 后重试，既不让风暴期反复重探，
		// 也不会把瞬时 503 变成永久降级。
		maccmsAPIEndpointCache.Store(source, maccmsAPIEndpointEntry{expires: time.Now().Add(30 * time.Second)})
	default:
		maccmsAPIEndpointCache.Store(source, maccmsAPIEndpointEntry{expires: time.Now().Add(60 * time.Second)})
	}
	return found
}

// maccmsAPIProbeOnce 探测单个候选 API 地址。
// 返回 (endpoint, definitive)：endpoint 非空表示该候选可用；
// definitive=true 表示拿到了明确的「非 API 响应」，可放心缓存负面结论；
// definitive=false 表示传输层/5xx 等临时故障，不应据此否定 API 支持。
func (d *Downloader) maccmsAPIProbeOnce(ctx context.Context, candidate, base string) (string, bool) {
	body, err := d.fetchProviderText(ctx, candidate+"?ac=videolist&pg=1", base+"/")
	if err != nil {
		return "", maccmsAPIErrorDefinitive(err)
	}
	body = strings.TrimSpace(body)
	if strings.HasPrefix(body, "{") {
		var payload map[string]any
		if json.Unmarshal([]byte(body), &payload) != nil {
			return candidate, false // JSON 却解析失败：形态可疑，不缓存负面结论
		}
		if _, hasList := payload["list"]; hasList {
			return candidate, false // list 键存在即认 API（空列表只是暂无数据）
		}
		if _, hasData := payload["data"]; hasData {
			return candidate, false
		}
		return "", true
	}
	// 采集接口可返回 XML（MacCMS at/xml 形态）：识别到 list / class / video 标签即认 API。
	if strings.HasPrefix(body, "<") && maccmsAPIXMLLooksLike(body) {
		return candidate, false
	}
	return "", true // 有响应但既非 JSON 也非 MacCMS XML：确定不支持
}

// maccmsAPIXMLLooksLike 粗判一段文本是否为 MacCMS 采集 XML（含视频/分类/列表任一结构标签）。
func maccmsAPIXMLLooksLike(body string) bool {
	probe := body
	if len(probe) > 4096 {
		probe = probe[:4096]
	}
	for _, marker := range []string{"<list", "<video", "<class", "<ty ", "<ty>", "<?xml"} {
		if strings.Contains(probe, marker) {
			return true
		}
	}
	return false
}

// maccmsAPIErrorDefinitive 判断一次抓取错误是否是「站点明确拒绝」而非临时抖动。
// fetchProviderText 的 HTTP 错误形如 "host HTTP 503"；5xx/408/429 与无状态码的
// 网络错误都属临时（下次调用应重试探测），其余 4xx 说明该路径确实没有 API。
func maccmsAPIErrorDefinitive(err error) bool {
	if err == nil {
		return false
	}
	var backoff *requestBackoff
	if errors.As(err, &backoff) {
		return backoff.status >= 400 && backoff.status < 500 && backoff.status != 408 && backoff.status != 429
	}
	match := maccmsAPIStatusPattern.FindStringSubmatch(err.Error())
	if len(match) != 2 {
		return false // 无状态码：连接失败/超时等，视为临时
	}
	status, convErr := strconv.Atoi(match[1])
	if convErr != nil {
		return false
	}
	return status >= 400 && status < 500 && status != 408 && status != 429
}

// maccmsAPICall 请求 API 并解出 list / class，失败时返回错误。
// 兼容两种响应体：标准 JSON（{"list":[...],"class":[...]}）与 MacCMS 采集 XML
// (<list pic_domain=".."><video>..</video><class>..</class></list>)，XML 归一化成
// 与 JSON 同形态的 map（list / class 两个键），下游 maccmsAPIItems / maccmsAPIDrama
// 等无需感知格式差异。
func (d *Downloader) maccmsAPICall(ctx context.Context, address, referer string) (map[string]any, error) {
	body, err := d.fetchProviderText(ctx, address, referer)
	if err != nil || strings.TrimSpace(body) == "" || len(body) > 8*1024*1024 {
		if err == nil {
			err = errMaccmsAPIEmpty
		}
		return nil, err
	}
	body = strings.TrimSpace(body)
	var payload map[string]any
	switch {
	case strings.HasPrefix(body, "{"):
		if json.Unmarshal([]byte(body), &payload) != nil {
			return nil, errMaccmsAPIEmpty
		}
	case strings.HasPrefix(body, "<"):
		xmlBody, _, xmlErr := maccmsAPIDecodeXML(body)
		if xmlErr != nil {
			return nil, xmlErr
		}
		payload, err = maccmsAPIParseXML(xmlBody)
		if err != nil {
			return nil, errMaccmsAPIEmpty
		}
	default:
		return nil, errMaccmsAPIEmpty
	}
	if code := maccmsAPIInt(payload["code"]); code == 0 && len(payload) > 1 {
		// 部分站点不返回 code 字段，只要有内容就放行。
		if _, hasList := payload["list"]; !hasList {
			if _, hasData := payload["data"]; !hasData {
				return nil, errMaccmsAPIEmpty
			}
		}
	}
	return payload, nil
}

var errMaccmsAPIEmpty = &maccmsAPIError{"接口未返回可用数据"}

type maccmsAPIError struct{ message string }

func (e *maccmsAPIError) Error() string { return e.message }

// ---------------------------------------------------------------------------
// MacCMS 采集 XML（/api.php/provide/vod/at/xml）解析
//
// streamhub 那批采集接口几乎全走 at/xml，返回形如：
//
//	<?xml version="1.0"?>
//	<total>99</total><pagecount>5</pagecount>
//	<list pic_domain="http://img.x.cn"><video>…<vod_play_url>第1集$url#…</vod_play_url></video></list>
//	<class><ty id="1">电影</ty>…</class>
//
// 不同 MacCMS 版本根元素不统一（单根 / 多顶级兄弟 / 无 list 包裹都见过），
// 故用 xml.Decoder 逐 token 扫描，按 <video> / <class> / <pagecount> 标签抓取，
// 不依赖具体嵌套结构；再归一化成与 JSON 同形态的 map（list / class / pagecount），
// 下游 maccmsAPIItems / maccmsAPIDrama / maccmsAPIChapters 无需感知格式差异。
// ---------------------------------------------------------------------------

type maccmsXMLVideo struct {
	ID          string `xml:"id"`
	VodID       string `xml:"vod_id"`
	Name        string `xml:"name"`
	VodName     string `xml:"vod_name"`
	Title       string `xml:"title"`
	Type        string `xml:"type"`
	TypeName    string `xml:"type_name"`
	Remarks     string `xml:"note"`
	VodRemarks  string `xml:"vod_remarks"`
	Content     string `xml:"des"`
	VodContent  string `xml:"vod_content"`
	Blurb       string `xml:"vod_blurb"`
	Actor       string `xml:"actor"`
	VodActor    string `xml:"vod_actor"`
	Director    string `xml:"director"`
	VodDirector string `xml:"vod_director"`
	Pic         string `xml:"vod_pic"`
	PicAlt      string `xml:"pic"`
	Img         string `xml:"vod_img"`
	ImgAlt      string `xml:"img"`
	PlayURL     string `xml:"vod_play_url"`
	URL         string `xml:"vod_url"`
	DL          struct {
		Items []string `xml:"dd"`
	} `xml:"dl"`
}

type maccmsXMLType struct {
	ID   string `xml:"id,attr"`
	Name string `xml:",chardata"`
}

type maccmsXMLClass struct {
	Types []maccmsXMLType `xml:"ty"`
}

// maccmsAPIDecodeXML 归一化 XML 文本编码：MacCMS 采集接口大量输出 GBK/GB18030，
// 而 fetchProviderText 按响应字节原样返回。UTF-8 合法性不成立时按 GB18030 兜底解码。
func maccmsAPIDecodeXML(body string) (string, string, error) {
	if utf8.ValidString(body) {
		return body, "utf-8", nil
	}
	decoded, _, err := transform.String(simplifiedchinese.GB18030.NewDecoder(), body)
	if err != nil {
		return "", "", err
	}
	return decoded, "gb18030", nil
}

// maccmsAPIParseXML 把 MacCMS 采集 XML 解析成 {list, class, pagecount} 形态的 map。
// 逐 token 扫描，兼容单根 / 多顶级兄弟 / 无 list 包裹等结构差异。
func maccmsAPIParseXML(body string) (map[string]any, error) {
	decoder := xml.NewDecoder(strings.NewReader(body))
	var videos []map[string]any
	var classes []map[string]any
	pageCount := ""
	sawClass := false
	picDomain := ""
	for {
		token, err := decoder.Token()
		if err != nil {
			break // 末尾或 malformed：拿到多少算多少
		}
		start, ok := token.(xml.StartElement)
		if !ok {
			continue
		}
		switch start.Name.Local {
		case "video":
			var video maccmsXMLVideo
			if decoder.DecodeElement(&video, &start) != nil {
				continue
			}
			if entry := maccmsXMLVideoToMap(video, picDomain); entry != nil {
				videos = append(videos, entry)
			}
		case "class":
			if sawClass {
				_ = decoder.Skip()
				continue
			}
			var class maccmsXMLClass
			if decoder.DecodeElement(&class, &start) == nil {
				sawClass = true
				for _, ty := range class.Types {
					id := strings.TrimSpace(ty.ID)
					name := strings.TrimSpace(ty.Name)
					if id == "" || name == "" {
						continue
					}
					classes = append(classes, map[string]any{"type_id": id, "type_name": name})
				}
			}
		case "list":
			// 只记录 pic_domain 供图片补全，不消费子树（继续下探 <video>）。
			for _, attr := range start.Attr {
				if attr.Name.Local == "pic_domain" || attr.Name.Local == "vod_pic_domain" {
					picDomain = strings.TrimSpace(attr.Value)
				}
			}
		case "pagecount", "page_count", "pageCount":
			var text string
			if decoder.DecodeElement(&text, &start) == nil {
				pageCount = strings.TrimSpace(text)
			}
		}
	}
	payload := map[string]any{}
	if len(videos) > 0 {
		list := make([]any, 0, len(videos))
		for _, video := range videos {
			list = append(list, video)
		}
		payload["list"] = list
	}
	if len(classes) > 0 {
		classRows := make([]any, 0, len(classes))
		for _, class := range classes {
			classRows = append(classRows, class)
		}
		payload["class"] = classRows
	}
	if pageCount != "" {
		payload["pagecount"] = pageCount
	}
	if len(payload) == 0 {
		return nil, errors.New("XML 无可识别的视频或分类内容")
	}
	return payload, nil
}

// maccmsXMLVideoToMap 把一个 <video> 转成 maccmsAPIDrama 认识的键值；
// 缺主键/标题/分集地址任一即判无效返回 nil。picDomain 存在且图片为相对路径时按
// 图片域补全（对齐 streamhub formatImageUrl 的 pic_domain 处理）。
func maccmsXMLVideoToMap(video maccmsXMLVideo, picDomain string) map[string]any {
	id := firstNonEmpty(video.VodID, video.ID)
	name := firstNonEmpty(video.VodName, video.Name, video.Title)
	if id == "" || name == "" {
		return nil
	}
	pic := firstNonEmpty(video.Pic, video.PicAlt, video.Img, video.ImgAlt)
	if picDomain != "" && pic != "" && !strings.Contains(pic, "://") {
		if strings.HasPrefix(pic, "/") {
			pic = strings.TrimRight(picDomain, "/") + pic
		} else {
			pic = strings.TrimRight(picDomain, "/") + "/" + pic
		}
	}
	playURL := firstNonEmpty(video.PlayURL, video.URL)
	if playURL == "" && len(video.DL.Items) > 0 {
		parts := make([]string, 0, len(video.DL.Items))
		for _, raw := range video.DL.Items {
			if text := strings.TrimSpace(raw); text != "" {
				parts = append(parts, text)
			}
		}
		playURL = strings.Join(parts, "$$$")
	}
	if playURL == "" {
		return nil
	}
	return map[string]any{
		"vod_id":       id,
		"vod_name":     name,
		"vod_pic":      pic,
		"type_name":    firstNonEmpty(video.TypeName, video.Type),
		"vod_remarks":  firstNonEmpty(video.VodRemarks, video.Remarks),
		"vod_content":  firstNonEmpty(video.VodContent, video.Content, video.Blurb),
		"vod_actor":    firstNonEmpty(video.VodActor, video.Actor),
		"vod_director": firstNonEmpty(video.VodDirector, video.Director),
		"vod_play_url": playURL,
	}
}

// maccmsAPIItems 取出 list（或 data）里的条目。
func maccmsAPIItems(payload map[string]any) []map[string]any {
	raw, found := payload["list"]
	if !found {
		raw = payload["data"]
	}
	rows, ok := raw.([]any)
	if !ok {
		return nil
	}
	items := make([]map[string]any, 0, len(rows))
	for _, row := range rows {
		if entry, ok := row.(map[string]any); ok {
			items = append(items, entry)
		}
	}
	return items
}

func maccmsAPIClasses(payload map[string]any) []map[string]any {
	raw, found := payload["class"]
	if !found {
		raw = payload["classlist"]
	}
	rows, ok := raw.([]any)
	if !ok {
		return nil
	}
	items := make([]map[string]any, 0, len(rows))
	for _, row := range rows {
		if entry, ok := row.(map[string]any); ok {
			items = append(items, entry)
		}
	}
	return items
}

func maccmsAPIString(value any) string {
	switch typed := value.(type) {
	case nil:
		return ""
	case string:
		return strings.TrimSpace(typed)
	case float64:
		return strconv.FormatInt(int64(typed), 10)
	case bool:
		if typed {
			return "1"
		}
		return ""
	case json.Number:
		return typed.String()
	}
	return ""
}

func maccmsAPIInt(value any) int {
	text := maccmsAPIString(value)
	if text == "" {
		return 0
	}
	number, err := strconv.Atoi(text)
	if err != nil {
		if parsed, perr := strconv.ParseFloat(text, 64); perr == nil {
			return int(parsed)
		}
		return 0
	}
	return number
}

var maccmsAPITagPattern = regexp.MustCompile(`(?s)<[^>]*>`)

func maccmsAPICleanText(value string) string {
	text := maccmsAPITagPattern.ReplaceAllString(value, " ")
	text = strings.ReplaceAll(text, "&nbsp;", " ")
	text = strings.ReplaceAll(text, "&amp;", "&")
	return strings.TrimSpace(text)
}

// maccmsAPIDrama 把一条 API 记录转成剧集卡片。
func maccmsAPIDrama(source, base string, item map[string]any) (Drama, []Chapter) {
	id := maccmsAPIString(item["vod_id"])
	if id == "" {
		id = maccmsAPIString(item["id"])
	}
	if id == "" || !webProviderNumericID.MatchString(id) {
		return Drama{}, nil
	}
	title := strings.TrimSpace(maccmsAPICleanText(maccmsAPIString(item["vod_name"])))
	if title == "" {
		title = strings.TrimSpace(maccmsAPICleanText(maccmsAPIString(item["name"])))
	}
	if title == "" {
		return Drama{}, nil
	}
	cover := providerCoverAddress(maccmsAPIString(item["vod_pic"]), base+"/")
	if cover == "" {
		cover = providerCoverAddress(maccmsAPIString(item["vod_pic_slide"]), base+"/")
	}
	category := strings.TrimSpace(maccmsAPIString(item["type_name"]))
	if category == "" {
		category = strings.TrimSpace(maccmsAPIString(item["vod_class"]))
	}
	intro := maccmsAPICleanText(maccmsAPIString(item["vod_content"]))
	if intro == "" {
		intro = maccmsAPICleanText(maccmsAPIString(item["vod_blurb"]))
	}
	remarks := strings.TrimSpace(maccmsAPIString(item["vod_remarks"]))
	drama := Drama{
		ID:          providerDramaID(source, id),
		Source:      source,
		SourceID:    id,
		Title:       title,
		Intro:       truncate(intro, 2000),
		Cover:       cover,
		Category:    category,
		ChannelName: duanjuSourceName(source),
		Remark:      remarks,
	}
	chapters := maccmsAPIChapters(source, base, id, item)
	drama.EpisodeCount = json.Number(strconv.Itoa(len(chapters)))
	return drama, chapters
}

type maccmsAPIEpisode struct {
	Title string
	URL   string
}

// maccmsAPIRouteGroups 解析 vod_play_from / vod_play_url：
// 线路之间用 $$$ 分隔，线路内分集用 # 分隔，每集形如「第1集$地址」。
func maccmsAPIRouteGroups(item map[string]any) [][]maccmsAPIEpisode {
	playURL := maccmsAPIString(item["vod_play_url"])
	if playURL == "" {
		playURL = maccmsAPIString(item["vod_url"])
	}
	if playURL == "" {
		return nil
	}
	// 少数老模板用 \r\n 分隔分集，先归一成 #。
	playURL = strings.ReplaceAll(playURL, "\r\n", "#")
	playURL = strings.ReplaceAll(playURL, "\n", "#")
	groups := strings.Split(playURL, "$$$")
	var routes [][]maccmsAPIEpisode
	for _, group := range groups {
		group = strings.TrimSpace(group)
		if group == "" {
			continue
		}
		var episodes []maccmsAPIEpisode
		for _, entry := range strings.Split(group, "#") {
			entry = strings.TrimSpace(entry)
			if entry == "" {
				continue
			}
			name, address := entry, ""
			if index := strings.LastIndex(entry, "$"); index >= 0 {
				name = strings.TrimSpace(entry[:index])
				address = strings.TrimSpace(entry[index+1:])
			}
			address = strings.ReplaceAll(address, `\/`, "/")
			if address == "" {
				continue
			}
			episodes = append(episodes, maccmsAPIEpisode{
				Title: strings.TrimSpace(maccmsAPICleanText(name)),
				URL:   address,
			})
		}
		if len(episodes) > 0 {
			routes = append(routes, episodes)
		}
	}
	return routes
}

// maccmsAPIChapters 选播放线路后取分集。线路优先级对齐 streamhub 的 parsePlayUrl：
// 1) 优先取含 .m3u8 的线路（HLS 直链最稳）；2) 其次含 .mp4 的线路；
// 3) 都没有时退化为「分集最多」，并列取靠前。保证选到的是能直接播放的真链接。
func maccmsAPIChapters(source, base, sourceID string, item map[string]any) []Chapter {
	routes := maccmsAPIRouteGroups(item)
	if len(routes) == 0 {
		return nil
	}
	best := maccmsAPIBestRouteIndex(routes)
	detail := base + "/index.php/vod/detail/id/" + sourceID + ".html"
	chapters := make([]Chapter, 0, len(routes[best]))
	for index, episode := range routes[best] {
		number := duanjuEpisodeNumber(episode.Title, index+1)
		chapters = append(chapters, duanjuChapter(source, sourceID, number, episode.Title, episode.URL, detail, base+"/"))
	}
	sortDuanjuChapters(chapters)
	return chapters
}

// maccmsAPIBestRouteIndex 按 streamhub 的线路优先级挑一条线路下标：
// 先找含 .m3u8 的、再找含 .mp4 的，否则取分集数最多的（并列取靠前）。
func maccmsAPIBestRouteIndex(routes [][]maccmsAPIEpisode) int {
	contains := func(index int, marker string) bool {
		for _, episode := range routes[index] {
			if strings.Contains(strings.ToLower(episode.URL), marker) {
				return true
			}
		}
		return false
	}
	for _, marker := range []string{".m3u8", ".mp4"} {
		for index := range routes {
			if contains(index, marker) {
				return index
			}
		}
	}
	best := 0
	for index, route := range routes {
		if len(route) > len(routes[best]) {
			best = index
		}
	}
	return best
}

// fetchMaccmsAPICategories 取分类（ac=list 或直接取 videolist 带回的 class）。
func (d *Downloader) fetchMaccmsAPICategories(ctx context.Context, endpoint, base string) []nativeCategory {
	var categories []nativeCategory
	var classes []map[string]any
	for _, address := range []string{endpoint + "?ac=list", endpoint + "?ac=videolist&pg=1"} {
		payload, err := d.maccmsAPICall(ctx, address, base+"/")
		if err != nil {
			continue
		}
		if rows := maccmsAPIClasses(payload); len(rows) > 0 {
			classes = rows
			break
		}
	}
	for _, row := range classes {
		id := maccmsAPIString(row["type_id"])
		name := strings.TrimSpace(maccmsAPICleanText(maccmsAPIString(row["type_name"])))
		if id == "" || name == "" {
			continue
		}
		categories = append(categories, nativeCategory{ID: id, Name: name})
	}
	if len(categories) > 0 {
		return categories
	}
	// 很多站点的 ac=list 并不返回 class 数组（实测直接回 videolist）。
	// 退化方案：从列表接口返回的条目里回收 type_id / type_name，够用且稳。
	seen := map[string]bool{}
	for page := 1; page <= 3 && len(seen) < 12; page++ {
		payload, err := d.maccmsAPICall(ctx, endpoint+"?ac=videolist&pg="+strconv.Itoa(page), base+"/")
		if err != nil {
			break
		}
		for _, item := range maccmsAPIItems(payload) {
			id := maccmsAPIString(item["type_id"])
			name := strings.TrimSpace(maccmsAPICleanText(maccmsAPIString(item["type_name"])))
			if id == "" || name == "" || seen[id] {
				continue
			}
			seen[id] = true
			categories = append(categories, nativeCategory{ID: id, Name: name})
		}
	}
	return categories
}

// fetchMaccmsAPICatalog 取目录/分类分页。category 为空表示全部。
func (d *Downloader) fetchMaccmsAPICatalog(ctx context.Context, source, endpoint, base string, page int, category string) ([]Drama, bool, error) {
	if page < 1 {
		page = 1
	}
	query := url.Values{}
	query.Set("ac", "videolist")
	query.Set("pg", strconv.Itoa(page))
	if trimmed := strings.TrimSpace(category); trimmed != "" {
		query.Set("t", trimmed)
	}
	address := endpoint + "?" + query.Encode()
	payload, err := d.maccmsAPICall(ctx, address, base+"/")
	if err != nil {
		return nil, false, err
	}
	return d.maccmsAPICatalogFromPayload(source, base, payload, page)
}

func (d *Downloader) maccmsAPICatalogFromPayload(source, base string, payload map[string]any, page int) ([]Drama, bool, error) {
	items := maccmsAPIItems(payload)
	var dramas []Drama
	for _, item := range items {
		drama, _ := maccmsAPIDrama(source, base, item)
		if drama.ID == "" {
			continue
		}
		dramas = append(dramas, drama)
	}
	if len(dramas) == 0 {
		return nil, false, errMaccmsAPIEmpty
	}
	hasMore := true
	if count := maccmsAPIInt(payload["pagecount"]); count > 0 {
		hasMore = page < count
	}
	return dramas, hasMore, nil
}

// fetchMaccmsAPISearch 用 wd 参数搜索。
func (d *Downloader) fetchMaccmsAPISearch(ctx context.Context, source, endpoint, base, query string) ([]Drama, error) {
	keyword := strings.TrimSpace(query)
	if keyword == "" {
		return nil, nil
	}
	values := url.Values{}
	values.Set("ac", "videolist")
	values.Set("wd", keyword)
	address := endpoint + "?" + values.Encode()
	payload, err := d.maccmsAPICall(ctx, address, base+"/")
	if err == nil {
		dramas, _, convErr := d.maccmsAPICatalogFromPayload(source, base, payload, 1)
		if convErr == nil {
			return dramas, nil
		}
		err = convErr
	}
	// 部分站点把搜索挂在 ac=search 上。
	values.Set("ac", "search")
	address = endpoint + "?" + values.Encode()
	if retry, retryErr := d.maccmsAPICall(ctx, address, base+"/"); retryErr == nil {
		if dramas, _, convErr := d.maccmsAPICatalogFromPayload(source, base, retry, 1); convErr == nil {
			return dramas, nil
		}
	}
	if err == nil {
		err = errMaccmsAPIEmpty
	}
	return nil, err
}

// fetchMaccmsAPIDetail 用 ids 取单部剧；返回剧集与分集（分集地址多为直链）。
func (d *Downloader) fetchMaccmsAPIDetail(ctx context.Context, source, endpoint, base, sourceID string) (Drama, []Chapter, error) {
	addresses := []string{
		endpoint + "?ac=detail&ids=" + url.QueryEscape(sourceID),
		endpoint + "?ac=videolist&ids=" + url.QueryEscape(sourceID),
	}
	var lastErr error
	for _, address := range addresses {
		payload, err := d.maccmsAPICall(ctx, address, base+"/")
		if err != nil {
			lastErr = err
			continue
		}
		for _, item := range maccmsAPIItems(payload) {
			drama, chapters := maccmsAPIDrama(source, base, item)
			if drama.ID == "" {
				continue
			}
			if len(chapters) == 0 {
				lastErr = &maccmsAPIError{"接口未返回分集地址"}
				continue
			}
			return drama, chapters, nil
		}
		lastErr = errMaccmsAPIEmpty
	}
	if lastErr == nil {
		lastErr = &maccmsAPIError{"接口未返回该剧"}
	}
	return Drama{}, nil, lastErr
}

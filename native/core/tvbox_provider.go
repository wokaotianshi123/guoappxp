package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"

	"duanjuapp/native/core/netdisk"
	"duanjuapp/native/core/tvbox"
)

type tvboxProvider struct {
	id     string
	site   tvbox.Site
	spider string
	host   Host
}

func (p *tvboxProvider) Descriptor() SourceDescriptor {
	desc, _ := registeredDescriptor(p.id)
	return desc
}

func (p *tvboxProvider) callSpider(ctx context.Context, action string, params map[string]string, out any) error {
	return p.callSpiderExt(ctx, action, params, nil, out)
}

// callSpiderExt 比 callSpider 多一个 extend：TVBox 的二级筛选值靠它传给 spider。
func (p *tvboxProvider) callSpiderExt(ctx context.Context, action string, params, extend map[string]string, out any) error {
	spiderBridgeMu.RLock()
	port := spiderBridgePort
	spiderBridgeMu.RUnlock()
	if port <= 0 {
		return errors.New("安卓 .jar 插件引擎尚未就绪，请重启应用后再试")
	}
	extStr := ""
	switch v := p.site.Ext.(type) {
	case string:
		extStr = v
	case nil:
	default:
		if b, err := json.Marshal(v); err == nil {
			extStr = string(b)
		}
	}
	reqBody := map[string]string{
		"spider": p.spider,
		"api":    p.site.API,
		"ext":    extStr,
		"action": action,
	}
	for k, v := range params {
		reqBody[k] = v
	}
	if len(extend) > 0 {
		if raw, err := json.Marshal(extend); err == nil {
			reqBody["extend"] = string(raw)
		}
	}
	encoded, err := json.Marshal(reqBody)
	if err != nil {
		return err
	}
	endpoint := fmt.Sprintf("http://127.0.0.1:%d/spider", port)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(string(encoded)))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := webViewLocalClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return err
	}
	var res struct {
		OK    bool   `json:"ok"`
		JSON  string `json:"json"`
		Error string `json:"error"`
	}
	if err := json.Unmarshal(body, &res); err != nil {
		return err
	}
	if !res.OK {
		if res.Error != "" {
			return errors.New(res.Error)
		}
		return errors.New("Spider 插件调用失败")
	}
	trimmed := strings.TrimSpace(res.JSON)
	if trimmed == "" {
		return errors.New("Spider 未返回有效数据")
	}
	return json.Unmarshal([]byte(trimmed), out)
}

func (p *tvboxProvider) getJSON(ctx context.Context, rawURL string, out any) error {
	var raw []byte
	if p.host != nil {
		resp, err := p.host.FetchText(ctx, TextRequest{
			URL:       rawURL,
			UserAgent: "okhttp/3.15",
		})
		if err != nil {
			return err
		}
		raw = []byte(resp.Body)
	} else {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
		if err != nil {
			return err
		}
		req.Header.Set("User-Agent", "okhttp/3.15")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			return err
		}
		defer resp.Body.Close()
		if resp.StatusCode < 200 || resp.StatusCode >= 300 {
			return fmt.Errorf("站源返回 HTTP %d", resp.StatusCode)
		}
		body, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
		if err != nil {
			return err
		}
		raw = body
	}
	trimmed := strings.TrimSpace(string(raw))
	if trimmed == "" || strings.HasPrefix(trimmed, "<") {
		return errors.New("站源返回非 JSON 内容（可能已失效或被拦截）")
	}
	return json.Unmarshal([]byte(trimmed), out)
}

func (p *tvboxProvider) buildAPIURL(params url.Values) (string, error) {
	u, err := url.Parse(strings.TrimSpace(p.site.API))
	if err != nil {
		return "", err
	}
	q := u.Query()
	if p.site.Type == 4 {
		if ext, ok := p.site.Ext.(string); ok && strings.TrimSpace(ext) != "" && q.Get("extend") == "" {
			q.Set("extend", strings.TrimSpace(ext))
		}
	}
	for k, vals := range params {
		for _, v := range vals {
			q.Set(k, v)
		}
	}
	u.RawQuery = q.Encode()
	return u.String(), nil
}

type tvboxVodItem struct {
	ID             any    `json:"vod_id"`
	Name           string `json:"vod_name"`
	Pic            string `json:"vod_pic"`
	Remarks        string `json:"vod_remarks"`
	TypeName       string `json:"type_name"`
	Content        string `json:"vod_content"`
	Year           string `json:"vod_year"`
	Area           string `json:"vod_area"`
	PlayFrom       string `json:"vod_play_from"`
	PlayURL        string `json:"vod_play_url"`
	VodDirector    string `json:"vod_director"`
	VodActor       string `json:"vod_actor"`
	VodScore       any    `json:"vod_score"`
	VodDoubanScore any    `json:"vod_douban_score"`
}

var tvboxHTMLTagPattern = regexp.MustCompile(`<[^>]+>`)

func cleanTVBoxText(raw string) string {
	if strings.TrimSpace(raw) == "" {
		return ""
	}
	replacer := strings.NewReplacer(
		"<br>", "\n",
		"<br/>", "\n",
		"<br />", "\n",
		"</p>", "\n",
		"&nbsp;", " ",
		"&amp;", "&",
		"&lt;", "<",
		"&gt;", ">",
		"&quot;", `"`,
		"&#39;", "'",
	)
	text := replacer.Replace(raw)
	text = tvboxHTMLTagPattern.ReplaceAllString(text, " ")
	lines := strings.Split(text, "\n")
	cleaned := make([]string, 0, len(lines))
	for _, line := range lines {
		fields := strings.Fields(line)
		if len(fields) > 0 {
			cleaned = append(cleaned, strings.Join(fields, " "))
		}
	}
	return strings.Join(cleaned, "\n")
}

func tvboxScoreString(v any) string {
	switch val := v.(type) {
	case float64:
		if val > 0 && val <= 10 {
			return strconv.FormatFloat(val, 'f', 1, 64)
		}
		return ""
	case int:
		if val > 0 && val <= 10 {
			return strconv.Itoa(val) + ".0"
		}
		return ""
	case int64:
		if val > 0 && val <= 10 {
			return strconv.FormatInt(val, 10) + ".0"
		}
		return ""
	case string:
		return NativeDramaScore(val)
	default:
		return ""
	}
}

type tvboxResponse struct {
	Code      any `json:"code"`
	Page      any `json:"page"`
	PageCount any `json:"pagecount"`
	Class     []struct {
		TypeID   any    `json:"type_id"`
		TypeName string `json:"type_name"`
	} `json:"class"`
	Filters map[string][]struct {
		Key   string `json:"key"`
		Name  string `json:"name"`
		Value []struct {
			N string `json:"n"`
			V string `json:"v"`
		} `json:"value"`
	} `json:"filters"`
	List []tvboxVodItem `json:"list"`
}

func anyToString(v any) string {
	switch val := v.(type) {
	case string:
		return strings.TrimSpace(val)
	case float64:
		return strconv.FormatInt(int64(val), 10)
	case int:
		return strconv.Itoa(val)
	case int64:
		return strconv.FormatInt(val, 10)
	default:
		return ""
	}
}

func anyToInt(v any) int {
	switch val := v.(type) {
	case float64:
		return int(val)
	case int:
		return val
	case int64:
		return int(val)
	case string:
		n, _ := strconv.Atoi(strings.TrimSpace(val))
		return n
	default:
		return 0
	}
}

func (p *tvboxProvider) Categories(ctx context.Context, _ bool) ([]Category, error) {
	var resp tvboxResponse
	if p.site.Kind == tvbox.KindJar {
		if err := p.callSpider(ctx, "home", nil, &resp); err != nil {
			return nil, err
		}
	} else {
		q := url.Values{"ac": {"list"}}
		u, err := p.buildAPIURL(q)
		if err != nil {
			return nil, err
		}
		if err := p.getJSON(ctx, u, &resp); err != nil {
			return nil, err
		}
		if len(resp.Class) == 0 {
			if homeURL, homeErr := p.buildAPIURL(url.Values{}); homeErr == nil {
				var homeResp tvboxResponse
				if p.getJSON(ctx, homeURL, &homeResp) == nil && len(homeResp.Class) > 0 {
					resp.Class = homeResp.Class
				}
			}
		}
	}
	cats := []Category{{ID: "", Name: "全部"}}
	seen := map[string]bool{"": true}
	for _, c := range resp.Class {
		id := anyToString(c.TypeID)
		name := strings.TrimSpace(c.TypeName)
		if id == "" || name == "" || seen[id] {
			continue
		}
		seen[id] = true
		cats = append(cats, Category{ID: id, Name: name})
	}
	return cats, nil
}

// CategoryFilters 返回每个分类的二级筛选项（TVBox 配置里的 filters 字段）。
func (p *tvboxProvider) CategoryFilters(ctx context.Context) (map[string][]CategoryFilter, error) {
	var resp tvboxResponse
	if p.site.Kind == tvbox.KindJar {
		if err := p.callSpider(ctx, "home", nil, &resp); err != nil {
			return nil, err
		}
	} else {
		q := url.Values{"ac": {"list"}}
		u, err := p.buildAPIURL(q)
		if err != nil {
			return nil, err
		}
		if err := p.getJSON(ctx, u, &resp); err != nil {
			return nil, err
		}
	}
	out := make(map[string][]CategoryFilter, len(resp.Filters))
	for tid, groups := range resp.Filters {
		list := make([]CategoryFilter, 0, len(groups))
		for _, group := range groups {
			items := make([]CategoryFilterItem, 0, len(group.Value))
			for _, item := range group.Value {
				items = append(items, CategoryFilterItem{Name: item.N, Value: item.V})
			}
			if group.Key == "" || len(items) == 0 {
				continue
			}
			list = append(list, CategoryFilter{Key: group.Key, Name: group.Name, Values: items})
		}
		if len(list) > 0 {
			out[tid] = list
		}
	}
	return out, nil
}

func (p *tvboxProvider) toDramas(items []tvboxVodItem) []Drama {
	out := make([]Drama, 0, len(items))
	for _, item := range items {
		vodID := anyToString(item.ID)
		if vodID == "" {
			continue
		}
		badge := strings.TrimSpace(item.Remarks)
		score := tvboxScoreString(item.VodScore)
		if score == "" {
			score = tvboxScoreString(item.VodDoubanScore)
		}
		out = append(out, Drama{
			ID:         p.id + ":" + vodID,
			Source:     p.id,
			SourceID:   vodID,
			Title:      strings.TrimSpace(item.Name),
			Cover:      strings.TrimSpace(item.Pic),
			Desc:       cleanTVBoxText(item.Content),
			Category:   strings.TrimSpace(item.TypeName),
			Score:      score,
			Badge:      badge,
			OnlineDate: strings.TrimSpace(item.Year),
		})
	}
	return out
}

func (p *tvboxProvider) CatalogPage(ctx context.Context, page int, category string) ([]Drama, bool, error) {
	return p.CatalogPageFiltered(ctx, page, category, nil)
}

// CatalogPageFiltered 带上二级筛选（extend）请求列表，TVBox 的筛选值就是这么传的。
func (p *tvboxProvider) CatalogPageFiltered(ctx context.Context, page int, category string, extend map[string]string) ([]Drama, bool, error) {
	if page < 1 {
		page = 1
	}
	cat := strings.TrimSpace(category)
	var resp tvboxResponse
	if p.site.Kind == tvbox.KindJar {
		if cat == "" || cat == "all" {
			if err := p.callSpider(ctx, "home", nil, &resp); err != nil {
				return nil, false, err
			}
			// 很多 jar 站的首页只给 class/filters，没有推荐列表；这时按第一个分类
			// 拉一页，否则「全部」永远是空白。
			if len(resp.List) == 0 && len(resp.Class) > 0 {
				if first := anyToString(resp.Class[0].TypeID); first != "" {
					var catResp tvboxResponse
					if err := p.callSpider(ctx, "category", map[string]string{"tid": first, "pg": strconv.Itoa(page)}, &catResp); err == nil && len(catResp.List) > 0 {
						resp = catResp
					}
				}
			}
			dramas := p.toDramas(resp.List)
			return dramas, false, nil
		}
		if err := p.callSpiderExt(ctx, "category", map[string]string{"tid": cat, "pg": strconv.Itoa(page)}, extend, &resp); err != nil {
			return nil, false, err
		}
		dramas := p.toDramas(resp.List)
		pageCount := anyToInt(resp.PageCount)
		hasMore := pageCount > page || (pageCount == 0 && len(dramas) >= 15)
		return dramas, hasMore, nil
	}
	q := url.Values{
		"ac": {"detail"},
		"pg": {strconv.Itoa(page)},
	}
	if cat != "" && cat != "all" {
		q.Set("t", cat)
	}
	u, err := p.buildAPIURL(q)
	if err != nil {
		return nil, false, err
	}
	if err := p.getJSON(ctx, u, &resp); err != nil {
		return nil, false, err
	}
	if len(resp.List) == 0 && page == 1 && (cat == "" || cat == "all") {
		if homeURL, homeErr := p.buildAPIURL(url.Values{}); homeErr == nil {
			var homeResp tvboxResponse
			if p.getJSON(ctx, homeURL, &homeResp) == nil && len(homeResp.List) > 0 {
				resp = homeResp
			}
		}
	}
	dramas := p.toDramas(resp.List)
	pageCount := anyToInt(resp.PageCount)
	hasMore := pageCount > page || (pageCount == 0 && len(dramas) >= 20)
	return dramas, hasMore, nil
}

func (p *tvboxProvider) Search(ctx context.Context, page int, query string) ([]Drama, bool, error) {
	if page < 1 {
		page = 1
	}
	var resp tvboxResponse
	if p.site.Kind == tvbox.KindJar {
		if err := p.callSpider(ctx, "search", map[string]string{"wd": strings.TrimSpace(query), "pg": strconv.Itoa(page)}, &resp); err != nil {
			return nil, false, err
		}
		dramas := p.toDramas(resp.List)
		pageCount := anyToInt(resp.PageCount)
		hasMore := pageCount > page || (pageCount == 0 && len(dramas) >= 15)
		return dramas, hasMore, nil
	}
	q := url.Values{
		"ac": {"detail"},
		"wd": {strings.TrimSpace(query)},
		"pg": {strconv.Itoa(page)},
	}
	u, err := p.buildAPIURL(q)
	if err != nil {
		return nil, false, err
	}
	if err := p.getJSON(ctx, u, &resp); err != nil {
		return nil, false, err
	}
	dramas := p.toDramas(resp.List)
	pageCount := anyToInt(resp.PageCount)
	hasMore := pageCount > page || (pageCount == 0 && len(dramas) >= 20)
	return dramas, hasMore, nil
}

func tvboxTagsFromItem(item tvboxVodItem) []string {
	tags := make([]string, 0, 8)
	seen := map[string]bool{}
	add := func(raw string) {
		val := strings.TrimSpace(raw)
		if val == "" || seen[val] || len(tags) >= 12 {
			return
		}
		seen[val] = true
		tags = append(tags, val)
	}
	add(item.Year)
	add(item.Area)
	add(item.TypeName)
	for _, director := range strings.FieldsFunc(item.VodDirector, func(r rune) bool { return r == ',' || r == '，' || r == '/' }) {
		if trimmed := strings.TrimSpace(director); trimmed != "" {
			add("导演 " + trimmed)
		}
	}
	for _, actor := range strings.FieldsFunc(item.VodActor, func(r rune) bool { return r == ',' || r == '，' || r == '/' }) {
		if trimmed := strings.TrimSpace(actor); trimmed != "" {
			add(trimmed)
		}
	}
	return tags
}

// tvboxSearchKeyword 从 TVBox 的"搜索型" vod_id 里取关键词：msearch:###关键词###海报
func tvboxSearchKeyword(id string) string {
	if !strings.HasPrefix(id, "msearch:###") {
		return ""
	}
	rest := strings.TrimPrefix(id, "msearch:###")
	if i := strings.Index(rest, "###"); i > 0 {
		return strings.TrimSpace(rest[:i])
	}
	return ""
}

func (p *tvboxProvider) Detail(ctx context.Context, sourceID string) (Drama, []Chapter, error) {
	var resp tvboxResponse
	if p.site.Kind == tvbox.KindJar {
		id := strings.TrimSpace(sourceID)
		// 搜索型条目把关键词塞在 vod_id 里（msearch:###关键词###海报），
		// detailContent 对它是空的，得先按关键词搜一次拿真实 id。
		if kw := tvboxSearchKeyword(id); kw != "" {
			var searchResp tvboxResponse
			if err := p.callSpider(ctx, "search", map[string]string{"wd": kw, "pg": "1"}, &searchResp); err == nil && len(searchResp.List) > 0 {
				if real := anyToString(searchResp.List[0].ID); real != "" {
					id = real
				}
			}
		}
		if err := p.callSpider(ctx, "detail", map[string]string{"id": id}, &resp); err != nil {
			return Drama{}, nil, err
		}
		sourceID = id
	} else {
		q := url.Values{
			"ac":  {"detail"},
			"ids": {strings.TrimSpace(sourceID)},
		}
		u, err := p.buildAPIURL(q)
		if err != nil {
			return Drama{}, nil, err
		}
		if err := p.getJSON(ctx, u, &resp); err != nil {
			return Drama{}, nil, err
		}
	}
	if len(resp.List) == 0 {
		return Drama{}, nil, errors.New("未找到影片详情")
	}
	item := resp.List[0]
	score := tvboxScoreString(item.VodScore)
	if score == "" {
		score = tvboxScoreString(item.VodDoubanScore)
	}
	drama := Drama{
		ID:         p.id + ":" + sourceID,
		Source:     p.id,
		SourceID:   sourceID,
		Title:      strings.TrimSpace(item.Name),
		Cover:      strings.TrimSpace(item.Pic),
		Desc:       cleanTVBoxText(item.Content),
		Category:   strings.TrimSpace(item.TypeName),
		Score:      score,
		Badge:      strings.TrimSpace(item.Remarks),
		OnlineDate: strings.TrimSpace(item.Year),
		Tags:       tvboxTagsFromItem(item),
	}

	routes := strings.Split(item.PlayFrom, "$$$")
	urlGroups := strings.Split(item.PlayURL, "$$$")
	chapters := make([]Chapter, 0)
	epIndex := 0
	// 同名线路要合并/去重：TVBox 订阅里常见两条都叫「线路1」，直接并列会让
	// 用户在选集里看到两个一模一样的标题、集数还混在一起。这里给重名的追加序号，
	// 空线路名补「线路 N」，与 GoMovie 的处理一致。
	seenRoutes := make(map[string]int, len(urlGroups))

	for rIdx, group := range urlGroups {
		routeName := ""
		if rIdx < len(routes) {
			routeName = strings.TrimSpace(routes[rIdx])
		}
		if routeName == "" {
			routeName = fmt.Sprintf("线路 %d", rIdx+1)
		}
		if count := seenRoutes[routeName]; count > 0 {
			routeName = fmt.Sprintf("%s (%d)", routeName, count+1)
		}
		seenRoutes[routeName]++
		rawEntries := strings.Split(group, "#")
		entries := make([]string, 0, len(rawEntries))
		for _, e := range rawEntries {
			if strings.TrimSpace(e) != "" {
				entries = append(entries, e)
			}
		}
		if len(entries) == 1 {
			_, rawLink := parseEpisodeEntry(entries[0], "正片")
			if shareURL := netdisk.ExtractShareURL(rawLink); shareURL != "" {
				// 夸克与 UC 分享都自动展开成网盘里的真实文件列表。
				if provider := netdisk.DetectProvider(shareURL); provider == "quark" || provider == "uc" {
					if expanded, ok := p.expandNetdiskShare(ctx, drama.ID, routeName, provider, shareURL, &epIndex); ok {
						chapters = append(chapters, expanded...)
						continue
					}
				}
			}
		}

		for _, entry := range entries {
			epName, rawLink := parseEpisodeEntry(entry, fmt.Sprintf("第 %d 集", epIndex+1))
			if rawLink == "" {
				continue
			}
			if len(urlGroups) > 1 {
				epName = routeName + " · " + epName
			}
			videoRef := rawLink
			if shareURL := netdisk.ExtractShareURL(rawLink); shareURL != "" {
				videoRef = encodeNetdiskVideoRef(0, shareURL)
			} else if p.site.Kind == tvbox.KindJar {
				videoRef = "spider:" + url.QueryEscape(routeName) + "|" + rawLink
			} else if before, _, ok := strings.Cut(rawLink, "$"); ok && (strings.HasPrefix(strings.ToLower(before), "http://") || strings.HasPrefix(strings.ToLower(before), "https://")) {
				videoRef = strings.TrimSpace(before)
			}
			epIndex++
			epNum, _ := json.Marshal(epIndex)
			chapters = append(chapters, Chapter{
				ID:             fmt.Sprintf("%s#%d", drama.ID, epIndex),
				Source:         p.id,
				Title:          epName,
				VideoURL:       videoRef,
				CurrentEpisode: epNum,
			})
		}
	}
	return drama, chapters, nil
}

func (p *tvboxProvider) expandNetdiskShare(ctx context.Context, dramaID, routeName, provider, shareURL string, epIndex *int) ([]Chapter, bool) {
	netdiskMu.Lock()
	rt := netdiskRT
	netdiskMu.Unlock()
	var creds *netdisk.Credentials
	if rt != nil && rt.store != nil {
		creds, _ = rt.store.Get(netdisk.NormalizeProvider(provider))
	}
	var info *netdisk.ShareInfo
	var err error
	if netdisk.NormalizeProvider(provider) == "uc" {
		info, err = netdisk.NewUC(creds).Share(ctx, shareURL)
	} else {
		info, err = netdisk.NewQuark(creds).Share(ctx, shareURL)
	}
	if err != nil || len(info.Episodes) == 0 {
		return nil, false
	}
	out := make([]Chapter, 0, len(info.Episodes))
	for i, ep := range info.Episodes {
		*epIndex++
		// 直接展示网盘原文件名，用户能对上自己网盘里的文件。
		title := strings.TrimSpace(ep.Name)
		if title == "" {
			title = fmt.Sprintf("文件 %d", i+1)
		}
		if sizeText := formatNetdiskSize(ep.Size); sizeText != "" {
			title += " · " + sizeText
		}
		if routeName != "" {
			title = routeName + " · " + title
		}
		epNum, _ := json.Marshal(*epIndex)
		out = append(out, Chapter{
			ID:             fmt.Sprintf("%s#%d", dramaID, *epIndex),
			Source:         p.id,
			Title:          title,
			VideoURL:       encodeNetdiskVideoRef(i, shareURL),
			CurrentEpisode: epNum,
			MediaSize:      ep.Size,
		})
	}
	return out, true
}

func parseEpisodeEntry(entry, fallbackName string) (string, string) {
	trimmed := strings.TrimSpace(entry)
	if trimmed == "" {
		return "", ""
	}
	if name, link, ok := strings.Cut(trimmed, "$"); ok {
		name = strings.TrimSpace(name)
		link = strings.TrimSpace(link)
		if name == "" {
			name = fallbackName
		}
		return name, link
	}
	return fallbackName, trimmed
}

func isDirectMediaURL(raw string) bool {
	lower := strings.ToLower(strings.TrimSpace(raw))
	if !strings.HasPrefix(lower, "http://") && !strings.HasPrefix(lower, "https://") {
		return false
	}
	parsed, err := url.Parse(raw)
	if err != nil {
		return false
	}
	p := strings.ToLower(parsed.Path)
	return strings.HasSuffix(p, ".m3u8") ||
		strings.HasSuffix(p, ".mp4") ||
		strings.HasSuffix(p, ".flv") ||
		strings.HasSuffix(p, ".mkv")
}

func parseTVBoxHeaderMap(raw any) map[string]string {
	out := map[string]string{}
	switch v := raw.(type) {
	case map[string]any:
		for k, val := range v {
			if s := strings.TrimSpace(anyToStringOrText(val)); s != "" {
				out[k] = s
			}
		}
	case string:
		var decoded map[string]any
		if json.Unmarshal([]byte(v), &decoded) == nil {
			for k, val := range decoded {
				if s := strings.TrimSpace(anyToStringOrText(val)); s != "" {
					out[k] = s
				}
			}
		}
	}
	return out
}

func anyToStringOrText(v any) string {
	if s, ok := v.(string); ok {
		return s
	}
	return anyToString(v)
}

func (p *tvboxProvider) ResolveMedia(ctx context.Context, task Task) (ProviderMedia, error) {
	raw := strings.TrimSpace(task.Chapter.VideoURL)
	if raw == "" {
		return ProviderMedia{}, errors.New("该集缺少播放地址")
	}
	if _, _, isNetdisk := decodeNetdiskVideoRef(raw); isNetdisk {
		return resolveNetdiskMedia(ctx, raw)
	}
	if strings.HasPrefix(raw, "spider:") {
		rest := strings.TrimPrefix(raw, "spider:")
		encodedFlag, id, _ := strings.Cut(rest, "|")
		flag, _ := url.QueryUnescape(encodedFlag)
		var playResp struct {
			URL     string `json:"url"`
			Header  any    `json:"header"`
			Headers any    `json:"headers"`
		}
		if err := p.callSpider(ctx, "player", map[string]string{"flag": flag, "id": id}, &playResp); err != nil {
			return ProviderMedia{}, err
		}
		resolved := strings.TrimSpace(playResp.URL)
		if _, _, isNetdisk := decodeNetdiskVideoRef(resolved); isNetdisk {
			return resolveNetdiskMedia(ctx, resolved)
		}
		if resolved == "" {
			return ProviderMedia{}, errors.New("Spider 未返回有效播放地址")
		}
		hdrs := parseTVBoxHeaderMap(playResp.Header)
		if len(hdrs) == 0 {
			hdrs = parseTVBoxHeaderMap(playResp.Headers)
		}
		referer, ua, cookie := "", "", ""
		for k, v := range hdrs {
			switch strings.ToLower(strings.TrimSpace(k)) {
			case "referer":
				referer = v
			case "user-agent":
				ua = v
			case "cookie":
				cookie = v
			}
		}
		media := ProviderMedia{URL: resolved, Referer: referer}
		if ua != "" || cookie != "" || referer != "" {
			parsed, _ := url.Parse(resolved)
			media.Credentials = &MediaCredentials{
				Cookie:    cookie,
				Origin:    ProviderMediaOrigin(parsed),
				Referer:   referer,
				UserAgent: ua,
			}
		}
		return media, nil
	}
	if p.site.Type == 4 && !isDirectMediaURL(raw) {
		playURL, buildErr := p.buildAPIURL(url.Values{"play": {raw}})
		if buildErr == nil {
			var playResp struct {
				URL     string `json:"url"`
				Header  any    `json:"header"`
				Headers any    `json:"headers"`
			}
			getErr := p.getJSON(ctx, playURL, &playResp)
			if getErr == nil {
				resolved := strings.TrimSpace(playResp.URL)
				if _, _, isNetdisk := decodeNetdiskVideoRef(resolved); isNetdisk {
					return resolveNetdiskMedia(ctx, resolved)
				}
				if strings.HasPrefix(strings.ToLower(resolved), "http://") || strings.HasPrefix(strings.ToLower(resolved), "https://") {
					hdrs := parseTVBoxHeaderMap(playResp.Header)
					if len(hdrs) == 0 {
						hdrs = parseTVBoxHeaderMap(playResp.Headers)
					}
					referer := p.site.API
					ua := ""
					cookie := ""
					for k, v := range hdrs {
						switch strings.ToLower(strings.TrimSpace(k)) {
						case "referer":
							referer = v
						case "user-agent":
							ua = v
						case "cookie":
							cookie = v
						}
					}
					media := ProviderMedia{
						URL:     resolved,
						Referer: referer,
					}
					if ua != "" || cookie != "" {
						parsed, _ := url.Parse(resolved)
						media.Credentials = &MediaCredentials{
							Cookie:    cookie,
							Origin:    ProviderMediaOrigin(parsed),
							Referer:   referer,
							UserAgent: ua,
						}
					}
					return media, nil
				}
			}
			lowerRaw := strings.ToLower(raw)
			if !strings.HasPrefix(lowerRaw, "http://") && !strings.HasPrefix(lowerRaw, "https://") {
				if getErr != nil {
					return ProviderMedia{}, getErr
				}
				return ProviderMedia{}, errors.New("T4 解析接口未返回有效播放地址")
			}
		}
	}
	return ProviderMedia{
		URL:     raw,
		Referer: p.site.API,
	}, nil
}

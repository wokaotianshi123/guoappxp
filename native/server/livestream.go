package main

import (
	"bufio"
	"bytes"
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// 直播（Web 服务器版）。内置源与 App 端 lib/live_sources.dart 保持一致；
// 上游请求全部由本机服务端代发（liveSession），浏览器只访问 /api/livestream/*，
// 这样 Cookie、UA、Referer 等取流头都不需要暴露给前端，也绕开跨域限制。

const (
	liveMaxBytes       = 8 << 20
	liveRequestTimeout = 14 * time.Second
	liveUserAgentValue = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
		"(KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36"
	liveUnsortedGroupName = "其他"
)

// 与 App 端 LiveProtocol 对应。
const (
	liveProtocolPingtai = "pingtai"
	liveProtocolList    = "list"
	liveProtocolRoom    = "room"
)

type liveSourceDef struct {
	ID          string            `json:"id"`
	Name        string            `json:"name"`
	Description string            `json:"description"`
	Protocol    string            `json:"protocol"`
	Endpoints   []string          `json:"endpoints"`
	Headers     map[string]string `json:"headers"`
	Proxies     []string          `json:"proxies"`
	Group       string            `json:"group"`
	Adult       bool              `json:"adult"`
	Builtin     bool              `json:"builtin"`
}

// 内置直播源，与 lib/live/live_sources.dart 的 LiveSource.values 保持一致：
// 默认斗鱼，其次哔哩哔哩、虎牙，秀果直播（adult）排在最后并在绿色模式下整源隐藏。
var builtinLiveSources = []liveSourceDef{
	{
		ID: "douyu", Name: "斗鱼", Description: "游戏 · 娱乐 · 赛事",
		Protocol:  liveProtocolRoom,
		Endpoints: []string{"https://www.douyu.com"},
		Builtin:   true,
	},
	{
		ID: "bilibili", Name: "哔哩哔哩", Description: "游戏 · 娱乐 · 赛事",
		Protocol:  liveProtocolRoom,
		Endpoints: []string{"https://live.bilibili.com"},
		Builtin:   true,
	},
	{
		ID: "huya", Name: "虎牙", Description: "游戏 · 娱乐 · 赛事",
		Protocol:  liveProtocolRoom,
		Endpoints: []string{"https://www.huya.com"},
		Builtin:   true,
	},
	{
		ID: "xiuguo", Name: "秀果直播", Description: "主播直播 · 实时开播",
		Protocol: liveProtocolPingtai,
		Endpoints: []string{
			"http://api.vipmisss.com:81/xcdsw",
			"http://api.hclyz.com:81/mf",
		},
		Adult: true, Builtin: true,
	},
}

// 绿色模式放行的直播分类（与 App 端 _greenCategory 正则一致）。
var liveGreenCategory = regexp.MustCompile(`(?i)(卫视|央视|CCTV|CGTN|电视直播|广播|新闻|体育|财经|少儿|纪录|地方台|剧场|电影|电视剧)`)

// 已失效分类（与 App 端 LiveRepository.retiredCategories 一致）。
var liveRetiredCategories = []string{"weishizhibo"}

var liveCCTV = regexp.MustCompile(`(?i)^(cctv|央视|中央电视台)`)

var livePlayableScheme = map[string]bool{
	"http": true, "https": true, "rtmp": true, "rtsp": true, "rtp": true,
	"udp": true, "rtmps": true, "rtmpe": true, "rtmpt": true,
}

func liveURLUsable(raw string) bool {
	text := strings.TrimSpace(raw)
	at := strings.Index(text, "://")
	if at < 0 {
		return false
	}
	return livePlayableScheme[strings.ToLower(text[:at])]
}

// —— 自定义直播源（m3u / 列表 txt / 接口 json），持久化在数据目录 ——

const liveSourcesFile = "live-sources.json"

var (
	liveSourcesMu   sync.Mutex
	liveSourcesPath string
)

func setLiveWebDirectory(directory string) {
	liveSourcesMu.Lock()
	liveSourcesPath = filepath.Join(directory, liveSourcesFile)
	liveSourcesMu.Unlock()
}

func loadLiveCustomSources() []liveSourceDef {
	liveSourcesMu.Lock()
	path := liveSourcesPath
	liveSourcesMu.Unlock()
	if path == "" {
		return nil
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var parsed []liveSourceDef
	if json.Unmarshal(raw, &parsed) != nil {
		return nil
	}
	var result []liveSourceDef
	for _, item := range parsed {
		if strings.TrimSpace(item.ID) == "" || len(item.Endpoints) == 0 || strings.TrimSpace(item.Endpoints[0]) == "" {
			continue
		}
		item.Builtin = false
		result = append(result, item)
	}
	return result
}

func saveLiveCustomSources(items []liveSourceDef) error {
	liveSourcesMu.Lock()
	defer liveSourcesMu.Unlock()
	if liveSourcesPath == "" {
		return errors.New("数据目录未就绪")
	}
	encoded, err := json.MarshalIndent(items, "", "  ")
	if err != nil {
		return err
	}
	temporary := liveSourcesPath + ".tmp"
	if err := os.WriteFile(temporary, encoded, 0o644); err != nil {
		return err
	}
	return os.Rename(temporary, liveSourcesPath)
}

func allLiveSources() []liveSourceDef {
	return append(append([]liveSourceDef{}, builtinLiveSources...), loadLiveCustomSources()...)
}

func findLiveSource(id string) (liveSourceDef, bool) {
	for _, item := range allLiveSources() {
		if item.ID == id {
			return item, true
		}
	}
	return liveSourceDef{}, false
}

func liveSourceSafeName(name string) bool {
	trimmed := strings.TrimSpace(name)
	if trimmed == "" || len([]rune(trimmed)) > 40 {
		return false
	}
	// 禁止把分隔符写进源名，防止 key 注入。
	return !strings.ContainsAny(trimmed, "/\\,#\u0000")
}

// —— 上游会话：Cookie 保持与 Dart LiveHttp._rememberCookies 同构 ——

type liveSession struct {
	mu      sync.Mutex
	cookies map[string]string
}

func newLiveSession() *liveSession {
	return &liveSession{cookies: map[string]string{}}
}

func (session *liveSession) cookieHeader() string {
	session.mu.Lock()
	defer session.mu.Unlock()
	parts := make([]string, 0, len(session.cookies))
	for name, value := range session.cookies {
		parts = append(parts, name+"="+value)
	}
	return strings.Join(parts, "; ")
}

func (session *liveSession) remember(response *http.Response) {
	for _, value := range response.Header.Values("Set-Cookie") {
		at := strings.Index(value, "=")
		if at <= 0 {
			continue
		}
		name := strings.TrimSpace(value[:at])
		if name == "" {
			continue
		}
		raw := value[at+1:]
		if semi := strings.Index(raw, ";"); semi >= 0 {
			raw = raw[:semi]
		}
		session.mu.Lock()
		session.cookies[name] = strings.TrimSpace(raw)
		session.mu.Unlock()
	}
}

func (session *liveSession) request(target string, method string, body []byte, headers map[string]string) ([]byte, error) {
	payload, _, err := session.requestWithHeaders(target, method, body, headers)
	return payload, err
}

// requestWithHeaders 与 request 相同，额外把响应头交给调用方：斗鱼签名要用
// 响应 Date 计算时间戳（本机时钟偏差会让 auth 校验失败）。
func (session *liveSession) requestWithHeaders(target string, method string, body []byte, headers map[string]string) ([]byte, http.Header, error) {
	client := &http.Client{Transport: localTransport, Timeout: liveRequestTimeout}
	var reader io.Reader
	if body != nil {
		reader = bytes.NewReader(body)
	}
	request, err := http.NewRequest(method, target, reader)
	if err != nil {
		return nil, nil, errors.New("直播源地址无效")
	}
	request.Header.Set("User-Agent", liveUserAgentValue)
	if cookie := session.cookieHeader(); cookie != "" {
		request.Header.Set("Cookie", cookie)
	}
	for name, value := range headers {
		trimmed := strings.TrimSpace(value)
		lower := strings.ToLower(name)
		if trimmed == "" || lower == "user-agent" || lower == "cookie" {
			continue
		}
		request.Header.Set(name, trimmed)
	}
	if method == http.MethodPost && request.Header.Get("Content-Type") == "" {
		request.Header.Set("Content-Type", "application/x-www-form-urlencoded; charset=UTF-8")
	}
	response, err := client.Do(request)
	if err != nil {
		return nil, nil, errors.New("无法连接直播源")
	}
	defer response.Body.Close()
	session.remember(response)
	if response.StatusCode != http.StatusOK {
		return nil, nil, errors.New("直播源返回 " + strconv.Itoa(response.StatusCode))
	}
	payload, err := io.ReadAll(io.LimitReader(response.Body, liveMaxBytes+1))
	if err != nil {
		return nil, nil, errors.New("直播源读取失败")
	}
	if len(payload) > liveMaxBytes {
		return nil, nil, errors.New("直播源返回的数据过大")
	}
	return payload, response.Header, nil
}

func (session *liveSession) get(target string, headers map[string]string) (string, error) {
	payload, err := session.request(target, http.MethodGet, nil, headers)
	if err != nil {
		return "", err
	}
	return string(payload), nil
}

// —— 解析：与 App 端 LiveParser 对齐（m3u / 列表 txt / json）——

type liveChannelOut struct {
	Name    string            `json:"name"`
	URLs    []string          `json:"urls"`
	Logo    string            `json:"logo"`
	Number  string            `json:"number"`
	Group   string            `json:"group"`
	Headers map[string]string `json:"headers"`
	// 房间型源（斗鱼 / 哔哩哔哩 / 虎牙）只下发房间号，点播时再换取真实地址。
	Token    string `json:"token,omitempty"`
	Subtitle string `json:"subtitle,omitempty"`
}

type liveGroupOut struct {
	Name     string           `json:"name"`
	Channels []liveChannelOut `json:"channels"`
}

func liveAttr(line string, key string) string {
	pattern := regexp.MustCompile(`(?i)` + regexp.QuoteMeta(key) + `="(.*?)"`)
	if match := pattern.FindStringSubmatch(line); match != nil {
		return strings.TrimSpace(match[1])
	}
	return ""
}

var liveDirective = regexp.MustCompile(`^(ua|parse|click|header|format|origin|referer|forceKey|#EXTHTTP:|#EXTVLCOPT:|#KODIPROP:)`)
var liveGenre = regexp.MustCompile(`#genre#`)
var liveM3UHeader = regexp.MustCompile(`(?i)#EXTM3U`)

type liveSetter struct {
	header map[string]string
}

func (setter *liveSetter) read(raw string) {
	for _, pair := range strings.Split(raw, "|") {
		pair = strings.TrimSpace(pair)
		if pair == "" {
			continue
		}
		// 与 Dart 端 _Setters.readHeader 一致：只吸收 name=value 形态。
		if eq := strings.Index(pair, "="); eq > 0 {
			name := strings.TrimSpace(pair[:eq])
			value := strings.TrimSpace(pair[eq+1:])
			if name != "" && value != "" {
				if setter.header == nil {
					setter.header = map[string]string{}
				}
				setter.header[name] = value
			}
		}
	}
}

func (setter *liveSetter) clear() { setter.header = nil }

var liveMetaPrefixes = []string{"更新时间", "更新日期", "update time", "update date", "last update"}

func liveIsMetaChannel(name string) bool {
	lower := strings.ToLower(strings.TrimSpace(name))
	if lower == "" {
		return false
	}
	for _, prefix := range liveMetaPrefixes {
		if strings.HasPrefix(lower, strings.ToLower(prefix)) {
			return true
		}
	}
	return false
}

type liveChannelBuilder struct {
	name    string
	group   string
	urls    []string
	headers map[string]string
	logo    string
	number  string
}

type liveGroupBuilder struct {
	name   string
	order  []*liveChannelBuilder
	byName map[string]*liveChannelBuilder
}

func newLiveGroupBuilder(name string) *liveGroupBuilder {
	return &liveGroupBuilder{name: name, byName: map[string]*liveChannelBuilder{}}
}

func (group *liveGroupBuilder) channel(name string) *liveChannelBuilder {
	if item, ok := group.byName[name]; ok {
		return item
	}
	item := &liveChannelBuilder{name: name, group: group.name}
	group.byName[name] = item
	group.order = append(group.order, item)
	return item
}

func liveSplitFirst(value string, separator string) (string, string, bool) {
	at := strings.Index(value, separator)
	if at < 0 {
		return value, "", false
	}
	return value[:at], value[at+len(separator):], true
}

// parseLiveListText 解析「分类名,#genre#\n频道名,地址」列表格式。
func parseLiveListText(text string, defaultGroup string) []*liveGroupBuilder {
	var groups []*liveGroupBuilder
	setter := &liveSetter{}
	for _, raw := range strings.Split(text, "\n") {
		if raw == "" {
			continue
		}
		if liveDirective.MatchString(raw) {
			setter.read(raw)
			continue
		}
		head, tail, hasTail := liveSplitFirst(raw, ",")
		if liveGenre.MatchString(raw) {
			setter.clear()
			name := strings.TrimSpace(head)
			if name == "" || name == "#genre#" {
				name = defaultGroup
			}
			groups = append(groups, newLiveGroupBuilder(name))
			continue
		}
		if !hasTail {
			continue
		}
		name := strings.TrimSpace(head)
		if name == "" || liveIsMetaChannel(name) {
			continue
		}
		for _, entry := range strings.Split(tail, "#") {
			pipe, extra, hasExtra := liveSplitFirst(entry, "|")
			target := strings.TrimSpace(pipe)
			if !liveURLUsable(target) {
				continue
			}
			if hasExtra && strings.TrimSpace(extra) != "" {
				setter.read(extra)
			}
			if len(groups) == 0 {
				groups = append(groups, newLiveGroupBuilder(defaultGroup))
			}
			group := groups[len(groups)-1]
			channel := group.channel(name)
			channel.urls = append(channel.urls, target)
			channel.headers = copyHeader(setter.header)
		}
	}
	return groups
}

// parseLiveM3U 解析 #EXTM3U 播放列表。
func parseLiveM3U(text string, defaultGroup string) []*liveGroupBuilder {
	var groups []*liveGroupBuilder
	setter := &liveSetter{}
	var pending *liveChannelBuilder
	afterComma := func(line string) string {
		at := strings.LastIndex(line, ",")
		if at < 0 {
			return ""
		}
		return strings.TrimSpace(line[at+1:])
	}
	for _, raw := range strings.Split(text, "\n") {
		if raw == "" {
			continue
		}
		if liveDirective.MatchString(raw) {
			setter.read(raw)
			continue
		}
		if strings.HasPrefix(raw, "#EXTM3U") {
			continue
		}
		if strings.HasPrefix(raw, "#EXTINF:") {
			name := afterComma(raw)
			if name == "" || liveIsMetaChannel(name) {
				pending = nil
				continue
			}
			title := liveAttr(raw, "group-title")
			if title == "" {
				title = defaultGroup
			}
			var group *liveGroupBuilder
			for _, item := range groups {
				if item.name == title {
					group = item
					break
				}
			}
			if group == nil {
				group = newLiveGroupBuilder(title)
				groups = append(groups, group)
			}
			pending = group.channel(name)
			if logo := liveAttr(raw, "tvg-logo"); logo != "" {
				pending.logo = logo
			}
			if number := liveAttr(raw, "tvg-chno"); number != "" {
				pending.number = number
			}
			if agent := liveAttr(raw, "http-user-agent"); agent != "" {
				setter.read("User-Agent=" + agent)
			}
			continue
		}
		if pending == nil || strings.HasPrefix(raw, "#") {
			continue
		}
		pipe, extra, hasExtra := liveSplitFirst(raw, "|")
		target := strings.TrimSpace(pipe)
		if !liveURLUsable(target) {
			continue
		}
		if hasExtra && strings.TrimSpace(extra) != "" {
			setter.read(extra)
		}
		pending.urls = append(pending.urls, target)
		pending.headers = copyHeader(setter.header)
	}
	return groups
}

// parseLiveChannels 统一入口：按内容自动识别 m3u / txt 列表格式。
func parseLiveChannels(text string, defaultGroup string) []*liveGroupBuilder {
	normalized := strings.ReplaceAll(text, "\r\n", "\n")
	normalized = strings.ReplaceAll(normalized, "\r", "\n")
	if strings.HasPrefix(strings.TrimLeft(normalized, " \t\n"), "[") ||
		strings.HasPrefix(strings.TrimLeft(normalized, " \t\n"), "{") {
		return parseLiveJSONChannels(normalized, defaultGroup)
	}
	if !liveGenre.MatchString(normalized) && liveM3UHeader.MatchString(normalized) {
		return parseLiveM3U(normalized, defaultGroup)
	}
	return parseLiveListText(normalized, defaultGroup)
}

// parseLiveJSONChannels 解析 [{group, channels:[{name,urls}]}] 接口。
func parseLiveJSONChannels(text string, defaultGroup string) []*liveGroupBuilder {
	var decoded any
	if json.Unmarshal([]byte(text), &decoded) != nil {
		return nil
	}
	var rows []any
	switch value := decoded.(type) {
	case []any:
		rows = value
	case map[string]any:
		for _, key := range []string{"groups", "list", "data"} {
			if nested, ok := value[key].([]any); ok {
				rows = nested
				break
			}
		}
		if rows == nil {
			rows = []any{value}
		}
	}
	pick := func(row map[string]any, keys []string) string {
		for _, key := range keys {
			if text, ok := row[key].(string); ok && strings.TrimSpace(text) != "" {
				return strings.TrimSpace(text)
			}
		}
		return ""
	}
	var groups []*liveGroupBuilder
	for _, item := range rows {
		row, ok := item.(map[string]any)
		if !ok {
			continue
		}
		var raw []any
		for _, key := range []string{"channel", "channels", "list", "items"} {
			if nested, ok := row[key].([]any); ok {
				raw = nested
				break
			}
		}
		if raw == nil {
			continue
		}
		groupName := pick(row, []string{"group", "name"})
		if groupName == "" {
			groupName = defaultGroup
		}
		group := newLiveGroupBuilder(groupName)
		for _, child := range raw {
			entry, ok := child.(map[string]any)
			if !ok {
				continue
			}
			name := pick(entry, []string{"name", "tvg-name", "title"})
			if name == "" || liveIsMetaChannel(name) {
				continue
			}
			channel := group.channel(name)
			switch urls := entry["urls"].(type) {
			case []any:
				for _, value := range urls {
					if text, ok := value.(string); ok && liveURLUsable(text) {
						channel.urls = append(channel.urls, strings.TrimSpace(text))
					}
				}
			case string:
				if liveURLUsable(urls) {
					channel.urls = append(channel.urls, strings.TrimSpace(urls))
				}
			}
			if len(channel.urls) == 0 {
				continue
			}
			channel.logo = pick(entry, []string{"logo", "img"})
		}
		if len(group.order) > 0 {
			groups = append(groups, group)
		}
	}
	return groups
}

func copyHeader(source map[string]string) map[string]string {
	if len(source) == 0 {
		return nil
	}
	result := make(map[string]string, len(source))
	for k, v := range source {
		result[k] = v
	}
	return result
}

// —— 平台（分类）协议：秀果类接口 ——

func livePingtaiPlatforms(session *liveSession, source liveSourceDef) ([]map[string]any, error) {
	byID := map[string]map[string]any{}
	order := []string{}
	var failures []string
	for _, endpoint := range source.Endpoints {
		text, err := session.get(endpoint+"/json.txt", source.Headers)
		if err != nil {
			failures = append(failures, err.Error())
			continue
		}
		var decoded any
		if json.Unmarshal([]byte(text), &decoded) != nil {
			continue
		}
		raw := decoded
		if value, ok := decoded.(map[string]any); ok {
			if nested, ok := value["pingtai"].([]any); ok {
				raw = nested
			}
		}
		rows, ok := raw.([]any)
		if !ok {
			continue
		}
		for _, item := range rows {
			row, ok := item.(map[string]any)
			if !ok {
				continue
			}
			id := strings.TrimSpace(asString(row["address"]))
			name := strings.TrimSpace(asString(row["title"]))
			if id == "" || name == "" {
				continue
			}
			retired := false
			for _, retiredID := range liveRetiredCategories {
				if strings.Contains(id, retiredID) {
					retired = true
					break
				}
			}
			if retired {
				continue
			}
			count, _ := strconv.Atoi(strings.TrimSpace(asString(row["Number"])))
			existing, seen := byID[id]
			if !seen {
				byID[id] = map[string]any{
					"id": id, "name": name, "count": count, "endpoint": endpoint,
					"logo": strings.TrimSpace(asString(row["xinimg"])),
				}
				order = append(order, id)
			} else if count > existing["count"].(int) {
				existing["count"] = count
				existing["endpoint"] = endpoint
			}
		}
	}
	if len(byID) == 0 {
		if len(failures) > 0 {
			return nil, errors.New("该直播源暂时不可用：" + failures[0])
		}
		return nil, errors.New("该直播源没有可用分类")
	}
	var all []map[string]any
	for _, id := range order {
		all = append(all, byID[id])
	}
	var result []map[string]any
	for _, item := range all {
		if item["count"].(int) > 0 {
			result = append(result, item)
		}
	}
	if len(result) == 0 {
		result = all
	}
	return result, nil
}

func asString(value any) string {
	switch typed := value.(type) {
	case string:
		return typed
	case float64:
		return strconv.FormatFloat(typed, 'f', -1, 64)
	case bool:
		return strconv.FormatBool(typed)
	default:
		return ""
	}
}

func livePingtaiChannels(session *liveSession, source liveSourceDef, endpoint string, platformID string) ([]liveChannelOut, error) {
	candidates := []string{}
	if endpoint != "" {
		candidates = append(candidates, endpoint)
	}
	for _, item := range source.Endpoints {
		if item != endpoint {
			candidates = append(candidates, item)
		}
	}
	var text string
	var lastErr error
	found := false
	for _, candidate := range candidates {
		payload, err := session.get(candidate+"/"+platformID, source.Headers)
		if err == nil {
			text, found = payload, true
			break
		}
		lastErr = err
	}
	if !found {
		if lastErr == nil {
			lastErr = errors.New("该分类暂时没有频道")
		}
		return nil, lastErr
	}
	var decoded any
	if json.Unmarshal([]byte(text), &decoded) != nil {
		return nil, errors.New("该分类暂时没有频道")
	}
	raw := decoded
	if value, ok := decoded.(map[string]any); ok {
		for _, key := range []string{"zhubo", "list", "data"} {
			if nested, ok := value[key].([]any); ok {
				raw = nested
				break
			}
		}
	}
	rows, ok := raw.([]any)
	if !ok {
		return nil, errors.New("该分类暂时没有频道")
	}
	var reliable []liveChannelOut
	var fallback []liveChannelOut
	seen := map[string]bool{}
	number := 0
	for _, item := range rows {
		row, ok := item.(map[string]any)
		if !ok {
			continue
		}
		name := strings.TrimSpace(asString(row["title"]))
		target := strings.TrimSpace(asString(row["address"]))
		if name == "" || !liveURLUsable(target) || seen[name] {
			continue
		}
		if liveCCTV.MatchString(name) {
			continue
		}
		seen[name] = true
		number++
		channel := liveChannelOut{
			Name:    name,
			URLs:    []string{target},
			Number:  pad3(number),
			Logo:    strings.TrimSpace(asString(row["img"])),
			Headers: copyHeader(source.Headers),
		}
		if strings.HasPrefix(target, "rtmp") {
			fallback = append(fallback, channel)
		} else {
			reliable = append(reliable, channel)
		}
	}
	return append(reliable, fallback...), nil
}

func pad3(value int) string {
	text := strconv.Itoa(value)
	for len(text) < 3 {
		text = "0" + text
	}
	return text
}

// —— HTTP 接口 ——

// GET /api/livestream/sources?green=1 → 可见直播源列表。
func handleLiveSources(writer http.ResponseWriter, request *http.Request) {
	green := request.URL.Query().Get("green") != "0"
	var result []map[string]any
	for _, item := range allLiveSources() {
		if green && item.Adult {
			continue
		}
		result = append(result, map[string]any{
			"id": item.ID, "name": item.Name, "description": item.Description,
			"protocol": item.Protocol, "builtin": item.Builtin,
		})
	}
	if result == nil {
		result = []map[string]any{}
	}
	writeJSON(writer, map[string]any{"ok": true, "data": result})
}

// POST /api/livestream/custom-sources {action: save|delete, id, name, endpoint}
func handleLiveCustomSources(writer http.ResponseWriter, request *http.Request) {
	body, err := io.ReadAll(io.LimitReader(request.Body, 1<<20))
	if err != nil {
		writeJSON(writer, map[string]any{"ok": false, "error": "读取请求失败"})
		return
	}
	var input struct {
		Action   string `json:"action"`
		ID       string `json:"id"`
		Name     string `json:"name"`
		Endpoint string `json:"endpoint"`
	}
	if json.Unmarshal(body, &input) != nil {
		writeJSON(writer, map[string]any{"ok": false, "error": "请求格式无效"})
		return
	}
	custom := loadLiveCustomSources()
	switch input.Action {
	case "save":
		name := strings.TrimSpace(input.Name)
		endpoint := strings.TrimSpace(input.Endpoint)
		if !liveSourceSafeName(name) {
			writeJSON(writer, map[string]any{"ok": false, "error": "直播源名称无效"})
			return
		}
		parsed, err := url.Parse(endpoint)
		if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" {
			writeJSON(writer, map[string]any{"ok": false, "error": "直播源地址需要是 http(s) 直链"})
			return
		}
		id := "live-" + hex.EncodeToString(sha1.New().Sum([]byte(name + "\x00" + endpoint))[:8])
		replaced := false
		for index := range custom {
			if custom[index].ID == id || strings.TrimSpace(custom[index].Name) == name {
				custom[index] = liveSourceDef{
					ID: id, Name: name, Description: "自定义直播源",
					Protocol: liveProtocolList, Endpoints: []string{endpoint},
					Group: liveUnsortedGroupName,
				}
				replaced = true
			}
		}
		if !replaced {
			custom = append(custom, liveSourceDef{
				ID: id, Name: name, Description: "自定义直播源",
				Protocol: liveProtocolList, Endpoints: []string{endpoint},
				Group: liveUnsortedGroupName,
			})
		}
		if err := saveLiveCustomSources(custom); err != nil {
			writeJSON(writer, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		writeJSON(writer, map[string]any{"ok": true, "data": id})
	case "delete":
		next := []liveSourceDef{}
		for _, item := range custom {
			if item.ID != input.ID {
				next = append(next, item)
			}
		}
		if err := saveLiveCustomSources(next); err != nil {
			writeJSON(writer, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		writeJSON(writer, map[string]any{"ok": true})
	default:
		writeJSON(writer, map[string]any{"ok": true, "data": custom})
	}
}

// GET /api/livestream/platforms?source=ID → 分类列表。
func handleLivePlatforms(writer http.ResponseWriter, request *http.Request) {
	source, ok := findLiveSource(request.URL.Query().Get("source"))
	if !ok {
		writeJSON(writer, map[string]any{"ok": false, "error": "直播源不存在"})
		return
	}
	session := newLiveSession()
	var platforms []map[string]any
	switch source.Protocol {
	case liveProtocolPingtai:
		list, err := livePingtaiPlatforms(session, source)
		if err != nil {
			writeJSON(writer, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		platforms = list
	case liveProtocolRoom:
		list, err := liveRoomPlatforms(session, source)
		if err != nil {
			writeJSON(writer, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		platforms = list
	default:
		platforms = []map[string]any{{"id": "all", "name": "全部频道", "count": 0, "endpoint": ""}}
	}
	writeJSON(writer, map[string]any{"ok": true, "data": platforms})
}

// GET /api/livestream/channels?source=ID&platform=ID → 频道列表。
// 列表型协议在首频道上实测各线路延迟并重排（与 App 端 _routeOrder 同语义）。
func handleLiveChannels(writer http.ResponseWriter, request *http.Request) {
	source, ok := findLiveSource(request.URL.Query().Get("source"))
	if !ok {
		writeJSON(writer, map[string]any{"ok": false, "error": "直播源不存在"})
		return
	}
	green := request.URL.Query().Get("green") != "0"
	session := newLiveSession()
	var channels []liveChannelOut
	switch source.Protocol {
	case liveProtocolPingtai:
		platformID := request.URL.Query().Get("platform")
		endpoint := request.URL.Query().Get("endpoint")
		name := request.URL.Query().Get("group")
		list, err := livePingtaiChannels(session, source, endpoint, platformID)
		if err != nil {
			writeJSON(writer, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		for _, item := range list {
			item.Group = name
			channels = append(channels, item)
		}
	case liveProtocolRoom:
		platformID := request.URL.Query().Get("platform")
		group := request.URL.Query().Get("group")
		page, _ := strconv.Atoi(request.URL.Query().Get("page"))
		if platformID == "" {
			writeJSON(writer, map[string]any{"ok": true, "data": []liveChannelOut{}})
			return
		}
		list, err := liveRoomChannels(session, source, platformID, page, group)
		if err != nil {
			writeJSON(writer, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		channels = list
	default:
		if len(source.Endpoints) == 0 {
			writeJSON(writer, map[string]any{"ok": false, "error": "直播源没有可用地址"})
			return
		}
		text, err := session.get(source.Endpoints[0], source.Headers)
		if err != nil {
			writeJSON(writer, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		defaultGroup := source.Group
		if defaultGroup == "" {
			defaultGroup = liveUnsortedGroupName
		}
		for _, group := range parseLiveChannels(text, defaultGroup) {
			for _, item := range group.order {
				if len(item.urls) == 0 {
					continue
				}
				channels = append(channels, liveChannelOut{
					Name: item.name, URLs: item.urls, Logo: item.logo,
					Number: item.number, Group: group.name, Headers: item.headers,
				})
			}
		}
	}
	greenHidden := func(name string) bool {
		return green && !liveGreenCategory.MatchString(name)
	}
	var result []liveChannelOut
	for _, item := range channels {
		if source.Protocol == liveProtocolPingtai && greenHidden(item.Group) {
			continue
		}
		result = append(result, item)
	}
	if result == nil {
		result = []liveChannelOut{}
	}
	writeJSON(writer, map[string]any{"ok": true, "data": result})
}

// GET /api/livestream/play?source=ID&room=ID —— 房间型源换取真实播放地址。
// 列表接口不下发地址（斗鱼/哔哩哔哩/虎牙都要二次签名解析），点播时才解析。
func handleLivePlay(writer http.ResponseWriter, request *http.Request) {
	source, ok := findLiveSource(request.URL.Query().Get("source"))
	if !ok {
		writeJSON(writer, map[string]any{"ok": false, "error": "直播源不存在"})
		return
	}
	room := request.URL.Query().Get("room")
	if room == "" {
		room = request.URL.Query().Get("token")
	}
	urls, headers, err := liveRoomPlayback(newLiveSession(), source, room)
	if err != nil {
		writeJSON(writer, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	writeJSON(writer, map[string]any{"ok": true, "data": map[string]any{
		"urls": urls, "headers": headers,
	}})
}

// GET /api/livestream/stream?source=ID&url=RAW  —— 直播流代理。
// m3u8：服务端拉取清单、改写分片与子清单地址继续走本代理；其余直接流式转发。
func handleLivestreamStream(writer http.ResponseWriter, request *http.Request) {
	raw := request.URL.Query().Get("url")
	target, err := url.Parse(raw)
	if err != nil || (target.Scheme != "http" && target.Scheme != "https") || target.Host == "" {
		http.Error(writer, "直播地址无效", http.StatusBadRequest)
		return
	}
	source, _ := findLiveSource(request.URL.Query().Get("source"))
	headers := copyHeader(source.Headers)
	// 房间型源（斗鱼/哔哩哔哩/虎牙）必须带 Referer 才不返回 403，源定义里没有
	// 头信息，这里按平台补一份与 App 端一致的取流头。
	if len(headers) == 0 && source.Protocol == liveProtocolRoom {
		headers = liveRoomHeaders(source.ID)
	}
	// 直播流是长连接：不能用整请求超时的 http.Client.Timeout（会把持续拉流
	// 的 HLS / flv 在 14 秒后截断），只保留 localTransport 的 15 秒拨号/建连上限。
	client := &http.Client{Transport: localTransport}
	upstream, err := http.NewRequest(http.MethodGet, target.String(), nil)
	if err != nil {
		http.Error(writer, "直播地址无效", http.StatusBadRequest)
		return
	}
	upstream.Header.Set("User-Agent", liveUserAgentValue)
	for name, value := range headers {
		if strings.TrimSpace(value) != "" {
			upstream.Header.Set(name, value)
		}
	}
	response, err := client.Do(upstream)
	if err != nil {
		http.Error(writer, "无法连接直播源", http.StatusBadGateway)
		return
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		http.Error(writer, "直播源返回 "+strconv.Itoa(response.StatusCode), http.StatusBadGateway)
		return
	}
	playlist := strings.Contains(response.Header.Get("Content-Type"), "mpegurl") ||
		strings.HasSuffix(strings.ToLower(target.Path), ".m3u8")
	if !playlist {
		writer.Header().Set("Content-Type", response.Header.Get("Content-Type"))
		if writer.Header().Get("Content-Type") == "" {
			writer.Header().Set("Content-Type", "application/octet-stream")
		}
		writer.Header().Set("Cache-Control", "no-store")
		_, _ = io.Copy(writer, response.Body)
		return
	}
	payload, err := io.ReadAll(io.LimitReader(response.Body, liveMaxBytes+1))
	if err != nil || len(payload) > liveMaxBytes {
		http.Error(writer, "直播清单读取失败", http.StatusBadGateway)
		return
	}
	var rewritten bytes.Buffer
	scanner := bufio.NewScanner(bytes.NewReader(payload))
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := scanner.Text()
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(line, "#EXT-X-STREAM-INF") || trimmed == "" || strings.HasPrefix(trimmed, "#") {
			rewritten.WriteString(line)
			rewritten.WriteByte('\n')
			continue
		}
		absolute, err := target.Parse(trimmed)
		if err != nil {
			rewritten.WriteString(line)
			rewritten.WriteByte('\n')
			continue
		}
		forward := url.Values{}
		forward.Set("source", source.ID)
		forward.Set("url", absolute.String())
		rewritten.WriteString("/api/livestream/stream?")
		rewritten.WriteString(forward.Encode())
		rewritten.WriteByte('\n')
	}
	writer.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
	writer.Header().Set("Cache-Control", "no-store")
	_, _ = writer.Write(rewritten.Bytes())
}

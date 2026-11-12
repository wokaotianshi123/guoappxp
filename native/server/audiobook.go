package main

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"duanjuapp/native/core"
)

// 听书（Web 服务器版）。榜单 / 搜索 / 目录 / 正文全部走 Go 核心的听书动作，
// 与 Flutter 端共用同一套请求：代理、限流、超时都跟 App 一致，浏览器只访问
// /api/audiobook/*。音频可能带 CENC 加密，浏览器既不能解密也不能解 m4a，
// 因此由 ffmpeg 解密后重编码成 HLS（纯音频），前端用 hls.js 播。

const (
	audiobookGenre      = "4" // 番茄听书频道 id
	audiobookPageSize   = 20
	audiobookChunkLimit = 50
)

// —— 核心调用 ——

func coreCall(payload map[string]any) (map[string]any, error) {
	encoded, err := json.Marshal(payload)
	if err != nil {
		return nil, errors.New("请求编码失败")
	}
	reply := core.NativeRequest(string(encoded))
	var envelope struct {
		OK    bool            `json:"ok"`
		Data  json.RawMessage `json:"data"`
		Error string          `json:"error"`
	}
	if json.Unmarshal([]byte(reply), &envelope) != nil {
		return nil, errors.New("听书核心返回的内容无法识别")
	}
	if !envelope.OK {
		message := strings.TrimSpace(envelope.Error)
		if message == "" {
			message = "听书请求失败"
		}
		return nil, errors.New(message)
	}
	if len(envelope.Data) == 0 {
		return map[string]any{}, nil
	}
	var data map[string]any
	if json.Unmarshal(envelope.Data, &data) != nil {
		return map[string]any{}, nil
	}
	return data, nil
}

func audiobookFetchJSON(target string, headers map[string]string) (map[string]any, error) {
	encodedHeaders := ""
	if len(headers) > 0 {
		payload, err := json.Marshal(headers)
		if err == nil {
			encodedHeaders = string(payload)
		}
	}
	data, err := coreCall(map[string]any{
		"action":  "audiobookFetch",
		"query":   target,
		"content": encodedHeaders,
	})
	if err != nil {
		return nil, err
	}
	body, _ := data["body"].(string)
	if strings.TrimSpace(body) == "" {
		return nil, errors.New("听书源没有返回内容")
	}
	var decoded map[string]any
	if json.Unmarshal([]byte(body), &decoded) != nil {
		return nil, errors.New("听书源返回的内容无法识别")
	}
	return decoded, nil
}

// —— 取值助手 ——

func audiobookObject(value any) map[string]any {
	if root, ok := value.(map[string]any); ok {
		return root
	}
	return nil
}

func audiobookRows(value any) []map[string]any {
	rows, ok := value.([]any)
	if !ok {
		return nil
	}
	result := make([]map[string]any, 0, len(rows))
	for _, item := range rows {
		if row := audiobookObject(item); row != nil {
			result = append(result, row)
		}
	}
	return result
}

func audiobookText2(value any) string {
	switch typed := value.(type) {
	case string:
		return stripFanqieEm(typed)
	case float64:
		return strconv.FormatFloat(typed, 'f', -1, 64)
	case nil:
		return ""
	default:
		return stripFanqieEm(asString(typed))
	}
}

// stripFanqieEm 去掉番茄标题里的 <em> 高亮标签（搜索结果会带）。
func stripFanqieEm(value string) string {
	value = strings.ReplaceAll(value, "<em>", "")
	value = strings.ReplaceAll(value, "</em>", "")
	return strings.TrimSpace(value)
}

// —— 榜单 / 搜索 / 目录 ——
//
// 榜单与搜索都改由服务端全量书库（audiobook_library.go）统一供数：榜单接口
// 固定每页 30 条且 has_more 恒 false，旧的「limit=20 + offset 步长 20」会重叠
// 漏书、翻页也永远停在首页。保留这两个旧端点，回包格式不变，额外带上
// total / pageCount / categories / library 供网页显示分类与分页。

// GET /api/audiobook/ranks?side=17&type=1&page=1
func handleAudiobookRanks(writer http.ResponseWriter, request *http.Request) {
	params := request.URL.Query()
	board := 0
	if params.Get("type") == "0" {
		board = 1
	}
	page, _ := strconv.Atoi(params.Get("page"))
	data := abLibrary.query(board, "", "", page, audiobookPageSize)
	data["hasMore"] = abQueryHasMore(data)
	writeJSON(writer, map[string]any{"ok": true, "data": data})
}

// GET /api/audiobook/search?q=&page=1
func handleAudiobookSearch(writer http.ResponseWriter, request *http.Request) {
	query := strings.TrimSpace(request.URL.Query().Get("q"))
	if query == "" {
		writeJSON(writer, map[string]any{"ok": true, "data": map[string]any{
			"books": []map[string]any{}, "hasMore": false,
		}})
		return
	}
	page, _ := strconv.Atoi(request.URL.Query().Get("page"))
	data := abLibrary.query(0, "", query, page, audiobookLibraryPage)
	data["hasMore"] = abQueryHasMore(data)
	writeJSON(writer, map[string]any{"ok": true, "data": data})
}

// GET /api/audiobook/chapters?book=ID&page=1 —— 目录一次取全，按页切片。
func handleAudiobookChapters(writer http.ResponseWriter, request *http.Request) {
	bookID := strings.TrimSpace(request.URL.Query().Get("book"))
	if bookID == "" {
		writeJSON(writer, map[string]any{"ok": false, "error": "缺少书籍编号"})
		return
	}
	page, _ := strconv.Atoi(request.URL.Query().Get("page"))
	if page < 1 {
		page = 1
	}
	target := "https://fanqienovel.com/api/reader/directory/detail?bookId=" + url.QueryEscape(bookID)
	root, err := audiobookFetchJSON(target, nil)
	if err != nil {
		writeJSON(writer, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	data := audiobookObject(root["data"])
	chapters := []map[string]any{}
	order := 0
	for _, volume := range audiobookAnyList(data["chapterListWithVolume"]) {
		for _, row := range audiobookRows(volume) {
			id := strings.TrimSpace(asString(row["itemId"]))
			title := audiobookText2(row["title"])
			if id == "" || title == "" {
				continue
			}
			order++
			number := order
			if parsed, ok := row["realChapterOrder"].(float64); ok && parsed > 0 {
				number = int(parsed)
			}
			locked := row["isChapterLock"] == true || asString(row["needPay"]) == "1"
			chapters = append(chapters, map[string]any{
				"id": id, "title": title, "order": number, "locked": locked,
			})
		}
	}
	total := len(chapters)
	start := (page - 1) * audiobookChunkLimit
	if start >= total {
		writeJSON(writer, map[string]any{"ok": true, "data": map[string]any{
			"chapters": []map[string]any{}, "total": total, "hasMore": false,
		}})
		return
	}
	end := start + audiobookChunkLimit
	if end > total {
		end = total
	}
	writeJSON(writer, map[string]any{"ok": true, "data": map[string]any{
		"chapters": chapters[start:end], "total": total, "hasMore": end < total,
	}})
}

func audiobookAnyList(value any) []any {
	if rows, ok := value.([]any); ok {
		return rows
	}
	return nil
}

func firstNonEmpty(values ...any) any {
	for _, value := range values {
		if strings.TrimSpace(asString(value)) != "" {
			return value
		}
	}
	return ""
}

// —— 正文（带逐句时间轴） ——

// GET /api/audiobook/text?chapter=ITEM_ID —— 返回段落与逐句时间。
func handleAudiobookText(writer http.ResponseWriter, request *http.Request) {
	chapterID := strings.TrimSpace(request.URL.Query().Get("chapter"))
	if chapterID == "" {
		writeJSON(writer, map[string]any{"ok": false, "error": "缺少章节编号"})
		return
	}
	data, err := coreCall(map[string]any{
		"action":   "audiobookText",
		"category": chapterID,
	})
	if err != nil {
		writeJSON(writer, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	paragraphs, _ := data["paragraphs"].([]any)
	if paragraphs == nil {
		paragraphs = []any{}
	}
	writeJSON(writer, map[string]any{"ok": true, "data": map[string]any{
		"paragraphs": paragraphs, "timed": data["timed"] == true,
	}})
}

// —— 音频 ——

type audiobookMediaCache struct {
	mu    sync.Mutex
	items map[string]audiobookMediaItem
}

type audiobookMediaItem struct {
	url       string
	key       string
	duration  int
	headers   map[string]string
	expiresAt time.Time
}

var audiobookMedia = &audiobookMediaCache{items: map[string]audiobookMediaItem{}}

func (cache *audiobookMediaCache) put(id string, item audiobookMediaItem) {
	cache.mu.Lock()
	defer cache.mu.Unlock()
	item.expiresAt = time.Now().Add(15 * time.Minute)
	cache.items[id] = item
}

func (cache *audiobookMediaCache) get(id string) (audiobookMediaItem, bool) {
	cache.mu.Lock()
	defer cache.mu.Unlock()
	item, ok := cache.items[id]
	if !ok || time.Now().After(item.expiresAt) {
		return audiobookMediaItem{}, false
	}
	return item, true
}

func audiobookResolveMedia(bookID, chapterID string) (audiobookMediaItem, error) {
	id := bookID + "\u0000" + chapterID
	if item, ok := audiobookMedia.get(id); ok {
		return item, nil
	}
	data, err := coreCall(map[string]any{
		"action":   "audiobookMedia",
		"query":    bookID,
		"category": chapterID,
	})
	if err != nil {
		return audiobookMediaItem{}, err
	}
	target := strings.TrimSpace(asString(data["url"]))
	if target == "" {
		return audiobookMediaItem{}, errors.New("这一章暂时没有音频地址")
	}
	headers := map[string]string{}
	if rows, ok := data["headers"].(map[string]any); ok {
		for name, value := range rows {
			headers[name] = asString(value)
		}
	}
	item := audiobookMediaItem{
		url:      target,
		key:      strings.TrimSpace(asString(data["decryptionKey"])),
		duration: int(liveNumber(data["duration"])),
		headers:  headers,
	}
	audiobookMedia.put(id, item)
	return item, nil
}

// GET /api/audiobook/media?book=ID&chapter=ID —— 起播：加密音频转 HLS，明文音频走代理。
func handleAudiobookMedia(writer http.ResponseWriter, request *http.Request) {
	bookID := strings.TrimSpace(request.URL.Query().Get("book"))
	chapterID := strings.TrimSpace(request.URL.Query().Get("chapter"))
	if bookID == "" || chapterID == "" {
		writeJSON(writer, map[string]any{"ok": false, "error": "缺少书籍或章节编号"})
		return
	}
	item, err := audiobookResolveMedia(bookID, chapterID)
	if err != nil {
		writeJSON(writer, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	answer := map[string]any{
		"duration":  item.duration,
		"encrypted": item.key != "",
		"mode":      "direct",
		"url": "/api/audiobook/stream?book=" + url.QueryEscape(bookID) +
			"&chapter=" + url.QueryEscape(chapterID),
	}
	if ffmpegPath() == "" {
		if item.key != "" {
			answer["message"] = "这一章的音频是加密的，需要 ffmpeg 才能播放"
		}
		writeJSON(writer, map[string]any{"ok": true, "data": answer})
		return
	}
	key := jobKey("audiobook", bookID, chapterID, item.key)
	job, err := transcoder.startAudio(key, item.url, item.key, item.headers)
	if err != nil {
		answer["message"] = err.Error()
		writeJSON(writer, map[string]any{"ok": true, "data": answer})
		return
	}
	ready, failure := transcoder.wait(job)
	answer["mode"] = "hls"
	answer["url"] = "/api/live/" + key + "/index.m3u8"
	answer["transcoding"] = !job.isFinished()
	if !ready && failure != "" {
		// 转码启动失败（密钥不对 / 地址过期）时退回直连，至少让明文音频能听。
		answer["mode"] = "direct"
		answer["url"] = "/api/audiobook/stream?book=" + url.QueryEscape(bookID) +
			"&chapter=" + url.QueryEscape(chapterID)
		answer["message"] = "音频转码失败：" + failure
	}
	writeJSON(writer, map[string]any{"ok": true, "data": answer})
}

// GET /api/audiobook/stream?book=ID&chapter=ID —— 明文音频代理（带 Range 透传）。
func handleAudiobookStream(writer http.ResponseWriter, request *http.Request) {
	bookID := strings.TrimSpace(request.URL.Query().Get("book"))
	chapterID := strings.TrimSpace(request.URL.Query().Get("chapter"))
	if bookID == "" || chapterID == "" {
		http.Error(writer, "缺少书籍或章节编号", http.StatusBadRequest)
		return
	}
	item, err := audiobookResolveMedia(bookID, chapterID)
	if err != nil {
		http.Error(writer, err.Error(), http.StatusBadGateway)
		return
	}
	target, err := url.Parse(item.url)
	if err != nil || (target.Scheme != "http" && target.Scheme != "https") {
		http.Error(writer, "音频地址无效", http.StatusBadGateway)
		return
	}
	client := &http.Client{Transport: localTransport}
	upstream, err := http.NewRequest(http.MethodGet, target.String(), nil)
	if err != nil {
		http.Error(writer, "音频地址无效", http.StatusBadGateway)
		return
	}
	for name, value := range item.headers {
		if strings.TrimSpace(value) != "" {
			upstream.Header.Set(name, value)
		}
	}
	if upstream.Header.Get("User-Agent") == "" {
		upstream.Header.Set("User-Agent", "com.dragon.read")
	}
	// 跳转/分段请求都要原样转发，否则 <audio> 无法拖动进度。
	if value := request.Header.Get("Range"); value != "" {
		upstream.Header.Set("Range", value)
	}
	response, err := client.Do(upstream)
	if err != nil {
		http.Error(writer, "无法连接音频源", http.StatusBadGateway)
		return
	}
	defer response.Body.Close()
	for _, name := range []string{"Content-Type", "Content-Length", "Content-Range", "Accept-Ranges"} {
		if value := response.Header.Get(name); value != "" {
			writer.Header().Set(name, value)
		}
	}
	if writer.Header().Get("Content-Type") == "" {
		writer.Header().Set("Content-Type", "audio/mp4")
	}
	writer.Header().Set("Cache-Control", "no-store")
	writer.WriteHeader(response.StatusCode)
	_, _ = io.Copy(writer, response.Body)
}

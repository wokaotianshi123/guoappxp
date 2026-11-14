package main

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"sort"
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
	// abHongguoBookPrefix 区分两个书源的书籍 ID：红果听书是纯数字 book_id，
	// 与番茄可能重号，加上前缀后列表、进度、缓存都天然隔离。
	abHongguoBookPrefix = "hg:"
)

// abHongguoStore 缓存红果听书两个频道的全量书池。
//
// 红果书城单页只有 12 本，翻页接口每页 10 本且相邻页有重叠，边翻边供数会让
// 前端看到「只有十几本」。这里像番茄书库一样后台抓全量并缓存，列表直接按
// 缓存分页；抓取中先用已有部分顶上，前端按 library.loading 轮询补全。
type abHongguoStore struct {
	mu         sync.Mutex
	books      map[string][]map[string]any // category → 书单
	loading    map[string]bool
	done       map[string]bool
	errText    map[string]string
	finished   map[string]time.Time
	generation map[string]uint64
}

var abHongguo = &abHongguoStore{
	books:      map[string][]map[string]any{},
	loading:    map[string]bool{},
	done:       map[string]bool{},
	errText:    map[string]string{},
	finished:   map[string]time.Time{},
	generation: map[string]uint64{},
}

const abHongguoTtl = 30 * time.Minute

// ensure 在缓存过期或首次访问时触发后台抓取，已有书池继续可用。
func (store *abHongguoStore) ensure(category string) {
	store.mu.Lock()
	if store.loading[category] {
		store.mu.Unlock()
		return
	}
	if store.done[category] && time.Since(store.finished[category]) < abHongguoTtl {
		store.mu.Unlock()
		return
	}
	store.generation[category]++
	generation := store.generation[category]
	store.loading[category] = true
	store.done[category] = false
	store.errText[category] = ""
	store.mu.Unlock()
	go store.load(category, generation)
}

func (store *abHongguoStore) load(category string, generation uint64) {
	// core 侧的 pool 是「边翻边发布」的异步实现：首次调用很快返回第一批，
	// 之后要轮询到 loading=false 才算抓全。这里一直轮询到底，
	// 期间把已有进度先写进书池，前端能看到书库逐步变大。
	books := make([]map[string]any, 0)
	deadline := time.Now().Add(6 * time.Minute)
	var lastErr error
	for {
		data, err := coreCall(map[string]any{
			"action": "audiobookHongguoPool", "category": category, "page": 80,
		})
		store.mu.Lock()
		if store.generation[category] != generation {
			store.mu.Unlock()
			return
		}
		if err != nil {
			lastErr = err
			store.mu.Unlock()
			break
		}
		batch := make([]map[string]any, 0)
		for _, item := range audiobookAnyList(data["books"]) {
			if row, ok := item.(map[string]any); ok {
				batch = append(batch, row)
			}
		}
		if len(batch) > 0 {
			books = batch
			// 先把当前进度写进去，前端轮询能看到书库在长。
			store.books[category] = books
		}
		loading := data["loading"] == true
		store.mu.Unlock()
		if !loading {
			break
		}
		if time.Now().After(deadline) {
			lastErr = errors.New("红果听书抓取超时")
			break
		}
		time.Sleep(1200 * time.Millisecond)
	}

	store.mu.Lock()
	defer store.mu.Unlock()
	if store.generation[category] != generation {
		return
	}
	store.loading[category] = false
	if lastErr != nil && len(books) == 0 {
		store.errText[category] = lastErr.Error()
		store.done[category] = len(store.books[category]) > 0
		return
	}
	if len(books) > 0 {
		store.books[category] = books
	}
	store.done[category] = true
	store.finished[category] = time.Now()
}

// snapshot 返回当前书池与抓取状态。
func (store *abHongguoStore) snapshot(category string) ([]map[string]any, map[string]any) {
	store.mu.Lock()
	defer store.mu.Unlock()
	books := append([]map[string]any(nil), store.books[category]...)
	info := map[string]any{
		"loading": store.loading[category],
		"done":    store.done[category],
		"count":   len(books),
		"error":   store.errText[category],
	}
	return books, info
}

// abHongguoCategory 把前端 board（0 听书 / 1 小说）映射成红果频道。
func abHongguoCategory(board int) string {
	if board == 1 {
		return "novel"
	}
	return "listen"
}

// abHongguoLibrary 返回红果听书的一页书单，字段与番茄书库保持一致。
// category 参数是题材小分类（如「战神赘婿」），空串表示全部。
func abHongguoLibrary(board int, category, query string, page, size int) map[string]any {
	if page < 1 {
		page = 1
	}
	if size < 1 || size > 50 {
		size = audiobookPageSize
	}
	channel := abHongguoCategory(board)
	abHongguo.ensure(channel)

	// 搜索走红果自己的搜索接口，不依赖缓存书池（能搜到池外的书）。
	if strings.TrimSpace(query) != "" {
		data, err := coreCall(map[string]any{
			"action": "audiobookHongguoSearch", "category": channel, "query": query, "page": page,
		})
		answer := map[string]any{
			"books": []map[string]any{}, "total": 0, "page": page, "pageCount": 1,
			"pageSize": size, "categories": []string{}, "origin": "hongguo",
			"library": map[string]any{"loading": false, "done": true, "count": 0, "error": ""},
		}
		if err != nil {
			answer["library"].(map[string]any)["error"] = err.Error()
			return answer
		}
		books := abHongguoPrefix(audiobookAnyList(data["books"]))
		hasMore := data["hasMore"] == true
		pageCount := page
		if hasMore {
			pageCount = page + 1
		}
		answer["books"] = books
		answer["total"] = (page-1)*size + len(books)
		answer["pageCount"] = pageCount
		return answer
	}

	pool, info := abHongguo.snapshot(channel)
	list := make([]map[string]any, 0, len(pool))
	for _, book := range pool {
		if category != "" && !abHongguoMatchesCategory(book, category) {
			continue
		}
		list = append(list, book)
	}
	total := len(list)
	pageCount := (total + size - 1) / size
	if pageCount < 1 {
		pageCount = 1
	}
	if page > pageCount {
		page = pageCount
	}
	start := (page - 1) * size
	end := start + size
	if end > total {
		end = total
	}
	pageBooks := make([]any, 0, end-start)
	for _, book := range list[start:end] {
		pageBooks = append(pageBooks, book)
	}
	return map[string]any{
		"books":      abHongguoPrefix(pageBooks),
		"total":      total,
		"page":       page,
		"pageCount":  pageCount,
		"pageSize":   size,
		"categories": abHongguoCategories(pool),
		"origin":     "hongguo",
		"library":    info,
	}
}

// abHongguoMatchesCategory 判断一本书是否属于某个题材分类。
// 红果的 category 字段是「战神赘婿」这类题材名，可能带顿号分隔的多个标签。
func abHongguoMatchesCategory(book map[string]any, category string) bool {
	text := strings.TrimSpace(asString(book["category"]))
	if text == "" {
		return false
	}
	for _, tag := range strings.FieldsFunc(text, func(r rune) bool {
		return r == '·' || r == ',' || r == '，' || r == '、' || r == '/' || r == ' ' || r == '|'
	}) {
		if strings.TrimSpace(tag) == category {
			return true
		}
	}
	return false
}

// abHongguoCategories 统计书池里真实出现的题材分类，按出现次数降序。
func abHongguoCategories(pool []map[string]any) []string {
	counts := map[string]int{}
	for _, book := range pool {
		text := strings.TrimSpace(asString(book["category"]))
		if text == "" {
			continue
		}
		for _, tag := range strings.FieldsFunc(text, func(r rune) bool {
			return r == '·' || r == ',' || r == '，' || r == '、' || r == '/' || r == ' ' || r == '|'
		}) {
			if tag = strings.TrimSpace(tag); tag != "" {
				counts[tag]++
			}
		}
	}
	out := make([]string, 0, len(counts))
	for name := range counts {
		out = append(out, name)
	}
	sort.SliceStable(out, func(i, j int) bool {
		if counts[out[i]] != counts[out[j]] {
			return counts[out[i]] > counts[out[j]]
		}
		return out[i] < out[j]
	})
	if len(out) > 40 {
		out = out[:40]
	}
	return out
}

func abHongguoPrefix(books []any) []map[string]any {
	out := make([]map[string]any, 0, len(books))
	for _, item := range books {
		book, ok := item.(map[string]any)
		if !ok {
			continue
		}
		id := strings.TrimSpace(asString(book["id"]))
		if id == "" {
			continue
		}
		book["id"] = abHongguoBookPrefix + id
		out = append(out, book)
	}
	return out
}

// abHongguoChapters 取红果听书的目录，按页切片（与番茄目录接口同款回包）。
func abHongguoChapters(bookID string, page int) (map[string]any, error) {
	if page < 1 {
		page = 1
	}
	data, err := coreCall(map[string]any{"action": "audiobookHongguoChapters", "query": bookID})
	if err != nil {
		return nil, err
	}
	chapters := make([]map[string]any, 0)
	for _, item := range audiobookAnyList(data["chapters"]) {
		if row, ok := item.(map[string]any); ok {
			// 章节 ID 也加前缀：红果与番茄的 item_id 都是长数字，加前缀才能
			// 让「正文 / 播放」两条按 ID 判书源的路径可靠区分。
			if id := strings.TrimSpace(asString(row["id"])); id != "" {
				row["id"] = abHongguoBookPrefix + id
			}
			chapters = append(chapters, row)
		}
	}
	total := len(chapters)
	start := (page - 1) * audiobookChunkLimit
	if start >= total {
		return map[string]any{"chapters": []map[string]any{}, "total": total, "hasMore": false}, nil
	}
	end := start + audiobookChunkLimit
	if end > total {
		end = total
	}
	return map[string]any{"chapters": chapters[start:end], "total": total, "hasMore": end < total}, nil
}

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
	data := abLibrary.query(abOriginAll, board, "", "", page, audiobookPageSize)
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
	data := abLibrary.query(abOriginAll, 0, "", query, page, audiobookLibraryPage)
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
	// 红果听书的目录走红果接口，书籍 ID 带 hg: 前缀。
	if strings.HasPrefix(bookID, abHongguoBookPrefix) {
		data, err := abHongguoChapters(strings.TrimPrefix(bookID, abHongguoBookPrefix), page)
		if err != nil {
			writeJSON(writer, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		writeJSON(writer, map[string]any{"ok": true, "data": data})
		return
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
	// 红果听书暂时没有逐句正文，章节 ID 带 hg: 前缀，回空段落让前端直接播音频。
	if strings.HasPrefix(chapterID, abHongguoBookPrefix) {
		writeJSON(writer, map[string]any{"ok": true, "data": map[string]any{
			"paragraphs": []any{}, "timed": false,
		}})
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
	// 红果听书：红果接口直接给地址与 CENC key，不需要走番茄 playinfo。
	if strings.HasPrefix(bookID, abHongguoBookPrefix) {
		data, err := coreCall(map[string]any{
			"action":   "audiobookHongguoMedia",
			"query":    strings.TrimPrefix(bookID, abHongguoBookPrefix),
			"category": strings.TrimPrefix(chapterID, abHongguoBookPrefix),
		})
		if err != nil {
			return audiobookMediaItem{}, err
		}
		item := audiobookMediaItem{
			url:      strings.TrimSpace(asString(data["url"])),
			key:      strings.TrimSpace(asString(data["decryptionKey"])),
			duration: int(liveNumber(data["duration"])),
			headers:  map[string]string{},
		}
		if item.url == "" {
			return audiobookMediaItem{}, errors.New("这一章暂时没有音频地址")
		}
		if rows, ok := data["headers"].(map[string]any); ok {
			for name, value := range rows {
				item.headers[name] = asString(value)
			}
		}
		audiobookMedia.put(id, item)
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

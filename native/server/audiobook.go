package main

import (
	"encoding/json"
	"errors"
	"fmt"
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

// abHongguoCatalogPageSize 是 core 的 audiobookHongguoCatalog 单页条数
// （page 1 首屏 12 本，之后每次 offset 步进 10）。按请求页换算需要取几页。
const abHongguoCatalogPageSize = 10

// abHongguoStore 缓存红果听书两个频道「已按需取到」的书页。
//
// 旧实现在首次访问时启动 goroutine，用 6 分钟、每 1.2 秒一次的循环把
// audiobookHongguoPool 的 80 页全量翻完，期间 core 还在后台持续抓取，前端
// 也要定时轮询 library.loading 补全——这正是打开软件时争抢限流、IPC 与
// CPU、把界面拖卡的主因。
//
// 现在与 App 端一致改成按需加载：点开书源只取第 1 页；用户翻到第几页，
// 才同步补到能覆盖该页的页数，取完立刻结束。没有后台 goroutine、没有
// 定时轮询、没有超时循环；snapshot 的 loading 恒为 false，前端的补全
// 定时器自然不会再启动。
type abHongguoStore struct {
	mu       sync.Mutex
	books    map[string][]map[string]any // category → 已加载书单（按页去重追加）
	pages    map[string]int              // category → 已取到第几页
	hasMore  map[string]bool             // 上游是否还有更多
	errText  map[string]string
	inflight map[string]bool // 同一频道同时只补一次页，避免并发重复请求
}

var abHongguo = &abHongguoStore{
	books:    map[string][]map[string]any{},
	pages:    map[string]int{},
	hasMore:  map[string]bool{},
	errText:  map[string]string{},
	inflight: map[string]bool{},
}

// ensurePages 同步把某个频道补到 needPages 页，只在用户主动翻页时调用。
//
// 每次循环只取一页，页数有界（needPages 由请求的 page/size 算出，最多几页）；
// 失败或上游没有更多就立刻停，不重试、不后台续抓、不 sleep。
func (store *abHongguoStore) ensurePages(category string, needPages int) {
	if needPages < 1 {
		needPages = 1
	}
	for {
		store.mu.Lock()
		loaded := store.pages[category]
		if loaded >= needPages {
			store.mu.Unlock()
			return
		}
		if loaded > 0 && !store.hasMore[category] {
			store.mu.Unlock()
			return
		}
		if store.inflight[category] {
			// 已有请求正在补页：用当前进度先响应，不并发抢资源。
			store.mu.Unlock()
			return
		}
		store.inflight[category] = true
		page := loaded + 1
		store.mu.Unlock()

		data, err := coreCall(map[string]any{
			"action": "audiobookHongguoCatalog", "category": category, "page": page,
		})

		store.mu.Lock()
		store.inflight[category] = false
		if err != nil {
			store.errText[category] = err.Error()
			store.mu.Unlock()
			return
		}
		// 只接受「紧接着已加载页」的那一页，避免与并发请求交错写乱。
		if store.pages[category] == page-1 {
			known := make(map[string]bool)
			for _, book := range store.books[category] {
				known[fmt.Sprint(book["id"])] = true
			}
			for _, item := range audiobookAnyList(data["books"]) {
				row, ok := item.(map[string]any)
				if !ok {
					continue
				}
				rawID, exists := row["id"]
				if !exists || rawID == nil {
					continue
				}
				id := fmt.Sprint(rawID)
				if id == "" || known[id] {
					continue
				}
				known[id] = true
				store.books[category] = append(store.books[category], row)
			}
			store.pages[category] = page
			store.hasMore[category] = data["hasMore"] == true
			store.errText[category] = ""
		}
		store.mu.Unlock()
	}
}

// snapshot 返回已加载书池与状态。loading 恒 false：本次请求已同步取完页，
// 没有任何后台任务，前端的定时补全不会再被触发。
func (store *abHongguoStore) snapshot(category string) ([]map[string]any, map[string]any) {
	store.mu.Lock()
	defer store.mu.Unlock()
	books := append([]map[string]any(nil), store.books[category]...)
	info := map[string]any{
		"loading": false,
		"done":    true,
		"count":   len(books),
		"error":   store.errText[category],
		"hasMore": store.hasMore[category],
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

	// 搜索走红果自己的搜索接口，不依赖书池：搜索时一本书池页都不取，
	// 也就不产生任何后台加载。
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

	// 按需加载：只取到能覆盖当前请求页的页数，取完立刻结束。
	// 没有后台 goroutine，也没有定时轮询；用户翻到下一页才会再补一页。
	needPages := (page*size + abHongguoCatalogPageSize - 1) / abHongguoCatalogPageSize
	if needPages < 1 {
		needPages = 1
	}
	abHongguo.ensurePages(channel, needPages)

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
	// 上游还有更多时多留一页：用户点「下一页」才触发下一次按页加载。
	if info["hasMore"] == true {
		pageCount++
	}
	if page > pageCount {
		page = pageCount
	}
	start := (page - 1) * size
	// hasMore 时 pageCount 多留了一页，补页失败或并发让道时这一页可能
	// 还没有数据；把 start 钳到 total，返回空页而不是让切片越界 panic。
	if start > total {
		start = total
	}
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

// abHongguoPrefix 给红果书籍 ID 加 hg: 前缀。
//
// 必须幂等：这个函数会被多条路径调用（书库快照、分页切片），同一条记录可能
// 被加多次。之前不做判断，结果 ID 变成 hg:hg:hg:...，目录接口拿到的 ID 无效，
// 前端就永远卡在「正在加载目录」。
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
		book["id"] = abHongguoBookID(id)
		out = append(out, book)
	}
	return out
}

// abHongguoBookID 把红果 ID 规范化成「带一次 hg: 前缀」的形式。
// 已经带前缀的会先剥干净再加，保证无论调用多少次结果都一样。
func abHongguoBookID(id string) string {
	id = strings.TrimSpace(id)
	for strings.HasPrefix(id, abHongguoBookPrefix) {
		id = strings.TrimPrefix(id, abHongguoBookPrefix)
	}
	return abHongguoBookPrefix + id
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
			// 让「正文 / 播放」两条按 ID 判书源的路径可靠区分。同样要幂等。
			if id := strings.TrimSpace(asString(row["id"])); id != "" {
				row["id"] = abHongguoBookID(id)
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

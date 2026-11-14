package main

import (
	"net/http"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"
)

// 听书全量书库（Web 服务器版）。
//
// 与 App 端 lib/ui/audiobook/audiobook_fanqie.dart 的 rankAll 同一套修复：
// 榜单接口忽略 limit、固定每页 30 条，has_more 恒为 false，只有 offset 递增
// 才会持续返回新书；男/女榜各约 34 页、book_id 不重叠，合计约 2040 本。
// 这里在服务端后台分批并发抓全量并缓存，浏览器只拿当前页，多标签页共享一份
// 书池，不必每个页面都把上游翻一遍。分类用榜单自带的 category_v2 真实标签，
// 搜索以全量书池本地匹配为主、服务端搜索结果补充书池之外的听书。

const (
	audiobookRankStep      = 30 // 榜单固定每页 30 条，offset 步长必须也是 30
	audiobookRankBatch     = 6  // 每批并发页数
	audiobookRankMaxPages  = 60 // 单榜翻页上限（实测约 34 页见底）
	audiobookLibraryTTL    = 6 * time.Hour
	audiobookLibraryPage   = 10 // 与 App 端 _pageSize 一致
	audiobookRemoteTimeout = 4 * time.Second
)

type audiobookBoardDef struct {
	key  string
	side string
	kind string
}

var audiobookBoardDefs = []audiobookBoardDef{
	{"17:1", "17", "1"}, // 听书榜（男生）
	{"17:0", "17", "0"}, // 女生听书
}

// 番茄畅听榜单返回的 category_v2 真实标签，顺序与 App 端
// fanqieAudiobookCategories 完全一致；只展示当前书池里确实有书的分类。
var audiobookCategoryOrder = []string{
	"都市", "玄幻", "悬疑", "灵异", "推理", "历史", "系统", "穿越", "重生",
	"民俗秘闻", "游戏体育", "都市生活", "科幻末世", "战神赘婿", "现代言情",
	"古代言情", "豪门总裁", "宫斗宅斗", "年代", "种田", "神医", "女强",
	"玄幻言情", "先婚后爱",
}

// 听书页的两个书源：红果听书吃官方书城听书专辑，番茄听书吃畅听男女榜。
const (
	abOriginHongguo = "hongguo"
	abOriginFanqie  = "fanqie"
	// abOriginAll 保留旧接口「榜单 + 官方书城合并」的行为。
	abOriginAll = "all"
)

func abNormalizeOrigin(origin string) string {
	switch {
	case strings.EqualFold(strings.TrimSpace(origin), abOriginFanqie):
		return abOriginFanqie
	case strings.EqualFold(strings.TrimSpace(origin), abOriginAll):
		return abOriginAll
	default:
		// 默认红果听书。
		return abOriginHongguo
	}
}

type audiobookBook struct {
	ID       string
	Title    string
	Author   string
	Category string
	Cover    string
	Intro    string
	Board    int    // 0 男生榜 / 1 女生榜
	Anchor   string // 有声书主播；为空说明没有真人录制
}

func (book audiobookBook) payload() map[string]any {
	return map[string]any{
		"id": book.ID, "title": book.Title, "author": book.Author,
		"category": book.Category, "cover": book.Cover,
		"intro": book.Intro, "board": book.Board,
		"anchor": book.Anchor, "voiceMode": abVoiceMode(book.Anchor),
	}
}

// abVoiceMode 与 App 端同规则：有真人主播名是「真人录音」，否则是 AI 音色朗读。
func abVoiceMode(anchor string) string {
	anchor = strings.ToLower(strings.TrimSpace(anchor))
	if anchor == "" {
		return "AI 朗读"
	}
	for _, hint := range []string{"ai", "智能", "机器", "合成", "tts", "番茄畅听", "番茄小说", "听书助手"} {
		if strings.Contains(anchor, hint) {
			return "AI 朗读"
		}
	}
	return "真人录音"
}

type audiobookLibrarySnapshot struct {
	pool       []audiobookBook
	rank       []audiobookBook // 只含畅听男女榜，供「番茄听书」
	official   []audiobookBook // 只含官方书城听书专辑，供「红果听书」
	categories []string
	loading    bool
	done       bool
	errText    string
}

type audiobookLibraryStore struct {
	mu         sync.RWMutex
	boards     map[string][]audiobookBook
	official   map[string]audiobookBook // 官方书城实时抓到的书，跨榜单刷新累积
	merged     []audiobookBook
	categories []string
	loading    bool
	done       bool
	errText    string
	finished   time.Time
	generation uint64
}

var abLibrary = &audiobookLibraryStore{boards: map[string][]audiobookBook{}}

// 上游请求仍由 Go 核心代发，限一下并发，避免翻全库时把番茄接口打爆。
var abFetchSlots = make(chan struct{}, audiobookRankBatch)

// ensure 在缓存过期或首次访问时触发后台抓取；抓取期间旧书池继续可用。
func (store *audiobookLibraryStore) ensure() {
	store.mu.Lock()
	if store.loading {
		store.mu.Unlock()
		return
	}
	if store.done && time.Since(store.finished) < audiobookLibraryTTL {
		store.mu.Unlock()
		return
	}
	store.generation++
	generation := store.generation
	store.loading = true
	store.done = false
	store.errText = ""
	store.boards = map[string][]audiobookBook{}
	// 榜单重新抓取期间，官方书城已抓到的书仍然可用，不要把书池清空。
	store.rebuildLocked()
	store.mu.Unlock()
	abRefreshOfficialLibrary()
	go store.load(generation)
}

func (store *audiobookLibraryStore) load(generation uint64) {
	var wait sync.WaitGroup
	for _, board := range audiobookBoardDefs {
		wait.Add(1)
		go func(board audiobookBoardDef) {
			defer wait.Done()
			pool := make([]audiobookBook, 0, 1024)
			seen := map[string]bool{}
			page := 1
			emptyBatches := 0
			for page <= audiobookRankMaxPages && emptyBatches < 2 {
				batch := make([]int, 0, audiobookRankBatch)
				for len(batch) < audiobookRankBatch && page <= audiobookRankMaxPages {
					batch = append(batch, page)
					page++
				}
				results := make([][]audiobookBook, len(batch))
				var inner sync.WaitGroup
				for position, number := range batch {
					inner.Add(1)
					go func(position, number int) {
						defer inner.Done()
						abFetchSlots <- struct{}{}
						defer func() { <-abFetchSlots }()
						books, err := abFetchRankPage(board.side, board.kind, number)
						if err == nil {
							results[position] = books
						}
					}(position, number)
				}
				inner.Wait()
				nonEmpty := 0
				for _, books := range results {
					if len(books) > 0 {
						nonEmpty++
					}
					for _, book := range books {
						if book.ID != "" && !seen[book.ID] {
							seen[book.ID] = true
							pool = append(pool, book)
						}
					}
				}
				// 单页失败不算翻到底，连续两批出现空页才停。
				if nonEmpty < len(batch) {
					emptyBatches++
				} else {
					emptyBatches = 0
				}
				store.publish(generation, board.key, pool)
			}
		}(board)
	}
	wait.Wait()
	store.mu.Lock()
	if generation == store.generation {
		store.loading = false
		store.done = true
		store.finished = time.Now()
		if len(store.merged) == 0 {
			store.errText = "番茄畅听榜单暂时没有书"
		}
	}
	store.mu.Unlock()
}

// publish 每批回吐一次，书库边加载边可用，不必等全部抓完。
func (store *audiobookLibraryStore) publish(generation uint64, key string, pool []audiobookBook) {
	store.mu.Lock()
	defer store.mu.Unlock()
	if generation != store.generation {
		return
	}
	store.boards[key] = append([]audiobookBook(nil), pool...)
	store.rebuildLocked()
}

// publishOfficial 在官方书城刷新出书后重算书池；官方书按 gender 归到男/女榜，
// 与榜单书按 book_id 去重，榜单已抓到的书优先保留其原始分类与封面。
func (store *audiobookLibraryStore) publishOfficial() {
	books, _ := abOfficialSnapshot()
	store.mu.Lock()
	defer store.mu.Unlock()
	store.official = make(map[string]audiobookBook, len(books))
	for _, book := range books {
		store.official[book.ID] = book
	}
	store.rebuildLocked()
}

// rebuildLocked 合并三个来源：男榜、女榜、官方书城。调用方必须持有写锁。
func (store *audiobookLibraryStore) rebuildLocked() {
	seen := map[string]bool{}
	merged := make([]audiobookBook, 0, 2048)
	for index, board := range audiobookBoardDefs {
		for _, book := range store.boards[board.key] {
			if seen[book.ID] {
				continue
			}
			seen[book.ID] = true
			book.Board = index
			merged = append(merged, book)
		}
	}
	for _, book := range store.official {
		if book.ID == "" || seen[book.ID] {
			continue
		}
		seen[book.ID] = true
		merged = append(merged, book)
	}
	store.merged = merged
	store.categories = abCategoriesFrom(merged)
}

func (store *audiobookLibraryStore) snapshot() audiobookLibrarySnapshot {
	store.mu.RLock()
	defer store.mu.RUnlock()
	rank := make([]audiobookBook, 0, len(store.merged))
	seen := map[string]bool{}
	for _, board := range audiobookBoardDefs {
		for _, book := range store.boards[board.key] {
			if seen[book.ID] {
				continue
			}
			seen[book.ID] = true
			rank = append(rank, book)
		}
	}
	official := make([]audiobookBook, 0, len(store.official))
	for _, book := range store.official {
		official = append(official, book)
	}
	return audiobookLibrarySnapshot{
		pool:       append([]audiobookBook(nil), store.merged...),
		rank:       rank,
		official:   official,
		categories: append([]string(nil), store.categories...),
		loading:    store.loading,
		done:       store.done,
		errText:    store.errText,
	}
}

// query 返回当前过滤 / 搜索结果的某一页。抓取中也能用，前端按 loading 轮询即可。
// origin 决定书源：fanqie=番茄听书（畅听男女榜 + 官方书城听书专辑），
// all=两者合并；红果听书不走这里（由 handleAudiobookLibrary 直接转红果接口）。
func (store *audiobookLibraryStore) query(origin string, board int, category, keyword string, page, size int) map[string]any {
	store.ensure()
	snapshot := store.snapshot()
	pool := snapshot.pool
	switch abNormalizeOrigin(origin) {
	case abOriginFanqie:
		// 番茄听书现在也含官方书城的听书专辑：原来「红果听书」的真人剧内容
		// 已合并进来，书源名仍叫「番茄听书」。
		pool = snapshot.pool
	case abOriginAll:
		pool = snapshot.pool
	default:
		pool = snapshot.official
	}
	if board < 0 || board >= len(audiobookBoardDefs) {
		board = 0
	}
	if size < 1 || size > 50 {
		size = audiobookLibraryPage
	}
	list := make([]audiobookBook, 0, len(pool))
	switch {
	case keyword != "":
		// 全量书池本地匹配为主；服务端搜索补的是番茄畅听的书，
		// 红果听书只用官方书城书池，不能把榜单书混进来。
		seen := map[string]bool{}
		add := func(books []audiobookBook) {
			for _, book := range books {
				if book.ID == "" || seen[book.ID] {
					continue
				}
				seen[book.ID] = true
				list = append(list, book)
			}
		}
		add(abSearchInPool(pool, keyword))
		if abNormalizeOrigin(origin) != abOriginHongguo {
			add(abRemoteSearchFunc(keyword))
		}
	case category != "":
		// 分类来自真实标签，选分类时把男/女两榜合并后的全量书库一起过滤。
		for _, book := range pool {
			if abMatchesCategory(book, category) {
				list = append(list, book)
			}
		}
	default:
		for _, book := range pool {
			if book.Board == board {
				list = append(list, book)
			}
		}
	}
	total := len(list)
	pageCount := (total + size - 1) / size
	if pageCount < 1 {
		pageCount = 1
	}
	if page < 1 {
		page = 1
	}
	if page > pageCount {
		page = pageCount
	}
	start := (page - 1) * size
	end := start + size
	if end > total {
		end = total
	}
	books := make([]map[string]any, 0, end-start)
	for _, book := range list[start:end] {
		books = append(books, book.payload())
	}
	return map[string]any{
		"books":      books,
		"total":      total,
		"page":       page,
		"pageCount":  pageCount,
		"categories": abCategoriesFrom(pool),
		"origin":     abNormalizeOrigin(origin),
		"library": map[string]any{
			"loading": snapshot.loading,
			"done":    snapshot.done,
			"count":   len(pool),
			"error":   snapshot.errText,
		},
	}
}

// —— 榜单 / 搜索原始解析 ——

func abFetchRankPage(side, kind string, page int) ([]audiobookBook, error) {
	offset := (page - 1) * audiobookRankStep
	target := "https://api.fanqiesdk.com/api/novel/channel/homepage/rank/rank_list/v2/" +
		"?aid=13&limit=" + strconv.Itoa(audiobookRankStep) +
		"&offset=" + strconv.Itoa(offset) +
		"&side_type=" + url.QueryEscape(side) + "&type=" + url.QueryEscape(kind)
	root, err := audiobookFetchJSON(target, nil)
	if err != nil {
		return nil, err
	}
	return abRankBooks(root), nil
}

func abRankBooks(root map[string]any) []audiobookBook {
	return abBooksFromRows(audiobookRows(audiobookObject(root["data"])["result"]))
}

func abSearchBooks(root map[string]any) []audiobookBook {
	data := audiobookObject(root["data"])
	rows := audiobookRows(data["list"])
	if len(rows) == 0 {
		rows = audiobookRows(data["ret_data"])
	}
	return abBooksFromRows(rows)
}

func abBooksFromRows(rows []map[string]any) []audiobookBook {
	books := make([]audiobookBook, 0, len(rows))
	for _, row := range rows {
		// 只保留听书（genre=4），与 App 端一致，避免混进小说。
		if asString(row["genre"]) != audiobookGenre {
			continue
		}
		id := strings.TrimSpace(asString(row["book_id"]))
		title := abInlineText(audiobookText2(firstNonEmpty(row["book_name"], row["title"])))
		if id == "" || title == "" {
			continue
		}
		books = append(books, audiobookBook{
			ID:       id,
			Title:    title,
			Author:   abInlineText(audiobookText2(row["author"])),
			Category: abRowCategory(row),
			Cover:    strings.TrimSpace(asString(row["thumb_url"])),
			Intro:    abInlineText(asString(row["abstract"])),
		})
	}
	return books
}

// abRowCategory 优先用 category_v2 标签数组，回落 category 逗号串。
func abRowCategory(row map[string]any) string {
	if value := row["category_v2"]; value != nil {
		switch typed := value.(type) {
		case []any:
			parts := make([]string, 0, len(typed))
			for _, item := range typed {
				if text := strings.TrimSpace(abInlineText(asString(item))); text != "" {
					parts = append(parts, text)
				}
			}
			if len(parts) > 0 {
				return strings.Join(parts, " · ")
			}
		case string:
			if text := strings.TrimSpace(abInlineText(typed)); text != "" {
				return text
			}
		}
	}
	return abInlineText(audiobookText2(row["category"]))
}

var abBreakTag = regexp.MustCompile(`(?i)<br\s*/?>`)
var abAnyTag = regexp.MustCompile(`<[^>]+>`)

// abInlineText 去掉番茄的 <em> 高亮、<br> 与其余标签，简介压成一行。
func abInlineText(value string) string {
	value = abBreakTag.ReplaceAllString(value, " ")
	value = abAnyTag.ReplaceAllString(value, "")
	value = strings.ReplaceAll(value, "&nbsp;", " ")
	return strings.TrimSpace(strings.Join(strings.Fields(value), " "))
}

// 可替换便于单测隔离网络；生产环境就是 abRemoteSearch。
var abRemoteSearchFunc = abRemoteSearch

// abRemoteSearch 带超时：本地书池结果先出，慢请求不拖住整个页面。
func abRemoteSearch(keyword string) []audiobookBook {
	result := make(chan []audiobookBook, 1)
	go func() {
		target := "https://api.fanqiesdk.com/api/novel/channel/homepage/search/search/v1/" +
			"?q=" + url.QueryEscape(keyword) + "&offset=0" +
			"&aid=13&app_name=news_article&version_name=7.0.8&device_platform=android"
		root, err := audiobookFetchJSON(target, nil)
		if err != nil {
			result <- nil
			return
		}
		result <- abSearchBooks(root)
	}()
	select {
	case books := <-result:
		return books
	case <-time.After(audiobookRemoteTimeout):
		return nil
	}
}

// —— 分类与全库搜索 ——

func abSplitTags(value string) []string {
	return strings.FieldsFunc(value, func(r rune) bool {
		return r == '·' || r == ',' || r == '，' || r == '、' || r == '/' || unicode.IsSpace(r)
	})
}

func abMatchesCategory(book audiobookBook, category string) bool {
	if category == "" {
		return true
	}
	for _, tag := range abSplitTags(book.Category) {
		if tag == category {
			return true
		}
	}
	return false
}

// abCategoriesFrom 只展示书池里确实有书的分类。
// 候选名 = 榜单高频基线 + 官方书城实时返回的 category_info / popular_tags，
// 顺序保持「主类在前、官方 Dim 从小到大」，不是写死的一份静态清单。
func abCategoriesFrom(pool []audiobookBook) []string {
	counts := map[string]int{}
	for _, book := range pool {
		for _, tag := range abSplitTags(book.Category) {
			counts[tag]++
		}
	}
	_, official := abOfficialSnapshot()
	order := make([]string, 0, len(audiobookCategoryOrder)+len(official))
	order = append(order, audiobookCategoryOrder...)
	for _, name := range official {
		if !containsString(order, name) {
			order = append(order, name)
		}
	}
	categories := make([]string, 0, len(order))
	for _, name := range order {
		if counts[name] > 0 {
			categories = append(categories, name)
		}
	}
	return categories
}

type abScoredBook struct {
	book  audiobookBook
	score int
}

// abSearchInPool 与 App 端 fanqieSearchInPool 等价：空格分词需全部命中，
// 书名 / 分类 / 作者 / 简介分别计 4 / 3 / 2 / 1 分，按相关度排序。
func abSearchInPool(pool []audiobookBook, keyword string) []audiobookBook {
	words := strings.Fields(strings.ToLower(strings.TrimSpace(keyword)))
	if len(words) == 0 {
		return nil
	}
	scored := make([]abScoredBook, 0)
	for _, book := range pool {
		title := strings.ToLower(book.Title)
		author := strings.ToLower(book.Author)
		category := strings.ToLower(book.Category)
		intro := strings.ToLower(book.Intro)
		haystack := title + " " + author + " " + category + " " + intro
		matched := true
		for _, word := range words {
			if !strings.Contains(haystack, word) {
				matched = false
				break
			}
		}
		if !matched {
			continue
		}
		score := 0
		for _, word := range words {
			if strings.Contains(title, word) {
				score += 4
			}
			if strings.Contains(category, word) {
				score += 3
			}
			if strings.Contains(author, word) {
				score += 2
			}
			if strings.Contains(intro, word) {
				score += 1
			}
		}
		scored = append(scored, abScoredBook{book: book, score: score})
	}
	sort.SliceStable(scored, func(i, j int) bool {
		return scored[i].score > scored[j].score
	})
	books := make([]audiobookBook, 0, len(scored))
	for _, item := range scored {
		books = append(books, item.book)
	}
	return books
}

func abQueryHasMore(data map[string]any) bool {
	page, _ := data["page"].(int)
	count, _ := data["pageCount"].(int)
	return page < count
}

// GET /api/audiobook/library?board=0&category=&q=&page=1&size=10
func handleAudiobookLibrary(writer http.ResponseWriter, request *http.Request) {
	params := request.URL.Query()
	board, _ := strconv.Atoi(params.Get("board"))
	page, _ := strconv.Atoi(params.Get("page"))
	size, _ := strconv.Atoi(params.Get("size"))
	// 红果听书走红果 App 的官方书城接口（听书 / 小说两个频道），
	// 不再从番茄书库里拼数据；番茄听书保留原书库（畅听榜 + 官方听书专辑）。
	if abNormalizeOrigin(params.Get("origin")) == abOriginHongguo {
		writeJSON(writer, map[string]any{"ok": true, "data": abHongguoLibrary(
			board, strings.TrimSpace(params.Get("q")), page, size,
		)})
		return
	}
	// 官方书城单独按 10 分钟 TTL 刷新，不受榜单书池 6 小时缓存牵制。
	abRefreshOfficialLibrary()
	answer := abLibrary.query(
		abNormalizeOrigin(params.Get("origin")),
		board,
		strings.TrimSpace(params.Get("category")),
		strings.TrimSpace(params.Get("q")),
		page,
		size,
	)
	answer["official"] = abOfficialStatus()
	writeJSON(writer, map[string]any{"ok": true, "data": answer})
}

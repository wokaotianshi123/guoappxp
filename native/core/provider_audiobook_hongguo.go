package core

// 红果听书（听书 / 小说）书源。
//
// 数据全部来自红果 App 的官方书城接口（与短剧共用设备签名管道），
// 由 Flutter 听书页与本地服务版 /api/audiobook/* 共用：
//   - 目录：bookmall tab（tab_type=5 听书、2 小说），按推荐流分页；
//   - 搜索：search/tab/v1，按分类选 tab；
//   - 详情：detail/v1 + directory/all_items/v1；
//   - 播放：reader/audio/playinfo，加密音频给 CENC key。
//
// 书籍 ID 是纯数字，与番茄的 book_id 可能重号，前端统一加 "hg:" 前缀区分，
// 本文件只处理裸 ID。

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	audiobookHongguoDetailPath   = "/reading/bookapi/detail/v1/"
	audiobookHongguoTonePath     = "/reading/bookapi/audio/toneinfo/"
	audiobookHongguoDirectory    = "/reading/bookapi/directory/all_items/v1/"
	audiobookHongguoPlayInfoPath = "/reading/reader/audio/playinfo/"
	audiobookHongguoSearchPath   = "/reading/bookapi/search/tab/v1/"
	audiobookHongguoSearchSize   = 10
)

// audiobookHongguoCategory 是听书页的两个频道。
//
// 注意两套编号不一样，混用会拿到错的数据：
//   - BookmallTab 是「书城 tab」的频道号（听书 5、小说 2），目录/推荐流用它；
//   - SearchTab 是「搜索结果 tab」的频道号（听书 2、小说 1），搜索用它。
//
// 实测：书城 5 是听书、2 是小说；搜索里 tab_type=2 是「听书」、1 是「小说」，
// 搜索 5 则不存在（返回空 tab）。两者语义重叠但编号不同，必须分开存。
type audiobookHongguoCategory struct {
	ID          string
	Name        string
	BookmallTab string
	SearchTab   string
}

var audiobookHongguoCategories = []audiobookHongguoCategory{
	{ID: "listen", Name: "听书", BookmallTab: "5", SearchTab: "2"},
	{ID: "novel", Name: "小说", BookmallTab: "2", SearchTab: "1"},
}

func audiobookHongguoCategoryFor(category string) (audiobookHongguoCategory, bool) {
	category = strings.TrimSpace(strings.ToLower(category))
	if category == "" {
		return audiobookHongguoCategories[0], true
	}
	for _, entry := range audiobookHongguoCategories {
		if entry.ID == category {
			return entry, true
		}
	}
	return audiobookHongguoCategory{}, false
}

// AudiobookHongguoCategories 供前端渲染分类条，两种版本都返回「听书 / 小说」。
func AudiobookHongguoCategories() []NativeCategory {
	out := make([]NativeCategory, 0, len(audiobookHongguoCategories))
	for _, entry := range audiobookHongguoCategories {
		out = append(out, NativeCategory{ID: entry.ID, Name: entry.Name})
	}
	return out
}

// audiobookHongguoBook 把书城 / 搜索返回的一条 book_data 转成前端需要的形状。
// 字段名与听书页现有的书模型对齐，前端不需要为红果单独写一套。
func audiobookHongguoBook(book map[string]any, category audiobookHongguoCategory) map[string]any {
	sourceID := mapString(book, "book_id", "bookId")
	if !hongguoNumericID.MatchString(sourceID) {
		return nil
	}
	title := mapString(book, "book_name", "bookName", "original_book_name")
	if title == "" {
		title = sourceID
	}
	cover := firstNonEmpty(
		mapString(book, "audio_thumb_url_hd", "audio_thumb_url"),
		mapString(book, "thumb_url", "horiz_thumb_url"),
	)
	intro := mapString(book, "abstract", "book_abstract")
	genre := mapString(book, "category", "genre_name")
	count := mapString(book, "chapter_number", "serial_count", "chapterNumber")
	voice := ""
	switch mapString(book, "genre") {
	case "4":
		voice = "真人录音"
	case "0", "6":
		voice = "AI 朗读"
	}
	remark := ""
	if count != "" {
		remark = "共" + count + "章"
	}
	board := 0
	if category.ID == "novel" {
		board = 1
	}
	// 听书页用 anchor 是否为空判断「真人录音 / AI 朗读」：红果详情不总给主播名，
	// 真人频道又没有主播名时用频道标签兜底，避免把真人录制标成 AI。
	anchor := mapString(book, "speaker", "anchor", "reader_name")
	if anchor == "" && voice == "真人录音" {
		anchor = voice
	}
	return map[string]any{
		"id":       sourceID,
		"title":    title,
		"author":   mapString(book, "author", "author_name"),
		"category": firstNonEmpty(genre, category.Name),
		"cover":    cover,
		"intro":    intro,
		"anchor":   anchor,
		"voice":    voice,
		"board":    board,
		"total":    count,
		"remark":   remark,
		"source":   "hongguo",
	}
}

// audiobookHongguoBooksOf 深度遍历推荐流里的 book_data 数组。
func audiobookHongguoBooksOf(value any) []map[string]any {
	var out []map[string]any
	var walk func(any, int)
	walk = func(node any, depth int) {
		if depth > 8 {
			return
		}
		switch typed := node.(type) {
		case []any:
			for _, item := range typed {
				walk(item, depth+1)
			}
		case map[string]any:
			if list, ok := typed["book_data"].([]any); ok {
				for _, item := range list {
					if book, ok := item.(map[string]any); ok {
						out = append(out, book)
					}
				}
			}
			for key, item := range typed {
				if key == "book_data" {
					continue
				}
				switch item.(type) {
				case []any, map[string]any:
					walk(item, depth+1)
				}
			}
		}
	}
	walk(value, 0)
	return out
}

// audiobookHongguoFeed 取一批书城推荐流（offset=0 的首页）。
func (d *Downloader) audiobookHongguoFeed(ctx context.Context, category audiobookHongguoCategory, offset int) ([]map[string]any, string, string, string, bool, error) {
	requestType := "1"
	if offset > 0 {
		requestType = "2"
	}
	extra := url.Values{
		"tab_type":        {category.BookmallTab},
		"offset":          {strconv.Itoa(offset)},
		"client_req_type": {requestType},
	}
	result, err := d.hongguoAppRequest(ctx, http.MethodGet, hongguoBookmallTabPath, extra, nil)
	if err != nil {
		return nil, "", "", "", false, err
	}
	for _, row := range anyList(nestedMap(result, "data")["tab_item"]) {
		item, _ := row.(map[string]any)
		if mapString(item, "tab_type") != category.BookmallTab {
			continue
		}
		// 书城 tab 只给「首屏 cell」，真正翻页靠 cell/change（见 audiobookHongguoCellPage）。
		var cellID, showType string
		if cells := anyList(item["cell_data"]); len(cells) > 0 {
			cell, _ := cells[0].(map[string]any)
			cellID, showType = mapString(cell, "cell_id"), mapString(cell, "show_type")
		}
		hasMore, _ := item["has_more"].(bool)
		return audiobookHongguoBooksOf(item), cellID, showType, mapString(item, "session_id"), hasMore, nil
	}
	return nil, "", "", "", false, errors.New("红果听书频道数据格式异常")
}

// audiobookHongguoCellPage 用 cell/change 翻一页。
//
// 书城 tab 的 has_more 恒为 false，分页全在这个接口上：offset 每页步进 10，
// 单页返回 10~12 本且与上一页有重叠（实测 offset=10 的 12 本里只有 4 本是新的），
// 所以调用方必须按 book_id 去重。
func (d *Downloader) audiobookHongguoCellPage(ctx context.Context, category audiobookHongguoCategory, cellID, showType, session string, offset int) ([]map[string]any, bool, int, error) {
	// 听书翻页单独一条 lane：书城接口与红果短剧共用同一个 host，
	// 共用 gate 时翻近百页会把短剧首页/详情一起堵住（用户感知就是「刚打开
	// 软件就卡」）。分 lane 后两边各走各的节奏，互不阻塞。
	ctx = context.WithValue(ctx, requestLaneKey{}, "hongguo-audiobook")
	extra := url.Values{
		"cell_id":         {cellID},
		"change_type":     {"0"},
		"offset":          {strconv.Itoa(offset)},
		"limit":           {"10"},
		"session_id":      {session},
		"tab_type":        {category.BookmallTab},
		"client_req_type": {"2"},
		"show_type":       {showType},
	}
	result, err := d.hongguoAppRequest(ctx, http.MethodGet, hongguoBookmallCellChangePath, extra, nil)
	if err != nil {
		return nil, false, 0, err
	}
	data := nestedMap(result, "data")
	books := audiobookHongguoBooksOf(nestedMap(data, "cell_view"))
	hasMore, _ := data["has_more"].(bool)
	next, parseErr := strconv.Atoi(mapString(data, "next_offset"))
	if parseErr != nil || next <= offset {
		// next_offset 没前进说明已经到底，避免调用方死循环。
		hasMore = false
	}
	return books, hasMore, next, nil
}

// audiobookHongguoCatalog 返回一页书单。
//
// 书城是「一个 cell 无限往下翻」的形态：page 1 是首屏（12 本），之后每页
// 对应 cell/change 的一次 offset 步进（10）。known 由调用方传入已展示的 ID，
// 用来过滤相邻页重叠的部分。
func (d *Downloader) audiobookHongguoCatalog(ctx context.Context, category string, page int, known map[string]bool) ([]map[string]any, bool, error) {
	spec, ok := audiobookHongguoCategoryFor(category)
	if !ok {
		return nil, false, errors.New("红果听书分类无效")
	}
	if page < 1 {
		page = 1
	}
	first, cellID, showType, session, _, err := d.audiobookHongguoFeed(ctx, spec, 0)
	if err != nil {
		return nil, false, err
	}
	var raw []map[string]any
	hasMore := true
	if page == 1 {
		raw = first
	} else {
		if cellID == "" {
			return nil, false, errors.New("红果听书频道未返回可翻页的栏目")
		}
		// 第 N 页对应 offset=(N-1)*10；cell/change 的 next_offset 与步进一致。
		offset := (page - 1) * 10
		raw, hasMore, _, err = d.audiobookHongguoCellPage(ctx, spec, cellID, showType, session, offset)
		if err != nil {
			return nil, false, err
		}
	}
	out := make([]map[string]any, 0, len(raw))
	seen := map[string]bool{}
	for _, book := range raw {
		entry := audiobookHongguoBook(book, spec)
		if entry == nil {
			continue
		}
		id := entry["id"].(string)
		if seen[id] || known[id] {
			continue
		}
		seen[id] = true
		out = append(out, entry)
	}
	// 单页被 known 过滤空（整页重叠）时也要允许继续翻，否则列表会假到底。
	if len(out) == 0 && hasMore {
		hasMore = true
	}
	return out, hasMore, ctx.Err()
}

// audiobookHongguoPoolEntry 是某个频道的书池缓存。
//
// 全量翻页要近百次请求，受「同一 host 每 250ms 一次」的限流约束，实测约 60 秒。
// 用户在两个书源之间来回切换时如果每次都重抓，必然卡死。这里按频道缓存，
// 并且**边翻边发布**：首屏只等第一批，其余在后台继续累积，
// 前端按 loading 标记轮询即可逐步补全，不用干等一分钟。
type audiobookHongguoPoolEntry struct {
	books    []map[string]any
	loadedAt time.Time // 全量抓完的时间；零值表示还没抓完过
	loading  bool
}

var audiobookHongguoPoolCache = struct {
	sync.Mutex
	entries map[string]*audiobookHongguoPoolEntry
}{entries: map[string]*audiobookHongguoPoolEntry{}}

const audiobookHongguoPoolTTL = 30 * time.Minute

// audiobookHongguoPoolBudget 是单轮全量抓取的时间上限。
// 正常约 60 秒能翻完；给 5 分钟余量，站点卡住时也不会无限占资源。
const audiobookHongguoPoolBudget = 5 * time.Minute

// audiobookHongguoPoolSnapshot 读某频道的书池快照与状态。
func audiobookHongguoPoolSnapshot(category string) (books []map[string]any, loading, stale, ok bool) {
	spec, valid := audiobookHongguoCategoryFor(category)
	if !valid {
		return nil, false, false, false
	}
	cache := &audiobookHongguoPoolCache
	cache.Lock()
	defer cache.Unlock()
	entry := cache.entries[spec.ID]
	if entry == nil {
		return nil, false, false, true
	}
	books = append([]map[string]any(nil), entry.books...)
	loading = entry.loading
	// loadedAt 为零说明从没抓完过，这份数据只是「不完整」，不算过期。
	stale = !entry.loadedAt.IsZero() && time.Since(entry.loadedAt) >= audiobookHongguoPoolTTL
	return books, loading, stale, true
}

// audiobookHongguoPoolStart 确保某频道有后台抓取在跑，并返回书池。
//
// since 是调用方已持有的书数：传 0 返回全量；传已持有的数量则只返回**新增**
// 那部分（增量），配合 total 字段让前端追加即可。轮询时用增量能避免每次把
// 上千本书（含封面 / 简介）重复序列化过 IPC——那是卡顿的主因。
//
// 首次调用（缓存为空）会短暂阻塞等首屏那一批，让界面立刻有书可看；
// 之后的全量翻页在后台继续，调用方按 loading 轮询补全。
func (d *Downloader) audiobookHongguoPoolStart(ctx context.Context, category string, maxPages int, force bool, since int) (books []map[string]any, total int, loading, needFetch bool) {
	spec, ok := audiobookHongguoCategoryFor(category)
	if !ok {
		return nil, 0, false, false
	}
	cache := &audiobookHongguoPoolCache
	cache.Lock()
	entry := cache.entries[spec.ID]
	if entry == nil {
		entry = &audiobookHongguoPoolEntry{}
		cache.entries[spec.ID] = entry
	}
	fresh := !entry.loadedAt.IsZero() && time.Since(entry.loadedAt) < audiobookHongguoPoolTTL
	needFetch = force || !fresh
	empty := len(entry.books) == 0
	alreadyLoading := entry.loading
	if needFetch && !alreadyLoading {
		entry.loading = true
	}
	cache.Unlock()

	// 缓存为空且本轮刚开始：先把首屏那一批抢出来，别让界面空着。
	//
	// 关键：这次用**前台**身份请求（不带 backgroundCatalogKey）。首屏只有 1 次
	// 请求、用户正在等，如果也当后台任务，就得排队等短剧请求全空闲，
	// 用户感知就是「刚打开软件点听书半天没反应」。后续那近百页翻页才走后台。
	//
	// 顺序也很重要：必须**先** seed **再**启动后台翻页，否则两者同时抢
	// 同一个 host 的限流节奏，首屏反而被自己人堵住。
	if empty && !alreadyLoading {
		seedCtx, cancel := context.WithTimeout(ctx, 6*time.Second)
		d.audiobookHongguoPoolSeed(seedCtx, spec)
		cancel()
	}

	if needFetch && !alreadyLoading {
		// 后台抓取带超时：站点卡住时不会永远占着那一个并发槽。
		// 用 WithoutCancel 是为了用户切页/关页面时别丢掉已抓到的数据，
		// 但抓取本身必须有上限，否则会一直耗资源。
		//
		// 打上 backgroundCatalogKey 是关键：让限流器把它当后台任务，
		// 只占 1 个并发槽、且必须等前台空闲才发请求。否则这近百次翻页
		// 会以前台身份抢资源，用户刚打开软件点什么都卡。
		runCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), audiobookHongguoPoolBudget)
		runCtx = context.WithValue(runCtx, backgroundCatalogKey{}, true)
		go func() {
			defer cancel()
			d.audiobookHongguoPoolRun(runCtx, spec, maxPages)
		}()
	}
	all, loading, _, _ := audiobookHongguoPoolSnapshot(spec.ID)
	total = len(all)
	books = audiobookHongguoPoolSlice(all, since)
	return books, total, loading, needFetch
}

// audiobookHongguoPoolSlice 按 since 切出增量。since 越界时回退到全量，
// 保证前端拿到的数据始终能拼出完整书池（例如换设备 / 重启后本地为空）。
func audiobookHongguoPoolSlice(all []map[string]any, since int) []map[string]any {
	if since <= 0 || since > len(all) {
		return all
	}
	return all[since:]
}

// audiobookHongguoPoolSeed 同步抓首屏那一批并立刻发布。
//
// 只发 1 次请求（书城 tab 首屏，12~24 本），用前台身份跑，保证用户刚点进
// 听书页就能看到内容。全量翻页由 audiobookHongguoPoolRun 在后台继续。
func (d *Downloader) audiobookHongguoPoolSeed(ctx context.Context, spec audiobookHongguoCategory) {
	// 显式清掉后台标记：这条路径是用户在等的，不该被降级排队。
	ctx = context.WithValue(ctx, backgroundCatalogKey{}, false)
	first, _, _, _, _, err := d.audiobookHongguoFeed(ctx, spec, 0)
	if err != nil {
		return
	}
	books := make([]map[string]any, 0, len(first))
	seen := map[string]bool{}
	for _, raw := range first {
		entry := audiobookHongguoBook(raw, spec)
		if entry == nil {
			continue
		}
		if id := entry["id"].(string); !seen[id] {
			seen[id] = true
			books = append(books, entry)
		}
	}
	if len(books) == 0 {
		return
	}
	cache := &audiobookHongguoPoolCache
	cache.Lock()
	defer cache.Unlock()
	entry := cache.entries[spec.ID]
	if entry == nil {
		entry = &audiobookHongguoPoolEntry{}
		cache.entries[spec.ID] = entry
	}
	// 只填空白：后台可能已经发布了更多，别用首屏覆盖回去。
	if len(entry.books) < len(books) {
		entry.books = books
	}
}

// audiobookHongguoPoolRun 后台翻页，边翻边发布，让前端逐步看到书池变大。
func (d *Downloader) audiobookHongguoPoolRun(ctx context.Context, spec audiobookHongguoCategory, maxPages int) {
	cache := &audiobookHongguoPoolCache
	publish := func(books []map[string]any, done bool) {
		cache.Lock()
		defer cache.Unlock()
		entry := cache.entries[spec.ID]
		if entry == nil {
			return
		}
		if len(books) > 0 {
			entry.books = books
		}
		if done {
			entry.loading = false
			if len(entry.books) > 0 {
				entry.loadedAt = time.Now()
			}
		}
	}
	// 兜底：无论正常结束、超时还是 panic，都必须把 loading 复位，
	// 否则前端会永远轮询下去，看起来就是「一直加载不完」。
	defer func() {
		cache.Lock()
		entry := cache.entries[spec.ID]
		loading := entry != nil && entry.loading
		cache.Unlock()
		if loading {
			publish(nil, true)
		}
	}()
	// 每攒够一批就发布一次：首屏很快有内容，后面继续补。
	// 阈值随进度放大（20 → 40 → 80）：前期小步快跑让界面尽早有书，
	// 后期大步减少 IPC 往返次数——948 本按 40 一批要轮询 24 次。
	published := 0
	threshold := 20
	progress := func(books []map[string]any) {
		if len(books)-published >= threshold {
			published = len(books)
			switch {
			case threshold < 40:
				threshold = 40
			case threshold < 80:
				threshold = 80
			}
			publish(books, false)
		}
	}
	books, err := d.audiobookHongguoPoolCollect(ctx, spec, maxPages, progress)
	if err != nil && len(books) == 0 {
		// 一本都没抓到：结束本轮，下次请求会重试。
		publish(nil, true)
		return
	}
	publish(books, true)
}

// audiobookHongguoPoolRefresh 同步抓取并写回缓存（测试与需要阻塞的调用方用）。
func (d *Downloader) audiobookHongguoPoolRefresh(ctx context.Context, spec audiobookHongguoCategory, maxPages int) ([]map[string]any, error) {
	books, err := d.AudiobookHongguoPool(ctx, spec.ID, maxPages)
	cache := &audiobookHongguoPoolCache
	cache.Lock()
	defer cache.Unlock()
	entry := cache.entries[spec.ID]
	if entry == nil {
		entry = &audiobookHongguoPoolEntry{}
		cache.entries[spec.ID] = entry
	}
	entry.loading = false
	// 抓失败但已有旧数据时保留旧的，避免站点抖动把书池清空。
	if err == nil && len(books) > 0 {
		entry.books = books
		entry.loadedAt = time.Now()
	}
	return books, err
}

// AudiobookHongguoPool 连续翻页抓取整个频道，返回去重后的书单。
//
// 服务端要一次供全量书库（前端本地分页/分类都靠它），单页接口只给 12 本，
// 因此这里把 cell/change 一直翻到底。maxPages 是安全上限，避免站点异常时
// 无限请求；每页之间会检查 ctx，前端关页面能立刻停。
//
// 注意：这是「无条件重抓」的底层实现（约 60 秒），调用方一般应该用
// audiobookHongguoPoolStart，否则每次切书源都要等一分钟。
func (d *Downloader) AudiobookHongguoPool(ctx context.Context, category string, maxPages int) ([]map[string]any, error) {
	spec, ok := audiobookHongguoCategoryFor(category)
	if !ok {
		return nil, errors.New("红果听书分类无效")
	}
	return d.audiobookHongguoPoolCollect(ctx, spec, maxPages, nil)
}

// audiobookHongguoPoolCollect 是翻页抓取的实际实现。
// progress 非空时每抓完一页回调一次，供后台任务增量发布。
func (d *Downloader) audiobookHongguoPoolCollect(ctx context.Context, spec audiobookHongguoCategory, maxPages int, progress func([]map[string]any)) ([]map[string]any, error) {
	if maxPages < 1 || maxPages > 200 {
		maxPages = 60
	}
	first, cellID, showType, session, _, err := d.audiobookHongguoFeed(ctx, spec, 0)
	if err != nil {
		return nil, err
	}
	out := make([]map[string]any, 0, 256)
	seen := map[string]bool{}
	appendBooks := func(raw []map[string]any) int {
		added := 0
		for _, book := range raw {
			entry := audiobookHongguoBook(book, spec)
			if entry == nil {
				continue
			}
			id := entry["id"].(string)
			if seen[id] {
				continue
			}
			seen[id] = true
			out = append(out, entry)
			added++
		}
		return added
	}
	appendBooks(first)
	// 首屏这批立刻回调：界面马上有书可看，不用等 cell 翻页攒够一批。
	if progress != nil && len(out) > 0 {
		progress(append([]map[string]any(nil), out...))
	}
	if cellID == "" {
		return out, ctx.Err()
	}
	offset := 10
	for page := 1; page < maxPages; page++ {
		if err := ctx.Err(); err != nil {
			return out, err
		}
		books, hasMore, next, err := d.audiobookHongguoCellPage(ctx, spec, cellID, showType, session, offset)
		if err != nil {
			// 已抓到的不丢，站点抖动时返回现有书池。
			if len(out) > 0 {
				return out, nil
			}
			return nil, err
		}
		added := appendBooks(books)
		if progress != nil && added > 0 {
			progress(append([]map[string]any(nil), out...))
		}
		if !hasMore || added == 0 {
			break
		}
		offset = next
	}
	return out, ctx.Err()
}

// audiobookHongguoSearch 搜索书城。红果搜索按 tab 分开，听书与小说各查各的。
func (d *Downloader) audiobookHongguoSearch(ctx context.Context, category, query string, page int) ([]map[string]any, bool, error) {
	spec, ok := audiobookHongguoCategoryFor(category)
	if !ok {
		return nil, false, errors.New("红果听书分类无效")
	}
	query = strings.TrimSpace(query)
	if query == "" {
		return nil, false, nil
	}
	if page < 1 {
		page = 1
	}
	offset := strconv.Itoa((page - 1) * audiobookHongguoSearchSize)
	extra := url.Values{
		"query":    {query},
		"offset":   {offset},
		"count":    {strconv.Itoa(audiobookHongguoSearchSize)},
		"tab_type": {spec.SearchTab},
	}
	if page > 1 {
		extra.Set("passback", offset)
	}
	result, err := d.hongguoAppRequest(ctx, http.MethodGet, audiobookHongguoSearchPath, extra, nil)
	if err != nil {
		return nil, false, err
	}
	var tab map[string]any
	for _, item := range anyList(result["search_tabs"]) {
		candidate, _ := item.(map[string]any)
		if mapString(candidate, "tab_type") == spec.SearchTab {
			tab = candidate
		}
	}
	if tab == nil {
		return nil, false, errors.New("红果听书搜索未返回有效结果")
	}
	out := make([]map[string]any, 0, audiobookHongguoSearchSize)
	seen := map[string]bool{}
	for _, cell := range anyList(tab["data"]) {
		row, _ := cell.(map[string]any)
		for _, item := range anyList(row["book_data"]) {
			book, _ := item.(map[string]any)
			entry := audiobookHongguoBook(book, spec)
			if entry == nil {
				continue
			}
			id := entry["id"].(string)
			if seen[id] {
				continue
			}
			seen[id] = true
			out = append(out, entry)
		}
	}
	return out, tab["has_more"] == true, ctx.Err()
}

// audiobookHongguoChapters 取详情 + 全量目录。返回的 book 只含展示字段，
// 章节 ID 是红果的 item_id，直接用于播放。
func (d *Downloader) audiobookHongguoChapters(ctx context.Context, bookID string) (map[string]any, []map[string]any, error) {
	bookID = strings.TrimSpace(bookID)
	if !hongguoNumericID.MatchString(bookID) {
		return nil, nil, errors.New("红果听书 ID 无效")
	}
	result, err := d.hongguoAppRequest(ctx, http.MethodGet, audiobookHongguoDetailPath, url.Values{"book_id": {bookID}}, nil)
	if err != nil {
		return nil, nil, err
	}
	detail := nestedMap(result, "data")
	if mapString(detail, "book_id") != bookID {
		return nil, nil, errors.New("红果听书未返回所请求的书籍")
	}
	category := audiobookHongguoCategories[0]
	book := audiobookHongguoBook(detail, category)
	if book == nil {
		return nil, nil, errors.New("红果听书详情无效")
	}
	directory, err := d.hongguoAppRequest(ctx, http.MethodGet, audiobookHongguoDirectory, url.Values{"book_id": {bookID}}, nil)
	if err != nil {
		return nil, nil, err
	}
	data := nestedMap(directory, "data")
	items := anyList(data["item_data_list"])
	if len(items) == 0 {
		items = anyList(data["item_list"])
	}
	chapters := make([]map[string]any, 0, len(items))
	for index, row := range items {
		item, _ := row.(map[string]any)
		itemID := mapString(item, "item_id", "chapter_id")
		if !hongguoNumericID.MatchString(itemID) {
			continue
		}
		title := mapString(item, "title")
		if title == "" {
			title = fmt.Sprintf("第%d章", index+1)
		}
		chapters = append(chapters, map[string]any{
			"id":     itemID,
			"title":  title,
			"order":  index + 1,
			"locked": false,
		})
	}
	if len(chapters) == 0 {
		return nil, nil, errors.New("红果听书未返回章节")
	}
	book["total"] = strconv.Itoa(len(chapters))
	book["remark"] = fmt.Sprintf("共%d章", len(chapters))
	return book, chapters, nil
}

// audiobookHongguoTone 取真人音色 ID；拿不到就按默认音色请求。
func (d *Downloader) audiobookHongguoTone(ctx context.Context, bookID string) int64 {
	result, err := d.hongguoAppRequest(ctx, http.MethodGet, audiobookHongguoTonePath, url.Values{"book_id": {bookID}}, nil)
	if err != nil {
		return 0
	}
	for _, row := range anyList(nestedMap(result, "data")["tts_tones"]) {
		item, _ := row.(map[string]any)
		if id, convErr := strconv.ParseInt(mapString(item, "id", "tone_id"), 10, 64); convErr == nil && id > 0 {
			return id
		}
	}
	return 0
}

// AudiobookHongguoMedia 解析一章的音频地址；加密音频同时给出 CENC key。
func (d *Downloader) audiobookHongguoMedia(ctx context.Context, bookID, chapterID string) (map[string]any, error) {
	bookID = strings.TrimSpace(bookID)
	chapterID = strings.TrimSpace(chapterID)
	if !hongguoNumericID.MatchString(bookID) || !hongguoNumericID.MatchString(chapterID) {
		return nil, errors.New("红果听书章节无效")
	}
	extra := url.Values{"book_id": {bookID}, "item_ids": {chapterID}, "req_type": {"0"}}
	if tone := d.audiobookHongguoTone(ctx, bookID); tone > 0 {
		extra.Set("tone_id", strconv.FormatInt(tone, 10))
	}
	result, err := d.hongguoAppRequest(ctx, http.MethodGet, audiobookHongguoPlayInfoPath, extra, nil)
	if err != nil {
		return nil, err
	}
	for _, row := range anyList(result["data"]) {
		item, _ := row.(map[string]any)
		address := mapString(item, "main_url", "backup_url")
		if address == "" {
			continue
		}
		// 时长不在顶层 duration（那个字段根本不存在），而在 video_model JSON 的
		// video_duration 里，单位秒，带小数。
		duration := 0
		if model := mapString(item, "video_model"); model != "" {
			var decoded map[string]any
			if json.Unmarshal([]byte(model), &decoded) == nil {
				if seconds, ok := decoded["video_duration"].(float64); ok && seconds > 0 {
					duration = int(seconds)
				}
			}
		}
		if duration == 0 {
			if seconds, convErr := strconv.ParseFloat(mapString(item, "duration"), 64); convErr == nil && seconds > 0 {
				duration = int(seconds)
			}
		}
		keyText := mapString(item, "encryption_key")
		key := ""
		if keyText != "" || mapString(item, "is_encrypt") == "true" {
			raw, keyErr := hongguoContentKey(keyText)
			if keyErr != nil {
				return nil, keyErr
			}
			key = hex.EncodeToString(raw)
		}
		return map[string]any{
			"url":           address,
			"decryptionKey": key,
			"duration":      duration,
			"headers": map[string]string{
				"Referer":    "https://novel.snssdk.com/",
				"User-Agent": "com.dragon.read",
			},
		}, nil
	}
	return nil, errors.New("红果听书未返回播放地址")
}

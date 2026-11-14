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
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
)

const (
	audiobookHongguoDetailPath   = "/reading/bookapi/detail/v1/"
	audiobookHongguoTonePath     = "/reading/bookapi/audio/toneinfo/"
	audiobookHongguoDirectory    = "/reading/bookapi/directory/all_items/v1/"
	audiobookHongguoPlayInfoPath = "/reading/reader/audio/playinfo/"
	audiobookHongguoSearchPath   = "/reading/bookapi/search/tab/v1/"
	audiobookHongguoSearchSize   = 10
)

// audiobookHongguoCategory 是听书页的分类：tab 是红果书城的频道号。
type audiobookHongguoCategory struct {
	ID   string
	Name string
	Tab  string
}

var audiobookHongguoCategories = []audiobookHongguoCategory{
	{ID: "listen", Name: "听书", Tab: "5"},
	{ID: "novel", Name: "小说", Tab: "2"},
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

// audiobookHongguoFeed 取一批书城推荐流。
func (d *Downloader) audiobookHongguoFeed(ctx context.Context, category audiobookHongguoCategory, page int) ([]map[string]any, error) {
	requestType := "1"
	if page > 1 {
		requestType = "2"
	}
	extra := url.Values{
		"tab_type":       {category.Tab},
		"offset":         {"0"},
		"client_req_type": {requestType},
	}
	result, err := d.hongguoAppRequest(ctx, http.MethodGet, hongguoBookmallTabPath, extra, nil)
	if err != nil {
		return nil, err
	}
	for _, row := range anyList(nestedMap(result, "data")["tab_item"]) {
		item, _ := row.(map[string]any)
		if mapString(item, "tab_type") == category.Tab {
			return audiobookHongguoBooksOf(item), nil
		}
	}
	return nil, errors.New("红果听书频道数据格式异常")
}

// AudiobookHongguoCatalog 返回一页书单。known 由调用方传入已展示的 ID，
// 推荐流会重复吐同一批书，这里负责过滤。
func (d *Downloader) audiobookHongguoCatalog(ctx context.Context, category string, page int, known map[string]bool) ([]map[string]any, bool, error) {
	spec, ok := audiobookHongguoCategoryFor(category)
	if !ok {
		return nil, false, errors.New("红果听书分类无效")
	}
	if page < 1 {
		page = 1
	}
	attempts := 1
	if page > 1 {
		attempts = 3
	}
	out := make([]map[string]any, 0, 40)
	seen := map[string]bool{}
	for attempt := 0; attempt < attempts && len(out) == 0; attempt++ {
		books, err := d.audiobookHongguoFeed(ctx, spec, page)
		if err != nil {
			return nil, false, err
		}
		for _, book := range books {
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
	}
	return out, len(out) > 0 && page < 200, ctx.Err()
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
		"tab_type": {spec.Tab},
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
		if mapString(candidate, "tab_type") == spec.Tab {
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
		duration := 0
		if seconds, convErr := strconv.ParseFloat(mapString(item, "duration"), 64); convErr == nil && seconds > 0 {
			duration = int(seconds)
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
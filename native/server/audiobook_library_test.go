package main

import (
	"testing"
	"time"
)

func abTestBook(id, title, author, category, intro string, board int) audiobookBook {
	return audiobookBook{
		ID: id, Title: title, Author: author,
		Category: category, Intro: intro, Board: board,
	}
}

// 榜单同时给 category（逗号串）与 category_v2（标签数组），后者才是真实分类；
// 封面、简介也要带出来，否则网页卡片只能显示书名首字。
func TestAbBooksFromRowsUsesRealTagsAndCover(t *testing.T) {
	rows := []map[string]any{
		{
			"genre": "4", "book_id": "book-1", "book_name": "<em>十年</em>雪落",
			"author": "张三", "category": "都市,玄幻",
			"category_v2": []any{"都市", "系统"},
			"thumb_url":   "https://img.example/cover.jpg?x=1&y=2",
			"abstract":    "<p>一段<br/>简介</p>&nbsp;完",
		},
		{"genre": "1", "book_id": "novel-1", "book_name": "普通小说"},
		{"genre": "4", "book_id": "", "book_name": "缺编号"},
		{
			"genre": "4", "book_id": "book-2", "title": "回落分类",
			"category": "悬疑,推理",
		},
	}
	books := abBooksFromRows(rows)
	if len(books) != 2 {
		t.Fatalf("应只保留 2 本可播放听书，实际 %d 本", len(books))
	}
	if books[0].Title != "十年雪落" {
		t.Fatalf("标题高亮标签未去掉：%q", books[0].Title)
	}
	if books[0].Category != "都市 · 系统" {
		t.Fatalf("应优先用 category_v2，实际 %q", books[0].Category)
	}
	if books[0].Cover != "https://img.example/cover.jpg?x=1&y=2" {
		t.Fatalf("封面丢失：%q", books[0].Cover)
	}
	if books[0].Intro != "一段 简介 完" {
		t.Fatalf("简介标签未清理干净：%q", books[0].Intro)
	}
	if books[1].Category != "悬疑,推理" {
		t.Fatalf("category_v2 缺失时应回落 category：%q", books[1].Category)
	}
}

func TestAbCategoriesAndMatch(t *testing.T) {
	pool := []audiobookBook{
		abTestBook("1", "甲", "", "都市 · 系统", "", 0),
		abTestBook("2", "乙", "", "玄幻，穿越", "", 1),
		abTestBook("3", "丙", "", "冷门标签", "", 0),
	}
	categories := abCategoriesFrom(pool)
	want := []string{"都市", "玄幻", "系统", "穿越"}
	if len(categories) != len(want) {
		t.Fatalf("分类应按固定顺序只保留有书的真实标签，实际 %v", categories)
	}
	for index, name := range want {
		if categories[index] != name {
			t.Fatalf("分类顺序错位：%v", categories)
		}
	}
	if !abMatchesCategory(pool[0], "系统") || abMatchesCategory(pool[0], "玄幻") {
		t.Fatalf("分类匹配应拆开 · 分隔的标签")
	}
	if !abMatchesCategory(pool[1], "穿越") {
		t.Fatalf("中文逗号也应作为标签分隔符")
	}
	if !abMatchesCategory(pool[0], "") {
		t.Fatalf("空分类表示全部")
	}
}

// 搜索要覆盖全量书池，并按书名 / 分类 / 作者 / 简介的相关度排序。
func TestAbSearchInPoolScoresWholeLibrary(t *testing.T) {
	pool := []audiobookBook{
		abTestBook("1", "别人的书", "李四", "年代", "提到过都市生活", 0),
		abTestBook("2", "都市夜归人", "王五", "玄幻", "", 0),
		abTestBook("3", "夜行", "赵六", "都市", "", 1),
		abTestBook("4", "无关", "钱七", "种田", "", 0),
	}
	books := abSearchInPool(pool, "都市")
	if len(books) != 3 {
		t.Fatalf("应命中 3 本（含简介命中），实际 %d 本", len(books))
	}
	if books[0].ID != "2" {
		t.Fatalf("书名命中应排在最前，实际第一本 %s", books[0].ID)
	}
	if books[1].ID != "3" {
		t.Fatalf("分类命中应排在简介命中之前，实际第二本 %s", books[1].ID)
	}
	if len(abSearchInPool(pool, "都市 王五")) != 1 || abSearchInPool(pool, "都市 王五")[0].ID != "2" {
		t.Fatalf("空格分词应要求全部命中")
	}
	if len(abSearchInPool(pool, "   ")) != 0 {
		t.Fatalf("空关键词不应返回书")
	}
}

func abTestStore(books []audiobookBook) *audiobookLibraryStore {
	store := &audiobookLibraryStore{
		boards:     map[string][]audiobookBook{},
		merged:     books,
		categories: abCategoriesFrom(books),
		done:       true,
		finished:   time.Now(), // 让 ensure() 认为缓存仍新鲜，测试不触网
	}
	return store
}

// 榜单 has_more 恒 false，翻页必须靠书池总数算页数，且分类要跨男女两榜。
func TestAbLibraryQueryPagingAndCategory(t *testing.T) {
	original := abRemoteSearchFunc
	abRemoteSearchFunc = func(string) []audiobookBook { return nil }
	defer func() { abRemoteSearchFunc = original }()

	books := []audiobookBook{}
	for index := 0; index < 25; index++ {
		tag := "都市"
		if index%2 == 0 {
			tag = "玄幻"
		}
		books = append(books, abTestBook(
			"id-"+string(rune('a'+index)), "书", "", tag, "", index%2,
		))
	}
	store := abTestStore(books)

	first := store.query(abOriginAll, 0, "", "", 1, 10)
	if first["total"].(int) != 13 || first["pageCount"].(int) != 2 {
		t.Fatalf("男生榜应为 13 本 / 2 页：%+v", first)
	}
	second := store.query(abOriginAll, 0, "", "", 2, 10)
	if len(second["books"].([]map[string]any)) != 3 {
		t.Fatalf("第二页应剩 3 本")
	}
	clamped := store.query(abOriginAll, 0, "", "", 99, 10)
	if clamped["page"].(int) != 2 {
		t.Fatalf("越界页码应钳到最后一页，实际 %v", clamped["page"])
	}

	byCategory := store.query(abOriginAll, 0, "玄幻", "", 1, 50)
	if byCategory["total"].(int) != 13 {
		t.Fatalf("分类应合并男女两榜，实际 %v", byCategory["total"])
	}
	if len(byCategory["categories"].([]string)) != 2 {
		t.Fatalf("分类列表应来自书池真实标签：%v", byCategory["categories"])
	}

	search := store.query(abOriginAll, 0, "", "书", 1, 10)
	if search["total"].(int) != 25 || search["pageCount"].(int) != 3 {
		t.Fatalf("全库搜索应覆盖全部 25 本，实际 %+v", search)
	}
}

// 两个书源必须各自独立：红果听书只看官方书城听书专辑，番茄听书只看畅听榜单，
// 混在一起会让用户在两个 tab 里看到同一批书。
func TestAbLibraryQuerySeparatesOrigins(t *testing.T) {
	store := &audiobookLibraryStore{
		boards: map[string][]audiobookBook{
			audiobookBoardDefs[0].key: {{ID: "rank-1", Title: "榜单书", Board: 0}},
		},
		official: map[string]audiobookBook{
			"off-1": {ID: "off-1", Title: "官方书", Board: 0, Anchor: "真人主播"},
			"off-2": {ID: "off-2", Title: "AI 书", Board: 0, Anchor: "番茄畅听AI"},
		},
		done:     true,
		finished: time.Now(), // 缓存仍新鲜，测试不触网
	}
	store.mu.Lock()
	store.rebuildLocked()
	store.mu.Unlock()

	hongguo := store.query(abOriginHongguo, 0, "", "", 1, 10)
	if hongguo["origin"] != abOriginHongguo || hongguo["total"].(int) != 2 {
		t.Fatalf("红果听书书池 = %v / %v", hongguo["origin"], hongguo["total"])
	}
	official := hongguo["books"].([]map[string]any)
	modes := map[string]string{}
	for _, book := range official {
		modes[book["id"].(string)] = book["voiceMode"].(string)
	}
	if modes["off-1"] != "真人录音" || modes["off-2"] != "AI 朗读" {
		t.Fatalf("有声书类型标签 = %v", modes)
	}

	fanqie := store.query(abOriginFanqie, 0, "", "", 1, 10)
	rank := fanqie["books"].([]map[string]any)
	if len(rank) != 1 || rank[0]["id"] != "rank-1" {
		t.Fatalf("番茄听书书池 = %v", rank)
	}

	// 不传 origin 时默认红果听书。
	if got := store.query("", 0, "", "", 1, 10)["origin"]; got != abOriginHongguo {
		t.Fatalf("默认书源 = %v, want %v", got, abOriginHongguo)
	}
}

// 红果听书搜索不能被番茄榜单的远程结果污染。
func TestAbLibrarySearchKeepsHongguoPoolOnly(t *testing.T) {
	original := abRemoteSearchFunc
	abRemoteSearchFunc = func(keyword string) []audiobookBook {
		return []audiobookBook{{ID: "remote-1", Title: "远程榜单书", Board: 0}}
	}
	defer func() { abRemoteSearchFunc = original }()

	store := &audiobookLibraryStore{
		boards:   map[string][]audiobookBook{},
		official: map[string]audiobookBook{"off-1": {ID: "off-1", Title: "官方书库", Board: 0}},
		done:     true,
		finished: time.Now(),
	}
	store.mu.Lock()
	store.rebuildLocked()
	store.mu.Unlock()

	for _, book := range store.query(abOriginHongguo, 0, "", "书", 1, 10)["books"].([]map[string]any) {
		if book["id"] == "remote-1" {
			t.Fatal("红果听书搜索混入了番茄榜单的书")
		}
	}
	// 番茄听书仍然要能用到远程搜索补书。
	found := false
	for _, book := range store.query(abOriginFanqie, 0, "", "书", 1, 10)["books"].([]map[string]any) {
		if book["id"] == "remote-1" {
			found = true
		}
	}
	if !found {
		t.Fatal("番茄听书丢掉了远程搜索结果")
	}
}

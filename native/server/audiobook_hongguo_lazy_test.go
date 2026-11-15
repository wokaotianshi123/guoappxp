package main

import "testing"

// 红果听书按需加载的关键性质：书池状态里没有「后台还在翻页」这回事，
// 前端的 library.loading 补全定时器因此不会再启动。这几个用例都预置了
// 已加载页，ensurePages 命中早退分支，不会真的发起 coreCall 触网。
func newLazyHongguoStore() *abHongguoStore {
	return &abHongguoStore{
		books:    map[string][]map[string]any{},
		pages:    map[string]int{},
		hasMore:  map[string]bool{},
		errText:  map[string]string{},
		inflight: map[string]bool{},
	}
}

func TestAbHongguoSnapshotNeverReportsBackgroundLoading(t *testing.T) {
	store := newLazyHongguoStore()
	store.books["listen"] = []map[string]any{
		{"id": "1", "title": "书一"},
		{"id": "2", "title": "书二"},
	}
	store.pages["listen"] = 1
	store.hasMore["listen"] = true

	pool, info := store.snapshot("listen")
	if len(pool) != 2 {
		t.Fatalf("snapshot 书数 = %d, want 2", len(pool))
	}
	if info["loading"] != false {
		t.Fatalf("library.loading = %v, want false（不应有后台任务）", info["loading"])
	}
	if info["done"] != true {
		t.Fatalf("library.done = %v, want true", info["done"])
	}
	if info["count"] != 2 {
		t.Fatalf("library.count = %v, want 2", info["count"])
	}
	if info["hasMore"] != true {
		t.Fatalf("library.hasMore = %v, want true", info["hasMore"])
	}
}

func TestAbHongguoEnsurePagesNoopWhenAlreadyEnough(t *testing.T) {
	store := newLazyHongguoStore()
	store.pages["listen"] = 3
	store.hasMore["listen"] = true

	// 已取到第 3 页，请求只要 2 页：应当立刻返回，不发任何请求。
	store.ensurePages("listen", 2)
	if store.pages["listen"] != 3 {
		t.Fatalf("页数被改动 = %d, want 3", store.pages["listen"])
	}
	if store.inflight["listen"] {
		t.Fatal("不该留下 inflight 标记")
	}
}

func TestAbHongguoEnsurePagesStopsWhenUpstreamExhausted(t *testing.T) {
	store := newLazyHongguoStore()
	store.pages["listen"] = 1
	store.hasMore["listen"] = false

	// 上游已经到底：即便调用方想翻到很后面，也不能空转或后台续抓。
	store.ensurePages("listen", 9)
	if store.pages["listen"] != 1 {
		t.Fatalf("页数被改动 = %d, want 1", store.pages["listen"])
	}
	if store.inflight["listen"] {
		t.Fatal("不该留下 inflight 标记")
	}
}

func TestAbHongguoEnsurePagesSkipsConcurrentFetch(t *testing.T) {
	store := newLazyHongguoStore()
	store.pages["listen"] = 1
	store.hasMore["listen"] = true
	store.inflight["listen"] = true

	// 同一频道已有请求在补页：用现有进度先响应，不并发抢限流资源。
	store.ensurePages("listen", 4)
	if store.pages["listen"] != 1 {
		t.Fatalf("页数被改动 = %d, want 1", store.pages["listen"])
	}
}

func TestAbHongguoLibraryLeavesOneMorePageToLoadOnDemand(t *testing.T) {
	// 预置「已取到第 1 页且上游仍有更多」，让 ensurePages 直接命中缓存不触网。
	store := newLazyHongguoStore()
	store.books["listen"] = []map[string]any{
		{"id": "1", "title": "书一"},
		{"id": "2", "title": "书二"},
	}
	store.pages["listen"] = 1
	store.hasMore["listen"] = true

	previous := abHongguo
	abHongguo = store
	defer func() { abHongguo = previous }()

	data := abHongguoLibrary(0, "", "", 1, 10)
	if data["origin"] != "hongguo" {
		t.Fatalf("origin = %v, want hongguo", data["origin"])
	}
	library, ok := data["library"].(map[string]any)
	if !ok {
		t.Fatal("library 字段缺失")
	}
	if library["loading"] != false {
		t.Fatalf("library.loading = %v, want false", library["loading"])
	}
	// 已加载 2 本、size=10 → 本地只有 1 页；上游还有更多，多留 1 页供
	// 用户点「下一页」，点下去才会触发下一次按页加载。
	if data["pageCount"] != 2 {
		t.Fatalf("pageCount = %v, want 2", data["pageCount"])
	}
	books, ok := data["books"].([]map[string]any)
	if !ok {
		t.Fatalf("books 类型 = %T, want []map[string]any", data["books"])
	}
	if len(books) != 2 {
		t.Fatalf("首页书数 = %d, want 2", len(books))
	}
}

func TestAbHongguoLibraryEmptyExtraPageDoesNotPanic(t *testing.T) {
	// hasMore 时 pageCount 会多留一页；若这一页还没补到数据（并发让道、
	// 单页失败），返回空页即可，不能让切片越界把服务打挂。
	store := newLazyHongguoStore()
	store.books["listen"] = []map[string]any{{"id": "1", "title": "书一"}}
	store.pages["listen"] = 1
	store.hasMore["listen"] = true
	store.inflight["listen"] = true // 模拟补页请求正在别处进行，本次不补

	previous := abHongguo
	abHongguo = store
	defer func() { abHongguo = previous }()

	data := abHongguoLibrary(0, "", "", 2, 10)
	books, ok := data["books"].([]map[string]any)
	if !ok {
		t.Fatalf("books 类型 = %T", data["books"])
	}
	if len(books) != 0 {
		t.Fatalf("尚未加载的页应为空，实际 %d 本", len(books))
	}
	if data["page"] != 2 {
		t.Fatalf("page = %v, want 2", data["page"])
	}
}

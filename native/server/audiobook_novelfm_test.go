package main

import (
	"encoding/json"
	"sync"
	"testing"
	"time"
)

// 从 fanqie.apk 官方书城 tab_v2 真实回包裁剪的最小样本：
// 一个 sub_cell 带听书 + 普通小说（应被 genre=4 过滤），
// 一个 popular_tags 单元格带官方分类入口。
const novelfmSample = `{
  "code":0,
  "data":{"book_tab_infos":[{
    "tab_title":"推荐","tab_type":10,
    "cells":[
      {"name":"排行榜","show_type":241,"books":[],"sub_cells":[
        {"name":"推荐榜","books":[
          {"book_id":"7281195245084691518","book_name":"十日终焉","author":"杀虫队队员",
           "genre":"4","gender":"1","tags":"惊悚游戏,悬疑,推理","abstract":"当我以为这只是寻常的一天时",
           "audio_thumb_uri":"https://img.example/cover.jpg?sign=1",
           "category_info":"[{\"ObjectId\":537,\"Dim\":10,\"Name\":\"惊悚游戏\"},{\"ObjectId\":10,\"Dim\":1,\"Name\":\"悬疑\"}]",
           "score":"9.9"},
          {"book_id":"999","book_name":"普通小说","genre":"0","tags":"都市"}
        ]}
      ]},
      {"name":"热门标签","show_type":263,"books":[],
       "popular_tags":{"show_tags":[
         {"category_id":7,"name":"玄幻"},{"category_id":1,"name":"都市"}
       ]}}
    ]
  }]}
}`

func novelfmSampleRoot(t *testing.T) map[string]any {
	t.Helper()
	var root map[string]any
	if err := json.Unmarshal([]byte(novelfmSample), &root); err != nil {
		t.Fatalf("样本不是合法 JSON: %v", err)
	}
	return root
}

func TestAbParseNovelfmPage(t *testing.T) {
	page := abParseNovelfmPage(novelfmSampleRoot(t), 10)
	if page.tabTitle != "推荐" || page.tabType != 10 {
		t.Fatalf("一级分类没解析出来：%q / %d", page.tabTitle, page.tabType)
	}
	if len(page.books) != 1 {
		t.Fatalf("应只保留 genre=4 的听书，实际 %d 本", len(page.books))
	}
	book := page.books[0]
	if book.ID != "7281195245084691518" || book.Title != "十日终焉" || book.Author != "杀虫队队员" {
		t.Fatalf("书目字段错位：%+v", book)
	}
	if book.Cover != "https://img.example/cover.jpg?sign=1" {
		t.Fatalf("封面应优先用 audio_thumb_uri：%q", book.Cover)
	}
	if book.Category != "惊悚游戏 · 悬疑 · 推理" {
		t.Fatalf("分类应合并 tags 并去重 category_info：%q", book.Category)
	}
	if book.Board != 0 {
		t.Fatalf("gender=1 应归男生榜，实际 %d", book.Board)
	}
	if len(page.hotTags) != 2 || page.hotTags[0] != "玄幻" {
		t.Fatalf("热门标签没解析出来：%v", page.hotTags)
	}
	names := map[string]bool{}
	for _, def := range page.categories {
		names[def.Name] = true
	}
	for _, want := range []string{"玄幻", "都市", "惊悚游戏", "悬疑"} {
		if !names[want] {
			t.Fatalf("官方分类词表缺 %q：%v", want, page.categories)
		}
	}
	// Dim 小的主类排在前面。
	if first := page.categories[0]; first.Dim != 0 && first.Dim != 1 {
		t.Fatalf("分类应按 Dim 排序，首个是 %+v", first)
	}
}

// 刷新是后台并发的；这里替换取数函数隔离网络，验证书目会累积、分类会学到。
func TestAbRefreshOfficialLibraryAccumulates(t *testing.T) {
	originalFetch := abOfficialFetchFn
	originalBooks := abOfficialBooks
	originalCats := abOfficialCats
	originalHot := abOfficialHotTags
	originalTabs := abOfficialTabs
	originalLast := abOfficialLast
	t.Cleanup(func() {
		abOfficialFetchFn = originalFetch
		abOfficialBooks = originalBooks
		abOfficialCats = originalCats
		abOfficialHotTags = originalHot
		abOfficialTabs = originalTabs
		abOfficialLast = originalLast
	})
	abOfficialBooks = map[string]audiobookBook{}
	abOfficialCats = map[string]novelfmCategoryDef{}
	abOfficialHotTags = map[string]bool{}
	abOfficialTabs = map[int]string{}
	abOfficialLast = time.Time{}
	abOfficialRefresh = false
	abOfficialFetchFn = func(tab int) (map[string]any, error) {
		return novelfmSampleRoot(t), nil
	}

	if !abRefreshOfficialLibrary() {
		t.Fatal("首次刷新应被触发")
	}
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		abOfficialMu.RLock()
		busy := abOfficialRefresh
		abOfficialMu.RUnlock()
		if !busy {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	books, cats := abOfficialSnapshot()
	if len(books) != 1 {
		t.Fatalf("官方书应累积 1 本，实际 %d 本", len(books))
	}
	if len(cats) < 4 {
		t.Fatalf("官方分类词表应学到至少 4 个，实际 %v", cats)
	}
	// 第二次调用在 TTL 内不应重复发起刷新（但书池仍在）。
	if abRefreshOfficialLibrary() {
		t.Fatal("TTL 内不应重复刷新")
	}
}

// 并发读快照不应与刷新写互相打架（go test -race 会检查）。
func TestAbOfficialSnapshotConcurrent(t *testing.T) {
	var wait sync.WaitGroup
	for i := 0; i < 20; i++ {
		wait.Add(1)
		go func() {
			defer wait.Done()
			abOfficialSnapshot()
			abOfficialStatus()
		}()
	}
	wait.Wait()
}

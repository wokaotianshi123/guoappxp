package main

import (
	"encoding/json"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// 番茄畅听官方书城（实时数据源）。
//
// 来源：fanqie.apk 反编译。APK 的 assets/tab_v2_simple.json 只带 6 个一级
// tab 和 8 本兜底书，真正的书库与分类由 BookmallApiService 走 RPC 下发；
// smali 里硬编码了 host `https://api.novelfm.com` 和路径
// `/novelfm/bookmall/tab_v2/v1/`，scheme `novelfm3040://` 说明 aid=3040。
// 实测匿名 GET 可用，但必须带 update_version_code（缺了网关报
// "update_version_code is 0"），且要按 tab_type 分别请求才有书目。
//
// 这里不固化任何书目：每次刷新都重新请求官方接口，累计去重，所以书库、
// 分类、封面签名都会随时间更新。请求仍走 Go 核心的 audiobookFetch 代发，
// 与榜单 / 搜索共用代理和超时设置。

const (
	novelfmBookmallURL = "https://api.novelfm.com/novelfm/bookmall/tab_v2/v1/"
	novelfmCommonQuery = "aid=3040&device_platform=android&version_name=6.7.8&version_code=678&device_type=SM-G9730&iid=1&device_id=1&update_version_code=1"
	novelfmRefreshTTL  = 10 * time.Minute
	novelfmFetchRounds = 3 // 首屏推荐带随机性，多取几轮能覆盖更多书
)

// 官方一级分类 tab_type，来自 APK 内置 tab_v2_simple.json + 接口返回值。
var novelfmTabTypes = []int{10, 12, 4, 5, 9, 6}

type novelfmCategoryDef struct {
	ID   int
	Name string
	Dim  int
}

var (
	abOfficialMu      sync.RWMutex
	abOfficialBooks   = map[string]audiobookBook{}
	abOfficialCats    = map[string]novelfmCategoryDef{} // name -> 定义
	abOfficialHotTags = map[string]bool{}
	abOfficialTabs    = map[int]string{}
	abOfficialLast    time.Time
	abOfficialRefresh bool
	abOfficialErr     string
	abOfficialFetchFn = abFetchNovelfmTabCore // 单测可替换，隔离网络
)

func abNovelfmURL(tabType int) string {
	return novelfmBookmallURL + "?" + novelfmCommonQuery + "&tab_type=" + strconv.Itoa(tabType)
}

// abFetchNovelfmTabCore 走 Go 核心代发，返回解码后的官方书城首页。
func abFetchNovelfmTabCore(tabType int) (map[string]any, error) {
	return audiobookFetchJSON(abNovelfmURL(tabType), nil)
}

type abNovelfmPage struct {
	books      []audiobookBook
	categories []novelfmCategoryDef
	hotTags    []string
	tabTitle   string
	tabType    int
}

// abParseNovelfmPage 从官方书城首页里取书、官方分类词表和热门标签。
// 结构：data.book_tab_infos[].cells[] 里 books / sub_cells[].books 是书目，
// popular_tags.show_tags[] 是官方分类入口，书籍的 category_info 是官方分类
// 字典（ObjectId / Name / Dim / ExternalDesc），比榜单的 category_v2 更全。
func abParseNovelfmPage(root map[string]any, tabType int) abNovelfmPage {
	page := abNovelfmPage{tabType: tabType}
	data, _ := root["data"].(map[string]any)
	tabs, _ := data["book_tab_infos"].([]any)
	cats := map[string]novelfmCategoryDef{}
	addCategory := func(id int, name string, dim int) {
		name = strings.TrimSpace(abInlineText(name))
		if name == "" {
			return
		}
		if existing, ok := cats[name]; !ok || (dim > 0 && dim < existing.Dim) {
			cats[name] = novelfmCategoryDef{ID: id, Name: name, Dim: dim}
		}
	}
	rows := make([]map[string]any, 0, 64)
	for _, rawTab := range tabs {
		tab, _ := rawTab.(map[string]any)
		if tab == nil {
			continue
		}
		if title := strings.TrimSpace(asString(tab["tab_title"])); title != "" {
			page.tabTitle = title
		}
		if value := asString(tab["tab_type"]); value != "" {
			if parsed, err := strconv.Atoi(value); err == nil && parsed != 0 {
				page.tabType = parsed
			}
		}
		cells, _ := tab["cells"].([]any)
		for _, rawCell := range cells {
			cell, _ := rawCell.(map[string]any)
			if cell == nil {
				continue
			}
			popular, _ := cell["popular_tags"].(map[string]any)
			showTags, _ := popular["show_tags"].([]any)
			for _, rawTag := range showTags {
				tag, _ := rawTag.(map[string]any)
				if tag == nil {
					continue
				}
				name := strings.TrimSpace(asString(tag["name"]))
				if name == "" {
					continue
				}
				id, _ := strconv.Atoi(asString(tag["category_id"]))
				addCategory(id, name, 0)
				page.hotTags = append(page.hotTags, name)
			}
			rows = append(rows, cell)
			subCells, _ := cell["sub_cells"].([]any)
			for _, rawSub := range subCells {
				sub, _ := rawSub.(map[string]any)
				if sub != nil {
					rows = append(rows, sub)
				}
			}
		}
	}
	books := make([]audiobookBook, 0, 64)
	seen := map[string]bool{}
	for _, cell := range rows {
		list, _ := cell["books"].([]any)
		for _, rawBook := range list {
			row, _ := rawBook.(map[string]any)
			if row == nil || asString(row["genre"]) != audiobookGenre {
				continue
			}
			id := strings.TrimSpace(asString(row["book_id"]))
			title := abInlineText(asString(firstNonEmpty(row["book_name"], row["title"])))
			if id == "" || title == "" || seen[id] {
				continue
			}
			seen[id] = true
			names := make([]string, 0, 8)
			for _, tag := range strings.Split(asString(row["tags"]), ",") {
				if tag = strings.TrimSpace(abInlineText(tag)); tag != "" && !containsString(names, tag) {
					names = append(names, tag)
				}
			}
			if info := asString(row["category_info"]); info != "" {
				var entries []struct {
					ObjectID int    `json:"ObjectId"`
					Name     string `json:"Name"`
					Dim      int    `json:"Dim"`
				}
				if json.Unmarshal([]byte(info), &entries) == nil {
					for _, entry := range entries {
						name := strings.TrimSpace(abInlineText(entry.Name))
						if name != "" && !containsString(names, name) && len(names) < 12 {
							names = append(names, name)
						}
						addCategory(entry.ObjectID, name, entry.Dim)
					}
				}
			}
			books = append(books, audiobookBook{
				ID:       id,
				Title:    title,
				Author:   abInlineText(asString(row["author"])),
				Category: strings.Join(names, " · "),
				Cover:    strings.TrimSpace(asString(firstNonEmpty(row["audio_thumb_uri"], row["thumb_url"]))),
				Intro:    abInlineText(asString(row["abstract"])),
				Board:    boardFromGender(asString(row["gender"])),
				Anchor:   abInlineText(asString(row["anchor"])),
			})
		}
	}
	page.books = books
	for _, def := range cats {
		page.categories = append(page.categories, def)
	}
	sort.Slice(page.categories, func(i, j int) bool {
		a, b := page.categories[i], page.categories[j]
		if a.Dim != b.Dim {
			return a.Dim < b.Dim
		}
		return a.ID < b.ID
	})
	return page
}

func containsString(list []string, value string) bool {
	for _, item := range list {
		if item == value {
			return true
		}
	}
	return false
}

// 官方书的 gender 与番茄榜单一致：1 男生、0 女生，其余归男生榜。
func boardFromGender(gender string) int {
	if strings.TrimSpace(gender) == "0" {
		return 1
	}
	return 0
}

// abRefreshOfficialLibrary 按 TTL 后台刷新，书只会累积不会因某次失败被清掉。
// 返回是否真的发起了刷新，方便调用方决定要不要重新 publish。
func abRefreshOfficialLibrary() bool {
	abOfficialMu.Lock()
	if abOfficialRefresh || (!abOfficialLast.IsZero() && time.Since(abOfficialLast) < novelfmRefreshTTL) {
		abOfficialMu.Unlock()
		return false
	}
	abOfficialRefresh = true
	abOfficialMu.Unlock()

	go func() {
		defer func() {
			abOfficialMu.Lock()
			abOfficialRefresh = false
			abOfficialLast = time.Now()
			abOfficialMu.Unlock()
		}()
		pages := make(chan abNovelfmPage, len(novelfmTabTypes)*novelfmFetchRounds)
		var wg sync.WaitGroup
		for round := 0; round < novelfmFetchRounds; round++ {
			for _, tab := range novelfmTabTypes {
				wg.Add(1)
				go func(tab int) {
					defer wg.Done()
					root, err := abOfficialFetchFn(tab)
					if err != nil || root == nil {
						return
					}
					pages <- abParseNovelfmPage(root, tab)
				}(tab)
			}
		}
		wg.Wait()
		close(pages)
		abOfficialMu.Lock()
		count, received := 0, 0
		for page := range pages {
			received++
			if page.tabTitle != "" && page.tabType != 0 {
				abOfficialTabs[page.tabType] = page.tabTitle
			}
			for _, def := range page.categories {
				if def.Name != "" {
					abOfficialCats[def.Name] = def
				}
			}
			for _, tag := range page.hotTags {
				abOfficialHotTags[tag] = true
			}
			for _, book := range page.books {
				if book.ID != "" {
					if _, exists := abOfficialBooks[book.ID]; !exists {
						count++
					}
					abOfficialBooks[book.ID] = book
				}
			}
		}
		if count > 0 {
			abOfficialErr = ""
		} else if received == 0 {
			abOfficialErr = "官方书城暂时连不上，已沿用现有书库"
		}
		// 必须先释放写锁：publishOfficial 会经 abCategoriesFrom 读这里的快照。
		abOfficialMu.Unlock()
		if count > 0 {
			abLibrary.publishOfficial()
		}
	}()
	return true
}

// abOfficialSnapshot 给书池合并用：书目 + 官方分类白名单（按 Dim/ID 排序）。
func abOfficialSnapshot() ([]audiobookBook, []string) {
	abOfficialMu.RLock()
	defer abOfficialMu.RUnlock()
	books := make([]audiobookBook, 0, len(abOfficialBooks))
	for _, book := range abOfficialBooks {
		books = append(books, book)
	}
	cats := make([]string, 0, len(abOfficialCats))
	for name := range abOfficialCats {
		cats = append(cats, name)
	}
	sort.Slice(cats, func(i, j int) bool {
		a, b := abOfficialCats[cats[i]], abOfficialCats[cats[j]]
		if a.Dim != b.Dim {
			return a.Dim < b.Dim
		}
		return a.ID < b.ID
	})
	return books, cats
}

func abOfficialStatus() map[string]any {
	abOfficialMu.RLock()
	defer abOfficialMu.RUnlock()
	return map[string]any{
		"count":   len(abOfficialBooks),
		"tabs":    len(abOfficialTabs),
		"tags":    len(abOfficialHotTags),
		"loading": abOfficialRefresh,
		"error":   abOfficialErr,
	}
}

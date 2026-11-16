package core

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

// hongguoBookmallFixture 造一个只回放指定响应的 Downloader：
// key 为 "10"（cell/change 的 offset）或 "playinfo"，值是接口原始 data。
func hongguoBookmallFixture(t *testing.T, replies map[string]string) (*Downloader, *[]string) {
	t.Helper()
	var requests []string
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		query := request.URL.Query()
		switch request.URL.Path {
		case audiobookHongguoPlayInfoPath:
			requests = append(requests, "playinfo")
			body := replies["playinfo"]
			if body == "" {
				body = `{"code":0,"data":[]}`
			}
			return sourceFixtureResponse(request, http.StatusOK, body), nil
		case hongguoBookmallCellChangePath:
			offset := query.Get("offset")
			requests = append(requests, "cell@"+offset)
			body := replies[offset]
			if body == "" {
				body = `{"data":{"has_more":false,"next_offset":"0","cell_view":{"cell_data":[]}}}`
			}
			return sourceFixtureResponse(request, http.StatusOK, `{"code":0,`+strings.TrimPrefix(body, "{")), nil
		case audiobookHongguoTonePath:
			return sourceFixtureResponse(request, http.StatusOK, `{"code":0,"data":{"tts_tones":[]}}`), nil
		}
		return sourceFixtureResponse(request, http.StatusOK, `{"code":0,"data":{}}`), nil
	})
	return d, &requests
}

func testContext() context.Context { return context.Background() }

// 红果书城的 has_more 在 tab 层恒为 false，真实分页在 cell/change 的
// next_offset 上；这里锁定「next_offset 不前进就当到底」这条护栏，
// 避免站点异常时调用方无限翻页。
func TestAudiobookHongguoCellPageStopsWhenOffsetStalls(t *testing.T) {
	d, _ := hongguoBookmallFixture(t, map[string]string{
		// next_offset 与请求 offset 相同 → 视为到底。
		"10": `{"data":{"has_more":true,"next_offset":"10","cell_view":{"cell_data":[{"book_data":[{"book_id":"123","book_name":"样本"}]}]}}}`,
	})
	books, hasMore, _, err := d.audiobookHongguoCellPage(
		testContext(), audiobookHongguoCategories[0], "1", "337", "s", 10)
	if err != nil {
		t.Fatalf("cell page: %v", err)
	}
	if len(books) != 1 {
		t.Fatalf("books = %d", len(books))
	}
	if hasMore {
		t.Fatal("next_offset 未前进时必须判定为到底，否则会无限翻页")
	}
}

// 音频时长在 video_model 的 video_duration 里，顶层没有 duration 字段。
// 取错字段会让播放器把每章时长算成 0，进度条与「听完」判断都会失效。
func TestAudiobookHongguoMediaReadsDurationFromVideoModel(t *testing.T) {
	model, _ := json.Marshal(map[string]any{"video_duration": 495.547, "media_type": "audio"})
	encoded, _ := json.Marshal(string(model))
	d, _ := hongguoBookmallFixture(t, map[string]string{
		"playinfo": `{"code":0,"data":[{"main_url":"https://cdn.example.test/a.mp4","is_encrypt":true,` +
			`"encryption_key":"obwv82S8KcdjjjPFfogy83iJKNlRoQHqT6c19n+4NsV5vTG9vQ==",` +
			`"video_model":` + string(encoded) + `}]}`,
	})
	media, err := d.audiobookHongguoMedia(testContext(), "7189544077984009277", "7189549819830993468")
	if err != nil {
		t.Fatalf("media: %v", err)
	}
	if media["duration"] != 495 {
		t.Fatalf("duration = %v, want 495（取自 video_model.video_duration）", media["duration"])
	}
	if key, _ := media["decryptionKey"].(string); len(key) != 32 {
		t.Fatalf("decryptionKey = %q, want 32 位十六进制", key)
	}
	if media["url"] == "" {
		t.Fatal("缺少播放地址")
	}
}

// hongguoCatalogFixture 造一个能同时回放首屏（bookmall tab）与翻页
// （cell/change）的 Downloader，并记录每次请求走了哪条路径。
//
// cellReply 决定 cell/change 第几次被调用时返回空（模拟 session 过期后
// 上游回 200 + 空列表）。
func hongguoCatalogFixture(t *testing.T, cellReply func(call int) string) (*Downloader, *[]string) {
	t.Helper()
	var requests []string
	cellCalls := 0
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		switch request.URL.Path {
		case hongguoBookmallTabPath:
			requests = append(requests, "tab")
			return sourceFixtureResponse(request, http.StatusOK, `{"code":0,"data":{"tab_item":[{`+
				`"tab_type":"5","has_more":true,"session_id":"s-1","cell_data":[{"cell_id":"c-1","show_type":"337",`+
				`"book_data":[{"book_id":"111","book_name":"首屏第一本"},{"book_id":"112","book_name":"首屏第二本"}]}]}]}}`), nil
		case hongguoBookmallCellChangePath:
			cellCalls++
			requests = append(requests, "cell@"+request.URL.Query().Get("offset"))
			body := `{"code":0,"data":{"has_more":true,"next_offset":"20","cell_view":{"cell_data":[{"book_data":[{"book_id":"221","book_name":"翻页第一本"}]}]}}}`
			if cellReply != nil {
				body = cellReply(cellCalls)
			}
			return sourceFixtureResponse(request, http.StatusOK, body), nil
		}
		return sourceFixtureResponse(request, http.StatusOK, `{"code":0,"data":{}}`), nil
	})
	return d, &requests
}

func countAudiobookRequests(requests []string, prefix string) int {
	total := 0
	for _, entry := range requests {
		if strings.HasPrefix(entry, prefix) {
			total++
		}
	}
	return total
}

// 翻页不该重复取首屏：首屏单次响应约 500KB、实测 4~5 秒，每次翻页都重取
// 会把「下一页」拖成两个请求（实测 5~10 秒）。元数据缓存后翻页只发
// cell/change 一个请求。
func TestAudiobookHongguoCatalogPagingSkipsSecondFeed(t *testing.T) {
	d, requests := hongguoCatalogFixture(t, nil)

	first, _, err := d.audiobookHongguoCatalog(testContext(), "listen", 1, nil)
	if err != nil {
		t.Fatalf("page 1: %v", err)
	}
	if len(first) != 2 {
		t.Fatalf("page 1 books = %d, want 2", len(first))
	}
	if countAudiobookRequests(*requests, "tab") != 1 {
		t.Fatalf("首屏应只取一次，实际 %v", *requests)
	}

	second, hasMore, err := d.audiobookHongguoCatalog(testContext(), "listen", 2, nil)
	if err != nil {
		t.Fatalf("page 2: %v", err)
	}
	if len(second) != 1 {
		t.Fatalf("page 2 books = %d, want 1", len(second))
	}
	if !hasMore {
		t.Fatal("next_offset 前进时应允许继续翻页")
	}
	if countAudiobookRequests(*requests, "tab") != 1 {
		t.Fatalf("翻页不该重取首屏（那次请求 500KB、4~5 秒），实际 %v", *requests)
	}
	if countAudiobookRequests(*requests, "cell@10") != 1 {
		t.Fatalf("第 2 页应对应 offset=10 的一次 cell/change，实际 %v", *requests)
	}
}

// 缓存里的 session 过期后上游会回 200 + 空列表；这时必须回退到重取首屏，
// 不能把空页当成「已经到底」。
func TestAudiobookHongguoCatalogPagingFallsBackWhenSessionStale(t *testing.T) {
	d, requests := hongguoCatalogFixture(t, func(call int) string {
		if call == 1 {
			// 第一次翻页：session 已失效，上游回一个空 cell。
			return `{"code":0,"data":{"has_more":true,"next_offset":"20","cell_view":{"cell_data":[]}}}`
		}
		return `{"code":0,"data":{"has_more":true,"next_offset":"20","cell_view":{"cell_data":[{"book_data":[{"book_id":"221","book_name":"翻页第一本"}]}]}}}`
	})

	if _, _, err := d.audiobookHongguoCatalog(testContext(), "listen", 1, nil); err != nil {
		t.Fatalf("page 1: %v", err)
	}
	books, _, err := d.audiobookHongguoCatalog(testContext(), "listen", 2, nil)
	if err != nil {
		t.Fatalf("page 2: %v", err)
	}
	if len(books) != 1 {
		t.Fatalf("page 2 books = %d, want 1（缓存的 session 失效后应重取首屏）", len(books))
	}
	if countAudiobookRequests(*requests, "tab") != 2 {
		t.Fatalf("应重取一次首屏，实际 %v", *requests)
	}
}

// 两个频道的 cell 元数据必须各存一份：共用会把「小说」的 cell_id 拿去翻「听书」，
// 拿回的是另一个频道的内容。
func TestAudiobookHongguoFeedMetaIsPerChannel(t *testing.T) {
	audiobookHongguoFeedMetas.Lock()
	audiobookHongguoFeedMetas.entries = map[string]audiobookHongguoFeedMeta{}
	audiobookHongguoFeedMetas.Unlock()

	audiobookHongguoRememberFeedMeta(audiobookHongguoCategories[0],
		audiobookHongguoFeedMeta{cellID: "listen-cell", showType: "337", session: "ls"})
	audiobookHongguoRememberFeedMeta(audiobookHongguoCategories[1],
		audiobookHongguoFeedMeta{cellID: "novel-cell", showType: "338", session: "ns"})

	listen, ok := audiobookHongguoFeedMetaFor(audiobookHongguoCategories[0])
	if !ok || listen.cellID != "listen-cell" {
		t.Fatalf("听书频道元数据 = %+v ok=%v", listen, ok)
	}
	novel, ok := audiobookHongguoFeedMetaFor(audiobookHongguoCategories[1])
	if !ok || novel.cellID != "novel-cell" {
		t.Fatalf("小说频道元数据 = %+v ok=%v", novel, ok)
	}
	if audiobookHongguoFeedMetas.entries["listen"].session == audiobookHongguoFeedMetas.entries["novel"].session {
		t.Fatal("两个频道的元数据不能混用")
	}
}

// 空 cell_id 不该进缓存：缓存了反而会让后续翻页一直走「重取首屏」还找不到栏目。
func TestAudiobookHongguoFeedMetaSkipsEmptyCell(t *testing.T) {
	audiobookHongguoFeedMetas.Lock()
	audiobookHongguoFeedMetas.entries = map[string]audiobookHongguoFeedMeta{}
	audiobookHongguoFeedMetas.Unlock()

	audiobookHongguoRememberFeedMeta(audiobookHongguoCategories[0], audiobookHongguoFeedMeta{session: "s"})
	if _, ok := audiobookHongguoFeedMetaFor(audiobookHongguoCategories[0]); ok {
		t.Fatal("cell_id 为空时不该写入缓存")
	}
}

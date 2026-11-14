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

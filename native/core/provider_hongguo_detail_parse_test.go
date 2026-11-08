package core

import "testing"

// 红果网页详情的 vid_list 只有开放的试看集，episode_cnt 才是全剧总集数。
// 回归「四个榜单点进详情都显示共 3 集」的问题。
func TestParseHongguoWebDetailKeepsTotalEpisodes(t *testing.T) {
	const id = "7702763145030290457"
	body := `<script>window._ROUTER_DATA = {"loaderData":{"detail_page":{"seriesDetail":{` +
		`"series_id":"` + id + `","series_name":"测试剧","episode_cnt":202,` +
		`"vid_list":["7702764976515075096","7702765030164401176","7702765100528061464"]` +
		`}}}}</script>`
	drama, chapters, err := parseHongguoWebDetail(body, id)
	if err != nil {
		t.Fatal(err)
	}
	if len(chapters) != 3 {
		t.Fatalf("可访问分集 = %d，期望 3", len(chapters))
	}
	if got := nativeNormalize(drama).Episodes; got != 202 {
		t.Fatalf("详情元数据总集数 = %d，期望 202", got)
	}
	if drama.DisplayTitle() != "测试剧" {
		t.Fatalf("详情标题 = %q", drama.DisplayTitle())
	}
}

func TestParseHongguoWebDetailRejectsEmptyPayload(t *testing.T) {
	if _, _, err := parseHongguoWebDetail("<html></html>", "7702763145030290457"); err == nil {
		t.Fatal("空详情不应被接受")
	}
}

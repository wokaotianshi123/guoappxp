package core

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestMagnetParseSizeBytes(t *testing.T) {
	cases := map[string]int64{
		"1.2 GB":     1288490188,
		"1.2GB":      1288490188,
		"1,234.5 MB": 1294467072,
		"800 KiB":    819200,
		"2 TB":       2199023255552,
		"512":        512,
		"":           0,
		"未知大小":       0,
	}
	for raw, want := range cases {
		got := magnetParseSizeBytes(raw)
		if want == 0 {
			if got != 0 {
				t.Errorf("magnetParseSizeBytes(%q) = %d, want 0", raw, got)
			}
			continue
		}
		if got < want-2 || got > want+2 {
			t.Errorf("magnetParseSizeBytes(%q) = %d, want ≈%d", raw, got, want)
		}
	}
	// 只有「大小」能按数值排，字典序会把 900 MB 排在 1.2 GB 后面。
	if magnetParseSizeBytes("1.2 GB") <= magnetParseSizeBytes("900 MB") {
		t.Fatal("按大小排序的归一化数值不正确")
	}
}

func TestMagnetParseTimestamp(t *testing.T) {
	now := time.Date(2026, 11, 9, 12, 0, 0, 0, time.Local)
	full := time.Date(2026, 11, 8, 0, 0, 0, 0, time.Local).Unix()
	for _, raw := range []string{"2026-11-08", "2026/11/08", "2026-11-08 10:20:30"} {
		if got := magnetParseTimestamp(raw, now); got != full {
			t.Errorf("magnetParseTimestamp(%q) = %d, want %d", raw, got, full)
		}
	}
	if got := magnetParseTimestamp("3天前", now); got != now.Add(-72*time.Hour).Unix() {
		t.Errorf("相对时间解析错误: %d", got)
	}
	if got := magnetParseTimestamp("2小时前", now); got != now.Add(-2*time.Hour).Unix() {
		t.Errorf("小时相对时间解析错误: %d", got)
	}
	for _, raw := range []string{"", "未知时间", "2026-13-45"} {
		if got := magnetParseTimestamp(raw, now); got != 0 {
			t.Errorf("magnetParseTimestamp(%q) = %d, want 0", raw, got)
		}
	}
	if magnetParseTimestamp("2026-11-08", now) <= magnetParseTimestamp("2026-10-01", now) {
		t.Fatal("按时间排序的归一化数值不正确")
	}
}

func TestMagnetParseListExposesSortableNumbers(t *testing.T) {
	hex := "1111111111111111111111111111111111111111"
	site := magnetSite{
		ID: 90001, Name: "测试站",
		Request: magnetSiteRequest{MainURL: "https://a.test"},
		Expression: magnetSiteExpression{
			Group: "//div[@class='item']", Title: ".//h3/a",
			Size: ".//span[@class='size']", Date: ".//span[@class='date']",
			Magnet: ".//h3/a/@href",
		},
	}
	body := "<div class='item'><h3><a href='/hash/" + hex + "'>资源一</a></h3>" +
		"<span class='size'>1.2 GB</span><span class='date'>2026-11-08</span></div>"
	items := magnetParseList(site, body)
	if len(items) != 1 {
		t.Fatalf("解析出 %d 条, want 1", len(items))
	}
	if items[0].SizeBytes < 1<<30 || items[0].Timestamp == 0 {
		t.Fatalf("排序数值缺失: %+v", items[0])
	}
	encoded, err := json.Marshal(items[0])
	if err != nil {
		t.Fatal(err)
	}
	for _, field := range []string{`"sizeBytes"`, `"timestamp"`, `"siteId"`} {
		if !strings.Contains(string(encoded), field) {
			t.Errorf("搜索结果缺少字段 %s: %s", field, encoded)
		}
	}
}

func TestMagnetHashValid(t *testing.T) {
	for _, valid := range []string{
		"1111111111111111111111111111111111111111",
		"abcdefabcdefabcdefabcdefabcdefabcdefabcd",
		"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
	} {
		if !magnetHashValid(valid) {
			t.Errorf("合法 infohash 被拒绝: %s", valid)
		}
	}
	for _, invalid := range []string{"", "not-a-hash", "00000000000000000000000000000000", "11111111111111111111111111111111111111111"} {
		if magnetHashValid(invalid) {
			t.Errorf("非法 infohash 被放行: %s", invalid)
		}
	}
}

func TestMagnetPeersIgnoresInvalidHashesWithoutEngine(t *testing.T) {
	// 全是非法 hash 时不应懒启动 BT 客户端（会占端口和缓存目录）。
	result, err := magnetPeers(context.Background(), []string{"", "bad", "标题文字"}, "", false)
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Items) != 0 || result.Probing != 0 {
		t.Fatalf("非法 hash 不该触发探测: %+v", result)
	}
}

func TestMagnetLoadManagerSwitchesHashImmediately(t *testing.T) {
	manager := &magnetLoadManager{active: map[string]*magnetLoad{}}
	hashA := "1111111111111111111111111111111111111111"
	hashB := "2222222222222222222222222222222222222222"
	ctxA, doneA := manager.begin(context.Background(), hashA, nil)
	// 同一个 infohash 的并发请求共享一个 context，不能互相取消。
	ctxA2, doneA2 := manager.begin(context.Background(), hashA, nil)
	if ctxA2 != ctxA || manager.pending() != 1 {
		t.Fatal("同一 hash 的并发加载应共享可取消 context")
	}
	dropped := []string{}
	ctxB, doneB := manager.begin(context.Background(), hashB, func(hash string) {
		dropped = append(dropped, hash)
	})
	if ctxA.Err() == nil {
		t.Fatal("点新磁力后旧加载没有被立即取消")
	}
	if len(dropped) != 1 || dropped[0] != hashA {
		t.Fatalf("旧任务没有被释放: %v", dropped)
	}
	if ctxB.Err() != nil || manager.pending() != 1 {
		t.Fatalf("新任务被误取消: err=%v pending=%d", ctxB.Err(), manager.pending())
	}
	doneA()
	doneA2()
	doneB()
	if manager.pending() != 0 {
		t.Fatalf("活动加载没有清空: %d", manager.pending())
	}
}

func TestMagnetLoadManagerCancelAll(t *testing.T) {
	manager := &magnetLoadManager{active: map[string]*magnetLoad{}}
	hash := "1111111111111111111111111111111111111111"
	ctx, done := manager.begin(context.Background(), hash, nil)
	dropped := []string{}
	manager.cancelAll(func(value string) { dropped = append(dropped, value) })
	if ctx.Err() == nil || len(dropped) != 1 || manager.pending() != 0 {
		t.Fatalf("cancelAll 没生效: err=%v dropped=%v pending=%d", ctx.Err(), dropped, manager.pending())
	}
	done()
}

func TestMagnetCancelAllIsSafeWhenIdle(t *testing.T) {
	// 用户还没播过任何磁力就点切换，不能因为引擎未启动而 panic。
	magnetCancelAll()
	magnetCancelAll()
}

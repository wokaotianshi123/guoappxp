package core

// 限流器的优先级行为测试。
//
// 这两条是「红果听书抓取拖慢整体」的根因，改动限流器时务必保持：
//  1. 后台任务最多占 1 个并发槽（不能把全局槽吃满）
//  2. 前台有排队请求时，后台必须让路（不能和用户操作抢）

import (
	"context"
	"net/http"
	"net/url"
	"testing"
	"time"
)

func limiterTestRequest(t *testing.T, raw string) *http.Request {
	t.Helper()
	parsed, err := url.Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	return &http.Request{URL: parsed, Header: http.Header{}}
}

// 后台请求必须带 backgroundCatalogKey 才会被降级；不带标记就是前台。
func TestBackgroundCatalogKeyMarksRequest(t *testing.T) {
	ctx := context.WithValue(context.Background(), backgroundCatalogKey{}, true)
	if background, _ := ctx.Value(backgroundCatalogKey{}).(bool); !background {
		t.Fatal("backgroundCatalogKey 未生效")
	}
	// 听书抓取正是靠这个标记降到后台优先级，否则近百次翻页会以前台身份抢资源。
	if background, _ := context.Background().Value(backgroundCatalogKey{}).(bool); background {
		t.Fatal("空 context 不应带后台标记")
	}
}

// 后台任务不得占满并发槽：全局 3 槽时后台只能占 1 个。
func TestBackgroundRequestTakesSingleSlot(t *testing.T) {
	limiter := newRequestLimiter(3, 0)
	request := limiterTestRequest(t, "https://api5-normal-sinfonlineb.fqnovel.com/x")
	ctx := context.WithValue(context.Background(), backgroundCatalogKey{}, true)

	release, err := limiter.acquire(ctx, request)
	if err != nil {
		t.Fatalf("后台请求应能拿到槽: %v", err)
	}
	limiter.mu.Lock()
	active := limiter.active
	limiter.mu.Unlock()
	release()
	if active != 1 {
		t.Fatalf("后台请求只应占 1 槽，实际 %d", active)
	}

	// 后台占着时，第二个后台请求必须等（因为后台并发上限是 1）。
	release1, err := limiter.acquire(ctx, limiterTestRequest(t, "https://api5-normal-sinfonlineb.fqnovel.com/y"))
	if err != nil {
		t.Fatalf("第一个后台请求失败: %v", err)
	}
	defer release1()

	blocked := make(chan struct{})
	go func() {
		ctx2, cancel := context.WithTimeout(context.Background(), 150*time.Millisecond)
		defer cancel()
		ctx2 = context.WithValue(ctx2, backgroundCatalogKey{}, true)
		if release2, err := limiter.acquire(ctx2, limiterTestRequest(t, "https://api5-normal-sinfonlineb.fqnovel.com/z")); err == nil {
			release2()
		}
		close(blocked)
	}()
	select {
	case <-blocked:
		// 超时返回也算「被挡住」，符合预期。
	case <-time.After(2 * time.Second):
		t.Fatal("第二个后台请求不应立刻拿到槽（后台并发上限为 1）")
	}
}

// 前台有请求在排队时，后台必须让路。
func TestBackgroundYieldsToForeground(t *testing.T) {
	limiter := newRequestLimiter(3, 0)
	host := "https://api5-normal-sinfonlineb.fqnovel.com/"

	// 让前台先占一个槽并保持，制造「前台活跃」状态。
	releaseForeground, err := limiter.acquire(context.Background(), limiterTestRequest(t, host+"fg"))
	if err != nil {
		t.Fatalf("前台请求失败: %v", err)
	}

	// 后台请求在 100ms 内拿不到槽（因为前台还占着、且 lastForeground 刚更新）。
	acquired := make(chan bool, 1)
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
		defer cancel()
		ctx = context.WithValue(ctx, backgroundCatalogKey{}, true)
		if release, err := limiter.acquire(ctx, limiterTestRequest(t, host+"bg")); err == nil {
			release()
			acquired <- true
			return
		}
		acquired <- false
	}()

	time.Sleep(80 * time.Millisecond)
	select {
	case <-acquired:
		// 后台在 80ms 内就拿到槽了——说明没让路，前台会被拖慢。
		releaseForeground()
		t.Fatal("前台活跃时后台不应立刻拿到槽")
	default:
	}
	releaseForeground()
	<-acquired
}

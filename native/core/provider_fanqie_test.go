package core

import (
	"errors"
	"strings"
	"testing"
)

// 番茄站源的纯映射逻辑（不联网、不需要本机引擎）。

func TestFanqieDramaFromCardMapsCoreFields(t *testing.T) {
	row := map[string]any{
		"series_id_str":   "7300000000000000001",
		"series_title":    "总裁的替身新娘",
		"series_intro":    "一场意外的替身婚姻……",
		"series_cover":    "https://p3.example.com/cover.jpg",
		"episode_cnt":     "80",
		"channel_name":    "都市",
		"category_schema": `[{"name":"甜宠"},{"name":"逆袭"}]`,
		"rec_text":        "1.2 亿播放",
	}
	drama := fanqieDramaFromCard(row, "短剧")
	if drama.ID != "fanqie:7300000000000000001" {
		t.Fatalf("drama id = %q", drama.ID)
	}
	if drama.Source != sourceFanqie || drama.SourceID != "7300000000000000001" {
		t.Fatalf("source mapping wrong: %+v", drama)
	}
	if drama.Title != "总裁的替身新娘" || drama.Name != "总裁的替身新娘" {
		t.Fatalf("title mapping wrong: %q / %q", drama.Title, drama.Name)
	}
	if drama.Cover != "https://p3.example.com/cover.jpg" {
		t.Fatalf("cover mapping wrong: %v", drama.Cover)
	}
	if drama.Category != "甜宠" {
		t.Fatalf("category should come from category_schema, got %q", drama.Category)
	}
	if drama.ChannelName != "都市" {
		t.Fatalf("channel mapping wrong: %q", drama.ChannelName)
	}
	if drama.Heat != "1.2 亿播放" {
		t.Fatalf("heat mapping wrong: %q", drama.Heat)
	}
}

func TestFanqieDramaFromCardRejectsMissingSeriesID(t *testing.T) {
	if drama := fanqieDramaFromCard(map[string]any{"series_title": "无 ID"}, "短剧"); drama.ID != "" {
		t.Fatalf("card without series id should be dropped, got %+v", drama)
	}
}

func TestFanqieVariantHeightsDedupesAndSortsDesc(t *testing.T) {
	payload := map[string]any{
		"variants": []any{
			map[string]any{"width": float64(720), "height": float64(1280)},
			map[string]any{"width": float64(1080), "height": float64(1920)},
			map[string]any{"width": float64(720), "height": float64(1280)},
			map[string]any{"height": float64(480)},
			map[string]any{"width": float64(0), "height": float64(0)},
		},
	}
	heights := fanqieVariantHeights(payload)
	want := []int{1080, 720, 480}
	if len(heights) != len(want) {
		t.Fatalf("heights = %v, want %v", heights, want)
	}
	for index, value := range want {
		if heights[index] != value {
			t.Fatalf("heights = %v, want %v", heights, want)
		}
	}
}

func TestFanqieCategoriesAndSourceIdentity(t *testing.T) {
	if canonicalProviderSource("fanqie") != sourceFanqie {
		t.Fatal("fanqie should canonicalize to itself")
	}
	if canonicalProviderSource("番茄") != sourceFanqie {
		t.Fatal("chinese alias should canonicalize to fanqie")
	}
	if !isHuangguoProviderSource(sourceFanqie) {
		t.Fatal("fanqie must be a known provider source")
	}
	if !nativeSourceAvailable(sourceFanqie) {
		t.Fatal("fanqie must stay available in every build variant")
	}
	if !validNativeCategory(sourceFanqie, fanqieCategoryKanju) ||
		!validNativeCategory(sourceFanqie, fanqieCategoryManju) {
		t.Fatal("kanju/manju should be valid fanqie categories")
	}
	if validNativeCategory(sourceFanqie, "unknown") {
		t.Fatal("unknown fanqie category must be rejected")
	}
	if !nativeSourceSupportsSearch(sourceFanqie) {
		t.Fatal("fanqie supports online search")
	}
	if label := nativeSearchSourceLabel(sourceFanqie); label != "番茄" {
		t.Fatalf("fanqie search label = %q", label)
	}
}

func TestFanqieOfflineHintGuidesUser(t *testing.T) {
	// 三种可能出现的错误形态都要被翻译：Go 标准库、tls-client(Rust)、
	// Windows 本地化文案。少一种就会有平台看到一串机器味儿的原始报错。
	for name, cause := range map[string]error{
		"go":     errFanqieStub{},
		"rust":   errFanqieRustStub{},
		"zh_win": errFanqieChineseStub{},
	} {
		err := fanqieOfflineHint(cause)
		if err == nil || !strings.Contains(err.Error(), "番茄内容引擎未就绪") {
			t.Fatalf("%s: connection failure should carry an actionable hint, got %v", name, err)
		}
		if !strings.Contains(err.Error(), "18921") {
			t.Fatalf("%s: hint should mention the engine port, got %v", name, err)
		}
		// 原始错误必须保留：真机上只看「未就绪」永远查不出是没起来、被拒还是
		// 引擎中途挂了。
		if !strings.Contains(err.Error(), cause.Error()) {
			t.Fatalf("%s: hint should keep the original error, got %v", name, err)
		}
	}
	// 引擎活着但返回业务错误时，不能被误译成「未就绪」。
	real := errors.New("番茄引擎错误 500: upstream busy")
	if got := fanqieOfflineHint(real); got != real {
		t.Fatalf("business errors must pass through, got %v", got)
	}
	// 错误出口会做 URL 脱敏（https?://[^\s"'<>]+ 会连后面中文一起吞掉），
	// 所以提示里不能带 scheme，否则用户只能看到半截话。
	surfaced := publicError(fanqieOfflineHint(errFanqieRustStub{})).Error()
	if !strings.Contains(surfaced, "未就绪") || !strings.Contains(surfaced, "18921") {
		t.Fatalf("hint must survive URL redaction intact, got %q", surfaced)
	}
	if strings.Contains(surfaced, "http://") {
		t.Fatalf("hint should not embed a scheme-prefixed URL: %q", surfaced)
	}
}

// TestFanqieLoopbackURLIsNotRehosted 守住一个关键前提：番茄请求打的是本机
// loopback（127.0.0.1:18921），通用取文链路里的「站源域名改写」绝不能把它
// 换成某个上游域名——否则会出现「本地引擎明明活着，请求却飞到了外网」的怪象。
func TestFanqieLoopbackURLIsNotRehosted(t *testing.T) {
	raw := fanqieDefaultBaseURL + "/api/v1/videos/123?quality=720"
	if source := providerSourceForURL(raw); source != "" {
		t.Fatalf("loopback URL should not resolve to a provider source, got %q", source)
	}
	downloader := &Downloader{}
	candidates := downloader.providerURLCandidates(raw)
	if len(candidates) != 1 || candidates[0] != raw {
		t.Fatalf("loopback URL must be used as-is, got %v", candidates)
	}
}

type errFanqieStub struct{}

func (errFanqieStub) Error() string {
	return "Get \"http://127.0.0.1:18921/x\": dial tcp 127.0.0.1:18921: connect: connection refused"
}

// errFanqieRustStub 是 tls-client（Rust 后端）拒绝连接时的文案。
type errFanqieRustStub struct{}

func (errFanqieRustStub) Error() string {
	return "upstream connect failed: No connection could be made because the target machine actively refused it. (os error 10061)"
}

// errFanqieChineseStub 是中文 Windows 上的本地化文案。
type errFanqieChineseStub struct{}

func (errFanqieChineseStub) Error() string {
	return "upstream connect failed: 由于目标计算机积极拒绝，无法连接。 (os error 10061)"
}

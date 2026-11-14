package core

// 上游 guoappxpx 站源兼容性契约测试。
//
// 这些用例锁定「上游放出的站源文件能否直接编译并跑通」所依赖的公开面：
// 契约符号存在、字段可写、可选接口可被运行时识别、版本裁剪生效。
// 以后改动 core 的导出面时，这里会先红，避免悄悄破坏上游源的适配性。

import (
	"context"
	"encoding/json"
	"net/url"
	"testing"
)

// 上游源文件里最常见的写法：用空结构体断言契约版本。
var _ SourceAPI1

// 上游源必须能实现的五件套。
type contractProbe struct{}

func (contractProbe) Descriptor() SourceDescriptor { return SourceDescriptor{ID: "probe"} }
func (contractProbe) Categories(context.Context, bool) ([]Category, error) {
	return nil, nil
}
func (contractProbe) CatalogPage(context.Context, int, string) ([]Drama, bool, error) {
	return nil, false, nil
}
func (contractProbe) Detail(context.Context, string) (Drama, []Chapter, error) {
	return Drama{}, nil, nil
}
func (contractProbe) ResolveMedia(context.Context, Task) (ProviderMedia, error) {
	return ProviderMedia{}, nil
}

var _ Provider = contractProbe{}

// 上游源会直接给 ProviderMedia.Credentials 赋值、读 MediaCredentials 的导出字段。
func TestUpstreamMediaCredentialsAreExported(t *testing.T) {
	media := ProviderMedia{URL: "https://cdn.example.test/a.m3u8"}
	media.Credentials = &MediaCredentials{
		Cookie:    "session=1",
		Origin:    "https://cdn.example.test",
		Referer:   "https://source.example.test/",
		UserAgent: "Agent",
	}
	if media.Credentials.Cookie != "session=1" || media.Credentials.Referer == "" {
		t.Fatal("MediaCredentials 字段必须可读写（上游源直接赋值）")
	}
	if _, ok := any(MediaCredentialsKey{}).(MediaCredentialsKey); !ok {
		t.Fatal("MediaCredentialsKey 必须存在（上游源用它取凭据）")
	}
}

// 上游可选接口必须都能被运行时类型断言识别。
func TestUpstreamOptionalInterfacesExist(t *testing.T) {
	var _ CoverRepairer = coverProbe{}
	var _ CoverResolver = coverProbe{}
	var _ CoverRefererProvider = coverProbe{}
	var _ MediaAuthorizer = coverProbe{}
	var _ MetadataEnricher = coverProbe{}
	var _ SeasonProvider = coverProbe{}
	var _ DeviceProvider = coverProbe{}
	var _ DanmakuProvider = coverProbe{}
	var _ Recommender = coverProbe{}
	var _ Suggester = coverProbe{}
	var _ CatalogStateful = coverProbe{}
}

type coverProbe struct{}

func (coverProbe) RepairCover(LibraryDrama) string { return "" }
func (coverProbe) CoverAddress(context.Context, LibraryDrama, string) (string, error) {
	return "", nil
}
func (coverProbe) CoverReferer(string) string    { return "" }
func (coverProbe) AuthorizesMedia(*url.URL) bool { return false }
func (coverProbe) MediaAuthorization(context.Context, *url.URL, string) (string, string, error) {
	return "", "", nil
}
func (coverProbe) RejectMediaAuthorization(*url.URL, string) {}
func (coverProbe) NeedsExtraMetadata(LibraryDrama) bool      { return false }
func (coverProbe) ExtraMetadata(context.Context, LibraryDrama, string) (LibraryDrama, error) {
	return LibraryDrama{}, nil
}
func (coverProbe) Seasons(context.Context, string) ([]Season, error) { return nil, nil }
func (coverProbe) Devices(context.Context, bool) (bool, error)       { return false, nil }
func (coverProbe) DanmakuIDs(Task) (string, string, bool)            { return "", "", false }
func (coverProbe) Danmaku(context.Context, string, string, int64, int64) (DanmakuPage, error) {
	return DanmakuPage{}, nil
}
func (coverProbe) ValidRecommendation(string, json.RawMessage) error { return nil }
func (coverProbe) Recommendations(context.Context, string, json.RawMessage, []string) (RecommendationPage, error) {
	return RecommendationPage{}, nil
}
func (coverProbe) Suggestions(context.Context, string) ([]string, error) { return nil, nil }
func (coverProbe) CatalogState() json.RawMessage                         { return nil }
func (coverProbe) RestoreCatalogState(json.RawMessage)                   {}

// 上游 helper 必须存在且语义可用（源文件直接调用它们）。
func TestUpstreamHelpersAreExported(t *testing.T) {
	if got := ExtractPageTitle(`<html><h1>标题甲</h1></html>`); got != "标题甲" {
		t.Fatalf("ExtractPageTitle = %q", got)
	}
	if got := ExtractDescription(`<meta name="description" content="简介乙">`); got != "简介乙" {
		t.Fatalf("ExtractDescription = %q", got)
	}
	if got := ExtractAttr(`<a data-id="42" href="/x">`, "data-id"); got != "42" {
		t.Fatalf("ExtractAttr = %q", got)
	}
	if got := EpisodeIndex("更新至 12 集", 1); got != 12 {
		t.Fatalf("EpisodeIndex = %d", got)
	}
	if got := NormalizeDate("2026年11月14日 2026-11-14"); got != "2026-11-14" {
		t.Fatalf("NormalizeDate = %q", got)
	}
	if got := ProviderDramaID("probe", " 9 "); got != "probe:9" {
		t.Fatalf("ProviderDramaID = %q", got)
	}
	if source, id, ok := SplitProviderDramaID("hongguo:123"); !ok || source != sourceHongguo || id != "123" {
		t.Fatalf("SplitProviderDramaID = %q %q %v", source, id, ok)
	}
	if got := RehostProviderURL(mustParseURL(t, "https://old.example/a/b?q=1"), "https://new.example"); got != "https://new.example/a/b?q=1" {
		t.Fatalf("RehostProviderURL = %q", got)
	}
	if !IsProviderHTTPMediaURL("https://cdn.example.test/a.m3u8") {
		t.Fatal("IsProviderHTTPMediaURL 拒绝了合法地址")
	}
	if ProviderMaxBodyBytes <= 0 || ProviderChinaTime == nil {
		t.Fatal("ProviderMaxBodyBytes / ProviderChinaTime 未导出")
	}
	if len(Pkcs7Pad([]byte("abc"), 8)) != 8 {
		t.Fatal("Pkcs7Pad 未按块补齐")
	}
}

func mustParseURL(t *testing.T, raw string) *url.URL {
	t.Helper()
	parsed, err := url.Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	return parsed
}

// 上游站源模块用 RegisterFlavor 声明版本归属，运行时据此裁剪源列表。
func TestRegisterFlavorGatesSources(t *testing.T) {
	previousFlavor := activeFlavor
	previousAll := buildAllSources
	t.Cleanup(func() {
		activeFlavor = previousFlavor
		buildAllSources = previousAll
	})

	activeFlavor = buildFlavorSpec{}
	buildAllSources = "true"
	RegisterFlavor("hongguojian", []string{sourceGuipian})
	if got := BuildFlavor(); got != "hongguojian" {
		t.Fatalf("BuildFlavor = %q", got)
	}
	if !nativeSourceAvailable(sourceGuipian) {
		t.Fatal("flavor 清单里的源应可用")
	}
	// 红果 / 番茄是 core 内置源，任何 flavor 都保留。
	if !nativeSourceAvailable(sourceHongguo) || !nativeSourceAvailable(sourceFanqie) {
		t.Fatal("内置源不应被 flavor 裁掉")
	}
	if nativeSourceAvailable(sourceA123) {
		t.Fatal("不在 flavor 清单里的源必须不可用")
	}
}

// 上游 sources_example 是「站源怎么写」的活文档，可以编进来验证契约，
// 但绝不能出现在站源下拉框、聚合搜索或任何默认列表里。
func TestDemoProviderSourcesAreHidden(t *testing.T) {
	demo := SourceDescriptor{
		ID:                "example",
		Name:              "示例",
		Description:       "假数据示例站源，不访问网络",
		AllowEmptyCatalog: true,
	}
	if !isDemoProviderSource(demo) {
		t.Fatal("上游示例源必须被判定为示例源")
	}
	// 只有描述符特征、没有固定 ID 的示例源同样要识别出来。
	anonymous := SourceDescriptor{
		ID:                "some-fixture",
		Name:              "假数据",
		AllowEmptyCatalog: true,
	}
	if !isDemoProviderSource(anonymous) {
		t.Fatal("描述符自称假数据的源必须被判定为示例源")
	}
	// 正常站源不能被误判：有真实站点地址的不算示例源。
	real := SourceDescriptor{
		ID:                "realsite",
		Name:              "真站",
		Description:       "分类视频 · 在线搜索",
		BaseURL:           "https://real.example.test",
		AllowEmptyCatalog: false,
	}
	if isDemoProviderSource(real) {
		t.Fatal("正常站源被误判为示例源")
	}
	// 真实源即使声明允许空目录，只要有站点地址就不算示例源。
	emptyCatalog := SourceDescriptor{
		ID:                "emptysite",
		Name:              "空目录站",
		BaseURL:           "https://empty.example.test",
		AllowEmptyCatalog: true,
	}
	if isDemoProviderSource(emptyCatalog) {
		t.Fatal("有站点地址的源不应被判为示例源")
	}
}

// 示例源编进二进制后也必须判定为不可用（不进列表、不可直接请求）。
func TestDemoSourceIsUnavailableEvenWhenRegistered(t *testing.T) {
	previousFlavor, previousAll := activeFlavor, buildAllSources
	t.Cleanup(func() { activeFlavor, buildAllSources = previousFlavor, previousAll })
	activeFlavor = buildFlavorSpec{}
	buildAllSources = "true"

	descriptor := SourceDescriptor{
		ID: "demo-fixture", Name: "示例", Description: "假数据示例站源",
		AllowEmptyCatalog: true,
	}
	Register(descriptor, func(Host) Provider { return contractProbe{} })
	t.Cleanup(func() { unregisterSource("demo-fixture") })

	if nativeSourceAvailable("demo-fixture") {
		t.Fatal("示例源即使注册了也必须判定为不可用")
	}
}

package core

// 听书相关文件从 guoappxp 移植过来时用到的小工具。这些函数在 guoappxp 里散落在
// provider_huangguo.go / provider_hongguo.go / source_sites.go / helpers.go，
// guoappxpx 没有对应实现，因此在这里集中补一份最小版本，避免为了几个工具函数
// 把整站源搬过来。

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// NativeCategory 是听书频道分类的类型别名，与 Category 结构一致。
type NativeCategory = Category

// m3u8Duration 累加 m3u8 媒体清单里各分片的 #EXTINF 时长（网页取流时补时长用）。
func m3u8Duration(raw string) time.Duration {
	var total time.Duration
	for _, line := range strings.Split(raw, "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "#EXTINF:") {
			continue
		}
		value := strings.TrimSpace(strings.TrimPrefix(line, "#EXTINF:"))
		if comma := strings.IndexByte(value, ','); comma >= 0 {
			value = value[:comma]
		}
		seconds, err := strconv.ParseFloat(strings.TrimSpace(value), 64)
		if err != nil || seconds < 0 || math.IsNaN(seconds) || math.IsInf(seconds, 0) {
			continue
		}
		total += time.Duration(seconds * float64(time.Second))
	}
	return total
}

// requestBackoff 是限流 / 403 冷却的退避错误。guoappxpx 侧导出的名字是
// RequestBackoff，搬运过来的短剧 / MacCMS 代码沿用 guoappxp 的写法。
type requestBackoff = RequestBackoff

// providerTextMirrorsKey 是「文本请求的镜像列表」ctx 标记。guoappxpx 没有
// 镜像轮换，保留类型定义只为让搬运过来的代码编译通过。
type providerTextMirrorsKey struct{}

// providerDramaID 拼装剧 ID：<站源>:<站内剧 ID>。
func providerDramaID(source, sourceID string) string {
	return source + ":" + strings.TrimSpace(sourceID)
}

// providerSearch 是搜索的统一派发口：优先带警告的搜索（站点会提示结果被截断），
// 其次普通搜索；两者都没实现的源返回错误，让调用方决定是提示用户还是静默跳过。
func providerSearch(ctx context.Context, provider Provider, page int, query string) ([]Drama, bool, error) {
	if searcher, ok := providerAs[WarningSearcher](provider); ok {
		dramas, more, _, err := searcher.SearchWithWarning(ctx, page, query)
		return dramas, more, err
	}
	if searcher, ok := providerAs[Searcher](provider); ok {
		return searcher.Search(ctx, page, query)
	}
	return nil, false, errors.New("该站源不支持搜索")
}

// fetchProviderText 拉取站源页面文本。guoappxpx 的实现在 provider_media.go 里
// 叫 fetchProviderRequest，这里给搬运过来的短剧 / XBPQ 代码留一个同名入口。
func (d *Downloader) fetchProviderText(ctx context.Context, rawURL, referer string) (string, error) {
	return d.fetchProviderRequest(ctx, rawURL, referer, nil)
}

// recordGoroutinePanic 记录后台协程里的 panic。guoappxpx 的诊断日志结构不同，
// 这里降级为写诊断日志（若可用），不影响业务逻辑。
func (d *Downloader) recordGoroutinePanic(label string, recovered any) {
	if d == nil {
		return
	}
	defer func() { _ = recover() }()
	if d.diagnostics == nil {
		return
	}
	d.diagnostics.write(diagnosticEvent{
		Level: "error",
		Event: "goroutine_panic",
		Message: fmt.Sprintf("%s: %v", label, recovered),
	})
}

// sourceProvider 是 guoappxp 侧「按站源 ID 取 Provider」的入口，
// guoappxpx 对应的方法叫 provider。
func (d *Downloader) sourceProvider(source string) (Provider, bool) {
	return d.provider(source)
}

// providerTimeout 是单次站源请求的超时上限，与 guoappxp 一致。
const providerTimeout = 12 * time.Second

// nativeText 把任意值归一到文本，供站源解析读取字段。
func nativeText(value any) string {
	switch v := value.(type) {
	case string:
		return strings.TrimSpace(v)
	case map[string]any:
		for _, key := range []string{"url", "src", "cover", "image", "pic"} {
			if text := nativeText(v[key]); text != "" {
				return text
			}
		}
	case []any:
		for _, entry := range v {
			if text := nativeText(entry); text != "" {
				return text
			}
		}
	case float64:
		if v == float64(int64(v)) {
			return strconv.FormatInt(int64(v), 10)
		}
		return strconv.FormatFloat(v, 'f', -1, 64)
	case int:
		return strconv.Itoa(v)
	case json.Number:
		return v.String()
	}
	return ""
}

// rawEpisode 生成剧集原始 JSON（纯数字集号）。
func rawEpisode(n int) json.RawMessage {
	if n <= 0 {
		n = 1
	}
	return json.RawMessage(strconv.Itoa(n))
}

// episodeIndex 从标题里提取集号，取不到时用 fallback。
func episodeIndex(s string, fallback int) int {
	if m := reEpisodeNumber.FindStringSubmatch(s); len(m) > 1 {
		for _, group := range m[1:] {
			if group == "" {
				continue
			}
			if n, err := strconv.Atoi(group); err == nil && n > 0 {
				return n
			}
		}
	}
	return fallback
}

// providerChapterID 拼装剧集 ID：<站源>:<站内剧 ID>:<集 key>。
func providerChapterID(source, sourceID, chapterKey string) string {
	return source + ":" + strings.TrimSpace(sourceID) + ":" + strings.TrimSpace(chapterKey)
}

// providerCategories 取站源分类，失败时返回 nil（调用方据此走兜底）。
func providerCategories(ctx context.Context, provider Provider, force bool) []Category {
	categories, err := provider.Categories(ctx, force)
	if err != nil {
		return nil
	}
	return categories
}

// providerCoverAddress 从任意 JSON 形态里取封面地址并补成绝对地址。
func providerCoverAddress(value any, pageURL string) string {
	switch item := value.(type) {
	case []any:
		for _, value := range item {
			if address := providerCoverAddress(value, pageURL); address != "" {
				return address
			}
		}
	case map[string]any:
		for _, key := range []string{"url", "contentUrl", "thumbnailUrl"} {
			if address := providerCoverAddress(item[key], pageURL); address != "" {
				return address
			}
		}
	case string:
		if strings.TrimSpace(item) == "" {
			return ""
		}
		address, err := url.Parse(strings.TrimSpace(item))
		if err != nil {
			return ""
		}
		if base, err := url.Parse(pageURL); err == nil && base.IsAbs() {
			address = base.ResolveReference(address)
		}
		if IsProviderHTTPMediaURL(address.String()) {
			return address.String()
		}
	}
	return ""
}

// providerEpisode 是站源解析出的单集（短剧引擎 / MacCMS 解析用）。
type providerEpisode struct {
	Key   string
	Title string
	URL   string
	Index int
	HLS   string
}

// providerMaxBodyBytes 是单次站源响应体的上限（8MB），与 guoappxp 一致。
const providerMaxBodyBytes = 8 << 20

// backgroundCatalogKey 是「后台预热请求」的 ctx 标记。guoappxpx 侧导出的
// 名字是 BackgroundCatalogKey，听书代码沿用 guoappxp 的写法，这里做别名。
type backgroundCatalogKey = BackgroundCatalogKey

func mapString(m map[string]any, keys ...string) string {
	for _, key := range keys {
		v, ok := m[key]
		if !ok {
			continue
		}
		switch x := v.(type) {
		case string:
			if text := strings.TrimSpace(x); text != "" {
				return text
			}
		case bool:
			return strconv.FormatBool(x)
		case float64:
			if x == float64(int64(x)) {
				return strconv.FormatInt(int64(x), 10)
			}
			return strconv.FormatFloat(x, 'f', -1, 64)
		case int:
			return strconv.Itoa(x)
		case json.Number:
			return x.String()
		}
	}
	return ""
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if strings.TrimSpace(v) != "" {
			return strings.TrimSpace(v)
		}
	}
	return ""
}

func nestedMap(v any, keys ...string) map[string]any {
	cur, _ := v.(map[string]any)
	for _, key := range keys {
		if cur == nil {
			return nil
		}
		cur, _ = cur[key].(map[string]any)
	}
	return cur
}

func anyList(v any) []any {
	switch x := v.(type) {
	case []any:
		return x
	case map[string]any:
		for _, key := range []string{"list", "items", "data"} {
			if out := anyList(x[key]); len(out) > 0 {
				return out
			}
		}
	}
	return nil
}

func truncate(s string, n int) string {
	s = strings.TrimSpace(s)
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n]) + "..."
}

func randomHex(n int) string {
	buffer := make([]byte, n)
	if _, err := rand.Read(buffer); err != nil {
		return ""
	}
	return hex.EncodeToString(buffer)
}

// uuidLike 生成 8-4-4-4-12 形式的随机标识（红果设备号用）。
func uuidLike() string {
	raw := randomHex(16)
	if len(raw) != 32 {
		return raw
	}
	return raw[:8] + "-" + raw[8:12] + "-" + raw[12:16] + "-" + raw[16:20] + "-" + raw[20:]
}

func pkcs7Pad(src []byte, blockSize int) []byte {
	pad := blockSize - len(src)%blockSize
	return append(src, bytes.Repeat([]byte{byte(pad)}, pad)...)
}

func pkcs7Unpad(src []byte, blockSize int) ([]byte, error) {
	if len(src) == 0 || len(src)%blockSize != 0 {
		return nil, errors.New("invalid pkcs7 length")
	}
	pad := int(src[len(src)-1])
	if pad == 0 || pad > blockSize || pad > len(src) {
		return nil, errors.New("invalid pkcs7 padding")
	}
	for _, v := range src[len(src)-pad:] {
		if int(v) != pad {
			return nil, errors.New("invalid pkcs7 padding bytes")
		}
	}
	return src[:len(src)-pad], nil
}

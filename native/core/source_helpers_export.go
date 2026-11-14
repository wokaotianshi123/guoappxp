package core

// 站源 helper 导出层。
//
// 上游 guoappxpx 把独立站源常用的解析与工具函数直接导出在 core 里，私有源
// 文件搬过来即可编译。guoappxp 的这些能力一直存在，但都是未导出的小写名，
// 外置源只能自己抄一份，容易与运行时行为漂移。这里统一做导出包装：
// 只做转发，不复制实现，保证站源看到的语义与运行时内部完全一致。

import (
	"context"
	"errors"
	"net/url"
	"regexp"
	"strings"
	"time"

	xhtml "golang.org/x/net/html"
)

// —— HTML / 文本解析 ——

// ExtractPageTitle 从详情页 HTML 里取标题：h1 → og:title → <title> 依次回退。
func ExtractPageTitle(rawHTML string) string { return extractPageTitle(rawHTML) }

// ExtractDescription 取 <meta description> / og:description 的简介。
func ExtractDescription(rawHTML string) string { return extractDescription(rawHTML) }

// ExtractAttr 按候选属性名从一段 HTML 片段里取属性值。
func ExtractAttr(block string, names ...string) string { return extractAttr(block, names...) }

// ExtractTags 取带 hg-tag class 的标签文本。
func ExtractTags(raw string) []string { return extractTags(raw) }

// FirstMatchText 返回正则的首个匹配文本（已去空白）。
func FirstMatchText(re *regexp.Regexp, raw string) string { return firstMatchText(re, raw) }

// —— 数字 / 日期 / 集数 ——

// NormalizeDate 把任意日期文本规范成 YYYY-MM-DD，无法识别返回空串。
func NormalizeDate(value string) string { return normalizeDate(value) }

// EpisodeIndex 从「第 3 集 / 更新至 12 集 / EP05」这类文本里抽集号。
func EpisodeIndex(value string, fallback int) int { return episodeIndex(value, fallback) }

// ProviderChinaTime 是站源处理日期用的中国时区（UTC+8）。
var ProviderChinaTime = providerChinaTime

// ReDateText / ReViewsText 是站源常用的日期与播放量正则。
var (
	ReDateText  = reDateText
	ReViewsText = reViewsText
)

// —— 加密 / 编码 ——

// Pkcs7Pad 按块大小补 PKCS#7 填充。
func Pkcs7Pad(src []byte, blockSize int) []byte { return pkcs7Pad(src, blockSize) }

// Pkcs7Unpad 去掉 PKCS#7 填充。
func Pkcs7Unpad(src []byte, blockSize int) ([]byte, error) { return pkcs7Unpad(src, blockSize) }

// —— 媒体与地址 ——

// M3u8Duration 统计播放列表总时长，读不出返回 0。
func M3u8Duration(playlist string) time.Duration { return m3u8Duration(playlist) }

// RehostProviderURL 把一个地址的 scheme/host 换成镜像站点的，路径与查询保留。
func RehostProviderURL(target *url.URL, mirror string) string {
	return rehostProviderURL(target, mirror)
}

// ProviderSourceForURL 反查地址属于哪个站源（认不出返回空）。
func ProviderSourceForURL(raw string) string { return providerSourceForURL(raw) }

// CoverPathFromAny 把封面值（字符串 / 数组 / 对象）解析成可用的封面地址。
func CoverPathFromAny(value any) string { return coverPathFromAny(value) }

// ProviderCoverAddress 同 CoverPathFromAny，额外按页面地址补全相对路径。
func ProviderCoverAddress(value any, pageURL string) string {
	return providerCoverAddress(value, pageURL)
}

// —— 剧集数据 ——

// MergeDramaMetadata 用 extra 补齐 base 里缺失的元数据字段（不覆盖已有值）。
func MergeDramaMetadata(base, extra Drama) Drama { return mergeDramaMetadata(base, extra) }

// —— 网页抓取 ——

// FetchHostPage 抓一页并解析成 HTML 文档，同时返回跟随重定向后的最终地址。
//
// 上游把它做成 Host 的便捷封装：站源解析详情/列表页时不用自己 FetchText +
// html.Parse 两遍。超过 4MB 视为异常页，直接拒绝，避免把大文件塞进解析器。
func FetchHostPage(ctx context.Context, host Host, address, referer, agent string) (*xhtml.Node, string, error) {
	response, err := host.FetchText(ctx, TextRequest{URL: address, Referer: referer, UserAgent: agent})
	if err != nil {
		return nil, "", err
	}
	if len(response.Body) > 4<<20 {
		return nil, "", errors.New("站源页面过大")
	}
	document, parseErr := xhtml.Parse(strings.NewReader(response.Body))
	finalURL := response.URL
	if finalURL == "" {
		finalURL = address
	}
	return document, finalURL, parseErr
}

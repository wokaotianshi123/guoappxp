package core

// 参照 streamhub 的 fetchViaProxy：对 Cloudflare 前缀加速类的「拼接自定义源」，
// 当直连被 Cloudflare 按出口 IP 判成 JS 浏览器验证（403 Cf-Mitigated:challenge）时，
// 改经公共 CORS/中继代理代发同一目标——换一个「数据中心出口 IP」，往往能绕过针对
// 当前 IP 的 CF 挑战。纯 HTTP 客户端（带不带浏览器指纹都一样）无法自行执行 CF 的
// 挑战 JS，唯一可行的"尝试解决"就是换出口 IP；本模块提供这条兜底链。

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// cfRelayProxy 是 streamhub PROXIES 数组的一个元素（公共 CORS/中继）。
type cfRelayProxy struct {
	prefix   string // 目标 URL 拼在 prefix 之后（URL 编码后）
	jsonWrap bool   // 响应是否被 {contents:"..."} 包装（allorigins/win/get 形态）
	label    string
}

// cfRelayProxies：参照 streamhub fetchViaProxy 的 PROXIES 公共代理链。
// 仅对命中 Cloudflare 浏览器验证的「拼接加速自定义源」取数生效，正常源不触碰。
// 顺序与 streamhub 公共代理段一致（codetabs → allorigins/raw → allorigins/get）；
// 已剔除 streamhub 注释里弃用的 corsproxy.io（被墙/地区不可达）。
var cfRelayProxies = []cfRelayProxy{
	{prefix: "https://api.codetabs.com/v1/proxy?quest=", label: "codetabs"},
	{prefix: "https://api.allorigins.win/raw?url=", label: "allorigins-raw"},
	{prefix: "https://api.allorigins.win/get?url=", jsonWrap: true, label: "allorigins-get"},
}

// isCFChallengeError 判断错误是否为 Cloudflare 浏览器验证拦截。
// 该文案由 catalogResponseError 在命中 403 Cf-Mitigated:challenge 时生成。
func isCFChallengeError(err error) bool {
	return err != nil && strings.Contains(err.Error(), "站点要求浏览器验证")
}

// isHongguoProviderURL 判断目标是否落在红果（hongguo）站的已知 host 上。
// 红果源不受 Cloudflare 403 挑战影响，无需（也不应）经公共 CF 中继代发；
// 显式排除它，避免任何 CF 挑战形态的失败再拖入最慢的公共代理链（3×25s），
// 保障红果目录/详情/取流的加载速度。
func isHongguoProviderURL(rawURL string) bool {
	parsed, err := url.Parse(rawURL)
	if err != nil {
		return false
	}
	switch strings.ToLower(parsed.Hostname()) {
	case "hongguoduanju.com", "www.hongguoduanju.com":
		return true
	}
	return false
}

// fetchProviderTextViaCFRelay 对拼接加速自定义源在命中 Cloudflare 浏览器验证时，
// 依次改经公共中继代理重取同一目标。命中任一中继即返回正文；全部失败回传错误。
// 普通源与非 CF 挑战场景不会进入本函数（调用方按 isSplicedAcceleratorURL +
// isCFChallengeError 双重门控）。
func (d *Downloader) fetchProviderTextViaCFRelay(ctx context.Context, target, referer string) (string, error) {
	var lastErr error
	for _, relay := range cfRelayProxies {
		if err := ctx.Err(); err != nil {
			return "", err
		}
		body, err := d.fetchRelayText(ctx, relay, target, referer)
		if err == nil {
			return body, nil
		}
		lastErr = err
	}
	if lastErr == nil {
		lastErr = errors.New("没有可用的 Cloudflare 中继代理")
	}
	return "", fmt.Errorf("Cloudflare 浏览器验证无法通过，中继代理亦失败：%v", lastErr)
}

// fetchRelayText 用中继 prefix 取目标正文：URL 编码目标拼到 prefix 后、走 d.client
// 代发、按需拆掉 allorigins/get 的 JSON 包装、丢弃 HTML 错误页（上游仍被拦的信号）。
func (d *Downloader) fetchRelayText(ctx context.Context, relay cfRelayProxy, target, referer string) (string, error) {
	// 公共中继自身较慢，套独立超时，避免单次中继卡死整个目录请求。
	timed, cancel := context.WithTimeout(ctx, cfRelayTimeout)
	defer cancel()
	relayURL := relay.prefix + url.QueryEscape(target)
	req, err := http.NewRequestWithContext(timed, http.MethodGet, relayURL, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("User-Agent", userAgent)
	if referer != "" {
		req.Header.Set("Referer", referer)
	}
	req.Header.Set("Accept-Language", "zh-CN,zh;q=0.9")

	resp, err := d.client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", fmt.Errorf("%s 中继 HTTP %d", relay.label, resp.StatusCode)
	}
	body, readErr := io.ReadAll(io.LimitReader(resp.Body, providerMaxBodyBytes+1))
	if readErr != nil {
		return "", readErr
	}
	if len(body) > providerMaxBodyBytes {
		return "", fmt.Errorf("%s 中继响应过大", relay.label)
	}
	text := unwrapRelayBody(string(body), relay.jsonWrap)
	trimmed := strings.TrimSpace(text)
	if trimmed == "" {
		return "", fmt.Errorf("%s 中继返回空内容", relay.label)
	}
	// 中继回传 HTML（CF 挑战页 / 网关错误页）说明上游仍被拦，判为失败换下一个。
	lower := strings.ToLower(trimmed)
	if strings.HasPrefix(lower, "<!doctype html") || strings.HasPrefix(lower, "<html") {
		return "", fmt.Errorf("%s 中继返回 HTML（上游仍被拦）", relay.label)
	}
	return text, nil
}

// unwrapRelayBody 拆掉 allorigins/win/get 的 {contents:"..."} / {content:"..."} 包装。
func unwrapRelayBody(raw string, jsonWrap bool) string {
	if !jsonWrap {
		return raw
	}
	trimmed := strings.TrimSpace(raw)
	if !strings.HasPrefix(trimmed, "{") {
		return raw
	}
	var payload struct {
		Contents string `json:"contents"`
		Content  string `json:"content"`
	}
	if json.Unmarshal([]byte(trimmed), &payload) != nil {
		return raw
	}
	if payload.Contents != "" {
		return payload.Contents
	}
	return payload.Content
}

// 中继代发的默认超时：公共代理本身较慢，给到 25 秒，避免拖垮目录翻页。
const cfRelayTimeout = 25 * time.Second

// withCFRelayTimeout 给中继代发套独立超时，避免单次中继卡死整个目录请求。
func withCFRelayTimeout(ctx context.Context) (context.Context, context.CancelFunc) {
	return context.WithTimeout(ctx, cfRelayTimeout)
}

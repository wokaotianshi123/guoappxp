package core

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

type ProviderMedia struct {
	Credentials *MediaCredentials
	URL         string
	Referer     string
	Duration    time.Duration
	Playlist    string
	HLSKey      []byte
	CENCKey     []byte
	Quality     int
	Variants    []ProviderMedia
}

func (d *Downloader) providerBaseURL(source string) string {
	source = canonicalProviderSource(source)
	if descriptor, ok := registeredDescriptor(source); ok {
		if p, ok := d.provider(source); ok {
			if sited, ok := providerAs[Sited](p); ok {
				return strings.TrimRight(sited.BaseURL(), "/")
			}
		}
		return strings.TrimRight(descriptor.BaseURL, "/")
	}
	return "https://d2pypzndaqisk.cloudfront.net"
}

func ProviderSourceForURL(raw string) string {
	parsed, err := url.Parse(raw)
	if err != nil {
		return ""
	}
	host := strings.ToLower(parsed.Hostname())
	if id, ok := registeredSource(host); ok {
		return id
	}
	return ""
}

func (d *Downloader) providerURLCandidates(ctx context.Context, raw string) []string {
	source := ProviderSourceForURL(raw)
	if descriptor, registered := registeredDescriptor(source); source == "" || registered && descriptor.NoHostRotation {
		return []string{raw}
	}
	parsed, _ := url.Parse(raw)
	d.providerMu.Lock()
	preferred := d.providerHosts[source]
	d.providerMu.Unlock()
	var candidates []string
	seen := map[string]bool{}
	add := func(candidate string) {
		if candidate != "" && !seen[candidate] {
			seen[candidate] = true
			candidates = append(candidates, candidate)
		}
	}
	add(RehostProviderURL(parsed, preferred))
	configured := d.providerBaseURL(source)
	add(RehostProviderURL(parsed, configured))
	if ProviderSourceForURL(configured) == "" {
		return candidates
	}
	rotated := []string{raw}
	if mirrors, ok := ctx.Value(providerTextMirrorsKey{}).([]string); ok {
		rotated = mirrors
	} else if p, ok := d.provider(source); ok {
		if rotator, ok := providerAs[URLRotator](p); ok {
			rotated = rotator.URLCandidates(raw)
		}
	}
	for _, candidate := range rotated {
		add(candidate)
	}
	return candidates
}

// BrowserVerifyPrefix 标记「需要先用浏览器完成验证」的分集地址。
//
// 站源把 videoUrl 写成 browser://<短链地址> 时，应用先用隐藏浏览器走完
// Cloudflare 挑战，把落地地址写回 pageUrl，再调用 resolveMedia 取直链。
const BrowserVerifyPrefix = "browser://"

// BrowserVerifyError 表示这一集需要先在浏览器里完成验证。
// 应用据此启动隐藏浏览器，而不是当成普通失败。
type BrowserVerifyError struct {
	// Address 是 browser:// 后面的短链地址。
	Address string
}

func (err BrowserVerifyError) Error() string {
	return "这一集需要在应用内浏览器完成验证后才能播放"
}

// browserVerifyAddress 判断分集地址是不是 browser:// 短链，返回后面的地址。
func browserVerifyAddress(videoURL string) (string, bool) {
	trimmed := strings.TrimSpace(videoURL)
	if !strings.HasPrefix(trimmed, BrowserVerifyPrefix) {
		return "", false
	}
	address := strings.TrimSpace(strings.TrimPrefix(trimmed, BrowserVerifyPrefix))
	return address, address != ""
}

func (d *Downloader) resolveProviderMedia(ctx context.Context, task Task) (ProviderMedia, error) {
	chapter := task.Chapter
	chapter.Source = canonicalProviderSource(chapter.Source)
	if chapter.Source == "" {
		chapter.Source = SourceFromDramaID(task.DramaID)
	}
	// 分集地址带 browser:// 前缀时，先让应用去走浏览器验证。
	// 落地地址会被写回 pageUrl，此时 videoUrl 已清空，才继续正常解析。
	if address, needed := browserVerifyAddress(chapter.VideoURL); needed {
		return ProviderMedia{}, BrowserVerifyError{Address: address}
	}
	// 编译期接入的站源自己解析取流（抓当集播放页、算令牌、取线路表等），
	// 不能落到下面按 chapter.VideoURL 直连的通用兜底。
	if p, ok := d.provider(chapter.Source); ok {
		return p.ResolveMedia(ctx, task)
	}
	// 短剧 / 自定义源（含 XBPQ 规则）各有专用取流逻辑，resolveDuanjuMedia
	// 内部会按 customXBPQRule 分支走「跳转播放链接 → player_data → 嗅探兜底」。
	// 不能落到通用兜底：兜底按 chapter.VideoURL 直连，XBPQ 源这样取不到地址，
	// 表现为「打开源后报 unsupported provider source: custom:...」。
	if isDuanjuProviderSource(chapter.Source) {
		return d.resolveDuanjuMedia(ctx, task)
	}
	// 通用兜底：按 chapter.VideoURL 直连（finishProviderMedia 内含 M3U8 展开）。
	media := ProviderMedia{
		URL:     chapter.VideoURL,
		Referer: firstNonEmpty(chapter.Referer, d.providerBaseURL(chapter.Source)+"/"),
	}
	return d.finishProviderMedia(ctx, media, chapter.Source)
}

func (d *Downloader) finishProviderMedia(ctx context.Context, media ProviderMedia, source string) (ProviderMedia, error) {
	if !IsProviderHTTPMediaURL(media.URL) {
		return ProviderMedia{}, fmt.Errorf("%s 未返回有效播放地址，请刷新章节或确认站点访问权限", source)
	}
	parsed, _ := url.Parse(media.URL)
	if strings.HasSuffix(strings.ToLower(parsed.Path), ".m3u8") {
		playlist, finalURL, err := d.fetchMediaPlaylist(ctx, media.URL, media.Referer)
		if err != nil {
			return ProviderMedia{}, fmt.Errorf("获取播放列表失败: %w", err)
		}
		if !strings.HasPrefix(strings.TrimSpace(strings.TrimPrefix(playlist, "\ufeff")), "#EXTM3U") {
			return ProviderMedia{}, fmt.Errorf("站点未返回有效 M3U8，可能需要登录或链接已失效")
		}
		if duration := M3u8Duration(playlist); duration > 0 {
			media.Duration = duration
		}
		media.Playlist = playlist
		media.URL = finalURL
	}
	return media, nil
}

func (d *Downloader) fetchProviderRequest(ctx context.Context, rawURL, referer string, payload []byte) (string, error) {
	retries := d.cfg.Retries
	if retries <= 0 {
		retries = 3
	}
	if referer == "" {
		referer = rawURL
	}
	candidates := d.providerURLCandidates(ctx, rawURL)
	var lastErr error
	tried := 0
	for _, candidate := range candidates {
		if err := ctx.Err(); err != nil {
			return "", err
		}
		attempts := retries
		if len(candidates) > 1 {
			attempts = 1
		}
		for attempt := 1; attempt <= attempts; attempt++ {
			tried++
			if attempt > 1 {
				select {
				case <-time.After(time.Duration(attempt) * time.Second):
				case <-ctx.Done():
					return "", ctx.Err()
				}
			}
			timeout := ProviderTimeout
			if len(candidates) > 1 {
				timeout = 5 * time.Second
			}
			method, requestBody := http.MethodGet, io.Reader(nil)
			if payload != nil {
				method, requestBody = http.MethodPost, bytes.NewReader(payload)
			}
			req, err := http.NewRequestWithContext(ctx, method, candidate, requestBody)
			if err != nil {
				return "", err
			}
			if payload != nil {
				req.Header.Set("Content-Type", "application/json")
				req.Header.Set("Accept", "application/json")
			}
			req.Header.Set("User-Agent", UserAgent)
			if agent, ok := ctx.Value(providerTextUserAgentKey{}).(string); ok && agent != "" {
				req.Header.Set("User-Agent", agent)
			}
			if ProviderSourceForURL(rawURL) != "" {
				req.Header.Set("Referer", providerRefererForURL(candidate, referer))
			} else {
				req.Header.Set("Referer", referer)
			}
			req.Header.Set("Accept-Language", "zh-CN,zh;q=0.9")
			if cookie, ok := ctx.Value(providerTextCookieKey{}).(string); ok && cookie != "" {
				req.Header.Set("Cookie", cookie)
			}
			if noCache, _ := ctx.Value(providerTextNoCacheKey{}).(bool); noCache {
				req.Header.Set("Cache-Control", "no-cache")
			}
			resp, err := d.doCatalogRequestWithTimeout(req, timeout)
			if err != nil {
				lastErr = err
				var backoff *RequestBackoff
				if errors.As(err, &backoff) {
					break
				}
				continue
			}
			body, readErr := io.ReadAll(io.LimitReader(resp.Body, ProviderMaxBodyBytes+1))
			closeErr := resp.Body.Close()
			if readErr != nil {
				lastErr = readErr
				continue
			}
			if closeErr != nil {
				lastErr = closeErr
				continue
			}
			if len(body) > ProviderMaxBodyBytes {
				lastErr = fmt.Errorf("response exceeds %d bytes", ProviderMaxBodyBytes)
				continue
			}
			if resp.StatusCode < 200 || resp.StatusCode >= 300 || catalogResponseBlockReason(resp, body) != "" {
				lastErr = d.catalogResponseError(req, resp, body)
				if catalogResponseBlockReason(resp, body) != "" || resp.StatusCode >= 400 && resp.StatusCode < 500 && resp.StatusCode != 408 {
					break
				}
				continue
			}
			if source := ProviderSourceForURL(rawURL); source != "" {
				effectiveURL := req.URL
				if resp.Request != nil {
					effectiveURL = resp.Request.URL
				}
				d.providerMu.Lock()
				if d.providerHosts == nil {
					d.providerHosts = map[string]string{}
				}
				d.providerHosts[source] = effectiveURL.Scheme + "://" + effectiveURL.Host
				d.providerMu.Unlock()
			}
			rememberPlaybackResponseURL(ctx, rawURL, resp)
			return string(body), nil
		}
	}
	if len(candidates) > 1 && lastErr != nil {
		name := "站源"
		if descriptor, ok := registeredDescriptor(ProviderSourceForURL(rawURL)); ok && descriptor.Name != "" {
			name = descriptor.Name
		}
		return "", fmt.Errorf("%s请求失败：已尝试 %d 个域名，最后错误：%w", name, tried, lastErr)
	}
	return "", lastErr
}

func RehostProviderURL(u *url.URL, mirror string) string {
	mu, err := url.Parse(mirror)
	if err != nil || mu.Host == "" {
		return ""
	}
	copyURL := *u
	copyURL.Scheme = mu.Scheme
	copyURL.Host = mu.Host
	return copyURL.String()
}

func providerRefererForURL(candidate, fallback string) string {
	target, err := url.Parse(candidate)
	previous, previousErr := url.Parse(fallback)
	if err != nil || target.Host == "" || previousErr != nil || previous.Host == "" {
		return fallback
	}
	if source := ProviderSourceForURL(fallback); source != "" && (source == ProviderSourceForURL(candidate) || ProviderSourceForURL(candidate) == "") {
		previous.Scheme, previous.Host = target.Scheme, target.Host
	}
	previous.Fragment = ""
	return previous.String()
}

func (d *Downloader) GetHuangguoChapters(ctx context.Context, source, sourceID string) (string, []Chapter, error) {
	p, ok := d.provider(source)
	if !ok {
		return "", nil, fmt.Errorf("unsupported provider source: %s", source)
	}
	drama, chapters, err := p.Detail(ctx, sourceID)
	return drama.DisplayTitle(), chapters, err
}

func (d *Downloader) repairCover(drama LibraryDrama) string {
	if d == nil {
		return drama.Cover
	}
	for _, source := range []string{drama.Source, SourceFromDramaID(drama.ID)} {
		if p, ok := d.provider(source); ok {
			if repairer, ok := providerAs[CoverRepairer](p); ok {
				return repairer.RepairCover(drama)
			}
		}
	}
	return drama.Cover
}

func (d *Downloader) mediaAuthorizer(address *url.URL) MediaAuthorizer {
	for _, descriptor := range registeredDescriptors() {
		if p, ok := d.provider(descriptor.ID); ok {
			if authorizer, ok := providerAs[MediaAuthorizer](p); ok && authorizer.AuthorizesMedia(address) {
				return authorizer
			}
		}
	}
	return nil
}

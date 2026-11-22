package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

var (
	webViewBridgeMu       sync.RWMutex
	webViewBridgePort     int
	webViewBridgeHosts    = map[string]bool{}
	webViewBridgeSuffixes = map[string]bool{}
	webViewBridgeCookies  = map[string]string{}
	webViewBridgeAgents   = map[string]string{}
	webViewLocalClient    = &http.Client{Timeout: 25 * time.Second}
)

func appendBridgeTarget(hosts *[]string, suffixes *[]string, raw string) {
	s := strings.ToLower(strings.TrimSpace(raw))
	if s == "" {
		return
	}
	if strings.HasPrefix(s, "*.") || strings.HasPrefix(s, ".") {
		suffix := "." + strings.TrimLeft(s, "*.")
		if len(suffix) > 1 && !strings.ContainsAny(suffix, "/:") {
			*suffixes = append(*suffixes, suffix)
		}
		return
	}
	if h := normalizeBridgeHost(s); h != "" && h != "movie.douban.com" {
		*hosts = append(*hosts, h)
	}
}

func (engine *nativeEngine) setWebViewBridge(port int, rawHost, source, cookie, userAgent string) map[string]any {
	hosts := make([]string, 0, 8)
	suffixes := make([]string, 0, 4)
	appendBridgeTarget(&hosts, &suffixes, rawHost)
	if source != "" {
		if desc, ok := registeredDescriptor(canonicalProviderSource(source)); ok {
			appendBridgeTarget(&hosts, &suffixes, desc.BaseURL)
			for _, alias := range desc.Aliases {
				appendBridgeTarget(&hosts, &suffixes, alias)
			}
			for _, host := range desc.Hosts {
				appendBridgeTarget(&hosts, &suffixes, host)
			}
			for _, suffix := range desc.HostSuffixes {
				appendBridgeTarget(&hosts, &suffixes, suffix)
			}
		}
		if engine.downloader != nil {
			if base := engine.downloader.providerBaseURL(source); base != "" {
				appendBridgeTarget(&hosts, &suffixes, base)
			}
		}
	}

	cookie = strings.TrimSpace(cookie)
	userAgent = strings.TrimSpace(userAgent)

	webViewBridgeMu.Lock()
	if port > 0 {
		webViewBridgePort = port
	}
	for _, h := range hosts {
		webViewBridgeHosts[h] = true
		if cookie != "" {
			webViewBridgeCookies[h] = cookie
		}
		if userAgent != "" {
			webViewBridgeAgents[h] = userAgent
		}
	}
	for _, suffix := range suffixes {
		webViewBridgeSuffixes[suffix] = true
		if cookie != "" {
			webViewBridgeCookies[suffix] = cookie
		}
		if userAgent != "" {
			webViewBridgeAgents[suffix] = userAgent
		}
	}
	webViewBridgeMu.Unlock()

	if engine.downloader != nil && engine.downloader.limiter != nil {
		engine.downloader.limiter.mu.Lock()
		for _, h := range hosts {
			delete(engine.downloader.limiter.backoffs, h)
			delete(engine.downloader.limiter.backgroundBackoffs, h)
		}
		for h := range engine.downloader.limiter.backoffs {
			for _, suffix := range suffixes {
				if strings.HasSuffix(h, suffix) {
					delete(engine.downloader.limiter.backoffs, h)
				}
			}
		}
		for h := range engine.downloader.limiter.backgroundBackoffs {
			for _, suffix := range suffixes {
				if strings.HasSuffix(h, suffix) {
					delete(engine.downloader.limiter.backgroundBackoffs, h)
				}
			}
		}
		engine.downloader.limiter.mu.Unlock()
	}
	return map[string]any{"ok": true, "hosts": hosts, "suffixes": suffixes}
}

func bridgeMatchesPattern(host, pattern string) bool {
	p := strings.ToLower(strings.TrimSpace(pattern))
	if p == "" {
		return false
	}
	if strings.HasPrefix(p, "*.") || strings.HasPrefix(p, ".") {
		return strings.HasSuffix(host, "."+strings.TrimLeft(p, "*."))
	}
	return host == normalizeBridgeHost(p)
}

func firstChallengeURL(candidates []string) string {
	for _, h := range candidates {
		s := strings.TrimSpace(h)
		if s == "" || strings.HasPrefix(s, "*.") || strings.HasPrefix(s, ".") {
			continue
		}
		if strings.Contains(s, "://") {
			return s
		}
		return "https://" + s
	}
	return ""
}

func (engine *nativeEngine) sourceChallengeURL(source string) string {
	id := canonicalProviderSource(source)
	base := ""
	if engine.downloader != nil {
		base = strings.TrimSpace(engine.downloader.providerBaseURL(id))
	}
	desc, hasDesc := registeredDescriptor(id)
	if base == "" && hasDesc {
		base = strings.TrimSpace(desc.BaseURL)
	}
	if hasDesc && (len(desc.Hosts) > 0 || len(desc.Aliases) > 0) {
		baseHost := normalizeBridgeHost(base)
		matched := false
		if baseHost != "" {
			for _, item := range desc.Aliases {
				if bridgeMatchesPattern(baseHost, item) {
					matched = true
					break
				}
			}
			if !matched {
				for _, item := range desc.Hosts {
					if bridgeMatchesPattern(baseHost, item) {
						matched = true
						break
					}
				}
			}
		}
		if !matched {
			if u := firstChallengeURL(desc.Aliases); u != "" {
				return u
			}
			if u := firstChallengeURL(desc.Hosts); u != "" {
				return u
			}
		}
	}
	if base != "" {
		return base
	}
	if hasDesc {
		if u := firstChallengeURL(desc.Aliases); u != "" {
			return u
		}
		if u := firstChallengeURL(desc.Hosts); u != "" {
			return u
		}
	}
	return ""
}

func normalizeBridgeHost(raw string) string {
	s := strings.TrimSpace(raw)
	if s == "" {
		return ""
	}
	if strings.Contains(s, "://") {
		if u, err := url.Parse(s); err == nil {
			return strings.ToLower(u.Hostname())
		}
	}
	if host, _, ok := strings.Cut(s, ":"); ok {
		s = host
	}
	return strings.ToLower(strings.TrimSpace(s))
}

func isWebViewBridgeHost(rawURL string) (int, string, bool) {
	u, err := url.Parse(rawURL)
	if err != nil {
		return 0, "", false
	}
	host := strings.ToLower(u.Hostname())
	if host == "" {
		return 0, "", false
	}
	webViewBridgeMu.RLock()
	port := webViewBridgePort
	ok := port > 0 && webViewBridgeHosts[host]
	if !ok && port > 0 {
		for suffix := range webViewBridgeSuffixes {
			if strings.HasSuffix(host, suffix) {
				ok = true
				break
			}
		}
	}
	webViewBridgeMu.RUnlock()
	return port, host, ok
}

func webViewBridgeHeaders(rawURL string) (cookie, userAgent string) {
	u, err := url.Parse(rawURL)
	if err != nil {
		return "", ""
	}
	host := strings.ToLower(u.Hostname())
	if host == "" {
		return "", ""
	}
	webViewBridgeMu.RLock()
	defer webViewBridgeMu.RUnlock()
	cookie = webViewBridgeCookies[host]
	userAgent = webViewBridgeAgents[host]
	if cookie == "" || userAgent == "" {
		for suffix := range webViewBridgeSuffixes {
			if strings.HasSuffix(host, suffix) {
				if cookie == "" {
					cookie = webViewBridgeCookies[suffix]
				}
				if userAgent == "" {
					userAgent = webViewBridgeAgents[suffix]
				}
			}
		}
	}
	return cookie, userAgent
}

func webViewBridgeFetch(ctx context.Context, rawURL string) (string, string, bool, error) {
	port, host, ok := isWebViewBridgeHost(rawURL)
	if !ok {
		return "", "", false, nil
	}
	endpoint := fmt.Sprintf("http://127.0.0.1:%d/fetch?url=%s", port, url.QueryEscape(rawURL))
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return "", "", true, err
	}
	resp, err := webViewLocalClient.Do(req)
	if err != nil {
		return "", "", true, err
	}
	defer resp.Body.Close()
	bodyBytes, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return "", "", true, err
	}
	var payload struct {
		OK    bool   `json:"ok"`
		HTML  string `json:"html"`
		URL   string `json:"url"`
		Error string `json:"error"`
	}
	if err := json.Unmarshal(bodyBytes, &payload); err != nil {
		return "", "", true, err
	}
	if !payload.OK {
		if payload.Error != "" {
			return "", "", true, errors.New(payload.Error)
		}
		return "", "", true, errors.New("WebView 请求失败")
	}
	lower := strings.ToLower(payload.HTML)
	if strings.Contains(lower, "_cf_chl_opt") || (strings.Contains(lower, "<title>just a moment") && strings.Contains(lower, "cloudflare")) {
		webViewBridgeMu.Lock()
		delete(webViewBridgeHosts, host)
		delete(webViewBridgeCookies, host)
		delete(webViewBridgeAgents, host)
		for suffix := range webViewBridgeSuffixes {
			if strings.HasSuffix(host, suffix) {
				delete(webViewBridgeSuffixes, suffix)
				delete(webViewBridgeCookies, suffix)
				delete(webViewBridgeAgents, suffix)
			}
		}
		webViewBridgeMu.Unlock()
		return "", "", true, errors.New("该站已开启 Cloudflare 人机验证，请点击「完成人机验证」通过后再试")
	}
	finalURL := payload.URL
	if finalURL == "" {
		finalURL = rawURL
	}
	return payload.HTML, finalURL, true, nil
}

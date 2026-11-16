package core

import (
	"crypto/tls"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	fhttp "github.com/bogdanfinn/fhttp"
	tlsclient "github.com/bogdanfinn/tls-client"
	"github.com/bogdanfinn/tls-client/profiles"
)

const huangguoBrowserProfile = "Chrome 150"

type browserHTTPClient interface {
	Do(*fhttp.Request) (*fhttp.Response, error)
	CloseIdleConnections()
}

type huangguoBrowserTransport struct {
	base      http.RoundTripper
	router    *proxyRouter
	baseURL   func(string) string
	static    map[string]string
	insecure  bool
	record    func(diagnosticEvent)
	mu        sync.Mutex
	clients   map[string]browserHTTPClient
	newClient func(string) (browserHTTPClient, error)
	// custom 是运行期登记的自定义源 host（registerHost）。这类站点形态各异，
	// 浏览器指纹并非总是更优：实测部分站点（如 hanjuds 一类普通 CMS）对 utls
	// 指纹直接返回 403 Cloudflare 验证页，而标准 Go 传输可以正常拿到 200。
	// 因此它们先走标准传输，只有真被验证页拦住（challenged）才升级到浏览器指纹。
	custom   map[string]bool
	upgraded map[string]bool
	// fingerprintHosts 是「声明了 browserFingerprint 的站源」的 host → 站源 ID 表，
	// 由站源注册表（含运行期注册的模块）现算。之前这里只认编译期写死的
	// duanjuProviderCatalog 里的 Browser 标记，模块清单里的 browserFingerprint
	// 从来没被读过，于是 Hanime1、MissAV 这类模块在部分网络下开屏即 403。
	// 表按注册表代数缓存，模块装卸后自动失效重建。
	fingerprintHosts map[string]string
	fingerprintGen   int
}

func newHuangguoBrowserTransport(base http.RoundTripper, downloader *Downloader) *huangguoBrowserTransport {
	configured, _ := url.Parse(downloader.providerBaseURL(sourceHuangguoVideo))
	transport := &huangguoBrowserTransport{
		base: base, router: downloader.proxyRouter, baseURL: downloader.providerBaseURL,
		static:   browserTransportHosts(configured.Host),
		insecure: downloader.cfg.InsecureTLS, record: downloader.recordDiagnostic,
		clients: make(map[string]browserHTTPClient), custom: make(map[string]bool),
		upgraded: make(map[string]bool),
	}
	transport.newClient = transport.createClient
	return transport
}

// browserTransportHosts 是编译期固定的指纹 host：黄果系站点与显式标了
// Browser 的短剧源。模块与其它站源走 fingerprintHosts 动态查表。
func browserTransportHosts(huangguoVideoHost string) map[string]string {
	hosts := map[string]string{"huangguo.video": sourceHuangguoVideo}
	if huangguoVideoHost != "" {
		hosts[strings.ToLower(huangguoVideoHost)] = sourceHuangguoVideo
	}
	for _, spec := range duanjuProviderCatalog {
		if !spec.Browser {
			continue
		}
		if parsed, err := url.Parse(spec.Base); err == nil && parsed.Host != "" {
			hosts[strings.ToLower(parsed.Host)] = spec.ID
		}
	}
	return hosts
}

// buildFingerprintHosts 汇总「该走浏览器指纹」的 host。
//
// 判据是站源描述符上的 BrowserFingerprint（模块清单里的 browserFingerprint
// 会原样带进描述符），host 取三类：配置里的基础地址、描述符声明的 BaseURL、
// 以及别名。三类都补上 www. 变体，避免站点在裸域与 www 之间跳转后指纹失效。
func (transport *huangguoBrowserTransport) buildFingerprintHosts() map[string]string {
	hosts := make(map[string]string, len(transport.static)+8)
	for host, source := range transport.static {
		hosts[host] = source
	}
	add := func(raw, source string) {
		host := strings.ToLower(strings.TrimSpace(raw))
		if host == "" {
			return
		}
		hosts[host] = source
		if without, ok := strings.CutPrefix(host, "www."); ok && without != "" {
			if _, exists := hosts[without]; !exists {
				hosts[without] = source
			}
		} else if !strings.Contains(host, ":") {
			if _, exists := hosts["www."+host]; !exists {
				hosts["www."+host] = source
			}
		}
	}
	for _, descriptor := range RegisteredSources() {
		if !descriptor.BrowserFingerprint {
			continue
		}
		if configured, err := url.Parse(transport.baseURL(descriptor.ID)); err == nil && configured.Host != "" {
			add(configured.Host, descriptor.ID)
		}
		if declared, err := url.Parse(descriptor.BaseURL); err == nil && declared.Host != "" {
			add(declared.Host, descriptor.ID)
		}
		for _, name := range descriptor.Aliases {
			add(name, descriptor.ID)
		}
	}
	return hosts
}

// source 返回该地址应走浏览器指纹的站源 ID，空串表示不用指纹。
func (transport *huangguoBrowserTransport) source(address *url.URL) string {
	if address == nil {
		return ""
	}
	transport.mu.Lock()
	generation := sourceRegistryGeneration()
	if transport.fingerprintHosts == nil || transport.fingerprintGen != generation {
		transport.fingerprintHosts = transport.buildFingerprintHosts()
		transport.fingerprintGen = generation
	}
	hosts := transport.fingerprintHosts
	transport.mu.Unlock()
	if source, ok := hosts[strings.ToLower(address.Host)]; ok {
		return source
	}
	return hosts[strings.ToLower(address.Hostname())]
}

func (transport *huangguoBrowserTransport) matches(request *http.Request) bool {
	if !browserEligibleRequest(request) {
		return false
	}
	if transport.source(request.URL) != "" {
		return true
	}
	// 自定义源 host 只有在被验证页拦住过之后才用指纹传输。
	host := strings.ToLower(request.URL.Hostname())
	transport.mu.Lock()
	after := transport.upgraded[host]
	transport.mu.Unlock()
	return after
}

// browserEligibleRequest 只有 GET/HEAD 的 http(s) 请求才适合改换指纹传输。
func browserEligibleRequest(request *http.Request) bool {
	if request.Method != http.MethodGet && request.Method != http.MethodHead {
		return false
	}
	return request.URL.Scheme == "http" || request.URL.Scheme == "https"
}

// isCustomHost 判断 host 是否由 registerHost 运行期登记（自定义源）。
func (transport *huangguoBrowserTransport) isCustomHost(request *http.Request) bool {
	host := strings.ToLower(request.URL.Hostname())
	transport.mu.Lock()
	defer transport.mu.Unlock()
	return transport.custom[host] || transport.custom[strings.ToLower(request.URL.Host)]
}

// promoted 判断自定义源 host 是否已确认需要浏览器指纹（曾被验证页拦住过）。
func (transport *huangguoBrowserTransport) promoted(request *http.Request) bool {
	host := strings.ToLower(request.URL.Hostname())
	transport.mu.Lock()
	defer transport.mu.Unlock()
	return transport.upgraded[host]
}

func (transport *huangguoBrowserTransport) promote(host string) {
	host = strings.ToLower(strings.TrimSpace(host))
	if host == "" {
		return
	}
	transport.mu.Lock()
	transport.upgraded[host] = true
	transport.mu.Unlock()
}

// browserChallengeStatus 判断是否值得换浏览器指纹再试一次。
// 只认 403：Cloudflare 的 managed challenge 固定用 403 + `cf-mitigated: challenge`，
// 而站点本身的权限拒绝也是 403——后者多花一次请求就返回，代价可接受；
// 429/503 属于限流与维护，换指纹只会加重负担，不重试。
func browserChallengeStatus(response *http.Response) bool {
	return response != nil && response.StatusCode == http.StatusForbidden
}

// registerHost 动态把一个 host 加入浏览器指纹传输候选集。
// 自定义源（含「加速链接+真实网址」拼接形态的 Cloudflare 前缀加速源）在新增、更新与
// 加载时调用它。这类 host 与内置 Browser 源不同：先按标准 Go 传输取一次，
// 只有返回 Cloudflare 验证页时才升级到 Chrome 指纹传输，并记住该 host，
// 之后同进程内一直用指纹传输。
func (transport *huangguoBrowserTransport) registerHost(host string) {
	host = strings.ToLower(strings.TrimSpace(host))
	if host == "" {
		return
	}
	// 已声明 browserFingerprint 的站源 host 本来就常走指纹，不必再登记成
	// 「先标准后升级」的自定义源。
	if transport.source(&url.URL{Scheme: "https", Host: host}) != "" {
		return
	}
	transport.mu.Lock()
	transport.custom[host] = true
	transport.mu.Unlock()
}

func (transport *huangguoBrowserTransport) createClient(proxy string) (browserHTTPClient, error) {
	idleTimeout := 90 * time.Second
	options := []tlsclient.HttpClientOption{
		tlsclient.WithClientProfile(profiles.Chrome_150),
		tlsclient.WithRandomTLSExtensionOrder(),
		tlsclient.WithDisableHttp3(),
		tlsclient.WithNotFollowRedirects(),
		tlsclient.WithTimeoutSeconds(45),
		tlsclient.WithProxyUrl(proxy),
		tlsclient.WithCookieJar(tlsclient.NewCookieJar()),
		tlsclient.WithTransportOptions(&tlsclient.TransportOptions{
			IdleConnTimeout: &idleTimeout, MaxIdleConns: 8, MaxIdleConnsPerHost: 4,
			MaxResponseHeaderBytes: 1 << 20,
			// Android 端纯 Go 不加载系统信任库，tls-client 的 RootCAs 为空时
			// utls 回落系统池会报 unknown authority。显式挂上「系统信任库 +
			// 打包 CA 全集」，与标准传输（app_runtime.go）保持一致的信任锚，
			// 修复黄果站点目录与播放请求在 Android 上握手失败的问题。
			RootCAs: systemCertPoolWithBundle(),
		}),
	}
	if transport.insecure {
		options = append(options, tlsclient.WithInsecureSkipVerify())
	}
	return tlsclient.NewHttpClient(tlsclient.NewNoopLogger(), options...)
}

func (transport *huangguoBrowserTransport) client(request *http.Request) (browserHTTPClient, error) {
	transport.mu.Lock()
	defer transport.mu.Unlock()
	proxy, err := transport.router.proxy(request)
	if err != nil {
		return nil, err
	}
	proxyURL := ""
	if proxy != nil {
		proxyURL = proxy.String()
	}
	key := request.URL.Scheme + "://" + strings.ToLower(request.URL.Host) + "|" + proxyURL
	if client := transport.clients[key]; client != nil {
		return client, nil
	}
	client, err := transport.newClient(proxyURL)
	if err != nil {
		return nil, err
	}
	if len(transport.clients) >= 8 {
		for key, old := range transport.clients {
			old.CloseIdleConnections()
			delete(transport.clients, key)
			break
		}
	}
	transport.clients[key] = client
	return client, nil
}

func huangguoBrowserHeaders(request *http.Request) fhttp.Header {
	headers := fhttp.Header{
		"sec-ch-ua":                 {`"Chromium";v="150", "Google Chrome";v="150", "Not_A Brand";v="24"`},
		"sec-ch-ua-mobile":          {"?0"},
		"sec-ch-ua-platform":        {`"macOS"`},
		"upgrade-insecure-requests": {"1"},
		"user-agent":                {"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36"},
		"accept":                    {"text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8"},
		"sec-fetch-site":            {"same-origin"},
		"sec-fetch-mode":            {"navigate"},
		"sec-fetch-user":            {"?1"},
		"sec-fetch-dest":            {"document"},
		"accept-language":           {"zh-CN,zh;q=0.9"},
		fhttp.HeaderOrderKey:        {"sec-ch-ua", "sec-ch-ua-mobile", "sec-ch-ua-platform", "upgrade-insecure-requests", "user-agent", "accept", "sec-fetch-site", "sec-fetch-mode", "sec-fetch-user", "sec-fetch-dest", "referer", "accept-encoding", "accept-language", "cookie"},
	}
	if mode := request.Header.Get("Sec-Fetch-Mode"); mode != "" && mode != "navigate" {
		headers["accept"] = []string{firstNonEmpty(request.Header.Get("Accept"), "*/*")}
		headers["sec-fetch-mode"] = []string{mode}
		headers["sec-fetch-dest"] = []string{firstNonEmpty(request.Header.Get("Sec-Fetch-Dest"), "empty")}
		delete(headers, "upgrade-insecure-requests")
		delete(headers, "sec-fetch-user")
	}
	for key, values := range request.Header {
		lower := strings.ToLower(key)
		if _, fixed := headers[lower]; fixed || lower == "host" || lower == "connection" {
			continue
		}
		headers[lower] = append([]string(nil), values...)
	}
	if referer := request.Header.Get("Referer"); referer == "" {
		headers["sec-fetch-site"] = []string{"none"}
	} else if parsed, err := url.Parse(referer); err == nil && !strings.EqualFold(parsed.Host, request.URL.Host) {
		headers["sec-fetch-site"] = []string{"cross-site"}
	}
	return headers
}

func standardBrowserHeaders(headers fhttp.Header) http.Header {
	result := make(http.Header, len(headers))
	for key, values := range headers {
		result[http.CanonicalHeaderKey(key)] = append([]string(nil), values...)
	}
	return result
}

func (transport *huangguoBrowserTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	// 自定义源 host：先用标准传输（能带上规则里的 请求头/UA，且不少站点对
	// utls 指纹直接回 403 验证页），只有真的撞上验证页才升级到浏览器指纹。
	if browserEligibleRequest(request) && transport.isCustomHost(request) && !transport.promoted(request) {
		response, err := transport.base.RoundTrip(request)
		if err != nil || !browserChallengeStatus(response) {
			return response, err
		}
		status := response.StatusCode
		mitigated := response.Header.Get("Cf-Mitigated")
		if response.Body != nil {
			response.Body.Close()
		}
		transport.promote(request.URL.Hostname())
		message := "自定义源返回 403，已改用浏览器指纹重试"
		if strings.Contains(strings.ToLower(mitigated), "challenge") {
			message = "自定义源被 Cloudflare 验证页拦截，已改用浏览器指纹重试"
		}
		transport.recordEvent(request, status, message)
		return transport.browserRoundTrip(request)
	}
	if !transport.matches(request) {
		return transport.base.RoundTrip(request)
	}
	return transport.browserRoundTrip(request)
}

// recordEvent 在切换传输通道时留一条诊断，便于用户定位站点拦截行为。
func (transport *huangguoBrowserTransport) recordEvent(request *http.Request, status int, message string) {
	if transport.record == nil || request == nil || request.URL == nil {
		return
	}
	transport.record(diagnosticEvent{Event: "network.browser_request", Level: "warning", Source: transport.source(request.URL),
		Host: request.URL.Hostname(), HTTPStatus: status, Client: huangguoBrowserProfile,
		ResponseType: "text/html", Message: message})
}

func (transport *huangguoBrowserTransport) browserRoundTrip(request *http.Request) (*http.Response, error) {
	client, err := transport.client(request)
	if err != nil {
		return nil, fmt.Errorf("黄果浏览器客户端初始化失败：%w", publicError(err))
	}
	upstream, err := fhttp.NewRequestWithContext(request.Context(), request.Method, request.URL.String(), request.Body)
	if err != nil {
		return nil, err
	}
	upstream.Header = huangguoBrowserHeaders(request)
	upstream.Host = request.Host
	upstream.ContentLength = request.ContentLength
	upstream.GetBody = request.GetBody
	response, err := client.Do(upstream)
	if err != nil {
		if response != nil && response.Body != nil {
			response.Body.Close()
		}
		return nil, publicError(err)
	}
	result := &http.Response{
		Status: response.Status, StatusCode: response.StatusCode,
		Proto: response.Proto, ProtoMajor: response.ProtoMajor, ProtoMinor: response.ProtoMinor,
		Header: standardBrowserHeaders(response.Header), Body: response.Body,
		ContentLength: response.ContentLength, TransferEncoding: response.TransferEncoding,
		Close: response.Close, Uncompressed: response.Uncompressed,
		Trailer: standardBrowserHeaders(response.Trailer), Request: request,
	}
	if state := response.TLS; state != nil {
		result.TLS = &tls.ConnectionState{Version: state.Version, HandshakeComplete: state.HandshakeComplete,
			DidResume: state.DidResume, CipherSuite: state.CipherSuite, NegotiatedProtocol: state.NegotiatedProtocol,
			ServerName: state.ServerName, PeerCertificates: state.PeerCertificates, VerifiedChains: state.VerifiedChains}
	}
	if transport.record != nil {
		level := "info"
		if result.StatusCode >= 400 || strings.EqualFold(result.Header.Get("Cf-Mitigated"), "challenge") {
			level = "warning"
		}
		transport.record(diagnosticEvent{Event: "network.browser_request", Level: level, Source: transport.source(request.URL),
			Host: request.URL.Hostname(), HTTPStatus: result.StatusCode, Client: huangguoBrowserProfile,
			Protocol: result.Proto, CFRay: truncate(result.Header.Get("Cf-Ray"), 128),
			ResponseType: truncate(result.Header.Get("Content-Type"), 128), Message: "浏览器指纹请求完成"})
	}
	return result, nil
}

func (transport *huangguoBrowserTransport) CloseIdleConnections() {
	transport.mu.Lock()
	for key, client := range transport.clients {
		client.CloseIdleConnections()
		delete(transport.clients, key)
	}
	transport.mu.Unlock()
	if closer, ok := transport.base.(interface{ CloseIdleConnections() }); ok {
		closer.CloseIdleConnections()
	}
}

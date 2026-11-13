package core

// xpxHost 把 guoappxp 运行时的 Host 能力包装成 guoappxpx 契约里的 Host。
// 不能让 downloaderSourceHost 直接实现 Host：两边都有 FetchText，但签名不同
// （string 参数 vs TextRequest），Go 不允许同一类型有两个同名方法。

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"time"

	xhtml "golang.org/x/net/html"
)

type xpxHost struct {
	sh downloaderSourceHost
	d  *Downloader
}

func newXpxHost(sh downloaderSourceHost) *xpxHost {
	return &xpxHost{sh: sh, d: sh.d}
}

func (h *xpxHost) Reserve(context.Context, string, string) (uint64, error) {
	// 运行时的限流由 DoPrepared / FetchTextFinal 内部完成，这里不需要票据。
	return 0, nil
}

func (h *xpxHost) Retries() int {
	if h.d != nil && h.d.cfg.Retries > 0 {
		return h.d.cfg.Retries
	}
	return 2
}

func (h *xpxHost) MaxPages() int {
	if h.d != nil && h.d.cfg.MaxPagesPerSort > 0 {
		return h.d.cfg.MaxPagesPerSort
	}
	return 50
}

func (h *xpxHost) Fetch(ctx context.Context, request HTTPRequest) (HTTPResponse, error) {
	if h.sh.d == nil {
		return HTTPResponse{}, errors.New("站源 Host 未就绪")
	}
	method := request.Method
	if method == "" {
		method = http.MethodGet
	}
	var body io.Reader
	if len(request.Body) > 0 {
		body = bytes.NewReader(request.Body)
	}
	prepared, err := http.NewRequestWithContext(ctx, method, request.URL, body)
	if err != nil {
		return HTTPResponse{}, err
	}
	for key, value := range request.Header {
		prepared.Header.Set(key, value)
	}
	response, err := h.sh.DoPrepared(ctx, prepared, request.Timeout)
	if err != nil {
		return HTTPResponse{}, err
	}
	defer response.Body.Close()
	limit := request.Limit
	if limit <= 0 {
		limit = 4 << 20
	}
	data, readErr := io.ReadAll(io.LimitReader(response.Body, limit))
	if readErr != nil {
		return HTTPResponse{}, readErr
	}
	status := response.StatusCode
	if status < 200 || status >= 300 {
		if request.AnyStatus {
			return HTTPResponse{Status: status, Header: response.Header, Body: data}, nil
		}
		return HTTPResponse{}, h.sh.CatalogResponseError(prepared, response, data)
	}
	return HTTPResponse{Status: status, Header: response.Header, Body: data}, nil
}

func (h *xpxHost) BaseURL(source string) string {
	if h.sh.d == nil {
		return ""
	}
	return h.sh.BaseURL(source)
}

func (h *xpxHost) PreferredSite(source string) string {
	if h.sh.d == nil {
		return ""
	}
	return h.sh.ConfigURL(source)
}

func (h *xpxHost) RememberSite(source, site string) {
	if h.sh.d != nil {
		h.sh.RememberHost(source, site)
	}
}

func (h *xpxHost) FetchText(ctx context.Context, request TextRequest) (TextResponse, error) {
	if h.sh.d == nil {
		return TextResponse{}, errors.New("站源 Host 未就绪")
	}
	if len(request.Body) > 0 {
		body, err := h.sh.PostJSON(ctx, request.URL, request.Referer, request.Body)
		if err != nil {
			return TextResponse{}, err
		}
		return TextResponse{Body: body, URL: request.URL}, nil
	}
	body, finalURL, err := h.sh.FetchTextFinal(ctx, request.URL, request.Referer, request.UserAgent, request.Cookie)
	if err != nil {
		return TextResponse{}, err
	}
	if finalURL == "" {
		finalURL = request.URL
	}
	return TextResponse{Body: body, URL: finalURL}, nil
}

func (h *xpxHost) FetchPlaylist(ctx context.Context, address, referer string, _ *MediaCredentials) (string, string, error) {
	if h.sh.d == nil {
		return "", "", errors.New("站源 Host 未就绪")
	}
	return h.sh.FetchMediaPlaylist(ctx, address, referer)
}

func (h *xpxHost) LoadState(name string) ([]byte, error) {
	if h.sh.d == nil || h.sh.StateDir() == "" {
		return nil, errors.New("站源状态目录未就绪")
	}
	return os.ReadFile(filepath.Join(h.sh.StateDir(), filepath.Base(name)))
}

func (h *xpxHost) SaveState(name string, data []byte) error {
	if h.sh.d == nil || h.sh.StateDir() == "" {
		return errors.New("站源状态目录未就绪")
	}
	dir := h.sh.StateDir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(dir, filepath.Base(name)), data, 0o600)
}

func (h *xpxHost) PrepareWebMedia(ctx context.Context, media ProviderMedia, sourceName string) (ProviderMedia, error) {
	if h.sh.d == nil {
		return media, nil
	}
	return h.sh.PrepareWebMedia(ctx, media, sourceName)
}

func (h *xpxHost) FinishMedia(_ context.Context, media ProviderMedia, _ string) (ProviderMedia, error) {
	// core 的收尾逻辑内联在 resolveProviderMedia 里，运行时会在派发层统一处理。
	return media, nil
}

// 以下方法是 guoappxp 运行时扩展（RuntimeHost）的实现：全部转发给底层运行时 Host，
// 让按示例模板改造的存量源仍能使用短剧引擎、MacCMS 引擎、legacy 协议等能力。

func (h *xpxHost) FetchPage(ctx context.Context, address, referer, userAgent, cookie string) (*xhtml.Node, string, error) {
	if h.sh.d == nil {
		return nil, "", errors.New("站源 Host 未就绪")
	}
	return h.sh.FetchPage(ctx, address, referer, userAgent, cookie)
}

func (h *xpxHost) HTTPClient() *http.Client {
	if h.sh.d == nil {
		return nil
	}
	return h.sh.HTTPClient()
}

func (h *xpxHost) Limiter() RequestLimiter {
	if h.sh.d == nil {
		return nil
	}
	return h.sh.Limiter()
}

func (h *xpxHost) CatalogResponseError(request *http.Request, response *http.Response, body []byte) error {
	if h.sh.d == nil {
		return errors.New("站源 Host 未就绪")
	}
	return h.sh.CatalogResponseError(request, response, body)
}

func (h *xpxHost) ConfigURL(source string) string {
	if h.sh.d == nil {
		return ""
	}
	return h.sh.ConfigURL(source)
}

func (h *xpxHost) ConfigAPIURL(source string) string {
	if h.sh.d == nil {
		return ""
	}
	return h.sh.ConfigAPIURL(source)
}

func (h *xpxHost) DuanjuBaseURL(source string) string {
	if h.sh.d == nil {
		return ""
	}
	return h.sh.DuanjuBaseURL(source)
}

func (h *xpxHost) DuanjuJSON(ctx context.Context, request DuanjuRequest) (map[string]any, error) {
	if h.sh.d == nil {
		return nil, errors.New("站源 Host 未就绪")
	}
	return h.sh.DuanjuJSON(ctx, request)
}

func (h *xpxHost) DuanjuDo(ctx context.Context, request DuanjuRequest) ([]byte, error) {
	if h.sh.d == nil {
		return nil, errors.New("站源 Host 未就绪")
	}
	return h.sh.DuanjuDo(ctx, request)
}

func (h *xpxHost) MaccmsCatalogPage(ctx context.Context, source string, page int, category string) ([]Drama, bool, error) {
	if h.sh.d == nil {
		return nil, false, errors.New("站源 Host 未就绪")
	}
	return h.sh.MaccmsCatalogPage(ctx, source, page, category)
}

func (h *xpxHost) MaccmsDetail(ctx context.Context, source, sourceID string) (Drama, []Chapter, error) {
	if h.sh.d == nil {
		return Drama{}, nil, errors.New("站源 Host 未就绪")
	}
	return h.sh.MaccmsDetail(ctx, source, sourceID)
}

func (h *xpxHost) MaccmsSearch(ctx context.Context, source, query string) ([]Drama, error) {
	if h.sh.d == nil {
		return nil, errors.New("站源 Host 未就绪")
	}
	return h.sh.MaccmsSearch(ctx, source, query)
}

func (h *xpxHost) DuanjuResolveMedia(ctx context.Context, task Task) (ProviderMedia, error) {
	if h.sh.d == nil {
		return ProviderMedia{}, errors.New("站源 Host 未就绪")
	}
	return h.sh.DuanjuResolveMedia(ctx, task)
}

func (h *xpxHost) BrowserPostJSON(ctx context.Context, address string, headers [][2]string, body []byte, timeout time.Duration) (int, []byte, error) {
	if h.sh.d == nil {
		return 0, nil, errors.New("站源 Host 未就绪")
	}
	return h.sh.BrowserPostJSON(ctx, address, headers, body, timeout)
}

func (h *xpxHost) DoPrepared(ctx context.Context, request *http.Request, timeout time.Duration) (*http.Response, error) {
	if h.sh.d == nil {
		return nil, errors.New("站源 Host 未就绪")
	}
	return h.sh.DoPrepared(ctx, request, timeout)
}

func (h *xpxHost) RememberHost(source, host string) {
	if h.sh.d != nil {
		h.sh.RememberHost(source, host)
	}
}

func (h *xpxHost) LegacySettings() LegacySettings {
	if h.sh.d == nil {
		return LegacySettings{}
	}
	return h.sh.LegacySettings()
}

func (h *xpxHost) APIEndpoint(ctx context.Context) (string, error) {
	if h.sh.d == nil {
		return "", errors.New("站源 Host 未就绪")
	}
	return h.sh.APIEndpoint(ctx)
}

func (h *xpxHost) ResetAPIEndpoint(base string) {
	if h.sh.d != nil {
		h.sh.ResetAPIEndpoint(base)
	}
}

func (h *xpxHost) PostJSON(ctx context.Context, address, referer string, payload []byte) (string, error) {
	if h.sh.d == nil {
		return "", errors.New("站源 Host 未就绪")
	}
	return h.sh.PostJSON(ctx, address, referer, payload)
}

func (h *xpxHost) ForgetHost(source string) {
	if h.sh.d != nil {
		h.sh.ForgetHost(source)
	}
}

func (h *xpxHost) FetchTextFinal(ctx context.Context, address, referer, userAgent, cookie string) (string, string, error) {
	if h.sh.d == nil {
		return "", "", errors.New("站源 Host 未就绪")
	}
	return h.sh.FetchTextFinal(ctx, address, referer, userAgent, cookie)
}

func (h *xpxHost) FetchMediaPlaylist(ctx context.Context, address, referer string) (string, string, error) {
	if h.sh.d == nil {
		return "", "", errors.New("站源 Host 未就绪")
	}
	return h.sh.FetchMediaPlaylist(ctx, address, referer)
}

func (h *xpxHost) StateDir() string {
	if h.sh.d == nil {
		return ""
	}
	return h.sh.StateDir()
}

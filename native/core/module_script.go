package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"net/url"
	"reflect"
	"strings"
	"sync"
	"time"

	"github.com/dop251/goja"
)

const (
	moduleInstanceLimit = 4
	moduleCallTimeout   = 60 * time.Second
	moduleQuickTimeout  = 5 * time.Second
)

var moduleInvoker = goja.MustCompile("module-invoker", `(function(exports) {
	return function(name, encoded) {
		var target = exports[name];
		if (typeof target !== "function") throw new Error("模块未导出函数 " + name);
		var result = target.apply(exports, JSON.parse(encoded));
		if (result instanceof Promise) throw new Error("模块函数 " + name + " 不能是异步函数");
		return JSON.stringify(result === undefined ? null : result);
	};
})`, true)

// moduleByteHelpers 给 goja 的 Uint8Array 补上标准库有、goja 没实现的方法。
//
// goja 目前没有 Uint8Array.prototype.concat，而商店里的模块（如 cloudfront）
// 会把多段字节拼起来当 AES 密钥/向量用，缺了它会报
// "Object has no member 'concat'"。这里按规范补一个，返回新的 Uint8Array。
var moduleByteHelpers = goja.MustCompile("module-byte-helpers", `(function() {
	if (typeof Uint8Array.prototype.concat === "function") return;
	Object.defineProperty(Uint8Array.prototype, "concat", {
		value: function() {
			var total = this.length;
			var parts = [];
			for (var i = 0; i < arguments.length; i++) {
				var item = arguments[i];
				parts.push(item);
				total += item && typeof item.length === "number" ? item.length : 0;
			}
			var out = new Uint8Array(total);
			out.set(this, 0);
			var offset = this.length;
			for (var j = 0; j < parts.length; j++) {
				var part = parts[j];
				if (part && typeof part.length === "number") {
					out.set(part, offset);
					offset += part.length;
				}
			}
			return out;
		},
		writable: true,
		configurable: true
	});
})();`, true)

// installByteArrayHelpers 在每个新实例里装上字节数组补丁。
func installByteArrayHelpers(vm *goja.Runtime) error {
	_, err := vm.RunProgram(moduleByteHelpers)
	return err
}

type jsProvider struct {
	module    *jsModule
	host      Host
	exclusive chan struct{}
	slots     chan struct{}
	idle      chan *jsInstance
	cacheMu   sync.Mutex
	cache     map[string]moduleCacheEntry
}

type jsInstance struct {
	vm        *goja.Runtime
	invoke    goja.Callable
	exports   *goja.Object
	ctx       context.Context
	exclusive bool
}

type jsFetchRequest struct {
	Method          string            `json:"method"`
	URL             string            `json:"url"`
	Headers         map[string]string `json:"headers"`
	Body            string            `json:"body"`
	TimeoutMS       int64             `json:"timeoutMs"`
	Limit           int64             `json:"limit"`
	FollowRedirects bool              `json:"followRedirects"`
	AnyStatus       bool              `json:"anyStatus"`
	AcceptStatus    []int             `json:"acceptStatus"`
	Ticket          uint64            `json:"ticket"`
	Background      bool              `json:"background"`
	Direct          bool              `json:"direct"`
}

type jsFetchResponse struct {
	Status    int                 `json:"status"`
	Headers   map[string][]string `json:"headers"`
	Body      string              `json:"body"`
	Blocked   bool                `json:"blocked"`
	Oversized bool                `json:"oversized"`
}

type jsDramaPage struct {
	Items   []Drama `json:"items"`
	HasMore bool    `json:"hasMore"`
	Warning string  `json:"warning"`
}

type jsDetail struct {
	Drama    Drama     `json:"drama"`
	Chapters []Chapter `json:"chapters"`
}

type jsTextRequest struct {
	URL       string   `json:"url"`
	Referer   string   `json:"referer"`
	UserAgent string   `json:"userAgent"`
	Cookie    string   `json:"cookie"`
	NoCache   bool     `json:"noCache"`
	Body      string   `json:"body"`
	Mirrors   []string `json:"mirrors"`
	// 商店里的模块常把 fetch 的写法套在 fetchText 上（method / headers /
	// anyStatus / limit / followRedirects / timeoutMs）。这些字段这里全部接受，
	// 让同一个请求对象在两种接口下都能用。
	Method          string            `json:"method"`
	Headers         map[string]string `json:"headers"`
	AnyStatus       bool              `json:"anyStatus"`
	Limit           int64             `json:"limit"`
	FollowRedirects bool              `json:"followRedirects"`
	TimeoutMS       int64             `json:"timeoutMs"`
}

type jsTextResponse struct {
	Body string `json:"body"`
	URL  string `json:"url"`
	// Status 与 Headers 让模块能读到响应码与响应头（例如 set-cookie）。
	// 老模块不读这两个字段，返回它们不影响兼容性。
	Status  int                 `json:"status"`
	Headers map[string][]string `json:"headers"`
}

type jsPlaylistRequest struct {
	URL         string         `json:"url"`
	Referer     string         `json:"referer"`
	Credentials *jsCredentials `json:"credentials"`
}

type jsPlaylist struct {
	Playlist   string `json:"playlist"`
	URL        string `json:"url"`
	DurationMS int64  `json:"durationMs"`
}

type jsURL struct {
	Scheme   string `json:"scheme"`
	Host     string `json:"host"`
	Hostname string `json:"hostname"`
	Port     string `json:"port"`
	Path     string `json:"path"`
	Query    string `json:"query"`
	Fragment string `json:"fragment"`
	UserInfo bool   `json:"userInfo"`
	Href     string `json:"href"`
}

type jsCredentials struct {
	Cookie    string `json:"cookie"`
	Origin    string `json:"origin"`
	Referer   string `json:"referer"`
	UserAgent string `json:"userAgent"`
	ExpiresMS int64  `json:"expiresMs"`
}

type jsMedia struct {
	Credentials *jsCredentials `json:"credentials"`
	URL         string         `json:"url"`
	Referer     string         `json:"referer"`
	Playlist    string         `json:"playlist"`
	HLSKey      []byte         `json:"hlsKey"`
	CENCKey     []byte         `json:"cencKey"`
	Quality     int            `json:"quality"`
	DurationMS  int64          `json:"durationMs"`
	Variants    []jsMedia      `json:"variants"`
}

func (media jsMedia) providerMedia() ProviderMedia {
	converted := ProviderMedia{URL: media.URL, Referer: media.Referer, Playlist: media.Playlist, Quality: media.Quality,
		HLSKey: media.HLSKey, CENCKey: media.CENCKey, Duration: time.Duration(media.DurationMS) * time.Millisecond}
	if credentials := media.Credentials; credentials != nil {
		converted.Credentials = &MediaCredentials{Cookie: credentials.Cookie, Origin: credentials.Origin,
			Referer: credentials.Referer, UserAgent: credentials.UserAgent}
		if credentials.ExpiresMS > 0 {
			converted.Credentials.Expires = time.UnixMilli(credentials.ExpiresMS)
		}
	}
	for _, variant := range media.Variants {
		converted.Variants = append(converted.Variants, variant.providerMedia())
	}
	return converted
}

func moduleMedia(media ProviderMedia) jsMedia {
	converted := jsMedia{URL: media.URL, Referer: media.Referer, Playlist: media.Playlist, Quality: media.Quality,
		HLSKey: media.HLSKey, CENCKey: media.CENCKey, DurationMS: media.Duration.Milliseconds()}
	if credentials := media.Credentials; credentials != nil {
		converted.Credentials = &jsCredentials{Cookie: credentials.Cookie, Origin: credentials.Origin,
			Referer: credentials.Referer, UserAgent: credentials.UserAgent}
		if !credentials.Expires.IsZero() {
			converted.Credentials.ExpiresMS = credentials.Expires.UnixMilli()
		}
	}
	for _, variant := range media.Variants {
		converted.Variants = append(converted.Variants, moduleMedia(variant))
	}
	return converted
}

func (module *jsModule) provider(host Host) Provider {
	p := &jsProvider{module: module, host: host, exclusive: make(chan struct{}, 1), cache: map[string]moduleCacheEntry{},
		slots: make(chan struct{}, moduleInstanceLimit), idle: make(chan *jsInstance, moduleInstanceLimit)}
	module.active.Store(p)
	return p
}

func (module *jsModule) validCategory(category string) bool {
	// 空分类永远有效（应用的「全部」入口），不必起 VM 问模块。
	if strings.TrimSpace(category) == "" {
		return true
	}
	p := module.active.Load()
	if p == nil {
		// provider 还没创建时（模块刚注册、用户第一次点分类）不能直接判无效，
		// 否则表现为「点击分类提示内容分类无效」。此时按「合法 id」放行，
		// 真正的校验交给模块自己的 catalogPage（它内部会再判一次）。
		return validCategoryIDShape(category)
	}
	// 模块没导出 validCategory 时（商店里很多 maccmsweb 模板模块就是如此），
	// 不能一律判 false——那样模块自己 categories() 报的分类会被判无效，
	// 表现为「点击分类提示内容分类无效」。这类模块交给 catalogPage 自己兜底。
	if !p.exportsFunction("validCategory") {
		return validCategoryIDShape(category)
	}
	ctx, cancel := context.WithTimeout(context.Background(), moduleQuickTimeout)
	defer cancel()
	var valid bool
	return p.call(ctx, "validCategory", &valid, category) == nil && valid
}

// validCategoryIDShape 只做形态校验：排除缓存键分隔符、反斜杠与控制字符。
// 与 ValidNativeCategory 的前置规则保持一致，避免在 provider 就绪前误杀合法分类。
func validCategoryIDShape(category string) bool {
	if len(category) > 128 || strings.ContainsAny(category, "|\\\x00\r\n") {
		return false
	}
	return true
}

func (p *jsProvider) Descriptor() SourceDescriptor { return p.module.descriptor() }

func (p *jsProvider) ProvidesCapability(capability reflect.Type) bool {
	return p.module.capabilities[capability]
}

func (p *jsProvider) Categories(ctx context.Context, force bool) ([]Category, error) {
	var raw json.RawMessage
	if err := p.call(ctx, "categories", &raw, force); err != nil {
		return nil, err
	}
	var categories []Category
	if json.Unmarshal(raw, &categories) == nil {
		return categories, nil
	}
	var partial struct {
		Items      []Category `json:"items"`
		Incomplete bool       `json:"incomplete"`
	}
	if err := json.Unmarshal(raw, &partial); err != nil {
		return nil, err
	}
	if partial.Incomplete {
		return partial.Items, ErrCategoriesIncomplete
	}
	return partial.Items, nil
}

func (p *jsProvider) CatalogPage(ctx context.Context, page int, category string) ([]Drama, bool, error) {
	var result jsDramaPage
	if err := p.call(ctx, "catalogPage", &result, page, category); err != nil {
		return nil, false, err
	}
	if result.Warning != "" {
		return result.Items, result.HasMore, errors.New(result.Warning)
	}
	return result.Items, result.HasMore, nil
}

func (p *jsProvider) Search(ctx context.Context, page int, query string) ([]Drama, bool, error) {
	items, more, _, err := p.SearchWithWarning(ctx, page, query)
	return items, more, err
}

func (p *jsProvider) SearchWithWarning(ctx context.Context, page int, query string) ([]Drama, bool, string, error) {
	var result jsDramaPage
	err := p.call(ctx, "search", &result, page, query)
	return result.Items, result.HasMore, result.Warning, err
}

func (p *jsProvider) Detail(ctx context.Context, sourceID string) (Drama, []Chapter, error) {
	var result jsDetail
	err := p.call(ctx, "detail", &result, sourceID)
	return result.Drama, result.Chapters, err
}

func (p *jsProvider) Account(ctx context.Context, command string, payload json.RawMessage) (any, error) {
	var result any
	return result, p.call(ctx, "account", &result, command, payload)
}

func (p *jsProvider) ResolveMedia(ctx context.Context, task Task) (ProviderMedia, error) {
	// 有的模块不给 resolveMedia，而是在 detail 里把直链写进 chapter.videoUrl
	// （采集站常见：分集本身就带 m3u8/mp4）。这时直接用清单里的地址，
	// 不要报「模块未导出函数 resolveMedia」。
	if !p.exportsFunction("resolveMedia") {
		if url := strings.TrimSpace(task.Chapter.VideoURL); url != "" {
			return ProviderMedia{URL: url, Referer: task.Chapter.Referer}, nil
		}
		return ProviderMedia{}, errors.New("这个模块没有提供播放地址，请刷新详情后重试")
	}
	var media jsMedia
	if err := p.call(ctx, "resolveMedia", &media, task); err != nil {
		return ProviderMedia{}, err
	}
	return media.providerMedia(), nil
}

// exportsFunction 判断模块是否导出了某个函数，用于兼容不实现可选函数的模块。
func (p *jsProvider) exportsFunction(name string) bool {
	// 必须带超时：实例池只有 moduleInstanceLimit 个，并发搜索时可能全被占用，
	// 用 context.Background() 会在这里永久阻塞（点分类/搜索时表现为卡死）。
	ctx, cancel := context.WithTimeout(context.Background(), moduleQuickTimeout)
	defer cancel()
	instance, err := p.acquire(ctx)
	if err != nil {
		// 拿不到实例时按「已导出」处理，让 call 报出真实错误。
		return true
	}
	defer func() { p.idle <- instance }()
	if instance.exports == nil {
		return false
	}
	target := instance.exports.Get(name)
	if target == nil || goja.IsUndefined(target) || goja.IsNull(target) {
		return false
	}
	_, ok := goja.AssertFunction(target)
	return ok
}

func (p *jsProvider) call(ctx context.Context, function string, result any, arguments ...any) error {
	ctx, cancel := context.WithTimeout(ctx, moduleCallTimeout)
	defer cancel()
	encoded, err := json.Marshal(arguments)
	if err != nil {
		return err
	}
	instance, err := p.acquire(ctx)
	if err != nil {
		return err
	}
	defer func() { p.idle <- instance }()
	instance.ctx = ctx
	interrupted := make(chan struct{})
	stop := context.AfterFunc(ctx, func() {
		instance.vm.Interrupt(ctx.Err())
		close(interrupted)
	})
	value, err := instance.invoke(goja.Undefined(), instance.vm.ToValue(function), instance.vm.ToValue(string(encoded)))
	if !stop() {
		<-interrupted
		instance.vm.ClearInterrupt()
	}
	if err != nil {
		return moduleError(ctx, err)
	}
	return json.Unmarshal([]byte(value.String()), result)
}

func moduleError(ctx context.Context, err error) error {
	var interrupted *goja.InterruptedError
	if errors.As(err, &interrupted) && ctx.Err() != nil {
		return ctx.Err()
	}
	var exception *goja.Exception
	if !errors.As(err, &exception) {
		return err
	}
	if cause := exception.Unwrap(); cause != nil {
		return cause
	}
	if thrown, ok := exception.Value().(*goja.Object); ok {
		if message := thrown.Get("message"); message != nil && !goja.IsUndefined(message) {
			if login := thrown.Get("loginRequired"); login != nil && login.ToBoolean() {
				return SourceLoginError(message.String())
			}
			return errors.New(message.String())
		}
	}
	return errors.New(exception.Value().String())
}

func (p *jsProvider) acquire(ctx context.Context) (*jsInstance, error) {
	select {
	case instance := <-p.idle:
		return instance, nil
	default:
	}
	select {
	case instance := <-p.idle:
		return instance, nil
	case p.slots <- struct{}{}:
		instance, err := p.newInstance()
		if err != nil {
			<-p.slots
		}
		return instance, err
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func (p *jsProvider) newInstance() (*jsInstance, error) {
	vm := goja.New()
	vm.SetFieldNameMapper(goja.TagFieldNameMapper("json", true))
	instance := &jsInstance{vm: vm, ctx: context.Background()}
	module, exports := vm.NewObject(), vm.NewObject()
	if err := module.Set("exports", exports); err != nil {
		return nil, err
	}
	if err := installByteArrayHelpers(vm); err != nil {
		return nil, err
	}
	wrapper, err := vm.RunProgram(p.module.program)
	if err != nil {
		return nil, moduleError(instance.ctx, err)
	}
	load, _ := goja.AssertFunction(wrapper)
	if _, err := load(goja.Undefined(), module, exports, p.hostObject(instance)); err != nil {
		return nil, moduleError(instance.ctx, err)
	}
	invoker, err := vm.RunProgram(moduleInvoker)
	if err != nil {
		return nil, err
	}
	bind, _ := goja.AssertFunction(invoker)
	bound, err := bind(goja.Undefined(), module.Get("exports"))
	if err != nil {
		return nil, moduleError(instance.ctx, err)
	}
	instance.invoke, _ = goja.AssertFunction(bound)
	// 记下 exports，供 exportsFunction 判断模块是否实现了可选函数。
	if exported := module.Get("exports"); exported != nil && !goja.IsUndefined(exported) && !goja.IsNull(exported) {
		instance.exports = exported.ToObject(vm)
	}
	return instance, nil
}

func (p *jsProvider) hostObject(instance *jsInstance) *goja.Object {
	id := p.module.manifest.ID
	host := instance.vm.NewObject()
	members := map[string]any{
		"source":    id,
		"dramaId":   func(sourceID string) string { return ProviderDramaID(id, sourceID) },
		"chapterId": func(sourceID, key string) string { return ProviderChapterID(id, sourceID, key) },
		// guoappcheng 商店的模块（maccms 采集站那一族）在脚本开头就读
		// host.manifest() 拿 config / base，本站自带的模块则直接把常量写在
		// 脚本里。缺了这两个成员，脚本一执行就报
		// "object has no member 'manifest'"。
		"manifest": func() any { return p.module.manifestData() },
		"baseUrl": func() string { return p.module.manifest.effectiveBaseURL() },
		"fetch": func(request jsFetchRequest) jsFetchResponse {
			response, err := p.fetch(instance.ctx, request)
			if err != nil {
				instance.failResponse(err, response)
			}
			return response
		},
		"fetchText": func(request jsTextRequest) jsTextResponse {
			response, err := p.fetchText(instance.ctx, request)
			if err != nil {
				instance.fail(err, false)
			}
			return response
		},
		"parseUrl":      parseModuleURL,
		"preferredSite": func() string { return p.host.PreferredSite(id) },
		"fetchPlaylist": func(request jsPlaylistRequest) (jsPlaylist, error) {
			return p.fetchPlaylist(instance.ctx, request)
		},
		"exclusive": func(call goja.FunctionCall) goja.Value {
			critical, ok := goja.AssertFunction(call.Argument(0))
			if !ok {
				panic(instance.vm.NewTypeError("exclusive 需要一个函数"))
			}
			if instance.exclusive {
				panic(instance.vm.NewTypeError("exclusive 不可重入"))
			}
			select {
			case p.exclusive <- struct{}{}:
			case <-instance.ctx.Done():
				panic(instance.vm.NewGoError(instance.ctx.Err()))
			}
			instance.exclusive = true
			defer func() {
				instance.exclusive = false
				<-p.exclusive
			}()
			value, err := critical(goja.Undefined())
			if err != nil {
				panic(err)
			}
			return value
		},
		"prepareWebMedia": func(media jsMedia, sourceName string) (jsMedia, error) {
			prepared, err := p.host.PrepareWebMedia(instance.ctx, media.providerMedia(), sourceName)
			return moduleMedia(prepared), err
		},
		"loadState": func(name string) (string, error) {
			data, err := p.host.LoadState(moduleStatePrefix + id + "-" + name)
			return string(data), err
		},
		"saveState": func(name, value string) error {
			return p.host.SaveState(moduleStatePrefix+id+"-"+name, []byte(value))
		},
		"log": func(message string) {
			if downloader, ok := p.host.(*Downloader); ok {
				downloader.recordDiagnostic(diagnosticEvent{Time: time.Now(), Level: "info", Event: "module", Source: id, Message: message})
			}
		},
	}
	maps.Copy(members, p.hostUtilities(instance))
	for name, member := range members {
		_ = host.Set(name, member)
	}
	return host
}

func (instance *jsInstance) fail(err error, oversized bool) {
	instance.failResponse(err, jsFetchResponse{Oversized: oversized})
}

func (instance *jsInstance) failResponse(err error, response jsFetchResponse) {
	failure := instance.vm.NewGoError(err)
	var backoff *RequestBackoff
	_ = failure.Set("backoff", errors.As(err, &backoff))
	_ = failure.Set("oversized", response.Oversized)
	_ = failure.Set("status", response.Status)
	_ = failure.Set("body", response.Body)
	_ = failure.Set("blocked", response.Blocked)
	panic(failure)
}

func moduleBody(body string) []byte {
	if body == "" {
		return nil
	}
	return []byte(body)
}

func parseModuleURL(raw string) (jsURL, error) {
	address, err := url.Parse(raw)
	if err != nil {
		return jsURL{}, errors.New("地址无效")
	}
	return jsURL{Scheme: address.Scheme, Host: address.Host, Hostname: address.Hostname(), Port: address.Port(),
		Path: address.Path, Query: address.RawQuery, Fragment: address.Fragment, UserInfo: address.User != nil, Href: address.String()}, nil
}

func (p *jsProvider) allowedAddress(raw string) error {
	address, err := url.Parse(raw)
	if err != nil || address.Scheme != "https" && address.Scheme != "http" || address.Hostname() == "" {
		return errors.New("请求地址无效")
	}
	if !p.module.allowsHost(address.Hostname()) {
		return fmt.Errorf("模块清单未声明访问 %s", address.Hostname())
	}
	return nil
}

func (p *jsProvider) fetchPlaylist(ctx context.Context, request jsPlaylistRequest) (jsPlaylist, error) {
	media := jsMedia{Credentials: request.Credentials}.providerMedia()
	playlist, address, err := p.host.FetchPlaylist(ctx, request.URL, request.Referer, media.Credentials)
	return jsPlaylist{Playlist: playlist, URL: address, DurationMS: M3u8Duration(playlist).Milliseconds()}, err
}

func (p *jsProvider) fetchText(ctx context.Context, request jsTextRequest) (jsTextResponse, error) {
	if err := p.allowedAddress(request.URL); err != nil {
		return jsTextResponse{}, err
	}
	var mirrors []string
	for _, mirror := range request.Mirrors {
		if p.allowedAddress(mirror) == nil {
			mirrors = append(mirrors, mirror)
		}
	}
	// 模块把 fetch 的写法套在 fetchText 上时（带 method / headers / anyStatus /
	// limit / followRedirects / timeoutMs），改走 fetch 通道，这样响应码与响应头
	// 都能拿到。商店里的 dongpiandi 就是这种写法，走原路径会拿不到 status。
	if request.usesFetchShape() {
		response, err := p.fetch(ctx, jsFetchRequest{
			Method:          request.Method,
			URL:             request.URL,
			Headers:         request.Headers,
			Body:            request.Body,
			TimeoutMS:       request.TimeoutMS,
			Limit:           request.Limit,
			FollowRedirects: request.FollowRedirects,
			AnyStatus:       request.AnyStatus,
		})
		return jsTextResponse{
			Body: response.Body, URL: request.URL, Status: response.Status, Headers: response.Headers,
		}, err
	}
	response, err := p.host.FetchText(ctx, TextRequest{URL: request.URL, Referer: request.Referer, UserAgent: request.UserAgent,
		Cookie: request.Cookie, NoCache: request.NoCache, Body: moduleBody(request.Body), Mirrors: mirrors})
	return jsTextResponse{Body: response.Body, URL: response.URL, Status: 200}, err
}

// usesFetchShape 判断这次 fetchText 调用是否用了 fetch 风格的字段。
func (request jsTextRequest) usesFetchShape() bool {
	return strings.TrimSpace(request.Method) != "" || len(request.Headers) > 0 ||
		request.AnyStatus || request.Limit > 0 || request.FollowRedirects || request.TimeoutMS > 0
}

func (p *jsProvider) fetch(ctx context.Context, request jsFetchRequest) (jsFetchResponse, error) {
	if err := p.allowedAddress(request.URL); err != nil {
		return jsFetchResponse{}, err
	}
	if request.Background {
		ctx = context.WithValue(ctx, BackgroundCatalogKey{}, true)
	}
	response, err := p.host.Fetch(ctx, HTTPRequest{
		Label: p.module.manifest.Name, Method: request.Method, URL: request.URL, Header: request.Headers,
		Body: moduleBody(request.Body), Timeout: time.Duration(request.TimeoutMS) * time.Millisecond, Limit: request.Limit,
		FollowRedirects: request.FollowRedirects, AnyStatus: request.AnyStatus, AcceptJSONStatus: request.AcceptStatus, Ticket: request.Ticket,
		Direct: request.Direct,
	})
	if err != nil {
		return jsFetchResponse{Status: response.Status, Body: string(response.Body), Blocked: response.Blocked, Oversized: response.Oversized}, err
	}
	return jsFetchResponse{Status: response.Status, Headers: response.Header, Body: string(response.Body),
		Blocked: response.Blocked, Oversized: response.Oversized}, nil
}

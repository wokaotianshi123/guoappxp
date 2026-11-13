package core

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"time"

	xhtml "golang.org/x/net/html"
)

// errSourceNotCompiled 是站源未编入当前版本时返回的错误。
var errSourceNotCompiled = errors.New("该站源未编入当前版本")

// 站源账号的标准错误：站源把需要登录 / 登录失效的错误包上它们，
// 运行时据此回 code=source_login，前端就能把用户引到「站源账号」页面。
var (
	ErrSourceLoginRequired = errors.New("该站源需要登录后才能播放")
	ErrSourceLoginExpired  = errors.New("站源登录已失效，请重新登录")
)

// sourceValidCategory 让编译期接入的站源自己判定分类。第二个返回值表示是否已由站源处理。
// 探针实例不带 Host，站源的 ValidCategory 因此必须是纯函数。
func sourceValidCategory(source, category string) (valid bool, handled bool) {
	source = canonicalProviderSource(source)
	sourceRegistry.RLock()
	factory, ok := sourceRegistry.factories[source]
	sourceRegistry.RUnlock()
	if !ok {
		// 番茄是 core 内置源，未编入外置模块时分类校验也要能走通，
		// 否则红果鉴里目录请求会先被「无效分类」挡下来。
		if source == sourceFanqie {
			return fanqieBuiltinValidCategory(category), true
		}
		return false, false
	}
	return factory(nil).ValidCategory(category), true
}

// 本文件是「站源分离」的对外接口面：站源不再写在 core 里，而是编译期由
// 独立的 Go 模块（默认 guoapp/sources）接入，只单向依赖这里导出的标识符。
//
// 约定：
//   - 站源实现 SourceProvider，在 init 里用 RegisterSource 登记描述符与工厂；
//   - 站源访问网络、读写运行时状态只能经 SourceHost，不要自建 http.Client；
//   - core 不再直接引用任何具体站源，派发一律经 sourceProvider(id) 查表。

// SourceDescriptor 描述一个编译期接入的站源。
type SourceDescriptor struct {
	ID          string
	Name        string
	Description string
}

// SourceProvider 是站源必须实现的接口。
//
// 方法集合刻意保持最小：分类、分类校验、目录分页（含搜索）、详情、取流。
// 站源特有的能力（榜单、弹幕、设备注册等）后续按可选接口补充，不塞进这里。
type SourceProvider interface {
	Categories() []NativeCategory
	ValidCategory(category string) bool
	CatalogPage(ctx context.Context, page int, category, query string) ([]Drama, bool, error)
	Detail(ctx context.Context, sourceID string) (Drama, []Chapter, error)
	ResolveMedia(ctx context.Context, task Task) (ProviderMedia, error)
}

// SourceAccount 是站源的可选账号能力（登录 / 验证码 / 登出）。
// 只有需要账号的站源才实现它；command 与 input 的语义由站源自己定义，
// 运行时只负责把请求原样转发（input 为请求里的 JSON 原文）。
type SourceAccount interface {
	Account(ctx context.Context, command string, input json.RawMessage) (any, error)
}

// SourceRankings 是站源的可选榜单能力：board 是站源自己的榜单键（如黄豆的 "all"），
// 站源只负责取数据并转成 Drama，名次与提示由运行时统一组装。
type SourceRankings interface {
	RankingPage(ctx context.Context, board string, page int) ([]Drama, bool, error)
}

// RankingEntry 是榜单单条：名次与文案由站点决定，运行时只负责透传与缓存。
type RankingEntry struct {
	Rank   int
	Drama  Drama
	Metric string
}

// SourceRankingEntries 是站源的榜单能力（站点自带名次 / 指标文案时用它）。
// 只要求「位置名次」的站源实现 SourceRankings 即可。
type SourceRankingEntries interface {
	RankingEntries(ctx context.Context, board string, page int) ([]RankingEntry, bool, error)
}

// SourceCategoryLess 表示站源自身不提供分类（界面上只有「全部」）。
// 运行时据此不再报「站源暂未返回内容分类」。
type SourceCategoryLess interface {
	CategoryLess() bool
}

// SourceHost 是站源访问运行时的唯一入口。
type SourceHost interface {
	// BaseURL 返回站源的站点地址（设置里配过就用配置，否则用内置默认）。
	BaseURL(source string) string
	// FetchText 抓取纯文本，referer 为空时用请求地址本身；userAgent / cookie 为空时不附加。
	FetchText(ctx context.Context, address, referer, userAgent, cookie string) (string, error)
	// FetchPage 抓取并解析 HTML，返回文档与（跟随重定向后的）最终地址。
	FetchPage(ctx context.Context, address, referer, userAgent, cookie string) (*xhtml.Node, string, error)
	// PrepareWebMedia 校验网页源给出的播放地址，m3u8 会预取播放列表。
	PrepareWebMedia(ctx context.Context, media ProviderMedia, sourceName string) (ProviderMedia, error)
	// HTTPClient 返回运行时配置好的标准客户端（代理、DoH、TLS 信任库已就位）。
	// 站源可以复制它的 Transport 发自定义请求，但不要改它的字段。
	HTTPClient() *http.Client
	// Limiter 返回运行时的请求限流器，未启用时返回 nil。
	Limiter() RequestLimiter
	// CatalogResponseError 把站点的错误响应转成可读错误（含被拦截判定）。
	CatalogResponseError(request *http.Request, response *http.Response, body []byte) error
	// ConfigURL 返回设置里给该站源配的自定义地址，未配置时为空。
	ConfigURL(source string) string
	// ConfigAPIURL 返回设置里给该站源配的接口地址（如黄剧 api、野果 api）。
	ConfigAPIURL(source string) string
	// DuanjuBaseURL 返回短剧家族站源的接口地址。
	DuanjuBaseURL(source string) string
	// DuanjuJSON 用短剧家族的客户端发请求并解出 JSON。
	DuanjuJSON(ctx context.Context, request DuanjuRequest) (map[string]any, error)
	// DuanjuDo 同 DuanjuJSON，但返回原始响应体。
	DuanjuDo(ctx context.Context, request DuanjuRequest) ([]byte, error)
	// MaccmsCatalogPage / MaccmsDetail / MaccmsSearch 是运行时的 MacCMS 通用引擎。
	// 内置的 MacCMS 短剧站与自定义 MacCMS 源共用这套解析，站源只负责声明自己的地址与分类。
	MaccmsCatalogPage(ctx context.Context, source string, page int, category string) ([]Drama, bool, error)
	MaccmsDetail(ctx context.Context, source, sourceID string) (Drama, []Chapter, error)
	MaccmsSearch(ctx context.Context, source, query string) ([]Drama, error)
	// DuanjuResolveMedia 用运行时里的短剧通用取流逻辑解析播放地址。
	// 站源不需要自定义取流时，ResolveMedia 直接转调它即可。
	DuanjuResolveMedia(ctx context.Context, task Task) (ProviderMedia, error)
	// BrowserPostJSON 用带 Chrome 指纹与独立 Cookie 会话的客户端发 POST，
	// headers 按传入顺序写入（部分站点会校验头部顺序）。
	BrowserPostJSON(ctx context.Context, address string, headers [][2]string, body []byte, timeout time.Duration) (int, []byte, error)
	// DoPrepared 执行一个已经组装好的请求，经运行时的限流与超时管理。
	// 响应体读完必须关闭；timeout<=0 表示用运行时默认。
	DoPrepared(ctx context.Context, request *http.Request, timeout time.Duration) (*http.Response, error)
	// RememberHost 记录站源当前可用的站点地址（域名轮换后封面 / 取流要用）。
	RememberHost(source, host string)
	// LegacySettings 返回 legacy 家族（黄果旧接口）的账号、协议与取流配置。
	LegacySettings() LegacySettings
	// APIEndpoint 返回 legacy 家族的接口根地址，运行时会做域名健康度轮换。
	APIEndpoint(ctx context.Context) (string, error)
	// ResetAPIEndpoint 让运行时把某个接口根地址标记为不可用并换下一个。
	ResetAPIEndpoint(base string)
	// PostJSON 以 POST 发送 JSON 载荷并返回响应文本（走站源的镜像候选与限流）。
	PostJSON(ctx context.Context, address, referer string, payload []byte) (string, error)
	// ForgetHost 忘掉记住的站点地址，下次请求重新选路（会话失效时换镜像用）。
	ForgetHost(source string)
	// FetchTextFinal 抓取文本并返回跟随重定向后的最终地址。
	// 有些站点的播放页会跳转到另一个域名，取流必须用跳转后的地址当 Referer。
	FetchTextFinal(ctx context.Context, address, referer, userAgent, cookie string) (string, string, error)
	// FetchMediaPlaylist 取一个播放列表（会解开 legacy 接口的 JSON 信封），
	// 返回列表文本与（跟随重定向后的）最终地址。
	FetchMediaPlaylist(ctx context.Context, address, referer string) (string, string, error)
	// StateDir 返回应用数据目录。站源在这里存取登录态 / 访客会话等需要跨启动保留的小文件，
	// 不要写缓存（缓存另有清理流程）。返回空串表示当前运行时不支持持久化。
	StateDir() string
}

var sourceRegistry = struct {
	sync.RWMutex
	factories   map[string]func(SourceHost) SourceProvider
	descriptors map[string]SourceDescriptor
	order       []string
}{
	factories:   map[string]func(SourceHost) SourceProvider{},
	descriptors: map[string]SourceDescriptor{},
}

// RegisterSource 由站源模块在 init 里调用。ID 重复或为空直接 panic：
// 编译期拼装的站源本来就该在出包时暴露冲突，而不是装到设备上才出错。
func RegisterSource(descriptor SourceDescriptor, factory func(SourceHost) SourceProvider) {
	if descriptor.ID == "" {
		panic("core: 站源描述缺少 ID")
	}
	if factory == nil {
		panic("core: 站源 " + descriptor.ID + " 缺少工厂函数")
	}
	sourceRegistry.Lock()
	defer sourceRegistry.Unlock()
	if _, exists := sourceRegistry.factories[descriptor.ID]; exists {
		panic("core: 站源 ID 重复: " + descriptor.ID)
	}
	sourceRegistry.factories[descriptor.ID] = factory
	sourceRegistry.descriptors[descriptor.ID] = descriptor
	sourceRegistry.order = append(sourceRegistry.order, descriptor.ID)
}

// unregisterSource 只给测试用：正式构建的站源集合是编译期固定的，运行期不卸载。
func unregisterSource(id string) {
	sourceRegistry.Lock()
	defer sourceRegistry.Unlock()
	delete(sourceRegistry.factories, id)
	delete(sourceRegistry.descriptors, id)
	for index, value := range sourceRegistry.order {
		if value == id {
			sourceRegistry.order = append(sourceRegistry.order[:index], sourceRegistry.order[index+1:]...)
			break
		}
	}
}

// RegisteredSources 返回当前二进制里编入的站源描述符，按注册顺序。
func RegisteredSources() []SourceDescriptor {
	sourceRegistry.RLock()
	defer sourceRegistry.RUnlock()
	out := make([]SourceDescriptor, 0, len(sourceRegistry.order))
	for _, id := range sourceRegistry.order {
		out = append(out, sourceRegistry.descriptors[id])
	}
	return out
}

// sourceProvider 取（并按需实例化）某个站源的实现，未编入返回 false。
func (d *Downloader) sourceProvider(source string) (SourceProvider, bool) {
	source = canonicalProviderSource(source)
	sourceRegistry.RLock()
	factory, ok := sourceRegistry.factories[source]
	sourceRegistry.RUnlock()
	if !ok {
		// 注册表优先；番茄在 core 里有内置实现，未编入外置站源模块时
		// 回落到这里（红果鉴 / 不带 --sources 的构建），目录、搜索、
		// 详情、取流、分类五条派发由此一并打通。
		return d.fanqieBuiltinSource(source)
	}
	d.sourceProviderMu.Lock()
	defer d.sourceProviderMu.Unlock()
	if provider, exists := d.sourceProviders[source]; exists {
		return provider, true
	}
	provider := factory(downloaderSourceHost{d: d})
	if d.sourceProviders == nil {
		d.sourceProviders = map[string]SourceProvider{}
	}
	d.sourceProviders[source] = provider
	return provider, true
}

// downloaderSourceHost 把 Downloader 的能力收敛成站源可用的 Host。
type downloaderSourceHost struct {
	d *Downloader
}

func (h downloaderSourceHost) BaseURL(source string) string {
	return h.d.providerBaseURL(source)
}

func (h downloaderSourceHost) FetchText(ctx context.Context, address, referer, userAgent, cookie string) (string, error) {
	if userAgent != "" {
		ctx = context.WithValue(ctx, providerTextUserAgentKey{}, userAgent)
	}
	if cookie != "" {
		ctx = context.WithValue(ctx, providerTextCookieKey{}, cookie)
	}
	return h.d.fetchProviderText(ctx, address, referer)
}

func (h downloaderSourceHost) PostJSON(ctx context.Context, address, referer string, payload []byte) (string, error) {
	return h.d.fetchProviderRequest(ctx, address, referer, payload)
}

func (h downloaderSourceHost) ForgetHost(source string) {
	h.d.providerMu.Lock()
	delete(h.d.providerHosts, canonicalProviderSource(source))
	h.d.providerMu.Unlock()
}

func (h downloaderSourceHost) FetchTextFinal(ctx context.Context, address, referer, userAgent, cookie string) (string, string, error) {
	if userAgent != "" {
		ctx = context.WithValue(ctx, providerTextUserAgentKey{}, userAgent)
	}
	if cookie != "" {
		ctx = context.WithValue(ctx, providerTextCookieKey{}, cookie)
	}
	responses := &playbackResponseURLs{}
	body, err := h.d.fetchProviderText(context.WithValue(ctx, playbackResponseURLsKey{}, responses), address, referer)
	if err != nil {
		return "", "", err
	}
	final := address
	if actual, ok := responses.values.Load(address); ok {
		if text, valid := actual.(string); valid && text != "" {
			final = text
		}
	}
	return body, final, nil
}

func (h downloaderSourceHost) FetchPage(ctx context.Context, address, referer, userAgent, cookie string) (*xhtml.Node, string, error) {
	if cookie != "" {
		ctx = context.WithValue(ctx, providerTextCookieKey{}, cookie)
	}
	return h.d.fetchProviderPage(ctx, address, referer, userAgent)
}

func (h downloaderSourceHost) PrepareWebMedia(ctx context.Context, media ProviderMedia, sourceName string) (ProviderMedia, error) {
	return h.d.prepareWebProviderMedia(ctx, media, sourceName)
}

type sourceLimiter struct{ limiter *requestLimiter }

func (l sourceLimiter) Acquire(ctx context.Context, request *http.Request) (func(), error) {
	return l.limiter.acquire(ctx, request)
}

func (l sourceLimiter) Observe(request *http.Request, response *http.Response) {
	l.limiter.observe(request, response)
}

// RequestLimiter 是运行时限流器的站源视图。
type RequestLimiter interface {
	Acquire(ctx context.Context, request *http.Request) (func(), error)
	Observe(request *http.Request, response *http.Response)
}

func (h downloaderSourceHost) HTTPClient() *http.Client { return h.d.client }

func (h downloaderSourceHost) Limiter() RequestLimiter {
	if h.d.limiter == nil {
		return nil
	}
	return sourceLimiter{limiter: h.d.limiter}
}

func (h downloaderSourceHost) CatalogResponseError(request *http.Request, response *http.Response, body []byte) error {
	return h.d.catalogResponseError(request, response, body)
}

func (h downloaderSourceHost) ConfigURL(source string) string {
	switch canonicalProviderSource(source) {
	case sourceHuangju:
		return h.d.cfg.HuangjuURL
	case sourceYeguo:
		return h.d.cfg.YeguoURL
	case sourceJinguoDuanju:
		return h.d.cfg.JinguoDuanjuURL
	case sourceDSD:
		return h.d.cfg.DSDURL
	case sourceSorani:
		return h.d.cfg.SoraniURL
	case sourceFanqie:
		return h.d.cfg.FanqieURL
	case sourceHongguo:
		return h.d.cfg.HongguoURL
	case sourceHuangdou:
		return h.d.cfg.HuangdouURL
	case sourceHuangguoAI:
		return h.d.cfg.HuangguoAIURL
	case sourceHuangguoVideo:
		return h.d.cfg.HuangguoVideoURL
	case sourceBeabox:
		return h.d.cfg.BeaboxURL
	}
	return ""
}

func (h downloaderSourceHost) ConfigAPIURL(source string) string {
	switch canonicalProviderSource(source) {
	case sourceHuangju:
		return h.d.cfg.HuangjuAPIURL
	case sourceYeguo:
		return h.d.cfg.YeguoAPIURL
	case sourceSorani:
		return h.d.cfg.SoraniAPIURL
	}
	return ""
}

func (h downloaderSourceHost) DuanjuBaseURL(source string) string {
	return h.d.duanjuBaseURL(source)
}

func (h downloaderSourceHost) DuanjuJSON(ctx context.Context, request DuanjuRequest) (map[string]any, error) {
	return h.d.duanjuJSON(ctx, request)
}

func (h downloaderSourceHost) DuanjuDo(ctx context.Context, request DuanjuRequest) ([]byte, error) {
	return h.d.duanjuDo(ctx, request)
}

func (h downloaderSourceHost) MaccmsCatalogPage(ctx context.Context, source string, page int, category string) ([]Drama, bool, error) {
	return h.d.fetchMaccmsCatalogPage(ctx, source, page, category)
}

func (h downloaderSourceHost) MaccmsDetail(ctx context.Context, source, sourceID string) (Drama, []Chapter, error) {
	return h.d.fetchMaccmsDetail(ctx, source, sourceID)
}

func (h downloaderSourceHost) MaccmsSearch(ctx context.Context, source, query string) ([]Drama, error) {
	return h.d.searchMaccms(ctx, source, query)
}

func (h downloaderSourceHost) DuanjuResolveMedia(ctx context.Context, task Task) (ProviderMedia, error) {
	return h.d.resolveDuanjuMedia(ctx, task)
}

func (h downloaderSourceHost) BrowserPostJSON(ctx context.Context, address string, headers [][2]string, body []byte, timeout time.Duration) (int, []byte, error) {
	return h.d.browserPostJSON(ctx, address, headers, body, timeout)
}

func (h downloaderSourceHost) DoPrepared(ctx context.Context, request *http.Request, timeout time.Duration) (*http.Response, error) {
	if ctx != nil && request.Context() != ctx {
		request = request.WithContext(ctx)
	}
	return h.d.doPreparedCatalogRequest(request, timeout, nil)
}

func (h downloaderSourceHost) StateDir() string { return h.d.cfg.dataDir }

func (h downloaderSourceHost) RememberHost(source, host string) {
	host = strings.TrimRight(strings.TrimSpace(host), "/")
	if host == "" {
		return
	}
	h.d.providerMu.Lock()
	if h.d.providerHosts == nil {
		h.d.providerHosts = map[string]string{}
	}
	h.d.providerHosts[canonicalProviderSource(source)] = host
	h.d.providerMu.Unlock()
}

// RandomHex 返回 n 字节随机数的十六进制文本，取不到随机源时返回空串。
func RandomHex(n int) string { return randomHex(n) }

// M3U8Duration 统计播放列表的总时长（读不出时返回 0）。
func M3U8Duration(playlist string) time.Duration { return m3u8Duration(playlist) }

// LegacyFrontendURL 是 legacy 家族的官网地址（Origin / Referer 与前端脚本的来源）。
const LegacyFrontendURL = legacyFrontendURL

// LegacySettings 是 legacy 家族（黄果旧接口）的账号、协议与取流配置。
// 这些字段来自用户在设置里填的登录令牌 / 自定义参数，站源不能自己造。
type LegacySettings struct {
	Token        string
	InterfaceKey string
	ParamKey     string
	ParamIV      string
	APIBase      string
	// CDNURL 已填好默认值，站源直接拼到取流地址里。
	CDNURL    string
	AESKeyHex string
	Retries   int
	PageSize  int
	// SessionScope 是访客会话的作用域：接口根地址变了，旧会话就不该复用。
	SessionScope string
}

func (h downloaderSourceHost) LegacySettings() LegacySettings {
	return LegacySettings{
		Token:        h.d.cfg.Token,
		InterfaceKey: h.d.cfg.InterfaceKey,
		ParamKey:     h.d.cfg.ParamKey,
		ParamIV:      h.d.cfg.ParamIV,
		APIBase:      h.d.cfg.APIBase,
		CDNURL:       firstNonEmpty(h.d.cfg.CDNURL, defaultCDNURL),
		AESKeyHex:    h.d.cfg.AESKeyHex,
		Retries:      h.d.cfg.Retries,
		PageSize:     h.d.cfg.PageSize,
		SessionScope: strings.TrimRight(firstNonEmpty(h.d.cfg.APIBase, defaultAPIBase), "/"),
	}
}

func (h downloaderSourceHost) APIEndpoint(ctx context.Context) (string, error) {
	return h.d.apiEndpoint(ctx)
}

func (h downloaderSourceHost) ResetAPIEndpoint(base string) { h.d.resetAPIEndpoint(base) }

func (h downloaderSourceHost) FetchMediaPlaylist(ctx context.Context, address, referer string) (string, string, error) {
	return h.d.fetchMediaPlaylist(ctx, address, referer)
}

// ---- 站源可用的类型与工具（core 内部仍用未导出名，这里只做别名/转发）----

type (
	// NativeCategory 是界面用的分类条目。
	NativeCategory = nativeCategory
	// ProviderMedia 是站源解析出的播放地址。
	ProviderMedia = providerMedia
)

const (
	// SourceA123 是 A123（w4 模板网页源）的站源 ID。
	SourceA123 = sourceA123
	// SourceGuipian 是鬼片网（网页源）的站源 ID。
	SourceGuipian = sourceGuipian
	// SourceIkanbot 是爱看机器人（聚合搜索网页源）的站源 ID。
	SourceIkanbot = sourceIkanbot
	// SourceTheporny 是 Theporny（TLS 指纹站）的站源 ID。
	SourceTheporny = sourceTheporny
	// SourceHeitao 是黑桃（MacCMS 网页源）的站源 ID。
	SourceHeitao = sourceHeitao
	// SourceHanxiaoquan 是韩小圈（网页源）的站源 ID。
	SourceHanxiaoquan = sourceHanxiaoquan
	// SourceXChina 是 XChina（加密接口源）的站源 ID。
	SourceXChina = sourceXChina
	// SourceHeguo 是河果（Next.js 站点）的站源 ID。
	SourceHeguo = sourceHeguo
)

// WebProviderNumericID 匹配网页源常用的纯数字站内 ID。
var WebProviderNumericID *regexp.Regexp = webProviderNumericID

// Truncate 按字符数截断，站源用来收敛标题/简介长度。
func Truncate(s string, n int) string { return truncate(s, n) }

// DuanjuPlainText 去掉 HTML 标签与多余空白。
func DuanjuPlainText(raw string) string { return duanjuPlainText(raw) }

// MaccmsDetailIntro 从已解析的详情页文档里取剧情简介。
func MaccmsDetailIntro(document *xhtml.Node) string { return maccmsDetailIntro(document) }

// ProviderDramaID 拼剧集 ID，格式写进用户数据后不可改。
func ProviderDramaID(source, sourceID string) string { return providerDramaID(source, sourceID) }

// ProviderChapterID 拼分集 ID。
func ProviderChapterID(source, sourceID, chapterKey string) string {
	return providerChapterID(source, sourceID, chapterKey)
}

// SplitProviderDramaID 拆剧集 ID 为站源与站内 ID。
func SplitProviderDramaID(id string) (source, sourceID string, ok bool) {
	return splitProviderDramaID(id)
}

// RawEpisode 生成章节的集号字段。
func RawEpisode(n int) json.RawMessage { return rawEpisode(n) }

// IsProviderHTTPMediaURL 判断地址是否是可播放的 http(s) 地址。
func IsProviderHTTPMediaURL(raw string) bool { return isProviderHTTPMediaURL(raw) }

// SortProviderChapters 按集号稳定排序。
func SortProviderChapters(chapters []Chapter) { sortProviderChapters(chapters) }

// UniqueChapters 去掉重复分集。
func UniqueChapters(chapters []Chapter) []Chapter { return uniqueChapters(chapters) }

// ValidNativeCoverURL 判断封面地址是否可用（过滤 data:、内网等）。
func ValidNativeCoverURL(address *url.URL) bool { return validNativeCoverURL(address) }

// DecodeHongguoBase64 解红果系接口常用的 base64 变体。
func DecodeHongguoBase64(value string) ([]byte, error) { return decodeHongguoBase64(value) }

// PKCS7Unpad 去 PKCS#7 填充。
func PKCS7Unpad(data []byte, blockSize int) ([]byte, error) { return pkcs7Unpad(data, blockSize) }

// ProviderMaxBodyBytes 是站源响应体的上限，超过视为异常。
const ProviderMaxBodyBytes = providerMaxBodyBytes

// MediaCredentials 是播放请求要带的临时凭证。
type MediaCredentials = providerMediaCredentials

// NewMediaCredentials 构造播放凭证；站源只填自己知道的字段，其余留空。
func NewMediaCredentials(cookie, origin, referer, userAgent string, expires time.Time) MediaCredentials {
	return providerMediaCredentials{cookie: cookie, origin: origin, referer: referer, userAgent: userAgent, expires: expires}
}

// WithMediaCredentials 给播放地址挂上临时凭证。
func WithMediaCredentials(media ProviderMedia, credentials MediaCredentials) ProviderMedia {
	media.credentials = &credentials
	return media
}

// DuanjuRequest 是短剧家族引擎的请求描述。
type DuanjuRequest = duanjuRequest

// DuanjuStaticCategories 返回站源的固定分类。
func DuanjuStaticCategories(source string) []NativeCategory {
	static, found := duanjuStaticCategories[canonicalProviderSource(source)]
	if !found {
		return nil
	}
	out := make([]NativeCategory, 0, len(static))
	for _, entry := range static {
		out = append(out, NativeCategory{ID: entry.ID, Name: entry.Name})
	}
	return out
}

// ValidDuanjuCategory 校验短剧家族的分类 ID。
func ValidDuanjuCategory(source, category string) bool { return validDuanjuCategory(source, category) }

// DuanjuFindString 按候选键取字符串。
func DuanjuFindString(node map[string]any, keys ...string) string {
	return duanjuFindString(node, keys...)
}

// DuanjuFindInt 按候选键取整数。
func DuanjuFindInt(node map[string]any, keys ...string) int { return duanjuFindInt(node, keys...) }

// DuanjuFindMap 按候选键取子对象。
func DuanjuFindMap(node map[string]any, keys ...string) map[string]any {
	return duanjuFindMap(node, keys...)
}

// DuanjuFindList 按候选键取数组。
func DuanjuFindList(node map[string]any, keys ...string) []any { return duanjuFindList(node, keys...) }

// DuanjuFindBool 按候选键取布尔值。
func DuanjuFindBool(node map[string]any, keys ...string) bool { return duanjuFindBool(node, keys...) }

// DuanjuStringList 把任意值读成字符串数组。
func DuanjuStringList(value any) []string { return duanjuStringList(value) }

// DuanjuCSV 把字符串数组拼成逗号串。
func DuanjuCSV(values []string) string { return duanjuCSV(values) }

// DuanjuCover 从对象里取封面并补全相对地址。
func DuanjuCover(base string, node map[string]any, keys ...string) string {
	return duanjuCover(base, node, keys...)
}

// DuanjuSourceName 返回站源显示名。
func DuanjuSourceName(source string) string { return duanjuSourceName(source) }

// DuanjuAbsolute 把相对地址补成绝对地址。
func DuanjuAbsolute(base, reference string) string { return duanjuAbsolute(base, reference) }

// DuanjuQueryEscape 转义查询参数。
func DuanjuQueryEscape(value string) string { return duanjuQueryEscape(value) }

// DuanjuChapter 组装一集。
func DuanjuChapter(source, sourceID string, number int, title, videoURL, pageURL, referer string) Chapter {
	return duanjuChapter(source, sourceID, number, title, videoURL, pageURL, referer)
}

// DuanjuHeguoSearchPath / PName / SourceType 是河果搜索接口的固定参数。
const (
	DuanjuHeguoSearchPath       = heguoSearchPath
	DuanjuHeguoSearchPName      = heguoSearchPName
	DuanjuHeguoSearchSourceType = heguoSearchSourceType
)

// DuanjuFormatCount 把集数/播放量格式化成界面文案。
func DuanjuFormatCount(value int) string { return duanjuFormatCount(value) }

// DuanjuReleaseStatus 由总集数与当前集算出更新状态。
func DuanjuReleaseStatus(raw string, total, current int) string {
	return duanjuReleaseStatus(raw, total, current)
}

// SortDuanjuChapters 按集号排序章节。
func SortDuanjuChapters(chapters []Chapter) { sortDuanjuChapters(chapters) }

// CanonicalProviderSource 把站源别名归一到站源 ID。
func CanonicalProviderSource(source string) string { return canonicalProviderSource(source) }

// AnyList 把任意值当成数组读出来（兼容 list/items/data 包装）。
func AnyList(value any) []any { return anyList(value) }

// HTMLAttr 读节点属性。
func HTMLAttr(node *xhtml.Node, name string) string { return providerHTMLAttr(node, name) }

// HTMLClass 判断节点是否带某个 class。
func HTMLClass(node *xhtml.Node, name string) bool { return providerHTMLClass(node, name) }

// HTMLNodes 收集满足条件的节点。
func HTMLNodes(root *xhtml.Node, match func(*xhtml.Node) bool) []*xhtml.Node {
	return providerHTMLNodes(root, match)
}

// HTMLFirstClass 找第一个带指定 class 的节点。
func HTMLFirstClass(root *xhtml.Node, names ...string) *xhtml.Node {
	return providerHTMLFirstClass(root, names...)
}

// HTMLText 取节点纯文本（压缩空白）。
func HTMLText(root *xhtml.Node) string { return providerHTMLText(root) }

// CoverAddress 把封面值（字符串/数组/对象）解析成绝对地址。
func CoverAddress(value any, pageURL string) string { return providerCoverAddress(value, pageURL) }

// DsdRouteParameters 解析 MacCMS 路由参数（show/type/detail/play）。
func DsdRouteParameters(pageURL, reference string) (string, map[string]string, bool) {
	return dsdRouteParameters(pageURL, reference)
}

// ResolveProviderURL 把相对地址补成绝对地址。
func ResolveProviderURL(baseURL, ref string) string { return resolveProviderURL(baseURL, ref) }

// ProviderMediaOrigin 返回媒体的 scheme://host。
func ProviderMediaOrigin(address *url.URL) string { return providerMediaOrigin(address) }

// PublicError 去掉内部细节，只留可展示给用户的错误文案。
func PublicError(err error) error { return publicError(err) }

// CatalogBlockedReason 返回站点响应被判为「拦截页」的原因，空串表示正常。
func CatalogBlockedReason(response *http.Response, body []byte) string {
	return catalogResponseBlockReason(response, body)
}

// IsBackgroundCatalogContext 判断当前请求是否来自后台预热。
func IsBackgroundCatalogContext(ctx context.Context) bool {
	background, _ := ctx.Value(backgroundCatalogKey{}).(bool)
	return background
}

// BackgroundCatalogContext 标记「后台预热」请求，限流器对这类请求让步。
func BackgroundCatalogContext(ctx context.Context) context.Context {
	return context.WithValue(ctx, backgroundCatalogKey{}, true)
}

// WebProviderInteger 把任意值读成整数（超过 maximum 视为无效）。
func WebProviderInteger(value any, maximum int) (int, bool) {
	return webProviderInteger(value, maximum)
}

// NormalizeViews 把播放量文本规范化成「N万次播放」。
func NormalizeViews(value string) string { return normalizeViews(value) }

// ProviderReleaseDate 从发布日期里抽 YYYY-MM-DD。
func ProviderReleaseDate(value string) string { return providerReleaseDate(value) }

// SourceForURL 反查某个地址属于哪个站源（认不出返回空）。
func SourceForURL(raw string) string { return providerSourceForURL(raw) }

// NoCacheContext 让本次抓取跳过运行时缓存（用于发现类请求）。
func NoCacheContext(ctx context.Context) context.Context {
	return context.WithValue(ctx, providerTextNoCacheKey{}, true)
}

// IsBackoffError 判断错误是否来自运行时的「退避」（限流 / 403 冷却）。
func IsBackoffError(err error) bool {
	var backoff *requestBackoff
	return errors.As(err, &backoff)
}

// CleanText 把文本里的空白与零宽字符压平。
func CleanText(value string) string { return cleanText(value) }

// UserAgent 是运行时默认的移动端 UA，站源没特殊要求时直接用它。
const UserAgent = userAgent

// FirstNonEmpty 返回第一个非空字符串。
func FirstNonEmpty(values ...string) string { return firstNonEmpty(values...) }

// ---- legacy 家族（黄果 / 云栈 / 禁果）共用的协议与数据形状 ----

// LegacyCipher 是 legacy 家族接口的加解密参数：
// 请求参数用 ParamKey/ParamIV 做 AES-CBC，响应体用 InterfaceKey 派生的密钥解密。
type LegacyCipher struct {
	InterfaceKey string
	ParamKey     string
	ParamIV      string
}

// EncryptParams 把请求参数加密成接口要求的 data 字段。
func (cipher LegacyCipher) EncryptParams(params any) (string, error) {
	return encryptParam(params, []byte(cipher.ParamKey), []byte(cipher.ParamIV))
}

// DecryptResponse 解密接口返回的 data 字段。
func (cipher LegacyCipher) DecryptResponse(data string) ([]byte, error) {
	return decryptResponse(data, []byte(cipher.InterfaceKey))
}

// Valid 判断这套加解密参数是否完整可用。
func (cipher LegacyCipher) Valid() bool {
	return validLegacyProtocol(legacyProtocol{
		InterfaceKey: cipher.InterfaceKey, ParamKey: cipher.ParamKey, ParamIV: cipher.ParamIV,
	})
}

// LegacyEnvelope 是 legacy 家族统一的响应信封。
type LegacyEnvelope struct {
	Code json.RawMessage `json:"code"`
	Msg  string          `json:"msg"`
	Hash json.RawMessage `json:"hash"`
	Data json.RawMessage `json:"data"`
}

// LegacyEnvelopeCode 返回信封里的状态码（去掉可能的引号）。
func LegacyEnvelopeCode(envelope LegacyEnvelope) string {
	return strings.Trim(string(envelope.Code), `"`)
}

// LegacyEnvelopeEncrypted 判断信封的 data 是否经过二次加密。
func LegacyEnvelopeEncrypted(envelope LegacyEnvelope) bool { return apiHashEnabled(envelope.Hash) }

// IsLegacySessionExpired 判断错误是否为 legacy 家族的「访客会话失效」（业务码 5005）。
// 站源拿到它应当清掉本地令牌后重试一次。
func IsLegacySessionExpired(err error) bool {
	var apiErr *legacyAPIError
	return errors.As(err, &apiErr) && apiErr.code == "5005"
}

// LegacyDetail 是 legacy 家族详情/列表行的宽松解码结果：
// 把十几种封面、集数、简介字段名都收敛到 Drama 上。
type LegacyDetail = detailResponse

// LegacyTabList 兼容 legacy 家族分类接口的两种返回形态（裸数组与 {list:[]}）。
type LegacyTabList = legacyTabList

// LegacyCoverURL 从任意封面字段里取一个可用的封面地址。
func LegacyCoverURL(value any) string { return legacyCoverURL(value) }

// ChapterEpisodeNumber 读分集自己的集数，读不到用 fallback。
func ChapterEpisodeNumber(chapter Chapter, fallback int) int {
	return chapterEpisodeNumber(chapter, fallback)
}

// ReleaseStatusFromRemark 从「更新至 N 集 / 全 24 集 / 已完结」这类备注里判定更新状态。
func ReleaseStatusFromRemark(remark string) string { return releaseStatusFromRemark(remark) }

// MapString 按候选键从 map 里读字符串；数字与布尔会转成文本（接口常把 ID 给成数字）。
func MapString(node map[string]any, keys ...string) string { return mapString(node, keys...) }

// MapStringSlice 按候选键从 map 里读字符串数组。
func MapStringSlice(node map[string]any, keys ...string) []string {
	return mapStringSlice(node, keys...)
}

// NormalizeProviderMediaURL 把站源给的相对播放地址按页面地址补全。
func NormalizeProviderMediaURL(pageURL, raw string) string {
	return normalizeProviderMediaURL(pageURL, raw)
}

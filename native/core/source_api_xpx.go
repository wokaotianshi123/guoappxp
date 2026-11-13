package core

// 本文件提供与 guoappxpx 外置源仓库一致的「SourceAPI1」契约：那边私有外置源
// 包里的 .go 文件用 core.Register / core.Host / core.Provider / core.Category
// 等符号，原样放进 guoapp-sources 模块即可编译。
//
// 这是唯一的站源契约：旧 SourceProvider/SourceHost 已删除，core 内部一切派发
// （目录、搜索、详情、取流、分类、榜单、账号）都经 sourceProvider() 取 Provider。

import (
	"context"
	"errors"
	"net/http"
	"time"

	xhtml "golang.org/x/net/html"
)

// SourceAPI1 是契约版本标记，外置源可用 `var _ core.SourceAPI1` 声明依赖。
type SourceAPI1 struct{}

// Category 与运行时内部的 nativeCategory 是同一类型，字段 {ID, Name}。
type Category = nativeCategory

// LibraryKnownKey 用于从 ctx 取「本页已知剧集」集合，避免连续信息流重复。
// 与运行时内部 libraryKnownKey 是同一类型，因此两种契约共用同一个 ctx value。
type LibraryKnownKey = libraryKnownKey

var ErrSourceLogin = errors.New("站源需要登录")

type SourceLoginError string

func (err SourceLoginError) Error() string { return string(err) }
func (err SourceLoginError) Is(target error) bool {
	return target == ErrSourceLogin
}

// TextRequest / TextResponse 是外置源发起文本请求的参数与结果。
type TextRequest struct {
	URL       string
	Referer   string
	UserAgent string
	Cookie    string
	NoCache   bool
	Body      []byte
}

type TextResponse struct {
	Body string
	URL  string
}

type HTTPRequest struct {
	Label   string
	Method  string
	URL     string
	Header  map[string]string
	Body    []byte
	Limit   int64
	Timeout time.Duration

	AcceptJSONStatus []int
	FollowRedirects  bool
	AnyStatus        bool
	Direct           bool
	Ticket           uint64
}

type HTTPResponse struct {
	Status    int
	Header    map[string][]string
	Body      []byte
	Blocked   bool
	Oversized bool
}

type PlaylistError struct{ Body []byte }

func (*PlaylistError) Error() string {
	return "站源未返回有效的播放列表，链接可能已失效"
}

// RankingBoard 是外置源描述符里可声明的榜单定义。
type RankingBoard struct {
	ID          string
	Source      string
	Name        string
	Description string
	Path        string
	UpstreamKey string
}

// Host 是外置源访问运行时的唯一入口（guoappxpx 契约）。
type Host interface {
	Reserve(ctx context.Context, address, lane string) (uint64, error)
	Retries() int
	MaxPages() int
	Fetch(ctx context.Context, request HTTPRequest) (HTTPResponse, error)
	BaseURL(source string) string
	PreferredSite(source string) string
	RememberSite(source, site string)
	FetchText(ctx context.Context, request TextRequest) (TextResponse, error)
	FetchPlaylist(ctx context.Context, address, referer string, credentials *MediaCredentials) (playlist, finalURL string, err error)
	LoadState(name string) ([]byte, error)
	SaveState(name string, data []byte) error
	PrepareWebMedia(ctx context.Context, media ProviderMedia, sourceName string) (ProviderMedia, error)
	FinishMedia(ctx context.Context, media ProviderMedia, source string) (ProviderMedia, error)
}

// Provider 是外置源必须实现的接口（guoappxpx 契约）。
type Provider interface {
	Descriptor() SourceDescriptor
	Categories(ctx context.Context, force bool) ([]Category, error)
	CatalogPage(ctx context.Context, page int, category string) ([]Drama, bool, error)
	Detail(ctx context.Context, sourceID string) (Drama, []Chapter, error)
	ResolveMedia(ctx context.Context, task Task) (ProviderMedia, error)
}

type ProviderFactory func(host Host) Provider

// RuntimeHost 是 guoappxp 运行时在 guoappxpx Host 之外额外提供的能力集合：
// 短剧通用引擎（Duanju*）、MacCMS 通用引擎（Maccms*）、legacy 旧接口协议、
// 站源状态目录、可配置站点地址等。
//
// 这些方法不属于 guoappxpx 契约——上游源只用 Host 的 13 个方法，因此不会感知
// 到它们；存量源按示例模板改造后若仍需要运行时引擎，用 AsRuntime 取。这样 Host
// 保持与上游一致，同时不必把几千行引擎代码搬进外置模块。
type RuntimeHost interface {
	Host

	FetchPage(ctx context.Context, address, referer, userAgent, cookie string) (*xhtml.Node, string, error)
	HTTPClient() *http.Client
	Limiter() RequestLimiter
	CatalogResponseError(request *http.Request, response *http.Response, body []byte) error
	ConfigURL(source string) string
	ConfigAPIURL(source string) string
	DuanjuBaseURL(source string) string
	DuanjuJSON(ctx context.Context, request DuanjuRequest) (map[string]any, error)
	DuanjuDo(ctx context.Context, request DuanjuRequest) ([]byte, error)
	MaccmsCatalogPage(ctx context.Context, source string, page int, category string) ([]Drama, bool, error)
	MaccmsDetail(ctx context.Context, source, sourceID string) (Drama, []Chapter, error)
	MaccmsSearch(ctx context.Context, source, query string) ([]Drama, error)
	DuanjuResolveMedia(ctx context.Context, task Task) (ProviderMedia, error)
	BrowserPostJSON(ctx context.Context, address string, headers [][2]string, body []byte, timeout time.Duration) (int, []byte, error)
	DoPrepared(ctx context.Context, request *http.Request, timeout time.Duration) (*http.Response, error)
	RememberHost(source, host string)
	LegacySettings() LegacySettings
	APIEndpoint(ctx context.Context) (string, error)
	ResetAPIEndpoint(base string)
	PostJSON(ctx context.Context, address, referer string, payload []byte) (string, error)
	ForgetHost(source string)
	FetchTextFinal(ctx context.Context, address, referer, userAgent, cookie string) (string, string, error)
	FetchMediaPlaylist(ctx context.Context, address, referer string) (string, string, error)
	StateDir() string
}

// AsRuntime 把 guoappxp 的站源 Host 取成 RuntimeHost。不是运行时 Host（例如
// 单元测试里的假 Host）时返回 nil，调用方需自行判断——正常出包路径下永远非 nil。
func AsRuntime(host Host) RuntimeHost {
	runtime, _ := host.(RuntimeHost)
	return runtime
}

// 以下为可选能力，运行时按类型断言使用。

type Searcher interface {
	Search(ctx context.Context, page int, query string) ([]Drama, bool, error)
}

type WarningSearcher interface {
	SearchWithWarning(ctx context.Context, page int, query string) ([]Drama, bool, string, error)
}

type Sited interface {
	BaseURL() string
}

type URLRotator interface {
	URLCandidates(rawURL string) []string
}

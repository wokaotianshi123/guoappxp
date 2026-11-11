package core

import (
	"context"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"runtime/debug"
	"strconv"
	"strings"
	"sync"
	"time"
)

type Config struct {
	dataDir          string
	MaxPagesPerSort  int
	PageSize         int
	Retries          int
	InsecureTLS      bool
	HuangguoAIURL    string
	HuangguoVideoURL string
	HuangdouURL      string
	JinguoDuanjuURL  string
	HeitaoURL        string
	// BeaboxURL 是笔盒的固定线路；留空时按「上次可用线路 → 内置线路 → 发布页发现」顺序取。
	BeaboxURL      string
	HongguoURL     string
	HuangjuURL     string
	HuangjuAPIURL  string
	YeguoURL       string
	YeguoAPIURL    string
	DSDURL         string
	SoraniURL      string
	SoraniAPIURL   string
	GuipianURL     string
	HanxiaoquanURL string
	// FanqieURL 是番茄内容引擎（本机 loopback REST）地址，留空用默认 127.0.0.1:18921。
	FanqieURL    string
	XChinaURL    string
	ThepornyURL  string
	Token        string
	AESKeyHex    string
	InterfaceKey string
	ParamKey     string
	ParamIV      string
	APIBase      string
	CDNURL       string
}

type Downloader struct {
	rankings              rankingCache
	cfg                   Config
	client                *http.Client
	huangdouDetails       map[string]huangdouDetailEntry
	huangdouDetailPending map[string]*huangdouDetailCall
	ikanbotLineCache      map[string]ikanbotLineEntry
	ikanbotLinePending    map[string]*ikanbotLineCall
	providerMu            sync.Mutex
	providerHosts         map[string]string
	beaboxMu              sync.Mutex
	beaboxLoaded          bool
	beaboxSite            string
	beaboxPool            []string
	beaboxPoolNext        time.Time
	beaboxDiscoverMu      sync.Mutex
	limiter               *requestLimiter
	proxyRouter           *proxyRouter
	browserTransport      *huangguoBrowserTransport
	hongguoOnce           sync.Once
	hongguo               *hongguoAppClient
	fanqieMu              sync.Mutex
	fanqieFeeds           map[int]*fanqieFeedState
	xchinaOnce            sync.Once
	xchinaCore            *xchinaClient
	thepornyOnce          sync.Once
	thepornyCore          *thepornyClient
	huangjuOnce           sync.Once
	huangju               *huangjuAPIClient
	yeguoOnce             sync.Once
	yeguo                 *yeguoAPIClient
	jinguoDuanjuOnce      sync.Once
	jinguoDuanju          *jinguoDuanjuAPIClient
	jinguoOnce            sync.Once
	jinguo                *jinguoAPIClient
	soraniOnce            sync.Once
	sorani                *soraniAPIClient
	dsdCatalog            dsdCatalogState
	diagnostics           *diagnosticLog
	apiMu                 sync.Mutex
	apiBase               string
	apiFailures           map[string]time.Time
	legacyOnce            sync.Once
	legacy                *legacyAPIClient
	previewMu             sync.Mutex
	previewSessions       map[string]*huangguoPreviewSession
}

func defaultConfig() Config { return Config{MaxPagesPerSort: 50, PageSize: 30, Retries: 2} }

type nativeDrama struct {
	MetadataSchema int      `json:"metadataSchema"`
	ID             string   `json:"id"`
	Source         string   `json:"source"`
	SourceID       string   `json:"sourceId"`
	Title          string   `json:"title"`
	Description    string   `json:"description"`
	Cover          string   `json:"cover"`
	Episodes       int      `json:"episodes"`
	Category       string   `json:"category"`
	VIP            *bool    `json:"vip"`
	Heat           string   `json:"heat,omitempty"`
	Views          string   `json:"views,omitempty"`
	OnlineDate     string   `json:"onlineDate,omitempty"`
	Tags           []string `json:"tags,omitempty"`
	ReleaseStatus  string   `json:"releaseStatus,omitempty"`
	Badge          string   `json:"badge,omitempty"`
	// Peers 在跨源聚合搜索里带上其它站源的同一部剧，供界面一键切换播放源。
	Peers []nativeDrama `json:"peers,omitempty"`
}

type nativeInput struct {
	SystemProxy     nativeSystemProxy       `json:"systemProxy"`
	Settings        nativeResourceSettings  `json:"settings"`
	JobIDs          []string                `json:"jobIds"`
	Sources         []string                `json:"sources"`
	Search          string                  `json:"search"`
	PlaybackSession string                  `json:"playbackSession"`
	StartMS         int64                   `json:"startMs"`
	DurationMS      int64                   `json:"durationMs"`
	Board           string                  `json:"board"`
	Entries         []nativeDownloadEpisode `json:"entries"`
	JobID           string                  `json:"jobId"`
	Command         string                  `json:"command"`
	Action          string                  `json:"action"`
	Directory       string                  `json:"directory"`
	Source          string                  `json:"source"`
	Name            string                  `json:"name"`
	Base            string                  `json:"base"`
	Rule            string                  `json:"rule"`
	Kind            string                  `json:"kind"`
	Content         string                  `json:"content"`
	Page            int                     `json:"page"`
	Query           string                  `json:"query"`
	Category        string                  `json:"category"`
	Drama           nativeDrama             `json:"drama"`
	Chapter         Chapter                 `json:"chapter"`
	Index           int                     `json:"index"`
	Quality         int                     `json:"quality"`
	Route           int                     `json:"route"`
	Session         string                  `json:"session"`
	Peer            string                  `json:"peer"`
	Sequence        int64                   `json:"sequence"`
	Force           bool                    `json:"force"`
	AdBlock         *bool                   `json:"adBlock"`
	Account         soraniAccountInput      `json:"account"`
	CacheDirectory  string                  `json:"cacheDirectory"`
	// 下载列表增量：Since 是上次拿到的列表指纹，列表没变化时核心只回指纹。
	Since string `json:"since"`
}

type nativeCatalogResult struct {
	Items       []nativeDrama `json:"items"`
	HasMore     bool          `json:"hasMore"`
	Page        int           `json:"page"`
	Warning     string        `json:"warning,omitempty"`
	LocalSearch bool          `json:"localSearch"`
	Fresh       bool          `json:"fresh"`
	hongguo     *hongguoCatalogState
	saveError   error
}

type nativePlan struct {
	ExpiresAt       int64  `json:"expiresAt,omitempty"`
	PrefetchedBytes int64  `json:"prefetchedBytes,omitempty"`
	DanmakuID       string `json:"danmakuId,omitempty"`
	Local           bool   `json:"local"`
	URL             string `json:"url"`
	// DirectURL 是站源返回的原始播放地址（未经本机中转）。投屏时优先用它，
	// 让电视自己去拉流，手机退出 App 也不影响播放。只有不需要本机重写播放
	// 列表、也不需要本机解密分片时才非空；本地文件与加密线路为空。
	DirectURL  string            `json:"directUrl,omitempty"`
	Headers    map[string]string `json:"headers"`
	Key        string            `json:"decryptionKey,omitempty"`
	Quality    int               `json:"quality"`
	Qualities  []int             `json:"qualities"`
	Session    string            `json:"session,omitempty"`
	RouteIndex int               `json:"routeIndex"`
	RouteCount int               `json:"routeCount"`
}

type nativeEngine struct {
	settingsMu       sync.Mutex
	settings         nativeResourceSettings
	readMu           sync.Mutex
	reads            map[string]nativeReadRequest
	readCount        int
	work             map[string]bool
	downloads        *nativeDownloads
	downloader       *Downloader
	directory        string
	mu               sync.Mutex
	catalogs         map[string][]nativeDrama
	catalogStates    map[string]nativeCatalogState
	categoryOptions  map[string][]nativeCategory
	hongguoCatalog   *hongguoCatalogState
	recommendations  map[string]nativeRecommendationState
	catalogSaveError error
	covers           *nativeCoverCache
	stream           *nativeStreamServer
	playbacks        map[string]nativePlaybackChoice
	playbackMu       sync.Mutex
	playbackSequence int64
	playbackCancel   context.CancelFunc
	sourceCatalogMu  sync.Mutex
	sourceCatalogs   map[string]chan struct{}
	customRegistry   *customMaccmsRegistry
	// 跨源聚合搜索的进行中会话：searchStart 建会话，searchPoll 读快照。
	searchMu sync.Mutex
	searches map[string]*nativeSearchSession
}

var nativeState struct {
	sync.Mutex
	engine *nativeEngine
}

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
	case json.Number:
		return string(v)
	case float64:
		return strconv.Itoa(int(v))
	case int:
		return strconv.Itoa(v)
	}
	return ""
}

func nativeNormalize(drama Drama) nativeDrama {
	cover := ""
	for _, value := range []any{drama.Cover, drama.CoverURL, drama.CoverURLSnake, drama.Image, drama.ImageURL, drama.ImageURLSnake, drama.Img, drama.Pic, drama.Picture, drama.Poster, drama.Thumb, drama.Thumbnail} {
		candidate := nativeText(value)
		if strings.HasPrefix(candidate, "//") {
			candidate = "https:" + candidate
		}
		if isProviderHTTPMediaURL(candidate) {
			cover = candidate
			break
		}
	}
	episodes := 0
	for _, value := range []any{drama.TotalEpisode, drama.TotalEpisodeSnake, drama.EpisodeCount, drama.EpisodeCountSnake, drama.ChapterCount, drama.ChapterCountSnake, drama.Total, drama.Episodes} {
		if count, _ := strconv.Atoi(nativeText(value)); count > episodes {
			episodes = count
		}
	}
	source, sourceID, _ := splitProviderDramaID(drama.ID)
	return nativeDrama{MetadataSchema: 1, ID: drama.ID, Source: source, SourceID: sourceID, Title: drama.DisplayTitle(),
		Description: firstNonEmpty(drama.Desc, drama.Intro), Cover: cover, Episodes: episodes,
		Category: nativeDramaCategory(drama), VIP: drama.VIP,
		Heat: drama.Heat, Views: drama.Views, OnlineDate: providerReleaseDate(drama.OnlineDate),
		Tags: append([]string(nil), drama.Tags...), ReleaseStatus: drama.ReleaseStatus, Badge: drama.Badge}
}

func nativeDramaCategory(drama Drama) string {
	category := firstNonEmpty(drama.CategoryName, drama.CategoryNameSnake, drama.TypeName, drama.TypeNameSnake, drama.SortName, drama.SortNameSnake, drama.Category)
	if category != "" {
		return category
	}
	switch drama.ChannelName {
	case "真人剧", "短剧", "漫剧", "AI 剧", "AI剧", "AI 短剧", "AI 漫剧", "AI 换脸", "AI 魔改":
		return drama.ChannelName
	}
	return ""
}

func newNativeEngine(directory string) (*nativeEngine, error) {
	if !filepath.IsAbs(directory) {
		return nil, errors.New("应用数据目录无效")
	}
	if err := os.MkdirAll(directory, 0700); err != nil {
		return nil, err
	}
	cfg := defaultConfig()
	cfg.dataDir = directory
	router := &proxyRouter{}
	d := &Downloader{cfg: cfg, providerHosts: map[string]string{}, proxyRouter: router,
		limiter: newRequestLimiter(3, 250*time.Millisecond), diagnostics: newDiagnosticLog(directory)}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	// RootCAs 设为「系统信任库 + 打包 CA 全集」。通过 dart:ffi / JNI 嵌入时 Go 的
	// crypto/tls 不会加载系统信任库，x509.SystemCertPool() 在 Android 端返回空池，
	// 站源换成 Certum 等小众公共根后 m3u8 分片与海报就会报
	// "tls: failed to verify certificate: x509: certificate signed by unknown
	// authority"。打包 CA 在此提供信任锚；其余平台只是多追加一份，行为不变。
	transport.TLSClientConfig = &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: systemCertPoolWithBundle()}
	transport.MaxIdleConnsPerHost = 8
	transport.ResponseHeaderTimeout = 20 * time.Second
	transport.Proxy = router.proxy
	cdn := newCDNTransport(transport, newDNSResolver(transport))
	// 浏览器指纹传输必须留住引用：自定义源新增/读取时要把自己的 host 登记进
	// 白名单（registerCustomBrowserHost），这里不赋值的话白名单永远是空的，
	// 自定义源与 XBPQ 的页面请求会走普通传输，直接被源站拒掉。
	browserTransport := newHuangguoBrowserTransport(cdn, d)
	d.browserTransport = browserTransport
	d.client = &http.Client{Transport: browserTransport, Timeout: 45 * time.Second,
		CheckRedirect: func(request *http.Request, via []*http.Request) error {
			if len(via) >= 10 {
				return errors.New("站源重定向次数过多")
			}
			if len(via) > 0 && !strings.EqualFold(request.URL.Host, via[0].URL.Host) {
				request.Header.Del("X-Preview-Token")
			}
			return nil
		}}
	engine := &nativeEngine{downloader: d, directory: directory, catalogs: map[string][]nativeDrama{}, catalogStates: map[string]nativeCatalogState{}, searches: map[string]*nativeSearchSession{}}
	engine.loadResourceSettings()
	d.loadRankingCache()
	engine.loadCatalogCache()
	// 自定义源注册表必须在任何站源判定之前就绪：isDuanjuProviderSource /
	// isHuangguoProviderSource 都会回调 customMaccmsSpecFor 查询自定义源，
	// registry 为 nil 时那次查询会直接空指针 panic（表现为「本地核心处理失败」）。
	engine.customRegistry = newCustomMaccmsRegistry(directory)
	engine.customRegistry.load()
	// 已存在的自定义源也要登记进浏览器指纹传输白名单，保证重启后
	// 其目录/页面请求与运行时新增路径一致。
	for _, record := range engine.customMaccmsSources() {
		engine.registerCustomBrowserHost(record.Base)
	}
	engine.covers = newNativeCoverCache(directory, d)
	engine.downloads = newNativeDownloads(engine)
	return engine, nil
}

func NativeRequest(raw string) (result string) {
	defer func() {
		if recovered := recover(); recovered != nil {
			// 这里必须留下堆栈：对外只回「处理失败」，没有堆栈就无从定位。
			// c-shared 下 stderr 已被重定向到 native_stderr.log（见 bridge），
			// 本地服务版则直接打在终端。
			fmt.Fprintf(os.Stderr, "native core panic: %v\n%s\n", recovered, debug.Stack())
			result = `{"ok":false,"error":"本地核心处理失败，请重试"}`
		}
	}()
	var input nativeInput
	if len(raw) > 1<<20 || json.Unmarshal([]byte(raw), &input) != nil {
		return `{"ok":false,"error":"请求格式无效"}`
	}
	data, err := nativeDispatch(input)
	envelope := map[string]any{"ok": err == nil}
	if err != nil {
		envelope["error"] = publicError(err).Error()
		if errors.Is(err, errNativeLocalFile) {
			envelope["code"] = "local_media"
		}
		if errors.Is(err, errSoraniLoginRequired) || errors.Is(err, errSoraniLoginExpired) {
			envelope["code"] = "source_login"
		}
		var backoff *requestBackoff
		if errors.As(err, &backoff) {
			envelope["code"] = "source_blocked"
			envelope["retryAt"] = backoff.until
		}
	} else {
		envelope["data"] = data
	}
	body, marshalErr := json.Marshal(envelope)
	if marshalErr != nil {
		return `{"ok":false,"error":"无法读取站源返回的数据"}`
	}
	return string(body)
}

func nativeDispatch(input nativeInput) (any, error) {
	if err := nativeAuthorizeInput(input); err != nil {
		return nil, err
	}
	nativeState.Lock()
	if input.Action == "initialize" {
		if nativeState.engine == nil {
			engine, err := newNativeEngine(input.Directory)
			if err != nil {
				nativeState.Unlock()
				return nil, err
			}
			nativeState.engine = engine
		}
		nativeState.Unlock()
		return map[string]any{"version": "0.2.17", "standalone": true, "allSources": buildAllSources == "true"}, nil
	}
	engine := nativeState.engine
	nativeState.Unlock()
	if engine == nil {
		return nil, errors.New("应用核心尚未就绪，请重新打开应用")
	}
	duration := 60 * time.Second
	if input.Action == "moveDownloads" {
		duration = 10 * time.Minute
	} else if input.Action == "analyzeCustomSourceSite" {
		// 自动识别要依次抓首页 / 分类页 / 搜索接口 / 详情页，给足预算；
		// 分析器内部另有 45 秒硬预算与请求数上限，不会真的拖到 90 秒。
		duration = 90 * time.Second
	} else if input.Action == "danmaku" {
		duration = 10 * time.Second
	} else if input.Action == "preload" {
		duration = 15 * time.Second
	}
	ctx, cancel := context.WithTimeout(context.Background(), duration)
	defer cancel()
	if input.Action == "danmaku" || input.Action == "preload" || input.Session != "" && (input.Action == "catalog" || input.Action == "categories" || input.Action == "suggestions" || input.Action == "recommendations" || input.Action == "metadata") {
		work, finish, err := engine.beginRead(ctx, input)
		if err != nil {
			return nil, err
		}
		defer finish()
		ctx = work
	}
	switch input.Action {
	case "updateSystemProxy":
		return true, engine.updateSystemProxy(input.SystemProxy)
	case "resourceSettings":
		return engine.resourceSettings(), nil
	case "saveResourceSettings":
		return engine.saveResourceSettings(input.Settings)
	case "controlDownloadBatch":
		return engine.downloads.controlBatch(ctx, input.JobIDs, input.Command)
	case "preload":
		return engine.nativePreload(ctx, input)
	case "danmaku":
		return engine.nativeDanmaku(ctx, input)
	case "cancelRead":
		engine.cancelRead(input)
		return true, nil
	case "recommendations":
		return engine.nativeRecommendations(ctx, input)
	case "cachedRecommendations":
		return engine.cachedRecommendations(input.Category)
	case "rankingBoards":
		boards := []rankingBoard{}
		for _, board := range rankingBoards {
			if nativeSourceAvailable(board.Source) {
				boards = append(boards, board)
			}
		}
		return map[string]any{"items": boards}, nil
	case "rankings":
		return engine.nativeRanking(ctx, input)
	case "suggestions":
		items, err := engine.suggestions(ctx, input.Query)
		return map[string]any{"items": items}, err
	case "audiobookFetch":
		body, err := engine.downloader.fetchAudiobookRaw(ctx, input.Query, input.Content)
		if err != nil {
			return nil, err
		}
		return map[string]any{"body": body}, nil
	case "audiobookText":
		paragraphs, err := engine.downloader.fetchAudiobookText(ctx, input.Category)
		if err != nil {
			return nil, err
		}
		timed := false
		for _, paragraph := range paragraphs {
			if paragraph.Start >= 0 {
				timed = true
				break
			}
		}
		return map[string]any{"paragraphs": paragraphs, "timed": timed}, nil
	case "audiobookMedia":
		media, err := engine.downloader.resolveNovelfmAudio(ctx, input.Query, input.Category)
		if err != nil {
			return nil, err
		}
		return map[string]any{
			"url":           media.URL,
			"decryptionKey": hex.EncodeToString(media.CENCKey),
			"duration":      int(media.Duration.Seconds()),
			"headers":       map[string]string{"Referer": media.Referer, "User-Agent": "com.dragon.read"},
		}, nil
	case "downloadDirectory":
		engine.downloads.mu.Lock()
		root := engine.downloads.root
		engine.downloads.mu.Unlock()
		return map[string]string{"directory": root}, nil
	case "storage":
		return engine.storage()
	case "cacheInfo":
		return engine.cacheInfo(input.CacheDirectory), nil
	case "clearCache":
		return engine.clearCache(input.CacheDirectory)
	case "moveDownloads":
		return true, engine.moveDownloads(ctx, input.Directory)
	case "workLease":
		count, err := engine.workLease(input.JobID, input.Command)
		return map[string]int{"count": count}, err
	case "downloads":
		return engine.downloads.snapshotSince(input.Since)
	case "enqueueDownloads":
		added, err := engine.downloads.enqueueContext(ctx, input)
		return map[string]int{"added": added}, err
	case "controlDownloads":
		return true, engine.downloads.control(input.JobID, input.Command)
	case "beginConversion":
		return engine.downloads.beginConversion(input.JobID)
	case "finishConversion":
		return true, engine.downloads.finishConversion(input.JobID, input.Command)
	case "localPlayback":
		plan, _, err := engine.downloads.localPlan(input.Drama.ID, input.Index)
		return plan, err
	case "catalog":
		return engine.nativeCatalog(ctx, input)
	// 跨源聚合搜索：start 立刻建会话返回，poll 取增量快照，cancel 主动放弃。
	case "searchStart":
		return engine.nativeSearchStart(input)
	case "searchPoll":
		return engine.nativeSearchPoll(input)
	case "searchCancel":
		engine.nativeSearchCancel(input.Search)
		return true, nil
	case "searchAcross":
		return engine.nativeSearchAcross(ctx, input)
	case "cached":
		if !validNativeCategory(canonicalProviderSource(input.Source), input.Category) {
			return nil, errors.New("内容分类无效")
		}
		return engine.nativeCached(nativeCatalogKey(input.Source, input.Category)), nil
	case "categories":
		items, err := engine.nativeCategories(ctx, input.Source, input.Force)
		return map[string]any{"items": items}, err
	case "cover":
		return engine.loadCover(ctx, input.Drama, input.Force)
	case "prepareCover":
		return engine.prepareCover(ctx, input.Drama)
	case "detail":
		return engine.nativeDetail(ctx, input.Drama)
	case "metadata":
		return engine.nativeMetadata(ctx, input.Drama)
	case "followCheck":
		return engine.nativeFollowCheck(ctx, input.Drama)
	case "resolve", "fallback":
		playback, finish, err := engine.nativeBeginPlayback(ctx, input.Sequence)
		if err != nil {
			return nil, err
		}
		defer finish()
		if input.Action == "fallback" {
			return engine.nativeNextPlayback(playback, input.Session)
		}
		return engine.nativeResolve(playback, input)
	case "selectRoute":
		playback, finish, err := engine.nativeBeginPlayback(ctx, input.Sequence)
		if err != nil {
			return nil, err
		}
		defer finish()
		return engine.nativeSelectRoute(playback, input.Session, input.Route)
	case "cancelPlayback":
		engine.nativeCancelPlayback(input.Sequence)
		return true, nil
	case "release":
		engine.nativeReleasePlayback(input.Session)
		return true, nil
	// 投屏：把当前播放会话再挂一份到 0.0.0.0，返回电视能访问的内网基址；
	// 停止投屏时关掉该监听，会话本身不影响本机播放。Peer 是电视地址，
	// 用来确定手机这一侧走哪块网卡（Android 网卡枚举不一定可用）。
	case "castBase":
		base, err := engine.nativeCastBase(input.Peer)
		if err != nil {
			return nil, err
		}
		return map[string]any{"base": base}, nil
	case "closeCast":
		engine.nativeCloseCast()
		return true, nil
	case "customSources":
		return map[string]any{"items": engine.customMaccmsSources()}, nil
	// analyzeCustomSourceSite：新增自定义源时按网页 HTML 自动反推 XBPQ 规则。
	// 只返回规则文本与诊断说明，不写盘；是否保存仍由用户在表单里点「保存」决定。
	case "analyzeCustomSourceSite":
		return engine.downloader.analyzeCustomSourceSite(ctx, input.Base)
	// sourceStatus：本地服务版（native/server）用它判断某个站源在当前构建里是否存在。
	// 授权阶段已用 nativeSourceAvailable 拦掉未编译进来的源，能走到这里即代表可用；
	// 这里不返回 Flutter 端那套任务进度字段（xp 的 core 没有站源任务状态机）。
	case "sourceStatus":
		return map[string]any{"source": canonicalProviderSource(input.Source), "available": true}, nil
	// 启动时先注册红果主设备与辅助设备；command == "register" 是用户显式重试，
	// 会忽略上一次失败留下的暂停窗口。
	case "hongguoDevices":
		return engine.hongguoDevices(ctx, input.Command == "register")
	case "soraniAccount":
		return engine.downloader.soraniAccount(ctx, input.Command, input.Account)
	case "addCustomSource":
		record, err := engine.addCustomMaccmsSource(input.Name, input.Base, input.Rule, input.Kind)
		if err != nil {
			return nil, err
		}
		return record, nil
	case "updateCustomSource":
		record, err := engine.updateCustomMaccmsSource(input.Source, input.Name, input.Base, input.Rule, input.Kind)
		if err != nil {
			return nil, err
		}
		return record, nil
	case "removeCustomSource":
		return true, engine.removeCustomMaccmsSource(input.Source)
	case "exportCustomSources":
		content, err := engine.exportCustomMaccmsSources()
		if err != nil {
			return nil, err
		}
		return map[string]any{"content": content, "filename": customSourceExportFilename()}, nil
	case "importCustomSources":
		if strings.TrimSpace(input.Content) == "" {
			return nil, errors.New("导入内容为空")
		}
		result, err := engine.importCustomMaccmsSources(input.Content)
		if err != nil {
			return nil, err
		}
		return result, nil
	case "resetCustomSources":
		removed, err := engine.resetCustomMaccmsSources()
		if err != nil {
			return nil, err
		}
		return map[string]any{"removed": removed}, nil
	default:
		return nil, errors.New("不支持的应用操作")
	}
}

func (engine *nativeEngine) nativeCatalog(ctx context.Context, input nativeInput) (nativeCatalogResult, error) {
	source := canonicalProviderSource(input.Source)
	if !isHuangguoProviderSource(source) {
		return nativeCatalogResult{}, errors.New("请选择有效站源")
	}
	category := strings.TrimSpace(input.Category)
	if !validNativeCategory(source, category) {
		return nativeCatalogResult{}, errors.New("内容分类无效")
	}
	cacheKey := nativeCatalogKey(source, category)
	if err := ctx.Err(); err != nil {
		return nativeCatalogResult{}, err
	}
	page := max(1, input.Page)
	query := strings.TrimSpace(input.Query)
	if query == "" {
		if retried, err := engine.retryCatalogSave(); retried {
			cached := engine.nativeCached(cacheKey)
			if err != nil || len(cached.Items) > 0 {
				return cached, nil
			}
		}
	}
	if query == "" && page == 1 && !input.Force {
		if cached := engine.nativeCached(cacheKey); cached.Fresh {
			return cached, nil
		}
	}
	result := nativeCatalogResult{Items: []nativeDrama{}, Page: page}
	if query != "" {
		// 有在线搜索接口的站源统一走 nativeSearchSource：单源搜索与「全部源」
		// 聚合搜索共用同一套实现，不会出现两处结果不一致的情况。
		if nativeSourceSupportsSearch(source) {
			return engine.nativeSearchSource(ctx, source, query, page)
		}
		// 没有搜索接口的站源（黄豆、黄果 AI / 视频 / 旧版）退回已缓存目录里筛选。
		engine.mu.Lock()
		items := append([]nativeDrama{}, engine.catalogs[source]...)
		engine.mu.Unlock()
		for _, item := range items {
			text := hongguoSearchText(item.Title + " " + item.Description + " " + strings.Join(item.Tags, " "))
			matches := true
			for _, word := range strings.Fields(query) {
				matches = matches && strings.Contains(text, hongguoSearchText(word))
			}
			if matches {
				result.Items = append(result.Items, item)
			}
		}
		result.LocalSearch = true
		return result, nil
	}
	d := engine.downloader
	unlock, lockErr := engine.lockSourceCatalog(ctx, source)
	if lockErr != nil {
		return nativeCatalogResult{}, lockErr
	}
	defer unlock()
	if err := ctx.Err(); err != nil {
		return result, err
	}
	var items []Drama
	var err error
	switch source {
	case sourceFanqie:
		items, result.HasMore, err = d.fetchFanqieCatalogPage(ctx, category, page)
	case sourceHongguo:
		if strings.HasPrefix(category, hongguoTagPrefix) {
			items, result.HasMore, err = d.fetchHongguoTagPage(ctx, category, page)
			break
		}
		engine.mu.Lock()
		known := make(map[string]bool, len(engine.catalogs[cacheKey]))
		for _, drama := range engine.catalogs[cacheKey] {
			known[drama.ID] = true
		}
		engine.mu.Unlock()
		ctx = context.WithValue(ctx, libraryKnownKey{}, known)
		if page > 1 {
			ctx = context.WithValue(ctx, libraryMoreKey{}, true)
		}
		items, err = d.fetchHongguoAppCatalogCategory(ctx, category)
		state := d.hongguoCatalogSnapshot()
		result.hongguo = state
		result.HasMore = hongguoCatalogHasMore(state)
		if category != "" && state != nil {
			result.HasMore = !state.Feeds["category:"+category].Exhausted
		}
		if len(items) == 0 && err != nil && ctx.Err() == nil && (category == "" || category == "short_play") {
			var totalPages int
			items, totalPages, err = d.fetchHongguoCategoryPage(ctx, "real-drama?page="+strconv.Itoa(page), "真人剧")
			result.HasMore = page < totalPages
		}
	case sourceHuangdou:
		client := newHuangdouAPIClient(d)
		var decoded any
		err = client.call(ctx, "/drama/list", map[string]any{"page": strconv.Itoa(page), "page_size": "30"}, &decoded)
		if err == nil {
			rows := huangdouList(decoded)
			for _, row := range rows {
				if drama := huangdouDramaFromMap(row); drama.ID != "" {
					items = append(items, drama)
				}
			}
			result.HasMore = len(rows) >= 30
		}
	case sourceHuangguoAI:
		items, result.HasMore, err = d.fetchHuangguoAICatalogPage(ctx, page, category)
	case sourceHuangju:
		items, result.HasMore, err = d.fetchHuangjuCatalogPage(ctx, page, category, "")
	case sourceYeguo:
		items, result.HasMore, err = d.fetchYeguoCatalogPage(ctx, page, category, "")
	case sourceJinguoDuanju:
		items, result.HasMore, err = d.fetchJinguoDuanjuCatalogPage(ctx, page, category, "")
	case sourceJinguo:
		items, result.HasMore, err = d.fetchJinguoCatalogPage(ctx, page, category, "")
	case sourceHeitao:
		items, result.HasMore, err = d.fetchHeitaoCatalogPage(ctx, page, category, "")
	case sourceBeabox:
		items, result.HasMore, err = d.fetchBeaboxCatalogPage(ctx, page, category, "")
	case sourceDSD:
		items, result.HasMore, err = d.fetchDSDCatalogPage(ctx, page, category, "")
	case sourceSorani:
		items, result.HasMore, err = d.fetchSoraniCatalogPage(ctx, page, category, "")
	case sourceGuipian:
		items, result.HasMore, err = d.fetchGuipianCatalogPage(ctx, page, category, "")
	case sourceHanxiaoquan:
		items, result.HasMore, err = d.fetchHanxiaoquanCatalogPage(ctx, page, category, "")
	case sourceHuangguoVideo:
		address := fmt.Sprintf("%s/videos?page=%d", d.providerBaseURL(source), page)
		if category != "" {
			address += "&category=" + url.QueryEscape(category)
		}
		var body string
		body, err = d.fetchProviderText(ctx, address, d.providerBaseURL(source)+"/")
		if err == nil {
			items = parseHuangguoVideoCards(body, address)
		}
		result.HasMore = len(items) >= 20
	case sourceCloudFront:
		items, result.HasMore, err = d.fetchLegacyCatalogCategoryPage(ctx, page, category)
	case sourceIkanbot:
		items, result.HasMore, err = d.fetchIkanbotCatalogPage(ctx, page, category, "")
	case sourceA123:
		items, result.HasMore, err = d.fetchA123CatalogPage(ctx, page, category, "")
	case sourceXChina:
		items, result.HasMore, err = d.fetchXChinaCatalogPage(ctx, page, category, "")
	case sourceTheporny:
		items, result.HasMore, err = d.fetchThepornyCatalogPage(ctx, page, category, "")
	default:
		// 短剧家族与自定义 MacCMS 源共用同一套目录抓取（isDuanjuProviderSource 已含自定义源）。
		if isDuanjuProviderSource(source) {
			items, result.HasMore, err = d.fetchDuanjuCatalogPage(ctx, source, page, category)
		}
	}
	if err != nil && len(items) == 0 {
		return result, err
	}
	if len(items) == 0 && page == 1 && source != sourceHuangju && source != sourceYeguo && source != sourceJinguoDuanju && source != sourceJinguo && source != sourceHeitao && source != sourceBeabox && source != sourceDSD && source != sourceSorani && source != sourceGuipian && source != sourceHanxiaoquan && source != sourceFanqie {
		return result, errors.New("站源暂未返回剧集，请稍后刷新")
	}
	if err != nil {
		result.Warning = publicError(err).Error()
	}
	seen := map[string]bool{}
	for _, drama := range items {
		if drama.ID == "" || seen[drama.ID] {
			continue
		}
		seen[drama.ID] = true
		result.Items = append(result.Items, nativeNormalize(drama))
	}
	engine.saveCatalogCache(cacheKey, &result)
	return result, nil
}

func (engine *nativeEngine) nativeDetail(ctx context.Context, drama nativeDrama) (any, error) {
	source, sourceID, valid := splitProviderDramaID(drama.ID)
	if !valid {
		return nil, errors.New("剧集信息无效，请刷新剧库")
	}
	var title string
	var raw Drama
	var chapters []Chapter
	var err error
	switch source {
	case sourceHuangguoAI:
		raw, chapters, err = engine.downloader.fetchHuangguoAIDetail(ctx, sourceID)
	case sourceHuangguoVideo:
		raw, chapters, err = engine.downloader.fetchHuangguoVideoDetail(ctx, sourceID)
	case sourceCloudFront:
		raw, chapters, err = engine.downloader.fetchLegacyDetail(ctx, sourceID)
	case sourceHuangju:
		raw, chapters, err = engine.downloader.fetchHuangjuDetail(ctx, sourceID)
	case sourceYeguo:
		raw, chapters, err = engine.downloader.fetchYeguoDetail(ctx, sourceID)
	case sourceDSD:
		raw, chapters, err = engine.downloader.fetchDSDDetail(ctx, sourceID)
	case sourceSorani:
		raw, chapters, err = engine.downloader.fetchSoraniDetail(ctx, sourceID)
	case sourceGuipian:
		raw, chapters, err = engine.downloader.fetchGuipianDetail(ctx, sourceID)
	case sourceHanxiaoquan:
		raw, chapters, err = engine.downloader.fetchHanxiaoquanDetail(ctx, sourceID)
	case sourceFanqie:
		raw, chapters, err = engine.downloader.fetchFanqieDetail(ctx, sourceID)
	case sourceXChina:
		raw, chapters, err = engine.downloader.fetchXChinaDetail(ctx, sourceID)
	case sourceTheporny:
		raw, chapters, err = engine.downloader.fetchThepornyDetail(ctx, sourceID)
	default:
		// 必须拿完整 Drama：这些源（网页源 / XBPQ 自定义源 / 爱看机器人 /
		// A123 / 短剧家族 / 红果 / 黄豆）的详情层解析出了简介、封面、类型等，
		// 只取标题会让播放页简介与详情页资料区一直空白。
		raw, chapters, err = engine.downloader.GetHuangguoDetail(ctx, source, sourceID)
		title = raw.DisplayTitle()
	}
	if err != nil {
		return nil, err
	}
	if len(chapters) == 0 {
		return nil, errors.New("该剧暂时没有可播放的分集")
	}
	if title != "" && title != "短剧" {
		drama.Title = title
	}
	if raw.ID == drama.ID {
		drama = mergeNativeDrama(drama, nativeNormalize(raw))
	}
	if source == sourceHongguo {
		raw := engine.downloader.hongguoCachedDrama(Drama{ID: drama.ID, Title: drama.Title, Source: source})
		drama = mergeNativeDrama(drama, nativeNormalize(raw))
	}
	if source == sourceHuangdou {
		if row, err := engine.downloader.huangdouDetail(ctx, sourceID); err == nil {
			fresh := nativeNormalize(huangdouDramaFromMap(row))
			if fresh.ID == drama.ID {
				drama = mergeNativeDrama(drama, fresh)
			}
		}
	}
	// 覆盖前留一份「榜单 / 剧库 / 详情元数据」给出的总集数。
	metadataEpisodes := drama.Episodes
	drama.Source, drama.SourceID, drama.Episodes = source, sourceID, len(chapters)
	if source == sourceHongguo {
		// 红果网页只开放前几集 vid，len(chapters) 是「可看集数」而非总集数；
		// 站点声明的 episode_cnt / 榜单 episodeCount 才应该显示成「共 N 集」。
		drama.Episodes = max(max(drama.Episodes, metadataEpisodes), nativeNormalize(raw).Episodes)
	}
	if source == sourceHuangju || source == sourceYeguo || source == sourceJinguoDuanju || source == sourceJinguo {
		drama.Episodes = max(drama.Episodes, nativeNormalize(raw).Episodes)
	}
	warning := ""
	if err := engine.saveDetailMetadata(drama); err != nil {
		warning = err.Error()
	}
	return map[string]any{"drama": drama, "chapters": chapters, "warning": warning}, nil
}

func (engine *nativeEngine) nativeResolve(ctx context.Context, input nativeInput) (nativePlan, error) {
	if _, _, valid := splitProviderDramaID(input.Drama.ID); !valid {
		return nativePlan{}, errors.New("剧集信息无效")
	}
	if !input.Force && engine.downloads != nil {
		if plan, found, err := engine.downloads.localPlan(input.Drama.ID, input.Index); found || err != nil {
			return plan, err
		}
	}
	task := Task{DramaID: input.Drama.ID, DramaTitle: input.Drama.Title, Chapter: input.Chapter, Index: input.Index, Quality: input.Quality}
	media, err := engine.downloader.resolveProviderMedia(ctx, task)
	if err != nil {
		return nativePlan{}, err
	}
	// 沿用玩家上一次选中的线路（input.Route，0 起）。这一集没有该序号
	// 的线路时由 nativeChoosePlayback 回落到第一条。
	choice := nativeChoosePlayback(media, input.Quality, input.Route)
	if input.AdBlock != nil {
		choice.adBlock = *input.AdBlock
	}
	if series, video, valid := hongguoPlaybackIDs(task); valid {
		choice.danmakuSeries, choice.danmakuVideo = series, video
	}
	return engine.nativeOpenPlayback(ctx, choice)
}

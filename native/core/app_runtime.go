package core

import (
	"context"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

type Config struct {
	dataDir         string
	cacheDir        string
	MaxPagesPerSort int
	PageSize        int
	Retries         int
	InsecureTLS     bool
}

type Downloader struct {
	rankings          rankingCache
	cfg               Config
	client            *http.Client
	reserveMu         sync.Mutex
	reserveNext       uint64
	reservations      map[uint64]func()
	providerMu        sync.Mutex
	providerHosts     map[string]string
	providersMu       sync.Mutex
	providers         map[string]Provider
	providerRevisions map[string]uint64
	limiter           *requestLimiter
	proxyRouter       *proxyRouter
	directOnce        sync.Once
	direct            *http.Client
	diagnostics       *diagnosticLog
	// 红果 App 接口客户端（短剧用）。惰性创建，见 provider_hongguo_app.go。
	hongguoOnce sync.Once
	hongguo     *hongguoAppClient
}

func DefaultConfig() Config { return Config{MaxPagesPerSort: 50, PageSize: 30, Retries: 2} }

type LibraryDrama struct {
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
	Score          string   `json:"score,omitempty"`
	Tags           []string `json:"tags,omitempty"`
	ReleaseStatus  string   `json:"releaseStatus,omitempty"`
	Badge          string   `json:"badge,omitempty"`
	// Peers 在跨源聚合搜索里带上其它站源的同一部剧，供界面一键切换播放源。
	Peers []LibraryDrama `json:"peers,omitempty"`
}

type nativeInput struct {
	SystemProxy     nativeSystemProxy       `json:"systemProxy"`
	Settings        nativeResourceSettings  `json:"settings"`
	JobIDs          []string                `json:"jobIds"`
	PlaybackSession string                  `json:"playbackSession"`
	StartMS         int64                   `json:"startMs"`
	DurationMS      int64                   `json:"durationMs"`
	Board           string                  `json:"board"`
	Entries         []nativeDownloadEpisode `json:"entries"`
	JobID           string                  `json:"jobId"`
	Command         string                  `json:"command"`
	Action          string                  `json:"action"`
	Directory       string                  `json:"directory"`
	Cache           string                  `json:"cache"`
	Downloads       string                  `json:"downloads"`
	Source          string                  `json:"source"`
	Page            int                     `json:"page"`
	Query           string                  `json:"query"`
	Category        string                  `json:"category"`
	Drama           LibraryDrama            `json:"drama"`
	Chapter         Chapter                 `json:"chapter"`
	Index           int                     `json:"index"`
	Quality         int                     `json:"quality"`
	Session         string                  `json:"session"`
	// Route 是播放线路下标（从 0 开始），仅 selectRoute 使用。
	Route    int             `json:"route"`
	Sequence int64           `json:"sequence"`
	Force    bool            `json:"force"`
	Bundled  bool            `json:"bundled"`
	Version  string          `json:"version"`
	Since    string          `json:"since"`
	Account  json.RawMessage `json:"account"`
	Device   string          `json:"device"`
	File     string          `json:"file"`
	URL      string          `json:"url"`
	Token    string          `json:"token"`
	// Files / URLs 供批量安装模块使用：一次可提交多个本地安装包或下载地址。
	Files []string `json:"files"`
	URLs  []string `json:"urls"`
	// IDs 供批量导出、批量卸载、恢复默认使用。
	IDs []string `json:"ids"`
	// Repositories / ActiveRepository 供在线仓库的增删改切换使用。
	Repositories     []nativeModuleRepository `json:"repositories"`
	ActiveRepository int                      `json:"activeRepository"`
	// Content 供听书接口使用：Content 是听书请求的附加请求头 JSON。
	Content string `json:"content"`
	Offset  int    `json:"offset"`
	// Peer 是投屏目标（电视）的地址，核心据此挑本机走哪块网卡。
	Peer string `json:"peer"`
	// Sources 是跨源聚合搜索要查的站源列表；Search 是搜索会话号。
	Sources []string `json:"sources"`
	Search  string   `json:"search"`
	// 自定义源表单字段。
	Name string `json:"name"`
	Base string `json:"base"`
	Rule string `json:"rule"`
	Kind string `json:"kind"`
	// AdBlock 控制 m3u8 广告分片过滤。缺省（nil）按开启处理，
	// 与播放设置里的默认值一致。
	AdBlock *bool `json:"adBlock"`
}

type nativeCatalogResult struct {
	Items       []LibraryDrama `json:"items"`
	HasMore     bool           `json:"hasMore"`
	Page        int            `json:"page"`
	Warning     string         `json:"warning,omitempty"`
	LocalSearch bool           `json:"localSearch"`
	Fresh       bool           `json:"fresh"`
	saveError   error
}

type nativePlan struct {
	ExpiresAt       int64  `json:"expiresAt,omitempty"`
	PrefetchedBytes int64  `json:"prefetchedBytes,omitempty"`
	DanmakuID       string `json:"danmakuId,omitempty"`
	Local           bool   `json:"local"`
	URL             string `json:"url"`
	// DirectURL 是站源给出的原始播放地址，投屏时优先直接交给电视。
	DirectURL  string            `json:"directUrl,omitempty"`
	Headers    map[string]string `json:"headers"`
	Key        string            `json:"decryptionKey,omitempty"`
	Quality    int               `json:"quality"`
	Qualities  []int             `json:"qualities"`
	Session    string            `json:"session,omitempty"`
	RouteIndex int               `json:"routeIndex"`
	RouteCount int               `json:"routeCount"`
	// Verify 非空表示这一集要先用隐藏浏览器完成验证；值是 browser:// 后面的
	// 短链地址。前端拿到后走验证，再把落地地址写回分集重新解析。
	Verify string `json:"verify,omitempty"`
}

type nativeEngine struct {
	settingsMu sync.Mutex
	settings   nativeResourceSettings
	// 在线仓库配置：仓库名 + index.json 地址列表与当前启用项，落盘在数据目录。
	repositoriesMu      sync.Mutex
	repositories        moduleRepositoriesConfig
	repositoriesWarning string
	readMu              sync.Mutex
	reads               map[string]nativeReadRequest
	readCount           int
	work                map[string]bool
	downloads           *nativeDownloads
	downloader          *Downloader
	directory           string
	cacheDirectory      string
	defaultDownloads    string
	mu                  sync.Mutex
	catalogs            map[string][]LibraryDrama
	catalogStates       map[string]nativeCatalogState
	categoryOptions     map[string][]Category
	providerStates      map[string]json.RawMessage
	providerStatesSaved []byte
	recommendations     map[string]nativeRecommendationState
	catalogSaveError    error
	covers              *nativeCoverCache
	stream              *nativeStreamServer
	cast                nativeCast
	playbacks           map[string]nativePlaybackChoice
	playbackMu          sync.Mutex
	playbackSequence    int64
	playbackCancel      context.CancelFunc
	sourceCatalogMu     sync.Mutex
	sourceCatalogs      map[string]chan struct{}
	// customRegistry 是自定义源（MacCMS / XBPQ 规则）注册表，落盘在数据目录。
	customRegistry *customMaccmsRegistry
	// 跨源聚合搜索的进行中会话：searchStart 建会话，searchPoll 读快照。
	searchMu sync.Mutex
	searches map[string]*nativeSearchSession
}

var nativeState struct {
	sync.Mutex
	engine *nativeEngine
}

func NativeText(value any) string {
	switch v := value.(type) {
	case string:
		return strings.TrimSpace(v)
	case map[string]any:
		for _, key := range []string{"url", "src", "cover", "image", "pic"} {
			if text := NativeText(v[key]); text != "" {
				return text
			}
		}
	case []any:
		for _, entry := range v {
			if text := NativeText(entry); text != "" {
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

func NativeNormalize(drama Drama) LibraryDrama {
	cover := ""
	for _, value := range []any{drama.Cover, drama.CoverURL, drama.CoverURLSnake, drama.Image, drama.ImageURL, drama.ImageURLSnake, drama.Img, drama.Pic, drama.Picture, drama.Poster, drama.Thumb, drama.Thumbnail} {
		candidate := NativeText(value)
		if strings.HasPrefix(candidate, "//") {
			candidate = "https:" + candidate
		}
		if IsProviderHTTPMediaURL(candidate) {
			cover = candidate
			break
		}
	}
	episodes := 0
	for _, value := range []any{drama.TotalEpisode, drama.TotalEpisodeSnake, drama.EpisodeCount, drama.EpisodeCountSnake, drama.ChapterCount, drama.ChapterCountSnake, drama.Total, drama.Episodes} {
		if count, _ := strconv.Atoi(NativeText(value)); count > episodes {
			episodes = count
		}
	}
	source, sourceID, _ := SplitProviderDramaID(drama.ID)
	return LibraryDrama{MetadataSchema: 1, ID: drama.ID, Source: source, SourceID: sourceID, Title: drama.DisplayTitle(),
		Description: FirstNonEmpty(drama.Desc, drama.Intro), Cover: cover, Episodes: episodes,
		Category: nativeDramaCategory(drama), VIP: drama.VIP,
		Heat: drama.Heat, Views: drama.Views, OnlineDate: ProviderReleaseDate(drama.OnlineDate), Score: NativeDramaScore(drama.Score),
		Tags: append([]string(nil), drama.Tags...), ReleaseStatus: drama.ReleaseStatus, Badge: drama.Badge}
}

func NativeDramaScore(score string) string {
	score = strings.TrimSpace(strings.TrimSuffix(strings.TrimPrefix(strings.TrimSpace(score), "评分"), "分"))
	value, err := strconv.ParseFloat(score, 64)
	if err != nil || !(value > 0 && value <= 10) {
		return ""
	}
	return strconv.FormatFloat(value, 'f', 1, 64)
}

func nativeDramaCategory(drama Drama) string {
	category := FirstNonEmpty(drama.CategoryName, drama.CategoryNameSnake, drama.TypeName, drama.TypeNameSnake, drama.SortName, drama.SortNameSnake, drama.Category)
	if category != "" {
		return category
	}
	switch drama.ChannelName {
	case "真人剧", "短剧", "漫剧", "AI 剧", "AI剧", "AI 短剧", "AI 漫剧", "AI 换脸", "AI 魔改":
		return drama.ChannelName
	}
	return ""
}

func newNativeEngine(directory, cache, downloads string) (*nativeEngine, error) {
	if !filepath.IsAbs(directory) {
		return nil, errors.New("应用数据目录无效")
	}
	if !filepath.IsAbs(cache) {
		return nil, errors.New("应用缓存目录无效")
	}
	if err := os.MkdirAll(directory, 0700); err != nil {
		return nil, err
	}
	if err := os.MkdirAll(cache, 0700); err != nil {
		return nil, err
	}
	moveLegacyNativeCache(directory, cache)
	cfg := DefaultConfig()
	cfg.dataDir = directory
	cfg.cacheDir = cache
	router := &proxyRouter{}
	d := &Downloader{cfg: cfg, providerHosts: map[string]string{}, proxyRouter: router,
		limiter: newRequestLimiter(3, 0), diagnostics: newDiagnosticLog(directory)}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.TLSClientConfig = &tls.Config{MinVersion: tls.VersionTLS12}
	transport.MaxIdleConnsPerHost = 8
	transport.ResponseHeaderTimeout = 20 * time.Second
	transport.Proxy = router.proxy
	cdn := newCDNTransport(transport, newDNSResolver(transport))
	d.client = &http.Client{Transport: newHuangguoBrowserTransport(cdn, d), Timeout: 45 * time.Second,
		CheckRedirect: func(request *http.Request, via []*http.Request) error {
			if len(via) >= 10 {
				return errors.New("站源重定向次数过多")
			}
			if len(via) > 0 && !strings.EqualFold(request.URL.Host, via[0].URL.Host) {
				request.Header.Del("X-Preview-Token")
			}
			return nil
		}}
	engine := &nativeEngine{downloader: d, directory: directory, cacheDirectory: cache, defaultDownloads: nativeDefaultDownloads(directory), catalogs: map[string][]LibraryDrama{}, catalogStates: map[string]nativeCatalogState{}}
	if filepath.IsAbs(downloads) {
		engine.defaultDownloads = filepath.Clean(downloads)
	}
	d.loadModules()
	// 自定义源注册表必须在任何站源判定之前就绪：站源可用性判定会回调
	// customMaccmsSpecFor 查询自定义源，registry 为 nil 时那次查询会直接
	// 空指针 panic（表现为「本地核心处理失败」）。
	engine.customRegistry = newCustomMaccmsRegistry(directory)
	engine.customRegistry.load()
	engine.loadModuleRepositories()
	engine.loadResourceSettings()
	d.loadRankingCache()
	engine.loadCatalogCache()
	engine.covers = newNativeCoverCache(cache, d)
	engine.downloads = newNativeDownloads(engine)
	return engine, nil
}

func NativeRequest(raw string) (result string) {
	defer func() {
		if recover() != nil {
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
		envelope["error"] = PublicError(err).Error()
		if errors.Is(err, errNativeLocalFile) {
			envelope["code"] = "local_media"
		}
		if errors.Is(err, ErrSourceLogin) {
			envelope["code"] = "source_login"
		}
		var backoff *RequestBackoff
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
			engine, err := newNativeEngine(input.Directory, input.Cache, input.Downloads)
			if err != nil {
				nativeState.Unlock()
				return nil, err
			}
			nativeState.engine = engine
		}
		engine := nativeState.engine
		nativeState.Unlock()
		return map[string]any{"version": "0.2.17", "standalone": true, "sources": engine.sourceList()}, nil
	}
	engine := nativeState.engine
	nativeState.Unlock()
	if engine == nil {
		return nil, errors.New("应用核心尚未就绪，请重新打开应用")
	}
	duration := 60 * time.Second
	if input.Action == "moveDownloads" || input.Action == "deleteAllData" {
		duration = 10 * time.Minute
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
		return engine.cachedRecommendations(nativeActionSource(input), input.Category)
	case "modules":
		items, err := engine.modules()
		return map[string]any{"items": items}, err
	case "moduleIndex":
		return engine.moduleStore(ctx)
	case "moduleRepositories":
		return engine.repositoriesView(), nil
	case "saveModuleRepositories":
		return engine.saveModuleRepositories(moduleRepositoriesConfig{
			Repositories: input.Repositories,
			Active:       input.ActiveRepository,
		})
	case "prepareModule":
		return engine.prepareModule(ctx, input.File, input.URL, input.Source, input.Bundled)
	// prepareModules：批量准备安装包，返回每个来源的结果（成功带 token，失败带原因）。
	// 本地 zip 支持「一个包里含多个子模块 zip」，在线地址也支持一次多个。
	case "prepareModules":
		return engine.prepareModules(ctx, input.Files, input.URLs)
	case "installModule":
		return engine.installModule(input.Token)
	case "uninstallModule":
		return engine.uninstallModule(input.Source)
	// uninstallModules：批量卸载。resetModules 在此基础上再把内置模块恢复回来。
	case "uninstallModules":
		return engine.uninstallModules(input.IDs)
	case "resetModules":
		return engine.resetModules()
	// exportModules：导出指定模块（为空时导出全部用户安装的模块）为 zip。
	case "exportModules":
		return engine.exportModules(input.IDs)
	case "sourceDevices":
		return engine.sourceDevices(ctx, nativeActionSource(input), input.Command == "register")
	case "soraniAccount", "sourceAccount":
		return engine.sourceAccount(ctx, nativeActionSource(input), input.Command, input.Account)
	case "rankingBoards":
		boards := []RankingBoard{}
		for _, board := range allRankingBoards() {
			if nativeSourceAvailable(board.Source) {
				boards = append(boards, board)
			}
		}
		return map[string]any{"items": boards}, nil
	case "rankings":
		return engine.nativeRanking(ctx, input)
	case "suggestions":
		items, err := engine.suggestions(ctx, nativeActionSource(input), input.Query)
		return map[string]any{"items": items}, err
	case "customSources":
		return map[string]any{"items": engine.customMaccmsSources()}, nil
	// analyzeCustomSourceSite：新增自定义源时按网页 HTML 自动反推 XBPQ 规则。
	// 只返回规则文本与诊断说明，不写盘；是否保存仍由用户在表单里点「保存」决定。
	case "analyzeCustomSourceSite":
		return engine.downloader.analyzeCustomSourceSite(ctx, input.Base)
	// sourceStatus：本地服务版（native/server）用它判断某个站源在当前构建里是否存在。
	// 授权阶段已用 nativeSourceAvailable 拦掉未编译进来的源，能走到这里即代表可用；
	// 这里不返回 Flutter 端那套任务进度字段。
	case "sourceStatus":
		return map[string]any{"source": canonicalProviderSource(input.Source), "available": true}, nil
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
		return engine.withAudiobookStream(map[string]any{
			"url":           media.URL,
			"decryptionKey": hex.EncodeToString(media.CENCKey),
			"duration":      int(media.Duration.Seconds()),
			"headers":       map[string]string{"Referer": media.Referer, "User-Agent": "com.dragon.read"},
		}), nil
	case "downloadDirectory":
		engine.downloads.mu.Lock()
		root := engine.downloads.root
		engine.downloads.mu.Unlock()
		return map[string]string{"directory": root}, nil
	case "storage":
		return engine.storage()
	case "cache", "cacheInfo":
		// cache 供 Dart 端使用，cacheInfo 供本地服务版网页「清理缓存」统计使用；
		// 两者口径一致。server 侧会再把转码临时目录的统计并进来。
		return map[string]int64{"bytes": engine.cacheBytes()}, nil
	case "clearCache":
		// 网页端按 {clearedBytes, bytes} 显示清理结果；core 只清理数据目录内的缓存，
		// 转码临时目录由 server 侧 mergeTranscodeCache 追加。清前后做差得到释放量。
		before := engine.cacheBytes()
		if err := engine.clearCache(); err != nil {
			return nil, err
		}
		return map[string]int64{
			"clearedBytes": before - engine.cacheBytes(),
			"bytes":        engine.cacheBytes(),
		}, nil
	case "deleteAllData":
		leftover, err := engine.deleteAllData()
		return map[string]any{"leftover": leftover}, err
	case "moveDownloads":
		leftover, reason, err := engine.moveDownloads(ctx, input.Directory)
		return map[string]string{"leftover": leftover, "leftoverReason": reason}, err
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
	// 跨源聚合搜索：searchStart 建会话并并发查各源，searchPoll 读增量快照，
	// searchCancel 取消，searchAcross 是一次性（不分页轮询）的同步版本。
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
		if !ValidNativeCategory(canonicalProviderSource(input.Source), input.Category) {
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
	case "seasons":
		return engine.nativeSeasons(ctx, input.Drama)
	case "metadata":
		return engine.nativeMetadata(ctx, input.Drama)
	case "followCheck":
		return engine.nativeFollowCheck(ctx, input.Drama)
	case "resolve", "fallback", "selectRoute":
		playback, finish, err := engine.nativeBeginPlayback(ctx, input.Sequence)
		if err != nil {
			return nil, err
		}
		defer finish()
		switch input.Action {
		case "fallback":
			return engine.nativeNextPlayback(playback, input.Session)
		case "selectRoute":
			return engine.nativeSelectPlayback(playback, input.Session, input.Route)
		}
		return engine.nativeResolve(playback, input)
	case "cancelPlayback":
		engine.nativeCancelPlayback(input.Sequence)
		return true, nil
	case "release":
		engine.nativeReleasePlayback(input.Session)
		return true, nil
	case "cast":
		return engine.nativeCast(ctx, input)
	// 投屏（移植自 guoappxp）：castBase 开局域网监听并返回电视可访问的基址，
	// closeCast 停止监听。DLNA 的 SSDP/SOAP 在 Android 原生侧，这里只管流。
	case "castBase":
		base, err := engine.nativeCastBase(input.Peer)
		if err != nil {
			return nil, err
		}
		return map[string]any{"base": base}, nil
	case "closeCast":
		engine.nativeCloseCast()
		return true, nil
	default:
		return nil, errors.New("不支持的应用操作")
	}
}

func (engine *nativeEngine) nativeCatalog(ctx context.Context, input nativeInput) (nativeCatalogResult, error) {
	source := canonicalProviderSource(input.Source)
	// 自定义源不进 provider 注册表，但它由 downloader 的 maccms 分支处理分类与目录，
	// 不能只认注册表，否则一进目录就报「请选择有效站源」。
	if !registeredProviderSource(source) && !isCustomMaccmsSource(source) {
		return nativeCatalogResult{}, errors.New("请选择有效站源")
	}
	category := strings.TrimSpace(input.Category)
	if !ValidNativeCategory(source, category) {
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
	d := engine.downloader
	result := nativeCatalogResult{Items: []LibraryDrama{}, Page: page}
	registered, hasProvider := d.provider(source)
	if searcher, ok := providerAs[WarningSearcher](registered); ok && query != "" {
		items, more, warning, err := searcher.SearchWithWarning(ctx, page, query)
		if err != nil {
			return result, err
		}
		for _, drama := range items {
			result.Items = append(result.Items, NativeNormalize(drama))
		}
		result.Warning, result.HasMore = warning, more
		return result, nil
	}
	if searcher, ok := providerAs[Searcher](registered); ok && query != "" {
		items, more, err := searcher.Search(ctx, page, query)
		if err != nil {
			return result, err
		}
		for _, drama := range items {
			result.Items = append(result.Items, NativeNormalize(drama))
		}
		result.HasMore = more
		return result, nil
	}
	if query != "" {
		engine.mu.Lock()
		items := append([]LibraryDrama{}, engine.catalogs[source]...)
		engine.mu.Unlock()
		for _, item := range items {
			text := NativeSearchText(item.Title + " " + item.Description + " " + strings.Join(item.Tags, " "))
			matches := true
			for _, word := range strings.Fields(query) {
				matches = matches && strings.Contains(text, NativeSearchText(word))
			}
			if matches {
				result.Items = append(result.Items, item)
			}
		}
		result.LocalSearch = true
		return result, nil
	}
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
	allowEmptyCatalog := false
	if !hasProvider {
		if isCustomMaccmsSource(source) {
			// 自定义源（MacCMS / XBPQ 规则）不进 provider 注册表，目录按规则字段
			// 或网页模板实时抓取。fetchDuanjuCatalogPage 内部已含这条分支。
			items, result.HasMore, err = d.fetchDuanjuCatalogPage(ctx, source, page, category)
		} else {
			return result, errors.New("请选择有效站源")
		}
	} else {
		descriptor := registered.Descriptor()
		allowEmptyCatalog = descriptor.AllowEmptyCatalog
		if descriptor.ContinuousFeed {
			engine.mu.Lock()
			known := make(map[string]bool, len(engine.catalogs[cacheKey]))
			for _, drama := range engine.catalogs[cacheKey] {
				known[drama.ID] = true
			}
			engine.mu.Unlock()
			ctx = context.WithValue(ctx, LibraryKnownKey{}, known)
			if page > 1 {
				ctx = context.WithValue(ctx, LibraryMoreKey{}, true)
			}
		}
		items, result.HasMore, err = registered.CatalogPage(ctx, page, category)
	}
	if err != nil && len(items) == 0 {
		return result, err
	}
	if len(items) == 0 && page == 1 && !allowEmptyCatalog {
		return result, errors.New("站源暂未返回剧集，请稍后刷新")
	}
	if err != nil {
		result.Warning = PublicError(err).Error()
	}
	seen := map[string]bool{}
	for _, drama := range items {
		if drama.ID == "" || seen[drama.ID] {
			continue
		}
		seen[drama.ID] = true
		result.Items = append(result.Items, NativeNormalize(drama))
	}
	engine.saveCatalogCache(cacheKey, &result)
	return result, nil
}

func (engine *nativeEngine) nativeDetail(ctx context.Context, drama LibraryDrama) (any, error) {
	source, sourceID, valid := SplitProviderDramaID(drama.ID)
	if !valid {
		return nil, errors.New("剧集信息无效，请刷新剧库")
	}
	// 自定义源（MacCMS / XBPQ 规则）不进 provider 注册表，详情按规则 / 网页模板
	// 实时解析；fetchDuanjuDetail 内部已含这条分支。
	raw, chapters, err := engine.downloader.fetchDuanjuDetail(ctx, source, sourceID)
	if err != nil {
		return nil, err
	}
	if len(chapters) == 0 {
		return nil, errors.New("该剧暂时没有可播放的分集")
	}
	if raw.ID == drama.ID {
		drama = MergeNativeDrama(drama, NativeNormalize(raw))
	}
	drama.Source, drama.SourceID, drama.Episodes = source, sourceID, len(chapters)
	if p, ok := engine.downloader.provider(source); ok && p.Descriptor().KeepDetailEpisodes {
		drama.Episodes = max(drama.Episodes, NativeNormalize(raw).Episodes)
	}
	warning := ""
	if err := engine.saveDetailMetadata(drama); err != nil {
		warning = err.Error()
	}
	return map[string]any{"drama": drama, "chapters": chapters, "warning": warning}, nil
}

func (engine *nativeEngine) nativeResolve(ctx context.Context, input nativeInput) (nativePlan, error) {
	if _, _, valid := SplitProviderDramaID(input.Drama.ID); !valid {
		return nativePlan{}, errors.New("剧集信息无效")
	}
	if !input.Force && engine.downloads != nil {
		if plan, found, err := engine.downloads.localPlan(input.Drama.ID, input.Index); found || err != nil {
			return plan, err
		}
	}
	task := Task{DramaID: input.Drama.ID, DramaTitle: input.Drama.Title, Chapter: input.Chapter, Index: input.Index}
	media, err := engine.downloader.resolveProviderMedia(ctx, task)
	if err != nil {
		// 需要浏览器验证时不算失败：把短链地址回给前端，由它走完验证再重新解析。
		var verify BrowserVerifyError
		if errors.As(err, &verify) {
			return nativePlan{Verify: verify.Address}, nil
		}
		return nativePlan{}, err
	}
	choice := nativePlaybackChoices(media, input.Quality)
	if input.AdBlock != nil {
		choice.adBlock = *input.AdBlock
	}
	if p, ok := engine.downloader.provider(SourceFromDramaID(task.DramaID)); ok {
		if danmaku, ok := providerAs[DanmakuProvider](p); ok {
			if series, video, valid := danmaku.DanmakuIDs(task); valid {
				choice.danmakuSource, choice.danmakuSeries, choice.danmakuVideo = p.Descriptor().ID, series, video
			}
		}
	}
	return engine.nativeOpenPlayback(ctx, choice)
}

// withAudiobookStream 给听书音频附上一个本机明文流地址（streamUrl）。
// 播放器拿到的是带 .m4a 扩展名的 127.0.0.1 地址，与短剧播放同构：容器探测稳定、
// CENC 的 decryption_key 能落到 mov demuxer，上游的 Referer / User-Agent 也由
// Go 侧统一注入。streamUrl 是附加字段：拿不到流服务器时退回原来的直连路径。
func (engine *nativeEngine) withAudiobookStream(plan map[string]any) map[string]any {
	if plan == nil {
		return plan
	}
	engine.mu.Lock()
	if engine.stream == nil {
		stream, err := newNativeStreamServer(engine.downloader)
		if err == nil {
			engine.stream = stream
		}
	}
	stream := engine.stream
	engine.mu.Unlock()
	if stream != nil {
		if address := stream.nativeOpenAudiobook(plan); address != "" {
			plan["streamUrl"] = address
		}
	}
	return plan
}

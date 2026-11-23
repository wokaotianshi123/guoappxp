package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"path/filepath"
	"strconv"
	"strings"
	"sync"

	"duanjuapp/native/core/netdisk"
)

// 网盘通道：扫码登录 + 分享解析 + 直链播放 + 统一站源桥接。
// 凭据只存应用私有目录（netdisk-cookies.json，0600），不上传任何服务。

type netdiskRuntime struct {
	once  sync.Once
	store *netdisk.Store
	login *netdisk.LoginManager
	err   error
	dir   string
}

var (
	netdiskMu sync.Mutex
	netdiskRT *netdiskRuntime
)

func init() {
	Register(SourceDescriptor{
		ID:                 "netdisk",
		Name:               "网盘分享",
		Description:        "粘贴夸克网盘分享链接解析选集并直链播放",
		Group:              "netdisk",
		GroupName:          "网盘直达",
		SkipVIPPrompt:      true,
		AllowEmptyCatalog:  true,
		KeepDetailEpisodes: true,
		NoHostRotation:     true,
	}, func(Host) Provider {
		return &netdiskProvider{}
	})
}

func (engine *nativeEngine) netdiskInit() (*netdiskRuntime, error) {
	netdiskMu.Lock()
	dir := engine.directory
	netdiskMu.Unlock()

	netdiskMu.Lock()
	defer netdiskMu.Unlock()
	if netdiskRT != nil && netdiskRT.dir == dir && netdiskRT.err == nil {
		return netdiskRT, nil
	}
	rt := &netdiskRuntime{dir: filepath.Clean(dir)}
	if rt.dir == "" || rt.dir == "." {
		rt.err = errors.New("应用目录尚未就绪")
		netdiskRT = rt
		return nil, rt.err
	}
	rt.store = netdisk.NewStore(rt.dir)
	rt.login = netdisk.NewLoginManager(rt.store)
	netdiskRT = rt
	return rt, nil
}

// netdiskStatus 返回各网盘登录状态与临时目录说明。
func (engine *nativeEngine) netdiskStatus() (map[string]any, error) {
	rt, err := engine.netdiskInit()
	if err != nil {
		return nil, err
	}
	// 前端要能同时展示夸克与 UC 两个网盘的登录态，没存过凭据的也要给出 false，
	// 否则界面上看不到「去登录 UC」的入口。
	status := rt.store.Status()
	loggedIn := map[string]bool{}
	ready := map[string]bool{}
	for _, provider := range []string{"quark", "uc"} {
		creds, err := rt.store.Get(provider)
		loggedIn[provider] = err == nil && creds != nil
		ready[provider] = err == nil && netdisk.ProviderReady(creds)
	}
	for name, value := range status {
		if _, ok := loggedIn[name]; !ok {
			loggedIn[name] = value
		}
	}
	return map[string]any{"loggedIn": loggedIn, "ready": ready}, nil
}

// netdiskLoginStart 生成扫码登录二维码。
func (engine *nativeEngine) netdiskLoginStart(ctx context.Context, provider string) (any, error) {
	rt, err := engine.netdiskInit()
	if err != nil {
		return nil, err
	}
	return rt.login.StartFor(ctx, provider)
}

// netdiskLoginCookie 用浏览器里复制出来的 Cookie 直接登录。
func (engine *nativeEngine) netdiskLoginCookie(provider, cookie string) (any, error) {
	rt, err := engine.netdiskInit()
	if err != nil {
		return nil, err
	}
	creds, err := netdisk.ParseCookieHeader(provider, cookie)
	if err != nil {
		return nil, err
	}
	if err := rt.store.Put(creds); err != nil {
		return nil, err
	}
	status := rt.store.Status()
	return map[string]any{"loggedIn": status, "provider": creds.Provider}, nil
}

// netdiskLoginPoll 查询扫码结果。
func (engine *nativeEngine) netdiskLoginPoll(ctx context.Context, id string) (any, error) {
	rt, err := engine.netdiskInit()
	if err != nil {
		return nil, err
	}
	return rt.login.Poll(ctx, id)
}

// netdiskLogout 清除本地凭据。
func (engine *nativeEngine) netdiskLogout(provider string) (bool, error) {
	rt, err := engine.netdiskInit()
	if err != nil {
		return false, err
	}
	provider = netdisk.NormalizeProvider(provider)
	return true, rt.store.Clear(provider)
}

func (engine *nativeEngine) netdiskClient() (netdisk.Provider, error) {
	rt, err := engine.netdiskInit()
	if err != nil {
		return nil, err
	}
	// 默认走夸克；分享链接是 UC 时由调用方用 netdiskClientFor 指定。
	creds, err := rt.store.Get("quark")
	if err != nil {
		return netdisk.NewQuark(nil), nil
	}
	return netdisk.NewQuark(creds), nil
}

// netdiskClientFor 按网盘标识取对应客户端（夸克 / UC）。
func (engine *nativeEngine) netdiskClientFor(provider string) (netdisk.Provider, error) {
	rt, err := engine.netdiskInit()
	if err != nil {
		return nil, err
	}
	if netdisk.NormalizeProvider(provider) == "uc" {
		creds, err := rt.store.Get("uc")
		if err != nil {
			return netdisk.NewUC(nil), nil
		}
		return netdisk.NewUC(creds), nil
	}
	creds, err := rt.store.Get("quark")
	if err != nil {
		return netdisk.NewQuark(nil), nil
	}
	return netdisk.NewQuark(creds), nil
}

// netdiskClientForShare 按分享链接自动识别网盘并返回客户端。
func (engine *nativeEngine) netdiskClientForShare(raw string) (netdisk.Provider, error) {
	return engine.netdiskClientFor(netdisk.DetectProvider(raw))
}

// netdiskShare 解析分享链接，返回剧集列表。
func (engine *nativeEngine) netdiskShare(ctx context.Context, raw string) (any, error) {
	if raw == "" {
		return nil, errors.New("请填写网盘分享链接")
	}
	client, err := engine.netdiskClientForShare(raw)
	if err != nil {
		return nil, err
	}
	return client.Share(ctx, raw)
}

// netdiskOpenShare 将分享链接解析为标准 Drama 与 Chapter 列表，供统一详情页和主播放器使用。
func (engine *nativeEngine) netdiskOpenShare(ctx context.Context, raw string) (map[string]any, error) {
	shareURL := netdisk.ExtractShareURL(raw)
	if shareURL == "" {
		shareURL = strings.TrimSpace(raw)
	}
	if shareURL == "" {
		return nil, errors.New("请填写网盘分享链接")
	}
	client, err := engine.netdiskClientForShare(shareURL)
	if err != nil {
		return nil, err
	}
	info, err := client.Share(ctx, shareURL)
	if err != nil {
		return nil, err
	}
	drama, chapters := shareInfoToDrama("netdisk", shareURL, info)
	libDrama := LibraryDrama{
		ID:            drama.ID,
		Source:        "netdisk",
		SourceID:      shareURL,
		Title:         drama.Title,
		Description:   drama.Desc,
		Episodes:      len(chapters),
		Category:      "网盘分享",
		Badge:         netdiskBadge(info.Provider),
		ReleaseStatus: "已完结",
	}
	return map[string]any{
		"drama":    libDrama,
		"chapters": chapters,
		"loggedIn": info.LoggedIn,
	}, nil
}

// netdiskBadge 返回分享来源的展示名。
func netdiskBadge(provider string) string {
	if provider == "uc" {
		return "UC 网盘"
	}
	return "夸克网盘"
}

// netdiskPlay 把指定集转存并取回播放地址（含播放所需请求头）。
func (engine *nativeEngine) netdiskPlay(ctx context.Context, raw string, index int) (any, error) {
	if raw == "" {
		return nil, errors.New("请填写网盘分享链接")
	}
	client, err := engine.netdiskClientForShare(raw)
	if err != nil {
		return nil, err
	}
	return client.ResolveShare(ctx, raw, index)
}

// netdiskCleanup 清理网盘临时转存目录（gomovie_tmp）。
func (engine *nativeEngine) netdiskCleanup(ctx context.Context, provider string) (map[string]any, error) {
	rt, err := engine.netdiskInit()
	if err != nil {
		return nil, err
	}
	provider = netdisk.NormalizeProvider(provider)
	creds, err := rt.store.Get(provider)
	if err != nil {
		return nil, netdisk.ErrNotLoggedIn
	}
	var deleted int
	if provider == "uc" {
		deleted, err = netdisk.NewUC(creds).CleanupTemp(ctx)
	} else {
		deleted, err = netdisk.NewQuark(creds).CleanupTemp(ctx)
	}
	if err != nil {
		return nil, err
	}
	return map[string]any{"deleted": deleted, "tempDir": "gomovie_tmp"}, nil
}

// netdiskInfo 返回临时目录说明。
func (engine *nativeEngine) netdiskInfo() map[string]any {
	return map[string]any{
		"tempDir": "gomovie_tmp",
		"note":    "转存的文件会放在网盘根目录的 gomovie_tmp 下，可随时一键清理",
	}
}

func formatNetdiskSize(bytes int64) string {
	if bytes <= 0 {
		return ""
	}
	const gb = 1024 * 1024 * 1024
	const mb = 1024 * 1024
	if bytes >= gb {
		return fmt.Sprintf("%.1fGB", float64(bytes)/float64(gb))
	}
	if bytes >= mb {
		return fmt.Sprintf("%dMB", bytes/mb)
	}
	return ""
}

func shareInfoToDrama(source, shareURL string, info *netdisk.ShareInfo) (Drama, []Chapter) {
	title := strings.TrimSpace(info.Title)
	if title == "" {
		title = "网盘分享 (" + info.ShareID + ")"
	}
	badge := netdiskBadge(info.Provider)
	drama := Drama{
		ID:       source + ":" + shareURL,
		Source:   source,
		SourceID: shareURL,
		Title:    title,
		Desc:     "网盘分享 · 共 " + strconv.Itoa(len(info.Episodes)) + " 个文件",
		Badge:    badge,
	}
	chapters := make([]Chapter, 0, len(info.Episodes))
	for i, ep := range info.Episodes {
		// 直接展示网盘里的原始文件名（不带编号前缀），用户能对上自己网盘里的文件。
		epTitle := strings.TrimSpace(ep.Name)
		if epTitle == "" {
			epTitle = "文件 " + strconv.Itoa(i+1)
		}
		if sizeText := formatNetdiskSize(ep.Size); sizeText != "" {
			epTitle = epTitle + " · " + sizeText
		}
		epNum, _ := json.Marshal(i + 1)
		chapters = append(chapters, Chapter{
			ID:             drama.ID + "#" + strconv.Itoa(i),
			Source:         source,
			Title:          epTitle,
			VideoURL:       encodeNetdiskVideoRef(i, shareURL),
			CurrentEpisode: epNum,
			MediaSize:      ep.Size,
		})
	}
	return drama, chapters
}

func encodeNetdiskVideoRef(index int, shareURL string) string {
	return "netdisk:" + strconv.Itoa(index) + "|" + shareURL
}

func decodeNetdiskVideoRef(raw string) (int, string, bool) {
	trimmed := strings.TrimSpace(raw)
	if strings.HasPrefix(trimmed, "netdisk:") {
		rest := strings.TrimPrefix(trimmed, "netdisk:")
		if idxStr, shareURL, ok := strings.Cut(rest, "|"); ok {
			idx, err := strconv.Atoi(idxStr)
			if err == nil && shareURL != "" {
				return idx, shareURL, true
			}
		}
	}
	if shareURL := netdisk.ExtractShareURL(trimmed); shareURL != "" {
		return 0, shareURL, true
	}
	return 0, "", false
}

func resolveNetdiskMedia(ctx context.Context, rawVideoURL string) (ProviderMedia, error) {
	idx, shareURL, ok := decodeNetdiskVideoRef(rawVideoURL)
	if !ok {
		return ProviderMedia{}, errors.New("无效的网盘播放引用")
	}
	netdiskMu.Lock()
	rt := netdiskRT
	netdiskMu.Unlock()
	if rt == nil || rt.store == nil {
		return ProviderMedia{}, errors.New("网盘模块尚未初始化")
	}
	provider := netdisk.NormalizeProvider(netdisk.DetectProvider(shareURL))
	creds, err := rt.store.Get(provider)
	if err != nil {
		return ProviderMedia{}, netdisk.ErrNotLoggedIn
	}
	if !netdisk.ProviderReady(creds) {
		return ProviderMedia{}, errors.New("网盘登录态不完整，请先扫码登录 " + netdiskBadge(provider))
	}
	var play *netdisk.Playback
	if provider == "uc" {
		play, err = netdisk.NewUC(creds).ResolveShare(ctx, shareURL, idx)
	} else {
		play, err = netdisk.NewQuark(creds).ResolveShare(ctx, shareURL, idx)
	}
	if err != nil {
		return ProviderMedia{}, err
	}
	parsed, _ := url.Parse(play.URL)
	ua := play.Headers["User-Agent"]
	if ua == "" {
		ua = UserAgent
	}
	referer := play.Headers["Referer"]
	if referer == "" {
		if provider == "uc" {
			referer = "https://drive.uc.cn/"
		} else {
			referer = "https://pan.quark.cn/"
		}
	}
	return ProviderMedia{
		URL:     play.URL,
		Referer: referer,
		Credentials: &MediaCredentials{
			Cookie:    play.Headers["Cookie"],
			Origin:    ProviderMediaOrigin(parsed),
			Referer:   referer,
			UserAgent: ua,
		},
	}, nil
}

type netdiskProvider struct{}

func (p *netdiskProvider) Descriptor() SourceDescriptor {
	desc, _ := registeredDescriptor("netdisk")
	return desc
}

func (p *netdiskProvider) Categories(context.Context, bool) ([]Category, error) {
	return []Category{{ID: "all", Name: "全部"}}, nil
}

func (p *netdiskProvider) CatalogPage(context.Context, int, string) ([]Drama, bool, error) {
	return []Drama{}, false, nil
}

func (p *netdiskProvider) Detail(ctx context.Context, sourceID string) (Drama, []Chapter, error) {
	netdiskMu.Lock()
	rt := netdiskRT
	netdiskMu.Unlock()
	provider := netdisk.NormalizeProvider(netdisk.DetectProvider(sourceID))
	var creds *netdisk.Credentials
	if rt != nil && rt.store != nil {
		creds, _ = rt.store.Get(provider)
	}
	var info *netdisk.ShareInfo
	var err error
	if provider == "uc" {
		info, err = netdisk.NewUC(creds).Share(ctx, sourceID)
	} else {
		info, err = netdisk.NewQuark(creds).Share(ctx, sourceID)
	}
	if err != nil {
		return Drama{}, nil, err
	}
	drama, chapters := shareInfoToDrama("netdisk", sourceID, info)
	return drama, chapters, nil
}

func (p *netdiskProvider) ResolveMedia(ctx context.Context, task Task) (ProviderMedia, error) {
	return resolveNetdiskMedia(ctx, task.Chapter.VideoURL)
}

package core

// 站源可选能力接口（上游 guoappxpx 契约）。
//
// 上游把「详情页补封面 / 补元数据 / 系列剧 / 弹幕 / 设备注册 / 推荐流 / 搜索建议 /
// 榜单 / 目录状态」都做成可选接口，站源按需实现，运行时用类型断言调用。
// guoappxp 这些能力原先硬编码在 nativeEngine 里（只服务红果等内置源），
// 外置源无法参与。这里补齐接口定义，并让运行时优先走站源实现。
//
// 新增上游源时只需 import core 并实现对应方法，不必回来改 core。

import (
	"context"
	"encoding/json"
	"errors"
	"net/url"
)

// LibraryDrama 是站源侧看到的剧集形态，与 nativeDrama 同构。
// 用别名而不是新结构，避免两边字段漂移导致转换丢数据。
type LibraryDrama = nativeDrama

// LibraryMoreKey 标记「本页请求来自翻页」，站源据此决定是否返回连续流。
type LibraryMoreKey = libraryMoreKey

// ErrCategoriesIncomplete 表示分类只拿到一部分（站点分页抓取中途失败）。
// 站源返回它时，运行时会保留已拿到的分类并允许下次重试，而不是整源报错。
var ErrCategoriesIncomplete = errors.New("categories incomplete")

// CoverRepairer 让站源自己修补封面地址（域名轮换、加签名等）。
type CoverRepairer interface {
	RepairCover(drama LibraryDrama) string
}

// CoverResolver 让站源自己解析封面（比通用 Detail 取封面更省一次请求）。
type CoverResolver interface {
	CoverAddress(ctx context.Context, drama LibraryDrama, sourceID string) (string, error)
}

// CoverRefererProvider 让站源给封面请求指定 Referer（图床防盗链）。
type CoverRefererProvider interface {
	CoverReferer(address string) string
}

// MediaAuthorizer 让站源给播放请求加鉴权头（临时 token / 签名）。
type MediaAuthorizer interface {
	AuthorizesMedia(address *url.URL) bool
	MediaAuthorization(ctx context.Context, address *url.URL, referer string) (header, value string, err error)
	RejectMediaAuthorization(address *url.URL, value string)
}

// MetadataEnricher 让站源补齐详情页额外的元数据（评分、热度、标签等）。
type MetadataEnricher interface {
	NeedsExtraMetadata(drama LibraryDrama) bool
	ExtraMetadata(ctx context.Context, drama LibraryDrama, sourceID string) (LibraryDrama, error)
}

// Season 是一季的概要。
type Season struct {
	Number int
	Drama  Drama
}

// SeasonProvider 让站源提供系列剧的多季数据。
type SeasonProvider interface {
	Seasons(ctx context.Context, sourceID string) ([]Season, error)
}

// DeviceProvider 让站源自己管理设备注册（红果系的设备池）。
type DeviceProvider interface {
	Devices(ctx context.Context, register bool) (bool, error)
}

// DanmakuItem / DanmakuPage 是弹幕的条目与分页。
type DanmakuItem struct {
	ID     string `json:"id"`
	Text   string `json:"text"`
	TimeMS int64  `json:"timeMs"`
}

type DanmakuPage struct {
	EpisodeID string        `json:"episodeId"`
	Items     []DanmakuItem `json:"items"`
	StartMS   int64         `json:"startMs"`
	NextMS    int64         `json:"nextMs"`
	Total     int64         `json:"total"`
}

// DanmakuMaxDurationMS 是弹幕单次请求允许的最大时间跨度（10 分钟）。
const DanmakuMaxDurationMS int64 = 10 * 60 * 1000

// DanmakuProvider 让站源提供弹幕。
type DanmakuProvider interface {
	DanmakuIDs(task Task) (series, video string, ok bool)
	Danmaku(ctx context.Context, series, video string, startMS, durationMS int64) (DanmakuPage, error)
}

// RecommendationPage 是推荐流的一页。
type RecommendationPage struct {
	Dramas  []Drama
	Cursor  json.RawMessage
	HasMore bool
}

// Recommender 让站源提供「发现 / 推荐」信息流。
type Recommender interface {
	ValidRecommendation(genre string, cursor json.RawMessage) error
	Recommendations(ctx context.Context, genre string, cursor json.RawMessage, seen []string) (RecommendationPage, error)
}

// Suggester 让站源提供搜索联想词。
type Suggester interface {
	Suggestions(ctx context.Context, query string) ([]string, error)
}

// CatalogStateful 让站源保存/恢复目录翻页游标（连续信息流类站源需要）。
type CatalogStateful interface {
	CatalogState() json.RawMessage
	RestoreCatalogState(raw json.RawMessage)
}

// —— 运行时派发：优先站源实现，没有就回落到原有内置逻辑 ——

// providerOf 取站源实例，未编入返回 nil。
func (d *Downloader) providerOf(source string) Provider {
	provider, ok := d.sourceProvider(source)
	if !ok {
		return nil
	}
	return provider
}

// providerCoverRepair 让站源补封面，未实现返回空串由调用方回落。
func (d *Downloader) providerCoverRepair(drama nativeDrama) string {
	for _, source := range []string{drama.Source, sourceFromDramaID(drama.ID)} {
		provider := d.providerOf(source)
		if provider == nil {
			continue
		}
		if repairer, ok := provider.(CoverRepairer); ok {
			if cover := repairer.RepairCover(drama); cover != "" {
				return cover
			}
		}
	}
	return ""
}

// providerCoverAddress 让站源自己解析封面。
func (d *Downloader) providerCoverAddress(ctx context.Context, drama nativeDrama, sourceID string) (string, bool, error) {
	provider := d.providerOf(drama.Source)
	if provider == nil {
		return "", false, nil
	}
	resolver, ok := provider.(CoverResolver)
	if !ok {
		return "", false, nil
	}
	cover, err := resolver.CoverAddress(ctx, drama, sourceID)
	return cover, true, err
}

// providerCoverReferer 让站源指定封面请求的 Referer。
func (d *Downloader) providerCoverReferer(source, address string) string {
	provider := d.providerOf(source)
	if provider == nil {
		return ""
	}
	if referer, ok := provider.(CoverRefererProvider); ok {
		return referer.CoverReferer(address)
	}
	return ""
}

// providerMediaAuthorizer 找到负责这个播放地址的站源鉴权器。
func (d *Downloader) providerMediaAuthorizer(address *url.URL) MediaAuthorizer {
	for _, descriptor := range RegisteredSources() {
		provider := d.providerOf(descriptor.ID)
		if provider == nil {
			continue
		}
		if authorizer, ok := provider.(MediaAuthorizer); ok && authorizer.AuthorizesMedia(address) {
			return authorizer
		}
	}
	return nil
}

// providerNeedsExtraMetadata 判断站源是否要求补元数据。
func (d *Downloader) providerNeedsExtraMetadata(drama nativeDrama) bool {
	provider := d.providerOf(drama.Source)
	if provider == nil {
		return false
	}
	enricher, ok := provider.(MetadataEnricher)
	return ok && enricher.NeedsExtraMetadata(drama)
}

// providerExtraMetadata 让站源补元数据。
func (d *Downloader) providerExtraMetadata(ctx context.Context, drama nativeDrama, sourceID string) (nativeDrama, bool, error) {
	provider := d.providerOf(drama.Source)
	if provider == nil {
		return drama, false, nil
	}
	enricher, ok := provider.(MetadataEnricher)
	if !ok || !enricher.NeedsExtraMetadata(drama) {
		return drama, false, nil
	}
	fresh, err := enricher.ExtraMetadata(ctx, drama, sourceID)
	return fresh, true, err
}

// providerSeasons 让站源提供多季数据。
func (d *Downloader) providerSeasons(ctx context.Context, drama nativeDrama, sourceID string) ([]nativeSeason, bool, error) {
	provider := d.providerOf(drama.Source)
	if provider == nil {
		return nil, false, nil
	}
	seasons, ok := provider.(SeasonProvider)
	if !ok {
		return nil, false, nil
	}
	items, err := seasons.Seasons(ctx, sourceID)
	if err != nil {
		return nil, true, err
	}
	out := make([]nativeSeason, 0, len(items))
	for _, item := range items {
		out = append(out, nativeSeason{Number: item.Number, Drama: nativeNormalize(item.Drama)})
	}
	return out, true, nil
}

// providerDevices 让站源自己管设备注册。
func (d *Downloader) providerDevices(ctx context.Context, source string, register bool) (bool, bool, error) {
	provider := d.providerOf(source)
	if provider == nil {
		return false, false, nil
	}
	devices, ok := provider.(DeviceProvider)
	if !ok {
		return false, false, nil
	}
	registered, err := devices.Devices(ctx, register)
	return registered, true, err
}

// providerDanmaku 让站源提供弹幕。
func (d *Downloader) providerDanmaku(ctx context.Context, task Task, startMS, durationMS int64) (DanmakuPage, bool, error) {
	provider := d.providerOf(task.Chapter.Source)
	if provider == nil {
		provider = d.providerOf(sourceFromDramaID(task.DramaID))
	}
	if provider == nil {
		return DanmakuPage{}, false, nil
	}
	danmaku, ok := provider.(DanmakuProvider)
	if !ok {
		return DanmakuPage{}, false, nil
	}
	series, video, valid := danmaku.DanmakuIDs(task)
	if !valid {
		return DanmakuPage{}, false, nil
	}
	if durationMS <= 0 || durationMS > DanmakuMaxDurationMS {
		durationMS = DanmakuMaxDurationMS
	}
	page, err := danmaku.Danmaku(ctx, series, video, startMS, durationMS)
	return page, true, err
}

// providerSuggestions 让站源提供搜索联想词。
func (d *Downloader) providerSuggestions(ctx context.Context, source, query string) ([]string, bool, error) {
	provider := d.providerOf(source)
	if provider == nil {
		return nil, false, nil
	}
	suggester, ok := provider.(Suggester)
	if !ok {
		return nil, false, nil
	}
	items, err := suggester.Suggestions(ctx, query)
	return items, true, err
}

// providerCatalogState 取站源的目录游标快照。
func (d *Downloader) providerCatalogState(source string) (json.RawMessage, bool) {
	provider := d.providerOf(source)
	if provider == nil {
		return nil, false
	}
	stateful, ok := provider.(CatalogStateful)
	if !ok {
		return nil, false
	}
	return stateful.CatalogState(), true
}

// restoreProviderCatalogState 把上次的目录游标还给站源。
func (d *Downloader) restoreProviderCatalogState(source string, raw json.RawMessage) bool {
	provider := d.providerOf(source)
	if provider == nil {
		return false
	}
	stateful, ok := provider.(CatalogStateful)
	if !ok {
		return false
	}
	stateful.RestoreCatalogState(raw)
	return true
}

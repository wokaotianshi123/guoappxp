package core

// Register 是外置源契约的注册入口。编译期拼装的站源集合必须固定：ID 重复或为空
// 直接 panic，让冲突在出包时暴露，而不是装到设备上才出错。

import (
	"context"
	"errors"
	"net/url"
	"strings"
)

func Register(descriptor SourceDescriptor, factory ProviderFactory) {
	id := strings.ToLower(strings.TrimSpace(descriptor.ID))
	if id == "" || factory == nil {
		panic("core.Register: empty source id or nil factory")
	}
	descriptor.ID = id
	sourceRegistry.Lock()
	defer sourceRegistry.Unlock()
	if _, exists := sourceRegistry.factories[id]; exists {
		panic("core: 站源 ID 重复: " + id)
	}
	sourceRegistry.factories[id] = factory
	sourceRegistry.descriptors[id] = descriptor
	sourceRegistry.order = append(sourceRegistry.order, id)
}

// registeredProviderSource 供门卫判断「这个 ID 是否已编入」，避免每加一个新源
// 都要往硬编码白名单里补一行。
func registeredProviderSource(source string) bool {
	sourceRegistry.RLock()
	_, ok := sourceRegistry.factories[source]
	sourceRegistry.RUnlock()
	return ok
}

// providerCategories 取站源分类。失败时返回 nil 而不是把错误抛给调用方：
// 分类抓不到不该连带把目录也打空，上层会回退上次成功的缓存或只展示「全部」。
func providerCategories(ctx context.Context, provider Provider, force bool) []Category {
	categories, err := provider.Categories(ctx, force)
	if err != nil {
		return nil
	}
	return categories
}

// providerSearch 是搜索的统一派发口：优先带警告的搜索（站点会提示结果被截断），
// 其次普通搜索；两者都没实现的源返回 errSearchUnsupported，让调用方决定是提示
// 用户（单源）还是静默跳过（跨源聚合）。
func providerSearch(ctx context.Context, provider Provider, page int, query string) ([]Drama, bool, error) {
	if searcher, ok := provider.(WarningSearcher); ok {
		dramas, more, _, err := searcher.SearchWithWarning(ctx, page, query)
		return dramas, more, err
	}
	if searcher, ok := provider.(Searcher); ok {
		return searcher.Search(ctx, page, query)
	}
	return nil, false, errSearchUnsupported
}

// providerRankingPage 取榜单列表。只声明了「带名次的条目」的源（如黄果 AI）
// 去掉名次信息后回退成剧集列表，保证两类源在榜单页表现一致。
func providerRankingPage(ctx context.Context, provider Provider, board string, page int) ([]Drama, bool, error) {
	if ranker, ok := provider.(SourceRankings); ok {
		return ranker.RankingPage(ctx, board, page)
	}
	if ranker, ok := provider.(SourceRankingEntries); ok {
		entries, more, err := ranker.RankingEntries(ctx, board, page)
		if err != nil {
			return nil, false, err
		}
		dramas := make([]Drama, 0, len(entries))
		for _, entry := range entries {
			dramas = append(dramas, entry.Drama)
		}
		return dramas, more, nil
	}
	return nil, false, errors.New("该站源不支持榜单")
}

// providerRankingEntries 取带名次的榜单条目。只实现了「按页取剧集」的源（如黄豆）
// 按运行时的旧口径补名次与热度文案，保证改造前后榜单一模一样。
func providerRankingEntries(ctx context.Context, provider Provider, board string, page int) ([]RankingEntry, bool, error) {
	if ranker, ok := provider.(SourceRankingEntries); ok {
		return ranker.RankingEntries(ctx, board, page)
	}
	if ranker, ok := provider.(SourceRankings); ok {
		dramas, more, err := ranker.RankingPage(ctx, board, page)
		if err != nil {
			return nil, false, err
		}
		entries := make([]RankingEntry, 0, len(dramas))
		for index, drama := range dramas {
			metric := ""
			if drama.Heat != "" {
				metric = drama.Heat + "热度"
			}
			entries = append(entries, RankingEntry{Rank: (page-1)*20 + index + 1, Drama: drama, Metric: metric})
		}
		return entries, more, nil
	}
	return nil, false, errors.New("该站源不支持榜单")
}

// HongguoAppRequest 让外置源包里的红果 App 客户端复用 core 的设备签名与
// 公共参数管道。外置源只持有 Host，拿不到未导出的 Downloader 方法，故由此桥接。
func HongguoAppRequest(ctx context.Context, host Host, method, path string, extra url.Values, payload any) (map[string]any, error) {
	wrapped, ok := host.(*xpxHost)
	if !ok || wrapped.d == nil {
		return nil, errors.New("红果 App 接口需要运行时 Host")
	}
	return wrapped.d.hongguoAppRequest(ctx, method, path, extra, payload)
}

// HongguoContentKey 解开红果播放信息里的 spade_a / encryption_key，得到 CENC key。
func HongguoContentKey(value string) ([]byte, error) {
	return hongguoContentKey(value)
}

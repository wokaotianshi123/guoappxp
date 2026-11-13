package core

import (
	"context"
	"strings"
)

// fanqieBuiltinDescriptor 是 core 内置番茄短剧源的描述符。
// ValidCategory 必须是纯函数：分类探针没有实例、不带 Host。
var fanqieBuiltinDescriptor = SourceDescriptor{
	ID:            sourceFanqie,
	Name:          "番茄",
	Description:   "番茄短剧（core 内置，未编入外置站源模块时兜底）",
	ValidCategory: fanqieBuiltinValidCategory,
}

// fanqieBuiltinProvider 把 core 内置的番茄短剧实现包装成 Provider。
//
// 它刻意**不**注册进全局注册表：真果鉴里外置站源模块若也提供 fanqie，
// 注册表优先、走外置实现，两边不会因 ID 重复触发 Register 的 panic；
// 红果鉴（不接外置模块）则由 sourceProvider() 回落到这里，番茄短剧源照常可用。
// 番茄内容引擎由 Flutter 侧 FanqieBackend 拉起，宿主链路两种版本都保留。
type fanqieBuiltinProvider struct {
	d *Downloader
}

func (p *fanqieBuiltinProvider) Descriptor() SourceDescriptor {
	return fanqieBuiltinDescriptor
}

func (p *fanqieBuiltinProvider) Categories(context.Context, bool) ([]Category, error) {
	return []Category{
		{ID: fanqieCategoryKanju, Name: "看剧"},
		{ID: fanqieCategoryManju, Name: "漫剧"},
	}, nil
}

func (p *fanqieBuiltinProvider) CatalogPage(
	ctx context.Context,
	page int,
	category string,
) ([]Drama, bool, error) {
	return p.d.fetchFanqieCatalogPage(ctx, category, page)
}

// Search 独立于 CatalogPage：上游契约把搜索拆出目录，空关键字直接返回空结果。
func (p *fanqieBuiltinProvider) Search(
	ctx context.Context,
	page int,
	query string,
) ([]Drama, bool, error) {
	if strings.TrimSpace(query) == "" {
		return nil, false, nil
	}
	return p.d.fetchFanqieSearchPage(ctx, page, query)
}

func (p *fanqieBuiltinProvider) Detail(
	ctx context.Context,
	sourceID string,
) (Drama, []Chapter, error) {
	return p.d.fetchFanqieDetail(ctx, sourceID)
}

func (p *fanqieBuiltinProvider) ResolveMedia(
	ctx context.Context,
	task Task,
) (ProviderMedia, error) {
	return p.d.resolveFanqieMedia(ctx, task.Chapter, task.Quality)
}

// fanqieBuiltinValidCategory 供分类校验的探针路径使用：那里没有 Downloader
// 实例，只能做纯函数判断（看剧 / 漫剧两个固定频道，空分类一律放行）。
func fanqieBuiltinValidCategory(category string) bool {
	if strings.TrimSpace(category) == "" {
		return true
	}
	_, ok := fanqieCategoryTabTypes[category]
	return ok
}

// fanqieBuiltinSource 在注册表里没有 fanqie 时返回内置实现，并复用
// Downloader 的站源实例缓存，保证翻页游标等状态在同一实例内保持一致。
func (d *Downloader) fanqieBuiltinSource(source string) (Provider, bool) {
	if source != sourceFanqie {
		return nil, false
	}
	d.sourceProviderMu.Lock()
	defer d.sourceProviderMu.Unlock()
	if provider, exists := d.sourceProviders[source]; exists {
		return provider, true
	}
	provider := &fanqieBuiltinProvider{d: d}
	if d.sourceProviders == nil {
		d.sourceProviders = map[string]Provider{}
	}
	d.sourceProviders[source] = provider
	return provider, true
}

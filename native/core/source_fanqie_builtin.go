package core

import (
	"context"
	"strings"
)

// fanqieBuiltinProvider 把 core 内置的番茄短剧实现包装成 SourceProvider。
//
// 它刻意**不**注册进全局注册表：真果鉴里外置站源模块若也提供 fanqie，
// 注册表优先、走外置实现，两边不会因 ID 重复触发 RegisterSource 的 panic；
// 红果鉴（不接外置模块）则由 sourceProvider() 回落到这里，番茄短剧源照常可用。
// 番茄内容引擎由 Flutter 侧 FanqieBackend 拉起，宿主链路两种版本都保留。
type fanqieBuiltinProvider struct {
	d *Downloader
}

func (p *fanqieBuiltinProvider) Categories() []NativeCategory {
	return []NativeCategory{
		{ID: fanqieCategoryKanju, Name: "看剧"},
		{ID: fanqieCategoryManju, Name: "漫剧"},
	}
}

func (p *fanqieBuiltinProvider) ValidCategory(category string) bool {
	return fanqieBuiltinValidCategory(category)
}

func (p *fanqieBuiltinProvider) CatalogPage(
	ctx context.Context,
	page int,
	category, query string,
) ([]Drama, bool, error) {
	if strings.TrimSpace(query) != "" {
		return p.d.fetchFanqieSearchPage(ctx, page, query)
	}
	return p.d.fetchFanqieCatalogPage(ctx, category, page)
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
func (d *Downloader) fanqieBuiltinSource(source string) (SourceProvider, bool) {
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
		d.sourceProviders = map[string]SourceProvider{}
	}
	d.sourceProviders[source] = provider
	return provider, true
}

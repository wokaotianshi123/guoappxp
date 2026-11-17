package core

import (
	"context"
	"errors"
)

type nativeSeason struct {
	Number int          `json:"number"`
	Drama  LibraryDrama `json:"drama"`
}

func (engine *nativeEngine) nativeSeasons(ctx context.Context, drama LibraryDrama) (any, error) {
	source, sourceID, valid := SplitProviderDramaID(drama.ID)
	if !valid {
		return nil, errors.New("剧集信息无效")
	}
	items := []nativeSeason{}
	// 自定义源（MacCMS / XBPQ 规则）没有 provider，也不提供「分季」能力，
	// 优雅降级为空列表，而不是报「请选择有效站源」把整个详情拦下来。
	p, ok := engine.downloader.provider(source)
	if !ok {
		if isCustomMaccmsSource(source) {
			return map[string]any{"items": items}, nil
		}
		return nil, errors.New("请选择有效站源")
	}
	provider, ok := providerAs[SeasonProvider](p)
	if !ok {
		return map[string]any{"items": items}, nil
	}
	seasons, err := provider.Seasons(ctx, sourceID)
	if err != nil {
		return nil, err
	}
	current := false
	for _, season := range seasons {
		item := NativeNormalize(season.Drama)
		if item.ID == drama.ID {
			item, current = MergeNativeDrama(drama, item), true
		}
		items = append(items, nativeSeason{Number: season.Number, Drama: item})
	}
	if !current || len(items) < 2 {
		items = items[:0]
	}
	return map[string]any{"items": items}, nil
}

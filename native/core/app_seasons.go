package core

import (
	"context"
	"errors"
	"sort"
)

// nativeSeason 是一季的概要，供详情页「系列多季」卡片条使用。
type nativeSeason struct {
	Number int         `json:"number"`
	Drama  nativeDrama `json:"drama"`
}

// nativeSeasons 返回当前剧所属系列的各季。不足两季时返回空列表，
// 界面据此决定是否显示卡片条。
func (engine *nativeEngine) nativeSeasons(ctx context.Context, drama nativeDrama) (any, error) {
	source, sourceID, valid := splitProviderDramaID(drama.ID)
	if !valid {
		return nil, errors.New("剧集信息无效")
	}
	items := []nativeSeason{}
	fromProvider := false
	// 站源实现了 SeasonProvider 就先收下它给的结果（上游契约）。
	if seasons, handled, err := engine.downloader.providerSeasons(ctx, drama, sourceID); handled && err == nil {
		fromProvider = true
		for _, season := range seasons {
			item := season.Drama
			if item.ID == drama.ID {
				// 当前这一季沿用界面已有的标题 / 封面 / 分类，避免卡片条信息回退。
				item = mergeNativeDrama(drama, item)
			}
			items = append(items, nativeSeason{Number: season.Number, Drama: item})
		}
	}
	// 桌面端（Windows / macOS）的站源来自外置源包，SeasonProvider 常常
	// 返回空或只给当前一季；移动端进程内则走内置的「基础名 + 季号」补搜。
	// 红果一律再用内置实现兜底并与外置结果取并集，保证「系列多季」在
	// 各平台都出现，且包含不带季号的第一季。
	if source == sourceHongguo {
		if builtin, err := engine.downloader.hongguoSeriesSeasons(ctx, sourceID, drama.Title); err == nil {
			items = mergeNativeSeasons(items, builtin, drama)
		} else if !fromProvider {
			return nil, err
		}
	}
	current := false
	for _, item := range items {
		if item.Drama.ID == drama.ID {
			current = true
			break
		}
	}
	if !current || len(items) < 2 {
		items = []nativeSeason{}
	}
	return map[string]any{"items": items}, nil
}

// mergeNativeSeasons 把内置补搜到的季并入外置源结果，按季号 / 剧 ID 去重，
// 同一季号只保留一条，最后按季号升序排列。
func mergeNativeSeasons(existing []nativeSeason, builtin []hongguoSeason, anchor nativeDrama) []nativeSeason {
	out := append([]nativeSeason(nil), existing...)
	bySeason := map[int]bool{}
	byID := map[string]bool{}
	for _, item := range out {
		bySeason[item.Number] = true
		byID[item.Drama.ID] = true
	}
	for _, season := range builtin {
		item := nativeNormalize(season.Drama)
		if item.ID == anchor.ID {
			item = mergeNativeDrama(anchor, item)
		}
		if bySeason[season.Number] || byID[item.ID] {
			continue
		}
		bySeason[season.Number] = true
		byID[item.ID] = true
		out = append(out, nativeSeason{Number: season.Number, Drama: item})
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Number < out[j].Number })
	return out
}

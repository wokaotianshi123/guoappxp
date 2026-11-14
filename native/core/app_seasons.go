package core

import (
	"context"
	"errors"
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
	// 站源实现了 SeasonProvider 就优先用它（上游契约），否则走内置源的特例。
	if seasons, handled, err := engine.downloader.providerSeasons(ctx, drama, sourceID); handled {
		if err != nil {
			return nil, err
		}
		for _, season := range seasons {
			item := season.Drama
			if item.ID == drama.ID {
				// 当前这一季沿用界面已有的标题 / 封面 / 分类，避免卡片条信息回退。
				item = mergeNativeDrama(drama, item)
			}
			items = append(items, nativeSeason{Number: season.Number, Drama: item})
		}
	} else {
		switch source {
		case sourceHongguo:
			seasons, err := engine.downloader.hongguoSeriesSeasons(ctx, sourceID, drama.Title)
			if err != nil {
				return nil, err
			}
			for _, season := range seasons {
				item := nativeNormalize(season.Drama)
				if item.ID == drama.ID {
					item = mergeNativeDrama(drama, item)
				}
				items = append(items, nativeSeason{Number: season.Number, Drama: item})
			}
		default:
			// 其它站源暂无系列剧数据，返回空列表即可。
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

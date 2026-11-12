package core

import (
	"context"
	"errors"
	"net/url"
	"time"
)

func nativeNeedsExtraMetadata(drama nativeDrama) bool {
	return drama.Source == sourceHongguo && drama.OnlineDate == "" ||
		drama.Source == sourceHuangdou && (drama.Heat == "" || drama.VIP == nil)
}

func (engine *nativeEngine) nativeExtraMetadata(ctx context.Context, drama nativeDrama) (nativeDrama, error) {
	source, id, valid := splitProviderDramaID(drama.ID)
	if !valid {
		return drama, errors.New("剧集信息无效")
	}
	if !nativeNeedsExtraMetadata(drama) {
		return drama, nil
	}
	ctx, cancel := context.WithTimeout(context.WithValue(ctx, backgroundCatalogKey{}, true), 15*time.Second)
	defer cancel()
	var raw Drama
	switch source {
	case sourceHongguo:
		if !hongguoNumericID.MatchString(id) {
			return drama, errors.New("红果剧集 ID 无效")
		}
		body, err := engine.downloader.fetchProviderText(ctx, hongguoBaseURL+"/detail?series_id="+url.QueryEscape(id), hongguoBaseURL+"/")
		if err != nil {
			return drama, err
		}
		raw, err = parseHongguoSortDetail(body, id)
		if err != nil {
			return drama, err
		}
	default:
		// 已外置的站源自己补齐元数据（黄豆的热度就是它在详情里补的）。
		provider, ok := engine.downloader.sourceProvider(source)
		if !ok {
			return drama, nil
		}
		fresh, _, err := provider.Detail(ctx, id)
		if err != nil {
			return drama, err
		}
		raw = fresh
	}
	if raw.ID == drama.ID {
		drama = mergeNativeDrama(drama, nativeNormalize(raw))
	}
	return drama, ctx.Err()
}

func (engine *nativeEngine) nativeFollowCheck(ctx context.Context, drama nativeDrama) (any, error) {
	ctx, cancel := context.WithTimeout(context.WithValue(ctx, backgroundCatalogKey{}, true), 20*time.Second)
	defer cancel()
	result, err := engine.nativeDetail(ctx, drama)
	if err != nil {
		return nil, err
	}
	return map[string]any{"drama": result.(map[string]any)["drama"]}, nil
}

func (engine *nativeEngine) nativeMetadata(ctx context.Context, drama nativeDrama) (any, error) {
	fresh, err := engine.nativeExtraMetadata(ctx, drama)
	if err != nil {
		return nil, err
	}
	warning := ""
	if err := engine.saveDetailMetadata(fresh); err != nil {
		warning = err.Error()
	}
	return map[string]any{"drama": fresh, "warning": warning}, nil
}

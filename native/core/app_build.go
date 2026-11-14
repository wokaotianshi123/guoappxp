package core

import "errors"

var buildAllSources = "false"

var errNativeBuildSource = errors.New("当前版本不包含此站源")

// 已下线的站源：站点长期不可达、采集接口关闭，或体验明显不达标，
// 从产品里整体移除。ID 常量与归一化映射仍保留，让旧收藏、播放记录里的这些
// ID 能被正确识别（不至于变成「未知源」而丢失历史数据），但它们一律判定为
// 不可用，列表、授权、聚合搜索、目录、取流都不会再带上它们。
var removedProviderSources = map[string]bool{
	sourceHeitao:  true,
	sourceGuanguo: true,
	sourceFaguo:   true,
	sourceWuguo:   true,
	// 芽果 / 猫果 / 河果 / 星果 / 牛果：接口频繁失效或内容质量差，整体下线。
	sourceYaguo:   true,
	sourceMaoguo:  true,
	sourceHeguo:   true,
	sourceXingguo: true,
	sourceNiuguo:  true,
}

func nativeSourceAvailable(source string) bool {
	source = canonicalProviderSource(source)
	// 已下线的站源一律不可用，优先于内置源与全站源门控。
	if removedProviderSources[source] {
		return false
	}
	// 红果与番茄是 core 内置源，红果鉴 / 真果鉴都保留。番茄短剧实现已回迁到
	// core（见 provider_fanqie.go / source_fanqie_builtin.go），不依赖外置站源
	// 模块，因此不再随 buildAllSources 门控。注意与「番茄听书」区分——听书走
	// audiobookFetch/Text/Media 独立 action，不经本函数，两种版本都保留。
	if source == sourceHongguo || source == sourceFanqie {
		return true
	}
	if isCustomMaccmsSource(source) {
		return isHuangguoProviderSource(source)
	}
	return buildAllSources == "true" && isHuangguoProviderSource(source)
}

func nativeDramaAvailable(drama nativeDrama) bool {
	source, _, valid := splitProviderDramaID(drama.ID)
	return valid && nativeSourceAvailable(source) &&
		(drama.Source == "" || canonicalProviderSource(drama.Source) == source)
}

func nativeChapterAvailable(drama nativeDrama, chapter Chapter) bool {
	if !nativeDramaAvailable(drama) {
		return false
	}
	source, _, _ := splitProviderDramaID(drama.ID)
	if chapter.Source != "" && canonicalProviderSource(chapter.Source) != source {
		return false
	}
	if chapterSource, _, valid := splitProviderDramaID(chapter.ID); valid && chapterSource != source {
		return false
	}
	return true
}

func nativeDownloadAvailable(job nativeDownloadJob) bool {
	return nativeChapterAvailable(job.Drama, job.Chapter)
}

func nativeAuthorizeInput(input nativeInput) error {
	switch input.Action {
	case "recommendations", "cachedRecommendations", "suggestions", "danmaku":
		if !nativeSourceAvailable(sourceHongguo) {
			return errNativeBuildSource
		}
	case "rankings":
		board, found := findRankingBoard(input.Board)
		if !found || !nativeSourceAvailable(board.Source) {
			return errNativeBuildSource
		}
	case "soraniAccount":
		if !nativeSourceAvailable(sourceSorani) {
			return errNativeBuildSource
		}
	case "catalog", "cached", "categories", "sourceStatus":
		if !nativeSourceAvailable(input.Source) {
			return errNativeBuildSource
		}
	case "cover", "prepareCover", "detail", "metadata", "followCheck", "resolve", "preload", "enqueueDownloads", "localPlayback":
		if !nativeDramaAvailable(input.Drama) {
			return errNativeBuildSource
		}
		if (input.Action == "resolve" || input.Action == "preload") && !nativeChapterAvailable(input.Drama, input.Chapter) {
			return errNativeBuildSource
		}
	}
	return nil
}

package core

import "errors"

var buildAllSources = "false"

var errNativeBuildSource = errors.New("当前版本不包含此站源")

func nativeSourceAvailable(source string) bool {
	source = canonicalProviderSource(source)
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

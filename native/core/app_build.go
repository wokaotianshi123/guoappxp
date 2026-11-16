package core

import "errors"

var errNativeBuildSource = errors.New("当前版本不包含此站源")

func nativeSourceAvailable(source string) bool {
	source = canonicalProviderSource(source)
	if _, ok := registeredDescriptor(source); ok {
		return true
	}
	// 自定义源（MacCMS 站点 / XBPQ 规则）不进 provider 注册表，它存在引擎自己的
	// 自定义源清单里。只查注册表会把它们一律判成 false，表现为「站源名能显示，
	// 一点就报当前版本不包含此站源」。这里与 nativeSourceSupportsSearch 的兜底
	// 写法保持一致：注册表命中，或者是个自定义源。
	return isCustomMaccmsSource(source)
}

func nativeDramaAvailable(drama LibraryDrama) bool {
	source, _, valid := SplitProviderDramaID(drama.ID)
	return valid && nativeSourceAvailable(source) &&
		(drama.Source == "" || canonicalProviderSource(drama.Source) == source)
}

func nativeChapterAvailable(drama LibraryDrama, chapter Chapter) bool {
	if !nativeDramaAvailable(drama) {
		return false
	}
	source, _, _ := SplitProviderDramaID(drama.ID)
	if chapter.Source != "" && canonicalProviderSource(chapter.Source) != source {
		return false
	}
	if chapterSource, _, valid := SplitProviderDramaID(chapter.ID); valid && chapterSource != source {
		return false
	}
	return true
}

func nativeDownloadAvailable(job nativeDownloadJob) bool {
	return nativeChapterAvailable(job.Drama, job.Chapter)
}

func nativeActionSource(input nativeInput) string {
	if input.Source != "" {
		return canonicalProviderSource(input.Source)
	}
	if input.Action == "soraniAccount" {
		return "sorani"
	}
	return ""
}

func nativeAuthorizeInput(input nativeInput) error {
	switch input.Action {
	case "recommendations", "cachedRecommendations", "suggestions", "soraniAccount", "sourceAccount":
		if !nativeSourceAvailable(nativeActionSource(input)) {
			return errNativeBuildSource
		}
	case "rankings":
		board, found := findRankingBoard(input.Board)
		if !found || !nativeSourceAvailable(board.Source) {
			return errNativeBuildSource
		}
	case "catalog", "cached", "categories", "sourceStatus":
		if !nativeSourceAvailable(input.Source) {
			return errNativeBuildSource
		}
	case "cast":
		if input.Command == "play" && !nativeChapterAvailable(input.Drama, input.Chapter) {
			return errNativeBuildSource
		}
	case "cover", "prepareCover", "detail", "seasons", "metadata", "followCheck", "resolve", "preload", "enqueueDownloads", "localPlayback":
		if !nativeDramaAvailable(input.Drama) {
			return errNativeBuildSource
		}
		if (input.Action == "resolve" || input.Action == "preload") && !nativeChapterAvailable(input.Drama, input.Chapter) {
			return errNativeBuildSource
		}
	}
	return nil
}

package core

import "context"

type libraryProgressKey struct{}

type libraryProgressFunc func(string, []Drama, error, bool)

func reportLibraryProgress(ctx context.Context, source string, items []Drama, err error, done bool) {
	if callback, ok := ctx.Value(libraryProgressKey{}).(libraryProgressFunc); ok && (done || len(items) > 0) {
		callback(source, items, err, done)
	}
}

// ReportLibraryProgress 是对外名字（上游站源契约）：站源模块抓到一批剧集后
// 即时上报，界面可以边抓边显示，而不必等整轮目录请求结束。
func ReportLibraryProgress(ctx context.Context, source string, items []Drama, err error, done bool) {
	reportLibraryProgress(ctx, source, items, err, done)
}

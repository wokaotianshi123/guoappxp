package core

import (
	"context"
	"errors"
	"strings"
)

func (engine *nativeEngine) suggestions(ctx context.Context, source, query string) ([]string, error) {
	if strings.TrimSpace(query) == "" {
		return []string{}, nil
	}
	p, ok := engine.downloader.provider(source)
	if !ok {
		// 自定义源（MacCMS / XBPQ 规则）没有 provider，也没有联想词接口，
		// 返回空即可，搜索建议不是必需能力，不该因此报错。
		if isCustomMaccmsSource(source) {
			return []string{}, nil
		}
		return nil, errors.New("请选择有效站源")
	}
	suggester, ok := providerAs[Suggester](p)
	if !ok {
		return []string{}, nil
	}
	return suggester.Suggestions(ctx, query)
}

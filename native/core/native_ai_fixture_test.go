//go:build !sources

package core

// 黄果 AI 的站源实现已搬到 guoapp/sources。core 侧仍有若干用例（目录缓存与持久化、
// 分类选项、封面归一化、镜像候选）需要一个「能跑通」的黄果 provider 当夹具。
// 这里给一个最小实现：按请求的分类去站点信封接口取一页，详情与取流只做形状。
// 带 sources 标签构建时本文件不参与，避免与真实站源重复注册。

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"sync"
	"testing"
)

var aiFixtureOnce sync.Once

// installAIFixture 给需要黄果站源的 core 用例装一个最小 provider。
func installAIFixture(t *testing.T) {
	t.Helper()
	aiFixtureOnce.Do(func() {
		RegisterSource(SourceDescriptor{ID: sourceHuangguoAI, Name: "黄果", Description: "测试夹具"},
			func(host SourceHost) SourceProvider { return aiFixtureSource{host: host} })
	})
}

type aiFixtureSource struct{ host SourceHost }

var aiFixtureCategories = []nativeCategory{
	{ID: "ai-duanju", Name: "AI 短剧"},
	{ID: "ai-manju", Name: "AI 漫剧"},
	{ID: "ai-huanlian", Name: "AI 换脸"},
	{ID: "ai-mogai", Name: "AI 魔改"},
}

func (s aiFixtureSource) Categories() []NativeCategory {
	return append([]nativeCategory{}, aiFixtureCategories...)
}

func (s aiFixtureSource) ValidCategory(category string) bool {
	if category == "" {
		return true
	}
	for _, entry := range aiFixtureCategories {
		if entry.ID == category {
			return true
		}
	}
	return false
}

func (s aiFixtureSource) edge(ctx context.Context, path string) (string, error) {
	payload, err := json.Marshal(map[string]string{"method": http.MethodGet, "path": path})
	if err != nil {
		return "", err
	}
	base := s.host.BaseURL(sourceHuangguoAI)
	return s.host.PostJSON(ctx, base+"/api/edge/request", base+"/", payload)
}

func (s aiFixtureSource) CatalogPage(ctx context.Context, page int, category, query string) ([]Drama, bool, error) {
	categories := aiFixtureCategories
	if category != "" {
		categories = nil
		for _, entry := range aiFixtureCategories {
			if entry.ID == category {
				categories = append(categories, entry)
			}
		}
	}
	var items []Drama
	more := false
	for _, entry := range categories {
		body, err := s.edge(ctx, fmt.Sprintf("/api/videos/category/%s?sort=hot&page=%d&size=24", url.PathEscape(entry.ID), page))
		if err != nil {
			return nil, false, err
		}
		expired, parseErr := huangguoAIEnvelopeForFixture(body)
		if parseErr != nil {
			if !expired {
				return nil, false, parseErr
			}
			s.host.ForgetHost(sourceHuangguoAI)
			body, err = s.edge(ctx, fmt.Sprintf("/api/videos/category/%s?sort=hot&page=%d&size=24", url.PathEscape(entry.ID), page))
			if err != nil {
				return nil, false, err
			}
		}
		var rows json.RawMessage
		if _, decodeErr := huangguoAIEnvelopeForFixture(body, &rows); decodeErr != nil {
			return nil, false, decodeErr
		}
		fresh := parseHuangguoAIJSONCards(rows, s.host.BaseURL(sourceHuangguoAI)+"/", entry.Name)
		items = append(items, fresh...)
		more = more || len(fresh) >= 24
	}
	return items, more, nil
}

func (s aiFixtureSource) Detail(ctx context.Context, sourceID string) (Drama, []Chapter, error) {
	body, err := s.edge(ctx, "/api/videos/"+url.PathEscape(sourceID))
	if err != nil {
		return Drama{}, nil, err
	}
	var row map[string]any
	if _, err := huangguoAIEnvelopeForFixture(body, &row); err != nil {
		return Drama{}, nil, err
	}
	drama, ok := dramaFromAIMap(row, s.host.BaseURL(sourceHuangguoAI)+"/", "")
	if !ok {
		return plainProviderDrama(sourceHuangguoAI, sourceID, ""), nil, nil
	}
	chapters := []Chapter{{
		ID: providerChapterID(sourceHuangguoAI, sourceID, "auto-1"), Source: sourceHuangguoAI,
		Title: "第1集", CurrentEpisode: rawEpisode(1),
	}}
	return drama, chapters, nil
}

func (s aiFixtureSource) ResolveMedia(ctx context.Context, task Task) (ProviderMedia, error) {
	return ProviderMedia{}, errors.New("测试夹具不支持取流")
}

// huangguoAIEnvelopeForFixture 与真实站源一样的信封解析，只是不区分业务错误文案。
func huangguoAIEnvelopeForFixture(body string, out ...any) (bool, error) {
	var reply struct {
		Status int             `json:"status"`
		Msg    string          `json:"msg"`
		Data   json.RawMessage `json:"data"`
	}
	if err := json.Unmarshal([]byte(body), &reply); err != nil {
		return false, fmt.Errorf("信封格式无效: %w", err)
	}
	if reply.Status != 1 {
		return true, fmt.Errorf("信封返回失败: %s", reply.Msg)
	}
	if len(out) > 0 && out[0] != nil {
		return false, json.Unmarshal(reply.Data, out[0])
	}
	return false, nil
}

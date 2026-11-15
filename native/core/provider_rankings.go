package core

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"sync"
	"time"
)

const rankingCacheTTL = 5 * time.Minute

type rankingBoard struct {
	ID          string `json:"id"`
	Source      string `json:"source"`
	Name        string `json:"name"`
	Description string `json:"description"`
	path        string
	upstreamKey string
}

var rankingBoards = []rankingBoard{
	{ID: "hongguo-hot", Source: sourceHongguo, Name: "总热播榜", Description: "红果观看、互动等综合热度；每日更新。", path: "hot-drama", upstreamKey: "hongguo"},
	{ID: "hongguo-real", Source: sourceHongguo, Name: "真人剧榜", Description: "红果真人剧热播榜；每日更新。", path: "hot-real-drama", upstreamKey: "real"},
	{ID: "hongguo-comic", Source: sourceHongguo, Name: "漫剧榜", Description: "红果漫剧热播榜；每日更新。", path: "hot-comic-drama", upstreamKey: "comic"},
	{ID: "hongguo-ai", Source: sourceHongguo, Name: "AI剧榜", Description: "红果 AI 剧热播榜；每日更新。", path: "hot-ai-drama", upstreamKey: "ai"},
	{ID: "huangdou-all", Source: sourceHuangdou, Name: "总榜", Description: "黄豆短剧总榜，保留站点返回的顺序。", upstreamKey: "all"},
	{ID: "huangdou-mogai", Source: sourceHuangdou, Name: "魔改榜", Description: "黄豆站点魔改榜。", upstreamKey: "mogai"},
	{ID: "huangdou-search", Source: sourceHuangdou, Name: "搜索榜", Description: "黄豆站点搜索榜。", upstreamKey: "search"},
	{ID: "huangdou-favorite", Source: sourceHuangdou, Name: "收藏榜", Description: "黄豆站点收藏榜。", upstreamKey: "favorite"},
	{ID: "huangdou-finish", Source: sourceHuangdou, Name: "完结榜", Description: "黄豆站点完结榜。", upstreamKey: "finish"},
	{ID: "huangguo-hot", Source: sourceHuangguoAI, Name: "热播榜", Description: "黄果站点热播 TOP 20；每日更新。", path: "hot"},
	{ID: "huangguo-recommend", Source: sourceHuangguoAI, Name: "推荐榜", Description: "黄果站点推荐 TOP 20。", path: "recommend"},
	{ID: "huangguo-potential", Source: sourceHuangguoAI, Name: "潜力榜", Description: "黄果站点潜力 TOP 20。", path: "potential"},
}

type rankingItem struct {
	Rank   int    `json:"rank"`
	Drama  Drama  `json:"drama"`
	Metric string `json:"metric,omitempty"`
}

type rankingPage struct {
	BoardID     string        `json:"boardId"`
	Page        int           `json:"page"`
	Items       []rankingItem `json:"items"`
	HasMore     bool          `json:"hasMore"`
	TotalPages  int           `json:"totalPages,omitempty"`
	UpdatedText string        `json:"updatedText,omitempty"`
	FetchedAt   time.Time     `json:"fetchedAt"`
	Stale       bool          `json:"stale,omitempty"`
	Warning     string        `json:"warning,omitempty"`
}

type rankingCall struct {
	done chan struct{}
	page rankingPage
	err  error
}

type rankingCache struct {
	mu      sync.Mutex
	pages   map[string]rankingPage
	pending map[string]*rankingCall
}

// findRankingBoard 在本体榜单表与站源模块声明的榜单里查一个榜单。
func findRankingBoard(id string) (rankingBoard, bool) {
	for _, board := range allRankingBoards() {
		if board.ID == id {
			return board, true
		}
	}
	return rankingBoard{}, false
}

// allRankingBoards 是「本体榜单 + 模块榜单」的合并视图。
//
// 模块在清单的 rankings 里声明榜单，运行时把它并进来，模块源的榜单页才有内容。
// 标识与本体重复时以本体为准（模块源与其同名时本来就已经改名，不会撞）。
func allRankingBoards() []rankingBoard {
	boards := make([]rankingBoard, 0, len(rankingBoards)+4)
	boards = append(boards, rankingBoards...)
	taken := make(map[string]bool, len(rankingBoards))
	for _, board := range rankingBoards {
		taken[board.ID] = true
	}
	for _, descriptor := range RegisteredSources() {
		if !isModuleProviderSource(descriptor.ID) {
			continue
		}
		for _, board := range descriptor.Rankings {
			if board.ID == "" || board.Source == "" || taken[board.ID] {
				continue
			}
			taken[board.ID] = true
			boards = append(boards, rankingBoard{
				ID: board.ID, Source: board.Source, Name: board.Name, Description: board.Description,
				// 模块的 rankingPage(boardId, page) 直接吃榜单标识，所以把标识放进
				// upstreamKey（取榜时优先用它）；path 保留编译期站源的站点路径语义。
				upstreamKey: firstNonEmpty(board.UpstreamKey, board.ID),
			})
		}
	}
	return boards
}

func cloneRankingPage(page rankingPage) rankingPage {
	page.Items = append([]rankingItem{}, page.Items...)
	return page
}

func (d *Downloader) loadRankingPage(ctx context.Context, board rankingBoard, page int, refresh bool) (rankingPage, error) {
	key := board.ID + ":" + strconv.Itoa(page)
	cache := &d.rankings
	cache.mu.Lock()
	if cache.pages == nil {
		cache.pages = map[string]rankingPage{}
		cache.pending = map[string]*rankingCall{}
	}
	cached, exists := cache.pages[key]
	if exists && !refresh && time.Since(cached.FetchedAt) >= 0 && time.Since(cached.FetchedAt) < rankingCacheTTL {
		cache.mu.Unlock()
		return cloneRankingPage(cached), nil
	}
	if pending := cache.pending[key]; pending != nil {
		cache.mu.Unlock()
		select {
		case <-ctx.Done():
			return rankingPage{}, ctx.Err()
		case <-pending.done:
			if (errors.Is(pending.err, context.Canceled) || errors.Is(pending.err, context.DeadlineExceeded)) && ctx.Err() == nil {
				return d.loadRankingPage(ctx, board, page, refresh)
			}
			return cloneRankingPage(pending.page), pending.err
		}
	}
	pending := &rankingCall{done: make(chan struct{})}
	cache.pending[key] = pending
	cache.mu.Unlock()

	result, err := d.fetchRankingPage(ctx, board, page)
	cache.mu.Lock()
	defer cache.mu.Unlock()
	if err == nil {
		result.BoardID, result.Page, result.FetchedAt = board.ID, page, time.Now()
		if refresh && page == 1 {
			for cachedKey, old := range cache.pages {
				if old.BoardID == board.ID {
					delete(cache.pages, cachedKey)
				}
			}
		}
		if len(cache.pages) >= 128 {
			oldestKey, oldest := "", time.Now()
			for cachedKey, old := range cache.pages {
				if old.FetchedAt.Before(oldest) {
					oldestKey, oldest = cachedKey, old.FetchedAt
				}
			}
			delete(cache.pages, oldestKey)
		}
		cache.pages[key] = cloneRankingPage(result)
		d.writeRankingCacheLocked()
	} else if exists && ctx.Err() == nil && time.Since(cached.FetchedAt) >= 0 && time.Since(cached.FetchedAt) < 24*time.Hour {
		result = cloneRankingPage(cached)
		result.Stale = true
		result.Warning = "站点暂不可用，显示上次取得的榜单，请稍后刷新。"
		err = nil
	}
	pending.page, pending.err = cloneRankingPage(result), err
	delete(cache.pending, key)
	close(pending.done)
	return result, err
}

func (d *Downloader) fetchRankingPage(ctx context.Context, board rankingBoard, page int) (rankingPage, error) {
	// 站源自带名次与指标文案时优先用它：站点榜单的名次未必等于返回顺序；
	// 只实现「按页取剧集」的源由 providerRankingEntries 统一补名次。
	if provider, ok := d.sourceProvider(board.Source); ok {
		_, ranker := providerAs[SourceRankings](provider)
		_, entries := providerAs[SourceRankingEntries](provider)
		if ranker || entries {
			key := firstNonEmpty(board.upstreamKey, board.path)
			items, more, err := providerRankingEntries(ctx, provider, key, page)
			if err != nil {
				return rankingPage{}, err
			}
			result := rankingPage{Items: make([]rankingItem, 0, len(items)), HasMore: more}
			for _, item := range items {
				result.Items = append(result.Items, rankingItem{Rank: item.Rank, Drama: item.Drama, Metric: item.Metric})
			}
			return result, nil
		}
	}
	switch board.Source {
	case sourceHongguo:
		return d.fetchHongguoRankingPage(ctx, board, page)
	default:
		return rankingPage{}, fmt.Errorf("不支持的榜单站源 %s", board.Source)
	}
}

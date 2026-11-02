package core

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"
)

// 跨源聚合搜索：一次搜索并发打所有可见站源，再按「标题 / 年份 / 集数」归一去重，
// 同一部剧保留多个站源副本，供界面一键切换播放源。
//
// 搜索是分批返回的：searchStart 立刻返回会话号，各站源的结果落地一个就写一个，
// 界面用 searchPoll 轮询快照，不必等最慢的站源。这样十几二十个站点全搜完之前，
// 用户已经能看到并点开先返回的那些结果。

// 单源搜索的每一步最长耗时：整轮搜索由会话自己的 ctx 兜底，这里再压一层，
// 避免个别站源卡死拖住整轮的 finished 判定。
const (
	nativeSearchSourceTimeout = 25 * time.Second
	nativeSearchSessionTTL    = 5 * time.Minute
)

// errSearchUnsupported 标记「站源没有在线搜索接口」。
// 单源搜索时要把原因告诉用户；跨源聚合搜索时则静默跳过，避免刷一屏无用提示。
var errSearchUnsupported = errors.New("站源暂不支持在线搜索")

// nativeSearchAcrossResult 是聚合搜索的返回体。
// Items 为归一去重后的主条目（每组一条），每条的 Peers 带上其它站源的同一部剧。
// Sources 为已成功返回的站源，Pending 为仍在搜索的站源，Failures 记录失败原因。
type nativeSearchAcrossResult struct {
	Search   string            `json:"search"`
	Query    string            `json:"query"`
	Items    []nativeDrama     `json:"items"`
	Sources  []string          `json:"sources"`
	Pending  []string          `json:"pending,omitempty"`
	Failures map[string]string `json:"failures,omitempty"`
	Warning  string            `json:"warning,omitempty"`
	Total    int               `json:"total"`
	Done     int               `json:"done"`
	Finished bool              `json:"finished"`
}

// nativeSourceSupportsSearch 判断站源是否提供在线搜索接口。
// 这里只依据站源自身能力，不再把「已加载的本地资源」当作搜索来源。
func nativeSourceSupportsSearch(source string) bool {
	switch canonicalProviderSource(source) {
	case sourceHongguo, sourceHuangju, sourceYeguo, sourceDSD, sourceSorani,
		sourceGuipian, sourceHanxiaoquan, sourceA123, sourceIkanbot, sourceFanqie:
		return true
	}
	if isDuanjuProviderSource(source) {
		return duanjuSupportsSearch(source)
	}
	return false
}

// nativeSearchSourceLabel 返回站源的展示名，供提示与排序使用。
func nativeSearchSourceLabel(source string) string {
	source = canonicalProviderSource(source)
	if isDuanjuProviderSource(source) {
		return duanjuSourceName(source)
	}
	if source == sourceFanqie {
		return "番茄"
	}
	return source
}

// nativeSearchSource 对单个站源执行在线搜索。
// 只走站源自身的搜索接口；不支持在线搜索的站源直接返回明确错误，
// 由调用方决定是提示用户（单源）还是静默跳过（跨源）。
func (engine *nativeEngine) nativeSearchSource(ctx context.Context, source, query string, page int) (nativeCatalogResult, error) {
	source = canonicalProviderSource(source)
	result := nativeCatalogResult{Items: []nativeDrama{}, Page: page}
	query = strings.TrimSpace(query)
	if query == "" {
		return result, nil
	}
	if page < 1 {
		page = 1
	}
	if !nativeSourceSupportsSearch(source) {
		return result, fmt.Errorf("%w：%s", errSearchUnsupported, nativeSearchSourceLabel(source))
	}
	d := engine.downloader
	var items []Drama
	var more bool
	var err error
	switch source {
	case sourceFanqie:
		// 番茄搜索走引擎的 /api/v1/search（tab_type=11 短剧）。
		items, more, err = d.fetchFanqieSearchPage(ctx, page, query)
	case sourceHongguo:
		// 红果的搜索接口是「首屏 + 翻页」两段式，首屏还能给出「结果被截断」的提示。
		var entry hongguoSearchEntry
		if page == 1 {
			entry, err = d.searchHongguoDramas(ctx, query)
		} else if keyword, keywordErr := hongguoSearchKeyword(query); keywordErr != nil {
			err = keywordErr
		} else {
			entry, err = d.fetchHongguoSearchPage(ctx, keyword, page)
		}
		if err != nil {
			return result, err
		}
		for _, drama := range entry.Dramas {
			result.Items = append(result.Items, nativeNormalize(drama))
		}
		result.Warning, result.HasMore = entry.Warning, entry.HasMore
		return result, nil
	case sourceHuangju:
		items, more, err = d.fetchHuangjuCatalogPage(ctx, page, "", query)
	case sourceYeguo:
		items, more, err = d.fetchYeguoCatalogPage(ctx, page, "", query)
	case sourceDSD:
		items, more, err = d.fetchDSDCatalogPage(ctx, page, "", query)
	case sourceSorani:
		items, more, err = d.fetchSoraniCatalogPage(ctx, page, "", query)
	case sourceGuipian:
		items, more, err = d.fetchGuipianCatalogPage(ctx, page, "", query)
	case sourceHanxiaoquan:
		items, more, err = d.fetchHanxiaoquanCatalogPage(ctx, page, "", query)
	case sourceA123:
		items, more, err = d.fetchA123CatalogPage(ctx, page, "", query)
	case sourceIkanbot:
		items, more, err = d.fetchIkanbotCatalogPage(ctx, page, "", query)
	default:
		// 短剧家族与自定义 MacCMS 源共用同一套搜索接口（isDuanjuProviderSource 已含自定义源）。
		items, err = d.searchDuanju(ctx, source, query)
	}
	if err != nil {
		return result, err
	}
	for _, drama := range items {
		if drama.ID == "" {
			continue
		}
		result.Items = append(result.Items, nativeNormalize(drama))
	}
	result.HasMore = more
	return result, nil
}

// nativeSearchSession 保存一轮跨源搜索的中间状态。
// 各站源的 goroutine 只往里写自己那一格，读快照时加锁合并。
type nativeSearchSession struct {
	id       string
	query    string
	mu       sync.Mutex
	order    []string
	items    map[string][]nativeDrama
	done     map[string]bool
	failures map[string]string
	cancel   context.CancelFunc
	started  time.Time

	merged    []nativeDrama
	mergeDone int
}

// nativeSearchID 生成会话号：只需要进程内唯一，时间戳 + 随机后缀足够。
func nativeSearchID() string {
	buffer := make([]byte, 6)
	if _, err := rand.Read(buffer); err != nil {
		return fmt.Sprintf("s%d", time.Now().UnixNano())
	}
	return fmt.Sprintf("s%d%s", time.Now().UnixNano(), hex.EncodeToString(buffer))
}

// finish 落地一个站源的结果（成功或失败），同一个站源只认第一次。
func (session *nativeSearchSession) finish(source string, items []nativeDrama, err error) {
	session.mu.Lock()
	defer session.mu.Unlock()
	if session.done[source] {
		return
	}
	session.done[source] = true
	if err == nil {
		session.items[source] = items
		return
	}
	// 没有在线搜索接口的站源静默跳过，不占失败名额，免得刷一屏无用提示。
	if errors.Is(err, errSearchUnsupported) {
		return
	}
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		session.failures[source] = "搜索超时"
		return
	}
	session.failures[source] = publicError(err).Error()
}

// snapshot 生成当前的聚合快照。合并只做增量：已算过的不再重算，
// 保证前端每次轮询拿到的顺序是「只往后追加」，不会整屏跳动。
func (session *nativeSearchSession) snapshot() nativeSearchAcrossResult {
	session.mu.Lock()
	defer session.mu.Unlock()
	succeeded := make([]string, 0, len(session.order))
	pending := make([]string, 0, len(session.order))
	done := 0
	for _, source := range session.order {
		if !session.done[source] {
			pending = append(pending, source)
			continue
		}
		done++
		if _, failed := session.failures[source]; failed {
			continue
		}
		succeeded = append(succeeded, source)
	}
	finished := done == len(session.order)
	// 增量的做法：已经有合并结果时只看「完成数量有没有变」，变了就把新到的站源
	// 结果合并进去；不变就直接返回上次的切片，省掉重复排序。
	if len(session.merged) > 0 && session.mergeDone == done {
		return nativeSearchAcrossResult{
			Search: session.id, Query: session.query, Items: session.merged,
			Sources: succeeded, Pending: pending, Failures: copySearchFailures(session.failures),
			Warning: nativeSearchFailureText(session.failures),
			Total:   len(session.order), Done: done, Finished: finished,
		}
	}
	var all []nativeDrama
	for _, source := range session.order {
		all = append(all, session.items[source]...)
	}
	session.merged = nativeSearchMerge(all, finished)
	session.mergeDone = done
	return nativeSearchAcrossResult{
		Search: session.id, Query: session.query, Items: session.merged,
		Sources: succeeded, Pending: pending, Failures: copySearchFailures(session.failures),
		Warning: nativeSearchFailureText(session.failures),
		Total:   len(session.order), Done: done, Finished: finished,
	}
}

func copySearchFailures(failures map[string]string) map[string]string {
	if len(failures) == 0 {
		return nil
	}
	copied := make(map[string]string, len(failures))
	for source, reason := range failures {
		copied[source] = reason
	}
	return copied
}

// nativeSearchTargets 归一化请求里的站源列表：去重、纠正别名，并丢掉当前构建
// 不包含（或站源管理里已关闭）的站源。
func nativeSearchTargets(raw []string) []string {
	seen := map[string]bool{}
	var sources []string
	for _, entry := range raw {
		source := canonicalProviderSource(strings.TrimSpace(entry))
		if source == "" || seen[source] {
			continue
		}
		if !isHuangguoProviderSource(source) || !nativeSourceAvailable(source) {
			continue
		}
		seen[source] = true
		sources = append(sources, source)
	}
	return sources
}

// pruneSearchesLocked 清掉过期会话，避免放弃的搜索一直占着内存与 goroutine。
func (engine *nativeEngine) pruneSearchesLocked() {
	cutoff := time.Now().Add(-nativeSearchSessionTTL)
	for id, session := range engine.searches {
		if session.started.After(cutoff) {
			continue
		}
		delete(engine.searches, id)
		session.cancel()
	}
}

// nativeSearchStart 启动一轮跨源搜索并立刻返回首个快照（此时通常还没有结果）。
func (engine *nativeEngine) nativeSearchStart(input nativeInput) (nativeSearchAcrossResult, error) {
	query := strings.TrimSpace(input.Query)
	if query == "" {
		return nativeSearchAcrossResult{}, errors.New("请输入搜索内容")
	}
	sources := nativeSearchTargets(input.Sources)
	if len(sources) == 0 {
		return nativeSearchAcrossResult{}, errors.New("请选择有效站源")
	}
	page := max(1, input.Page)
	// 会话用自己的 ctx：nativeDispatch 的 ctx 在这个请求返回时就被 cancel 了，
	// 后台站源还需要继续跑。
	ctx, cancel := context.WithTimeout(context.Background(), nativeSearchSessionTTL/2)
	session := &nativeSearchSession{
		id:       nativeSearchID(),
		query:    query,
		order:    sources,
		items:    map[string][]nativeDrama{},
		done:     map[string]bool{},
		failures: map[string]string{},
		cancel:   cancel,
		started:  time.Now(),
	}
	engine.searchMu.Lock()
	engine.pruneSearchesLocked()
	engine.searches[session.id] = session
	engine.searchMu.Unlock()

	concurrency := 6
	if len(sources) < concurrency {
		concurrency = len(sources)
	}
	sem := make(chan struct{}, concurrency)
	for _, source := range sources {
		go func(source string) {
			defer func() {
				if recovered := recover(); recovered != nil {
					if engine.downloader != nil {
						engine.downloader.recordGoroutinePanic("searchAcross", recovered)
					}
					session.finish(source, nil, errors.New("搜索出错，请稍后重试"))
				}
			}()
			sem <- struct{}{}
			defer func() { <-sem }()
			sourceCtx, sourceCancel := context.WithTimeout(ctx, nativeSearchSourceTimeout)
			defer sourceCancel()
			found, err := engine.nativeSearchSource(sourceCtx, source, query, page)
			session.finish(source, found.Items, err)
		}(source)
	}
	return session.snapshot(), nil
}

// nativeSearchPoll 返回指定会话的当前快照，界面据此增量刷新结果。
func (engine *nativeEngine) nativeSearchPoll(input nativeInput) (nativeSearchAcrossResult, error) {
	id := strings.TrimSpace(input.Search)
	if id == "" {
		return nativeSearchAcrossResult{}, errors.New("搜索会话无效，请重新搜索")
	}
	engine.searchMu.Lock()
	session := engine.searches[id]
	engine.pruneSearchesLocked()
	engine.searchMu.Unlock()
	if session == nil {
		return nativeSearchAcrossResult{}, errors.New("搜索会话已结束，请重新搜索")
	}
	return session.snapshot(), nil
}

// nativeSearchCancel 取消并丢弃一个会话（换关键词、离开页面时调用）。
func (engine *nativeEngine) nativeSearchCancel(id string) {
	id = strings.TrimSpace(id)
	if id == "" {
		return
	}
	engine.searchMu.Lock()
	session := engine.searches[id]
	delete(engine.searches, id)
	engine.searchMu.Unlock()
	if session != nil {
		session.cancel()
	}
}

// nativeSearchAcross 一次性搜索全部站源并等所有结果（老接口 / 命令行脚本用）。
func (engine *nativeEngine) nativeSearchAcross(ctx context.Context, input nativeInput) (nativeSearchAcrossResult, error) {
	started, err := engine.nativeSearchStart(nativeInput{Query: input.Query, Sources: input.Sources, Page: input.Page})
	if err != nil {
		return started, err
	}
	engine.searchMu.Lock()
	session := engine.searches[started.Search]
	engine.searchMu.Unlock()
	if session == nil {
		return nativeSearchAcrossResult{}, errors.New("搜索会话已结束，请重新搜索")
	}
	ticker := time.NewTicker(120 * time.Millisecond)
	defer ticker.Stop()
	for {
		snapshot := session.snapshot()
		if snapshot.Finished {
			engine.nativeSearchCancel(snapshot.Search)
			if len(snapshot.Items) == 0 && len(snapshot.Failures) > 0 {
				return snapshot, errors.New(snapshot.Warning)
			}
			return snapshot, nil
		}
		select {
		case <-ctx.Done():
			engine.nativeSearchCancel(snapshot.Search)
			return snapshot, ctx.Err()
		case <-ticker.C:
		}
	}
}

// nativeSearchFailureText 把各站源的失败原因合并成一句提示。
func nativeSearchFailureText(failures map[string]string) string {
	if len(failures) == 0 {
		return ""
	}
	names := make([]string, 0, len(failures))
	for source := range failures {
		names = append(names, nativeSearchSourceLabel(source))
	}
	sort.Strings(names)
	if len(names) == 1 {
		return fmt.Sprintf("%s：%s", names[0], failures[firstSearchKey(failures, names[0])])
	}
	return fmt.Sprintf("%s 等 %d 个站源未返回结果", names[0], len(names))
}

func firstSearchKey(failures map[string]string, label string) string {
	for source := range failures {
		if nativeSearchSourceLabel(source) == label {
			return source
		}
	}
	return ""
}

// nativeSearchYear 从上线日期里取出年份，取不到返回空串。
func nativeSearchYear(drama nativeDrama) string {
	date := drama.OnlineDate
	for index := 0; index+4 <= len(date); index++ {
		year := date[index : index+4]
		if year[0] != '1' && year[0] != '2' {
			continue
		}
		digits := true
		for i := 0; i < 4; i++ {
			if year[i] < '0' || year[i] > '9' {
				digits = false
				break
			}
		}
		if digits {
			return year
		}
	}
	return ""
}

// nativeSearchKey 按「归一标题 + 年份」生成分组键。
// 标题归一复用 hongguoSearchText：NFKC 折叠、去掉空白与标点、统一小写。
func nativeSearchKey(drama nativeDrama) string {
	return hongguoSearchText(drama.Title) + "|" + nativeSearchYear(drama)
}

// nativeSearchCanMerge 判断两部剧是否可视为同一部（集数维度）。
// 集数缺失或相等直接合并；都有集数时，差异超过 25% 视为不同版本，避免把
// 「12 集短剧」和「80 集长剧」错误合成一条。
func nativeSearchCanMerge(base, other nativeDrama) bool {
	if base.Episodes == 0 || other.Episodes == 0 || base.Episodes == other.Episodes {
		return true
	}
	diff := base.Episodes - other.Episodes
	if diff < 0 {
		diff = -diff
	}
	larger := base.Episodes
	if other.Episodes > larger {
		larger = other.Episodes
	}
	return diff*4 <= larger
}

// nativeSearchScore 评估条目完整度，用于挑选每组的展示主条目。
func nativeSearchScore(drama nativeDrama) int {
	score := 0
	if drama.Cover != "" {
		score += 4
	}
	if drama.Episodes > 0 {
		score += 2
	}
	if drama.Description != "" {
		score += 1
	}
	if drama.OnlineDate != "" {
		score += 1
	}
	if drama.Category != "" {
		score += 1
	}
	return score
}

// nativeSearchMerge 把多源结果按标题/年份/集数归一去重。
// 每组挑一个完整度最高的作为主条目，其它站源副本放进 Peers，供切换播放源使用。
//
// sorted 为 false 时保持「首次出现」的顺序，用于流式搜索：已有条目不会因为新
// 站源陆续返回而整屏重排；全部搜完后（sorted=true）再按完整度排序。
func nativeSearchMerge(items []nativeDrama, sorted bool) []nativeDrama {
	type group struct {
		primary nativeDrama
		peers   []nativeDrama
		score   int
	}
	groups := map[string][]*group{}
	var order []string
	for _, item := range items {
		if item.ID == "" || item.Title == "" {
			continue
		}
		key := nativeSearchKey(item)
		bucket := groups[key]
		var target *group
		for _, entry := range bucket {
			if nativeSearchCanMerge(entry.primary, item) {
				target = entry
				break
			}
		}
		if target == nil {
			// order 只记录键首次出现的顺序，避免同一键下多组时被重复遍历。
			_, known := groups[key]
			target = &group{primary: item, score: nativeSearchScore(item)}
			groups[key] = append(bucket, target)
			if !known {
				order = append(order, key)
			}
			continue
		}
		score := nativeSearchScore(item)
		if score > target.score {
			target.peers = append(target.peers, target.primary)
			target.primary, target.score = item, score
		} else {
			target.peers = append(target.peers, item)
		}
	}
	merged := make([]nativeDrama, 0, len(order))
	for _, key := range order {
		for _, entry := range groups[key] {
			primary := entry.primary
			seenID := map[string]bool{primary.ID: true}
			seenSource := map[string]bool{primary.Source: true}
			peers := make([]nativeDrama, 0, len(entry.peers))
			for _, peer := range entry.peers {
				// 同一站源只保留一个副本，避免同一部剧被重复罗列。
				if seenID[peer.ID] || seenSource[peer.Source] {
					continue
				}
				seenID[peer.ID], seenSource[peer.Source] = true, true
				peers = append(peers, peer)
			}
			sort.Slice(peers, func(i, j int) bool {
				if peers[i].Source != peers[j].Source {
					return nativeSearchSourceLabel(peers[i].Source) < nativeSearchSourceLabel(peers[j].Source)
				}
				return peers[i].Title < peers[j].Title
			})
			primary.Peers = peers
			merged = append(merged, primary)
		}
	}
	if sorted {
		sort.SliceStable(merged, func(i, j int) bool {
			left, right := nativeSearchScore(merged[i]), nativeSearchScore(merged[j])
			if left != right {
				return left > right
			}
			if merged[i].Episodes != merged[j].Episodes {
				return merged[i].Episodes > merged[j].Episodes
			}
			return merged[i].Title < merged[j].Title
		})
	}
	return merged
}

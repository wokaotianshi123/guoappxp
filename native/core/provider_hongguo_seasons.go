package core

import (
	"context"
	"sort"
	"strings"
)

const (
	// hongguoSeasonSearchLimit 限制补齐缺失季时最多发起的搜索次数，
	// 避免名字很常见的剧（如「都市」）把搜索接口打满。
	hongguoSeasonSearchLimit = 10
	hongguoSeasonLimit       = 60
)

// hongguoSeason 是红果同一系列里的一季。
type hongguoSeason struct {
	Number int
	Drama  Drama
}

// hongguoSeasonMember 判断候选剧是否属于同一系列，并返回它的季号。
//
// 红果的第一季通常不写季号，标题就是基础名（如「长夜将明」），
// hongguoSearchSeason 对这种标题返回 season=0。以前分组和补搜都把
// season==0 直接丢掉，导致打开第二季及以后时「系列多季」里永远缺第一季。
// 这里把「无季号但标题归一化后正好等于系列基础名」的候选按第 1 季处理；
// 带季号的候选仍要求单位与基础名都一致，避免把「某某之续集」「第X部」混进来。
func hongguoSeasonMember(title, key, unit string) (int, string, bool) {
	if key == "" || unit == "" {
		return 0, "", false
	}
	text := strings.TrimSpace(title)
	base, season, candidateUnit, label := hongguoSearchSeason(text)
	if season == 0 {
		// 没有季号后缀：只有标题本身就是系列基础名时才算第一季。
		if candidateUnit == "" && hongguoSearchText(text) == key {
			return 1, "", true
		}
		return 0, "", false
	}
	if candidateUnit != unit || hongguoSearchText(base) != key {
		return 0, "", false
	}
	return season, label, true
}

// hongguoSeasonGroup 把同一部剧的各季收成一组。
//
// 红果官方没有单独的「系列剧」接口：同一部剧的每季是独立剧集，标题带
// 「第二季 / 第 2 部」这类后缀。这里按归一化后的基础名 + 季单位分组，
// 同名但基础名不同的剧（如「都市情缘」与「都市情缘之再续」）不会混在一起。
func hongguoSeasonGroup(anchor Drama, candidates []Drama) (map[int]Drama, string, string) {
	title := strings.TrimSpace(anchor.DisplayTitle())
	base, number, unit, _ := hongguoSearchSeason(title)
	key := hongguoSearchText(title)
	if number > 0 {
		key = hongguoSearchText(base)
	}
	if key == "" {
		return nil, "", ""
	}
	if number == 0 {
		// 当前剧标题没写季号：从候选里挑最常见的「第X季 / 第X部」单位。
		counts := map[string]int{}
		for _, drama := range candidates {
			candidateBase, season, candidateUnit, _ := hongguoSearchSeason(drama.DisplayTitle())
			if season == 0 || candidateUnit == "" || hongguoSearchText(candidateBase) != key {
				continue
			}
			counts[candidateUnit]++
		}
		best := ""
		for candidateUnit, count := range counts {
			if best == "" || count > counts[best] {
				best = candidateUnit
			}
		}
		if best == "" {
			return nil, key, ""
		}
		unit = best
	}
	member := map[int]Drama{}
	if anchor.ID != "" {
		season := number
		if season == 0 {
			season = 1
		}
		member[season] = anchor
	}
	for _, drama := range candidates {
		if drama.ID == "" || drama.ID == anchor.ID {
			continue
		}
		season, _, ok := hongguoSeasonMember(drama.DisplayTitle(), key, unit)
		if !ok {
			continue
		}
		if _, exists := member[season]; exists {
			continue
		}
		member[season] = drama
	}
	return member, key, unit
}

// hongguoSeriesSeasons 用「同名剧的季节分组」得到系列剧各季，
// 缺失的季再按「基础名第X季」补搜。
func (downloader *Downloader) hongguoSeriesSeasons(ctx context.Context, sourceID, title string) ([]hongguoSeason, error) {
	anchorID := providerDramaID(sourceHongguo, sourceID)
	title = strings.TrimSpace(title)
	if title == "" {
		entry, err := downloader.hongguoAppDetail(ctx, sourceID)
		if err != nil {
			return nil, err
		}
		title = entry.Drama.DisplayTitle()
	}
	if title == "" {
		return nil, nil
	}
	base, number, _, _ := hongguoSearchSeason(title)
	keyword := title
	if number > 0 && base != "" {
		keyword = base
	}
	candidates, _ := downloader.fetchHongguoSearchNames(ctx, keyword)
	anchor := Drama{ID: anchorID, Source: sourceHongguo, SourceID: sourceID, Title: title}
	for _, drama := range candidates {
		if drama.ID == anchorID {
			// 搜索里带回的当前剧带封面与总集数，卡片条能显示真实信息。
			anchor = drama
			break
		}
	}
	member, key, unit := hongguoSeasonGroup(anchor, candidates)
	if len(member) < 2 && number == 0 {
		// 当前剧没写季号、同名候选也没凑出多季：按单季处理，不显示卡片条。
		// 但标题明确写着「第二季」时必然存在第一季，即便首轮搜索没带回来，
		// 也要继续走下面的补搜，把第一季补出来。
		return nil, nil
	}

	known := map[int]bool{}
	labels := map[int]string{}
	maximum := 0
	for season := range member {
		known[season] = true
		labels[season] = hongguoSearchChineseSeason(season)
		maximum = max(maximum, season)
	}
	series := &hongguoSearchSeries{
		title:   firstNonEmpty(base, title),
		key:     key,
		unit:    unit,
		maximum: maximum,
		known:   known,
		labels:  labels,
	}
	attempted := map[string]bool{keyword: true}
	for round := 0; round < hongguoSeasonSearchLimit; round++ {
		query := series.nextQuery(attempted)
		if query == "" {
			break
		}
		attempted[query] = true
		names, err := downloader.fetchHongguoSearchNames(ctx, query)
		if err != nil {
			break
		}
		for _, drama := range names {
			if drama.ID == "" || drama.ID == anchorID {
				continue
			}
			season, label, ok := hongguoSeasonMember(drama.DisplayTitle(), key, unit)
			if !ok {
				continue
			}
			if _, exists := member[season]; exists {
				continue
			}
			member[season] = drama
			known[season] = true
			maximum = max(maximum, season)
			if label != "" {
				labels[season] = label
			}
		}
	}
	series.maximum = maximum

	seasons := make([]hongguoSeason, 0, len(member))
	for season, drama := range member {
		if season < 1 || season > hongguoSeasonLimit {
			continue
		}
		seasons = append(seasons, hongguoSeason{Number: season, Drama: drama})
	}
	sort.SliceStable(seasons, func(left, right int) bool {
		if seasons[left].Number != seasons[right].Number {
			return seasons[left].Number < seasons[right].Number
		}
		return seasons[left].Drama.DisplayTitle() < seasons[right].Drama.DisplayTitle()
	})
	if len(seasons) < 2 {
		return nil, nil
	}
	return seasons, nil
}

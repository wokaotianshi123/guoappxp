package core

import (
	"context"
	"errors"
	"sort"
	"strings"
	"sync"
	"time"
)

// 磁力搜索的「会话式」执行：一次 start 立刻返回全部目标站标签，各站并发去抓，
// 每抓完一个站就把该站结果写进会话；界面轮询 poll 增量取回，做到「有结果就显示」，
// 不必等最慢的那个站。
//
// 为什么用轮询而不是回调：FFI 的 _nativeRequest 是同步请求-应答，Dart 侧每次调用
// 都跑在独立 Isolate 里，没有从 Go 反向推送的通道。会话 + 轮询在五个端（含本地
// 服务版的 HTTP 转发）都是同一套语义，也不引入长连接与生命周期问题。
//
// 会话是「一次搜索」的快照，不是持久缓存：stop 或超时后即可丢弃，界面重新搜索会
// 建新会话。同一时间只保留最近若干个会话，避免用户连点搜索把内存拖大。
const (
	magnetSessionTTL      = 3 * time.Minute
	magnetSessionKeep     = 4
	magnetSessionBudget   = 45 * time.Second
	magnetSessionPollWait = 2 * time.Second
)

type magnetSessionSite struct {
	SiteID int    `json:"siteId"`
	Name   string `json:"name"`
	// State 是该站的抓取状态：pending / fetching / done / failed。
	State string `json:"state"`
	// Count 是该站已产出的条目数，让标签上能立刻显示「站点名 0/12」。
	Count int    `json:"count"`
	Error string `json:"error,omitempty"`
}

type magnetSessionSnapshot struct {
	ID string `json:"id"`
	// Phase 是整体阶段：running（还有站在跑）/ done（全部结束）。
	Phase string `json:"phase"`
	Page  int    `json:"page"`
	Query string `json:"query"`
	// Sites 是所有目标站的状态，顺序与站源表一致，界面据此先画出全部标签。
	Sites []magnetSessionSite `json:"sites"`
	// Items 只包含本轮新产出、尚未被 poll 取走的条目（增量）。
	Items []magnetResult `json:"items"`
	// Total 是会话累计条目数，用于界面显示总数而不必自己累加。
	Total   int    `json:"total"`
	HasMore bool   `json:"hasMore"`
	Warning string `json:"warning,omitempty"`
}

type magnetSearchSession struct {
	mu      sync.Mutex
	id      string
	query   string
	page    int
	browse  bool
	created time.Time
	phase   string
	sites   []magnetSessionSite
	// pending 是还没被取走的增量条目。
	pending []magnetResult
	total   int
	// seen 用于跨站去重，去重口径与 magnetRunSearch 一致。
	seen    map[string]bool
	hasMore bool
	cancel  context.CancelFunc
}

var magnetSessions = struct {
	sync.Mutex
	items map[string]*magnetSearchSession
	order []string
}{items: map[string]*magnetSearchSession{}}

// magnetSessionBegin 建会话并立刻把全部目标站以 pending 状态登记好，随后异步开抓。
// 返回的第一份快照就带着完整标签列表，界面可以先把标签画出来。
func magnetSessionBegin(ctx context.Context, query string, page int, selected []int, browse bool, categoryURL string, categorySiteID int) (magnetSessionSnapshot, error) {
	query = strings.TrimSpace(query)
	if query == "" {
		if !browse {
			return magnetSessionSnapshot{}, errors.New("请输入搜索关键词")
		}
		query = magnetDefaultBrowseWord()
	}
	if page < 1 {
		page = 1
	}
	if page > magnetMaxPage {
		page = magnetMaxPage
	}
	sites, err := loadMagnetSites()
	if err != nil {
		return magnetSessionSnapshot{}, err
	}
	allowed := map[int]bool{}
	for _, id := range selected {
		allowed[id] = true
	}
	targets := make([]magnetSite, 0, len(sites))
	for _, site := range sites {
		if !site.State || site.Request.SearchURL == "" {
			continue
		}
		if len(allowed) > 0 && !allowed[site.ID] {
			continue
		}
		targets = append(targets, site)
	}

	// 会话自己的 context 与调用方的 ctx 解耦：start 请求返回后外层 ctx 就被取消，
	// 但抓取要继续跑，所以这里只继承取消能力，不继承 deadline。
	sessionCtx, cancel := context.WithTimeout(context.Background(), magnetSessionBudget)
	session := &magnetSearchSession{
		id:      magnetSessionID(),
		query:   query,
		page:    page,
		browse:  browse,
		created: time.Now(),
		phase:   "running",
		sites:   make([]magnetSessionSite, 0, len(targets)),
		seen:    map[string]bool{},
		cancel:  cancel,
	}
	for _, site := range targets {
		session.sites = append(session.sites, magnetSessionSite{
			SiteID: site.ID, Name: site.Name, State: "pending",
		})
	}
	if len(targets) == 0 {
		session.phase = "done"
	}
	magnetSessionStore(session)
	go magnetSessionRun(sessionCtx, session, targets, categoryURL, categorySiteID)
	return session.snapshot(), nil
}

func magnetSessionRun(ctx context.Context, session *magnetSearchSession, targets []magnetSite, categoryURL string, categorySiteID int) {
	limit := make(chan struct{}, magnetSiteWorkers)
	var wait sync.WaitGroup
	for index := range targets {
		wait.Add(1)
		go func(i int) {
			defer wait.Done()
			site := targets[i]
			session.setSiteState(site.ID, "fetching", 0, "")
			select {
			case limit <- struct{}{}:
			case <-ctx.Done():
				session.setSiteState(site.ID, "failed", 0, "已取消")
				return
			}
			defer func() { <-limit }()

			address := magnetSearchAddress(site, session.query, session.page)
			if session.browse {
				address = magnetBrowseAddress(site, session.query, session.page)
			}
			if categoryURL != "" && categorySiteID > 0 && site.ID == categorySiteID {
				address = magnetCategoryAddress(categoryURL, session.page)
			}
			body, err := magnetFetch(ctx, address, site.Request.Header)
			if err != nil {
				session.setSiteState(site.ID, "failed", 0, publicMagnetError(err))
				return
			}
			items := magnetParseList(site, body)
			if categoryURL != "" && categorySiteID > 0 && site.ID == categorySiteID && len(items) == 0 {
				if fallback := magnetBrowseAddress(site, session.query, session.page); fallback != address {
					if fallbackBody, fallbackErr := magnetFetch(ctx, fallback, site.Request.Header); fallbackErr == nil {
						items = magnetParseList(site, fallbackBody)
					}
				}
			}
			// 列表先落地：用户不用等详情页补磁力就能看到条目。
			session.appendItems(items)
			session.setSiteState(site.ID, "done", len(items), "")

			// 再补那些列表里没给 infohash 的条目，补到一条推一条。
			if len(items) > 0 {
				magnetSessionResolveDetails(ctx, session, site, items)
			}
		}(index)
	}
	wait.Wait()
	if ctx.Err() != nil {
		session.failPending("已取消")
	}
	session.finish()
}

// magnetSessionResolveDetails 抓详情页补磁力，并把补到的结果增量推给界面。
func magnetSessionResolveDetails(ctx context.Context, session *magnetSearchSession, site magnetSite, items []magnetResult) {
	type job struct {
		title  string
		detail string
	}
	jobs := make([]job, 0, len(items))
	for _, item := range items {
		if item.Magnet == "" && item.Detail != "" {
			jobs = append(jobs, job{title: item.Title, detail: item.Detail})
		}
	}
	if len(jobs) == 0 {
		return
	}
	limit := make(chan struct{}, magnetDetailWorkers)
	var wait sync.WaitGroup
	for _, current := range jobs {
		wait.Add(1)
		go func(j job) {
			defer wait.Done()
			select {
			case limit <- struct{}{}:
			case <-ctx.Done():
				return
			}
			defer func() { <-limit }()
			link := magnetFromDetail(ctx, site, j.detail, j.title)
			if link == "" {
				return
			}
			session.upgradeItem(site.ID, j.title, link)
		}(current)
	}
	wait.Wait()
}

func (s *magnetSearchSession) snapshot() magnetSessionSnapshot {
	s.mu.Lock()
	defer s.mu.Unlock()
	sites := make([]magnetSessionSite, len(s.sites))
	copy(sites, s.sites)
	items := make([]magnetResult, len(s.pending))
	copy(items, s.pending)
	s.pending = nil
	warning := ""
	failed := 0
	for _, site := range s.sites {
		if site.State == "failed" {
			failed++
		}
	}
	if s.phase == "done" && failed > 0 && s.total == 0 {
		warning = "站源都没有返回结果，可稍后重试或换一批站源"
	}
	return magnetSessionSnapshot{
		ID:      s.id,
		Phase:   s.phase,
		Page:    s.page,
		Query:   s.query,
		Sites:   sites,
		Items:   items,
		Total:   s.total,
		HasMore: s.hasMore,
		Warning: warning,
	}
}

// appendItems 去重后并入增量队列。ID 为空（没解析出磁力）的条目按站名+标题去重，
// 与 magnetRunSearch 的口径保持一致。
func (s *magnetSearchSession) appendItems(items []magnetResult) {
	if len(items) == 0 {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, item := range items {
		key := item.ID
		if key == "" {
			key = item.Site + "|" + item.Title
		}
		if s.seen[key] {
			continue
		}
		s.seen[key] = true
		item.Playable = strings.HasPrefix(item.Magnet, "magnet:")
		s.pending = append(s.pending, item)
		s.total++
	}
}

// upgradeItem 给已推送过的条目补上磁力链接。界面按 ID 合并，不会重复插入。
func (s *magnetSearchSession) upgradeItem(siteID int, title, link string) {
	hash := magnetInfoHash(link)
	if hash == "" {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.seen[hash] {
		return
	}
	s.seen[hash] = true
	s.pending = append(s.pending, magnetResult{
		ID:       hash,
		Title:    title,
		Magnet:   link,
		SiteID:   siteID,
		Playable: true,
	})
	s.total++
}

func (s *magnetSearchSession) setSiteState(siteID int, state string, count int, message string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for index := range s.sites {
		if s.sites[index].SiteID != siteID {
			continue
		}
		s.sites[index].State = state
		if count > 0 {
			s.sites[index].Count = count
		}
		s.sites[index].Error = message
		return
	}
}

func (s *magnetSearchSession) failPending(message string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for index := range s.sites {
		if s.sites[index].State == "pending" || s.sites[index].State == "fetching" {
			s.sites[index].State = "failed"
			s.sites[index].Error = message
		}
	}
}

func (s *magnetSearchSession) finish() {
	s.mu.Lock()
	s.phase = "done"
	s.hasMore = s.total > 0 && s.page < magnetMaxPage
	s.mu.Unlock()
}

// magnetSessionPoll 取回增量。wait 为 true 时最多等一小会儿（长轮询），
// 让界面在「还没结果」时不必空转轮询。
func magnetSessionPoll(id string, wait bool) (magnetSessionSnapshot, error) {
	session := magnetSessionGet(id)
	if session == nil {
		return magnetSessionSnapshot{}, errors.New("搜索会话已失效，请重新搜索")
	}
	deadline := time.Now().Add(magnetSessionPollWait)
	for {
		snapshot := session.snapshot()
		if len(snapshot.Items) > 0 || snapshot.Phase == "done" || !wait || time.Now().After(deadline) {
			return snapshot, nil
		}
		time.Sleep(80 * time.Millisecond)
	}
}

func magnetSessionStop(id string) {
	magnetSessions.Lock()
	session := magnetSessions.items[id]
	delete(magnetSessions.items, id)
	for index, existing := range magnetSessions.order {
		if existing == id {
			magnetSessions.order = append(magnetSessions.order[:index], magnetSessions.order[index+1:]...)
			break
		}
	}
	magnetSessions.Unlock()
	if session != nil {
		session.cancel()
	}
}

func magnetSessionStore(session *magnetSearchSession) {
	magnetSessions.Lock()
	expired := make([]*magnetSearchSession, 0)
	now := time.Now()
	for id, existing := range magnetSessions.items {
		if now.Sub(existing.created) > magnetSessionTTL {
			delete(magnetSessions.items, id)
			expired = append(expired, existing)
		}
	}
	magnetSessions.items[session.id] = session
	magnetSessions.order = append(magnetSessions.order, session.id)
	// 超出保留数量时，从最旧的开始丢。
	for len(magnetSessions.order) > magnetSessionKeep {
		oldest := magnetSessions.order[0]
		magnetSessions.order = magnetSessions.order[1:]
		if existing := magnetSessions.items[oldest]; existing != nil {
			delete(magnetSessions.items, oldest)
			expired = append(expired, existing)
		}
	}
	magnetSessions.Unlock()
	for _, item := range expired {
		item.cancel()
	}
}

func magnetSessionGet(id string) *magnetSearchSession {
	magnetSessions.Lock()
	defer magnetSessions.Unlock()
	return magnetSessions.items[id]
}

func magnetSessionID() string {
	return "magnet-" + time.Now().Format("150405.000000") + "-" + randomMagnetSuffix()
}

var magnetSessionSeq struct {
	sync.Mutex
	value int64
}

func randomMagnetSuffix() string {
	magnetSessionSeq.Lock()
	magnetSessionSeq.value++
	value := magnetSessionSeq.value
	magnetSessionSeq.Unlock()
	const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
	out := make([]byte, 4)
	for i := range out {
		out[i] = alphabet[value%int64(len(alphabet))]
		value /= int64(len(alphabet))
	}
	return string(out)
}

// publicMagnetError 把抓取错误压缩成一句能直接显示的话，避免把完整 URL 与
// Go 的错误链塞进界面。
func publicMagnetError(err error) string {
	if err == nil {
		return ""
	}
	message := err.Error()
	if index := strings.Index(message, "HTTP "); index >= 0 && len(message) >= index+8 {
		return message[index : index+8]
	}
	if strings.Contains(message, "context canceled") {
		return "已取消"
	}
	if strings.Contains(message, "deadline exceeded") || strings.Contains(message, "Timeout") {
		return "超时"
	}
	if strings.Contains(message, "no such host") {
		return "域名解析失败"
	}
	if strings.Contains(message, "connection refused") {
		return "连接被拒绝"
	}
	if strings.Contains(message, "EOF") {
		return "连接中断"
	}
	if len([]rune(message)) > 24 {
		return string([]rune(message)[:24])
	}
	return message
}

// magnetSessionSummary 给测试与诊断用：把站点状态按 siteID 排序后返回。
func magnetSessionSummary(snapshot magnetSessionSnapshot) []magnetSessionSite {
	sites := append([]magnetSessionSite(nil), snapshot.Sites...)
	sort.Slice(sites, func(i, j int) bool { return sites[i].SiteID < sites[j].SiteID })
	return sites
}

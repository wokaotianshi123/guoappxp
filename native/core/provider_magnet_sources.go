package core

import (
	"encoding/json"
	"errors"
	"fmt"
	"hash/fnv"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
)

// 用户自行新增的磁力站源、对内置站的修改、以及「删掉的内置站」一起持久化到
// 应用数据目录，规则形态与内置的 magnet_sites.json 完全一致（request + expressionModel）。
//
// 三种记录的分工：
//   - Custom：用户新增的站源，ID 落在 magnetCustomIDBase 之上。
//   - Overrides：用户改了内置站的规则/名称，按内置 ID 存整条覆盖。
//   - Disabled：用户删掉的内置站 ID。
//
// 「恢复默认」= 清空三者，回到 magnet_sites.json 的原始 35 站。
type magnetSourceFile struct {
	Custom    []magnetSite `json:"custom"`
	Overrides []magnetSite `json:"overrides,omitempty"`
	Disabled  []int        `json:"disabled,omitempty"`
}

const magnetCustomIDBase = 900000

var magnetSources = struct {
	sync.RWMutex
	path      string
	custom    []magnetSite
	overrides map[int]magnetSite
	disabled  map[int]bool
	loaded    bool
}{overrides: map[int]magnetSite{}, disabled: map[int]bool{}}

// magnetInitSources 在 nativeEngine 建好后调用；重复调用（测试 / 热重载）是幂等的，
// 同一目录只从磁盘读一次，避免把运行期的新增覆盖掉。
func magnetInitSources(directory string) {
	if strings.TrimSpace(directory) == "" {
		return
	}
	path := filepath.Join(directory, "magnet_sources.json")
	magnetSources.Lock()
	defer magnetSources.Unlock()
	if magnetSources.loaded && magnetSources.path == path {
		return
	}
	magnetSources.path = path
	magnetSources.loaded = true
	magnetSources.custom = nil
	magnetSources.overrides = map[int]magnetSite{}
	magnetSources.disabled = map[int]bool{}
	body, err := os.ReadFile(path)
	if err != nil || len(body) == 0 || len(body) > 1<<20 {
		return
	}
	var stored magnetSourceFile
	if json.Unmarshal(body, &stored) != nil {
		return
	}
	for _, site := range stored.Custom {
		if magnetValidCustomSite(site) {
			magnetSources.custom = append(magnetSources.custom, site)
		}
	}
	for _, site := range stored.Overrides {
		if site.ID > 0 && strings.TrimSpace(site.Expression.Group) != "" {
			site.Custom = false
			magnetSources.overrides[site.ID] = site
		}
	}
	for _, id := range stored.Disabled {
		magnetSources.disabled[id] = true
	}
}

func magnetSourceSnapshot() ([]magnetSite, map[int]magnetSite, map[int]bool) {
	magnetSources.RLock()
	defer magnetSources.RUnlock()
	custom := append([]magnetSite(nil), magnetSources.custom...)
	overrides := make(map[int]magnetSite, len(magnetSources.overrides))
	for id, site := range magnetSources.overrides {
		overrides[id] = site
	}
	disabled := make(map[int]bool, len(magnetSources.disabled))
	for id := range magnetSources.disabled {
		disabled[id] = true
	}
	return custom, overrides, disabled
}

// saveMagnetSourcesLocked 要求调用方已持有写锁，与 customMaccmsRegistry.save 同约定。
func saveMagnetSourcesLocked() error {
	if magnetSources.path == "" {
		return nil // 未初始化（单测 / 纯内存调用）时只改内存，不落盘
	}
	stored := magnetSourceFile{Custom: magnetSources.custom}
	for _, site := range magnetSources.overrides {
		stored.Overrides = append(stored.Overrides, site)
	}
	// 覆盖表是 map，落盘前按 ID 排序，避免每次写文件顺序都变。
	sort.Slice(stored.Overrides, func(i, j int) bool {
		return stored.Overrides[i].ID < stored.Overrides[j].ID
	})
	for id := range magnetSources.disabled {
		stored.Disabled = append(stored.Disabled, id)
	}
	sort.Ints(stored.Disabled)
	body, err := json.Marshal(stored)
	if err != nil {
		return err
	}
	return writeNativeCacheFile(magnetSources.path, body)
}

func magnetValidCustomSite(site magnetSite) bool {
	if site.ID < magnetCustomIDBase || strings.TrimSpace(site.Name) == "" {
		return false
	}
	if strings.TrimSpace(site.Request.SearchURL) == "" && strings.TrimSpace(site.Request.ListURL) == "" {
		return false
	}
	return strings.TrimSpace(site.Expression.Group) != ""
}

func magnetCustomID(base string) int {
	hash := fnv.New32a()
	_, _ = hash.Write([]byte(strings.ToLower(strings.TrimSpace(base))))
	return magnetCustomIDBase + int(hash.Sum32()%100000)
}

func magnetSiteOrigin(raw string) string {
	parsed, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || parsed.Scheme == "" || parsed.Host == "" {
		return ""
	}
	return parsed.Scheme + "://" + parsed.Host
}

// magnetParseCustomRule 接受弹窗里粘贴/自动识别出的规则 JSON。允许两种形态：
// 完整的 magnetSite（带 request / expressionModel），或自动识别器输出的扁平结构
// （name / mainUrl / searchUrl / header / expressionModel）。两者都归一化成 magnetSite。
func magnetParseCustomRule(name, base, rule string) (magnetSite, error) {
	rule = strings.TrimSpace(rule)
	if rule == "" {
		return magnetSite{}, errors.New("请先自动识别或粘贴磁力源规则")
	}
	var raw map[string]any
	if err := json.Unmarshal([]byte(rule), &raw); err != nil {
		return magnetSite{}, fmt.Errorf("规则不是合法 JSON：%v", err)
	}
	// 完整形态：直接反序列化，再补上缺省的名称与主页。
	if _, nested := raw["request"]; nested {
		body, _ := json.Marshal(raw)
		var site magnetSite
		if err := json.Unmarshal(body, &site); err != nil {
			return magnetSite{}, fmt.Errorf("规则字段无法解析：%v", err)
		}
		if strings.TrimSpace(site.Request.MainURL) == "" {
			site.Request.MainURL = magnetSiteOrigin(site.Request.SearchURL)
		}
		site.Custom = true
		if strings.TrimSpace(name) != "" {
			site.Name = strings.TrimSpace(name)
		}
		return site, nil
	}
	// 扁平形态：自动识别器与用户手写规则常这么给。
	read := func(key string) string {
		if value, ok := raw[key].(string); ok {
			return strings.TrimSpace(value)
		}
		return ""
	}
	site := magnetSite{
		Name:   strings.TrimSpace(name),
		Info:   read("info"),
		State:  true,
		Custom: true,
		Request: magnetSiteRequest{
			Method:    strings.ToUpper(read("method")),
			MainURL:   read("mainUrl"),
			SearchURL: read("searchUrl"),
			ListURL:   read("listUrl"),
		},
	}
	if site.Request.Method == "" {
		site.Request.Method = "GET"
	}
	if site.Request.MainURL == "" {
		site.Request.MainURL = magnetSiteOrigin(base)
	}
	if site.Request.MainURL == "" {
		site.Request.MainURL = magnetSiteOrigin(site.Request.SearchURL)
	}
	if header, ok := raw["header"].(map[string]any); ok {
		site.Request.Header = map[string]string{}
		for key, value := range header {
			if text, ok := value.(string); ok && strings.TrimSpace(text) != "" {
				site.Request.Header[key] = text
			}
		}
	}
	expression, ok := raw["expressionModel"].(map[string]any)
	if !ok {
		// 也允许把 group/title/... 直接平铺在顶层。
		expression = raw
	}
	for key, target := range map[string]*string{
		"group": &site.Expression.Group, "title": &site.Expression.Title,
		"date": &site.Expression.Date, "size": &site.Expression.Size,
		"url": &site.Expression.URL, "magnet": &site.Expression.Magnet,
	} {
		if value, ok := expression[key].(string); ok {
			*target = value
		}
	}
	if site.Name == "" {
		site.Name = read("name")
	}
	if site.Name == "" {
		if parsed, err := url.Parse(site.Request.MainURL); err == nil && parsed.Host != "" {
			site.Name = parsed.Host
		}
	}
	if site.Name == "" {
		site.Name = "自定义磁力源"
	}
	if site.Request.MainURL == "" {
		return magnetSite{}, errors.New("规则缺少 mainUrl（源网址）")
	}
	if strings.TrimSpace(site.Expression.Group) == "" {
		return magnetSite{}, errors.New("规则缺少 expressionModel.group（列表条目 XPath）")
	}
	if strings.TrimSpace(site.Request.SearchURL) == "" &&
		strings.TrimSpace(site.Request.ListURL) == "" {
		return magnetSite{}, errors.New("规则缺少 searchUrl 或 listUrl")
	}
	return site, nil
}

func magnetSiteItemOf(site magnetSite) magnetSiteItem {
	item := magnetSiteItem{
		ID: site.ID, Name: site.Name, Info: site.Info,
		State: site.State, Custom: site.Custom,
		MainURL: site.Request.MainURL,
	}
	if body, err := json.Marshal(site); err == nil {
		item.Rule = string(body)
	}
	return item
}

func magnetAddCustomSite(name, base, rule string) (magnetSiteItem, error) {
	site, err := magnetParseCustomRule(name, base, rule)
	if err != nil {
		return magnetSiteItem{}, err
	}
	if strings.TrimSpace(site.Request.MainURL) == "" {
		site.Request.MainURL = strings.TrimRight(base, "/")
	}
	if site.Request.SearchURL != "" && !strings.HasPrefix(site.Request.SearchURL, "http") {
		site.Request.SearchURL = magnetAbsoluteURL(site, site.Request.SearchURL)
	}
	if !strings.HasPrefix(site.Request.SearchURL, "http") && strings.TrimSpace(site.Request.ListURL) == "" {
		return magnetSiteItem{}, errors.New("规则缺少可用的 searchUrl 或 listUrl")
	}
	origin := magnetSiteOrigin(site.Request.MainURL)
	if origin == "" {
		origin = magnetSiteOrigin(site.Request.SearchURL)
	}
	if origin == "" {
		return magnetSiteItem{}, errors.New("源网址不是合法的 http(s) 地址")
	}
	// 同一站点重复保存时落到同一个 ID，表现为「编辑」而不是堆出重复源。
	seed := strings.TrimSpace(base)
	if seed == "" {
		seed = origin
	}
	site.ID = magnetCustomID(seed)
	if site.Request.Header == nil {
		site.Request.Header = map[string]string{
			"Referer":    origin + "/",
			"User-Agent": userAgent,
		}
	}
	if !magnetValidCustomSite(site) {
		return magnetSiteItem{}, errors.New("规则必须包含 expressionModel.group（列表条目 XPath）")
	}

	magnetSources.Lock()
	defer magnetSources.Unlock()
	for index, existing := range magnetSources.custom {
		if existing.ID == site.ID {
			magnetSources.custom[index] = site
			if err := saveMagnetSourcesLocked(); err != nil {
				return magnetSiteItem{}, err
			}
			return magnetSiteItemOf(site), nil
		}
	}
	magnetSources.custom = append(magnetSources.custom, site)
	if err := saveMagnetSourcesLocked(); err != nil {
		return magnetSiteItem{}, err
	}
	return magnetSiteItemOf(site), nil
}

func magnetUpdateCustomSite(id int, name, rule string, state *bool) (magnetSiteItem, error) {
	magnetSources.Lock()
	defer magnetSources.Unlock()
	for index, existing := range magnetSources.custom {
		if existing.ID != id {
			continue
		}
		base := existing.Request.MainURL
		updated, err := magnetParseCustomRule(name, base, rule)
		if err != nil {
			return magnetSiteItem{}, err
		}
		updated.ID = id
		if state != nil {
			updated.State = *state
		} else {
			updated.State = existing.State
		}
		magnetSources.custom[index] = updated
		if err := saveMagnetSourcesLocked(); err != nil {
			return magnetSiteItem{}, err
		}
		return magnetSiteItemOf(updated), nil
	}

	// 内置源：允许编辑规则，写进覆盖层；「恢复默认」会把它清掉。
	builtin, err := magnetBuiltinByID(id)
	if err != nil {
		return magnetSiteItem{}, err
	}
	if strings.TrimSpace(rule) == "" {
		// 只改启停、没给规则：沿用当前生效规则（可能已经是覆盖过的）。
		current := builtin
		if patched, ok := magnetSources.overrides[id]; ok {
			current = patched
		}
		if state != nil && !*state {
			magnetSources.disabled[id] = true
			delete(magnetSources.overrides, id)
			if err := saveMagnetSourcesLocked(); err != nil {
				return magnetSiteItem{}, err
			}
			return magnetSiteItem{ID: id, State: false}, nil
		}
		if state != nil && *state {
			delete(magnetSources.disabled, id)
			if err := saveMagnetSourcesLocked(); err != nil {
				return magnetSiteItem{}, err
			}
			return magnetSiteItemOf(current), nil
		}
		return magnetSiteItemOf(current), nil
	}

	updated, err := magnetParseCustomRule(name, builtin.Request.MainURL, rule)
	if err != nil {
		return magnetSiteItem{}, err
	}
	updated.ID = id
	updated.Custom = false
	if state != nil {
		updated.State = *state
	} else if current, ok := magnetSources.overrides[id]; ok {
		updated.State = current.State
	} else {
		updated.State = builtin.State
	}
	// 内容与内置原始规则完全一致时不必留覆盖，省得升级后拿不到新规则。
	if magnetSiteEqual(updated, builtin) {
		delete(magnetSources.overrides, id)
	} else {
		magnetSources.overrides[id] = updated
	}
	delete(magnetSources.disabled, id)
	if err := saveMagnetSourcesLocked(); err != nil {
		return magnetSiteItem{}, err
	}
	item := magnetSiteItemOf(updated)
	item.Edited = true
	return item, nil
}

// magnetBuiltinByID 在内嵌的 35 站里按 ID 找原始规则。
//
// 只触发一次内嵌数据的解析，**不调用 loadMagnetSites**：后者要拿
// magnetSources 的读锁，而本函数会在持有写锁的调用方里被用到（编辑内置源），
// 那样会自己把自己锁死。
func magnetBuiltinByID(id int) (magnetSite, error) {
	magnetBuiltinOnce.Do(func() {
		magnetBuiltinErr = json.Unmarshal(magnetSitesJSON, &magnetBuiltinData)
	})
	if magnetBuiltinErr != nil {
		return magnetSite{}, magnetBuiltinErr
	}
	for _, site := range magnetBuiltinData {
		if site.ID == id {
			return site, nil
		}
	}
	return magnetSite{}, errors.New("找不到这个内置站源")
}

// magnetSiteEqual 只比会影响抓取结果的字段，忽略 Custom / Edited 之类的标记。
func magnetSiteEqual(left, right magnetSite) bool {
	if left.Name != right.Name || left.Info != right.Info || left.State != right.State {
		return false
	}
	if left.Request.MainURL != right.Request.MainURL ||
		left.Request.SearchURL != right.Request.SearchURL ||
		left.Request.ListURL != right.Request.ListURL {
		return false
	}
	if len(left.Request.Header) != len(right.Request.Header) {
		return false
	}
	for key, value := range left.Request.Header {
		if right.Request.Header[key] != value {
			return false
		}
	}
	return left.Expression == right.Expression
}

func magnetRemoveSite(id int) error {
	magnetSources.Lock()
	defer magnetSources.Unlock()
	for index, existing := range magnetSources.custom {
		if existing.ID == id {
			magnetSources.custom = append(
				magnetSources.custom[:index], magnetSources.custom[index+1:]...)
			return saveMagnetSourcesLocked()
		}
	}
	// 删内置站：禁用并丢掉它的覆盖，避免「先改再删再恢复」留下脏覆盖。
	magnetSources.disabled[id] = true
	delete(magnetSources.overrides, id)
	return saveMagnetSourcesLocked()
}

// magnetResetSites 恢复出厂：清空自定义源、内置覆盖与禁用表，回到内嵌的 35 站。
func magnetResetSites() (int, error) {
	magnetSources.Lock()
	defer magnetSources.Unlock()
	removed := len(magnetSources.custom) + len(magnetSources.overrides) + len(magnetSources.disabled)
	magnetSources.custom = nil
	magnetSources.overrides = map[int]magnetSite{}
	magnetSources.disabled = map[int]bool{}
	if err := saveMagnetSourcesLocked(); err != nil {
		return 0, err
	}
	return removed, nil
}

// magnetExportSites 导出当前「生效配置」：包含内置源（含被改过的版本）与自定义源。
// 导出的是完整规则，别人导入后能得到一模一样的站源表。
func magnetExportSites() (map[string]any, error) {
	sites, err := loadMagnetSites()
	if err != nil {
		return nil, err
	}
	exported := make([]magnetSite, 0, len(sites))
	for _, site := range sites {
		exported = append(exported, site)
	}
	return map[string]any{
		"version": 1,
		"sites":   exported,
		"count":   len(exported),
	}, nil
}

// magnetImportSites 导入一份站源配置。mode：
//   - replace：先用导入内容替换掉当前自定义源与内置覆盖（内置源本身仍在，只是规则被覆盖）
//   - merge：只追加/更新，不动其它源
//
// 导入时按 ID 归类：ID 落在自定义区间的新增为自定义源；其余按内置 ID 写覆盖层。
// 认不出的 ID（既不是内置也不是自定义区间）当作自定义源重新分配 ID，避免丢数据。
func magnetImportSites(body string, mode string) (map[string]any, error) {
	body = strings.TrimSpace(body)
	if body == "" {
		return nil, errors.New("导入内容为空")
	}
	var payload struct {
		Sites []magnetSite `json:"sites"`
	}
	// 也接受「直接是一个数组」的写法，方便用户手工整理配置。
	if strings.HasPrefix(body, "[") {
		if err := json.Unmarshal([]byte(body), &payload.Sites); err != nil {
			return nil, fmt.Errorf("导入内容不是合法的站源数组：%v", err)
		}
	} else if err := json.Unmarshal([]byte(body), &payload); err != nil {
		return nil, fmt.Errorf("导入内容不是合法的 JSON：%v", err)
	}
	if len(payload.Sites) == 0 {
		return nil, errors.New("导入内容里没有站源")
	}
	if len(payload.Sites) > 500 {
		return nil, errors.New("一次最多导入 500 个站源")
	}
	builtinIDs := map[int]bool{}
	// 注意：这里必须在拿写锁之前把内置 ID 表建好——loadMagnetSites 会去读
	// magnetSources，持锁再调会自锁。
	magnetBuiltinOnce.Do(func() {
		magnetBuiltinErr = json.Unmarshal(magnetSitesJSON, &magnetBuiltinData)
	})
	for _, site := range magnetBuiltinData {
		builtinIDs[site.ID] = true
	}

	magnetSources.Lock()
	defer magnetSources.Unlock()
	if mode == "replace" {
		magnetSources.custom = nil
		magnetSources.overrides = map[int]magnetSite{}
		magnetSources.disabled = map[int]bool{}
	}
	added, updated, skipped := 0, 0, 0
	for _, site := range payload.Sites {
		if strings.TrimSpace(site.Name) == "" || strings.TrimSpace(site.Expression.Group) == "" {
			skipped++
			continue
		}
		if strings.TrimSpace(site.Request.SearchURL) == "" && strings.TrimSpace(site.Request.ListURL) == "" {
			skipped++
			continue
		}
		if builtinIDs[site.ID] {
			site.Custom = false
			// 与出厂规则完全一致的条目不必留覆盖，省得升级后拿不到新版内置规则。
			builtin := magnetBuiltinData[0]
			for _, candidate := range magnetBuiltinData {
				if candidate.ID == site.ID {
					builtin = candidate
					break
				}
			}
			if magnetSiteEqual(site, builtin) {
				delete(magnetSources.overrides, site.ID)
				delete(magnetSources.disabled, site.ID)
				skipped++
				continue
			}
			if _, exists := magnetSources.overrides[site.ID]; exists {
				updated++
			} else {
				added++
			}
			magnetSources.overrides[site.ID] = site
			delete(magnetSources.disabled, site.ID)
			continue
		}
		// 自定义源：ID 必须落在自定义区间，否则重新按源网址分配。
		if site.ID < magnetCustomIDBase {
			site.ID = magnetCustomID(site.Request.MainURL + "|" + site.Name)
		}
		site.Custom = true
		replaced := false
		for index, existing := range magnetSources.custom {
			if existing.ID == site.ID {
				magnetSources.custom[index] = site
				replaced = true
				break
			}
		}
		if replaced {
			updated++
		} else {
			magnetSources.custom = append(magnetSources.custom, site)
			added++
		}
	}
	if err := saveMagnetSourcesLocked(); err != nil {
		return nil, err
	}
	return map[string]any{
		"added": added, "updated": updated, "skipped": skipped,
	}, nil
}

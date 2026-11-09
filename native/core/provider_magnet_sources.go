package core

import (
	"encoding/json"
	"errors"
	"fmt"
	"hash/fnv"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

// 用户自行新增的磁力站源与「删掉的内置站」一起持久化到应用数据目录，
// 规则形态与内置的 magnet_sites.json 完全一致（request + expressionModel）。
// 这样 loadMagnetSites 只要合并两个来源，搜索 / 浏览 / 列表都不需要分支。
type magnetSourceFile struct {
	Custom   []magnetSite `json:"custom"`
	Disabled []int        `json:"disabled,omitempty"`
}

const magnetCustomIDBase = 900000

var magnetSources = struct {
	sync.RWMutex
	path     string
	custom   []magnetSite
	disabled map[int]bool
	loaded   bool
}{disabled: map[int]bool{}}

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
	for _, id := range stored.Disabled {
		magnetSources.disabled[id] = true
	}
}

func magnetSourceSnapshot() ([]magnetSite, map[int]bool) {
	magnetSources.RLock()
	defer magnetSources.RUnlock()
	custom := append([]magnetSite(nil), magnetSources.custom...)
	disabled := make(map[int]bool, len(magnetSources.disabled))
	for id := range magnetSources.disabled {
		disabled[id] = true
	}
	return custom, disabled
}

// saveMagnetSourcesLocked 要求调用方已持有写锁，与 customMaccmsRegistry.save 同约定。
func saveMagnetSourcesLocked() error {
	if magnetSources.path == "" {
		return nil // 未初始化（单测 / 纯内存调用）时只改内存，不落盘
	}
	stored := magnetSourceFile{Custom: magnetSources.custom}
	for id := range magnetSources.disabled {
		stored.Disabled = append(stored.Disabled, id)
	}
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
	// 内置站只允许启停：写进 disabled 表，恢复时统一由 reset 清掉。
	if state != nil && !*state {
		magnetSources.disabled[id] = true
		if err := saveMagnetSourcesLocked(); err != nil {
			return magnetSiteItem{}, err
		}
		return magnetSiteItem{ID: id, State: false}, nil
	}
	return magnetSiteItem{}, errors.New("内置站源不支持编辑，可删除后到「恢复默认」找回")
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
	magnetSources.disabled[id] = true
	return saveMagnetSourcesLocked()
}

func magnetResetSites() (int, error) {
	magnetSources.Lock()
	defer magnetSources.Unlock()
	removed := len(magnetSources.custom) + len(magnetSources.disabled)
	magnetSources.custom = nil
	magnetSources.disabled = map[int]bool{}
	if err := saveMagnetSourcesLocked(); err != nil {
		return 0, err
	}
	return removed, nil
}

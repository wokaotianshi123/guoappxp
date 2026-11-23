package core

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
)

// 在线仓库：一份「仓库名 + index.json 地址」的列表，首个为当前启用的仓库。
// 配置文件落在应用数据目录，与模块安装包、资源设置彼此独立。
const (
	moduleRepositoriesFile  = "module-repositories.json"
	moduleRepositoriesBytes = 16 << 10
	moduleRepositoriesMax   = 20
	moduleRepositoryNameMax = 40
	moduleRepositoryURLMax  = 2048
)

type nativeModuleRepository struct {
	Name string `json:"name"`
	URL  string `json:"url"`
}

type moduleRepositoriesConfig struct {
	Repositories []nativeModuleRepository `json:"repositories"`
	Active       int                      `json:"active"`
}

// moduleBuiltinRepositories 是出厂自带的在线仓库列表，顺序即默认启用项。
//
// 「官方仓库」是本项目原本使用的 guoapp-modules/index，保留在最前面作为默认项；
// 后两家是社区合集，用户可在「在线仓库」里随时切换。
var moduleBuiltinRepositories = []nativeModuleRepository{
	{Name: "官方仓库", URL: "https://raw.githubusercontent.com/guoapp-modules/index/main/index.json"},
	// 真果鉴官方仓库：索引以 AES-256-GCM 加密下发（GCM1 封包），
	// 由 decryptModuleIndex 解出明文后走同一套解析。
	{Name: "真果鉴", URL: "https://guoapp.dpdns.org/modules/index.json"},
	{Name: "jqk4388", URL: "https://raw.githubusercontent.com/jqk4388/guoapp-modules-private/refs/heads/main/index.json"},
}

// 默认配置就是内置的两家商店；moduleIndex 在仓库失败时仍会把官方镜像
// （moduleIndexAddresses）当兜底组尝试（见 moduleIndexGroups）。
func defaultModuleRepositoriesConfig() moduleRepositoriesConfig {
	return moduleRepositoriesConfig{
		Repositories: append([]nativeModuleRepository(nil), moduleBuiltinRepositories...),
	}
}

// upgradeRepositories 把老版本的默认配置补齐成当前的内置列表。
//
// 老默认配置（只有内置官方镜像、或 guocheng1378 + jqk4388 那套）会被换成
// 当前的内置列表；只要用户自己加过、删过、改过仓库就原样保留，不覆盖用户配置。
func upgradeRepositories(config moduleRepositoriesConfig) moduleRepositoriesConfig {
	if len(config.Repositories) == 0 {
		return config
	}
	for _, repo := range config.Repositories {
		if !isBuiltinRepositoryURL(repo.URL) {
			return config
		}
	}
	// 全部都是出厂默认：与当前内置列表逐项比对（不能只比长度，新旧列表
	// 长度都是 3 但内容不同）。
	if sameRepositoryList(config.Repositories, moduleBuiltinRepositories) {
		return config
	}
	upgraded := defaultModuleRepositoriesConfig()
	// 尽量保住用户当时选中的仓库：按地址找到它在旧列表里的位置。
	if config.Active >= 0 && config.Active < len(config.Repositories) {
		activeURL := strings.ToLower(strings.TrimSpace(config.Repositories[config.Active].URL))
		for index, repo := range upgraded.Repositories {
			if strings.ToLower(strings.TrimSpace(repo.URL)) == activeURL {
				upgraded.Active = index
				break
			}
		}
	}
	return upgraded
}

// sameRepositoryList 判断两组仓库是否完全一致（顺序、地址都相同）。
func sameRepositoryList(left, right []nativeModuleRepository) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if strings.ToLower(strings.TrimSpace(left[index].URL)) !=
			strings.ToLower(strings.TrimSpace(right[index].URL)) {
			return false
		}
	}
	return true
}

// legacyBuiltinRepositoryURLs 是「曾经内置、后来被替换掉」的仓库地址。
//
// 这些地址仍算出厂默认，这样老用户的纯默认配置能被 upgradeRepositories
// 顺利换成当前列表；用户自己加的仓库不在其中，不会被误判。
var legacyBuiltinRepositoryURLs = []string{
	"https://raw.githubusercontent.com/guocheng1378/guoapp-modules/refs/heads/main/index.json",
}

// isBuiltinRepositoryURL 判断某个地址是否属于出厂自带的仓库（含官方镜像与被替换的旧地址）。
func isBuiltinRepositoryURL(address string) bool {
	key := strings.ToLower(strings.TrimSpace(address))
	if key == "" {
		return false
	}
	for _, repo := range moduleBuiltinRepositories {
		if strings.ToLower(strings.TrimSpace(repo.URL)) == key {
			return true
		}
	}
	for _, legacy := range legacyBuiltinRepositoryURLs {
		if strings.ToLower(strings.TrimSpace(legacy)) == key {
			return true
		}
	}
	for _, official := range moduleIndexAddresses {
		if strings.ToLower(strings.TrimSpace(official)) == key {
			return true
		}
	}
	return false
}

func (config moduleRepositoriesConfig) validate() error {
	if len(config.Repositories) == 0 {
		return errors.New("至少保留一个在线仓库")
	}
	if len(config.Repositories) > moduleRepositoriesMax {
		return fmt.Errorf("在线仓库最多 %d 个", moduleRepositoriesMax)
	}
	seen := map[string]bool{}
	for _, repo := range config.Repositories {
		name := strings.TrimSpace(repo.Name)
		if name == "" || len([]rune(name)) > moduleRepositoryNameMax {
			return errors.New("仓库名称应为 1 至 40 个字符")
		}
		address := strings.TrimSpace(repo.URL)
		if address == "" || len(address) > moduleRepositoryURLMax {
			return errors.New("仓库地址过长或为空")
		}
		parsed, err := url.Parse(address)
		if err != nil || parsed.Host == "" || parsed.Fragment != "" ||
			(parsed.Scheme != "http" && parsed.Scheme != "https") {
			return errors.New("仓库地址须为以 http:// 或 https:// 开头的 index.json 地址")
		}
		key := strings.ToLower(address)
		if seen[key] {
			return errors.New("仓库地址不能重复")
		}
		seen[key] = true
	}
	if config.Active < 0 || config.Active >= len(config.Repositories) {
		return errors.New("启用的仓库序号无效")
	}
	return nil
}

func (config moduleRepositoriesConfig) sanitized() moduleRepositoriesConfig {
	clean := moduleRepositoriesConfig{Active: config.Active}
	for _, repo := range config.Repositories {
		clean.Repositories = append(clean.Repositories, nativeModuleRepository{
			Name: strings.TrimSpace(repo.Name),
			URL:  strings.TrimSpace(repo.URL),
		})
	}
	return clean
}

func (engine *nativeEngine) moduleRepositoriesPath() string {
	return filepath.Join(engine.directory, moduleRepositoriesFile)
}

// loadModuleRepositories 读取已保存的仓库配置；文件缺失或非法时回退默认值。
func (engine *nativeEngine) loadModuleRepositories() {
	file := engine.moduleRepositoriesPath()
	info, err := os.Stat(file)
	if err != nil {
		engine.repositories = defaultModuleRepositoriesConfig()
		return
	}
	if !info.Mode().IsRegular() || info.Size() > moduleRepositoriesBytes {
		engine.repositoriesWarning = "在线仓库配置无效，已使用默认仓库"
		engine.repositories = defaultModuleRepositoriesConfig()
		return
	}
	data, readErr := os.ReadFile(file)
	var stored moduleRepositoriesConfig
	if readErr != nil || json.Unmarshal(data, &stored) != nil || stored.validate() != nil {
		engine.repositoriesWarning = "在线仓库配置无法读取，已使用默认仓库"
		engine.repositories = defaultModuleRepositoriesConfig()
		return
	}
	engine.repositories = upgradeRepositories(stored).sanitized()
}

// repositoriesView 供 UI 展示：带上当前启用项与可能的告警文案。
func (engine *nativeEngine) repositoriesView() map[string]any {
	engine.repositoriesMu.Lock()
	defer engine.repositoriesMu.Unlock()
	items := make([]map[string]any, 0, len(engine.repositories.Repositories))
	for _, repo := range engine.repositories.Repositories {
		items = append(items, map[string]any{"name": repo.Name, "url": repo.URL})
	}
	return map[string]any{
		"items":   items,
		"active":  engine.repositories.Active,
		"warning": engine.repositoriesWarning,
	}
}

// saveModuleRepositories 校验并保存仓库配置，空列表或非法地址直接拒绝。
func (engine *nativeEngine) saveModuleRepositories(config moduleRepositoriesConfig) (map[string]any, error) {
	clean := config.sanitized()
	if err := clean.validate(); err != nil {
		return nil, err
	}
	data, err := json.Marshal(clean)
	if err != nil {
		return nil, errors.New("无法保存在线仓库配置")
	}
	engine.repositoriesMu.Lock()
	defer engine.repositoriesMu.Unlock()
	if err := nativeDownloadWrite(engine.moduleRepositoriesPath(), data); err != nil {
		return nil, errors.New("未能保存在线仓库配置，原配置保持不变")
	}
	engine.repositories = clean
	engine.repositoriesWarning = ""
	return map[string]any{
		"items":  repositoriesAsMap(clean.Repositories),
		"active": clean.Active,
	}, nil
}

func repositoriesAsMap(repos []nativeModuleRepository) []map[string]any {
	items := make([]map[string]any, 0, len(repos))
	for _, repo := range repos {
		items = append(items, map[string]any{"name": repo.Name, "url": repo.URL})
	}
	return items
}

// activeModuleRepositoryURL 返回当前启用仓库的 index.json 地址；没有配置时
// 用内置官方仓库的第一处镜像。
func (engine *nativeEngine) activeModuleRepositoryURL() string {
	engine.repositoriesMu.Lock()
	config := engine.repositories
	engine.repositoriesMu.Unlock()
	if len(config.Repositories) == 0 {
		if len(moduleIndexAddresses) == 0 {
			return ""
		}
		return moduleIndexAddresses[0]
	}
	active := config.Active
	if active < 0 || active >= len(config.Repositories) {
		active = 0
	}
	if address := strings.TrimSpace(config.Repositories[active].URL); address != "" {
		return address
	}
	if len(moduleIndexAddresses) > 0 {
		return moduleIndexAddresses[0]
	}
	return ""
}

// moduleIndexGroups 返回按优先级排列的候选镜像组：
// 第一组是当前启用仓库的镜像（GitHub 仓库会展开成 jsDelivr / fastly / raw
// 三处，同一份 index.json 并发取），第二组是内置官方仓库的兜底。
// 两组内容完全相同时只取一组，避免对着同一个地址重试。
func (engine *nativeEngine) moduleIndexGroups() [][]string {
	groups := [][]string{}
	primary := moduleIndexMirrors(engine.activeModuleRepositoryURL())
	if len(primary) > 0 {
		groups = append(groups, primary)
	}
	official := dedupeModuleAddresses(moduleIndexAddresses)
	if len(official) == 0 {
		return groups
	}
	if len(groups) == 0 || !sameModuleAddresses(groups[0], official) {
		groups = append(groups, official)
	}
	return groups
}

func dedupeModuleAddresses(addresses []string) []string {
	cleaned := make([]string, 0, len(addresses))
	for _, address := range addresses {
		address = strings.TrimSpace(address)
		if address == "" || sameModuleAddresses(cleaned, []string{address}) {
			continue
		}
		cleaned = append(cleaned, address)
	}
	return cleaned
}

// sameModuleAddresses 判断两组地址是否等价（顺序无关、忽略大小写）。
func sameModuleAddresses(left, right []string) bool {
	if len(left) != len(right) {
		return false
	}
	remaining := make([]string, 0, len(right))
	for _, address := range right {
		remaining = append(remaining, strings.ToLower(strings.TrimSpace(address)))
	}
	for _, address := range left {
		key := strings.ToLower(strings.TrimSpace(address))
		found := -1
		for index, candidate := range remaining {
			if candidate == key {
				found = index
				break
			}
		}
		if found < 0 {
			return false
		}
		remaining = append(remaining[:found], remaining[found+1:]...)
	}
	return true
}

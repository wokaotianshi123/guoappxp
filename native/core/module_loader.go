package core

// 站源模块：运行时加载的 JS 站源（目录里一份 manifest.json 加一份 main.js）。
//
// 移植自 guoappxpx。模块注册进与编译期站源完全相同的 Provider 契约，
// 因此目录、搜索、详情、取流、榜单等派发路径不需要为模块另开一套。
//
// 与上游的唯一差别在冲突处理：guoappxp 已经把红果、番茄、笔盒等源编进本体，
// 上游模块商店里的同名模块（hongguo、beabox…）会撞车。上游遇到冲突直接判失败，
// 这里改成「模块另行标记、两边共存」——模块标识被占用时以 mod:<标识> 登记
// （见 moduleSourceID），界面上一律标出它是模块源。

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/dop251/goja"
)

const (
	moduleAPIVersion  = 1
	moduleRuntimeJS   = "js"
	moduleDirectory   = "modules"
	moduleManifest    = "manifest.json"
	moduleEntry       = "main.js"
	moduleEntryBytes  = 4 << 20
	moduleStatePrefix = "module-"
	// moduleSourcePrefix 是模块标识与已有站源冲突时加的前缀。带冒号是为了和自定义源
	// 的 custom: 保持一致，拆剧集 ID 时按同样的规则处理（见 splitProviderDramaID）。
	moduleSourcePrefix = "mod:"
)

var moduleIDPattern = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{0,31}$`)

// moduleCapabilityTypes 是模块清单里 capabilities 声明到运行时可选接口的映射。
// 名字沿用上游清单，接口用 guoappxp 侧的既有定义。
var moduleCapabilityTypes = map[string][]reflect.Type{
	"search":          {reflect.TypeFor[Searcher](), reflect.TypeFor[WarningSearcher]()},
	"account":         {reflect.TypeFor[SourceAccount]()},
	"suggestions":     {reflect.TypeFor[Suggester]()},
	"recommendations": {reflect.TypeFor[Recommender]()},
	"danmaku":         {reflect.TypeFor[DanmakuProvider]()},
	"devices":         {reflect.TypeFor[DeviceProvider]()},
	"rankings":        {reflect.TypeFor[SourceRankings](), reflect.TypeFor[SourceRankingEntries]()},
	"seasons":         {reflect.TypeFor[SeasonProvider]()},
	"cover":           {reflect.TypeFor[CoverResolver]()},
	"metadata":        {reflect.TypeFor[MetadataEnricher]()},
	"catalogState":    {reflect.TypeFor[CatalogStateful]()},
	"mediaAuth":       {reflect.TypeFor[MediaAuthorizer]()},
}

type ModuleRanking struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Description string `json:"description"`
}

type ModuleManifest struct {
	ID                string   `json:"id"`
	Name              string   `json:"name"`
	Version           string   `json:"version"`
	Description       string   `json:"description"`
	Runtime           string   `json:"runtime"`
	API               int      `json:"api"`
	Hosts             []string `json:"hosts"`
	Capabilities      []string `json:"capabilities"`
	Adult             *bool    `json:"adult"`
	AllowEmptyCatalog bool     `json:"allowEmptyCatalog"`

	Group              string   `json:"group"`
	GroupName          string   `json:"groupName"`
	EntryName          string   `json:"entryName"`
	SkipVIPPrompt      bool     `json:"skipVipPrompt"`
	Aliases            []string `json:"aliases"`
	HostSuffixes       []string `json:"hostSuffixes"`
	BaseURL            string   `json:"baseUrl"`
	NoHostRotation     bool     `json:"noHostRotation"`
	KeepDetailEpisodes bool     `json:"keepDetailEpisodes"`
	ContinuousFeed     bool     `json:"continuousFeed"`
	BrowserFingerprint bool     `json:"browserFingerprint"`

	Rankings       []ModuleRanking `json:"rankings"`
	MediaAuthPaths []string        `json:"mediaAuthPaths"`
}

type jsModule struct {
	manifest     ModuleManifest
	program      *goja.Program
	capabilities map[reflect.Type]bool
	active       atomic.Pointer[jsProvider]
	// registeredID 是真正登记进站源注册表的 ID。与已有站源冲突时是
	// mod:<标识>，其余情况等于 manifest.ID。剧集 ID 与 host.source 都用它。
	registeredID string
}

// loadedModules 记录已登记进注册表的模块：
//   - byName 是「模块目录名（等于模块标识）→ 实际登记的站源 ID」；
//   - sources 是「已登记的模块站源 ID」集合，用来判断某个站源是不是模块。
//
// 两者分开是因为冲突改名后目录名与站源 ID 不再相等；卸载与更新都要按目录名
// 找回上一次登记的 ID，才能把旧注册干净地摘掉。
var loadedModules = struct {
	sync.Mutex
	byName  map[string]string
	sources map[string]bool
}{byName: map[string]string{}, sources: map[string]bool{}}

// moduleSourceID 决定模块登记用的站源 ID：标识没被占用就用模块自己的标识，
// 被占用（例如本体已编入红果、笔盒）时加 mod: 前缀另行标记，与本体源共存。
func moduleSourceID(manifest ModuleManifest) string {
	if !registeredProviderSource(manifest.ID) {
		return manifest.ID
	}
	return moduleSourcePrefix + manifest.ID
}

// isModuleProviderSource 判断站源是不是运行时加载的模块（含冲突改名后的 mod: 前缀）。
//
// 模块源不受本体的「版本裁剪」门控：它不在编译期的源清单里，用户在模块页装上
// 就应该能用，红果鉴与真果鉴一致。
func isModuleProviderSource(source string) bool {
	key := strings.ToLower(strings.TrimSpace(source))
	loadedModules.Lock()
	defer loadedModules.Unlock()
	return loadedModules.sources[key]
}

// moduleAllowsEmptyCatalog 表示这个模块允许返回空目录（站点没有固定分类）。
func moduleAllowsEmptyCatalog(source string) bool {
	descriptor, ok := sourceDescriptorOf(source)
	return ok && descriptor.AllowEmptyCatalog
}

func readModule(directory string) (*jsModule, error) {
	raw, err := os.ReadFile(filepath.Join(directory, moduleManifest))
	if err != nil {
		return nil, err
	}
	info, err := os.Stat(filepath.Join(directory, moduleEntry))
	if err != nil {
		return nil, err
	}
	if info.Size() > moduleEntryBytes {
		return nil, fmt.Errorf("%s 超过 %d MB", moduleEntry, moduleEntryBytes>>20)
	}
	code, err := os.ReadFile(filepath.Join(directory, moduleEntry))
	if err != nil {
		return nil, err
	}
	return parseModule(raw, code)
}

func parseModule(raw, code []byte) (*jsModule, error) {
	var manifest ModuleManifest
	if err := json.Unmarshal(raw, &manifest); err != nil {
		return nil, fmt.Errorf("%s 无法解析：%w", moduleManifest, err)
	}
	if !moduleIDPattern.MatchString(manifest.ID) {
		return nil, errors.New("模块标识只能用小写字母、数字、下划线和连字符，最长 32 个字符")
	}
	if strings.TrimSpace(manifest.Name) == "" {
		return nil, errors.New("模块缺少名称")
	}
	if manifest.Runtime != moduleRuntimeJS {
		return nil, fmt.Errorf("不支持的模块运行时 %q", manifest.Runtime)
	}
	if manifest.API != moduleAPIVersion {
		return nil, fmt.Errorf("模块接口版本为 %d，当前应用支持 %d", manifest.API, moduleAPIVersion)
	}
	if manifest.Adult == nil {
		return nil, errors.New("模块缺少 adult 声明")
	}
	capabilities := map[reflect.Type]bool{}
	for _, name := range manifest.Capabilities {
		types, known := moduleCapabilityTypes[name]
		if !known {
			return nil, fmt.Errorf("未知的模块能力 %q", name)
		}
		for _, capability := range types {
			capabilities[capability] = true
		}
	}
	if capabilities[reflect.TypeFor[MediaAuthorizer]()] != (len(manifest.MediaAuthPaths) > 0) {
		return nil, errors.New("媒体鉴权能力与 mediaAuthPaths 须同时声明")
	}
	for _, path := range manifest.MediaAuthPaths {
		if !strings.HasPrefix(path, "/") {
			return nil, errors.New("mediaAuthPaths 的每一项须以 / 开头")
		}
	}
	rankings := map[string]bool{}
	for _, ranking := range manifest.Rankings {
		if strings.TrimSpace(ranking.ID) == "" || strings.TrimSpace(ranking.Name) == "" || rankings[ranking.ID] {
			return nil, errors.New("榜单缺少标识、名称或标识重复")
		}
		rankings[ranking.ID] = true
	}
	if len(code) > moduleEntryBytes {
		return nil, fmt.Errorf("%s 超过 %d MB", moduleEntry, moduleEntryBytes>>20)
	}
	program, err := goja.Compile(manifest.ID+"/"+moduleEntry, "(function(module, exports, host) {"+string(code)+"\n})", true)
	if err != nil {
		return nil, err
	}
	return &jsModule{manifest: manifest, program: program, capabilities: capabilities}, nil
}

// id 是模块登记用的站源 ID（冲突改名后与标识不同）。
func (module *jsModule) id() string {
	if module.registeredID != "" {
		return module.registeredID
	}
	return module.manifest.ID
}

func (module *jsModule) descriptor() SourceDescriptor {
	var rankings []RankingBoard
	for _, ranking := range module.manifest.Rankings {
		rankings = append(rankings, RankingBoard{ID: ranking.ID, Source: module.id(), Name: ranking.Name, Description: ranking.Description})
	}
	return SourceDescriptor{
		Rankings:          rankings,
		ID:                module.id(),
		Name:              module.manifest.Name,
		Description:       module.manifest.Description,
		AllowEmptyCatalog: module.manifest.AllowEmptyCatalog,
		ValidCategory:     module.validCategory,

		Group:              module.manifest.Group,
		GroupName:          module.manifest.GroupName,
		EntryName:          module.manifest.EntryName,
		SkipVIPPrompt:      module.manifest.SkipVIPPrompt,
		Aliases:            module.manifest.Aliases,
		HostSuffixes:       module.manifest.HostSuffixes,
		BaseURL:            module.manifest.BaseURL,
		NoHostRotation:     module.manifest.NoHostRotation,
		KeepDetailEpisodes: module.manifest.KeepDetailEpisodes,
		ContinuousFeed:     module.manifest.ContinuousFeed,
		BrowserFingerprint: module.manifest.BrowserFingerprint,
	}
}

func (module *jsModule) allowsHost(host string) bool {
	host = strings.ToLower(host)
	for _, pattern := range module.manifest.Hosts {
		pattern = strings.ToLower(strings.TrimSpace(pattern))
		if suffix, wildcard := strings.CutPrefix(pattern, "*"); wildcard && strings.HasPrefix(suffix, ".") && strings.HasSuffix(host, suffix) {
			return true
		}
		if pattern != "" && pattern == host {
			return true
		}
	}
	return false
}

// loadModules 重建运行时的模块站源集合：先摘掉上一轮的注册，再依次扫描
// 内置模块与数据目录下的模块文件夹。引擎启动时调用一次。
func (d *Downloader) loadModules() {
	loadedModules.Lock()
	defer loadedModules.Unlock()
	for name := range loadedModules.byName {
		d.releaseModuleLocked(name)
	}
	clear(loadedModules.byName)
	clear(loadedModules.sources)
	d.installBundledModulesLocked()
	entries, err := os.ReadDir(d.moduleRoot())
	if err != nil {
		if !errors.Is(err, fs.ErrNotExist) {
			d.recordModuleFailure("", err)
		}
		return
	}
	for _, entry := range entries {
		if entry.IsDir() && !strings.HasPrefix(entry.Name(), ".") {
			d.registerModuleLocked(entry.Name())
		}
	}
}

func (d *Downloader) moduleRoot() string { return filepath.Join(d.cfg.dataDir, moduleDirectory) }

// releaseModuleLocked 把某个模块从站源注册表与 Provider 缓存里摘掉。
func (d *Downloader) releaseModuleLocked(name string) {
	registered, ok := loadedModules.byName[name]
	if !ok {
		return
	}
	delete(loadedModules.byName, name)
	delete(loadedModules.sources, registered)
	Unregister(registered)
	// 缓存的 Provider 还握着旧模块的 JS 虚拟机，必须一起丢掉，
	// 否则更新模块后仍由旧代码提供服务。
	d.forgetSourceProvider(registered)
	d.forgetSourceProvider(name)
}

func (d *Downloader) reloadModuleLocked(name string) {
	d.releaseModuleLocked(name)
	if _, err := os.Stat(filepath.Join(d.moduleRoot(), name)); err == nil {
		d.registerModuleLocked(name)
	}
}

func (d *Downloader) registerModuleLocked(name string) {
	module, err := readModule(filepath.Join(d.moduleRoot(), name))
	if err == nil && module.manifest.ID != name {
		err = fmt.Errorf("模块文件夹名应与标识 %q 一致", module.manifest.ID)
	}
	if err == nil {
		module.registeredID = moduleSourceID(module.manifest)
	}
	if err == nil && registeredProviderSource(module.registeredID) {
		err = fmt.Errorf("站源 %q 已被占用", module.registeredID)
	}
	if err != nil {
		d.recordModuleFailure(name, err)
		return
	}
	Register(module.descriptor(), module.provider)
	loadedModules.byName[name] = module.registeredID
	loadedModules.sources[module.registeredID] = true
	if module.registeredID != module.manifest.ID {
		// 冲突改名是正常情况（本体已经有同名站源），记一条信息日志方便排查
		// 「为什么模块装上了却多出一个带 mod: 前缀的源」。
		d.recordDiagnostic(diagnosticEvent{Time: time.Now(), Level: "info", Event: "module_load", Source: name,
			Message: fmt.Sprintf("模块 %s 与已有站源同名，改以站源 %s 注册", module.manifest.ID, module.registeredID)})
	}
}

func (d *Downloader) recordModuleFailure(module string, err error) {
	d.recordDiagnostic(diagnosticEvent{Time: time.Now(), Level: "error", Event: "module_load", Source: module, Message: err.Error()})
}

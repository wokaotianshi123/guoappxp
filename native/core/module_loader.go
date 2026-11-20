package core

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
)

var moduleIDPattern = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{0,31}$`)

// moduleBaseCapabilities 是「基础三件套」的能力别名。目录（catalog）、详情
// （detail）、播放（media）由 Provider 接口本身提供，任何模块都不用额外实现
// 接口，所以这几种名字只作为「已知能力」放行，不登记进能力表。
//
// 这几个名字来自 guoappcheng 商店的模块清单口径（catalog/detail/search/media），
// 与本站源模块一直用的扩展能力名（search/rankings/cover…）是两套写法。清单里
// 出现基础名时报「未知的模块能力」会让整批模块装不上，所以这里按已知处理。
var moduleBaseCapabilities = map[string]bool{
	"catalog": true,
	"detail":  true,
	"media":   true,
}

// moduleCapabilityAliases 把商店里的另一种写法折回本站的能力名。
// guoappcheng 的「搜索联想」写 suggest，本站接口叫 suggestions。
var moduleCapabilityAliases = map[string]string{
	"suggest": "suggestions",
}

// moduleIgnoredCapabilities 是商店清单里会出现、但本站没有对应接口的能力。
// 这些能力只影响商店那边的几处界面（自定义路由、首页流、日历、跳过片头预设），
// 装到本机后按「已声明但不实现」处理——不报错，也不假装有。
var moduleIgnoredCapabilities = map[string]bool{
	"routes":     true,
	"homefeed":   true,
	"calendar":   true,
	"skippreset": true,
}

var moduleCapabilityTypes = map[string][]reflect.Type{
	"search":          {reflect.TypeFor[Searcher](), reflect.TypeFor[WarningSearcher]()},
	"account":         {reflect.TypeFor[AccountProvider]()},
	"suggestions":     {reflect.TypeFor[Suggester]()},
	"recommendations": {reflect.TypeFor[Recommender]()},
	"danmaku":         {reflect.TypeFor[DanmakuProvider]()},
	"devices":         {reflect.TypeFor[DeviceProvider]()},
	"rankings":        {reflect.TypeFor[Ranker]()},
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

	// Group/GroupName 是「同一入口的多个条目归一组」的老写法；Category/Family
	// 是 guoappcheng 商店清单的分组字段（category 取 shortDrama/video/adult，
	// family 取 huangguo）。两者互不影响：前者是条目分组，后者只决定界面类目
	// （见 sourceClass）。
	Group         string   `json:"group"`
	GroupName     string   `json:"groupName"`
	Category      string   `json:"category"`
	Family        string   `json:"family"`
	EntryName     string   `json:"entryName"`
	SkipVIPPrompt bool     `json:"skipVipPrompt"`
	Aliases       []string `json:"aliases"`
	HostSuffixes  []string `json:"hostSuffixes"`
	BaseURL       string   `json:"baseUrl"`
	// Base 是 guoappcheng 商店清单里的站点基址（baseUrl 常留空），模块脚本
	// 通过 host.baseUrl() 取它；本站自己的清单写 baseUrl。
	Base               string `json:"base"`
	NoHostRotation     bool   `json:"noHostRotation"`
	KeepDetailEpisodes bool   `json:"keepDetailEpisodes"`
	ContinuousFeed     bool   `json:"continuousFeed"`
	BrowserFingerprint bool   `json:"browserFingerprint"`

	Rankings       []ModuleRanking `json:"rankings"`
	MediaAuthPaths []string        `json:"mediaAuthPaths"`
}

type jsModule struct {
	manifest     ModuleManifest
	program      *goja.Program
	capabilities map[reflect.Type]bool
	active       atomic.Pointer[jsProvider]

	// 清单原文与按原文解出来的通用结构：第三方商店的模块在 JS 里用
	// host.manifest() 读 config / base 这类本站结构里没有的字段，只能给原文。
	raw         []byte
	rawOnce     sync.Once
	rawManifest any
}

// manifestData 返回清单原文解析出的通用结构（map/slice/string/bool/float64），
// 供 host.manifest() 转成每次运行时的 JS 对象用。
func (module *jsModule) manifestData() any {
	module.rawOnce.Do(func() {
		var decoded any
		if err := json.Unmarshal(module.raw, &decoded); err != nil {
			decoded = map[string]any{}
		}
		module.rawManifest = decoded
	})
	return module.rawManifest
}

var loadedModules = struct {
	sync.Mutex
	ids map[string]bool
}{ids: map[string]bool{}}

// nativeModuleSource 判断某个站源是不是由站源模块提供的。
//
// 模块注册的站源 ID 就是模块标识本身（jsModule.descriptor() 拿 manifest.ID 当
// SourceDescriptor.ID），所以查 loadedModules.ids 即可。
//
// 前端用它区分「模块源」与「编进包里的源」：模块源和自定义源一样属于
// 「谁用谁配」的本机内容，装上就属于这台设备，不参与用户级源权限判定。
func nativeModuleSource(id string) bool {
	loadedModules.Lock()
	defer loadedModules.Unlock()
	return loadedModules.ids[id]
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
	// guoappcheng 商店的模块清单普遍不写 adult。缺省按「非限制级」处理，
	// 否则整批模块会因为缺这一个字段装不上；写了就必须是布尔值。
	if manifest.Adult == nil {
		adult := false
		manifest.Adult = &adult
	}
	capabilities := map[reflect.Type]bool{}
	for _, name := range manifest.Capabilities {
		name = strings.TrimSpace(name)
		if moduleBaseCapabilities[name] || moduleIgnoredCapabilities[name] {
			continue
		}
		if alias, aliased := moduleCapabilityAliases[name]; aliased {
			name = alias
		}
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
	return &jsModule{manifest: manifest, raw: append([]byte(nil), raw...), program: program, capabilities: capabilities}, nil
}

// moduleClassKeys 是模块清单 category/family 认可的站源类目。类目标识沿用
// 清单里的写法（shortDrama/video/huangguo/adult），与 guoappcheng 的
// 「短剧类 / 视频类 / 黄果类 / 成人类」一一对应；显示名在界面侧决定。
var moduleClassKeys = map[string]bool{
	"shortdrama": true,
	"video":      true,
	"huangguo":   true,
	"adult":      true,
}

// sourceClass 返回站源类目（界面按它把站源菜单分段）：以清单的 category 为准；
// 没写 category 时才退回 family。两项都没有时返回空，界面按站源标识的既有
// 归类兜底，再不行归「其他」。
//
// 注意 family 不能盖过 category：guoappcheng 商店里红果也写着
// "family": "huangguo"（那是同一套 App 系谱，不是界面上的「黄果类」），
// 而黄果类成员（黄豆/剧果等）的清单写的是 category: shortDrama。
// 「黄果类」的判定在界面侧按站源标识做，与 guoappcheng 的站源表一致。
func (manifest ModuleManifest) sourceClass() string {
	for _, raw := range []string{manifest.Category, manifest.Family} {
		key := strings.ToLower(strings.TrimSpace(raw))
		if moduleClassKeys[key] {
			return canonicalModuleClass(key)
		}
	}
	return ""
}

// canonicalModuleClass 把清单里的类目写法归一，避免 "shortdrama" 与
// "shortDrama" 在菜单里变成两个分段。
func canonicalModuleClass(key string) string {
	if key == "shortdrama" {
		return "shortDrama"
	}
	return key
}

func (module *jsModule) descriptor() SourceDescriptor {
	var rankings []RankingBoard
	for _, ranking := range module.manifest.Rankings {
		rankings = append(rankings, RankingBoard{ID: ranking.ID, Source: module.manifest.ID, Name: ranking.Name, Description: ranking.Description})
	}
	return SourceDescriptor{
		Rankings:          rankings,
		ID:                module.manifest.ID,
		Name:              module.manifest.Name,
		Description:       module.manifest.Description,
		AllowEmptyCatalog: module.manifest.AllowEmptyCatalog,
		ValidCategory:     module.validCategory,

		Group:              module.manifest.Group,
		GroupName:          module.manifest.GroupName,
		Category:           module.manifest.sourceClass(),
		EntryName:          module.manifest.EntryName,
		Adult:              *module.manifest.Adult,
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

func (d *Downloader) loadModules() {
	loadedModules.Lock()
	defer loadedModules.Unlock()
	for id := range loadedModules.ids {
		Unregister(id)
	}
	clear(loadedModules.ids)
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

func (d *Downloader) reloadModuleLocked(id string) {
	if loadedModules.ids[id] {
		Unregister(id)
		delete(loadedModules.ids, id)
	}
	if _, err := os.Stat(filepath.Join(d.moduleRoot(), id)); err == nil {
		d.registerModuleLocked(id)
	}
}

func (d *Downloader) registerModuleLocked(name string) {
	module, err := readModule(filepath.Join(d.moduleRoot(), name))
	if err == nil && module.manifest.ID != name {
		err = fmt.Errorf("模块文件夹名应与标识 %q 一致", module.manifest.ID)
	}
	if err == nil {
		err = moduleConflict(module.manifest)
	}
	if err != nil {
		d.recordModuleFailure(name, err)
		return
	}
	Register(module.descriptor(), module.provider)
	loadedModules.ids[module.manifest.ID] = true
}

func moduleConflict(manifest ModuleManifest) error {
	for _, name := range append([]string{manifest.ID}, manifest.Aliases...) {
		if owner, taken := registeredSource(name); taken && owner != manifest.ID {
			return fmt.Errorf("模块标识或别名 %q 与已有站源 %q 重复", name, owner)
		}
	}
	return nil
}

func (d *Downloader) recordModuleFailure(module string, err error) {
	d.recordDiagnostic(diagnosticEvent{Time: time.Now(), Level: "error", Event: "module_load", Source: module, Message: err.Error()})
}

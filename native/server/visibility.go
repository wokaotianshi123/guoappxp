package main

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"

	"duanjuapp/native/core"
)

// 源显示列表：被隐藏的站源不出现在首页站源下拉框里。
// 与 Flutter 端的 hiddenSites 语义一致——隐藏只影响首页显示，
// 自定义源记录、已缓存内容与播放都不受影响。
const visibilityFile = "source-visibility.json"

// sourceVisibilityRevision 标记源显示列表的结构版本。
// 新增默认隐藏的内置源时递增，并在 loadVisibility 里按版本把新增项补进旧存档，
// 保证升级后的老用户也默认看不到这些站源，同时不覆盖用户之后手动开启的选择。
const sourceVisibilityRevision = 3

// revisionHiddenSources 按版本记录「该版本起默认隐藏」的内置源。
// 加载旧存档时只补 parsed.Revision 之后的版本，已经手动开启过的源不会被翻回隐藏。
var revisionHiddenSources = map[int][]string{
	2: {"xchina", "theporny"},
	3: {"beabox", "jinguo", "jinguoduanju"},
}

// 从未保存过源显示列表时的默认隐藏集，与 App 端一致：
// 默认可见 = 红果、韩小圈、鬼片、A123、爱看机器人，其余内置源默认隐藏。
var defaultHiddenSources = map[string]bool{
	"huangdou": true, "huangju": true, "yeguo": true, "dsd": true,
	"xchina": true, "theporny": true,
	"huangguo-video": true, "huangguoai": true, "cloudfront": true,
	"fanguo": true,
	"huaguo": true,
	"wangguo": true, "faguo": true, "wuguo": true,
	"beabox": true, "jinguo": true, "jinguoduanju": true,
}

// adultModuleSources 返回清单里标记为限制级的站源模块。
// 限制级模块可以安装，但用户没有主动开启前不出现在首页站源下拉框里。
func adultModuleSources() map[string]bool {
	adult := map[string]bool{}
	for _, descriptor := range core.RegisteredSources() {
		if descriptor.Adult {
			adult[descriptor.ID] = true
		}
	}
	return adult
}

var (
	visibilityMu     sync.Mutex
	visibilityPath   string
	visibilityLoaded bool
	hiddenSources    = map[string]bool{}
	// visibilityExplicit 记录用户手动开关过的站源。限制级模块默认隐藏，
	// 只有用户主动开启过（出现在这里且不在 hiddenSources 里）才显示。
	visibilityExplicit = map[string]bool{}
)

func setVisibilityDirectory(directory string) {
	visibilityMu.Lock()
	visibilityPath = filepath.Join(directory, visibilityFile)
	visibilityLoaded = false
	hiddenSources = map[string]bool{}
	visibilityExplicit = map[string]bool{}
	visibilityMu.Unlock()
}

func loadVisibility() {
	if visibilityLoaded {
		return
	}
	if visibilityPath != "" {
		if raw, err := os.ReadFile(visibilityPath); err == nil {
			var parsed struct {
				Hidden   []string `json:"hidden"`
				Explicit []string `json:"explicit"`
				Revision int      `json:"revision"`
			}
			if json.Unmarshal(raw, &parsed) == nil {
				hiddenSources = map[string]bool{}
				for _, id := range parsed.Hidden {
					if id = strings.TrimSpace(id); id != "" {
						hiddenSources[id] = true
					}
				}
				visibilityExplicit = map[string]bool{}
				for _, id := range parsed.Explicit {
					if id = strings.TrimSpace(id); id != "" {
						visibilityExplicit[id] = true
					}
				}
				visibilityLoaded = true
				if parsed.Revision < sourceVisibilityRevision {
					for version := parsed.Revision + 1; version <= sourceVisibilityRevision; version++ {
						for _, id := range revisionHiddenSources[version] {
							if !visibilityExplicit[id] {
								hiddenSources[id] = true
							}
						}
					}
					_ = saveVisibility()
				}
				return
			}
		}
	}
	// 无存档（或存档不可读）时落到与 App 端一致的默认隐藏集。
	hiddenSources = map[string]bool{}
	for id := range defaultHiddenSources {
		hiddenSources[id] = true
	}
	visibilityExplicit = map[string]bool{}
	visibilityLoaded = true
}

func saveVisibility() error {
	if visibilityPath == "" {
		return nil
	}
	ids := []string{}
	for id := range hiddenSources {
		ids = append(ids, id)
	}
	explicit := []string{}
	for id := range visibilityExplicit {
		explicit = append(explicit, id)
	}
	raw, err := json.MarshalIndent(map[string]any{
		"hidden": ids, "explicit": explicit, "revision": sourceVisibilityRevision,
	}, "", "  ")
	if err != nil {
		return err
	}
	tmp := visibilityPath + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, visibilityPath)
}

func isSourceHidden(source string) bool {
	visibilityMu.Lock()
	defer visibilityMu.Unlock()
	loadVisibility()
	return hiddenLocked(source)
}

// hiddenLocked 在已持有 visibilityMu 时判断可见性，避免重复加锁。
func hiddenLocked(source string) bool {
	if hiddenSources[source] {
		return true
	}
	// 限制级模块默认不出现在首页；用户手动开关过之后以显式选择为准。
	return !visibilityExplicit[source] && adultModuleSources()[source]
}

// handleSourceVisibility GET 返回全部可用站源与可见状态；
// POST {id, visible} 设置某个站源是否在首页显示。
func handleSourceVisibility(writer http.ResponseWriter, request *http.Request) {
	visibilityMu.Lock()
	defer visibilityMu.Unlock()
	loadVisibility()
	switch request.Method {
	case http.MethodGet:
		items := []map[string]any{}
		seen := map[string]bool{}
		moduleSources := moduleSourceNames()
		for _, source := range sourceNames {
			if sourceAvailable(source.ID) {
				seen[source.ID] = true
				// 静态表只提供规范显示名与顺序，不代表这个源就编在包里：本地服务版
				// 不内置站源，表里的 id 同样是模块提供的，别标成「内置」。
				_, fromModule := moduleSources[source.ID]
				items = append(items, map[string]any{
					"id": source.ID, "name": source.Name, "builtin": !fromModule, "module": fromModule,
					"visible": !hiddenLocked(source.ID),
				})
			}
		}
		var customReply struct {
			OK   bool `json:"ok"`
			Data struct {
				Items []map[string]string `json:"items"`
			} `json:"data"`
		}
		if json.Unmarshal([]byte(core.NativeRequest(`{"action":"customSources"}`)), &customReply) == nil && customReply.OK {
			for _, custom := range customReply.Data.Items {
				if sourceAvailable(custom["id"]) {
					seen[custom["id"]] = true
					items = append(items, map[string]any{
						"id": custom["id"], "name": custom["name"], "builtin": false,
						"visible": !hiddenLocked(custom["id"]),
					})
				}
			}
		}
		// 站源模块提供的站源同样要能在这里开关：装上的模块源与内置源、自定义源
		// 一样参与「首页显示」的取舍。
		//
		// 模块注册的站源 ID 就是模块标识，很可能与静态表里的 id 同一个（模块商店
		// 里的 hongguo、ikanbot 之类就是照这些 id 命名的）。那种情况上面已经加过
		// 且用的是规范名，这里跳过，否则同一个源会列出两条。
		for source, name := range moduleSources {
			if seen[source] {
				continue
			}
			seen[source] = true
			if sourceAvailable(source) {
				items = append(items, map[string]any{
					"id": source, "name": name, "builtin": false, "module": true,
					"visible": !hiddenLocked(source),
				})
			}
		}
		// 与 /api/sources 同款排序：先中文（拼音序）后字母序。
		sort.SliceStable(items, func(i, j int) bool {
			return core.CompareSourceNames(items[i]["name"].(string), items[j]["name"].(string)) < 0
		})
		writeJSON(writer, map[string]any{"items": items})
	case http.MethodPost:
		payload := struct {
			ID      string `json:"id"`
			Visible bool   `json:"visible"`
		}{}
		if err := json.NewDecoder(request.Body).Decode(&payload); err != nil || strings.TrimSpace(payload.ID) == "" {
			writeJSON(writer, map[string]any{"ok": false, "error": "缺少站源标识"})
			return
		}
		if payload.Visible {
			delete(hiddenSources, payload.ID)
		} else {
			hiddenSources[payload.ID] = true
		}
		// 手动开关过就记下显式选择：限制级模块的默认隐藏只对没选择过的源生效。
		visibilityExplicit[payload.ID] = true
		if err := saveVisibility(); err != nil {
			writeJSON(writer, map[string]any{"ok": false, "error": "保存失败：" + err.Error()})
			return
		}
		writeJSON(writer, map[string]any{"ok": true})
	default:
		http.Error(writer, "只接受 GET/POST 请求", http.StatusMethodNotAllowed)
	}
}

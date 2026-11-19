package main

// 本地服务版的站源模块管理。
//
// 模块运行时都在核心（native/core/module_*.go），这里只把它包成 HTTP 接口，
// 并把模块源并进站源列表与源显示列表。
//
// 与 Flutter 端的差别：网页端没有本地文件选择器，「从文件安装」改成浏览器
// 上传安装包（POST 原始 zip 字节）；「从地址安装」与「从商店安装」与桌面端一致。

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"strings"

	"duanjuapp/native/core"
)

// moduleUploadBytes 是上传安装包的上限，与核心的 modulePackageBytes 对齐。
const moduleUploadBytes = 8 << 20

type moduleInfo struct {
	ID           string   `json:"id"`
	Name         string   `json:"name"`
	Version      string   `json:"version"`
	Description  string   `json:"description"`
	Capabilities []string `json:"capabilities"`
	Adult        bool     `json:"adult"`
	Error        string   `json:"error"`
}

// moduleItems 读核心的已装模块列表。核心响应是
// {"ok":true,"data":{"items":[...]}} 信封，必须从 data 里取 items。
func moduleItems() []moduleInfo {
	var reply struct {
		OK   bool `json:"ok"`
		Data struct {
			Items []moduleInfo `json:"items"`
		} `json:"data"`
	}
	if json.Unmarshal([]byte(core.NativeRequest(`{"action":"modules"}`)), &reply) != nil || !reply.OK {
		return []moduleInfo{}
	}
	items := reply.Data.Items
	if items == nil {
		return []moduleInfo{}
	}
	return items
}

// moduleSourceNames 返回模块提供的站源：(站源 ID → 显示名)。
//
// 模块注册的站源 ID 就是模块标识本身——核心 core.jsModule.descriptor() 拿
// manifest.ID 当 SourceDescriptor.ID，并不额外下发 sourceId 字段（曾经按
// sourceId 取，取到的永远是空串，于是模块源在站源列表和源显示里都不出现）。
//
// 名字用原名，不加「（模块）」之类的后缀：本地服务版不内置站源，所有站源都
// 来自模块，逐个标「模块」等于没标；App 端的站源页也从不加这个标注。
// 源显示列表要区分来源，由前端按 builtin / module / custom 标记自行渲染。
func moduleSourceNames() map[string]string {
	names := map[string]string{}
	for _, item := range moduleItems() {
		source := strings.TrimSpace(item.ID)
		if source == "" || strings.TrimSpace(item.Error) != "" {
			continue
		}
		name := strings.TrimSpace(item.Name)
		if name == "" {
			name = source
		}
		names[source] = name
	}
	return names
}

func moduleStoreItems() ([]map[string]any, string, error) {
	var reply struct {
		OK   bool `json:"ok"`
		Data struct {
			Items   []map[string]any `json:"items"`
			Warning string           `json:"warning"`
		} `json:"data"`
		Error string `json:"error"`
	}
	if err := json.Unmarshal([]byte(core.NativeRequest(`{"action":"moduleIndex"}`)), &reply); err != nil {
		return nil, "", errors.New("核心响应无法解析")
	}
	if !reply.OK {
		message := strings.TrimSpace(reply.Error)
		if message == "" {
			message = "读取模块商店失败"
		}
		return nil, "", errors.New(message)
	}
	return reply.Data.Items, reply.Data.Warning, nil
}

// moduleInstall 走「准备安装包 → 安装」两步：核心先校验安装包并把 zip 暂存成一个
// 一次性凭据，用户确认后再按凭据安装。三者互斥：file 本地路径 / address 下载地址 /
// indexed 商店标识。
func moduleInstall(file, address, indexed string) (map[string]any, error) {
	payload := map[string]any{"action": "prepareModule"}
	if file != "" {
		payload["file"] = file
	}
	if address != "" {
		payload["url"] = address
	}
	if indexed != "" {
		payload["source"] = indexed
	}
	encoded, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}
	var prepared struct {
		OK    bool           `json:"ok"`
		Data  map[string]any `json:"data"`
		Error string         `json:"error"`
	}
	if err := json.Unmarshal([]byte(core.NativeRequest(string(encoded))), &prepared); err != nil {
		return nil, errors.New("核心响应无法解析")
	}
	if !prepared.OK {
		return nil, errors.New(moduleErrorText(prepared.Error, "安装包校验失败"))
	}
	token, _ := prepared.Data["token"].(string)
	if strings.TrimSpace(token) == "" {
		return nil, errors.New("安装包校验失败")
	}
	installPayload, err := json.Marshal(map[string]any{"action": "installModule", "token": token})
	if err != nil {
		return nil, err
	}
	var installed struct {
		OK    bool           `json:"ok"`
		Data  map[string]any `json:"data"`
		Error string         `json:"error"`
	}
	if err := json.Unmarshal([]byte(core.NativeRequest(string(installPayload))), &installed); err != nil {
		return nil, errors.New("核心响应无法解析")
	}
	if !installed.OK {
		return nil, errors.New(moduleErrorText(installed.Error, "安装失败"))
	}
	result := map[string]any{}
	for key, value := range prepared.Data {
		if key != "token" {
			result[key] = value
		}
	}
	for key, value := range installed.Data {
		result[key] = value
	}
	return result, nil
}

func moduleUninstall(id string) error {
	encoded, err := json.Marshal(map[string]any{"action": "uninstallModule", "source": id})
	if err != nil {
		return err
	}
	var reply struct {
		OK    bool   `json:"ok"`
		Error string `json:"error"`
	}
	if err := json.Unmarshal([]byte(core.NativeRequest(string(encoded))), &reply); err != nil {
		return errors.New("核心响应无法解析")
	}
	if !reply.OK {
		return errors.New(moduleErrorText(reply.Error, "卸载失败"))
	}
	return nil
}

func moduleErrorText(message, fallback string) string {
	message = strings.TrimSpace(message)
	if message == "" {
		return fallback
	}
	return message
}

// coreReply 是核心 NativeRequest 的统一信封。
type coreReply struct {
	OK    bool           `json:"ok"`
	Data  map[string]any `json:"data"`
	Error string         `json:"error"`
}

func callCore(payload map[string]any) (coreReply, error) {
	encoded, err := json.Marshal(payload)
	if err != nil {
		return coreReply{}, err
	}
	var reply coreReply
	if err := json.Unmarshal([]byte(core.NativeRequest(string(encoded))), &reply); err != nil {
		return coreReply{}, errors.New("核心响应无法解析")
	}
	return reply, nil
}

// moduleUninstallMany 批量卸载，返回成功与失败的标识。
func moduleUninstallMany(ids []string) ([]string, []string, error) {
	reply, err := callCore(map[string]any{"action": "uninstallModules", "ids": ids})
	if err != nil {
		return nil, nil, err
	}
	if !reply.OK {
		return nil, nil, errors.New(moduleErrorText(reply.Error, "卸载失败"))
	}
	removed := stringList(reply.Data["removed"])
	failures := stringList(reply.Data["failures"])
	return removed, failures, nil
}

// moduleReset 恢复默认：删除全部用户模块，内置模块重新装回来。
func moduleReset() ([]string, int, error) {
	reply, err := callCore(map[string]any{"action": "resetModules"})
	if err != nil {
		return nil, 0, err
	}
	if !reply.OK {
		return nil, 0, errors.New(moduleErrorText(reply.Error, "恢复默认失败"))
	}
	removed := stringList(reply.Data["removed"])
	bundled := 0
	if items, ok := reply.Data["bundled"].([]any); ok {
		bundled = len(items)
	}
	return removed, bundled, nil
}

func stringList(value any) []string {
	items, ok := value.([]any)
	if !ok {
		return nil
	}
	out := make([]string, 0, len(items))
	for _, item := range items {
		if text, ok := item.(string); ok && strings.TrimSpace(text) != "" {
			out = append(out, strings.TrimSpace(text))
		}
	}
	return out
}

// handleModuleBatchInstall 批量安装：提交多个地址或标识，逐个准备并安装。
func handleModuleBatchInstall(writer http.ResponseWriter, request *http.Request) {
	payload := struct {
		URLs []string `json:"urls"`
		IDs  []string `json:"ids"`
	}{}
	if err := json.NewDecoder(io.LimitReader(request.Body, 1<<20)).Decode(&payload); err != nil {
		writeJSON(writer, map[string]any{"ok": false, "error": "请求不是合法 JSON"})
		return
	}
	urls := make([]string, 0, len(payload.URLs))
	for _, value := range payload.URLs {
		if value = strings.TrimSpace(value); value != "" {
			urls = append(urls, value)
		}
	}
	if len(urls) == 0 && len(payload.IDs) == 0 {
		writeJSON(writer, map[string]any{"ok": false, "error": "请填写安装包地址或模块标识"})
		return
	}
	installed := 0
	failures := []string{}
	// 在线地址交给核心的批量准备接口，能一次展开多个地址和合集包。
	if len(urls) > 0 {
		reply, err := callCore(map[string]any{"action": "prepareModules", "urls": urls})
		if err != nil {
			writeJSON(writer, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		if !reply.OK {
			writeJSON(writer, map[string]any{"ok": false, "error": moduleErrorText(reply.Error, "安装包校验失败")})
			return
		}
		var prepared []map[string]any
		if items, ok := reply.Data["items"].([]any); ok {
			for _, item := range items {
				if entry, ok := item.(map[string]any); ok {
					prepared = append(prepared, entry)
				}
			}
		}
		count, problems := installPreparedModules(prepared)
		installed += count
		failures = append(failures, problems...)
	}
	// 商店标识走单个安装路径。
	for _, id := range payload.IDs {
		id = strings.TrimSpace(id)
		if id == "" {
			continue
		}
		if _, err := moduleInstall("", "", id); err != nil {
			failures = append(failures, id+"："+err.Error())
			continue
		}
		installed++
	}
	writeJSON(writer, map[string]any{
		"ok": true, "installed": installed, "failures": failures, "items": moduleItems(),
	})
}

// handleModuleExport 导出模块 zip。GET 导出全部，POST {"ids":[...]} 导出指定项。
func handleModuleExport(writer http.ResponseWriter, request *http.Request) {
	var ids []string
	if request.Method == http.MethodPost {
		payload := struct {
			IDs []string `json:"ids"`
		}{}
		if err := json.NewDecoder(io.LimitReader(request.Body, 1<<20)).Decode(&payload); err == nil {
			ids = payload.IDs
		}
	} else if request.Method != http.MethodGet {
		writeJSON(writer, map[string]any{"ok": false, "error": "不支持该请求方法"})
		return
	}
	reply, err := callCore(map[string]any{"action": "exportModules", "ids": ids})
	if err != nil {
		writeJSON(writer, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	if !reply.OK {
		writeJSON(writer, map[string]any{"ok": false, "error": moduleErrorText(reply.Error, "导出失败")})
		return
	}
	content, _ := reply.Data["content"].(string)
	raw, err := base64.StdEncoding.DecodeString(content)
	if err != nil || len(raw) == 0 {
		writeJSON(writer, map[string]any{"ok": false, "error": "导出内容无效"})
		return
	}
	writer.Header().Set("Content-Type", "application/zip")
	writer.Header().Set("Content-Disposition", `attachment; filename="guoapp-modules.zip"`)
	writer.Header().Set("Cache-Control", "no-store")
	_, _ = writer.Write(raw)
}

// handleModules 是模块页的接口：
//
//	GET  /api/modules           已装模块列表
//	GET  /api/modules/index     模块商店（含随包内置的模块）
//	POST /api/modules/install   安装：{"url":"…"} / {"id":"…"} / 原始 zip 字节
//	POST /api/modules/uninstall 卸载：{"id":"…"}
func handleModules(writer http.ResponseWriter, request *http.Request) {
	switch request.URL.Path {
	case "/api/modules":
		if request.Method != http.MethodGet {
			writeJSON(writer, map[string]any{"ok": false, "error": "不支持该请求方法"})
			return
		}
		writeJSON(writer, map[string]any{"ok": true, "items": moduleItems()})
	case "/api/modules/index":
		if request.Method != http.MethodGet {
			writeJSON(writer, map[string]any{"ok": false, "error": "不支持该请求方法"})
			return
		}
		items, warning, err := moduleStoreItems()
		if err != nil {
			writeJSON(writer, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		writeJSON(writer, map[string]any{"ok": true, "items": items, "warning": warning})
	case "/api/modules/install":
		if request.Method != http.MethodPost {
			writeJSON(writer, map[string]any{"ok": false, "error": "不支持该请求方法"})
			return
		}
		handleModuleInstall(writer, request)
	case "/api/modules/uninstall":
		if request.Method != http.MethodPost {
			writeJSON(writer, map[string]any{"ok": false, "error": "不支持该请求方法"})
			return
		}
		payload := struct {
			ID  string   `json:"id"`
			IDs []string `json:"ids"`
		}{}
		if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
			writeJSON(writer, map[string]any{"ok": false, "error": "缺少模块标识"})
			return
		}
		// 单个 id 与批量 ids 都接受；批量用于「恢复默认」这类一次删多个的场景。
		ids := payload.IDs
		if strings.TrimSpace(payload.ID) != "" {
			ids = append([]string{strings.TrimSpace(payload.ID)}, ids...)
		}
		if len(ids) == 0 {
			writeJSON(writer, map[string]any{"ok": false, "error": "缺少模块标识"})
			return
		}
		removed, failures, err := moduleUninstallMany(ids)
		if err != nil {
			writeJSON(writer, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		writeJSON(writer, map[string]any{"ok": true, "removed": removed, "failures": failures, "items": moduleItems()})
	case "/api/modules/batch":
		// 批量安装：一次提交多个地址或标识，核心展开后逐个安装。
		if request.Method != http.MethodPost {
			writeJSON(writer, map[string]any{"ok": false, "error": "不支持该请求方法"})
			return
		}
		handleModuleBatchInstall(writer, request)
	case "/api/modules/reset":
		if request.Method != http.MethodPost {
			writeJSON(writer, map[string]any{"ok": false, "error": "不支持该请求方法"})
			return
		}
		removed, bundled, err := moduleReset()
		if err != nil {
			writeJSON(writer, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		writeJSON(writer, map[string]any{"ok": true, "removed": removed, "bundled": bundled, "items": moduleItems()})
	case "/api/modules/export":
		// 导出模块为 zip：GET 全部，POST {"ids":[...]} 导出指定项。
		handleModuleExport(writer, request)
	default:
		http.NotFound(writer, request)
	}
}

func handleModuleInstall(writer http.ResponseWriter, request *http.Request) {
	body, err := io.ReadAll(io.LimitReader(request.Body, moduleUploadBytes+1))
	if err != nil {
		writeJSON(writer, map[string]any{"ok": false, "error": "读取安装包失败"})
		return
	}
	if len(body) == 0 {
		writeJSON(writer, map[string]any{"ok": false, "error": "安装包为空"})
		return
	}
	if len(body) > moduleUploadBytes {
		writeJSON(writer, map[string]any{"ok": false, "error": "安装包超过 8 MB"})
		return
	}
	// 三种入参：JSON 包装的地址 / 商店标识，或直接上传的 zip 字节。
	// zip 以 PK 开头，JSON 以 { 开头，可以安全区分。
	if trimmed := strings.TrimSpace(string(body)); strings.HasPrefix(trimmed, "{") {
		var payload struct {
			URL string `json:"url"`
			ID  string `json:"id"`
		}
		if err := json.Unmarshal(body, &payload); err == nil {
			address, indexed := strings.TrimSpace(payload.URL), strings.TrimSpace(payload.ID)
			if address == "" && indexed == "" {
				writeJSON(writer, map[string]any{"ok": false, "error": "请填写安装包地址或模块标识"})
				return
			}
			result, err := moduleInstall("", address, indexed)
			if err != nil {
				writeJSON(writer, map[string]any{"ok": false, "error": err.Error()})
				return
			}
			writeJSON(writer, map[string]any{"ok": true, "module": result, "items": moduleItems()})
			return
		}
	}
	// 上传的安装包先落到临时文件：核心按路径读，不接收内存里的字节。
	handle, err := os.CreateTemp("", "module-*.zip")
	if err != nil {
		writeJSON(writer, map[string]any{"ok": false, "error": "无法暂存安装包"})
		return
	}
	location := handle.Name()
	defer os.Remove(location)
	if _, err := handle.Write(body); err != nil {
		handle.Close()
		writeJSON(writer, map[string]any{"ok": false, "error": "无法暂存安装包"})
		return
	}
	handle.Close()
	// 走批量准备接口：单个模块 zip 与「一个 zip 里含多个子模块 zip」都能装。
	installed, failures, err := moduleInstallFiles([]string{location})
	if err != nil {
		writeJSON(writer, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	if installed == 0 {
		message := "安装包校验失败"
		if len(failures) > 0 {
			message = strings.Join(failures, "；")
		}
		writeJSON(writer, map[string]any{"ok": false, "error": message})
		return
	}
	writeJSON(writer, map[string]any{
		"ok": true, "installed": installed, "failures": failures, "items": moduleItems(),
	})
}

// moduleInstallFiles 把本地安装包交给核心批量准备并逐个安装，返回成功数与失败说明。
func moduleInstallFiles(files []string) (int, []string, error) {
	reply, err := callCore(map[string]any{"action": "prepareModules", "files": files})
	if err != nil {
		return 0, nil, err
	}
	if !reply.OK {
		return 0, nil, errors.New(moduleErrorText(reply.Error, "安装包校验失败"))
	}
	count, failures := installPreparedModules(preparedEntries(reply.Data["items"]))
	return count, failures, nil
}

// preparedEntries 从核心响应里取出待安装项。
func preparedEntries(value any) []map[string]any {
	items, ok := value.([]any)
	if !ok {
		return nil
	}
	out := make([]map[string]any, 0, len(items))
	for _, item := range items {
		if entry, ok := item.(map[string]any); ok {
			out = append(out, entry)
		}
	}
	return out
}

// installPreparedModules 逐个安装已暂存的模块，返回成功数与失败说明。
func installPreparedModules(prepared []map[string]any) (int, []string) {
	installed := 0
	failures := []string{}
	for _, entry := range prepared {
		info, _ := entry["info"].(map[string]any)
		token, _ := info["token"].(string)
		name, _ := entry["name"].(string)
		if message, _ := entry["error"].(string); strings.TrimSpace(message) != "" {
			failures = append(failures, name+"："+message)
			continue
		}
		if strings.TrimSpace(token) == "" {
			failures = append(failures, name+"：安装包校验失败")
			continue
		}
		reply, err := callCore(map[string]any{"action": "installModule", "token": token})
		if err != nil || !reply.OK {
			message := "安装失败"
			if err != nil {
				message = err.Error()
			} else {
				message = moduleErrorText(reply.Error, message)
			}
			failures = append(failures, name+"："+message)
			continue
		}
		installed++
	}
	return installed, failures
}

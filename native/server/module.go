package main

// 本地服务版的站源模块管理。
//
// 模块运行时都在核心（native/core/module_*.go），这里只把它包成 HTTP 接口，
// 并把模块源并进站源列表与源显示列表。
//
// 与 Flutter 端的差别：网页端没有本地文件选择器，「从文件安装」改成浏览器
// 上传安装包（POST 原始 zip 字节）；「从地址安装」与「从商店安装」与桌面端一致。

import (
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
	SourceID     string   `json:"sourceId"`
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
// 站源 ID 与模块标识同名时带 mod: 前缀（核心侧改名，见 core.moduleSourceID），
// 显示名统一带「（模块）」标注，与同名的本体源区分开。
func moduleSourceNames() map[string]string {
	names := map[string]string{}
	for _, item := range moduleItems() {
		source := strings.TrimSpace(item.SourceID)
		if source == "" || strings.TrimSpace(item.Error) != "" {
			continue
		}
		name := strings.TrimSpace(item.Name)
		if name == "" {
			name = source
		}
		names[source] = name + "（模块）"
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
			ID string `json:"id"`
		}{}
		if err := json.NewDecoder(request.Body).Decode(&payload); err != nil || strings.TrimSpace(payload.ID) == "" {
			writeJSON(writer, map[string]any{"ok": false, "error": "缺少模块标识"})
			return
		}
		if err := moduleUninstall(strings.TrimSpace(payload.ID)); err != nil {
			writeJSON(writer, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		writeJSON(writer, map[string]any{"ok": true, "items": moduleItems()})
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
	result, err := moduleInstall(location, "", "")
	if err != nil {
		writeJSON(writer, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	writeJSON(writer, map[string]any{"ok": true, "module": result, "items": moduleItems()})
}

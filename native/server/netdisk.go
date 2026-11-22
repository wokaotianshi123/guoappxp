package main

import (
	"errors"
	"net/http"
	"strings"
)

// 网盘（夸克）与饭太硬 / TVBox 订阅的 HTTP 入口。
//
// 这些动作在 Go 核心里已经实现（netdisk* / tvbox*），服务端只负责转发与
// 参数校验；前端拿到的是和 App 端一致的 JSON 结构。

// handleNetdisk 统一处理 /api/netdisk/ 下的子动作。
func handleNetdisk(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost && request.Method != http.MethodGet {
		http.Error(writer, "只支持 POST 或 GET 请求", http.StatusMethodNotAllowed)
		return
	}
	action := strings.TrimPrefix(request.URL.Path, "/api/netdisk/")
	query := request.URL.Query()
	payload := map[string]any{"action": "netdisk" + netdiskActionName(action)}
	switch action {
	case "loginPoll":
		payload["session"] = query.Get("session")
	case "logout":
		payload["source"] = firstNonEmptyString(query.Get("provider"), "quark")
	case "share", "openShare":
		payload["url"] = query.Get("url")
	case "play":
		payload["url"] = query.Get("url")
		payload["index"] = query.Get("index")
	}
	reply, err := callCore(payload)
	if err != nil {
		writeJSON(writer, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	if !reply.OK {
		writeJSON(writer, map[string]any{"ok": false, "error": netdiskErrorText(reply.Error)})
		return
	}
	writeJSON(writer, map[string]any{"ok": true, "data": reply.Data})
}

// netdiskActionName 把 URL 里的短动作名映射成核心动作名。
func netdiskActionName(action string) string {
	switch action {
	case "status":
		return "Status"
	case "login":
		return "Login"
	case "loginPoll":
		return "LoginPoll"
	case "logout":
		return "Logout"
	case "share":
		return "Share"
	case "play":
		return "Play"
	case "openShare":
		return "OpenShare"
	case "cleanup":
		return "Cleanup"
	case "info":
		return "Info"
	default:
		return "Status"
	}
}

func netdiskErrorText(raw string) string {
	text := strings.TrimSpace(raw)
	if text == "" {
		return "网盘请求失败"
	}
	return text
}

// handleTVBox 统一处理 /api/tvbox/ 下的子动作。
func handleTVBox(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost && request.Method != http.MethodGet {
		http.Error(writer, "只支持 POST 或 GET 请求", http.StatusMethodNotAllowed)
		return
	}
	action := strings.TrimPrefix(request.URL.Path, "/api/tvbox/")
	query := request.URL.Query()
	switch action {
	case "subscribe":
		url := strings.TrimSpace(query.Get("url"))
		if url == "" {
			writeJSON(writer, map[string]any{"ok": false, "error": "请填写订阅地址"})
			return
		}
		reply, err := callCore(map[string]any{"action": "tvboxSubscribe", "url": url})
		if err != nil {
			writeJSON(writer, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		if !reply.OK {
			writeJSON(writer, map[string]any{"ok": false, "error": tvboxErrorText(reply.Error)})
			return
		}
		writeJSON(writer, map[string]any{"ok": true, "data": reply.Data})
	case "clear":
		reply, err := callCore(map[string]any{"action": "tvboxClear"})
		if err != nil {
			writeJSON(writer, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		if !reply.OK {
			writeJSON(writer, map[string]any{"ok": false, "error": tvboxErrorText(reply.Error)})
			return
		}
		writeJSON(writer, map[string]any{"ok": true, "data": reply.Data})
	default:
		reply, err := callCore(map[string]any{"action": "tvboxStatus"})
		if err != nil {
			writeJSON(writer, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		if !reply.OK {
			writeJSON(writer, map[string]any{"ok": false, "error": tvboxErrorText(reply.Error)})
			return
		}
		writeJSON(writer, map[string]any{"ok": true, "data": reply.Data})
	}
}

func tvboxErrorText(raw string) string {
	text := strings.TrimSpace(raw)
	if text == "" {
		return "订阅请求失败"
	}
	return text
}

// handleWebViewBridge 登记浏览器验证后的回环抓取通道。
//
// 本地服务版没有原生 WebView，前端用浏览器自带的验证页完成后，把 Cookie /
// User-Agent 与一个本机端口交给核心，核心之后遇到挑战域名时改走该端口。
func handleWebViewBridge(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		http.Error(writer, "只支持 POST 请求", http.StatusMethodNotAllowed)
		return
	}
	query := request.URL.Query()
	port := query.Get("port")
	source := query.Get("source")
	url := query.Get("url")
	cookies := query.Get("cookies")
	userAgent := query.Get("userAgent")
	payload := map[string]any{"action": "webViewBridge", "url": url, "source": source, "token": cookies, "device": userAgent}
	if port != "" {
		payload["index"] = port
	}
	reply, err := callCore(payload)
	if err != nil {
		writeJSON(writer, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	if !reply.OK {
		writeJSON(writer, map[string]any{"ok": false, "error": netdiskErrorText(reply.Error)})
		return
	}
	writeJSON(writer, map[string]any{"ok": true, "data": reply.Data})
}

// handleSourceChallenge 返回站源建议的验证地址。
func handleSourceChallenge(writer http.ResponseWriter, request *http.Request) {
	source := request.URL.Query().Get("source")
	reply, err := callCore(map[string]any{"action": "sourceChallengeUrl", "source": source})
	if err != nil {
		writeJSON(writer, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	if !reply.OK {
		writeJSON(writer, map[string]any{"ok": false, "error": netdiskErrorText(reply.Error)})
		return
	}
	writeJSON(writer, map[string]any{"ok": true, "data": reply.Data})
}

func firstNonEmptyString(values ...string) string {
	for _, value := range values {
		if trimmed := strings.TrimSpace(value); trimmed != "" {
			return trimmed
		}
	}
	return ""
}

var errNetdiskUnavailable = errors.New("网盘模块尚未初始化")

package main

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// JS 沙箱（本地服务版）。
//
// App 端的沙箱跑在 Flutter 里（QuickJS / JavaScriptCore），本地服务版没有
// Dart 运行时，脚本改由浏览器执行：网页用一个 Web Worker 装载脚本，脚本里的
// fetch 经本文件的 /api/js/fetch 代发（绕开 CORS，并且由服务端带 UA / Referer），
// 取到的直链再由 /api/js/stream 代理播放（浏览器的 <video> 不能自定义请求头）。
//
// 这里只负责「存脚本」和「代发请求」，不理解 CatPawOpen 协议——协议解析在
// js-sandbox-worker.js 里，与 App 端共用同一套 shim。

const (
	jsSourceDirName  = "js_sources"
	jsSourceMaxBytes = 4 << 20
	jsFetchMaxBytes  = 8 << 20
)

var (
	jsSourceMu   sync.Mutex
	jsSourceRoot string
)

// jsSourceMeta 是脚本 meta 里沙箱用得到的那几个字段。
// 解析规则与 Dart 侧 parseJsSourceMeta 完全一致：只认字面量，不做 JS 求值。
type jsSourceMeta struct {
	ID          string   `json:"id"`
	Name        string   `json:"name"`
	Version     string   `json:"version"`
	Description string   `json:"description"`
	Author      string   `json:"author"`
	Features    []string `json:"features"`
	FileName    string   `json:"fileName"`
	Active      bool     `json:"active"`
}

var (
	jsMetaID       = regexp.MustCompile(`\bid\s*:\s*["']([^"']+)["']`)
	jsMetaName     = regexp.MustCompile(`\bname\s*:\s*["']([^"']+)["']`)
	jsMetaVersion  = regexp.MustCompile(`\bversion\s*:\s*["']([^"']+)["']`)
	jsMetaDesc     = regexp.MustCompile(`\bdescription\s*:\s*["']([^"']+)["']`)
	jsMetaAuthor   = regexp.MustCompile(`\bauthor\s*:\s*["']([^"']+)["']`)
	jsMetaFeatures = regexp.MustCompile(`(?s)\bfeatures\s*:\s*\[(.*?)\]`)
	jsMetaQuoted   = regexp.MustCompile(`["']([^"']+)["']`)
	jsSafeID       = regexp.MustCompile(`^[A-Za-z0-9_.-]{1,64}$`)
	jsSafeFileName = regexp.MustCompile(`^[^/\\<>:"|?*\x00-\x1f]{1,180}$`)
)

func setJsSourceDirectory(directory string) {
	jsSourceMu.Lock()
	defer jsSourceMu.Unlock()
	jsSourceRoot = filepath.Join(directory, jsSourceDirName)
	_ = os.MkdirAll(jsSourceRoot, 0o755)
}

// parseJsSourceMeta 从脚本正文里读 meta。缺 id / name 视为不是脚本源。
func parseJsSourceMeta(script, fileName string) (jsSourceMeta, bool) {
	idMatch := jsMetaID.FindStringSubmatch(script)
	nameMatch := jsMetaName.FindStringSubmatch(script)
	if idMatch == nil || nameMatch == nil {
		return jsSourceMeta{}, false
	}
	id := strings.TrimSpace(idMatch[1])
	name := strings.TrimSpace(nameMatch[1])
	if !jsSafeID.MatchString(id) || name == "" {
		return jsSourceMeta{}, false
	}
	meta := jsSourceMeta{
		ID:       id,
		Name:     name,
		Version:  "1.0.0",
		FileName: fileName,
	}
	if match := jsMetaVersion.FindStringSubmatch(script); match != nil {
		meta.Version = strings.TrimSpace(match[1])
	}
	if match := jsMetaDesc.FindStringSubmatch(script); match != nil {
		meta.Description = strings.TrimSpace(match[1])
	}
	if match := jsMetaAuthor.FindStringSubmatch(script); match != nil {
		meta.Author = strings.TrimSpace(match[1])
	}
	features := []string{}
	if match := jsMetaFeatures.FindStringSubmatch(script); match != nil {
		for _, quoted := range jsMetaQuoted.FindAllStringSubmatch(match[1], -1) {
			features = append(features, strings.TrimSpace(quoted[1]))
		}
	}
	if len(features) == 0 {
		features = []string{"search", "categories"}
	}
	meta.Features = features
	return meta, true
}

func normalizeJsScript(raw []byte) string {
	text := string(raw)
	text = strings.TrimPrefix(text, "\ufeff")
	return strings.ReplaceAll(text, "\r\n", "\n")
}

// scanJsSources 读目录里的脚本并去重（同 id 保留版本更高的那份）。
func scanJsSources() []jsSourceMeta {
	jsSourceMu.Lock()
	root := jsSourceRoot
	jsSourceMu.Unlock()
	if root == "" {
		return nil
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		return nil
	}
	byID := map[string]jsSourceMeta{}
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(strings.ToLower(entry.Name()), ".js") {
			continue
		}
		raw, err := os.ReadFile(filepath.Join(root, entry.Name()))
		if err != nil {
			continue
		}
		meta, ok := parseJsSourceMeta(normalizeJsScript(raw), entry.Name())
		if !ok {
			continue
		}
		if existing, found := byID[meta.ID]; found && !versionNewer(meta.Version, existing.Version) {
			continue
		}
		byID[meta.ID] = meta
	}
	items := make([]jsSourceMeta, 0, len(byID))
	for _, meta := range byID {
		items = append(items, meta)
	}
	sort.Slice(items, func(i, j int) bool {
		return strings.ToLower(items[i].Name) < strings.ToLower(items[j].Name)
	})
	return items
}

func versionNewer(candidate, baseline string) bool {
	parts := func(text string) []int {
		fields := strings.Split(strings.SplitN(text, "-", 2)[0], ".")
		values := make([]int, 0, len(fields))
		for _, field := range fields {
			number := 0
			for _, char := range field {
				if char < '0' || char > '9' {
					break
				}
				number = number*10 + int(char-'0')
			}
			values = append(values, number)
		}
		return values
	}
	a, b := parts(candidate), parts(baseline)
	for i := 0; i < len(a) || i < len(b); i++ {
		var left, right int
		if i < len(a) {
			left = a[i]
		}
		if i < len(b) {
			right = b[i]
		}
		if left != right {
			return left > right
		}
	}
	return false
}

func writeJsSource(fileName, script string) (jsSourceMeta, error) {
	if !jsSafeFileName.MatchString(fileName) || !strings.HasSuffix(strings.ToLower(fileName), ".js") {
		return jsSourceMeta{}, errors.New("文件名无效，需以 .js 结尾且不能包含路径")
	}
	meta, ok := parseJsSourceMeta(script, fileName)
	if !ok {
		return jsSourceMeta{}, errors.New("无法识别脚本的 meta 定义（需要 id 与 name 字段）")
	}
	jsSourceMu.Lock()
	root := jsSourceRoot
	jsSourceMu.Unlock()
	if root == "" {
		return jsSourceMeta{}, errors.New("JS 沙箱目录尚未初始化")
	}
	// 同一个 id 换了文件名时把旧文件删掉，避免扫描出两份。
	removeJsSourceFiles(meta.ID, fileName)
	target := filepath.Join(root, fileName)
	if err := os.WriteFile(target, []byte(script), 0o644); err != nil {
		return jsSourceMeta{}, fmt.Errorf("写入脚本失败：%w", err)
	}
	return meta, nil
}

func removeJsSourceFiles(id, keep string) {
	jsSourceMu.Lock()
	root := jsSourceRoot
	jsSourceMu.Unlock()
	if root == "" {
		return
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		return
	}
	for _, entry := range entries {
		if entry.IsDir() || entry.Name() == keep || !strings.HasSuffix(strings.ToLower(entry.Name()), ".js") {
			continue
		}
		path := filepath.Join(root, entry.Name())
		raw, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		if meta, ok := parseJsSourceMeta(normalizeJsScript(raw), entry.Name()); ok && meta.ID == id {
			_ = os.Remove(path)
		}
	}
}

func jsSourceScript(id string) (string, bool) {
	jsSourceMu.Lock()
	root := jsSourceRoot
	jsSourceMu.Unlock()
	if root == "" || !jsSafeID.MatchString(id) {
		return "", false
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		return "", false
	}
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(strings.ToLower(entry.Name()), ".js") {
			continue
		}
		raw, err := os.ReadFile(filepath.Join(root, entry.Name()))
		if err != nil {
			continue
		}
		script := normalizeJsScript(raw)
		if meta, ok := parseJsSourceMeta(script, entry.Name()); ok && meta.ID == id {
			return script, true
		}
	}
	return "", false
}

func readJsActiveID() string {
	jsSourceMu.Lock()
	defer jsSourceMu.Unlock()
	if jsSourceRoot == "" {
		return ""
	}
	raw, err := os.ReadFile(filepath.Join(jsSourceRoot, "active.txt"))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(raw))
}

func writeJsActiveID(id string) {
	jsSourceMu.Lock()
	defer jsSourceMu.Unlock()
	if jsSourceRoot == "" {
		return
	}
	_ = os.WriteFile(filepath.Join(jsSourceRoot, "active.txt"), []byte(id), 0o644)
}

// jsPresetFiles 是随包发布的内置脚本。官方源的签名参数在构建时经
// `-ldflags -X` 写进 exe，用户开箱即可播，不需要额外配置。
var jsPresetFiles = []string{"hongguo.js"}

// ensureJsPreset 把缺失的内置源补进沙箱目录，省得用户开箱没东西可播。
// 已存在的（用户可能自己更新过）不动。
func ensureJsPreset(site func(string) ([]byte, error)) {
	if jsSourceRoot == "" {
		return
	}
	installed := map[string]bool{}
	for _, item := range scanJsSources() {
		installed[item.ID] = true
	}
	added := ""
	for _, name := range jsPresetFiles {
		raw, err := site("sources/" + name)
		if err != nil {
			continue
		}
		script := normalizeJsScript(raw)
		meta, ok := parseJsSourceMeta(script, name)
		if !ok || installed[meta.ID] {
			continue
		}
		if _, err := writeJsSource(name, script); err != nil {
			continue
		}
		installed[meta.ID] = true
		if added == "" {
			added = meta.ID
		}
	}
	if readJsActiveID() == "" {
		// 有官方源就默认用它（功能完整，补签名即可播）；只有网页源时才退到它。
		switch {
		case installed["hongguo"]:
			writeJsActiveID("hongguo")
		case added != "":
			writeJsActiveID(added)
		}
	}
}

// handleJsSources 管理脚本源：列表 / 导入（文本或网址）/ 启用 / 删除。
func handleJsSources(writer http.ResponseWriter, request *http.Request) {
	switch request.Method {
	case http.MethodGet:
		items := scanJsSources()
		active := readJsActiveID()
		if active == "" && len(items) > 0 {
			active = items[0].ID
		}
		for index := range items {
			items[index].Active = items[index].ID == active
		}
		writeJSON(writer, map[string]any{"items": items, "active": active})
	case http.MethodPost:
		body, err := io.ReadAll(io.LimitReader(request.Body, jsSourceMaxBytes+4096))
		if err != nil {
			http.Error(writer, "读取请求失败", http.StatusBadRequest)
			return
		}
		var payload struct {
			FileName string `json:"fileName"`
			Script   string `json:"script"`
			URL      string `json:"url"`
			Preset   string `json:"preset"`
		}
		if json.Unmarshal(body, &payload) != nil {
			http.Error(writer, "请求不是合法 JSON", http.StatusBadRequest)
			return
		}
		if payload.Preset != "" {
			raw, err := webAssets.ReadFile("web/sources/" + payload.Preset + ".js")
			if err != nil {
				http.Error(writer, "内置源不存在", http.StatusNotFound)
				return
			}
			script := normalizeJsScript(raw)
			meta, err := writeJsSource(payload.Preset+".js", script)
			if err != nil {
				http.Error(writer, err.Error(), http.StatusBadRequest)
				return
			}
			if readJsActiveID() == "" {
				writeJsActiveID(meta.ID)
			}
			writeJSON(writer, map[string]any{"ok": true, "meta": meta})
			return
		}
		script := payload.Script
		fileName := strings.TrimSpace(payload.FileName)
		if strings.TrimSpace(payload.URL) != "" {
			fetched, name, err := downloadJsScript(payload.URL)
			if err != nil {
				http.Error(writer, err.Error(), http.StatusBadGateway)
				return
			}
			script = fetched
			fileName = name
		}
		if strings.TrimSpace(script) == "" {
			http.Error(writer, "脚本内容为空", http.StatusBadRequest)
			return
		}
		if len(script) > jsSourceMaxBytes {
			http.Error(writer, "脚本超过 4MB", http.StatusRequestEntityTooLarge)
			return
		}
		if fileName == "" {
			fileName = "custom_source.js"
		}
		if !strings.HasSuffix(strings.ToLower(fileName), ".js") {
			fileName += ".js"
		}
		meta, err := writeJsSource(fileName, normalizeJsScript([]byte(script)))
		if err != nil {
			http.Error(writer, err.Error(), http.StatusBadRequest)
			return
		}
		if readJsActiveID() == "" {
			writeJsActiveID(meta.ID)
		}
		writeJSON(writer, map[string]any{"ok": true, "meta": meta})
	case http.MethodDelete:
		id := strings.TrimSpace(request.URL.Query().Get("id"))
		if !jsSafeID.MatchString(id) {
			http.Error(writer, "缺少脚本 id", http.StatusBadRequest)
			return
		}
		removeJsSourceFiles(id, "")
		if readJsActiveID() == id {
			items := scanJsSources()
			next := ""
			if len(items) > 0 {
				next = items[0].ID
			}
			writeJsActiveID(next)
		}
		writeJSON(writer, map[string]any{"ok": true})
	default:
		http.Error(writer, "不支持的方法", http.StatusMethodNotAllowed)
	}
}

// ---------------------------------------------------------------- 签名参数

const (
	jsSigningIDToken       = "__THL_HONGGUO_SIGNING_ID_BASE64__"
	jsSigningMaterialToken = "__THL_HONGGUO_SIGNING_MATERIAL_BASE64__"
)

type jsSigningProfile struct {
	ID       string `json:"id"`
	Material string `json:"material"`
}

// loadJsSigning 读签名参数：优先构建时写进 exe 的那份（本地服务版不落盘、
// 不暴露），其次是环境变量 HONGGUO_SIGNING_CONFIG（开发 / 批量部署用），
// 最后才回退到 js_sources/signing.json（旧版兼容，发布包里不再放这个文件）。
func loadJsSigning() (jsSigningProfile, bool) {
	if builtInSigningID != "" && builtInSigningMaterial != "" {
		return jsSigningProfile{ID: builtInSigningID, Material: builtInSigningMaterial}, true
	}
	if raw := strings.TrimSpace(os.Getenv("HONGGUO_SIGNING_CONFIG")); raw != "" {
		if profile, ok := parseSigningJSON([]byte(raw)); ok {
			return profile, true
		}
	}
	jsSourceMu.Lock()
	root := jsSourceRoot
	jsSourceMu.Unlock()
	if root == "" {
		return jsSigningProfile{}, false
	}
	raw, err := os.ReadFile(filepath.Join(root, "signing.json"))
	if err != nil {
		return jsSigningProfile{}, false
	}
	return parseSigningJSON(raw)
}

func parseSigningJSON(raw []byte) (jsSigningProfile, bool) {
	var profile jsSigningProfile
	if json.Unmarshal(raw, &profile) != nil {
		return jsSigningProfile{}, false
	}
	id, err := base64.StdEncoding.DecodeString(profile.ID)
	if err != nil || len(id) != 9 {
		return jsSigningProfile{}, false
	}
	material, err := base64.StdEncoding.DecodeString(profile.Material)
	if err != nil || len(material) != 32 {
		return jsSigningProfile{}, false
	}
	return profile, true
}

func saveJsSigning(profile *jsSigningProfile) error {
	jsSourceMu.Lock()
	root := jsSourceRoot
	jsSourceMu.Unlock()
	if root == "" {
		return errors.New("JS 沙箱目录尚未初始化")
	}
	path := filepath.Join(root, "signing.json")
	if profile == nil {
		_ = os.Remove(path)
		return nil
	}
	body, err := json.Marshal(profile)
	if err != nil {
		return err
	}
	if _, ok := parseSigningJSON(body); !ok {
		return errors.New("参数无效：id 需为 9 字节、material 需为 32 字节的 base64")
	}
	return os.WriteFile(path, body, 0o600)
}

// applyJsSigning 把脚本里的占位符换成真参数；没配置就原样返回。
func applyJsSigning(script string) string {
	profile, ok := loadJsSigning()
	if !ok {
		return script
	}
	script = strings.ReplaceAll(script, jsSigningIDToken, profile.ID)
	return strings.ReplaceAll(script, jsSigningMaterialToken, profile.Material)
}

func handleJsSigning(writer http.ResponseWriter, request *http.Request) {
	switch request.Method {
	case http.MethodGet:
		_, ok := loadJsSigning()
		writeJSON(writer, map[string]any{
			"configured": ok,
			"embedded":   builtInSigningID != "" && builtInSigningMaterial != "",
		})
	case http.MethodPost:
		var payload jsSigningProfile
		if json.NewDecoder(io.LimitReader(request.Body, 8192)).Decode(&payload) != nil {
			http.Error(writer, "请求不是合法 JSON", http.StatusBadRequest)
			return
		}
		if strings.TrimSpace(payload.ID) == "" && strings.TrimSpace(payload.Material) == "" {
			if err := saveJsSigning(nil); err != nil {
				http.Error(writer, err.Error(), http.StatusBadRequest)
				return
			}
			writeJSON(writer, map[string]any{"ok": true, "configured": false})
			return
		}
		if err := saveJsSigning(&payload); err != nil {
			http.Error(writer, err.Error(), http.StatusBadRequest)
			return
		}
		writeJSON(writer, map[string]any{"ok": true, "configured": true})
	default:
		http.Error(writer, "不支持的方法", http.StatusMethodNotAllowed)
	}
}

// handleJsSourceScript 把脚本正文交给浏览器 Worker。
func handleJsSourceScript(writer http.ResponseWriter, request *http.Request) {
	id := strings.TrimSpace(request.URL.Query().Get("id"))
	script, ok := jsSourceScript(id)
	if !ok {
		http.Error(writer, "脚本不存在", http.StatusNotFound)
		return
	}
	writer.Header().Set("Content-Type", "text/javascript; charset=utf-8")
	writer.Header().Set("Cache-Control", "no-store")
	_, _ = io.WriteString(writer, applyJsSigning(script))
}

func handleJsActive(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		http.Error(writer, "只接受 POST 请求", http.StatusMethodNotAllowed)
		return
	}
	var payload struct {
		ID string `json:"id"`
	}
	if json.NewDecoder(io.LimitReader(request.Body, 4096)).Decode(&payload) != nil {
		http.Error(writer, "请求不是合法 JSON", http.StatusBadRequest)
		return
	}
	if _, ok := jsSourceScript(payload.ID); !ok {
		http.Error(writer, "脚本不存在", http.StatusNotFound)
		return
	}
	writeJsActiveID(payload.ID)
	writeJSON(writer, map[string]any{"ok": true, "active": payload.ID})
}

func downloadJsScript(address string) (string, string, error) {
	parsed, err := url.Parse(strings.TrimSpace(address))
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" {
		return "", "", errors.New("只支持 http / https 直链")
	}
	client := &http.Client{Timeout: 20 * time.Second}
	response, err := client.Get(parsed.String())
	if err != nil {
		return "", "", fmt.Errorf("网络拉取失败：%v", err)
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return "", "", fmt.Errorf("下载失败（HTTP %d）", response.StatusCode)
	}
	raw, err := io.ReadAll(io.LimitReader(response.Body, jsSourceMaxBytes+1))
	if err != nil || len(raw) > jsSourceMaxBytes {
		return "", "", errors.New("脚本超过 4MB 或读取失败")
	}
	name := filepath.Base(parsed.Path)
	if name == "" || name == "." || name == "/" {
		name = "remote_source.js"
	}
	if !strings.HasSuffix(strings.ToLower(name), ".js") {
		name += ".js"
	}
	return normalizeJsScript(raw), name, nil
}

// ---------------------------------------------------------------- 代发请求

var jsFetchClient = &http.Client{
	Timeout: 40 * time.Second,
	Transport: &http.Transport{
		Proxy:                 http.ProxyFromEnvironment,
		MaxIdleConnsPerHost:   8,
		IdleConnTimeout:       60 * time.Second,
		TLSHandshakeTimeout:   15 * time.Second,
		ResponseHeaderTimeout: 30 * time.Second,
	},
}

var jsFetchBlocked = regexp.MustCompile(`^(localhost|127\.|10\.|192\.168\.|169\.254\.|::1|\[::1\])`)

func isPrivateHost(host string) bool {
	if jsFetchBlocked.MatchString(host) {
		return true
	}
	if ip := net.ParseIP(host); ip != nil {
		return ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast()
	}
	if strings.HasPrefix(host, "172.") {
		parts := strings.Split(host, ".")
		if len(parts) > 1 {
			if value, err := strconv.Atoi(parts[1]); err == nil && value >= 16 && value <= 31 {
				return true
			}
		}
	}
	return false
}

// handleJsFetch 代理脚本里的 fetch：浏览器直连会被 CORS 拦住，且需要带
// 站源自己的 UA / Referer。请求体与响应体都按原样转发，二进制用 base64。
func handleJsFetch(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		http.Error(writer, "只接受 POST 请求", http.StatusMethodNotAllowed)
		return
	}
	var payload struct {
		URL       string            `json:"url"`
		Method    string            `json:"method"`
		Headers   map[string]string `json:"headers"`
		Body      string            `json:"body"`
		TimeoutMS int               `json:"timeoutMs"`
	}
	decoder := json.NewDecoder(io.LimitReader(request.Body, jsFetchMaxBytes))
	if decoder.Decode(&payload) != nil {
		http.Error(writer, "请求不是合法 JSON", http.StatusBadRequest)
		return
	}
	parsed, err := url.Parse(strings.TrimSpace(payload.URL))
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" {
		writeJSON(writer, map[string]any{"status": 0, "error": "BAD_URL", "body": ""})
		return
	}
	if isPrivateHost(parsed.Hostname()) {
		writeJSON(writer, map[string]any{"status": 0, "error": "BLOCKED_HOST", "body": ""})
		return
	}
	method := strings.ToUpper(strings.TrimSpace(payload.Method))
	if method == "" {
		method = http.MethodGet
	}
	timeout := time.Duration(payload.TimeoutMS) * time.Millisecond
	if timeout <= 0 || timeout > 30*time.Second {
		timeout = 20 * time.Second
	}
	ctx := request.Context()
	outgoing, err := http.NewRequestWithContext(ctx, method, parsed.String(), strings.NewReader(payload.Body))
	if err != nil {
		writeJSON(writer, map[string]any{"status": 0, "error": "BAD_REQUEST", "body": ""})
		return
	}
	for key, value := range payload.Headers {
		outgoing.Header.Set(key, value)
	}
	if outgoing.Header.Get("User-Agent") == "" {
		outgoing.Header.Set("User-Agent", "Mozilla/5.0 (compatible; guoapp js sandbox)")
	}
	client := *jsFetchClient
	client.Timeout = timeout
	response, err := client.Do(outgoing)
	if err != nil {
		writeJSON(writer, map[string]any{
			"status":      0,
			"error":       "NETWORK",
			"errorDetail": err.Error(),
			"body":        "",
		})
		return
	}
	defer response.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(response.Body, jsFetchMaxBytes))
	if err != nil {
		writeJSON(writer, map[string]any{"status": 0, "error": "READ", "body": ""})
		return
	}
	headers := map[string]string{}
	for key := range response.Header {
		headers[key] = response.Header.Get(key)
	}
	writeJSON(writer, map[string]any{
		"status":  response.StatusCode,
		"headers": headers,
		"body":    string(raw),
	})
}

// handleJsStream 代理播放流。浏览器不能给 <video> 加请求头，站源直链又常
// 要求特定 UA / Referer，所以由服务端带上头去取，再把字节原样转回来；
// m3u8 里的分片地址一并改写成本代理，否则分片请求会丢头。
func handleJsStream(writer http.ResponseWriter, request *http.Request) {
	target := strings.TrimSpace(request.URL.Query().Get("u"))
	parsed, err := url.Parse(target)
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" {
		http.Error(writer, "播放地址无效", http.StatusBadRequest)
		return
	}
	if isPrivateHost(parsed.Hostname()) {
		http.Error(writer, "播放地址不可访问", http.StatusForbidden)
		return
	}
	outgoing, err := http.NewRequestWithContext(request.Context(), http.MethodGet, parsed.String(), nil)
	if err != nil {
		http.Error(writer, "播放地址无效", http.StatusBadRequest)
		return
	}
	for key, values := range request.Header {
		lower := strings.ToLower(key)
		if lower == "range" || lower == "if-range" || lower == "accept" {
			for _, value := range values {
				outgoing.Header.Add(key, value)
			}
		}
	}
	if agent := strings.TrimSpace(request.URL.Query().Get("ua")); agent != "" {
		outgoing.Header.Set("User-Agent", agent)
	}
	if referer := strings.TrimSpace(request.URL.Query().Get("r")); referer != "" {
		outgoing.Header.Set("Referer", referer)
	}
	response, err := jsFetchClient.Do(outgoing)
	if err != nil {
		http.Error(writer, "取流失败", http.StatusBadGateway)
		return
	}
	defer response.Body.Close()

	contentType := response.Header.Get("Content-Type")
	isPlaylist := strings.Contains(contentType, "mpegurl") || strings.HasSuffix(strings.ToLower(parsed.Path), ".m3u8")
	if isPlaylist && response.StatusCode == http.StatusOK {
		raw, err := io.ReadAll(io.LimitReader(response.Body, 4<<20))
		if err != nil {
			http.Error(writer, "播放列表读取失败", http.StatusBadGateway)
			return
		}
		rewritten := rewritePlaylist(raw, parsed, request)
		writer.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
		writer.Header().Set("Cache-Control", "no-store")
		_, _ = writer.Write(rewritten)
		return
	}

	for _, header := range []string{"Content-Type", "Content-Length", "Content-Range", "Accept-Ranges", "Last-Modified", "ETag"} {
		if value := response.Header.Get(header); value != "" {
			writer.Header().Set(header, value)
		}
	}
	writer.WriteHeader(response.StatusCode)
	_, _ = io.Copy(writer, response.Body)
}

// rewritePlaylist 把分片 / 密钥地址改成经本代理的相对地址，并带上同样的
// UA / Referer，保证分片请求与清单请求的身份一致。
func rewritePlaylist(raw []byte, base *url.URL, request *http.Request) []byte {
	var builder bytes.Buffer
	scanner := bufio.NewScanner(bytes.NewReader(raw))
	scanner.Buffer(make([]byte, 0, 64*1024), 4<<20)
	for scanner.Scan() {
		line := strings.TrimRight(scanner.Text(), "\r")
		trimmed := strings.TrimSpace(line)
		switch {
		case trimmed == "" || strings.HasPrefix(trimmed, "#"):
			if strings.HasPrefix(trimmed, "#EXT-X-KEY:") || strings.HasPrefix(trimmed, "#EXT-X-MAP:") {
				builder.WriteString(rewritePlaylistTag(trimmed, base, request))
				builder.WriteString("\n")
				continue
			}
			builder.WriteString(line)
			builder.WriteString("\n")
		default:
			resolved := resolvePlaylistURL(base, trimmed)
			builder.WriteString(proxyStreamURL(resolved, request))
			builder.WriteString("\n")
		}
	}
	return builder.Bytes()
}

func rewritePlaylistTag(tag string, base *url.URL, request *http.Request) string {
	quoted := regexp.MustCompile(`URI="([^"]+)"`)
	return quoted.ReplaceAllStringFunc(tag, func(match string) string {
		value := strings.TrimSuffix(strings.TrimPrefix(match, `URI="`), `"`)
		resolved := resolvePlaylistURL(base, value)
		return `URI="` + proxyStreamURL(resolved, request) + `"`
	})
}

func resolvePlaylistURL(base *url.URL, value string) string {
	parsed, err := url.Parse(value)
	if err != nil {
		return value
	}
	return base.ResolveReference(parsed).String()
}

func proxyStreamURL(target string, request *http.Request) string {
	query := url.Values{}
	query.Set("u", target)
	if agent := strings.TrimSpace(request.URL.Query().Get("ua")); agent != "" {
		query.Set("ua", agent)
	}
	if referer := strings.TrimSpace(request.URL.Query().Get("r")); referer != "" {
		query.Set("r", referer)
	}
	return "/api/js/stream?" + query.Encode()
}

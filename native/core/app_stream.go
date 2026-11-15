package core

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"path"
	"regexp"
	"strings"
	"sync"
	"time"
)

type nativeStreamAsset struct {
	kind        string
	address     string
	data        []byte
	contentType string
	total       int64
	etag        string
	modified    string
}

type nativeStreamSession struct {
	credentials  *providerMediaCredentials
	mu           sync.Mutex
	assets       map[string]nativeStreamAsset
	referer      string
	key          []byte
	ctx          context.Context
	cancel       context.CancelFunc
	lastUsed     time.Time
	diagnosticID string
	adBlock      bool
}

type nativeStreamServer struct {
	mu         sync.Mutex
	downloader *Downloader
	address    string
	sessions   map[string]*nativeStreamSession
	server     *http.Server

	// 投屏用：同一个 handler 再挂一份到 0.0.0.0，让局域网里的电视 / 投影仪
	// 按本机内网地址拉流。只在用户真的投屏时打开，停止投屏就关掉。
	castServer   *http.Server
	castListener net.Listener
	castBase     string

	// 在线听书音频的本地明文代理条目。与短剧播放会话分开管理：听书切章
	// 频繁、单章常听十几分钟，不能受会话数上限与 10 分钟闲置回收影响。
	audiobooks map[string]*audiobookStreamEntry
}

// audiobookStreamEntry 是一章在线音频的上游地址与请求头。
type audiobookStreamEntry struct {
	address string
	headers map[string]string
	used    time.Time
}

func (stream *nativeStreamServer) nativeRequest(request *http.Request) (*http.Response, error) {
	client := *stream.downloader.client
	client.Timeout = 0
	info, _ := request.Context().Value(nativeStreamDiagnosticKey{}).(nativeStreamDiagnostic)
	response, err := stream.downloader.doMediaRequestWithClient(request, &client)
	if err != nil {
		stream.nativeLogError(info, "upstream_error", request.URL.String(), err, "")
		return response, err
	}
	address := request.URL.String()
	if response.Request != nil && response.Request.URL != nil {
		address = response.Request.URL.String()
	}
	if response.StatusCode != http.StatusOK && response.StatusCode != http.StatusPartialContent {
		stream.nativeLog(info, "upstream_status", address, "", response.StatusCode, response.Header.Get("Content-Type"))
	}
	response.Body = &nativeDiagnosticBody{ReadCloser: response.Body, stream: stream, info: info, address: address}
	return response, nil
}

var nativePlaylistURI = regexp.MustCompile(`URI="([^"]+)"`)

func newNativeStreamServer(d *Downloader) (*nativeStreamServer, error) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return nil, errors.New("无法初始化本机播放器")
	}
	stream := &nativeStreamServer{
		downloader: d,
		address:    "http://" + listener.Addr().String(),
		sessions:   map[string]*nativeStreamSession{},
		audiobooks: map[string]*audiobookStreamEntry{},
	}
	// 听书音频走独立前缀：它只需要带正确扩展名的本地 URL 与 Go 侧统一
	// 注入的 Referer / User-Agent，不需要播放列表重写，也不占短剧会话表。
	handler := http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if strings.HasPrefix(request.URL.Path, "/audiobook/") {
			stream.nativeServeAudiobook(writer, request)
			return
		}
		stream.nativeServe(writer, request)
	})
	server := &http.Server{Handler: handler, ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 16384}
	stream.server = server
	go func() { _ = server.Serve(listener) }()
	return stream, nil
}

func (stream *nativeStreamServer) nativeOpen(media providerMedia, adBlock bool) (string, string) {
	tokenBytes := make([]byte, 24)
	if _, err := rand.Read(tokenBytes); err != nil {
		panic(err)
	}
	token := hex.EncodeToString(tokenBytes)
	ctx, cancel := context.WithCancel(providerMediaContext(context.Background(), media.Credentials))
	session := &nativeStreamSession{assets: map[string]nativeStreamAsset{}, referer: media.Referer, key: media.HLSKey, ctx: ctx, cancel: cancel, lastUsed: time.Now(), credentials: media.Credentials, diagnosticID: nativeStreamID(token), adBlock: adBlock}
	stream.mu.Lock()
	for id, old := range stream.sessions {
		if time.Since(old.lastUsed) > 10*time.Minute {
			stream.nativeCancel(old, "idle_expired")
			delete(stream.sessions, id)
		}
	}
	if len(stream.sessions) >= 8 {
		oldest := ""
		for id, old := range stream.sessions {
			if oldest == "" || old.lastUsed.Before(stream.sessions[oldest].lastUsed) {
				oldest = id
			}
		}
		stream.nativeCancel(stream.sessions[oldest], "capacity_eviction")
		delete(stream.sessions, oldest)
	}
	stream.sessions[token] = session
	stream.mu.Unlock()
	entry := nativeStreamAsset{kind: "media", address: media.URL, contentType: "video/mp4"}
	parsedURL, parseErr := url.Parse(media.URL)
	isHLS := media.Playlist != "" || (parseErr == nil && strings.HasSuffix(strings.ToLower(parsedURL.Path), ".m3u8"))
	if isHLS {
		entry.contentType = "application/vnd.apple.mpegurl"
	}
	if media.Playlist != "" {
		entry.data = []byte(media.Playlist)
		entry.contentType = "application/vnd.apple.mpegurl"
	}
	if isHLS || strings.Contains(entry.contentType, "mpegurl") {
		entry.kind = "entry_playlist"
	}
	return stream.nativeAsset(token, session, entry), token
}

func (stream *nativeStreamServer) nativeCancel(session *nativeStreamSession, reason string) {
	if reason != "release" {
		stream.nativeLog(nativeStreamDiagnostic{session: session.diagnosticID}, "session_cancel", "", "reason="+reason, 0, "")
	}
	session.cancel()
}

func (stream *nativeStreamServer) nativeRelease(token string) {
	stream.mu.Lock()
	if session := stream.sessions[token]; session != nil {
		stream.nativeCancel(session, "release")
		delete(stream.sessions, token)
	}
	stream.mu.Unlock()
}

func (stream *nativeStreamServer) nativeAsset(token string, session *nativeStreamSession, asset nativeStreamAsset) string {
	return stream.nativeAssetAt(stream.address, token, session, asset)
}

// nativeAssetAt 用调用方给的基址生成资源地址。本机播放走 127.0.0.1，
// 投屏时必须换成「手机内网 IP + 投屏端口」，否则电视拿到的是它自己的
// localhost；同一个会话因此在两个监听上共用资源表，只有前缀不同。
func (stream *nativeStreamServer) nativeAssetAt(base, token string, session *nativeStreamSession, asset nativeStreamAsset) string {
	digest := sha256.Sum256([]byte(asset.address + "\x00" + asset.contentType))
	extension := ".ts"
	if parsed, err := url.Parse(asset.address); err == nil {
		switch candidate := strings.ToLower(path.Ext(parsed.Path)); candidate {
		case ".m3u8", ".ts", ".m4s", ".mp4", ".aac", ".m4a", ".mp3", ".vtt", ".webvtt", ".key":
			extension = candidate
		}
	}
	switch asset.contentType {
	case "application/vnd.apple.mpegurl":
		extension = ".m3u8"
	case "application/octet-stream":
		extension = ".key"
	case "video/mp4":
		extension = ".mp4"
	}
	id := hex.EncodeToString(digest[:12]) + extension
	session.mu.Lock()
	if previous, found := session.assets[id]; !found || len(previous.data) == 0 || len(asset.data) > 0 {
		session.assets[id] = asset
	}
	session.mu.Unlock()
	return base + "/" + token + "/" + id
}

func (stream *nativeStreamServer) nativeRewrite(token string, session *nativeStreamSession, body, base string) (string, error) {
	return stream.nativeRewriteAt(stream.address, token, session, body, base)
}

// nativeRewriteAt 的 publicBase 决定播放列表里写回的绝对地址前缀：本机播放是
// 127.0.0.1，投屏请求进来时用请求的 Host（内网 IP），两种客户端各拿各的。
func (stream *nativeStreamServer) nativeRewriteAt(publicBase, token string, session *nativeStreamSession, body, base string) (string, error) {
	var output []string
	nextPlaylist := false
	for _, line := range strings.Split(strings.ReplaceAll(body, "\r\n", "\n"), "\n") {
		text := strings.TrimSpace(line)
		rewrite := func(reference string, key bool, contentType string) string {
			if strings.HasPrefix(reference, "data:") {
				return reference
			}
			parsed, err := url.Parse(base)
			if err != nil {
				return ""
			}
			relative, err := url.Parse(reference)
			if err != nil {
				return ""
			}
			address := parsed.ResolveReference(relative).String()
			if !isProviderHTTPMediaURL(address) {
				return ""
			}
			kind := "segment"
			switch contentType {
			case "application/vnd.apple.mpegurl":
				kind = "child_playlist"
			case "application/octet-stream":
				kind = "key"
			case "video/mp4":
				kind = "map"
			}
			asset := nativeStreamAsset{kind: kind, address: address, contentType: contentType}
			if key && len(session.key) == 16 {
				asset.data = append([]byte{}, session.key...)
				asset.contentType = "application/octet-stream"
			}
			return stream.nativeAssetAt(publicBase, token, session, asset)
		}
		if text != "" && !strings.HasPrefix(text, "#") {
			contentType := ""
			if nextPlaylist {
				contentType = "application/vnd.apple.mpegurl"
			}
			line = rewrite(text, false, contentType)
			nextPlaylist = false
			if line == "" {
				return "", errors.New("播放列表中的媒体地址无效")
			}
		} else if strings.Contains(text, "URI=") {
			invalid := false
			line = nativePlaylistURI.ReplaceAllStringFunc(line, func(match string) string {
				reference := nativePlaylistURI.FindStringSubmatch(match)[1]
				key := strings.HasPrefix(text, "#EXT-X-KEY:") || strings.HasPrefix(text, "#EXT-X-SESSION-KEY:")
				contentType := ""
				switch {
				case key:
					contentType = "application/octet-stream"
				case strings.HasPrefix(text, "#EXT-X-MAP:"):
					contentType = "video/mp4"
				case strings.HasPrefix(text, "#EXT-X-MEDIA:"), strings.HasPrefix(text, "#EXT-X-I-FRAME-STREAM-INF:"), strings.HasPrefix(text, "#EXT-X-RENDITION-REPORT:"):
					contentType = "application/vnd.apple.mpegurl"
				}
				updated := rewrite(reference, key, contentType)
				if updated == "" {
					invalid = true
				}
				return "URI=\"" + updated + "\""
			})
			if invalid {
				return "", errors.New("播放列表中的附属地址无效")
			}
		}
		if strings.HasPrefix(text, "#EXT-X-STREAM-INF:") {
			nextPlaylist = true
		}
		output = append(output, line)
	}
	return strings.Join(output, "\n"), nil
}

func (stream *nativeStreamServer) nativeServe(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet && request.Method != http.MethodHead {
		writer.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	parts := strings.Split(strings.Trim(request.URL.Path, "/"), "/")
	if len(parts) != 2 {
		http.NotFound(writer, request)
		return
	}
	stream.mu.Lock()
	session := stream.sessions[parts[0]]
	if session != nil {
		session.lastUsed = time.Now()
	}
	stream.mu.Unlock()
	if session == nil {
		http.Error(writer, "播放已结束", http.StatusGone)
		return
	}
	session.mu.Lock()
	asset, found := session.assets[parts[1]]
	session.mu.Unlock()
	info := nativeStreamDiagnostic{session: session.diagnosticID, asset: asset.kind}
	if !found {
		stream.nativeLog(info, "asset_missing", "", "", 0, "")
		http.NotFound(writer, request)
		return
	}
	ctx, cancel := context.WithCancel(providerMediaContext(request.Context(), session.credentials))
	defer cancel()
	ctx = context.WithValue(ctx, nativeStreamDiagnosticKey{}, info)
	stop := context.AfterFunc(session.ctx, cancel)
	defer stop()
	writer.Header().Set("Cache-Control", "no-store")
	// 播放列表里写回的绝对地址跟着请求来源走：本机播放是 127.0.0.1，投屏时
	// 电视按内网地址请求，只有用请求 Host 才能让两边都拉到同一份资源。
	publicBase := stream.address
	if host := request.Host; host != "" {
		publicBase = "http://" + host
	}
	if len(asset.data) > 0 && asset.total > int64(len(asset.data)) {
		if stream.nativeServePrefix(ctx, writer, request, session, asset) {
			return
		}
		asset.data = nil
	}
	if len(asset.data) > 0 {
		if strings.Contains(asset.contentType, "mpegurl") {
			body, err := stream.nativeRewriteAt(publicBase, parts[0], session, nativeAdCleaned(session, string(asset.data), asset.address), asset.address)
			if err != nil {
				stream.nativeLog(info, "playlist_rewrite", asset.address, "kind="+nativePlaylistKind(string(asset.data))+" error="+nativeStreamError(err), 0, "")
				http.Error(writer, err.Error(), http.StatusBadGateway)
				return
			}
			writer.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
			if request.Method == http.MethodGet {
				_, _ = io.WriteString(writer, body)
			}
		} else {
			writer.Header().Set("Content-Type", asset.contentType)
			if asset.etag != "" {
				writer.Header().Set("ETag", asset.etag)
			}
			http.ServeContent(writer, request, parts[1], time.Time{}, bytes.NewReader(asset.data))
		}
		return
	}
	upstream, err := http.NewRequestWithContext(ctx, request.Method, asset.address, nil)
	if err != nil {
		http.Error(writer, "媒体地址无效", http.StatusBadGateway)
		return
	}
	upstream.Header.Set("User-Agent", userAgent)
	upstream.Header.Set("Referer", session.referer)
	for _, name := range []string{"Range", "If-Range"} {
		if value := request.Header.Get(name); value != "" {
			upstream.Header.Set(name, value)
		}
	}
	response, err := stream.nativeRequest(upstream)
	if err != nil {
		http.Error(writer, "读取媒体失败，请重试", http.StatusBadGateway)
		return
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK && response.StatusCode != http.StatusPartialContent {
		body, _ := io.ReadAll(io.LimitReader(response.Body, 64<<10))
		err := stream.downloader.catalogResponseError(upstream, response, body)
		http.Error(writer, err.Error(), response.StatusCode)
		return
	}
	contentType := strings.ToLower(response.Header.Get("Content-Type"))
	finalURL := upstream.URL
	if response.Request != nil && response.Request.URL != nil {
		finalURL = response.Request.URL
	}
	contentIsMP4 := strings.Contains(contentType, "video/mp4")
	playlist := strings.Contains(contentType, "mpegurl") ||
		(strings.HasSuffix(strings.ToLower(finalURL.Path), ".m3u8") && !contentIsMP4)
	reader := bufio.NewReader(response.Body)
	if request.Method == http.MethodGet {
		peek, _ := reader.Peek(512)
		bodyIsPlaylist := strings.HasPrefix(strings.TrimSpace(strings.TrimPrefix(string(peek), "\ufeff")), "#EXTM3U")
		if bodyIsPlaylist {
			playlist = true
		} else if contentIsMP4 {
			playlist = false
		}
	}
	if playlist && request.Method == http.MethodHead {
		writer.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
		writer.WriteHeader(http.StatusOK)
		return
	}
	if playlist && request.Method == http.MethodGet {
		body, err := io.ReadAll(io.LimitReader(reader, 4<<20+1))
		if err != nil || len(body) > 4<<20 {
			stream.nativeLogError(info, "playlist_read_failed", finalURL.String(), err, contentType)
			http.Error(writer, "播放列表过大或读取失败", http.StatusBadGateway)
			return
		}
		text := nativeAdCleaned(session, strings.TrimSpace(strings.TrimPrefix(string(body), "\ufeff")), finalURL.String())
		if !strings.HasPrefix(text, "#EXTM3U") {
			stream.nativeLog(info, "playlist_invalid", finalURL.String(), "", 0, contentType)
			http.Error(writer, "播放列表无效", http.StatusBadGateway)
			return
		}
		rewritten, err := stream.nativeRewriteAt(publicBase, parts[0], session, text, finalURL.String())
		if err != nil {
			stream.nativeLog(info, "playlist_rewrite", finalURL.String(), "kind="+nativePlaylistKind(text)+" error="+nativeStreamError(err), 0, contentType)
			http.Error(writer, err.Error(), http.StatusBadGateway)
			return
		}
		writer.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
		_, _ = io.WriteString(writer, rewritten)
		return
	}
	for _, name := range []string{"Content-Type", "Content-Length", "Content-Range", "Accept-Ranges", "ETag", "Last-Modified"} {
		if value := response.Header.Get(name); value != "" {
			writer.Header().Set(name, value)
		}
	}
	writer.WriteHeader(response.StatusCode)
	if request.Method == http.MethodGet {
		_, _ = io.Copy(writer, reader)
	}
}

// nativeOpenAudiobook 把一章在线音频登记成本地明文流，返回带 .m4a 扩展名的地址。
//
// 红果 / 番茄的音频地址常是不带扩展名的 CDN 路径，libmpv 在 Windows 上按
// 扩展名探测不到 mov 容器，CENC 的 decryption_key 就不会落到 mov demuxer，
// 结果是「时长和进度都有、音频 sample 仍是加密的」——完全静音。短剧之所以
// 正常，正是因为它播的是本机流服务器给出的带 .mp4 扩展名地址。这里让听书
// 走同一条链路，并把上游要求的 Referer / User-Agent 交给 Go 侧统一注入，
// 不再依赖播放器转发 httpHeaders（各平台实现不一致）。
func (stream *nativeStreamServer) nativeOpenAudiobook(plan map[string]any) string {
	address := strings.TrimSpace(mapString(plan, "url"))
	if address == "" {
		return ""
	}
	headers := map[string]string{}
	switch rows := plan["headers"].(type) {
	case map[string]string:
		for name, value := range rows {
			if strings.TrimSpace(value) != "" {
				headers[name] = value
			}
		}
	case map[string]any:
		for name, value := range rows {
			if text := strings.TrimSpace(fmt.Sprint(value)); text != "" {
				headers[name] = text
			}
		}
	}
	digest := sha256.Sum256([]byte(address + "\x00" + mapString(plan, "decryptionKey")))
	token := hex.EncodeToString(digest[:12])
	stream.mu.Lock()
	defer stream.mu.Unlock()
	for id, entry := range stream.audiobooks {
		if time.Since(entry.used) > 2*time.Hour {
			delete(stream.audiobooks, id)
		}
	}
	stream.audiobooks[token] = &audiobookStreamEntry{
		address: address, headers: headers, used: time.Now(),
	}
	return stream.address + "/audiobook/" + token + ".m4a"
}

// nativeServeAudiobook 只做明文转发：透传 Range 让播放器能拖动进度，并带
// 上上游校验需要的请求头。CENC 解密仍由播放器的 decryption_key 完成。
func (stream *nativeStreamServer) nativeServeAudiobook(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet && request.Method != http.MethodHead {
		writer.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	name := strings.TrimPrefix(request.URL.Path, "/audiobook/")
	token := strings.TrimSuffix(name, path.Ext(name))
	stream.mu.Lock()
	entry := stream.audiobooks[token]
	if entry != nil {
		entry.used = time.Now()
	}
	stream.mu.Unlock()
	if entry == nil {
		http.Error(writer, "播放已结束", http.StatusGone)
		return
	}
	upstream, err := http.NewRequestWithContext(request.Context(), request.Method, entry.address, nil)
	if err != nil {
		http.Error(writer, "音频地址无效", http.StatusBadGateway)
		return
	}
	upstream.Header.Set("User-Agent", userAgent)
	for name, value := range entry.headers {
		upstream.Header.Set(name, value)
	}
	for _, name := range []string{"Range", "If-Range"} {
		if value := request.Header.Get(name); value != "" {
			upstream.Header.Set(name, value)
		}
	}
	// 这里刻意不走 stream.nativeRequest：那条媒体请求管线会用
	// mediaRequestHeaders 把 User-Agent 强制改成通用浏览器 UA，红果 / 番茄
	// 听书 CDN 校验的却是 com.dragon.read，覆盖后拿到的就不是可播放音频。
	// 听书只需要原样转发，保留登记时自带的请求头即可。
	var response *http.Response
	if stream.downloader.client != nil {
		client := *stream.downloader.client
		client.Timeout = 0 // 一章可能十几分钟，不能套媒体请求的短超时
		response, err = client.Do(upstream)
	} else {
		response, err = http.DefaultClient.Do(upstream)
	}
	if err != nil {
		http.Error(writer, "读取音频失败，请重试", http.StatusBadGateway)
		return
	}
	defer response.Body.Close()
	for _, name := range []string{"Content-Type", "Content-Length", "Content-Range", "Accept-Ranges", "ETag", "Last-Modified"} {
		if value := response.Header.Get(name); value != "" {
			writer.Header().Set(name, value)
		}
	}
	writer.Header().Set("Cache-Control", "no-store")
	writer.WriteHeader(response.StatusCode)
	if request.Method == http.MethodGet {
		_, _ = io.Copy(writer, response.Body)
	}
}

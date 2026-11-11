package core

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/anacrolix/torrent/metainfo"
)

// 迅雷 SDK 之所以能「一秒列文件」，本质是按 infohash 直接从云端种子库取回
// .torrent，跳过本地 DHT 慢慢抓 info 字典。这里用公开的 torrent 缓存端点做
// 等价的一步：本地 magnet-meta 没命中时，花几秒按 infohash 把种子取回来，
// 校验通过就落盘，随后 addMagnetFast 用 InfoBytes 直接建任务，不必等最多
// 40 秒的元数据。
//
// 端点会失效，也可能对不存在的 hash 返回 200 + HTML 页面（实测 itorrents.org
// 就是这样），因此必须严格校验 bencode 与 infohash；所有失败都静默降级回
// 原来的 DHT 路径，绝不让这一步变成新的卡点。是否启用由资源设置里的
// magnetMetaFetch 决定，默认开启，用户可在设置里关掉。
const (
	magnetOnlineMetaTimeout = 5 * time.Second
	magnetOnlineMetaMaxBody = 2 << 20
	// itorrents.org 对没有浏览器 UA 的请求直接 403，必须带一个正常 UA。
	magnetOnlineMetaUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)

// 只保留实测确实返回 bencode 种子的一条：itorrents.org 对真实 infohash
// 约 4 秒返回种子；torrage.info / btcache.me / torrentbox.me 等老站实测
// 已是 HTML 404、TLS 失败或域名不通，列进来只会白等超时。
var magnetOnlineMetaURLs = []string{
	"https://itorrents.org/torrent/%s.torrent",
}

var magnetOnlineMetaHTTP = &http.Client{Timeout: magnetOnlineMetaTimeout}

var magnetOnlineMetaTransportOnce sync.Once

// configureMagnetOnlineMetaHTTP 复用核心已经配好的传输层：系统代理、打包 CA、
// 连接方式设置都在里面，否则在手动代理环境下这一步会变成必失败的请求。
// 只在引擎初始化时调用一次（用 Once 保护，避免重新 initialize 时与在途请求竞争），
// 之后只读。
func configureMagnetOnlineMetaHTTP(base *http.Transport) {
	magnetOnlineMetaTransportOnce.Do(func() {
		if base == nil {
			return
		}
		transport := base.Clone()
		transport.ResponseHeaderTimeout = magnetOnlineMetaTimeout
		transport.MaxIdleConnsPerHost = 4
		magnetOnlineMetaHTTP.Transport = transport
	})
}

// magnetParseOnlineMeta 只接受「能解析且 infohash 完全匹配」的种子。
// 端点返回 HTML / 空页 / 别人的种子时一律拒绝，避免把垃圾写进缓存。
func magnetParseOnlineMeta(body []byte, wantHash string) *metainfo.MetaInfo {
	if len(body) == 0 || len(body) > magnetOnlineMetaMaxBody || body[0] != 'd' {
		return nil
	}
	info, err := metainfo.Load(bytes.NewReader(body))
	if err != nil || info == nil || len(info.InfoBytes) == 0 {
		return nil
	}
	if info.HashInfoBytes().HexString() != strings.ToLower(strings.TrimSpace(wantHash)) {
		return nil
	}
	return info
}

// magnetFetchOnlineMeta 并行请求所有端点，取第一个合法的种子。ctx 到期或
// 全部失败返回 nil；调用方继续走 DHT。请求数很少（当前一条），不需要限流。
func magnetFetchOnlineMeta(ctx context.Context, hash string) *metainfo.MetaInfo {
	hash = strings.ToLower(strings.TrimSpace(hash))
	if !magnetHashValid(hash) || len(magnetOnlineMetaURLs) == 0 {
		return nil
	}
	requestCtx, cancel := context.WithTimeout(ctx, magnetOnlineMetaTimeout)
	defer cancel()
	results := make(chan *metainfo.MetaInfo, len(magnetOnlineMetaURLs))
	var wait sync.WaitGroup
	for _, pattern := range magnetOnlineMetaURLs {
		address := strings.ReplaceAll(pattern, "%s", hash)
		wait.Add(1)
		go func(url string) {
			defer wait.Done()
			request, err := http.NewRequestWithContext(requestCtx, http.MethodGet, url, nil)
			if err != nil {
				return
			}
			request.Header.Set("User-Agent", magnetOnlineMetaUA)
			request.Header.Set("Accept", "application/x-bittorrent, */*")
			response, err := magnetOnlineMetaHTTP.Do(request)
			if err != nil {
				return
			}
			defer response.Body.Close()
			if response.StatusCode < 200 || response.StatusCode >= 300 {
				return
			}
			body, err := io.ReadAll(io.LimitReader(response.Body, magnetOnlineMetaMaxBody+1))
			if err != nil {
				return
			}
			if info := magnetParseOnlineMeta(body, hash); info != nil {
				select {
				case results <- info:
				default:
				}
			}
		}(address)
	}
	go func() {
		wait.Wait()
		close(results)
	}()
	select {
	case info := <-results:
		return info
	case <-requestCtx.Done():
		return nil
	}
}

// magnetCacheOnlineMeta 只在本地没有缓存时尝试在线补齐，成功落盘返回 true。
// 失败不返回错误：这是加速路径，不是必需路径。
func magnetCacheOnlineMeta(ctx context.Context, hash, dataDir string) bool {
	if dataDir == "" || magnetLoadMeta(dataDir, hash) != nil {
		return false
	}
	info := magnetFetchOnlineMeta(ctx, hash)
	if info == nil {
		return false
	}
	magnetSaveMeta(dataDir, hash, *info)
	return magnetLoadMeta(dataDir, hash) != nil
}

package core

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// 听书榜单 / 搜索 / 目录 / 网页正文都在番茄的公开接口上。
// Flutter 端和本地服务端（网页）共用同一个动作：请求由 Go 核心代发，
// 这样系统代理、站点限流和请求超时都跟 guoappxp 现有设置保持一致。
// 为避免把它变成通用代理，只允许下面几个域名，且只支持 GET。
var audiobookFetchHosts = map[string]bool{
	"api.fanqiesdk.com":                   true,
	"fanqienovel.com":                     true,
	"api5-normal-sinfonlineb.fqnovel.com": true,
	"api5-normal-lq.fqnovel.com":          true,
	"api5-sinfonlineb.novelfm.com":        true,
	"novelfm.changdunovel.com":            true,
	// 番茄畅听官方书城（fanqie.apk 反编译所得）。书库/分类实时从这里取，
	// 见 server/audiobook_novelfm.go 与 lib/ui/audiobook/audiobook_fanqie.dart。
	"api.novelfm.com":                     true,
}

func audiobookFetchURL(raw string) (*url.URL, error) {
	parsed, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || parsed == nil {
		return nil, errors.New("听书地址无效")
	}
	if parsed.Scheme != "https" && parsed.Scheme != "http" {
		return nil, errors.New("听书地址无效")
	}
	host := strings.ToLower(parsed.Hostname())
	if !audiobookFetchHosts[host] {
		return nil, errors.New("不允许访问这个听书地址")
	}
	return parsed, nil
}

func (downloader *Downloader) fetchAudiobookRaw(ctx context.Context, rawURL, headerJSON string) (string, error) {
	parsed, err := audiobookFetchURL(rawURL)
	if err != nil {
		return "", err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, parsed.String(), nil)
	if err != nil {
		return "", err
	}
	request.Header.Set("User-Agent", "Mozilla/5.0")
	request.Header.Set("Accept", "application/json")
	request.Header.Set("Referer", "https://fanqienovel.com/")
	if strings.TrimSpace(headerJSON) != "" {
		var headers map[string]string
		if json.Unmarshal([]byte(headerJSON), &headers) != nil {
			return "", errors.New("听书请求头无效")
		}
		for key, value := range headers {
			// 只放行少量业务头，避免调用方覆盖核心统一设置的代理 / 身份头。
			switch strings.ToLower(key) {
			case "ismobile", "accept", "referer", "user-agent":
				request.Header.Set(key, value)
			}
		}
	}
	client := downloader.client
	if client == nil {
		client = &http.Client{Timeout: 20 * time.Second}
	}
	response, err := client.Do(request)
	if err != nil {
		return "", errors.New("无法连接听书源")
	}
	defer response.Body.Close()
	payload, err := io.ReadAll(io.LimitReader(response.Body, 8<<20))
	if err != nil {
		return "", errors.New("听书内容读取失败")
	}
	if response.StatusCode != http.StatusOK {
		return "", errors.New("听书源没有返回内容")
	}
	return string(payload), nil
}

package core

// 红果 App 请求客户端（听书专用裁剪版）。
//
// 移植自 guoappxp 的 provider_hongguo_app.go。原版客户端同时承载目录、详情、
// 搜索、联想、弹幕、标签等多条业务线，字段与方法量很大；guoappxpx 本体不内置
// 红果站源（站源以模块形式安装），听书只需要「签好名的 App 接口请求」这一项
// 能力，因此这里只保留设备注册 + 请求签名 + 重试/轮转，其余缓存表一概不带。

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

const hongguoAppBaseURL = "https://api5-normal-sinfonlineb.fqnovel.com"

const hongguoAppUserAgent = "com.phoenix.read/73532 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)"

// 书城 Tab 与 Cell 接口不需要设备签名，其余接口都需要。
const (
	hongguoBookmallTabPath        = "/reading/bookapi/bookmall/tab/v1/"
	hongguoBookmallCellChangePath = "/reading/bookapi/bookmall/cell/change/v1/"
)

type hongguoAppClient struct {
	mu                  sync.Mutex
	deviceMu            sync.Mutex
	registerPausedUntil time.Time
	registerPauseErr    error
	baseURL             string
	deviceID            string
	installID           string
	registered          bool
	helperDeviceID      string
	helperInstallID     string
	helperRegistered    bool
}

func (downloader *Downloader) hongguoClient() *hongguoAppClient {
	downloader.hongguoOnce.Do(func() {
		downloader.hongguo = &hongguoAppClient{
			baseURL:         hongguoAppBaseURL,
			deviceID:        newHongguoDeviceID(),
			installID:       newHongguoDeviceID(),
			helperDeviceID:  newHongguoDeviceID(),
			helperInstallID: newHongguoDeviceID(),
		}
	})
	return downloader.hongguo
}

func (client *hongguoAppClient) deviceLocked(helper bool) (string, string, bool) {
	if helper {
		return client.helperDeviceID, client.helperInstallID, client.helperRegistered
	}
	return client.deviceID, client.installID, client.registered
}

func (client *hongguoAppClient) device(helper bool) (string, string, bool) {
	client.mu.Lock()
	defer client.mu.Unlock()
	return client.deviceLocked(helper)
}

func hongguoAppQuery(deviceID, installID string) url.Values {
	return url.Values{
		"aid": {"8662"}, "app_name": {"novelread"}, "version_code": {"73532"}, "version_name": {"7.3.5.32"},
		"manifest_version_code": {"73532"}, "update_version_code": {"73532"}, "channel": {"update_64"},
		"device_platform": {"android"}, "os": {"android"}, "ssmix": {"a"}, "device_type": {"25053RT47C"},
		"device_brand": {"Redmi"}, "language": {"zh"}, "os_api": {"36"}, "os_version": {"16"},
		"resolution": {"1280*2772"}, "dpi": {"520"}, "ac": {"wifi"}, "device_id": {deviceID}, "iid": {installID},
	}
}

func (downloader *Downloader) hongguoAppRequest(ctx context.Context, method, path string, extra url.Values, payload any) (map[string]any, error) {
	client := downloader.hongguoClient()
	helper, _ := ctx.Value(hongguoHelperDeviceKey{}).(bool)
	signed := path != hongguoBookmallTabPath
	var registerErr error
	if signed {
		registerErr = downloader.ensureHongguoDevice(ctx, helper, "")
	}
	client.mu.Lock()
	base := client.baseURL
	deviceID, installID, _ := client.deviceLocked(helper)
	client.mu.Unlock()
	if helper {
		if deviceID == "" || !signed {
			return nil, errors.New("红果辅助设备不可用")
		}
		ctx = context.WithValue(ctx, requestLaneKey{}, "hongguo-helper")
	}
	query := hongguoAppQuery(deviceID, installID)
	for key, values := range extra {
		query[key] = append([]string(nil), values...)
	}
	var body []byte
	var err error
	if payload != nil {
		body, err = json.Marshal(payload)
		if err != nil {
			return nil, err
		}
	}
	attempts := downloader.cfg.Retries
	if attempts < 1 {
		attempts = 1
	}
	if attempts > 3 {
		attempts = 3
	}
	var lastErr error
	rotations := 0
	for attempt := 0; attempt < attempts; attempt++ {
		if attempt > 0 {
			select {
			case <-time.After(time.Duration(attempt) * time.Second):
			case <-ctx.Done():
				return nil, ctx.Err()
			}
		}
		request, err := http.NewRequestWithContext(ctx, method, strings.TrimRight(base, "/")+path, bytes.NewReader(body))
		if err != nil {
			return nil, err
		}
		request.Header.Set("User-Agent", hongguoAppUserAgent)
		request.Header.Set("Accept", "application/json")
		request.Header.Set("X-XS-From-Web", "0")
		request.Header.Set("Sdk-Version", "2")
		if payload != nil {
			request.Header.Set("Content-Type", "application/json; charset=utf-8")
		}
		response, err := downloader.doPreparedCatalogRequest(request, 20*time.Second, func(prepared *http.Request) {
			now := time.Now()
			query.Set("_rticket", strconv.FormatInt(now.UnixMilli(), 10))
			prepared.URL.RawQuery = query.Encode()
			if signed {
				signHongguoPlayerRequest(prepared, body, now)
			}
		})
		if err != nil {
			lastErr = err
			var backoff *RequestBackoff
			if errors.As(err, &backoff) || ctx.Err() != nil {
				return nil, err
			}
			continue
		}
		content, readErr := io.ReadAll(io.LimitReader(response.Body, providerMaxBodyBytes+1))
		response.Body.Close()
		if readErr != nil {
			lastErr = readErr
			continue
		}
		if response.StatusCode != http.StatusOK {
			lastErr = fmt.Errorf("红果 App 接口 HTTP %d", response.StatusCode)
			if response.StatusCode >= 400 && response.StatusCode < 500 {
				return nil, lastErr
			}
			continue
		}
		if len(content) == 0 {
			lastErr = errors.New("红果 App 接口未返回有效数据")
			if signed && rotations < hongguoDeviceRotations {
				if registerErr = downloader.ensureHongguoDevice(ctx, helper, deviceID); registerErr == nil {
					rotations++
					deviceID, installID, _ = client.device(helper)
					query.Set("device_id", deviceID)
					query.Set("iid", installID)
					attempt--
				}
			}
			if registerErr != nil {
				lastErr = fmt.Errorf("红果 App 接口未返回有效数据（设备注册失败：%v）", registerErr)
			}
			continue
		}
		if len(content) > providerMaxBodyBytes {
			return nil, errors.New("红果 App 接口未返回有效数据")
		}
		var result map[string]any
		decoder := json.NewDecoder(bytes.NewReader(content))
		decoder.UseNumber()
		if err := decoder.Decode(&result); err != nil || result == nil {
			return nil, errors.New("红果 App 接口返回格式异常")
		}
		code := firstNonEmpty(mapString(result, "code", "Code", "status_code"), mapString(nestedMap(result, "BaseResp"), "StatusCode"))
		if code != "" && code != "0" {
			return nil, fmt.Errorf("红果 App 接口暂不可用（%s）", truncate(code, 20))
		}
		return result, nil
	}
	return nil, lastErr
}

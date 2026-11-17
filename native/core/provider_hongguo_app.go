package core

// 红果 App 请求客户端（短剧设备注册用）。
//
// 只保留短剧设备注册所需的客户端结构与查询参数构造。

import (
	"net/url"
	"sync"
	"time"
)

const hongguoAppBaseURL = "https://api5-normal-sinfonlineb.fqnovel.com"

const hongguoAppUserAgent = "com.phoenix.read/73532 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)"

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

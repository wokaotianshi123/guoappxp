package core

import (
	"os"
	"testing"
	"time"
)

// 测量从商店下载模块文件各镜像的实际耗时，用于判断 moduleFetchTimeout 是否够用。
//
//	GUOAPP_NET_TEST=1 go test ./core/ -run TestStoreDownloadTiming -v -timeout 10m
func TestStoreDownloadTiming(t *testing.T) {
	if os.Getenv("GUOAPP_NET_TEST") != "1" {
		t.Skip("设置 GUOAPP_NET_TEST=1 才会联网测速")
	}
	addresses := []string{
		"https://cdn.jsdelivr.net/gh/guocheng1378/guoapp-modules@v2.0.0/main.js",
		"https://fastly.jsdelivr.net/gh/guocheng1378/guoapp-modules@v2.0.0/main.js",
		"https://raw.githubusercontent.com/guocheng1378/guoapp-modules/v2.0.0/main.js",
		"https://api.github.com/repos/guocheng1378/guoapp-modules/contents/main.js?ref=v2.0.0",
	}
	client := storeTestClient()
	for _, address := range addresses {
		started := time.Now()
		raw, err := fetchStoreBytes(client, address)
		elapsed := time.Since(started)
		if err != nil {
			t.Logf("%8.2fs  FAIL  %s  %v", elapsed.Seconds(), address, err)
			continue
		}
		t.Logf("%8.2fs  OK    %s  %dB", elapsed.Seconds(), address, len(raw))
	}
}

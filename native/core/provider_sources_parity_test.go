package core

import (
	"encoding/base64"
	"io"
	"net/http"
	"net/url"
	"testing"
	"time"
)

func providerParityDownloader(t *testing.T, transport func(*http.Request, url.Values) (*http.Response, error)) *Downloader {
	t.Helper()
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		form := request.URL.Query()
		if request.Body != nil {
			body, err := io.ReadAll(request.Body)
			if err != nil {
				t.Fatal(err)
			}
			bodyForm, _ := url.ParseQuery(string(body))
			for key, values := range bodyForm {
				form[key] = append(form[key], values...)
			}
		}
		return transport(request, form)
	})
	d.cfg.HuangjuAPIURL = "https://api.huangju.test"
	d.cfg.HuangjuURL = "https://huangju.test"
	d.cfg.YeguoURL = "https://yeguo.test"
	d.cfg.DSDURL = "https://dsd.test"
	return d
}

func TestProviderSourceParsesTextFixturesAndRejectsMismatchedIdentity(t *testing.T) {
	// 剧果的解析与 ID 校验已随站源迁到 guoapp-sources。
	// 野果的解析与线路发现已随站源迁到 guoapp-sources。
	page := "https://www.dsd.com.se/index.php/vod/type/id/9/page/1.html"
	action, values, valid := dsdRouteParameters(page, "/index.php/vod/play/id/456/sid/1/nid/2.html?extra=1")
	if !valid || action != "play" || values["id"] != "456" || values["sid"] != "1" || values["nid"] != "2" || values["extra"] != "1" {
		t.Fatal("dsd route parser lost valid fields", action, values, valid)
	}
	if _, _, valid = dsdRouteParameters(page, "https://other.example/index.php/vod/play/id/456/sid/1/nid/2.html"); valid {
		t.Fatal("dsd accepted a cross-origin route")
	}
}

func TestProviderMediaCredentialsLimitOriginAndUseBackupAddresses(t *testing.T) {
	primary := "https://media.example.test/main.mp4"
	backup := "https://media.example.test/backup.mp4"
	model := map[string]any{"video_duration": "6", "video_list": []any{map[string]any{
		"main_url": "invalid", "backup_url": base64.StdEncoding.EncodeToString([]byte(primary)), "backup_urls": []any{backup},
		"video_meta": map[string]any{"codec_type": "h264", "definition": "720p"},
	}}}
	media, err := selectHongguoAppMedia(model)
	if err != nil || media.URL != primary || len(media.Variants) != 2 || media.Variants[1].URL != backup || media.Duration != 6*time.Second {
		t.Fatalf("hongguo backup media fields were lost: %+v %v", media, err)
	}
	credentials := &providerMediaCredentials{Origin: "https://media.example.test", Cookie: "Signed=fixture", Referer: "https://source.example.test/page", UserAgent: "Agent"}
	request, _ := http.NewRequest(http.MethodGet, "https://media.example.test/part", nil)
	if err := credentials.apply(request); err != nil || request.Header.Get("Cookie") != "Signed=fixture" || request.Header.Get("Origin") != "https://source.example.test" || request.Header.Get("User-Agent") != "Agent" {
		t.Fatal("credentials not applied on exact origin", err, request.Header)
	}
	other, _ := http.NewRequest(http.MethodGet, "https://media.example.test:444/part", nil)
	other.Header.Set("Cookie", "old=value")
	if err := credentials.apply(other); err != nil || other.Header.Get("Cookie") != "" {
		t.Fatal("credentials leaked to another origin", err, other.Header)
	}
}


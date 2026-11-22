package netdisk

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestExtractShareURL(t *testing.T) {
	cases := map[string]string{
		"https://pan.quark.cn/s/abc123":                         "https://pan.quark.cn/s/abc123",
		"看这个 https://pan.quark.cn/s/xyz789 提取码 abcd":        "https://pan.quark.cn/s/xyz789",
		"push://https://pan.quark.cn/s/push01":                   "https://pan.quark.cn/s/push01",
		"https://drive.uc.cn/s/uc001":                            "https://drive.uc.cn/s/uc001",
		"没有链接":                                                 "",
	}
	for input, want := range cases {
		if got := ExtractShareURL(input); got != want {
			t.Errorf("ExtractShareURL(%q) = %q，期望 %q", input, got, want)
		}
	}
}

func TestDetectProvider(t *testing.T) {
	cases := map[string]string{
		"https://pan.quark.cn/s/abc":            "quark",
		"https://drive.uc.cn/s/abc":             "uc",
		"https://www.alipan.com/s/abc":          "alipan",
		"https://example.com/s/abc":             "",
	}
	for input, want := range cases {
		if got := DetectProvider(input); got != want {
			t.Errorf("DetectProvider(%q) = %q，期望 %q", input, got, want)
		}
	}
}

func TestParseShareURL(t *testing.T) {
	id, pwd, err := ParseShareURL("https://pan.quark.cn/s/abc123")
	if err != nil || id != "abc123" || pwd != "" {
		t.Errorf("解析失败: id=%q pwd=%q err=%v", id, pwd, err)
	}
	id, pwd, err = ParseShareURL("https://pan.quark.cn/s/abc123?pwd=xy12")
	if err != nil || id != "abc123" || pwd != "xy12" {
		t.Errorf("提取码解析失败: id=%q pwd=%q err=%v", id, pwd, err)
	}
	if _, _, err := ParseShareURL("https://example.com/nothing"); err == nil {
		t.Error("无效链接应报错")
	}
}

func TestCredentialsHeader(t *testing.T) {
	creds := &Credentials{
		Provider: "quark",
		Cookies: []Cookie{
			{Name: "a", Value: "1"},
			{Name: "b", Value: "2"},
		},
	}
	if got := creds.Header(); got != "a=1; b=2" {
		t.Errorf("Cookie 头拼接不对: %q", got)
	}
	if got := creds.Cookie("b"); got != "2" {
		t.Errorf("按名取 Cookie 不对: %q", got)
	}
	if got := creds.Cookie("missing"); got != "" {
		t.Errorf("缺失 Cookie 应返回空串，实际 %q", got)
	}
}

func TestProviderReadyRequiresPuus(t *testing.T) {
	if ProviderReady(nil) {
		t.Error("nil 凭据不应判为就绪")
	}
	without := &Credentials{Provider: "quark", Cookies: []Cookie{{Name: "a", Value: "1"}}}
	if ProviderReady(without) {
		t.Error("缺 __puus 不应判为就绪（播放 CDN 会 403）")
	}
	with := &Credentials{Provider: "quark", Cookies: []Cookie{{Name: "__puus", Value: "x"}}}
	if !ProviderReady(with) {
		t.Error("有 __puus 应判为就绪")
	}
}

func TestQuarkShareListing(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		path := request.URL.Path
		switch {
		case strings.Contains(path, "sharepage/token"):
			json.NewEncoder(writer).Encode(map[string]any{
				"status": 200,
				"data":   map[string]any{"stoken": "tok"},
			})
		case strings.Contains(path, "sharepage/detail"):
			// 第一次列根目录：一个子目录 + 一个视频；进入子目录再列一集。
			fid := request.URL.Query().Get("pdir_fid")
			if fid == "0" {
				json.NewEncoder(writer).Encode(map[string]any{
					"status": 200,
					"data": map[string]any{"list": []map[string]any{
						{"fid": "dir1", "file_name": "第一季", "dir": true},
						{"fid": "root-video", "file_name": "预告.mp4", "share_fid_token": "t0", "size": 1024},
					}},
				})
				return
			}
			json.NewEncoder(writer).Encode(map[string]any{
				"status": 200,
				"data": map[string]any{"list": []map[string]any{
					{"fid": "ep1", "file_name": "第01集.mkv", "share_fid_token": "t1", "size": 2048},
					{"fid": "note", "file_name": "说明.txt", "size": 10},
				}},
			})
		default:
			http.NotFound(writer, request)
		}
	}))
	defer server.Close()

	// 把 API 基址临时指到测试服务器。
	client := NewQuark(nil)
	client.api = server.URL + "/1/clouddrive/"

	info, err := client.Share(context.Background(), "https://pan.quark.cn/s/abc123")
	if err != nil {
		t.Fatalf("解析分享失败: %v", err)
	}
	if info.ShareID != "abc123" {
		t.Errorf("shareId 不对: %q", info.ShareID)
	}
	// 只应收集视频（预告.mp4 + 第01集.mkv），说明.txt 不算。
	if len(info.Episodes) != 2 {
		t.Fatalf("集数不对: %d %+v", len(info.Episodes), info.Episodes)
	}
	names := map[string]bool{}
	for _, ep := range info.Episodes {
		names[ep.Name] = true
	}
	if !names["预告.mp4"] || !names["第01集.mkv"] {
		t.Errorf("缺少预期视频: %+v", info.Episodes)
	}
	if names["说明.txt"] {
		t.Error("非视频文件不应出现在集数里")
	}
}

package netdisk

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// TestParseUCShareURL 校验 UC 分享链接的 shareID 与提取码解析。
func TestParseUCShareURL(t *testing.T) {
	shareID, pwd, err := ParseUCShareURL("https://drive.uc.cn/s/ucabc123?pwd=x9y8")
	if err != nil || shareID != "ucabc123" || pwd != "x9y8" {
		t.Fatalf("ParseUCShareURL = %q, %q, %v", shareID, pwd, err)
	}
	if _, _, err := ParseUCShareURL("https://pan.quark.cn/s/abc"); err == nil {
		t.Fatal("夸克链接不该被 UC 解析器接受")
	}
}

// TestUCDetectsOwnShare 确认 UC 客户端的 ID 与 Match 只认 UC 链接。
func TestUCDetectsOwnShare(t *testing.T) {
	client := NewUC(nil)
	if client.ID() != "uc" {
		t.Fatalf("ID = %q", client.ID())
	}
	if !client.Match("https://drive.uc.cn/s/abc123") {
		t.Fatal("UC 链接应匹配 UC 客户端")
	}
	if client.Match("https://pan.quark.cn/s/abc123") {
		t.Fatal("夸克链接不该匹配 UC 客户端")
	}
}

// TestUCShareListsFiles 用假服务验证 UC 分享解析：走 sharepage/token →
// sharepage/detail，并按视频扩展名过滤、保留原文件名。
func TestUCShareListsFiles(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		switch {
		case strings.Contains(request.URL.Path, "/share/sharepage/token"):
			_, _ = writer.Write([]byte(`{"status":200,"data":{"stoken":"st-1"}}`))
		case strings.Contains(request.URL.Path, "/share/sharepage/detail"):
			// 第一层：一个目录 + 一个视频；目录里再放一个视频与一个非视频。
			if request.URL.Query().Get("pdir_fid") == "0" {
				_, _ = writer.Write([]byte(`{"status":200,"data":{"list":[
					{"fid":"dir1","file_name":"第 1 季","dir":true},
					{"fid":"f1","file_name":"第 1 集.mp4","share_fid_token":"t1","size":1048576}
				]}}`))
				return
			}
			_, _ = writer.Write([]byte(`{"status":200,"data":{"list":[
				{"fid":"f2","file_name":"第 2 集.mkv","share_fid_token":"t2","size":2097152},
				{"fid":"f3","file_name":"说明.txt","share_fid_token":"t3"}
			]}}`))
		default:
			_, _ = writer.Write([]byte(`{"status":200,"data":{}}`))
		}
	}))
	defer server.Close()

	client := NewUC(nil)
	client.api = server.URL + "/1/clouddrive/"
	info, err := client.Share(context.Background(), "https://drive.uc.cn/s/ucabc123")
	if err != nil {
		t.Fatalf("Share: %v", err)
	}
	if info.Provider != "uc" {
		t.Fatalf("Provider = %q", info.Provider)
	}
	if len(info.Episodes) != 2 {
		t.Fatalf("剧集数 = %d，期望 2（非视频应被过滤）", len(info.Episodes))
	}
	// 原文件名必须保留，不能被编号覆盖。
	if info.Episodes[0].Name != "第 1 集.mp4" || info.Episodes[1].Name != "第 2 集.mkv" {
		t.Fatalf("文件名 = %q / %q", info.Episodes[0].Name, info.Episodes[1].Name)
	}
	if info.Episodes[0].Size != 1048576 {
		t.Fatalf("文件大小 = %d", info.Episodes[0].Size)
	}
}

// TestParseCookieHeader 校验 Cookie 登录：分号与换行都能解析，缺 __puus 要报错。
func TestParseCookieHeader(t *testing.T) {
	creds, err := ParseCookieHeader("uc", "__pus=abc; __puus=def\nother=1")
	if err != nil {
		t.Fatalf("ParseCookieHeader: %v", err)
	}
	if creds.Provider != "uc" {
		t.Fatalf("Provider = %q", creds.Provider)
	}
	if creds.Cookie("__puus") != "def" || creds.Cookie("other") != "1" {
		t.Fatalf("cookies = %+v", creds.Cookies)
	}
	if _, err := ParseCookieHeader("quark", "__pus=abc"); err == nil {
		t.Fatal("缺 __puus 时应报错")
	}
	if _, err := ParseCookieHeader("quark", "   "); err == nil {
		t.Fatal("空 Cookie 应报错")
	}
}

// TestNormalizeProvider 校验网盘标识归一。
func TestNormalizeProvider(t *testing.T) {
	cases := map[string]string{
		"":         "quark",
		"quark":    "quark",
		"uc":       "uc",
		"UC":       "uc",
		"ucdrive":  "uc",
		"unknown":  "quark",
	}
	for input, want := range cases {
		if got := NormalizeProvider(input); got != want {
			t.Errorf("NormalizeProvider(%q) = %q，期望 %q", input, got, want)
		}
	}
}

// TestUCCleanupTemp 校验临时目录清理会列出并删除 gomovie_tmp 里的文件。
func TestUCCleanupTemp(t *testing.T) {
	deleted := 0
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		switch {
		case strings.Contains(request.URL.Path, "/file/delete"):
			var body struct {
				FileList []string `json:"filelist"`
			}
			_ = json.NewDecoder(request.Body).Decode(&body)
			deleted = len(body.FileList)
			_, _ = writer.Write([]byte(`{"status":200}`))
		case strings.Contains(request.URL.Path, "/file/sort"):
			if request.URL.Query().Get("pdir_fid") == "0" {
				_, _ = writer.Write([]byte(`{"status":200,"data":{"list":[
					{"fid":"tmp1","file_name":"gomovie_tmp","dir":true}
				]}}`))
				return
			}
			_, _ = writer.Write([]byte(`{"status":200,"data":{"list":[
				{"fid":"a"},{"fid":"b"}
			]}}`))
		default:
			_, _ = writer.Write([]byte(`{"status":200}`))
		}
	}))
	defer server.Close()

	creds := &Credentials{Provider: "uc", Cookies: []Cookie{{Name: "__puus", Value: "x"}}}
	client := NewUC(creds)
	client.api = server.URL + "/1/clouddrive/"
	count, err := client.CleanupTemp(context.Background())
	if err != nil {
		t.Fatalf("CleanupTemp: %v", err)
	}
	if count != 2 || deleted != 2 {
		t.Fatalf("清理数 = %d（删除 %d），期望 2", count, deleted)
	}
}

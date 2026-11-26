package main

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"io"
	"net/url"
	"strings"
	"testing"
)

const jsSubscriptionTestScript = `var spider = {
  meta: {
    id: "demo-source",
    name: "演示源",
    version: "1.0.0",
    author: "tester",
  },
  home: function () { return { class: [] }; },
};
`

func mustURL(t *testing.T, raw string) *url.URL {
	t.Helper()
	parsed, err := url.Parse(raw)
	if err != nil {
		t.Fatalf("url.Parse(%q): %v", raw, err)
	}
	return parsed
}

func TestResolveJsSubscriptionURL(t *testing.T) {
	base := mustURL(
		t,
		"https://raw.githubusercontent.com/wokaotianshi123/config/refs/heads/main/xiaoguojs/xiaoguojs.json",
	)
	cases := map[string]string{
		// 与订阅同目录：这是导出包和订阅里推荐的写法。
		`.\hongguo.js`: "https://raw.githubusercontent.com/wokaotianshi123/config/refs/heads/main/xiaoguojs/hongguo.js",
		`.\volcanoexpo-com.js`: "https://raw.githubusercontent.com/wokaotianshi123/config/refs/heads/main/xiaoguojs/volcanoexpo-com.js",
		"./redguoxianji.js": "https://raw.githubusercontent.com/wokaotianshi123/config/refs/heads/main/xiaoguojs/redguoxianji.js",
		"hongguo.js": "https://raw.githubusercontent.com/wokaotianshi123/config/refs/heads/main/xiaoguojs/hongguo.js",
		"../xiaoguojs/hongguo.js": "https://raw.githubusercontent.com/wokaotianshi123/config/refs/heads/main/xiaoguojs/hongguo.js",
		// 绝对地址与根路径是显式写法，按原样解析。
		"https://cdn.example.com/a.js": "https://cdn.example.com/a.js",
		"/root/a.js":                   "https://raw.githubusercontent.com/root/a.js",
	}
	for raw, want := range cases {
		if got := resolveJsSubscriptionURL(raw, base); got != want {
			t.Errorf("resolveJsSubscriptionURL(%q) = %q, want %q", raw, got, want)
		}
	}
}

func TestResolveJsSubscriptionURLIgnoresRelativeWithoutBase(t *testing.T) {
	if got := resolveJsSubscriptionURL("./a.js", nil); got != "" {
		t.Fatalf("没有订阅地址时相对路径应忽略，got %q", got)
	}
}

func TestParseJsSubscriptionFormats(t *testing.T) {
	base := mustURL(t, "https://example.com/subs/list.json")
	cases := []struct {
		name string
		raw  string
		want []jsSubscriptionEntry
	}{
		{
			name: "sources 数组",
			raw:  `{"sources":[{"name":"A","url":"./a.js"},{"title":"B","address":"b.js"}]}`,
			want: []jsSubscriptionEntry{
				{Name: "A", URL: "https://example.com/subs/a.js"},
				{Name: "B", URL: "https://example.com/subs/b.js"},
			},
		},
		{
			name: "裸数组",
			raw:  `["./a.js",{"name":"B","url":"https://cdn.example.com/b.js"}]`,
			want: []jsSubscriptionEntry{
				{URL: "https://example.com/subs/a.js"},
				{Name: "B", URL: "https://cdn.example.com/b.js"},
			},
		},
		{
			name: "映射写法",
			raw:  `{"甲源":"./a.js"}`,
			want: []jsSubscriptionEntry{{Name: "甲源", URL: "https://example.com/subs/a.js"}},
		},
		{
			name: "单个对象",
			raw:  `{"name":"单源","url":"./a.js"}`,
			want: []jsSubscriptionEntry{{Name: "单源", URL: "https://example.com/subs/a.js"}},
		},
	}
	for _, testCase := range cases {
		got := parseJsSubscription([]byte(testCase.raw), base)
		if len(got) != len(testCase.want) {
			t.Fatalf("%s: got %d entries, want %d", testCase.name, len(got), len(testCase.want))
		}
		for index := range got {
			if got[index] != testCase.want[index] {
				t.Errorf("%s[%d] = %+v, want %+v", testCase.name, index, got[index], testCase.want[index])
			}
		}
	}
}

func TestParseJsSubscriptionRepairsWindowsBackslash(t *testing.T) {
	base := mustURL(t, "https://example.com/xiaoguojs/xiaoguojs.json")
	// 单个反斜杠在 JSON 里是非法转义，这里应修复后仍能解析。
	entries := parseJsSubscription(
		[]byte(`{"sources":[{"name":"官方流红果","url":".\hongguo.js"}]}`),
		base,
	)
	if len(entries) != 1 {
		t.Fatalf("got %d entries, want 1", len(entries))
	}
	if entries[0].Name != "官方流红果" {
		t.Errorf("name = %q", entries[0].Name)
	}
	want := "https://example.com/xiaoguojs/hongguo.js"
	if entries[0].URL != want {
		t.Errorf("url = %q, want %q", entries[0].URL, want)
	}
}

func TestParseLocalJsSubscriptionKeepsRelativePaths(t *testing.T) {
	entries := parseLocalJsSubscription([]byte(`{"sources":[
		{"name":"官方流红果","url":".\hongguo.js"},
		{"name":"子目录","url":"./sub/a.js"},
		{"name":"远程","url":"https://example.com/b.js"}
	]}`))
	want := []string{"hongguo.js", "sub/a.js", "https://example.com/b.js"}
	if len(entries) != len(want) {
		t.Fatalf("got %d entries, want %d", len(entries), len(want))
	}
	for index := range want {
		if entries[index].URL != want[index] {
			t.Errorf("entries[%d].URL = %q, want %q", index, entries[index].URL, want[index])
		}
	}
}

func TestSubscriptionZipRoundTrip(t *testing.T) {
	root := t.TempDir()
	jsSourceMu.Lock()
	previous := jsSourceRoot
	jsSourceMu.Unlock()
	setJsSourceDirectory(root)
	t.Cleanup(func() {
		jsSourceMu.Lock()
		jsSourceRoot = previous
		jsSourceMu.Unlock()
	})

	if _, err := writeJsSource("hongguo.js", jsSubscriptionTestScript); err != nil {
		t.Fatalf("writeJsSource: %v", err)
	}
	items := scanJsSources()
	if len(items) != 1 {
		t.Fatalf("scanJsSources got %d items, want 1", len(items))
	}

	raw, err := buildJsSubscriptionZip(items)
	if err != nil {
		t.Fatalf("buildJsSubscriptionZip: %v", err)
	}
	reader, err := zip.NewReader(bytes.NewReader(raw), int64(len(raw)))
	if err != nil {
		t.Fatalf("zip.NewReader: %v", err)
	}
	found := map[string]bool{}
	config := ""
	for _, file := range reader.File {
		found[file.Name] = true
		if file.Name == jsSubscriptionConfigName {
			handle, err := file.Open()
			if err != nil {
				t.Fatalf("open config: %v", err)
			}
			body, err := io.ReadAll(handle)
			_ = handle.Close()
			if err != nil {
				t.Fatalf("read config: %v", err)
			}
			config = string(body)
		}
	}
	if !found[jsSubscriptionConfigName] || !found["hongguo.js"] {
		t.Fatalf("zip entries = %v, want xiaoguo.json + hongguo.js", found)
	}
	var decoded struct {
		Sources []struct {
			Name string `json:"name"`
			URL  string `json:"url"`
		} `json:"sources"`
	}
	if err := json.Unmarshal([]byte(config), &decoded); err != nil {
		t.Fatalf("config 不是合法 JSON：%v\n%s", err, config)
	}
	if len(decoded.Sources) != 1 ||
		decoded.Sources[0].URL != `.\hongguo.js` ||
		decoded.Sources[0].Name != "演示源" {
		t.Fatalf("config = %s", config)
	}

	// 清空后再按导出的包导入，应还原同一个脚本。
	for _, item := range scanJsSources() {
		removeJsSourceFiles(item.ID, "")
	}
	imported, failed, err := importJsSubscriptionZip(raw)
	if err != nil {
		t.Fatalf("importJsSubscriptionZip: %v", err)
	}
	if len(failed) != 0 {
		t.Fatalf("failed = %v", failed)
	}
	if len(imported) != 1 || imported[0].ID != "demo-source" {
		t.Fatalf("imported = %+v", imported)
	}
	if script, ok := jsSourceScript("demo-source"); !ok || !strings.Contains(script, "spider") {
		t.Fatalf("导入后读不到脚本")
	}
}

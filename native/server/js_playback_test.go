package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

type jsTestRoundTripper func(*http.Request) (*http.Response, error)

func (trip jsTestRoundTripper) RoundTrip(request *http.Request) (*http.Response, error) {
	return trip(request)
}

// 服务端把响应头转成小写后，Worker 里的脚本才能用 fetch 习惯的
// response.headers['content-type']（红果取流时靠它判断片源类型）。
func TestHandleJsFetchLowercasesResponseHeaders(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Type", "video/mp4")
		writer.Header().Set("X-Media-Key", "abc")
		writer.WriteHeader(http.StatusOK)
	}))
	defer upstream.Close()

	previous := jsFetchClient
	jsFetchClient = &http.Client{Transport: jsTestRoundTripper(func(request *http.Request) (*http.Response, error) {
		request.URL.Scheme = "http"
		request.URL.Host = strings.TrimPrefix(upstream.URL, "http://")
		return http.DefaultTransport.RoundTrip(request)
	})}
	t.Cleanup(func() { jsFetchClient = previous })

	body := `{"url":"http://media.example.com/clip.mp4","method":"HEAD"}`
	recorder := httptest.NewRecorder()
	handleJsFetch(recorder, httptest.NewRequest(http.MethodPost, "/api/js/fetch", strings.NewReader(body)))

	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", recorder.Code, recorder.Body.String())
	}
	var answer struct {
		Status  int               `json:"status"`
		Headers map[string]string `json:"headers"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &answer); err != nil {
		t.Fatalf("decode: %v\n%s", err, recorder.Body.String())
	}
	if answer.Status != http.StatusOK {
		t.Fatalf("upstream status = %d", answer.Status)
	}
	if got := answer.Headers["content-type"]; got != "video/mp4" {
		t.Fatalf("content-type = %q, want video/mp4 (headers=%v)", got, answer.Headers)
	}
	if got := answer.Headers["x-media-key"]; got != "abc" {
		t.Fatalf("x-media-key = %q", got)
	}
}

func TestHandleJsPlaybackRejectsBadRequests(t *testing.T) {
	cases := []struct {
		name   string
		method string
		body   string
		want   int
	}{
		{name: "非 POST", method: http.MethodGet, want: http.StatusMethodNotAllowed},
		{name: "非法 JSON", method: http.MethodPost, body: "{", want: http.StatusBadRequest},
		{name: "不支持的协议", method: http.MethodPost, body: `{"url":"file:///a.mp4"}`, want: http.StatusBadRequest},
		{name: "内网地址", method: http.MethodPost, body: `{"url":"http://127.0.0.1/a.mp4"}`, want: http.StatusForbidden},
	}
	for _, testCase := range cases {
		recorder := httptest.NewRecorder()
		request := httptest.NewRequest(testCase.method, "/api/js/playback", strings.NewReader(testCase.body))
		handleJsPlayback(recorder, request)
		if recorder.Code != testCase.want {
			t.Errorf("%s: status = %d, want %d", testCase.name, recorder.Code, testCase.want)
		}
	}
}

// 前端静态资源是 go:embed 打进 exe 的，这里守住三处本轮修复的关键点，
// 避免以后改页面时把内置订阅或 HLS 判断删回去。
func TestJsSandboxWebAssetsKeepFixes(t *testing.T) {
	sandbox, err := webAssets.ReadFile("web/js-sandbox.js")
	if err != nil {
		t.Fatalf("read js-sandbox.js: %v", err)
	}
	for _, want := range []string{
		"xiaoguojs/xiaoguo.json",
		"js-subscription-url",
		"js-fill-xiaoguo",
		"js-import-subscription",
		"/api/js/playback",
		"mode: mode",
	} {
		if !strings.Contains(string(sandbox), want) {
			t.Errorf("js-sandbox.js 缺少 %q", want)
		}
	}

	app, err := webAssets.ReadFile("web/app.js")
	if err != nil {
		t.Fatalf("read app.js: %v", err)
	}
	for _, want := range []string{
		"function videoIsPlaylist",
		"plan.mode === 'hls'",
		"/api/js/stream?",
	} {
		if !strings.Contains(string(app), want) {
			t.Errorf("app.js 缺少 %q", want)
		}
	}

	worker, err := webAssets.ReadFile("web/js-sandbox-worker.js")
	if err != nil {
		t.Fatalf("read js-sandbox-worker.js: %v", err)
	}
	for _, want := range []string{
		"Object.keys(rawHeaders).forEach",
		"headers.get",
	} {
		if !strings.Contains(string(worker), want) {
			t.Errorf("js-sandbox-worker.js 缺少 %q", want)
		}
	}
}

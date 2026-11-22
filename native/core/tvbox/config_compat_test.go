package tvbox

import (
	"encoding/base64"
	"strings"
	"testing"
)

// FlexInt 必须兼容字符串数字：饭太硬的 0821.json 里 type 写成 "4" 这种字符串。
func TestParseConfigFlexIntFromString(t *testing.T) {
	raw := []byte(`{
		"sites": [
			{"key":"a","name":"A","type":"4","api":"https://a.example.com/api","searchable":"1"},
			{"key":"b","name":"B","type":1,"api":"https://b.example.com/api"}
		]
	}`)
	cfg, err := ParseConfig(raw)
	if err != nil {
		t.Fatalf("解析失败: %v", err)
	}
	if len(cfg.Sites) != 2 {
		t.Fatalf("站点数不对: %d", len(cfg.Sites))
	}
	if int(cfg.Sites[0].Type) != 4 {
		t.Errorf("字符串 type 未解析为 4，实际 %d", cfg.Sites[0].Type)
	}
	if int(cfg.Sites[0].Searchable) != 1 {
		t.Errorf("字符串 searchable 未解析为 1，实际 %d", cfg.Sites[0].Searchable)
	}
	if cfg.Sites[0].Kind != KindT4 || !cfg.Sites[0].Supported {
		t.Errorf("type=4 且为 http 接口应判为可用 T4，实际 kind=%s supported=%v", cfg.Sites[0].Kind, cfg.Sites[0].Supported)
	}
}

// drpy 的 .js 伪 T4 站点必须被过滤掉：这类站点要靠 JS 引擎执行，原生取不到数据。
func TestParseConfigFiltersDrpyJS(t *testing.T) {
	raw := []byte(`{
		"sites": [
			{"key":"drpy","name":"drpy","type":4,"api":"https://x.example.com/drpy2.js"},
			{"key":"drpy2","name":"drpy2","type":4,"api":"https://x.example.com/drpy.js?v=1"},
			{"key":"ok","name":"ok","type":4,"api":"https://x.example.com/api.php/provide/vod/"}
		]
	}`)
	cfg, err := ParseConfig(raw)
	if err != nil {
		t.Fatalf("解析失败: %v", err)
	}
	if cfg.Sites[0].Supported {
		t.Error("drpy .js 伪 T4 站点不应判为可用")
	}
	if cfg.Sites[1].Supported {
		t.Error("drpy.js?xxx 伪 T4 站点不应判为可用")
	}
	if !cfg.Sites[2].Supported {
		t.Error("普通 http T4 接口应判为可用")
	}
}

// 图片尾 **Base64：正文里先出现一个无关的 **，真正的编码块在最后一个 ** 之后。
func TestParseConfigBase64AfterLastMarker(t *testing.T) {
	payload := `{"sites":[{"key":"k","name":"n","type":1,"api":"https://a.example.com/api"}]}`
	encoded := base64.StdEncoding.EncodeToString([]byte(payload))
	raw := []byte("这是站点说明 ** 分隔符 **" + encoded)

	cfg, err := ParseConfig(raw)
	if err != nil {
		t.Fatalf("解析失败: %v", err)
	}
	if len(cfg.Sites) != 1 || cfg.Sites[0].Key != "k" {
		t.Fatalf("没有按最后一个 ** 之后的 Base64 解析出站点: %+v", cfg.Sites)
	}
}

// 纯 Base64 订阅（没有 ** 前缀）也要能解开。
func TestParseConfigPlainBase64(t *testing.T) {
	payload := `{"sites":[{"key":"plain","name":"plain","type":1,"api":"https://p.example.com/api"}]}`
	encoded := base64.StdEncoding.EncodeToString([]byte(payload))
	cfg, err := ParseConfig([]byte(encoded))
	if err != nil {
		t.Fatalf("解析失败: %v", err)
	}
	if len(cfg.Sites) != 1 || cfg.Sites[0].Key != "plain" {
		t.Fatalf("纯 Base64 订阅未解析出站点: %+v", cfg.Sites)
	}
}

// 带注释的 JSON 要能解析；注释出现在字符串里则不能误删。
func TestParseConfigStripsComments(t *testing.T) {
	raw := []byte(`{
		// 顶部注释
		"sites": [
			{"key":"c","name":"http://not-a-comment","type":1,"api":"https://c.example.com/api"} /* 行内 */
		]
	}`)
	cfg, err := ParseConfig(raw)
	if err != nil {
		t.Fatalf("解析失败: %v", err)
	}
	if len(cfg.Sites) != 1 {
		t.Fatalf("站点数不对: %d", len(cfg.Sites))
	}
	if cfg.Sites[0].Name != "http://not-a-comment" {
		t.Errorf("字符串里的 // 被误当注释删掉了: %q", cfg.Sites[0].Name)
	}
}

// csp_ 前缀的 jar 站点只在 Android 可用。
func TestClassifyJarOnlyOnAndroid(t *testing.T) {
	kind, supported := classifySite(Site{Type: 3, API: "csp_Test"})
	if kind != KindJar {
		t.Errorf("csp_ 应判为 jar，实际 %s", kind)
	}
	// 非 Android 平台不可用；测试机是 windows，这里断言 false。
	if supported {
		t.Error("非 Android 平台上的 csp_ jar 站点不应判为可用")
	}
}

func TestMirrorCandidatesAvoidDoublePrefix(t *testing.T) {
	mirrored := "https://ghfast.top/https://raw.githubusercontent.com/a/b.json"
	out := MirrorCandidates(mirrored)
	if len(out) != 1 || out[0] != mirrored {
		t.Errorf("已是镜像地址不应再套一层: %v", out)
	}
	plain := "https://raw.githubusercontent.com/a/b.json"
	out = MirrorCandidates(plain)
	if len(out) < 2 {
		t.Errorf("GitHub 直链应追加镜像候选: %v", out)
	}
	if !strings.HasPrefix(out[0], "https://raw.githubusercontent.com") {
		t.Errorf("首个候选应保持直连: %v", out)
	}
}

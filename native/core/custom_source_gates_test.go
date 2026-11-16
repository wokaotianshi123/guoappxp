package core

import "testing"

// 自定义源（MacCMS 站点 / XBPQ 规则）不进 provider 注册表，它存在引擎自己的
// 自定义源清单里。8e6d38d「同步代码」把核心对它的四处处理一起删掉了，表现为
// 「导入后站源名能显示，一用就报当前版本不包含此站源」——因为授权门禁只查
// 注册表，自定义源一律判成不可用。
//
// 这条链路上的每一道闸门都单独锁一遍，任何一道回退都会在测试里显形。
func TestCustomSourcePassesCoreGates(t *testing.T) {
	const source = "custom:0123456789abcdef"

	if !isCustomMaccmsSource(source) {
		t.Fatal("前缀判定失效，后面的用例都失去意义")
	}

	// ① 可用性：授权门禁与 nativeDramaAvailable 都靠它。
	if !nativeSourceAvailable(source) {
		t.Fatal("自定义源应判为可用，否则一点就报「当前版本不包含此站源」")
	}

	// ② 剧集 ID 拆分：站源 ID 本身含冒号，必须按第二个冒号拆。
	source_, sourceID, ok := SplitProviderDramaID(source + ":999")
	if !ok || source_ != source || sourceID != "999" {
		t.Fatalf("自定义剧集 ID 拆分 = %q / %q / %v，期望 %q / \"999\" / true", source_, sourceID, ok, source)
	}
	// 拆不出源内 ID 的应判失败，不能把 half-formed 的 ID 放过去。
	if _, _, ok := SplitProviderDramaID(source); ok {
		t.Fatal("缺少源内 ID 的自定义剧集 ID 不该拆成功")
	}

	// ③ 分类校验：自定义 MacCMS 源的分类 ID 允许路径形式。
	if !ValidNativeCategory(source, "/fenlei/1") {
		t.Fatal("自定义源的路径式分类应放行")
	}

	// ④ 授权阶段：端到端串一遍，确认 catalog 不会被拦。
	if err := nativeAuthorizeInput(nativeInput{Action: "catalog", Source: source}); err != nil {
		t.Fatalf("catalog 授权自定义源失败：%v", err)
	}
	// 反向：未注册的普通源仍必须拦住，别把闸门整个放开了。
	if err := nativeAuthorizeInput(nativeInput{Action: "catalog", Source: "definitely-not-a-source"}); err == nil {
		t.Fatal("未注册的普通源不该通过授权")
	}
}

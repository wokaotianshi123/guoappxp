package core

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func decodeNativeReply(t *testing.T, raw string) (bool, map[string]any) {
	t.Helper()
	var reply struct {
		OK    bool           `json:"ok"`
		Error string         `json:"error"`
		Data  map[string]any `json:"data"`
	}
	if err := json.Unmarshal([]byte(raw), &reply); err != nil {
		t.Fatalf("响应无法解析：%s", raw)
	}
	if !reply.OK {
		t.Logf("核心返回失败：%s", reply.Error)
	}
	return reply.OK, reply.Data
}

// 本地服务版（native/server）用 sourceStatus 判断某个站源有没有编进当前构建，
// /api/sources 与 /api/source-visibility 都靠它，判错就整张列表空掉。
//
// 这个动作被 8e6d38d「同步代码」连授权 case 一起删过，而核心的 action 清单
// 此前没有任何测试覆盖，于是坏了两轮才被发现。这里把这条缝两端都锁住：
//
//   - 已注册的源：能走到 case，返回 available=true
//   - 未注册的源：在 nativeAuthorizeInput 就被 nativeSourceAvailable 拦掉
//   - 不存在的 action：必须报错，不能静默返回 ok（静默成功会让上面前两条失去意义）
func TestSourceStatusAction(t *testing.T) {
	example := filepath.Join("..", "module_example", "jsexample")
	manifest, err := os.ReadFile(filepath.Join(example, moduleManifest))
	if err != nil {
		t.Fatal(err)
	}
	code, err := os.ReadFile(filepath.Join(example, moduleEntry))
	if err != nil {
		t.Fatal(err)
	}
	engine := &nativeEngine{
		downloader:     &Downloader{cfg: Config{dataDir: t.TempDir()}},
		cacheDirectory: t.TempDir(),
	}

	// NativeRequest 走包级 nativeState；sourceStatus 本身不碰引擎，但分发器
	// 会先检查引擎是否就绪，所以这里要把实例挂上去。
	nativeState.Lock()
	previous := nativeState.engine
	nativeState.engine = engine
	nativeState.Unlock()
	t.Cleanup(func() {
		nativeState.Lock()
		nativeState.engine = previous
		nativeState.Unlock()
	})

	// sourceStatus 只认注册表，装个模块让 registry 里有个真实的源。
	prepared, err := engine.prepareModule(context.Background(),
		testModulePackage(t, "jsexample/", map[string]string{moduleManifest: string(manifest), moduleEntry: string(code)}),
		"", "", false)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := engine.installModule(prepared.Token); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if _, err := engine.uninstallModule("jsexample"); err != nil {
			t.Fatal(err)
		}
	})

	ok, data := decodeNativeReply(t, NativeRequest(`{"action":"sourceStatus","source":"jsexample"}`))
	if !ok {
		t.Fatal("已注册的源问 sourceStatus 应该成功")
	}
	if data["available"] != true {
		t.Fatalf("available = %v，期望 true", data["available"])
	}
	if data["source"] != "jsexample" {
		t.Fatalf("source = %v，期望回显 jsexample", data["source"])
	}

	if ok, _ := decodeNativeReply(t, NativeRequest(`{"action":"sourceStatus","source":"definitely-not-a-source"}`)); ok {
		t.Fatal("未注册的源应该被授权阶段拦掉，返回 ok=false")
	}

	if ok, _ := decodeNativeReply(t, NativeRequest(`{"action":"definitelyNotAnAction"}`)); ok {
		t.Fatal("不存在的 action 必须报错；静默成功会让 action 清单的错误失效")
	}
}
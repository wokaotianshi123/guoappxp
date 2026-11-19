package core

import (
	"context"
	"encoding/json"
	"testing"
)

// 内置的限制级模块必须能被核心加载，且 sourceList 如实报出 Adult，
// 前端才能据此默认关闭。这里直接读仓库自带的 modules/，不依赖出包流程。
func TestRepositoryBundledModulesReportAdult(t *testing.T) {
	modules, failures := readBundledModules()
	if len(failures) > 0 {
		t.Fatalf("读取内置模块失败: %v", failures)
	}
	if len(modules) == 0 {
		t.Skip("当前没有内置模块（native/core/bundled 为空）")
	}
	if _, ok := modules["missav"]; ok {
		t.Fatal("missav 不应内置")
	}
	if _, ok := modules["guipian"]; !ok {
		t.Fatal("鬼片应内置")
	}

	adult, normal := 0, 0
	for id, module := range modules {
		if module.manifest.Adult == nil {
			t.Fatalf("%s 缺少 adult 声明", id)
		}
		if *module.manifest.Adult {
			adult++
		} else {
			normal++
		}
	}
	if adult == 0 {
		t.Fatal("没有任何限制级内置模块，默认关闭的逻辑无法生效")
	}
	t.Logf("内置模块 %d 个：限制级 %d，非限制级 %d", len(modules), adult, normal)
}

// 限制级内置模块装进数据目录后，sourceList 必须把 Adult 传出去。
func TestBundledAdultSourceListed(t *testing.T) {
	modules, failures := readBundledModules()
	if len(failures) > 0 {
		t.Fatalf("读取内置模块失败: %v", failures)
	}
	var adultID string
	for id, module := range modules {
		if module.manifest.Adult != nil && *module.manifest.Adult {
			adultID = id
			break
		}
	}
	if adultID == "" {
		t.Skip("没有限制级内置模块")
	}

	engine := &nativeEngine{
		downloader:     &Downloader{cfg: Config{dataDir: t.TempDir()}},
		cacheDirectory: t.TempDir(),
	}
	t.Cleanup(func() { Unregister(adultID) })
	engine.downloader.loadModules()

	var found *nativeSourceInfo
	for _, info := range engine.sourceList() {
		if info.ID == adultID {
			candidate := info
			found = &candidate
			break
		}
	}
	if found == nil {
		t.Fatalf("限制级内置模块 %s 没有出现在 sourceList 里", adultID)
	}
	if !found.Adult {
		t.Fatalf("%s 的 Adult 应为 true，前端才能默认关闭", adultID)
	}
	if !found.Module {
		t.Fatalf("%s 应标记为模块源", adultID)
	}
	if !found.Available {
		t.Fatalf("%s 应可用", adultID)
	}
	payload, err := json.Marshal(found)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("限制级源下发: %s", payload)
	_ = context.Background()
}

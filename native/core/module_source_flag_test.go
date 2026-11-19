package core

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

// sourceList 必须给「由站源模块提供」的源打上 module 标记。
//
// 前端（lib/local_store.dart 的 allowsSource）据此把模块源当成「谁用谁配」的
// 本机内容，不参与用户级源权限判定——和自定义源一个待遇。没有这个标记，
// 非管理员用户在装模块之前建的档就看不到后来装的模块源。
//
// 这条路径顺带覆盖一个死锁：installModule 会持 loadedModules 锁再调
// sourceList()，而 sourceList 现在要读同一把锁判断哪些源来自模块。Go 的
// Mutex 不可重入，持锁段一旦延伸到 sourceList 就会卡死（本测试会挂住超时）。
func TestSourceListMarksModuleSources(t *testing.T) {
	isolateBundledModules(t)
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
	t.Cleanup(func() {
		if _, err := engine.uninstallModule("jsexample"); err != nil {
			t.Fatal(err)
		}
	})

	prepared, err := engine.prepareModule(context.Background(),
		testModulePackage(t, "jsexample/", map[string]string{moduleManifest: string(manifest), moduleEntry: string(code)}),
		"", "", false)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := engine.installModule(prepared.Token); err != nil {
		t.Fatal(err)
	}

	found := false
	for _, info := range engine.sourceList() {
		if info.ID == "jsexample" {
			if !info.Module {
				t.Fatal("模块源 jsexample 没有打上 module 标记")
			}
			found = true
			continue
		}
		if info.Module {
			t.Fatalf("非模块源 %s 被误标成模块", info.ID)
		}
	}
	if !found {
		t.Fatal("sourceList 里没有装上的模块源 jsexample")
	}
}

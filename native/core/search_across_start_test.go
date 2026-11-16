package core

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// 多源搜索（搜索页勾多个源 / 本地服务版的「全部源」）曾经：勾一个源请求挂住，
// 勾两个源报「本地核心处理失败」（核心 panic 被 NativeRequest 的 recover 吞掉）。
// 这里直接调 nativeSearchStart，panic 会带完整堆栈失败、挂住会被超时抓住。
func TestSearchStartMultiSource(t *testing.T) {
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
	ctx := context.Background()
	ids := []string{"jsexample", "jsexample2"}
	for _, id := range ids {
		// 同一份模块代码换两个标识，得到两个都能搜索的站源。
		body := strings.Replace(string(manifest), `"jsexample"`, `"`+id+`"`, 1)
		prepared, err := engine.prepareModule(ctx,
			testModulePackage(t, id+"/", map[string]string{moduleManifest: body, moduleEntry: string(code)}),
			"", "", false)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := engine.installModule(prepared.Token); err != nil {
			t.Fatal(err)
		}
		installed := id
		t.Cleanup(func() {
			if _, err := engine.uninstallModule(installed); err != nil {
				t.Fatal(err)
			}
		})
	}

	if _, err := engine.nativeSearchStart(nativeInput{Query: "测试", Sources: ids, Page: 1}); err != nil {
		t.Fatalf("多源 searchStart 失败：%v", err)
	}
}

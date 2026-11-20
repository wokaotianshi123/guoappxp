package core

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// 用仓库里真实的笔盒模块跑一遍列表，确认 AES 解码不再失败。
//
// 需要联网，默认跳过：
//
//	GUOAPP_BEABOX_TEST=1 go test ./core/ -run TestBeaboxDecodesRealCatalog -v
func TestBeaboxDecodesRealCatalog(t *testing.T) {
	if os.Getenv("GUOAPP_BEABOX_TEST") != "1" {
		t.Skip("设置 GUOAPP_BEABOX_TEST=1 才会联网验证笔盒")
	}
	dir := filepath.Join("..", "..", "modules", "beabox")
	if _, err := os.Stat(filepath.Join(dir, moduleManifest)); err != nil {
		t.Skip("仓库里没有 beabox 模块")
	}
	manifestRaw, err := os.ReadFile(filepath.Join(dir, moduleManifest))
	if err != nil {
		t.Fatal(err)
	}
	codeRaw, err := os.ReadFile(filepath.Join(dir, moduleEntry))
	if err != nil {
		t.Fatal(err)
	}
	module, err := parseModule(manifestRaw, codeRaw)
	if err != nil {
		t.Fatalf("笔盒清单解析失败: %v", err)
	}

	client := storeTestClient()
	engine := &nativeEngine{
		downloader: &Downloader{
			cfg:     Config{dataDir: t.TempDir()},
			client:  client,
			limiter: newRequestLimiter(3, 0),
		},
		cacheDirectory: t.TempDir(),
	}
	t.Cleanup(func() { Unregister(module.manifest.ID) })
	loadedModules.Lock()
	writeErr := engine.downloader.writeModuleLocked(module.manifest.ID, manifestRaw, codeRaw)
	loadedModules.Unlock()
	if writeErr != nil {
		t.Fatal(writeErr)
	}
	engine.downloader.reloadModuleLocked(module.manifest.ID)
	provider, ok := engine.downloader.provider(module.manifest.ID)
	if !ok {
		t.Fatal("笔盒模块没有注册")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()

	categories, err := provider.Categories(ctx, false)
	if err != nil {
		t.Fatalf("分类失败: %v", err)
	}
	t.Logf("分类 %d 个", len(categories))
	category := ""
	if len(categories) > 0 {
		category = categories[0].ID
	}

	items, _, err := provider.CatalogPage(ctx, 1, category)
	if err != nil {
		// 这里是最关键的一条：解码失败会带「笔盒接口数据解码失败」。
		if strings.Contains(err.Error(), "解码失败") {
			t.Fatalf("笔盒仍然解码失败: %v", err)
		}
		t.Fatalf("列表失败: %v", err)
	}
	if len(items) == 0 {
		t.Fatal("列表为空")
	}
	t.Logf("列表 %d 条，首条「%s」", len(items), items[0].Title)
}

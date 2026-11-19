package core

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"testing/fstest"
)

// moduleZip 用给定的 manifest/code 拼一个模块包，prefix 控制是否套一层文件夹。
func moduleZip(t *testing.T, id, version, prefix string) []byte {
	t.Helper()
	var buffer bytes.Buffer
	archive := zip.NewWriter(&buffer)
	manifest := `{"id":"` + id + `","name":"` + id + `","version":"` + version + `","description":"","runtime":"js","api":1,"adult":false,"hosts":[]}`
	code := `module.exports={categories:function(){return [];},catalogPage:function(){return {items:[]};},detail:function(){return {drama:{},chapters:[]};},resolveMedia:function(){return {url:""};}};`
	files := map[string]string{moduleManifest: manifest, moduleEntry: code}
	for name, content := range files {
		writer, err := archive.Create(prefix + name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := writer.Write([]byte(content)); err != nil {
			t.Fatal(err)
		}
	}
	if err := archive.Close(); err != nil {
		t.Fatal(err)
	}
	return buffer.Bytes()
}

// bundleZip 把若干模块包再打成一个合集 zip。
func bundleZip(t *testing.T, members map[string][]byte) []byte {
	t.Helper()
	var buffer bytes.Buffer
	archive := zip.NewWriter(&buffer)
	for name, raw := range members {
		writer, err := archive.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := writer.Write(raw); err != nil {
			t.Fatal(err)
		}
	}
	if err := archive.Close(); err != nil {
		t.Fatal(err)
	}
	return buffer.Bytes()
}

func TestExpandModulePackageSingle(t *testing.T) {
	raw := moduleZip(t, "alpha", "1.0.0", "")
	items, err := expandModulePackage("alpha.zip", raw, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 {
		t.Fatalf("单个模块包应展开成 1 份，得到 %d", len(items))
	}
}

func TestExpandModulePackageNestedFolder(t *testing.T) {
	// 模块包常见形态：zip 里套一层同名文件夹。
	raw := moduleZip(t, "beta", "1.0.0", "beta/")
	items, err := expandModulePackage("beta.zip", raw, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 {
		t.Fatalf("套一层文件夹的模块包应展开成 1 份，得到 %d", len(items))
	}
}

func TestExpandModulePackageBundle(t *testing.T) {
	// 一个 zip 里装多个子模块 zip，要能全部识别。
	bundle := bundleZip(t, map[string][]byte{
		"gamma.zip": moduleZip(t, "gamma", "1.0.0", ""),
		"delta.zip": moduleZip(t, "delta", "1.0.1", ""),
	})
	items, err := expandModulePackage("bundle.zip", bundle, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 2 {
		t.Fatalf("合集包应展开成 2 份，得到 %d", len(items))
	}
}

func TestExpandModulePackageBundleWithNestedFolder(t *testing.T) {
	// 合集包里的子包又套了一层文件夹。
	bundle := bundleZip(t, map[string][]byte{
		"eps.zip": moduleZip(t, "epsilon", "1.0.0", "epsilon/"),
	})
	items, err := expandModulePackage("bundle.zip", bundle, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 {
		t.Fatalf("应展开成 1 份，得到 %d", len(items))
	}
}

func TestExpandModulePackageRejectsNonModule(t *testing.T) {
	var buffer bytes.Buffer
	archive := zip.NewWriter(&buffer)
	writer, _ := archive.Create("readme.txt")
	_, _ = writer.Write([]byte("not a module"))
	_ = archive.Close()
	if _, err := expandModulePackage("junk.zip", buffer.Bytes(), 0); err == nil {
		t.Fatal("不含模块的 zip 应当报错")
	}
}

func TestExpandModulePackageRejectsPlainText(t *testing.T) {
	if _, err := expandModulePackage("x.zip", []byte("hello"), 0); err == nil {
		t.Fatal("非 zip 内容应当报错")
	}
}

func newBatchEngine(t *testing.T) *nativeEngine {
	t.Helper()
	engine := &nativeEngine{
		downloader:     &Downloader{cfg: Config{dataDir: t.TempDir()}},
		cacheDirectory: t.TempDir(),
	}
	return engine
}

func TestPrepareModulesAcceptsMultipleFiles(t *testing.T) {
	engine := newBatchEngine(t)
	t.Cleanup(func() { Unregister("alpha"); Unregister("beta") })
	dir := t.TempDir()
	first := filepath.Join(dir, "alpha.zip")
	second := filepath.Join(dir, "beta.zip")
	if err := os.WriteFile(first, moduleZip(t, "alpha", "1.0.0", ""), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(second, moduleZip(t, "beta", "1.0.0", ""), 0o600); err != nil {
		t.Fatal(err)
	}
	result, err := engine.prepareModules(context.Background(), []string{first, second}, nil)
	if err != nil {
		t.Fatal(err)
	}
	items, _ := result["items"].([]prepareModuleResult)
	ok := 0
	for _, item := range items {
		if item.Info != nil && item.Info.Token != "" {
			ok++
		}
	}
	if ok != 2 {
		t.Fatalf("应暂存 2 个模块，实际 %d（items=%+v）", ok, items)
	}
}

func TestPrepareModulesExpandsBundle(t *testing.T) {
	engine := newBatchEngine(t)
	t.Cleanup(func() { Unregister("gamma"); Unregister("delta") })
	dir := t.TempDir()
	file := filepath.Join(dir, "bundle.zip")
	bundle := bundleZip(t, map[string][]byte{
		"gamma.zip": moduleZip(t, "gamma", "1.0.0", ""),
		"delta.zip": moduleZip(t, "delta", "1.0.0", ""),
	})
	if err := os.WriteFile(file, bundle, 0o600); err != nil {
		t.Fatal(err)
	}
	result, err := engine.prepareModules(context.Background(), []string{file}, nil)
	if err != nil {
		t.Fatal(err)
	}
	items, _ := result["items"].([]prepareModuleResult)
	ok := 0
	for _, item := range items {
		if item.Info != nil && item.Info.Token != "" {
			ok++
		}
	}
	if ok != 2 {
		t.Fatalf("合集包应暂存 2 个模块，实际 %d（items=%+v）", ok, items)
	}
}

func TestPrepareModulesKeepsIndependentTokens(t *testing.T) {
	engine := newBatchEngine(t)
	t.Cleanup(func() { Unregister("alpha"); Unregister("beta") })
	dir := t.TempDir()
	first := filepath.Join(dir, "alpha.zip")
	second := filepath.Join(dir, "beta.zip")
	_ = os.WriteFile(first, moduleZip(t, "alpha", "1.0.0", ""), 0o600)
	_ = os.WriteFile(second, moduleZip(t, "beta", "1.0.0", ""), 0o600)
	result, _ := engine.prepareModules(context.Background(), []string{first, second}, nil)
	items, _ := result["items"].([]prepareModuleResult)
	tokens := map[string]bool{}
	for _, item := range items {
		if item.Info != nil {
			if tokens[item.Info.Token] {
				t.Fatal("批量暂存出现了重复 token")
			}
			tokens[item.Info.Token] = true
			if _, err := os.Stat(filepath.Join(engine.cacheDirectory, modulePackageFolder, item.Info.Token+".zip")); err != nil {
				t.Fatalf("token %s 的暂存文件不存在", item.Info.Token)
			}
		}
	}
	if len(tokens) != 2 {
		t.Fatalf("应有 2 个不同 token，实际 %d", len(tokens))
	}
}

func TestExportModulesRoundTrip(t *testing.T) {
	engine := newBatchEngine(t)
	t.Cleanup(func() { Unregister("alpha"); Unregister("beta") })
	dir := t.TempDir()
	first := filepath.Join(dir, "alpha.zip")
	second := filepath.Join(dir, "beta.zip")
	_ = os.WriteFile(first, moduleZip(t, "alpha", "1.0.0", ""), 0o600)
	_ = os.WriteFile(second, moduleZip(t, "beta", "1.0.0", ""), 0o600)

	for _, file := range []string{first, second} {
		info, err := engine.prepareModule(context.Background(), file, "", "", false)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := engine.installModule(info.Token); err != nil {
			t.Fatal(err)
		}
	}

	result, err := engine.exportModules(nil)
	if err != nil {
		t.Fatal(err)
	}
	if count, _ := result["count"].(int); count != 2 {
		t.Fatalf("应导出 2 个模块，实际 %v", result["count"])
	}
	content, _ := result["content"].(string)
	if content == "" {
		t.Fatal("导出内容为空")
	}
}

func TestExportModulesSelectedOnly(t *testing.T) {
	engine := newBatchEngine(t)
	t.Cleanup(func() { Unregister("alpha"); Unregister("beta") })
	dir := t.TempDir()
	for _, id := range []string{"alpha", "beta"} {
		file := filepath.Join(dir, id+".zip")
		_ = os.WriteFile(file, moduleZip(t, id, "1.0.0", ""), 0o600)
		info, err := engine.prepareModule(context.Background(), file, "", "", false)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := engine.installModule(info.Token); err != nil {
			t.Fatal(err)
		}
	}
	result, err := engine.exportModules([]string{"beta"})
	if err != nil {
		t.Fatal(err)
	}
	if count, _ := result["count"].(int); count != 1 {
		t.Fatalf("只导出 1 个，实际 %v", result["count"])
	}
	names, _ := result["names"].([]string)
	if len(names) != 1 || names[0] != "beta" {
		t.Fatalf("导出名单不对: %v", names)
	}
}

// folderBundleZip 把若干模块以「每个模块一个子目录、目录里直接放 manifest 与
// main.js」的布局打成一个合集包，模拟软件早期版本的导出格式。
func folderBundleZip(t *testing.T, ids []string) []byte {
	t.Helper()
	var buffer bytes.Buffer
	archive := zip.NewWriter(&buffer)
	manifest := `{"id":"ID","name":"ID","version":"1.0.0","description":"","runtime":"js","api":1,"adult":false,"hosts":[]}`
	code := `module.exports={categories:function(){return [];},catalogPage:function(){return {items:[]};},detail:function(){return {drama:{},chapters:[]};},resolveMedia:function(){return {url:""};}};`
	for _, id := range ids {
		w, err := archive.Create(id + "/" + moduleManifest)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := w.Write([]byte(strings.ReplaceAll(manifest, "ID", id))); err != nil {
			t.Fatal(err)
		}
		w, err = archive.Create(id + "/" + moduleEntry)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := w.Write([]byte(code)); err != nil {
			t.Fatal(err)
		}
	}
	if err := archive.Close(); err != nil {
		t.Fatal(err)
	}
	return buffer.Bytes()
}

func TestExpandModulePackageFolderLayout(t *testing.T) {
	// 早期版本导出的合集：每个模块占一个子目录，也要能展开。
	bundle := folderBundleZip(t, []string{"alpha", "beta"})
	items, err := expandModulePackage("legacy.zip", bundle, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 2 {
		t.Fatalf("子目录式合集应展开成 2 份，得到 %d", len(items))
	}
	for _, item := range items {
		module, err := unpackModule(item.raw)
		if err != nil {
			t.Fatalf("子目录重组后的模块包无效: %v", err)
		}
		if module.manifest.ID == "" {
			t.Fatal("重组后的模块缺少标识")
		}
	}
}

func TestExportModulesImportRoundTrip(t *testing.T) {
	// 导出 → 重新导入要能完整闭环：每个模块都变成可安装的独立包。
	engine := newBatchEngine(t)
	t.Cleanup(func() { Unregister("alpha"); Unregister("beta") })
	dir := t.TempDir()
	for _, id := range []string{"alpha", "beta"} {
		file := filepath.Join(dir, id+".zip")
		_ = os.WriteFile(file, moduleZip(t, id, "1.0.0", ""), 0o600)
		info, err := engine.prepareModule(context.Background(), file, "", "", false)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := engine.installModule(info.Token); err != nil {
			t.Fatal(err)
		}
	}
	result, err := engine.exportModules(nil)
	if err != nil {
		t.Fatal(err)
	}
	content, _ := result["content"].(string)
	raw, err := base64.StdEncoding.DecodeString(content)
	if err != nil {
		t.Fatal(err)
	}
	// 走与「从文件导入」完全相同的展开入口。
	items, err := expandModulePackage("exported.zip", raw, 0)
	if err != nil {
		t.Fatalf("软件导出的合集包应能被自己识别: %v", err)
	}
	if len(items) != 2 {
		t.Fatalf("导出的合集应展开成 2 份，得到 %d", len(items))
	}
	ids := map[string]bool{}
	for _, item := range items {
		module, err := unpackModule(item.raw)
		if err != nil {
			t.Fatalf("导出的子包无效: %v", err)
		}
		ids[module.manifest.ID] = true
	}
	if !ids["alpha"] || !ids["beta"] {
		t.Fatalf("导出丢失模块: %v", ids)
	}
}

func TestResetModulesRestoresBundled(t *testing.T) {
	engine := newBatchEngine(t)
	t.Cleanup(func() { Unregister("alpha") })
	// 用示例模块当「内置」，验证恢复默认后会重新装回来。
	example := filepath.Join("..", "module_example", "jsexample")
	manifest, err := os.ReadFile(filepath.Join(example, moduleManifest))
	if err != nil {
		t.Fatal(err)
	}
	code, err := os.ReadFile(filepath.Join(example, moduleEntry))
	if err != nil {
		t.Fatal(err)
	}
	previous := bundledModules
	bundledModules = fstest.MapFS{
		"jsexample/" + moduleManifest: {Data: manifest},
		"jsexample/" + moduleEntry:    {Data: code},
	}
	t.Cleanup(func() { bundledModules = previous })

	// 先装一个用户模块，再装内置模块后手动移除，模拟真实使用。
	dir := t.TempDir()
	file := filepath.Join(dir, "alpha.zip")
	_ = os.WriteFile(file, moduleZip(t, "alpha", "1.0.0", ""), 0o600)
	info, err := engine.prepareModule(context.Background(), file, "", "", false)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := engine.installModule(info.Token); err != nil {
		t.Fatal(err)
	}
	engine.downloader.loadModules()
	if !isBundledModule("jsexample") {
		t.Fatal("内置模块表没有生效")
	}

	if _, err := engine.uninstallModule("jsexample"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(engine.downloader.moduleRoot(), "jsexample")); !os.IsNotExist(err) {
		t.Fatal("内置模块应已移除")
	}

	result, err := engine.resetModules()
	if err != nil {
		t.Fatal(err)
	}
	removed, _ := result["removed"].([]string)
	if len(removed) == 0 {
		t.Fatal("恢复默认应记录被删除的模块")
	}
	// 用户模块被删掉，内置模块被装回来。
	if _, err := os.Stat(filepath.Join(engine.downloader.moduleRoot(), "alpha")); !os.IsNotExist(err) {
		t.Fatal("用户安装的模块应被删除")
	}
	if _, err := os.Stat(filepath.Join(engine.downloader.moduleRoot(), "jsexample")); err != nil {
		t.Fatal("内置模块应被恢复")
	}
	if _, err := os.Stat(filepath.Join(engine.downloader.moduleRoot(), bundledRemovedFile)); !os.IsNotExist(err) {
		t.Fatal("恢复默认后不应保留「已移除」记录")
	}
}

func TestUninstallModulesReportsFailures(t *testing.T) {
	engine := newBatchEngine(t)
	t.Cleanup(func() { Unregister("alpha") })
	dir := t.TempDir()
	file := filepath.Join(dir, "alpha.zip")
	_ = os.WriteFile(file, moduleZip(t, "alpha", "1.0.0", ""), 0o600)
	info, err := engine.prepareModule(context.Background(), file, "", "", false)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := engine.installModule(info.Token); err != nil {
		t.Fatal(err)
	}
	result, err := engine.uninstallModules([]string{"alpha", "..", "not-installed"})
	if err != nil {
		t.Fatal(err)
	}
	removed, _ := result["removed"].([]string)
	failures, _ := result["failures"].([]string)
	if len(removed) != 1 || removed[0] != "alpha" {
		t.Fatalf("应卸载 alpha，实际 %v", removed)
	}
	// ".." 是非法标识，"not-installed" 没装过，两者都要如实报失败。
	if len(failures) != 2 {
		t.Fatalf("应报告 2 个失败，实际 %v", failures)
	}
	joined := strings.Join(failures, " ")
	if !strings.Contains(joined, "..") || !strings.Contains(joined, "not-installed") {
		t.Fatalf("失败原因不完整: %v", failures)
	}
}

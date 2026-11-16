package core

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

// 「删除全部数据」要把下载目录、缓存与数据目录一起清掉，并且不动下载目录
// 的父目录（下载位置可能是用户指定的任意路径，甚至 SD 卡上的目录）。
func TestDeleteAllDataWipesAppDirectoriesOnly(t *testing.T) {
	data := t.TempDir()
	engine, err := newNativeEngine(data)
	if err != nil {
		t.Fatal(err)
	}
	// 模拟用户把下载目录改到了数据目录之外（例如另一个盘）。
	outsideRoot := t.TempDir()
	engine.downloads.mu.Lock()
	engine.downloads.root = filepath.Join(outsideRoot, "downloads")
	engine.downloads.mu.Unlock()

	write := func(root, relative string, size int) string {
		path := filepath.Join(root, relative)
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, bytes.Repeat([]byte{'x'}, size), 0o600); err != nil {
			t.Fatal(err)
		}
		return path
	}
	// 数据目录里的设置与模块、缓存目录里的封面、下载目录里的成片。
	write(engine.directory, "settings.json", 64)
	write(engine.directory, filepath.Join("modules", "demo", "main.js"), 32)
	write(engine.directory, filepath.Join(coverCacheDirNameV1, "cover.img"), 128)
	download := write(engine.downloads.root, filepath.Join("drama", "media.mp4"), 256)
	// 下载目录的父目录放一个用户文件：删除只能清下载目录本身，不能向上扩散。
	outside := write(outsideRoot, "user-file.txt", 16)

	leftover, err := engine.deleteAllData("")
	if err != nil {
		t.Fatalf("删除全部数据失败：%v", err)
	}
	if len(leftover) != 0 {
		t.Fatalf("不该有残留，得到 %v", leftover)
	}
	if _, err := os.Stat(download); !os.IsNotExist(err) {
		t.Fatal("下载内容没有被删除")
	}
	if _, err := os.Stat(engine.downloads.root); !os.IsNotExist(err) {
		t.Fatal("下载目录本身没有被删除")
	}
	if _, err := os.Stat(filepath.Join(engine.directory, "settings.json")); !os.IsNotExist(err) {
		t.Fatal("数据目录里的设置没有被删除")
	}
	if _, err := os.Stat(outside); err != nil {
		t.Fatal("下载目录的父目录被误删")
	}
}

// 存储用量要把缓存算进去：否则「清理缓存」前后数字不变，用户会以为没生效。
func TestStorageIncludesCacheBytes(t *testing.T) {
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	cover := filepath.Join(engine.directory, coverCacheDirNameV1, "cover.img")
	if err := os.MkdirAll(filepath.Dir(cover), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(cover, bytes.Repeat([]byte{'x'}, 4096), 0o600); err != nil {
		t.Fatal(err)
	}
	before, err := engine.storage("")
	if err != nil {
		t.Fatal(err)
	}
	if before.Cache != 4096 {
		t.Fatalf("缓存用量应为 4096，得到 %d", before.Cache)
	}
	if before.Bytes < before.Cache {
		t.Fatalf("总用量没有包含缓存：总量 %d，缓存 %d", before.Bytes, before.Cache)
	}
	if _, err := engine.clearCache(""); err != nil {
		t.Fatal(err)
	}
	after, err := engine.storage("")
	if err != nil {
		t.Fatal(err)
	}
	if after.Cache != 0 {
		t.Fatalf("清理后缓存应归零，得到 %d", after.Cache)
	}
	if before.Bytes-after.Bytes != 4096 {
		t.Fatalf("清理释放的字节数对不上：清理前 %d，清理后 %d", before.Bytes, after.Bytes)
	}
}

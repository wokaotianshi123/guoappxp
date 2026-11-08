package core

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestClearCacheOnlyRemovesRegenerableFiles(t *testing.T) {
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	write := func(relative string, size int) string {
		path := filepath.Join(engine.directory, relative)
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, bytes.Repeat([]byte{'x'}, size), 0o600); err != nil {
			t.Fatal(err)
		}
		return path
	}
	magnet := write(filepath.Join("magnet-cache", "piece.bin"), 1024)
	playback := write(filepath.Join("playback-cache", "clip.ts"), 512)
	temp := write(filepath.Join("downloads", ".download-write-abc"), 256)
	keep := write("catalog-cache.json", 128)
	old := time.Now().Add(-2 * time.Hour)
	if err := os.Chtimes(temp, old, old); err != nil {
		t.Fatal(err)
	}
	// 30 分钟内的临时文件属于正在进行的下载，不能删。
	fresh := write(filepath.Join("downloads", ".convert-active.tmp"), 64)
	// 断点续传分片与已下载的 HLS 分片不是缓存，任何时候都不能删。
	resume := write(filepath.Join("downloads", "episode.mp4.part"), 777)
	segment := write(filepath.Join("downloads", "hls", "segment.ts"), 333)
	for _, path := range []string{resume, segment} {
		if err := os.Chtimes(path, old, old); err != nil {
			t.Fatal(err)
		}
	}

	info := engine.cacheInfo("")
	if info.Bytes != 1024+512+256 {
		t.Fatalf("可清理缓存 = %d 字节，期望 1792：%+v", info.Bytes, info)
	}
	if info.MagnetBytes != 1024 || info.PlaybackBytes != 512 || info.TempBytes != 256 {
		t.Fatalf("缓存分类统计错误: %+v", info)
	}

	result, err := engine.clearCache("")
	if err != nil {
		t.Fatal(err)
	}
	if result.ClearedBytes != info.Bytes || result.ClearedFiles != 3 {
		t.Fatalf("实际清理 = %d 字节 / %d 文件：%+v", result.ClearedBytes, result.ClearedFiles, result)
	}
	if result.Bytes != 0 {
		t.Fatalf("清理后仍有 %d 字节缓存", result.Bytes)
	}
	for _, path := range []string{magnet, playback, temp} {
		if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("缓存文件未被删除: %s (%v)", path, err)
		}
	}
	for _, path := range []string{keep, fresh, resume, segment} {
		if _, err := os.Stat(path); err != nil {
			t.Fatalf("不该删除的文件被清理: %s (%v)", path, err)
		}
	}
}

func TestNativeCacheExtraDirectoryRejectsSystemPaths(t *testing.T) {
	base := t.TempDir()
	for _, path := range []string{"", "/", "/tmp", "/var/tmp", base, "relative/cache", os.TempDir()} {
		if got := nativeCacheExtraDirectory(path, base); got != "" {
			t.Fatalf("危险路径 %q 被接受为缓存目录: %s", path, got)
		}
	}
	cache := filepath.Join(base, "cache")
	if got := nativeCacheExtraDirectory(cache, base); got != filepath.Clean(cache) {
		t.Fatalf("应用私有 cache 目录未被接受: %s", got)
	}
}

func TestClearCacheIncludesPlayerCacheDirectory(t *testing.T) {
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	cache := filepath.Join(engine.directory, "cache")
	player := filepath.Join(cache, "media-kit", "buffer.m4s")
	if err := os.MkdirAll(filepath.Dir(player), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(player, bytes.Repeat([]byte{'x'}, 300), 0o600); err != nil {
		t.Fatal(err)
	}
	if info := engine.cacheInfo(cache); info.PlaybackBytes != 300 {
		t.Fatalf("播放器缓存未被统计: %+v", info)
	}
	result, err := engine.clearCache(cache)
	if err != nil {
		t.Fatal(err)
	}
	if result.ClearedBytes != 300 {
		t.Fatalf("播放器缓存未被清理: %+v", result)
	}
	if _, err := os.Stat(player); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("播放器缓存仍在: %v", err)
	}
}

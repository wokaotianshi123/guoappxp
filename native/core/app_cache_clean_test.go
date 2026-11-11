package core

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
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
	if info.Bytes != 512+256 {
		t.Fatalf("可清理缓存 = %d 字节，期望 768：%+v", info.Bytes, info)
	}
	if info.PlaybackBytes != 512 || info.TempBytes != 256 {
		t.Fatalf("缓存分类统计错误: %+v", info)
	}

	result, err := engine.clearCache("")
	if err != nil {
		t.Fatal(err)
	}
	if result.ClearedBytes != info.Bytes || result.ClearedFiles != 2 {
		t.Fatalf("实际清理 = %d 字节 / %d 文件：%+v", result.ClearedBytes, result.ClearedFiles, result)
	}
	if result.Bytes != 0 {
		t.Fatalf("清理后仍有 %d 字节缓存", result.Bytes)
	}
	for _, path := range []string{playback, temp} {
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

func TestClearCacheRemovesAppGeneratedCaches(t *testing.T) {
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
	// 封面 / 目录 / 日志都是应用自己生成、随时可以再生的缓存。
	coverKey := strings.Repeat("a", 64)
	cover := write(filepath.Join(coverCacheDirNameV1, coverKey+".img"), 1024)
	// App 端把 HEIC 转成 JPEG 后另存的一份同样属于封面缓存。
	converted := write(filepath.Join(coverCacheDirNameV1, "compatible-v1", coverKey+"-1-1.jpg"), 512)
	// 封面目录里的临时文件不按封面处理，交给临时文件规则。
	coverTemp := write(filepath.Join(coverCacheDirNameV1, ".cache-write-cover"), 256)
	old := time.Now().Add(-2 * time.Hour)
	if err := os.Chtimes(coverTemp, old, old); err != nil {
		t.Fatal(err)
	}
	catalog := write(catalogCacheName, 512)
	logFile := write(filepath.Join(logCacheDirName, "app.log"), 300)
	// 轮转出来的 app.log.1 同样是日志缓存。
	rotatedLog := write(filepath.Join(logCacheDirName, "app.log.1"), 64)
	// 设置、听书离线内容与已下载视频不是缓存。
	settings := write("shared_preferences.json", 400)
	sources := write("sources.json", 80)
	audio := write(filepath.Join("audiobooks", "default", "audio", "chapter.m4a"), 2048)
	download := write(filepath.Join("downloads", "episode.mp4"), 4096)
	// 封面缓存对象在引擎初始化时扫过一次目录，这里手动重建索引，
	// 让后面的断言能确认清理会把内存索引一起更新。
	engine.covers.refresh()
	if len(engine.covers.entries) != 1 || engine.covers.size != 1024 {
		t.Fatalf("封面索引重建失败: %d 条 / %d 字节", len(engine.covers.entries), engine.covers.size)
	}

	info := engine.cacheInfo("")
	if info.CoverBytes != 1536 || info.CatalogBytes != 512 || info.LogBytes != 364 || info.TempBytes != 256 {
		t.Fatalf("应用缓存分类统计错误: %+v", info)
	}
	if info.Bytes != 1536+512+364+256 || info.Files != 6 {
		t.Fatalf("可清理缓存 = %d 字节 / %d 文件：%+v", info.Bytes, info.Files, info)
	}

	result, err := engine.clearCache("")
	if err != nil {
		t.Fatal(err)
	}
	if result.ClearedBytes != info.Bytes || result.ClearedFiles != info.Files {
		t.Fatalf("实际清理 = %d 字节 / %d 文件：%+v", result.ClearedBytes, result.ClearedFiles, result)
	}
	if result.Bytes != 0 || result.CoverBytes != 0 || result.CatalogBytes != 0 || result.LogBytes != 0 {
		t.Fatalf("清理后仍有缓存: %+v", result)
	}
	for _, path := range []string{cover, converted, coverTemp, catalog, logFile, rotatedLog} {
		if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("缓存文件未被删除: %s (%v)", path, err)
		}
	}
	for _, path := range []string{settings, sources, audio, download} {
		if _, err := os.Stat(path); err != nil {
			t.Fatalf("不该删除的文件被清理: %s (%v)", path, err)
		}
	}
	// 封面索引必须跟着磁盘走，否则下次取封面会拿到已删除的路径。
	if len(engine.covers.entries) != 0 || engine.covers.size != 0 {
		t.Fatalf("封面索引没有随清理更新: %d 条 / %d 字节", len(engine.covers.entries), engine.covers.size)
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

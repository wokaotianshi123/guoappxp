package core

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// 「清理缓存」只处理应用自己生成、随时可以再生的缓存：播放缓存、封面缓存、
// 目录缓存、日志和临时文件。剧库、设置、追剧、观看记录、会话凭据、
// 已完成的下载与听书离线音频一律不动。
const (
	playbackCacheDirName = "playback-cache"
	coverCacheDirNameV1  = "covers-v1"
	catalogCacheName     = "catalogs.json"
	logCacheDirName      = "logs"
)

// 播放器（media_kit / libmpv / ExoPlayer 系）在应用 cache 目录里常用的复用名。
// 只按名字白名单进入，不整目录递归删除应用 cache。
var playbackCacheSubdirs = []string{
	"media-kit", "media_kit", "mpv", "exoplayer", "video_cache",
	"videocache", "playback-cache", "SimpleCache",
}

type nativeCacheInfo struct {
	Bytes         int64  `json:"bytes"`
	Files         int64  `json:"files"`
	PlaybackBytes int64  `json:"playbackBytes"`
	CoverBytes    int64  `json:"coverBytes"`
	CatalogBytes  int64  `json:"catalogBytes"`
	LogBytes      int64  `json:"logBytes"`
	TempBytes     int64  `json:"tempBytes"`
	ClearedBytes  int64  `json:"clearedBytes"`
	ClearedFiles  int64  `json:"clearedFiles"`
	Warning       string `json:"warning,omitempty"`
}

type nativeCacheFile struct {
	path string
	size int64
	kind string
}

// nativeCacheExtraDirectory 校验 Dart 传进来的临时/缓存目录。
// 只接受应用私有的 cache/Caches/tmp 目录；根目录、系统 /tmp、数据目录本身
// 全部拒绝，避免把「清理缓存」变成误删用户文件。
func nativeCacheExtraDirectory(path, dataDir string) string {
	path = strings.TrimSpace(path)
	if path == "" || !filepath.IsAbs(path) {
		return ""
	}
	clean := filepath.Clean(path)
	if clean == filepath.Clean(dataDir) || clean == filepath.Clean(os.TempDir()) ||
		strings.Count(clean, string(filepath.Separator)) < 2 {
		return ""
	}
	switch strings.ToLower(filepath.Base(clean)) {
	case "cache", "caches", "tmp", "temp":
		return clean
	default:
		return ""
	}
}

// nativeCacheTempName 只认应用自己写出的临时文件前缀。
// 下载目录里的 *.part / *.ts / *.m4s 是断点续传分片和已下载内容，
// 绝不能按后缀删，否则会破坏未完成的下载与离线视频。
func nativeCacheTempName(name string) bool {
	if strings.HasPrefix(name, ".download-write-") ||
		strings.HasPrefix(name, ".convert-") ||
		strings.HasPrefix(name, ".decode-") ||
		strings.HasPrefix(name, ".cache-write-") ||
		strings.HasPrefix(name, ".write-test-") {
		return true
	}
	for _, prefix := range []string{".jinguo-session-", ".huangguo-session-", ".sorani-"} {
		if strings.HasPrefix(name, prefix) && strings.HasSuffix(name, ".tmp") {
			return true
		}
	}
	return false
}

// nativeCacheMediaTempName 仅用于应用 cache 目录根下的播放器临时文件。
func nativeCacheMediaTempName(name string) bool {
	lower := strings.ToLower(name)
	for _, suffix := range []string{".tmp", ".part", ".m4s", ".ts", ".m3u8"} {
		if strings.HasSuffix(lower, suffix) {
			return true
		}
	}
	return false
}

// nativeCacheCoverName 只认封面缓存正文：封面写入走临时文件 + 原子改名，
// 所以 *.img 一定是写完整的；同目录下的 .decode-* / .cache-write-* 不动。
// compatible-v1 是 App 端把 HEIC 等格式转成 JPEG 后另存的一份，同样可再生。
func nativeCacheCoverName(path string) bool {
	base := filepath.Base(path)
	if strings.HasPrefix(base, ".") {
		return false
	}
	switch strings.ToLower(filepath.Ext(base)) {
	case ".img":
		return true
	case ".jpg":
		return strings.Contains(filepath.ToSlash(path), "/compatible-v1/")
	default:
		return false
	}
}

// nativeCacheLogName 只认日志文件（app.log / native_stderr.log / crash.log）。
// 日志不属于用户数据，删掉只会少一份排查材料。轮转出来的 app.log.1 也要算上。
func nativeCacheLogName(name string) bool {
	lower := strings.ToLower(name)
	if strings.HasSuffix(lower, ".log") {
		return true
	}
	return strings.HasPrefix(lower, "app.log.") || strings.HasPrefix(lower, "native_stderr.log.")
}

// nativeCacheFiles 收集当前可清理的缓存文件。临时文件只挑 30 分钟前的，
// 不碰正在写入的下载分片和正在播放的转码中间文件。
func (engine *nativeEngine) nativeCacheFiles(extra string) []nativeCacheFile {
	playbackDir := filepath.Join(engine.directory, playbackCacheDirName)
	seen := map[string]bool{}
	var out []nativeCacheFile
	add := func(path string, size int64, kind string) {
		if seen[path] {
			return
		}
		seen[path] = true
		out = append(out, nativeCacheFile{path: path, size: size, kind: kind})
	}
	collectDir := func(dir, kind string) {
		_ = filepath.WalkDir(dir, func(path string, entry fs.DirEntry, err error) error {
			if err != nil {
				return nil
			}
			if entry.Type()&os.ModeSymlink != 0 {
				if entry.IsDir() {
					return fs.SkipDir
				}
				return nil
			}
			if entry.IsDir() {
				return nil
			}
			if info, err := entry.Info(); err == nil && info.Mode().IsRegular() {
				add(path, info.Size(), kind)
			}
			return nil
		})
	}
	collectMatched := func(dir string, match func(string) bool, kind string) {
		_ = filepath.WalkDir(dir, func(path string, entry fs.DirEntry, err error) error {
			if err != nil {
				return nil
			}
			if entry.Type()&os.ModeSymlink != 0 {
				if entry.IsDir() {
					return fs.SkipDir
				}
				return nil
			}
			if entry.IsDir() {
				return nil
			}
			if !match(path) {
				return nil
			}
			if info, err := entry.Info(); err == nil && info.Mode().IsRegular() {
				add(path, info.Size(), kind)
			}
			return nil
		})
	}
	collectTemp := func(root string, onlyRoot, mediaSuffixes bool) {
		_ = filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
			if err != nil {
				return nil
			}
			if entry.IsDir() {
				if path == root {
					return nil
				}
				if onlyRoot || path == playbackDir {
					return fs.SkipDir
				}
				return nil
			}
			removable := nativeCacheTempName(entry.Name())
			if mediaSuffixes && !removable {
				removable = nativeCacheMediaTempName(entry.Name())
			}
			if entry.Type()&os.ModeSymlink != 0 || !removable {
				return nil
			}
			info, err := entry.Info()
			if err != nil || !info.Mode().IsRegular() || time.Since(info.ModTime()) < 30*time.Minute {
				return nil
			}
			add(path, info.Size(), "temp")
			return nil
		})
	}
	collectDir(playbackDir, "playback")
	// 封面缓存是应用自己下载的图片，删掉只会让下次浏览重新取一遍。
	collectMatched(filepath.Join(engine.directory, coverCacheDirNameV1), nativeCacheCoverName, "cover")
	// 目录缓存（榜单 / 分类 / 推荐）同样可再生；内存里的目录不受影响。
	if info, err := os.Stat(filepath.Join(engine.directory, catalogCacheName)); err == nil && info.Mode().IsRegular() {
		add(filepath.Join(engine.directory, catalogCacheName), info.Size(), "catalog")
	}
	collectMatched(filepath.Join(engine.directory, logCacheDirName),
		func(path string) bool { return nativeCacheLogName(filepath.Base(path)) }, "log")
	collectTemp(engine.directory, false, false)
	if cache := nativeCacheExtraDirectory(extra, engine.directory); cache != "" {
		for _, name := range playbackCacheSubdirs {
			collectDir(filepath.Join(cache, name), "playback")
		}
		collectTemp(cache, true, true)
	}
	return out
}

func nativeCacheTotals(files []nativeCacheFile) nativeCacheInfo {
	var info nativeCacheInfo
	for _, file := range files {
		info.Bytes += file.size
		info.Files++
		switch file.kind {
		case "playback":
			info.PlaybackBytes += file.size
		case "cover":
			info.CoverBytes += file.size
		case "catalog":
			info.CatalogBytes += file.size
		case "log":
			info.LogBytes += file.size
		default:
			info.TempBytes += file.size
		}
	}
	return info
}

// nativePruneEmptyDirs 只删空的缓存子目录，保留根缓存目录本身。
func nativePruneEmptyDirs(dir string) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	for _, entry := range entries {
		if entry.IsDir() {
			nativePruneEmptyDirs(filepath.Join(dir, entry.Name()))
		}
	}
	remaining, err := os.ReadDir(dir)
	if err == nil && len(remaining) == 0 {
		_ = os.Remove(dir)
	}
}

// nativeClearLogFile 先尝试删除；日志正被写入（Windows 上句柄占用）时退化成清空。
// 返回是否真的释放了内容。
func nativeClearLogFile(path string) bool {
	if err := os.Remove(path); err == nil || errors.Is(err, os.ErrNotExist) {
		return true
	}
	// 清空后文件还在，但原内容已经释放，尺寸仍按清理前的值计。
	return os.Truncate(path, 0) == nil
}

func (engine *nativeEngine) cacheInfo(extra string) nativeCacheInfo {
	return nativeCacheTotals(engine.nativeCacheFiles(extra))
}

// clearCache 先关掉正在写的缓存句柄（封面走原子改名，无需等待），
// 再逐个删除白名单缓存文件。被进程占用的文件会跳过并给出提示，其余照常清理。
func (engine *nativeEngine) clearCache(extra string) (nativeCacheInfo, error) {
	files := engine.nativeCacheFiles(extra)
	info := nativeCacheInfo{}
	failed := 0
	clearedCover := false
	for _, file := range files {
		var cleared bool
		if file.kind == "log" {
			cleared = nativeClearLogFile(file.path)
		} else {
			err := os.Remove(file.path)
			cleared = err == nil || errors.Is(err, os.ErrNotExist)
		}
		if !cleared {
			failed++
			continue
		}
		if file.kind == "cover" {
			clearedCover = true
		}
		info.ClearedBytes += file.size
		info.ClearedFiles++
	}
	// 封面索引在内存里记着文件名与尺寸：清完必须跟着磁盘重扫，
	// 否则下次取封面会以为本地还有文件，直接返回一个不存在的路径。
	if clearedCover && engine.covers != nil {
		engine.covers.refresh()
	}
	nativePruneEmptyDirs(filepath.Join(engine.directory, playbackCacheDirName))
	remaining := nativeCacheTotals(engine.nativeCacheFiles(extra))
	info.Bytes, info.Files = remaining.Bytes, remaining.Files
	info.PlaybackBytes, info.TempBytes = remaining.PlaybackBytes, remaining.TempBytes
	info.CoverBytes, info.CatalogBytes, info.LogBytes = remaining.CoverBytes, remaining.CatalogBytes, remaining.LogBytes
	if failed > 0 {
		info.Warning = fmt.Sprintf("%d 个文件正在使用中，未能删除；关闭播放或下载后可再清理一次", failed)
	}
	return info, nil
}

package main

import (
	"encoding/json"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
)

// 本地服务版没有 Flutter 的「应用 cache 目录」，但转码产物落在系统临时目录下的
// duanjuweb-<slug>-live；顶栏「清理缓存」只问核心的话永远统计不到这部分，
// 表现为「0 B、没有需要清理的缓存」。这里把转码临时目录并进核心的统计结果。

// transcodeCacheRoot 是转码任务目录的根（每个 job 一个子目录）。
func transcodeCacheRoot() string {
	return filepath.Join(os.TempDir(), "duanjuweb-"+editionSlug+"-live")
}

// activeTranscodeDirs 返回仍在播放/转码中的任务目录，清理时必须跳过。
func activeTranscodeDirs() map[string]bool {
	active := map[string]bool{}
	transcoder.mu.Lock()
	defer transcoder.mu.Unlock()
	for key, job := range transcoder.jobs {
		if job != nil {
			active[filepath.Join(transcodeCacheRoot(), key)] = true
		}
	}
	return active
}

// transcodeCacheFiles 列出可回收的转码缓存文件（跳过正在使用的任务目录）。
func transcodeCacheFiles() (bytes, files int64) {
	active := activeTranscodeDirs()
	root := transcodeCacheRoot()
	_ = filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if entry.IsDir() {
			if active[path] {
				return fs.SkipDir
			}
			return nil
		}
		if entry.Type()&os.ModeSymlink != 0 {
			return nil
		}
		if info, err := entry.Info(); err == nil && info.Mode().IsRegular() {
			bytes += info.Size()
			files++
		}
		return nil
	})
	return bytes, files
}

// clearTranscodeCache 删除不在使用中的转码任务目录，返回释放的字节与文件数。
func clearTranscodeCache() (bytes, files int64, failed int) {
	active := activeTranscodeDirs()
	root := transcodeCacheRoot()
	entries, err := os.ReadDir(root)
	if err != nil {
		return 0, 0, 0
	}
	for _, entry := range entries {
		dir := filepath.Join(root, entry.Name())
		if active[dir] {
			continue
		}
		// 先统计大小，再整目录删除；删失败就不计入释放量。
		var dirBytes, dirFiles int64
		_ = filepath.WalkDir(dir, func(path string, item fs.DirEntry, err error) error {
			if err != nil {
				return nil
			}
			if item.IsDir() || item.Type()&os.ModeSymlink != 0 {
				return nil
			}
			if info, err := item.Info(); err == nil && info.Mode().IsRegular() {
				dirBytes += info.Size()
				dirFiles++
			}
			return nil
		})
		if err := os.RemoveAll(dir); err != nil {
			failed++
			continue
		}
		bytes += dirBytes
		files += dirFiles
	}
	return bytes, files, failed
}

// cacheNumber 读取核心返回里的数字（JSON 解出来是 float64）。
func cacheNumber(value any) int64 {
	switch typed := value.(type) {
	case float64:
		return int64(typed)
	case json.Number:
		number, err := typed.Int64()
		if err != nil {
			return 0
		}
		return number
	case int64:
		return typed
	case int:
		return int64(typed)
	case string:
		number, err := strconv.ParseInt(typed, 10, 64)
		if err != nil {
			return 0
		}
		return number
	}
	return 0
}

// mergeTranscodeCache 把转码临时目录的统计/清理结果并进核心的缓存回包。
func mergeTranscodeCache(reply string, clear bool) string {
	var envelope map[string]any
	if json.Unmarshal([]byte(reply), &envelope) != nil || envelope["ok"] != true {
		return reply
	}
	data, _ := envelope["data"].(map[string]any)
	if data == nil {
		return reply
	}
	warning := ""
	if clear {
		clearedBytes, clearedFiles, failed := clearTranscodeCache()
		if clearedBytes > 0 || clearedFiles > 0 {
			data["clearedBytes"] = cacheNumber(data["clearedBytes"]) + clearedBytes
			data["clearedFiles"] = cacheNumber(data["clearedFiles"]) + clearedFiles
		}
		if failed > 0 {
			warning = "部分转码目录正在使用中，未能删除"
		}
	}
	remainingBytes, remainingFiles := transcodeCacheFiles()
	if remainingBytes > 0 || remainingFiles > 0 {
		data["bytes"] = cacheNumber(data["bytes"]) + remainingBytes
		data["files"] = cacheNumber(data["files"]) + remainingFiles
		data["tempBytes"] = cacheNumber(data["tempBytes"]) + remainingBytes
	}
	// 清理完仍有文件没删掉时，把原有提示和转码目录的提示合并，别覆盖核心的说明。
	if warning != "" {
		if existing, ok := data["warning"].(string); ok && existing != "" {
			warning = existing + "；" + warning
		}
		data["warning"] = warning
	}
	encoded, err := json.Marshal(envelope)
	if err != nil {
		return reply
	}
	return string(encoded)
}

package core

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
)

type nativeStorageInfo struct {
	Directory string `json:"directory"`
	Bytes     int64  `json:"bytes"`
	Free      int64  `json:"free"`
	Files     int    `json:"files"`
}

func (engine *nativeEngine) storage() (nativeStorageInfo, error) {
	manager := engine.downloads
	manager.mu.Lock()
	root := manager.root
	manager.mu.Unlock()
	info := nativeStorageInfo{Directory: root}
	err := filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.Type()&os.ModeSymlink != 0 {
			return nil
		}
		if !entry.IsDir() {
			if stat, err := entry.Info(); err == nil {
				info.Bytes += stat.Size()
				info.Files++
			}
		}
		return nil
	})
	if err != nil {
		return info, errors.New("无法读取下载目录，请检查存储设备")
	}
	info.Free = nativeFreeSpace(root)
	return info, nil
}

func nativeDownloadLocation(directory string) string {
	var value struct {
		Directory string `json:"directory"`
	}
	body, _ := os.ReadFile(filepath.Join(directory, "download-location.json"))
	if json.Unmarshal(body, &value) == nil && filepath.IsAbs(value.Directory) {
		return filepath.Clean(value.Directory)
	}
	return filepath.Join(directory, "downloads")
}

// nativeCanonicalPath 把路径解析成可相互比较的形式。Windows 上临时目录常以
// 8.3 短名（如 ADMINI~1）返回，而 EvalSymlinks 会还原成长名；两者混用时
// filepath.Rel 会算出跨目录的 ".." 前缀，使包含关系判定失效。
func nativeCanonicalPath(path string) string {
	if resolved, err := filepath.EvalSymlinks(path); err == nil {
		return filepath.Clean(resolved)
	}
	return filepath.Clean(path)
}

func nativeCopyTree(ctx context.Context, source, target string) error {
	source = nativeCanonicalPath(source)
	target = nativeCanonicalPath(target)
	// 目标若落在源目录内，遍历过程中不断创建子目录会形成无限递归，必须提前拒绝。
	if nativePathsOverlap(source, target) {
		return errors.New("目标目录不能位于待迁移目录内部")
	}
	return filepath.WalkDir(source, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		if path == target {
			return filepath.SkipDir
		}
		if entry.Type()&os.ModeSymlink != 0 {
			return errors.New("下载目录中包含符号链接，无法迁移")
		}
		relative, err := filepath.Rel(source, path)
		if err != nil {
			return err
		}
		destination := filepath.Join(target, relative)
		if entry.IsDir() {
			return os.MkdirAll(destination, 0700)
		}
		input, err := os.Open(path)
		if err != nil {
			return err
		}
		defer input.Close()
		output, err := os.OpenFile(destination, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if err != nil {
			return err
		}
		defer output.Close()
		buffer := make([]byte, 512<<10)
		for {
			if err := ctx.Err(); err != nil {
				return err
			}
			count, readErr := input.Read(buffer)
			if count > 0 {
				written, err := output.Write(buffer[:count])
				if err != nil {
					return err
				}
				if written != count {
					return io.ErrShortWrite
				}
			}
			if readErr == io.EOF {
				break
			}
			if readErr != nil {
				return readErr
			}
		}
		return output.Sync()
	})
}

func (engine *nativeEngine) moveDownloads(ctx context.Context, parent string) error {
	if !filepath.IsAbs(parent) {
		return errors.New("请选择有效的保存目录")
	}
	manager := engine.downloads
	resolved, err := filepath.EvalSymlinks(parent)
	if err != nil {
		return errors.New("无法打开所选目录")
	}
	parent = resolved
	engine.mu.Lock()
	defer engine.mu.Unlock()
	target := filepath.Join(filepath.Clean(parent), "zhenguojian-downloads")
	manager.mu.Lock()
	if manager.loadErr != nil {
		manager.mu.Unlock()
		return errors.New("下载记录无法读取，已停止迁移并保留原索引和文件；请先恢复下载记录")
	}
	if manager.closed || manager.moving {
		manager.mu.Unlock()
		return errors.New("下载目录正在处理，请稍后重试")
	}
	if len(manager.converting) > 0 {
		manager.mu.Unlock()
		return errors.New("请等待下载的分集处理完成后再迁移")
	}
	source := nativeCanonicalPath(manager.root)
	if target == source {
		manager.mu.Unlock()
		return nil
	}
	if nativePathsOverlap(source, target) {
		manager.mu.Unlock()
		return errors.New("新目录不能与原下载目录互相包含")
	}
	if _, err := os.Stat(target); !os.IsNotExist(err) {
		manager.mu.Unlock()
		return errors.New("目标中已有应用下载目录，请选择空目录，避免覆盖文件")
	}
	manager.moving = true
	for id, job := range manager.jobs {
		if job.State == "queued" || job.State == "downloading" {
			job.State = "paused"
		}
		if cancel := manager.active[id]; cancel != nil {
			cancel()
		}
	}
	saveErr := manager.saveLocked()
	manager.mu.Unlock()
	manager.workers.Wait()
	manager.mu.Lock()
	defer manager.mu.Unlock()
	defer func() { manager.moving = false }()
	if saveErr != nil {
		return saveErr
	}
	if err := os.Mkdir(target, 0700); err != nil {
		return errors.New("无法创建目标目录，请检查权限或选择其他位置")
	}
	if err := nativeCopyTree(ctx, source, target); err != nil {
		_ = os.RemoveAll(target)
		return errors.New("文件迁移未完成，原文件已保留，请检查空间与目录权限")
	}
	if err := ctx.Err(); err != nil {
		_ = os.RemoveAll(target)
		return err
	}
	data, _ := json.Marshal(map[string]string{"directory": target})
	if err := nativeDownloadWrite(filepath.Join(engine.directory, "download-location.json"), data); err != nil {
		_ = os.RemoveAll(target)
		return errors.New("保存下载目录失败，原文件已保留")
	}
	manager.root = target
	_ = os.RemoveAll(source)
	return nil
}

func nativePathsOverlap(first, second string) bool {
	inside := func(base, path string) bool {
		relative, err := filepath.Rel(base, path)
		return err == nil && relative != ".." && !strings.HasPrefix(relative, ".."+string(os.PathSeparator))
	}
	return inside(first, second) || inside(second, first)
}

func (engine *nativeEngine) workLease(id, command string) (int, error) {
	engine.mu.Lock()
	defer engine.mu.Unlock()
	if engine.work == nil {
		engine.work = map[string]bool{}
	}
	manager := engine.downloads
	manager.mu.Lock()
	defer manager.mu.Unlock()
	if id != "" {
		if id != "storage" {
			return 0, errors.New("无效的本地任务")
		}
		if command != "start" && command != "end" {
			return 0, errors.New("无效的本地任务操作")
		}
		if command == "start" {
			if engine.work[id] || manager.moving {
				return 0, errors.New("已有本地任务正在运行，请稍后重试")
			}
			engine.work[id] = true
		} else {
			delete(engine.work, id)
		}
	}
	return len(engine.work) + len(manager.converting), nil
}

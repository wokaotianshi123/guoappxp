package core

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
)

// 批量安装、导出与恢复默认。
//
// 单个模块包的格式没变（根目录或唯一一层文件夹里放 manifest.json + main.js），
// 这里额外支持三种批量来源：
//
//  1. 一次选多个 zip（Files）；
//  2. 一个 zip 里装着多个子模块 zip（俗称合集包）；
//  3. 一次贴多个在线地址（URLs）。
//
// 三种来源最终都摊平成「一份模块包字节」，复用 prepareModule 的校验与暂存逻辑。

const (
	// moduleBundleDepth 限制合集包的嵌套层数，避免压缩炸弹式的递归解包。
	moduleBundleDepth = 3
	// moduleBundleEntries 限制合集包里最多包含的成员数。
	moduleBundleEntries = 256
)

// modulePackageCandidate 是一份待安装的模块包，name 只用于失败提示。
type modulePackageCandidate struct {
	name string
	raw  []byte
}

// prepareModuleResult 是批量准备里单个来源的结果。
type prepareModuleResult struct {
	Name  string            `json:"name"`
	Info  *nativeModuleInfo `json:"info,omitempty"`
	Error string            `json:"error,omitempty"`
}

// expandModulePackage 把一份字节摊平成若干模块包。
//
// 判定顺序：先按普通模块包解析；解析不了再当作合集包，逐个成员递归展开。
// 这样单个模块 zip 与合集 zip 都能用同一入口提交。
func expandModulePackage(name string, raw []byte, depth int) ([]modulePackageCandidate, error) {
	if _, _, err := modulePackageFiles(raw); err == nil {
		return []modulePackageCandidate{{name: name, raw: raw}}, nil
	}
	if depth >= moduleBundleDepth {
		return nil, fmt.Errorf("%s 不是有效的模块包", name)
	}
	archive, err := zip.NewReader(bytes.NewReader(raw), int64(len(raw)))
	if err != nil {
		return nil, fmt.Errorf("%s 不是有效的 zip 文件", name)
	}
	var candidates []modulePackageCandidate
	count := 0
	for _, file := range archive.File {
		if file.FileInfo().IsDir() {
			continue
		}
		if !strings.EqualFold(path.Ext(file.Name), ".zip") {
			continue
		}
		if file.UncompressedSize64 > modulePackageBytes {
			return nil, fmt.Errorf("%s 里的 %s 超过 %d MB", name, path.Base(file.Name), modulePackageBytes>>20)
		}
		count++
		if count > moduleBundleEntries {
			return nil, fmt.Errorf("%s 里的子包超过 %d 个", name, moduleBundleEntries)
		}
		member, err := readZipMember(file, modulePackageBytes)
		if err != nil {
			return nil, err
		}
		expanded, err := expandModulePackage(path.Base(file.Name), member, depth+1)
		if err != nil {
			return nil, err
		}
		candidates = append(candidates, expanded...)
	}
	if len(candidates) == 0 {
		return nil, fmt.Errorf("%s 里没有找到模块 zip", name)
	}
	return candidates, nil
}

func readZipMember(file *zip.File, limit int64) ([]byte, error) {
	reader, err := file.Open()
	if err != nil {
		return nil, fmt.Errorf("无法解压 %s", path.Base(file.Name))
	}
	defer reader.Close()
	data, err := io.ReadAll(io.LimitReader(reader, limit+1))
	if err != nil {
		return nil, fmt.Errorf("无法解压 %s", path.Base(file.Name))
	}
	if int64(len(data)) > limit {
		return nil, fmt.Errorf("%s 超过 %d MB", path.Base(file.Name), limit>>20)
	}
	return data, nil
}

// modulePackageCandidates 把 Files / URLs 摊平成待安装列表，并保留失败项。
func (engine *nativeEngine) modulePackageCandidates(ctx context.Context, files, urls []string) ([]modulePackageCandidate, []prepareModuleResult) {
	var candidates []modulePackageCandidate
	var failures []prepareModuleResult
	for _, file := range files {
		file = strings.TrimSpace(file)
		if file == "" {
			continue
		}
		raw, err := readModulePackage(file)
		if err != nil {
			failures = append(failures, prepareModuleResult{Name: filepath.Base(file), Error: err.Error()})
			continue
		}
		expanded, err := expandModulePackage(filepath.Base(file), raw, 0)
		if err != nil {
			failures = append(failures, prepareModuleResult{Name: filepath.Base(file), Error: err.Error()})
			continue
		}
		candidates = append(candidates, expanded...)
	}
	for _, address := range urls {
		address = strings.TrimSpace(address)
		if address == "" {
			continue
		}
		raw, err := engine.downloadModulePackage(ctx, address)
		if err != nil {
			failures = append(failures, prepareModuleResult{Name: address, Error: err.Error()})
			continue
		}
		expanded, err := expandModulePackage(address, raw, 0)
		if err != nil {
			failures = append(failures, prepareModuleResult{Name: address, Error: err.Error()})
			continue
		}
		candidates = append(candidates, expanded...)
	}
	return candidates, failures
}

// prepareModules 批量暂存安装包，返回每一项的结果。成功的项带 token，可直接安装。
func (engine *nativeEngine) prepareModules(ctx context.Context, files, urls []string) (map[string]any, error) {
	candidates, failures := engine.modulePackageCandidates(ctx, files, urls)
	results := make([]prepareModuleResult, 0, len(candidates)+len(failures))
	results = append(results, failures...)
	for _, candidate := range candidates {
		info, err := engine.stageModulePackage(candidate.raw)
		if err != nil {
			results = append(results, prepareModuleResult{Name: candidate.name, Error: err.Error()})
			continue
		}
		item := info
		results = append(results, prepareModuleResult{Name: info.Name, Info: &item})
	}
	return map[string]any{"items": results}, nil
}

// stageModulePackage 校验并暂存一份模块包，返回带 token 的信息。
//
// 每个包按自己的 token 单独落盘，批量安装时不会互相覆盖；单个安装的历史行为
// （每次都清空暂存目录）由调用方按需处理。
func (engine *nativeEngine) stageModulePackage(raw []byte) (nativeModuleInfo, error) {
	module, err := unpackModule(raw)
	if err != nil {
		return nativeModuleInfo{}, err
	}
	if err := moduleConflict(module.manifest); err != nil {
		return nativeModuleInfo{}, err
	}
	folder := filepath.Join(engine.cacheDirectory, modulePackageFolder)
	if err := os.MkdirAll(folder, 0o700); err != nil {
		return nativeModuleInfo{}, err
	}
	token := make([]byte, 16)
	if _, err := rand.Read(token); err != nil {
		return nativeModuleInfo{}, err
	}
	info := moduleInfo(module.manifest)
	info.Token = fmt.Sprintf("%x", token)
	if err := os.WriteFile(filepath.Join(folder, info.Token+".zip"), raw, 0o600); err != nil {
		return nativeModuleInfo{}, err
	}
	if installed, err := readModule(filepath.Join(engine.downloader.moduleRoot(), module.manifest.ID)); err == nil {
		info.Installed, info.Previous = true, installed.manifest.Version
	}
	return info, nil
}

// clearModuleStaging 清空暂存目录。单个安装前调用，避免旧安装包长期占用缓存。
func (engine *nativeEngine) clearModuleStaging() {
	_ = os.RemoveAll(filepath.Join(engine.cacheDirectory, modulePackageFolder))
}

// uninstallModules 批量卸载。内置模块会被记入「已移除」，不会自动装回。
func (engine *nativeEngine) uninstallModules(ids []string) (map[string]any, error) {
	var removed, failures []string
	root := engine.downloader.moduleRoot()
	for _, id := range ids {
		id = strings.TrimSpace(id)
		if id == "" {
			continue
		}
		// 批量卸载要如实报告「没装过」，否则界面上的成功数会对不上。
		if id == "" || !filepath.IsLocal(id) || filepath.Base(id) != id || strings.HasPrefix(id, ".") {
			failures = append(failures, id+"：模块标识无效")
			continue
		}
		if _, err := os.Stat(filepath.Join(root, id)); err != nil {
			failures = append(failures, id+"：模块未安装")
			continue
		}
		if _, err := engine.uninstallModule(id); err != nil {
			failures = append(failures, id+"："+err.Error())
			continue
		}
		removed = append(removed, id)
	}
	return map[string]any{"removed": removed, "failures": failures, "sources": engine.sourceList()}, nil
}

// resetModules 恢复默认：删掉所有用户安装的模块，再让内置模块回到安装状态。
func (engine *nativeEngine) resetModules() (map[string]any, error) {
	root := engine.downloader.moduleRoot()
	entries, err := os.ReadDir(root)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	var removed []string
	for _, entry := range entries {
		name := entry.Name()
		// .bundled-removed.json 之类以点开头的文件不是模块。
		if !entry.IsDir() || strings.HasPrefix(name, ".") {
			continue
		}
		if _, err := engine.uninstallModule(name); err != nil {
			continue
		}
		removed = append(removed, name)
	}
	// 清空「已移除」记录，内置模块会在下次加载时重新写入。
	markFile := filepath.Join(root, bundledRemovedFile)
	if err := os.Remove(markFile); err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	engine.downloader.loadModules()
	return map[string]any{
		"removed": removed,
		"bundled": bundledIndexEntries(),
		"sources": engine.sourceList(),
	}, nil
}

// exportModules 把模块导出成一个 zip（内含每个模块一个子目录）。
//
// ids 为空时导出全部用户安装的模块。内置模块只要装在数据目录里也能导出，
// 这样换设备时可以直接整包带走。
func (engine *nativeEngine) exportModules(ids []string) (map[string]any, error) {
	root := engine.downloader.moduleRoot()
	wanted := map[string]bool{}
	for _, id := range ids {
		if id = strings.TrimSpace(id); id != "" {
			wanted[id] = true
		}
	}
	entries, err := os.ReadDir(root)
	if errors.Is(err, os.ErrNotExist) {
		return nil, errors.New("还没有安装任何模块")
	}
	if err != nil {
		return nil, err
	}
	names := make([]string, 0, len(entries))
	for _, entry := range entries {
		name := entry.Name()
		if !entry.IsDir() || strings.HasPrefix(name, ".") {
			continue
		}
		if len(wanted) > 0 && !wanted[name] {
			continue
		}
		names = append(names, name)
	}
	if len(names) == 0 {
		return nil, errors.New("没有可导出的模块")
	}
	sort.Strings(names)

	var buffer bytes.Buffer
	archive := zip.NewWriter(&buffer)
	count := 0
	for _, name := range names {
		folder := filepath.Join(root, name)
		manifest, err := os.ReadFile(filepath.Join(folder, moduleManifest))
		if err != nil {
			continue
		}
		code, err := os.ReadFile(filepath.Join(folder, moduleEntry))
		if err != nil {
			continue
		}
		for _, item := range []struct {
			name string
			data []byte
		}{
			{moduleManifest, manifest},
			{moduleEntry, code},
		} {
			writer, err := archive.Create(name + "/" + item.name)
			if err != nil {
				_ = archive.Close()
				return nil, err
			}
			if _, err := writer.Write(item.data); err != nil {
				_ = archive.Close()
				return nil, err
			}
		}
		count++
	}
	if err := archive.Close(); err != nil {
		return nil, err
	}
	if count == 0 {
		return nil, errors.New("没有可导出的模块")
	}
	return map[string]any{
		"count": count,
		"names": names,
		// 直接给 Base64，前端解码后写入用户选定的文件。
		"content": base64.StdEncoding.EncodeToString(buffer.Bytes()),
	}, nil
}

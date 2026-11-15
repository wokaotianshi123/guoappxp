package core

// 模块的安装、卸载与升级。移植自 guoappxpx，差别有三处：
//   - 暂存目录用引擎的数据目录（guoappxp 只有 dataDir，没有单独的 cacheDir）；
//   - 不再因为与本体站源同名而拒绝安装（冲突由 moduleSourceID 改名解决）；
//   - 对外回报里带上实际登记的站源 ID，界面据此在源列表里显示出模块源。

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"maps"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"strings"
)

const (
	modulePackageBytes  = 8 << 20
	moduleManifestBytes = 64 << 10
	modulePackageFolder = "module-packages"
)

var modulePackageToken = regexp.MustCompile(`^[0-9a-f]{32}$`)

type nativeModuleInfo struct {
	ID           string   `json:"id"`
	Name         string   `json:"name"`
	Version      string   `json:"version"`
	Description  string   `json:"description"`
	Hosts        []string `json:"hosts"`
	Capabilities []string `json:"capabilities"`
	Adult        bool     `json:"adult"`
	Installed    bool     `json:"installed"`
	Previous     string   `json:"previous,omitempty"`
	Token        string   `json:"token,omitempty"`
	Error        string   `json:"error,omitempty"`
	// SourceID 是模块在站源列表里实际用的 ID。与本体站源同名时带 mod- 前缀，
	// 前端用它把模块源登记进源列表并与同名的本体源区分开。
	SourceID string `json:"sourceId,omitempty"`
}

func moduleInfo(manifest ModuleManifest) nativeModuleInfo {
	return nativeModuleInfo{ID: manifest.ID, Name: manifest.Name, Version: manifest.Version, Description: manifest.Description,
		Hosts: manifest.Hosts, Capabilities: manifest.Capabilities, Adult: *manifest.Adult}
}

func (engine *nativeEngine) modules() ([]nativeModuleInfo, error) {
	entries, err := os.ReadDir(engine.downloader.moduleRoot())
	if errors.Is(err, os.ErrNotExist) {
		return []nativeModuleInfo{}, nil
	}
	if err != nil {
		return nil, err
	}
	root := engine.downloader.moduleRoot()
	loadedModules.Lock()
	registered := maps.Clone(loadedModules.byName)
	loadedModules.Unlock()
	items := []nativeModuleInfo{}
	for _, entry := range entries {
		if !entry.IsDir() || strings.HasPrefix(entry.Name(), ".") {
			continue
		}
		module, err := readModule(filepath.Join(root, entry.Name()))
		if err != nil {
			items = append(items, nativeModuleInfo{ID: entry.Name(), Name: entry.Name(), Error: err.Error()})
			continue
		}
		info := moduleInfo(module.manifest)
		info.SourceID = entry.Name()
		if source, found := registered[entry.Name()]; found {
			info.SourceID = source
		}
		if !registeredProviderSource(info.SourceID) {
			info.Error = "模块未能加载，详见诊断日志"
		}
		items = append(items, info)
	}
	return items, nil
}

func (engine *nativeEngine) prepareModule(ctx context.Context, file, address, indexed string) (nativeModuleInfo, error) {
	var raw []byte
	var err error
	switch {
	case indexed != "":
		raw, err = engine.indexedModulePackage(ctx, indexed)
	case address != "":
		raw, err = engine.downloadModulePackage(ctx, address)
	default:
		raw, err = readModulePackage(file)
	}
	if err != nil {
		return nativeModuleInfo{}, err
	}
	module, err := unpackModule(raw)
	if err != nil {
		return nativeModuleInfo{}, err
	}
	if indexed != "" && module.manifest.ID != indexed {
		return nativeModuleInfo{}, fmt.Errorf("索引里的 %s 实际是模块 %s", indexed, module.manifest.ID)
	}
	folder := filepath.Join(engine.directory, modulePackageFolder)
	if err := os.RemoveAll(folder); err != nil {
		return nativeModuleInfo{}, err
	}
	if err := os.MkdirAll(folder, 0o700); err != nil {
		return nativeModuleInfo{}, err
	}
	token := make([]byte, 16)
	_, _ = rand.Read(token)
	info := moduleInfo(module.manifest)
	info.Token = hex.EncodeToString(token)
	if err := os.WriteFile(filepath.Join(folder, info.Token+".zip"), raw, 0o600); err != nil {
		return nativeModuleInfo{}, err
	}
	if installed, err := readModule(filepath.Join(engine.downloader.moduleRoot(), module.manifest.ID)); err == nil {
		info.Installed, info.Previous = true, installed.manifest.Version
	}
	return info, nil
}

func (engine *nativeEngine) installModule(token string) (map[string]any, error) {
	if !modulePackageToken.MatchString(token) {
		return nil, errors.New("安装包已失效，请重新选择")
	}
	staged := filepath.Join(engine.directory, modulePackageFolder, token+".zip")
	raw, err := os.ReadFile(staged)
	if err != nil {
		return nil, errors.New("安装包已失效，请重新选择")
	}
	manifest, code, err := modulePackageFiles(raw)
	if err != nil {
		return nil, err
	}
	module, err := parseModule(manifest, code)
	if err != nil {
		return nil, err
	}
	d := engine.downloader
	// 注册表的加解锁必须自己包住，reloadModuleLocked 之后才能安全地重新列举模块
	// （modules() 也要拿同一把锁，嵌在里面会死锁）。
	id := module.manifest.ID
	source, err := func() (string, error) {
		loadedModules.Lock()
		defer loadedModules.Unlock()
		if err := d.writeModuleLocked(id, manifest, code); err != nil {
			return "", err
		}
		if err := d.markBundledRemoved(id, false); err != nil {
			return "", err
		}
		d.reloadModuleLocked(id)
		registered, loaded := loadedModules.byName[id]
		if !loaded || !registeredProviderSource(registered) {
			return "", errors.New("模块已写入但未能加载，详见诊断日志")
		}
		return registered, nil
	}()
	if err != nil {
		return nil, err
	}
	_ = os.Remove(staged)
	return map[string]any{"source": source, "modules": engine.moduleInfos()}, nil
}

func (engine *nativeEngine) uninstallModule(name string) (map[string]any, error) {
	if name == "" || !filepath.IsLocal(name) || filepath.Base(name) != name || strings.HasPrefix(name, ".") {
		return nil, errors.New("模块标识无效")
	}
	d := engine.downloader
	loadedModules.Lock()
	err := func() error {
		if err := os.RemoveAll(filepath.Join(d.moduleRoot(), name)); err != nil {
			return err
		}
		if err := d.markBundledRemoved(name, true); err != nil {
			return err
		}
		d.reloadModuleLocked(name)
		return nil
	}()
	loadedModules.Unlock()
	if err != nil {
		return nil, err
	}
	return map[string]any{"modules": engine.moduleInfos()}, nil
}

// moduleInfos 是 modules() 的容错包装：卸载/安装成功后顺手回报一份最新列表，
// 读不到就让前端自己再拉一次，不因此把已经成功的操作报成失败。
func (engine *nativeEngine) moduleInfos() []nativeModuleInfo {
	items, err := engine.modules()
	if err != nil {
		return []nativeModuleInfo{}
	}
	return items
}

func (d *Downloader) writeModuleLocked(id string, manifest, code []byte) error {
	root := d.moduleRoot()
	temporary := filepath.Join(root, "."+id+".installing")
	if err := os.RemoveAll(temporary); err != nil {
		return err
	}
	if err := os.MkdirAll(temporary, 0o700); err != nil {
		return err
	}
	defer os.RemoveAll(temporary)
	if err := os.WriteFile(filepath.Join(temporary, moduleManifest), manifest, 0o600); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(temporary, moduleEntry), code, 0o600); err != nil {
		return err
	}
	target := filepath.Join(root, id)
	if err := os.RemoveAll(target); err != nil {
		return err
	}
	return os.Rename(temporary, target)
}

func (engine *nativeEngine) downloadModulePackage(ctx context.Context, address string) ([]byte, error) {
	parsed, err := url.Parse(strings.TrimSpace(address))
	if err != nil || (parsed.Scheme != "https" && parsed.Scheme != "http") || parsed.Host == "" {
		return nil, errors.New("请填写以 http:// 或 https:// 开头的安装包地址")
	}
	raw, err := engine.fetchLimited(ctx, parsed.String(), modulePackageBytes)
	if err != nil {
		return nil, fmt.Errorf("下载安装包失败：%w", err)
	}
	return raw, nil
}

func (engine *nativeEngine) fetchLimited(ctx context.Context, address string, limit int) ([]byte, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return nil, err
	}
	response, err := engine.downloader.client.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d", response.StatusCode)
	}
	raw, err := io.ReadAll(io.LimitReader(response.Body, int64(limit)+1))
	if err != nil {
		return nil, err
	}
	if len(raw) > limit {
		if limit >= 1<<20 {
			return nil, fmt.Errorf("文件超过 %d MB", limit>>20)
		}
		return nil, fmt.Errorf("文件超过 %d KB", limit>>10)
	}
	return raw, nil
}

func readModulePackage(file string) ([]byte, error) {
	handle, err := os.Open(file)
	if err != nil {
		return nil, errors.New("无法读取所选文件")
	}
	defer handle.Close()
	raw, err := io.ReadAll(io.LimitReader(handle, modulePackageBytes+1))
	if err != nil {
		return nil, errors.New("无法读取所选文件")
	}
	if len(raw) > modulePackageBytes {
		return nil, fmt.Errorf("安装包超过 %d MB", modulePackageBytes>>20)
	}
	return raw, nil
}

func unpackModule(raw []byte) (*jsModule, error) {
	manifest, code, err := modulePackageFiles(raw)
	if err != nil {
		return nil, err
	}
	return parseModule(manifest, code)
}

func modulePackageFiles(raw []byte) (manifest, code []byte, err error) {
	archive, err := zip.NewReader(bytes.NewReader(raw), int64(len(raw)))
	if err != nil {
		return nil, nil, errors.New("安装包不是有效的 zip 文件")
	}
	files := map[string]*zip.File{}
	var prefixes []string
	for _, file := range archive.File {
		name := strings.TrimPrefix(strings.ReplaceAll(file.Name, `\`, "/"), "./")
		files[name] = file
		if name == moduleManifest {
			prefixes = append(prefixes, "")
		} else if folder, base := path.Split(name); base == moduleManifest && strings.Count(folder, "/") == 1 {
			prefixes = append(prefixes, folder)
		}
	}
	if len(prefixes) != 1 {
		return nil, nil, fmt.Errorf("安装包根目录或唯一的文件夹里应有 %s 和 %s", moduleManifest, moduleEntry)
	}
	if manifest, err = readPackageFile(files[prefixes[0]+moduleManifest], moduleManifestBytes); err != nil {
		return nil, nil, err
	}
	if code, err = readPackageFile(files[prefixes[0]+moduleEntry], moduleEntryBytes); err != nil {
		return nil, nil, err
	}
	return manifest, code, nil
}

func readPackageFile(file *zip.File, limit int) ([]byte, error) {
	if file == nil {
		return nil, fmt.Errorf("安装包里缺少 %s", moduleEntry)
	}
	if file.UncompressedSize64 > uint64(limit) {
		return nil, fmt.Errorf("%s 超过 %d KB", path.Base(file.Name), limit>>10)
	}
	reader, err := file.Open()
	if err != nil {
		return nil, fmt.Errorf("无法解压 %s", path.Base(file.Name))
	}
	defer reader.Close()
	data, err := io.ReadAll(io.LimitReader(reader, int64(limit)+1))
	if err != nil {
		return nil, fmt.Errorf("无法解压 %s", path.Base(file.Name))
	}
	if len(data) > limit {
		return nil, fmt.Errorf("%s 超过 %d KB", path.Base(file.Name), limit>>10)
	}
	return data, nil
}

package core

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"time"
)

const (
	moduleIndexFormat  = 1
	moduleIndexBytes   = 1 << 20
	moduleIndexTimeout = 12 * time.Second
	moduleFetchTimeout = 20 * time.Second
	// moduleMirrorTimeout 是「单个镜像」的超时，比总预算短得多。
	//
	// 镜像可用性差异极大：实测 fastly.jsdelivr.net 在部分网络下会卡满 30 秒
	// 才报 i/o timeout，而 raw.githubusercontent.com 只要 0.6 秒。如果所有镜像
	// 共用一份总预算，慢镜像会把时间耗光，后面能用的镜像根本没机会跑，表现为
	// 「全部镜像都超时」。
	moduleMirrorTimeout = 6 * time.Second
)

var (
	// 内置官方仓库的两处镜像。自定义仓库失效时用它兜底，保证官方模块照常可见。
	moduleIndexAddresses = []string{
		"https://raw.githubusercontent.com/guoapp-modules/index/main/index.json",
		"https://cdn.jsdelivr.net/gh/guoapp-modules/index@main/index.json",
	}
	// 模块文件的下载模板，按实测可用性排序：raw 最快最稳（0.6s），
	// jsDelivr 的 CDN 在部分网络会被重置或卡满超时，放后面。
	// 全部失败后再走 api.github.com 兜底。
	moduleFileAddresses = []string{
		"https://raw.githubusercontent.com/%s/%s/%s",
		"https://cdn.jsdelivr.net/gh/%s@%s/%s",
		"https://fastly.jsdelivr.net/gh/%s@%s/%s",
	}
	moduleIndexRepo = regexp.MustCompile(`^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$`)
	// moduleRepositoryAPI 是 GitHub contents 接口的根地址。镜像全灭时用它兜底；
	// 单独提出来是为了测试能把它指到本地服务上。
	moduleRepositoryAPI = "https://api.github.com"
	// 标签容忍「模块标识-」前缀：guoappjqk 的商店给每个模块单独打
	// fullboys-v0.1.0 这类标签，早期仓库统一用 v1.0.0。
	moduleIndexTag  = regexp.MustCompile(`^(?:[a-z0-9][a-z0-9_-]{0,31}-)?v\d+\.\d+\.\d+$`)
	moduleIndexHash = regexp.MustCompile(`^[0-9a-f]{64}$`)
)

type moduleIndexEntry struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Version     string `json:"version"`
	Description string `json:"description"`
	API         int    `json:"api"`
	Adult       bool   `json:"adult"`
	Repo        string `json:"repo"`
	Tag         string `json:"tag"`
	// Path 是模块文件在仓库里的子目录（guoappjqk 的商店用它把多个模块
	// 放进同一个仓库）。空表示文件就在标签的根目录。
	Path   string            `json:"path"`
	SHA256 map[string]string `json:"sha256"`
	// Bundled 标出「安装包内自带」的条目，它们不从仓库下载。
	Bundled bool `json:"bundled,omitempty"`
}

func (entry moduleIndexEntry) usable() bool {
	return entry.API == moduleAPIVersion && moduleIDPattern.MatchString(entry.ID) && strings.TrimSpace(entry.Name) != "" &&
		moduleIndexRepo.MatchString(entry.Repo) && moduleIndexTag.MatchString(entry.Tag) && entry.safePath() &&
		moduleIndexHash.MatchString(entry.SHA256[moduleManifest]) && moduleIndexHash.MatchString(entry.SHA256[moduleEntry])
}

// safePath 校验 path 只能是仓库内的相对子目录，避免拼出 ../ 之类的越界地址。
func (entry moduleIndexEntry) safePath() bool {
	path := strings.Trim(strings.TrimSpace(entry.Path), "/")
	if path == "" {
		return true
	}
	if strings.ContainsAny(path, `\?#`) || strings.HasPrefix(path, "/") {
		return false
	}
	for _, segment := range strings.Split(path, "/") {
		if segment == "" || segment == "." || segment == ".." {
			return false
		}
	}
	return true
}

func parseModuleIndex(raw []byte) ([]moduleIndexEntry, error) {
	var index struct {
		Format  int                `json:"format"`
		Modules []moduleIndexEntry `json:"modules"`
	}
	if err := json.Unmarshal(raw, &index); err != nil {
		return nil, errors.New("索引格式无效")
	}
	// guoappcheng 的商店索引没有写 format，早期版本照样能读；缺省按第 1 版处理，
	// 只有明确写了更高版本才提示更新应用。
	if index.Format != 0 && index.Format != moduleIndexFormat {
		return nil, fmt.Errorf("索引格式为第 %d 版，请更新应用", index.Format)
	}
	entries := []moduleIndexEntry{}
	for _, entry := range index.Modules {
		if entry.usable() {
			entries = append(entries, entry)
		}
	}
	return entries, nil
}

// moduleGitHubSource 从 GitHub 的 raw / blob / jsDelivr 地址里解析出仓库、
// 引用与文件路径。解析不出来（自建镜像、内网地址）时返回 false。
func moduleGitHubSource(address string) (repo, ref, path string, ok bool) {
	parsed, err := url.Parse(strings.TrimSpace(address))
	if err != nil {
		return "", "", "", false
	}
	segments := []string{}
	for _, segment := range strings.Split(strings.Trim(parsed.Path, "/"), "/") {
		if segment != "" {
			segments = append(segments, segment)
		}
	}
	join := func(parts []string) string {
		escaped := make([]string, len(parts))
		for index, part := range parts {
			escaped[index] = url.PathEscape(part)
		}
		return strings.Join(escaped, "/")
	}
	repoOf := func(owner, name string) string { return owner + "/" + name }
	// raw.githubusercontent.com/<owner>/<repo>/<ref>/<path>，
	// 也兼容 /refs/heads/<branch>/<path> 这种带 refs 前缀的写法。
	trimRef := func(rest []string) (string, []string, bool) {
		if len(rest) >= 3 && rest[0] == "refs" && (rest[1] == "heads" || rest[1] == "tags") {
			return rest[2], rest[3:], len(rest) > 3
		}
		if len(rest) >= 2 {
			return rest[0], rest[1:], true
		}
		return "", nil, false
	}
	switch strings.ToLower(parsed.Hostname()) {
	case "raw.githubusercontent.com":
		if len(segments) < 4 {
			return "", "", "", false
		}
		branch, rest, ok := trimRef(segments[2:])
		if !ok {
			return "", "", "", false
		}
		return repoOf(segments[0], segments[1]), branch, join(rest), true
	case "github.com":
		// github.com/<owner>/<repo>/raw|blob/<ref>/<path>
		if len(segments) < 5 || (segments[2] != "raw" && segments[2] != "blob") {
			return "", "", "", false
		}
		branch, rest, ok := trimRef(segments[3:])
		if !ok {
			return "", "", "", false
		}
		return repoOf(segments[0], segments[1]), branch, join(rest), true
	case "cdn.jsdelivr.net", "fastly.jsdelivr.net", "gcore.jsdelivr.net":
		// cdn.jsdelivr.net/gh/<owner>/<repo>@<ref>/<path>
		if len(segments) < 4 || segments[0] != "gh" {
			return "", "", "", false
		}
		owner, tagged := segments[1], segments[2]
		name, branch, found := strings.Cut(tagged, "@")
		if !found || branch == "" {
			return "", "", "", false
		}
		return repoOf(owner, name), branch, join(segments[3:]), true
	}
	return "", "", "", false
}

// moduleIndexMirrors 返回同一份 index.json 的镜像地址：GitHub 仓库走
// jsDelivr、fastly 与 raw 三处（并发取、按版本合并），其它地址原样返回。
func moduleIndexMirrors(address string) []string {
	address = strings.TrimSpace(address)
	if address == "" {
		return nil
	}
	repo, ref, path, ok := moduleGitHubSource(address)
	if !ok {
		return []string{address}
	}
	return moduleMirrorAddresses(repo, ref, path)
}

func moduleMirrorAddresses(repo, ref, path string) []string {
	if path == "" {
		path = "index.json"
	}
	return []string{
		fmt.Sprintf("https://cdn.jsdelivr.net/gh/%s@%s/%s", repo, ref, path),
		fmt.Sprintf("https://fastly.jsdelivr.net/gh/%s@%s/%s", repo, ref, path),
		fmt.Sprintf("https://raw.githubusercontent.com/%s/%s/%s", repo, ref, path),
	}
}

// moduleIndex 读取模块索引：当前仓库的三处镜像一起取，同一模块按版本取最新；
// 镜像全部失败时退回 api.github.com，再不行才用内置官方仓库兜底。
//
// 超时按「组」算（见 fetchIndexGroup），不在这里统一限时：否则第一组用光
// 预算后，兜底的官方仓库会被已经过期的 ctx 直接取消。
func (engine *nativeEngine) moduleIndex(ctx context.Context) ([]moduleIndexEntry, error) {
	var failures []string
	for _, group := range engine.moduleIndexGroups() {
		entries, ok, errs := engine.fetchIndexGroup(ctx, group)
		if ok {
			return entries, nil
		}
		failures = append(failures, errs...)
	}
	if len(failures) == 0 {
		failures = append(failures, "没有可用的模块源")
	}
	return nil, fmt.Errorf("读取模块索引失败：%s", strings.Join(failures, "；"))
}

// fetchIndexGroup 并发取一组镜像地址，按地址顺序合并：同一模块保留版本较新
// 的那份（镜像有缓存时新旧混杂，取最新才不会把用户按到旧版本上）。
// 只要有一处解析成功就算成功——索引为空也算（该仓库确实没有模块）。
func (engine *nativeEngine) fetchIndexGroup(ctx context.Context, addresses []string) ([]moduleIndexEntry, bool, []string) {
	// 一组最多「三处镜像并发 + api.github.com 兜底」两轮，按两倍预算限时。
	ctx, cancel := context.WithTimeout(ctx, moduleIndexTimeout+moduleFetchTimeout)
	defer cancel()
	type fetched struct {
		entries []moduleIndexEntry
		err     error
	}
	results := make([]fetched, len(addresses))
	var wait sync.WaitGroup
	for index, address := range addresses {
		wait.Add(1)
		go func(index int, address string) {
			defer wait.Done()
			list, err := engine.fetchIndexList(ctx, address)
			results[index] = fetched{entries: list, err: err}
		}(index, address)
	}
	wait.Wait()

	entries := []moduleIndexEntry{}
	positions := map[string]int{}
	ok := false
	var failures []string
	for _, result := range results {
		if result.err != nil {
			failures = append(failures, result.err.Error())
			continue
		}
		ok = true
		for _, entry := range result.entries {
			position, found := positions[entry.ID]
			if !found {
				positions[entry.ID] = len(entries)
				entries = append(entries, entry)
				continue
			}
			if newerModuleVersion(entry.Version, entries[position].Version) {
				entries[position] = entry
			}
		}
	}
	if ok {
		return entries, true, nil
	}
	// 镜像全灭：GitHub 仓库走一次 api.github.com（不占镜像缓存，能绕过 CDN 抽风）。
	if len(addresses) > 0 {
		if repo, ref, path, github := moduleGitHubSource(addresses[0]); github {
			if list, err := engine.fetchRepositoryIndex(ctx, repo, ref, path); err == nil {
				return list, true, nil
			} else {
				failures = append(failures, err.Error())
			}
		}
	}
	return nil, false, failures
}

func (engine *nativeEngine) fetchIndexList(ctx context.Context, address string) ([]moduleIndexEntry, error) {
	ctx, cancel := context.WithTimeout(ctx, moduleIndexTimeout)
	defer cancel()
	raw, err := engine.fetchModuleResource(ctx, address, moduleIndexBytes)
	if err != nil {
		return nil, err
	}
	return parseModuleIndex(raw)
}

// fetchRepositoryIndex 用 GitHub contents 接口读仓库里的索引，作为镜像全灭时
// 的最后兜底。repo 形如 owner/name，path 为仓库内相对路径。
func (engine *nativeEngine) fetchRepositoryIndex(ctx context.Context, repo, ref, path string) ([]moduleIndexEntry, error) {
	raw, err := engine.fetchRepositoryFile(ctx, repo, ref, path, moduleIndexBytes)
	if err != nil {
		return nil, fmt.Errorf("%s：%w", repo, err)
	}
	list, err := parseModuleIndex(raw)
	if err != nil {
		return nil, fmt.Errorf("%s：%w", repo, err)
	}
	return list, nil
}

func (engine *nativeEngine) moduleStore(ctx context.Context) (map[string]any, error) {
	entries, err := engine.moduleIndex(ctx)
	bundled := bundledIndexEntries()
	if err != nil && len(bundled) == 0 {
		return nil, err
	}
	items := append(bundled, entries...)
	result := map[string]any{"items": items}
	if err != nil {
		result["warning"] = err.Error()
	}
	return result, nil
}

func (engine *nativeEngine) indexedModulePackage(ctx context.Context, id string, bundled bool) ([]byte, error) {
	if bundled {
		modules, _ := readBundledModules()
		if modules[id].raw == nil {
			return nil, fmt.Errorf("安装包没有内置 %s", id)
		}
		return zipModuleFiles(modules[id].raw, modules[id].code)
	}
	entries, err := engine.moduleIndex(ctx)
	if err != nil {
		return nil, err
	}
	for _, entry := range entries {
		if entry.ID != id {
			continue
		}
		manifest, err := engine.fetchIndexedFile(ctx, entry, moduleManifest, moduleManifestBytes)
		if err != nil {
			return nil, err
		}
		code, err := engine.fetchIndexedFile(ctx, entry, moduleEntry, moduleEntryBytes)
		if err != nil {
			return nil, err
		}
		return zipModuleFiles(manifest, code)
	}
	return nil, fmt.Errorf("模块索引里没有 %s", id)
}

// fetchIndexedFile 依次试 jsDelivr、fastly、raw 下载模块文件，逐个核对
// sha256；三处都失败时再走 api.github.com 兜底。
func (engine *nativeEngine) fetchIndexedFile(ctx context.Context, entry moduleIndexEntry, name string, limit int) ([]byte, error) {
	file := name
	if prefix := strings.Trim(strings.TrimSpace(entry.Path), "/"); prefix != "" {
		file = prefix + "/" + name
	}
	expected := entry.SHA256[name]
	var failures []string
	for _, pattern := range moduleFileAddresses {
		// 每个镜像用自己的短超时：慢镜像不能吃掉整轮预算，
		// 否则后面的镜像连尝试的机会都没有。
		mirrorCtx, cancel := context.WithTimeout(ctx, moduleMirrorTimeout)
		data, err := engine.fetchModuleResource(mirrorCtx, fmt.Sprintf(pattern, entry.Repo, entry.Tag, file), limit)
		cancel()
		if err == nil {
			sum := sha256.Sum256(data)
			if hex.EncodeToString(sum[:]) == expected {
				return data, nil
			}
			err = errors.New("文件校验不符")
		}
		failures = append(failures, err.Error())
	}
	if data, err := engine.fetchRepositoryFile(ctx, entry.Repo, entry.Tag, file, limit); err == nil {
		sum := sha256.Sum256(data)
		if hex.EncodeToString(sum[:]) == expected {
			return data, nil
		}
		failures = append(failures, "文件校验不符")
	} else {
		failures = append(failures, err.Error())
	}
	return nil, fmt.Errorf("下载 %s 的 %s 失败：%s", entry.Name, name, strings.Join(failures, "；"))
}

// fetchRepositoryFile 用 contents 接口取仓库里的单个文件（raw 响应）。
func (engine *nativeEngine) fetchRepositoryFile(ctx context.Context, repo, ref, path string, limit int) ([]byte, error) {
	segments := strings.Split(strings.Trim(path, "/"), "/")
	for index := range segments {
		segments[index] = url.PathEscape(segments[index])
	}
	address := fmt.Sprintf("%s/repos/%s/contents/%s?ref=%s",
		strings.TrimSuffix(moduleRepositoryAPI, "/"), repo, strings.Join(segments, "/"), url.QueryEscape(ref))
	ctx, cancel := context.WithTimeout(ctx, moduleFetchTimeout)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return nil, err
	}
	request.Header.Set("Accept", "application/vnd.github.raw+json")
	request.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	request.Header.Set("User-Agent", "guoapp")
	response, err := engine.downloader.client.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	switch response.StatusCode {
	case http.StatusOK:
	case http.StatusNotFound:
		return nil, errors.New("模块源里没有该文件")
	case http.StatusUnauthorized, http.StatusForbidden:
		return nil, fmt.Errorf("模块源拒绝访问（HTTP %d）", response.StatusCode)
	default:
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

func (engine *nativeEngine) fetchModuleResource(ctx context.Context, address string, limit int) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, moduleFetchTimeout)
	defer cancel()
	return engine.fetchLimited(ctx, address, limit)
}

func zipModuleFiles(manifest, code []byte) ([]byte, error) {
	var buffer bytes.Buffer
	archive := zip.NewWriter(&buffer)
	for _, file := range []struct {
		name string
		data []byte
	}{{moduleManifest, manifest}, {moduleEntry, code}} {
		writer, err := archive.Create(file.name)
		if err != nil {
			return nil, err
		}
		if _, err := writer.Write(file.data); err != nil {
			return nil, err
		}
	}
	if err := archive.Close(); err != nil {
		return nil, err
	}
	return buffer.Bytes(), nil
}

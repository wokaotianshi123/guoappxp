package core

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"testing"
	"testing/fstest"
	"time"
)

// 用真实商店索引验证模块能不能装、能不能加载、能不能出播放地址。
//
// 默认跳过（要联网、耗时且依赖站点可用性）。需要验证时：
//
//	GUOAPP_STORE_TEST=1 go test ./core/ -run TestStoreModulesReal -v -timeout 30m
//
// 索引与模块文件都从 guocheng1378 商店取，覆盖用户报错的
// 「模块未导出函数 resolveMedia」与「object has no member 'hmacSha256'」两类问题。

const storeIndexURL = "https://raw.githubusercontent.com/guocheng1378/guoapp-modules/refs/heads/main/index.json"

func storeTestClient() *http.Client {
	return &http.Client{Timeout: 45 * time.Second}
}

func fetchStoreBytes(client *http.Client, address string) ([]byte, error) {
	request, err := http.NewRequest(http.MethodGet, address, nil)
	if err != nil {
		return nil, err
	}
	request.Header.Set("User-Agent", "guoapp-store-test")
	response, err := client.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d", response.StatusCode)
	}
	return io.ReadAll(io.LimitReader(response.Body, 32<<20))
}

type storeIndex struct {
	Modules []struct {
		ID      string            `json:"id"`
		Name    string            `json:"name"`
		Version string            `json:"version"`
		Repo    string            `json:"repo"`
		Tag     string            `json:"tag"`
		SHA256  map[string]string `json:"sha256"`
	} `json:"modules"`
}

func TestStoreModulesReal(t *testing.T) {
	if os.Getenv("GUOAPP_STORE_TEST") != "1" {
		t.Skip("设置 GUOAPP_STORE_TEST=1 才会联网验证商店模块")
	}
	client := storeTestClient()
	raw, err := fetchStoreBytes(client, storeIndexURL)
	if err != nil {
		t.Fatalf("读取商店索引失败: %v", err)
	}
	var index storeIndex
	if err := json.Unmarshal(raw, &index); err != nil {
		t.Fatalf("解析商店索引失败: %v", err)
	}
	if len(index.Modules) == 0 {
		t.Fatal("商店索引里没有模块")
	}
	t.Logf("商店索引共 %d 个模块", len(index.Modules))

	engine := &nativeEngine{
		downloader: &Downloader{
			cfg:     Config{dataDir: t.TempDir()},
			client:  client,
			limiter: newRequestLimiter(3, 0),
		},
		cacheDirectory: t.TempDir(),
	}
	// 内置模块表清空，避免与本测试装的模块互相干扰。
	previous := bundledModules
	bundledModules = fstest.MapFS{}
	t.Cleanup(func() { bundledModules = previous })

	type outcome struct {
		id      string
		name    string
		install string
		load    string
		catalog string
		detail  string
		media   string
	}
	var outcomes []outcome

	for _, module := range index.Modules {
		result := outcome{id: module.ID, name: module.Name}
		t.Cleanup(func() { Unregister(module.ID) })

		manifestURL := moduleFileURL(module.Repo, module.Tag, "manifest.json")
		codeURL := moduleFileURL(module.Repo, module.Tag, "main.js")
		manifestRaw, err := fetchStoreBytes(client, manifestURL)
		if err != nil {
			result.install = "下载清单失败: " + err.Error()
			outcomes = append(outcomes, result)
			continue
		}
		codeRaw, err := fetchStoreBytes(client, codeURL)
		if err != nil {
			result.install = "下载代码失败: " + err.Error()
			outcomes = append(outcomes, result)
			continue
		}

		// 安装：直接写进数据目录再加载，等价于安装流程的落盘结果。
		loadedModules.Lock()
		writeErr := engine.downloader.writeModuleLocked(module.ID, manifestRaw, codeRaw)
		loadedModules.Unlock()
		if writeErr != nil {
			result.install = "写入失败: " + writeErr.Error()
			outcomes = append(outcomes, result)
			continue
		}
		result.install = "ok"
		engine.downloader.reloadModuleLocked(module.ID)
		if !registeredProviderSource(module.ID) {
			result.load = "未注册（脚本执行失败，详见日志）"
			outcomes = append(outcomes, result)
			continue
		}
		result.load = "ok"

		provider, ok := engine.downloader.provider(module.ID)
		if !ok {
			result.load = "无法取得 provider"
			outcomes = append(outcomes, result)
			continue
		}
		ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)

		// 分类 + 列表
		categories, catErr := provider.Categories(ctx, false)
		if catErr != nil {
			result.catalog = "分类失败: " + catErr.Error()
			cancel()
			outcomes = append(outcomes, result)
			continue
		}
		category := ""
		if len(categories) > 0 {
			category = categories[0].ID
		}
		dramas, _, catalogErr := provider.CatalogPage(ctx, 1, category)
		if catalogErr != nil || len(dramas) == 0 {
			message := "列表为空"
			if catalogErr != nil {
				message = "列表失败: " + catalogErr.Error()
			}
			result.catalog = message
			cancel()
			outcomes = append(outcomes, result)
			continue
		}
		result.catalog = "ok(" + strconv.Itoa(len(dramas)) + ")"
		drama := dramas[0]

		// 详情
		detail, chapters, detailErr := provider.Detail(ctx, drama.SourceID)
		if detailErr != nil || len(chapters) == 0 {
			message := "分集为空"
			if detailErr != nil {
				message = "详情失败: " + detailErr.Error()
			}
			result.detail = message
			cancel()
			outcomes = append(outcomes, result)
			continue
		}
		result.detail = "ok(" + strconv.Itoa(len(chapters)) + "集)"

		// 播放：resolveMedia 缺失时走 chapter.videoUrl 回退
		chapter := chapters[0]
		task := Task{DramaID: detail.ID, DramaTitle: detail.Title, Chapter: chapter, Index: 1, Total: len(chapters)}
		media, mediaErr := provider.ResolveMedia(ctx, task)
		cancel()
		if mediaErr != nil || strings.TrimSpace(media.URL) == "" {
			message := "无播放地址"
			if mediaErr != nil {
				message = "播放失败: " + mediaErr.Error()
			}
			result.media = message
		} else {
			result.media = "ok(" + shortMedia(media.URL) + ")"
		}
		outcomes = append(outcomes, result)
	}

	// 汇总
	type reportRow struct {
		ID      string `json:"id"`
		Name    string `json:"name"`
		Install string `json:"install"`
		Load    string `json:"load"`
		Catalog string `json:"catalog"`
		Detail  string `json:"detail"`
		Media   string `json:"media"`
	}
	report := make([]reportRow, 0, len(outcomes))
	// 只有「代码级」问题才算失败：脚本跑不起来、装了加载不了。
	// 站点连不上、403、超时是网络与站点侧的问题，不该让测试红掉。
	var failed []string
	for _, item := range outcomes {
		line := item.id + " [" + item.name + "] 安装=" + item.install + " 加载=" + item.load +
			" 列表=" + item.catalog + " 详情=" + item.detail + " 播放=" + item.media
		t.Log(line)
		report = append(report, reportRow{
			ID: item.id, Name: item.name, Install: item.install, Load: item.load,
			Catalog: item.catalog, Detail: item.detail, Media: item.media,
		})
		if item.install != "ok" || item.load != "ok" {
			failed = append(failed, line)
		}
	}
	// 报告写成 UTF-8 JSON，避免终端编码把中文和链接弄坏。
	if path := os.Getenv("GUOAPP_STORE_REPORT"); path != "" {
		if encoded, err := json.MarshalIndent(report, "", "  "); err == nil {
			_ = os.WriteFile(path, encoded, 0o600)
		}
	}
	if len(failed) > 0 {
		t.Fatalf("%d/%d 个模块未通过：\n%s", len(failed), len(outcomes), strings.Join(failed, "\n"))
	}
	t.Logf("全部 %d 个模块通过", len(outcomes))
}

// moduleFileURL 按商店的 tag 结构拼出模块文件地址（文件在标签根目录）。
func moduleFileURL(repo, tag, file string) string {
	return "https://raw.githubusercontent.com/" + repo + "/" + tag + "/" + file
}

func shortMedia(url string) string {
	if len(url) > 60 {
		return url[:60] + "…"
	}
	return url
}

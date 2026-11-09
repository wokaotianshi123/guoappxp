package core

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/anacrolix/torrent/bencode"
	"github.com/anacrolix/torrent/metainfo"
)

// 搜索会话必须「先把所有站标签给出来，再逐站填结果」，而不是等最慢的站。
func TestMagnetSessionEmitsSitesBeforeResults(t *testing.T) {
	withFreshMagnetSources(t)

	// 慢站故意拖 300ms，快站立即返回；若实现是「等全部完成」，快站的结果
	// 也要等到 300ms 后才能看到。
	fast := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`<ul>
<li class="item"><a href="/hash/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa">快站资源</a></li>
</ul>`))
	}))
	defer fast.Close()
	slow := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		time.Sleep(300 * time.Millisecond)
		_, _ = w.Write([]byte(`<ul>
<li class="item"><a href="/hash/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb">慢站资源</a></li>
</ul>`))
	}))
	defer slow.Close()

	ruleFor := func(name, base string) string {
		return `{"name":"` + name + `","mainUrl":"` + base + `",` +
			`"searchUrl":"` + base + `/s?keyword=[keyword]",` +
			`"expressionModel":{"group":"//li[@class='item']","title":".//a[1]",` +
			`"url":".//a[1]/@href","magnet":".//a[1]/@href"}}`
	}
	if _, err := magnetAddCustomSite("快站", fast.URL, ruleFor("快站", fast.URL)); err != nil {
		t.Fatalf("新增快站失败: %v", err)
	}
	slowItem, err := magnetAddCustomSite("慢站", slow.URL, ruleFor("慢站", slow.URL))
	if err != nil {
		t.Fatalf("新增慢站失败: %v", err)
	}
	// 只搜这两个本地桩站，避免真的去抓内嵌的 35 个外网站点。
	fastID := magnetCustomID(fast.URL)
	slowID := slowItem.ID

	snapshot, err := magnetSessionBegin(context.Background(), "三体", 1, []int{fastID, slowID}, false, "", 0)
	if err != nil {
		t.Fatalf("建会话失败: %v", err)
	}
	if len(snapshot.Sites) < 2 {
		t.Fatalf("start 应立刻返回全部站标签，实际 %d 个", len(snapshot.Sites))
	}
	if snapshot.Phase != "running" {
		t.Fatalf("start 阶段应为 running，实际 %q", snapshot.Phase)
	}

	// 等到快站结果出现，此时慢站还没返回。
	deadline := time.Now().Add(2 * time.Second)
	sawFast := false
	for time.Now().Before(deadline) {
		next, err := magnetSessionPoll(snapshot.ID, false)
		if err != nil {
			t.Fatalf("poll 失败: %v", err)
		}
		for _, item := range next.Items {
			if strings.Contains(item.Title, "快站资源") {
				sawFast = true
			}
			if strings.Contains(item.Title, "慢站资源") && !sawFast {
				t.Fatal("慢站结果比快站先出现，说明没有边搜边显")
			}
		}
		if sawFast {
			break
		}
		time.Sleep(30 * time.Millisecond)
	}
	if !sawFast {
		t.Fatal("快站结果始终没出现")
	}

	// 最终会话要收敛到 done。
	final := waitMagnetSessionDone(t, snapshot.ID)
	if final.Phase != "done" {
		t.Fatalf("会话应结束，实际 %q", final.Phase)
	}
	magnetSessionStop(snapshot.ID)
}

func waitMagnetSessionDone(t *testing.T, id string) magnetSessionSnapshot {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	var last magnetSessionSnapshot
	for time.Now().Before(deadline) {
		snapshot, err := magnetSessionPoll(id, false)
		if err != nil {
			t.Fatalf("poll 失败: %v", err)
		}
		last = snapshot
		if snapshot.Phase == "done" {
			return snapshot
		}
		time.Sleep(30 * time.Millisecond)
	}
	return last
}

func TestMagnetSessionStopCancelsAndExpires(t *testing.T) {
	withFreshMagnetSources(t)
	snapshot, err := magnetSessionBegin(context.Background(), "三体", 1, []int{-1}, false, "", 0)
	if err != nil {
		t.Fatal(err)
	}
	magnetSessionStop(snapshot.ID)
	if _, err := magnetSessionPoll(snapshot.ID, false); err == nil {
		t.Fatal("会话停止后 poll 应报失效")
	}
	// 空关键词的普通搜索仍然要被拒绝。
	if _, err := magnetSessionBegin(context.Background(), "  ", 1, nil, false, "", 0); err == nil {
		t.Fatal("普通搜索的空关键词应被拒绝")
	}
}

// 元数据缓存：写进去要能读回来，hash 不匹配 / 非法 hash 必须拒绝。
func TestMagnetMetaCacheRoundTrip(t *testing.T) {
	dir := t.TempDir()
	// 用真实元数据算出 hash：读回时会校验文件名与内容一致，不能随便编。
	info := magnetTestMetaInfo(t)
	hash := info.HashInfoBytes().HexString()

	if magnetLoadMeta(dir, hash) != nil {
		t.Fatal("空目录不应读到元数据")
	}

	magnetSaveMeta(dir, hash, info)
	loaded := magnetLoadMeta(dir, hash)
	if loaded == nil {
		t.Fatal("写入后应能读回元数据")
	}
	if len(loaded.InfoBytes) == 0 {
		t.Fatal("读回的元数据缺 info 字典")
	}
	// 文件名与内容不一致时必须当作未命中，避免串种子。
	if magnetLoadMeta(dir, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb") != nil {
		t.Fatal("hash 不匹配的缓存应被拒绝")
	}
	if magnetLoadMeta(dir, "not-a-hash") != nil {
		t.Fatal("非法 hash 不应拼出路径")
	}
	if magnetMetaPath(dir, "../etc/passwd") != "" {
		t.Fatal("非法 hash 不能生成路径")
	}
}

func TestMagnetPruneMetaDropsExpired(t *testing.T) {
	dir := t.TempDir()
	metaDir := magnetMetaDirectory(dir)
	if err := os.MkdirAll(metaDir, 0o700); err != nil {
		t.Fatal(err)
	}
	stale := filepath.Join(metaDir, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.torrent")
	if err := os.WriteFile(stale, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-magnetMetaMaxAge - time.Hour)
	if err := os.Chtimes(stale, old, old); err != nil {
		t.Fatal(err)
	}
	magnetPruneMeta(dir)
	if _, err := os.Stat(stale); !os.IsNotExist(err) {
		t.Fatal("过期元数据应被清理")
	}
}

// 内置源可以被编辑，编辑结果写进覆盖层；恢复默认能还原。
func TestMagnetBuiltinSiteEditableAndReset(t *testing.T) {
	withFreshMagnetSources(t)
	builtin, err := magnetBuiltinByID(10001)
	if err != nil {
		t.Fatalf("找不到内置站: %v", err)
	}
	rule := `{"name":"改过的 SOBT","mainUrl":"` + builtin.Request.MainURL + `",` +
		`"searchUrl":"https://sobt22.top/search-[keyword].html?page=[page]",` +
		`"expressionModel":{"group":"//div[@class='search-item']","title":".//h3/a",` +
		`"url":".//h3/a/@href","magnet":".//h3/a/@href"}}`

	item, err := magnetUpdateCustomSite(10001, "改过的 SOBT", rule, nil)
	if err != nil {
		t.Fatalf("编辑内置源应被允许: %v", err)
	}
	if item.Custom {
		t.Fatal("内置源编辑后仍应标记为非自定义")
	}
	if !item.Edited {
		t.Fatal("编辑后的内置源应带 edited 标记")
	}

	all, err := loadMagnetSites()
	if err != nil {
		t.Fatal(err)
	}
	if len(all) != 35 {
		t.Fatalf("编辑内置源不应改变站源数量，实际 %d", len(all))
	}
	var patched *magnetSite
	for index := range all {
		if all[index].ID == 10001 {
			patched = &all[index]
		}
	}
	if patched == nil || patched.Name != "改过的 SOBT" {
		t.Fatalf("覆盖层没生效: %+v", patched)
	}

	// 恢复默认：覆盖被清掉，回到出厂名。
	if _, err := magnetResetSites(); err != nil {
		t.Fatal(err)
	}
	restored, _ := loadMagnetSites()
	for _, site := range restored {
		if site.ID == 10001 && site.Name != builtin.Name {
			t.Fatalf("恢复默认后应回到出厂名 %q，实际 %q", builtin.Name, site.Name)
		}
	}
	if len(restored) != 35 {
		t.Fatalf("恢复默认后应回到 35 站，实际 %d", len(restored))
	}
}

// 导出要包含内置源当前生效的规则；导入能还原，并且 merge / replace 语义不同。
func TestMagnetExportImportSites(t *testing.T) {
	withFreshMagnetSources(t)
	builtin, err := magnetBuiltinByID(10001)
	if err != nil {
		t.Fatal(err)
	}
	rule := `{"name":"导出测试站","mainUrl":"` + builtin.Request.MainURL + `",` +
		`"searchUrl":"https://sobt22.top/export-[keyword].html",` +
		`"expressionModel":{"group":"//div[@class='search-item']","title":".//h3/a"}}`
	if _, err := magnetUpdateCustomSite(10001, "导出测试站", rule, nil); err != nil {
		t.Fatal(err)
	}

	exported, err := magnetExportSites()
	if err != nil {
		t.Fatal(err)
	}
	sites, _ := exported["sites"].([]magnetSite)
	if len(sites) != 35 {
		t.Fatalf("导出应含全部 35 个站源，实际 %d", len(sites))
	}
	found := false
	for _, site := range sites {
		if site.ID == 10001 && site.Name == "导出测试站" {
			found = true
		}
	}
	if !found {
		t.Fatal("导出内容没带上内置源的修改")
	}

	body, err := jsonMarshalSites(sites)
	if err != nil {
		t.Fatal(err)
	}
	// 恢复默认后导入 merge，应把修改找回来。
	if _, err := magnetResetSites(); err != nil {
		t.Fatal(err)
	}
	result, err := magnetImportSites(body, "merge")
	if err != nil {
		t.Fatalf("导入失败: %v", err)
	}
	if result["updated"].(int)+result["added"].(int) == 0 {
		t.Fatal("导入应至少处理一条站源")
	}
	after, _ := loadMagnetSites()
	for _, site := range after {
		if site.ID == 10001 && site.Name != "导出测试站" {
			t.Fatalf("导入后内置覆盖没生效，实际 %q", site.Name)
		}
	}

	// replace 模式会先清空，再按导入内容重建。
	if _, err := magnetImportSites(body, "replace"); err != nil {
		t.Fatal(err)
	}
	replaced, _ := loadMagnetSites()
	if len(replaced) != 35 {
		t.Fatalf("replace 后应仍为 35 站，实际 %d", len(replaced))
	}

	if _, err := magnetImportSites("", "merge"); err == nil {
		t.Fatal("空内容应被拒绝")
	}
	if _, err := magnetImportSites("not-json", "merge"); err == nil {
		t.Fatal("非法 JSON 应被拒绝")
	}
	if _, err := magnetImportSites(`{"sites":[]}`, "merge"); err == nil {
		t.Fatal("没有站源时应被拒绝")
	}
}

// 会话在同一时刻只保留有限个，避免用户连点搜索把内存拖大。
func TestMagnetSessionKeepsBounded(t *testing.T) {
	withFreshMagnetSources(t)
	var created []string
	for i := 0; i < magnetSessionKeep+3; i++ {
		snapshot, err := magnetSessionBegin(context.Background(), "三体", 1, []int{-1}, false, "", 0)
		if err != nil {
			t.Fatal(err)
		}
		created = append(created, snapshot.ID)
	}
	alive := 0
	for _, id := range created {
		if magnetSessionGet(id) != nil {
			alive++
		}
	}
	if alive > magnetSessionKeep {
		t.Fatalf("会话数应被限制在 %d 以内，实际 %d", magnetSessionKeep, alive)
	}
	for _, id := range created {
		magnetSessionStop(id)
	}
}

// 并发 poll / stop 不应 panic 或死锁。
func TestMagnetSessionConcurrentAccess(t *testing.T) {
	withFreshMagnetSources(t)
	snapshot, err := magnetSessionBegin(context.Background(), "三体", 1, []int{-1}, false, "", 0)
	if err != nil {
		t.Fatal(err)
	}
	var done atomic.Int32
	for i := 0; i < 8; i++ {
		go func() {
			defer done.Add(1)
			for j := 0; j < 10; j++ {
				_, _ = magnetSessionPoll(snapshot.ID, false)
			}
		}()
	}
	for done.Load() < 8 {
		time.Sleep(10 * time.Millisecond)
	}
	magnetSessionStop(snapshot.ID)
}

// magnetTestMetaInfo 造一份最小可用的种子元数据：单文件 + 一个整块。
func magnetTestMetaInfo(t *testing.T) metainfo.MetaInfo {
	t.Helper()
	info := metainfo.Info{
		Name:        "test.bin",
		PieceLength: 16 << 10,
		Length:      16 << 10,
		// 一个 16KiB 块对应一个 20 字节 SHA1。
		Pieces: make([]byte, 20),
	}
	body, err := bencode.Marshal(info)
	if err != nil {
		t.Fatalf("构造 info 失败: %v", err)
	}
	return metainfo.MetaInfo{InfoBytes: body}
}

func jsonMarshalSites(sites []magnetSite) (string, error) {
	body, err := json.Marshal(map[string]any{"version": 1, "sites": sites})
	if err != nil {
		return "", err
	}
	return string(body), nil
}

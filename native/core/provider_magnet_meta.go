package core

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/anacrolix/torrent"
	"github.com/anacrolix/torrent/metainfo"
)

// 磁力「解析慢」的主因是每次都要等 DHT / tracker 把种子元数据（info 字典）拉回来，
// 冷门种子在国内网络经常要十几秒甚至超时。cibo 用迅雷 SDK，元数据由迅雷服务端
// 缓存直接给，这一点无法复刻；但「同一个种子第二次打开」可以做到秒开——把拿到的
// 元数据按 infohash 落盘，下次直接 AddTorrentSpec(InfoBytes) 跳过等待。
//
// 目录放在 <dataDir>/magnet-meta/<hash>.torrent，属于可清理缓存：
// 「设置 → 清理缓存」里按磁力缓存一起统计与删除，删掉只是下次重新走 DHT。
const (
	magnetMetaDirName = "magnet-meta"
	// 元数据本身很小（几十 KB），但条数可能很多，限制总量避免无限增长。
	magnetMetaMaxFiles = 2000
	magnetMetaMaxAge   = 30 * 24 * time.Hour
)

func magnetMetaDirectory(base string) string {
	return filepath.Join(base, magnetMetaDirName)
}

// magnetMetaPath 只接受合法 infohash，避免把用户输入拼进路径。
func magnetMetaPath(base, hash string) string {
	hash = strings.ToLower(strings.TrimSpace(hash))
	if !magnetHashValid(hash) {
		return ""
	}
	return filepath.Join(magnetMetaDirectory(base), hash+".torrent")
}

// magnetLoadMeta 读本地缓存的元数据；没有或损坏时返回 nil。
func magnetLoadMeta(base, hash string) *metainfo.MetaInfo {
	path := magnetMetaPath(base, hash)
	if path == "" {
		return nil
	}
	file, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer file.Close()
	info, err := metainfo.Load(file)
	if err != nil || info == nil {
		return nil
	}
	// 校验 hash 与请求一致，防止缓存文件被替换或命名错位。
	if info.HashInfoBytes().HexString() != strings.ToLower(strings.TrimSpace(hash)) {
		return nil
	}
	// 顺带刷新访问时间，便于按 LRU 淘汰。
	now := time.Now()
	_ = os.Chtimes(path, now, now)
	return info
}

// magnetSaveMeta 把拿到的元数据落盘，失败不影响播放。
func magnetSaveMeta(base, hash string, info metainfo.MetaInfo) {
	path := magnetMetaPath(base, hash)
	if path == "" {
		return
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return
	}
	file, err := os.Create(path)
	if err != nil {
		return
	}
	defer file.Close()
	if err := info.Write(file); err != nil {
		_ = file.Close()
		_ = os.Remove(path)
	}
}

// magnetPruneMeta 控制元数据缓存规模：先按最后访问时间淘汰过期项，
// 仍然超出条数上限时按最旧访问时间删到上限以内。
func magnetPruneMeta(base string) {
	dir := magnetMetaDirectory(base)
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	type record struct {
		path string
		at   time.Time
	}
	records := make([]record, 0, len(entries))
	now := time.Now()
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".torrent") {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			continue
		}
		path := filepath.Join(dir, entry.Name())
		if now.Sub(info.ModTime()) > magnetMetaMaxAge {
			_ = os.Remove(path)
			continue
		}
		records = append(records, record{path: path, at: info.ModTime()})
	}
	excess := len(records) - magnetMetaMaxFiles
	if excess <= 0 {
		return
	}
	// 简单选择排序取最旧的若干个，条数规模小，不值得引入 sort 依赖的额外开销。
	for i := 0; i < excess; i++ {
		oldest := i
		for j := i + 1; j < len(records); j++ {
			if records[j].at.Before(records[oldest].at) {
				oldest = j
			}
		}
		records[i], records[oldest] = records[oldest], records[i]
		_ = os.Remove(records[i].path)
	}
}

// addMagnetFast 是 prepare / 探测共用的「加磁力」入口：本地有元数据时直接用
// InfoBytes 建任务，跳过 DHT 等待；没有才走 AddMagnet。
func (state *magnetStreamEngineState) addMagnetFast(link, hash string) (*torrent.Torrent, error) {
	if state.metaDir != "" {
		if info := magnetLoadMeta(state.metaDir, hash); info != nil {
			spec, err := torrent.TorrentSpecFromMetaInfoErr(info)
			if err == nil && len(spec.InfoBytes) > 0 {
				for _, tracker := range magnetPublicTrackers {
					spec.Trackers = append(spec.Trackers, []string{tracker})
				}
				task, _, addErr := state.client.AddTorrentSpec(spec)
				if addErr == nil && task != nil {
					return task, nil
				}
			}
		}
	}
	return state.client.AddMagnet(magnetWithTrackers(link))
}

// rememberMeta 在拿到元数据后落盘，并顺手做一次规模控制。
func (state *magnetStreamEngineState) rememberMeta(hash string, task *torrent.Torrent) {
	if state.metaDir == "" || task == nil {
		return
	}
	select {
	case <-task.GotInfo():
	default:
		return // 元数据还没到，别把空 info 写进缓存
	}
	magnetSaveMeta(state.metaDir, hash, task.Metainfo())
}

// magnetWarmup 提前把 BT 客户端与 DHT 拉起来。磁力页一打开就调，等用户真正点播放时
// DHT 路由表已经有节点，能省掉 1~3 秒的冷启动。失败不影响后续（播放时会再懒启动）。
func magnetWarmup(dataDir string) bool {
	state, err := magnetEngine(dataDir)
	if err != nil {
		return false
	}
	// 触发一次 DHT 查询，让路由表尽快填满；不关心结果。
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
		defer cancel()
		state.probePeers(ctx, nil)
	}()
	go magnetPruneMeta(dataDir)
	return true
}

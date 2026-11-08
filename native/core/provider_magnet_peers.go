package core

import (
	"context"
	"reflect"
	"strings"
	"sync"
	"time"

	"github.com/anacrolix/torrent"
)

// 每个磁力片源的「可连接 DHT 数量」通过真实 BT 客户端探测：把 infohash 加进
// 客户端（带公共 tracker + DHT），在一个短窗口里收集 get_peers / announce 返回的
// 节点，再按来源统计 DHT 节点数与总可连接节点数。探测不下载文件，结束后
// 未用于播放的 torrent 会被 Drop，不会长期占用连接。
const (
	magnetPeerMaxBatch = 24
	magnetPeerWindow   = 6 * time.Second
	magnetPeerTTL      = 5 * time.Minute
	magnetPeerWorkers  = 8
)

type magnetPeerItem struct {
	Hash      string `json:"hash"`
	DHT       int    `json:"dht"`
	Peers     int    `json:"peers"`
	Connected int    `json:"connected"`
}

type magnetPeerResult struct {
	Items    []magnetPeerItem `json:"items"`
	DHTNodes int              `json:"dhtNodes"`
	Probing  int              `json:"probing"`
}

type magnetPeerCacheEntry struct {
	item magnetPeerItem
	at   time.Time
}

var magnetPeerCache = struct {
	mu     sync.Mutex
	values map[string]magnetPeerCacheEntry
}{values: map[string]magnetPeerCacheEntry{}}

var magnetProbeState = struct {
	mu     sync.Mutex
	cancel context.CancelFunc
	token  int64
}{}

// magnetProbeBegin 让新一轮探测取消上一轮还没跑完的等待窗口。切站源标签时
// 旧标签的探测没必要继续占着 DHT 连接。
func magnetProbeBegin(parent context.Context) (context.Context, func()) {
	magnetProbeState.mu.Lock()
	if magnetProbeState.cancel != nil {
		magnetProbeState.cancel()
	}
	magnetProbeState.token++
	token := magnetProbeState.token
	ctx, cancel := context.WithCancel(parent)
	magnetProbeState.cancel = cancel
	magnetProbeState.mu.Unlock()
	return ctx, func() {
		magnetProbeState.mu.Lock()
		if magnetProbeState.token == token {
			magnetProbeState.cancel = nil
		}
		magnetProbeState.mu.Unlock()
		cancel()
	}
}

// magnetHashValid 只放行 40 位 hex / 32 位 base32 infohash，避免把标题里的
// 普通英文单词当成种子交给 AddMagnet。
func magnetHashValid(hash string) bool {
	validHex := func() bool {
		if len(hash) != 40 {
			return false
		}
		for _, char := range hash {
			if (char < '0' || char > '9') && (char < 'a' || char > 'f') {
				return false
			}
		}
		return true
	}
	validBase32 := func() bool {
		if len(hash) != 32 {
			return false
		}
		for _, char := range hash {
			if (char < 'a' || char > 'z') && (char < '2' || char > '7') {
				return false
			}
		}
		return true
	}
	return validHex() || validBase32()
}

// magnetDhtNodes 读 DHT 路由表里的好节点数，作为「DHT 网络是否连上」的全局提示。
// DhtServer.Stats() 返回 interface{}，用反射读字段可兼容值 / 指针两种实现。
func magnetDhtNodes(client *torrent.Client) int {
	total := 0
	for _, server := range client.DhtServers() {
		value := reflect.ValueOf(server.Stats())
		for value.Kind() == reflect.Ptr || value.Kind() == reflect.Interface {
			if value.IsNil() {
				break
			}
			value = value.Elem()
		}
		if value.Kind() != reflect.Struct {
			continue
		}
		for _, name := range []string{"GoodNodes", "Nodes"} {
			field := value.FieldByName(name)
			if field.IsValid() && field.Kind() == reflect.Int {
				total += int(field.Int())
				break
			}
		}
	}
	return total
}

// state.probePeers 只做探测，不碰 state.tasks（播放用的 torrent 登记表）。
func (state *magnetStreamEngineState) probePeers(ctx context.Context, hashes []string) []magnetPeerItem {
	tasks := make(map[string]*torrent.Torrent, len(hashes))
	var mu sync.Mutex
	var wait sync.WaitGroup
	limit := make(chan struct{}, magnetPeerWorkers)
	for _, hash := range hashes {
		wait.Add(1)
		go func(value string) {
			defer wait.Done()
			select {
			case limit <- struct{}{}:
			case <-ctx.Done():
				return
			}
			defer func() { <-limit }()
			task, err := state.client.AddMagnet(magnetWithTrackers(magnetCanonical(value, "")))
			if err != nil || task == nil {
				return
			}
			mu.Lock()
			tasks[value] = task
			mu.Unlock()
		}(hash)
	}
	wait.Wait()

	if len(tasks) > 0 {
		timer := time.NewTimer(magnetPeerWindow)
		defer timer.Stop()
		select {
		case <-timer.C:
		case <-ctx.Done():
		}
	}
	items := make([]magnetPeerItem, 0, len(tasks))
	for hash, task := range tasks {
		swarm := task.KnownSwarm()
		dht := 0
		for _, peer := range swarm {
			if peer.Source == torrent.PeerSourceDhtGetPeers ||
				peer.Source == torrent.PeerSourceDhtAnnouncePeer {
				dht++
			}
		}
		items = append(items, magnetPeerItem{
			Hash:      hash,
			DHT:       dht,
			Peers:     len(swarm),
			Connected: len(task.PeerConns()),
		})
		// 播放登记过的 torrent 要留着，否则会把正在看的流掐断。
		if !state.isTask(hash) {
			task.Drop()
		}
	}
	return items
}

// magnetPeers 返回这一批 infohash 的可连接节点数。缓存命中直接返回，
// 未命中的统一跑一轮短探测；force 跳过缓存（界面上的「刷新 DHT」）。
// 引擎起不来时返回全 0，不让搜索页整页报错。
func magnetPeers(ctx context.Context, hashes []string, dataDir string, force bool) (magnetPeerResult, error) {
	result := magnetPeerResult{Items: []magnetPeerItem{}}
	unique := make([]string, 0, len(hashes))
	seen := map[string]bool{}
	for _, raw := range hashes {
		hash := strings.ToLower(strings.TrimSpace(raw))
		if !magnetHashValid(hash) || seen[hash] {
			continue
		}
		seen[hash] = true
		unique = append(unique, hash)
		if len(unique) >= magnetPeerMaxBatch {
			break
		}
	}
	if len(unique) == 0 {
		return result, nil
	}

	cached := map[string]magnetPeerItem{}
	pending := make([]string, 0, len(unique))
	now := time.Now()
	magnetPeerCache.mu.Lock()
	for _, hash := range unique {
		entry, ok := magnetPeerCache.values[hash]
		if ok && !force && now.Sub(entry.at) < magnetPeerTTL {
			cached[hash] = entry.item
		} else {
			pending = append(pending, hash)
		}
	}
	magnetPeerCache.mu.Unlock()

	if len(pending) > 0 {
		probeCtx, finish := magnetProbeBegin(ctx)
		defer finish()
		state, err := magnetEngine(dataDir)
		if err == nil {
			probed := state.probePeers(probeCtx, pending)
			for _, item := range probed {
				cached[item.Hash] = item
				// 被新请求取消的窗口数据不完整，不写缓存，下一轮会重新探测。
				if probeCtx.Err() == nil {
					magnetPeerCache.mu.Lock()
					magnetPeerCache.values[item.Hash] = magnetPeerCacheEntry{item: item, at: now}
					magnetPeerCache.mu.Unlock()
				}
			}
			result.DHTNodes = magnetDhtNodes(state.client)
		}
		result.Probing = len(pending)
	}
	for _, hash := range unique {
		item, ok := cached[hash]
		if !ok {
			item = magnetPeerItem{Hash: hash}
		}
		result.Items = append(result.Items, item)
	}
	return result, nil
}

// magnetCancelAll 立即终止所有正在进行的磁力加载，并释放 BT 分片 / 连接。
// 用户点下另一条磁力、或离开磁力页时调用。
func magnetCancelAll() {
	state := magnetCurrentEngine()
	var drop func(string)
	if state != nil {
		drop = state.dropTorrent
	}
	magnetLoads.cancelAll(drop)
	if state != nil {
		state.dropLastTask()
	}
	// 探测窗口也一起收掉，避免它继续占 DHT 连接拖慢新的播放。
	magnetProbeState.mu.Lock()
	if magnetProbeState.cancel != nil {
		magnetProbeState.cancel()
		magnetProbeState.cancel = nil
	}
	magnetProbeState.mu.Unlock()
}

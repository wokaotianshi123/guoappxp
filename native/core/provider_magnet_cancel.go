package core

import (
	"context"
	"sync"
)

// 磁力切换要「即刻生效」：用户点下另一条磁力时，上一条还在等 DHT / tracker
// 返回元数据的 goroutine 必须马上退出，并把它占用的连接与分片下载释放掉。
//
// FFI 的 _nativeRequest 是同步调用，Dart 每次请求都跑在独立 Isolate 里，
// 所以 magnetCancel 能与正在阻塞的 magnetFiles / magnetPlay 并发进入 Go 核心。
// 这里用一张「活动加载表」记录每一条正在 prepare 的磁力，按 infohash 聚合引用：
// 同一个 hash 的 magnetFiles / magnetPlay 共享一个可取消 context，不同 hash 的
// 新请求会先把其它 hash 全部取消。
type magnetLoad struct {
	ctx    context.Context
	cancel context.CancelFunc
	refs   int
}

type magnetLoadManager struct {
	mu     sync.Mutex
	active map[string]*magnetLoad
}

var magnetLoads = &magnetLoadManager{active: map[string]*magnetLoad{}}

// begin 注册一次加载；onDrop 在锁外回调，避免与引擎的 state.mu 形成锁环。
func (m *magnetLoadManager) begin(parent context.Context, hash string, onDrop func(string)) (context.Context, func()) {
	m.mu.Lock()
	dropped := make([]string, 0, len(m.active))
	for other, load := range m.active {
		if other == hash {
			continue
		}
		load.cancel()
		delete(m.active, other)
		dropped = append(dropped, other)
	}
	load := m.active[hash]
	if load == nil {
		ctx, cancel := context.WithCancel(parent)
		load = &magnetLoad{ctx: ctx, cancel: cancel}
		m.active[hash] = load
	}
	load.refs++
	ctx := load.ctx
	m.mu.Unlock()

	for _, other := range dropped {
		if onDrop != nil {
			onDrop(other)
		}
	}
	return ctx, func() {
		m.mu.Lock()
		defer m.mu.Unlock()
		if m.active[hash] != load {
			return
		}
		load.refs--
		if load.refs <= 0 {
			delete(m.active, hash)
			load.cancel()
		}
	}
}

func (m *magnetLoadManager) cancelAll(onDrop func(string)) {
	m.mu.Lock()
	dropped := make([]string, 0, len(m.active))
	for hash, load := range m.active {
		load.cancel()
		delete(m.active, hash)
		dropped = append(dropped, hash)
	}
	m.mu.Unlock()
	for _, hash := range dropped {
		if onDrop != nil {
			onDrop(hash)
		}
	}
}

func (m *magnetLoadManager) pending() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return len(m.active)
}

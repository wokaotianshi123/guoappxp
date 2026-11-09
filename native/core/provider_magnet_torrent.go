package core

import (
	"context"
	"errors"
	"fmt"
	"mime"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/anacrolix/torrent"
)

// cibo.apk 的磁力播放是「迅雷 SDK 把磁力解析成种子 → 下载视频文件 → 本地播放器播放」。
// 迅雷 SDK 是 Android 闭源 .so，搬不进 Go 核心 / Flutter 五端，这里做等价重实现：
// 纯 Go BT 客户端解析元数据并下载选中文件，同时在本机起一个支持 Range 的 HTTP 端点，
// 把 http://127.0.0.1:<port>/magnet/<hash>/<index> 交给 guoappxp 现有的播放器。
// 本地服务版的 rewriteLocalMedia 会把这个地址改写成 /api/media/... 反向代理，局域网设备同样可用。
const (
	magnetMetadataBudget = 40 * time.Second
	// readahead 是播放器读位置的预读窗口。原来 16MB 在拖动进度条时经常卡住等分片，
	// 提到 32MB 让「起播」和「小幅度拖动」更快出画面。
	magnetReadahead = 32 << 20
)

type magnetFileItem struct {
	Index int    `json:"index"`
	Name  string `json:"name"`
	Size  int64  `json:"size"`
	Video bool   `json:"video"`
}

type magnetStreamEngineState struct {
	client   *torrent.Client
	listener net.Listener
	base     string
	// metaDir 是种子元数据缓存目录（<dataDir>/magnet-meta）。命中时用 InfoBytes
	// 直接建任务，跳过 DHT 等待，第二次打开同一个种子基本秒开。
	metaDir string
	mu      sync.Mutex
	tasks   map[string]*torrent.Torrent
	files   map[string]map[int]*torrent.File
	// lastHash 记住最近一次 prepare 的种子：即使上一次加载已经结束，
	// 用户点另一条磁力时也要把它的下载分片停掉，别让旧任务抢带宽。
	lastHash string
}

var (
	magnetEngineMu    sync.Mutex
	magnetEngineState *magnetStreamEngineState
)

// magnetCacheDirectory 固定落在 initialize 传入的应用数据目录里。
// 不能用 os.TempDir()：Android 上它是 /data/local/tmp，普通应用没有写权限，
// 点磁力播放会直接报 "mkdir /data/local/tmp/duanjuapp-magnet: permission denied"。
// 固定路径也让「清理缓存」能准确找到 BT 分片。
func magnetCacheDirectory(base string) string {
	return filepath.Join(base, "magnet-cache")
}

func magnetEngineDataDir(base string) (string, error) {
	base = strings.TrimSpace(base)
	if base == "" || !filepath.IsAbs(base) {
		return "", errors.New("应用数据目录未设置")
	}
	dir := magnetCacheDirectory(base)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	probe, err := os.CreateTemp(dir, ".write-test-*")
	if err != nil {
		return "", err
	}
	name := probe.Name()
	_ = probe.Close()
	_ = os.Remove(name)
	return dir, nil
}

// magnetPublicTrackers 补在规范化磁力后面。cisou 的站源很多只给 infohash，
// 没有 tracker 时单靠 DHT 在国内网络里经常拿不到元数据。
var magnetPublicTrackers = []string{
	"udp://tracker.opentrackr.org:1337/announce",
	"udp://open.stealth.si:80/announce",
	"udp://tracker.torrent.eu.org:451/announce",
}

func magnetWithTrackers(link string) string {
	if !strings.HasPrefix(link, "magnet:?") {
		return link
	}
	for _, tracker := range magnetPublicTrackers {
		if !strings.Contains(link, "tr="+tracker) {
			link += "&tr=" + tracker
		}
	}
	return link
}

// magnetEngine 懒启动 BT 客户端与本机流服务。用互斥锁而不是 sync.Once：
// 一次初始化失败（例如权限或端口问题）不应把错误永久钉死，用户重试或
// 清理缓存后应能重新拉起引擎。
func magnetEngine(dataDir string) (*magnetStreamEngineState, error) {
	magnetEngineMu.Lock()
	defer magnetEngineMu.Unlock()
	if magnetEngineState != nil {
		return magnetEngineState, nil
	}
	dir, err := magnetEngineDataDir(dataDir)
	if err != nil {
		return nil, fmt.Errorf("磁力缓存目录不可用：%w", err)
	}
	config := torrent.NewDefaultClientConfig()
	config.DataDir = dir
	config.Seed = false
	config.NoUpload = true
	config.NoDefaultPortForwarding = true
	client, err := torrent.NewClient(config)
	if err != nil {
		return nil, fmt.Errorf("启动 BT 引擎失败：%w", err)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		_ = client.Close()
		return nil, fmt.Errorf("启动磁力本机播放服务失败：%w", err)
	}
	state := &magnetStreamEngineState{
		client:   client,
		listener: listener,
		base:     "http://127.0.0.1:" + strconv.Itoa(listener.Addr().(*net.TCPAddr).Port) + "/",
		metaDir:  dataDir,
		tasks:    map[string]*torrent.Torrent{},
		files:    map[string]map[int]*torrent.File{},
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/magnet/", state.serve)
	go func() { _ = http.Serve(listener, mux) }()
	magnetEngineState = state
	return state, nil
}

// magnetEngineReset 关闭 BT 客户端，释放它持有的分片文件句柄，再允许清理
// 磁力缓存；下次播放会重新懒启动。Windows 上不关闭客户端是删不掉分片的。
func magnetEngineReset() {
	magnetEngineMu.Lock()
	defer magnetEngineMu.Unlock()
	state := magnetEngineState
	if state == nil {
		return
	}
	magnetEngineState = nil
	state.mu.Lock()
	state.tasks = map[string]*torrent.Torrent{}
	state.files = map[string]map[int]*torrent.File{}
	state.lastHash = ""
	state.mu.Unlock()
	_ = state.client.Close()
	_ = state.listener.Close()
}

// magnetCurrentEngine 只读当前引擎，找不到时返回 nil，绝不在这里懒启动：
// 取消动作不应该为了「停止」而把 BT 客户端又拉起来。
func magnetCurrentEngine() *magnetStreamEngineState {
	magnetEngineMu.Lock()
	defer magnetEngineMu.Unlock()
	return magnetEngineState
}

// dropTorrent 释放某个种子占的连接与分片句柄，并从登记表里摘掉。
// 之后同一个 hash 再播放会重新 AddMagnet，是干净的切换语义。
func (state *magnetStreamEngineState) dropTorrent(hash string) {
	state.mu.Lock()
	task := state.tasks[hash]
	delete(state.tasks, hash)
	delete(state.files, hash)
	if state.lastHash == hash {
		state.lastHash = ""
	}
	state.mu.Unlock()
	if task != nil {
		task.Drop()
	}
}

func (state *magnetStreamEngineState) dropLastTask() {
	state.mu.Lock()
	hash := state.lastHash
	state.lastHash = ""
	state.mu.Unlock()
	if hash != "" {
		state.dropTorrent(hash)
	}
}

func (state *magnetStreamEngineState) isTask(hash string) bool {
	state.mu.Lock()
	defer state.mu.Unlock()
	_, ok := state.tasks[hash]
	return ok
}

// beginTask 记录本次播放的种子，并把上一条种子停掉。
func (state *magnetStreamEngineState) beginTask(hash string) {
	state.mu.Lock()
	previous := state.lastHash
	state.lastHash = hash
	state.mu.Unlock()
	if previous != "" && previous != hash {
		state.dropTorrent(previous)
	}
}

func magnetVideoExtension(name string) bool {
	switch strings.ToLower(filepath.Ext(name)) {
	case ".mp4", ".mkv", ".avi", ".mov", ".m4v", ".flv", ".wmv", ".rmvb", ".rm", ".ts", ".webm", ".mpg", ".mpeg", ".3gp", ".f4v":
		return true
	default:
		return false
	}
}

func magnetPickFile(files []magnetFileItem, wanted int) (int, error) {
	if len(files) == 0 {
		return 0, errors.New("种子里没有可播放的文件")
	}
	if wanted >= 0 && wanted < len(files) {
		return wanted, nil
	}
	best, bestSize := -1, int64(-1)
	for _, file := range files {
		if file.Video && file.Size > bestSize {
			best, bestSize = file.Index, file.Size
		}
	}
	if best < 0 {
		// 没有明显视频后缀时挑最大的文件，避免直接判失败。
		for _, file := range files {
			if file.Size > bestSize {
				best, bestSize = file.Index, file.Size
			}
		}
	}
	if best < 0 {
		return 0, errors.New("种子里没有可播放的文件")
	}
	return best, nil
}

// prepare 添加磁力、等待元数据并登记文件索引。
// 每次 prepare 都会先取消其它 infohash 仍在等待的加载：用户点另一条磁力时，
// 旧任务立刻退出并释放连接，不必等它 40 秒超时。
func (state *magnetStreamEngineState) prepare(ctx context.Context, link string) (string, []magnetFileItem, error) {
	hash := magnetInfoHash(link)
	if hash == "" {
		return "", nil, errors.New("磁力链接无效，未找到 infohash")
	}
	loadCtx, finish := magnetLoads.begin(ctx, hash, state.dropTorrent)
	defer finish()
	state.beginTask(hash)

	state.mu.Lock()
	task, exists := state.tasks[hash]
	if !exists {
		created, err := state.addMagnetFast(link, hash)
		if err != nil {
			state.mu.Unlock()
			return "", nil, fmt.Errorf("添加磁力失败：%w", err)
		}
		state.tasks[hash] = created
		task = created
	}
	state.mu.Unlock()
	if loadCtx.Err() != nil {
		return hash, nil, errors.New("已取消上一条磁力的加载")
	}

	budget, cancel := context.WithTimeout(loadCtx, magnetMetadataBudget)
	defer cancel()
	select {
	case <-task.GotInfo():
	case <-budget.Done():
		if loadCtx.Err() != nil {
			return hash, nil, errors.New("已取消上一条磁力的加载")
		}
		return hash, nil, errors.New("获取种子信息超时，请检查网络后重试")
	}
	if loadCtx.Err() != nil {
		return hash, nil, errors.New("已取消上一条磁力的加载")
	}
	// 拿到元数据就落盘，下次打开同一个种子不必再等 DHT。
	state.rememberMeta(hash, task)

	raw := task.Files()
	items := make([]magnetFileItem, 0, len(raw))
	indexed := make(map[int]*torrent.File, len(raw))
	for i, file := range raw {
		name := file.DisplayPath()
		indexed[i] = file
		items = append(items, magnetFileItem{
			Index: i,
			Name:  name,
			Size:  file.Length(),
			Video: magnetVideoExtension(name),
		})
	}
	state.mu.Lock()
	state.files[hash] = indexed
	state.mu.Unlock()
	return hash, items, nil
}

func magnetContentType(name string) string {
	if detected := mime.TypeByExtension(filepath.Ext(name)); detected != "" {
		return detected
	}
	return "video/mp4"
}

// serve 把种子里的单个文件当成本地视频流提供，http.ServeContent 负责 Range / 206。
// Reader 会在所需分片尚未下载完成时阻塞，这就是边下边播的缓冲行为。
func (state *magnetStreamEngineState) serve(writer http.ResponseWriter, request *http.Request) {
	parts := strings.Split(strings.Trim(strings.TrimPrefix(request.URL.Path, "/magnet/"), "/"), "/")
	if len(parts) != 2 {
		http.Error(writer, "磁力流地址无效", http.StatusBadRequest)
		return
	}
	index, err := strconv.Atoi(parts[1])
	if err != nil {
		http.Error(writer, "分集编号无效", http.StatusBadRequest)
		return
	}
	state.mu.Lock()
	files := state.files[parts[0]]
	file := files[index]
	state.mu.Unlock()
	if file == nil {
		http.Error(writer, "种子还在解析中，请稍后重试", http.StatusServiceUnavailable)
		return
	}
	file.Download()
	reader := file.NewReader()
	defer reader.Close()
	reader.SetReadahead(magnetReadahead)
	name := filepath.Base(file.DisplayPath())
	writer.Header().Set("Content-Type", magnetContentType(name))
	writer.Header().Set("Accept-Ranges", "bytes")
	http.ServeContent(writer, request, name, time.Time{}, reader)
}

func magnetFileList(ctx context.Context, link, dataDir string) (map[string]any, error) {
	state, err := magnetEngine(dataDir)
	if err != nil {
		return nil, err
	}
	hash, items, err := state.prepare(ctx, link)
	if err != nil {
		return nil, err
	}
	return map[string]any{"hash": hash, "items": items}, nil
}

// magnetPlaybackPlan 返回 guoappxp 播放器能直接吃的 PlaybackPlan。
func magnetPlaybackPlan(ctx context.Context, link string, wanted int, dataDir string) (nativePlan, error) {
	state, err := magnetEngine(dataDir)
	if err != nil {
		return nativePlan{}, err
	}
	hash, items, err := state.prepare(ctx, link)
	if err != nil {
		return nativePlan{}, err
	}
	index, err := magnetPickFile(items, wanted)
	if err != nil {
		return nativePlan{}, err
	}
	state.mu.Lock()
	file := state.files[hash][index]
	state.mu.Unlock()
	if file != nil {
		file.Download()
	}
	return nativePlan{
		URL:        state.base + "magnet/" + hash + "/" + strconv.Itoa(index),
		Headers:    map[string]string{},
		Local:      true,
		Quality:    0,
		Qualities:  []int{0},
		RouteIndex: 0,
		RouteCount: 1,
	}, nil
}

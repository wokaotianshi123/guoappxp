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
	magnetReadahead      = 16 << 20
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
	mu       sync.Mutex
	tasks    map[string]*torrent.Torrent
	files    map[string]map[int]*torrent.File
}

var (
	magnetEngineOnce  sync.Once
	magnetEngineState *magnetStreamEngineState
	magnetEngineError error
)

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

func magnetEngine() (*magnetStreamEngineState, error) {
	magnetEngineOnce.Do(func() {
		dataDir := filepath.Join(os.TempDir(), "duanjuapp-magnet")
		if err := os.MkdirAll(dataDir, 0o755); err != nil {
			magnetEngineError = err
			return
		}
		config := torrent.NewDefaultClientConfig()
		config.DataDir = dataDir
		config.Seed = false
		config.NoUpload = true
		config.NoDefaultPortForwarding = true
		client, err := torrent.NewClient(config)
		if err != nil {
			magnetEngineError = err
			return
		}
		listener, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			_ = client.Close()
			magnetEngineError = err
			return
		}
		state := &magnetStreamEngineState{
			client:   client,
			listener: listener,
			base:     "http://127.0.0.1:" + strconv.Itoa(listener.Addr().(*net.TCPAddr).Port) + "/",
			tasks:    map[string]*torrent.Torrent{},
			files:    map[string]map[int]*torrent.File{},
		}
		mux := http.NewServeMux()
		mux.HandleFunc("/magnet/", state.serve)
		go func() { _ = http.Serve(listener, mux) }()
		magnetEngineState = state
	})
	return magnetEngineState, magnetEngineError
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

// prepare 添加磁力、等待元数据并登记文件索引。超时不删除任务，后台会继续找种子，
// 用户稍后重试就能直接命中缓存。
func (state *magnetStreamEngineState) prepare(ctx context.Context, link string) (string, []magnetFileItem, error) {
	hash := magnetInfoHash(link)
	if hash == "" {
		return "", nil, errors.New("磁力链接无效，未找到 infohash")
	}
	state.mu.Lock()
	task, exists := state.tasks[hash]
	if !exists {
		created, err := state.client.AddMagnet(magnetWithTrackers(link))
		if err != nil {
			state.mu.Unlock()
			return "", nil, fmt.Errorf("添加磁力失败：%w", err)
		}
		state.tasks[hash] = created
		task = created
	}
	state.mu.Unlock()

	budget, cancel := context.WithTimeout(ctx, magnetMetadataBudget)
	defer cancel()
	select {
	case <-task.GotInfo():
	case <-budget.Done():
		return hash, nil, errors.New("获取种子信息超时，请检查网络后重试")
	}

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

func magnetFileList(ctx context.Context, link string) (map[string]any, error) {
	state, err := magnetEngine()
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
func magnetPlaybackPlan(ctx context.Context, link string, wanted int) (nativePlan, error) {
	state, err := magnetEngine()
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

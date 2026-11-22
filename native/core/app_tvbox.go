package core

import (
	"context"
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"

	"duanjuapp/native/core/tvbox"
)

type tvboxSubscriptionState struct {
	URL            string       `json:"url"`
	Spider         string       `json:"spider,omitempty"`
	Sites          []tvbox.Site `json:"sites"`
	RegisteredIDs  []string     `json:"registeredIds"`
	SupportedCount int          `json:"supportedCount"`
	SkippedCount   int          `json:"skippedCount"`
}

var (
	tvboxMu          sync.Mutex
	tvboxState       *tvboxSubscriptionState
	tvboxLoaded      bool
	tvboxKeySafe     = regexp.MustCompile(`[^a-zA-Z0-9_-]+`)
	spiderBridgeMu   sync.RWMutex
	spiderBridgePort int
)

func (engine *nativeEngine) setSpiderBridge(port int) map[string]any {
	spiderBridgeMu.Lock()
	if port > 0 {
		spiderBridgePort = port
	}
	spiderBridgeMu.Unlock()
	return map[string]any{"ok": true, "port": port}
}

func (engine *nativeEngine) tvboxConfigPath() string {
	dir := filepath.Clean(engine.directory)
	if dir == "" || dir == "." {
		return ""
	}
	return filepath.Join(dir, "tvbox-config.json")
}

func (engine *nativeEngine) tvboxEnsureLoaded() {
	tvboxMu.Lock()
	defer tvboxMu.Unlock()
	if tvboxLoaded {
		return
	}
	tvboxLoaded = true

	path := engine.tvboxConfigPath()
	if path == "" {
		return
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var saved tvboxSubscriptionState
	if err := json.Unmarshal(raw, &saved); err != nil {
		return
	}
	saved.RegisteredIDs = registerTVBoxSitesLocked(saved.Sites, saved.Spider)
	tvboxState = &saved
}

func makeTVBoxSourceID(site tvbox.Site) string {
	key := strings.TrimSpace(site.Key)
	safe := strings.ToLower(tvboxKeySafe.ReplaceAllString(key, "_"))
	safe = strings.Trim(safe, "_")
	// 饭太硬的 key 大量是中文（点我切源、玩偶…），只留 a-z0-9 会全被清空，
	// 一堆站点挤成同一个 id 后在去重里只剩一个。所以永远追加 key 哈希保证唯一。
	sum := sha1.Sum([]byte(key))
	suffix := hex.EncodeToString(sum[:4])
	if safe == "" || safe == "site" {
		return "tvbox_" + suffix
	}
	return "tvbox_" + safe + "_" + suffix
}

func registerTVBoxSitesLocked(sites []tvbox.Site, spiderURL string) []string {
	if tvboxState != nil {
		for _, oldID := range tvboxState.RegisteredIDs {
			Unregister(oldID)
		}
	}
	registered := make([]string, 0)
	seen := map[string]bool{}
	for _, site := range sites {
		if !site.Supported {
			continue
		}
		id := makeTVBoxSourceID(site)
		if seen[id] {
			continue
		}
		seen[id] = true
		siteCopy := site
		spiderCopy := strings.TrimSpace(spiderURL)
		var aliases []string
		if parsed, err := url.Parse(strings.TrimSpace(siteCopy.API)); err == nil && parsed.Hostname() != "" {
			aliases = []string{strings.ToLower(parsed.Hostname())}
		}
		Unregister(id)
		Register(SourceDescriptor{
			ID:             id,
			Name:           siteCopy.Name,
			Description:    "订阅源（" + string(siteCopy.Kind) + "）",
			Group:          "tvbox",
			GroupName:      "饭太硬订阅",
			Aliases:        aliases,
			BaseURL:        strings.TrimSpace(siteCopy.API),
			SkipVIPPrompt:  true,
			NoHostRotation: true,
		}, func(host Host) Provider {
			return &tvboxProvider{id: id, site: siteCopy, spider: spiderCopy, host: host}
		})
		registered = append(registered, id)
	}
	return registered
}

func (engine *nativeEngine) tvboxStatus() map[string]any {
	engine.tvboxEnsureLoaded()
	tvboxMu.Lock()
	defer tvboxMu.Unlock()
	if tvboxState == nil || tvboxState.URL == "" {
		return map[string]any{
			"url":            "",
			"supportedCount": 0,
			"skippedCount":   0,
			"sites":          []tvbox.Site{},
		}
	}
	return map[string]any{
		"url":            tvboxState.URL,
		"supportedCount": tvboxState.SupportedCount,
		"skippedCount":   tvboxState.SkippedCount,
		"sites":          tvboxState.Sites,
	}
}

func (engine *nativeEngine) tvboxSubscribe(ctx context.Context, rawURL string) (map[string]any, error) {
	u := strings.TrimSpace(rawURL)
	if u == "" {
		return nil, errors.New("请输入订阅接口地址")
	}
	cfg, err := tvbox.FetchConfig(ctx, engine.downloader.client, u)
	if err != nil {
		return nil, err
	}
	supported := 0
	skipped := 0
	for _, s := range cfg.Sites {
		if s.Supported {
			supported++
		} else {
			skipped++
		}
	}

	tvboxMu.Lock()
	ids := registerTVBoxSitesLocked(cfg.Sites, cfg.Spider)
	state := &tvboxSubscriptionState{
		URL:            u,
		Spider:         cfg.Spider,
		Sites:          cfg.Sites,
		RegisteredIDs:  ids,
		SupportedCount: supported,
		SkippedCount:   skipped,
	}
	tvboxState = state
	tvboxLoaded = true
	tvboxMu.Unlock()

	if path := engine.tvboxConfigPath(); path != "" {
		if encoded, err := json.MarshalIndent(state, "", "  "); err == nil {
			_ = os.WriteFile(path, encoded, 0o600)
		}
	}
	// 附上最新站源表，前端订阅成功后无需再单独拉一次源列表。
	status := engine.tvboxStatus()
	status["sources"] = engine.sourceList()
	return status, nil
}

func (engine *nativeEngine) tvboxClear() (map[string]any, error) {
	tvboxMu.Lock()
	if tvboxState != nil {
		for _, id := range tvboxState.RegisteredIDs {
			Unregister(id)
		}
	}
	tvboxState = nil
	tvboxLoaded = true
	tvboxMu.Unlock()

	if path := engine.tvboxConfigPath(); path != "" {
		_ = os.Remove(path)
	}
	status := engine.tvboxStatus()
	status["sources"] = engine.sourceList()
	return status, nil
}

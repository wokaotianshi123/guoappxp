package core

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestModuleRepositoriesValidate(t *testing.T) {
	valid := moduleRepositoriesConfig{
		Repositories: []nativeModuleRepository{
			{Name: "官方", URL: "https://example.com/index.json"},
			{Name: "镜像", URL: "http://127.0.0.1:8080/index.json"},
		},
		Active: 1,
	}
	if err := valid.validate(); err != nil {
		t.Fatalf("valid config rejected: %v", err)
	}
	cases := []struct {
		name   string
		config moduleRepositoriesConfig
		want   string
	}{
		{"empty", moduleRepositoriesConfig{}, "至少保留"},
		{"bad name", moduleRepositoriesConfig{Repositories: []nativeModuleRepository{{Name: " ", URL: "https://a.com/x.json"}}}, "名称"},
		{"ftp", moduleRepositoriesConfig{Repositories: []nativeModuleRepository{{Name: "x", URL: "ftp://a.com/x.json"}}}, "http"},
		{"no host", moduleRepositoriesConfig{Repositories: []nativeModuleRepository{{Name: "x", URL: "https:///index.json"}}}, "地址"},
		{"fragment", moduleRepositoriesConfig{Repositories: []nativeModuleRepository{{Name: "x", URL: "https://a.com/x.json#f"}}}, "地址"},
		{"duplicate", moduleRepositoriesConfig{Repositories: []nativeModuleRepository{{Name: "a", URL: "https://A.com/x.json"}, {Name: "b", URL: "https://a.com/x.json"}}}, "重复"},
		{"bad active", moduleRepositoriesConfig{Repositories: []nativeModuleRepository{{Name: "x", URL: "https://a.com/x.json"}}, Active: 5}, "序号"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := tc.config.validate()
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("want error containing %q, got %v", tc.want, err)
			}
		})
	}
}

func TestModuleRepositoriesSaveLoadAndFallback(t *testing.T) {
	directory := t.TempDir()
	engine := &nativeEngine{directory: directory}
	engine.loadModuleRepositories()
	if len(engine.repositories.Repositories) == 0 {
		t.Fatal("default repositories not loaded")
	}

	custom := moduleRepositoriesConfig{
		Repositories: []nativeModuleRepository{
			{Name: "自定义仓库", URL: "https://mirror.example.com/index.json"},
			{Name: "官方仓库", URL: moduleIndexAddresses[0]},
		},
		Active: 0,
	}
	view, err := engine.saveModuleRepositories(custom)
	if err != nil {
		t.Fatal(err)
	}
	if view["active"] != 0 {
		t.Fatalf("active = %v", view["active"])
	}
	if got := engine.activeModuleRepositoryURL(); got != "https://mirror.example.com/index.json" {
		t.Fatalf("active repository = %q", got)
	}
	// 内置官方镜像应作为兜底仍在分组列表里。
	groups := engine.moduleIndexGroups()
	if len(groups) < 2 {
		t.Fatalf("groups = %v", groups)
	}
	foundFallback := false
	for _, address := range groups[1] {
		if address == moduleIndexAddresses[0] {
			foundFallback = true
		}
	}
	if !foundFallback {
		t.Fatalf("missing builtin fallback in %v", groups)
	}

	// 重新加载应还原保存的配置。
	reloaded := &nativeEngine{directory: directory}
	reloaded.loadModuleRepositories()
	if len(reloaded.repositories.Repositories) != 2 || reloaded.repositories.Active != 0 ||
		reloaded.repositories.Repositories[0].Name != "自定义仓库" {
		t.Fatalf("reloaded = %+v", reloaded.repositories)
	}

	// 切换到第二个仓库。
	custom.Active = 1
	if _, err := reloaded.saveModuleRepositories(custom); err != nil {
		t.Fatal(err)
	}
	if got := reloaded.activeModuleRepositoryURL(); got != moduleIndexAddresses[0] {
		t.Fatalf("after switch, active repository = %q", got)
	}
}

func TestModuleRepositoriesCorruptFallsBack(t *testing.T) {
	directory := t.TempDir()
	if err := os.WriteFile(filepath.Join(directory, moduleRepositoriesFile), []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	engine := &nativeEngine{directory: directory}
	engine.loadModuleRepositories()
	if engine.repositoriesWarning == "" {
		t.Fatal("expected warning for corrupt config")
	}
	if len(engine.repositories.Repositories) == 0 {
		t.Fatal("expected default repositories after corrupt config")
	}
}

func TestModuleIndexUsesActiveRepository(t *testing.T) {
	index := []byte(`{"format":1,"modules":[]}`)
	var customHits, fallbackHits int
	custom := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		customHits++
		_, _ = w.Write(index)
	}))
	defer custom.Close()
	fallback := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fallbackHits++
		_, _ = w.Write(index)
	}))
	defer fallback.Close()

	original := moduleIndexAddresses
	moduleIndexAddresses = []string{fallback.URL + "/index.json"}
	defer func() { moduleIndexAddresses = original }()

	engine := &nativeEngine{
		directory:      t.TempDir(),
		cacheDirectory: t.TempDir(),
		downloader:     &Downloader{cfg: Config{dataDir: t.TempDir()}, client: custom.Client()},
		repositories: moduleRepositoriesConfig{Repositories: []nativeModuleRepository{
			{Name: "custom", URL: custom.URL + "/index.json"},
		}, Active: 0},
	}
	entries, err := engine.moduleIndex(t.Context())
	if err != nil {
		t.Fatalf("moduleIndex: %v", err)
	}
	if len(entries) != 0 {
		t.Fatalf("entries=%v", entries)
	}
	if customHits != 1 || fallbackHits != 0 {
		t.Fatalf("customHits=%d fallbackHits=%d", customHits, fallbackHits)
	}

	// 自定义仓库失效时回退到内置镜像。
	custom.Close()
	engine.repositories = moduleRepositoriesConfig{Repositories: []nativeModuleRepository{
		{Name: "down", URL: "https://127.0.0.1:1/index.json"},
	}, Active: 0}
	if _, err := engine.moduleIndex(t.Context()); err != nil {
		t.Fatalf("fallback moduleIndex: %v", err)
	}
	if fallbackHits == 0 {
		t.Fatal("expected builtin fallback to be hit")
	}
}

func TestRepositoriesViewJSON(t *testing.T) {
	engine := &nativeEngine{repositories: moduleRepositoriesConfig{Repositories: []nativeModuleRepository{
		{Name: "A", URL: "https://a.com/x.json"},
	}, Active: 0}}
	view := engine.repositoriesView()
	data, err := json.Marshal(view)
	if err != nil {
		t.Fatal(err)
	}
	var decoded struct {
		Items   []map[string]any `json:"items"`
		Active  int              `json:"active"`
		Warning string           `json:"warning"`
	}
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatal(err)
	}
	if len(decoded.Items) != 1 || decoded.Items[0]["name"] != "A" || decoded.Active != 0 {
		t.Fatalf("decoded = %+v", decoded)
	}
}

// TestModuleRepositoriesUpgradeOfficialDefault 校验老默认配置（只有官方镜像）
// 会自动换成出厂内置的 guocheng1378 / jqk4388 两家商店；用户自己配过的不动。
func TestModuleRepositoriesUpgradeOfficialDefault(t *testing.T) {
	directory := t.TempDir()
	old := moduleRepositoriesConfig{Repositories: []nativeModuleRepository{
		{Name: "官方仓库", URL: moduleIndexAddresses[0]},
		{Name: "官方仓库", URL: moduleIndexAddresses[1]},
	}}
	data, err := json.Marshal(old)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, moduleRepositoriesFile), data, 0o600); err != nil {
		t.Fatal(err)
	}
	engine := &nativeEngine{directory: directory}
	engine.loadModuleRepositories()
	names := []string{}
	for _, repo := range engine.repositories.Repositories {
		names = append(names, repo.Name)
	}
	if len(names) != len(moduleBuiltinRepositories) || names[0] != "官方仓库" ||
		names[1] != "guocheng1378" || names[2] != "jqk4388" {
		t.Fatalf("repositories = %v", names)
	}
	if got := engine.activeModuleRepositoryURL(); got != moduleBuiltinRepositories[0].URL {
		t.Fatalf("active = %q", got)
	}

	// 用户自己加的仓库不参与升级。
	mixed := moduleRepositoriesConfig{Repositories: []nativeModuleRepository{
		{Name: "官方仓库", URL: moduleIndexAddresses[0]},
		{Name: "我的镜像", URL: "https://mirror.example.com/index.json"},
	}}
	if got := upgradeRepositories(mixed); len(got.Repositories) != 2 || got.Repositories[1].Name != "我的镜像" {
		t.Fatalf("mixed upgraded = %+v", got.Repositories)
	}
}

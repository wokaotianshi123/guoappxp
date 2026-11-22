// Package netdisk 提供网盘（当前为夸克）分享链接解析与播放直链。
//
// 设计要点：
//   - 分享的「列表」可免登录解析；「转存」「取流」需要网页版登录态（cookie）。
//   - 播放 CDN 会校验 cookie（尤其 __puus），所以直链必须连同 Cookie 头一起交给播放器。
//   - 凭据只落本机应用私有目录，绝不外发。
package netdisk

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

var (
	ErrNotLoggedIn = errors.New("网盘未登录，请先在设置里扫码登录")
	ErrBadShare    = errors.New("分享链接无效或已失效")
)

// Cookie 是单个 cookie 的持久化形式。
type Cookie struct {
	Name  string `json:"name"`
	Value string `json:"value"`
}

// Credentials 是某个网盘的登录态。
type Credentials struct {
	Provider string   `json:"provider"`
	Cookies  []Cookie `json:"cookies"`
	SavedAt  int64    `json:"savedAt"`
}

// Header 返回可直接拼进 HTTP 请求的 Cookie 头。
func (c *Credentials) Header() string {
	parts := make([]string, 0, len(c.Cookies))
	for _, item := range c.Cookies {
		parts = append(parts, item.Name+"="+item.Value)
	}
	return strings.Join(parts, "; ")
}

// Cookie 按名字查找。
func (c *Credentials) Cookie(name string) string {
	for _, item := range c.Cookies {
		if item.Name == name {
			return item.Value
		}
	}
	return ""
}

// Store 负责凭据的读写（应用私有目录，权限 0600）。
type Store struct {
	mu   sync.Mutex
	path string
}

// NewStore 在 dir 下使用 cookies.json 存放凭据。
func NewStore(dir string) *Store {
	return &Store{path: filepath.Join(dir, "netdisk-cookies.json")}
}

func (s *Store) load() (map[string]*Credentials, error) {
	raw, err := os.ReadFile(s.path)
	if errors.Is(err, os.ErrNotExist) {
		return map[string]*Credentials{}, nil
	}
	if err != nil {
		return nil, err
	}
	out := map[string]*Credentials{}
	if len(raw) == 0 {
		return out, nil
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return map[string]*Credentials{}, nil
	}
	return out, nil
}

// Get 读取某个网盘的凭据。
func (s *Store) Get(provider string) (*Credentials, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	all, err := s.load()
	if err != nil {
		return nil, err
	}
	cred := all[provider]
	if cred == nil || len(cred.Cookies) == 0 {
		return nil, ErrNotLoggedIn
	}
	return cred, nil
}

// Put 覆盖写入某个网盘的凭据。
func (s *Store) Put(cred *Credentials) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	all, err := s.load()
	if err != nil {
		return err
	}
	all[cred.Provider] = cred
	body, err := json.MarshalIndent(all, "", " ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(s.path), 0o700); err != nil {
		return err
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, body, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.path)
}

// Clear 删除某个网盘的凭据（退出登录）。
func (s *Store) Clear(provider string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	all, err := s.load()
	if err != nil {
		return err
	}
	if _, ok := all[provider]; !ok {
		return nil
	}
	delete(all, provider)
	body, err := json.MarshalIndent(all, "", " ")
	if err != nil {
		return err
	}
	return os.WriteFile(s.path, body, 0o600)
}

// Status 返回各网盘的登录状态（不泄露 cookie 值）。
func (s *Store) Status() map[string]bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	all, err := s.load()
	if err != nil {
		return map[string]bool{}
	}
	out := map[string]bool{}
	for name, cred := range all {
		out[name] = cred != nil && len(cred.Cookies) > 0
	}
	return out
}

// httpClient 返回带固定 UA 的超时客户端。
func httpClient() *http.Client {
	return &http.Client{Timeout: 30 * time.Second}
}

func withContext(ctx context.Context, req *http.Request) *http.Request {
	if ctx != nil {
		return req.WithContext(ctx)
	}
	return req
}

// escape 包一层 url.QueryEscape，失败时返回原串。
func escape(value string) string { return url.QueryEscape(value) }

func wrap(op string, err error) error {
	if err == nil {
		return nil
	}
	return fmt.Errorf("%s: %w", op, err)
}

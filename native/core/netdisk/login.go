package netdisk

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"

	qrcode "github.com/skip2/go-qrcode"
)

// 夸克网页版登录参数（来自官方 Web 前端，非第三方中转）。
const (
	quarkCASClientID = "532"
	quarkCASRedirect = "https://pan.quark.cn"
	quarkScanPage    = "https://su.quark.cn/4_eMHBJ"
	quarkBizStr      = "S:custom|OPT:SAREA@0|OPT:IMMERSIVE@1|OPT:BACK_BTN_STYLE@0"
)

// LoginState 是扫码登录会话的对外状态。
type LoginState struct {
	ID        string `json:"id"`
	Provider  string `json:"provider"`
	Status    string `json:"status"` // pending / scanned / done / expired / error
	Message   string `json:"message,omitempty"`
	QRBase64  string `json:"qrBase64,omitempty"` // PNG
	StartedAt int64  `json:"startedAt"`
}

type loginSession struct {
	state  LoginState
	token  string
	store  *Store
	readMu sync.Mutex
}

// LoginManager 管理进行中的扫码会话。
type LoginManager struct {
	mu       sync.Mutex
	sessions map[string]*loginSession
	store    *Store
}

// NewLoginManager 绑定凭据存储。
func NewLoginManager(store *Store) *LoginManager {
	return &LoginManager{sessions: map[string]*loginSession{}, store: store}
}

func randomID() string {
	buf := make([]byte, 8)
	if _, err := rand.Read(buf); err != nil {
		return fmt.Sprintf("s%d", time.Now().UnixNano())
	}
	return hex.EncodeToString(buf)
}

func casGet(ctx context.Context, rawURL string, out any) error {
	req, err := http.NewRequest(http.MethodGet, rawURL, nil)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", quarkUA)
	req.Header.Set("Referer", "https://pan.quark.cn/")
	resp, err := httpClient().Do(withContext(ctx, req))
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return err
	}
	if out == nil {
		return nil
	}
	if err := json.Unmarshal(body, out); err != nil {
		return fmt.Errorf("解析登录返回失败（HTTP %d）", resp.StatusCode)
	}
	return nil
}

// Start 创建一次扫码登录，返回带二维码 PNG（base64）的状态。
func (m *LoginManager) Start(ctx context.Context) (*LoginState, error) {
	var got struct {
		Status int `json:"status"`
		Data   struct {
			Members struct {
				Token string `json:"token"`
			} `json:"members"`
		} `json:"data"`
	}
	u := "https://uop.quark.cn/cas/ajax/getTokenForQrcodeLogin?client_id=" + quarkCASClientID +
		"&redirect_uri=" + escape(quarkCASRedirect)
	if err := casGet(ctx, u, &got); err != nil {
		return nil, err
	}
	token := got.Data.Members.Token
	if token == "" {
		return nil, errors.New("获取登录二维码失败，请稍后重试")
	}
	// 二维码内容必须是官方深链，裸 token 扫出来是无效网页。
	payload := quarkScanPage + "?token=" + escape(token) +
		"&client_id=" + quarkCASClientID + "&ssb=weblogin&uc_param_str=" +
		"&uc_biz_str=" + escape(quarkBizStr)
	png, err := qrcode.Encode(payload, qrcode.Medium, 460)
	if err != nil {
		return nil, err
	}
	session := &loginSession{
		state: LoginState{
			ID:        randomID(),
			Provider:  "quark",
			Status:    "pending",
			QRBase64:  base64.StdEncoding.EncodeToString(png),
			StartedAt: time.Now().Unix(),
		},
		token: token,
		store: m.store,
	}
	m.mu.Lock()
	m.sessions[session.state.ID] = session
	m.mu.Unlock()
	out := session.state
	return &out, nil
}

// Poll 查询扫码结果；成功后把 cookie 落盘并返回 done。
func (m *LoginManager) Poll(ctx context.Context, id string) (*LoginState, error) {
	m.mu.Lock()
	session := m.sessions[id]
	m.mu.Unlock()
	if session == nil {
		return nil, errors.New("登录会话已失效，请重新获取二维码")
	}
	if session.state.Status == "done" || session.state.Status == "expired" {
		out := session.state
		return &out, nil
	}
	if time.Since(time.Unix(session.state.StartedAt, 0)) > 6*time.Minute {
		session.state.Status = "expired"
		session.state.Message = "二维码已过期，请重新获取"
		session.state.QRBase64 = ""
		out := session.state
		return &out, nil
	}

	var got struct {
		Status int `json:"status"`
		Data   struct {
			Members struct {
				ServiceTicket string `json:"service_ticket"`
			} `json:"members"`
		} `json:"data"`
	}
	u := "https://uop.quark.cn/cas/ajax/getServiceTicketByQrcodeToken?token=" +
		escape(session.token) + "&client_id=" + quarkCASClientID
	if err := casGet(ctx, u, &got); err != nil {
		return nil, err
	}
	ticket := got.Data.Members.ServiceTicket
	if ticket == "" {
		// status 50004001 表示还没有扫码确认，属于正常等待。
		out := session.state
		return &out, nil
	}
	session.state.Status = "scanned"
	creds, err := exchangeTicket(ctx, ticket)
	if err != nil {
		session.state.Status = "error"
		session.state.Message = err.Error()
		out := session.state
		return &out, nil
	}
	if err := session.store.Put(creds); err != nil {
		session.state.Status = "error"
		session.state.Message = "登录成功但保存凭据失败"
		out := session.state
		return &out, nil
	}
	session.state.Status = "done"
	session.state.QRBase64 = ""
	session.state.Message = "登录成功"
	delete(m.sessions, id)
	out := session.state
	return &out, nil
}

// exchangeTicket 用 service ticket 换取网页版 cookie，并补齐播放 CDN 需要的 __puus。
func exchangeTicket(ctx context.Context, ticket string) (*Credentials, error) {
	jar := map[string]string{}

	// 第一步：account/info 带 st 换主登录态。
	req, err := http.NewRequest(http.MethodGet, "https://pan.quark.cn/account/info?st="+escape(ticket), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", quarkUA)
	req.Header.Set("Referer", "https://pan.quark.cn/")
	resp, err := httpClient().Do(withContext(ctx, req))
	if err != nil {
		return nil, err
	}
	for _, c := range resp.Cookies() {
		jar[c.Name] = c.Value
	}
	resp.Body.Close()
	if len(jar) == 0 {
		return nil, errors.New("登录态换取失败，请重试")
	}

	// 第二步：config 接口补 __puus，缺了它播放 CDN 会 403。
	creds := &Credentials{Provider: "quark", SavedAt: time.Now().Unix()}
	for name, value := range jar {
		creds.Cookies = append(creds.Cookies, Cookie{Name: name, Value: value})
	}
	req2, err := http.NewRequest(http.MethodGet, "https://drive-pc.quark.cn/1/clouddrive/config"+quarkPR, nil)
	if err != nil {
		return creds, nil
	}
	req2.Header.Set("User-Agent", quarkUA)
	req2.Header.Set("Referer", "https://pan.quark.cn/")
	req2.Header.Set("Cookie", creds.Header())
	resp2, err := httpClient().Do(withContext(ctx, req2))
	if err == nil {
		for _, c := range resp2.Cookies() {
			if c.Name == "__puus" && c.Value != "" {
				replaced := false
				for i := range creds.Cookies {
					if creds.Cookies[i].Name == "__puus" {
						creds.Cookies[i].Value = c.Value
						replaced = true
					}
				}
				if !replaced {
					creds.Cookies = append(creds.Cookies, Cookie{Name: "__puus", Value: c.Value})
				}
			}
		}
		resp2.Body.Close()
	}
	creds.SavedAt = time.Now().Unix()
	return creds, nil
}

// ProviderReady 判断某网盘凭据是否完整（缺 __puus 视为不可播放）。
func ProviderReady(creds *Credentials) bool {
	if creds == nil {
		return false
	}
	return strings.TrimSpace(creds.Cookie("__puus")) != ""
}

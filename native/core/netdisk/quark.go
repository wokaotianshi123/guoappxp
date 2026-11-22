package netdisk

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"
)

const (
	quarkUA     = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
	quarkAPI    = "https://drive-pc.quark.cn/1/clouddrive/"
	quarkPR     = "?pr=ucpro&fr=pc"
	quarkTmpDir = "gomovie_tmp"
)

// Episode 是分享内的一集（或一个文件）。
type Episode struct {
	FID      string `json:"fid"`
	Token    string `json:"token"`
	Name     string `json:"name"`
	Size     int64  `json:"size"`
	Duration int64  `json:"duration"`
}

// ShareInfo 是解析出来的分享。
type ShareInfo struct {
	Provider string    `json:"provider"`
	ShareID  string    `json:"shareId"`
	Title    string    `json:"title"`
	Episodes []Episode `json:"episodes"`
	LoggedIn bool      `json:"loggedIn"`
}

// Playback 是可以交给播放器的直链与请求头。
type Playback struct {
	URL     string            `json:"url"`
	Headers map[string]string `json:"headers"`
}

var (
	shareIDPattern  = regexp.MustCompile(`pan\.quark\.cn/s/([A-Za-z0-9]+)`)
	passcodePattern = regexp.MustCompile(`(?:pwd=|passcode=|提取码[：:\s]*)([A-Za-z0-9]{4})`)
)

// Quark 是夸克网盘客户端。creds 为空表示游客（只能解析列表）。
type Quark struct {
	creds *Credentials
	// api 是接口基址，默认官方地址；测试时可替换成本地假服务。
	api string
}

// NewQuark 用给定凭据构造客户端，可为 nil。
func NewQuark(creds *Credentials) *Quark { return &Quark{creds: creds, api: quarkAPI} }

func (q *Quark) base() string {
	if q.api != "" {
		return q.api
	}
	return quarkAPI
}

type quarkReply struct {
	Status  int             `json:"status"`
	Code    int             `json:"code"`
	Message string          `json:"message"`
	Data    json.RawMessage `json:"data"`
}

func (q *Quark) do(ctx context.Context, path string, body any) (*quarkReply, error) {
	var reader io.Reader
	method := http.MethodGet
	if body != nil {
		payload, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		reader = strings.NewReader(string(payload))
		method = http.MethodPost
	}
	req, err := http.NewRequest(method, q.base()+path, reader)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", quarkUA)
	req.Header.Set("Referer", "https://pan.quark.cn/")
	req.Header.Set("Accept", "application/json, text/plain, */*")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if q.creds != nil {
		req.Header.Set("Cookie", q.creds.Header())
	}
	resp, err := httpClient().Do(withContext(ctx, req))
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return nil, err
	}
	out := &quarkReply{}
	if err := json.Unmarshal(raw, out); err != nil {
		return nil, fmt.Errorf("解析网盘返回失败（HTTP %d）", resp.StatusCode)
	}
	return out, nil
}

// ParseShareURL 从分享链接里取出 shareID 与提取码。
func ParseShareURL(raw string) (string, string, error) {
	m := shareIDPattern.FindStringSubmatch(raw)
	if m == nil {
		return "", "", ErrBadShare
	}
	pwd := ""
	if pm := passcodePattern.FindStringSubmatch(raw); pm != nil {
		pwd = pm[1]
	}
	return m[1], pwd, nil
}

func (q *Quark) shareToken(ctx context.Context, shareID, pwd string) (string, error) {
	r, err := q.do(ctx, "share/sharepage/token"+quarkPR,
		map[string]any{"pwd_id": shareID, "passcode": pwd})
	if err != nil {
		return "", err
	}
	var data struct {
		Stoken string `json:"stoken"`
	}
	_ = json.Unmarshal(r.Data, &data)
	if data.Stoken == "" {
		if r.Message != "" {
			return "", fmt.Errorf("分享解析失败：%s", r.Message)
		}
		return "", ErrBadShare
	}
	return data.Stoken, nil
}

type quarkFile struct {
	FID      string `json:"fid"`
	FileName string `json:"file_name"`
	ShareTok string `json:"share_fid_token"`
	Dir      bool   `json:"dir"`
	Size     int64  `json:"size"`
	Duration int64  `json:"duration"`
	Category int    `json:"category"`
}

func (q *Quark) listDir(ctx context.Context, shareID, stoken, fid string, page int) ([]quarkFile, error) {
	qy := fmt.Sprintf("share/sharepage/detail%s&pwd_id=%s&stoken=%s&pdir_fid=%s&force=0&_page=%d&_size=200&_sort=file_type:asc,file_name:asc",
		quarkPR, shareID, url.QueryEscape(stoken), fid, page)
	r, err := q.do(ctx, qy, nil)
	if err != nil {
		return nil, err
	}
	var data struct {
		List []quarkFile `json:"list"`
	}
	_ = json.Unmarshal(r.Data, &data)
	return data.List, nil
}

func (q *Quark) walk(ctx context.Context, shareID, stoken, fid string, depth int, out *[]quarkFile) error {
	if depth > 6 {
		return nil
	}
	items, err := q.listDir(ctx, shareID, stoken, fid, 1)
	if err != nil {
		return err
	}
	for _, item := range items {
		if item.Dir {
			if err := q.walk(ctx, shareID, stoken, item.FID, depth+1, out); err != nil {
				return err
			}
			continue
		}
		if isVideo(item.FileName) {
			*out = append(*out, item)
		}
	}
	return nil
}

func isVideo(name string) bool {
	lower := strings.ToLower(name)
	for _, ext := range []string{".mp4", ".mkv", ".ts", ".mov", ".avi", ".flv", ".m4v", ".wmv"} {
		if strings.HasSuffix(lower, ext) {
			return true
		}
	}
	return false
}

// Share 解析分享链接，返回可播放的剧集列表（列表本身免登录）。
func (q *Quark) Share(ctx context.Context, raw string) (*ShareInfo, error) {
	shareID, pwd, err := ParseShareURL(raw)
	if err != nil {
		return nil, err
	}
	stoken, err := q.shareToken(ctx, shareID, pwd)
	if err != nil {
		return nil, err
	}
	var files []quarkFile
	if err := q.walk(ctx, shareID, stoken, "0", 0, &files); err != nil {
		return nil, err
	}
	info := &ShareInfo{Provider: "quark", ShareID: shareID, LoggedIn: q.creds != nil}
	for _, f := range files {
		info.Episodes = append(info.Episodes, Episode{
			FID: f.FID, Token: f.ShareTok, Name: f.FileName,
			Size: f.Size, Duration: f.Duration,
		})
	}
	if len(info.Episodes) == 0 {
		return info, errors.New("这个分享里没有可播放的视频文件")
	}
	return info, nil
}

func (q *Quark) ensureTmpDir(ctx context.Context) (string, error) {
	r, err := q.do(ctx, "file/sort"+quarkPR+"&pdir_fid=0&_page=1&_size=200&_sort=file_type:asc,updated_at:desc", nil)
	if err != nil {
		return "", err
	}
	var data struct {
		List []quarkFile `json:"list"`
	}
	_ = json.Unmarshal(r.Data, &data)
	for _, item := range data.List {
		if item.FileName == quarkTmpDir {
			return item.FID, nil
		}
	}
	c, err := q.do(ctx, "file"+quarkPR,
		map[string]any{"pdir_fid": "0", "file_name": quarkTmpDir, "dir_path": "", "dir_init_lock": false})
	if err != nil {
		return "", err
	}
	var created struct {
		FID string `json:"fid"`
	}
	_ = json.Unmarshal(c.Data, &created)
	if created.FID == "" {
		return "", errors.New("无法创建临时目录")
	}
	return created.FID, nil
}

// Save 把分享里的一集转存到临时目录，返回转存后的文件 ID。
func (q *Quark) Save(ctx context.Context, shareID, stoken string, ep Episode) (string, error) {
	if q.creds == nil {
		return "", ErrNotLoggedIn
	}
	toFID, err := q.ensureTmpDir(ctx)
	if err != nil {
		return "", err
	}
	r, err := q.do(ctx, "share/sharepage/save"+quarkPR, map[string]any{
		"fid_list":       []string{ep.FID},
		"fid_token_list": []string{ep.Token},
		"to_pdir_fid":    toFID,
		"pwd_id":         shareID,
		"stoken":         stoken,
		"pdir_fid":       "0",
		"scene":          "link",
	})
	if err != nil {
		return "", err
	}
	var saved struct {
		TaskID string `json:"task_id"`
	}
	_ = json.Unmarshal(r.Data, &saved)
	if saved.TaskID == "" {
		if r.Message != "" {
			return "", fmt.Errorf("转存失败：%s", r.Message)
		}
		return "", errors.New("转存失败")
	}
	for i := 0; i < 5; i++ {
		time.Sleep(time.Second)
		t, err := q.do(ctx, fmt.Sprintf("task%s&task_id=%s&retry_index=%d", quarkPR, saved.TaskID, i), nil)
		if err != nil {
			continue
		}
		var data struct {
			SaveAs struct {
				TopFIDs []string `json:"save_as_top_fids"`
			} `json:"save_as"`
		}
		_ = json.Unmarshal(t.Data, &data)
		if len(data.SaveAs.TopFIDs) > 0 {
			return data.SaveAs.TopFIDs[0], nil
		}
	}
	return "", errors.New("转存超时，请稍后重试")
}

// PlayURL 为已转存的文件取播放直链，并附带播放所需请求头。
func (q *Quark) PlayURL(ctx context.Context, fid string) (*Playback, error) {
	if q.creds == nil {
		return nil, ErrNotLoggedIn
	}
	r, err := q.do(ctx, "file/v2/play"+quarkPR, map[string]any{
		"fid":         fid,
		"resolutions": "normal,low,high,super,2k,4k",
		"supports":    "fmp4",
	})
	if err != nil {
		return nil, err
	}
	var data struct {
		VideoList []struct {
			VideoInfo struct {
				URL string `json:"url"`
			} `json:"video_info"`
		} `json:"video_list"`
	}
	_ = json.Unmarshal(r.Data, &data)
	for _, item := range data.VideoList {
		if item.VideoInfo.URL != "" {
			return &Playback{
				URL: item.VideoInfo.URL,
				Headers: map[string]string{
					"User-Agent": quarkUA,
					"Referer":    "https://pan.quark.cn/",
					"Cookie":     q.creds.Header(),
				},
			}, nil
		}
	}
	return nil, errors.New("取播放地址失败，可能是会员限制或文件不可转码")
}

// ResolveShare 一步到位：解析分享 -> 转存指定集 -> 返回直链。
func (q *Quark) ResolveShare(ctx context.Context, raw string, index int) (*Playback, error) {
	shareID, pwd, err := ParseShareURL(raw)
	if err != nil {
		return nil, err
	}
	stoken, err := q.shareToken(ctx, shareID, pwd)
	if err != nil {
		return nil, err
	}
	var files []quarkFile
	if err := q.walk(ctx, shareID, stoken, "0", 0, &files); err != nil {
		return nil, err
	}
	if len(files) == 0 {
		return nil, errors.New("这个分享里没有可播放的视频文件")
	}
	if index < 0 || index >= len(files) {
		index = 0
	}
	ep := Episode{FID: files[index].FID, Token: files[index].ShareTok, Name: files[index].FileName}
	saved, err := q.Save(ctx, shareID, stoken, ep)
	if err != nil {
		return nil, err
	}
	return q.PlayURL(ctx, saved)
}

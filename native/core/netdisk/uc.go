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

// UC 网盘与夸克同源：底层都是 1/clouddrive 接口，只是域名、Cookie 名与
// 播放鉴权字段不同。这里按夸克的调用序列实现一份 UC 版本，保持两者行为一致。
const (
	ucUA     = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
	ucAPI    = "https://pc-api.uc.cn/1/clouddrive/"
	ucPR     = "?pr=UCBrowser&fr=pc"
	ucTmpDir = "gomovie_tmp"
)

var (
	ucShareIDPattern = regexp.MustCompile(`drive\.uc\.cn/s/([A-Za-z0-9]+)`)
	ucPasscodePattern = regexp.MustCompile(`(?:pwd=|passcode=|提取码[：:\s]*)([A-Za-z0-9]{4})`)
)

// UC 是 UC 网盘客户端。creds 为空表示游客（只能解析列表）。
type UC struct {
	creds *Credentials
	// api 是接口基址，默认官方地址；测试时可替换成本地假服务。
	api string
}

// NewUC 用给定凭据构造客户端，可为 nil。
func NewUC(creds *Credentials) *UC { return &UC{creds: creds, api: ucAPI} }

func (u *UC) base() string {
	if u.api != "" {
		return u.api
	}
	return ucAPI
}

type ucReply struct {
	Status  int             `json:"status"`
	Code    int             `json:"code"`
	Message string          `json:"message"`
	Data    json.RawMessage `json:"data"`
}

func (u *UC) do(ctx context.Context, path string, body any) (*ucReply, error) {
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
	req, err := http.NewRequest(method, u.base()+path, reader)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", ucUA)
	req.Header.Set("Referer", "https://drive.uc.cn/")
	req.Header.Set("Accept", "application/json, text/plain, */*")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if u.creds != nil {
		req.Header.Set("Cookie", u.creds.Header())
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
	out := &ucReply{}
	if err := json.Unmarshal(raw, out); err != nil {
		return nil, fmt.Errorf("解析 UC 网盘返回失败（HTTP %d）", resp.StatusCode)
	}
	return out, nil
}

// ParseUCShareURL 从 UC 分享链接里取出 shareID 与提取码。
func ParseUCShareURL(raw string) (string, string, error) {
	m := ucShareIDPattern.FindStringSubmatch(raw)
	if m == nil {
		return "", "", ErrBadShare
	}
	pwd := ""
	if pm := ucPasscodePattern.FindStringSubmatch(raw); pm != nil {
		pwd = pm[1]
	}
	return m[1], pwd, nil
}

func (u *UC) shareToken(ctx context.Context, shareID, pwd string) (string, error) {
	r, err := u.do(ctx, "share/sharepage/token"+ucPR,
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

type ucFile struct {
	FID      string `json:"fid"`
	FileName string `json:"file_name"`
	ShareTok string `json:"share_fid_token"`
	Dir      bool   `json:"dir"`
	Size     int64  `json:"size"`
	Duration int64  `json:"duration"`
}

func (u *UC) listDir(ctx context.Context, shareID, stoken, fid string) ([]ucFile, error) {
	qy := fmt.Sprintf("share/sharepage/detail%s&pwd_id=%s&stoken=%s&pdir_fid=%s&force=0&_page=1&_size=200&_sort=file_type:asc,file_name:asc",
		ucPR, shareID, url.QueryEscape(stoken), fid)
	r, err := u.do(ctx, qy, nil)
	if err != nil {
		return nil, err
	}
	var data struct {
		List []ucFile `json:"list"`
	}
	_ = json.Unmarshal(r.Data, &data)
	return data.List, nil
}

func (u *UC) walk(ctx context.Context, shareID, stoken, fid string, depth int, out *[]ucFile) error {
	if depth > 6 {
		return nil
	}
	items, err := u.listDir(ctx, shareID, stoken, fid)
	if err != nil {
		return err
	}
	for _, item := range items {
		if item.Dir {
			if err := u.walk(ctx, shareID, stoken, item.FID, depth+1, out); err != nil {
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

// Share 解析分享链接，返回可播放的剧集列表（列表本身免登录）。
func (u *UC) Share(ctx context.Context, raw string) (*ShareInfo, error) {
	shareID, pwd, err := ParseUCShareURL(raw)
	if err != nil {
		return nil, err
	}
	stoken, err := u.shareToken(ctx, shareID, pwd)
	if err != nil {
		return nil, err
	}
	var files []ucFile
	if err := u.walk(ctx, shareID, stoken, "0", 0, &files); err != nil {
		return nil, err
	}
	info := &ShareInfo{Provider: "uc", ShareID: shareID, LoggedIn: u.creds != nil}
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

func (u *UC) ensureTmpDir(ctx context.Context) (string, error) {
	r, err := u.do(ctx, "file/sort"+ucPR+"&pdir_fid=0&_page=1&_size=200&_sort=file_type:asc,updated_at:desc", nil)
	if err != nil {
		return "", err
	}
	var data struct {
		List []ucFile `json:"list"`
	}
	_ = json.Unmarshal(r.Data, &data)
	for _, item := range data.List {
		if item.FileName == ucTmpDir {
			return item.FID, nil
		}
	}
	c, err := u.do(ctx, "file"+ucPR,
		map[string]any{"pdir_fid": "0", "file_name": ucTmpDir, "dir_path": "", "dir_init_lock": false})
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
func (u *UC) Save(ctx context.Context, shareID, stoken string, ep Episode) (string, error) {
	if u.creds == nil {
		return "", ErrNotLoggedIn
	}
	toFID, err := u.ensureTmpDir(ctx)
	if err != nil {
		return "", err
	}
	r, err := u.do(ctx, "share/sharepage/save"+ucPR, map[string]any{
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
		t, err := u.do(ctx, fmt.Sprintf("task%s&task_id=%s&retry_index=%d", ucPR, saved.TaskID, i), nil)
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
func (u *UC) PlayURL(ctx context.Context, fid string) (*Playback, error) {
	if u.creds == nil {
		return nil, ErrNotLoggedIn
	}
	r, err := u.do(ctx, "file/v2/play"+ucPR, map[string]any{
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
					"User-Agent": ucUA,
					"Referer":    "https://drive.uc.cn/",
					"Cookie":     u.creds.Header(),
				},
			}, nil
		}
	}
	return nil, errors.New("取播放地址失败，可能是会员限制或文件不可转码")
}

// ResolveShare 一步到位：解析分享 -> 转存指定集 -> 返回直链。
func (u *UC) ResolveShare(ctx context.Context, raw string, index int) (*Playback, error) {
	shareID, pwd, err := ParseUCShareURL(raw)
	if err != nil {
		return nil, err
	}
	stoken, err := u.shareToken(ctx, shareID, pwd)
	if err != nil {
		return nil, err
	}
	var files []ucFile
	if err := u.walk(ctx, shareID, stoken, "0", 0, &files); err != nil {
		return nil, err
	}
	if len(files) == 0 {
		return nil, errors.New("这个分享里没有可播放的视频文件")
	}
	if index < 0 || index >= len(files) {
		index = 0
	}
	ep := Episode{FID: files[index].FID, Token: files[index].ShareTok, Name: files[index].FileName}
	saved, err := u.Save(ctx, shareID, stoken, ep)
	if err != nil {
		return nil, err
	}
	return u.PlayURL(ctx, saved)
}

func (u *UC) ID() string { return "uc" }

func (u *UC) Match(rawURL string) bool { return DetectProvider(rawURL) == "uc" }

// CleanupTemp 清理 UC 网盘根目录下的 gomovie_tmp 临时目录，返回清理的文件数。
func (u *UC) CleanupTemp(ctx context.Context) (int, error) {
	if !ProviderReady(u.creds) {
		return 0, ErrNotLoggedIn
	}
	reply, err := u.do(ctx, "file/sort"+ucPR+"&pdir_fid=0&_page=1&_size=100", nil)
	if err != nil {
		return 0, err
	}
	var rootData struct {
		List []struct {
			FID      string `json:"fid"`
			FileName string `json:"file_name"`
			Dir      bool   `json:"dir"`
		} `json:"list"`
	}
	if err := json.Unmarshal(reply.Data, &rootData); err != nil {
		return 0, err
	}
	var tmpFID string
	for _, item := range rootData.List {
		if item.Dir && item.FileName == ucTmpDir {
			tmpFID = item.FID
			break
		}
	}
	if tmpFID == "" {
		return 0, nil
	}
	childReply, err := u.do(ctx, "file/sort"+ucPR+"&pdir_fid="+url.QueryEscape(tmpFID)+"&_page=1&_size=200", nil)
	if err != nil {
		return 0, err
	}
	var childData struct {
		List []struct {
			FID string `json:"fid"`
		} `json:"list"`
	}
	if err := json.Unmarshal(childReply.Data, &childData); err != nil {
		return 0, err
	}
	fids := make([]string, 0, len(childData.List))
	for _, item := range childData.List {
		if item.FID != "" {
			fids = append(fids, item.FID)
		}
	}
	if len(fids) == 0 {
		return 0, nil
	}
	body := map[string]any{"action_type": 2, "filelist": fids, "exclude_fids": []string{}}
	delReply, err := u.do(ctx, "file/delete"+ucPR, body)
	if err != nil {
		return 0, err
	}
	if delReply.Status != 0 && delReply.Status != 200 {
		if delReply.Message != "" {
			return 0, errors.New(delReply.Message)
		}
		return 0, errors.New("清理临时目录失败")
	}
	return len(fids), nil
}

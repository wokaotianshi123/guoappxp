package netdisk

import (
	"context"
	"encoding/json"
	"errors"
	"net/url"
	"regexp"
	"strings"
)

// Provider 抽象不同网盘的分享解析与直链取流能力。
type Provider interface {
	ID() string
	Match(rawURL string) bool
	Share(ctx context.Context, rawURL string) (*ShareInfo, error)
	ResolveShare(ctx context.Context, rawURL string, index int) (*Playback, error)
}

var (
	quarkURLPattern  = regexp.MustCompile(`https?://pan\.quark\.cn/s/[A-Za-z0-9_-]+(?:\?[^\s"'<>]*)?`)
	ucURLPattern     = regexp.MustCompile(`https?://drive\.uc\.cn/s/[A-Za-z0-9_-]+(?:\?[^\s"'<>]*)?`)
	alipanURLPattern = regexp.MustCompile(`https?://(?:www\.)?(?:alipan|aliyundrive)\.com/s/[A-Za-z0-9_-]+(?:\?[^\s"'<>]*)?`)
)

// ExtractShareURL 从文本或 push:// 协议中提取网盘分享链接。
func ExtractShareURL(raw string) string {
	text := strings.TrimSpace(raw)
	if text == "" {
		return ""
	}
	if strings.HasPrefix(strings.ToLower(text), "push://") {
		text = strings.TrimSpace(text[len("push://"):])
	}
	if m := quarkURLPattern.FindString(text); m != "" {
		return m
	}
	if m := ucURLPattern.FindString(text); m != "" {
		return m
	}
	if m := alipanURLPattern.FindString(text); m != "" {
		return m
	}
	return ""
}

// DetectProvider 识别分享链接所属网盘标识。
func DetectProvider(raw string) string {
	extracted := ExtractShareURL(raw)
	if extracted == "" {
		extracted = strings.TrimSpace(raw)
	}
	u, err := url.Parse(extracted)
	if err != nil {
		return ""
	}
	host := strings.ToLower(u.Hostname())
	switch {
	case strings.Contains(host, "quark.cn"):
		return "quark"
	case strings.Contains(host, "uc.cn"):
		return "uc"
	case strings.Contains(host, "alipan.com") || strings.Contains(host, "aliyundrive.com"):
		return "alipan"
	default:
		return ""
	}
}

func (q *Quark) ID() string { return "quark" }

func (q *Quark) Match(rawURL string) bool { return DetectProvider(rawURL) == "quark" }

// CleanupTemp 清理夸克网盘根目录下的 gomovie_tmp 临时目录，返回清理的文件数。
func (q *Quark) CleanupTemp(ctx context.Context) (int, error) {
	if !ProviderReady(q.creds) {
		return 0, ErrNotLoggedIn
	}
	reply, err := q.do(ctx, "file/sort"+quarkPR+"&pdir_fid=0&_page=1&_size=100", nil)
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
		if item.Dir && item.FileName == quarkTmpDir {
			tmpFID = item.FID
			break
		}
	}
	if tmpFID == "" {
		return 0, nil
	}

	childReply, err := q.do(ctx, "file/sort"+quarkPR+"&pdir_fid="+url.QueryEscape(tmpFID)+"&_page=1&_size=200", nil)
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
	body := map[string]any{
		"action_type":  2,
		"filelist":     fids,
		"exclude_fids": []string{},
	}
	delReply, err := q.do(ctx, "file/delete"+quarkPR, body)
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

package core

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

// legacyProtocol 是旧接口的加解密参数（官网脚本里下发，也允许用户在设置里覆盖）。
type legacyProtocol struct {
	InterfaceKey string
	ParamKey     string
	ParamIV      string
}

type Tab struct {
	ID   string
	Name string
}

type legacyTabList []Tab

func (tabs *legacyTabList) UnmarshalJSON(raw []byte) error {
	raw = bytes.TrimSpace(raw)
	if len(raw) > 0 && raw[0] == '[' {
		return json.Unmarshal(raw, (*[]Tab)(tabs))
	}
	var wrapped struct {
		List []Tab `json:"list"`
	}
	if err := json.Unmarshal(raw, &wrapped); err != nil {
		return err
	}
	*tabs = wrapped.List
	return nil
}

type apiEnvelope struct {
	Code json.RawMessage `json:"code"`
	Msg  string          `json:"msg"`
	Hash json.RawMessage `json:"hash"`
	Data json.RawMessage `json:"data"`
}

func apiHashEnabled(raw json.RawMessage) bool {
	if len(raw) == 0 || string(raw) == "null" {
		return false
	}
	var b bool
	if err := json.Unmarshal(raw, &b); err == nil {
		return b
	}
	var s string
	if err := json.Unmarshal(raw, &s); err == nil {
		s = strings.TrimSpace(strings.ToLower(s))
		return s != "" && s != "false" && s != "0" && s != "null"
	}
	return true
}

type listResponse struct {
	List []Drama `json:"list"`
}

type detailResponse struct {
	Drama
	Title    string    `json:"title"`
	Name     string    `json:"name"`
	Chapters []Chapter `json:"chapters"`
}

func (detail *detailResponse) UnmarshalJSON(body []byte) error {
	var core struct {
		Title    string    `json:"title"`
		Name     string    `json:"name"`
		Chapters []Chapter `json:"chapters"`
	}
	if err := json.Unmarshal(body, &core); err != nil {
		return err
	}
	var fields map[string]any
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.UseNumber()
	if err := decoder.Decode(&fields); err != nil {
		return err
	}
	detail.Title, detail.Name, detail.Chapters = core.Title, core.Name, core.Chapters
	detail.Drama = Drama{
		ID: mapString(fields, "id"), Title: core.Title, Name: core.Name,
		Desc: mapString(fields, "desc", "description", "summary"), Intro: mapString(fields, "intro"),
		Cover: fields["cover"], CoverURL: fields["coverUrl"], CoverURLSnake: fields["cover_url"],
		Image: fields["image"], ImageURL: fields["imageUrl"], ImageURLSnake: fields["image_url"],
		Img: fields["img"], Pic: fields["pic"], Picture: fields["picture"], Poster: fields["poster"],
		Thumb: fields["thumb"], Thumbnail: fields["thumbnail"],
		TotalEpisode: fields["totalEpisode"], TotalEpisodeSnake: fields["total_episode"],
		EpisodeCount: fields["episodeCount"], EpisodeCountSnake: fields["episode_count"],
		ChapterCount: fields["chapterCount"], ChapterCountSnake: fields["chapter_count"],
		Total: fields["total"], Episodes: fields["episodes"],
		CategoryName: mapString(fields, "categoryName", "category_name", "typeName", "type_name", "sortName", "sort_name", "category"),
		Heat:         mapString(fields, "heat"), Views: mapString(fields, "views", "play_count"),
		OnlineDate: mapString(fields, "onlineDate", "online_date", "issue_date"),
		Tags:       mapStringSlice(fields, "tags"), ReleaseStatus: mapString(fields, "releaseStatus", "release_status"),
	}
	if value, known := fields["vip"].(bool); known {
		detail.Drama.VIP = &value
	}
	if detail.Drama.ReleaseStatus == "" {
		detail.Drama.ReleaseStatus = releaseStatusFromRemark(mapString(fields, "remark"))
	}
	return nil
}

func pkcs7Pad(src []byte, blockSize int) []byte {
	pad := blockSize - len(src)%blockSize
	return append(src, bytes.Repeat([]byte{byte(pad)}, pad)...)
}

func pkcs7Unpad(src []byte, blockSize int) ([]byte, error) {
	if len(src) == 0 || len(src)%blockSize != 0 {
		return nil, errors.New("invalid pkcs7 length")
	}
	pad := int(src[len(src)-1])
	if pad == 0 || pad > blockSize || pad > len(src) {
		return nil, errors.New("invalid pkcs7 padding")
	}
	for _, v := range src[len(src)-pad:] {
		if int(v) != pad {
			return nil, errors.New("invalid pkcs7 padding bytes")
		}
	}
	return src[:len(src)-pad], nil
}

func encryptParam(obj any, key, iv []byte) (string, error) {
	plain, err := json.Marshal(obj)
	if err != nil {
		return "", err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return "", err
	}
	padded := pkcs7Pad(plain, block.BlockSize())
	out := make([]byte, len(padded))
	cipher.NewCBCEncrypter(block, iv).CryptBlocks(out, padded)
	return base64.StdEncoding.EncodeToString(out), nil
}

func sha256Bytes(b []byte) []byte {
	h := sha256.Sum256(b)
	return h[:]
}

func decryptResponse(dataStr string, interfaceKey []byte) ([]byte, error) {
	o, err := base64.StdEncoding.DecodeString(strings.TrimSpace(dataStr))
	if err != nil {
		return nil, err
	}
	if len(o) < 12 {
		return nil, errors.New("encrypted payload too short")
	}
	i := o[:12]
	r := append(append([]byte{}, interfaceKey...), i...)
	l := len(r) >> 1
	s := sha256Bytes(r)[8:24]
	c := append(append([]byte{}, s...), r[:l]...)
	a := append(append([]byte{}, r[l:]...), s...)
	d := sha256Bytes(c)
	f := sha256Bytes(a)
	m := append(append(append([]byte{}, d[:8]...), f[8:24]...), d[24:]...)
	p := append(append(append([]byte{}, f[:4]...), d[12:20]...), f[28:]...)
	g := o[12:]
	block, err := aes.NewCipher(m)
	if err != nil {
		return nil, err
	}
	if len(g)%block.BlockSize() != 0 {
		return nil, errors.New("ciphertext is not block aligned")
	}
	plain := make([]byte, len(g))
	cipher.NewCBCDecrypter(block, p).CryptBlocks(plain, g)
	return pkcs7Unpad(plain, block.BlockSize())
}

type legacyAPIError struct{ code, message string }

func (err *legacyAPIError) Error() string {
	return fmt.Sprintf("黄果 API 错误 %s: %s", err.code, err.message)
}

// validLegacyProtocol 判断一套接口协议参数是否完整。
func validLegacyProtocol(protocol legacyProtocol) bool {
	return len(protocol.InterfaceKey) > 0 && len(protocol.InterfaceKey) <= 512 && len(protocol.ParamKey) == 16 && len(protocol.ParamIV) == 16
}

// validLegacyToken 判断令牌是否可以安全放进请求头。
func validLegacyToken(token string) bool {
	return len(token) <= 4096 && !strings.ContainsAny(token, "\r\n\t ")
}

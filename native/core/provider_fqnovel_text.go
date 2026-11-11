package core

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"html"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// 番茄正文接口：/reading/reader/full/v1/ 返回 AES-CBC 加密的正文。
// 先用注册设备号向 /reading/crypt/registerkey 换一把正文密钥（请求和返回都用固定的注册密钥加密），
// 再解开正文。听书章节的正文里带 novel-fm-asr 段落，每个 <span start_time="毫秒"> 是一句的起始时间。
const fqnovelTextBase = "https://api5-normal-sinfonlineb.fqnovel.com"

var fqnovelRegisterKey, _ = hex.DecodeString("ac25c67ddd8f38c1b37a2348828e222e")

type fqnovelTextKey struct {
	device string
	key    []byte
	at     time.Time
}

var fqnovelTextKeys struct {
	sync.Mutex
	current fqnovelTextKey
}

// AudiobookSegment 是一句话；Start 为秒，没有时间戳时为 -1。
type AudiobookSegment struct {
	Text  string  `json:"text"`
	Start float64 `json:"start"`
}

type AudiobookParagraph struct {
	Text     string             `json:"text"`
	Start    float64            `json:"start"`
	Segments []AudiobookSegment `json:"segments,omitempty"`
}

func (downloader *Downloader) fqnovelSignedRequest(ctx context.Context, method, raw, body string) ([]byte, error) {
	var nonce, random [4]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return nil, err
	}
	if _, err := rand.Read(random[:]); err != nil {
		return nil, err
	}
	headers, err := novelfmSignRequest(raw, body, time.Now().UnixMilli(), nonce[:], binary.BigEndian.Uint32(random[:]))
	if err != nil {
		return nil, err
	}
	var reader io.Reader
	if body != "" {
		reader = strings.NewReader(body)
	}
	request, err := http.NewRequestWithContext(ctx, method, raw, reader)
	if err != nil {
		return nil, err
	}
	if body != "" {
		request.Header.Set("Content-Type", "application/json; charset=utf-8")
	}
	request.Header.Set("User-Agent", "com.dragon.read")
	for key, value := range headers {
		request.Header.Set(key, value)
	}
	client := downloader.client
	if client == nil {
		client = &http.Client{Timeout: 20 * time.Second}
	}
	response, err := client.Do(request)
	if err != nil {
		return nil, errors.New("无法连接番茄正文接口")
	}
	defer response.Body.Close()
	payload, err := io.ReadAll(io.LimitReader(response.Body, 4<<20))
	if err != nil {
		return nil, err
	}
	if response.StatusCode != http.StatusOK || len(bytes.TrimSpace(payload)) == 0 {
		return nil, errors.New("番茄正文接口没有返回内容")
	}
	return payload, nil
}

func fqnovelTextQuery(device audiobookPlaybackDevice) string {
	return "aid=1967&app_name=novelapp&device_platform=android&os=android&version_code=58932&version_name=5.8.9.32" +
		"&device_id=" + url.QueryEscape(device.DeviceID) + "&iid=" + url.QueryEscape(device.Install)
}

func fqnovelRegisterContent(deviceID string) (string, error) {
	id, err := strconv.ParseUint(deviceID, 10, 64)
	if err != nil {
		return "", errors.New("设备号无效")
	}
	plain := make([]byte, 16)
	binary.LittleEndian.PutUint64(plain[:8], id)
	iv := make([]byte, aes.BlockSize)
	if _, err := rand.Read(iv); err != nil {
		return "", err
	}
	block, err := aes.NewCipher(fqnovelRegisterKey)
	if err != nil {
		return "", err
	}
	padded := pkcs7Pad(plain, aes.BlockSize)
	encrypted := make([]byte, len(padded))
	cipher.NewCBCEncrypter(block, iv).CryptBlocks(encrypted, padded)
	return base64.StdEncoding.EncodeToString(append(iv, encrypted...)), nil
}

func fqnovelDecrypt(key []byte, encoded string) ([]byte, error) {
	raw, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil || len(raw) < 2*aes.BlockSize || len(raw)%aes.BlockSize != 0 {
		return nil, errors.New("番茄正文密文格式异常")
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	plain := make([]byte, len(raw)-aes.BlockSize)
	cipher.NewCBCDecrypter(block, raw[:aes.BlockSize]).CryptBlocks(plain, raw[aes.BlockSize:])
	return pkcs7Unpad(plain, aes.BlockSize)
}

func (downloader *Downloader) fqnovelContentKey(ctx context.Context, device audiobookPlaybackDevice, refresh bool) ([]byte, error) {
	fqnovelTextKeys.Lock()
	current := fqnovelTextKeys.current
	fqnovelTextKeys.Unlock()
	if !refresh && current.device == device.DeviceID && len(current.key) == 16 && time.Since(current.at) < 6*time.Hour {
		return current.key, nil
	}
	content, err := fqnovelRegisterContent(device.DeviceID)
	if err != nil {
		return nil, err
	}
	payload, err := downloader.fqnovelSignedRequest(ctx, http.MethodPost,
		fqnovelTextBase+"/reading/crypt/registerkey?"+fqnovelTextQuery(device), `{"content":"`+content+`","keyver":1}`)
	if err != nil {
		return nil, err
	}
	var decoded struct {
		Code int `json:"code"`
		Data struct {
			Key string `json:"key"`
		} `json:"data"`
	}
	if json.Unmarshal(payload, &decoded) != nil || decoded.Code != 0 || decoded.Data.Key == "" {
		return nil, errors.New("番茄正文密钥注册失败")
	}
	key, err := fqnovelDecrypt(fqnovelRegisterKey, decoded.Data.Key)
	if err != nil || len(key) < 16 {
		return nil, errors.New("番茄正文密钥无法解开")
	}
	key = key[:16]
	fqnovelTextKeys.Lock()
	fqnovelTextKeys.current = fqnovelTextKey{device: device.DeviceID, key: key, at: time.Now()}
	fqnovelTextKeys.Unlock()
	return key, nil
}

// fetchAudiobookText 取回一章正文，按段落返回；听书章节带逐句时间戳。
func (downloader *Downloader) fetchAudiobookText(ctx context.Context, itemID string) ([]AudiobookParagraph, error) {
	itemID = strings.TrimSpace(itemID)
	if !hongguoNumericID.MatchString(itemID) {
		return nil, errors.New("听书章节无效")
	}
	device, err := downloader.audiobookPlaybackDevice(ctx)
	if err != nil {
		return nil, err
	}
	var lastErr error
	for attempt := 0; attempt < 2; attempt++ {
		key, err := downloader.fqnovelContentKey(ctx, device, attempt > 0)
		if err != nil {
			return nil, err
		}
		payload, err := downloader.fqnovelSignedRequest(ctx, http.MethodGet,
			fqnovelTextBase+"/reading/reader/full/v1/?"+fqnovelTextQuery(device)+"&item_id="+itemID, "")
		if err != nil {
			return nil, err
		}
		var decoded struct {
			Code int `json:"code"`
			Data struct {
				Content     string `json:"content"`
				CryptStatus int    `json:"crypt_status"`
			} `json:"data"`
		}
		if json.Unmarshal(payload, &decoded) != nil || decoded.Code != 0 || decoded.Data.Content == "" || decoded.Data.Content == "Invalid" {
			lastErr = errors.New("这一章暂时没有原文")
			continue
		}
		plain, err := fqnovelDecrypt(key, decoded.Data.Content)
		if err != nil {
			lastErr = err
			continue
		}
		if unzipped, err := gzip.NewReader(bytes.NewReader(plain)); err == nil {
			if data, err := io.ReadAll(io.LimitReader(unzipped, 8<<20)); err == nil {
				plain = data
			}
		}
		paragraphs := parseAudiobookText(string(plain))
		if len(paragraphs) == 0 {
			lastErr = errors.New("这一章暂时没有原文")
			continue
		}
		return paragraphs, nil
	}
	return nil, lastErr
}

var (
	audiobookParagraphPattern = regexp.MustCompile(`(?s)<p\b[^>]*>(.*?)</p>`)
	audiobookSpanPattern      = regexp.MustCompile(`(?s)<span\b[^>]*?start_time="(\d+)"[^>]*>(.*?)</span>`)
	audiobookTagPattern       = regexp.MustCompile(`(?s)<[^>]+>`)
)

func audiobookPlain(raw string) string {
	return strings.TrimSpace(html.UnescapeString(audiobookTagPattern.ReplaceAllString(raw, "")))
}

func parseAudiobookText(document string) []AudiobookParagraph {
	var paragraphs []AudiobookParagraph
	for _, match := range audiobookParagraphPattern.FindAllStringSubmatch(document, -1) {
		inner := match[1]
		if strings.Contains(inner, "{!--") {
			continue // PGC_VOICE 等元数据
		}
		paragraph := AudiobookParagraph{Start: -1}
		for _, span := range audiobookSpanPattern.FindAllStringSubmatch(inner, -1) {
			text := audiobookPlain(span[2])
			if text == "" {
				continue
			}
			ms, _ := strconv.ParseInt(span[1], 10, 64)
			paragraph.Segments = append(paragraph.Segments, AudiobookSegment{Text: text, Start: float64(ms) / 1000})
		}
		if len(paragraph.Segments) > 0 {
			var text strings.Builder
			for _, segment := range paragraph.Segments {
				text.WriteString(segment.Text)
			}
			paragraph.Text = text.String()
			paragraph.Start = paragraph.Segments[0].Start
		} else {
			paragraph.Text = audiobookPlain(inner)
		}
		if paragraph.Text != "" {
			paragraphs = append(paragraphs, paragraph)
		}
	}
	return paragraphs
}

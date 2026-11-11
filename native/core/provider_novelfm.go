package core

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/md5"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"math/bits"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const novelfmAid = "1967"
const novelfmLicense = "1611921764"

func newNovelfmDeviceID() (string, error) {
	var random [6]byte
	if _, err := rand.Read(random[:]); err != nil {
		return "", err
	}
	value := uint64(random[0])<<40 | uint64(random[1])<<32 | uint64(random[2])<<24 | uint64(random[3])<<16 | uint64(random[4])<<8 | uint64(random[5])
	return strconv.FormatUint(1_000_000_000_000_000+value, 10), nil
}

func novelfmSignRequest(rawURL, body string, nowMillis int64, nonce []byte, randomValue uint32) (map[string]string, error) {
	parsed, err := url.Parse(rawURL)
	if err != nil {
		return nil, err
	}
	seconds := nowMillis / 1000
	query := strings.TrimPrefix(parsed.RawQuery, "?")
	aid := novelfmQueryValue(query, "aid")
	if aid == "" {
		aid = novelfmAid
	}
	headers := map[string]string{
		"x-argus":         novelfmArgus(query, []byte(body), seconds, randomValue, aid),
		"x-ladon":         novelfmLadon(seconds, nonce, aid),
		"x-khronos":       strconv.FormatInt(seconds, 10),
		"x-ss-req-ticket": strconv.FormatInt(nowMillis, 10),
	}
	if body != "" {
		sum := md5.Sum([]byte(body))
		headers["X-SS-STUB"] = hex.EncodeToString(sum[:])
	}
	return headers, nil
}

func novelfmArgus(query string, body []byte, seconds int64, randomValue uint32, aid string) string {
	signKey, _ := hex.DecodeString("ac1adaae95a7af94a5114ab3b3a97dd80050aa0a39314c40528caec95256c28c")
	version := novelfmQueryValue(query, "version_name")
	deviceID := novelfmQueryValue(query, "device_id")
	bodyHash := make([]byte, 16)
	if len(body) > 0 {
		sum := md5.Sum(body)
		bodyHash = sum[:]
	}
	queryHash := make([]byte, 16)
	if query != "" {
		queryHash = []byte(query)
	}
	message := novelfmAppendNum(nil, 1, 0x20200929*2)
	message = novelfmAppendNum(message, 2, 2)
	message = novelfmAppendNum(message, 3, randomValue)
	message = novelfmAppendBytes(message, 4, []byte(aid))
	message = novelfmAppendBytes(message, 5, []byte(deviceID))
	message = novelfmAppendBytes(message, 6, []byte(novelfmLicense))
	message = novelfmAppendBytes(message, 7, []byte(version))
	message = novelfmAppendBytes(message, 8, []byte("v04.04.05-ov-android"))
	message = novelfmAppendNum(message, 9, 134744640)
	message = novelfmAppendBytes(message, 10, make([]byte, 8))
	message = novelfmAppendNum(message, 11, 0)
	message = novelfmAppendNum(message, 12, uint32(seconds*2))
	bodySM3 := hongguoSM3(bodyHash)
	querySM3 := hongguoSM3(queryHash)
	message = novelfmAppendBytes(message, 13, bodySM3[:6])
	message = novelfmAppendBytes(message, 14, querySM3[:6])
	nested := novelfmAppendNum(nil, 1, 1)
	nested = novelfmAppendNum(nested, 2, 1)
	nested = novelfmAppendNum(nested, 3, 1)
	nested = novelfmAppendNum(nested, 7, 3348294860)
	message = novelfmAppendBytes(message, 15, nested)
	message = novelfmAppendBytes(message, 16, nil)
	message = novelfmAppendBytes(message, 20, []byte("none"))
	message = novelfmAppendNum(message, 21, 738)
	device := novelfmAppendBytes(nil, 1, []byte("NX551J"))
	device = novelfmAppendNum(device, 2, 8196)
	device = novelfmAppendNum(device, 4, 2162219008)
	message = novelfmAppendBytes(message, 23, device)
	message = novelfmAppendNum(message, 25, 2)

	mixed := append(append([]byte{}, signKey...), 0xf2, 0x81, 0x61, 0x6f)
	mixed = append(mixed, signKey...)
	simonKey := hongguoSM3(mixed)
	scrambled := append([]byte{0xf2, 0xf7, 0xfc, 0xff, 0xf2, 0xf7, 0xfc, 0xff}, novelfmSimon(pkcs7Pad(message, 16), simonKey[:])...)
	for i := 8; i < len(scrambled); i++ {
		scrambled[i] ^= scrambled[i%8]
	}
	for i, j := 0, len(scrambled)-1; i < j; i, j = i+1, j-1 {
		scrambled[i], scrambled[j] = scrambled[j], scrambled[i]
	}
	input := append([]byte{0xa6, 0x6e, 0xad, 0x9f, 0x77, 0x01, 0xd0, 0x0c, 0x18}, scrambled...)
	input = append(input, 'a', 'o')
	keySum := md5.Sum(signKey[:16])
	ivSum := md5.Sum(signKey[16:])
	block, _ := aes.NewCipher(keySum[:])
	padded := pkcs7Pad(input, aes.BlockSize)
	cipher.NewCBCEncrypter(block, ivSum[:]).CryptBlocks(padded, padded)
	out := append([]byte{0xf2, 0x81}, padded...)
	return base64.StdEncoding.EncodeToString(out)
}

func novelfmLadon(seconds int64, nonce []byte, aid string) string {
	sum := md5.Sum(append(append([]byte{}, nonce...), []byte(aid)...))
	seed := []byte(hex.EncodeToString(sum[:]))
	words := novelfmWords(seed)
	first := words[0]
	tail := append([]uint64{}, words[1:]...)
	rounds := []uint64{first}
	for i := 0; i < 33; i++ {
		turned := novelfmRotr(tail[i], 8)
		next := (turned + rounds[i]) ^ uint64(i)
		tail = append(tail, next)
		rounds = append(rounds, next^novelfmRotl(rounds[i], 3))
	}
	plain := pkcs7Pad([]byte(strconv.FormatInt(seconds, 10)+"-"+novelfmLicense+"-"+aid), 16)
	var blocks []byte
	for offset := 0; offset < len(plain); offset += 16 {
		pair := novelfmWords(plain[offset : offset+16])
		a, b := pair[0], pair[1]
		for _, key := range rounds {
			b = (novelfmRotr(b, 8) + a) ^ key
			a = novelfmRotl(a, 3) ^ b
		}
		blocks = append(blocks, novelfmPackWords([]uint64{a, b})...)
	}
	return base64.StdEncoding.EncodeToString(append(append([]byte{}, nonce...), blocks...))
}

func novelfmSimon(plain, key []byte) []byte {
	roundKeys := novelfmWords(key)
	for len(roundKeys) < 72 {
		i := len(roundKeys)
		turned := novelfmRotr(roundKeys[i-1], 3) ^ roundKeys[i-3]
		bit := (uint64(0x3dc94c3a046d678b) >> ((i - 4) % 62)) & 1
		roundKeys = append(roundKeys, ^roundKeys[i-4]^turned^novelfmRotr(turned, 1)^bit^3)
	}
	var out []byte
	for offset := 0; offset < len(plain); offset += 16 {
		pair := novelfmWords(plain[offset : offset+16])
		a, b := pair[0], pair[1]
		for _, key := range roundKeys {
			a, b = b, a^(novelfmRotl(b, 1)&novelfmRotl(b, 8))^novelfmRotl(b, 2)^key
		}
		out = append(out, novelfmPackWords([]uint64{a, b})...)
	}
	return out
}

func novelfmWords(in []byte) []uint64 {
	words := make([]uint64, len(in)/8)
	for i := range words {
		words[i] = binary.LittleEndian.Uint64(in[i*8 : (i+1)*8])
	}
	return words
}

func novelfmPackWords(values []uint64) []byte {
	out := make([]byte, len(values)*8)
	for i, value := range values {
		binary.LittleEndian.PutUint64(out[i*8:], value)
	}
	return out
}

func novelfmRotl(value uint64, n int) uint64 { return bits.RotateLeft64(value, n) }
func novelfmRotr(value uint64, n int) uint64 { return bits.RotateLeft64(value, -n) }

func novelfmVarint(n uint32) []byte {
	var out []byte
	for {
		b := byte(n & 0x7f)
		n >>= 7
		if n != 0 {
			b |= 0x80
		}
		out = append(out, b)
		if n == 0 {
			return out
		}
	}
}

func novelfmAppendNum(dst []byte, tag int, n uint32) []byte {
	dst = append(dst, novelfmVarint(uint32(tag<<3))...)
	return append(dst, novelfmVarint(n)...)
}

func novelfmAppendBytes(dst []byte, tag int, value []byte) []byte {
	dst = append(dst, novelfmVarint(uint32(tag<<3|2))...)
	dst = append(dst, novelfmVarint(uint32(len(value)))...)
	return append(dst, value...)
}

func novelfmQueryValue(query, key string) string {
	values, _ := url.ParseQuery(query)
	return values.Get(key)
}

func (downloader *Downloader) resolveNovelfmAudio(ctx context.Context, bookID, itemID string) (providerMedia, error) {
	bookID = strings.TrimSpace(bookID)
	itemID = strings.TrimSpace(itemID)
	if bookID == "" || itemID == "" {
		return providerMedia{}, errors.New("听书章节无效")
	}
	query := "os=android&aid=3040&app_name=novel_fm&ssmix=a&manifest_version_code=632&channel=54157680a&device_platform=android&device_brand=Redmi&language=zh&os_api=35&vip_state=0&host_abi=arm64-v8a&category_style=1&need_personal_recommend=1"
	raw := "https://api5-sinfonlineb.novelfm.com/novelfm/playerapi/video_model/mget/v1?" + query
	body := `{"audio_type":0,"bgm_used":0,"book_id":"` + bookID + `","device_score":0,"item_ids":["` + itemID + `"],"multi_shift":false,"source":"default","tone_id":0,"user_select_start_para":0,"user_select_start_para_off":0}`
	var nonce [4]byte
	var randomValue [4]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return providerMedia{}, err
	}
	if _, err := rand.Read(randomValue[:]); err != nil {
		return providerMedia{}, err
	}
	headers, err := novelfmSignRequest(raw, body, time.Now().UnixMilli(), nonce[:], binary.BigEndian.Uint32(randomValue[:]))
	if err != nil {
		return providerMedia{}, err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, raw, strings.NewReader(body))
	if err != nil {
		return providerMedia{}, err
	}
	request.Header.Set("Content-Type", "application/json; charset=utf-8")
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
		return providerMedia{}, errors.New("无法连接番茄畅听")
	}
	defer response.Body.Close()
	payload, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if err != nil {
		return providerMedia{}, err
	}
	if len(bytesTrim(payload)) == 0 {
		return providerMedia{}, errors.New("番茄畅听没有返回音频")
	}
	var parsed map[string]any
	if err := json.Unmarshal(payload, &parsed); err != nil {
		return providerMedia{}, errors.New("番茄畅听播放信息无法识别")
	}
	if code, _ := parsed["code"].(float64); code != 0 {
		return providerMedia{}, errors.New("番茄畅听没有返回音频")
	}
	address, key, duration, err := novelfmSelectAudio(parsed)
	if err != nil {
		return providerMedia{}, err
	}
	return providerMedia{
		URL:      address,
		Referer:  "https://novelfm.changdunovel.com/",
		CENCKey:  key,
		Duration: time.Duration(duration * float64(time.Second)),
	}, nil
}

func novelfmSelectAudio(root map[string]any) (string, []byte, float64, error) {
	data, _ := root["data"].(map[string]any)
	rows, _ := data["video_model_datas"].([]any)
	if len(rows) == 0 {
		return "", nil, 0, errors.New("这一章暂时没有音频地址")
	}
	row, _ := rows[0].(map[string]any)
	raw, _ := row["video_model"].(string)
	var model map[string]any
	if json.Unmarshal([]byte(raw), &model) != nil {
		return "", nil, 0, errors.New("番茄畅听播放信息无法识别")
	}
	duration, _ := model["video_duration"].(float64)
	list, _ := model["video_list"].([]any)
	if len(list) == 0 {
		return "", nil, duration, errors.New("这一章暂时没有音频地址")
	}
	item, _ := list[0].(map[string]any)
	address, _ := item["main_url"].(string)
	if address == "" {
		return "", nil, duration, errors.New("这一章暂时没有音频地址")
	}
	info, _ := item["encrypt_info"].(map[string]any)
	encrypted, _ := info["encrypt"].(bool)
	if !encrypted {
		return address, nil, duration, nil
	}
	spade, _ := info["spade_a"].(string)
	key, err := hongguoContentKey(spade)
	if err != nil || len(key) != 16 {
		return "", nil, duration, errors.New("这一章的音频暂时解不开")
	}
	return address, key, duration, nil
}

func bytesTrim(value []byte) []byte {
	return []byte(strings.TrimSpace(string(value)))
}

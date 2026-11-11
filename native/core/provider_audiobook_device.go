package core

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/md5"
	"crypto/rand"
	"crypto/sha512"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// 听书正文接口必须带一台新注册的番茄设备身份，和短剧取流用的设备注册互不干扰：
// 这里单独保留一套轻量的注册实现，避免改动 guoappxp 现有的红果设备链。
const audiobookRegisterURL = "https://log5-applog-lf.fqnovel.com/service/2/device_register/?tt_data=a&cronet_version=8d40f833_2026-03-03&ttnet_version=4.2.243.31-douyin&use_store_region_cookie=1"

var audiobookRegisterSalt = []byte{
	0x4d, 0xd4, 0xc2, 0xe6, 0xb8, 0x31, 0x62, 0x09, 0x0e, 0x52, 0xb3, 0xc7, 0xa6, 0x73, 0x3b, 0xa4,
	0x1c, 0xb2, 0x46, 0x2b, 0x82, 0x9a, 0xb5, 0x8a, 0x19, 0x6b, 0x39, 0xdb, 0x57, 0x17, 0x75, 0x24,
	0xf4, 0x9b, 0xaf, 0x7f, 0x08, 0xe8, 0xd6, 0x8d, 0x26, 0xa7, 0x2e, 0x37, 0xc1, 0xa9, 0x5a, 0x2f,
	0x1f, 0x05, 0xa5, 0x18, 0x92, 0xae, 0xf2, 0x94, 0x97, 0x32, 0xb6, 0x2a, 0x38, 0xaa, 0xdd, 0x58,
}

var errAudiobookDeviceRegister = errors.New("听书设备注册失败")

type audiobookPlaybackDevice struct {
	DeviceID string
	Install  string
	CDID     string
}

// audiobookPlaybackDevice 每次请求都注册一台新设备，不复用。
func (downloader *Downloader) audiobookPlaybackDevice(ctx context.Context) (audiobookPlaybackDevice, error) {
	device, err := downloader.registerAudiobookPlaybackDevice(ctx)
	if err != nil {
		return audiobookPlaybackDevice{}, fmt.Errorf("%w：%v", errAudiobookDeviceRegister, err)
	}
	return device, nil
}

func (downloader *Downloader) registerAudiobookPlaybackDevice(ctx context.Context) (audiobookPlaybackDevice, error) {
	now := time.Now().UnixMilli()
	cdid, err := audiobookRandomUUID()
	if err != nil {
		return audiobookPlaybackDevice{}, err
	}
	body, err := audiobookRegisterBody(now, cdid)
	if err != nil {
		return audiobookPlaybackDevice{}, err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, audiobookRegisterURL, bytes.NewReader(body))
	if err != nil {
		return audiobookPlaybackDevice{}, err
	}
	sum := md5.Sum(body)
	request.Header.Set("User-Agent", "com.phoenix.read/72232 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3)")
	request.Header.Set("Accept", "application/json")
	request.Header.Set("Content-Type", "application/octet-stream;tt-data=a")
	request.Header.Set("log-encode-type", "gzip")
	request.Header.Set("x-ss-dp", "8662")
	request.Header.Set("x-ss-req-ticket", strconv.FormatInt(now, 10))
	request.Header.Set("x-vc-bdturing-sdk-version", "4.0.3.cn")
	request.Header.Set("lc", "101")
	request.Header.Set("sdk-version", "2")
	request.Header.Set("passport-sdk-version", "5051452")
	request.Header.Set("x-neptune", "-8|50:51:59:30:40:47:49:39")
	request.Header.Set("x-ss-stub", strings.ToUpper(hex.EncodeToString(sum[:])))
	response, err := downloader.doCatalogRequestWithTimeout(request, 12*time.Second)
	if err != nil {
		return audiobookPlaybackDevice{}, err
	}
	defer response.Body.Close()
	payload, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if err != nil {
		return audiobookPlaybackDevice{}, err
	}
	if response.StatusCode != http.StatusOK || len(payload) == 0 {
		return audiobookPlaybackDevice{}, errors.New("听书设备注册没有返回身份")
	}
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.UseNumber()
	var decoded map[string]any
	if decoder.Decode(&decoded) != nil || decoded == nil {
		return audiobookPlaybackDevice{}, errors.New("听书设备注册返回格式异常")
	}
	if code := mapString(decoded, "code", "Code"); code != "" && code != "0" {
		return audiobookPlaybackDevice{}, errors.New("听书设备注册被拒绝")
	}
	deviceID := audiobookResponseID(decoded, "device_id")
	installID := audiobookResponseID(decoded, "install_id")
	if deviceID == "" || installID == "" {
		return audiobookPlaybackDevice{}, errors.New("听书设备注册未返回设备号")
	}
	return audiobookPlaybackDevice{DeviceID: deviceID, Install: installID, CDID: cdid}, nil
}

func audiobookResponseID(payload map[string]any, name string) string {
	if text := mapString(payload, name+"_str"); hongguoNumericID.MatchString(text) && strings.ContainsAny(text, "123456789") {
		return text
	}
	text := mapString(payload, name)
	if hongguoNumericID.MatchString(text) && strings.ContainsAny(text, "123456789") {
		return text
	}
	return ""
}

func audiobookRandomUUID() (string, error) {
	var value [16]byte
	if _, err := rand.Read(value[:]); err != nil {
		return "", err
	}
	value[6] = (value[6] & 0x0f) | 0x40
	value[8] = (value[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", value[0:4], value[4:6], value[6:8], value[8:10], value[10:]), nil
}

func audiobookRegisterBody(now int64, cdid string) ([]byte, error) {
	openUDID := make([]byte, 8)
	if _, err := rand.Read(openUDID); err != nil {
		return nil, err
	}
	clientID, err := audiobookRandomUUID()
	if err != nil {
		return nil, err
	}
	requestID, err := audiobookRandomUUID()
	if err != nil {
		return nil, err
	}
	header := map[string]any{
		"display_name": "红果免费短剧", "update_version_code": 73932, "manifest_version_code": 73932,
		"app_version_minor": "7.3.9.32", "aid": 8662, "channel": "update_64", "package": "com.phoenix.read",
		"app_version": "7.3.9.32", "version_code": 73932, "sdk_version": "3.7.0-rc.34-fanqie-xiaoshuo",
		"sdk_target_version": 29, "git_hash": "3a88f4e", "os": "Android", "os_version": "16", "os_api": 36,
		"device_model": "25053RT47C", "device_brand": "Redmi", "device_manufacturer": "Redmi",
		"cpu_abi": "arm64-v8a", "release_build": "b5e187f", "density_dpi": 520, "display_density": "mdpi",
		"resolution": "1280x2772", "language": "zh", "timezone": 8, "access": "wifi", "not_request_sender": 0,
		"carrier": "CHINA MOBILE", "mcc_mnc": "46000", "rom": "eng.root.20231116.160340",
		"rom_version": "W528JS release-keys", "cdid": cdid,
		"sig_hash": "56a962410c494bbaf0b58dba20cae56f", "openudid": hex.EncodeToString(openUDID),
		"clientudid": clientID, "ipv6_list": []any{}, "region": "CN", "tz_name": "Asia/Shanghai",
		"tz_offset": 28800, "sim_region": "cn", "sim_serial_number": []any{}, "oaid_may_support": false,
		"req_id": requestID, "device_platform": "android",
		"custom":                map[string]any{"account_region_src": "fallback", "account_region": "cn", "host_bit": 64, "dragon_device_type": "phone"},
		"pre_installed_channel": "", "apk_first_install_time": now, "is_system_app": 0, "sdk_flavor": "china", "guest_mode": 0,
	}
	raw, err := json.Marshal(map[string]any{"magic_tag": "ss_app_log", "header": header, "_gen_time": now})
	if err != nil {
		return nil, err
	}
	var compressed bytes.Buffer
	writer, err := gzip.NewWriterLevel(&compressed, gzip.DefaultCompression)
	if err != nil {
		return nil, err
	}
	if _, err = writer.Write(raw); err != nil {
		return nil, err
	}
	if err = writer.Close(); err != nil {
		return nil, err
	}
	random := make([]byte, 32)
	if _, err = rand.Read(random); err != nil {
		return nil, err
	}
	first := sha512.Sum512(random)
	derived := sha512.Sum512(append(first[:], audiobookRegisterSalt...))
	block, err := aes.NewCipher(derived[:16])
	if err != nil {
		return nil, err
	}
	digest := sha512.Sum512(compressed.Bytes())
	plain := pkcs7Pad(append(digest[:], compressed.Bytes()...), aes.BlockSize)
	encrypted := make([]byte, len(plain))
	cipher.NewCBCEncrypter(block, derived[16:32]).CryptBlocks(encrypted, plain)
	return append(append([]byte{0x74, 0x63, 0x05, 0x10, 0x00, 0x00}, random...), encrypted...), nil
}

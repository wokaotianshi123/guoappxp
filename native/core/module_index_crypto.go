package core

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"errors"
)

// 在线仓库（真果鉴 guoapp.dpdns.org 一系）索引的读取。
//
// 真果鉴仓库现在直接下发**明文** index.json（标准 JSON，顶层 format + modules），
// 客户端拿到就能解析，不再需要解密；之前它会用 AES-256-GCM 把索引加密后下发，
// 封包格式固定为：
//
//	GCM1 | nonce(12) | 密文 | tag(16)
//
// 前缀是 4 个 ASCII 字节 "GCM1"，其后没有版本号或长度字段，nonce 每次随机。
// 老版本客户端只认这种封包，所以这里保留解密封包的分支：镜像 / CDN 上残留的
// 旧密文照样能读，明文与密文两条路最后都走同一个 parseModuleIndex。
//
// 明文索引在解析前会做一次清洗（见 plainModuleIndex）：编辑器或上传工具偶尔
// 会在文件头带上 UTF-8 BOM、在末尾留下空行，json.Unmarshal 遇到 BOM 会直接
// 报「索引格式无效」，把一份本来完全合法的索引判成坏数据。

const (
	// encryptedModuleIndexPrefix 是加密索引的魔数前缀。
	encryptedModuleIndexPrefix = "GCM1"
	// encryptedModuleIndexNonce 是 GCM nonce 长度（标准 12 字节）。
	encryptedModuleIndexNonce = 12
	// encryptedModuleIndexTag 是 GCM 认证标签长度（标准 16 字节）。
	encryptedModuleIndexTag = 16
)

// encryptedModuleIndexKey 是旧版加密在线仓库的 AES-256 密钥。
//
// 与真果鉴 APK 中 libduanju_core.so 的 .noptrdata 段内置值一致。仓库改成明文
// 下发后只有镜像上的历史密文还会用到它，保留是为了老链接不至于报错；改密钥会
// 同时影响所有使用该仓库的客户端，不要随意改动。
var encryptedModuleIndexKey = []byte{
	0x92, 0x91, 0x79, 0x5e, 0x2b, 0x95, 0xa7, 0x1d,
	0x52, 0x41, 0x8f, 0x69, 0xf3, 0x8e, 0x60, 0x14,
	0x3d, 0xee, 0x51, 0x02, 0x4e, 0x04, 0x69, 0xcf,
	0xa3, 0xd0, 0x6e, 0xf0, 0x22, 0x7e, 0x21, 0x96,
}

// isEncryptedModuleIndex 判断索引是否为旧版的加密封包。
func isEncryptedModuleIndex(raw []byte) bool {
	return bytes.HasPrefix(raw, []byte(encryptedModuleIndexPrefix))
}

// plainModuleIndex 清洗明文索引：去掉 UTF-8 BOM 与首尾空白。
//
// 真果鉴仓库的 index.json 现在由人工 / 脚本直接维护，文件头带 BOM、结尾多几个
// 空行都很常见。这两种情况都会让 json.Unmarshal 失败并显示成「索引格式无效」，
// 看起来像仓库坏了，所以解析前先归一。
func plainModuleIndex(raw []byte) []byte {
	return bytes.TrimSpace(bytes.TrimPrefix(raw, []byte("\xef\xbb\xbf")))
}

// decryptModuleIndex 返回可解析的索引明文：明文原样（清洗后）返回，旧版 GCM1
// 封包解出明文再返回。
//
// 不是加密格式时不报错，让调用方统一处理「明文仓库 / 加密仓库」两种来源。
func decryptModuleIndex(raw []byte) ([]byte, error) {
	if !isEncryptedModuleIndex(raw) {
		return plainModuleIndex(raw), nil
	}
	body := raw[len(encryptedModuleIndexPrefix):]
	if len(body) <= encryptedModuleIndexNonce+encryptedModuleIndexTag {
		return nil, errors.New("加密索引内容过短")
	}
	nonce := body[:encryptedModuleIndexNonce]
	sealed := body[encryptedModuleIndexNonce:]
	block, err := aes.NewCipher(encryptedModuleIndexKey)
	if err != nil {
		return nil, errors.New("索引解密失败")
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, errors.New("索引解密失败")
	}
	plain, err := aead.Open(nil, nonce, sealed, nil)
	if err != nil {
		// tag 校验失败：密钥不匹配或内容被篡改。不透出底层错误，避免把
		// 密码学细节抛给用户。
		return nil, errors.New("加密索引校验失败，请更新应用")
	}
	return plain, nil
}

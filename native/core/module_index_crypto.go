package core

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"errors"
)

// 加密在线仓库（真果鉴 guoapp.dpdns.org 一系）的索引解密。
//
// 服务端把 index.json 用 AES-256-GCM 加密后下发，封包格式固定为：
//
//	GCM1 | nonce(12) | 密文 | tag(16)
//
// 前缀是 4 个 ASCII 字节 "GCM1"，其后没有版本号或长度字段，nonce 每次随机，
// 因此同一份索引每次请求的密文都不同。密钥内置在客户端（与本项目同源的
// 真果鉴 APK 里以 32 字节常量形式存在），这里按同样的密钥与格式解密。
//
// 明文是标准索引 JSON，解出来之后走原有的 parseModuleIndex，所以加密仓库与
// 明文仓库在后续流程里完全没有区别。

const (
	// encryptedModuleIndexPrefix 是加密索引的魔数前缀。
	encryptedModuleIndexPrefix = "GCM1"
	// encryptedModuleIndexNonce 是 GCM nonce 长度（标准 12 字节）。
	encryptedModuleIndexNonce = 12
	// encryptedModuleIndexTag 是 GCM 认证标签长度（标准 16 字节）。
	encryptedModuleIndexTag = 16
)

// encryptedModuleIndexKey 是加密在线仓库的 AES-256 密钥。
//
// 与真果鉴 APK 中 libduanju_core.so 的 .noptrdata 段内置值一致；改密钥会
// 同时影响所有使用该仓库的客户端，不要随意改动。
var encryptedModuleIndexKey = []byte{
	0x92, 0x91, 0x79, 0x5e, 0x2b, 0x95, 0xa7, 0x1d,
	0x52, 0x41, 0x8f, 0x69, 0xf3, 0x8e, 0x60, 0x14,
	0x3d, 0xee, 0x51, 0x02, 0x4e, 0x04, 0x69, 0xcf,
	0xa3, 0xd0, 0x6e, 0xf0, 0x22, 0x7e, 0x21, 0x96,
}

// isEncryptedModuleIndex 判断索引是否为加密格式。
func isEncryptedModuleIndex(raw []byte) bool {
	return bytes.HasPrefix(raw, []byte(encryptedModuleIndexPrefix))
}

// decryptModuleIndex 解开 GCM1 封包的索引，返回明文 JSON。
//
// 明文索引原样返回（不是加密格式时不报错），让调用方可以统一处理
// 「加密仓库 / 明文仓库」两种来源。
func decryptModuleIndex(raw []byte) ([]byte, error) {
	if !isEncryptedModuleIndex(raw) {
		return raw, nil
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

package core

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"encoding/json"
	"testing"
)

// 测试用的密钥必须与 encryptedModuleIndexKey 一致：加密索引由服务端用同一
// 密钥下发，客户端只能解密、不能自行改密钥。
func sealTestModuleIndex(t *testing.T, plain []byte) []byte {
	t.Helper()
	block, err := aes.NewCipher(encryptedModuleIndexKey)
	if err != nil {
		t.Fatal(err)
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		t.Fatal(err)
	}
	nonce := bytes.Repeat([]byte{0x42}, encryptedModuleIndexNonce)
	sealed := aead.Seal(nil, nonce, plain, nil)
	out := append([]byte(encryptedModuleIndexPrefix), nonce...)
	return append(out, sealed...)
}

// TestDecryptModuleIndexRoundTrip 校验 GCM1 封包能还原出明文索引。
func TestDecryptModuleIndexRoundTrip(t *testing.T) {
	plain := []byte(`{"format":1,"modules":[{"id":"demo","name":"示例"}]}`)
	sealed := sealTestModuleIndex(t, plain)
	if !isEncryptedModuleIndex(sealed) {
		t.Fatal("封包应被识别为加密索引")
	}
	got, err := decryptModuleIndex(sealed)
	if err != nil {
		t.Fatalf("decryptModuleIndex: %v", err)
	}
	if !bytes.Equal(got, plain) {
		t.Fatalf("明文 = %q，期望 %q", got, plain)
	}
}

// TestDecryptModuleIndexPassesPlainText 明文索引要原样返回，不能被当成错误。
func TestDecryptModuleIndexPassesPlainText(t *testing.T) {
	plain := []byte(`{"format":1,"modules":[]}`)
	got, err := decryptModuleIndex(plain)
	if err != nil {
		t.Fatalf("明文索引不该报错: %v", err)
	}
	if !bytes.Equal(got, plain) {
		t.Fatalf("明文被改动: %q", got)
	}
}

// TestDecryptModuleIndexRejectsTampered 内容被改动或密钥不符时要报错，而不是
// 返回半截明文。
func TestDecryptModuleIndexRejectsTampered(t *testing.T) {
	sealed := sealTestModuleIndex(t, []byte(`{"format":1,"modules":[]}`))
	// 翻转密文里的一个字节（跳过 GCM1 前缀与 nonce）。
	sealed[len(encryptedModuleIndexPrefix)+encryptedModuleIndexNonce] ^= 0xff
	if _, err := decryptModuleIndex(sealed); err == nil {
		t.Fatal("篡改后的索引应解密失败")
	}
}

// TestDecryptModuleIndexRejectsShort 过短的封包要给出明确错误。
func TestDecryptModuleIndexRejectsShort(t *testing.T) {
	if _, err := decryptModuleIndex([]byte("GCM1")); err == nil {
		t.Fatal("空封包应报错")
	}
}

// TestParseEncryptedModuleIndex 端到端：加密索引解密后能解析出可用条目。
func TestParseEncryptedModuleIndex(t *testing.T) {
	index := map[string]any{
		"format": 1,
		"modules": []map[string]any{{
			"id": "demo", "name": "示例", "version": "1.0.0", "api": 1,
			"repo": "owner/repo", "tag": "v1.0.0",
			"sha256": map[string]string{
				"manifest.json": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
				"main.js":       "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
			},
		}},
	}
	plain, err := json.Marshal(index)
	if err != nil {
		t.Fatal(err)
	}
	sealed := sealTestModuleIndex(t, plain)
	decrypted, err := decryptModuleIndex(sealed)
	if err != nil {
		t.Fatalf("decryptModuleIndex: %v", err)
	}
	entries, err := parseModuleIndex(decrypted)
	if err != nil {
		t.Fatalf("parseModuleIndex: %v", err)
	}
	if len(entries) != 1 || entries[0].ID != "demo" {
		t.Fatalf("entries = %+v", entries)
	}
}

// TestBuiltinRepositoriesIncludeEncryptedStore 锁住内置仓库列表：
// guocheng1378 已换成真果鉴的加密仓库地址。
func TestBuiltinRepositoriesIncludeEncryptedStore(t *testing.T) {
	var found bool
	for _, repo := range moduleBuiltinRepositories {
		if repo.URL == "https://guoapp.dpdns.org/modules/index.json" {
			found = true
		}
		if repo.URL == "https://raw.githubusercontent.com/guocheng1378/guoapp-modules/refs/heads/main/index.json" {
			t.Fatal("旧的 guocheng1378 地址应已被替换")
		}
	}
	if !found {
		t.Fatalf("内置仓库缺少真果鉴加密仓库：%+v", moduleBuiltinRepositories)
	}
}

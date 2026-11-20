package core

import "testing"

func TestPKCS7PadUnpad(t *testing.T) {
	cases := [][]byte{
		{},
		[]byte("a"),
		[]byte("123456789012345"),
		[]byte("1234567890123456"),
		[]byte("0123456789012345678901234567890"),
	}
	for _, input := range cases {
		padded := modulePadPKCS7(input, 16)
		if len(padded)%16 != 0 {
			t.Fatalf("补齐后长度 %d 不是 16 的倍数", len(padded))
		}
		if len(padded) <= len(input) {
			t.Fatalf("补齐后长度 %d 应大于原文 %d", len(padded), len(input))
		}
		unpadded, ok := moduleUnpadPKCS7(padded, 16)
		if !ok {
			t.Fatalf("去填充失败")
		}
		if string(unpadded) != string(input) {
			t.Fatalf("往返不一致: %q -> %q", input, unpadded)
		}
	}
}

func TestPKCS7UnpadRejectsInvalid(t *testing.T) {
	// 末尾填充字节明显不合法时不能误删数据。
	bad := []byte("0123456789abcdef")
	if _, ok := moduleUnpadPKCS7(bad, 16); ok {
		t.Fatal("不合法的填充应被拒绝")
	}
	if _, ok := moduleUnpadPKCS7([]byte("short"), 16); ok {
		t.Fatal("长度不是块倍数时应被拒绝")
	}
}

// 用固定 key/iv 验证 AES-CBC 加解密往返。
//
// 加密自动补 PKCS#7，解密**不去填充**（模块自己 unpad），所以这里解密结果要
// 手动去填充才能还原原文。这也是 beabox / yeguo / huangdou 的真实写法。
func TestAesCbcRoundTripWithPadding(t *testing.T) {
	vm := newTestRuntime(t)
	key := []byte("1234567890123456")
	iv := []byte("6543210987654321")
	plain := []byte(`{"devID":"abc","sysType":"ios"}`) // 长度不是 16 的倍数

	vm.Set("key", bytesValueForTest(vm, key))
	vm.Set("iv", bytesValueForTest(vm, iv))
	vm.Set("plain", bytesValueForTest(vm, plain))
	if _, err := vm.RunString(`globalThis.sealed = host.aesCbcEncrypt(key, iv, plain)`); err != nil {
		t.Fatalf("加密失败: %v", err)
	}
	sealed := exportBytes(t, vm, "sealed")
	if len(sealed)%16 != 0 || len(sealed) <= len(plain) {
		t.Fatalf("密文长度 %d 异常", len(sealed))
	}
	if _, err := vm.RunString(`globalThis.opened = host.aesCbcDecrypt(key, iv, sealed)`); err != nil {
		t.Fatalf("解密失败: %v", err)
	}
	opened := exportBytes(t, vm, "opened")
	// 解密结果保持块对齐，模块据此判断填充是否合法。
	if len(opened)%16 != 0 {
		t.Fatalf("解密结果长度 %d 不是 16 的倍数（不应由宿主去填充）", len(opened))
	}
	unpadded, ok := moduleUnpadPKCS7(opened, 16)
	if !ok {
		t.Fatal("解密结果不是合法的 PKCS#7 填充")
	}
	if string(unpadded) != string(plain) {
		t.Fatalf("往返不一致: %q != %q", unpadded, plain)
	}
}

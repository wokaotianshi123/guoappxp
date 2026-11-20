package core

import (
	"testing"

	"github.com/dop251/goja"
)

// newTestRuntime 造一个带完整 host 对象的运行时，供加密/字节类测试使用。
func newTestRuntime(t *testing.T) *goja.Runtime {
	t.Helper()
	vm := goja.New()
	if err := installByteArrayHelpers(vm); err != nil {
		t.Fatal(err)
	}
	// 只装纯计算相关的成员：加解密、哈希、编码，不发网络请求。
	host := vm.NewObject()
	members := map[string]any{
		"utf8Encode": func(text string) goja.Value { return bytesValueForTest(vm, []byte(text)) },
		"utf8Decode": func(data goja.Value) string { return string(exportValueBytes(t, vm, data)) },
		"hexEncode":  func(data goja.Value) string { return hexEncodeBytes(exportValueBytes(t, vm, data)) },
		"base64Encode": func(data goja.Value) string {
			return base64EncodeBytes(exportValueBytes(t, vm, data))
		},
		"base64Decode": func(text string) (goja.Value, error) {
			raw, err := base64DecodeText(text)
			if err != nil {
				return nil, err
			}
			return bytesValueForTest(vm, raw), nil
		},
		"sha256": func(data goja.Value) goja.Value {
			return bytesValueForTest(vm, sha256Bytes(exportValueBytes(t, vm, data)))
		},
		"md5": func(data goja.Value) goja.Value {
			return bytesValueForTest(vm, md5Bytes(exportValueBytes(t, vm, data)))
		},
		"hmacSha256": func(key, data goja.Value) goja.Value {
			return bytesValueForTest(vm, hmacSha256Bytes(exportValueBytes(t, vm, key), exportValueBytes(t, vm, data)))
		},
		"aesCbcEncrypt": func(key, iv, data goja.Value) (goja.Value, error) {
			out, err := aesCBCEncryptBytes(exportValueBytes(t, vm, key), exportValueBytes(t, vm, iv), exportValueBytes(t, vm, data))
			if err != nil {
				return nil, err
			}
			return bytesValueForTest(vm, out), nil
		},
		"aesCbcDecrypt": func(key, iv, data goja.Value) (goja.Value, error) {
			out, err := aesCBCDecryptBytes(exportValueBytes(t, vm, key), exportValueBytes(t, vm, iv), exportValueBytes(t, vm, data))
			if err != nil {
				return nil, err
			}
			return bytesValueForTest(vm, out), nil
		},
	}
	for name, member := range members {
		_ = host.Set(name, member)
	}
	_ = vm.Set("host", host)
	return vm
}

func bytesValueForTest(vm *goja.Runtime, data []byte) goja.Value {
	array, err := vm.New(vm.Get("Uint8Array"), vm.ToValue(vm.NewArrayBuffer(data)))
	if err != nil {
		panic(err)
	}
	return array
}

func exportValueBytes(t *testing.T, vm *goja.Runtime, value goja.Value) []byte {
	t.Helper()
	if text, ok := value.Export().(string); ok {
		return []byte(text)
	}
	var data []byte
	if err := vm.ExportTo(value, &data); err != nil {
		t.Fatalf("无法导出字节: %v", err)
	}
	return append([]byte(nil), data...)
}

func exportBytes(t *testing.T, vm *goja.Runtime, name string) []byte {
	t.Helper()
	return exportValueBytes(t, vm, vm.Get(name))
}

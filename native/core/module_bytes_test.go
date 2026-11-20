package core

import (
	"testing"

	"github.com/dop251/goja"
)

// 验证 Uint8Array 经过 slice/concat 之后，bytesOf 还能不能正确取出字节。
// cloudfront 模块就是这么用的：host.base64Decode(...).slice(12) 再交给 aesCbcDecrypt。
func TestModuleBytesFromUint8ArrayOps(t *testing.T) {
	vm := goja.New()
	if err := installByteArrayHelpers(vm); err != nil {
		t.Fatal(err)
	}
	// 复制 module_host.go 里的 bytesOf 逻辑
	bytesOf := func(value goja.Value) []byte {
		if text, ok := value.Export().(string); ok {
			return []byte(text)
		}
		var data []byte
		if err := vm.ExportTo(value, &data); err != nil {
			panic(vm.NewTypeError("需要字符串或字节数组"))
		}
		return append([]byte(nil), data...)
	}
	bytesValue := func(data []byte) goja.Value {
		array, err := vm.New(vm.Get("Uint8Array"), vm.ToValue(vm.NewArrayBuffer(data)))
		if err != nil {
			panic(err)
		}
		return array
	}

	original := []byte{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20}
	vm.Set("bytes", bytesValue(original))
	vm.Set("bytesOf", bytesOf)

	cases := []struct {
		name   string
		script string
		want   int
	}{
		{"原样", `bytes`, 20},
		{"slice", `bytes.slice(12)`, 8},
		{"slice 后再切片", `bytes.slice(0,12)`, 12},
		{"concat", `bytes.slice(0,4).concat(bytes.slice(8,12))`, 8},
		{"subarray", `bytes.subarray(4)`, 16},
	}
	for _, item := range cases {
		value, err := vm.RunString(`globalThis.out = bytesOf(` + item.script + `)`)
		if err != nil {
			t.Errorf("%s: 执行失败 %v", item.name, err)
			continue
		}
		_ = value
		exported := vm.Get("out").Export()
		data, ok := exported.([]byte)
		if !ok {
			t.Errorf("%s: 导出类型 %T，不是 []byte", item.name, exported)
			continue
		}
		if len(data) != item.want {
			t.Errorf("%s: 长度 %d，期望 %d", item.name, len(data), item.want)
			continue
		}
		t.Logf("%s: OK (%d 字节)", item.name, len(data))
	}
}

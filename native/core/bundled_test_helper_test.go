package core

import (
	"testing"
	"testing/fstest"
)

// isolateBundledModules 把内置模块表换成空的，测试结束后恢复。
//
// 仓库现在自带 modules/ 并在出包时复制进 native/core/bundled/，因此
// loadModules() 会把那批内置模块注册进全局注册表。凡是断言「注册表里只有
// 本用例装的模块」的测试都必须先清空内置表，否则会被其它测试装进来的内置
// 模块污染（例如 sourceList 把 beabox 也标成模块源）。
func isolateBundledModules(t *testing.T) {
	t.Helper()
	previous := bundledModules
	bundledModules = fstest.MapFS{}
	t.Cleanup(func() { bundledModules = previous })
}

//go:build sources

package core

import "testing"

// 带 sources 标签构建时黄果 AI 由站源模块提供，core 侧的夹具不参与编译；
// 这里留一个空实现，让同样的用例在静态检查（go vet -tags sources）下也能编译。
func installAIFixture(t *testing.T) { t.Helper() }

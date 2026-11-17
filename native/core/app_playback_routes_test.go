package core

import (
	"context"
	"strings"
	"testing"
)

// selectRoute 只能切到当前这集真实存在的线路：会话不存在、下标越界都要报错，
// 不能把越界下标塞进 nativeOpenPlayback 里再崩在 media[choice.index]。
func TestNativeSelectPlaybackRejectsUnknownRoute(t *testing.T) {
	engine := &nativeEngine{playbacks: map[string]nativePlaybackChoice{
		"live": {media: []ProviderMedia{
			{URL: "https://media.test/a.m3u8"},
			{URL: "https://media.test/b.m3u8"},
		}},
	}}
	if _, err := engine.nativeSelectPlayback(context.Background(), "gone", 0); err == nil {
		t.Fatal("未知会话应当报错")
	}
	for _, route := range []int{-1, 2, 9} {
		_, err := engine.nativeSelectPlayback(context.Background(), "live", route)
		if err == nil || !strings.Contains(err.Error(), "线路不存在") {
			t.Fatalf("线路 %d 越界应当报「线路不存在」，实际 %v", route, err)
		}
	}
}

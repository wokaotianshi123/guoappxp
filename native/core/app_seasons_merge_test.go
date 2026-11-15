package core

import "testing"

// 桌面端外置源常返回空或只给当前一季，内置补搜要能把「无季号第一季」
// 一起补进来，并保证按季号升序、同季不重复。
func TestMergeNativeSeasonsDesktopFallback(t *testing.T) {
	anchor := nativeDrama{ID: providerDramaID(sourceHongguo, "100")}
	builtin := []hongguoSeason{
		{
			Number: 2,
			Drama: Drama{
				ID:       providerDramaID(sourceHongguo, "200"),
				Source:   sourceHongguo,
				SourceID: "200",
				Title:    "长夜将明 第二季",
			},
		},
		{
			Number: 1,
			Drama: Drama{
				ID:       anchor.ID,
				Source:   sourceHongguo,
				SourceID: "100",
				Title:    "长夜将明",
			},
		},
	}
	out := mergeNativeSeasons(nil, builtin, anchor)
	if len(out) != 2 {
		t.Fatalf("外置源返回空时应补齐两季，实际 %d", len(out))
	}
	if out[0].Number != 1 || out[1].Number != 2 {
		t.Fatalf("季号未按升序排列：%d, %d", out[0].Number, out[1].Number)
	}
	found := false
	for _, item := range out {
		if item.Drama.ID == anchor.ID {
			found = true
		}
	}
	if !found {
		t.Fatal("系列里缺少当前剧（第一季）")
	}
}

// 外置源已经给出一季时，内置结果不能重复追加同一季号 / 同一剧，
// 且已有条目的信息优先保留。
func TestMergeNativeSeasonsDeduplicates(t *testing.T) {
	anchor := nativeDrama{ID: providerDramaID(sourceHongguo, "100")}
	existing := []nativeSeason{
		{Number: 2, Drama: nativeDrama{ID: providerDramaID(sourceHongguo, "200")}},
	}
	out := mergeNativeSeasons(existing, []hongguoSeason{
		{Number: 2, Drama: Drama{ID: providerDramaID(sourceHongguo, "200"), Source: sourceHongguo, SourceID: "200", Title: "重复季"}},
		{Number: 1, Drama: Drama{ID: anchor.ID, Source: sourceHongguo, SourceID: "100", Title: "长夜将明"}},
		{Number: 3, Drama: Drama{ID: providerDramaID(sourceHongguo, "300"), Source: sourceHongguo, SourceID: "300", Title: "长夜将明 第三季"}},
	}, anchor)
	if len(out) != 3 {
		t.Fatalf("去重后应为三季，实际 %d", len(out))
	}
	if out[0].Number != 1 || out[1].Number != 2 || out[2].Number != 3 {
		t.Fatalf("季号顺序异常：%d %d %d", out[0].Number, out[1].Number, out[2].Number)
	}
	if out[1].Drama.ID != existing[0].Drama.ID {
		t.Fatal("第 2 季被内置结果覆盖，应保留外置源条目")
	}
}

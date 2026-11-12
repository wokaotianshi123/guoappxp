package core

import "testing"

func hongguoSeasonTestDrama(id, title string) Drama {
	return Drama{ID: providerDramaID(sourceHongguo, id), Source: sourceHongguo, SourceID: id, Title: title}
}

func TestHongguoSeasonGroupKeepsOnlySameSeries(t *testing.T) {
	anchor := hongguoSeasonTestDrama("1", "长夜将明第二季")
	candidates := []Drama{
		hongguoSeasonTestDrama("2", "长夜将明第一季"),
		hongguoSeasonTestDrama("3", "长夜将明第三季"),
		// 同名前缀但是另一部剧，不能并进同一组。
		hongguoSeasonTestDrama("4", "长夜将明之归途第二季"),
		hongguoSeasonTestDrama("5", "长夜将明外传第一季"),
		hongguoSeasonTestDrama("6", "完全无关的剧第二季"),
	}
	member, _, unit := hongguoSeasonGroup(anchor, candidates)
	if unit != "季" {
		t.Fatalf("unit = %q, want 季", unit)
	}
	if len(member) != 3 {
		t.Fatalf("季数 = %d, want 3（%v）", len(member), member)
	}
	for season, want := range map[int]string{1: "2", 2: "1", 3: "3"} {
		if member[season].SourceID != want {
			t.Fatalf("第 %d 季 = %q, want %q", season, member[season].SourceID, want)
		}
	}
}

func TestHongguoSeasonGroupInfersUnitFromCandidates(t *testing.T) {
	// 当前剧标题没写季号，但同名剧里有「第二部 / 第三部」，算同一系列。
	anchor := hongguoSeasonTestDrama("10", "旧城故事")
	candidates := []Drama{
		hongguoSeasonTestDrama("11", "旧城故事第二部"),
		hongguoSeasonTestDrama("12", "旧城故事第三部"),
		hongguoSeasonTestDrama("13", "别的故事第二部"),
	}
	member, key, unit := hongguoSeasonGroup(anchor, candidates)
	if unit != "部" {
		t.Fatalf("unit = %q, want 部", unit)
	}
	if key != hongguoSearchText("旧城故事") {
		t.Fatalf("key = %q", key)
	}
	if len(member) != 3 || member[1].SourceID != "10" {
		t.Fatalf("分组结果 = %v", member)
	}
}

func TestHongguoSeasonGroupRejectsSingleSeason(t *testing.T) {
	// 只有自己一季：界面不该出现「系列多季」卡片条。
	anchor := hongguoSeasonTestDrama("20", "单季短剧")
	candidates := []Drama{
		hongguoSeasonTestDrama("21", "单季短剧第二季"),
	}
	member, _, _ := hongguoSeasonGroup(anchor, candidates)
	if len(member) != 2 {
		t.Fatalf("季数 = %d, want 2", len(member))
	}
	member, _, _ = hongguoSeasonGroup(anchor, nil)
	if len(member) != 0 {
		// 没有同名分季剧时无法判断是「季」还是「部」，返回空表示不是系列剧。
		t.Fatalf("无候选时季数 = %d, want 0（不显示卡片条）", len(member))
	}
}

func TestHongguoSeasonGroupIgnoresDifferentUnit(t *testing.T) {
	anchor := hongguoSeasonTestDrama("30", "山河故人第二季")
	candidates := []Drama{
		hongguoSeasonTestDrama("31", "山河故人第三季"),
		hongguoSeasonTestDrama("32", "山河故人第二部"),
	}
	member, _, unit := hongguoSeasonGroup(anchor, candidates)
	if unit != "季" {
		t.Fatalf("unit = %q, want 季", unit)
	}
	if len(member) != 2 {
		t.Fatalf("季数 = %d, want 2（部 不应该并入 季）", len(member))
	}
	if member[2].SourceID != "30" || member[3].SourceID != "31" {
		t.Fatalf("第 2/3 季 = %v / %v", member[2], member[3])
	}
}

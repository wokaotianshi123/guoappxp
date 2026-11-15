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

// 回归：第一季在红果里通常不写季号，标题就是基础名。打开第二季及以后时，
// 分组曾把 season==0 的候选一律丢掉，导致「系列多季」卡片条缺第一季。
func TestHongguoSeasonGroupIncludesBareFirstSeasonFromLaterAnchor(t *testing.T) {
	anchor := hongguoSeasonTestDrama("1", "长夜将明第二季")
	candidates := []Drama{
		hongguoSeasonTestDrama("2", "长夜将明"), // 第一季：没有季号后缀
		hongguoSeasonTestDrama("3", "长夜将明第三季"),
		hongguoSeasonTestDrama("4", "长夜将明之归途第二季"), // 另一部剧
		hongguoSeasonTestDrama("5", "长夜将明外传"),         // 同名前缀但不等于基础名
	}
	member, key, unit := hongguoSeasonGroup(anchor, candidates)
	if unit != "季" {
		t.Fatalf("unit = %q, want 季", unit)
	}
	if key != hongguoSearchText("长夜将明") {
		t.Fatalf("key = %q", key)
	}
	if len(member) != 3 {
		t.Fatalf("季数 = %d, want 3（第一季不能缺）: %v", len(member), member)
	}
	for season, want := range map[int]string{1: "2", 2: "1", 3: "3"} {
		if member[season].SourceID != want {
			t.Fatalf("第 %d 季 = %q, want %q", season, member[season].SourceID, want)
		}
	}
}

func TestHongguoSeasonGroupIncludesBareFirstSeasonWithBuUnit(t *testing.T) {
	anchor := hongguoSeasonTestDrama("40", "山河录第二部")
	candidates := []Drama{
		hongguoSeasonTestDrama("41", "山河录"),
		hongguoSeasonTestDrama("42", "山河录第三部"),
		hongguoSeasonTestDrama("43", "山河录第二季"), // 单位不同，不能混入
	}
	member, _, unit := hongguoSeasonGroup(anchor, candidates)
	if unit != "部" {
		t.Fatalf("unit = %q, want 部", unit)
	}
	if len(member) != 3 || member[1].SourceID != "41" {
		t.Fatalf("分组结果 = %v", member)
	}
}

func TestHongguoSeasonGroupAnchorIsBareFirstSeason(t *testing.T) {
	// 打开的就是第一季时行为不变：自己占第 1 季，后续季照常识别。
	anchor := hongguoSeasonTestDrama("50", "旧城故事")
	candidates := []Drama{
		hongguoSeasonTestDrama("51", "旧城故事第二季"),
		hongguoSeasonTestDrama("52", "旧城故事第三季"),
	}
	member, _, unit := hongguoSeasonGroup(anchor, candidates)
	if unit != "季" {
		t.Fatalf("unit = %q, want 季", unit)
	}
	if len(member) != 3 || member[1].SourceID != "50" {
		t.Fatalf("分组结果 = %v", member)
	}
}

func TestHongguoSeasonMemberOnlyTreatsExactBareTitleAsFirstSeason(t *testing.T) {
	key := hongguoSearchText("旧城故事")
	cases := []struct {
		title  string
		season int
		ok     bool
	}{
		{"旧城故事", 1, true},
		{"旧城故事 第二季", 2, true},
		{"旧城故事第三季", 3, true},
		{"旧城故事第二部", 0, false}, // 单位不同
		{"旧城故事之续篇", 0, false},
		{"旧城故事番外", 0, false},
		{"别的剧", 0, false},
		{"", 0, false},
	}
	for _, item := range cases {
		season, _, ok := hongguoSeasonMember(item.title, key, "季")
		if ok != item.ok || (ok && season != item.season) {
			t.Errorf("hongguoSeasonMember(%q) = (%d, %v), want (%d, %v)",
				item.title, season, ok, item.season, item.ok)
		}
	}
	// 系列单位没推断出来时，宁可不认，避免把无关剧并进来。
	if _, _, ok := hongguoSeasonMember("旧城故事", key, ""); ok {
		t.Error("unit 为空时不应把候选算进系列")
	}
}

package core

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"golang.org/x/net/html"
)

func duanjuFixtureDownloader(t *testing.T, handler http.HandlerFunc) (*Downloader, *httptest.Server) {
	t.Helper()
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	d := &Downloader{
		cfg:           Config{dataDir: t.TempDir(), Retries: 1, PageSize: 30, MaxPagesPerSort: 1},
		client:        server.Client(),
		limiter:       newRequestLimiter(3, 0),
		providerHosts: map[string]string{},
	}
	return d, server
}

func TestDuanjuRegistryKeepsDistinctIdentitiesFromExistingSources(t *testing.T) {
	existing := []string{sourceHongguo, sourceHuangdou, sourceHuangju, sourceYeguo, sourceDSD, sourceHuangguoAI, sourceHuangguoVideo, sourceCloudFront}
	seen := map[string]bool{}
	for _, source := range existing {
		seen[source] = true
	}
	if len(duanjuProviderCatalog) != 11 {
		t.Fatalf("duanju catalog should register 11 sources, got %d", len(duanjuProviderCatalog))
	}
	for _, spec := range duanjuProviderCatalog {
		if seen[spec.ID] {
			t.Fatalf("duanju source %q collides with an existing source id", spec.ID)
		}
		seen[spec.ID] = true
		if canonicalProviderSource(spec.ID) != spec.ID {
			t.Fatalf("duanju source %q is not canonical", spec.ID)
		}
		if !isHuangguoProviderSource(spec.ID) || !isDuanjuProviderSource(spec.ID) {
			t.Fatalf("duanju source %q was not recognized as a provider source", spec.ID)
		}
		if duanjuSourceForHost(duanjuHostOf(spec.Base)) != spec.ID {
			t.Fatalf("duanju source %q does not recognize its own host %q", spec.ID, spec.Base)
		}
	}
	if canonicalProviderSource("星芽") != sourceYaguo || canonicalProviderSource("七猫") != sourceMaoguo {
		t.Fatal("duanju chinese aliases are not canonicalized")
	}
}

func TestDuanjuMaccmsParsesCardsAndPlaylist(t *testing.T) {
	d, server := duanjuFixtureDownloader(t, func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Type", "text/html; charset=utf-8")
		if strings.Contains(request.URL.Path, "detail") || strings.Contains(request.URL.Path, "show") {
			_, _ = writer.Write([]byte(`<html><head><title>五五样本 - 在线观看</title><meta name="description" content="简介内容"></head><body>
			<div class="dramaDetail_tagsBox">甜宠 古装</div>
			<ul class="content__playlist playlink clearfix">
			<li><a href="/play/100-1-1.html">第1集</a></li>
			<li><a href="/play/100-1-2.html">第2集</a></li>
			<li><a href="/play/100-1-3.html">APP播放</a></li>
			</ul></body></html>`))
			return
		}
		_, _ = writer.Write([]byte(`<html><body><div class="BrowseList_listBox">
		<div class="BrowseList_listItem"><a href="/detail/100.html" title="五五样本"><img data-original="/pic/100.jpg"></a>
		<span class="meta-post-type2">更新至12集</span></div>
		</div></body></html>`))
	})
	d.providerHosts[sourceWuguo] = server.URL

	items, more, err := d.fetchMaccmsCatalogPage(context.Background(), sourceWuguo, 1, "/type/duanju.html")
	if err != nil || len(items) != 1 || !more {
		t.Fatalf("maccms catalog failed: %+v %v", items, err)
	}
	if items[0].ID != "wuguo:100" || items[0].Source != sourceWuguo {
		t.Fatalf("maccms card identity is wrong: %+v", items[0])
	}
	if items[0].Cover != server.URL+"/pic/100.jpg" {
		t.Fatalf("maccms cover resolution is wrong: %q", items[0].Cover)
	}
	if items[0].EpisodeCount != json.Number("12") {
		t.Fatalf("maccms episode count is wrong: %+v", items[0].EpisodeCount)
	}

	drama, chapters, err := d.fetchMaccmsDetail(context.Background(), sourceWuguo, "100")
	if err != nil || len(chapters) != 2 {
		t.Fatalf("maccms detail failed: %+v %v", chapters, err)
	}
	if chapters[0].VideoURL != server.URL+"/play/100-1-1.html" {
		t.Fatalf("maccms chapter link is wrong: %q", chapters[0].VideoURL)
	}
	if drama.DisplayTitle() != "五五样本" {
		t.Fatalf("maccms title is wrong: %q", drama.DisplayTitle())
	}
}

func TestDuanjuMaccmsPlayerParsingHandlesCommonShells(t *testing.T) {
	playerShell := `<html><script>var player_aaaa={"flag":"1","url":"https:\/\/cdn.example.cn\/hls\/index.m3u8"}</script></html>`
	if got := maccmsNormalizePlaybackURL(maccmsPlayerURL(playerShell)); got != "https://cdn.example.cn/hls/index.m3u8" {
		t.Fatalf("maccms player url parsing is wrong: %q", got)
	}
	encodedShell := `<html><script>var player_aaaa={"url":"https://cdn.example.cn/p.\/u6d4b\u8bd5\/index.m3u8"}</script></html>`
	got := maccmsNormalizePlaybackURL(maccmsPlayerURL(encodedShell))
	if !strings.Contains(got, "index.m3u8") || strings.Contains(got, `\u`) {
		t.Fatalf("maccms encoded folder handling is wrong: %q", got)
	}
	if got := maccmsPlayerURL(`<html>no player here</html>`); got != "" {
		t.Fatalf("maccms should not invent a url: %q", got)
	}
}

func TestDuanjuMaccmsAcceptsHashedClassNamesAndWidenedEpisodes(t *testing.T) {
	document, err := html.Parse(strings.NewReader(`<html><body>
	<ul id="home1" class="_9dbe81752a1dbf17-vodlist clearfix">
	<li class="_9dbe81752a1dbf17-vodlist__item">
	<a class="_9dbe81752a1dbf17-vodlist__thumb lazyload" href="/zywview/20523.html" title="不做替身后被长公主截胡赐婚" data-original="https://pic.example.cn/a.jpg"><span class="pic-text">全集</span></a>
	<h4 class="_9dbe81752a1dbf17-vodlist__title"><a href="/zywview/20523.html" title="不做替身后被长公主截胡赐婚">不做替身后被长..</a></h4>
	</li></ul></body></html>`))
	if err != nil {
		t.Fatal(err)
	}
	cards := maccmsCards(document, sourceHuaguo, "https://www.example.cn")
	if len(cards) != 1 || cards[0].SourceID != "20523" {
		t.Fatalf("hashed class cards are wrong: %+v", cards)
	}
	if cards[0].Cover != "https://pic.example.cn/a.jpg" {
		t.Fatalf("hashed class cover is wrong: %q", cards[0].Cover)
	}
	if cards[0].DisplayTitle() != "不做替身后被长公主截胡赐婚" {
		t.Fatalf("hashed class title is wrong: %q", cards[0].DisplayTitle())
	}

	detail, err := html.Parse(strings.NewReader(`<html><body>
	<div class="pcDrama_catalogList">
	<a class="pcDrama_catalogItem" href="/index.php/vod/play/id/45856/sid/1/nid/1.html">第1集</a>
	<a class="pcDrama_catalogItem" href="/index.php/vod/play/id/45856/sid/1/nid/2.html">第2集</a>
	</div></body></html>`))
	if err != nil {
		t.Fatal(err)
	}
	episodes := maccmsEpisodesFromDocument(detail)
	if len(episodes) != 2 {
		t.Fatalf("catalog item episodes are wrong: %+v", episodes)
	}
}

func TestDuanjuMaccmsDetailCandidatesMatchLiveSites(t *testing.T) {
	cases := map[string]string{
		sourceWuguo:   "https://www.example.cn/index.php/vod/detail/id/45856.html",
		sourceWangguo: "https://www.example.cn/vod/48478.html",
		sourceHuaguo:  "https://www.example.cn/zywview/20523.html",
	}
	for source, want := range cases {
		got := maccmsDetailCandidates(source, "https://www.example.cn", firstNumericTail(want))
		if len(got) == 0 || got[0] != want {
			t.Fatalf("%s detail candidate is wrong: %v", source, got)
		}
	}
}

func firstNumericTail(address string) string {
	cleaned := strings.TrimSuffix(address, ".html")
	parts := strings.Split(cleaned, "/")
	for index := len(parts) - 1; index >= 0; index-- {
		if webProviderNumericID.MatchString(parts[index]) {
			return parts[index]
		}
	}
	return ""
}

func TestDuanjuMaccmsFallsBackToDetailAnchors(t *testing.T) {
	document, err := html.Parse(strings.NewReader(`<html><body>
	<div class="random-hash-outer"><ul><li class="x1 y2 z3"><div class="q9 w8 e7 thumb">
	<a class="a1 b2 v-thumb stui-vodlist__thumb lazyload" href="/xzyxvd/269321.html" title="都市古仙医" data-original="https://image.example.cn/a.jpg">
	<span class="c3 pic-text text-right">第216集</span></a></div></li></ul></div></body></html>`))
	if err != nil {
		t.Fatal(err)
	}
	cards := maccmsCards(document, sourceFaguo, "https://www.example.cn")
	if len(cards) != 1 || cards[0].SourceID != "269321" {
		t.Fatalf("anchor fallback cards are wrong: %+v", cards)
	}
	if cards[0].DisplayTitle() != "都市古仙医" || cards[0].Remark != "第216集" {
		t.Fatalf("anchor fallback metadata is wrong: %+v", cards[0])
	}
	if cards[0].Cover != "https://image.example.cn/a.jpg" {
		t.Fatalf("anchor fallback cover is wrong: %q", cards[0].Cover)
	}
}

func TestDuanjuRejectsMismatchedSourceIDsAndCategories(t *testing.T) {
	if split, id, ok := splitProviderDramaID("yaguo:51"); !ok || split != sourceYaguo || id != "51" {
		t.Fatalf("duanju drama id split failed: %q %q %v", split, id, ok)
	}
	if _, _, ok := splitProviderDramaID("yaguo:"); ok {
		t.Fatal("duanju accepted an empty source id")
	}
	if split, _, ok := splitProviderDramaID("unknown:1"); ok {
		t.Fatalf("duanju accepted an unknown source: %q", split)
	}
	if validDuanjuCategory(sourceGuanguo, "../etc") || validDuanjuCategory(sourceMaoguo, "a|b") {
		t.Fatal("duanju accepted an invalid category")
	}
	if !validDuanjuCategory(sourceGuanguo, "462") || !validDuanjuCategory(sourceHeguo, "417-464") {
		t.Fatal("duanju rejected a valid numeric category")
	}
	if !validDuanjuCategory(sourceFanguo, "都市") {
		t.Fatal("fanguo should accept a chinese category")
	}
}

func TestDuanjuSourceAvailabilityFollowsBuildVariant(t *testing.T) {
	previous := buildAllSources
	buildAllSources = "false"
	if nativeSourceAvailable(sourceYaguo) {
		t.Fatal("hongguo-only build must not expose duanju sources")
	}
	buildAllSources = "true"
	if !nativeSourceAvailable(sourceYaguo) || !nativeSourceAvailable(sourceWuguo) {
		t.Fatal("all-sources build must expose duanju sources")
	}
	buildAllSources = previous
}

func TestDuanjuNormalizePlaybackURLStripsTrailingPunctuation(t *testing.T) {
	cases := map[string]string{
		"https://cdn.example.cn/wjv11/202508/15/SnEXGkSedD83/video/index.m3u8,": "https://cdn.example.cn/wjv11/202508/15/SnEXGkSedD83/video/index.m3u8",
		"https://cdn.example.cn/a/index.m3u8。":                                  "https://cdn.example.cn/a/index.m3u8",
		"https://cdn.example.cn/a/index.m3u8":                                   "https://cdn.example.cn/a/index.m3u8",
		`https:\/\/cdn.example.cn\/a\/index.m3u8\,`:                             "https://cdn.example.cn/a/index.m3u8",
	}
	for input, want := range cases {
		if got := maccmsNormalizePlaybackURL(input); got != want {
			t.Fatalf("normalize %q => %q, want %q", input, got, want)
		}
	}
	if got := maccmsNormalizePlaybackURL(","); got != "" {
		t.Fatalf("punctuation-only input should normalize to empty, got %q", got)
	}
}

func TestDuanjuCleanTitleStripsLiveSeoSuffixes(t *testing.T) {
	cases := map[string]string{
		"黑月光归来-短剧黑月光归来全集-黑月光归来免费在线观看 - 免费五五短剧视频分享大全 - 最新的免费短剧视频": "黑月光归来",
		"修仙入世我在都市当靠山_高清完整版在线观看_爽文短剧 - 短剧网":                       "修仙入世我在都市当靠山",
		"三万月薪，我自己做主-短剧三万月薪，我自己做主全集-三万月薪，我自己做主免费在线观看":             "三万月薪，我自己做主",
		"不做替身后被长公主截胡赐婚 - 花生短剧":                                   "不做替身后被长公主截胡赐婚",
		"九转星辰诀":   "九转星辰诀",
		"我的剧-第二季": "我的剧-第二季",
	}
	for input, want := range cases {
		if got := maccmsCleanTitle(input); got != want {
			t.Fatalf("clean %q => %q, want %q", input, got, want)
		}
	}
}

func TestDuanjuSearchCoverageMatchesImplementedSources(t *testing.T) {
	for _, spec := range duanjuProviderCatalog {
		if !spec.Searcher {
			t.Fatalf("%s must advertise online search", spec.ID)
		}
		if !duanjuSupportsSearch(spec.ID) {
			t.Fatalf("%s should report search support", spec.ID)
		}
	}
	if !duanjuSupportsSearch(sourceHeguo) || !duanjuSupportsSearch(sourceXingguo) {
		t.Fatal("heguo and xingguo search must be advertised")
	}
}

func TestDuanjuPlainTextStripsSearchHighlightMarkup(t *testing.T) {
	cases := map[string]string{
		"<font color='#ff4242'>都</font><font color='#ff4242'>市</font>无上仙尊（<font color='#ff4242'>都</font><font color='#ff4242'>市</font>之无双仙尊）": "都市无上仙尊（都市之无双仙尊）",
		"<em>都市</em>风云":     "都市风云",
		"普通标题":              "普通标题",
		"":                  "",
		"  <b>加粗</b>  空格  ": "加粗 空格",
	}
	for input, want := range cases {
		if got := duanjuPlainText(input); got != want {
			t.Fatalf("plain %q => %q, want %q", input, got, want)
		}
	}
}

package core

import "testing"

func TestNativeCoverRefererDouban(t *testing.T) {
	downloader := &Downloader{cfg: defaultConfig(), providerHosts: map[string]string{}}
	douban := "https://img9.doubanio.com/view/photo/m_ratio_poster/public/p2936719035.jpg"
	// 爱看机器人与部分聚合源的海报直接指向豆瓣图床，豆瓣按 Referer 防盗链：
	// 不带豆瓣 Referer 会回 403，或者 302 到一张默认图。
	if got := nativeCoverReferer(downloader, sourceIkanbot, douban); got != "https://movie.douban.com/" {
		t.Fatalf("ikanbot 豆瓣海报的 Referer = %q", got)
	}
	if got := nativeCoverReferer(downloader, sourceHongguo, "https://img1.doubanio.com/view/photo/s_ratio_poster/public/p1.jpg"); got != "https://movie.douban.com/" {
		t.Fatalf("其它站源的豆瓣海报 Referer = %q", got)
	}
	// 非豆瓣域名仍然按所属站源出 Referer，不能被豆瓣规则吃掉。
	if got := nativeCoverReferer(downloader, sourceIkanbot, "https://cdn.example.test/poster.jpg"); got != downloader.providerBaseURL(sourceIkanbot)+"/" {
		t.Fatalf("非豆瓣海报的 Referer = %q", got)
	}
}

// 黄豆换线后封面必须跟着域名走，否则新域名会 403。
func TestNativeCoverRefererFollowsHuangdouPool(t *testing.T) {
	d := &Downloader{cfg: defaultConfig(), providerHosts: map[string]string{}}
	for _, pooled := range huangdouHostPool {
		cover := "https://" + pooled + "/covers/a.jpg"
		want := "https://" + pooled + "/home"
		if got := nativeCoverReferer(d, sourceHuangdou, cover); got != want {
			t.Fatalf("封面 referer 未跟随域名池: %s -> %s (want %s)", pooled, got, want)
		}
	}
	d.providerHosts[sourceHuangdou] = "https://" + huangdouHostPool[1]
	if got := nativeCoverReferer(d, sourceHuangdou, "https://example.com/covers/a.jpg"); got != "https://"+huangdouHostPool[1]+"/home" {
		t.Fatalf("非池域名封面未回落到首选站点: %s", got)
	}
}

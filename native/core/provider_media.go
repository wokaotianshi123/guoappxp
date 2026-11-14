package core

import (
	"context"
	"fmt"
	"net/url"
	"strings"
	"time"
)

type providerMedia struct {
	Credentials *providerMediaCredentials
	URL         string
	Referer     string
	Duration    time.Duration
	Playlist    string
	HLSKey      []byte
	CENCKey     []byte
	Quality     int
	Variants    []providerMedia
	// QualityOptions 是站源直接给出的可选清晰度档位（如 1080/720/540/480/360）。
	// 番茄这类「按档位分别缓存」的源走这个字段，避免为了列档位而伪造多条线路。
	QualityOptions []int
}

func (d *Downloader) providerBaseURL(source string) string {
	source = canonicalProviderSource(source)
	var configured, fallback string
	switch source {
	case sourceHuangguoAI:
		configured, fallback = d.cfg.HuangguoAIURL, huangguoAIBaseURL
	case sourceHuangguoVideo:
		configured, fallback = d.cfg.HuangguoVideoURL, huangguoVideoBaseURL
	case sourceHuangdou:
		configured, fallback = d.cfg.HuangdouURL, huangdouBaseURL
	case sourceHongguo:
		configured, fallback = d.cfg.HongguoURL, hongguoBaseURL
	case sourceHuangju:
		configured, fallback = d.cfg.HuangjuURL, huangjuBaseURL
	case sourceYeguo:
		configured, fallback = d.cfg.YeguoURL, yeguoBaseURL
	case sourceJinguoDuanju:
		configured, fallback = jinguoDuanjuContentSite(d.cfg.JinguoDuanjuURL), jinguoDuanjuSiteBaseURL
	case sourceDSD:
		configured, fallback = d.cfg.DSDURL, dsdBaseURL
	case sourceSorani:
		configured, fallback = d.cfg.SoraniURL, soraniSiteBaseURL
	case sourceGuipian:
		configured, fallback = d.cfg.GuipianURL, guipianSiteBaseURL
	case sourceHanxiaoquan:
		// 韩小圈站点地址只在 core 内置一份：外置源经 Host.BaseURL 取，
		// 漏掉这个分支会落到 default 的云存储地址，表现为「有分类、没列表」。
		fallback = hanxiaoquanSiteBaseURL
	case sourceIkanbot:
		fallback = ikanbotSiteBaseURL
	case sourceA123:
		fallback = a123SiteBaseURL
	case sourceFanqie:
		configured, fallback = d.cfg.FanqieURL, fanqieBaseURL
	case sourceXChina:
		configured, fallback = d.cfg.XChinaURL, xchinaBaseURL
	case sourceTheporny:
		configured, fallback = d.cfg.ThepornyURL, thepornyBaseURL
	case sourceBeabox:
		configured, fallback = d.cfg.BeaboxURL, beaboxBaseURL
	default:
		fallback = "https://d2pypzndaqisk.cloudfront.net"
	}
	return strings.TrimRight(firstNonEmpty(configured, fallback), "/")
}

func providerSourceForURL(raw string) string {
	parsed, err := url.Parse(raw)
	if err != nil {
		return ""
	}
	host := strings.ToLower(parsed.Hostname())
	switch {
	case host == "huangguoai.com" || isHuangguoAIMirrorHost(host):
		return sourceHuangguoAI
	case host == "huangguo.video":
		return sourceHuangguoVideo
	case isHuangdouHost(host):
		return sourceHuangdou
	case host == "hongguoduanju.com" || host == "www.hongguoduanju.com":
		return sourceHongguo
	case host == "huangju.net" || host == "www.huangju.net" || host == "api.huangju.net":
		return sourceHuangju
	case host == "ygdj7.com" || host == "www.ygdj7.com" || host == "ygdj15.com" || host == "www.ygdj15.com" ||
		host == "analyze.buxefaex.cc" || strings.HasSuffix(host, ".buxefaex.cc") ||
		strings.HasSuffix(host, ".fzchosdi.cc") || strings.HasSuffix(host, ".lwblvxvy.cc") ||
		strings.HasSuffix(host, ".vgbyziuz.cc") ||
		host == "delta.ygrwdsgt.cc" || host == "yeguodj.com" || host == "www.yeguodj.com":
		return sourceYeguo
	case host == "jinguoduanju.app" || host == "www.jinguoduanju.app" || host == "play.jinguoduanju.app" ||
		host == "jgdj.app" || host == "www.jgdj.app":
		return sourceJinguoDuanju
	case host == "dsd.com.se" || host == "www.dsd.com.se":
		return sourceDSD
	case host == "sorani.net" || host == "www.sorani.net" || host == "api.sorani.cc" || host == "sorani.cc":
		return sourceSorani
	case host == "guipianwu.com" || host == "www.guipianwu.com":
		return sourceGuipian
	case host == "jennyhow.com" || host == "www.jennyhow.com":
		return sourceHanxiaoquan
	case host == "heitaodj.com" || host == "www.heitaodj.com":
		return sourceHeitao
	case host == "ikanbot.com" || host == "www.ikanbot.com" || host == "www1.ikanbot.com":
		return sourceIkanbot
	case host == "a123tv.com" || host == "www.a123tv.com":
		return sourceA123
	case host == "xchina.tube" || host == "www.xchina.tube":
		return sourceXChina
	case host == "theporny.com" || host == "www.theporny.com":
		return sourceTheporny
	default:
		return ""
	}
}

func isHuangguoAIMirrorHost(host string) bool {
	for _, domain := range huangguoAIMirrorDomains {
		if strings.HasSuffix(host, "."+domain) {
			return true
		}
	}
	return false
}

func (d *Downloader) providerURLCandidates(raw string) []string {
	source := providerSourceForURL(raw)
	if source == "" || source == sourceHuangju || source == sourceYeguo {
		return []string{raw}
	}
	parsed, _ := url.Parse(raw)
	d.providerMu.Lock()
	preferred := d.providerHosts[source]
	d.providerMu.Unlock()
	var candidates []string
	seen := map[string]bool{}
	add := func(candidate string) {
		if candidate != "" && !seen[candidate] {
			seen[candidate] = true
			candidates = append(candidates, candidate)
		}
	}
	add(rehostProviderURL(parsed, preferred))
	configured := d.providerBaseURL(source)
	add(rehostProviderURL(parsed, configured))
	if providerSourceForURL(configured) == "" {
		return candidates
	}
	for _, candidate := range providerURLCandidates(raw) {
		add(candidate)
	}
	return candidates
}

func (d *Downloader) resolveProviderMedia(ctx context.Context, task Task) (providerMedia, error) {
	chapter := task.Chapter
	chapter.Source = canonicalProviderSource(chapter.Source)
	if chapter.Source == "" {
		chapter.Source = sourceFromDramaID(task.DramaID)
	}
	// 编译期接入的站源自己解析取流（抓当集播放页、算令牌、取线路表等），
	// 不能落到下面按 chapter.VideoURL 直连的通用兜底。
	if provider, ok := d.sourceProvider(chapter.Source); ok {
		return provider.ResolveMedia(ctx, task)
	}
	// 爱看机器人 / 短剧家族各有专用取流逻辑（抓当集播放页、算令牌、取 pp.la 等），
	// 不能落到下面通用兜底：兜底按 chapter.VideoURL 直连解析，
	// 这类地址会解不出有效播放地址，表现为「网页源视频均加载失败」。
	if isDuanjuProviderSource(chapter.Source) {
		return d.resolveDuanjuMedia(ctx, task)
	}
	if strings.HasPrefix(chapter.VideoURL, "hongguo-cenc://") {
		return d.resolveHongguoMedia(ctx, task)
	}
	media := providerMedia{URL: chapter.VideoURL, Referer: firstNonEmpty(chapter.Referer, d.providerBaseURL(chapter.Source)+"/")}
	if !isProviderHTTPMediaURL(media.URL) {
		return providerMedia{}, fmt.Errorf("%s 未返回有效播放地址，请刷新章节或确认站点访问权限", chapter.Source)
	}
	parsed, _ := url.Parse(media.URL)
	if strings.HasSuffix(strings.ToLower(parsed.Path), ".m3u8") {
		playlist, finalURL, err := d.fetchMediaPlaylist(ctx, media.URL, media.Referer)
		if err != nil {
			return providerMedia{}, fmt.Errorf("获取播放列表失败: %w", err)
		}
		if !strings.HasPrefix(strings.TrimSpace(strings.TrimPrefix(playlist, "\ufeff")), "#EXTM3U") {
			return providerMedia{}, fmt.Errorf("站点未返回有效 M3U8，可能需要登录或链接已失效")
		}
		if duration := m3u8Duration(playlist); duration > 0 {
			media.Duration = duration
		}
		media.Playlist = playlist
		media.URL = finalURL
	}
	return media, nil
}

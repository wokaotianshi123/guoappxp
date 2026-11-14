package core

import (
	"crypto/rand"
	"encoding/hex"
	"net/url"
	"regexp"
	"strconv"
	"strings"
)

// 网页源的默认站点地址。站源实现已经搬出 core，这里只保留运行时需要的兜底值：
// providerBaseURL 在设置里没配地址时用它，站源自己则通过 SourceHost.BaseURL 取。
// HTMLEntityUnescape 反复解 HTML 实体与数字字符引用（网页源详情/标题常带双层转义）。
func HTMLEntityUnescape(text string) string {
	replacer := strings.NewReplacer(
		"&amp;", "&", "&lt;", "<", "&gt;", ">", "&quot;", "\"",
		"&apos;", "'", "&#39;", "'", "&nbsp;", " ",
	)
	hexPattern := regexp.MustCompile(`&#x([0-9a-fA-F]+);`)
	decPattern := regexp.MustCompile(`&#(\d+);`)
	for i := 0; i < 3; i++ {
		next := replacer.Replace(text)
		next = hexPattern.ReplaceAllStringFunc(next, func(m string) string {
			if code, err := strconv.ParseInt(m[3:len(m)-1], 16, 32); err == nil {
				return string(rune(code))
			}
			return m
		})
		next = decPattern.ReplaceAllStringFunc(next, func(m string) string {
			if code, err := strconv.Atoi(m[2 : len(m)-1]); err == nil {
				return string(rune(code))
			}
			return m
		})
		if next == text {
			break
		}
		text = next
	}
	return text
}

const (
	a123SiteBaseURL    = "https://a123tv.com"
	guipianSiteBaseURL = "https://guipianwu.com"
	ikanbotSiteBaseURL = "https://www1.ikanbot.com"
	// 韩小圈：站点会换域名，外置源与封面拼接都经 Host.BaseURL 取这里。
	hanxiaoquanSiteBaseURL = "https://www.jennyhow.com"
	xchinaBaseURL      = "https://v2.cdn199.com"
	thepornyBaseURL    = "https://theporny.com"
	huangjuBaseURL     = "https://huangju.net"
	huangjuAPIBaseURL  = "https://api.huangju.net"
	yeguoBaseURL       = "https://attract.vgbyziuz.cc"
	soraniSiteBaseURL  = "https://www.sorani.net"
	dsdBaseURL         = "https://www.dsd.com.se"
	beaboxBaseURL      = "https://bh4066.top"
	huangdouBaseURL    = "https://ferncider.cc"
	// fanqieBaseURL 是番茄内容引擎（本机 loopback）的默认地址，站源侧有同名副本。
	fanqieBaseURL = "http://127.0.0.1:18921"

	// 禁果短剧只认自己的内容域名，设置里填了别的地址不会当成内容站用。
	jinguoDuanjuSiteBaseURL = "https://jinguoduanju.app"
)

var jinguoDuanjuContentHosts = []string{
	"jinguoduanju.app",
	"www.jinguoduanju.app",
	"play.jinguoduanju.app",
	"jgdj.app",
	"www.jgdj.app",
}

// jinguoDuanjuContentSite 从设置里的地址里挑出可用的禁果短剧内容站。
func jinguoDuanjuContentSite(raw string) string {
	address, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || address.Scheme != "https" || address.User != nil || address.RawQuery != "" || address.Fragment != "" || address.Hostname() == "" {
		return ""
	}
	if path := strings.Trim(address.EscapedPath(), "/"); path != "" {
		return ""
	}
	host := strings.ToLower(address.Hostname())
	for _, known := range jinguoDuanjuContentHosts {
		if host == known {
			return "https://" + host
		}
	}
	return ""
}

// 黄豆的域名池：站源实现已搬走，运行时只用它反查「这个地址属于黄豆」。
var huangdouHostPool = [...]string{
	"ferncider.cc",
	"onyxripple.cc",
	"reeflumen.cc",
	"niniharbor.top",
	"halomeadow.top",
	"larksummit.icu",
}

// huangdouHostname 从任意写法里取出主机名。
func huangdouHostname(candidate string) string {
	candidate = strings.ToLower(strings.TrimSpace(candidate))
	if index := strings.Index(candidate, "://"); index >= 0 {
		candidate = candidate[index+3:]
	}
	candidate = strings.TrimPrefix(candidate, "//")
	if index := strings.IndexAny(candidate, "/?#"); index >= 0 {
		candidate = candidate[:index]
	}
	if index := strings.LastIndex(candidate, "@"); index >= 0 {
		candidate = candidate[index+1:]
	}
	if index := strings.LastIndex(candidate, ":"); index >= 0 {
		candidate = candidate[:index]
	}
	return strings.TrimSuffix(candidate, ".")
}

// isHuangdouHost 判断主机名是否属于黄豆域名池。
func isHuangdouHost(candidate string) bool {
	host := huangdouHostname(candidate)
	if host == "" {
		return false
	}
	for _, pooled := range huangdouHostPool {
		if pooled == host {
			return true
		}
	}
	return false
}

// randomHex 返回 n 字节随机数的十六进制文本，取不到随机源时返回空串。
func randomHex(n int) string {
	buffer := make([]byte, n)
	if _, err := rand.Read(buffer); err != nil {
		return ""
	}
	return hex.EncodeToString(buffer)
}

// uuidLike 生成 8-4-4-4-12 形式的随机标识（黄豆/红果设备号用）。
func uuidLike() string {
	raw := randomHex(16)
	if len(raw) != 32 {
		return raw
	}
	return raw[:8] + "-" + raw[8:12] + "-" + raw[12:16] + "-" + raw[16:20] + "-" + raw[20:]
}

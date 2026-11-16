package core

import (
	"net/url"
	"testing"
)

// 模块清单里的 browserFingerprint 必须真正让该模块的域名走浏览器指纹传输。
// 这条回归测试盯的是「声明了却从未生效」：指纹 host 表曾经只认编译期写死的
// duanjuProviderCatalog，注册表里的模块描述符根本没被读过。
func TestBrowserFingerprintFollowsRegisteredSources(t *testing.T) {
	transport := &huangguoBrowserTransport{
		static:   map[string]string{},
		baseURL:  func(string) string { return "" },
		clients:  map[string]browserHTTPClient{},
		custom:   map[string]bool{},
		upgraded: map[string]bool{},
	}
	const id = "fingerprintprobe"
	Register(SourceDescriptor{
		ID: id, Name: "指纹测试",
		BaseURL:            "https://fp.example.invalid",
		Aliases:            []string{"www.fp.example.invalid"},
		BrowserFingerprint: true,
	}, func(Host) Provider { return nil })
	t.Cleanup(func() { Unregister(id) })

	for _, host := range []string{"fp.example.invalid", "www.fp.example.invalid", "fp.example.invalid:443"} {
		if source := transport.source(&url.URL{Scheme: "https", Host: host}); source != id {
			t.Fatalf("%s 未走浏览器指纹，得到 %q", host, source)
		}
	}
	if source := transport.source(&url.URL{Scheme: "https", Host: "other.example.invalid"}); source != "" {
		t.Fatalf("未声明指纹的域名走了浏览器指纹：%q", source)
	}

	// 卸载后必须立刻失效：指纹表按注册表代数重建。
	Unregister(id)
	if source := transport.source(&url.URL{Scheme: "https", Host: "fp.example.invalid"}); source != "" {
		t.Fatalf("卸载后的站源仍走浏览器指纹：%q", source)
	}
}

// 没有声明 browserFingerprint 的站源不能被指纹表收进去，否则会把本来正常的
// 站点推到 utls 指纹上，反而被 Cloudflare 拦成 403。
func TestBrowserFingerprintIgnoresPlainSources(t *testing.T) {
	transport := &huangguoBrowserTransport{
		static:   map[string]string{},
		baseURL:  func(string) string { return "" },
		clients:  map[string]browserHTTPClient{},
		custom:   map[string]bool{},
		upgraded: map[string]bool{},
	}
	const id = "plainprobe"
	Register(SourceDescriptor{ID: id, Name: "普通源", BaseURL: "https://plain.example.invalid"},
		func(Host) Provider { return nil })
	t.Cleanup(func() { Unregister(id) })

	if source := transport.source(&url.URL{Scheme: "https", Host: "plain.example.invalid"}); source != "" {
		t.Fatalf("未声明指纹的站源走了浏览器指纹：%q", source)
	}
}

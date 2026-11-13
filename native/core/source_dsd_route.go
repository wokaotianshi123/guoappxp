package core

import (
	"net/url"
	"strings"
)

// DSD（帝果）的站源实现已搬到 guoapp-sources，这里只保留运行时还要用的
// 地址解析：SourceHost 的导出包装与站源共用同一套路由规则。
func dsdRouteParameters(pageURL, reference string) (string, map[string]string, bool) {
	page, err := url.Parse(pageURL)
	if err != nil || reference == "" {
		return "", nil, false
	}
	address, err := url.Parse(reference)
	if err != nil {
		return "", nil, false
	}
	address = page.ResolveReference(address)
	if address.User != nil || providerMediaOrigin(address) != providerMediaOrigin(page) {
		return "", nil, false
	}
	path := strings.TrimPrefix(address.Path, "/index.php")
	parts := strings.Split(strings.Trim(strings.TrimSuffix(path, ".html"), "/"), "/")
	if len(parts) < 2 || parts[0] != "vod" || len(parts)%2 != 0 {
		return "", nil, false
	}
	switch parts[1] {
	case "type", "show", "search", "play", "detail":
	default:
		return "", nil, false
	}
	parameters := map[string]string{}
	for index := 2; index+1 < len(parts); index += 2 {
		parameters[parts[index]] = parts[index+1]
	}
	for key, values := range address.Query() {
		if len(values) == 1 && parameters[key] == "" {
			parameters[key] = values[0]
		}
	}
	return parts[1], parameters, true
}

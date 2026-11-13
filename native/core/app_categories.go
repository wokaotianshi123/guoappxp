package core

import (
	"context"
	"errors"
	"html"
	"net/url"
	"regexp"
	"strconv"
	"strings"
)

type nativeCategory struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

func nativeCatalogKey(source, category string) string {
	source = canonicalProviderSource(source)
	if category = strings.TrimSpace(category); category != "" {
		return source + "|" + category
	}
	return source
}

func validNativeCategory(source, category string) bool {
	if category == "" {
		return true
	}
	if len(category) > 128 || strings.ContainsAny(category, "|\\\x00\r\n") {
		return false
	}
	if isCustomMaccmsSource(source) {
		// 自定义 MacCMS 源的分类 ID 允许是路径形式（/fenlei/1、/listnews/2 等），
		// 上面已排除缓存键分隔符 |、反斜杠与控制字符，这里直接放行。
		return true
	}
	if strings.Contains(category, "/") {
		return false
	}
	// 编译期接入的站源自己判定分类；这里的探针实例不带 Host，
	// 因此站源的 ValidCategory 必须是纯函数、不访问网络与运行时状态。
	if valid, handled := sourceValidCategory(source, category); handled {
		return valid
	}
	switch source {
	case sourceHongguo:
		for _, genre := range hongguoAppGenres {
			if category == genre.key {
				return true
			}
		}
		return hongguoTagPattern.MatchString(category)
	}
	if isDuanjuProviderSource(source) {
		return validDuanjuCategory(source, category)
	}
	return false
}

func (engine *nativeEngine) nativeCategories(ctx context.Context, source string, force bool) ([]nativeCategory, error) {
	source = canonicalProviderSource(source)
	all := []nativeCategory{{Name: "全部"}}
	if provider, ok := engine.downloader.sourceProvider(source); ok {
		all = append(all, provider.Categories()...)
		if len(all) == 1 {
			// 站源声明「本来就没有分类」（如黄豆）时只有「全部」，属于正常情况。
			categoryLess := false
			if bare, ok := provider.(SourceCategoryLess); ok && bare.CategoryLess() {
				categoryLess = true
			}
			if !categoryLess {
				// 实时抓分类失败（站点临时不可达、接口改版、数据超阈值等）会返回
				// 空列表。以前这里直接抛错，导致「分类为空」连带把目录也一起显示
				// 为空——用户看到的是整个站源打不开。这里改为先回退上次成功缓存，
				// 没缓存就只给「全部」：目录请求不依赖分类参数，照样能加载内容。
				engine.mu.Lock()
				cached := append([]nativeCategory{}, engine.categoryOptions[source]...)
				engine.mu.Unlock()
				if len(cached) > 1 {
					return cached, nil
				}
				// 只保留「全部」，不写缓存：下次站点恢复时能重新拿到完整分类。
				return all, nil
			}
		}
		engine.rememberCategories(source, all)
		return all, nil
	} else {
		switch source {
		case sourceHongguo:
			for _, genre := range hongguoAppGenres {
				all = append(all, nativeCategory{ID: genre.key, Name: genre.name})
			}
			return engine.hongguoCategories(ctx, all, force), nil
		}
	}
	if isCustomMaccmsSource(source) {
		// 自定义 maccms 站点：从首页导航实时提取分类；识别不到则仅展示「全部」。
		categories, err := engine.downloader.fetchMaccmsCustomCategories(ctx, source)
		if err != nil || len(categories) == 0 {
			return all, nil
		}
		merged := append(all, categories...)
		engine.rememberCategories(source, merged)
		return merged, nil
	}
	engine.mu.Lock()
	cached := append([]nativeCategory{}, engine.categoryOptions[source]...)
	engine.mu.Unlock()
	if len(cached) > 1 && !force {
		return cached, nil
	}
	d := engine.downloader
	var err error
	switch source {
	case sourceGuipian:
		if provider, ok := d.sourceProvider(source); ok {
			all = append(all, provider.Categories()...)
		}
	case sourceIkanbot:
		if provider, ok := d.sourceProvider(source); ok {
			all = append(all, provider.Categories()...)
		}
	case sourceA123:
		if provider, ok := d.sourceProvider(source); ok {
			all = append(all, provider.Categories()...)
		}
	case sourceXChina:
		if provider, ok := d.sourceProvider(source); ok {
			all = append(all, provider.Categories()...)
		}
	default:
		if isDuanjuProviderSource(source) {
			var categories []nativeCategory
			categories, err = d.fetchDuanjuCategories(ctx, source)
			if err == nil {
				all = append(all, categories...)
			}
			break
		}
		if isHuangguoProviderSource(source) {
			// 已知站源但没编进当前版本：给出明确原因，而不是「请选择有效站源」。
			return nil, errSourceNotCompiled
		}
		return nil, errors.New("请选择有效站源")
	}
	if err != nil {
		return nil, err
	}
	if len(all) == 1 {
		// 与 provider 分支保持一致：分类暂时取不到时回退缓存或仅「全部」，
		// 不让「分类为空」把目录一起拖垮。
		engine.mu.Lock()
		cached := append([]nativeCategory{}, engine.categoryOptions[source]...)
		engine.mu.Unlock()
		if len(cached) > 1 {
			return cached, nil
		}
		return all, nil
	}
	engine.rememberCategories(source, all)
	return all, nil
}

func (engine *nativeEngine) hongguoCategories(ctx context.Context, genres []nativeCategory, force bool) []nativeCategory {
	engine.mu.Lock()
	cached := append([]nativeCategory{}, engine.categoryOptions[sourceHongguo]...)
	engine.mu.Unlock()
	if len(cached) > len(genres) && !force {
		return cached
	}
	tags, err := engine.downloader.fetchHongguoTagCategories(ctx)
	if err != nil {
		if len(cached) > len(genres) {
			return cached
		}
		return genres
	}
	all := append(genres, tags...)
	engine.rememberCategories(sourceHongguo, all)
	return all
}

func (engine *nativeEngine) rememberCategories(source string, all []nativeCategory) {
	engine.mu.Lock()
	defer engine.mu.Unlock()
	if engine.categoryOptions == nil {
		engine.categoryOptions = map[string][]nativeCategory{}
	}
	engine.categoryOptions[source] = all
	engine.writeCatalogDiskLocked()
}

var categoryAnchorPattern = regexp.MustCompile(`(?is)<a\b([^>]*)>(.*?)</a>`)
var categoryTextPattern = regexp.MustCompile(`(?s)<[^>]*>`)

func parseHuangguoVideoCategories(body string) []nativeCategory {
	var categories []nativeCategory
	seen := map[string]bool{}
	for _, match := range categoryAnchorPattern.FindAllStringSubmatch(body, -1) {
		href := html.UnescapeString(extractAttr("<a "+match[1]+">", "href"))
		address, err := url.Parse(href)
		if err != nil || address.Path != "" && strings.TrimRight(address.Path, "/") != "/videos" {
			continue
		}
		id := address.Query().Get("category")
		name := strings.TrimSpace(html.UnescapeString(categoryTextPattern.ReplaceAllString(match[2], "")))
		if number, convErr := strconv.Atoi(id); convErr != nil || number <= 0 || seen[id] || name == "" || len([]rune(name)) > 24 {
			continue
		}
		seen[id] = true
		categories = append(categories, nativeCategory{ID: id, Name: name})
	}
	return categories
}

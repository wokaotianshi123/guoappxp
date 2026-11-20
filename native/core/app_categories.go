package core

import (
	"context"
	"errors"
	"strings"
)

type Category struct {
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

func ValidNativeCategory(source, category string) bool {
	if category == "" {
		return true
	}
	// 这一道只挡缓存键分隔符、反斜杠与控制字符，刻意不含 "/"：自定义源的分类 ID
	// 本来就是路径形式，得留到下面单独放行。
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
	if descriptor, ok := registeredDescriptor(source); ok {
		return descriptor.ValidCategory != nil && descriptor.ValidCategory(category)
	}
	return false
}

func (engine *nativeEngine) nativeCategories(ctx context.Context, source string, force bool) ([]Category, error) {
	source = canonicalProviderSource(source)
	all := []Category{{Name: "全部"}}
	engine.mu.Lock()
	cached := append([]Category{}, engine.categoryOptions[source]...)
	engine.mu.Unlock()
	// 只缓存到「全部」也是有效结果（模块就只声明了一条「全部」），
	// 不必每次进分类页都重新问一遍模块。
	if len(cached) > 0 && !force {
		return cached, nil
	}
	d := engine.downloader
	var categories []Category
	var err error
	if isCustomMaccmsSource(source) {
		// 自定义源（MacCMS / XBPQ 规则）不进 provider 注册表，分类按规则 /
		// 首页导航实时提取。fetchDuanjuCategories 内部已含这条分支。
		categories, err = d.fetchDuanjuCategories(ctx, source)
		// 实时抓分类失败（站点抖动、规则未识别）时只保留「全部」：目录请求
		// 不依赖分类参数，不该因为分类为空就把整个站源显示成打不开。
		if err != nil || len(categories) == 0 {
			return all, nil
		}
	} else {
		p, ok := d.provider(source)
		if !ok {
			return nil, errors.New("请选择有效站源")
		}
		categories, err = p.Categories(ctx, force)
	}
	// 应用已经预置了「全部」，模块再返回空 id 的条目（很多 maccmsweb 模板模块
	// 的 categories() 就是 [{id:"", name:"全部"}]）会造成菜单里出现两个「全部」。
	all = append(all, filterDeclaredCategories(categories)...)
	if errors.Is(err, ErrCategoriesIncomplete) {
		return all, nil
	}
	if err != nil {
		return nil, err
	}
	// 模块只给了一条「全部」（商店里 maccmsweb 模板模块的 categories() 就是
	// [{id:"", name:"全部"}]），过滤后只剩预置项。这不是错误：空分类走全站
	// 列表本来就是可用状态，不该报「站源暂未返回内容分类」把站源显示成打不开。
	engine.rememberCategories(source, all)
	return all, nil
}

// filterDeclaredCategories 去掉与预置「全部」重复、以及自身重复的分类项。
//
// 商店里 maccmsweb 模板模块的 categories() 常返回 [{id:"", name:"全部"}]，
// 直接拼接会让菜单出现两个「全部」；id 为空的条目点进去就是全站列表，
// 由预置项承担即可。其余按 id 去重，保留模块给出的顺序。
func filterDeclaredCategories(categories []Category) []Category {
	seen := map[string]bool{"": true}
	filtered := make([]Category, 0, len(categories))
	for _, category := range categories {
		id := strings.TrimSpace(category.ID)
		if id == "" || seen[id] {
			continue
		}
		seen[id] = true
		name := strings.TrimSpace(category.Name)
		if name == "" {
			// 名称缺失时退回 id：宁可菜单上显示路径，也不要把这个分类整条丢掉。
			name = id
		}
		filtered = append(filtered, Category{ID: id, Name: name})
	}
	return filtered
}

func (engine *nativeEngine) rememberCategories(source string, all []Category) {
	engine.mu.Lock()
	defer engine.mu.Unlock()
	if engine.categoryOptions == nil {
		engine.categoryOptions = map[string][]Category{}
	}
	engine.categoryOptions[source] = all
	engine.writeCatalogDiskLocked()
}

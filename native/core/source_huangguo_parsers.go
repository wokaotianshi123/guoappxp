package core

// 黄果家族的 HTML 解析仍留在 core：黄果 AI（尚未外置）与「排序详情」模块
// 共用同一套卡片 / 详情解析。这里只导出站源需要的高层入口，
// 站源不必把十几个私有正则助手复制一遍。

// ProviderEpisode 是黄果网页解析出的分集中间形态。
type ProviderEpisode = providerEpisode

// HuangguoDetailMetadata 解析详情页的资料区（标题、简介、封面、标签、更新状态等）。
func HuangguoDetailMetadata(body, pageURL, source, sourceID string) Drama {
	return huangguoDetailMetadata(body, pageURL, source, sourceID)
}

// ParseHuangguoVideoCards 解析黄果视频的列表卡片。
func ParseHuangguoVideoCards(rawHTML, pageURL string) []Drama {
	return parseHuangguoVideoCards(rawHTML, pageURL)
}

// ParseHuangguoVideoEpisodes 解析黄果视频详情页的分集列表。
func ParseHuangguoVideoEpisodes(rawHTML, pageURL string) []ProviderEpisode {
	return parseHuangguoVideoEpisodes(rawHTML, pageURL)
}

// ParseHuangguoVideoCategories 解析黄果视频导航里的分类。
func ParseHuangguoVideoCategories(body string) []NativeCategory {
	return parseHuangguoVideoCategories(body)
}

// ParseHuangguoAIJSONCards 解析黄果 AI 的 JSON 卡片数组（目录与搜索共用）。
func ParseHuangguoAIJSONCards(raw []byte, pageURL, category string) []Drama {
	return parseHuangguoAIJSONCards(raw, pageURL, category)
}

// DramaFromAIMap 把黄果 AI 接口的一行数据转成 Drama。
func DramaFromAIMap(m map[string]any, pageURL, category string) (Drama, bool) {
	return dramaFromAIMap(m, pageURL, category)
}

// ParseDataHLS 从播放页的 data 属性里取出 HLS 地址。
func ParseDataHLS(rawHTML, pageURL string) string { return parseDataHLS(rawHTML, pageURL) }

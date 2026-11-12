package core

// 短剧家族站源外置后，运行时要继续提供给站源模块的常量与工具。
// 这些标识符属于「站源契约」的一部分，改动需同步 guoapp-sources。

const (
	// SourceYaguo 是芽果（剧场接口）的站源 ID。
	SourceYaguo = sourceYaguo
	// SourceMaoguo 是猫果的站源 ID。
	SourceMaoguo = sourceMaoguo
	// SourceFanguo 是饭果的站源 ID。
	SourceFanguo = sourceFanguo
	// SourceGuanguo 是观果的站源 ID。
	SourceGuanguo = sourceGuanguo
	// SourceXingguo 是星果的站源 ID。
	SourceXingguo = sourceXingguo
	// SourceNiuguo 是牛果的站源 ID。
	SourceNiuguo = sourceNiuguo
	// SourceHuaguo 是花果的站源 ID。
	SourceHuaguo = sourceHuaguo
	// SourceFaguo 是发果的站源 ID。
	SourceFaguo = sourceFaguo
	// SourceWuguo 是伍果的站源 ID。
	SourceWuguo = sourceWuguo
	// SourceWangguo 是网果的站源 ID。
	SourceWangguo = sourceWangguo
)

// 其余站源 ID：实现已外置或待外置，core 只保留身份。
const (
	// SourceHuangju 是黄剧（剧果）的站源 ID。
	SourceHuangju = sourceHuangju
	// SourceYeguo 是野果的站源 ID。
	SourceYeguo = sourceYeguo
	// SourceJinguo 是金果的站源 ID。
	SourceJinguo = sourceJinguo
	// SourceJinguoDuanju 是金果短剧的站源 ID。
	SourceJinguoDuanju = sourceJinguoDuanju
	// SourceDSD 是 DSD 的站源 ID。
	SourceDSD = sourceDSD
	// SourceSorani 是 Sorani 的站源 ID。
	SourceSorani = sourceSorani
	// SourceFanqie 是番茄的站源 ID。
	SourceFanqie = sourceFanqie
	// SourceHongguo 是红果的站源 ID。
	SourceHongguo = sourceHongguo
	// SourceHuangdou 是黄豆的站源 ID。
	SourceHuangdou = sourceHuangdou
	// SourceHuangguoAI 是黄果 AI 的站源 ID。
	SourceHuangguoAI = sourceHuangguoAI
	// SourceHuangguoVideo 是黄果视频的站源 ID。
	SourceHuangguoVideo = sourceHuangguoVideo
	// SourceCloudFront 是 legacy（CloudFront）站的站源 ID。
	SourceCloudFront = sourceCloudFront
	// SourceBeabox 是笔盒的站源 ID。
	SourceBeabox = sourceBeabox
)

var (
	// DuanjuYaguoBaseURL / DuanjuYaguoLoginURL 是芽果的接口与登录地址。
	DuanjuYaguoBaseURL  = yaguoBaseURL
	DuanjuYaguoLoginURL = yaguoLoginURL
	// DuanjuMaoguoBaseURL / DuanjuMaoguoReadURL 是猫果的店铺与播放地址。
	DuanjuMaoguoBaseURL = maoguoBaseURL
	DuanjuMaoguoReadURL = maoguoReadURL
	// DuanjuFanguoBaseURL 是饭果的接口地址。
	DuanjuFanguoBaseURL = fanguoBaseURL
	// DuanjuGuanguoBaseURL 是观果的接口地址。
	DuanjuGuanguoBaseURL = guanguoBaseURL
	// DuanjuXingguoBaseURL 是星果的接口地址。
	DuanjuXingguoBaseURL = xingguoBaseURL
	// DuanjuNiuguoBaseURL 是牛果的接口地址。
	DuanjuNiuguoBaseURL = niuguoBaseURL
	// DuanjuNiuguoParseURL / DuanjuNiuguoParseURL2 是牛果的解析服务地址。
	DuanjuNiuguoParseURL  = niuguoParseURL
	DuanjuNiuguoParseURL2 = niuguoParseURL2
)

// ValidNativeCategory 校验站源分类是否合法（含站源自定义规则）。
func ValidNativeCategory(source, category string) bool { return validNativeCategory(source, category) }

// NativeText 把任意 JSON 值读成文本（数字、数组、对象都能处理）。
func NativeText(value any) string { return nativeText(value) }

// DuanjuEpisodeNumber 从标题里认出集号，认不出就用 fallback。
func DuanjuEpisodeNumber(raw string, fallback int) int { return duanjuEpisodeNumber(raw, fallback) }

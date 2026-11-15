package core

// 模块运行时依赖的上游契约名在 guoappxp 里是未导出的内部符号，这里做一层别名与
// 包装，让模块代码保持与上游一致的写法，同时不动既有实现。
//
// 另外补上 CapabilityLimiter + providerAs：模块按清单声明能力，运行时据此决定
// 要不要调它的可选接口，避免「清单没声明、JS 里也没这个函数」的调用。

import "reflect"

// BackgroundCatalogKey 标记「后台预热」请求（上游契约名，运行时内部叫 backgroundCatalogKey）。
type BackgroundCatalogKey = backgroundCatalogKey

// RequestBackoff 是限流 / 403 冷却的退避错误（上游契约名）。
type RequestBackoff = requestBackoff

// NativeNormalize 把站源原生的 Drama 归一到剧库形态。
func NativeNormalize(drama Drama) LibraryDrama { return nativeNormalize(drama) }

// MergeNativeDrama 用一份新数据补齐旧记录的缺失字段（同 ID 才合并）。
func MergeNativeDrama(previous, fresh LibraryDrama) LibraryDrama { return mergeNativeDrama(previous, fresh) }

// CapabilityLimiter 让站源声明自己实现了哪些可选能力。
//
// 编译期接入的站源不实现它（返回 false 时按「不限」处理，行为与从前一致）；
// 模块站源按清单声明裁剪，没声明的能力运行时不会去调用。
type CapabilityLimiter interface {
	ProvidesCapability(capability reflect.Type) bool
}

// providerAs 是可选能力的统一断言口：站源声明了能力限制时以它为准。
func providerAs[T any](provider Provider) (T, bool) {
	capability, ok := provider.(T)
	if limiter, limited := provider.(CapabilityLimiter); ok && limited && !limiter.ProvidesCapability(reflect.TypeFor[T]()) {
		var none T
		return none, false
	}
	return capability, ok
}

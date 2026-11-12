package core

import (
	"fmt"
	"sort"
	"strconv"
)

// 站源外置后仍由运行时共用的小工具。站源经 source_api.go 的导出包装使用它们。

func sortDuanjuChapters(chapters []Chapter) {
	sort.SliceStable(chapters, func(i, j int) bool {
		left, _ := strconv.Atoi(chapters[i].EpisodeString(i + 1))
		right, _ := strconv.Atoi(chapters[j].EpisodeString(j + 1))
		return left < right
	})
}

func duanjuFindBool(node map[string]any, keys ...string) bool {
	for _, key := range keys {
		if value, found := node[key]; found {
			switch typed := value.(type) {
			case bool:
				return typed
			case string:
				return typed == "true" || typed == "1"
			case float64:
				return typed != 0
			}
		}
	}
	return false
}

func duanjuFormatCount(value int) string {
	if value <= 0 {
		return ""
	}
	return fmt.Sprintf("%d集", value)
}

// firstPresent 返回第一个非空字段（网页源解析常见：字段名多套并存）。
func firstPresent(values map[string]any, keys ...string) any {
	for _, key := range keys {
		if value, ok := values[key]; ok && value != nil && nativeText(value) != "" {
			return value
		}
	}
	return nil
}

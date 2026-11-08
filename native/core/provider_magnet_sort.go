package core

import (
	"regexp"
	"strconv"
	"strings"
	"time"
)

// 站源返回的大小 / 日期是给人看的文本（"1.2 GB"、"3天前"、"2026-11-08"），
// 按大小或按时间排序时不能按字典序比。这里在 Go 侧归一化成数值，
// Flutter 与网页端直接按数值排序即可，不必各自再写一套解析。
var (
	magnetSizeNumber = regexp.MustCompile(`(?i)([0-9][0-9,.]*)\s*(b|k|kb|kib|m|mb|mib|g|gb|gib|t|tb|tib)?\b`)
	magnetDateYMD    = regexp.MustCompile(`(\d{4})[-/.年](\d{1,2})[-/.月](\d{1,2})`)
	magnetDateMD     = regexp.MustCompile(`(?:^|\D)(\d{1,2})[-/.月](\d{1,2})(?:\D|$)`)
	magnetRelative   = regexp.MustCompile(`(\d+)\s*(秒|分钟|分|小时|天|周|月|年)前`)
)

// magnetParseSizeBytes 把 "1.2 GB" / "1,234.5MB" / "800 KiB" / "512" 转成字节数。
// 解析不出来返回 0，排序时统一沉到末尾。
func magnetParseSizeBytes(raw string) int64 {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return 0
	}
	match := magnetSizeNumber.FindStringSubmatch(raw)
	if match == nil {
		return 0
	}
	number, err := strconv.ParseFloat(strings.ReplaceAll(match[1], ",", ""), 64)
	if err != nil || number < 0 || number > 1<<50 {
		return 0
	}
	multiplier := float64(1)
	switch strings.ToLower(strings.TrimSpace(match[2])) {
	case "k", "kb", "kib":
		multiplier = 1 << 10
	case "m", "mb", "mib":
		multiplier = 1 << 20
	case "g", "gb", "gib":
		multiplier = 1 << 30
	case "t", "tb", "tib":
		multiplier = 1 << 40
	}
	return int64(number * multiplier)
}

// magnetParseTimestamp 把常见中文站点的时间文本转成 Unix 秒。
// 无年份的 "11-08" 按今年算，落到未来就回退一年；解析失败返回 0。
func magnetParseTimestamp(raw string, now time.Time) int64 {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return 0
	}
	if match := magnetDateYMD.FindStringSubmatch(raw); len(match) > 3 {
		year, _ := strconv.Atoi(match[1])
		month, _ := strconv.Atoi(match[2])
		day, _ := strconv.Atoi(match[3])
		if year >= 1970 && year <= now.Year()+5 && month >= 1 && month <= 12 && day >= 1 && day <= 31 {
			value := time.Date(year, time.Month(month), day, 0, 0, 0, 0, now.Location())
			if value.Year() == year && int(value.Month()) == month && value.Day() == day {
				return value.Unix()
			}
		}
	}
	if match := magnetRelative.FindStringSubmatch(raw); len(match) > 2 {
		count, err := strconv.Atoi(match[1])
		if err == nil && count > 0 && count < 100000 {
			var unit time.Duration
			switch match[2] {
			case "秒":
				unit = time.Second
			case "分钟", "分":
				unit = time.Minute
			case "小时":
				unit = time.Hour
			case "天":
				unit = 24 * time.Hour
			case "周":
				unit = 7 * 24 * time.Hour
			case "月":
				unit = 30 * 24 * time.Hour
			case "年":
				unit = 365 * 24 * time.Hour
			}
			if unit > 0 {
				return now.Add(-time.Duration(count) * unit).Unix()
			}
		}
	}
	switch {
	case strings.Contains(raw, "刚刚"), strings.Contains(raw, "刚才"):
		return now.Unix()
	case strings.Contains(raw, "今天"):
		return time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location()).Unix()
	case strings.Contains(raw, "昨天"):
		return now.AddDate(0, 0, -1).Unix()
	case strings.Contains(raw, "前天"):
		return now.AddDate(0, 0, -2).Unix()
	}
	if match := magnetDateMD.FindStringSubmatch(raw); len(match) > 2 {
		month, _ := strconv.Atoi(match[1])
		day, _ := strconv.Atoi(match[2])
		if month >= 1 && month <= 12 && day >= 1 && day <= 31 {
			value := time.Date(now.Year(), time.Month(month), day, 0, 0, 0, 0, now.Location())
			if value.Month() == time.Month(month) && value.Day() == day {
				if value.After(now.AddDate(0, 0, 1)) {
					value = value.AddDate(-1, 0, 0)
				}
				return value.Unix()
			}
		}
	}
	return 0
}

package core

import (
	"context"
	"math/rand"
	"regexp"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/antchfx/htmlquery"
)

// 磁力热词：搜索框下面的一行快捷词。默认池保证离线/刚进页面就能立刻出 20 个；
// 点「换一批」时再从已启用的磁力站首页抓一批标题词混进来，做到「随机取自磁力源」。
var magnetHotWordPool = []string{
	"4K 蓝光原盘", "杜比视界", "HDR10", "1080P 高清", "国语配音", "粤语原声",
	"双语字幕", "未删减版", "导演剪辑版", "全网合集", "无损音轨", "REMUX",
	"流浪地球", "哪吒之魔童闹海", "封神第二部", "沙丘2", "奥本海默", "芭比",
	"阿凡达", "星际穿越", "盗梦空间", "复仇者联盟", "蜘蛛侠", "蝙蝠侠",
	"千与千寻", "你的名字", "泰坦尼克号", "速度与激情", "变形金刚", "哈利波特",
	"庆余年", "繁花", "狂飙", "三体", "漫长的季节", "隐秘的角落",
	"权力的游戏", "绝命毒师", "老友记", "鱿鱼游戏", "黑暗荣耀", "怪奇物语",
	"海贼王", "火影忍者", "进击的巨人", "鬼灭之刃", "咒术回战", "间谍过家家",
	"葬送的芙莉莲", "灌篮高手", "名侦探柯南", "哆啦A梦", "斗罗大陆", "完美世界",
	"BBC 纪录片", "国家地理", "地球脉动", "舌尖上的中国", "航拍中国",
	"周杰伦", "陈奕迅", "邓紫棋", "无损音乐合集", "演唱会现场",
	"2026 最新", "本周热播", "高分电影", "豆瓣 Top250", "IMDb 250",
}

var (
	magnetHotWordNoise = regexp.MustCompile(`(?i)(下载|首页|登录|注册|更多|搜索|磁力|种子|版权|联系|关于|上一页|下一页|http|www|©|备案|导航|排行|最新|分类|专题|列表|详情|播放|收藏|分享|评论)`)
	magnetHotWordCache = struct {
		sync.RWMutex
		items  []string
		source string
		at     time.Time
	}{}
)

const (
	magnetHotWordCount = 20
	magnetHotWordTTL   = 10 * time.Minute
)

// magnetDefaultBrowseWord 给「磁力播放」分类列表提供一个稳定的默认浏览词。
// 取前 20 个画质/类型词（而不是具体片名），对绝大多数站都能返回一批最新条目。
func magnetDefaultBrowseWord() string {
	pool := magnetHotWordPool
	if len(pool) > 20 {
		pool = pool[:20]
	}
	return pool[rand.Intn(len(pool))]
}

func magnetHotWords(ctx context.Context, force bool) (map[string]any, error) {
	magnetHotWordCache.RLock()
	fresh := !force &&
		len(magnetHotWordCache.items) >= magnetHotWordCount &&
		time.Since(magnetHotWordCache.at) < magnetHotWordTTL
	cachedItems := append([]string(nil), magnetHotWordCache.items...)
	cachedSource := magnetHotWordCache.source
	magnetHotWordCache.RUnlock()
	if fresh {
		return map[string]any{"items": cachedItems, "source": cachedSource}, nil
	}

	pool := append([]string(nil), magnetHotWordPool...)
	siteWords := magnetSiteHotWords(ctx)
	source := "内置热词"
	if len(siteWords) > 0 {
		pool = append(pool, siteWords...)
		source = "磁力站实时"
	}
	seen := map[string]bool{}
	unique := make([]string, 0, len(pool))
	for _, word := range pool {
		word = strings.TrimSpace(word)
		if word == "" || seen[word] {
			continue
		}
		seen[word] = true
		unique = append(unique, word)
	}
	rand.Shuffle(len(unique), func(i, j int) {
		unique[i], unique[j] = unique[j], unique[i]
	})
	if len(unique) > magnetHotWordCount {
		unique = unique[:magnetHotWordCount]
	}
	if len(unique) < magnetHotWordCount {
		// 站点抓取结果太少时，用默认池补足，保证界面始终有 20 个。
		for _, word := range magnetHotWordPool {
			if len(unique) >= magnetHotWordCount {
				break
			}
			if !seen[word] {
				seen[word] = true
				unique = append(unique, word)
			}
		}
	}

	magnetHotWordCache.Lock()
	magnetHotWordCache.items = append([]string(nil), unique...)
	magnetHotWordCache.source = source
	magnetHotWordCache.at = time.Now()
	magnetHotWordCache.Unlock()
	return map[string]any{"items": unique, "source": source}, nil
}

// magnetSiteHotWords 挑少量已启用站点抓首页，从链接文本里抽出像片名/关键词的短语。
// 总预算 6 秒，单站失败不影响其它站；全部失败时返回空，由默认池兜底。
func magnetSiteHotWords(ctx context.Context) []string {
	sites, err := loadMagnetSites()
	if err != nil {
		return nil
	}
	var candidates []magnetSite
	for _, site := range sites {
		if !site.State || strings.TrimSpace(site.Request.MainURL) == "" {
			continue
		}
		candidates = append(candidates, site)
	}
	if len(candidates) > 4 {
		// 随机取 4 个站，避免每次都打同一批站点。
		start := rand.Intn(len(candidates))
		shuffled := make([]magnetSite, 0, 4)
		for i := 0; i < 4; i++ {
			shuffled = append(shuffled, candidates[(start+i)%len(candidates)])
		}
		candidates = shuffled
	}

	budget, cancel := context.WithTimeout(ctx, 6*time.Second)
	defer cancel()
	type outcome struct{ words []string }
	results := make([]outcome, len(candidates))
	var wait sync.WaitGroup
	for i := range candidates {
		wait.Add(1)
		go func(index int) {
			defer wait.Done()
			site := candidates[index]
			body, err := magnetFetch(budget, site.Request.MainURL, site.Request.Header)
			if err != nil {
				return
			}
			doc, err := htmlquery.Parse(strings.NewReader(body))
			if err != nil {
				return
			}
			for _, anchor := range htmlquery.Find(doc, "//a") {
				word := strings.TrimSpace(htmlquery.InnerText(anchor))
				if magnetHotWordUsable(word) {
					results[index].words = append(results[index].words, word)
				}
				if len(results[index].words) >= 24 {
					break
				}
			}
		}(i)
	}
	wait.Wait()

	var words []string
	for _, result := range results {
		words = append(words, result.words...)
	}
	return words
}

func magnetHotWordUsable(word string) bool {
	length := utf8.RuneCountInString(word)
	if length < 2 || length > 16 || magnetHotWordNoise.MatchString(word) {
		return false
	}
	letters, digits := 0, 0
	for _, r := range word {
		switch {
		case unicode.IsLetter(r):
			letters++
		case unicode.IsDigit(r):
			digits++
		case r == ' ' || r == '·' || r == '-' || r == ':' || r == '(' || r == ')':
		default:
			return false // 含标点/符号的大多是导航文案或整句简介
		}
	}
	if letters < 2 || digits > letters {
		return false
	}
	for _, r := range word {
		if r > 127 {
			return true // 含中文，最常见的片名/剧名
		}
	}
	// 纯 ASCII 时要求带空格（如 "Avatar 4K"），排除域名、hash、英文导航词。
	return strings.Contains(word, " ")
}

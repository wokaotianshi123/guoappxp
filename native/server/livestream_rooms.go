package main

import (
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// 房间型直播源（斗鱼 / 哔哩哔哩 / 虎牙）。与 App 端 lib/live/live_rooms.dart 同逻辑：
// 分类与房间列表都是公开 JSON 接口，真实播放地址必须按房间号二次解析，
// 因此列表接口只下发房间号（token），点播时再换取 flv/hls 地址。
// 浏览器不能跨域请求这些接口，也无法携带 Referer，所以全部由本机服务端代发。

const (
	liveRoomPageSize  = 30
	liveDouyuDeviceID = "10000000000000000000000000001501"
	liveDouyuMobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) " +
		"AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
	// 虎牙 mp 接口下发的取流地址带 ctype=tars_mp，CDN 只认虎牙客户端；
	// 用浏览器 UA 拉会在几秒后被动断开，详见 App 端 huyaLiveUserAgent。
	liveHuyaUserAgent = "HYSDK(Windows,30000002)_APP(pc_exe&50108&official)" +
		"_SDK(android,6.8.0)_PLATFORM(internal)_OS(micromac)"
)

var liveRoomReferers = map[string]string{
	"bilibili": "https://live.bilibili.com/",
	"douyu":    "https://www.douyu.com/",
	"huya":     "https://www.huya.com/",
}

// 取流时必须伪装成对应平台客户端的源。
var liveRoomUserAgents = map[string]string{
	"huya": liveHuyaUserAgent,
}

func liveRoomHeaders(sourceID string) map[string]string {
	referer := liveRoomReferers[sourceID]
	if referer == "" {
		return nil
	}
	agent := liveUserAgentValue
	if custom := liveRoomUserAgents[sourceID]; custom != "" {
		agent = custom
	}
	return map[string]string{"Referer": referer, "User-Agent": agent}
}

// —— JSON 取值助手（上游字段类型不稳定，统一走宽松转换）——

func liveDecodeObject(text string) (map[string]any, error) {
	var decoded any
	if err := json.Unmarshal([]byte(text), &decoded); err != nil {
		return nil, errors.New("直播源返回的内容无法识别")
	}
	root, ok := decoded.(map[string]any)
	if !ok {
		return nil, errors.New("直播源返回的内容无法识别")
	}
	return root, nil
}

func liveObject(value any) map[string]any {
	if root, ok := value.(map[string]any); ok {
		return root
	}
	return nil
}

func liveObjectList(value any) []map[string]any {
	rows, ok := value.([]any)
	if !ok {
		return nil
	}
	result := make([]map[string]any, 0, len(rows))
	for _, item := range rows {
		if row := liveObject(item); row != nil {
			result = append(result, row)
		}
	}
	return result
}

func liveText(value any) string {
	switch typed := value.(type) {
	case string:
		return strings.TrimSpace(typed)
	case float64:
		return strconv.FormatFloat(typed, 'f', -1, 64)
	case bool:
		return strconv.FormatBool(typed)
	case nil:
		return ""
	default:
		return strings.TrimSpace(asString(typed))
	}
}

func liveNumber(value any) int {
	switch typed := value.(type) {
	case float64:
		return int(typed)
	case int:
		return typed
	case string:
		number, _ := strconv.Atoi(strings.TrimSpace(typed))
		return number
	default:
		return 0
	}
}

func liveAccept(root map[string]any, key string, expected int) error {
	if _, ok := root[key]; !ok {
		return nil
	}
	if liveNumber(root[key]) == expected {
		return nil
	}
	return errors.New("该直播源暂时不可用")
}

// —— 分类 ——

func liveRoomPlatforms(session *liveSession, source liveSourceDef) ([]map[string]any, error) {
	switch source.ID {
	case "bilibili":
		return liveBilibiliPlatforms(session)
	case "douyu":
		return liveDouyuPlatforms(session)
	case "huya":
		return liveHuyaPlatforms(session)
	}
	return nil, errors.New("该直播源没有可用分类")
}

func liveBilibiliPlatforms(session *liveSession) ([]map[string]any, error) {
	payload, err := session.get(
		"https://api.live.bilibili.com/room/v1/Area/getList",
		liveRoomHeaders("bilibili"),
	)
	if err != nil {
		return nil, err
	}
	root, err := liveDecodeObject(payload)
	if err != nil {
		return nil, err
	}
	if err := liveAccept(root, "code", 0); err != nil {
		return nil, err
	}
	var result []map[string]any
	seen := map[string]bool{}
	for _, row := range liveObjectList(root["data"]) {
		id := liveText(row["id"])
		name := liveText(row["name"])
		if id == "" || name == "" || seen[id] {
			continue
		}
		seen[id] = true
		result = append(result, map[string]any{"id": id, "name": name, "count": 0})
	}
	return result, nil
}

func liveDouyuPlatforms(session *liveSession) ([]map[string]any, error) {
	payload, err := session.get(
		"https://m.douyu.com/api/cate/list",
		map[string]string{"Referer": "https://m.douyu.com/", "User-Agent": liveDouyuMobileUA},
	)
	if err != nil {
		return nil, err
	}
	root, err := liveDecodeObject(payload)
	if err != nil {
		return nil, err
	}
	if err := liveAccept(root, "code", 0); err != nil {
		return nil, err
	}
	var result []map[string]any
	seen := map[string]bool{}
	data := liveObject(root["data"])
	for _, row := range liveObjectList(data["cate2Info"]) {
		id := liveText(row["cate2Id"])
		name := liveText(row["cate2Name"])
		if id == "" || name == "" || seen[id] {
			continue
		}
		count := liveNumber(row["count"])
		if _, ok := row["count"]; ok && count <= 0 {
			continue
		}
		seen[id] = true
		result = append(result, map[string]any{"id": id, "name": name, "count": count})
	}
	return result, nil
}

func liveHuyaPlatforms(session *liveSession) ([]map[string]any, error) {
	payload, err := session.get(
		"https://www.huya.com/cache.php?m=Game&do=getGameList",
		liveRoomHeaders("huya"),
	)
	if err != nil {
		return nil, err
	}
	root, err := liveDecodeObject(payload)
	if err != nil {
		return nil, err
	}
	if err := liveAccept(root, "status", 200); err != nil {
		return nil, err
	}
	var result []map[string]any
	seen := map[string]bool{}
	for _, row := range liveObjectList(root["gameList"]) {
		id := liveText(row["gid"])
		name := liveText(row["gameFullName"])
		if id == "" || name == "" || seen[id] {
			continue
		}
		if liveNumber(row["isHide"]) == 1 {
			continue
		}
		if _, ok := row["profileNum"]; ok && liveNumber(row["profileNum"]) <= 0 {
			continue
		}
		seen[id] = true
		result = append(result, map[string]any{
			"id": id, "name": name, "count": liveNumber(row["profileNum"]),
		})
	}
	return result, nil
}

// —— 房间列表：只下发房间号，真实地址点播时解析 ——

func liveRoomChannels(session *liveSession, source liveSourceDef, platformID string, page int, group string) ([]liveChannelOut, error) {
	if page < 1 {
		page = 1
	}
	switch source.ID {
	case "bilibili":
		return liveBilibiliChannels(session, source, platformID, page, group)
	case "douyu":
		return liveDouyuChannels(session, source, platformID, page, group)
	case "huya":
		return liveHuyaChannels(session, source, platformID, page, group)
	}
	return nil, errors.New("该分类暂时没有频道")
}

func liveBilibiliChannels(session *liveSession, source liveSourceDef, platformID string, page int, group string) ([]liveChannelOut, error) {
	target := "https://api.live.bilibili.com/room/v3/Area/getRoomList" +
		"?platform=web&parent_area_id=" + url.QueryEscape(platformID) +
		"&cate_id=0&area_id=0&sort_type=online&page=" + strconv.Itoa(page) +
		"&page_size=" + strconv.Itoa(liveRoomPageSize)
	payload, err := session.get(target, liveRoomHeaders("bilibili"))
	if err != nil {
		return nil, err
	}
	root, err := liveDecodeObject(payload)
	if err != nil {
		return nil, err
	}
	if err := liveAccept(root, "code", 0); err != nil {
		return nil, err
	}
	data := liveObject(root["data"])
	return liveRoomRows(session, source, group, liveObjectList(data["list"]),
		func(row map[string]any) string { return liveText(row["roomid"]) },
		func(row map[string]any) string { return liveText(row["title"]) },
		func(row map[string]any) string { return liveText(row["uname"]) },
		func(row map[string]any) string { return liveText(row["user_cover"]) },
		func(row map[string]any) any { return row["online"] },
	), nil
}

func liveDouyuChannels(session *liveSession, source liveSourceDef, platformID string, page int, group string) ([]liveChannelOut, error) {
	target := "https://www.douyu.com/gapi/rkc/directory/mixList/2_" +
		url.QueryEscape(platformID) + "/" + strconv.Itoa(page)
	payload, err := session.get(target, liveRoomHeaders("douyu"))
	if err != nil {
		return nil, err
	}
	root, err := liveDecodeObject(payload)
	if err != nil {
		return nil, err
	}
	if err := liveAccept(root, "code", 0); err != nil {
		return nil, err
	}
	data := liveObject(root["data"])
	return liveRoomRows(session, source, group, liveObjectList(data["rl"]),
		func(row map[string]any) string { return liveText(row["rid"]) },
		func(row map[string]any) string { return liveText(row["rn"]) },
		func(row map[string]any) string { return liveText(row["nn"]) },
		func(row map[string]any) string { return liveText(row["rs16"]) },
		func(row map[string]any) any { return row["ol"] },
	), nil
}

func liveHuyaChannels(session *liveSession, source liveSourceDef, platformID string, page int, group string) ([]liveChannelOut, error) {
	target := "https://www.huya.com/cache.php?m=LiveList&do=getLiveListByPage" +
		"&gameId=" + url.QueryEscape(platformID) + "&tagAll=0&page=" + strconv.Itoa(page)
	payload, err := session.get(target, liveRoomHeaders("huya"))
	if err != nil {
		return nil, err
	}
	root, err := liveDecodeObject(payload)
	if err != nil {
		return nil, err
	}
	if err := liveAccept(root, "status", 200); err != nil {
		return nil, err
	}
	data := liveObject(root["data"])
	return liveRoomRows(session, source, group, liveObjectList(data["datas"]),
		func(row map[string]any) string { return liveText(row["profileRoom"]) },
		func(row map[string]any) string { return liveText(row["roomName"]) },
		func(row map[string]any) string { return liveText(row["nick"]) },
		func(row map[string]any) string { return liveText(row["screenshot"]) },
		func(row map[string]any) any { return row["totalCount"] },
	), nil
}

func liveRoomRows(
	session *liveSession,
	source liveSourceDef,
	group string,
	rows []map[string]any,
	idOf func(map[string]any) string,
	nameOf func(map[string]any) string,
	hostOf func(map[string]any) string,
	logoOf func(map[string]any) string,
	audienceOf func(map[string]any) any,
) []liveChannelOut {
	headers := liveRoomHeaders(source.ID)
	seen := map[string]bool{}
	result := make([]liveChannelOut, 0, len(rows))
	for _, row := range rows {
		room := idOf(row)
		host := hostOf(row)
		title := nameOf(row)
		name := host
		if name == "" {
			name = title
		}
		if room == "" || name == "" || seen[room] {
			continue
		}
		seen[room] = true
		parts := make([]string, 0, 2)
		if title != "" && title != name {
			parts = append(parts, title)
		}
		if audience := liveAudience(audienceOf(row)); audience != "" {
			parts = append(parts, audience)
		}
		result = append(result, liveChannelOut{
			Name:     name,
			URLs:     []string{},
			Logo:     logoOf(row),
			Group:    group,
			Headers:  copyHeader(headers),
			Token:    room,
			Subtitle: strings.Join(parts, " · "),
		})
	}
	return result
}

func liveAudience(value any) string {
	count := liveNumber(value)
	if count <= 0 {
		return ""
	}
	return "在线 " + strconv.Itoa(count)
}

// —— 取流 ——

func liveRoomPlayback(session *liveSession, source liveSourceDef, room string) ([]string, map[string]string, error) {
	room = strings.TrimSpace(room)
	if room == "" {
		return nil, nil, errors.New("该频道没有可用线路")
	}
	var raw string
	var err error
	switch source.ID {
	case "bilibili":
		raw, err = liveBilibiliPlayURL(session, room)
	case "douyu":
		raw, err = liveDouyuPlayURL(session, room)
	case "huya":
		raw, err = liveHuyaPlayURL(session, room)
	default:
		return nil, nil, errors.New("该频道没有可用线路")
	}
	if err != nil {
		return nil, nil, err
	}
	if !liveURLUsable(raw) {
		return nil, nil, errors.New("该直播间当前没有可播放的地址")
	}
	return []string{raw}, copyHeader(liveRoomHeaders(source.ID)), nil
}

func liveBilibiliPlayURL(session *liveSession, room string) (string, error) {
	target := "https://api.live.bilibili.com/xlive/web-room/v2/index/getRoomPlayInfo" +
		"?room_id=" + url.QueryEscape(room) +
		"&protocol=0,1&format=0,1,2&codec=0,1&qn=10000" +
		"&platform=web&ptype=8&dolby=5&panorama=1"
	payload, err := session.get(target, liveRoomHeaders("bilibili"))
	if err != nil {
		return "", err
	}
	root, err := liveDecodeObject(payload)
	if err != nil {
		return "", err
	}
	if err := liveAccept(root, "code", 0); err != nil {
		return "", err
	}
	best, _, ok := liveBilibiliBest(root)
	if !ok {
		return "", errors.New("该直播间当前没有可播放的地址")
	}
	return best, nil
}

// liveBilibiliBest 选 current_qn 最高的线路，同画质优先 flv（浏览器 flv.js 更稳）。
func liveBilibiliBest(root map[string]any) (string, int, bool) {
	playurl := liveObject(liveObject(liveObject(liveObject(root["data"])["playurl_info"])["playurl"]))
	var best string
	bestQuality := -1
	bestFlv := false
	for _, stream := range liveObjectList(playurl["stream"]) {
		httpStream := liveText(stream["protocol_name"]) == "http_stream"
		for _, format := range liveObjectList(stream["format"]) {
			flv := httpStream || liveText(format["format_name"]) == "flv"
			for _, codec := range liveObjectList(format["codec"]) {
				quality := liveNumber(codec["current_qn"])
				link, ok := liveBilibiliURL(codec)
				if !ok {
					continue
				}
				better := best == "" || quality > bestQuality ||
					(quality == bestQuality && flv && !bestFlv)
				if !better {
					continue
				}
				best, bestQuality, bestFlv = link, quality, flv
			}
		}
	}
	return best, bestQuality, best != ""
}

func liveBilibiliURL(codec map[string]any) (string, bool) {
	base := liveText(codec["base_url"])
	for _, info := range liveObjectList(codec["url_info"]) {
		link := liveJoinURL(liveText(info["host"]), base, liveText(info["extra"]))
		if link != "" && liveURLUsable(link) {
			return link, true
		}
	}
	return "", false
}

func liveJoinURL(host string, base string, extra string) string {
	origin := strings.TrimSpace(host)
	path := strings.TrimSpace(base)
	if origin == "" || path == "" {
		return ""
	}
	var joined string
	if strings.Contains(path, "://") {
		joined = path
	} else {
		switch {
		case strings.HasSuffix(origin, "/") && strings.HasPrefix(path, "/"):
			joined = origin[:len(origin)-1] + path
		case !strings.HasSuffix(origin, "/") && !strings.HasPrefix(path, "/"):
			joined = origin + "/" + path
		default:
			joined = origin + path
		}
	}
	tail := strings.TrimSpace(extra)
	if tail == "" {
		return joined
	}
	if strings.HasPrefix(tail, "?") || strings.HasPrefix(tail, "&") {
		if strings.Contains(joined, "?") && strings.HasPrefix(tail, "?") {
			return joined + "&" + tail[1:]
		}
		return joined + tail
	}
	if strings.HasSuffix(joined, "?") || strings.HasSuffix(joined, "&") {
		return joined + tail
	}
	if strings.Contains(joined, "?") {
		return joined + "&" + tail
	}
	return joined + "?" + tail
}

func liveDouyuPlayURL(session *liveSession, room string) (string, error) {
	first, err := liveDouyuStream(session, room, 0)
	if err != nil {
		return "", err
	}
	if first == nil {
		return "", errors.New("该直播间当前没有可播放的地址")
	}
	chosen := first
	if rate := liveDouyuPreferredRate(first["multirates"]); rate != 0 {
		if again, againErr := liveDouyuStream(session, room, rate); againErr == nil && again != nil {
			if _, ok := liveDouyuPlayURLOf(again); ok {
				chosen = again
			}
		}
	}
	link, ok := liveDouyuPlayURLOf(chosen)
	if !ok {
		return "", errors.New("该直播间当前没有可播放的地址")
	}
	return link, nil
}

func liveDouyuStream(session *liveSession, room string, rate int) (map[string]any, error) {
	headers := liveRoomHeaders("douyu")
	payload, header, err := session.requestWithHeaders(
		"https://www.douyu.com/wgapi/livenc/liveweb/websec/getEncryption?did="+liveDouyuDeviceID,
		http.MethodGet,
		nil,
		headers,
	)
	if err != nil {
		return nil, err
	}
	envelope, err := liveDecodeObject(string(payload))
	if err != nil {
		return nil, err
	}
	if err := liveAccept(envelope, "error", 0); err != nil {
		return nil, err
	}
	data := liveObject(envelope["data"])
	if data == nil {
		return nil, errors.New("该直播源暂时不可用")
	}
	key := liveText(data["key"])
	randStr := liveText(data["rand_str"])
	encData := liveText(data["enc_data"])
	encTime := liveNumber(data["enc_time"])
	if key == "" || randStr == "" || encData == "" || encTime < 0 || encTime > 4096 {
		return nil, errors.New("该直播源暂时不可用")
	}
	// 用响应头的 Date 计算签名时间戳，避免本机时钟偏差被斗鱼拒绝。
	timestamp := time.Now().Unix()
	if header != nil {
		if date, dateErr := http.ParseTime(header.Get("Date")); dateErr == nil {
			timestamp = date.Unix()
		}
	}
	form := url.Values{}
	form.Set("enc_data", encData)
	form.Set("tt", strconv.FormatInt(timestamp, 10))
	form.Set("did", liveDouyuDeviceID)
	form.Set("auth", liveDouyuAuth(
		room,
		timestamp,
		key,
		randStr,
		encTime,
		liveNumber(data["is_special"]),
	))
	form.Set("cdn", "")
	form.Set("rate", strconv.Itoa(rate))
	form.Set("hevc", "0")
	form.Set("fa", "0")
	form.Set("ive", "0")
	playPayload, err := session.request(
		"https://www.douyu.com/lapi/live/getH5PlayV1/"+url.PathEscape(room),
		http.MethodPost,
		[]byte(form.Encode()),
		headers,
	)
	if err != nil {
		return nil, err
	}
	play, err := liveDecodeObject(string(playPayload))
	if err != nil {
		return nil, err
	}
	if liveNumber(play["error"]) != 0 {
		return nil, nil
	}
	return liveObject(play["data"]), nil
}

func liveDouyuAuth(roomID string, timestamp int64, key string, randStr string, encTime int, special int) string {
	value := randStr
	rounds := encTime
	if rounds < 0 {
		rounds = 0
	}
	for index := 0; index < rounds; index++ {
		sum := md5.Sum([]byte(value + key))
		value = hex.EncodeToString(sum[:])
	}
	suffix := ""
	if special != 1 {
		suffix = roomID + strconv.FormatInt(timestamp, 10)
	}
	sum := md5.Sum([]byte(value + key + suffix))
	return hex.EncodeToString(sum[:])
}

func liveDouyuPreferredRate(rows any) int {
	list := liveObjectList(rows)
	rate := 0
	weight := int64(-1)
	for _, row := range list {
		bit := liveNumber(row["bit"])
		score := int64(bit)
		if bit <= 0 {
			score = 1 << 62
		}
		if score <= weight {
			continue
		}
		weight = score
		rate = liveNumber(row["rate"])
	}
	return rate
}

func liveDouyuPlayURLOf(data map[string]any) (string, bool) {
	base := liveText(data["rtmp_url"])
	live := liveText(data["rtmp_live"])
	if base == "" || live == "" {
		return "", false
	}
	if strings.Contains(live, "://") {
		return live, true
	}
	root := strings.TrimSuffix(base, "/")
	path := strings.TrimPrefix(live, "/")
	return root + "/" + path, true
}

func liveHuyaPlayURL(session *liveSession, room string) (string, error) {
	target := "https://mp.huya.com/cache.php?m=Live&do=profileRoom&roomid=" + url.QueryEscape(room)
	payload, err := session.get(target, liveRoomHeaders("huya"))
	if err != nil {
		return "", err
	}
	root, err := liveDecodeObject(payload)
	if err != nil {
		return "", err
	}
	if err := liveAccept(root, "status", 200); err != nil {
		return "", err
	}
	data := liveObject(root["data"])
	link := liveHuyaBestFLV(data["stream"])
	if link == "" {
		return "", errors.New("该直播间当前没有可播放的地址")
	}
	return link, nil
}

func liveHuyaBestFLV(stream any) string {
	root := liveObject(stream)
	rows := liveObjectList(root["baseSteamInfoList"])
	if len(rows) == 0 {
		rows = liveObjectList(stream)
	}
	best := ""
	bestMaster := false
	bestRate := -1 << 31
	for _, row := range rows {
		link := liveHuyaLineURL(row)
		if link == "" {
			continue
		}
		master := liveNumber(row["iIsMaster"]) == 1
		rate := liveNumber(row["iPCPriorityRate"])
		better := best == "" || (master && !bestMaster) ||
			(master == bestMaster && rate > bestRate)
		if !better {
			continue
		}
		best, bestMaster, bestRate = link, master, rate
	}
	return best
}

func liveHuyaLineURL(row map[string]any) string {
	host := liveText(row["sFlvUrl"])
	name := liveText(row["sStreamName"])
	suffix := liveText(row["sFlvUrlSuffix"])
	anti := liveText(row["sFlvAntiCode"])
	if host == "" || name == "" || suffix == "" {
		return ""
	}
	root := strings.TrimSuffix(host, "/")
	link := root + "/" + name + "." + suffix
	if anti == "" {
		return link
	}
	if strings.HasPrefix(anti, "?") || strings.HasPrefix(anti, "&") {
		return link + anti
	}
	return link + "?" + anti
}

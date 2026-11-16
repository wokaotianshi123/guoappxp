package core

import (
	"bytes"
	"context"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/net/html/charset"
)

type castDevice struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	control string
	service string
}

type nativeCast struct {
	mu      sync.Mutex
	devices map[string]castDevice
	device  castDevice
	token   string
	active  bool
}

type castDescriptionDevice struct {
	Name     string `xml:"friendlyName"`
	Services []struct {
		Type    string `xml:"serviceType"`
		Control string `xml:"controlURL"`
	} `xml:"serviceList>service"`
	Devices []castDescriptionDevice `xml:"deviceList>device"`
}

type castDescription struct {
	URLBase string                `xml:"URLBase"`
	Device  castDescriptionDevice `xml:"device"`
}

var castClient = &http.Client{Timeout: 6 * time.Second, Transport: &http.Transport{}}

var castSearchTargets = []string{
	"urn:schemas-upnp-org:service:AVTransport:1",
	"urn:schemas-upnp-org:device:MediaRenderer:1",
	"upnp:rootdevice",
	"ssdp:all",
}

func castSearch(target string) []byte {
	return []byte("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: " + target + "\r\n\r\n")
}

func castLocation(packet []byte) string {
	for line := range strings.Lines(string(packet)) {
		name, value, found := strings.Cut(line, ":")
		if found && strings.EqualFold(strings.TrimSpace(name), "location") {
			value = strings.TrimSpace(value)
			if parsed, err := url.Parse(value); err == nil && parsed.Scheme == "http" && parsed.Host != "" {
				return value
			}
		}
	}
	return ""
}

func castSearchLocations(ctx context.Context) []string {
	bind := []net.IP{nil}
	if addresses, err := net.InterfaceAddrs(); err == nil {
		for _, address := range addresses {
			if network, ok := address.(*net.IPNet); ok {
				if ip := network.IP.To4(); ip != nil && !ip.IsLoopback() {
					bind = append(bind, ip)
				}
			}
		}
	}
	deadline := time.Now().Add(3 * time.Second)
	target := &net.UDPAddr{IP: net.IPv4(239, 255, 255, 250), Port: 1900}
	var mu sync.Mutex
	var group sync.WaitGroup
	found := map[string]bool{}
	for _, ip := range bind {
		conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: ip})
		if err != nil {
			continue
		}
		group.Add(1)
		go func() {
			defer group.Done()
			defer conn.Close()
			stop := context.AfterFunc(ctx, func() { _ = conn.SetReadDeadline(time.Now()) })
			defer stop()
			_ = conn.SetReadDeadline(deadline)
			for range 2 {
				for _, search := range castSearchTargets {
					_, _ = conn.WriteToUDP(castSearch(search), target)
				}
			}
			buffer := make([]byte, 4096)
			for {
				size, _, err := conn.ReadFromUDP(buffer)
				if err != nil {
					return
				}
				if location := castLocation(buffer[:size]); location != "" {
					mu.Lock()
					found[location] = true
					mu.Unlock()
				}
			}
		}()
	}
	group.Wait()
	locations := make([]string, 0, len(found))
	for location := range found {
		locations = append(locations, location)
	}
	return locations
}

func castTransportService(device castDescriptionDevice) (string, string, bool) {
	for _, service := range device.Services {
		if strings.Contains(service.Type, ":service:AVTransport:") {
			return strings.TrimSpace(service.Type), strings.TrimSpace(service.Control), true
		}
	}
	for _, child := range device.Devices {
		if service, control, found := castTransportService(child); found {
			return service, control, true
		}
	}
	return "", "", false
}

func castDescribe(ctx context.Context, location string) (castDevice, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, location, nil)
	if err != nil {
		return castDevice{}, err
	}
	response, err := castClient.Do(request)
	if err != nil {
		return castDevice{}, err
	}
	defer response.Body.Close()
	var description castDescription
	decoder := xml.NewDecoder(io.LimitReader(response.Body, 1<<20))
	decoder.CharsetReader = charset.NewReaderLabel
	if err := decoder.Decode(&description); err != nil {
		return castDevice{}, err
	}
	service, control, found := castTransportService(description.Device)
	if !found {
		return castDevice{}, errors.New("设备不支持视频投屏")
	}
	base, err := url.Parse(location)
	if err != nil {
		return castDevice{}, err
	}
	if declared, err := url.Parse(strings.TrimSpace(description.URLBase)); err == nil && declared.Host != "" {
		base = declared
	}
	reference, err := url.Parse(control)
	if err != nil {
		return castDevice{}, err
	}
	name := strings.TrimSpace(description.Device.Name)
	if name == "" {
		name = base.Hostname()
	}
	return castDevice{ID: location, Name: name, control: base.ResolveReference(reference).String(), service: service}, nil
}

func (engine *nativeEngine) castDiscover(ctx context.Context) []castDevice {
	locations := castSearchLocations(ctx)
	devices := make([]castDevice, len(locations))
	var group sync.WaitGroup
	for index, location := range locations {
		group.Add(1)
		go func() {
			defer group.Done()
			devices[index], _ = castDescribe(ctx, location)
		}()
	}
	group.Wait()
	known := map[string]castDevice{}
	items := []castDevice{}
	for _, device := range devices {
		if device.ID != "" {
			known[device.ID] = device
			items = append(items, device)
		}
	}
	sort.Slice(items, func(i, j int) bool { return items[i].Name < items[j].Name })
	engine.cast.mu.Lock()
	if engine.cast.active {
		known[engine.cast.device.ID] = engine.cast.device
	}
	engine.cast.devices = known
	engine.cast.mu.Unlock()
	return items
}

func castEscape(value string) string {
	var buffer bytes.Buffer
	_ = xml.EscapeText(&buffer, []byte(value))
	return buffer.String()
}

func castInvoke(ctx context.Context, device castDevice, action string, arguments ...string) (map[string]string, error) {
	var body strings.Builder
	body.WriteString(`<?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>`)
	fmt.Fprintf(&body, `<u:%s xmlns:u="%s"><InstanceID>0</InstanceID>`, action, castEscape(device.service))
	for index := 0; index+1 < len(arguments); index += 2 {
		fmt.Fprintf(&body, "<%s>%s</%s>", arguments[index], castEscape(arguments[index+1]), arguments[index])
	}
	fmt.Fprintf(&body, `</u:%s></s:Body></s:Envelope>`, action)
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, device.control, strings.NewReader(body.String()))
	if err != nil {
		return nil, err
	}
	request.Header.Set("Content-Type", `text/xml; charset="utf-8"`)
	request.Header["SOAPACTION"] = []string{`"` + device.service + "#" + action + `"`}
	response, err := castClient.Do(request)
	if err != nil {
		return nil, fmt.Errorf("连接不上投屏设备「%s」：%w", device.Name, err)
	}
	defer response.Body.Close()
	values := map[string]string{}
	decoder := xml.NewDecoder(io.LimitReader(response.Body, 1<<20))
	name := ""
	for {
		token, err := decoder.Token()
		if err != nil {
			break
		}
		switch element := token.(type) {
		case xml.StartElement:
			name = element.Name.Local
		case xml.CharData:
			if text := strings.TrimSpace(string(element)); text != "" && name != "" {
				values[name] += text
			}
		case xml.EndElement:
			name = ""
		}
	}
	if response.StatusCode != http.StatusOK {
		detail := "HTTP " + strconv.Itoa(response.StatusCode)
		if code := values["errorCode"]; code != "" {
			detail = "错误码 " + code + " " + values["errorDescription"]
		}
		return nil, fmt.Errorf("投屏设备「%s」拒绝了 %s 操作（%s）", device.Name, action, strings.TrimSpace(detail))
	}
	return values, nil
}

func castClock(milliseconds int64) string {
	seconds := max(0, milliseconds) / 1000
	return fmt.Sprintf("%d:%02d:%02d", seconds/3600, seconds/60%60, seconds%60)
}

func castMilliseconds(clock string) int64 {
	parts := strings.Split(strings.TrimSpace(clock), ":")
	if len(parts) != 3 {
		return 0
	}
	hours, hourErr := strconv.Atoi(parts[0])
	minutes, minuteErr := strconv.Atoi(parts[1])
	seconds, secondErr := strconv.ParseFloat(parts[2], 64)
	if hourErr != nil || minuteErr != nil || secondErr != nil {
		return 0
	}
	return int64(hours)*3600000 + int64(minutes)*60000 + int64(seconds*1000)
}

func castState(transport string) string {
	switch transport {
	case "PLAYING":
		return "playing"
	case "PAUSED_PLAYBACK":
		return "paused"
	case "TRANSITIONING":
		return "loading"
	default:
		return "stopped"
	}
}

func (engine *nativeEngine) castStatus(ctx context.Context, device castDevice) (map[string]any, error) {
	transport, err := castInvoke(ctx, device, "GetTransportInfo")
	if err != nil {
		return nil, err
	}
	position, err := castInvoke(ctx, device, "GetPositionInfo")
	if err != nil {
		return nil, err
	}
	return map[string]any{
		"state":      castState(transport["CurrentTransportState"]),
		"positionMs": castMilliseconds(position["RelTime"]),
		"durationMs": castMilliseconds(position["TrackDuration"]),
	}, nil
}

func castMetadata(title, address, contentType string) string {
	return `<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"><item id="0" parentID="-1" restricted="1"><dc:title>` +
		castEscape(title) + `</dc:title><upnp:class>object.item.videoItem</upnp:class><res protocolInfo="http-get:*:` + contentType + `:*">` +
		castEscape(address) + `</res></item></DIDL-Lite>`
}

func (engine *nativeEngine) castPlay(ctx context.Context, input nativeInput) (any, error) {
	engine.cast.mu.Lock()
	device, known := engine.cast.devices[input.Device]
	previous, previousToken, wasActive := engine.cast.device, engine.cast.token, engine.cast.active
	engine.cast.mu.Unlock()
	if !known {
		return nil, errors.New("投屏设备已失效，请重新搜索")
	}
	if _, _, valid := SplitProviderDramaID(input.Drama.ID); !valid {
		return nil, errors.New("剧集信息无效")
	}
	task := Task{DramaID: input.Drama.ID, DramaTitle: input.Drama.Title, Chapter: input.Chapter, Index: input.Index}
	resolved, err := engine.downloader.resolveProviderMedia(ctx, task)
	if err != nil {
		return nil, err
	}
	var media *ProviderMedia
	for _, option := range nativePlaybackChoices(resolved, input.Quality).media {
		if IsProviderHTTPMediaURL(option.URL) {
			media = &option
			break
		}
	}
	if media == nil {
		return nil, errors.New("站源未返回有效的播放地址")
	}
	stream, err := engine.streamServer()
	if err != nil {
		return nil, err
	}
	control, err := url.Parse(device.control)
	if err != nil {
		return nil, err
	}
	origin, err := stream.lanOrigin(control.Host)
	if err != nil {
		return nil, err
	}
	local, token := stream.nativeOpen(*media, true)
	if len(media.CENCKey) > 0 {
		if err := stream.nativeDecrypt(ctx, token, *media); err != nil {
			stream.nativeRelease(token)
			return nil, err
		}
	}
	address := origin + strings.TrimPrefix(local, stream.address)
	contentType := "video/mp4"
	if strings.HasSuffix(local, ".m3u8") {
		contentType = "application/vnd.apple.mpegurl"
	}
	if wasActive {
		_, _ = castInvoke(ctx, previous, "Stop")
		stream.nativeRelease(previousToken)
	}
	engine.cast.mu.Lock()
	engine.cast.device, engine.cast.token, engine.cast.active = device, token, true
	engine.cast.mu.Unlock()
	title := strings.TrimSpace(input.Drama.Title + " 第 " + strconv.Itoa(input.Index) + " 集")
	if _, err := castInvoke(ctx, device, "SetAVTransportURI", "CurrentURI", address, "CurrentURIMetaData", castMetadata(title, address, contentType)); err != nil {
		engine.castRelease()
		return nil, err
	}
	if _, err := castInvoke(ctx, device, "Play", "Speed", "1"); err != nil {
		engine.castRelease()
		return nil, err
	}
	if input.StartMS > 0 {
		engine.castResume(ctx, device, input.StartMS)
	}
	return map[string]string{"name": device.Name}, nil
}

func (engine *nativeEngine) castResume(ctx context.Context, device castDevice, startMS int64) {
	for range 20 {
		transport, err := castInvoke(ctx, device, "GetTransportInfo")
		if err != nil {
			return
		}
		if transport["CurrentTransportState"] == "PLAYING" {
			_, _ = castInvoke(ctx, device, "Seek", "Unit", "REL_TIME", "Target", castClock(startMS))
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(500 * time.Millisecond):
		}
	}
}

func (engine *nativeEngine) castRelease() {
	engine.cast.mu.Lock()
	token := engine.cast.token
	engine.cast.token, engine.cast.active = "", false
	engine.cast.mu.Unlock()
	engine.mu.Lock()
	stream := engine.stream
	engine.mu.Unlock()
	if stream != nil {
		stream.nativeRelease(token)
		stream.lanClose()
	}
}

func (engine *nativeEngine) nativeCast(ctx context.Context, input nativeInput) (any, error) {
	if input.Command == "discover" {
		return map[string]any{"items": engine.castDiscover(ctx)}, nil
	}
	if input.Command == "play" {
		return engine.castPlay(ctx, input)
	}
	engine.cast.mu.Lock()
	device, active := engine.cast.device, engine.cast.active
	engine.cast.mu.Unlock()
	if input.Command == "active" {
		return map[string]bool{"active": active}, nil
	}
	if !active {
		if input.Command == "stop" {
			return true, nil
		}
		return nil, errors.New("当前没有正在进行的投屏")
	}
	switch input.Command {
	case "status":
		return engine.castStatus(ctx, device)
	case "pause":
		_, err := castInvoke(ctx, device, "Pause")
		return true, err
	case "resume":
		_, err := castInvoke(ctx, device, "Play", "Speed", "1")
		return true, err
	case "seek":
		_, err := castInvoke(ctx, device, "Seek", "Unit", "REL_TIME", "Target", castClock(input.StartMS))
		return true, err
	case "stop":
		_, err := castInvoke(ctx, device, "Stop")
		engine.castRelease()
		return true, err
	default:
		return nil, errors.New("不支持的投屏操作")
	}
}

// ---- 投屏（DLNA）：移植自 guoappxp ----
//
// 投屏只需要一个电视能访问到的播放地址。首选是把站源返回的原始地址直接交给
// 电视，电视自己上网拉流，手机退出 App 也不影响播放。
//
// 但有些线路离开本机就播不了：HLS 播放列表由核心重写过、分片要用本机持有的
// 密钥解密（CENC / AES-128），这些只能由核心在局域网口再挂一份流服务、让电视
// 连手机拉。因此核心同时给出 directUrl，由 Flutter 侧优先直连、失败再退回转发。

// nativeCastDirectURL 返回可以直接交给电视拉流的原始地址。
//
// 除了 CENC 加密（内容密钥只在手机侧，电视拿到也解不开）和本地文件，一律把
// 站源给出的原始地址原样交给电视：即使本机为了去广告、把相对路径补成绝对地址
// 而重写过播放列表，电视也能自己拉原始清单；AES-128 的 HLS 清单里带着密钥
// URI，电视同样能自己取。代价只是直连时去不掉广告，换来「投屏后退出 App、
// 切后台、锁屏都不影响电视播放」，取舍上以能独立播放为准。
func nativeCastDirectURL(media ProviderMedia) string {
	if !IsProviderHTTPMediaURL(media.URL) {
		return ""
	}
	if len(media.CENCKey) > 0 {
		return ""
	}
	return media.URL
}

// nativeCastBase 打开（或复用）投屏监听，返回局域网可访问的基址。
//
// peer 是投屏目标（电视）的地址，用来确定手机这一侧走哪块网卡：Android 上
// Go 的 net.Interfaces() 在部分机型 / 系统版本上拿不到网卡表（netlink 被拦，
// 表现为「当前没有可用的局域网地址，请先连接 Wi-Fi」，但 SSDP 明明能搜到设备），
// 而朝目标地址 connect 一个 UDP socket 再读本地地址只依赖内核路由，一定有值。
func (stream *nativeStreamServer) nativeCastBase(peer string) (string, error) {
	stream.mu.Lock()
	if stream.castBase != "" {
		base := stream.castBase
		stream.mu.Unlock()
		return base, nil
	}
	address := nativeCastAddress(peer, 0)
	if address == "" {
		stream.mu.Unlock()
		return "", errors.New("当前没有可用的局域网地址，请先连接 Wi-Fi")
	}
	listener, err := net.Listen("tcp4", "0.0.0.0:0")
	if err != nil {
		stream.mu.Unlock()
		return "", errors.New("无法开启投屏端口")
	}
	port := listener.Addr().(*net.TCPAddr).Port
	if port <= 0 {
		_ = listener.Close()
		stream.mu.Unlock()
		return "", errors.New("无法开启投屏端口")
	}
	server := &http.Server{
		Handler:           stream.server.Handler,
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    16384,
	}
	go func() { _ = server.Serve(listener) }()
	// 端口开好之后再定一次：这次能顺手验证地址确实落在本机某块网卡上。
	if checked := nativeCastAddress(peer, port); checked != "" {
		address = checked
	}
	base := "http://" + net.JoinHostPort(address, strconv.Itoa(port))
	stream.castServer = server
	stream.castListener = listener
	stream.castBase = base
	stream.mu.Unlock()
	return base, nil
}

// nativeCloseCast 停止投屏监听。会话本身不动，本机播放照常。
func (stream *nativeStreamServer) nativeCloseCast() {
	stream.mu.Lock()
	server := stream.castServer
	stream.castServer = nil
	stream.castListener = nil
	stream.castBase = ""
	stream.mu.Unlock()
	if server != nil {
		_ = server.Close()
	}
}

// nativeCastAddress 挑一个电视能访问的本地地址。
//
// port > 0 表示本地监听已经就绪，可以顺手验证候选地址确实落在本机某块网卡上
// （连不上说明是别的网卡的地址，比如流量卡的），避免把电视根本连不到的地址
// 返回出去。
func nativeCastAddress(peer string, port int) string {
	candidates := nativeCastCandidates(peer)
	if port > 0 {
		for _, candidate := range candidates {
			if nativeAddressServes(candidate, port) {
				return candidate
			}
		}
	}
	if len(candidates) > 0 {
		return candidates[0]
	}
	return ""
}

// nativeCastCandidates 按靠谱程度排候选地址：先是「朝电视那个方向选中」的地址，
// 再是枚举出来的网卡地址，最后才退到默认路由（可能是流量卡，优先级最低）。
func nativeCastCandidates(peer string) []string {
	seen := make(map[string]bool, 4)
	candidates := make([]string, 0, 4)
	add := func(address string) {
		if address == "" || seen[address] {
			return
		}
		seen[address] = true
		candidates = append(candidates, address)
	}
	add(nativeIPv4Toward(peer))
	for _, address := range nativeIPv4FromInterfaces() {
		add(address)
	}
	if strings.TrimSpace(peer) != "" {
		add(nativeIPv4Toward(""))
	}
	return candidates
}

// nativeIPv4Toward 朝 target 连一个 UDP socket，取内核选中的本地地址。target 为空
// 时退到一个公共地址，也就是走默认路由。UDP 的 connect 不发任何包，只是让路由表
// 挑出口，不用担心产生流量；它也不依赖网卡枚举，在 Android 上比 net.Interfaces()
// 可靠得多。
func nativeIPv4Toward(target string) string {
	targets := make([]string, 0, 2)
	if host := strings.TrimSpace(target); host != "" {
		if ip := net.ParseIP(host); ip != nil && ip.To4() != nil {
			targets = append(targets, net.JoinHostPort(host, "1900"))
		}
	} else {
		targets = append(targets, "223.5.5.5:80", "8.8.8.8:80")
	}
	for _, target := range targets {
		connection, err := net.Dial("udp4", target)
		if err != nil {
			continue
		}
		local := connection.LocalAddr()
		_ = connection.Close()
		host, _, err := net.SplitHostPort(local.String())
		if err != nil {
			continue
		}
		if address := nativeUsableIPv4(host); address != "" {
			return address
		}
	}
	return ""
}

// nativeAddressServes 确认 address:port 在本机真的连得上，也就是这个地址确实
// 属于本机某块网卡。
func nativeAddressServes(address string, port int) bool {
	connection, err := net.DialTimeout(
		"tcp4",
		net.JoinHostPort(address, strconv.Itoa(port)),
		400*time.Millisecond,
	)
	if err != nil {
		return false
	}
	_ = connection.Close()
	return true
}

// nativeIPv4FromInterfaces 枚举网卡地址，私有网段排在前面，跳过回环、未指定与
// 链路本地（169.254）。
func nativeIPv4FromInterfaces() []string {
	interfaces, err := net.Interfaces()
	if err != nil {
		return nil
	}
	private := make([]string, 0, 2)
	others := make([]string, 0, 2)
	for _, iface := range interfaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addresses, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addresses {
			ipNet, ok := addr.(*net.IPNet)
			if !ok {
				continue
			}
			address := nativeUsableIPv4(ipNet.IP.String())
			if address == "" {
				continue
			}
			if net.ParseIP(address).IsPrivate() {
				private = append(private, address)
				continue
			}
			others = append(others, address)
		}
	}
	return append(private, others...)
}

// nativeUsableIPv4 过滤掉投屏地址不能用的取值。
func nativeUsableIPv4(value string) string {
	ip := net.ParseIP(strings.TrimSpace(value)).To4()
	if ip == nil || ip.IsLoopback() || ip.IsUnspecified() || ip.IsLinkLocalUnicast() {
		return ""
	}
	return ip.String()
}

func (engine *nativeEngine) nativeCastBase(peer string) (string, error) {
	engine.mu.Lock()
	stream := engine.stream
	engine.mu.Unlock()
	if stream == nil {
		return "", errors.New("播放器尚未初始化，请先开始播放")
	}
	return stream.nativeCastBase(peer)
}

func (engine *nativeEngine) nativeCloseCast() {
	engine.mu.Lock()
	stream := engine.stream
	engine.mu.Unlock()
	if stream != nil {
		stream.nativeCloseCast()
	}
}

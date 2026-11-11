package main

import "testing"

// 虎牙 mp 接口下发的地址带 ctype=tars_mp，CDN 只放行虎牙客户端 UA；
// 取流头一旦退回浏览器 UA，播放几秒就会被掐断。
func TestLiveRoomHeadersUsePlatformAgent(t *testing.T) {
	huya := liveRoomHeaders("huya")
	if huya["User-Agent"] != liveHuyaUserAgent {
		t.Fatalf("虎牙取流 UA = %q，应为虎牙客户端标识", huya["User-Agent"])
	}
	if huya["Referer"] != "https://www.huya.com/" {
		t.Fatalf("虎牙取流 Referer = %q", huya["Referer"])
	}
	for _, id := range []string{"douyu", "bilibili"} {
		headers := liveRoomHeaders(id)
		if headers["User-Agent"] != liveUserAgentValue {
			t.Fatalf("%s 取流 UA 不应被改写：%q", id, headers["User-Agent"])
		}
	}
	if liveRoomHeaders("unknown") != nil {
		t.Fatalf("未来源不应下发取流头")
	}
}

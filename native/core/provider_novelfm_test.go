package core

import "testing"

func TestNovelfmSignMatchesFixedInput(t *testing.T) {
	raw := "https://reading.snssdk.com/reading/bookapi/search/tab/v?aid=1967&device_id=1000000000000001&query=test&tab_type=2&version_name=7.0.1.32"
	headers, err := novelfmSignRequest(raw, "", 1700000000000, []byte{1, 2, 3, 4}, 0x01020304)
	if err != nil {
		t.Fatal(err)
	}
	if headers["x-khronos"] != "1700000000" || headers["x-ss-req-ticket"] != "1700000000000" {
		t.Fatalf("time headers = %#v", headers)
	}
	if headers["x-ladon"] != "AQIDBKM7Y7bWnOIUXmTybD6/MpGbuge4sBwUJsyHVivhtMsH" {
		t.Fatalf("ladon = %s", headers["x-ladon"])
	}
	const argus = "8oGwZRLe2V38m+1gfqIeLa2MoV9ZBWosW5Y0NXKHAB2aEX8Sy3XkKahnaeRieievkKJXmGGpKhaZBa8O6sdcmF+mtVVEhi/I79DHPwSPQfEZyTeb20kzWMz+/gCj80stM8rDtbXVYXHnTljXLRixG4ki8nACevjtyeNlVXJdKzYL+SMggUuuwlNQ5fq68962YReLv3+Ql+u/GCLt1Ujg/jFRV7HszIvu57TNrlR64TLhp+7jMNnkg6+jc2xKJm6FCHaHJBCn3yRAmGeFj7z+rkp8"
	if headers["x-argus"] != argus {
		t.Fatalf("argus = %s", headers["x-argus"])
	}
	if _, ok := headers["X-SS-STUB"]; ok {
		t.Fatal("empty body must not set X-SS-STUB")
	}
}

func TestNovelfmSelectAudioReadsClearAddress(t *testing.T) {
	address, key, duration, err := novelfmSelectAudio(map[string]any{
		"code": 0.0,
		"data": map[string]any{
			"video_model_datas": []any{
				map[string]any{
					"video_model": `{"video_duration":12.5,"media_type":"audio","video_list":[{"main_url":"https://cdn.example/a.m4a","encrypt_info":{"encrypt":false}}]}`,
				},
			},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if address != "https://cdn.example/a.m4a" || key != nil || duration != 12.5 {
		t.Fatalf("address=%s key=%d duration=%v", address, len(key), duration)
	}
}

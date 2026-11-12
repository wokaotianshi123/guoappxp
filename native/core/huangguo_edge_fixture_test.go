package core

// 黄果 AI 的信封编解码与镜像候选用例：这些是纯辅助，不依赖站源是否编入。

import (
	"encoding/json"
	"net/http"
	"net/url"
	"strconv"
	"testing"
)

func huangguoEdgeTarget(t *testing.T, request *http.Request) *url.URL {
	t.Helper()
	var envelope struct {
		Method string `json:"method"`
		Path   string `json:"path"`
	}
	if request.Method != http.MethodPost || request.URL.Path != "/api/edge/request" || json.NewDecoder(request.Body).Decode(&envelope) != nil || envelope.Method != http.MethodGet {
		t.Errorf("request bypassed the edge envelope: %s %s", request.Method, request.URL)
		return &url.URL{}
	}
	target, err := url.Parse(envelope.Path)
	if err != nil {
		t.Errorf("invalid envelope path %q", envelope.Path)
		return &url.URL{}
	}
	return target
}

func huangguoEdgeReply(data any) string {
	body, _ := json.Marshal(map[string]any{"status": 1, "msg": "", "data": data})
	return string(body)
}

// 镜像候选必须覆盖每个域名，且第一个候选是原始地址。
func TestHuangguoAILinesCoverEveryMirrorDomain(t *testing.T) {
	const address = "https://huangguoai.com/api/edge/request"
	candidates := providerURLCandidates(address)
	if len(candidates) == 0 || candidates[0] != address {
		t.Fatal("the primary line is no longer tried first")
	}
	for _, candidate := range candidates {
		parsed, err := url.Parse(candidate)
		if err != nil || parsed.Path != "/api/edge/request" || providerSourceForURL(candidate) != sourceHuangguoAI {
			t.Fatalf("mirror candidate lost its identity: %s (%v)", candidate, err)
		}
	}
	if len(candidates) < 3 {
		t.Fatalf("mirror lines are missing: %v", candidates)
	}
	_ = strconv.Itoa
}

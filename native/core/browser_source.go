package core

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"strings"
	"time"

	fhttp "github.com/bogdanfinn/fhttp"
)

// browserPostJSON 用浏览器指纹传输发 POST，并把响应读成字节。
// 站源（Theporny 等）要求头部顺序与 Chrome 一致，所以这里按传入顺序写 Header。
func (d *Downloader) browserPostJSON(ctx context.Context, address string, headers [][2]string, body []byte, timeout time.Duration) (int, []byte, error) {
	if d.browserTransport == nil {
		return 0, nil, errors.New("浏览器指纹传输不可用")
	}
	if timeout <= 0 {
		timeout = 40 * time.Second
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	probe, err := http.NewRequestWithContext(ctx, http.MethodPost, address, bytes.NewReader(body))
	if err != nil {
		return 0, nil, err
	}
	client, err := d.browserTransport.client(probe)
	if err != nil {
		return 0, nil, err
	}
	request, err := fhttp.NewRequestWithContext(ctx, fhttp.MethodPost, address, bytes.NewReader(body))
	if err != nil {
		return 0, nil, err
	}
	order := make([]string, 0, len(headers))
	for _, header := range headers {
		name := strings.ToLower(strings.TrimSpace(header[0]))
		if name == "" {
			continue
		}
		request.Header.Set(name, header[1])
		order = append(order, name)
	}
	if len(order) > 0 {
		request.Header.Set(fhttp.HeaderOrderKey, strings.Join(order, ","))
	}
	response, err := client.Do(request)
	if err != nil {
		return 0, nil, err
	}
	defer response.Body.Close()
	payload, err := io.ReadAll(io.LimitReader(response.Body, providerMaxBodyBytes+1))
	if err != nil {
		return response.StatusCode, nil, err
	}
	if len(payload) > providerMaxBodyBytes {
		return response.StatusCode, nil, errors.New("站源响应体过大")
	}
	return response.StatusCode, payload, nil
}

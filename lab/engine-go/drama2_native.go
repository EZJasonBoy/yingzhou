package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"time"
)

const nativeSpiderSHA256 = "beaa0c16ecd5257bae7dd680ea145eda9a4385ce384bc02125ab64001940a0fe"
const nativeSpiderMD5 = "73c42d5c2f86efd6ddc6c85fd286069c"

type nativeCapabilities struct {
	Protocol int                 `json:"protocol"`
	SHA256   string              `json:"sha256"`
	Families map[string][]string `json:"families"`
}

type nativeSpider struct {
	path      string
	slots     chan struct{}
	globalJar string
	caps      nativeCapabilities
}

func newNativeSpider(path string, globalJar ...string) (*nativeSpider, error) {
	if !filepath.IsAbs(path) {
		return nil, errors.New("native host requires an absolute executable path")
	}
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() {
		return nil, errors.New("native host executable is unavailable")
	}
	spider := &nativeSpider{path: filepath.Clean(path), slots: make(chan struct{}, 2)}
	if len(globalJar) > 1 {
		return nil, errBadInput
	}
	if len(globalJar) == 1 {
		spider.globalJar = globalJar[0]
	}
	response, err := spider.execute(context.Background(), []byte("{\"op\":\"capabilities\"}\n"), 4096)
	if err != nil {
		return nil, err
	}
	spider.caps, err = parseNativeCapabilities(response)
	if err != nil {
		return nil, err
	}
	return spider, nil
}

func parseNativeCapabilities(response []byte) (nativeCapabilities, error) {
	var header struct {
		nativeCapabilities
		Error string   `json:"error"`
		API   string   `json:"api"`
		Sites []string `json:"sites"`
	}
	if err := json.Unmarshal(response, &header); err != nil {
		return nativeCapabilities{}, errors.New("invalid native host capabilities")
	}
	if header.Protocol == 0 && header.Error == "java.lang.IllegalStateException" {
		return nativeCapabilities{Protocol: 1, Families: map[string][]string{"csp_AppDrama2": {"干饭"}}}, nil
	}
	if header.SHA256 != nativeSpiderSHA256 || header.Error != "" {
		return nativeCapabilities{}, errors.New("unsupported native spider package")
	}
	switch header.Protocol {
	case 2:
		if header.API != "csp_AppDrama2" || len(header.Sites) == 0 {
			return nativeCapabilities{}, errors.New("invalid native host site list")
		}
		header.Families = map[string][]string{header.API: header.Sites}
	case 3:
		if len(header.Families) == 0 {
			return nativeCapabilities{}, errors.New("invalid native host family list")
		}
	default:
		return nativeCapabilities{}, errors.New("unsupported native host protocol")
	}
	return header.nativeCapabilities, nil
}

func knownNativeSite(api, key string) bool {
	switch api {
	case "csp_AppDrama2":
		return key == "干饭" || key == "行动" || key == "再来" || key == "一碗"
	case "csp_AppGet":
		return key == "蔬菜" || key == "方舟" || key == "番薯"
	case "csp_AppQi":
		return key == "肥猫" || key == "光盘"
	case "csp_SP360", "csp_Gz360", "csp_Jpys", "csp_SaoHuo":
		return key == api
	case "csp_AppYQK":
		return key == "一起"
	case "csp_GuaziTY":
		return key == "瓜子"
	case "csp_Gulu":
		return key == "咕噜"
	case "csp_Hxq":
		return key == "韩圈"
	case "csp_Jianpian":
		return key == "荐片"
	case "csp_Kanqiu":
		return key == "看球"
	case "csp_YGP":
		return key == "豆瓣预告"
	}
	return false
}

func (spider *nativeSpider) supports(site Site) bool {
	if site.Type != 3 || !knownNativeSite(site.API, site.Key) || !slices.Contains(spider.caps.Families[site.API], site.Key) {
		return false
	}
	effective := strings.TrimSpace(site.Jar)
	if effective == "" {
		effective = strings.TrimSpace(spider.globalJar)
	}
	parts := strings.Split(effective, ";")
	if len(parts) != 3 || strings.TrimSpace(parts[0]) == "" {
		return false
	}
	return (strings.EqualFold(parts[1], "md5") && strings.EqualFold(parts[2], nativeSpiderMD5)) ||
		(strings.EqualFold(parts[1], "sha256") && strings.EqualFold(parts[2], nativeSpiderSHA256))
}

type nativeOutput struct {
	buffer   bytes.Buffer
	limit    int
	overflow bool
	cancel   context.CancelFunc
}

func (out *nativeOutput) Write(data []byte) (int, error) {
	if len(data) > out.limit-out.buffer.Len() {
		out.overflow = true
		out.cancel()
		return 0, errors.New("native response too large")
	}
	return out.buffer.Write(data)
}

func (spider *nativeSpider) execute(parent context.Context, input []byte, limit int) ([]byte, error) {
	ctx, cancel := context.WithTimeout(parent, 45*time.Second)
	defer cancel()
	select {
	case spider.slots <- struct{}{}:
		defer func() { <-spider.slots }()
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	cmd := exec.CommandContext(ctx, spider.path)
	cmd.WaitDelay = time.Second
	cmd.Stdin = bytes.NewReader(input)
	output := &nativeOutput{limit: limit, cancel: cancel}
	cmd.Stdout = output
	cmd.Stderr = io.Discard
	err := cmd.Run()
	if output.overflow {
		return nil, errors.New("native response exceeded size limit")
	}
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	if err != nil {
		return nil, errors.New("native host failed to execute or exited unexpectedly")
	}
	return bytes.TrimSpace(output.buffer.Bytes()), nil
}

func (spider *nativeSpider) call(parent context.Context, site Site, request map[string]any) (json.RawMessage, error) {
	if !spider.supports(site) {
		return nil, errUnsupported
	}
	var ext string
	if len(site.Ext) > 0 && !bytes.Equal(bytes.TrimSpace(site.Ext), []byte("null")) {
		if !json.Valid(site.Ext) {
			return nil, errBadInput
		}
		if err := json.Unmarshal(site.Ext, &ext); err != nil {
			ext = string(site.Ext)
		}
	}
	var input bytes.Buffer
	enc := json.NewEncoder(&input)
	if err := enc.Encode(map[string]string{"op": "init", "api": site.API, "siteKey": site.Key, "ext": ext}); err != nil {
		return nil, errBadInput
	}
	if err := enc.Encode(request); err != nil || input.Len() > maxJSONSize {
		return nil, errBadInput
	}
	output, err := spider.execute(parent, input.Bytes(), maxJSONSize+1024)
	if err != nil {
		return nil, err
	}
	lines := bytes.SplitN(output, []byte{'\n'}, 3)
	var ready struct {
		Ready    bool   `json:"ready"`
		Protocol int    `json:"protocol"`
		SiteKey  string `json:"siteKey"`
		API      string `json:"api"`
		SHA256   string `json:"sha256"`
	}
	if len(lines) != 2 || len(lines[0]) > 1024 || json.Unmarshal(lines[0], &ready) != nil || !ready.Ready {
		return nil, errors.New("native host did not complete the protocol handshake")
	}
	if spider.caps.Protocol >= 2 && (ready.Protocol != spider.caps.Protocol || ready.SiteKey != site.Key || ready.SHA256 != nativeSpiderSHA256 || (ready.Protocol >= 3 && ready.API != site.API)) {
		return nil, errors.New("native host did not acknowledge the requested package and site")
	}
	payload := bytes.TrimSpace(lines[1])
	var result map[string]json.RawMessage
	if len(payload) > maxJSONSize || json.Unmarshal(payload, &result) != nil || result == nil {
		return nil, errors.New("invalid native host response")
	}
	if _, found := result["error"]; found {
		return nil, errors.New("native host reported an operation error")
	}
	return json.RawMessage(payload), nil
}

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
)

type drama2Host struct {
	client *http.Client
	base   string
}

func newDrama2Host(client *http.Client, endpoint string) (provider, error) {
	address, err := url.Parse(endpoint)
	if err != nil || (address.Scheme != "http" && address.Scheme != "https") || address.User != nil || address.ForceQuery || address.RawQuery != "" || address.Fragment != "" {
		return nil, fmt.Errorf("%w: expected local engine URL", errBadInput)
	}
	switch address.Hostname() {
	case "localhost":
		port := address.Port()
		address.Host = "127.0.0.1"
		if port != "" {
			address.Host += ":" + port
		}
	case "127.0.0.1", "::1":
	default:
		return nil, fmt.Errorf("%w: expected loopback engine", errBadInput)
	}
	if path := strings.TrimSuffix(address.EscapedPath(), "/"); path != "" && path != "/api/v1" {
		return nil, fmt.Errorf("%w: expected /api/v1", errBadInput)
	}
	address.Path = "/api/v1"
	if client == nil {
		client = http.DefaultClient
	}
	local := *client
	local.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	local.Jar = nil
	if transport, ok := local.Transport.(*http.Transport); ok {
		transport = transport.Clone()
		transport.Proxy = nil
		local.Transport = transport
	}
	return &drama2Host{client: &local, base: address.String()}, nil
}

func (host *drama2Host) request(ctx context.Context, path string, query url.Values, body any, output any) error {
	endpoint := host.base + path
	if len(query) != 0 {
		endpoint += "?" + query.Encode()
	}
	var payload []byte
	method := http.MethodGet
	if body != nil {
		var err error
		payload, err = json.Marshal(body)
		if err != nil {
			return err
		}
		method = http.MethodPost
	}
	req, err := http.NewRequestWithContext(ctx, method, endpoint, bytes.NewReader(payload))
	if err != nil {
		return err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := host.client.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return fmt.Errorf("local Yingzhou engine unavailable")
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("local Yingzhou engine returned HTTP %d", resp.StatusCode)
	}
	return readJSON(resp.Body, output)
}

func (host *drama2Host) verify(ctx context.Context, site Site) error {
	if site.Type != 3 || site.API != "csp_AppDrama2" || site.Key == "" || site.Key == "." || site.Key == ".." || strings.ContainsAny(site.Key, `/\`) {
		return errUnsupported
	}
	var sites []struct {
		Key, Runtime string
		Type         int
	}
	if err := host.request(ctx, "/sites", nil, nil, &sites); err != nil {
		return err
	}
	for _, candidate := range sites {
		if candidate.Key == site.Key && candidate.Type == 3 && candidate.Runtime == "jar" {
			return nil
		}
	}
	return fmt.Errorf("%w: local engine requires an active JAR site with the same key", errUnsupported)
}

func (host *drama2Host) get(ctx context.Context, site Site, action string, query url.Values, output any) error {
	if err := host.verify(ctx, site); err != nil {
		return err
	}
	return host.request(ctx, "/sites/"+url.PathEscape(site.Key)+"/"+action, query, nil, output)
}

func (host *drama2Host) Home(ctx context.Context, site Site) (Home, error) {
	var result Home
	err := host.get(ctx, site, "home", nil, &result)
	return result, err
}

func (host *drama2Host) Category(ctx context.Context, site Site, tid string, page int, filters map[string]string) (Page, error) {
	query := url.Values{"tid": {tid}, "pg": {strconv.Itoa(page)}}
	if len(filters) > 0 {
		data, err := json.Marshal(filters)
		if err != nil {
			return Page{}, err
		}
		query.Set("f", string(data))
	}
	var result Page
	err := host.get(ctx, site, "category", query, &result)
	return result, err
}

func (host *drama2Host) Search(ctx context.Context, site Site, query string, page int) (Page, error) {
	var result Page
	err := host.get(ctx, site, "search", url.Values{"wd": {query}, "pg": {strconv.Itoa(page)}}, &result)
	return result, err
}

func (host *drama2Host) Detail(ctx context.Context, site Site, id string) (Detail, error) {
	var result Detail
	err := host.get(ctx, site, "detail", url.Values{"id": {id}}, &result)
	return result, err
}

func (host *drama2Host) Play(ctx context.Context, site Site, line, id string) (PlayInfo, error) {
	if err := host.verify(ctx, site); err != nil {
		return PlayInfo{}, err
	}
	payload := map[string]any{"site": site.Key, "line": line, "episodeId": id, "direct": true}
	var result struct {
		PlayInfo
		Sniff struct {
			PageURL string `json:"pageUrl"`
			Headers map[string]string
			Scripts []string
		}
	}
	if err := host.request(ctx, "/play/resolve", nil, payload, &result); err != nil {
		return PlayInfo{}, err
	}
	switch result.Kind {
	case "sniff":
		if len(result.Sniff.Scripts) > 0 {
			return PlayInfo{}, fmt.Errorf("%w: local sniff requires scripts", errUnsupported)
		}
		result.URL, result.Headers = result.Sniff.PageURL, result.Sniff.Headers
	case "direct":
	default:
		return PlayInfo{}, errUnsupported
	}
	if result.URL == "" {
		return PlayInfo{}, fmt.Errorf("local engine returned an empty playback URL")
	}
	if strings.HasPrefix(result.URL, "/") && !strings.HasPrefix(result.URL, "//") {
		result.URL = strings.TrimSuffix(host.base, "/api/v1") + result.URL
	}
	return result.PlayInfo, nil
}

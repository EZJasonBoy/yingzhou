package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
)

type ganfanProvider struct {
	client *http.Client
	host   provider
}

func (backend ganfanProvider) accepts(site Site) bool {
	if native, ok := backend.host.(*compiledSpider); ok {
		return site.API == "csp_AppDrama2" && native.accepts(site)
	}
	return site.Key == "干饭"
}

func (backend ganfanProvider) mode() string {
	if _, native := backend.host.(*compiledSpider); native {
		return "go+compiled-spider"
	}
	if backend.host != nil {
		return "go-catalog+local-jar"
	}
	return "go-catalog"
}

func (backend ganfanProvider) origin(ctx context.Context, site Site) (string, error) {
	var settings struct {
		Host string `json:"host"`
		Site string `json:"site"`
	}
	if err := json.Unmarshal(site.Ext, &settings); err != nil {
		return "", fmt.Errorf("%w：干饭站点 ext 需要 JSON 对象", errBadInput)
	}
	address := strings.TrimSpace(settings.Host)
	if address == "" {
		var discovery struct {
			Enabled *bool  `json:"enabled"`
			Domain  string `json:"domain"`
		}
		if err := getJSON(ctx, backend.client, settings.Site, nil, &discovery); err != nil {
			return "", fmt.Errorf("读取干饭服务地址失败：%w", err)
		}
		if discovery.Enabled != nil && !*discovery.Enabled {
			return "", fmt.Errorf("干饭入口当前已停用")
		}
		address = strings.TrimSpace(discovery.Domain)
	}
	base, err := url.Parse(address)
	if err != nil || (base.Scheme != "http" && base.Scheme != "https") || base.Hostname() == "" || base.User != nil || base.RawQuery != "" || base.ForceQuery || base.Fragment != "" {
		return "", fmt.Errorf("干饭入口返回了无效的服务地址")
	}
	return strings.TrimRight(base.String(), "/"), nil
}

func (backend ganfanProvider) Home(ctx context.Context, site Site) (Home, error) {
	if site.Key != "" && !backend.accepts(site) {
		return Home{}, errUnsupported
	}
	if site.Key != "" && site.Key != "干饭" {
		return backend.host.Home(ctx, site)
	}
	home, catalogErr := backend.nativeHome(ctx, site)
	if backend.host == nil {
		return home, catalogErr
	}
	original, hostErr := backend.host.Home(ctx, site)
	if catalogErr != nil {
		if hostErr != nil {
			return Home{}, errors.Join(catalogErr, hostErr)
		}
		return original, nil
	}
	if hostErr == nil {
		home.List = original.List
	}
	return home, nil
}

func (backend ganfanProvider) nativeHome(ctx context.Context, site Site) (Home, error) {
	base, err := backend.origin(ctx, site)
	if err != nil {
		return Home{}, err
	}
	var data json.RawMessage
	if err := getJSON(ctx, backend.client, base+"/api/v3/drama/getCategory?orderBy=type_id", nil, &data); err != nil {
		return Home{}, fmt.Errorf("读取干饭分类失败：%w", err)
	}
	return parseDrama2Home(data)
}

func (backend ganfanProvider) catalogHost() (provider, error) {
	if backend.host == nil {
		return nil, fmt.Errorf("%w：干饭 v5 片单、详情及播放需要原蜘蛛会话。可用 -drama2-host 连接已激活原订阅的本机映舟引擎", errUnsupported)
	}
	return backend.host, nil
}

func (backend ganfanProvider) Category(ctx context.Context, site Site, tid string, page int, filters map[string]string) (Page, error) {
	host, err := backend.catalogHost()
	if err != nil {
		return Page{}, err
	}
	return host.Category(ctx, site, tid, page, filters)
}

func (backend ganfanProvider) Search(ctx context.Context, site Site, term string, page int) (Page, error) {
	host, err := backend.catalogHost()
	if err != nil {
		return Page{}, err
	}
	return host.Search(ctx, site, term, page)
}

func (backend ganfanProvider) Detail(ctx context.Context, site Site, id string) (Detail, error) {
	host, err := backend.catalogHost()
	if err != nil {
		return Detail{}, err
	}
	return host.Detail(ctx, site, id)
}

func (backend ganfanProvider) Play(ctx context.Context, site Site, line, id string) (PlayInfo, error) {
	host, err := backend.catalogHost()
	if err != nil {
		return PlayInfo{}, err
	}
	return host.Play(ctx, site, line, id)
}

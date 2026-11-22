package main

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"runtime"
	"strconv"
	"strings"
)

type mobileFault struct {
	status  int
	code    string
	message string
}

func (fault *mobileFault) Error() string { return fault.message }

var errMobileNoConfig = &mobileFault{409, "NO_CONFIG", "尚未激活订阅"}
var errMobileNotFound = &mobileFault{404, "NOT_FOUND", "未找到请求的项目"}

func mobileError(writer http.ResponseWriter, status int, code, message string) {
	writeJSON(writer, status, map[string]any{"error": map[string]string{"code": code, "message": message}})
}

type mobileAction func(*http.Request) (any, error)

func mobileHandler(status int, action mobileAction) http.HandlerFunc {
	return func(writer http.ResponseWriter, request *http.Request) {
		result, err := action(request)
		if err == nil {
			if status == http.StatusNoContent {
				writer.WriteHeader(status)
			} else {
				writeJSON(writer, status, result)
			}
			return
		}
		var fault *mobileFault
		switch {
		case errors.As(err, &fault):
			mobileError(writer, fault.status, fault.code, fault.message)
		case errors.Is(err, errBadInput):
			mobileError(writer, 400, "BAD_REQUEST", err.Error())
		case errors.Is(err, errUnsupported):
			mobileError(writer, 501, "UNSUPPORTED_SITE", err.Error())
		case errors.Is(err, context.DeadlineExceeded):
			mobileError(writer, 504, "SITE_TIMEOUT", "站点响应超时")
		default:
			mobileError(writer, 502, "SITE_ERROR", "Go 适配器未能从站点取得结果")
		}
	}
}

func mobileBody(request *http.Request, destination any) error {
	if err := readJSON(request.Body, destination); err != nil {
		return &mobileFault{400, "BAD_REQUEST", "需要有效的 JSON 请求体"}
	}
	return nil
}

func (service *mobileEngine) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	host := request.Host
	if name, _, err := net.SplitHostPort(host); err == nil {
		host = name
	}
	origin := request.Header.Get("Origin")
	if !isLoopback(strings.Trim(host, "[]")) || (origin != "" && !strings.EqualFold(origin, "http://"+request.Host)) || request.Header.Get("Sec-Fetch-Site") == "cross-site" {
		mobileError(writer, 403, "FORBIDDEN", "仅接受本机应用请求")
		return
	}
	request.Body = http.MaxBytesReader(writer, request.Body, 256<<10)
	if service.serveMobileExtras(writer, request) {
		return
	}
	service.mux.ServeHTTP(writer, request)
}

func mobileValue(value any) mobileAction {
	return func(*http.Request) (any, error) { return value, nil }
}

func (service *mobileEngine) mobileRoutes() *http.ServeMux {
	mux := http.NewServeMux()
	register := func(pattern string, status int, action mobileAction) {
		mux.HandleFunc(pattern, mobileHandler(status, action))
	}
	register("GET /api/v1/info", 200, mobileValue(map[string]any{
		"name": "yingzhou-go", "version": "0.4.1468250", "protocol": 1, "platform": runtime.GOOS,
		"capabilities": map[string]bool{"go": true, "jar": false, "js": false, "py": false, "sniff": false},
	}))
	register("GET /api/v1/settings", 200, mobileValue(map[string]any{"streamCache": false}))
	register("PUT /api/v1/settings", 501, func(*http.Request) (any, error) {
		return nil, &mobileFault{501, "UNSUPPORTED", "此 Go 引擎暂不支持修改网络与缓存设置"}
	})
	register("GET /api/v1/network", 200, mobileValue(map[string]any{}))
	register("GET /api/v1/stream-cache", 200, mobileValue(map[string]bool{"available": false}))
	register("GET /api/v1/live", 200, mobileValue([]any{}))
	register("GET /api/v1/subscriptions", 200, func(*http.Request) (any, error) { return service.snapshot().Subscriptions, nil })
	register("POST /api/v1/subscriptions", 201, func(request *http.Request) (any, error) {
		var body struct{ URL, Name string }
		if err := mobileBody(request, &body); err != nil {
			return nil, err
		}
		return service.addSubscription(body.URL, body.Name)
	})
	register("PUT /api/v1/subscriptions/{id}", 200, func(request *http.Request) (any, error) {
		var body struct{ Name string }
		if err := mobileBody(request, &body); err != nil {
			return nil, err
		}
		return service.changeSubscription(request.PathValue("id"), &body.Name)
	})
	register("DELETE /api/v1/subscriptions/{id}", 204, func(request *http.Request) (any, error) {
		return service.changeSubscription(request.PathValue("id"), nil)
	})
	register("POST /api/v1/subscriptions/{id}/activate", 200, func(request *http.Request) (any, error) {
		if request.Body != http.NoBody && request.ContentLength != 0 {
			var body struct{ Repo string }
			if err := mobileBody(request, &body); err != nil {
				return nil, err
			}
			if body.Repo != "" {
				return nil, &mobileFault{422, "UNSUPPORTED", "Go 引擎目前支持单订阅地址"}
			}
		}
		return service.activate(request.Context(), request.PathValue("id"))
	})
	register("GET /api/v1/config", 200, func(*http.Request) (any, error) { return service.summary() })
	register("POST /api/v1/config/reload", 200, func(request *http.Request) (any, error) { return service.activate(request.Context(), "") })
	register("GET /api/v1/sites", 200, service.listSites)
	register("GET /api/v1/sites/{key}/{action}", 200, service.browse)
	register("POST /api/v1/play/resolve", 200, service.resolve)
	return mux
}

func mobileEnabled(flag *int) bool { return flag == nil || *flag != 0 }

func (service *mobileEngine) listSites(*http.Request) (any, error) {
	active := service.activeEngine()
	if active == nil {
		return nil, errMobileNoConfig
	}
	sites := make([]map[string]any, 0, len(active.converted.Sites))
	for _, site := range active.converted.Sites {
		name := site.Name
		if name == "" {
			name = site.Key
		}
		sites = append(sites, map[string]any{
			"key": site.Key, "name": name, "runtime": "go", "type": 3,
			"searchable": mobileEnabled(site.Searchable), "quickSearch": mobileEnabled(site.QuickSearch),
			"filterable": mobileEnabled(site.Filterable), "changeable": mobileEnabled(site.Changeable),
		})
	}
	return sites, nil
}

func (service *mobileEngine) route(key string) (Site, provider, error) {
	active := service.activeEngine()
	if active == nil {
		return Site{}, nil, errMobileNoConfig
	}
	backend := active.routes[key]
	if backend == nil {
		return Site{}, nil, errMobileNotFound
	}
	return active.sites[key], backend, nil
}

func mobileCards(key string, cards []Card) []Card {
	result := make([]Card, len(cards))
	copy(result, cards)
	for index := range result {
		result[index].Site = key
	}
	return result
}

func (service *mobileEngine) browse(request *http.Request) (any, error) {
	site, backend, err := service.route(request.PathValue("key"))
	if err != nil {
		return nil, err
	}
	ctx, query := request.Context(), request.URL.Query()
	switch request.PathValue("action") {
	case "home":
		home, err := backend.Home(ctx, site)
		if home.Classes == nil {
			home.Classes = []Class{}
		}
		home.List = mobileCards(site.Key, home.List)
		return home, err
	case "category", "search":
		page := 1
		if query.Has("pg") {
			page, err = strconv.Atoi(query.Get("pg"))
			if err != nil || page < 1 {
				return nil, errBadInput
			}
		}
		var result Page
		if request.PathValue("action") == "search" {
			term := strings.TrimSpace(query.Get("wd"))
			if term == "" {
				return nil, errBadInput
			}
			result, err = backend.Search(ctx, site, term, page)
		} else {
			filters := map[string]string{}
			if !query.Has("tid") || (query.Has("f") && (json.Unmarshal([]byte(query.Get("f")), &filters) != nil || filters == nil)) {
				return nil, errBadInput
			}
			result, err = backend.Category(ctx, site, query.Get("tid"), page, filters)
		}
		result.List = mobileCards(site.Key, result.List)
		return result, err
	case "detail":
		id := query.Get("id")
		if id == "" {
			return nil, errBadInput
		}
		detail, err := backend.Detail(ctx, site, id)
		detail.Site = site.Key
		if detail.ID == "" {
			detail.ID = id
		}
		return detail, err
	default:
		return nil, errMobileNotFound
	}
}

func (service *mobileEngine) resolve(request *http.Request) (any, error) {
	var body struct{ Site, Line, EpisodeID string }
	if err := mobileBody(request, &body); err != nil {
		return nil, err
	}
	if body.Site == "" || body.EpisodeID == "" {
		return nil, errBadInput
	}
	site, backend, err := service.route(body.Site)
	if err != nil {
		return nil, err
	}
	play, err := backend.Play(request.Context(), site, body.Line, body.EpisodeID)
	if err != nil {
		return nil, err
	}
	if _, err := mobileSource(play.URL); err != nil {
		return nil, &mobileFault{502, "SITE_BAD_RESULT", "站点未返回有效的媒体地址"}
	}
	if play.Kind == "sniff" {
		return map[string]any{"kind": "sniff", "sniff": map[string]string{"pageUrl": play.URL}, "headers": play.Headers}, nil
	}
	if play.Kind != "direct" {
		return nil, errUnsupported
	}
	return map[string]any{"kind": "direct", "url": play.URL, "headers": play.Headers, "format": play.Format}, nil
}

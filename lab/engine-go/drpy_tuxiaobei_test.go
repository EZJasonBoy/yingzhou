package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"
)

type drpyTransport func(*http.Request) (*http.Response, error)

func (transport drpyTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	return transport(request)
}

func drpyFixture(t *testing.T, fixture func(*http.Request) (int, string)) *drpyProvider {
	t.Helper()
	client := &http.Client{Transport: drpyTransport(func(request *http.Request) (*http.Response, error) {
		if request.URL.Scheme != "https" || request.URL.Host != "www.tuxiaobei.com" || request.Header.Get("Cookie") != "" || request.Header.Get("Referer") != "" || request.Header.Get("User-Agent") != drpyUA {
			t.Fatalf("unexpected request host or headers: %s", request.URL.Host)
		}
		status, body := fixture(request)
		return &http.Response{StatusCode: status, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(body)), Request: request}, nil
	})}
	return newDrpyProvider(client)
}

func TestDrpyAcceptsOnlyKnownTemplate(t *testing.T) {
	provider := newDrpyProvider(nil)
	encoded := json.RawMessage(`"./js/兔小贝.js"`)
	if !provider.accepts(Site{Type: 3, API: drpyLoaderAPI, Ext: encoded}) {
		t.Fatal("published template not recognized")
	}
	for _, site := range []Site{
		{Type: 4, API: drpyLoaderAPI, Ext: encoded},
		{Type: 3, API: "https://unrelated.example/api/drpy2.min.js", Ext: encoded},
		{Type: 3, API: drpyLoaderAPI, Ext: json.RawMessage(`"./js/其他.js"`)},
		{Type: 3, API: drpyLoaderAPI, Ext: json.RawMessage(`"https://unrelated.example/兔小贝.js"`)},
		{Type: 3, API: drpyLoaderAPI, Ext: json.RawMessage(`{"url":"./js/兔小贝.js"}`)},
	} {
		if provider.accepts(site) {
			t.Fatalf("unexpected template match %s", site.Ext)
		}
	}
}

func TestDrpyPublicCatalogAndPlayer(t *testing.T) {
	const image = "https://resource-cdn.tuxiaobei.com/video/cover.jpg"
	const media = "https://resource-cdn.tuxiaobei.com/video/sample.mp4?key=1&part=2"
	const resultItem = `<div class="items"><div class="pic"><a href="/play/1177"><mip-img src="` + image + `"></mip-img></a></div><div class="text"><a href="/play/1177"><p class="title">萤<em>火</em>虫</p><p class="data"><span class="time">02:04</span></p></a></div></div>`
	const homeItem = `<li><a href="/play/1177"><p class="img"><mip-img src="` + image + `"></mip-img></p><p class="tit">萤火虫</p></a></li>`
	provider := drpyFixture(t, func(request *http.Request) (int, string) {
		switch request.URL.Path {
		case "/animate":
			return 200, `<ul class="animateTab list-box">` + homeItem + `</ul><ul class="animateTab list-box on">` + homeItem + homeItem + `</ul>`
		case "/list/mip-data":
			params := request.URL.Query()
			if params.Get("typeId") != "2" || params.Get("page") != "1" || !params.Has("callback") {
				t.Fatalf("category params %s", params)
			}
			return 200, `({"status":0,"data":{"items":[{"video_id":1177,"name":"萤火虫","image":"` + image + `","duration_string":"02:04"}]}});`
		case "/search/index":
			if request.URL.Query().Get("key") != "萤火虫 &" {
				t.Fatal("search query was not preserved")
			}
			return 200, `<script>if (1<2) {}</script><div class="list-con">` + resultItem + `</div>` + resultItem
		case "/play/1177":
			return 200, `<mip-search-video poster="` + image + `" id="videoWrap" video-src="https://resource-cdn.tuxiaobei.com/video/sample.mp4?key=1&amp;part=2"></mip-search-video><div class="title"><h1>萤火虫</h1></div>`
		default:
			t.Fatalf("unexpected route %s", request.URL.Path)
			return 404, ""
		}
	})
	ctx := context.Background()
	site := Site{Key: "儿童"}
	home, err := provider.Home(ctx, site)
	if err != nil || len(home.Classes) != 4 || home.Classes[3].Name != "启蒙" || len(home.List) != 1 || home.List[0].ID != "1177" {
		t.Fatalf("home = %+v, %v", home, err)
	}
	category, err := provider.Category(ctx, site, "2", 1, nil)
	if err != nil || category.PageCount != 1 || category.Total != 1 || len(category.List) != 1 || category.List[0].Remarks != "02:04" {
		t.Fatalf("category = %+v, %v", category, err)
	}
	search, err := provider.Search(ctx, site, "萤火虫 &", 1)
	if err != nil || len(search.List) != 1 || search.List[0] != category.List[0] {
		t.Fatalf("search = %+v, %v", search, err)
	}
	detail, err := provider.Detail(ctx, site, "1177")
	if err != nil || detail.Name != "萤火虫" || detail.Pic != image || len(detail.Lines) != 1 || len(detail.Lines[0].Episodes) != 1 || detail.Lines[0].Episodes[0].ID != "1177" {
		t.Fatalf("detail = %+v, %v", detail, err)
	}
	info, err := provider.Play(ctx, site, detail.Lines[0].Name, "1177")
	if err != nil || info.Kind != "direct" || info.Format != "mp4" || info.URL != media {
		t.Fatalf("play = %+v, %v", info, err)
	}
}

func TestDrpyEmptyAndErrorResponses(t *testing.T) {
	ctx, site := context.Background(), Site{Key: "儿童"}
	provider := drpyFixture(t, func(request *http.Request) (int, string) {
		switch request.URL.Path {
		case "/list/mip-data":
			return 200, `({"status":403,"data":{"items":[]}})`
		case "/search/index":
			if request.URL.Query().Get("key") == "empty" {
				return 200, `<div class="list-con"></div>`
			}
			return 200, `<html>Service unavailable</html>`
		case "/play/1177":
			return 200, `<h1>萤火虫</h1><div id="videoWrap" video-src="https://unrelated.example/clip.mp4"></div>`
		default:
			return 404, ``
		}
	})
	if _, err := provider.Category(ctx, site, "2", 1, nil); err == nil || !strings.Contains(err.Error(), "403") {
		t.Fatalf("missing upstream status: %v", err)
	}
	if _, err := provider.Category(ctx, site, "../play", 1, nil); !errors.Is(err, errBadInput) {
		t.Fatalf("category ID: %v", err)
	}
	if _, err := provider.Play(ctx, site, "", "https://unrelated.example/clip.mp4"); !errors.Is(err, errBadInput) {
		t.Fatalf("episode ID: %v", err)
	}
	if _, err := provider.Play(ctx, site, "", "1177"); err == nil {
		t.Fatal("returned third-party playback")
	}
	if result, err := provider.Search(ctx, site, "empty", 1); err != nil || len(result.List) != 0 {
		t.Fatalf("empty search: %+v, %v", result, err)
	}
	if _, err := provider.Search(ctx, site, "broken", 1); err == nil {
		t.Fatal("accepted non-catalog page as an empty result")
	}
	if result, err := provider.Search(ctx, site, "broken", 2); err != nil || len(result.List) != 0 || result.PageCount != 1 {
		t.Fatalf("repeated first search results: %+v, %v", result, err)
	}
}

func TestDrpySearchRedirectsOnlyWithinWebsite(t *testing.T) {
	for _, sample := range []struct {
		target string
		ok     bool
	}{
		{"/v2024/search?key=abc", true},
		{"https://www.tuxiaobei.com:443/v2024/search", true},
		{"https://example.org/v2024/search", false},
		{"http://www.tuxiaobei.com/v2024/search", false},
		{"https://www.tuxiaobei.com:444/v2024/search", false},
		{"https://name@www.tuxiaobei.com/v2024/search", false},
		{"/search/index", false},
	} {
		requests := 0
		provider := newDrpyProvider(&http.Client{Transport: drpyTransport(func(request *http.Request) (*http.Response, error) {
			requests++
			reply := &http.Response{StatusCode: 302, Header: http.Header{"Location": {sample.target}}, Body: http.NoBody, Request: request}
			if request.URL.Path != "/search/index" {
				if !sample.ok || request.Header.Get("Referer") != "" {
					t.Fatalf("unsafe redirect to %s", sample.target)
				}
				reply.StatusCode, reply.Body = 200, io.NopCloser(strings.NewReader(`<div class="list-con"></div>`))
			}
			return reply, nil
		})})
		_, err := provider.Search(context.Background(), Site{Key: "儿童"}, "abc", 1)
		if (err == nil) != sample.ok || requests > 4 {
			t.Fatalf("redirect=%s requests=%d err=%v", sample.target, requests, err)
		}
	}
}

func TestDrpyLiveOfficialSite(t *testing.T) {
	if os.Getenv("YINGZHOU_TEST_DRPY_LIVE") != "1" {
		t.Skip("set YINGZHOU_TEST_DRPY_LIVE=1 to test the public website")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	provider := newDrpyProvider(&http.Client{Timeout: 16 * time.Second})
	site := Site{Key: "儿童"}
	home, err := provider.Home(ctx, site)
	if err != nil || len(home.List) == 0 {
		t.Fatalf("no recommendations: %v", err)
	}
	category, err := provider.Category(ctx, site, "2", 1, nil)
	if err != nil || len(category.List) == 0 {
		t.Fatalf("empty song category: %v", err)
	}
	for _, title := range []string{"萤火虫", "洗白白"} {
		search, err := provider.Search(ctx, site, title, 1)
		if err != nil || len(search.List) == 0 {
			t.Fatalf("search did not find %s: %v", title, err)
		}
		id := ""
		for _, card := range search.List {
			if card.Name == title {
				id = card.ID
				break
			}
		}
		if id == "" {
			t.Fatalf("missing exact search match for %s", title)
		}
		detail, err := provider.Detail(ctx, site, id)
		if err != nil || detail.Name != title || len(detail.Lines) == 0 {
			t.Fatalf("unexpected detail for %s: %v", title, err)
		}
		info, err := provider.Play(ctx, site, detail.Lines[0].Name, id)
		if err != nil || info.Kind != "direct" || info.Format != "mp4" {
			t.Fatalf("unexpected playback for %s: %v", title, err)
		}
		t.Logf("%s: id=%s, %d search hits, %s", title, id, len(search.List), info.Format)
	}
	t.Logf("%d classes, %d recommendations, %d song entries", len(home.Classes), len(home.List), len(category.List))
}

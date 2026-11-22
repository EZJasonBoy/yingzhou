package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestBiliCatalogAndPublicVideo(t *testing.T) {
	const bvid = "BV1ME411Y71o"
	const media = "https://media.example/clip.mp4?token=example"
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.Header.Get("Cookie") != "" {
			t.Error("unexpected subscription cookie on an anonymous request")
		}
		query := request.URL.Query()
		switch request.URL.Path {
		case "/catalog":
			fmt.Fprint(writer, `{"class":[{"type_id":"一年级语文","type_name":"一年级"}],"filters":{"一年级语文":[{"key":"tid","name":"教材","value":[{"n":"全部","v":"0"},{"n":"人教版","v":"人教版一年级语文"}]}]}}`)
		case "/x/web-interface/search/type":
			if query.Get("keyword") != "人教版一年级语文" || query.Get("order") != "click" || query.Get("duration") != "2" || query.Get("page") != "2" || query.Get("search_type") != "video" {
				t.Errorf("unexpected search query %q", request.URL.RawQuery)
			}
			fmt.Fprintf(writer, `{"code":0,"data":{"numResults":45,"numPages":3,"result":[{"bvid":%q,"title":"<em class=\"keyword\">语文</em> &amp; 阅读","pic":"//i.example/poster.jpg","author":"老师","duration":"1:00"}]}}`, bvid)
		case "/x/player/pagelist":
			if query.Get("bvid") != bvid {
				t.Errorf("unexpected video ID %q", query.Get("bvid"))
			}
			fmt.Fprint(writer, `{"code":0,"data":[{"cid":10,"page":1,"part":"第一课"},{"cid":4100000123,"page":2,"part":"第二课"}]}`)
		case "/x/player/playurl":
			if query.Get("cid") != "4100000123" || query.Get("bvid") != bvid || query.Get("fnval") != "1" {
				t.Errorf("unexpected play query %q", request.URL.RawQuery)
			}
			fmt.Fprintf(writer, `{"code":0,"data":{"format":"mp4","durl":[{"url":%q}]}}`, media)
		default:
			t.Errorf("unexpected URL %s", request.URL.Path)
			http.NotFound(writer, request)
		}
	}))
	defer server.Close()
	provider := newBiliProvider(server.Client())
	provider.apiBase = server.URL
	ctx := context.Background()
	site := Site{Key: "csp_小学", API: "csp_Bili", Ext: json.RawMessage(fmt.Sprintf(`{"json":%q,"cookie":"do-not-forward"}`, server.URL+"/catalog"))}
	home, err := provider.Home(ctx, site)
	if err != nil || len(home.Classes) != 1 || len(home.Filters["一年级语文"]) != 1 || home.Filters["一年级语文"][0].Values[1].Value != "人教版一年级语文" {
		t.Fatalf("home = %+v, err = %v", home, err)
	}
	page, err := provider.Category(ctx, site, home.Classes[0].ID, 2, map[string]string{"tid": "人教版一年级语文", "order": "click", "duration": "2"})
	if err != nil || page.Page != 2 || page.PageCount != 3 || page.Total != 45 || len(page.List) != 1 || page.List[0].Name != "语文 & 阅读" || page.List[0].Pic != "https://i.example/poster.jpg" {
		t.Fatalf("page = %+v, err = %v", page, err)
	}
	detail, err := provider.Detail(ctx, site, page.List[0].ID)
	if err != nil || detail.Name != page.List[0].Name || len(detail.Lines) != 1 || len(detail.Lines[0].Episodes) != 2 || detail.Lines[0].Episodes[1].Name != "第二课" {
		t.Fatalf("detail = %+v, err = %v", detail, err)
	}
	play, err := provider.Play(ctx, site, detail.Lines[0].Name, detail.Lines[0].Episodes[1].ID)
	if err != nil || play.URL != media || play.Kind != "direct" || play.Headers["Referer"] != "https://www.bilibili.com/video/"+bvid+"/" || play.Headers["User-Agent"] == "" {
		t.Fatalf("play = %+v, err = %v", play, err)
	}
}

func TestBiliDefaultFilterKeepsKeywordAndEmptySearch(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		query := request.URL.Query()
		if query.Get("keyword") != "儿童英语" || query.Has("tid") || query.Has("order") || query.Has("duration") || query.Get("page") != "1" {
			t.Errorf("unexpected default search %s", request.URL.RawQuery)
		}
		fmt.Fprint(writer, `{"code":0,"data":{"numResults":0,"numPages":0,"result":[]}}`)
	}))
	defer server.Close()
	provider := newBiliProvider(server.Client())
	provider.apiBase = server.URL
	page, err := provider.Category(context.Background(), Site{}, "儿童英语", 0, map[string]string{"tid": "0", "order": "0", "duration": "0"})
	if err != nil || len(page.List) != 0 || page.PageCount != 0 {
		t.Fatalf("empty result = %+v, err = %v", page, err)
	}
	if _, err := provider.Category(context.Background(), Site{}, "peizhi", 1, nil); !errors.Is(err, errUnsupported) {
		t.Fatalf("login category = %v", err)
	}
}

func TestBiliRejectsMissingOrRestrictedMedia(t *testing.T) {
	for _, test := range []struct{ name, reply, want string }{
		{"upstream status", `{"code":-10403,"message":"地区限制"}`, "-10403：地区限制"},
		{"missing status", `{"data":{}}`, "缺少状态码"},
		{"DASH only", `{"code":0,"data":{"dash":{"video":[{}]}}}`, "未返回可直接播放"},
		{"multiple segments", `{"code":0,"data":{"durl":[{"url":"https://one.example"},{"url":"https://two.example"}]}}`, "2 段媒体"},
		{"invalid address", `{"code":0,"data":{"durl":[{"url":"file:///etc/hosts"}]}}`, "缺少有效"},
	} {
		t.Run(test.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) { fmt.Fprint(writer, test.reply) }))
			defer server.Close()
			provider := newBiliProvider(server.Client())
			provider.apiBase = server.URL
			if info, err := provider.Play(context.Background(), Site{}, "", "BV1ME411Y71o:10"); err == nil || info.URL != "" || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("got %+v, %v", info, err)
			}
		})
	}
}

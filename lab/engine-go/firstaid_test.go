package main

import (
	"context"
	"errors"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"
)

const firstAidTestArticle = firstAidOrigin + "/jijiu/article/944A17mma.html"
const firstAidTestMovie = "https://vod.youlai.cn/demo/first.mp4?part=1&quality=sd"

func firstAidFixture(t *testing.T, respond func(*http.Request) (int, string)) *firstAidProvider {
	t.Helper()
	return newFirstAidProvider(&http.Client{Transport: drpyTransport(func(request *http.Request) (*http.Response, error) {
		if !firstAidHost(request.URL, "m.youlai.cn") || request.Header.Get("User-Agent") != firstAidUA {
			t.Fatalf("unexpected outgoing request: %s", request.URL.Host)
		}
		status, body := respond(request)
		return &http.Response{Request: request, StatusCode: status, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(body))}, nil
	})})
}

func TestFirstAidCatalogAndVideo(t *testing.T) {
	var groups strings.Builder
	for index := range firstAidClasses {
		groups.WriteString(`<img class="block100" src="//static.cnkang.com/` + strconv.Itoa(index) + `.png"><div class="jj-title-li">`)
		if index == 0 {
			groups.WriteString(`<li class="list-br3"><a href="/jijiu/article/944A17mma.html"><div>人工<em>呼吸</em></div></a></li><li class="list-br3"><a href="https://outside.invalid/jijiu/article/a.html">别站</a></li>`)
		}
		groups.WriteString(`</div>`)
	}
	provider := firstAidFixture(t, func(request *http.Request) (int, string) {
		switch request.URL.Path {
		case "/jijiu":
			return 200, groups.String()
		case "/cse/search":
			if request.URL.Query().Get("q") != "人工 & 呼吸" || len(request.URL.Query()) != 1 {
				t.Fatalf("query = %s", request.URL.RawQuery)
			}
			return 200, `<div class="search-video-list"><div class="search-video-li list-br2"><a href="/video/article/70E14B00su.html"><dt class="logo-bg"><img src="//file.youlai.cn/a.jpg"></dt><dd><h5 class="line-clamp1">什么是人工呼吸</h5></dd></a></div></div>`
		case "/jijiu/article/944A17mma.html":
			return 200, `<h1>别的标题</h1><div class="video-cover list-flex-in"><img src="//file.youlai.cn/a.jpg"></div><h2 class="video-title h1-title">人工呼吸法</h2><span class="doc-name">医生甲</span><article class="img-text-con"><p>第一段</p><p>第二段</p></article><video id="video" controls><source src="//vod.youlai.cn/demo/first.mp4?part=1&amp;quality=sd"></video>`
		case "/video/article/70E14B00su.html":
			return 200, `<h1 class="title--demo">什么是人工呼吸</h1><video id="video" src="//vod.youlai.cn/demo/second.mp4" poster="//file.youlai.cn/second.jpg" controls></video>` + "<p>预\x00防</p>"
		default:
			t.Fatalf("unexpected path %s", request.URL.Path)
			return 404, ""
		}
	})
	ctx, site := context.Background(), Site{Key: "csp_FirstAid"}
	home, err := provider.Home(ctx, site)
	if err != nil || len(home.Classes) != 8 || len(home.List) != 0 || home.Classes[7] != (Class{"jijiu|7", "意外事故"}) {
		t.Fatalf("home = %+v, %v", home, err)
	}
	category, err := provider.Category(ctx, site, "jijiu|0", 1, nil)
	if err != nil || category.Total != 1 || category.PageCount != 1 || len(category.List) != 1 || category.List[0] != (Card{Site: site.Key, ID: firstAidTestArticle, Name: "人工呼吸", Pic: "https://static.cnkang.com/0.png"}) {
		t.Fatalf("category = %+v, %v", category, err)
	}
	later, err := provider.Category(ctx, site, "jijiu|0", 2, nil)
	if err != nil || later.PageCount != 1 || len(later.List) != 0 {
		t.Fatalf("unexpected repeated page = %+v, %v", later, err)
	}
	search, err := provider.Search(ctx, site, "人工 & 呼吸", 1)
	if err != nil || search.Total != 1 || search.List[0].Name != "什么是人工呼吸" || search.List[0].Pic != "https://file.youlai.cn/a.jpg" {
		t.Fatalf("search = %+v, %v", search, err)
	}
	first, err := provider.Detail(ctx, site, category.List[0].ID)
	if err != nil || first.Name != "人工呼吸法" || first.Actor != "医生甲" || first.Content != "第一段 第二段" || first.Pic != "https://file.youlai.cn/a.jpg" || len(first.Lines) != 1 || len(first.Lines[0].Episodes) != 1 || first.Lines[0].Episodes[0].ID != firstAidTestMovie {
		t.Fatalf("detail = %+v, %v", first, err)
	}
	second, err := provider.Detail(ctx, site, search.List[0].ID)
	if err != nil || second.Name != "什么是人工呼吸" || len(second.Lines) != 1 || second.Lines[0].Episodes[0].ID != "https://vod.youlai.cn/demo/second.mp4" {
		t.Fatalf("search detail = %+v, %v", second, err)
	}
	info, err := provider.Play(ctx, site, first.Lines[0].Name, first.Lines[0].Episodes[0].ID)
	if err != nil || info.Kind != "direct" || info.URL != firstAidTestMovie || info.Format != "mp4" || info.Headers["User-Agent"] != firstAidUA {
		t.Fatalf("play = %+v, %v", info, err)
	}
}

func TestFirstAidEmptyAndInvalidResponses(t *testing.T) {
	status, body := 200, `<div id="submitBtn"></div>`
	provider := firstAidFixture(t, func(*http.Request) (int, string) { return status, body })
	ctx, site := context.Background(), Site{Key: "csp_FirstAid"}
	if empty, err := provider.Search(ctx, site, "没有匹配", 1); err != nil || len(empty.List) != 0 {
		t.Fatalf("empty = %+v, %v", empty, err)
	}
	body = `<div>上游服务异常</div>`
	if _, err := provider.Search(ctx, site, "测试", 1); err == nil {
		t.Fatal("unrecognized upstream page looked like zero matches")
	}
	if _, err := provider.Category(ctx, site, "jijiu|1", 1, nil); err == nil {
		t.Fatal("missing category sections looked like an empty page")
	}
	status = 503
	if _, err := provider.Detail(ctx, site, firstAidTestArticle); err == nil || !strings.Contains(err.Error(), "503") {
		t.Fatalf("status = %v", err)
	}
	status, body = 200, `<h2 class="video-title h1-title">未提供视频</h2><video id="video" src="https://elsewhere.invalid/test.mp4"></video>`
	if detail, err := provider.Detail(ctx, site, firstAidTestArticle); err != nil || len(detail.Lines) != 0 {
		t.Fatalf("unavailable video = %+v, %v", detail, err)
	}
	for _, id := range []string{"https://127.0.0.1/jijiu/article/a.html", "https://id@m.youlai.cn/jijiu/article/a.html", "https://m.youlai.cn:444/video/article/a.html", "/jijiu/article/a%2fb.html", "http://m.youlai.cn/video/article/a.html"} {
		if _, err := provider.Detail(ctx, site, id); !errors.Is(err, errBadInput) {
			t.Fatalf("untrusted article %s = %v", id, err)
		}
	}
	if _, err := provider.Category(ctx, site, "jijiu|0", 1, map[string]string{"cateId": "elsewhere"}); !errors.Is(err, errBadInput) {
		t.Fatalf("invalid category filter = %v", err)
	}
	for _, media := range []string{"https://vod.youlai.cn.invalid/movie.mp4", "https://vod.youlai.cn:444/movie.mp4", "https://vod.youlai.cn/watch", "http://vod.youlai.cn/movie.mp4"} {
		if _, err := provider.Play(ctx, site, firstAidLine, media); !errors.Is(err, errBadInput) {
			t.Fatalf("untrusted media %s = %v", media, err)
		}
	}
}

func TestFirstAidLiveOfficialSite(t *testing.T) {
	if os.Getenv("YINGZHOU_TEST_FIRSTAID_LIVE") != "1" {
		t.Skip("set YINGZHOU_TEST_FIRSTAID_LIVE=1 to query the official catalog")
	}
	provider := newFirstAidProvider(&http.Client{Timeout: 20 * time.Second})
	ctx, site := context.Background(), Site{Key: "csp_FirstAid"}
	home, _ := provider.Home(ctx, site)
	category, err := provider.Category(ctx, site, home.Classes[0].ID, 1, nil)
	if err != nil || len(category.List) == 0 {
		t.Fatalf("official category = %d, %v", len(category.List), err)
	}
	item := category.List[0]
	hits, err := provider.Search(ctx, site, item.Name, 1)
	if err != nil || len(hits.List) == 0 {
		t.Fatalf("official search = %d, %v", len(hits.List), err)
	}
	for _, entry := range []Card{item, hits.List[len(hits.List)-1]} {
		detail, err := provider.Detail(ctx, site, entry.ID)
		if err != nil || len(detail.Lines) != 1 || len(detail.Lines[0].Episodes) != 1 {
			t.Fatalf("official detail %s: %d lines, %v", entry.Name, len(detail.Lines), err)
		}
		info, err := provider.Play(ctx, site, detail.Lines[0].Name, detail.Lines[0].Episodes[0].ID)
		if err != nil || info.Format != "mp4" {
			t.Fatalf("official play %s: %s, %v", entry.Name, info.Format, err)
		}
		t.Logf("%d classes, %d entries, %d search hits, %q → %q: %s", len(home.Classes), len(category.List), len(hits.List), entry.Name, detail.Name, info.Format)
	}
}

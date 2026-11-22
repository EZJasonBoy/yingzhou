package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

type t4TestProvider struct{ provider }

func (t4TestProvider) Home(context.Context, Site) (Home, error) {
	return Home{Classes: []Class{{ID: "m", Name: "电影"}}, Filters: map[string][]Filter{"m": {{Key: "genre", Name: "类型", Values: []FilterValue{{Name: "喜剧", Value: "c"}}}}}, List: []Card{{ID: "123", Name: "片名", Tag: "folder"}}}, nil
}

func (t4TestProvider) Category(_ context.Context, _ Site, tid string, page int, filters map[string]string) (Page, error) {
	return Page{Page: page, PageCount: 5, Total: 42, List: []Card{{ID: tid, Name: filters["genre"]}}}, nil
}

func (t4TestProvider) Search(_ context.Context, _ Site, query string, page int) (Page, error) {
	return Page{Page: page, List: []Card{{Name: query}}}, nil
}

func (t4TestProvider) Detail(_ context.Context, _ Site, id string) (Detail, error) {
	return Detail{ID: id, Lines: []Line{{Name: "主$$$线", Episodes: []Episode{{ID: "url#a$$$b$雪", Name: "第一#集$"}}}, {Name: "备", Episodes: []Episode{{ID: "b", Name: "单集"}}}}}, nil
}

func (t4TestProvider) Play(_ context.Context, _ Site, line, id string) (PlayInfo, error) {
	return PlayInfo{Kind: "direct", URL: line + ":" + id, Headers: map[string]string{"Referer": "example"}}, nil
}

func TestType4Actions(t *testing.T) {
	call := func(form url.Values, post bool) map[string]any {
		t.Helper()
		var request *http.Request
		if post {
			request = httptest.NewRequest(http.MethodPost, "/", strings.NewReader(form.Encode()))
			request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		} else {
			request = httptest.NewRequest(http.MethodGet, "/?"+form.Encode(), nil)
		}
		writer := httptest.NewRecorder()
		serveType4(writer, request, Site{}, t4TestProvider{})
		var result map[string]any
		if writer.Code != 200 || json.Unmarshal(writer.Body.Bytes(), &result) != nil {
			t.Fatalf("unexpected response %d %s", writer.Code, writer.Body.String())
		}
		return result
	}
	first := func(data map[string]any, key string) map[string]any { return data[key].([]any)[0].(map[string]any) }
	home := call(url.Values{"filter": {"true"}}, false)
	groups := home["filters"].(map[string]any)
	if first(home, "class")["type_id"] != "m" || first(home, "list")["vod_tag"] != "folder" || first(first(groups, "m"), "value")["n"] != "喜剧" {
		t.Fatal(home)
	}
	ext := base64.StdEncoding.EncodeToString([]byte(`{"genre":"喜剧"}`))
	page := call(url.Values{"t": {"m"}, "pg": {"2"}, "ext": {ext}, "extend": {strings.Repeat("长", 1024)}}, true)
	if page["page"] != float64(2) || page["pagecount"] != float64(5) || page["total"] != float64(42) || first(page, "list")["vod_name"] != "喜剧" {
		t.Fatal(page)
	}
	search := call(url.Values{"wd": {"我的电影"}, "pg": {"3"}}, false)
	if search["page"] != float64(3) || first(search, "list")["vod_name"] != "我的电影" {
		t.Fatal(search)
	}
	detail := first(call(url.Values{"ids": {"movie,01"}}, false), "list")
	lines := strings.Split(detail["vod_play_url"].(string), "$$$")
	if detail["vod_id"] != "movie,01" || len(lines) != 2 || detail["vod_play_from"] != "主＄＄＄线$$$备" || strings.Contains(lines[0], "#") {
		t.Fatal(detail)
	}
	name, packed, ok := strings.Cut(lines[0], "$")
	if !ok || name != "第一＃集＄" {
		t.Fatal(lines)
	}
	play := call(url.Values{"play": {packed}, "flag": {"主＄＄＄线"}}, false)
	if play["url"] != "主$$$线:url#a$$$b$雪" || play["parse"] != float64(0) || play["header"].(map[string]any)["Referer"] != "example" {
		t.Fatal(play)
	}
	if raw := call(url.Values{"play": {"legacy#id"}, "flag": {"raw"}}, false); raw["url"] != "raw:legacy#id" {
		t.Fatal(raw)
	}
}

func TestType4InvalidArguments(t *testing.T) {
	for _, query := range []string{"play=yzep1:bad", "t=movie&ext=invalid", "t=movie&ext=bnVsbA==", "wd=movie&pg=0"} {
		writer := httptest.NewRecorder()
		serveType4(writer, httptest.NewRequest(http.MethodGet, "/?"+query, nil), Site{}, t4TestProvider{})
		if writer.Code != http.StatusBadRequest {
			t.Errorf("%s returned %d", query, writer.Code)
		}
	}
}

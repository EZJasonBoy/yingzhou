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

func TestDrama2HostRoutes(t *testing.T) {
	checks := 0
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/api/v1/sites":
			checks++
			fmt.Fprint(writer, `[{"key":"干饭","type":3,"runtime":"jar"}]`)
		case "/api/v1/sites/干饭/home":
			fmt.Fprint(writer, `{"classes":[{"id":"1","name":"电影"}]}`)
		case "/api/v1/sites/干饭/category":
			q := request.URL.Query()
			if q.Get("f") != `{"year":"2026"}` || q.Get("pg") != "2" || q.Get("tid") != "1" {
				t.Error(q)
			}
			fmt.Fprint(writer, `{"pageCount":3,"list":[{"name":"影片"}]}`)
		case "/api/v1/sites/干饭/search":
			if request.URL.Query().Get("wd") != "A & B" || request.URL.Query().Get("pg") != "1" {
				t.Error(request.URL.Query())
			}
			fmt.Fprint(writer, `{"list":[{"id":"45"}]}`)
		case "/api/v1/sites/干饭/detail":
			if request.URL.Query().Get("id") != "45" {
				t.Error(request.URL.Query())
			}
			fmt.Fprint(writer, `{"id":"45","lines":[{"name":"原线","episodes":[{"name":"第一集","id":"x#1"}]}]}`)
		case "/api/v1/play/resolve":
			var body map[string]any
			if request.Method != http.MethodPost || json.NewDecoder(request.Body).Decode(&body) != nil || body["episodeId"] != "x#1" || body["site"] != "干饭" || body["line"] != "原线" || body["direct"] != true {
				t.Error(body)
			}
			fmt.Fprint(writer, `{"kind":"direct","url":"/m3u8?x=1","headers":{"Referer":"abc"}}`)
		default:
			t.Error(request.URL)
		}
	}))
	defer server.Close()
	host, err := newDrama2Host(server.Client(), strings.Replace(server.URL, "127.0.0.1", "localhost", 1)+"/api/v1/")
	if err != nil {
		t.Fatal(err)
	}
	site := Site{Key: "干饭", API: "csp_AppDrama2", Type: 3}
	ctx := context.Background()
	if home, err := host.Home(ctx, site); err != nil || len(home.Classes) != 1 {
		t.Fatal(home, err)
	}
	if page, err := host.Category(ctx, site, "1", 2, map[string]string{"year": "2026"}); err != nil || page.PageCount != 3 {
		t.Fatal(page, err)
	}
	if page, err := host.Search(ctx, site, "A & B", 1); err != nil || len(page.List) != 1 {
		t.Fatal(page, err)
	}
	if detail, err := host.Detail(ctx, site, "45"); err != nil || len(detail.Lines) != 1 || detail.Lines[0].Episodes[0].ID != "x#1" {
		t.Fatal(detail, err)
	}
	if play, err := host.Play(ctx, site, "原线", "x#1"); err != nil || play.URL != server.URL+"/m3u8?x=1" || play.Headers["Referer"] != "abc" {
		t.Fatal(play, err)
	}
	if checks != 5 {
		t.Fatalf("expected five site checks, got %d", checks)
	}
}

func TestDrama2HostRejectsRemoteBackend(t *testing.T) {
	for _, endpoint := range []string{"https://example.org", "http://127.0.0.1/other", "http://user@127.0.0.1/", "http://localhost/?key=1"} {
		if _, err := newDrama2Host(nil, endpoint); !errors.Is(err, errBadInput) {
			t.Error(endpoint, err)
		}
	}
	for _, reply := range []string{`[{"key":"干饭","type":4,"runtime":"remote"}]`, `[{"key":"其他站","type":3,"runtime":"jar"}]`, `[{"key":"干饭","type":3,"runtime":"js"}]`} {
		server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
			if request.URL.Path != "/api/v1/sites" {
				t.Fatal(request.URL)
			}
			fmt.Fprint(writer, reply)
		}))
		host, err := newDrama2Host(server.Client(), server.URL)
		if err != nil {
			t.Fatal(err)
		}
		_, err = host.Home(context.Background(), Site{Key: "干饭", API: "csp_AppDrama2", Type: 3})
		server.Close()
		if !errors.Is(err, errUnsupported) {
			t.Fatal(err)
		}
	}
}

func TestDrama2HostPlaybackShapes(t *testing.T) {
	for _, sample := range []struct {
		body, wantKind, wantPath, wantReferer string
		unsupported                           bool
	}{
		{`{"kind":"direct","url":"/proxy?do=spider%2F1&tvsig=test"}`, "direct", "/proxy?do=spider%2F1&tvsig=test", "", false},
		{`{"kind":"sniff","url":"","headers":{"Referer":"outer"},"sniff":{"pageUrl":"/demo/page?q=1%2B2","headers":{"Referer":"inner"},"scripts":[]}}`, "sniff", "/demo/page?q=1%2B2", "inner", false},
		{`{"kind":"sniff","sniff":{"pageUrl":"/demo/page","scripts":["example"]}}`, "", "", "", true},
	} {
		server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
			if request.URL.Path == "/api/v1/sites" {
				fmt.Fprint(writer, `[{"key":"干饭","type":3,"runtime":"jar"}]`)
				return
			}
			fmt.Fprint(writer, sample.body)
		}))
		host, err := newDrama2Host(server.Client(), server.URL)
		if err != nil {
			t.Fatal(err)
		}
		play, err := host.Play(context.Background(), Site{Key: "干饭", Type: 3, API: "csp_AppDrama2"}, "原线", "1")
		server.Close()
		if sample.unsupported {
			if !errors.Is(err, errUnsupported) {
				t.Fatal(err)
			}
		} else if err != nil || play.Kind != sample.wantKind || play.URL != server.URL+sample.wantPath || play.Headers["Referer"] != sample.wantReferer {
			t.Fatalf("unexpected playback %#v, error %v", play, err)
		}
	}
}

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"
)

func TestRemoteSubscriptionWithClientUserAgent(t *testing.T) {
	origin := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.UserAgent() != "okhttp/4.12.0" {
			writer.Header().Set("Content-Type", "text/html; charset=utf-8")
			fmt.Fprint(writer, `<!doctype html><title>Source homepage</title>`)
			return
		}
		writer.Header().Set("Content-Type", "application/json")
		fmt.Fprint(writer, `{"sites":[{"key":"sample","type":3,"api":"csp_Test"}]}`)
	}))
	defer origin.Close()
	ctx := context.Background()
	document, err := loadSubscription(ctx, origin.Client(), origin.URL)
	if err != nil {
		t.Fatal(err)
	}
	service, err := newEngine(document, map[string]provider{"csp_Test": t4TestProvider{}})
	if err != nil {
		t.Fatal(err)
	}
	local := httptest.NewServer(service)
	defer local.Close()
	var exported subscription
	if err := getJSON(ctx, local.Client(), local.URL+"/config.json", nil, &exported); err != nil {
		t.Fatal(err)
	}
	if len(exported.Sites) != 1 || exported.Sites[0].Type != 4 || exported.Sites[0].API != "./t4/sample" {
		t.Fatalf("unexpected published sites: %+v", exported.Sites)
	}
	endpoint, err := url.JoinPath(local.URL, exported.Sites[0].API)
	if err != nil {
		t.Fatal(err)
	}
	var home struct {
		Classes []map[string]string `json:"class"`
	}
	if err := getJSON(ctx, local.Client(), endpoint, nil, &home); err != nil {
		t.Fatal(err)
	}
	if len(home.Classes) != 1 || home.Classes[0]["type_id"] != "m" {
		t.Fatalf("unexpected Type 4 home: %+v", home.Classes)
	}
}

func TestConvertOriginalSubscription(t *testing.T) {
	var document subscription
	if err := json.Unmarshal([]byte(`{"spider":"private-jar","sites":[{"key":"示例","name":"同名","type":3,"api":"csp_Test","searchable":0,"ext":"private-extension","jar":"private-override"},{"key":"行动","type":3,"api":"csp_AppDrama2"},{"key":"干饭","type":3,"api":"csp_AppDrama2"},{"key":"js","type":3,"api":"https://example.org/?key=private-rule"}]}`), &document); err != nil {
		t.Fatal(err)
	}
	service, err := newEngine(document, map[string]provider{"csp_Test": t4TestProvider{}, "csp_AppDrama2": ganfanProvider{}})
	if err != nil {
		t.Fatal(err)
	}
	request := func(method, host, path string, status int) []byte {
		t.Helper()
		req := httptest.NewRequest(method, "http://"+host+path, nil)
		writer := httptest.NewRecorder()
		service.ServeHTTP(writer, req)
		if writer.Code != status {
			t.Fatalf("%s %s returned %d, want %d", method, path, writer.Code, status)
		}
		return writer.Body.Bytes()
	}
	var converted subscription
	body := request("GET", "127.0.0.1:9980", "/config.json", 200)
	if json.Unmarshal(body, &converted) != nil || len(converted.Sites) != 2 || converted.Sites[0].Key != "示例" || converted.Sites[1].Key != "干饭" || converted.Sites[0].Type != 4 || converted.Sites[0].Searchable == nil || *converted.Sites[0].Searchable != 0 || bytes.Contains(body, []byte("private-")) {
		t.Fatalf("incorrect conversion: %s", body)
	}
	base, _ := url.Parse("http://127.0.0.1:9980/config.json")
	endpoint, err := base.Parse(converted.Sites[0].API)
	if err != nil {
		t.Fatal(err)
	}
	request("POST", base.Host, endpoint.EscapedPath()+"?wd=test", 200)
	request("GET", base.Host, "/t4/"+url.PathEscape("行动"), 501)
	request("POST", base.Host, "/config.json", 405)
	request("GET", "example.org", "/config.json", 403)
	if status := request("GET", base.Host, "/status", 200); bytes.Contains(status, []byte("private-")) || !bytes.Contains(status, []byte(`"mode":"go-catalog"`)) {
		t.Fatal(string(status))
	}
}

func TestGanFanFollowsOriginalBootstrap(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/entry":
			fmt.Fprintf(writer, `{"enabled":true,"domain":"http://%s"}`, request.Host)
		case "/off":
			fmt.Fprint(writer, `{"enabled":false}`)
		case "/api/v3/drama/getCategory":
			if request.URL.Query().Get("orderBy") != "type_id" {
				t.Error("missing original sort parameter")
			}
			fmt.Fprint(writer, `{"code":200,"data":[{"id":1,"name":"电影"}]}`)
		default:
			t.Errorf("unexpected path %s", request.URL.Path)
		}
	}))
	defer server.Close()
	backend := ganfanProvider{client: server.Client()}
	site := Site{Ext: json.RawMessage(fmt.Sprintf(`{"site":%q}`, server.URL+"/entry"))}
	home, err := backend.Home(context.Background(), site)
	if err != nil || len(home.Classes) != 1 || home.Classes[0].Name != "电影" {
		t.Fatal(home, err)
	}
	site.Ext = json.RawMessage(fmt.Sprintf(`{"site":%q}`, server.URL+"/off"))
	if _, err := backend.Home(context.Background(), site); err == nil || !strings.Contains(err.Error(), "停用") {
		t.Fatal(err)
	}
}

type originalHomeStub struct {
	provider
	home Home
	err  error
}

func (stub originalHomeStub) Home(context.Context, Site) (Home, error) {
	return stub.home, stub.err
}

func TestGanFanHomeWithOriginalRecommendations(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		fmt.Fprint(writer, `{"code":200,"data":[{"id":1,"name":"电影"}]}`)
	}))
	defer server.Close()
	site := Site{Ext: json.RawMessage(fmt.Sprintf(`{"host":%q}`, server.URL))}
	original := originalHomeStub{home: Home{Classes: []Class{{ID: "other", Name: "宿主分类"}}, List: []Card{{ID: "73", Name: "首页推荐"}}}}
	backend := ganfanProvider{client: server.Client(), host: original}
	home, err := backend.Home(context.Background(), site)
	if err != nil || len(home.Classes) != 1 || home.Classes[0].ID != "1" || len(home.List) != 1 || home.List[0].ID != "73" {
		t.Fatalf("combined home: %+v, %v", home, err)
	}
	backend.host = originalHomeStub{err: errors.New("unavailable")}
	home, err = backend.Home(context.Background(), site)
	if err != nil || len(home.Classes) != 1 || len(home.List) != 0 {
		t.Fatalf("native home: %+v, %v", home, err)
	}
	backend.host = original
	home, err = backend.Home(context.Background(), Site{})
	if err != nil || len(home.Classes) != 1 || home.Classes[0].ID != "other" || len(home.List) != 1 {
		t.Fatalf("original home: %+v, %v", home, err)
	}
}

func TestGanFanLiveCatalog(t *testing.T) {
	address := os.Getenv("GANFAN_TEST_SUBSCRIPTION")
	if address == "" {
		t.Skip("set GANFAN_TEST_SUBSCRIPTION to check a live subscription")
	}
	client := &http.Client{Timeout: 18 * time.Second}
	document, err := loadSubscription(context.Background(), client, address)
	if err != nil {
		t.Fatal(err)
	}
	service, err := newEngine(document, map[string]provider{"csp_AppDrama2": ganfanProvider{client: client}})
	if err != nil || len(service.converted.Sites) != 1 {
		t.Fatalf("expected one selected GanFan site: %v", err)
	}
	local := httptest.NewServer(service)
	defer local.Close()
	var exported subscription
	if err := getJSON(context.Background(), client, local.URL+"/config.json", nil, &exported); err != nil || len(exported.Sites) != 1 {
		t.Fatalf("exported subscription: %v", err)
	}
	base, _ := url.Parse(local.URL + "/config.json")
	siteURL, err := base.Parse(exported.Sites[0].API)
	if err != nil {
		t.Fatal(err)
	}
	var home struct {
		Classes []struct {
			Name string `json:"type_name"`
		} `json:"class"`
		Filters map[string][]json.RawMessage `json:"filters"`
	}
	if err := getJSON(context.Background(), client, siteURL.String(), nil, &home); err != nil || len(home.Classes) == 0 {
		t.Fatalf("live Go home: %v", err)
	}
	t.Logf("%d source entries, %d GanFan categories, %d film filter groups", len(document.Sites), len(home.Classes), len(home.Filters["1"]))
}

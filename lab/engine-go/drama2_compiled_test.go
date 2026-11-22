package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"slices"
	"strings"
	"testing"
	"time"
)

type rawSpiderStub func(map[string]any) (string, error)

func (stub rawSpiderStub) call(_ context.Context, _ Site, request map[string]any) (json.RawMessage, error) {
	value, err := stub(request)
	return json.RawMessage(value), err
}

func TestGanFanLiveNative(t *testing.T) {
	testAppDrama2LiveSites(t, []string{"干饭"})
}

func TestAppDrama2LiveSites(t *testing.T) {
	keys := os.Getenv("APPDRAMA2_TEST_SITES")
	if keys == "" {
		t.Skip("set APPDRAMA2_TEST_SITES to a comma-separated list of site keys")
	}
	testAppDrama2LiveSites(t, strings.Split(keys, ","))
}

func testAppDrama2LiveSites(t *testing.T, keys []string) {
	t.Helper()
	address, program := os.Getenv("GANFAN_TEST_SUBSCRIPTION"), os.Getenv("GANFAN_TEST_NATIVE")
	if address == "" || program == "" {
		t.Skip("set GANFAN_TEST_SUBSCRIPTION and GANFAN_TEST_NATIVE to check the compiled spider")
	}
	ctx := context.Background()
	client := &http.Client{Timeout: 65 * time.Second}
	document, err := loadSubscription(ctx, client, address)
	if err != nil {
		t.Fatal(err)
	}
	spider, err := newNativeSpider(program, document.Spider)
	if err != nil {
		t.Fatal(err)
	}
	backend := ganfanProvider{client: client, host: &compiledSpider{spider: spider}}
	service, err := newEngine(document, map[string]provider{"csp_AppDrama2": backend})
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(service)
	defer server.Close()
	var config subscription
	if err := getJSON(ctx, client, server.URL+"/config.json", nil, &config); err != nil || len(config.Sites) == 0 {
		t.Fatalf("compiled subscription unavailable: %v", err)
	}
	base, _ := url.Parse(server.URL + "/config.json")
	for _, key := range keys {
		t.Run(key, func(t *testing.T) {
			for _, site := range config.Sites {
				if site.Key == key && site.Type == 4 {
					checkNativeType4(t, ctx, client, base, site)
					return
				}
			}
			t.Fatal("selected site is missing from the exported subscription")
		})
	}
}

func checkNativeType4(t *testing.T, ctx context.Context, client *http.Client, base *url.URL, site Site) {
	t.Helper()
	api, err := base.Parse(site.API)
	if err != nil {
		t.Fatal(err)
	}
	query := func(values url.Values) spiderRecord {
		t.Helper()
		var record spiderRecord
		if err := getJSON(ctx, client, api.String()+"?"+values.Encode(), nil, &record); err != nil {
			t.Fatal(err)
		}
		return record
	}
	home := query(url.Values{})
	var classes []spiderRecord
	if json.Unmarshal(home["class"], &classes) != nil || len(classes) == 0 {
		t.Fatal("home returned no classes")
	}
	category := classes[0]
	for _, entry := range classes {
		if strings.Contains(entry.text("type_name"), "电影") {
			category = entry
			break
		}
	}
	page := query(url.Values{"t": {category.text("type_id")}, "pg": {"2"}})
	cards, err := page.cards(site)
	if err != nil || len(cards) == 0 {
		t.Fatalf("no live film on page 2: %v", err)
	}
	card := cards[0]
	t.Logf("%s：%d 个分类，%s 第 2 页 %d 个条目，首项《%s》", site.Key, len(classes), category.text("type_name"), len(cards), card.Name)
	search := query(url.Values{"wd": {card.Name}, "pg": {"1"}})
	hits, err := search.cards(site)
	if err != nil || !slices.ContainsFunc(hits, func(hit Card) bool { return hit.ID == card.ID || hit.Name == card.Name }) {
		t.Fatalf("cannot find the live film by name: %v", err)
	}
	detail := query(url.Values{"ids": {card.ID}})
	var entries []spiderRecord
	if json.Unmarshal(detail["list"], &entries) != nil || len(entries) == 0 {
		t.Fatal("missing detail")
	}
	if entries[0].text("vod_name") != card.Name {
		t.Fatal("detail does not belong to the selected title")
	}
	line, _, _ := strings.Cut(entries[0].text("vod_play_from"), "$$$")
	lines, _, _ := strings.Cut(entries[0].text("vod_play_url"), "$$$")
	episode, _, _ := strings.Cut(lines, "#")
	_, id, found := strings.Cut(episode, "$")
	if !found || id == "" {
		t.Fatal("missing first episode")
	}
	info := query(url.Values{"flag": {line}, "play": {id}})
	if info.text("url") == "" {
		t.Fatal("missing resolved playback URL")
	}
	t.Log("片名搜索、详情及首条线路的播放解析通过")
}

func TestCompiledSpiderPreservesTVBoxRecords(t *testing.T) {
	site := Site{Key: "干饭", Type: 3, API: "csp_AppDrama2"}
	backend := &compiledSpider{spider: rawSpiderStub(func(request map[string]any) (string, error) {
		switch request["op"] {
		case "home":
			return `{"class":[{"type_id":2,"type_name":"连续剧"}]}`, nil
		case "category", "search":
			if request["page"] != 2 {
				t.Error("missing requested page")
			}
			return `{"page":"2","pagecount":4,"total":"53","list":[{"vod_id":823,"vod_name":"影片"}]}`, nil
		case "detail":
			return `{"list":[{"vod_id":823,"vod_name":"影片","vod_play_from":"A$$$B","vod_play_url":"第一集$ep$1#第二集$ep2$$$ep3"}]}`, nil
		case "play":
			if request["line"] != "A" || request["id"] != "ep$1" {
				t.Fatal("incorrect original episode")
			}
			return `{"parse":0,"url":"https://cdn.example.org/watch.m3u8","header":"{\"Referer\":\"https://example.org/\"}"}`, nil
		}
		return "", fmt.Errorf("unexpected op")
	})}
	ctx := context.Background()
	home, err := backend.Home(ctx, site)
	if err != nil || len(home.Classes) != 1 || home.Classes[0].ID != "2" {
		t.Fatal(home, err)
	}
	page, err := backend.Category(ctx, site, "2", 2, nil)
	if err != nil || page.Page != 2 || page.PageCount != 4 || page.Total != 53 || len(page.List) != 1 || page.List[0].ID != "823" {
		t.Fatal(page, err)
	}
	if found, err := backend.Search(ctx, site, "影片", 2); err != nil || len(found.List) != 1 {
		t.Fatal(found, err)
	}
	detail, err := backend.Detail(ctx, site, page.List[0].ID)
	if err != nil || len(detail.Lines) != 2 || len(detail.Lines[0].Episodes) != 2 || detail.Lines[1].Episodes[0].Name != "1" {
		t.Fatal(detail, err)
	}
	line := detail.Lines[0]
	play, err := backend.Play(ctx, site, line.Name, line.Episodes[0].ID)
	if err != nil || play.Kind != "direct" || play.Headers["Referer"] != "https://example.org/" {
		t.Fatal(play, err)
	}
}

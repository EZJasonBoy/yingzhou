package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"slices"
	"testing"
)

func TestType4CompiledFiltersAndResolverFlags(t *testing.T) {
	source := &compiledSpider{spider: rawSpiderStub(func(request map[string]any) (string, error) {
		if request["op"] == "home" {
			return `{"class":[{"type_id":1,"type_name":"电影"}],"filters":{"1":{"key":"order","value":[{"n":"最新","v":2}],"init":"2"},"2":[{"key":"area","name":"地区","value":[{"n":"全部","v":""}]}]}}`, nil
		}
		return `{"url":"https://example.org/watch","parse":0,"jx":1,"flag":"original","headers":{"Origin":"test"},"header":"{\"Referer\":\"test\"}","subs":[{"name":"字幕"}],"danmaku":"text","ext":"private"}`, nil
	})}
	call := func(path string) spiderRecord {
		t.Helper()
		recorder := httptest.NewRecorder()
		serveType4(recorder, httptest.NewRequest(http.MethodGet, path, nil), Site{Key: "sample"}, source)
		var result spiderRecord
		if recorder.Code != http.StatusOK || json.Unmarshal(recorder.Body.Bytes(), &result) != nil {
			t.Fatalf("incorrect response: %d", recorder.Code)
		}
		return result
	}
	home := call("/?filter=true")
	var filters map[string][]struct {
		Key, Name, Init string
		Value           []struct{ N, V string }
	}
	if json.Unmarshal(home["filters"], &filters) != nil || len(filters["1"]) != 1 || len(filters["2"]) != 1 {
		t.Fatal("compiled home lost its filter groups")
	}
	group := filters["1"][0]
	if group.Key != "order" || group.Name != "order" || group.Init != "2" || len(group.Value) != 1 || group.Value[0].V != "2" || filters["2"][0].Name != "地区" {
		t.Fatal("compiled filter values changed")
	}
	play := call("/?play=episode&flag=fallback")
	var headers map[string]string
	if play.text("parse") != "0" || play.text("jx") != "1" || play.text("flag") != "original" || play.text("danmaku") != "text" || len(play["subs"]) == 0 || len(play["ext"]) != 0 || json.Unmarshal(play["header"], &headers) != nil || headers["Origin"] != "test" || headers["Referer"] != "test" {
		t.Fatal("compiled player metadata changed")
	}
}

func TestCompiledQualityURLs(t *testing.T) {
	const first = "https://media.example/video?id=2&part=1"
	const second = "http://media.example/other#part"
	options := []string{"本地", "file:///tmp/video", "高清", first, "凭据", "https://a:b@media.example/v", "标清", second}
	encoded, err := json.Marshal(options)
	if err != nil {
		t.Fatal(err)
	}
	for _, format := range []string{"array", "string"} {
		t.Run(format, func(t *testing.T) {
			var input any = options
			if format == "string" {
				input = string(encoded)
			}
			payload, err := json.Marshal(map[string]any{"url": input, "parse": 0, "jx": 0})
			if err != nil {
				t.Fatal(err)
			}
			source := &compiledSpider{spider: rawSpiderStub(func(map[string]any) (string, error) { return string(payload), nil })}
			play, err := source.Play(context.Background(), Site{}, "line", "id")
			if err != nil || play.URL != first || play.Kind != "direct" {
				t.Fatalf("wrong primary quality: %v, %v", play.URL, err)
			}
			recorder := httptest.NewRecorder()
			serveType4(recorder, httptest.NewRequest(http.MethodGet, "/?play=episode&flag=line", nil), Site{}, source)
			var wire spiderRecord
			var qualities []string
			if recorder.Code != http.StatusOK || json.Unmarshal(recorder.Body.Bytes(), &wire) != nil || json.Unmarshal([]byte(wire.text("url")), &qualities) != nil {
				t.Fatal("Type 4 did not return a JSON string containing quality pairs")
			}
			if !slices.Equal(qualities, []string{"高清", first, "标清", second}) || wire.text("parse") != "0" || wire.text("jx") != "0" {
				t.Fatalf("wrong quality pairs or flags: %s", recorder.Body.String())
			}
		})
	}
	for _, invalid := range []string{`[]`, `["高清"]`, `[{"url":"https://media.example/a"}]`, `["高清","data:text/plain,hello"]`} {
		source := &compiledSpider{spider: rawSpiderStub(func(map[string]any) (string, error) { return `{"url":` + invalid + `}`, nil })}
		if _, err := source.Play(context.Background(), Site{}, "line", "id"); !errors.Is(err, errUnsupported) {
			t.Fatalf("invalid quality list accepted: %s", invalid)
		}
	}
}

func TestKanqiuAllCategoryHasUsableID(t *testing.T) {
	const payload = `{"class":[{"type_id":"","type_name":"全部直播"},{"type_id":"1","type_name":"足球"}],"filters":{"":[{"key":"state","value":[{"n":"全部","v":""}]}]}}`
	var selected any
	source := &compiledSpider{spider: rawSpiderStub(func(request map[string]any) (string, error) {
		if request["op"] == "home" {
			return payload, nil
		}
		selected = request["id"]
		return `{"list":[]}`, nil
	})}
	site := Site{API: "csp_Kanqiu"}
	home, err := source.Home(context.Background(), site)
	if err != nil || len(home.Classes) != 2 || home.Classes[0].ID == "" || home.Classes[1].ID != "1" || len(home.Filters[home.Classes[0].ID]) != 1 {
		t.Fatal("all matches category cannot be selected", err)
	}
	for _, class := range home.Classes {
		if _, err := source.Category(context.Background(), site, class.ID, 1, nil); err != nil {
			t.Fatal(err)
		}
		if (class.ID == kanqiuAllCategory && selected != "") || (class.ID == "1" && selected != "1") {
			t.Fatal("incorrect upstream category", selected)
		}
	}
}

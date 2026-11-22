package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
)

func callMobile(t *testing.T, method, address string, body any, status int, output any) {
	t.Helper()
	var input io.Reader
	if body != nil {
		encoded, err := json.Marshal(body)
		if err != nil {
			t.Fatal(err)
		}
		input = bytes.NewReader(encoded)
	}
	request, err := http.NewRequest(method, address, input)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Content-Type", "application/json")
	reply, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer reply.Body.Close()
	if reply.StatusCode != status {
		data, _ := io.ReadAll(reply.Body)
		t.Fatalf("%s: HTTP %d; want %d: %s", request.URL.Path, reply.StatusCode, status, data)
	}
	if output != nil {
		if err := json.NewDecoder(reply.Body).Decode(output); err != nil {
			t.Fatal(err)
		}
	}
}

func TestMobileLifecycleWithOriginalSubscription(t *testing.T) {
	var offline atomic.Bool
	origin := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/config" || request.UserAgent() != "okhttp/4.12.0" {
			t.Error("unexpected upstream request")
			http.NotFound(writer, request)
			return
		}
		if offline.Load() {
			writer.WriteHeader(503)
			return
		}
		fmt.Fprintf(writer, `{"spider":"http://%s/private.jar","sites":[{"key":"推送","type":3,"api":"csp_Push","searchable":0},{"key":"other","type":3,"api":"csp_Unknown","ext":"private-unsupported-extension"}]}`, request.Host)
	}))
	defer origin.Close()
	dir := t.TempDir()
	defer StopMobileEngine()
	address := func() string {
		port, err := StartMobileEngine(0, dir)
		if err != nil || port == 0 {
			t.Fatal(port, err)
		}
		if repeated, err := StartMobileEngine(port, dir); err != nil || repeated != port {
			t.Fatal(repeated, err)
		}
		return "http://127.0.0.1:" + strconv.Itoa(port) + "/api/v1"
	}
	base := address()
	var noConfig struct{ Error struct{ Code string } }
	callMobile(t, "GET", base+"/config", nil, 409, &noConfig)
	if noConfig.Error.Code != "NO_CONFIG" {
		t.Fatal(noConfig)
	}
	callMobile(t, "POST", base+"/subscriptions", map[string]string{"url": "file:///unknown"}, 400, nil)
	var sub mobileSubscription
	callMobile(t, "POST", base+"/subscriptions", map[string]string{"url": origin.URL + "/config"}, 201, &sub)
	if sub.ID == "" || sub.URL != origin.URL+"/config" {
		t.Fatal(sub)
	}
	path := base + "/subscriptions/" + sub.ID
	callMobile(t, "PUT", path, map[string]string{"name": "源"}, 200, nil)
	callMobile(t, "POST", path+"/activate", map[string]string{}, 200, nil)
	var sites []struct {
		Key, Runtime string
		Searchable   bool
	}
	callMobile(t, "GET", base+"/sites", nil, 200, &sites)
	if len(sites) != 1 || sites[0].Key != "推送" || sites[0].Runtime != "go" || sites[0].Searchable {
		t.Fatal(sites)
	}
	var detail Detail
	const media = "https://media.example/snow.mp4?quality=hd"
	callMobile(t, "GET", base+"/sites/"+url.PathEscape("推送")+"/detail?id="+url.QueryEscape("雪$"+media), nil, 200, &detail)
	if detail.Site != "推送" || len(detail.Lines) != 1 || detail.Lines[0].Episodes[0].Name != "雪" {
		t.Fatal(detail)
	}
	resolve := map[string]string{"site": detail.Site, "line": detail.Lines[0].Name, "episodeId": detail.Lines[0].Episodes[0].ID}
	var play PlayInfo
	callMobile(t, "POST", base+"/play/resolve", resolve, 200, &play)
	if play.Kind != "direct" || play.URL != media {
		t.Fatal(play)
	}
	offline.Store(true)
	callMobile(t, "POST", base+"/config/reload", nil, 502, nil)
	callMobile(t, "GET", base+"/sites", nil, 200, nil)
	disk, err := os.ReadFile(filepath.Join(dir, mobileStateFile))
	if err != nil || bytes.Contains(disk, []byte("private-unsupported")) || bytes.Contains(disk, []byte("private.jar")) || bytes.Contains(disk, []byte(media)) {
		t.Fatal("unexpected saved subscription", err)
	}
	StopMobileEngine()
	base = address()
	var restored struct {
		Stored bool
		Sites  int
	}
	callMobile(t, "GET", base+"/config", nil, 200, &restored)
	if !restored.Stored || restored.Sites != 1 {
		t.Fatal(restored)
	}
	callMobile(t, "POST", base+"/play/resolve", resolve, 200, nil)
	callMobile(t, "DELETE", base+"/subscriptions/"+sub.ID, nil, 204, nil)
	callMobile(t, "GET", base+"/config", nil, 409, nil)
	var items []mobileSubscription
	callMobile(t, "GET", base+"/subscriptions", nil, 200, &items)
	if items == nil || len(items) != 0 {
		t.Fatal(items)
	}
}

func TestMobileBrowseProtocol(t *testing.T) {
	origin := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		fmt.Fprint(writer, `{"sites":[{"key":"station","type":3,"api":"csp_Test"},{"key":"bili","type":3,"api":"csp_Bili","ext":{"class":[{"type_id":"m","type_name":"电影"}],"filters":{"m":[{"key":"g","name":"类型"}]}}}]}`)
	}))
	defer origin.Close()
	service, err := newMobileEngine(t.TempDir(), origin.Client())
	if err != nil {
		t.Fatal(err)
	}
	service.providers["csp_Test"] = t4TestProvider{}
	server := httptest.NewServer(service)
	defer server.Close()
	base := server.URL + "/api/v1"
	var sub mobileSubscription
	callMobile(t, "POST", base+"/subscriptions", map[string]string{"url": origin.URL}, 201, &sub)
	callMobile(t, "POST", base+"/subscriptions/"+sub.ID+"/activate", nil, 200, nil)
	route := base + "/sites/station/"
	var home map[string]json.RawMessage
	callMobile(t, "GET", route+"home", nil, 200, &home)
	if !strings.Contains(string(home["classes"]), `"id":"m"`) || !strings.Contains(string(home["list"]), `"site":"station"`) || !strings.Contains(string(home["filters"]), `"value":"c"`) {
		t.Fatal(home)
	}
	callMobile(t, "GET", base+"/sites/bili/home", nil, 200, &home)
	if !strings.Contains(string(home["filters"]), `"values":[]`) {
		t.Fatal("empty filter values must remain a list for Flutter")
	}
	var page Page
	callMobile(t, "GET", route+"category?tid=m&pg=2&f="+url.QueryEscape(`{"genre":"comedy"}`), nil, 200, &page)
	if page.Page != 2 || page.PageCount != 5 || page.List[0].Name != "comedy" {
		t.Fatal(page)
	}
	callMobile(t, "GET", route+"search?pg=1&wd=雪", nil, 200, &page)
	if len(page.List) != 1 || page.List[0].Site != "station" || page.List[0].Name != "雪" {
		t.Fatal(page)
	}
	callMobile(t, "GET", route+"category?f=null&tid=m", nil, 400, nil)
	callMobile(t, "GET", route+"search?pg=0&wd=sample", nil, 400, nil)
	callMobile(t, "GET", route+"detail", nil, 400, nil)
	callMobile(t, "GET", base+"/sites/other/home", nil, 404, nil)
	for _, foreign := range []string{"host", "origin", "fetch-site"} {
		request := httptest.NewRequest("POST", base+"/config/reload", nil)
		switch foreign {
		case "host":
			request.Host = "example.test"
		case "origin":
			request.Header.Set("Origin", "https://example.test")
		case "fetch-site":
			request.Header.Set("Sec-Fetch-Site", "cross-site")
		}
		recorder := httptest.NewRecorder()
		service.ServeHTTP(recorder, request)
		if recorder.Code != 403 {
			t.Fatalf("%s permitted", foreign)
		}
	}
}

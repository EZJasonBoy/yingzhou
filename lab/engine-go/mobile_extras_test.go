package main

import (
	"bufio"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

func mobileExtraCall(t *testing.T, service *mobileEngine, method, path, body string, want int) string {
	t.Helper()
	request := httptest.NewRequest(method, "http://127.0.0.1/api/v1/"+path, strings.NewReader(body))
	writer := httptest.NewRecorder()
	if !service.serveMobileExtras(writer, request) || writer.Code != want {
		t.Fatalf("%s %s got %d (want %d): %s", method, path, writer.Code, want, writer.Body.String())
	}
	return writer.Body.String()
}

func TestMobileLibrarySurvivesAnEngineSwitch(t *testing.T) {
	dir := t.TempDir()
	open := func() *mobileEngine {
		service, err := newMobileEngine(dir, http.DefaultClient)
		if err != nil {
			t.Fatal(err)
		}
		return service
	}
	service := open()
	item := url.PathEscape("站点") + "/" + url.PathEscape("https://example.test/episode?part=2")
	put := `{"name":"电影","positionMs":12345,"subtitle":"lang:zh"}`
	mobileExtraCall(t, service, "PUT", "history/"+item, put, 200)
	first := mobileExtraCall(t, service, "PUT", "favorites/"+item, put, 200)
	service = open()
	if again := mobileExtraCall(t, service, "PUT", "favorites/"+item, put, 200); first != again {
		t.Fatal("Updating the same favorite changed its creation date")
	}
	var history []mobileLibraryEntry
	if err := json.Unmarshal([]byte(mobileExtraCall(t, service, "GET", "history", "", 200)), &history); err != nil || len(history) != 1 || history[0].Site != "站点" || history[0].VodID != "https://example.test/episode?part=2" || history[0].PositionMs != 12345 || history[0].Subtitle != "lang:zh" {
		t.Fatalf("Restored library: %+v (%v)", history, err)
	}
	mobileExtraCall(t, service, "DELETE", "history", "", 204)
	mobileExtraCall(t, open(), "GET", "history/"+item, "", 404)
	mobileExtraCall(t, service, "DELETE", "favorites/"+item, "", 204)
	if strings.TrimSpace(mobileExtraCall(t, open(), "GET", "favorites", "", 200)) != "[]" {
		t.Fatal("Removing the final favorite must leave a JSON array")
	}
}

func TestMobileSearchMatchesFlutterStream(t *testing.T) {
	service, err := newMobileEngine(t.TempDir(), http.DefaultClient)
	if err != nil {
		t.Fatal(err)
	}
	disabled := 0
	service.active, err = newEngine(subscription{Sites: []Site{
		{Key: "searchable", Type: 3, API: "csp_Test"},
		{Key: "disabled", Type: 3, API: "csp_Test", Searchable: &disabled},
		{Key: "unselected", Type: 3, API: "csp_Test"},
	}}, map[string]provider{"csp_Test": t4TestProvider{}})
	if err != nil {
		t.Fatal(err)
	}
	stream := mobileExtraCall(t, service, "GET", "search/stream?wd=example&sites=searchable,disabled", "", 200)
	var names []string
	scanner := bufio.NewScanner(strings.NewReader(stream))
	for scanner.Scan() {
		if name, ok := strings.CutPrefix(scanner.Text(), "event: "); ok {
			names = append(names, name)
		}
	}
	if strings.Join(names, ",") != "site,results,site,end" || !strings.Contains(stream, `"sites":1`) || !strings.Contains(stream, `"name":"example"`) || !strings.Contains(stream, `"status":"done"`) || strings.Contains(stream, `"unselected"`) || strings.Contains(stream, `"disabled"`) {
		t.Fatal(stream)
	}
}

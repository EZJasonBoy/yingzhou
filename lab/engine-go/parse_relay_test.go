package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
)

func TestParseRelayExportsFixedTypeOneEndpoints(t *testing.T) {
	const input = "https://video.example/watch?id=中文+1&quality=HD"
	var called atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, req *http.Request) {
		called.Add(1)
		if req.Method != http.MethodGet || req.URL.RawQuery != "fixed=value&url="+url.QueryEscape(input) {
			t.Error("parser query did not match the subscribed prefix and exactly-once encoded input")
		}
		if req.Header.Get("User-Agent") != "parser-agent" || req.Header.Get("X-Resolver") != "fixture" || req.Header.Get("Authorization") != "" || req.Header.Get("Cookie") != "" || req.Header.Get("X-Client") != "" {
			t.Error("upstream did not receive precisely the configured headers")
		}
		writer.Header().Set("Set-Cookie", "fixture-response-cookie")
		fmt.Fprint(writer, `{"parse":0,"private":"discard","data":{"url":"https://media.example/film.m3u8","parse":1,"headers":{"Referer":"https://media.example/"},"private":"discard"}}`)
	}))
	defer upstream.Close()
	relay := newParseRelay([]parseConfig{
		{Name: "JS", Type: 2, URL: upstream.URL},
		{Name: "mix", Type: 3, URL: upstream.URL},
		{Name: "unsafe", Type: 1, URL: "file:///local/resource"},
		{Name: "credentials", Type: 1, URL: "https://name@example.test/resolver?url="},
		{Name: "parser", Type: 1, URL: upstream.URL + "/resolve?fixed=value&url=", Ext: json.RawMessage(`{"header":"{\"User-Agent\":\"parser-agent\"}","headers":{"X-Resolver":"fixture"}}`)},
	})
	entries := relay.entries()
	if len(entries) != 1 || entries[0].Name != "parser" || entries[0].Type != 1 || entries[0].URL != "./parse/0?url=" || len(entries[0].Ext) != 0 {
		t.Fatal("incorrect local parser declaration")
	}
	local := httptest.NewRequest(http.MethodGet, strings.TrimPrefix(entries[0].URL, ".")+url.QueryEscape(input), nil)
	local.Header.Set("Authorization", "client-authorization")
	local.Header.Set("Cookie", "client-cookie")
	local.Header.Set("X-Client", "client-header")
	writer := httptest.NewRecorder()
	relay.serve(writer, local)
	var result struct {
		Parse int
		Data  struct {
			URL     string
			Parse   int
			Headers map[string]string
		}
	}
	if writer.Code != http.StatusOK || called.Load() != 1 || json.Unmarshal(writer.Body.Bytes(), &result) != nil || result.Parse != 0 || result.Data.Parse != 1 || result.Data.URL != "https://media.example/film.m3u8" || result.Data.Headers["Referer"] == "" {
		t.Fatal("expected the nested Kotlin JSON parser response, including its parse flag and media headers")
	}
	if writer.Header().Get("Set-Cookie") != "" || strings.Contains(writer.Body.String(), "discard") {
		t.Fatal("included upstream HTTP headers or unrelated response fields")
	}
}

func TestParseRelayRejectsRedirectsAndBadRequests(t *testing.T) {
	var calls, redirected atomic.Int32
	target := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { redirected.Add(1) }))
	defer target.Close()
	upstream := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, req *http.Request) {
		calls.Add(1)
		if req.Header.Get("Authorization") != "configured-for-resolver" {
			t.Error("missing configured parser credential")
		}
		http.Redirect(writer, req, target.URL, http.StatusTemporaryRedirect)
	}))
	defer upstream.Close()
	relay := newParseRelay([]parseConfig{{Type: 1, URL: upstream.URL + "?url=", Ext: json.RawMessage(`{"header":{"Authorization":"configured-for-resolver"}}`)}})
	input := url.QueryEscape("https://video.example/watch")
	call := func(method, path string) *httptest.ResponseRecorder {
		t.Helper()
		writer := httptest.NewRecorder()
		relay.serve(writer, httptest.NewRequest(method, path, nil))
		return writer
	}
	for _, path := range []string{"/parse/0", "/parse/1?url=" + input, "/parse/00?url=" + input, "/parse/0?url=" + input + "&extra=1", "/parse/0?url=" + input + "&url=" + input, "/parse/0?url=file%3A%2F%2F%2Flocal"} {
		if got := call(http.MethodGet, path).Code; got != http.StatusBadRequest && got != http.StatusNotFound {
			t.Errorf("unexpected status on invalid relay request: %d", got)
		}
	}
	if call(http.MethodPost, "/parse/0?url="+input).Code != http.StatusMethodNotAllowed || calls.Load() != 0 {
		t.Fatal("an invalid request reached the parser")
	}
	reply := call(http.MethodGet, "/parse/0?url="+input)
	if reply.Code != http.StatusBadGateway || calls.Load() != 1 || redirected.Load() != 0 || reply.Header().Get("Location") != "" || strings.Contains(reply.Body.String(), target.URL) {
		t.Fatal("parser redirect was followed or disclosed")
	}
}

func TestParseRelayRejectsOversizedAndNonJSONResults(t *testing.T) {
	for _, text := range []string{"<html>private error</html>", `{"code":0,"msg":"private error"}`, strings.Repeat("x", parseResponseLimit+1)} {
		upstream := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) { fmt.Fprint(writer, text) }))
		relay := newParseRelay([]parseConfig{{Type: 1, URL: upstream.URL + "/?url="}})
		writer := httptest.NewRecorder()
		relay.serve(writer, httptest.NewRequest(http.MethodGet, "/parse/0?url=https%3A%2F%2Fvideo.example", nil))
		upstream.Close()
		if writer.Code != http.StatusBadGateway || strings.Contains(writer.Body.String(), "private error") || writer.Body.Len() > 1024 {
			t.Fatal("invalid response or private upstream error was forwarded")
		}
	}
}

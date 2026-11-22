package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const parseURLLimit = 16 << 10
const parseResponseLimit = 512 << 10

type relayParser struct {
	name     string
	endpoint *url.URL
	headers  http.Header
}

type parseRelay struct {
	parsers []relayParser
	client  *http.Client
}

func newParseRelay(parses []parseConfig) *parseRelay {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = nil
	transport.MaxResponseHeaderBytes = 32 << 10
	relay := &parseRelay{client: &http.Client{
		Transport:     transport,
		Timeout:       15 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}}
	for _, source := range parses {
		if source.Type != 1 || len(source.URL) > parseURLLimit {
			continue
		}
		endpoint, err := parseHTTPURL(source.URL)
		if err != nil || endpoint.Fragment != "" {
			continue
		}
		headers, err := parserHeaders(source.Ext)
		if err != nil {
			continue
		}
		name := strings.TrimSpace(source.Name)
		if name == "" || strings.Contains(name, "://") {
			name = "JSON 解析 " + strconv.Itoa(len(relay.parsers)+1)
		}
		relay.parsers = append(relay.parsers, relayParser{name: name, endpoint: endpoint, headers: headers})
	}
	return relay
}

func (relay *parseRelay) entries() []parseConfig {
	var entries []parseConfig
	for index, parser := range relay.parsers {
		entries = append(entries, parseConfig{Name: parser.name, Type: 1, URL: "./parse/" + strconv.Itoa(index) + "?url="})
	}
	return entries
}

func parseHTTPURL(value string) (*url.URL, error) {
	address, err := url.Parse(value)
	if err != nil || address.User != nil || address.Hostname() == "" || (address.Scheme != "http" && address.Scheme != "https") {
		return nil, errBadInput
	}
	return address, nil
}

func parserObject(raw json.RawMessage) (map[string]json.RawMessage, error) {
	var text string
	if len(raw) > 0 && raw[0] == '"' && json.Unmarshal(raw, &text) == nil {
		raw = json.RawMessage(text)
	}
	var object map[string]json.RawMessage
	if len(raw) == 0 || string(raw) == "null" {
		return nil, nil
	}
	err := json.Unmarshal(raw, &object)
	return object, err
}

func parserHeaders(raw json.RawMessage) (http.Header, error) {
	if len(raw) > parseURLLimit {
		return nil, errBadInput
	}
	ext, err := parserObject(raw)
	if err != nil {
		return nil, err
	}
	headers := make(http.Header)
	for _, key := range []string{"header", "headers"} {
		fields, err := parserObject(ext[key])
		if err != nil {
			return nil, err
		}
		for field, rawValue := range fields {
			name := http.CanonicalHeaderKey(field)
			if name == "" || strings.ContainsAny(name, "()<>@,;:\\\"/[]?={} \t\r\n") {
				return nil, errBadInput
			}
			switch name {
			case "Host", "Connection", "Keep-Alive", "Content-Length", "Transfer-Encoding", "Trailer", "Te", "Upgrade", "Proxy-Authorization", "Proxy-Connection", "Forwarded":
				continue
			}
			if strings.HasPrefix(name, "X-Forwarded-") {
				continue
			}
			var value string
			if json.Unmarshal(rawValue, &value) != nil || strings.ContainsAny(value, "\r\n\x00") {
				return nil, errBadInput
			}
			headers.Set(name, value)
		}
	}
	return headers, nil
}

func (relay *parseRelay) serve(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		writer.Header().Set("Allow", http.MethodGet)
		http.Error(writer, "GET required", http.StatusMethodNotAllowed)
		return
	}
	if origin := request.Header.Get("Origin"); origin != "" {
		originURL, err := parseHTTPURL(origin)
		if err != nil || !strings.EqualFold(originURL.Host, request.Host) {
			http.Error(writer, "same-origin request required", http.StatusForbidden)
			return
		}
	}
	if request.Header.Get("Sec-Fetch-Site") == "cross-site" {
		http.Error(writer, "same-origin request required", http.StatusForbidden)
		return
	}
	indexText, ok := strings.CutPrefix(request.URL.EscapedPath(), "/parse/")
	index, err := strconv.Atoi(indexText)
	if !ok || err != nil || index < 0 || index >= len(relay.parsers) || indexText != strconv.Itoa(index) {
		http.NotFound(writer, request)
		return
	}
	if request.ContentLength != 0 || len(request.URL.RawQuery) > 3*parseURLLimit+4 {
		writeProblem(writer, errBadInput)
		return
	}
	params, err := url.ParseQuery(request.URL.RawQuery)
	if err != nil || len(params) != 1 || len(params["url"]) != 1 || len(params.Get("url")) > parseURLLimit {
		writeProblem(writer, errBadInput)
		return
	}
	input := params.Get("url")
	if _, err := parseHTTPURL(input); err != nil {
		writeProblem(writer, errBadInput)
		return
	}
	parser := relay.parsers[index]
	requestURL := parser.endpoint.String() + url.QueryEscape(input)
	upstream, err := http.NewRequestWithContext(request.Context(), http.MethodGet, requestURL, nil)
	if err != nil || upstream.URL.Scheme != parser.endpoint.Scheme || upstream.URL.Host != parser.endpoint.Host || upstream.URL.User != nil {
		writeProblem(writer, errBadInput)
		return
	}
	upstream.Header = parser.headers.Clone()
	response, err := relay.client.Do(upstream)
	if err != nil {
		if errors.Is(err, context.DeadlineExceeded) {
			writeProblem(writer, context.DeadlineExceeded)
		} else {
			writeProblem(writer, errors.New("JSON 解析器连接失败"))
		}
		return
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		writeProblem(writer, errors.New("JSON 解析器返回 HTTP "+strconv.Itoa(response.StatusCode)))
		return
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, parseResponseLimit+1))
	var object map[string]json.RawMessage
	if err != nil || len(body) > parseResponseLimit || json.Unmarshal(body, &object) != nil || object == nil {
		writeProblem(writer, errors.New("JSON 解析器响应无效或过大"))
		return
	}
	var data map[string]json.RawMessage
	_ = json.Unmarshal(object["data"], &data)
	if len(data["url"]) == 0 && len(object["url"]) == 0 {
		writeProblem(writer, errors.New("JSON 解析器没有返回播放地址"))
		return
	}
	result := parserResultFields(object)
	if data != nil {
		result["data"] = parserResultFields(data)
	}
	writeJSON(writer, http.StatusOK, result)
}

func parserResultFields(object map[string]json.RawMessage) map[string]any {
	result := make(map[string]any)
	for _, key := range []string{"url", "header", "headers", "parse", "user-agent", "referer"} {
		if raw, ok := object[key]; ok {
			result[key] = raw
		}
	}
	return result
}

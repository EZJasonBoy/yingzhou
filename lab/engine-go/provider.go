package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
)

var errUnsupported = errors.New("此站点尚未适配该操作")
var errBadInput = errors.New("参数无效")

type Site struct {
	Key         string          `json:"key"`
	Name        string          `json:"name"`
	API         string          `json:"api"`
	Jar         string          `json:"jar,omitempty"`
	Type        int             `json:"type"`
	Ext         json.RawMessage `json:"ext,omitempty"`
	Searchable  *int            `json:"searchable,omitempty"`
	QuickSearch *int            `json:"quickSearch,omitempty"`
	Filterable  *int            `json:"filterable,omitempty"`
	Changeable  *int            `json:"changeable,omitempty"`
	Timeout     int             `json:"timeout,omitempty"`
}

type Class struct{ ID, Name string }
type FilterValue struct{ Name, Value string }
type Filter struct {
	Key, Name string
	Default   string `json:"init,omitempty"`
	Values    []FilterValue
}
type Card struct{ Site, ID, Name, Pic, Remarks, Tag string }
type Home struct {
	Classes []Class
	Filters map[string][]Filter
	List    []Card
}
type Page struct {
	Page, PageCount, Total int
	List                   []Card
}
type Episode struct{ ID, Name string }
type Line struct {
	Name     string
	Episodes []Episode
}
type Detail struct {
	Site, ID, Name, Pic, Year, Area, Type, Actor, Director, Content, Remarks string
	Lines                                                                    []Line
}
type PlayInfo struct {
	Kind, URL, Format string
	Headers           map[string]string
	qualities         []string
	tvbox             spiderRecord
}

type provider interface {
	Home(context.Context, Site) (Home, error)
	Category(context.Context, Site, string, int, map[string]string) (Page, error)
	Search(context.Context, Site, string, int) (Page, error)
	Detail(context.Context, Site, string) (Detail, error)
	Play(context.Context, Site, string, string) (PlayInfo, error)
}

const maxJSONSize = 4 << 20

func readJSON(reader io.Reader, result any) error {
	body, err := io.ReadAll(io.LimitReader(reader, maxJSONSize+1))
	if err != nil {
		return err
	}
	if len(body) > maxJSONSize {
		return fmt.Errorf("JSON exceeds %d bytes", maxJSONSize)
	}
	return json.Unmarshal(body, result)
}

func getJSON(ctx context.Context, client *http.Client, address string, headers map[string]string, result any) error {
	endpoint, err := url.Parse(address)
	if err != nil || endpoint.Hostname() == "" || endpoint.User != nil || (endpoint.Scheme != "https" && endpoint.Scheme != "http") {
		return fmt.Errorf("%w: expected an HTTP(S) URL", errBadInput)
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint.String(), nil)
	if err != nil {
		return fmt.Errorf("invalid request to %s", endpoint.Hostname())
	}
	request.Header.Set("User-Agent", "okhttp/4.12.0")
	for name, value := range headers {
		request.Header.Set(name, value)
	}
	response, err := client.Do(request)
	if err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return fmt.Errorf("could not reach %s", endpoint.Hostname())
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return fmt.Errorf("%s returned HTTP %d", endpoint.Hostname(), response.StatusCode)
	}
	if err := readJSON(response.Body, result); err != nil {
		return fmt.Errorf("%s: %w", endpoint.Hostname(), err)
	}
	return nil
}

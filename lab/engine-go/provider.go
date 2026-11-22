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

type Class struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}
type FilterValue struct {
	Name  string `json:"name"`
	Value string `json:"value"`
}
type Filter struct {
	Key     string        `json:"key"`
	Name    string        `json:"name"`
	Default string        `json:"init,omitempty"`
	Values  []FilterValue `json:"values"`
}
type Card struct {
	Site    string `json:"site"`
	ID      string `json:"id"`
	Name    string `json:"name"`
	Pic     string `json:"pic,omitempty"`
	Remarks string `json:"remarks,omitempty"`
	Tag     string `json:"tag,omitempty"`
}
type Home struct {
	Classes []Class             `json:"classes"`
	Filters map[string][]Filter `json:"filters,omitempty"`
	List    []Card              `json:"list"`
}
type Page struct {
	Page      int    `json:"page"`
	PageCount int    `json:"pageCount"`
	Total     int    `json:"total"`
	List      []Card `json:"list"`
}
type Episode struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}
type Line struct {
	Name     string    `json:"name"`
	Episodes []Episode `json:"episodes"`
}
type Detail struct {
	Site     string `json:"site"`
	ID       string `json:"id"`
	Name     string `json:"name"`
	Pic      string `json:"pic,omitempty"`
	Year     string `json:"year,omitempty"`
	Area     string `json:"area,omitempty"`
	Type     string `json:"type,omitempty"`
	Actor    string `json:"actor,omitempty"`
	Director string `json:"director,omitempty"`
	Content  string `json:"content,omitempty"`
	Remarks  string `json:"remarks,omitempty"`
	Lines    []Line `json:"lines"`
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

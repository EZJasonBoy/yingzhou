package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"strconv"
	"strings"
)

type compiledCaller interface {
	call(context.Context, Site, map[string]any) (json.RawMessage, error)
}

type compiledSpider struct{ spider compiledCaller }

const kanqiuAllCategory = "yz:kanqiu:all"

func (backend *compiledSpider) accepts(site Site) bool {
	runner, ok := backend.spider.(*nativeSpider)
	return ok && runner.supports(site)
}

func (*compiledSpider) mode() string { return "go+compiled-spider" }

type spiderRecord map[string]json.RawMessage

func (record spiderRecord) text(key string) string {
	raw := record[key]
	if len(raw) == 0 || string(raw) == "null" {
		return ""
	}
	var value string
	if json.Unmarshal(raw, &value) == nil {
		return value
	}
	var number json.Number
	if json.Unmarshal(raw, &number) == nil {
		return number.String()
	}
	return ""
}

func (backend *compiledSpider) result(ctx context.Context, site Site, args map[string]any) (spiderRecord, error) {
	raw, err := backend.spider.call(ctx, site, args)
	if err != nil {
		return nil, err
	}
	var result spiderRecord
	if json.Unmarshal(raw, &result) != nil || result == nil {
		return nil, fmt.Errorf("原生蜘蛛返回了无效的 TVBox 响应")
	}
	return result, nil
}

func (result spiderRecord) cards(site Site) ([]Card, error) {
	var entries []spiderRecord
	if len(result["list"]) != 0 && json.Unmarshal(result["list"], &entries) != nil {
		return nil, fmt.Errorf("原生蜘蛛返回了无效的片单")
	}
	cards := make([]Card, 0, len(entries))
	for _, entry := range entries {
		card := Card{Site: site.Key, ID: entry.text("vod_id"), Name: entry.text("vod_name"), Pic: entry.text("vod_pic"), Remarks: entry.text("vod_remarks"), Tag: entry.text("vod_tag")}
		if card.ID != "" || card.Name != "" {
			cards = append(cards, card)
		}
	}
	return cards, nil
}

func (backend *compiledSpider) Home(ctx context.Context, site Site) (Home, error) {
	result, err := backend.result(ctx, site, map[string]any{"op": "home"})
	if err != nil {
		return Home{}, err
	}
	var categories []spiderRecord
	if err := json.Unmarshal(result["class"], &categories); err != nil {
		return Home{}, fmt.Errorf("原生蜘蛛返回了无效的分类")
	}
	home := Home{Filters: spiderFilters(result["filters"])}
	for _, entry := range categories {
		class := Class{ID: entry.text("type_id"), Name: entry.text("type_name")}
		if site.API == "csp_Kanqiu" && class.ID == "" {
			class.ID = kanqiuAllCategory
			if filters, found := home.Filters[""]; found {
				home.Filters[kanqiuAllCategory] = filters
				delete(home.Filters, "")
			}
		}
		home.Classes = append(home.Classes, class)
	}
	home.List, err = result.cards(site)
	return home, err
}

func (backend *compiledSpider) listing(ctx context.Context, site Site, page int, args map[string]any) (Page, error) {
	result, err := backend.result(ctx, site, args)
	if err != nil {
		return Page{}, err
	}
	if len(result["list"]) == 0 {
		return Page{}, fmt.Errorf("原生蜘蛛响应缺少片单")
	}
	if upstreamPage, err := strconv.Atoi(result.text("page")); err == nil && upstreamPage > 0 {
		page = upstreamPage
	}
	pageCount, _ := strconv.Atoi(result.text("pagecount"))
	total, _ := strconv.Atoi(result.text("total"))
	cards, err := result.cards(site)
	return Page{Page: page, PageCount: pageCount, Total: total, List: cards}, err
}

func (backend *compiledSpider) Category(ctx context.Context, site Site, tid string, page int, filters map[string]string) (Page, error) {
	if site.API == "csp_Kanqiu" && tid == kanqiuAllCategory {
		tid = ""
	}
	return backend.listing(ctx, site, page, map[string]any{"op": "category", "id": tid, "page": page, "filters": filters})
}

func (backend *compiledSpider) Search(ctx context.Context, site Site, query string, page int) (Page, error) {
	return backend.listing(ctx, site, page, map[string]any{"op": "search", "query": query, "page": page})
}

func (backend *compiledSpider) Detail(ctx context.Context, site Site, id string) (Detail, error) {
	result, err := backend.result(ctx, site, map[string]any{"op": "detail", "id": id})
	if err != nil {
		return Detail{}, err
	}
	var entries []spiderRecord
	if json.Unmarshal(result["list"], &entries) != nil || len(entries) == 0 {
		return Detail{}, fmt.Errorf("原生蜘蛛没有返回该条目的详情")
	}
	entry := entries[0]
	detail := Detail{Site: site.Key, ID: entry.text("vod_id"), Name: entry.text("vod_name"), Pic: entry.text("vod_pic"), Year: entry.text("vod_year"), Area: entry.text("vod_area"), Type: entry.text("type_name"), Actor: entry.text("vod_actor"), Director: entry.text("vod_director"), Content: entry.text("vod_content"), Remarks: entry.text("vod_remarks")}
	flags := strings.Split(entry.text("vod_play_from"), "$$$")
	playlists := strings.Split(entry.text("vod_play_url"), "$$$")
	for index, name := range flags {
		if name == "" || index >= len(playlists) {
			continue
		}
		line := Line{Name: name}
		for _, part := range strings.Split(playlists[index], "#") {
			if part == "" {
				continue
			}
			label, episodeID, split := strings.Cut(part, "$")
			if !split {
				episodeID, label = label, strconv.Itoa(len(line.Episodes)+1)
			}
			line.Episodes = append(line.Episodes, Episode{ID: episodeID, Name: label})
		}
		if len(line.Episodes) > 0 {
			detail.Lines = append(detail.Lines, line)
		}
	}
	return detail, nil
}

func compiledHTTPURL(value string) string {
	address, err := url.Parse(value)
	if err != nil || address.User != nil || address.Hostname() == "" || (address.Scheme != "http" && address.Scheme != "https") {
		return ""
	}
	return address.String()
}

func compiledPlayURLs(raw json.RawMessage) (string, []string) {
	var text string
	if json.Unmarshal(raw, &text) == nil {
		text = strings.TrimSpace(text)
		if !strings.HasPrefix(text, "[") {
			return compiledHTTPURL(text), nil
		}
		raw = json.RawMessage(text)
	}
	var pairs []string
	if json.Unmarshal(raw, &pairs) != nil || len(pairs)%2 != 0 {
		return "", nil
	}
	qualities := make([]string, 0, len(pairs))
	for index := 0; index < len(pairs); index += 2 {
		if address := compiledHTTPURL(pairs[index+1]); address != "" {
			qualities = append(qualities, pairs[index], address)
		}
	}
	if len(qualities) == 0 {
		return "", nil
	}
	return qualities[1], qualities
}

func (backend *compiledSpider) Play(ctx context.Context, site Site, line, id string) (PlayInfo, error) {
	result, err := backend.result(ctx, site, map[string]any{"op": "play", "line": line, "id": id})
	if err != nil {
		return PlayInfo{}, err
	}
	address, qualities := compiledPlayURLs(result["url"])
	if address == "" {
		return PlayInfo{}, fmt.Errorf("%w：原生蜘蛛未返回 HTTP(S) 播放地址", errUnsupported)
	}
	info := PlayInfo{Kind: "direct", URL: address, Format: result.text("format"), qualities: qualities, tvbox: result}
	if result.text("parse") == "1" || result.text("jx") == "1" {
		info.Kind = "sniff"
	}
	for _, key := range []string{"header", "headers"} {
		header := result[key]
		if text := result.text(key); text != "" {
			header = json.RawMessage(text)
		}
		if len(header) > 0 && string(header) != `""` && string(header) != "null" && json.Unmarshal(header, &info.Headers) != nil {
			return PlayInfo{}, fmt.Errorf("原生蜘蛛返回了无效的播放请求头")
		}
	}
	return info, nil
}

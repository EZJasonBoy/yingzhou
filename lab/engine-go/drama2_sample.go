package main

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/url"
	"strconv"
	"strings"
	"time"
)

type drama2Sample struct {
	Schema        string             `json:"schema"`
	Version       int                `json:"version"`
	SourceClass   string             `json:"sourceClass"`
	SourceSite    string             `json:"sourceSite"`
	ExportedAt    time.Time          `json:"exportedAt"`
	CategoryInfo  Class              `json:"category"`
	Items         []drama2SampleItem `json:"items"`
	Dropped       map[string]int     `json:"dropped"`
	NonPortable   int                `json:"nonPortable"`
	MediaValidity string             `json:"mediaValidity"`
}

type drama2SampleItem struct {
	Card   Card                `json:"card"`
	Detail Detail              `json:"detail"`
	Media  map[string]PlayInfo `json:"media"`
}

type sampleSelection struct {
	Category string
	ItemID   string
	Page     int
	Limit    int
	Episodes int
}

func sampleURL(raw string) (*url.URL, bool) {
	address, err := url.Parse(raw)
	if err != nil || (address.Scheme != "https" && address.Scheme != "http") || address.User != nil || address.Opaque != "" {
		return nil, false
	}
	host := strings.ToLower(strings.TrimSuffix(address.Hostname(), "."))
	if host == "localhost" || strings.HasSuffix(host, ".localhost") || strings.HasSuffix(host, ".local") {
		return nil, false
	}
	if ip := net.ParseIP(host); ip != nil {
		if !ip.IsGlobalUnicast() || ip.IsPrivate() {
			return nil, false
		}
	} else if !strings.Contains(host, ".") || strings.Trim(host, "0123456789.") == "" || strings.ContainsAny(host, ":%") {
		return nil, false
	}
	return address, true
}

func sampleMedia(info PlayInfo, now time.Time) (PlayInfo, string) {
	if info.Kind != "direct" {
		return PlayInfo{}, "requires-resolver"
	}
	address, ok := sampleURL(info.URL)
	if !ok {
		return PlayInfo{}, "local-or-invalid-url"
	}
	for key, value := range info.Headers {
		switch strings.ToLower(key) {
		case "user-agent", "accept", "accept-language":
		case "referer", "origin":
			if ref, ok := sampleURL(value); !ok || ref.RawQuery != "" {
				return PlayInfo{}, "private-header"
			}
		default:
			return PlayInfo{}, "private-header"
		}
	}
	for key, values := range address.Query() {
		switch strings.ToLower(key) {
		case "authorization", "cookie", "access_token", "api_key", "apikey", "password", "sessionid", "tvsig":
			return PlayInfo{}, "credential-or-host-url"
		case "expires", "exp", "deadline":
			for _, value := range values {
				if stamp, err := strconv.ParseInt(value, 10, 64); err == nil && stamp > 0 && !now.Before(time.Unix(stamp, 0)) {
					return PlayInfo{}, "expired"
				}
			}
		}
	}
	return info, ""
}

func samplePicture(raw string) string {
	if address, ok := sampleURL(raw); ok && address.RawQuery == "" && !strings.Contains(raw, "|") {
		return raw
	}
	return ""
}

func sampleHostMedia(host provider, info PlayInfo) PlayInfo {
	local, ok := host.(*drama2Host)
	if !ok || info.Kind != "direct" {
		return info
	}
	base, err := url.Parse(local.base)
	if err != nil {
		return info
	}
	address, err := url.Parse(info.URL)
	if err != nil || address.User != nil || address.Scheme != base.Scheme || address.Host != base.Host || address.EscapedPath() != "/m3u8" || address.Fragment != "" {
		return info
	}
	query, err := url.ParseQuery(address.RawQuery)
	if err != nil || len(query["url"]) != 1 || len(query["d"]) != 1 || query.Get("d") != "1" {
		return info
	}
	for _, key := range []string{"h", "headers"} {
		for _, value := range query[key] {
			if value != "" {
				return info
			}
		}
	}
	if _, ok := sampleURL(query.Get("url")); !ok {
		return info
	}
	info.URL = query.Get("url")
	return info
}

func exportDrama2Sample(ctx context.Context, site Site, host provider, selection sampleSelection) (*drama2Sample, error) {
	if site.API != "csp_AppDrama2" || site.Type != 3 || site.Key != "干饭" || selection.Category == "" || selection.Limit < 1 || selection.Page < 1 || selection.Episodes < 1 || host == nil {
		return nil, errBadInput
	}
	page, err := host.Category(ctx, site, selection.Category, selection.Page, nil)
	if err != nil {
		return nil, err
	}
	if selection.ItemID != "" {
		var match []Card
		for _, card := range page.List {
			if card.ID == selection.ItemID {
				match = []Card{card}
				break
			}
		}
		if len(match) == 0 {
			return nil, fmt.Errorf("%w：所选条目不在该分类第 %d 页", errBadInput, selection.Page)
		}
		page.List = match
	}
	result := &drama2Sample{Schema: "yingzhou.drama2-sample", Version: 1, SourceClass: site.API, SourceSite: site.Key, ExportedAt: time.Now().UTC(), CategoryInfo: Class{ID: selection.Category, Name: selection.Category}, Dropped: map[string]int{}, Items: []drama2SampleItem{}}
	result.MediaValidity = "播放依赖原 CDN，媒体链接的有效期由片源决定。"
	if home, err := host.Home(ctx, site); err == nil {
		for _, class := range home.Classes {
			if class.ID == selection.Category {
				result.CategoryInfo = class
				break
			}
		}
	}
	for index, card := range page.List[:min(selection.Limit, len(page.List))] {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		detail, err := host.Detail(ctx, site, card.ID)
		if err != nil {
			result.Dropped["detail-unavailable"]++
			continue
		}
		lines := detail.Lines
		detail.Lines = nil
		card.ID = strconv.Itoa(index + 1)
		detail.ID = card.ID
		card.Pic = samplePicture(card.Pic)
		detail.Pic = samplePicture(detail.Pic)
		card.Site = site.Key
		detail.Site = site.Key
		media := map[string]PlayInfo{}
		for number, line := range lines {
			captured := Line{Name: line.Name}
			for episodeIndex, episode := range line.Episodes[:min(selection.Episodes, len(line.Episodes))] {
				if err := ctx.Err(); err != nil {
					return nil, err
				}
				info, err := host.Play(ctx, site, line.Name, episode.ID)
				if err != nil {
					result.Dropped["resolve-failed"]++
					continue
				}
				info, reason := sampleMedia(sampleHostMedia(host, info), result.ExportedAt)
				if reason != "" {
					result.Dropped[reason]++
					result.NonPortable++
					continue
				}
				episode.ID = fmt.Sprintf("%s-%d", card.ID, number+1)
				if episodeIndex > 0 {
					episode.ID += "-" + strconv.Itoa(episodeIndex+1)
				}
				media[episode.ID] = info
				captured.Episodes = append(captured.Episodes, episode)
			}
			if len(captured.Episodes) > 0 {
				detail.Lines = append(detail.Lines, captured)
			}
		}
		result.Items = append(result.Items, drama2SampleItem{Card: card, Detail: detail, Media: media})
	}
	return result, ctx.Err()
}

type drama2SampleProvider struct{ sample drama2Sample }

func (source *drama2SampleProvider) mode() string { return "go-sample" }

func newDrama2SampleProvider(reader io.Reader) (provider, error) {
	var sample drama2Sample
	if err := readJSON(reader, &sample); err != nil {
		return nil, err
	}
	if sample.Schema != "yingzhou.drama2-sample" || sample.Version != 1 || sample.SourceClass != "csp_AppDrama2" || sample.SourceSite != "干饭" || sample.CategoryInfo.ID == "" || sample.ExportedAt.IsZero() {
		return nil, fmt.Errorf("%w: invalid Drama2 sample", errBadInput)
	}
	for _, item := range sample.Items {
		for _, info := range item.Media {
			if _, reason := sampleMedia(info, time.Time{}); reason != "" {
				return nil, fmt.Errorf("%w: %s", errBadInput, reason)
			}
		}
	}
	return &drama2SampleProvider{sample}, nil
}

func (source *drama2SampleProvider) cards(site Site, page int, query string) Page {
	result := Page{Page: page, PageCount: 1, List: []Card{}}
	for _, item := range source.sample.Items {
		if strings.Contains(strings.ToLower(item.Card.Name), strings.ToLower(query)) {
			result.Total++
			if page == 1 {
				card := item.Card
				card.Site = site.Key
				result.List = append(result.List, card)
			}
		}
	}
	return result
}

func (source *drama2SampleProvider) Home(_ context.Context, site Site) (Home, error) {
	return Home{Classes: []Class{source.sample.CategoryInfo}, List: source.cards(site, 1, "").List}, nil
}
func (source *drama2SampleProvider) Category(_ context.Context, site Site, tid string, page int, filters map[string]string) (Page, error) {
	if tid != source.sample.CategoryInfo.ID || len(filters) > 0 {
		return Page{}, errUnsupported
	}
	return source.cards(site, page, ""), nil
}
func (source *drama2SampleProvider) Search(_ context.Context, site Site, query string, page int) (Page, error) {
	return source.cards(site, page, query), nil
}
func (source *drama2SampleProvider) Detail(_ context.Context, site Site, id string) (Detail, error) {
	for _, item := range source.sample.Items {
		if item.Card.ID == id {
			detail := item.Detail
			detail.Site = site.Key
			return detail, nil
		}
	}
	return Detail{}, errUnsupported
}
func (source *drama2SampleProvider) Play(_ context.Context, _ Site, line, id string) (PlayInfo, error) {
	for _, item := range source.sample.Items {
		for _, entry := range item.Detail.Lines {
			if entry.Name != line {
				continue
			}
			for _, episode := range entry.Episodes {
				if episode.ID == id {
					info, reason := sampleMedia(item.Media[id], time.Now())
					if reason != "" {
						return PlayInfo{}, fmt.Errorf("%w: %s", errUnsupported, reason)
					}
					return info, nil
				}
			}
		}
	}
	return PlayInfo{}, errUnsupported
}

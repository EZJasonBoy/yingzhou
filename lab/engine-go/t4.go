package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
)

const t4Prefix = "yzep1:"

var t4Label = strings.NewReplacer("$", "＄", "#", "＃")

func t4Cards(cards []Card) []map[string]string {
	result := make([]map[string]string, 0, len(cards))
	for _, card := range cards {
		result = append(result, map[string]string{"vod_id": card.ID, "vod_name": card.Name, "vod_pic": card.Pic, "vod_remarks": card.Remarks, "vod_tag": card.Tag})
	}
	return result
}

func t4Home(home Home) map[string]any {
	classes := make([]map[string]string, 0, len(home.Classes))
	for _, class := range home.Classes {
		classes = append(classes, map[string]string{"type_id": class.ID, "type_name": class.Name})
	}
	filters := map[string][]map[string]any{}
	for id, groups := range home.Filters {
		for _, group := range groups {
			values := make([]map[string]string, 0, len(group.Values))
			for _, value := range group.Values {
				values = append(values, map[string]string{"n": value.Name, "v": value.Value})
			}
			entry := map[string]any{"key": group.Key, "name": group.Name, "value": values}
			if group.Default != "" {
				entry["init"] = group.Default
			}
			filters[id] = append(filters[id], entry)
		}
	}
	return map[string]any{"class": classes, "filters": filters, "list": t4Cards(home.List)}
}

func t4Detail(detail Detail) map[string]any {
	var flags, playlists []string
	for _, line := range detail.Lines {
		var entries []string
		for _, ep := range line.Episodes {
			packed, _ := json.Marshal([2]string{line.Name, ep.ID})
			entries = append(entries, t4Label.Replace(ep.Name)+"$"+t4Prefix+base64.RawURLEncoding.EncodeToString(packed))
		}
		if len(entries) != 0 {
			flags = append(flags, t4Label.Replace(line.Name))
			playlists = append(playlists, strings.Join(entries, "#"))
		}
	}
	return map[string]any{"list": []map[string]string{{"vod_id": detail.ID, "vod_name": detail.Name, "vod_pic": detail.Pic, "vod_year": detail.Year, "vod_area": detail.Area, "type_name": detail.Type, "vod_actor": detail.Actor, "vod_director": detail.Director, "vod_content": detail.Content, "vod_remarks": detail.Remarks, "vod_play_from": strings.Join(flags, "$$$"), "vod_play_url": strings.Join(playlists, "$$$")}}}
}

func t4PlayArgs(flag, id string) (string, string, error) {
	encoded, packed := strings.CutPrefix(id, t4Prefix)
	if !packed {
		return flag, id, nil
	}
	data, err := base64.RawURLEncoding.DecodeString(encoded)
	var pair []string
	if err != nil || json.Unmarshal(data, &pair) != nil || len(pair) != 2 {
		return "", "", fmt.Errorf("%w: invalid episode identifier", errBadInput)
	}
	return pair[0], pair[1], nil
}

func t4QueryPage(form url.Values) (int, error) {
	if !form.Has("pg") {
		return 1, nil
	}
	page, err := strconv.Atoi(form.Get("pg"))
	if err != nil || page < 1 {
		return 0, fmt.Errorf("%w: invalid page", errBadInput)
	}
	return page, nil
}

func t4Request(request *http.Request, site Site, backend provider) (any, error) {
	ctx, form := request.Context(), request.Form
	switch {
	case form.Has("play"):
		line, id, err := t4PlayArgs(form.Get("flag"), form.Get("play"))
		if err != nil {
			return nil, err
		}
		info, err := backend.Play(ctx, site, line, id)
		if err != nil {
			return nil, err
		}
		parse := 0
		switch info.Kind {
		case "direct":
		case "sniff":
			parse = 1
		default:
			return nil, errUnsupported
		}
		result := map[string]any{"url": info.URL, "parse": parse, "header": info.Headers, "flag": line, "format": info.Format}
		if len(info.qualities) > 0 {
			encoded, _ := json.Marshal(info.qualities)
			result["url"] = string(encoded)
		}
		for _, key := range []string{"parse", "jx", "flag", "playUrl", "subt", "subs", "danmaku"} {
			if value := info.tvbox[key]; len(value) != 0 && string(value) != "null" {
				result[key] = value
			}
		}
		return result, nil
	case form.Has("ids"):
		detail, err := backend.Detail(ctx, site, form.Get("ids"))
		if err != nil {
			return nil, err
		}
		return t4Detail(detail), nil
	case form.Has("t") || form.Has("wd"):
		page, err := t4QueryPage(form)
		if err != nil {
			return nil, err
		}
		var result Page
		if form.Has("wd") {
			result, err = backend.Search(ctx, site, form.Get("wd"), page)
		} else {
			filters := map[string]string{}
			if encoded := form.Get("ext"); encoded != "" {
				data, decodeErr := base64.StdEncoding.DecodeString(encoded)
				if decodeErr != nil || json.Unmarshal(data, &filters) != nil || filters == nil {
					return nil, fmt.Errorf("%w: invalid filter map", errBadInput)
				}
			}
			result, err = backend.Category(ctx, site, form.Get("t"), page, filters)
		}
		if err != nil {
			return nil, err
		}
		return map[string]any{"page": result.Page, "pagecount": result.PageCount, "total": result.Total, "list": t4Cards(result.List)}, nil
	default:
		home, err := backend.Home(ctx, site)
		if err != nil {
			return nil, err
		}
		return t4Home(home), nil
	}
}

func serveType4(writer http.ResponseWriter, request *http.Request, site Site, backend provider) {
	if request.Method != http.MethodGet && request.Method != http.MethodPost {
		writer.Header().Set("Allow", "GET, POST")
		writeJSON(writer, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}
	request.Body = http.MaxBytesReader(writer, request.Body, 1<<20)
	if err := request.ParseForm(); err != nil {
		writeProblem(writer, fmt.Errorf("%w: invalid request form", errBadInput))
		return
	}
	result, err := t4Request(request, site, backend)
	if err != nil {
		writeProblem(writer, err)
		return
	}
	writeJSON(writer, http.StatusOK, result)
}

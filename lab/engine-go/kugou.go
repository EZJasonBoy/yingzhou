package main

import (
	"context"
	"encoding/json"
	"fmt"
	"html"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
)

type kugouProvider struct{ client *http.Client }

const kugouOrigin = "https://www.kugou.com"

var kugouClasses = []Class{{ID: "global", Name: "全球榜"}, {ID: "hot", Name: "热门榜"}, {ID: "special", Name: "特色榜"}}
var kugouSection = regexp.MustCompile(`(?is)<h3\b[^>]*>\s*<a\b[^>]*title="([^"]+)"`)
var kugouRank = regexp.MustCompile(`(?is)<a\s+title="([^"]+)"[^>]*href="https?://www\.kugou\.com/yy/rank/home/1-([0-9]+)\.html[^"<>]*"`)
var kugouSong = regexp.MustCompile(`(?is)<a\s+href="https?://www\.kugou\.com/mixsong/([a-z0-9]+)\.html"[^>]*title="([^"]+)"`)
var kugouTitle = regexp.MustCompile(`(?is)<title>([^<]+)</title>`)
var kugouTrackData = regexp.MustCompile(`\bvar\s+dataFromSmarty\s*=\s*`)
var kugouRankID = regexp.MustCompile(`^rank:([0-9]{1,10})$`)
var kugouSongID = regexp.MustCompile(`^song:([a-z0-9]{1,32})$`)

func (provider kugouProvider) fetch(ctx context.Context, path string) (string, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, kugouOrigin+path, nil)
	if err != nil {
		return "", err
	}
	request.Header.Set("User-Agent", "Yingzhou/0.4")
	reply, err := provider.client.Do(request)
	if err != nil {
		return "", err
	}
	defer reply.Body.Close()
	if reply.StatusCode != http.StatusOK {
		return "", fmt.Errorf("酷狗 HTTP %d", reply.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(reply.Body, maxJSONSize+1))
	if len(body) > maxJSONSize {
		return "", fmt.Errorf("酷狗网页过大")
	}
	return string(body), err
}

func (provider kugouProvider) Home(ctx context.Context, site Site) (Home, error) {
	return Home{Classes: append([]Class(nil), kugouClasses...)}, nil
}

func kugouFolders(body, key, section string) []Card {
	headings := kugouSection.FindAllStringSubmatchIndex(body, -1)
	var cards []Card
	labels := map[string]string{"热门榜单": "hot", "全球榜": "global", "特色音乐榜": "special"}
	for index, heading := range headings {
		if labels[body[heading[2]:heading[3]]] != section {
			continue
		}
		end := len(body)
		if index+1 < len(headings) {
			end = headings[index+1][0]
		}
		for _, item := range kugouRank.FindAllStringSubmatch(body[heading[1]:end], -1) {
			cards = append(cards, Card{Site: key, ID: "rank:" + item[2], Name: html.UnescapeString(item[1]), Tag: "folder"})
		}
	}
	return cards
}

func (provider kugouProvider) Category(ctx context.Context, site Site, tid string, page int, _ map[string]string) (Page, error) {
	if page < 1 || page > 1000 {
		return Page{}, errBadInput
	}
	result := Page{Page: page, PageCount: page, List: []Card{}}
	if tid == "global" || tid == "hot" || tid == "special" {
		result.PageCount = 1
		if page > 1 {
			return result, nil
		}
		body, err := provider.fetch(ctx, "/yy/rank/home/1-8888.html")
		if err != nil {
			return Page{}, err
		}
		result.List = kugouFolders(body, site.Key, tid)
	} else {
		match := kugouRankID.FindStringSubmatch(tid)
		if match == nil {
			return Page{}, errBadInput
		}
		body, err := provider.fetch(ctx, "/yy/rank/home/"+strconv.Itoa(page)+"-"+match[1]+".html")
		if err != nil {
			return Page{}, err
		}
		for _, item := range kugouSong.FindAllStringSubmatch(body, -1) {
			result.List = append(result.List, Card{Site: site.Key, ID: "song:" + item[1], Name: html.UnescapeString(item[2])})
		}
		if strings.Contains(body, "/yy/rank/home/"+strconv.Itoa(page+1)+"-"+match[1]+".html") {
			result.PageCount++
		}
	}
	result.Total = len(result.List)
	return result, nil
}

var kugouHashID = regexp.MustCompile(`^audio:([A-Fa-f0-9]{32})$`)

func (kugouProvider) accepts(site Site) bool {
	var ext struct {
		Classes []struct {
			ID string `json:"type_id"`
		} `json:"classes"`
	}
	return site.Type == 3 && site.API == "csp_Kugou" && site.Key == "酷狗" && json.Unmarshal(site.Ext, &ext) == nil && len(ext.Classes) == 1 && ext.Classes[0].ID == "kugou"
}

func (provider kugouProvider) Search(ctx context.Context, site Site, query string, page int) (Page, error) {
	if !provider.accepts(site) {
		return Page{}, errUnsupported
	}
	if strings.TrimSpace(query) == "" || page < 1 || page > 1000 {
		return Page{}, errBadInput
	}
	params := url.Values{"keyword": {query}, "page": {strconv.Itoa(page)}, "pagesize": {"8"}, "format": {"json"}}
	var reply struct {
		Status int
		Data   struct {
			Total int
			Info  []struct{ Hash, SongName, SingerName string }
		}
	}
	err := getJSON(ctx, provider.client, "https://mobiles.kugou.com/api/v3/search/song?"+params.Encode(), nil, &reply)
	if err != nil {
		return Page{}, err
	}
	if reply.Status != 1 {
		return Page{}, fmt.Errorf("酷狗搜索暂不可用")
	}
	result := Page{Page: page, Total: reply.Data.Total, PageCount: (reply.Data.Total + 7) / 8, List: []Card{}}
	for _, item := range reply.Data.Info {
		id := "audio:" + item.Hash
		if kugouHashID.MatchString(id) && item.SongName != "" {
			result.List = append(result.List, Card{Site: site.Key, ID: id, Name: item.SongName, Remarks: item.SingerName})
		}
	}
	return result, nil
}

type kugouAudio struct {
	Status                             int
	SongName, SingerName, URL, ExtName string
}

func (provider kugouProvider) audio(ctx context.Context, hash string) (kugouAudio, error) {
	var info kugouAudio
	err := getJSON(ctx, provider.client, "https://m.kugou.com/app/i/getSongInfo.php?cmd=playInfo&hash="+hash, nil, &info)
	if err == nil && info.Status != 1 {
		err = fmt.Errorf("酷狗未开放该歌曲")
	}
	return info, err
}

func (provider kugouProvider) Detail(ctx context.Context, site Site, id string) (Detail, error) {
	if hash := kugouHashID.FindStringSubmatch(id); hash != nil {
		info, err := provider.audio(ctx, hash[1])
		if err != nil {
			return Detail{}, err
		}
		return Detail{Site: site.Key, ID: id, Name: info.SongName, Actor: info.SingerName, Lines: []Line{{Name: "酷狗音乐", Episodes: []Episode{{ID: id, Name: info.SongName}}}}}, nil
	}
	match := kugouSongID.FindStringSubmatch(id)
	if match == nil {
		return Detail{}, errBadInput
	}
	body, err := provider.fetch(ctx, "/mixsong/"+match[1]+".html")
	if err != nil {
		return Detail{}, err
	}
	title := kugouTitle.FindStringSubmatch(body)
	if title == nil || !strings.Contains(title[1], "_高音质在线试听_") {
		return Detail{}, fmt.Errorf("酷狗歌曲详情缺失")
	}
	name, _, _ := strings.Cut(html.UnescapeString(title[1]), "_高音质在线试听_")
	if start := kugouTrackData.FindStringIndex(body); start != nil {
		var tracks []struct {
			ID     string `json:"encode_album_audio_id"`
			Hash   string `json:"hash"`
			Title  string `json:"song_name"`
			Singer string `json:"author_name"`
		}
		if json.NewDecoder(strings.NewReader(body[start[1]:])).Decode(&tracks) == nil {
			for _, track := range tracks {
				episodeID := "audio:" + track.Hash
				if track.ID == match[1] && track.Title != "" && kugouHashID.MatchString(episodeID) {
					return Detail{Site: site.Key, ID: id, Name: track.Title, Actor: track.Singer, Lines: []Line{{Name: "酷狗音乐", Episodes: []Episode{{ID: episodeID, Name: track.Title}}}}}, nil
				}
			}
		}
	}
	return Detail{Site: site.Key, ID: id, Name: name, Lines: []Line{{Name: "酷狗官网", Episodes: []Episode{{ID: id, Name: name}}}}}, nil
}

func (provider kugouProvider) Play(ctx context.Context, _ Site, _ string, id string) (PlayInfo, error) {
	if hash := kugouHashID.FindStringSubmatch(id); hash != nil {
		info, err := provider.audio(ctx, hash[1])
		if err != nil {
			return PlayInfo{}, err
		}
		media, err := url.Parse(info.URL)
		if err != nil || media.User != nil || (media.Scheme != "https" && media.Scheme != "http") || !strings.HasSuffix(strings.ToLower(media.Hostname()), ".kugou.com") {
			return PlayInfo{}, fmt.Errorf("酷狗未提供可用的试听地址")
		}
		return PlayInfo{Kind: "direct", URL: info.URL, Format: info.ExtName}, nil
	}
	match := kugouSongID.FindStringSubmatch(id)
	if match == nil {
		return PlayInfo{}, errBadInput
	}
	return PlayInfo{Kind: "sniff", URL: kugouOrigin + "/mixsong/" + match[1] + ".html"}, nil
}

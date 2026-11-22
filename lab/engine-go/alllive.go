package main

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"net/url"
	"slices"
	"strconv"
	"strings"
)

const liveBrowser = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/131.0.0.0 Safari/537.36"

var livePlatforms = []Class{{"huya", "虎牙"}, {"douyu", "斗鱼"}, {"bili", "哔哩"}}
var liveFolders = map[string][]Class{
	"huya":  {{"1", "英雄联盟"}, {"2", "单机热游"}, {"2135", "一起看"}, {"2336", "王者荣耀"}, {"2168", "颜值"}, {"1663", "星秀"}},
	"douyu": {{"LOL", "英雄联盟"}, {"TVgame", "单机热游"}, {"wzry", "手游休闲"}, {"yz", "颜值"}, {"smkj", "科技文化"}, {"yqk", "娱乐天地"}},
}

type allLiveProvider struct{ client *http.Client }

func newAllLiveProvider(client *http.Client) *allLiveProvider {
	if client == nil {
		client = http.DefaultClient
	}
	local := *client
	local.Jar = nil
	local.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	return &allLiveProvider{client: &local}
}

func (*allLiveProvider) accepts(site Site) bool {
	return site.Key == "alllive" && site.API == "csp_Alllive" && site.Type == 3
}

func livePlatform(id string) string {
	for _, platform := range livePlatforms {
		if platform.ID == id {
			return platform.Name
		}
	}
	return ""
}

func liveNumericID(id string) bool {
	if len(id) == 0 || len(id) > 16 || id[0] == '0' {
		return false
	}
	_, err := strconv.ParseUint(id, 10, 64)
	return err == nil
}

func liveHeaders(platform string) map[string]string {
	referer := map[string]string{"huya": "https://www.huya.com/", "bili": "https://live.bilibili.com/", "douyu": "https://m.douyu.com/"}
	return map[string]string{"Referer": referer[platform], "User-Agent": liveBrowser}
}

func (live *allLiveProvider) query(ctx context.Context, platform, endpoint string, values url.Values, destination any) error {
	var reply struct {
		Code   *int            `json:"code"`
		Status *int            `json:"status"`
		Data   json.RawMessage `json:"data"`
	}
	if err := getJSON(ctx, live.client, endpoint+"?"+values.Encode(), liveHeaders(platform), &reply); err != nil {
		return err
	}
	code, success := reply.Code, 0
	if platform == "huya" {
		code, success = reply.Status, http.StatusOK
	}
	if code == nil || len(reply.Data) == 0 || string(reply.Data) == "null" || *code != success {
		return fmt.Errorf("%s直播接口未返回可用数据", livePlatform(platform))
	}
	if err := json.Unmarshal(reply.Data, destination); err != nil {
		return fmt.Errorf("%s直播响应格式有误", livePlatform(platform))
	}
	return nil
}

func (*allLiveProvider) Home(context.Context, Site) (Home, error) {
	return Home{Classes: slices.Clone(livePlatforms)}, nil
}

func (live *allLiveProvider) folders(ctx context.Context, site Site, platform string, page int) (Page, error) {
	result := Page{Page: page, PageCount: 1}
	classes := liveFolders[platform]
	if platform == "bili" {
		var areas []struct {
			ID   json.Number `json:"id"`
			List []struct {
				ID   json.Number `json:"id"`
				Name string      `json:"name"`
				Pic  string      `json:"pic"`
			} `json:"list"`
		}
		err := live.query(ctx, platform, "https://api.live.bilibili.com/room/v1/Area/getList", url.Values{"parent_id": {"0"}, "need_entrance": {"1"}}, &areas)
		if err != nil {
			return Page{}, err
		}
		for _, area := range areas {
			if area.ID.String() == "2" {
				for _, item := range area.List {
					if liveNumericID(item.ID.String()) && item.Name != "" {
						result.List = append(result.List, Card{Site: site.Key, ID: "room|bili|" + item.ID.String(), Name: item.Name, Pic: item.Pic, Tag: "folder"})
					}
				}
				break
			}
		}
	}
	for _, item := range classes {
		result.List = append(result.List, Card{Site: site.Key, ID: "room|" + platform + "|" + item.ID, Name: item.Name, Tag: "folder"})
	}
	result.Total = len(result.List)
	return result, nil
}

func (live *allLiveProvider) Category(ctx context.Context, site Site, tid string, page int, _ map[string]string) (Page, error) {
	if page < 1 {
		return Page{}, errBadInput
	}
	if livePlatform(tid) != "" {
		return live.folders(ctx, site, tid, page)
	}
	parts := strings.Split(tid, "|")
	if len(parts) != 3 || parts[0] != "room" {
		return Page{}, errBadInput
	}
	platform, game := parts[1], parts[2]
	if platform == "bili" && liveNumericID(game) {
		return live.biliRooms(ctx, site, game, page)
	}
	if !slices.ContainsFunc(liveFolders[platform], func(class Class) bool { return class.ID == game }) {
		return Page{}, errBadInput
	}
	if platform == "huya" {
		return live.huyaRooms(ctx, site, game, page)
	}
	return live.douyuRooms(ctx, site, game, page)
}

func liveCard(result *Page, site Site, platform, room, title, nick, cover string) {
	if !liveNumericID(room) || strings.TrimSpace(title) == "" {
		return
	}
	result.List = append(result.List, Card{Site: site.Key, ID: "play|" + platform + "|" + room + "|" + url.QueryEscape(title), Name: title, Pic: cover, Remarks: nick})
}

func (live *allLiveProvider) huyaRooms(ctx context.Context, site Site, game string, page int) (Page, error) {
	var data struct {
		TotalPage, TotalCount int
		Datas                 []struct{ ProfileRoom, Introduction, Nick, Screenshot string }
	}
	params := url.Values{"m": {"LiveList"}, "do": {"getLiveListByPage"}, "gameId": {game}, "tagAll": {"0"}, "page": {strconv.Itoa(page)}}
	if err := live.query(ctx, "huya", "https://www.huya.com/cache.php", params, &data); err != nil {
		return Page{}, err
	}
	result := Page{Page: page, PageCount: data.TotalPage, Total: data.TotalCount}
	for _, item := range data.Datas {
		liveCard(&result, site, "huya", item.ProfileRoom, item.Introduction, item.Nick, item.Screenshot)
	}
	return result, nil
}

func (live *allLiveProvider) douyuRooms(ctx context.Context, site Site, game string, page int) (Page, error) {
	var data struct {
		PageCount int
		List      []struct {
			RID                         json.Number
			RoomName, Nickname, RoomSrc string
		}
	}
	params := url.Values{"page": {strconv.Itoa(page)}, "type": {game}}
	if err := live.query(ctx, "douyu", "https://m.douyu.com/api/room/list", params, &data); err != nil {
		return Page{}, err
	}
	result := Page{Page: page, PageCount: data.PageCount}
	for _, item := range data.List {
		liveCard(&result, site, "douyu", item.RID.String(), item.RoomName, item.Nickname, item.RoomSrc)
	}
	return result, nil
}

func (live *allLiveProvider) biliRooms(ctx context.Context, site Site, game string, page int) (Page, error) {
	var items []struct {
		RoomID       json.Number `json:"roomid"`
		Title, Uname string
		ShowCover    string `json:"show_cover"`
	}
	const pageSize = 30
	params := url.Values{"platform": {"web"}, "area_id": {game}, "page": {strconv.Itoa(page)}, "page_size": {strconv.Itoa(pageSize)}, "sort": {"online"}}
	if err := live.query(ctx, "bili", "https://api.live.bilibili.com/room/v1/area/getRoomList", params, &items); err != nil {
		return Page{}, err
	}
	result := Page{Page: page, PageCount: page}
	if len(items) == pageSize && page < math.MaxInt {
		result.PageCount++
	}
	for _, item := range items {
		liveCard(&result, site, "bili", item.RoomID.String(), item.Title, item.Uname, item.ShowCover)
	}
	return result, nil
}

func (*allLiveProvider) Search(_ context.Context, _ Site, _ string, page int) (Page, error) {
	return Page{Page: page, PageCount: 1}, nil
}

func liveRoomID(id string) (platform, room, title string, err error) {
	parts := strings.SplitN(id, "|", 4)
	if len(parts) != 4 || parts[0] != "play" || livePlatform(parts[1]) == "" || !liveNumericID(parts[2]) || len(parts[3]) > 8192 {
		return "", "", "", errBadInput
	}
	name, err := url.QueryUnescape(parts[3])
	if err != nil || strings.TrimSpace(name) == "" {
		return "", "", "", errBadInput
	}
	return parts[1], parts[2], name, nil
}

func (*allLiveProvider) Detail(_ context.Context, site Site, id string) (Detail, error) {
	platform, _, title, err := liveRoomID(id)
	if err != nil {
		return Detail{}, err
	}
	return Detail{Site: site.Key, ID: id, Name: title, Lines: []Line{{Name: livePlatform(platform), Episodes: []Episode{{ID: id, Name: "直播"}}}}}, nil
}

func liveMedia(raw, suffix, format string) bool {
	address, err := url.Parse(raw)
	return err == nil && address.User == nil && (address.Scheme == "https" || address.Scheme == "http") && address.Port() == "" && strings.HasSuffix(strings.ToLower(address.Hostname()), "."+suffix) && strings.HasSuffix(strings.ToLower(address.Path), "."+format)
}

func (live *allLiveProvider) Play(ctx context.Context, _ Site, _ string, id string) (PlayInfo, error) {
	platform, room, _, err := liveRoomID(id)
	if err != nil {
		return PlayInfo{}, err
	}
	headers := liveHeaders(platform)
	switch platform {
	case "huya":
		var data struct {
			LiveStatus string
			IsRoomPay  bool
			Stream     struct {
				HLS struct{ MultiLine []struct{ URL string } }
			}
		}
		params := url.Values{"m": {"Live"}, "do": {"profileRoom"}, "roomid": {room}}
		if err := live.query(ctx, platform, "https://mp.huya.com/cache.php", params, &data); err != nil {
			return PlayInfo{}, err
		}
		if data.LiveStatus != "ON" || data.IsRoomPay {
			return PlayInfo{}, fmt.Errorf("虎牙房间当前没有公开直播")
		}
		for _, line := range data.Stream.HLS.MultiLine {
			if liveMedia(line.URL, "huya.com", "m3u8") {
				return PlayInfo{Kind: "direct", URL: line.URL, Format: "m3u8", Headers: headers}, nil
			}
		}
	case "bili":
		var data struct{ DURL []struct{ URL string } }
		params := url.Values{"cid": {room}, "qn": {"80"}, "platform": {"web"}}
		if err := live.query(ctx, platform, "https://api.live.bilibili.com/room/v1/Room/playUrl", params, &data); err != nil {
			return PlayInfo{}, err
		}
		for _, line := range data.DURL {
			if liveMedia(line.URL, "bilivideo.com", "flv") || liveMedia(line.URL, "bilivideo.cn", "flv") {
				return PlayInfo{Kind: "direct", URL: line.URL, Format: "flv", Headers: headers}, nil
			}
		}
	case "douyu":
		return PlayInfo{Kind: "sniff", URL: "https://m.douyu.com/" + room, Headers: headers}, nil
	}
	return PlayInfo{}, fmt.Errorf("%s直播未提供可播放的公开流", livePlatform(platform))
}

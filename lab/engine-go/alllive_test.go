package main

import (
	"context"
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"
)

func TestAllLivePreservesNestedRoomsAndRenewsURLs(t *testing.T) {
	const title = "决赛 + A|B #1"
	roomRequests := 0
	client := &http.Client{Transport: drpyTransport(func(request *http.Request) (*http.Response, error) {
		var body string
		query := request.URL.Query()
		switch request.URL.Host + request.URL.Path {
		case "www.huya.com/cache.php":
			if query.Get("gameId") != "1" || query.Get("page") != "2" {
				t.Fatalf("wrong room listing query %v", query)
			}
			body = `{"status":200,"data":{"totalPage":4,"totalCount":333,"datas":[{"profileRoom":"100","introduction":"决赛 + A|B #1","nick":"解说","screenshot":"poster"}]}}`
		case "mp.huya.com/cache.php":
			if query.Get("roomid") != "100" || query.Get("do") != "profileRoom" {
				t.Fatalf("wrong play query %v", query)
			}
			roomRequests++
			body = `{"status":200,"data":{"liveStatus":"ON","isRoomPay":false,"stream":{"hls":{"multiLine":[{"url":"https://bad.invalid/tv.m3u8"},{"url":"https://media.huya.com/tv.m3u8"}]}}}}`
		case "api.live.bilibili.com/room/v1/Area/getList":
			body = `{"code":0,"data":[{"id":2,"list":[{"id":"0","name":"全部"},{"id":"86","name":"英雄联盟"}]},{"id":3,"list":[{"id":1,"name":"手游"}]}]}`
		case "api.live.bilibili.com/room/v1/area/getRoomList":
			if query.Get("area_id") != "86" || query.Get("page") != "2" {
				t.Fatal("lost Bilibili area or page")
			}
			body = `{"code":0,"data":[{"roomid":200,"title":"决赛 + A|B #1","uname":"解说","show_cover":"poster"}]}`
		case "api.live.bilibili.com/room/v1/Room/playUrl":
			if query.Get("cid") != "200" {
				t.Fatal("lost Bilibili room id")
			}
			roomRequests++
			body = `{"code":0,"data":{"durl":[{"url":"https://live.bilivideo.com/watch.flv"}]}}`
		case "m.douyu.com/api/room/list":
			if query.Get("type") != "LOL" || query.Get("page") != "2" {
				t.Fatal("lost Douyu area or page")
			}
			body = `{"code":0,"data":{"pageCount":3,"list":[{"rid":300,"roomName":"决赛 + A|B #1","nickname":"解说","roomSrc":"poster"}]}}`
		default:
			t.Fatalf("unexpected official request %s%s", request.URL.Host, request.URL.Path)
		}
		if request.Method != http.MethodGet || request.URL.Scheme != "https" || request.Header.Get("Referer") == "" || request.Header.Get("Cookie") != "" {
			t.Fatal("unexpected platform request headers")
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body)), Header: make(http.Header), Request: request}, nil
	})}
	live := newAllLiveProvider(client)
	site := Site{Key: "alllive", API: "csp_Alllive", Type: 3}
	ctx := context.Background()
	home, err := live.Home(ctx, site)
	if !live.accepts(site) || live.accepts(Site{Type: 3, API: site.API, Key: "unrelated"}) || err != nil || len(home.Classes) != 3 || len(home.List) != 0 {
		t.Fatal("incorrect station or home")
	}
	for _, match := range []struct{ platform, folder, kind string }{{"huya", "room|huya|1", "direct"}, {"bili", "room|bili|86", "direct"}, {"douyu", "room|douyu|LOL", "sniff"}} {
		folders, err := live.Category(ctx, site, match.platform, 1, nil)
		if err != nil || len(folders.List) == 0 || folders.List[0].ID != match.folder || folders.List[0].Tag != "folder" || folders.PageCount != 1 {
			t.Fatalf("%s lost its folder: %v", match.platform, err)
		}
		leaf, err := live.Category(ctx, site, match.folder, 2, nil)
		if err != nil || leaf.Page != 2 || len(leaf.List) != 1 || leaf.List[0].Tag != "" || leaf.List[0].Remarks != "解说" {
			t.Fatalf("%s lost its paged rooms: %v", match.platform, err)
		}
		detail, err := live.Detail(ctx, site, leaf.List[0].ID)
		if err != nil || detail.Name != title || len(detail.Lines) != 1 || len(detail.Lines[0].Episodes) != 1 {
			t.Fatalf("%s failed to recover the original room title: %v", match.platform, err)
		}
		for attempt := 0; attempt < 2; attempt++ {
			play, err := live.Play(ctx, site, detail.Lines[0].Name, detail.Lines[0].Episodes[0].ID)
			if err != nil || play.Kind != match.kind || play.URL == "" || play.Headers["Referer"] == "" || strings.Contains(play.URL, "bad.invalid") {
				t.Fatalf("%s failed to resolve a room: %v", match.platform, err)
			}
		}
	}
	if roomRequests != 4 {
		t.Fatal("replay should refresh both expiring direct streams")
	}
}

func TestAllLiveRejectsInvalidRoomAndRestrictedStreams(t *testing.T) {
	for _, id := range []string{"room|huya|1", "play|huya|https://localhost|room", "play|bili|0|bad", "play|other|1|name", "play|huya|1|%zz", "play|huya|1|"} {
		if _, _, _, err := liveRoomID(id); !errors.Is(err, errBadInput) {
			t.Fatalf("accepted invalid room id %q", id)
		}
	}
	for _, body := range []string{
		`{"status":403,"data":{}}`,
		`{"status":200,"data":{"liveStatus":"OFF"}}`,
		`{"status":200,"data":{"liveStatus":"ON","isRoomPay":true,"stream":{"hls":{"multiLine":[{"url":"https://media.huya.com/tv.m3u8"}]}}}}`,
		`{"status":200,"data":{"liveStatus":"ON","stream":{"hls":{"multiLine":[{"url":"https://huya.com.invalid/tv.m3u8"},{"url":"https://user@media.huya.com/tv.m3u8"}]}}}}`,
	} {
		live := newAllLiveProvider(&http.Client{Transport: drpyTransport(func(*http.Request) (*http.Response, error) {
			return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body))}, nil
		})})
		if _, err := live.Play(context.Background(), Site{}, "虎牙", "play|huya|1|room"); err == nil {
			t.Fatal("reported playback for an unavailable stream")
		}
	}
}

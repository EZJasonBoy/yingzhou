package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"
)

type sampleFixture struct{ provider }

func (sampleFixture) Home(context.Context, Site) (Home, error) {
	return Home{Classes: []Class{{ID: "1", Name: "电影"}}}, nil
}

func (sampleFixture) Category(context.Context, Site, string, int, map[string]string) (Page, error) {
	return Page{List: []Card{{ID: "a", Name: "春"}, {ID: "b", Name: "冬"}, {ID: "c"}, {ID: "d"}}}, nil
}

func (sampleFixture) Detail(context.Context, Site, string) (Detail, error) {
	return Detail{Name: "影片", Lines: []Line{{Name: "可移植", Episodes: []Episode{{ID: "opaque-private"}, {ID: "second"}}}, {Name: "需要宿主", Episodes: []Episode{{ID: "local"}}}}}, nil
}

func (sampleFixture) Play(_ context.Context, _ Site, line, id string) (PlayInfo, error) {
	if line == "需要宿主" {
		return PlayInfo{Kind: "direct", URL: "http://localhost:9978/proxy"}, nil
	}
	if id == "second" {
		return PlayInfo{Kind: "direct", URL: "https://media.example.org/channel-2.m3u8"}, nil
	}
	return PlayInfo{Kind: "direct", URL: "https://media.example.org/movie.mp4"}, nil
}

func TestDrama2SampleRoundTrip(t *testing.T) {
	site := Site{Key: "干饭", Type: 3, API: "csp_AppDrama2"}
	ctx := context.Background()
	sample, err := exportDrama2Sample(ctx, site, sampleFixture{}, sampleSelection{Category: "1", Page: 1, Limit: 3, Episodes: 1})
	if err != nil || len(sample.Items) != 3 || sample.NonPortable != 3 || sample.Dropped["local-or-invalid-url"] != 3 {
		t.Fatal(sample, err)
	}
	encoded, err := json.Marshal(sample)
	if err != nil || bytes.Contains(encoded, []byte("opaque-private")) || bytes.Contains(encoded, []byte("localhost")) {
		t.Fatal("unexpected source data", err)
	}
	player, err := newDrama2SampleProvider(bytes.NewReader(encoded))
	if err != nil {
		t.Fatal(err)
	}
	home, err := player.Home(ctx, site)
	if err != nil || home.Classes[0].Name != "电影" {
		t.Fatal(home, err)
	}
	page, err := player.Category(ctx, site, "1", 2, nil)
	if err != nil || len(page.List) != 0 || page.Total != 3 {
		t.Fatal(page, err)
	}
	page, err = player.Search(ctx, site, "春", 1)
	if err != nil || len(page.List) != 1 {
		t.Fatal(page, err)
	}
	detail, err := player.Detail(ctx, site, page.List[0].ID)
	if err != nil || len(detail.Lines) != 1 || len(detail.Lines[0].Episodes) != 1 {
		t.Fatal(detail, err)
	}
	play, err := player.Play(ctx, site, detail.Lines[0].Name, detail.Lines[0].Episodes[0].ID)
	if err != nil || !strings.HasSuffix(play.URL, "movie.mp4") {
		t.Fatal(play, err)
	}
}

func TestDrama2SampleSelectsRequestedCard(t *testing.T) {
	site := Site{Key: "干饭", Type: 3, API: "csp_AppDrama2"}
	document := subscription{Sites: []Site{site}}
	selection := sampleSelection{Category: "1", ItemID: "b", Page: 1, Limit: 1, Episodes: 2}
	sample, err := captureSample(context.Background(), document, sampleFixture{}, selection)
	if err != nil || len(sample.Items) != 1 || sample.Items[0].Card.Name != "冬" {
		t.Fatalf("targeted sample: %+v, %v", sample, err)
	}
	lines := sample.Items[0].Detail.Lines
	if len(lines) != 1 || len(lines[0].Episodes) != 2 {
		t.Fatalf("episodes: %+v", lines)
	}
	player := drama2SampleProvider{sample: *sample}
	switched, err := player.Play(context.Background(), site, lines[0].Name, lines[0].Episodes[1].ID)
	if err != nil || !strings.HasSuffix(switched.URL, "channel-2.m3u8") {
		t.Fatal("second channel unavailable", err)
	}
	selection.ItemID = "missing"
	if _, err := captureSample(context.Background(), document, sampleFixture{}, selection); !errors.Is(err, errBadInput) {
		t.Fatalf("missing card: %v", err)
	}
}

func TestDrama2SampleRejectsNonportableMedia(t *testing.T) {
	for _, info := range []PlayInfo{{Kind: "sniff", URL: "https://public.example.org"}, {Kind: "direct", URL: "http://[::1]/movie"}, {Kind: "direct", URL: "http://192.168.1.2/movie"}, {Kind: "direct", URL: "https://media.example.org/movie?expires=100"}, {Kind: "direct", URL: "https://media.example.org/movie", Headers: map[string]string{"Cookie": "private"}}, {Kind: "direct", URL: "https://media.example.org/movie", Headers: map[string]string{"Authorization": "private"}}} {
		if _, reason := sampleMedia(info, time.Now()); reason == "" {
			t.Error("accepted nonportable media")
		}
	}
}

func TestDrama2SampleUnwrapsOwnDirectHLS(t *testing.T) {
	host := &drama2Host{base: "http://127.0.0.1:9978/api/v1"}
	const inner = "https://cdn.example.org/index.m3u8?pkey=sample"
	const wrapper = "http://127.0.0.1:9978/m3u8?d=1&url=https%3A%2F%2Fcdn.example.org%2Findex.m3u8%3Fpkey%3Dsample&tvsig=outer"
	if result := sampleHostMedia(host, PlayInfo{Kind: "direct", URL: wrapper}); result.URL != inner {
		t.Errorf("expected inner URL")
	}
	for _, invalid := range []string{wrapper + "&url=extra", wrapper + "&h=private", wrapper + "&headers=private", strings.Replace(wrapper, "9978", "9979", 1), strings.Replace(wrapper, "/m3u8", "/proxy", 1), strings.Replace(wrapper, "d=1", "d=0", 1)} {
		if sampleHostMedia(host, PlayInfo{Kind: "direct", URL: invalid}).URL != invalid {
			t.Error("unwrapped unsupported wrapper")
		}
	}
	if sampleHostMedia(sampleFixture{}, PlayInfo{Kind: "direct", URL: wrapper}).URL != wrapper {
		t.Error("unwrapped foreign provider")
	}
}

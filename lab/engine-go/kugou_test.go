package main

import (
	"context"
	"io"
	"net/http"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"testing"
	"time"
)

func TestKugouPublicChartFolders(t *testing.T) {
	body := `<h3 data-index="0"><a title="热门榜单"><a title="TOP500" href="https://www.kugou.com/yy/rank/home/1-8888.html?from=rank"><h3 data-index="1"><a title="特色音乐榜"><a title="别的榜" href="https://www.kugou.com/yy/rank/home/1-999.html">`
	cards := kugouFolders(body, "酷狗", "hot")
	if len(cards) != 1 || cards[0].ID != "rank:8888" || cards[0].Tag != "folder" {
		t.Fatal(cards)
	}
	provider := kugouProvider{}
	if _, err := provider.Play(context.Background(), Site{}, "", "song:../../host"); err == nil {
		t.Fatal("invalid song accepted")
	}
	info, err := provider.Play(context.Background(), Site{}, "", "song:gb425vc4")
	if err != nil || info.Kind != "sniff" {
		t.Fatal(info, err)
	}
}

func TestKugouChartEpisodeUsesItsOwnPublishedHash(t *testing.T) {
	const trackHash = "1234567890abcdef1234567890abcdef"
	body := `<title>歌曲_高音质在线试听_酷狗</title><script>var dataFromSmarty = [{"encode_album_audio_id":"elsewhere","hash":"fedcba0987654321fedcba0987654321","song_name":"其他"},{"encode_album_audio_id":"chart12","hash":"` + trackHash + `","song_name":"歌曲","author_name":"歌手"}];</script>`
	client := &http.Client{Transport: drpyTransport(func(request *http.Request) (*http.Response, error) {
		if request.URL.Host != "www.kugou.com" || request.URL.Path != "/mixsong/chart12.html" {
			t.Fatal("unexpected chart detail request")
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body))}, nil
	})}
	provider := kugouProvider{client: client}
	if provider.accepts(Site{Type: 3, Key: "酷狗", API: "csp_Kugou", Ext: []byte(`{"classes":[{"type_id":"other"}]}`)}) {
		t.Fatal("accepted unrelated catalog")
	}
	detail, err := provider.Detail(context.Background(), Site{Key: "酷狗"}, "song:chart12")
	if err != nil || detail.Name != "歌曲" || detail.Actor != "歌手" || len(detail.Lines) != 1 || detail.Lines[0].Episodes[0].ID != "audio:"+trackHash {
		t.Fatalf("wrong chart song or episode: %v", err)
	}
}

func TestKugouLiveSearchAudio(t *testing.T) {
	if os.Getenv("YINGZHOU_TEST_KUGOU_LIVE") != "1" {
		t.Skip("live Kugou verification")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 35*time.Second)
	defer cancel()
	provider := kugouProvider{client: http.DefaultClient}
	site := Site{API: "csp_Kugou", Type: 3, Key: "酷狗", Ext: []byte(`{"classes":[{"type_id":"kugou"}]}`)}
	result, err := provider.Search(ctx, site, "慌啥子嘛", 1)
	if err != nil || len(result.List) == 0 {
		t.Fatalf("search: %v", err)
	}
	detail, err := provider.Detail(ctx, site, result.List[0].ID)
	if err != nil || detail.Name != "慌啥子嘛" {
		t.Fatalf("detail: %v", err)
	}
	play, err := provider.Play(ctx, site, "酷狗音乐", detail.Lines[0].Episodes[0].ID)
	if err != nil || play.Kind != "direct" {
		t.Fatalf("play: %v", err)
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, play.URL, nil)
	if err != nil {
		t.Fatal("invalid media URL")
	}
	request.Header.Set("Range", "bytes=0-262143")
	reply, err := provider.client.Do(request)
	if err != nil {
		t.Fatal("media request failed")
	}
	defer reply.Body.Close()
	if reply.StatusCode != 200 && reply.StatusCode != 206 {
		t.Fatalf("media HTTP %d", reply.StatusCode)
	}
	cmd := exec.CommandContext(ctx, "ffmpeg", "-v", "error", "-protocol_whitelist", "pipe", "-i", "pipe:0", "-map", "0:a:0", "-frames:a", "1", "-f", "framehash", "-")
	cmd.Stdin = io.LimitReader(reply.Body, 262144)
	output, err := cmd.Output()
	if err != nil || !strings.Contains(string(output), "#media_type 0: audio") || !regexp.MustCompile(`(?m)^0,\s*-?\d+,\s*-?\d+,\s*\d+,\s*[1-9]\d*,\s*[0-9a-f]{64}\s*$`).Match(output) {
		t.Fatal("audio decode failed")
	}
	t.Logf("%s / %s, %d search hits, %s", detail.Actor, detail.Name, result.Total, play.Format)
}

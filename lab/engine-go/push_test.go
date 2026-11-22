package main

import (
	"context"
	"errors"
	"testing"
)

func TestPushDirectMedia(t *testing.T) {
	ctx := context.Background()
	push := newPushProvider()
	site := Site{Key: "push_agent", API: "csp_Push"}
	urlMP4 := "https://media.example/clip.MP4?value=one$two#t=5"
	urlHLS := "https://media.example/live/stream.m3u8?key=demo"
	input := urlMP4 + "\r\n第二集$" + urlHLS + "\n"
	detail, err := push.Detail(ctx, site, input)
	if err != nil || len(detail.Lines) != 1 || len(detail.Lines[0].Episodes) != 2 {
		t.Fatalf("unexpected push detail: %+v, %v", detail, err)
	}
	if detail.ID != input || detail.Site != site.Key || detail.Lines[0].Episodes[0].Name != "clip.MP4" || detail.Lines[0].Episodes[1].Name != "第二集" {
		t.Fatalf("lost site, title or ID: %+v", detail)
	}
	for index, want := range []struct{ url, format string }{{urlMP4, "mp4"}, {urlHLS, "hls"}} {
		play, err := push.Play(ctx, site, detail.Lines[0].Name, detail.Lines[0].Episodes[index].ID)
		if err != nil || play.Kind != "direct" || play.URL != want.url || play.Format != want.format {
			t.Errorf("push result for episode %d: %+v, %v", index, play, err)
		}
	}
}

func TestPushRejectsUnsupportedInputs(t *testing.T) {
	ctx := context.Background()
	push := newPushProvider()
	site := Site{Key: "push_agent"}
	for _, input := range []string{"", "magnet:?xt=example", "file:///tmp/movie.mp4", "https://share.example/s/demo", "https://media.example/watch.html?file=video.mp4", "https://user@media.example/private.mp4", "https:///missing-host.mp4"} {
		if _, err := push.Detail(ctx, site, input); !errors.Is(err, errUnsupported) {
			t.Errorf("unexpected detail status for %q: %v", input, err)
		}
		if _, err := push.Play(ctx, site, "直连", input); !errors.Is(err, errUnsupported) {
			t.Errorf("unexpected play status for %q: %v", input, err)
		}
	}
	if _, err := push.Play(ctx, site, "嗅探", "https://media.example/file.mp4"); !errors.Is(err, errUnsupported) {
		t.Errorf("unsupported line returned %v", err)
	}
}

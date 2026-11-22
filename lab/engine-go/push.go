package main

import (
	"context"
	"fmt"
	"net/url"
	"path"
	"strings"
)

type pushProvider struct{}

func newPushProvider() provider {
	return pushProvider{}
}

func (pushProvider) Home(ctx context.Context, site Site) (Home, error) {
	return Home{Classes: []Class{}, List: []Card{}}, nil
}

func (pushProvider) Category(ctx context.Context, site Site, tid string, page int, filters map[string]string) (Page, error) {
	return Page{}, fmt.Errorf("%w: 推送站通过详情入口接收媒体链接", errUnsupported)
}

func (pushProvider) Search(ctx context.Context, site Site, query string, page int) (Page, error) {
	return Page{}, fmt.Errorf("%w: 推送站通过详情入口接收媒体链接", errUnsupported)
}

func (pushProvider) Detail(ctx context.Context, site Site, id string) (Detail, error) {
	var episodes []Episode
	for _, row := range strings.Split(id, "\n") {
		row = strings.TrimSpace(row)
		if row == "" {
			continue
		}
		name, address := "", row
		if !strings.HasPrefix(strings.ToLower(row), "http://") && !strings.HasPrefix(strings.ToLower(row), "https://") {
			if label, link, hasLabel := strings.Cut(row, "$"); hasLabel {
				name, address = strings.TrimSpace(label), strings.TrimSpace(link)
			}
		}
		media, _, err := pushMediaURL(address)
		if err != nil {
			return Detail{}, err
		}
		if name == "" {
			name = path.Base(media.Path)
		}
		episodes = append(episodes, Episode{ID: address, Name: name})
	}
	if len(episodes) == 0 {
		return Detail{}, fmt.Errorf("%w: 请输入推送的媒体链接", errUnsupported)
	}
	return Detail{Site: site.Key, ID: id, Name: episodes[0].Name, Lines: []Line{{Name: "直连", Episodes: episodes}}}, nil
}

func (pushProvider) Play(ctx context.Context, site Site, line, id string) (PlayInfo, error) {
	switch line {
	case "", "直连", "直連":
	default:
		return PlayInfo{}, fmt.Errorf("%w: 推送站支持直连线路", errUnsupported)
	}
	address := strings.TrimSpace(id)
	_, format, err := pushMediaURL(address)
	if err != nil {
		return PlayInfo{}, err
	}
	return PlayInfo{Kind: "direct", URL: address, Format: format}, nil
}

func pushMediaURL(address string) (*url.URL, string, error) {
	media, err := url.Parse(address)
	if err != nil || media.Hostname() == "" || media.User != nil || (media.Scheme != "http" && media.Scheme != "https") {
		return nil, "", fmt.Errorf("%w: 推送站需要 HTTP(S) 媒体直链", errUnsupported)
	}
	format := strings.ToLower(strings.TrimPrefix(path.Ext(media.Path), "."))
	switch format {
	case "m3u8":
		format = "hls"
	case "mpd":
		format = "dash"
	case "mp4", "webm", "mkv", "mov", "m4v", "flv", "ts", "mp3", "aac", "m4a", "ogg", "opus", "wav", "flac":
	default:
		return nil, "", fmt.Errorf("%w: 推送站需要带音视频或流清单扩展名的媒体直链", errUnsupported)
	}
	return media, format, nil
}

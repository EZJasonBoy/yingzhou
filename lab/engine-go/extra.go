package main

import (
	"context"
	"errors"
	"math"
	"net/http"
	"net/url"
	"strconv"
	"strings"
)

type doubanProvider struct {
	client   *http.Client
	endpoint string
}

func extraProviders(client *http.Client) map[string]provider {
	return map[string]provider{"csp_Douban": doubanProvider{client: client, endpoint: "https://movie.douban.com/j/search_subjects"}}
}

func (catalog doubanProvider) Home(ctx context.Context, site Site) (Home, error) {
	page, err := catalog.Category(ctx, site, "movie", 1, nil)
	if err != nil {
		return Home{}, err
	}
	return Home{Classes: []Class{{ID: "movie", Name: "热门电影"}, {ID: "tv", Name: "热门剧集"}}, List: page.List}, nil
}

func (catalog doubanProvider) Category(ctx context.Context, site Site, tid string, page int, filters map[string]string) (Page, error) {
	const pageSize = 20
	if tid != "movie" && tid != "tv" {
		return Page{}, errUnsupported
	}
	if page < 1 || page > math.MaxInt/pageSize {
		return Page{}, errors.New("invalid Douban page")
	}
	offset := (page - 1) * pageSize
	query := url.Values{"type": {tid}, "tag": {"热门"}, "page_limit": {strconv.Itoa(pageSize)}, "page_start": {strconv.Itoa(offset)}}
	var response struct {
		Subjects []struct{ Title, Cover, Rate string } `json:"subjects"`
	}
	if err := getJSON(ctx, catalog.client, catalog.endpoint+"?"+query.Encode(), nil, &response); err != nil {
		return Page{}, err
	}
	if response.Subjects == nil {
		return Page{}, errors.New("Douban returned no subjects field")
	}
	result := Page{Page: page, PageCount: page, Total: offset + len(response.Subjects), List: []Card{}}
	if len(response.Subjects) == pageSize {
		result.PageCount++
	}
	for _, subject := range response.Subjects {
		title := strings.TrimSpace(subject.Title)
		if title != "" {
			result.List = append(result.List, Card{Site: site.Key, ID: "msearch:" + title, Name: title, Pic: subject.Cover, Remarks: subject.Rate})
		}
	}
	return result, nil
}

func (doubanProvider) Search(context.Context, Site, string, int) (Page, error) {
	return Page{}, errUnsupported
}

func (doubanProvider) Detail(context.Context, Site, string) (Detail, error) {
	return Detail{}, errUnsupported
}

func (doubanProvider) Play(context.Context, Site, string, string) (PlayInfo, error) {
	return PlayInfo{}, errUnsupported
}

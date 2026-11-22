package main

import (
	"context"
	"encoding/json"
	"fmt"
	"html"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

const biliUserAgent = "Mozilla/5.0 (compatible; Yingzhou/1.0)"

var biliID = regexp.MustCompile(`^BV[0-9A-Za-z]{10}$`)
var biliHighlight = regexp.MustCompile(`(?i)</?em\b[^>]*>`)

type biliProvider struct {
	client  *http.Client
	apiBase string
	mu      sync.Mutex
	results map[string]biliVideo
	order   []string
}

func newBiliProvider(client *http.Client) *biliProvider {
	return &biliProvider{client: client, apiBase: "https://api.bilibili.com"}
}

type biliVideo struct {
	BVID        string `json:"bvid"`
	Title       string `json:"title"`
	Pic         string `json:"pic"`
	Author      string `json:"author"`
	Description string `json:"description"`
	Type        string `json:"typename"`
	Duration    string `json:"duration"`
	Pubdate     int64  `json:"pubdate"`
}

func biliText(value string) string {
	return strings.TrimSpace(html.UnescapeString(biliHighlight.ReplaceAllString(value, "")))
}

func biliWebURL(value string) string {
	if strings.HasPrefix(value, "//") {
		value = "https:" + value
	}
	parsed, err := url.Parse(value)
	if err != nil || parsed.Host == "" || parsed.User != nil || (parsed.Scheme != "https" && parsed.Scheme != "http") {
		return ""
	}
	return value
}

func biliHeaders(referer string) map[string]string {
	return map[string]string{"User-Agent": biliUserAgent, "Referer": referer}
}

func (provider *biliProvider) api(ctx context.Context, path string, values url.Values, result any) error {
	var envelope struct {
		Code    *int            `json:"code"`
		Message string          `json:"message"`
		Data    json.RawMessage `json:"data"`
	}
	address := provider.apiBase + path + "?" + values.Encode()
	if err := getJSON(ctx, provider.client, address, biliHeaders("https://www.bilibili.com/"), &envelope); err != nil {
		return fmt.Errorf("哔哩哔哩 %s: %w", path, err)
	}
	if envelope.Code == nil {
		return fmt.Errorf("哔哩哔哩 %s 的响应缺少状态码", path)
	}
	if *envelope.Code != 0 {
		return fmt.Errorf("哔哩哔哩 %s 返回 %d：%s", path, *envelope.Code, envelope.Message)
	}
	if len(envelope.Data) == 0 || string(envelope.Data) == "null" {
		return fmt.Errorf("哔哩哔哩 %s 缺少数据", path)
	}
	return json.Unmarshal(envelope.Data, result)
}

func (provider *biliProvider) Home(ctx context.Context, site Site) (Home, error) {
	var config struct {
		Catalog json.RawMessage `json:"json"`
	}
	catalog := site.Ext
	if json.Unmarshal(site.Ext, &config) == nil && len(config.Catalog) > 0 {
		catalog = config.Catalog
	}
	var categories struct {
		Classes []struct {
			ID   string `json:"type_id"`
			Name string `json:"type_name"`
		} `json:"class"`
		Filters map[string][]struct {
			Key    string `json:"key"`
			Name   string `json:"name"`
			Values []struct {
				Name  string `json:"n"`
				Value string `json:"v"`
			} `json:"value"`
		} `json:"filters"`
	}
	var address string
	if json.Unmarshal(catalog, &address) == nil && address != "" {
		if biliWebURL(address) == "" {
			return Home{}, fmt.Errorf("B 站栏目地址需要完整的 HTTP(S) URL")
		}
		if err := getJSON(ctx, provider.client, biliWebURL(address), nil, &categories); err != nil {
			return Home{}, fmt.Errorf("读取 B 站栏目失败: %w", err)
		}
	} else if err := json.Unmarshal(catalog, &categories); err != nil {
		return Home{}, fmt.Errorf("B 站栏目配置无效: %w", err)
	}
	home := Home{Filters: make(map[string][]Filter)}
	for _, class := range categories.Classes {
		if class.ID != "" && class.Name != "" {
			home.Classes = append(home.Classes, Class{ID: class.ID, Name: class.Name})
		}
	}
	if len(home.Classes) == 0 {
		return Home{}, fmt.Errorf("B 站栏目配置未包含有效分类")
	}
	for category, filters := range categories.Filters {
		for _, filter := range filters {
			option := Filter{Key: filter.Key, Name: filter.Name, Values: make([]FilterValue, 0, len(filter.Values))}
			for _, value := range filter.Values {
				option.Values = append(option.Values, FilterValue{Name: value.Name, Value: value.Value})
			}
			home.Filters[category] = append(home.Filters[category], option)
		}
	}
	return home, nil
}

func (provider *biliProvider) Category(ctx context.Context, site Site, tid string, page int, filters map[string]string) (Page, error) {
	if tid == "peizhi" {
		return Page{}, fmt.Errorf("%w：B 站登录配置需要账号交互，当前可浏览公开栏目", errUnsupported)
	}
	query := tid
	if subcategory := strings.TrimSpace(filters["tid"]); subcategory != "" && subcategory != "0" {
		query = subcategory
	}
	return provider.search(ctx, site, query, page, filters)
}

func (provider *biliProvider) Search(ctx context.Context, site Site, query string, page int) (Page, error) {
	return provider.search(ctx, site, query, page, nil)
}

func (provider *biliProvider) search(ctx context.Context, site Site, query string, page int, filters map[string]string) (Page, error) {
	if strings.TrimSpace(query) == "" {
		return Page{}, fmt.Errorf("请输入 B 站检索词")
	}
	if page < 1 {
		page = 1
	}
	values := url.Values{"search_type": {"video"}, "keyword": {query}, "page": {strconv.Itoa(page)}}
	for _, key := range []string{"order", "duration"} {
		if value := filters[key]; value != "" && value != "0" {
			values.Set(key, value)
		}
	}
	var data struct {
		Pages   int         `json:"numPages"`
		Total   int         `json:"numResults"`
		Results []biliVideo `json:"result"`
	}
	if err := provider.api(ctx, "/x/web-interface/search/type", values, &data); err != nil {
		return Page{}, err
	}
	result := Page{Page: page, PageCount: data.Pages, Total: data.Total}
	provider.mu.Lock()
	defer provider.mu.Unlock()
	if provider.results == nil {
		provider.results = make(map[string]biliVideo)
	}
	for _, video := range data.Results {
		if !biliID.MatchString(video.BVID) {
			continue
		}
		if _, exists := provider.results[video.BVID]; !exists {
			if len(provider.order) == 512 {
				delete(provider.results, provider.order[0])
				provider.order = provider.order[1:]
			}
			provider.order = append(provider.order, video.BVID)
		}
		provider.results[video.BVID] = video
		result.List = append(result.List, Card{Site: site.Key, ID: video.BVID, Name: biliText(video.Title), Pic: biliWebURL(video.Pic), Remarks: video.Duration})
	}
	return result, nil
}

func (provider *biliProvider) Detail(ctx context.Context, site Site, id string) (Detail, error) {
	if !biliID.MatchString(id) {
		return Detail{}, fmt.Errorf("无效的 B 站 BV 号")
	}
	var parts []struct {
		CID  int64  `json:"cid"`
		Page int    `json:"page"`
		Part string `json:"part"`
	}
	if err := provider.api(ctx, "/x/player/pagelist", url.Values{"bvid": {id}}, &parts); err != nil {
		return Detail{}, err
	}
	line := Line{Name: "哔哩哔哩"}
	for _, part := range parts {
		if part.CID <= 0 {
			continue
		}
		name := strings.TrimSpace(part.Part)
		if name == "" {
			name = "P" + strconv.Itoa(part.Page)
		}
		line.Episodes = append(line.Episodes, Episode{ID: id + ":" + strconv.FormatInt(part.CID, 10), Name: name})
	}
	if len(line.Episodes) == 0 {
		return Detail{}, fmt.Errorf("B 站视频没有公开分集")
	}
	provider.mu.Lock()
	video := provider.results[id]
	provider.mu.Unlock()
	detail := Detail{Site: site.Key, ID: id, Name: biliText(video.Title), Actor: video.Author, Pic: biliWebURL(video.Pic), Content: biliText(video.Description), Type: video.Type, Remarks: video.Duration, Lines: []Line{line}}
	if detail.Name == "" {
		detail.Name = line.Episodes[0].Name
	}
	if video.Pubdate > 0 {
		detail.Year = strconv.Itoa(time.Unix(video.Pubdate, 0).UTC().Year())
	}
	return detail, nil
}

func (provider *biliProvider) Play(ctx context.Context, site Site, line, id string) (PlayInfo, error) {
	bvid, cidText, found := strings.Cut(id, ":")
	cid, err := strconv.ParseInt(cidText, 10, 64)
	if !found || !biliID.MatchString(bvid) || err != nil || cid <= 0 {
		return PlayInfo{}, fmt.Errorf("B 站分集标识无效，请重新打开详情")
	}
	values := url.Values{"bvid": {bvid}, "cid": {strconv.FormatInt(cid, 10)}, "qn": {"32"}, "fnval": {"1"}, "platform": {"html5"}}
	var data struct {
		Format string `json:"format"`
		DURL   []struct {
			URL     string   `json:"url"`
			Backups []string `json:"backup_url"`
		} `json:"durl"`
	}
	if err := provider.api(ctx, "/x/player/playurl", values, &data); err != nil {
		return PlayInfo{}, err
	}
	if len(data.DURL) == 0 {
		return PlayInfo{}, fmt.Errorf("B 站未返回可直接播放的音视频流，请检查视频可见性、账号权限和地区限制")
	}
	if len(data.DURL) > 1 {
		return PlayInfo{}, fmt.Errorf("%w：B 站返回 %d 段媒体，当前播放器需要单一媒体地址", errUnsupported, len(data.DURL))
	}
	for _, address := range append([]string{data.DURL[0].URL}, data.DURL[0].Backups...) {
		if address = biliWebURL(address); address != "" {
			return PlayInfo{Kind: "direct", URL: address, Format: data.Format, Headers: biliHeaders("https://www.bilibili.com/video/" + bvid + "/")}, nil
		}
	}
	return PlayInfo{}, fmt.Errorf("B 站播放响应缺少有效的 HTTP 媒体地址")
}

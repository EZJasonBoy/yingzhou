package main

import (
	"bytes"
	"context"
	"encoding/json"
	"encoding/xml"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/url"
	"regexp"
	"slices"
	"strconv"
	"strings"
)

const drpyLoaderAPI = "./api/drpy2.min.js"
const drpyRule = "./js/兔小贝.js"
const drpyOrigin = "https://www.tuxiaobei.com"
const drpyUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Mobile/15E148 Safari/604.1"

var drpyClasses = []Class{{"2", "儿歌"}, {"3", "故事"}, {"4", "国学"}, {"25", "启蒙"}}
var drpyID = regexp.MustCompile(`^[1-9][0-9]{0,11}$`)
var drpyNonContent = regexp.MustCompile(`(?is)<!--.*?-->|<script\b[^>]*>.*?</script\s*>|<style\b[^>]*>.*?</style\s*>`)

type drpyProvider struct{ client *http.Client }

func newDrpyProvider(client *http.Client) *drpyProvider {
	if client == nil {
		client = http.DefaultClient
	}
	local := *client
	local.Jar = nil
	local.CheckRedirect = func(next *http.Request, via []*http.Request) error {
		address := next.URL
		if len(via) > 3 || address.Scheme != "https" || address.User != nil || !strings.EqualFold(address.Hostname(), "www.tuxiaobei.com") || address.Port() != "" && address.Port() != "443" {
			return http.ErrUseLastResponse
		}
		next.Header.Del("Referer")
		return nil
	}
	return &drpyProvider{client: &local}
}

func (*drpyProvider) accepts(site Site) bool {
	var rule string
	return site.Type == 3 && site.API == drpyLoaderAPI && json.Unmarshal(site.Ext, &rule) == nil && rule == drpyRule
}

func (provider *drpyProvider) fetch(ctx context.Context, route string) ([]byte, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, drpyOrigin+route, nil)
	if err != nil {
		return nil, err
	}
	request.Header.Set("User-Agent", drpyUA)
	response, err := provider.client.Do(request)
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, fmt.Errorf("无法连接兔小贝官网")
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("兔小贝官网返回 HTTP %d", response.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, maxJSONSize+1))
	if err != nil || len(body) > maxJSONSize {
		return nil, fmt.Errorf("兔小贝响应无法读取或超过 %d 字节", maxJSONSize)
	}
	return body, nil
}

func (provider *drpyProvider) Home(ctx context.Context, site Site) (Home, error) {
	body, err := provider.fetch(ctx, "/animate")
	if err != nil {
		return Home{}, err
	}
	cards, err := drpyHTMLCards(body, site.Key, true)
	if err != nil {
		return Home{}, err
	}
	return Home{Classes: slices.Clone(drpyClasses), List: cards}, nil
}

func (provider *drpyProvider) Category(ctx context.Context, site Site, tid string, page int, filters map[string]string) (Page, error) {
	if page < 1 || !slices.ContainsFunc(drpyClasses, func(class Class) bool { return class.ID == tid }) || len(filters) != 0 {
		return Page{}, fmt.Errorf("%w：无效的兔小贝分类、页码或筛选", errBadInput)
	}
	query := url.Values{"typeId": {tid}, "page": {strconv.Itoa(page)}, "callback": {""}}
	body, err := provider.fetch(ctx, "/list/mip-data?"+query.Encode())
	if err != nil {
		return Page{}, err
	}
	body = bytes.TrimSpace(bytes.TrimSuffix(bytes.TrimSpace(body), []byte(";")))
	if len(body) >= 2 && body[0] == '(' && body[len(body)-1] == ')' {
		body = body[1 : len(body)-1]
	}
	var response struct {
		Status *int `json:"status"`
		Data   struct {
			Items []struct {
				ID       json.Number `json:"video_id"`
				Name     string      `json:"name"`
				Image    string      `json:"image"`
				Duration string      `json:"duration_string"`
			} `json:"items"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &response); err != nil || response.Status == nil {
		return Page{}, fmt.Errorf("兔小贝分类响应格式有误")
	}
	if *response.Status != 0 {
		return Page{}, fmt.Errorf("兔小贝分类返回业务码 %d", *response.Status)
	}
	if response.Data.Items == nil {
		return Page{}, fmt.Errorf("兔小贝分类缺少 items")
	}
	result := Page{Page: page, PageCount: page}
	for _, item := range response.Data.Items {
		if !drpyID.MatchString(string(item.ID)) || strings.TrimSpace(item.Name) == "" {
			return Page{}, fmt.Errorf("兔小贝分类的影片缺少 ID 或标题")
		}
		result.List = append(result.List, Card{Site: site.Key, ID: string(item.ID), Name: item.Name, Pic: drpyResource(item.Image), Remarks: item.Duration})
	}
	const pageSize = 30
	if count := len(result.List); count >= pageSize && page < math.MaxInt {
		result.PageCount++
	} else if count != 0 && page-1 <= (math.MaxInt-count)/pageSize {
		result.Total = (page-1)*pageSize + count
	}
	return result, nil
}

func (provider *drpyProvider) Search(ctx context.Context, site Site, term string, page int) (Page, error) {
	term = strings.TrimSpace(term)
	if term == "" || page < 1 {
		return Page{}, fmt.Errorf("%w：需要关键词和有效页码", errBadInput)
	}
	if page > 1 {
		return Page{Page: page, PageCount: 1, List: []Card{}}, nil
	}
	body, err := provider.fetch(ctx, "/search/index?"+url.Values{"key": {term}}.Encode())
	if err != nil {
		return Page{}, err
	}
	cards, err := drpyHTMLCards(body, site.Key, false)
	if err != nil {
		return Page{}, err
	}
	return Page{Page: 1, PageCount: 1, Total: len(cards), List: cards}, nil
}

func drpyAttr(tag xml.StartElement, name string) string {
	for _, attr := range tag.Attr {
		if strings.EqualFold(attr.Name.Local, name) {
			return attr.Value
		}
	}
	return ""
}

func drpyResource(raw string) string {
	address, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || raw == "" || address.User != nil || address.Port() != "" {
		return ""
	}
	if address.Host == "" || address.Scheme == "" {
		base := url.URL{Scheme: "https", Host: "www.tuxiaobei.com", Path: "/"}
		address = base.ResolveReference(address)
	}
	if address.Scheme != "https" || !slices.Contains([]string{"www.tuxiaobei.com", "resource-cdn.tuxiaobei.com", "leyuan-cdn.tuxiaobei.com"}, address.Host) {
		return ""
	}
	return address.String()
}

func drpyLinkID(raw string) string {
	address, err := url.Parse(raw)
	if err != nil || address.User != nil || address.Host != "" && address.Host != "www.tuxiaobei.com" || address.Scheme != "" && address.Scheme != "https" {
		return ""
	}
	path := strings.TrimPrefix(address.Path, "/v2024")
	if id, ok := strings.CutPrefix(path, "/play/"); ok && drpyID.MatchString(id) {
		return id
	}
	return ""
}

func drpyHTML(body []byte) *xml.Decoder {
	decoder := xml.NewDecoder(bytes.NewReader(drpyNonContent.ReplaceAll(body, nil)))
	decoder.Strict = false
	decoder.Entity = xml.HTMLEntity
	return decoder
}

func drpyText(decoder *xml.Decoder, tag string) string {
	var text strings.Builder
	for {
		token, err := decoder.RawToken()
		if err != nil {
			return ""
		}
		switch element := token.(type) {
		case xml.CharData:
			text.Write(element)
		case xml.EndElement:
			if element.Name.Local == tag {
				return strings.Join(strings.Fields(text.String()), " ")
			}
		}
	}
}

func drpyHTMLCards(body []byte, siteKey string, home bool) ([]Card, error) {
	container, item := "div", "div"
	if home {
		container, item = "ul", "li"
	}
	decoder := drpyHTML(body)
	cards := []Card{}
	seen := map[string]bool{}
	var card Card
	var found bool
	var containerDepth, itemDepth int
	for {
		token, err := decoder.RawToken()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("无法读取兔小贝片单页面")
		}
		switch element := token.(type) {
		case xml.StartElement:
			tag := element.Name.Local
			classes := strings.Fields(drpyAttr(element, "class"))
			if tag == container {
				if containerDepth > 0 {
					containerDepth++
				} else if home && slices.Contains(classes, "list-box") && slices.Contains(classes, "on") || !home && slices.Contains(classes, "list-con") {
					containerDepth, found = 1, true
				}
			}
			if containerDepth == 0 {
				continue
			}
			if tag == item {
				if itemDepth > 0 {
					itemDepth++
				} else if home || slices.Contains(classes, "items") {
					itemDepth, card = 1, Card{Site: siteKey}
				}
			}
			if itemDepth == 0 {
				continue
			}
			switch {
			case tag == "a" && card.ID == "":
				card.ID = drpyLinkID(drpyAttr(element, "href"))
			case tag == "mip-img" && card.Pic == "":
				card.Pic = drpyResource(drpyAttr(element, "src"))
			case tag == "p" && (slices.Contains(classes, "tit") || slices.Contains(classes, "title")):
				card.Name = drpyText(decoder, tag)
			case tag == "span" && slices.Contains(classes, "time"):
				card.Remarks = drpyText(decoder, tag)
			}
		case xml.EndElement:
			if element.Name.Local == item && itemDepth > 0 {
				itemDepth--
				if itemDepth == 0 && card.ID != "" && card.Name != "" && !seen[card.ID] {
					seen[card.ID] = true
					cards = append(cards, card)
				}
			}
			if element.Name.Local == container && containerDepth > 0 {
				containerDepth--
			}
		}
	}
	if !found {
		return nil, fmt.Errorf("兔小贝页面缺少影片列表")
	}
	return cards, nil
}

func (provider *drpyProvider) video(ctx context.Context, id string) (title, pic, media string, err error) {
	if !drpyID.MatchString(id) {
		return "", "", "", fmt.Errorf("%w：无效的兔小贝影片 ID", errBadInput)
	}
	body, err := provider.fetch(ctx, "/play/"+id)
	if err != nil {
		return "", "", "", err
	}
	decoder := drpyHTML(body)
	for {
		token, parseErr := decoder.RawToken()
		if parseErr == io.EOF {
			break
		}
		if parseErr != nil {
			return "", "", "", fmt.Errorf("无法读取兔小贝影片页面")
		}
		if element, ok := token.(xml.StartElement); ok {
			switch {
			case drpyAttr(element, "id") == "videoWrap":
				media, pic = drpyResource(drpyAttr(element, "video-src")), drpyResource(drpyAttr(element, "poster"))
			case element.Name.Local == "h1" && title == "":
				title = drpyText(decoder, "h1")
			}
		}
		if title != "" && media != "" {
			break
		}
	}
	if title == "" {
		err = fmt.Errorf("兔小贝页面缺少影片标题")
	}
	return title, pic, media, err
}

func (provider *drpyProvider) Detail(ctx context.Context, site Site, id string) (Detail, error) {
	title, pic, media, err := provider.video(ctx, id)
	if err != nil {
		return Detail{}, err
	}
	result := Detail{Site: site.Key, ID: id, Name: title, Pic: pic}
	if media != "" {
		result.Lines = []Line{{Name: "兔小贝", Episodes: []Episode{{ID: id, Name: title}}}}
	}
	return result, nil
}

func (provider *drpyProvider) Play(ctx context.Context, _ Site, _ string, id string) (PlayInfo, error) {
	_, _, media, err := provider.video(ctx, id)
	if err != nil {
		return PlayInfo{}, err
	}
	if media == "" {
		return PlayInfo{}, fmt.Errorf("兔小贝页面缺少可播放的官方媒体地址")
	}
	_, format, err := pushMediaURL(media)
	if err != nil {
		return PlayInfo{}, fmt.Errorf("兔小贝媒体地址无效")
	}
	return PlayInfo{Kind: "direct", URL: media, Format: format}, nil
}

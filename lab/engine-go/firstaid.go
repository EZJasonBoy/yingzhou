package main

import (
	"bytes"
	"context"
	"encoding/xml"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"slices"
	"strings"
)

const firstAidOrigin = "https://m.youlai.cn"
const firstAidUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/117.0.0.0 Safari/537.36"
const firstAidLine = "Qile"

var firstAidClasses = []Class{{"jijiu|0", "急救技能"}, {"jijiu|1", "家庭生活"}, {"jijiu|2", "急危重症"}, {"jijiu|3", "常见损伤"}, {"jijiu|4", "动物致伤"}, {"jijiu|5", "海洋急救"}, {"jijiu|6", "中毒急救"}, {"jijiu|7", "意外事故"}}
var firstAidArticlePath = regexp.MustCompile(`^/(?:jijiu|video)/article/[A-Za-z0-9_-]{1,80}\.html$`)

type firstAidProvider struct{ client *http.Client }

func newFirstAidProvider(client *http.Client) *firstAidProvider {
	if client == nil {
		client = http.DefaultClient
	}
	local := *client
	local.Jar = nil
	local.CheckRedirect = func(next *http.Request, via []*http.Request) error {
		if len(via) > 3 || !firstAidHost(next.URL, "m.youlai.cn") {
			return http.ErrUseLastResponse
		}
		next.Header.Del("Referer")
		return nil
	}
	return &firstAidProvider{client: &local}
}

func firstAidHost(address *url.URL, hosts ...string) bool {
	return address.Scheme == "https" && address.User == nil && (address.Port() == "" || address.Port() == "443") && slices.Contains(hosts, strings.ToLower(address.Hostname()))
}

func firstAidURL(raw string, hosts ...string) string {
	if strings.TrimSpace(raw) == "" {
		return ""
	}
	base := url.URL{Scheme: "https", Host: "m.youlai.cn", Path: "/"}
	address, err := base.Parse(strings.TrimSpace(raw))
	if err != nil || !firstAidHost(address, hosts...) {
		return ""
	}
	return address.String()
}

func firstAidArticle(raw string) string {
	address, err := url.Parse(firstAidURL(raw, "m.youlai.cn"))
	if err != nil || address.RawPath != "" || !firstAidArticlePath.MatchString(address.Path) {
		return ""
	}
	return firstAidOrigin + address.Path
}

func firstAidPicture(raw string) string {
	return firstAidURL(raw, "static.cnkang.com", "file.youlai.cn", "m.youlai.cn")
}

type firstAidNode struct {
	element  xml.StartElement
	chars    string
	children []*firstAidNode
}

func (node *firstAidNode) attr(name string) string {
	if node == nil {
		return ""
	}
	return drpyAttr(node.element, name)
}

func (node *firstAidNode) matches(selector string) bool {
	switch selector[0] {
	case '.':
		return slices.Contains(strings.Fields(node.attr("class")), selector[1:])
	case '#':
		return node.attr("id") == selector[1:]
	default:
		return node.element.Name.Local == selector
	}
}

func (node *firstAidNode) elements(selector string) []*firstAidNode {
	var result []*firstAidNode
	var visit func(*firstAidNode)
	visit = func(current *firstAidNode) {
		if current == nil || current.chars != "" {
			return
		}
		if current.matches(selector) {
			result = append(result, current)
		}
		for _, child := range current.children {
			visit(child)
		}
	}
	visit(node)
	return result
}

func (node *firstAidNode) first(selector string) *firstAidNode {
	if found := node.elements(selector); len(found) != 0 {
		return found[0]
	}
	return nil
}

func (node *firstAidNode) text() string {
	var text strings.Builder
	var visit func(*firstAidNode)
	visit = func(current *firstAidNode) {
		if current == nil {
			return
		}
		if current.element.Name.Local == "p" || current.element.Name.Local == "br" {
			text.WriteByte(' ')
		}
		text.WriteString(current.chars)
		for _, child := range current.children {
			visit(child)
		}
	}
	visit(node)
	return strings.Join(strings.Fields(text.String()), " ")
}

func firstAidHTML(body []byte) (*firstAidNode, error) {
	root := &firstAidNode{}
	stack := []*firstAidNode{root}
	decoder := drpyHTML(bytes.ReplaceAll(body, []byte{0}, []byte("\uFFFD")))
	for count := 0; count < 100000 && len(stack) <= 128; count++ {
		token, err := decoder.RawToken()
		if err == io.EOF {
			return root, nil
		}
		if err != nil {
			return nil, fmt.Errorf("有来医生页面的 HTML 无法解析（字节 %d）", decoder.InputOffset())
		}
		parent := stack[len(stack)-1]
		switch element := token.(type) {
		case xml.StartElement:
			child := &firstAidNode{element: element.Copy()}
			parent.children = append(parent.children, child)
			switch element.Name.Local {
			case "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr":
			default:
				stack = append(stack, child)
			}
		case xml.EndElement:
			for index := len(stack) - 1; index > 0; index-- {
				if stack[index].element.Name.Local == element.Name.Local {
					stack = stack[:index]
					break
				}
			}
		case xml.CharData:
			if len(element) > 0 {
				parent.children = append(parent.children, &firstAidNode{chars: string(element)})
			}
		}
	}
	return nil, fmt.Errorf("有来医生页面过于复杂")
}

func (provider *firstAidProvider) page(ctx context.Context, address string) (*firstAidNode, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return nil, err
	}
	request.Header.Set("User-Agent", firstAidUA)
	response, err := provider.client.Do(request)
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, fmt.Errorf("无法连接有来医生")
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("有来医生返回 HTTP %d", response.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, maxJSONSize+1))
	if err != nil || len(body) > maxJSONSize {
		return nil, fmt.Errorf("有来医生页面无法读取或超过 %d 字节", maxJSONSize)
	}
	return firstAidHTML(body)
}

func (*firstAidProvider) Home(context.Context, Site) (Home, error) {
	return Home{Classes: slices.Clone(firstAidClasses)}, nil
}

func firstAidCard(site Site, row *firstAidNode, title, picture string) (Card, bool) {
	id := firstAidArticle(row.first("a").attr("href"))
	return Card{Site: site.Key, ID: id, Name: title, Pic: picture}, id != "" && title != ""
}

func (provider *firstAidProvider) Category(ctx context.Context, site Site, tid string, page int, filters map[string]string) (Page, error) {
	index := slices.IndexFunc(firstAidClasses, func(class Class) bool { return class.ID == tid })
	if index < 0 || page < 1 || len(filters) != 0 && (len(filters) != 1 || filters["cateId"] != "jijiu") {
		return Page{}, fmt.Errorf("%w：急救分类、页码或筛选无效", errBadInput)
	}
	result := Page{Page: page, PageCount: 1, List: []Card{}}
	if page > 1 {
		return result, nil
	}
	document, err := provider.page(ctx, firstAidOrigin+"/jijiu")
	if err != nil {
		return Page{}, err
	}
	groups := document.elements(".jj-title-li")
	if len(groups) != len(firstAidClasses) {
		return Page{}, fmt.Errorf("有来医生急救目录分组已变化")
	}
	var picture string
	if covers := document.elements(".block100"); index < len(covers) {
		picture = firstAidPicture(covers[index].attr("src"))
	}
	for _, item := range groups[index].elements(".list-br3") {
		if card, ok := firstAidCard(site, item, item.first("a").text(), picture); ok {
			result.List = append(result.List, card)
		}
	}
	result.Total = len(result.List)
	return result, nil
}

func (provider *firstAidProvider) Search(ctx context.Context, site Site, term string, page int) (Page, error) {
	term = strings.TrimSpace(term)
	if term == "" || page < 1 {
		return Page{}, fmt.Errorf("%w：需要关键词和有效页码", errBadInput)
	}
	result := Page{Page: page, PageCount: 1, List: []Card{}}
	if page > 1 {
		return result, nil
	}
	document, err := provider.page(ctx, firstAidOrigin+"/cse/search?"+url.Values{"q": {term}}.Encode())
	if err != nil {
		return Page{}, err
	}
	if document.first("#submitBtn") == nil && document.first(".search-video-list") == nil {
		return Page{}, fmt.Errorf("有来医生返回的页面缺少搜索结果区域")
	}
	for _, item := range document.elements(".search-video-li") {
		if !item.matches(".list-br2") {
			continue
		}
		title := item.first(".line-clamp1").text()
		picture := firstAidPicture(item.first(".logo-bg").first("img").attr("src"))
		if card, ok := firstAidCard(site, item, title, picture); ok {
			result.List = append(result.List, card)
		}
	}
	result.Total = len(result.List)
	return result, nil
}

func (provider *firstAidProvider) Detail(ctx context.Context, site Site, id string) (Detail, error) {
	address := firstAidArticle(id)
	if address == "" {
		return Detail{}, fmt.Errorf("%w：无效的有来医生视频文章", errBadInput)
	}
	document, err := provider.page(ctx, address)
	if err != nil {
		return Detail{}, err
	}
	title := document.first(".video-title").text()
	if title == "" && strings.Contains(address, "/video/article/") {
		title = document.first("h1").text()
	}
	if title == "" {
		return Detail{}, fmt.Errorf("有来医生视频文章缺少标题")
	}
	video := document.first("#video")
	media := firstAidURL(video.first("source").attr("src"), "vod.youlai.cn")
	if media == "" {
		media = firstAidURL(video.attr("src"), "vod.youlai.cn")
	}
	picture := firstAidPicture(video.attr("poster"))
	if picture == "" {
		picture = firstAidPicture(document.first(".video-cover").first("img").attr("src"))
	}
	detail := Detail{Site: site.Key, ID: address, Name: title, Pic: picture, Actor: document.first(".doc-name").text(), Area: "中国", Content: document.first(".img-text-con").text()}
	if _, _, err := pushMediaURL(media); err == nil {
		detail.Lines = []Line{{Name: firstAidLine, Episodes: []Episode{{ID: media, Name: title}}}}
	}
	return detail, nil
}

func (*firstAidProvider) Play(_ context.Context, _ Site, line, id string) (PlayInfo, error) {
	if line != "" && line != firstAidLine {
		return PlayInfo{}, fmt.Errorf("%w：有来医生没有这条线路", errBadInput)
	}
	media := firstAidURL(id, "vod.youlai.cn")
	_, format, err := pushMediaURL(media)
	if err != nil {
		return PlayInfo{}, fmt.Errorf("%w：有来医生未提供可辨识的官方媒体地址", errBadInput)
	}
	return PlayInfo{Kind: "direct", URL: media, Format: format, Headers: map[string]string{"User-Agent": firstAidUA}}, nil
}

package main

import (
	"encoding/json"
	"fmt"
	"strings"
)

func parseDrama2Home(body []byte) (Home, error) {
	var response struct {
		Code *int   `json:"code"`
		Msg  string `json:"msg"`
		Data []struct {
			ID        json.Number `json:"id"`
			Name      string      `json:"name"`
			ConverURL string      `json:"converUrl"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &response); err != nil {
		return Home{}, fmt.Errorf("读取干饭栏目失败: %w", err)
	}
	if response.Code == nil {
		return Home{}, fmt.Errorf("干饭栏目响应缺少业务状态码")
	}
	if *response.Code != 200 {
		message := []rune(strings.Join(strings.Fields(response.Msg), " "))
		return Home{}, fmt.Errorf("干饭接口返回业务码 %d %s", *response.Code, string(message[:min(200, len(message))]))
	}
	if response.Data == nil {
		return Home{}, fmt.Errorf("干饭栏目响应缺少 data 数组")
	}
	result := Home{Filters: make(map[string][]Filter)}
	seen := make(map[string]bool)
	for _, entry := range response.Data {
		id, name := entry.ID.String(), strings.TrimSpace(entry.Name)
		if id == "" || name == "" || seen[id] {
			continue
		}
		seen[id] = true
		if name == "公告" {
			continue
		}
		result.Classes = append(result.Classes, Class{ID: id, Name: name})
		if filters := drama2Filters(entry.ConverURL); len(filters) > 0 {
			result.Filters[id] = filters
		}
	}
	if len(response.Data) > 0 && len(seen) == 0 {
		return Home{}, fmt.Errorf("干饭栏目缺少有效 ID 和名称")
	}
	return result, nil
}

func drama2Filters(encoded string) []Filter {
	var options map[string]string
	if json.Unmarshal([]byte(encoded), &options) != nil {
		return nil
	}
	var groups []Filter
	for _, spec := range []struct{ key, name string }{
		{"class", "类型"}, {"area", "地区"}, {"lang", "语言"}, {"year", "年份"}, {"extend_sort", "排序"},
	} {
		group := Filter{Key: spec.key, Name: spec.name, Values: []FilterValue{{Name: "全部"}}}
		seen := map[string]bool{"全部": true}
		for _, item := range strings.Split(options[spec.key], ",") {
			value := strings.TrimSpace(item)
			if value != "" && !seen[value] {
				seen[value] = true
				group.Values = append(group.Values, FilterValue{Name: value, Value: value})
			}
		}
		if len(group.Values) > 1 {
			groups = append(groups, group)
		}
	}
	return groups
}

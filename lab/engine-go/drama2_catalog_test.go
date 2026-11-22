package main

import (
	"reflect"
	"strings"
	"testing"
)

func TestDrama2HomeCategoriesAndFilters(t *testing.T) {
	const response = `{"code":200,"data":[{"id":2,"name":"电视剧","converUrl":"{\"class\":\"\\u53e4\\u88c5,战争,古装\",\"area\":\"内地,香港\",\"lang\":\"国语\",\"year\":\"2026,2025\",\"extend_sort\":\"最新,最热,好评\"}"},{"id":1,"name":"电影"},{"id":2,"name":"重复栏目"},{"id":99,"name":"公告"}]}`
	home, err := parseDrama2Home([]byte(response))
	if err != nil {
		t.Fatal(err)
	}
	if want := []Class{{ID: "2", Name: "电视剧"}, {ID: "1", Name: "电影"}}; !reflect.DeepEqual(home.Classes, want) {
		t.Fatalf("classes = %+v", home.Classes)
	}
	groups := home.Filters["2"]
	if len(groups) != 5 || groups[0].Key != "class" || groups[4].Key != "extend_sort" || len(home.Filters["1"]) != 0 {
		t.Fatalf("filters = %+v", home.Filters)
	}
	want := []FilterValue{{Name: "全部"}, {Name: "古装", Value: "古装"}, {Name: "战争", Value: "战争"}}
	if !reflect.DeepEqual(groups[0].Values, want) || groups[4].Values[2].Value != "最热" {
		t.Fatalf("filter values = %+v", groups)
	}
}

func TestDrama2HomeRejectsBusinessAndFormatErrors(t *testing.T) {
	for _, sample := range []string{`{"code":500,"msg":"公共参数请求头不能为空"}`, `{"data":[]}`, `{"code":200,"data":null}`, `{"code":200,"data":{}}`, `{"code":200,"data":[{"id":1}]}`, `<html>`} {
		if _, err := parseDrama2Home([]byte(sample)); err == nil {
			t.Errorf("expected error for %s", sample)
		} else if strings.Contains(sample, `"code":500`) && (!strings.Contains(err.Error(), "500") || !strings.Contains(err.Error(), "公共参数请求头不能为空")) {
			t.Errorf("missing upstream status: %v", err)
		}
	}
	home, err := parseDrama2Home([]byte(`{"code":200,"data":[{"id":2,"name":"电视剧","converUrl":"{invalid}"}]}`))
	if err != nil || len(home.Classes) != 1 || len(home.Filters) != 0 {
		t.Fatalf("category with damaged optional filters = %+v, %v", home, err)
	}
}

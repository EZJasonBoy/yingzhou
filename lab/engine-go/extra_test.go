package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestDoubanRecommendations(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		query := request.URL.Query()
		if query.Get("page_limit") != "20" || query.Get("tag") != "热门" {
			t.Errorf("unexpected query %v", query)
		}
		if query.Get("type") == "tv" && query.Get("page_start") == "20" {
			fmt.Fprint(writer, `{"subjects":[]}`)
			return
		}
		if query.Get("type") != "movie" || query.Get("page_start") != "0" {
			t.Errorf("unexpected query %v", query)
		}
		subjects := make([]map[string]string, 20)
		for index := range subjects {
			subjects[index] = map[string]string{"title": "片名", "rate": "8.6", "cover": "poster"}
		}
		json.NewEncoder(writer).Encode(map[string]any{"subjects": subjects})
	}))
	defer server.Close()
	catalog := doubanProvider{client: server.Client(), endpoint: server.URL}
	site := Site{Key: "豆瓣"}
	ctx := context.Background()
	home, err := catalog.Home(ctx, site)
	if err != nil || len(home.Classes) != 2 || len(home.List) != 20 {
		t.Fatalf("unexpected home %#v, error %v", home, err)
	}
	if card := home.List[0]; card.ID != "msearch:片名" || card.Site != site.Key || card.Pic != "poster" || card.Remarks != "8.6" {
		t.Errorf("unexpected card %#v", card)
	}
	page, err := catalog.Category(ctx, site, "movie", 1, nil)
	if err != nil || page.PageCount != 2 {
		t.Fatalf("unexpected first page %#v, error %v", page, err)
	}
	page, err = catalog.Category(ctx, site, "tv", 2, nil)
	if err != nil || page.PageCount != 2 || len(page.List) != 0 {
		t.Fatalf("unexpected last page %#v, error %v", page, err)
	}
}

func TestDoubanUpstreamError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		fmt.Fprint(writer, `{"message":"rate limited"}`)
	}))
	defer server.Close()
	catalog := doubanProvider{client: server.Client(), endpoint: server.URL}
	if _, err := catalog.Home(context.Background(), Site{}); err == nil {
		t.Fatal("expected an error for an unrecognized response")
	}
}

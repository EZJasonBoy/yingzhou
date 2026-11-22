package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
)

type mobileLibraryEntry struct {
	Site         string `json:"site"`
	VodID        string `json:"vodId"`
	Name         string `json:"name"`
	Pic          string `json:"pic,omitempty"`
	Remarks      string `json:"remarks,omitempty"`
	Line         string `json:"line,omitempty"`
	EpisodeID    string `json:"episodeId,omitempty"`
	EpisodeName  string `json:"episodeName,omitempty"`
	EpisodeIndex int    `json:"episodeIndex,omitempty"`
	PositionMs   int64  `json:"positionMs,omitempty"`
	DurationMs   int64  `json:"durationMs,omitempty"`
	UpdatedAt    int64  `json:"updatedAt,omitempty"`
	AddedAt      int64  `json:"addedAt,omitempty"`
	Subtitle     string `json:"subtitle,omitempty"`
	Audio        string `json:"audio,omitempty"`
}

type mobileLibrary struct {
	History   []mobileLibraryEntry `json:"history"`
	Favorites []mobileLibraryEntry `json:"favorites"`
}

const mobileLibraryFile = "library.json"

func (service *mobileEngine) loadLibrary() error {
	if service.library != nil {
		return nil
	}
	var stored mobileLibrary
	file, err := os.Open(filepath.Join(service.dataDir, mobileLibraryFile))
	if err == nil {
		defer file.Close()
		body, err := io.ReadAll(io.LimitReader(file, mobileStoreLimit+1))
		if err != nil || len(body) > mobileStoreLimit || json.Unmarshal(body, &stored) != nil {
			return errors.New("invalid library file")
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	service.library = &stored
	return nil
}

func (service *mobileEngine) serveMobileExtras(writer http.ResponseWriter, request *http.Request) bool {
	path := strings.TrimPrefix(request.URL.EscapedPath(), "/api/v1/")
	if path == "search/stream" {
		if request.Method != http.MethodGet {
			writer.Header().Set("Allow", "GET")
			mobileError(writer, 405, "METHOD_NOT_ALLOWED", "请使用 GET")
		} else {
			service.searchStream(writer, request)
		}
		return true
	}
	collection, item, hasItem := strings.Cut(path, "/")
	if collection != "history" && collection != "favorites" {
		return false
	}
	var site, vodID string
	if hasItem {
		encodedSite, encodedID, ok := strings.Cut(item, "/")
		var siteErr, idErr error
		site, siteErr = url.PathUnescape(encodedSite)
		vodID, idErr = url.PathUnescape(encodedID)
		if !ok || site == "" || vodID == "" || strings.Contains(encodedID, "/") || siteErr != nil || idErr != nil {
			mobileError(writer, 404, "NOT_FOUND", "条目地址无效")
			return true
		}
	}
	var entry mobileLibraryEntry
	if hasItem && request.Method == http.MethodPut {
		if err := readJSON(http.MaxBytesReader(writer, request.Body, 64<<10), &entry); err != nil || entry.Name == "" {
			mobileError(writer, 400, "BAD_REQUEST", "条目需要名称及有效的 JSON")
			return true
		}
		entry.Site, entry.VodID = site, vodID
	}
	status, payload := service.libraryOperation(request.Method, collection, site, vodID, request.URL.Query().Get("limit"), entry)
	switch status {
	case http.StatusOK:
		writeJSON(writer, status, payload)
	case http.StatusNoContent:
		writer.WriteHeader(status)
	case http.StatusNotFound:
		mobileError(writer, status, "NOT_FOUND", "找不到这个条目")
	case http.StatusMethodNotAllowed:
		allowed := "GET"
		if hasItem {
			allowed = "GET, PUT, DELETE"
		} else if collection == "history" {
			allowed = "GET, DELETE"
		}
		writer.Header().Set("Allow", allowed)
		mobileError(writer, status, "METHOD_NOT_ALLOWED", "此操作不可用")
	default:
		mobileError(writer, status, "STORAGE_ERROR", "无法读写本机播放记录")
	}
	return true
}

func (service *mobileEngine) libraryOperation(method, collection, site, vodID, limit string, entry mobileLibraryEntry) (int, any) {
	service.libraryMu.Lock()
	defer service.libraryMu.Unlock()
	if err := service.loadLibrary(); err != nil {
		return http.StatusInternalServerError, nil
	}
	next := *service.library
	entries := &next.Favorites
	history := collection == "history"
	if history {
		entries = &next.History
	}
	index := slices.IndexFunc(*entries, func(item mobileLibraryEntry) bool { return item.Site == site && item.VodID == vodID })
	status := http.StatusNoContent
	var payload any
	switch method {
	case http.MethodGet:
		if site == "" {
			count := len(*entries)
			if history {
				maxEntries, err := strconv.Atoi(limit)
				if err != nil {
					maxEntries = 100
				}
				count = min(count, max(1, min(500, maxEntries)))
			}
			if count == 0 {
				return http.StatusOK, []mobileLibraryEntry{}
			}
			return http.StatusOK, (*entries)[:count]
		}
		if index < 0 {
			return http.StatusNotFound, nil
		}
		return http.StatusOK, (*entries)[index]
	case http.MethodPut:
		if site == "" {
			return http.StatusMethodNotAllowed, nil
		}
		items := slices.Clone(*entries)
		now := time.Now().UnixMilli()
		if history {
			entry.UpdatedAt, entry.AddedAt = now, 0
			if index >= 0 {
				items = slices.Delete(items, index, index+1)
			}
			*entries = slices.Insert(items, 0, entry)[:min(500, len(items)+1)]
		} else if index >= 0 {
			entry.AddedAt, entry.UpdatedAt = items[index].AddedAt, 0
			items[index] = entry
			*entries = items
		} else {
			entry.AddedAt, entry.UpdatedAt = now, 0
			*entries = slices.Insert(items, 0, entry)
		}
		status, payload = http.StatusOK, entry
	case http.MethodDelete:
		if site == "" {
			if !history {
				return http.StatusMethodNotAllowed, nil
			}
			*entries = nil
		} else if index >= 0 {
			*entries = slices.Delete(slices.Clone(*entries), index, index+1)
		} else {
			return status, nil
		}
	default:
		return http.StatusMethodNotAllowed, nil
	}
	if err := writeMobileJSON(service.dataDir, mobileLibraryFile, next); err != nil {
		return http.StatusInternalServerError, nil
	}
	service.library = &next
	return status, payload
}

type mobileSearchEvent struct {
	name string
	data any
}

func (service *mobileEngine) searchStream(writer http.ResponseWriter, request *http.Request) {
	query := request.URL.Query()
	keyword := strings.TrimSpace(query.Get("wd"))
	if keyword == "" {
		mobileError(writer, 400, "BAD_REQUEST", "请输入搜索词")
		return
	}
	active := service.activeEngine()
	if active == nil {
		mobileError(writer, 409, "NO_CONFIG", "请先激活订阅")
		return
	}
	selected := strings.Split(query.Get("sites"), ",")
	jobs := make(chan Site, len(active.converted.Sites))
	for _, exported := range active.converted.Sites {
		if exported.Searchable != nil && *exported.Searchable == 0 || query.Has("sites") && !slices.Contains(selected, exported.Key) {
			continue
		}
		jobs <- active.sites[exported.Key]
	}
	count := len(jobs)
	close(jobs)
	ctx, cancel := context.WithCancel(request.Context())
	defer cancel()
	started := time.Now()
	events := make(chan mobileSearchEvent)
	send := func(name string, data any) {
		select {
		case events <- mobileSearchEvent{name, data}:
		case <-ctx.Done():
		}
	}
	var workers sync.WaitGroup
	for worker := 0; worker < min(count, 4); worker++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for site := range jobs {
				if ctx.Err() != nil {
					return
				}
				send("site", map[string]any{"site": site.Key, "status": "started"})
				start := time.Now()
				timeout := 20 * time.Second
				if site.Timeout > 0 {
					timeout = time.Duration(min(site.Timeout, 60)) * time.Second
				}
				siteCtx, stop := context.WithTimeout(ctx, timeout)
				page, err := active.routes[site.Key].Search(siteCtx, site, keyword, 1)
				stop()
				status := map[string]any{"site": site.Key, "ms": time.Since(start).Milliseconds()}
				if err != nil {
					status["status"], status["message"] = "error", "站点搜索失败"
				} else {
					if len(page.List) > 0 {
						send("results", map[string]any{"site": site.Key, "items": mobileCards(site.Key, page.List)})
					}
					status["status"], status["count"] = "done", len(page.List)
				}
				send("site", status)
			}
		}()
	}
	go func() { workers.Wait(); close(events) }()
	writer.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
	writer.Header().Set("Cache-Control", "no-store")
	controller := http.NewResponseController(writer)
	flush := func(event mobileSearchEvent) bool {
		payload, err := json.Marshal(event.data)
		if err != nil {
			return false
		}
		_, err = fmt.Fprintf(writer, "event: %s\ndata: %s\n\n", event.name, payload)
		return err == nil && controller.Flush() == nil
	}
	for event := range events {
		if !flush(event) {
			return
		}
	}
	flush(mobileSearchEvent{"end", map[string]int64{"sites": int64(count), "ms": time.Since(started).Milliseconds()}})
}

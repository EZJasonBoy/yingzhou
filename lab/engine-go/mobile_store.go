package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"
)

const mobileStoreLimit = 16 << 20

type mobileSubscription struct {
	ID     string `json:"id"`
	URL    string `json:"url"`
	Name   string `json:"name"`
	UsedAt int64  `json:"usedAt"`
}

type mobileState struct {
	Subscriptions []mobileSubscription `json:"subscriptions"`
	ActiveID      string               `json:"activeId,omitempty"`
	Document      *subscription        `json:"document,omitempty"`
}

type mobileEngine struct {
	client    *http.Client
	providers map[string]provider
	dataDir   string
	mux       *http.ServeMux
	mutation  sync.Mutex
	mu        sync.RWMutex
	state     mobileState
	active    *engine
	stored    bool
	libraryMu sync.Mutex
	library   *mobileLibrary
}

const mobileStateFile = "go-subscriptions.json"

func newMobileEngine(dataDir string, client *http.Client) (*mobileEngine, error) {
	if !filepath.IsAbs(dataDir) {
		return nil, errors.New("需要应用数据目录的绝对路径")
	}
	if err := os.MkdirAll(dataDir, 0700); err != nil {
		return nil, err
	}
	service := &mobileEngine{dataDir: dataDir, client: client, providers: pureGoProviders(client), state: mobileState{Subscriptions: []mobileSubscription{}}}
	file, err := os.Open(filepath.Join(dataDir, mobileStateFile))
	if err == nil {
		defer file.Close()
		encoded, readErr := io.ReadAll(io.LimitReader(file, mobileStoreLimit+1))
		if readErr != nil || len(encoded) > mobileStoreLimit || json.Unmarshal(encoded, &service.state) != nil {
			return nil, errors.New("无法读取 Go 引擎保存的订阅")
		}
		if service.state.Document != nil && service.state.index(service.state.ActiveID) >= 0 {
			restored, rebuildErr := newEngine(*service.state.Document, service.providers)
			if rebuildErr == nil && len(restored.routes) > 0 {
				service.active, service.stored = restored, true
			}
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	service.mux = service.mobileRoutes()
	return service, nil
}

func writeMobileJSON(dir, name string, value any) error {
	encoded, err := json.Marshal(value)
	if err != nil {
		return err
	}
	if len(encoded) > mobileStoreLimit {
		return errors.New("数据超过本机存储上限")
	}
	file, err := os.CreateTemp(dir, ".go-state-*")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	if _, err = file.Write(encoded); err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(file.Name(), filepath.Join(dir, name))
}

func (state mobileState) index(id string) int {
	return slices.IndexFunc(state.Subscriptions, func(item mobileSubscription) bool { return item.ID == id })
}

func (service *mobileEngine) activeEngine() *engine {
	service.mu.RLock()
	defer service.mu.RUnlock()
	return service.active
}

func (service *mobileEngine) snapshot() mobileState {
	service.mu.RLock()
	defer service.mu.RUnlock()
	state := service.state
	state.Subscriptions = append([]mobileSubscription{}, state.Subscriptions...)
	return state
}

func (service *mobileEngine) persist(state mobileState, active *engine, stored bool) error {
	if err := writeMobileJSON(service.dataDir, mobileStateFile, state); err != nil {
		return &mobileFault{500, "STORAGE_ERROR", "Go 引擎无法保存订阅"}
	}
	service.mu.Lock()
	service.state, service.active, service.stored = state, active, stored
	service.mu.Unlock()
	return nil
}

func mobileSource(raw string) (string, error) {
	address := strings.TrimSpace(raw)
	parsed, err := url.Parse(address)
	if err != nil || len(address) > 8192 || parsed.Hostname() == "" || parsed.User != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") {
		return "", &mobileFault{400, "BAD_REQUEST", "请输入 HTTP(S) 订阅地址"}
	}
	return address, nil
}

func (service *mobileEngine) addSubscription(address, name string) (any, error) {
	address, err := mobileSource(address)
	if err != nil {
		return nil, err
	}
	name = strings.TrimSpace(name)
	if len(name) > 2048 {
		return nil, errBadInput
	}
	if name == "" {
		name = address
	}
	service.mutation.Lock()
	defer service.mutation.Unlock()
	state := service.snapshot()
	digest := sha256.Sum256([]byte(address))
	item := mobileSubscription{ID: hex.EncodeToString(digest[:12]), URL: address, Name: name}
	if pos := state.index(item.ID); pos >= 0 {
		return state.Subscriptions[pos], nil
	}
	if len(state.Subscriptions) >= 512 {
		return nil, &mobileFault{400, "BAD_REQUEST", "已达到本机订阅数量上限"}
	}
	state.Subscriptions = append(state.Subscriptions, item)
	return item, service.persist(state, service.active, service.stored)
}

func (service *mobileEngine) changeSubscription(id string, name *string) (any, error) {
	service.mutation.Lock()
	defer service.mutation.Unlock()
	state := service.snapshot()
	pos := state.index(id)
	if pos < 0 {
		return nil, errMobileNotFound
	}
	if name != nil {
		label := strings.TrimSpace(*name)
		if len(label) > 2048 {
			return nil, errBadInput
		}
		if label == "" {
			label = state.Subscriptions[pos].URL
		}
		state.Subscriptions[pos].Name = label
		return state.Subscriptions[pos], service.persist(state, service.active, service.stored)
	}
	state.Subscriptions = slices.Delete(state.Subscriptions, pos, pos+1)
	if state.ActiveID == id {
		state.ActiveID, state.Document = "", nil
		return nil, service.persist(state, nil, false)
	}
	return nil, service.persist(state, service.active, service.stored)
}

func (service *mobileEngine) activate(ctx context.Context, id string) (any, error) {
	service.mutation.Lock()
	defer service.mutation.Unlock()
	state := service.snapshot()
	if id == "" {
		id = state.ActiveID
		if id == "" {
			return nil, errMobileNoConfig
		}
	}
	pos := state.index(id)
	if pos < 0 {
		return nil, errMobileNotFound
	}
	address, err := mobileSource(state.Subscriptions[pos].URL)
	if err != nil {
		return nil, err
	}
	var document subscription
	if err := getJSON(ctx, service.client, address, nil, &document); err != nil {
		return nil, &mobileFault{502, "CONFIG_LOAD_FAILED", fmt.Sprintf("读取订阅失败：%v", err)}
	}
	active, err := newEngine(document, service.providers)
	if err != nil {
		return nil, &mobileFault{422, "CONFIG_LOAD_FAILED", "需要带有有效 sites 列表的 TVBox 单订阅"}
	}
	if len(active.routes) == 0 {
		return nil, &mobileFault{422, "UNSUPPORTED_SITE", "此订阅没有可用的内置 Go 适配器"}
	}
	kept := subscription{Sites: make([]Site, 0, len(active.routes))}
	for _, declared := range active.converted.Sites {
		site := active.sites[declared.Key]
		site.Jar = ""
		kept.Sites = append(kept.Sites, site)
	}
	state.ActiveID, state.Document = id, &kept
	state.Subscriptions[pos].UsedAt = time.Now().UnixMilli()
	if err := service.persist(state, active, false); err != nil {
		return nil, err
	}
	return service.summary()
}

func (service *mobileEngine) summary() (any, error) {
	service.mu.RLock()
	defer service.mu.RUnlock()
	if service.active == nil {
		return nil, errMobileNoConfig
	}
	item := service.state.Subscriptions[service.state.index(service.state.ActiveID)]
	return map[string]any{"subscriptionId": item.ID, "url": item.URL, "fetchedUrl": item.URL, "fetchedAt": item.UsedAt, "stored": service.stored, "repos": []string{}, "sites": len(service.active.routes), "parses": 0, "lives": 0}, nil
}

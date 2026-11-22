package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type subscription struct {
	Spider string        `json:"spider,omitempty"`
	Sites  []Site        `json:"sites"`
	Parses []parseConfig `json:"parses,omitempty"`
}

type parseConfig struct {
	Name string          `json:"name"`
	Type int             `json:"type"`
	URL  string          `json:"url"`
	Ext  json.RawMessage `json:"ext,omitempty"`
}

type siteStatus struct {
	Key    string `json:"key"`
	Name   string `json:"name"`
	API    string `json:"api"`
	Native bool   `json:"native"`
	Mode   string `json:"mode"`
}

type engine struct {
	sites     map[string]Site
	routes    map[string]provider
	statuses  []siteStatus
	converted subscription
	parsers   *parseRelay
}

func loadSubscription(ctx context.Context, client *http.Client, source string) (subscription, error) {
	var document subscription
	if strings.HasPrefix(source, "http://") || strings.HasPrefix(source, "https://") {
		err := getJSON(ctx, client, source, nil, &document)
		return document, err
	}
	file, err := os.Open(source)
	if err != nil {
		return document, err
	}
	defer file.Close()
	err = readJSON(file, &document)
	return document, err
}

func newEngine(document subscription, providers map[string]provider) (*engine, error) {
	if len(document.Sites) == 0 {
		return nil, errors.New("订阅里没有 sites")
	}
	service := &engine{sites: make(map[string]Site), routes: make(map[string]provider), converted: subscription{Sites: []Site{}}}
	for _, site := range document.Sites {
		if site.Key == "" || strings.ContainsAny(site.Key, "/\\") || site.Key == "." || site.Key == ".." {
			return nil, fmt.Errorf("无效的站点 key %q", site.Key)
		}
		if _, exists := service.sites[site.Key]; exists {
			return nil, fmt.Errorf("重复的站点 key %q", site.Key)
		}
		backend := providers[site.API]
		available := site.Type == 3 && backend != nil
		mode := "unsupported"
		if selected, ok := backend.(interface{ accepts(Site) bool }); ok {
			available = available && selected.accepts(site)
		}
		if available {
			service.routes[site.Key] = backend
			mode = "go"
			if specific, ok := backend.(interface{ mode() string }); ok {
				mode = specific.mode()
			}
			remote := site
			if remote.Timeout == 0 && site.API == "csp_AppYQK" && site.Key == "一起" {
				remote.Timeout = 50
			}
			remote.Type, remote.API, remote.Ext, remote.Jar = 4, "./t4/"+url.PathEscape(site.Key), nil, ""
			service.converted.Sites = append(service.converted.Sites, remote)
		}
		service.sites[site.Key] = site
		class := site.API
		if !strings.HasPrefix(class, "csp_") || strings.ContainsAny(class, "/:?#@") {
			class = "external"
		}
		if available && site.API == drpyLoaderAPI {
			class = "drpy"
		}
		service.statuses = append(service.statuses, siteStatus{site.Key, site.Name, class, mode == "go" || mode == "go-sample" || mode == "go+compiled-spider", mode})
		if mode == "go-catalog+local-jar" || mode == "go+compiled-spider" {
			if service.parsers == nil {
				service.parsers = newParseRelay(document.Parses)
				service.converted.Parses = append(service.parsers.entries(), parseConfig{Name: "直接嗅探"})
			}
		}
	}
	return service, nil
}

func writeJSON(response http.ResponseWriter, status int, value any) {
	response.Header().Set("Content-Type", "application/json; charset=utf-8")
	response.Header().Set("Cache-Control", "no-store")
	response.WriteHeader(status)
	_ = json.NewEncoder(response).Encode(value)
}

func writeProblem(response http.ResponseWriter, err error) {
	status := http.StatusBadGateway
	switch {
	case errors.Is(err, errBadInput):
		status = http.StatusBadRequest
	case errors.Is(err, errUnsupported):
		status = http.StatusNotImplemented
	case errors.Is(err, context.DeadlineExceeded):
		status = http.StatusGatewayTimeout
	}
	writeJSON(response, status, map[string]string{"error": err.Error()})
}

func isLoopback(host string) bool {
	return strings.EqualFold(host, "localhost") || net.ParseIP(host).IsLoopback()
}

func (service *engine) ServeHTTP(response http.ResponseWriter, request *http.Request) {
	host := request.Host
	if hostname, _, err := net.SplitHostPort(host); err == nil {
		host = hostname
	}
	if !isLoopback(strings.Trim(host, "[]")) {
		http.Error(response, "loopback host required", http.StatusForbidden)
		return
	}
	if request.Method != http.MethodGet && !strings.HasPrefix(request.URL.Path, "/t4/") {
		response.Header().Set("Allow", http.MethodGet)
		http.Error(response, "GET required", http.StatusMethodNotAllowed)
		return
	}
	switch request.URL.Path {
	case "/config.json":
		writeJSON(response, http.StatusOK, service.converted)
	case "/status":
		writeJSON(response, http.StatusOK, service.statuses)
	default:
		if strings.HasPrefix(request.URL.Path, "/parse/") && service.parsers != nil {
			service.parsers.serve(response, request)
			return
		}
		key, isSite := strings.CutPrefix(request.URL.Path, "/t4/")
		site, exists := service.sites[key]
		if !isSite || !exists {
			http.NotFound(response, request)
			return
		}
		backend := service.routes[key]
		if backend == nil {
			writeProblem(response, errUnsupported)
			return
		}
		serveType4(response, request, site, backend)
	}
}

func pureGoProviders(client *http.Client) map[string]provider {
	providers := extraProviders(client)
	providers["csp_Bili"] = newBiliProvider(client)
	providers["csp_Alllive"] = newAllLiveProvider(client)
	providers["csp_FirstAid"] = newFirstAidProvider(client)
	providers["csp_Kugou"] = kugouProvider{client: client}
	providers["csp_Push"] = newPushProvider()
	providers[drpyLoaderAPI] = newDrpyProvider(client)
	providers["csp_AppDrama2"] = ganfanProvider{client: client}
	return providers
}

func main() {
	source := flag.String("source", "", "订阅 URL 或本地 JSON 文件")
	listen := flag.String("listen", "127.0.0.1:9980", "本机监听地址")
	mobileData := flag.String("mobile-data", "", "运行与 iOS 内置引擎相同的映舟 API，将订阅和历史保存在此目录")
	dramaHost := flag.String("drama2-host", "", "可选，本机已激活原版干饭蜘蛛的独立映舟引擎地址")
	native := flag.String("drama2-native", "", "可选，肥猫蜘蛛的本机原生启动器绝对路径")
	flag.StringVar(native, "spider-native", "", "已编译的肥猫蜘蛛启动器绝对路径")
	export := flag.String("export-sample", "", "将干饭所选分类中的小样写入新的本地 JSON 文件并退出")
	sample := flag.String("sample", "", "从干饭小样启动独立 Go 服务")
	category := flag.String("category", "", "从这个分类取样，默认只保存在内存并提供订阅")
	itemID := flag.String("item", "", "可选，只迁移所选页的指定原站条目 ID")
	page := flag.Int("page", 1, "从原分类的第几页取样")
	limit := flag.Int("limit", 1, "从该页迁移的条目数")
	episodes := flag.Int("episodes", 1, "每条线路迁移的分集或频道数")
	flag.Parse()
	if *mobileData != "" {
		flag.Visit(func(option *flag.Flag) {
			if option.Name != "mobile-data" && option.Name != "listen" {
				log.Fatal("-mobile-data 模式从客户端导入订阅，只接受 -listen 参数")
			}
		})
		host, number, err := net.SplitHostPort(*listen)
		port, parseErr := strconv.Atoi(number)
		if err != nil || !isLoopback(host) || parseErr != nil {
			log.Fatal("-listen 需要本机回环地址及端口")
		}
		dir, err := filepath.Abs(*mobileData)
		if err != nil {
			log.Fatal(err)
		}
		bound, err := StartMobileEngine(port, dir)
		if err != nil {
			log.Fatal(err)
		}
		ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
		defer stop()
		log.Printf("映舟 Go 引擎 http://127.0.0.1:%d/api/v1/info", bound)
		<-ctx.Done()
		StopMobileEngine()
		return
	}
	if (*sample == "") == (*source == "") || (*sample != "" && (*dramaHost != "" || *native != "" || *category != "" || *export != "")) {
		log.Fatal("请选择 -source 读取原订阅，或单独使用 -sample 读取已迁移样本")
	}
	if *native != "" && *dramaHost != "" {
		log.Fatal("请选择 -drama2-native 或 -drama2-host 中的一个")
	}
	if (*itemID != "" || *export != "" || *page != 1 || *limit != 1 || *episodes != 1) && *category == "" {
		log.Fatal("请指定 -category 分类 ID")
	}
	if *page < 1 || *limit < 1 || *episodes < 1 {
		log.Fatal("-page、-limit 和 -episodes 均需大于零")
	}
	host, _, err := net.SplitHostPort(*listen)
	if err != nil || !isLoopback(host) {
		log.Fatal("-listen 需要本机回环地址及端口")
	}
	if *sample != "" {
		service, err := loadSampleFile(*sample)
		if err != nil {
			log.Fatal(err)
		}
		runServer(*listen, service)
		return
	}
	client := &http.Client{Timeout: 15 * time.Second}
	document, err := loadSubscription(context.Background(), client, *source)
	if err != nil {
		log.Fatal(err)
	}
	providers := pureGoProviders(client)
	drama := ganfanProvider{client: client}
	if *native != "" {
		runner, err := newNativeSpider(*native, document.Spider)
		if err != nil {
			log.Fatal(err)
		}
		drama.host = &compiledSpider{spider: runner}
		for _, site := range document.Sites {
			if site.API != "csp_AppDrama2" && providers[site.API] == nil && runner.supports(site) {
				providers[site.API] = drama.host
			}
		}
	}
	if *dramaHost != "" {
		drama.host, err = newDrama2Host(&http.Client{Timeout: 45 * time.Second}, *dramaHost)
		if err != nil {
			log.Fatal(err)
		}
	}
	if *category != "" {
		ctx, cancel := context.WithTimeout(context.Background(), 4*time.Minute)
		selection := sampleSelection{Category: *category, ItemID: *itemID, Page: *page, Limit: *limit, Episodes: *episodes}
		captured, err := captureSample(ctx, document, drama.host, selection)
		cancel()
		if err != nil {
			log.Fatal(err)
		}
		reportSample(captured)
		if *export != "" {
			if err := writeSampleFile(*export, captured); err != nil {
				log.Fatal(err)
			}
			return
		}
		service, err := sampleEngine(&drama2SampleProvider{sample: *captured})
		if err != nil {
			log.Fatal(err)
		}
		runServer(*listen, service)
		return
	}
	providers["csp_AppDrama2"] = drama
	service, err := newEngine(document, providers)
	if err != nil {
		log.Fatal(err)
	}
	runServer(*listen, service)
}

func runServer(listen string, service *engine) {
	listener, err := net.Listen("tcp", listen)
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("已导出 %d/%d 个入口。映舟订阅地址 http://%s/config.json", len(service.converted.Sites), len(service.statuses), listener.Addr())
	server := &http.Server{Handler: service, ReadHeaderTimeout: 5 * time.Second, WriteTimeout: 100 * time.Second, IdleTimeout: 60 * time.Second}
	log.Fatal(server.Serve(listener))
}

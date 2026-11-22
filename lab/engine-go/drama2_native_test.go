package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"
)

func TestMain(tests *testing.M) {
	if os.Getenv("YINGZHOU_TEST_NATIVE_CHILD") != "1" {
		os.Exit(tests.Run())
	}
	scanner := bufio.NewScanner(os.Stdin)
	var init map[string]string
	if !scanner.Scan() || json.Unmarshal(scanner.Bytes(), &init) != nil {
		os.Exit(2)
	}
	version := os.Getenv("YINGZHOU_TEST_NATIVE_VERSION")
	if init["op"] == "capabilities" {
		if len(init) != 1 {
			os.Exit(2)
		}
		if version == "legacy" {
			fmt.Println(`{"error":"java.lang.IllegalStateException"}`)
		} else {
			json.NewEncoder(os.Stdout).Encode(nativeCapabilities{Protocol: 3, SHA256: nativeSpiderSHA256, Families: map[string][]string{"csp_AppDrama2": {"干饭", "行动", "再来", "一碗"}, "csp_AppGet": {"蔬菜"}}})
		}
		os.Exit(0)
	}
	if init["op"] != "init" || init["ext"] != `{"sample":true}` || !knownNativeSite(init["api"], init["siteKey"]) {
		os.Exit(2)
	}
	var query map[string]string
	if !scanner.Scan() || json.Unmarshal(scanner.Bytes(), &query) != nil {
		os.Exit(3)
	}
	if version == "legacy" {
		fmt.Println(`{"ready":true}`)
	} else {
		site := init["siteKey"]
		if query["op"] == "wrongSite" {
			site = "干饭"
		}
		api := init["api"]
		if query["op"] == "wrongClass" {
			api = "csp_AppGet"
		}
		json.NewEncoder(os.Stdout).Encode(map[string]any{"ready": true, "protocol": 3, "sha256": nativeSpiderSHA256, "siteKey": site, "api": api})
	}
	switch query["op"] {
	case "sleep":
		time.Sleep(time.Minute)
	case "exit":
		os.Exit(4)
	case "error":
		fmt.Println(`{"error":"private detail"}`)
	case "large":
		fmt.Println(strings.Repeat("x", maxJSONSize+2048))
	case "bad":
		fmt.Println(`not-json`)
	default:
		json.NewEncoder(os.Stdout).Encode(query)
	}
	os.Exit(0)
}

func TestNativeSpiderProtocol(t *testing.T) {
	t.Setenv("YINGZHOU_TEST_NATIVE_CHILD", "1")
	path, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	host, err := newNativeSpider(path, "package;md5;"+nativeSpiderMD5)
	if err != nil {
		t.Fatal(err)
	}
	site := Site{Key: "行动", API: "csp_AppDrama2", Type: 3, Ext: json.RawMessage(`{"sample":true}`)}
	for _, op := range []string{"home", "category", "search", "detail", "play"} {
		got, err := host.call(context.Background(), site, map[string]any{"op": op, "id": "中文\n#"})
		if err != nil {
			t.Fatal(op, err)
		}
		var data map[string]string
		if json.Unmarshal(got, &data) != nil || data["op"] != op || data["id"] != "中文\n#" {
			t.Fatal(op)
		}
	}
	for _, op := range []string{"exit", "large", "error", "bad", "wrongSite", "wrongClass"} {
		if _, err := host.call(context.Background(), site, map[string]any{"op": op}); err == nil || strings.Contains(err.Error(), "private detail") {
			t.Errorf("invalid error for %s", op)
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Millisecond)
	defer cancel()
	if _, err := host.call(ctx, site, map[string]any{"op": "sleep"}); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatal(err)
	}
	if _, err := host.call(context.Background(), site, map[string]any{"op": "home"}); err != nil {
		t.Fatal(err)
	}
}

func TestNativeSitePinAndLegacyHost(t *testing.T) {
	t.Setenv("YINGZHOU_TEST_NATIVE_CHILD", "1")
	path, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	const pinned = "global;md5;" + nativeSpiderMD5
	for _, version := range []string{"family", "legacy"} {
		t.Setenv("YINGZHOU_TEST_NATIVE_VERSION", version)
		runner, err := newNativeSpider(path, pinned)
		if err != nil {
			t.Fatal(err)
		}
		for _, key := range []string{"干饭", "行动", "再来", "一碗"} {
			site := Site{Type: 3, API: "csp_AppDrama2", Key: key, Ext: json.RawMessage(`{"sample":true}`)}
			want := version != "legacy" || key == "干饭"
			if runner.supports(site) != want {
				t.Fatalf("%s routed %s incorrectly", version, key)
			}
			if want {
				if _, err := runner.call(context.Background(), site, map[string]any{"op": "home"}); err != nil {
					t.Fatalf("%s call: %v", key, err)
				}
			}
			site.Jar = "override;md5;unknown"
			if runner.supports(site) {
				t.Fatal("changed site package ignored")
			}
		}
		if runner.supports(Site{Type: 3, API: "csp_AppGet", Key: "行动"}) || runner.supports(Site{Type: 3, API: "csp_AppDrama2", Key: "新站"}) || runner.supports(Site{Type: 4, API: "csp_AppDrama2", Key: "干饭"}) {
			t.Fatal("an undeclared class/site pair or type passed")
		}
		runner.globalJar = "changed"
		site := Site{Type: 3, API: "csp_AppDrama2", Key: "干饭"}
		if runner.supports(site) {
			t.Fatal("unverified global package accepted")
		}
		site.Jar = "mirror;sha256;" + nativeSpiderSHA256
		if !runner.supports(site) {
			t.Fatal("pinned site override rejected")
		}
	}
}

func TestWaveTwoFamilyRoutes(t *testing.T) {
	routes := map[string]string{
		"csp_AppYQK": "一起", "csp_Gulu": "咕噜", "csp_GuaziTY": "瓜子", "csp_Gz360": "csp_Gz360",
		"csp_Hxq": "韩圈", "csp_Jianpian": "荐片", "csp_Jpys": "csp_Jpys", "csp_Kanqiu": "看球",
		"csp_SaoHuo": "csp_SaoHuo", "csp_YGP": "豆瓣预告",
	}
	families := map[string][]string{"csp_AppRJ": {"潮流"}, "csp_Dm84": {"csp_Dm84"}}
	for api, key := range routes {
		families[api] = []string{key, "other"}
	}
	runner := nativeSpider{caps: nativeCapabilities{Protocol: 3, Families: families}, globalJar: "global;sha256;" + nativeSpiderSHA256}
	for api, key := range routes {
		if !runner.supports(Site{Type: 3, API: api, Key: key}) || runner.supports(Site{Type: 3, API: api, Key: "other"}) {
			t.Errorf("incorrect package route for %s", api)
		}
	}
	for _, site := range []Site{{Type: 3, API: "csp_AppRJ", Key: "潮流"}, {Type: 3, API: "csp_Dm84", Key: "csp_Dm84"}, {Type: 3, API: "csp_Gz360", Key: "瓜子"}} {
		if runner.supports(site) {
			t.Errorf("unexpected site route %s %s", site.API, site.Key)
		}
	}
}

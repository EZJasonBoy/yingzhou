package main

import "testing"

func TestExportSiteTimeout(t *testing.T) {
	for _, test := range []struct {
		key         string
		input, want int
	}{{"一起", 0, 50}, {"一起", 40, 40}, {"其他", 0, 0}} {
		site := Site{Key: test.key, API: "csp_AppYQK", Type: 3, Timeout: test.input}
		service, err := newEngine(subscription{Sites: []Site{site}}, map[string]provider{site.API: t4TestProvider{}})
		if err != nil || len(service.converted.Sites) != 1 || service.converted.Sites[0].Timeout != test.want {
			t.Fatalf("%s timeout %d: %v", test.key, test.input, err)
		}
	}
}

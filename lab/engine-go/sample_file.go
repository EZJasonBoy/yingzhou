package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
)

func captureSample(ctx context.Context, document subscription, backend provider, selection sampleSelection) (*drama2Sample, error) {
	if backend == nil {
		return nil, fmt.Errorf("取样需要 -drama2-host 或 -drama2-native 加载原蜘蛛")
	}
	for _, site := range document.Sites {
		if site.Key == "干饭" && site.API == "csp_AppDrama2" && site.Type == 3 {
			return exportDrama2Sample(ctx, site, backend, selection)
		}
	}
	return nil, fmt.Errorf("指定订阅缺少干饭 csp_AppDrama2 入口")
}

func writeSampleFile(path string, sample *drama2Sample) error {
	encoded, err := json.MarshalIndent(sample, "", "  ")
	if err != nil {
		return err
	}
	if len(encoded) > maxJSONSize {
		return fmt.Errorf("所选样本超过 %d 字节，请减少条目或分集数", maxJSONSize)
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	_, writeErr := file.Write(encoded)
	closeErr := file.Close()
	if writeErr != nil || closeErr != nil {
		os.Remove(path)
		if writeErr != nil {
			return writeErr
		}
		return closeErr
	}
	return nil
}

func reportSample(sample *drama2Sample) {
	count := 0
	for _, item := range sample.Items {
		count += len(item.Media)
	}
	log.Printf("干饭「%s」%d 个条目、%d 个媒体地址。跳过原因 %v", sample.CategoryInfo.Name, len(sample.Items), count, sample.Dropped)
}

func loadSampleFile(path string) (*engine, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	backend, err := newDrama2SampleProvider(file)
	if err != nil {
		return nil, err
	}
	return sampleEngine(backend)
}

func sampleEngine(backend provider) (*engine, error) {
	site := Site{Key: "干饭", Name: "干饭 · 已迁移样本", Type: 3, API: "csp_AppDrama2"}
	return newEngine(subscription{Sites: []Site{site}}, map[string]provider{site.API: backend})
}

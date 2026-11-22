package main

import (
	"context"
	"errors"
	"net"
	"net/http"
	"strconv"
	"sync"
	"time"
)

var mobileProcess struct {
	sync.Mutex
	server *http.Server
	port   int
	dir    string
	cancel context.CancelFunc
	wait   sync.WaitGroup
}

func StartMobileEngine(port int, dataDir string) (int, error) {
	mobileProcess.Lock()
	defer mobileProcess.Unlock()
	if port < 0 || port > 65535 {
		return 0, errors.New("无效的本机端口")
	}
	if mobileProcess.server != nil {
		if dataDir == mobileProcess.dir && (port == 0 || port == mobileProcess.port) {
			return mobileProcess.port, nil
		}
		return 0, errors.New("Go 引擎已在运行")
	}
	client := &http.Client{Timeout: 15 * time.Second}
	service, err := newMobileEngine(dataDir, client)
	if err != nil {
		return 0, err
	}
	listener, err := net.Listen("tcp4", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
	if err != nil {
		return 0, err
	}
	ctx, cancel := context.WithCancel(context.Background())
	server := &http.Server{
		Handler: service, ReadTimeout: 10 * time.Second, ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout: 60 * time.Second, MaxHeaderBytes: 128 << 10,
		BaseContext: func(net.Listener) context.Context { return ctx },
	}
	mobileProcess.server, mobileProcess.port = server, listener.Addr().(*net.TCPAddr).Port
	mobileProcess.dir, mobileProcess.cancel = dataDir, cancel
	mobileProcess.wait.Add(1)
	go func() {
		defer mobileProcess.wait.Done()
		_ = server.Serve(listener)
		client.CloseIdleConnections()
	}()
	return mobileProcess.port, nil
}

func StopMobileEngine() {
	mobileProcess.Lock()
	defer mobileProcess.Unlock()
	if mobileProcess.server != nil {
		mobileProcess.cancel()
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		if err := mobileProcess.server.Shutdown(ctx); err != nil {
			_ = mobileProcess.server.Close()
		}
		cancel()
		mobileProcess.wait.Wait()
		mobileProcess.server, mobileProcess.cancel, mobileProcess.port, mobileProcess.dir = nil, nil, 0, ""
	}
}

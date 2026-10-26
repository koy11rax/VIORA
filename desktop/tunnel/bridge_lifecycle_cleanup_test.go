package main

import (
	"context"
	"reflect"
	"testing"
)

func TestBridgeStopsMetricsBeforeEitherChild(t *testing.T) {
	log := &lifecycleBridgeLog{}
	start := func(_ context.Context, stage string) (bridgeProcess, error) { return lifecycleProcess(stage, log), nil }
	code := superviseBridge(context.Background(), start, func() string { return "protection_failed" }, func() { log.add("stop:metrics") })
	if code != "protection_failed" {
		t.Fatalf("lost startup failure: %s", code)
	}
	want := []string{"ready:backend", "ready:frontend", "stop:metrics", "stop:frontend", "stop:backend"}
	if !reflect.DeepEqual(log.snapshot(), want) {
		t.Fatalf("unsafe shutdown order: %v", log.snapshot())
	}
}

package libv2ray

import (
	"sync"
	"testing"

	core "github.com/xtls/xray-core/core"
	corestats "github.com/xtls/xray-core/features/stats"
)

func TestFailedStartupClosesInstance(t *testing.T) {
	feature := &failingFeature{}
	instance := &core.Instance{}
	if err := instance.AddFeature(feature); err != nil {
		t.Fatal(err)
	}
	if err := startCoreInstance(instance); err == nil {
		t.Fatal("fixture did not fail")
	}
	if feature.closed != 1 {
		t.Fatal("failed startup leaked partial instance")
	}
}

func TestConcurrentLifecycleSnapshots(t *testing.T) {
	x := &CoreController{}
	var wait sync.WaitGroup
	wait.Add(3)
	go func() {
		defer wait.Done()
		for i := 0; i < 1000; i++ {
			x.coreMutex.Lock()
			x.statsManager = corestats.NoopManager{}
			x.isRunning = true
			x.coreMutex.Unlock()
			x.coreMutex.Lock()
			x.doShutdown()
			x.coreMutex.Unlock()
		}
	}()
	go func() {
		defer wait.Done()
		for i := 0; i < 1000; i++ {
			x.QueryAllOutboundTrafficStats()
			x.GetIsRunning()
		}
	}()
	go func() {
		defer wait.Done()
		for i := 0; i < 1000; i++ {
			// The controller deliberately has no core or endpoint. This tests
			// synchronization without opening sockets or changing the network.
			if delay, err := x.MeasureDelay(""); err == nil || delay != -1 {
				t.Error("nil instance falsely measured a working connection")
			}
		}
	}()
	wait.Wait()
}

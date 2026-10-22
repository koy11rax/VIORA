package libv2ray

import (
	"errors"
	"testing"

	core "github.com/xtls/xray-core/core"
	corestats "github.com/xtls/xray-core/features/stats"
)

type failingFeature struct{ closed int }

func (*failingFeature) Type() interface{} { return (*failingFeature)(nil) }
func (*failingFeature) Start() error      { return errors.New("fixture startup failure") }
func (f *failingFeature) Close() error    { f.closed++; return nil }

func TestStopLoopClosesPartialInstance(t *testing.T) {
	// Xray can retain a partially initialized instance while the running flag
	// is false. Stopping that state must release resources too.
	feature := &failingFeature{}
	instance := &core.Instance{}
	if err := instance.AddFeature(feature); err != nil {
		t.Fatal(err)
	}
	x := &CoreController{coreInstance: instance, statsManager: corestats.NoopManager{}}
	if err := x.StopLoop(); err != nil {
		t.Fatal(err)
	}
	if feature.closed != 1 || x.coreInstance != nil || x.statsManager != nil {
		t.Fatal("partial instance or statistics survived stop")
	}
	if err := x.StopLoop(); err != nil {
		t.Fatal(err)
	}
	if feature.closed != 1 {
		t.Fatal("repeat stop closed resources twice")
	}
}

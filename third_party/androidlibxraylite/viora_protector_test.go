package libv2ray

import (
	"context"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/transport/internet"
)

type fixtureProtector struct {
	allowed atomic.Bool
	calls   atomic.Int32
}

func (p *fixtureProtector) Protect(fd int64) bool {
	p.calls.Add(1)
	return fd >= 0 && p.allowed.Load()
}

func TestProtectorRejectsTCPAndUDPBeforeDial(t *testing.T) {
	protector := &fixtureProtector{}
	if err := UseProtector(protector); err != nil {
		t.Fatal(err)
	}
	defer protector.allowed.Store(true)
	for _, network := range []xnet.Network{xnet.Network_TCP, xnet.Network_UDP} {
		t.Run(network.String(), func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			destination := xnet.Destination{Network: network, Address: xnet.LocalHostIP, Port: 1}
			connection, err := internet.DialSystem(ctx, destination, nil)
			if connection != nil {
				connection.Close()
				t.Fatal("rejected VPN protector still produced a socket")
			}
			if err == nil || !strings.Contains(err.Error(), "VPN socket protection failed") {
				t.Fatal("protector failure was swallowed or replaced by a network error")
			}
		})
	}
	if protector.calls.Load() != 2 {
		t.Fatal("TCP/UDP did not both invoke the Android socket protector")
	}
}

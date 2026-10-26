package offline

import (
	"context"
	"errors"
	"testing"
	"time"

	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/transport/internet"
	"github.com/xtls/xray-core/transport/internet/tls"
	"github.com/xtls/xray-core/transport/internet/websocket"
)

type recordingDialer struct {
	remaining   time.Duration
	hasDeadline bool
	calls       int
}

func (d *recordingDialer) Dial(ctx context.Context, _ xnet.Address, _ xnet.Destination, _ *internet.SocketConfig) (xnet.Conn, error) {
	d.calls++
	deadline, ok := ctx.Deadline()
	d.hasDeadline = ok
	if ok {
		d.remaining = time.Until(deadline)
	}
	return nil, errors.New("offline fixture: no socket is created")
}

func (*recordingDialer) DestIpAddress() xnet.IP { return nil }

func TestPinnedWebsocketPassesHandshakeDeadlineToTLSNetworkDial(t *testing.T) {
	// This dedicated test process intercepts the real pinned transport's dial
	// before any socket is created. It neither starts Xray nor creates a TUN.
	dialer := &recordingDialer{}
	internet.UseAlternativeSystemDialer(dialer)
	t.Cleanup(func() { internet.UseAlternativeSystemDialer(nil) })
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	settings := &internet.MemoryStreamConfig{
		ProtocolName: "websocket", ProtocolSettings: &websocket.Config{Path: "/fixture"},
		SecurityType: "tls", SecuritySettings: &tls.Config{ServerName: "example.invalid", Fingerprint: "chrome"},
	}
	_, err := websocket.Dial(ctx, xnet.TCPDestination(xnet.ParseAddress("192.0.2.1"), 443), settings)
	if err == nil || dialer.calls != 1 {
		t.Fatal("expected exactly one intercepted dial failure")
	}
	if !dialer.hasDeadline || dialer.remaining > 9*time.Second {
		t.Fatalf("transport ignored its eight-second handshake deadline: observed bounded=%t remaining=%s", dialer.hasDeadline, dialer.remaining)
	}
}

package offline

import (
	"context"
	"io"
	"net"
	"testing"
	"time"

	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/transport/internet"
	"github.com/xtls/xray-core/transport/internet/tls"
	"github.com/xtls/xray-core/transport/internet/websocket"
)

// eofConnection is an entirely in-memory stream: TLS can write a ClientHello,
// but the first read fails. No socket or network interface is ever created.
type eofConnection struct {
	closed bool
	writes int
}

func (c *eofConnection) Read([]byte) (int, error)       { return 0, io.EOF }
func (c *eofConnection) Write(p []byte) (int, error)    { c.writes++; return len(p), nil }
func (c *eofConnection) Close() error                   { c.closed = true; return nil }
func (*eofConnection) LocalAddr() net.Addr              { return &net.TCPAddr{} }
func (*eofConnection) RemoteAddr() net.Addr             { return &net.TCPAddr{} }
func (*eofConnection) SetDeadline(time.Time) error      { return nil }
func (*eofConnection) SetReadDeadline(time.Time) error  { return nil }
func (*eofConnection) SetWriteDeadline(time.Time) error { return nil }

type eofDialer struct{ conn *eofConnection }

func (d *eofDialer) Dial(context.Context, xnet.Address, xnet.Destination, *internet.SocketConfig) (xnet.Conn, error) {
	return d.conn, nil
}
func (*eofDialer) DestIpAddress() xnet.IP { return nil }

func TestPinnedWebsocketClosesStreamAfterFailedTLSHandshake(t *testing.T) {
	conn := &eofConnection{}
	internet.UseAlternativeSystemDialer(&eofDialer{conn: conn})
	t.Cleanup(func() { internet.UseAlternativeSystemDialer(nil) })
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	settings := &internet.MemoryStreamConfig{
		ProtocolName: "websocket", ProtocolSettings: &websocket.Config{Path: "/fixture"},
		SecurityType: "tls", SecuritySettings: &tls.Config{ServerName: "example.invalid", Fingerprint: "chrome"},
	}
	_, err := websocket.Dial(ctx, xnet.TCPDestination(xnet.ParseAddress("192.0.2.1"), 443), settings)
	if err == nil || conn.writes == 0 {
		t.Fatal("expected attempted TLS handshake followed by fixture EOF")
	}
	if !conn.closed {
		t.Fatal("failed TLS handshake leaked the returned underlying stream")
	}
}

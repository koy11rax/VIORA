package tun

import (
	"bytes"
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"sync/atomic"
	"testing"
	"time"

	appdispatcher "github.com/xtls/xray-core/app/dispatcher"
	apppolicy "github.com/xtls/xray-core/app/policy"
	"github.com/xtls/xray-core/app/proxyman"
	_ "github.com/xtls/xray-core/app/proxyman/inbound"
	_ "github.com/xtls/xray-core/app/proxyman/outbound"
	approuter "github.com/xtls/xray-core/app/router"
	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/serial"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/features/routing"
	"github.com/xtls/xray-core/proxy/freedom"
	"github.com/xtls/xray-core/transport/internet"
)

type offlineHelloCapture struct{ bytes.Buffer }

func (*offlineHelloCapture) Read([]byte) (int, error)         { return 0, io.EOF }
func (*offlineHelloCapture) Close() error                     { return nil }
func (*offlineHelloCapture) LocalAddr() net.Addr              { return &net.TCPAddr{} }
func (*offlineHelloCapture) RemoteAddr() net.Addr             { return &net.TCPAddr{} }
func (*offlineHelloCapture) SetDeadline(time.Time) error      { return nil }
func (*offlineHelloCapture) SetReadDeadline(time.Time) error  { return nil }
func (*offlineHelloCapture) SetWriteDeadline(time.Time) error { return nil }

func offlineRealClientHello(t *testing.T) []byte {
	t.Helper()
	stream := &offlineHelloCapture{}
	client := tls.Client(stream, &tls.Config{ServerName: "fixture.example", MinVersion: tls.VersionTLS12})
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := client.HandshakeContext(ctx); err == nil {
		t.Fatal("fixture EOF must prevent actual TLS establishment")
	}
	hello := bytes.Clone(stream.Bytes())
	if len(hello) < 100 || hello[0] != 0x16 {
		t.Fatal("TLS client did not emit ClientHello")
	}
	return hello
}

type offlineDialObservation struct {
	alive                        bool
	target, route, tag, protocol string
	level                        uint32
}

// No default system dial is reachable: every freedom dial is replaced with
// a net.Pipe, which only connects two Go goroutines in this process.
type offlinePipeDialer struct {
	observations chan offlineDialObservation
	calls        atomic.Int64
	delay        time.Duration
	serve        func(net.Conn)
}

type offlineRejectDialer struct{}

func (offlineRejectDialer) Dial(context.Context, xnet.Address, xnet.Destination, *internet.SocketConfig) (xnet.Conn, error) {
	return nil, errors.New("offline fixture denies operating-system sockets")
}
func (offlineRejectDialer) DestIpAddress() xnet.IP { return nil }

func init() { internet.UseAlternativeSystemDialer(offlineRejectDialer{}) }

func (d *offlinePipeDialer) Dial(ctx context.Context, _ xnet.Address, dest xnet.Destination, _ *internet.SocketConfig) (xnet.Conn, error) {
	d.calls.Add(1)
	if dest.Network != xnet.Network_TCP || dest.Port != 443 || dest.Address.String() != "198.51.100.10" {
		return nil, errors.New("offline fixture blocked an unexpected outbound")
	}
	observation := offlineDialObservation{alive: ctx.Err() == nil, target: dest.Address.String()}
	if in := session.InboundFromContext(ctx); in != nil && in.User != nil {
		observation.level = in.User.Level
	}
	if content := session.ContentFromContext(ctx); content != nil {
		observation.protocol = content.Protocol
	}
	if outbounds := session.OutboundsFromContext(ctx); len(outbounds) > 0 {
		ob := outbounds[len(outbounds)-1]
		observation.tag = ob.Tag
		if ob.RouteTarget.Address != nil {
			observation.route = ob.RouteTarget.Address.String()
		}
	}
	d.observations <- observation
	if d.delay != 0 {
		timer := time.NewTimer(d.delay)
		defer timer.Stop()
		select {
		case <-timer.C:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	client, server := net.Pipe()
	_ = client.SetDeadline(time.Now().Add(3 * time.Second))
	_ = server.SetDeadline(time.Now().Add(3 * time.Second))
	go func() {
		defer server.Close()
		if d.serve != nil {
			d.serve(server)
		} else {
			_, _ = io.Copy(server, server)
		}
	}()
	return client, nil
}
func (*offlinePipeDialer) DestIpAddress() xnet.IP { return nil }

func offlineActualDispatcher(t *testing.T, dialer *offlinePipeDialer) (routing.Dispatcher, *core.Instance) {
	t.Helper()
	internet.UseAlternativeSystemDialer(dialer)
	t.Cleanup(func() { internet.UseAlternativeSystemDialer(offlineRejectDialer{}) })
	instance, err := core.New(&core.Config{
		App: []*serial.TypedMessage{
			serial.ToTypedMessage(&appdispatcher.Config{}),
			serial.ToTypedMessage(&proxyman.InboundConfig{}),
			serial.ToTypedMessage(&proxyman.OutboundConfig{}),
			serial.ToTypedMessage(&apppolicy.Config{}),
			serial.ToTypedMessage(&approuter.Config{DomainStrategy: approuter.Config_AsIs, Rule: []*approuter.RoutingRule{{TargetTag: &approuter.RoutingRule_Tag{Tag: "sniffed"}, Protocol: []string{"tls"}}}}),
		},
		Outbound: []*core.OutboundHandlerConfig{
			{Tag: "fallback", ProxySettings: serial.ToTypedMessage(&freedom.Config{})},
			{Tag: "sniffed", ProxySettings: serial.ToTypedMessage(&freedom.Config{})},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { instance.Close() })
	// There are no inbounds. Start only activates actual dispatcher/router/
	// policy/outbound managers; the fixture never asks them to open a listener.
	if err = instance.Start(); err != nil {
		t.Fatal(err)
	}
	return instance.GetFeature(routing.DispatcherType()).(routing.Dispatcher), instance
}

func TestOfflineTunActualDispatcherSniffingAndCache(t *testing.T) {
	hello := offlineRealClientHello(t)
	for _, mtu := range []uint32{1280, 1500} {
		for _, extra := range []int{1024, 8192, 65536} {
			for _, mode := range []string{"whole", "fragmented", "sniff_timeout"} {
				t.Run(fmt.Sprintf("mtu%d/extra%d/%s", mtu, extra, mode), func(t *testing.T) {
					dialer := &offlinePipeDialer{observations: make(chan offlineDialObservation, 4), delay: 25 * time.Millisecond}
					actual, instance := offlineActualDispatcher(t, dialer)
					h := newOfflineHarness(t, mtu, nil)
					h.handler.dispatcher = actual
					// core.XrayKey is explicitly exported for tests; production
					// Handler.Init inherits the same instance from its core context.
					h.handler.ctx = context.WithValue(h.handler.ctx, core.XrayKey(1), instance)
					conn := h.dial(t)
					payload := append(bytes.Clone(hello), offlinePayload(extra)...)
					writeDone := make(chan error, 1)
					go func() {
						if mode == "sniff_timeout" {
							if _, err := conn.Write(payload[:5]); err != nil {
								writeDone <- err
								return
							}
							time.Sleep(250 * time.Millisecond)
							payload = payload[5:]
						}
						step := len(payload)
						if mode == "fragmented" {
							step = 117
						}
						for pos := 0; pos < len(payload); {
							end := pos + step
							if end > len(payload) {
								end = len(payload)
							}
							n, err := conn.Write(payload[pos:end])
							if err != nil {
								writeDone <- err
								return
							}
							if n == 0 {
								writeDone <- io.ErrShortWrite
								return
							}
							pos += n
						}
						writeDone <- nil
					}()
					// Keep a private expected copy: the writer may advance its own slice.
					expected := append(bytes.Clone(hello), offlinePayload(extra)...)
					reply := make([]byte, len(expected))
					if _, err := io.ReadFull(conn, reply); err != nil {
						t.Fatal(err)
					}
					if err := <-writeDone; err != nil {
						t.Fatal(err)
					}
					if !bytes.Equal(expected, reply) {
						t.Fatal("actual dispatcher/cache/freedom changed TCP bytes")
					}
					conn.Close()
					var observation offlineDialObservation
					select {
					case observation = <-dialer.observations:
					case <-time.After(time.Second):
						t.Fatal("freedom never reached in-memory dialer")
					}
					if !observation.alive || observation.level != 8 || observation.target != "198.51.100.10" {
						t.Fatalf("bad actual outbound context: %+v", observation)
					}
					if mode == "sniff_timeout" {
						if observation.tag != "fallback" {
							t.Fatalf("expected timeout fallback without lost bytes: %+v", observation)
						}
					} else if observation.tag != "sniffed" || observation.protocol != "tls" || observation.route != "fixture.example" {
						t.Fatalf("actual TLS sniff/routeOnly failed: %+v", observation)
					}
					if dialer.calls.Load() != 1 {
						t.Fatalf("expected one virtual outbound; got %d", dialer.calls.Load())
					}
					for _, device := range h.devices {
						if device.maxSize.Load() > int64(mtu) {
							t.Fatal("MTU exceeded")
						}
					}
				})
			}
		}
	}
}

func TestOfflineTunFragmentedClientHelloRetainsSNIRoute(t *testing.T) {
	hello := offlineRealClientHello(t)
	if len(hello) < 350 {
		t.Fatal("fixture needs a ClientHello longer than two fragments")
	}
	dialer := &offlinePipeDialer{observations: make(chan offlineDialObservation, 4)}
	actual, instance := offlineActualDispatcher(t, dialer)
	h := newOfflineHarness(t, 1500, nil)
	h.handler.dispatcher = actual
	h.handler.ctx = context.WithValue(h.handler.ctx, core.XrayKey(1), instance)
	conn := h.dial(t)
	written := make(chan error, 1)
	go func() {
		for i, part := range [][]byte{hello[:117], hello[117:234], hello[234:]} {
			if _, err := conn.Write(part); err != nil {
				written <- err
				return
			}
			if i < 2 {
				time.Sleep(15 * time.Millisecond)
			}
		}
		written <- nil
	}()
	reply := make([]byte, len(hello))
	if _, err := io.ReadFull(conn, reply); err != nil {
		t.Fatal(err)
	}
	if err := <-written; err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(hello, reply) {
		t.Fatal("fragmented ClientHello bytes changed")
	}
	conn.Close()
	observation := <-dialer.observations
	if observation.tag != "sniffed" || observation.protocol != "tls" || observation.route != "fixture.example" {
		t.Fatalf("ClientHello completed within 30ms but lost SNI routing; payload was exact: %+v", observation)
	}
}

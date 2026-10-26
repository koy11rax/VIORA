package tun

import (
	"context"
	"crypto/tls"
	"errors"
	"io"
	"net"
	"sync/atomic"
	"testing"
	"time"

	approuter "github.com/xtls/xray-core/app/router"
	"github.com/xtls/xray-core/common/geodata"
	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/core"
	featuredns "github.com/xtls/xray-core/features/dns"
	"github.com/xtls/xray-core/features/outbound"
	"github.com/xtls/xray-core/features/routing"
	"github.com/xtls/xray-core/transport"
)

type offlineTrackedDispatcher struct {
	routing.Dispatcher
	done chan struct{}
}

func (d *offlineTrackedDispatcher) DispatchLink(ctx context.Context, dest xnet.Destination, link *transport.Link) error {
	defer close(d.done)
	return d.Dispatcher.DispatchLink(ctx, dest, link)
}

// The routing resolver has no network implementation. Artificial slow/failure
// modes model an unavailable secondary lookup without contacting an OS resolver.
type offlineRoutingDNS struct {
	delay    time.Duration
	fail     bool
	calls    atomic.Int64
	finished chan struct{}
}

func (*offlineRoutingDNS) Type() interface{} { return featuredns.ClientType() }
func (*offlineRoutingDNS) Start() error      { return nil }
func (*offlineRoutingDNS) Close() error      { return nil }
func (d *offlineRoutingDNS) LookupIP(string, featuredns.IPOption) ([]xnet.IP, uint32, error) {
	d.calls.Add(1)
	if d.delay > 0 {
		time.Sleep(d.delay)
	}
	if d.finished != nil {
		defer func() { d.finished <- struct{}{} }()
	}
	if d.fail {
		return nil, 0, errors.New("offline routing DNS unavailable")
	}
	return []xnet.IP{net.ParseIP("198.51.100.10").To4()}, 300, nil
}

func offlineProductionShapeRouter(t *testing.T, instance *core.Instance, dns *offlineRoutingDNS, terminal bool) {
	t.Helper()
	ipv6, err := geodata.ParseIPRules([]string{"::/0"})
	if err != nil {
		t.Fatal(err)
	}
	ru, err := geodata.ParseDomainRules([]string{"domain:ru", "domain:vk.com"}, geodata.Domain_Substr)
	if err != nil {
		t.Fatal(err)
	}
	rules := []*approuter.RoutingRule{
		{TargetTag: &approuter.RoutingRule_Tag{Tag: "sniffed"}, Ip: ipv6},
		{TargetTag: &approuter.RoutingRule_Tag{Tag: "sniffed"}, Domain: ru},
	}
	if terminal {
		rules = append(rules, &approuter.RoutingRule{TargetTag: &approuter.RoutingRule_Tag{Tag: "fallback"}, Networks: []xnet.Network{xnet.Network_TCP, xnet.Network_UDP}})
	}
	ctx := context.WithValue(context.Background(), core.XrayKey(1), instance)
	err = instance.GetFeature(routing.RouterType()).(*approuter.Router).Init(ctx,
		&approuter.Config{DomainStrategy: approuter.Config_IpIfNonMatch, Rule: rules}, dns,
		instance.GetFeature(outbound.ManagerType()).(outbound.Manager), instance.GetFeature(routing.DispatcherType()).(routing.Dispatcher))
	if err != nil {
		t.Fatal(err)
	}
}

func TestOfflineTunRoutingDNSGap(t *testing.T) {
	var systemDNSCalls atomic.Int64
	previousResolver := net.DefaultResolver
	net.DefaultResolver = &net.Resolver{PreferGo: true, Dial: func(context.Context, string, string) (net.Conn, error) {
		systemDNSCalls.Add(1)
		return nil, errors.New("offline fixture denied system DNS")
	}}
	t.Cleanup(func() {
		net.DefaultResolver = previousResolver
		if systemDNSCalls.Load() != 0 {
			t.Error("fixture attempted forbidden system DNS")
		}
	})
	serverTLS, clientTLS := offlineEphemeralTLS(t)
	for _, test := range []struct {
		name                                      string
		sendSNI, slowDNS, terminal, wantHandshake bool
		wantDNS                                   int64
	}{
		{"named_fastDNS_before", true, false, false, true, 1},
		{"numeric_slowDNS_before", false, true, false, true, 0},
		{"named_slowDNS_before", true, true, false, false, 1},
		{"named_slowDNS_terminalProxy", true, true, true, true, 0},
	} {
		t.Run(test.name, func(t *testing.T) {
			dns := &offlineRoutingDNS{fail: test.slowDNS, finished: make(chan struct{}, 4)}
			if test.slowDNS {
				dns.delay = time.Second
			}
			dialer := &offlinePipeDialer{observations: make(chan offlineDialObservation, 4)}
			serverDone := make(chan error, 4)
			dialer.serve = func(raw net.Conn) {
				server := tls.Server(raw, serverTLS.Clone())
				ctx, cancel := context.WithTimeout(context.Background(), time.Second)
				defer cancel()
				err := server.HandshakeContext(ctx)
				if err == nil {
					var p [4]byte
					_, err = io.ReadFull(server, p[:])
					if err == nil {
						_, err = server.Write(p[:])
					}
				}
				serverDone <- err
			}
			actual, instance := offlineActualDispatcher(t, dialer)
			offlineProductionShapeRouter(t, instance, dns, test.terminal)
			h := newOfflineHarness(t, 1280, nil)
			dispatchDone := make(chan struct{})
			h.handler.dispatcher = &offlineTrackedDispatcher{Dispatcher: actual, done: dispatchDone}
			h.handler.ctx = context.WithValue(h.handler.ctx, core.XrayKey(1), instance)
			clientConfig := clientTLS.Clone()
			if !test.sendSNI {
				clientConfig.ServerName = "198.51.100.10"
			}
			client := tls.Client(h.dial(t), clientConfig)
			defer client.Close()
			budget := 2 * time.Second
			if !test.wantHandshake {
				budget = 500 * time.Millisecond
			}
			ctx, cancel := context.WithTimeout(context.Background(), budget)
			defer cancel()
			started := time.Now()
			err := client.HandshakeContext(ctx)
			elapsed := time.Since(started)
			if (err == nil) != test.wantHandshake {
				t.Fatalf("TLS handshake success=%v want%v: %v", err == nil, test.wantHandshake, err)
			}
			if err == nil {
				if len(client.ConnectionState().VerifiedChains) == 0 {
					t.Fatal("TLS certificate was not verified")
				}
				if _, err = client.Write([]byte("ping")); err != nil {
					t.Fatal(err)
				}
				var reply [4]byte
				if _, err = io.ReadFull(client, reply[:]); err != nil || string(reply[:]) != "ping" {
					t.Fatalf("bad authenticated application data: %q %v", reply, err)
				}
				select {
				case err := <-serverDone:
					if err != nil {
						t.Fatal(err)
					}
				case <-time.After(time.Second):
					t.Fatal("virtual TLS server did not finish")
				}
			} else if !errors.Is(err, context.DeadlineExceeded) {
				t.Fatalf("expected secondary DNS delay to outlive handshake budget: %v", err)
			}
			if calls := dns.calls.Load(); calls != test.wantDNS {
				t.Fatalf("DNS lookup calls=%d want%d", calls, test.wantDNS)
			}
			if test.wantDNS > 0 {
				select {
				case <-dns.finished:
				case <-time.After(time.Second):
					t.Fatal("offline DNS did not finish")
				}
			}
			client.Close()
			h.cancel()
			select {
			case <-dispatchDone:
			case <-time.After(2 * time.Second):
				t.Fatal("virtual dispatcher did not terminate")
			}
			t.Logf("SNI=%v terminal=%v DNS calls=%d verified TLS=%v duration=%s", test.sendSNI, test.terminal, dns.calls.Load(), err == nil, elapsed)
		})
	}
}

package tun

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/features/routing"
	"github.com/xtls/xray-core/transport"
	"gvisor.dev/gvisor/pkg/buffer"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
)

// offlineDevice transports packet copies exclusively through Go channels.
// It cannot access Wintun, any host interface, or a system socket.
type offlineDevice struct {
	packets     chan []byte
	notify      chan struct{}
	done        chan struct{}
	peer        *offlineDevice
	closed      sync.Once
	count       atomic.Int64
	maxSize     atomic.Int64
	wireErrors  chan error
	validTCP    atomic.Int64
	firstPacket atomic.Pointer[[]byte]
}

func offlineDevicePair() (*offlineDevice, *offlineDevice) {
	a := &offlineDevice{packets: make(chan []byte, 2048), notify: make(chan struct{}, 1), done: make(chan struct{}), wireErrors: make(chan error, 1)}
	b := &offlineDevice{packets: make(chan []byte, 2048), notify: make(chan struct{}, 1), done: make(chan struct{}), wireErrors: make(chan error, 1)}
	a.peer, b.peer = b, a
	return a, b
}

func (d *offlineDevice) WritePacket(p *stack.PacketBuffer) tcpip.Error {
	packet := make([]byte, p.Size())
	i := 0
	for _, part := range p.AsSlices() {
		i += copy(packet[i:], part)
	}
	if i != p.Size() {
		return d.wireFailure(fmt.Errorf("serialized %d bytes, PacketBuffer.Size=%d", i, p.Size()))
	}
	if err := offlineValidateIPv4TCP(packet); err != nil {
		return d.wireFailure(err)
	}
	d.validTCP.Add(1)
	d.firstPacket.CompareAndSwap(nil, &packet)
	d.count.Add(1)
	for old := d.maxSize.Load(); int64(len(packet)) > old; old = d.maxSize.Load() {
		if d.maxSize.CompareAndSwap(old, int64(len(packet))) {
			break
		}
	}
	select {
	case <-d.done:
		return &tcpip.ErrClosedForSend{}
	case <-d.peer.done:
		return &tcpip.ErrClosedForSend{}
	case d.peer.packets <- packet:
		select {
		case d.peer.notify <- struct{}{}:
		default:
		}
		return nil
	}
}

func (d *offlineDevice) wireFailure(err error) tcpip.Error {
	select {
	case d.wireErrors <- err:
	default:
	}
	return &tcpip.ErrAborted{}
}

// Independent RFC1071 arithmetic over serialized bytes only. No parsed gVisor
// header or checksum helpers are used by this oracle.
func offlineSum16(sum uint32, data []byte) uint32 {
	for len(data) >= 2 {
		sum += uint32(data[0])<<8 | uint32(data[1])
		data = data[2:]
	}
	if len(data) == 1 {
		sum += uint32(data[0]) << 8
	}
	for sum>>16 != 0 {
		sum = (sum & 0xffff) + (sum >> 16)
	}
	return sum
}

func offlineValidateIPv4TCP(packet []byte) error {
	if len(packet) < 40 || packet[0]>>4 != 4 {
		return errors.New("expected a serialized IPv4 TCP packet")
	}
	ihl := int(packet[0]&0x0f) * 4
	if ihl < 20 || len(packet) < ihl+20 {
		return errors.New("invalid serialized IPv4 header length")
	}
	if total := int(binary.BigEndian.Uint16(packet[2:4])); total != len(packet) {
		return fmt.Errorf("IPv4 total length %d != serialized length %d", total, len(packet))
	}
	if packet[9] != 6 || binary.BigEndian.Uint16(packet[6:8])&0x3fff != 0 {
		return errors.New("unexpected fragmented or non-TCP fixture packet")
	}
	if offlineSum16(0, packet[:ihl]) != 0xffff {
		return errors.New("invalid independent IPv4 checksum")
	}
	segment := packet[ihl:]
	if offset := int(segment[12]>>4) * 4; offset < 20 || offset > len(segment) {
		return errors.New("invalid serialized TCP header length")
	}
	pseudo := offlineSum16(0, packet[12:20])
	pseudo += 6 + uint32(len(segment))
	if offlineSum16(pseudo, segment) != 0xffff {
		return errors.New("invalid independent TCP pseudo-header checksum")
	}
	return nil
}

func (d *offlineDevice) ReadPacket() (byte, *stack.PacketBuffer, error) {
	select {
	case <-d.done:
		return 0, nil, io.EOF
	case packet := <-d.packets:
		if len(packet) == 0 {
			return 0, nil, errors.New("empty fixture packet")
		}
		p := stack.NewPacketBuffer(stack.PacketBufferOptions{Payload: buffer.MakeWithData(packet), IsForwardedPacket: true})
		return packet[0] >> 4, p, nil
	default:
		return 0, nil, ErrQueueEmpty
	}
}

func (d *offlineDevice) Wait() {
	select {
	case <-d.done:
	case <-d.notify:
	}
}
func (d *offlineDevice) Close() { d.closed.Do(func() { close(d.done) }) }

type offlineTun struct {
	device *offlineDevice
	mtu    uint32
}

func (*offlineTun) Start() error          { return nil }
func (t *offlineTun) Close() error        { t.device.Close(); return nil }
func (*offlineTun) Name() (string, error) { return "offline-no-host-interface", nil }
func (*offlineTun) Index() (int, error)   { return 999999, nil }
func (t *offlineTun) newEndpoint() (stack.LinkEndpoint, error) {
	return &LinkEndpoint{deviceMTU: t.mtu, device: t.device}, nil
}

type offlineEchoDispatcher struct {
	gate          <-chan struct{}
	entered       chan struct{}
	finished      chan error
	contextAlive  atomic.Bool
	metadataValid atomic.Bool
}

func (*offlineEchoDispatcher) Type() interface{} { return routing.DispatcherType() }
func (*offlineEchoDispatcher) Start() error      { return nil }
func (*offlineEchoDispatcher) Close() error      { return nil }
func (*offlineEchoDispatcher) Dispatch(context.Context, xnet.Destination) (*transport.Link, error) {
	return nil, errors.New("fixture only accepts DispatchLink")
}
func (d *offlineEchoDispatcher) DispatchLink(ctx context.Context, destination xnet.Destination, link *transport.Link) (result error) {
	defer func() { d.finished <- result }()
	inbound := session.InboundFromContext(ctx)
	content := session.ContentFromContext(ctx)
	d.metadataValid.Store(inbound != nil && inbound.Name == "tun" && inbound.User != nil && inbound.User.Level == 8 && inbound.CanSpliceCopy == 3 && content != nil && content.SniffingRequest.Enabled && content.SniffingRequest.RouteOnly && destination.Port == 443)
	close(d.entered)
	if d.gate != nil {
		select {
		case <-d.gate:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	d.contextAlive.Store(ctx.Err() == nil)
	for {
		mb, err := link.Reader.ReadMultiBuffer()
		if len(mb) != 0 {
			if writeErr := link.Writer.WriteMultiBuffer(mb); writeErr != nil {
				return writeErr
			}
		}
		if err != nil {
			if errors.Is(err, io.EOF) {
				return nil
			}
			return err
		}
	}
}

type offlineHarness struct {
	handler        *Handler
	client         *stack.Stack
	clientEndpoint *LinkEndpoint
	server         Stack
	devices        [2]*offlineDevice
	dispatcher     *offlineEchoDispatcher
	cancel         context.CancelFunc
}

func newOfflineHarness(t *testing.T, mtu uint32, gate <-chan struct{}) *offlineHarness {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	a, b := offlineDevicePair()
	dispatcher := &offlineEchoDispatcher{gate: gate, entered: make(chan struct{}), finished: make(chan error, 1)}
	handler := &Handler{ctx: ctx, config: &Config{UserLevel: 8}, dispatcher: dispatcher, tag: "tun", sniffingRequest: session.SniffingRequest{Enabled: true, OverrideDestinationForProtocol: []string{"http", "tls", "quic"}, RouteOnly: true}}
	server, err := NewStack(ctx, StackOptions{Tun: &offlineTun{device: b, mtu: mtu}, IdleTimeout: time.Minute}, handler)
	if err != nil {
		cancel()
		t.Fatal(err)
	}
	if err = server.Start(); err != nil {
		cancel()
		t.Fatal(err)
	}
	clientEndpoint := &LinkEndpoint{deviceMTU: mtu, device: a}
	client, err := createStack(clientEndpoint)
	if err != nil {
		cancel()
		server.Close()
		t.Fatal(err)
	}
	address := tcpip.ProtocolAddress{Protocol: ipv4.ProtocolNumber, AddressWithPrefix: tcpip.AddrFrom4([4]byte{192, 0, 2, 2}).WithPrefix()}
	if e := client.AddProtocolAddress(defaultNIC, address, stack.AddressProperties{}); e != nil {
		cancel()
		server.Close()
		client.Close()
		t.Fatal(e)
	}
	h := &offlineHarness{handler: handler, client: client, clientEndpoint: clientEndpoint, server: server, devices: [2]*offlineDevice{a, b}, dispatcher: dispatcher, cancel: cancel}
	t.Cleanup(func() {
		cancel()
		a.Close()
		b.Close()
		clientEndpoint.Close()
		client.Close()
		for _, ep := range client.CleanupEndpoints() {
			ep.Abort()
		}
		server.Close()
		for _, device := range h.devices {
			select {
			case err := <-device.wireErrors:
				t.Errorf("serialized packet failed independent checks: %v", err)
			default:
			}
			if device.validTCP.Load() == 0 {
				t.Error("fixture emitted no independently validated TCP packets")
			}
		}
	})
	return h
}

func (h *offlineHarness) dial(t *testing.T) *gonet.TCPConn {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	conn, err := gonet.DialContextTCP(ctx, h.client, tcpip.FullAddress{NIC: defaultNIC, Addr: tcpip.AddrFrom4([4]byte{198, 51, 100, 10}), Port: 443}, ipv4.ProtocolNumber)
	if err != nil {
		t.Fatal(err)
	}
	if err := conn.SetDeadline(time.Now().Add(3 * time.Second)); err != nil {
		conn.Close()
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	return conn
}

func offlinePayload(size int) []byte {
	p := make([]byte, size)
	for i := range p {
		p[i] = byte((i*37 + 17) % 251)
	}
	// TLS-record-shaped prefix, so a 64 KiB fixture includes fragmented data.
	if len(p) > 5 {
		copy(p, []byte{0x16, 0x03, 0x01, byte((size - 5) >> 8), byte(size - 5)})
	}
	return p
}

func offlineRoundtrip(t *testing.T, h *offlineHarness, payload []byte, fragmented bool) {
	t.Helper()
	conn := h.dial(t)
	written := make(chan error, 1)
	go func() {
		step := len(payload)
		if fragmented {
			step = 117
		}
		for pos := 0; pos < len(payload); {
			end := pos + step
			if end > len(payload) {
				end = len(payload)
			}
			n, err := conn.Write(payload[pos:end])
			if err != nil {
				written <- err
				return
			}
			if n == 0 {
				written <- io.ErrShortWrite
				return
			}
			pos += n
		}
		written <- nil
	}()
	reply := make([]byte, len(payload))
	if _, err := io.ReadFull(conn, reply); err != nil {
		t.Fatal(err)
	}
	if err := <-written; err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(payload, reply) {
		t.Fatal("TCP payload changed across actual TUN forwarder and Handler.DispatchLink")
	}
	conn.Close()
	select {
	case err := <-h.dispatcher.finished:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("forwarder/dispatcher did not finish after client close")
	}
	if !h.dispatcher.contextAlive.Load() || !h.dispatcher.metadataValid.Load() {
		t.Fatal("per-connection context or inbound metadata was invalid")
	}
}

func TestOfflineTunTCPRoundtrip(t *testing.T) {
	for _, mtu := range []uint32{1280, 1500} {
		for _, size := range []int{1024, 8192, 65536} {
			for _, fragmented := range []bool{false, true} {
				t.Run(fmt.Sprintf("mtu%d/bytes%d/fragmented%t", mtu, size, fragmented), func(t *testing.T) {
					h := newOfflineHarness(t, mtu, nil)
					offlineRoundtrip(t, h, offlinePayload(size), fragmented)
					for _, d := range h.devices {
						if d.count.Load() < 3 || d.maxSize.Load() > int64(mtu) {
							t.Fatalf("unexpected packetization: packets=%d maximum=%d mtu=%d", d.count.Load(), d.maxSize.Load(), mtu)
						}
					}
				})
			}
		}
	}
}

func TestOfflineTunTCPConnectCompletesBeforeUpstreamReady(t *testing.T) {
	gate := make(chan struct{})
	h := newOfflineHarness(t, 1500, gate)
	start := time.Now()
	conn := h.dial(t)
	elapsed := time.Since(start)
	select {
	case <-h.dispatcher.entered:
	case <-time.After(time.Second):
		t.Fatal("local handshake did not reach dispatcher")
	}
	select {
	case err := <-h.dispatcher.finished:
		t.Fatalf("dispatcher finished before upstream ready: %v", err)
	default:
	}
	// Keep the fake upstream blocked after local TCP connect has succeeded.
	time.Sleep(50 * time.Millisecond)
	close(gate)
	payload := offlinePayload(8192)
	if _, err := conn.Write(payload); err != nil {
		t.Fatal(err)
	}
	reply := make([]byte, len(payload))
	if _, err := io.ReadFull(conn, reply); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(payload, reply) || !h.dispatcher.contextAlive.Load() {
		t.Fatal("upstream delay canceled or corrupted connection")
	}
	conn.Close()
	select {
	case err := <-h.dispatcher.finished:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("dispatcher cleanup timeout")
	}
	t.Logf("local TCP connect=%s; upstream held closed an additional 50ms; payload exact", elapsed)
}

func TestOfflineSerializedPacketOracleRejectsCorruption(t *testing.T) {
	h := newOfflineHarness(t, 1500, nil)
	conn := h.dial(t)
	defer conn.Close()
	first := h.devices[0].firstPacket.Load()
	if first == nil || len(*first) < 40 {
		t.Fatal("no serialized SYN captured")
	}
	if err := offlineValidateIPv4TCP(*first); err != nil {
		t.Fatal(err)
	}
	for _, test := range []struct {
		name  string
		alter func([]byte) []byte
	}{
		{"IPv4 checksum", func(p []byte) []byte { p[10] ^= 1; return p }},
		{"TCP checksum", func(p []byte) []byte { ihl := int(p[0]&15) * 4; p[ihl+16] ^= 1; return p }},
		{"serialized length", func(p []byte) []byte { return p[:len(p)-1] }},
	} {
		t.Run(test.name, func(t *testing.T) {
			bad := test.alter(bytes.Clone(*first))
			if offlineValidateIPv4TCP(bad) == nil {
				t.Fatal("independent packet oracle accepted corruption")
			}
		})
	}
}

package offline

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"testing"
	"time"

	"github.com/xtls/xray-core/common"
	"github.com/xtls/xray-core/common/protocol"
	xraytls "github.com/xtls/xray-core/common/protocol/tls"
)

// TLS emits its real ClientHello into memory. No listener, socket or DNS call
// exists: the peer returns EOF rather than pretending to establish TLS.
type sniffHelloCapture struct{ bytes.Buffer }

func (*sniffHelloCapture) Read([]byte) (int, error)         { return 0, io.EOF }
func (*sniffHelloCapture) Close() error                     { return nil }
func (*sniffHelloCapture) LocalAddr() net.Addr              { return &net.TCPAddr{} }
func (*sniffHelloCapture) RemoteAddr() net.Addr             { return &net.TCPAddr{} }
func (*sniffHelloCapture) SetDeadline(time.Time) error      { return nil }
func (*sniffHelloCapture) SetReadDeadline(time.Time) error  { return nil }
func (*sniffHelloCapture) SetWriteDeadline(time.Time) error { return nil }

func sniffActualClientHello(t *testing.T, serverName string) []byte {
	t.Helper()
	capture := &sniffHelloCapture{}
	client := tls.Client(capture, &tls.Config{ServerName: serverName, MinVersion: tls.VersionTLS12})
	defer client.Close()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if client.HandshakeContext(ctx) == nil {
		t.Fatal("memory EOF must not pretend that TLS succeeded")
	}
	hello := bytes.Clone(capture.Bytes())
	if len(hello) <= 117 || hello[0] != 0x16 || 5+int(binary.BigEndian.Uint16(hello[3:5])) > len(hello) {
		t.Fatal("TLS did not emit a complete ClientHello record")
	}
	return hello
}

func TestPinnedTLSSniffRequestsMoreDataForFragmentedClientHello(t *testing.T) {
	hello := sniffActualClientHello(t, "fixture.example")
	header, err := xraytls.SniffTLS(hello[:117])
	if header != nil || !errors.Is(err, protocol.ErrProtoNeedMoreData) {
		t.Fatal("TLS record prefix did not request more data")
	}
	header, err = xraytls.SniffTLS(hello)
	if err != nil || header == nil || header.Protocol() != "tls" || header.Domain() != "fixture.example" {
		t.Fatal("complete ClientHello lost its actual SNI after the prefix")
	}
}

func TestPinnedTLSSniffPreservesShortAndMalformedInputs(t *testing.T) {
	hello := sniffActualClientHello(t, "fixture.example")
	if _, err := xraytls.SniffTLS(hello[:4]); !errors.Is(err, common.ErrNoClue) {
		t.Fatal("short non-record prefix changed semantics")
	}
	malformed := bytes.Clone(hello)
	// Preserve the complete TLS record but corrupt its cipher-suite length.
	// An odd byte count is invalid, not an incomplete network fragment.
	sessionIDLength := int(malformed[5+38])
	cipherLengthOffset := 5 + 39 + sessionIDLength
	malformed[cipherLengthOffset], malformed[cipherLengthOffset+1] = 0, 1
	if header, err := xraytls.SniffTLS(malformed); header != nil || err == nil || errors.Is(err, protocol.ErrProtoNeedMoreData) {
		t.Fatal("malformed full record was treated as a fragment")
	}
	hello[0] = 0
	if header, err := xraytls.SniffTLS(hello); header != nil || err == nil || errors.Is(err, protocol.ErrProtoNeedMoreData) {
		t.Fatal("non-TLS record was treated as a fragment")
	}
	withoutSNI := sniffActualClientHello(t, "192.0.2.1")
	if header, err := xraytls.SniffTLS(withoutSNI); header != nil || err == nil || errors.Is(err, protocol.ErrProtoNeedMoreData) {
		t.Fatal("complete IP-only ClientHello invented an SNI or requested more data")
	}
}

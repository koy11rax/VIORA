package tun

import (
	"bufio"
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"testing"
	"time"

	"github.com/xtls/xray-core/core"
)

func offlineEphemeralTLS(t *testing.T) (*tls.Config, *tls.Config) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{
		SerialNumber: big.NewInt(1), DNSNames: []string{"fixture.example"},
		IPAddresses: []net.IP{net.ParseIP("198.51.100.10")},
		NotBefore:   time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		KeyUsage:    x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}, IsCA: true, BasicConstraintsValid: true,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	pool := x509.NewCertPool()
	pool.AddCert(cert)
	return &tls.Config{Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: key}}, MinVersion: tls.VersionTLS12},
		&tls.Config{RootCAs: pool, ServerName: "fixture.example", MinVersion: tls.VersionTLS12}
}

func TestOfflineTunActualDispatcherVerifiedTLSHTTP(t *testing.T) {
	serverTLS, clientTLS := offlineEphemeralTLS(t)
	for _, mtu := range []uint32{1280, 1500} {
		for _, size := range []int{1024, 8192, 65536} {
			t.Run(fmt.Sprintf("mtu%d/body%d", mtu, size), func(t *testing.T) {
				body := offlinePayload(size)
				served := make(chan error, 1)
				dialer := &offlinePipeDialer{observations: make(chan offlineDialObservation, 4), delay: 25 * time.Millisecond}
				dialer.serve = func(raw net.Conn) {
					var serveErr error
					defer func() { served <- serveErr }()
					server := tls.Server(raw, serverTLS.Clone())
					ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
					defer cancel()
					if serveErr = server.HandshakeContext(ctx); serveErr != nil {
						return
					}
					req, err := http.ReadRequest(bufio.NewReader(server))
					if err != nil {
						serveErr = err
						return
					}
					got, err := io.ReadAll(io.LimitReader(req.Body, 128*1024))
					req.Body.Close()
					if err != nil {
						serveErr = err
						return
					}
					if !bytes.Equal(got, body) {
						serveErr = fmt.Errorf("TLS server received changed request body")
						return
					}
					if _, serveErr = fmt.Fprintf(server, "HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n", len(got)); serveErr != nil {
						return
					}
					_, serveErr = server.Write(got)
				}
				actual, instance := offlineActualDispatcher(t, dialer)
				h := newOfflineHarness(t, mtu, nil)
				h.handler.dispatcher = actual
				h.handler.ctx = context.WithValue(h.handler.ctx, core.XrayKey(1), instance)
				raw := h.dial(t)
				client := tls.Client(raw, clientTLS.Clone())
				defer client.Close()
				ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
				defer cancel()
				if err := client.HandshakeContext(ctx); err != nil {
					t.Fatal(err)
				}
				if !client.ConnectionState().HandshakeComplete || len(client.ConnectionState().VerifiedChains) == 0 {
					t.Fatal("TLS was not authenticated")
				}
				req, err := http.NewRequest(http.MethodPost, "https://fixture.example/offline", bytes.NewReader(body))
				if err != nil {
					t.Fatal(err)
				}
				req.Close = true
				if err = req.Write(client); err != nil {
					t.Fatal(err)
				}
				response, err := http.ReadResponse(bufio.NewReader(client), req)
				if err != nil {
					t.Fatal(err)
				}
				got, err := io.ReadAll(io.LimitReader(response.Body, 128*1024))
				response.Body.Close()
				if err != nil {
					t.Fatal(err)
				}
				if response.StatusCode != 200 || !bytes.Equal(got, body) {
					t.Fatal("authenticated TLS HTTP roundtrip corrupted data")
				}
				select {
				case err := <-served:
					if err != nil {
						t.Fatal(err)
					}
				case <-time.After(time.Second):
					t.Fatal("TLS fixture did not finish")
				}
				observation := <-dialer.observations
				if observation.tag != "sniffed" || observation.route != "fixture.example" || observation.protocol != "tls" || !observation.alive || observation.target != "198.51.100.10" {
					t.Fatalf("wrong actual outbound context: %+v", observation)
				}
				for _, device := range h.devices {
					if device.maxSize.Load() > int64(mtu) {
						t.Fatal("serialized packet exceeded MTU")
					}
				}
				t.Logf("TLS authenticated; HTTP200 exact%dbytes; serializedTCP packets client=%d server=%d; MTU%d", size, h.devices[0].validTCP.Load(), h.devices[1].validTCP.Load(), mtu)
			})
		}
	}
}

package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/binary"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

type isolatedProtocolCase struct {
	name, protocol string
	config         map[string]any
}

func isolatedProtocolConfigurations(t *testing.T) []isolatedProtocolCase {
	t.Helper()
	var cases []isolatedProtocolCase
	if source := os.Getenv("VIORA_TEST_DART_PROTOCOLS"); source != "" {
		data, err := os.ReadFile(source)
		if err != nil {
			t.Fatal(err)
		}
		var generated []struct {
			Name   string
			Config map[string]any
		}
		if err := json.Unmarshal(data, &generated); err != nil {
			t.Fatal(err)
		}
		if len(generated) < 5 {
			t.Fatal("Dart fixture set is incomplete")
		}
		for _, entry := range generated {
			out, ok := entry.Config["outbounds"].([]any)
			if !ok || len(out) == 0 {
				t.Fatal("Dart config has no outbound")
			}
			protocol, _ := out[0].(map[string]any)["protocol"].(string)
			cases = append(cases, isolatedProtocolCase{entry.Name, protocol, entry.Config})
		}
		return cases
	}
	for _, protocol := range []string{"vless", "vmess", "trojan", "shadowsocks", "hysteria"} {
		cases = append(cases, isolatedProtocolCase{protocol, protocol, protocolFixture(protocol)})
	}
	return cases
}

func isolateIncorrectProxyCredential(t *testing.T, config map[string]any) {
	t.Helper()
	proxy := config["outbounds"].([]any)[0].(map[string]any)
	peer, err := proxyEndpoint(proxy)
	if err != nil {
		t.Fatal(err)
	}
	switch proxy["protocol"] {
	case "vless", "vmess":
		peer["users"].([]any)[0].(map[string]any)["id"] = "00000000-0000-4000-8000-000000000099"
	case "trojan", "shadowsocks":
		peer["password"] = "incorrect-fixture-password"
	case "hysteria":
		proxy["streamSettings"].(map[string]any)["hysteriaSettings"].(map[string]any)["auth"] = "incorrect-fixture-password"
	default:
		t.Fatal("unknown protocol in negative fixture")
	}
}

// This opt-in fixture runs actual pinned cores against ephemeral loopback
// protocol servers and a local HTTP destination. It creates no TUN, routes,
// firewall policy, host service, external network request or production config.
// The ephemeral CA is injected only into this test's in-memory client AFTER
// testing the privileged sanitizer: applications cannot supply CA/file options.
func TestIsolatedProtocolTransfersWithPinnedCore(t *testing.T) {
	core := os.Getenv("VIORA_TEST_CORE")
	if core == "" {
		t.Skip("set VIORA_TEST_CORE to enable isolated actual-core protocol tests")
	}
	certificate, key := isolatedProtocolCertificate(t)
	for _, test := range isolatedProtocolConfigurations(t) {
		protocol := test.protocol
		t.Run(test.name, func(t *testing.T) {
			serverPort := isolatedProtocolPort(t, protocol == "hysteria")
			clientPort := isolatedProtocolPort(t, false)
			var received atomic.Int64
			local, err := net.Listen("tcp4", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			targetPort := uint16(local.Addr().(*net.TCPAddr).Port)
			target := &http.Server{ReadHeaderTimeout: time.Second, Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				received.Add(1)
				_, _ = io.WriteString(w, "isolated-protocol-transfer-ok")
			})}
			go func() { _ = target.Serve(local) }()
			t.Cleanup(func() { _ = target.Close() })
			input := test.config
			proxy := input["outbounds"].([]any)[0].(map[string]any)
			// The IPC schema carries a numeric test endpoint before bootstrap.
			encodedProxy, _ := json.Marshal(proxy)
			validatedProxy, err := sanitizeProxy(encodedProxy)
			if err != nil {
				t.Fatal(err)
			}
			peer, err := proxyEndpoint(validatedProxy)
			if err != nil {
				t.Fatal(err)
			}
			peer["address"], peer["port"] = "127.0.0.1", serverPort
			stream := validatedProxy["streamSettings"].(map[string]any)
			stream["sockopt"] = map[string]any{"interface": "fixture-only"}
			input["outbounds"].([]any)[0] = validatedProxy
			data, _ := json.Marshal(input)
			clean, err := sanitizeConfig(data)
			if err != nil {
				t.Fatal(err)
			}
			proxy = proxyMap(clean)
			stream = proxy["streamSettings"].(map[string]any)
			stream["sockopt"] = map[string]any{"interface": "fixture-only"}
			backend, _, err := buildDesktopBridge(clean, clientPort, "fixture-user", strings.Repeat("p", 32))
			if err != nil {
				t.Fatal(err)
			}
			// Binding physical interfaces is validated separately with native
			// dependency fixtures. Loopback tests must not select a host underlay.
			delete(backend["outbounds"].([]any)[0].(map[string]any)["streamSettings"].(map[string]any), "sockopt")
			server := isolatedProtocolServer(t, protocol, validatedProxy, serverPort, targetPort, certificate, key)
			isolatedProtocolCore(t, core, server)
			usesTLS := backend["outbounds"].([]any)[0].(map[string]any)["streamSettings"].(map[string]any)["security"] == "tls"
			if usesTLS {
				tls := backend["outbounds"].([]any)[0].(map[string]any)["streamSettings"].(map[string]any)["tlsSettings"].(map[string]any)
				tls["certificates"] = []any{map[string]any{"usage": "verify", "certificate": certificate}}
				tls["serverName"] = "fixture.invalid"
			}
			stop := isolatedProtocolCore(t, core, backend)
			result, err := isolatedProtocolRequest(clientPort, targetPort)
			if err != nil || !strings.Contains(result, "isolated-protocol-transfer-ok") || received.Load() != 1 {
				t.Fatalf("actual %s transfer failed: %v (destination requests %d)", protocol, err, received.Load())
			}
			stop()
			badPassword, cloneErr := cloneBridgeMap(backend)
			if cloneErr != nil {
				t.Fatal(cloneErr)
			}
			badPasswordPort := isolatedProtocolPort(t, false)
			badPassword["inbounds"].([]any)[0].(map[string]any)["port"] = badPasswordPort
			isolateIncorrectProxyCredential(t, badPassword)
			stopBadPassword := isolatedProtocolCore(t, core, badPassword)
			badAuth, _ := isolatedProtocolRequest(badPasswordPort, targetPort)
			if strings.Contains(badAuth, "isolated-protocol-transfer-ok") || received.Load() != 1 {
				t.Fatal("invalid credential reached protected destination")
			}
			stopBadPassword()
			if !usesTLS {
				return
			}
			badPort := isolatedProtocolPort(t, false)
			backend["inbounds"].([]any)[0].(map[string]any)["port"] = badPort
			backend["outbounds"].([]any)[0].(map[string]any)["streamSettings"].(map[string]any)["tlsSettings"].(map[string]any)["serverName"] = "wrong.invalid"
			isolatedProtocolCore(t, core, backend)
			bad, _ := isolatedProtocolRequest(badPort, targetPort)
			if strings.Contains(bad, "isolated-protocol-transfer-ok") || received.Load() != 1 {
				t.Fatal("TLS accepted a different server identity")
			}
		})
	}
}

func isolatedProtocolCertificate(t *testing.T) ([]string, []string) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	value := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "VIORA isolated test CA"}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), DNSNames: []string{"fixture.invalid"}, IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	der, err := x509.CreateCertificate(rand.Reader, value, value, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	encodedKey, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	return strings.Split(strings.TrimSpace(string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}))), "\n"), strings.Split(strings.TrimSpace(string(pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: encodedKey}))), "\n")
}

func isolatedProtocolServer(t *testing.T, protocol string, proxy map[string]any, port, targetPort uint16, certificate, key []string) map[string]any {
	t.Helper()
	stream, err := cloneBridgeMap(proxy["streamSettings"].(map[string]any))
	if err != nil {
		t.Fatal(err)
	}
	delete(stream, "sockopt")
	if protocol != "shadowsocks" {
		stream["tlsSettings"] = map[string]any{"certificates": []any{map[string]any{"certificate": certificate, "key": key}}}
	}
	settings := map[string]any{}
	switch protocol {
	case "vless":
		settings = map[string]any{"decryption": "none", "clients": []any{map[string]any{"id": "00000000-0000-4000-8000-000000000001"}}}
	case "vmess":
		settings = map[string]any{"clients": []any{map[string]any{"id": "00000000-0000-4000-8000-000000000001"}}}
	case "trojan":
		settings = map[string]any{"clients": []any{map[string]any{"password": "fixture-password"}}}
	case "shadowsocks":
		peer, _ := proxyEndpoint(proxy)
		settings = map[string]any{"method": peer["method"], "password": "fixture-password", "network": "tcp,udp"}
	case "hysteria":
		settings = map[string]any{"version": 2, "clients": []any{map[string]any{"auth": "fixture-password"}}}
		stream["hysteriaSettings"] = map[string]any{"version": 2}
	}
	return map[string]any{"log": map[string]any{"loglevel": "warning"}, "inbounds": []any{map[string]any{"listen": "127.0.0.1", "port": port, "protocol": protocol, "settings": settings, "streamSettings": stream}}, "outbounds": []any{map[string]any{"protocol": "freedom", "settings": map[string]any{"finalRules": []any{map[string]any{"action": "allow", "ip": []string{"127.0.0.1/32"}, "port": fmt.Sprint(targetPort), "network": "tcp"}, map[string]any{"action": "block", "blockDelay": "0"}}}}}}
}

func isolatedProtocolPort(t *testing.T, udp bool) uint16 {
	t.Helper()
	if udp {
		conn, err := net.ListenPacket("udp4", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		defer conn.Close()
		return uint16(conn.LocalAddr().(*net.UDPAddr).Port)
	}
	conn, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	return uint16(conn.Addr().(*net.TCPAddr).Port)
}

func isolatedProtocolCore(t *testing.T, core string, config map[string]any) func() {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	data, err := json.Marshal(config)
	if err != nil {
		cancel()
		t.Fatal(err)
	}
	cmd := exec.CommandContext(ctx, core, "run", "-format", "json", "-config", "stdin:")
	cmd.Stdin = bytes.NewReader(data)
	logs, err := cmd.StdoutPipe()
	if err != nil {
		cancel()
		t.Fatal(err)
	}
	cmd.Stderr = cmd.Stdout
	if err := cmd.Start(); err != nil {
		cancel()
		t.Fatal(err)
	}
	done, marked := make(chan struct{}), make(chan struct{})
	go func() {
		defer close(done)
		scanner := bufio.NewScanner(logs)
		ready := false
		for scanner.Scan() {
			if !ready && strings.Contains(scanner.Text(), "Xray") && strings.Contains(scanner.Text(), "started") {
				ready = true
				close(marked)
			}
		}
	}()
	stopped := atomic.Bool{}
	stop := func() {
		if stopped.CompareAndSwap(false, true) {
			cancel()
			_ = cmd.Wait()
			_ = logs.Close()
			<-done
		}
	}
	t.Cleanup(stop)
	select {
	case <-marked:
		return stop
	case <-done:
		stop()
		t.Fatal("isolated protocol core exited before readiness")
	case <-time.After(5 * time.Second):
		stop()
		t.Fatal("isolated protocol core readiness timed out")
	}
	return stop
}

func isolatedProtocolRequest(proxyPort, destinationPort uint16) (string, error) {
	conn, err := net.DialTimeout("tcp4", net.JoinHostPort("127.0.0.1", fmt.Sprint(proxyPort)), time.Second)
	if err != nil {
		return "", err
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(4 * time.Second))
	if err := authenticateBridgeStream(conn, "fixture-user", strings.Repeat("p", 32)); err != nil {
		return "", err
	}
	request := []byte{5, 1, 0, 1, 127, 0, 0, 1, 0, 0}
	binary.BigEndian.PutUint16(request[8:], destinationPort)
	if _, err := conn.Write(request); err != nil {
		return "", err
	}
	response := make([]byte, 10)
	if _, err := io.ReadFull(conn, response); err != nil {
		return "", err
	}
	if response[0] != 5 || response[1] != 0 || response[3] != 1 {
		return "", fmt.Errorf("SOCKS connect rejected")
	}
	if _, err := io.WriteString(conn, "GET / HTTP/1.1\r\nHost: fixture.invalid\r\nConnection: close\r\n\r\n"); err != nil {
		return "", err
	}
	result, err := io.ReadAll(io.LimitReader(conn, 4096))
	return string(result), err
}

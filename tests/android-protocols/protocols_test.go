package protocoltests

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"math/big"
	"net"
	"os"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	libv2ray "github.com/2dust/AndroidLibXrayLite"
	xnet "github.com/xtls/xray-core/common/net"
	core "github.com/xtls/xray-core/core"
	serial "github.com/xtls/xray-core/infra/conf/serial"
	"github.com/xtls/xray-core/transport/internet"
)

// An additional fail-closed boundary makes accidental fixture DNS/public dials
// impossible. These are real proxy sockets, without a TUN, routes or host VPN.
type fixtureLoopbackDialer struct{ dialer internet.DefaultSystemDialer }

type fixtureProtector struct{ allowed atomic.Bool }

func (p *fixtureProtector) Protect(fd int64) bool { return fd >= 0 && p.allowed.Load() }

func (d *fixtureLoopbackDialer) Dial(ctx context.Context, source xnet.Address, destination xnet.Destination, options *internet.SocketConfig) (net.Conn, error) {
	if destination.Address == nil || destination.Address.Family().IsDomain() || !destination.Address.IP().IsLoopback() {
		return nil, errors.New("fixture refuses non-loopback destination")
	}
	return d.dialer.Dial(ctx, source, destination, options)
}
func (*fixtureLoopbackDialer) DestIpAddress() xnet.IP { return nil }

type fixtureTLS struct{ certificate, key []string }

func protocolFixtureTLS(t *testing.T) fixtureTLS {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "VIORA isolated protocol fixture"},
		DNSNames: []string{"fixture.invalid"}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	encodedKey, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	lines := func(data []byte) []string { return strings.Split(strings.TrimSpace(string(data)), "\n") }
	return fixtureTLS{lines(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})), lines(pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: encodedKey}))}
}

func fixtureCore(t *testing.T, configuration map[string]any) *core.Instance {
	t.Helper()
	configuration["log"] = map[string]any{"loglevel": "none"}
	if os.Getenv("VIORA_PROTOCOL_DEBUG") == "1" {
		configuration["log"] = map[string]any{"loglevel": "debug"}
	}
	data, err := json.Marshal(configuration)
	if err != nil {
		t.Fatal(err)
	}
	config, err := serial.LoadJSONConfig(bytes.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}
	instance, err := core.New(config)
	if err != nil {
		t.Fatal(err)
	}
	if err := instance.Start(); err != nil {
		instance.Close()
		t.Fatal(err)
	}
	t.Cleanup(func() { instance.Close() })
	return instance
}

func fixturePort(t *testing.T, udp bool) int {
	t.Helper()
	if udp {
		listener, err := net.ListenPacket("udp4", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		port := listener.LocalAddr().(*net.UDPAddr).Port
		listener.Close()
		return port
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	listener.Close()
	return port
}

func fixtureEcho(t *testing.T, udp bool) xnet.Destination {
	t.Helper()
	if udp {
		connection, err := net.ListenPacket("udp4", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { connection.Close() })
		go func() {
			buffer := make([]byte, 2048)
			for {
				n, address, err := connection.ReadFrom(buffer)
				if err != nil {
					return
				}
				connection.WriteTo(buffer[:n], address)
			}
		}()
		return xnet.UDPDestination(xnet.LocalHostIP, xnet.Port(connection.LocalAddr().(*net.UDPAddr).Port))
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	go func() {
		for {
			connection, err := listener.Accept()
			if err != nil {
				return
			}
			go func() { defer connection.Close(); io.Copy(connection, connection) }()
		}
	}()
	return xnet.TCPDestination(xnet.LocalHostIP, xnet.Port(listener.Addr().(*net.TCPAddr).Port))
}

func fixtureRoundTrip(t *testing.T, instance *core.Instance, destination xnet.Destination) error {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	connection, err := core.Dial(ctx, instance, destination)
	if err != nil {
		return err
	}
	defer connection.Close()
	done := make(chan error, 1)
	go func() {
		payload := []byte("VIORA isolated proxy fixture")
		if _, err := connection.Write(payload); err != nil {
			done <- err
			return
		}
		buffer := make([]byte, len(payload))
		if _, err := io.ReadFull(connection, buffer); err != nil {
			done <- err
			return
		}
		if !bytes.Equal(buffer, payload) {
			done <- errors.New("proxy changed payload")
			return
		}
		done <- nil
	}()
	select {
	case err := <-done:
		return err
	case <-ctx.Done():
		connection.Close()
		select {
		case <-done:
		case <-time.After(time.Second):
			t.Error("proxy I/O did not stop on close")
		}
		return ctx.Err()
	}
}

type protocolFixtureCase struct {
	name, protocol, network, method string
	tls, salamander                 bool
}

func (fixture protocolFixtureCase) configurations(port int, certificate fixtureTLS) (map[string]any, map[string]any) {
	const userID = "00112233-4455-6677-8899-aabbccddeeff"
	const password = "isolated-fixture-password"
	clientSettings := map[string]any{}
	serverSettings := map[string]any{}
	switch fixture.protocol {
	case "vless", "vmess":
		user := map[string]any{"id": userID}
		if fixture.protocol == "vless" {
			user["encryption"] = "none"
			serverSettings["decryption"] = "none"
		} else {
			user["security"] = "auto"
		}
		clientSettings["vnext"] = []any{map[string]any{"address": "127.0.0.1", "port": port, "users": []any{user}}}
		serverSettings["clients"] = []any{map[string]any{"id": userID}}
	case "trojan":
		clientSettings["servers"] = []any{map[string]any{"address": "127.0.0.1", "port": port, "password": password}}
		serverSettings["clients"] = []any{map[string]any{"password": password}}
	case "shadowsocks":
		clientSettings["servers"] = []any{map[string]any{"address": "127.0.0.1", "port": port, "method": fixture.method, "password": password}}
		serverSettings = map[string]any{"method": fixture.method, "password": password, "network": "tcp,udp"}
	case "hysteria":
		clientSettings = map[string]any{"version": 2, "address": "127.0.0.1", "port": port}
		serverSettings = map[string]any{"version": 2, "clients": []any{map[string]any{"auth": password}}}
	}
	clientStream := map[string]any{"network": fixture.network, "security": "none"}
	serverStream := map[string]any{"network": fixture.network, "security": "none"}
	if fixture.tls {
		clientStream["security"] = "tls"
		serverStream["security"] = "tls"
		clientStream["tlsSettings"] = map[string]any{"serverName": "fixture.invalid", "certificates": []any{map[string]any{"certificate": certificate.certificate, "usage": "verify"}}}
		serverStream["tlsSettings"] = map[string]any{"certificates": []any{map[string]any{"certificate": certificate.certificate, "key": certificate.key}}}
	}
	if fixture.network == "ws" {
		clientStream["wsSettings"] = map[string]any{"path": "/fixture", "headers": map[string]any{"Host": "fixture.invalid"}}
		serverStream["wsSettings"] = map[string]any{"path": "/fixture"}
	}
	if fixture.protocol == "hysteria" {
		clientStream["hysteriaSettings"] = map[string]any{"version": 2, "auth": password}
		clientStream["tlsSettings"].(map[string]any)["alpn"] = []string{"h3"}
		serverStream["hysteriaSettings"] = map[string]any{"version": 2}
		if fixture.salamander {
			mask := map[string]any{"udp": []any{map[string]any{"type": "salamander", "settings": map[string]any{"password": "isolated-obfs-password"}}}}
			clientStream["finalmask"] = mask
			serverStream["finalmask"] = mask
		}
	}
	server := map[string]any{"inbounds": []any{map[string]any{"listen": "127.0.0.1", "port": port, "protocol": fixture.protocol, "settings": serverSettings, "streamSettings": serverStream}}, "outbounds": []any{map[string]any{"protocol": "freedom"}}}
	client := map[string]any{"outbounds": []any{map[string]any{"tag": "proxy", "protocol": fixture.protocol, "settings": clientSettings, "streamSettings": clientStream}}}
	return server, client
}

func TestIsolatedProtocolTraffic(t *testing.T) {
	protector := &fixtureProtector{}
	protector.allowed.Store(true)
	if err := libv2ray.UseProtector(protector); err != nil {
		t.Fatal(err)
	}
	internet.UseAlternativeSystemDialer(&fixtureLoopbackDialer{})
	defer internet.UseAlternativeSystemDialer(nil)
	certificate := protocolFixtureTLS(t)
	cases := []protocolFixtureCase{
		{"VLESS-TCP-TLS", "vless", "tcp", "", true, false},
		{"VMess-TCP", "vmess", "tcp", "", false, false},
		{"VMess-WS-TLS", "vmess", "ws", "", true, false},
		{"Trojan-TCP-TLS", "trojan", "tcp", "", true, false},
		{"Trojan-WS-TLS", "trojan", "ws", "", true, false},
		{"SS-AES128-GCM", "shadowsocks", "tcp", "aes-128-gcm", false, false},
		{"SS-AES256-GCM", "shadowsocks", "tcp", "aes-256-gcm", false, false},
		{"SS-ChaCha20", "shadowsocks", "tcp", "chacha20-ietf-poly1305", false, false},
		{"Hysteria2", "hysteria", "hysteria", "", true, false},
		{"Hysteria2-Salamander", "hysteria", "hysteria", "", true, true},
	}
	for _, fixture := range cases {
		t.Run(fixture.name, func(t *testing.T) {
			targets := []xnet.Destination{fixtureEcho(t, false), fixtureEcho(t, true)}
			port := fixturePort(t, fixture.protocol == "hysteria")
			server, client := fixture.configurations(port, certificate)
			// Current Xray freedom defaults reject private proxy targets. Permit
			// only these two ephemeral echo endpoints in this fixture server;
			// all other destinations are blocked. Production defaults stay intact.
			finalRules := []any{}
			for _, target := range targets {
				finalRules = append(finalRules, map[string]any{"action": "allow", "ip": []string{"127.0.0.1/32"}, "port": strconv.Itoa(int(target.Port)), "network": strings.ToLower(target.Network.String())})
			}
			finalRules = append(finalRules, map[string]any{"action": "block", "blockDelay": "0"})
			server["outbounds"].([]any)[0].(map[string]any)["settings"] = map[string]any{"finalRules": finalRules}
			fixtureCore(t, server)
			instance := fixtureCore(t, client)
			for _, udp := range []bool{false, true} {
				name := "TCP"
				if udp {
					name = "UDP"
				}
				t.Run(name, func(t *testing.T) {
					target := targets[0]
					if udp {
						target = targets[1]
					}
					if err := fixtureRoundTrip(t, instance, target); err != nil {
						t.Fatal(err)
					}
				})
			}
		})
	}
}

func TestIsolatedProtocolRejectsInvalidCredentialsAndTLS(t *testing.T) {
	protector := &fixtureProtector{}
	protector.allowed.Store(true)
	if err := libv2ray.UseProtector(protector); err != nil {
		t.Fatal(err)
	}
	internet.UseAlternativeSystemDialer(&fixtureLoopbackDialer{})
	defer internet.UseAlternativeSystemDialer(nil)
	certificate := protocolFixtureTLS(t)
	cases := []struct {
		fixture  protocolFixtureCase
		mutation string
	}{
		{protocolFixtureCase{"VLESS-TLS-name", "vless", "tcp", "", true, false}, "tls-name"},
		{protocolFixtureCase{"VMess-user", "vmess", "tcp", "", false, false}, "uuid"},
		{protocolFixtureCase{"Trojan-password", "trojan", "tcp", "", true, false}, "password"},
		{protocolFixtureCase{"Shadowsocks-password", "shadowsocks", "tcp", "aes-128-gcm", false, false}, "password"},
		{protocolFixtureCase{"Hysteria2-auth", "hysteria", "hysteria", "", true, true}, "auth"},
		{protocolFixtureCase{"Hysteria2-TLS-name", "hysteria", "hysteria", "", true, true}, "tls-name"},
		{protocolFixtureCase{"Hysteria2-untrusted-TLS", "hysteria", "hysteria", "", true, true}, "tls-root"},
	}
	for _, row := range cases {
		t.Run(row.fixture.name, func(t *testing.T) {
			target := fixtureEcho(t, false)
			server, client := row.fixture.configurations(fixturePort(t, row.fixture.protocol == "hysteria"), certificate)
			server["outbounds"].([]any)[0].(map[string]any)["settings"] = map[string]any{"finalRules": []any{
				map[string]any{"action": "allow", "ip": []string{"127.0.0.1/32"}, "port": strconv.Itoa(int(target.Port)), "network": "tcp"},
				map[string]any{"action": "block", "blockDelay": "0"},
			}}
			proxy := client["outbounds"].([]any)[0].(map[string]any)
			settings := proxy["settings"].(map[string]any)
			stream := proxy["streamSettings"].(map[string]any)
			switch row.mutation {
			case "tls-name":
				stream["tlsSettings"].(map[string]any)["serverName"] = "wrong.invalid"
			case "tls-root":
				delete(stream["tlsSettings"].(map[string]any), "certificates")
			case "auth":
				stream["hysteriaSettings"].(map[string]any)["auth"] = "wrong-auth"
			case "uuid":
				settings["vnext"].([]any)[0].(map[string]any)["users"].([]any)[0].(map[string]any)["id"] = "11223344-5566-7788-99aa-bbccddeeff00"
			case "password":
				settings["servers"].([]any)[0].(map[string]any)["password"] = "wrong-password"
			}
			fixtureCore(t, server)
			if err := fixtureRoundTrip(t, fixtureCore(t, client), target); err == nil {
				t.Fatal("invalid credentials or TLS identity were accepted")
			}
		})
	}
}

func TestGeneratedDartProtocolOutbounds(t *testing.T) {
	path := os.Getenv("VIORA_TEST_DART_PROTOCOLS")
	if path == "" {
		t.Skip("set VIORA_TEST_DART_PROTOCOLS to the synthetic production-Dart DTO export")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var rows []struct {
		Name   string         `json:"name"`
		Config map[string]any `json:"config"`
	}
	if err := json.Unmarshal(data, &rows); err != nil {
		t.Fatal(err)
	}
	if len(rows) != 13 {
		t.Fatal("expected the 13 generated production-Dart protocol cases")
	}
	protector := &fixtureProtector{}
	protector.allowed.Store(true)
	if err := libv2ray.UseProtector(protector); err != nil {
		t.Fatal(err)
	}
	internet.UseAlternativeSystemDialer(&fixtureLoopbackDialer{})
	defer internet.UseAlternativeSystemDialer(nil)
	certificate := protocolFixtureTLS(t)
	for _, row := range rows {
		t.Run(row.Name, func(t *testing.T) {
			outbounds, ok := row.Config["outbounds"].([]any)
			if !ok || len(outbounds) == 0 {
				t.Fatal("missing generated outbound")
			}
			proxy := outbounds[0].(map[string]any)
			protocol := proxy["protocol"].(string)
			stream, _ := proxy["streamSettings"].(map[string]any)
			network, security := "tcp", "none"
			if stream != nil {
				network, _ = stream["network"].(string)
				security, _ = stream["security"].(string)
			}
			fixture := protocolFixtureCase{name: row.Name, protocol: protocol, network: network, tls: security == "tls"}
			settings := proxy["settings"].(map[string]any)
			var endpoint map[string]any
			switch protocol {
			case "vless", "vmess":
				endpoint = settings["vnext"].([]any)[0].(map[string]any)
			case "trojan", "shadowsocks":
				endpoint = settings["servers"].([]any)[0].(map[string]any)
			case "hysteria":
				endpoint = settings
			default:
				t.Fatal("unexpected generated protocol")
			}
			if protocol == "shadowsocks" {
				fixture.method = endpoint["method"].(string)
			}
			port := fixturePort(t, protocol == "hysteria")
			endpoint["address"], endpoint["port"] = "127.0.0.1", port
			server, _ := fixture.configurations(port, certificate)
			inbound := server["inbounds"].([]any)[0].(map[string]any)
			serverSettings := inbound["settings"].(map[string]any)
			switch protocol {
			case "vless", "vmess":
				serverSettings["clients"].([]any)[0].(map[string]any)["id"] = endpoint["users"].([]any)[0].(map[string]any)["id"]
			case "trojan":
				serverSettings["clients"].([]any)[0].(map[string]any)["password"] = endpoint["password"]
			case "shadowsocks":
				serverSettings["password"] = endpoint["password"]
			case "hysteria":
				serverSettings["clients"].([]any)[0].(map[string]any)["auth"] = stream["hysteriaSettings"].(map[string]any)["auth"]
				if mask, ok := stream["finalmask"]; ok {
					inbound["streamSettings"].(map[string]any)["finalmask"] = mask
				}
			}
			if fixture.tls {
				// Keep the actual generated protocol/transport/credentials. Only
				// replace remote trust with this ephemeral fixture certificate.
				tlsSettings := stream["tlsSettings"].(map[string]any)
				tlsSettings["serverName"] = "fixture.invalid"
				tlsSettings["certificates"] = []any{map[string]any{"certificate": certificate.certificate, "usage": "verify"}}
			}
			if network == "ws" {
				inbound["streamSettings"].(map[string]any)["wsSettings"] = map[string]any{"path": stream["wsSettings"].(map[string]any)["path"]}
			}
			targets := []xnet.Destination{fixtureEcho(t, false), fixtureEcho(t, true)}
			finalRules := []any{}
			for _, target := range targets {
				finalRules = append(finalRules, map[string]any{"action": "allow", "ip": []string{"127.0.0.1/32"}, "port": strconv.Itoa(int(target.Port)), "network": strings.ToLower(target.Network.String())})
			}
			finalRules = append(finalRules, map[string]any{"action": "block", "blockDelay": "0"})
			server["outbounds"].([]any)[0].(map[string]any)["settings"] = map[string]any{"finalRules": finalRules}
			fixtureCore(t, server)
			// Deliberately never start the exported TUN or modify host routes.
			instance := fixtureCore(t, map[string]any{"outbounds": []any{proxy}})
			for _, target := range targets {
				if err := fixtureRoundTrip(t, instance, target); err != nil {
					t.Fatal(err)
				}
			}
		})
	}
}

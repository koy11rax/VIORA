package main

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"strings"
	"testing"
)

func protocolFixture(protocol string) map[string]any {
	f := fixture()
	proxy := f["outbounds"].([]any)[0].(map[string]any)
	proxy["protocol"] = protocol
	stream := proxy["streamSettings"].(map[string]any)
	delete(stream, "wsSettings")
	stream["network"] = "raw"
	switch protocol {
	case "vmess":
		proxy["settings"].(map[string]any)["vnext"].([]any)[0].(map[string]any)["users"] = []any{map[string]any{"id": "00000000-0000-4000-8000-000000000001", "security": "auto", "alterId": 0}}
	case "trojan", "shadowsocks":
		server := map[string]any{"address": "example.invalid", "port": 443, "password": "fixture-password"}
		if protocol == "shadowsocks" {
			server["method"] = "aes-128-gcm"
			stream["security"] = "none"
			delete(stream, "tlsSettings")
		}
		proxy["settings"] = map[string]any{"servers": []any{server}}
	case "hysteria":
		proxy["settings"] = map[string]any{"version": 2, "address": "example.invalid", "port": 443}
		stream["network"] = "hysteria"
		stream["tlsSettings"].(map[string]any)["alpn"] = []string{"h3"}
		stream["hysteriaSettings"] = map[string]any{"version": 2, "auth": "fixture-password"}
		stream["finalmask"] = map[string]any{"udp": []any{map[string]any{"type": "salamander", "settings": map[string]any{"password": "fixture-obfuscation"}}}}
	}
	return f
}

func cleanProtocolFixture(t *testing.T, protocol string) map[string]any {
	t.Helper()
	data, err := json.Marshal(protocolFixture(protocol))
	if err != nil {
		t.Fatal(err)
	}
	clean, err := sanitizeConfig(data)
	if err != nil {
		t.Fatal(err)
	}
	return clean
}

func TestProtocolEndpointBootstrapAndBridge(t *testing.T) {
	for _, protocol := range []string{"vless", "vmess", "trojan", "shadowsocks", "hysteria"} {
		t.Run(protocol, func(t *testing.T) {
			clean := cleanProtocolFixture(t, protocol)
			proxy := proxyMap(clean)
			before, _ := json.Marshal(proxy["streamSettings"])
			if err := resolveEndpointWith(context.Background(), clean, false, endpointSuccess(t, `{"Status":0,"Answer":[{"type":1,"data":"203.0.113.10"}]}`)); err != nil {
				t.Fatal(err)
			}
			server, err := proxyEndpoint(proxy)
			if err != nil || server["address"] != "203.0.113.10" {
				t.Fatal("endpoint was not normalized")
			}
			stream := proxy["streamSettings"].(map[string]any)
			// Preserve the authentication/SNI/transport object during bootstrap;
			// only WS Host defaults may be added.
			if protocol != "vless" {
				after, _ := json.Marshal(stream)
				if !bytes.Equal(before, after) {
					t.Fatal("transport changed during endpoint resolution")
				}
			}
			stream["sockopt"] = map[string]any{"interface": "Ethernet", "mark": protectionMark}
			backend, frontend, err := buildDesktopBridge(clean, 31081, "fixture-user", strings.Repeat("p", 32))
			if err != nil {
				t.Fatal(err)
			}
			if backend["outbounds"].([]any)[0].(map[string]any)["protocol"] != protocol {
				t.Fatal("protocol changed")
			}
			if frontend["route"].(map[string]any)["final"] != "proxy" {
				t.Fatal("routing was lost")
			}
			if core := os.Getenv("VIORA_TEST_CORE"); core != "" {
				encoded, _ := json.Marshal(backend)
				cmd := exec.Command(core, "run", "-test", "-format", "json", "-config", "stdin:")
				cmd.Stdin = bytes.NewReader(encoded)
				if output, err := cmd.CombinedOutput(); err != nil {
					t.Fatalf("pinned core rejected %s: %s", protocol, output)
				}
			}
		})
	}
}

func TestProtocolSanitizerRejectsUnsafeAndUnsupportedOptions(t *testing.T) {
	cases := []struct {
		name, protocol string
		edit           func(map[string]any)
	}{
		{"unverified TLS", "hysteria", func(p map[string]any) {
			p["streamSettings"].(map[string]any)["tlsSettings"].(map[string]any)["allowInsecure"] = true
		}},
		{"hysteria version", "hysteria", func(p map[string]any) { p["settings"].(map[string]any)["version"] = 1 }},
		{"hysteria auth", "hysteria", func(p map[string]any) {
			p["streamSettings"].(map[string]any)["hysteriaSettings"].(map[string]any)["auth"] = ""
		}},
		{"arbitrary UDP mask", "hysteria", func(p map[string]any) {
			p["streamSettings"].(map[string]any)["finalmask"].(map[string]any)["udp"].([]any)[0].(map[string]any)["type"] = "xdns"
		}},
		{"arbitrary QUIC tuning", "hysteria", func(p map[string]any) {
			p["streamSettings"].(map[string]any)["finalmask"].(map[string]any)["quicParams"] = map[string]any{"debug": true}
		}},
		{"VMess legacy alter id", "vmess", func(p map[string]any) {
			p["settings"].(map[string]any)["vnext"].([]any)[0].(map[string]any)["users"].([]any)[0].(map[string]any)["alterId"] = 1
		}},
		{"VMess plaintext", "vmess", func(p map[string]any) {
			p["settings"].(map[string]any)["vnext"].([]any)[0].(map[string]any)["users"].([]any)[0].(map[string]any)["security"] = "none"
		}},
		{"Shadowsocks legacy cipher", "shadowsocks", func(p map[string]any) {
			p["settings"].(map[string]any)["servers"].([]any)[0].(map[string]any)["method"] = "aes-128-cfb"
		}},
		{"Trojan cleartext", "trojan", func(p map[string]any) { p["streamSettings"].(map[string]any)["security"] = "none" }},
		{"Host header injection", "vless", func(p map[string]any) {
			p["streamSettings"].(map[string]any)["network"] = "ws"
			p["streamSettings"].(map[string]any)["wsSettings"] = map[string]any{"path": "/", "headers": map[string]any{"Host": "fixture.invalid\r\nSecret: value"}}
		}},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			f := protocolFixture(test.protocol)
			test.edit(f["outbounds"].([]any)[0].(map[string]any))
			encoded, _ := json.Marshal(f)
			if _, err := sanitizeConfig(encoded); err == nil {
				t.Fatal("accepted unsafe protocol config")
			}
		})
	}
}

func TestProtocolSanitizerNeverCopiesNativeOptions(t *testing.T) {
	for _, protocol := range []string{"vmess", "trojan", "shadowsocks", "hysteria"} {
		t.Run(protocol, func(t *testing.T) {
			f := protocolFixture(protocol)
			proxy := f["outbounds"].([]any)[0].(map[string]any)
			proxy["proxySettings"] = map[string]any{"tag": "arbitrary"}
			stream := proxy["streamSettings"].(map[string]any)
			stream["sockopt"] = map[string]any{"interface": "untrusted-marker", "mark": 1234}
			if tls, ok := stream["tlsSettings"].(map[string]any); ok {
				tls["certificates"] = []any{map[string]any{"certificateFile": "untrusted-marker"}}
			}
			encoded, _ := json.Marshal(f)
			clean, err := sanitizeConfig(encoded)
			if err != nil {
				t.Fatal(err)
			}
			out, _ := json.Marshal(clean)
			if bytes.Contains(out, []byte("untrusted-marker")) || bytes.Contains(out, []byte("proxySettings")) {
				t.Fatal("native option escaped sanitizer")
			}
		})
	}
}

func TestShadowsocksApplicationDTOWithoutStreamSettings(t *testing.T) {
	input := protocolFixture("shadowsocks")
	delete(input["outbounds"].([]any)[0].(map[string]any), "streamSettings")
	data, _ := json.Marshal(input)
	clean, err := sanitizeConfig(data)
	if err != nil {
		t.Fatal("application-generated Shadowsocks DTO rejected", err)
	}
	stream := proxyMap(clean)["streamSettings"].(map[string]any)
	if stream["network"] != "raw" || stream["security"] != "none" {
		t.Fatal("unexpected native transport defaults")
	}
	for _, protocol := range []string{"vless", "vmess", "trojan", "hysteria"} {
		input := protocolFixture(protocol)
		delete(input["outbounds"].([]any)[0].(map[string]any), "streamSettings")
		data, _ := json.Marshal(input)
		if _, err := sanitizeConfig(data); err == nil {
			t.Fatal("missing required transport accepted", protocol)
		}
	}
}

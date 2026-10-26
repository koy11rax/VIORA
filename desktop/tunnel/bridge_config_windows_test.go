package main

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

const bridgeTestPassword = "isolated-fixture-password-32-bytes"

func bridgeConfigFixture(t *testing.T, mode string, strict bool) map[string]any {
	t.Helper()
	config := routingFixtureForMode(t, mode)
	proxy := proxyMap(config)
	proxy["settings"].(map[string]any)["vnext"].([]any)[0].(map[string]any)["address"] = "192.0.2.10"
	proxy["streamSettings"].(map[string]any)["sockopt"] = map[string]any{"interface": "Fixture uplink", "domainStrategy": "UseIPv4", "mark": 1234}
	config["dns"] = map[string]any{"servers": []string{"https://1.1.1.1/dns-query"}}
	if strict {
		restrictDirect(config)
	}
	return config
}

func bridgeJSON(t *testing.T, value any) []byte {
	t.Helper()
	encoded, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return encoded
}

func TestWindowsBridgeSeparatesNativeTUNFromExactVLESS(t *testing.T) {
	for _, transport := range []string{"ws", "xhttp", "raw"} {
		t.Run(transport, func(t *testing.T) {
			config := bridgeConfigFixture(t, "all", false)
			proxy := proxyMap(config)
			stream := proxy["streamSettings"].(map[string]any)
			stream["network"] = transport
			if transport == "xhttp" {
				delete(stream, "wsSettings")
				stream["xhttpSettings"] = map[string]any{"path": "/fixture", "mode": "auto", "host": "front.example"}
			}
			if transport == "raw" {
				delete(stream, "wsSettings")
				delete(stream, "tlsSettings")
				stream["security"] = "reality"
				stream["realitySettings"] = map[string]any{"serverName": "cover.example", "fingerprint": "chrome", "password": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "shortId": "0123456789abcdef", "spiderX": "/"}
				proxy["settings"].(map[string]any)["vnext"].([]any)[0].(map[string]any)["users"].([]any)[0].(map[string]any)["flow"] = "xtls-rprx-vision"
			}
			before := bridgeJSON(t, config)
			expectedProxy := bridgeJSON(t, proxy)
			backend, front, err := buildWindowsBridge(config, 31081, "fixture-user", bridgeTestPassword)
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(before, bridgeJSON(t, config)) {
				t.Fatal("builder mutated input")
			}
			outs := backend["outbounds"].([]any)
			if len(outs) != 1 || !bytes.Equal(expectedProxy, bridgeJSON(t, outs[0])) {
				t.Fatal("VLESS metadata/underlay changed")
			}
			for _, key := range []string{"dns", "routing", "api", "metrics", "desktop"} {
				if _, exists := backend[key]; exists {
					t.Fatalf("backend retained unintended %s", key)
				}
			}
			in := backend["inbounds"].([]any)[0].(map[string]any)
			if in["protocol"] != "socks" || in["listen"] != "127.0.0.1" || in["port"] != uint16(31081) || in["sniffing"].(map[string]any)["enabled"] != false {
				t.Fatal("backend owns something other than private SOCKS")
			}
			settings := in["settings"].(map[string]any)
			account := settings["accounts"].([]any)[0].(map[string]any)
			if settings["auth"] != "password" || settings["udp"] != true || settings["userLevel"] != 8 || account["user"] != "fixture-user" || account["pass"] != bridgeTestPassword {
				t.Fatal("SOCKS authentication/UDP/user level missing")
			}
			tun := front["inbounds"].([]any)[0].(map[string]any)
			if tun["type"] != "tun" || tun["stack"] != "system" || tun["auto_route"] != true || tun["strict_route"] != true || tun["dns_mode"] != "hijack" {
				t.Fatal("Windows TUN mode is not explicit")
			}
			if bytes.Contains(bridgeJSON(t, front), []byte(`"vless"`)) || bytes.Contains(bridgeJSON(t, front), []byte(`"uuid"`)) {
				t.Fatal("VLESS transport leaked into frontend")
			}
		})
	}
}

func TestWindowsBridgeDNSAlwaysUsesAuthenticatedSOCKS(t *testing.T) {
	for _, dns := range []string{"https://1.1.1.1/dns-query", "9.9.9.9"} {
		t.Run(dns, func(t *testing.T) {
			config := bridgeConfigFixture(t, "all", false)
			config["dns"] = map[string]any{"servers": []string{dns}}
			_, front, err := buildWindowsBridge(config, 31081, "fixture-user", bridgeTestPassword)
			if err != nil {
				t.Fatal(err)
			}
			settings := front["dns"].(map[string]any)
			server := settings["servers"].([]any)[0].(map[string]any)
			if server["detour"] != "proxy" || settings["final"] != "dns-remote" || settings["strategy"] != "ipv4_only" {
				t.Fatal("DNS could bypass SOCKS")
			}
			if settings["reverse_mapping"] != false {
				t.Fatal("shared CDN addresses must not acquire guessed direct-domain policy")
			}
			if dns[0] == 'h' {
				if server["type"] != "https" || server["server"] != "1.1.1.1" || server["tls"].(map[string]any)["enabled"] != true {
					t.Fatal("fixed HTTPS DNS lost TLS")
				}
			} else if server["type"] != "udp" || server["server"] != dns {
				t.Fatal("custom IPv4 DNS changed")
			}
			encoded := bridgeJSON(t, front)
			for _, forbidden := range []string{`"insecure":true`, `"fakeip"`, `"type":"local"`, `"action":"resolve"`} {
				if bytes.Contains(encoded, []byte(forbidden)) {
					t.Fatalf("unsafe DNS option %s", forbidden)
				}
			}
		})
	}
}

func TestWindowsBridgeRuleTranslationKeepsANDAndWindowsPaths(t *testing.T) {
	row := map[string]any{"type": "field", "domain": []string{"domain:example.com"}, "ip": []string{"203.0.113.7"}, "port": "443,1000-1010", "process": []string{"C:/Apps/Fixture.exe"}, "outboundTag": "proxy"}
	cloned, err := cloneBridgeMap(row)
	if err != nil {
		t.Fatal(err)
	}
	rule, skip, err := translateWindowsBridgeRule(cloned, map[string]string{"direct": "freedom"})
	if err != nil || skip {
		t.Fatal(err)
	}
	if rule["type"] != "logical" || rule["mode"] != "and" || len(rule["rules"].([]any)) != 4 {
		t.Fatal("Xray AND became sing-box OR")
	}
	var pattern string
	for _, item := range rule["rules"].([]any) {
		condition := item.(map[string]any)
		if paths, ok := condition["process_path_regex"]; ok {
			pattern = paths.([]string)[0]
		}
	}
	matcher, err := regexp.Compile(pattern)
	if err != nil || !matcher.MatchString(`c:\apps\fixture.EXE`) || matcher.MatchString(`C:\Apps\Other.exe`) {
		t.Fatal("Windows process path semantics changed")
	}
	if !bytes.Contains(bridgeJSON(t, rule), []byte("203.0.113.7/32")) || !bytes.Contains(bridgeJSON(t, rule), []byte("1000:1010")) {
		t.Fatal("IP/port translation changed")
	}
}

func TestWindowsBridgeAllExceptOnlyAndStrictPolicies(t *testing.T) {
	for _, mode := range []string{"all", "except", "only"} {
		for _, strict := range []bool{false, true} {
			t.Run(mode+map[bool]string{false: "/session", true: "/strict"}[strict], func(t *testing.T) {
				config := bridgeConfigFixture(t, mode, strict)
				_, front, err := buildWindowsBridge(config, 31081, "fixture-user", bridgeTestPassword)
				if err != nil {
					t.Fatal(err)
				}
				rules := front["route"].(map[string]any)["rules"].([]any)
				first := rules[0].(map[string]any)
				if first["action"] != "reject" || !bytes.Contains(bridgeJSON(t, first), []byte("::/0")) {
					t.Fatal("IPv6 protection displaced")
				}
				if rules[1].(map[string]any)["action"] != "hijack-dns" || !bytes.Contains(bridgeJSON(t, rules[2]), []byte("172.29.255.2/32")) {
					t.Fatal("DNS protection displaced")
				}
				terminal := rules[len(rules)-1].(map[string]any)
				if mode == "only" {
					if strict {
						if terminal["action"] != "reject" {
							t.Fatal("strict only mode leaked direct")
						}
					} else if terminal["outbound"] != "direct" {
						t.Fatal("only mode terminal direct lost")
					}
				} else if terminal["outbound"] != "proxy" {
					t.Fatal("default proxy fallback lost")
				}
				serialized := string(bridgeJSON(t, front))
				if strict && strings.Contains(serialized, `"outbound":"direct"`) {
					t.Fatal("strict direct rule survived")
				}
				if mode != "all" && !strings.Contains(serialized, "process_path_regex") {
					t.Fatal("per-app rules lost")
				}
				for _, value := range []string{"vk.com", "private.example", "203.0.113.0/24"} {
					if !strings.Contains(serialized, value) {
						t.Fatalf("custom rule missing: %s", value)
					}
				}
			})
		}
	}
}

func TestWindowsBridgeRejectsInvalidInputAtomically(t *testing.T) {
	for _, test := range []struct {
		name           string
		port           uint16
		user, password string
		change         func(map[string]any)
	}{
		{"zeroPort", 0, "fixture", bridgeTestPassword, func(map[string]any) {}},
		{"emptyUser", 1, "", bridgeTestPassword, func(map[string]any) {}},
		{"weakPassword", 1, "fixture", "short", func(map[string]any) {}},
		{"credentialNewline", 1, "fixture\n", bridgeTestPassword, func(map[string]any) {}},
		{"unresolvedEndpoint", 1, "fixture", bridgeTestPassword, func(c map[string]any) {
			proxyMap(c)["settings"].(map[string]any)["vnext"].([]any)[0].(map[string]any)["address"] = "vpn.example"
		}},
		{"missingUnderlay", 1, "fixture", bridgeTestPassword, func(c map[string]any) { delete(proxyMap(c)["streamSettings"].(map[string]any), "sockopt") }},
		{"ownUnderlay", 1, "fixture", bridgeTestPassword, func(c map[string]any) {
			proxyMap(c)["streamSettings"].(map[string]any)["sockopt"].(map[string]any)["interface"] = "viora0"
		}},
		{"missingSafetyRule", 1, "fixture", bridgeTestPassword, func(c map[string]any) {
			c["routing"].(map[string]any)["rules"].([]any)[0].(map[string]any)["outboundTag"] = "direct"
		}},
		{"arbitraryField", 1, "fixture", bridgeTestPassword, func(c map[string]any) {
			r := c["routing"].(map[string]any)["rules"].([]any)
			r[len(r)-1].(map[string]any)["execute"] = "untrusted"
		}},
		{"invalidPorts", 1, "fixture", bridgeTestPassword, func(c map[string]any) {
			r := c["routing"].(map[string]any)["rules"].([]any)
			r[len(r)-1].(map[string]any)["port"] = "80,invalid"
		}},
	} {
		t.Run(test.name, func(t *testing.T) {
			config := bridgeConfigFixture(t, "all", false)
			test.change(config)
			before := bridgeJSON(t, config)
			backend, front, err := buildWindowsBridge(config, test.port, test.user, test.password)
			if err == nil || backend != nil || front != nil {
				t.Fatal("invalid bridge config accepted")
			}
			if !bytes.Equal(before, bridgeJSON(t, config)) {
				t.Fatal("failed builder changed input")
			}
		})
	}
}

func TestWindowsBridgeNativeSchemaCheck(t *testing.T) {
	box := os.Getenv("VIORA_TEST_SING_BOX")
	if box == "" {
		t.Skip("optional official sing-box check binary not supplied; pure tests do not launch processes")
	}
	for _, mode := range []string{"all", "except", "only"} {
		for _, strict := range []bool{false, true} {
			_, front, err := buildWindowsBridge(bridgeConfigFixture(t, mode, strict), 31081, "fixture-user", bridgeTestPassword)
			if err != nil {
				t.Fatal(err)
			}
			file := filepath.Join(t.TempDir(), "fixture.json")
			if err = os.WriteFile(file, bridgeJSON(t, front), 0600); err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			output, checkErr := exec.CommandContext(ctx, box, "check", "-c", file).CombinedOutput()
			cancel()
			if err := checkErr; err != nil {
				t.Fatalf("official schema check failed: %v %s", err, output)
			}
		}
	}
}

func TestWindowsBridgeXrayBackendSchemaCheck(t *testing.T) {
	core := os.Getenv("VIORA_TEST_BRIDGE_XRAY")
	if core == "" {
		t.Skip("optional pinned Xray check binary not supplied; pure tests do not launch processes")
	}
	for _, network := range []string{"ws", "xhttp", "raw"} {
		t.Run(network, func(t *testing.T) {
			config := bridgeConfigFixture(t, "all", false)
			stream := proxyMap(config)["streamSettings"].(map[string]any)
			stream["network"] = network
			if network == "xhttp" {
				delete(stream, "wsSettings")
				stream["xhttpSettings"] = map[string]any{"path": "/fixture", "mode": "auto", "host": "front.example"}
			}
			if network == "raw" {
				delete(stream, "wsSettings")
				delete(stream, "tlsSettings")
				stream["security"] = "reality"
				stream["realitySettings"] = map[string]any{"serverName": "cover.example", "fingerprint": "chrome", "password": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "shortId": "", "spiderX": "/"}
			}
			backend, _, err := buildWindowsBridge(config, 31081, "fixture-user", bridgeTestPassword)
			if err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, core, "run", "-test", "-format", "json", "-config", "stdin:")
			cmd.Stdin = bytes.NewReader(bridgeJSON(t, backend))
			if output, err := cmd.CombinedOutput(); err != nil {
				t.Fatalf("pinned Xray rejected bridge backend: %v %s", err, output)
			}
		})
	}
}

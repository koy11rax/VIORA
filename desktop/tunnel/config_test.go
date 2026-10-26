package main

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"reflect"
	"runtime"
	"testing"
)

func fixture() map[string]any {
	return map[string]any{
		"log":      map[string]any{"loglevel": "none"},
		"dns":      map[string]any{"servers": []string{"1.1.1.1"}},
		"inbounds": []any{map[string]any{"protocol": "tun", "settings": map[string]any{"MTU": 1500}}},
		"outbounds": []any{
			map[string]any{"tag": "proxy", "protocol": "vless", "settings": map[string]any{"vnext": []any{map[string]any{"address": "example.invalid", "port": 443, "users": []any{map[string]any{"id": "00000000-0000-4000-8000-000000000001", "encryption": "none", "level": 8}}}}}, "streamSettings": map[string]any{"network": "ws", "security": "tls", "tlsSettings": map[string]any{"serverName": "example.invalid", "fingerprint": "chrome"}, "wsSettings": map[string]any{"path": "/vpn"}}},
			map[string]any{"tag": "direct", "protocol": "freedom"}, map[string]any{"tag": "block", "protocol": "blackhole"},
		},
		"routing": map[string]any{"rules": []any{
			map[string]any{"type": "field", "ip": []string{"::/0"}, "outboundTag": "block"},
			map[string]any{"type": "field", "port": "53,853", "outboundTag": "proxy"},
			map[string]any{"type": "field", "domain": []string{"domain:vk.com"}, "outboundTag": "direct"},
		}},
	}
}
func TestNoPrivilegedConfigInjection(t *testing.T) {
	for _, key := range []string{"api", "metrics", "reverse", "fakedns", "transport"} {
		f := fixture()
		f[key] = map[string]any{}
		data, _ := json.Marshal(f)
		if _, err := sanitizeConfig(data); err == nil {
			t.Fatal("accepted " + key)
		}
	}
	f := fixture()
	f["dns"] = map[string]any{"servers": []string{"https://evil.invalid/file"}}
	data, _ := json.Marshal(f)
	if _, err := sanitizeConfig(data); err == nil {
		t.Fatal("accepted DNS URL")
	}
	f = fixture()
	f["inbounds"] = []any{map[string]any{"protocol": "socks", "settings": map[string]any{"MTU": 1500}}}
	data, _ = json.Marshal(f)
	if _, err := sanitizeConfig(data); err == nil {
		t.Fatal("accepted listener")
	}
	f = fixture()
	f["log"] = map[string]any{"access": "/etc/privileged-file"}
	data, _ = json.Marshal(f)
	clean, err := sanitizeConfig(data)
	if err != nil {
		t.Fatal(err)
	}
	marshaled, _ := json.Marshal(clean)
	if bytes.Contains(marshaled, []byte("privileged-file")) {
		t.Fatal("copied log path")
	}
}
func TestGeneratedConfigsWithPinnedCore(t *testing.T) {
	for _, transport := range []string{"ws", "xhttp", "raw"} {
		t.Run(transport, func(t *testing.T) {
			f := fixture()
			stream := f["outbounds"].([]any)[0].(map[string]any)["streamSettings"].(map[string]any)
			stream["network"] = transport
			if transport == "xhttp" {
				delete(stream, "wsSettings")
				stream["xhttpSettings"] = map[string]any{"path": "/vpn", "mode": "auto"}
			}
			if transport == "raw" {
				delete(stream, "wsSettings")
				delete(stream, "tlsSettings")
				stream["security"] = "reality"
				stream["realitySettings"] = map[string]any{"serverName": "example.invalid", "fingerprint": "chrome", "password": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "shortId": ""}
			}
			data, _ := json.Marshal(f)
			clean, err := sanitizeConfig(data)
			if err != nil {
				t.Fatal(err)
			}
			settings := clean["inbounds"].([]any)[0].(map[string]any)["settings"].(map[string]any)
			if settings["autoOutboundsInterface"] != "auto" {
				t.Fatal("missing loop prevention")
			}
			if core := os.Getenv("VIORA_TEST_CORE"); core != "" {
				encoded, _ := json.Marshal(clean)
				cmd := exec.Command(core, "run", "-test", "-format", "json", "-config", "stdin:")
				cmd.Stdin = bytes.NewReader(encoded)
				if output, err := cmd.CombinedOutput(); err != nil {
					t.Fatalf("core rejected %s: %s", transport, output)
				}
			}
		})
	}
}
func TestHelperRejectsInvalidInputWithoutStarting(t *testing.T) {
	for _, input := range []string{"{}\n", "not json\n", string(bytes.Repeat([]byte("x"), 128*1024)) + "\n"} {
		var output bytes.Buffer
		run(ioCloser{bytes.NewReader([]byte(input))}, &output)
		if !bytes.Contains(output.Bytes(), []byte("invalid_config")) || bytes.Contains(output.Bytes(), []byte("CONNECTED")) {
			t.Fatal("invalid input passed")
		}
	}
}

type ioCloser struct{ *bytes.Reader }

func (ioCloser) Close() error { return nil }

func routingFixtureForMode(t *testing.T, mode string) map[string]any {
	t.Helper()
	f := fixture()
	application := "/usr/bin/fixture"
	if runtime.GOOS == "windows" {
		application = `C:\Apps\fixture.exe`
	}
	f["desktop"] = map[string]any{"appMode": mode, "applications": []string{runtime.GOOS + ":" + application}, "reconnect": true, "retries": 3}
	f["routing"].(map[string]any)["rules"] = append(f["routing"].(map[string]any)["rules"].([]any),
		map[string]any{"type": "field", "ip": []string{"203.0.113.0/24"}, "outboundTag": "block"},
		map[string]any{"type": "field", "domain": []string{"domain:private.example"}, "outboundTag": "direct"})
	data, err := json.Marshal(f)
	if err != nil {
		t.Fatal(err)
	}
	clean, err := sanitizeConfig(data)
	if err != nil {
		t.Fatal(err)
	}
	return clean
}

func TestRoutingTerminalRuleAvoidsSecondaryDNSForTUN(t *testing.T) {
	for _, mode := range []string{"all", "except", "only"} {
		t.Run(mode, func(t *testing.T) {
			clean := routingFixtureForMode(t, mode)
			rules := clean["routing"].(map[string]any)["rules"].([]any)
			wantTag := "proxy"
			if mode == "only" {
				wantTag = "direct"
			}
			want := map[string]any{"type": "field", "network": "tcp,udp", "outboundTag": wantTag}
			if !reflect.DeepEqual(rules[len(rules)-1], want) {
				t.Fatalf("missing final first-pass route: got%v want%v", rules[len(rules)-1], want)
			}
			if clean["routing"].(map[string]any)["domainStrategy"] != "IPIfNonMatch" {
				t.Fatal("routing strategy changed instead of making TUN fallback explicit")
			}
		})
	}
}

func TestRoutingTerminalRulePreservesPolicyPrecedence(t *testing.T) {
	for _, mode := range []string{"all", "except", "only"} {
		t.Run(mode, func(t *testing.T) {
			clean := routingFixtureForMode(t, mode)
			rules := clean["routing"].(map[string]any)["rules"].([]any)
			if len(rules) < 8 {
				t.Fatal("existing routing policy lost")
			}
			prefix := []any{
				map[string]any{"type": "field", "ip": []string{"::/0"}, "outboundTag": "block"},
				map[string]any{"type": "field", "inboundTag": []string{"dns-internal"}, "outboundTag": "proxy"},
				map[string]any{"type": "field", "port": "53", "outboundTag": "dns-out"},
				map[string]any{"type": "field", "ip": []string{"172.29.255.2"}, "port": "853", "outboundTag": "block"},
				map[string]any{"type": "field", "port": "853", "outboundTag": "proxy"},
			}
			if !reflect.DeepEqual(rules[:5], prefix) {
				t.Fatal("DNS/IPv6 safety prefix changed")
			}
			for _, item := range rules[:len(rules)-1] {
				if row := item.(map[string]any); row["network"] == "tcp,udp" {
					t.Fatal("terminal route precedes user rules")
				}
			}
			find := func(field, value, tag string) int {
				for index, item := range rules {
					row := item.(map[string]any)
					if row["outboundTag"] != tag {
						continue
					}
					encoded, _ := json.Marshal(row[field])
					if bytes.Equal(encoded, []byte(`["`+value+`"]`)) {
						return index
					}
				}
				return -1
			}
			for _, expect := range []struct{ field, value, tag string }{{"domain", "domain:vk.com", "direct"}, {"ip", "203.0.113.0/24", "block"}, {"domain", "domain:private.example", "direct"}} {
				if index := find(expect.field, expect.value, expect.tag); index < 5 || index >= len(rules)-1 {
					t.Fatalf("user rule no longer precedes fallback: %+v", expect)
				}
			}
			if mode == "except" && rules[5].(map[string]any)["process"] == nil {
				t.Fatal("excluded-app rule was displaced")
			}
			if mode == "only" {
				selected := rules[len(rules)-2].(map[string]any)
				if selected["process"] == nil || selected["outboundTag"] != "proxy" {
					t.Fatal("only-mode selected apps no longer precede terminal direct")
				}
			}
			before, _ := json.Marshal(rules)
			restrictDirect(clean)
			after, _ := json.Marshal(clean["routing"].(map[string]any)["rules"])
			if !bytes.Equal(before, after) {
				t.Fatal("strict mode changed rule precedence")
			}
			for _, outbound := range clean["outbounds"].([]any) {
				if outbound.(map[string]any)["protocol"] == "freedom" {
					t.Fatal("terminal rule introduced strict direct bypass")
				}
			}
		})
	}
}

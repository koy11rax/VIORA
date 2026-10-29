package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const linuxBridgePassword = "isolated-linux-fixture-password"

func linuxBridgeJSON(t *testing.T, value any) []byte {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func linuxBridgeFixture(t *testing.T, mode string, strict bool) map[string]any {
	t.Helper()
	config := routingFixtureForMode(t, mode)
	proxy := proxyMap(config)
	proxy["settings"].(map[string]any)["vnext"].([]any)[0].(map[string]any)["address"] = "192.0.2.10"
	proxy["streamSettings"].(map[string]any)["sockopt"] = map[string]any{"interface": "eth0", "mark": protectionMark}
	if strict {
		restrictDirect(config)
		proxyMap(config)["streamSettings"].(map[string]any)["sockopt"].(map[string]any)["interface"] = "eth0"
	}
	return config
}

func TestLinuxBridgeSeparatesTransportTUNAndReservedKernelPolicy(t *testing.T) {
	for _, mode := range []string{"all", "only", "except"} {
		for _, strict := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/%t", mode, strict), func(t *testing.T) {
				config := linuxBridgeFixture(t, mode, strict)
				before := linuxBridgeJSON(t, config)
				backend, frontend, err := buildPlatformBridge(config, 31081, "fixture", linuxBridgePassword)
				if err != nil {
					t.Fatal(err)
				}
				if !bytes.Equal(before, linuxBridgeJSON(t, config)) {
					t.Fatal("builder mutated input")
				}
				tun := frontend["inbounds"].([]any)[0].(map[string]any)
				if tun["stack"] != "system" || tun["iproute2_table_index"] != linuxBridgeTable || tun["iproute2_rule_index"] != linuxBridgeRuleStart || tun["dns_mode"] != "hijack" {
					t.Fatal("wrong Linux TUN policy")
				}
				if tun["route_exclude_address"].([]string)[0] != "192.0.2.10/32" {
					t.Fatal("transport can recurse into TUN")
				}
				if !bytes.Equal(linuxBridgeJSON(t, backend["outbounds"].([]any)[0]), linuxBridgeJSON(t, proxyMap(config))) {
					t.Fatal("VLESS changed")
				}
				out := frontend["outbounds"].([]any)
				if strict && len(out) != 1 {
					t.Fatal("direct bypass retained under lockdown")
				}
				for _, item := range out {
					row := item.(map[string]any)
					if row["type"] == "direct" && (row["bind_interface"] != "eth0" || row["routing_mark"] != protectionMark) {
						t.Fatal("unbound direct path")
					}
				}
				text := string(linuxBridgeJSON(t, frontend))
				if strings.Contains(text, `"vless"`) || strings.Contains(text, `"uuid"`) || strings.Contains(text, "(?i)") {
					t.Fatal("Windows/transport metadata entered Linux frontend")
				}
				if mode != "all" && !strings.Contains(text, `"process_path":["/usr/bin/fixture"]`) {
					t.Fatal("exact Linux process selection missing")
				}
				rules := frontend["route"].(map[string]any)["rules"].([]any)
				guardCount := 0
				for index, item := range rules {
					row := item.(map[string]any)
					if _, exists := row["process_path_regex"]; exists {
						guardCount++
						if index == 0 || rules[index-1].(map[string]any)["action"] != "sniff" || row["action"] != "reject" || row["invert"] != true || row["process_path_regex"].([]string)[0] != "^.+$" {
							t.Fatal("process identity guard is misplaced or permissive")
						}
					}
					if _, exists := row["process_path"]; exists && guardCount != 1 {
						t.Fatal("process policy precedes fail-closed guard")
					}
				}
				if (mode == "all" && guardCount != 0) || (mode != "all" && guardCount != 1) {
					t.Fatal("wrong process guard scope", guardCount)
				}
				if !strings.Contains(text, `"detour":"proxy"`) || !strings.Contains(text, `"reverse_mapping":false`) {
					t.Fatal("DNS routing protections missing")
				}
			})
		}
	}
}

func TestLinuxBridgeRejectsMissingMarkAndInvalidInterface(t *testing.T) {
	for _, name := range []string{"missing-mark", "wrong-mark", "interface-space", "interface-long"} {
		t.Run(name, func(t *testing.T) {
			config := linuxBridgeFixture(t, "all", false)
			options := proxyMap(config)["streamSettings"].(map[string]any)["sockopt"].(map[string]any)
			switch name {
			case "missing-mark":
				delete(options, "mark")
			case "wrong-mark":
				options["mark"] = 1
			case "interface-space":
				options["interface"] = "unsafe name"
			case "interface-long":
				options["interface"] = strings.Repeat("x", 16)
			}
			if _, _, err := buildPlatformBridge(config, 31081, "fixture", linuxBridgePassword); err == nil {
				t.Fatal("unsafe Linux policy accepted")
			}
		})
	}
}

func TestLinuxBridgeNativeSchemaChecksWithoutStartingVPN(t *testing.T) {
	frontend := os.Getenv("VIORA_TEST_FRONTEND")
	if frontend == "" {
		frontend = os.Getenv("VIORA_TEST_SING_BOX")
	}
	core := os.Getenv("VIORA_TEST_CORE")
	if frontend == "" || core == "" {
		t.Skip("optional Linux config-only binaries not supplied")
	}
	for _, mode := range []string{"all", "only", "except"} {
		for _, strict := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/%t", mode, strict), func(t *testing.T) {
				backend, front, err := buildPlatformBridge(linuxBridgeFixture(t, mode, strict), 31081, "fixture", linuxBridgePassword)
				if err != nil {
					t.Fatal(err)
				}
				ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
				defer cancel()
				file := filepath.Join(t.TempDir(), "synthetic-config.json")
				if err := os.WriteFile(file, linuxBridgeJSON(t, front), 0600); err != nil {
					t.Fatal(err)
				}
				if output, err := exec.CommandContext(ctx, frontend, "check", "-c", file).CombinedOutput(); err != nil {
					t.Fatalf("frontend schema: %v %s", err, output)
				}
				cmd := exec.CommandContext(ctx, core, "run", "-test", "-format", "json", "-config", "stdin:")
				cmd.Stdin = bytes.NewReader(linuxBridgeJSON(t, backend))
				if output, err := cmd.CombinedOutput(); err != nil {
					t.Fatalf("backend schema: %v %s", err, output)
				}
			})
		}
	}
}

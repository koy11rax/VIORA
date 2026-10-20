package main

import (
	"encoding/json"
	"testing"
)

func TestProtectionBlocksEveryDirectOutbound(t *testing.T) {
	f := fixture()
	raw, _ := json.Marshal(f)
	config, err := sanitizeConfig(raw)
	if err != nil {
		t.Fatal(err)
	}
	restrictDirect(config)
	for _, item := range config["outbounds"].([]any) {
		row := item.(map[string]any)
		if row["protocol"] == "freedom" {
			t.Fatal("cleartext outbound survived")
		}
		if row["tag"] == "direct" && row["protocol"] != "blackhole" {
			t.Fatal("direct exception bypassed protection")
		}
	}
	proxy := proxyMap(config)
	if proxy["protocol"] != "vless" {
		t.Fatal("VPN outbound changed")
	}
	server := proxy["settings"].(map[string]any)["vnext"].([]any)[0].(map[string]any)
	if server["address"] != "example.invalid" {
		t.Fatal("policy rewrite changed endpoint")
	}
}
func TestProtectionRejectsMalformedIntent(t *testing.T) {
	f := fixture()
	f["desktop"] = map[string]any{"appMode": "all", "retries": 3, "strict": "yes"}
	data, _ := json.Marshal(f)
	if _, err := sanitizeConfig(data); err == nil {
		t.Fatal("accepted non-boolean protection")
	}
	for _, text := range []string{`{}`, `{"desktop":{"strict":false}}`, `{"desktop":{"strict":"yes"}}`} {
		if strictRequested([]byte(text)) {
			t.Fatal("invalid request armed protection")
		}
	}
	if !strictRequested([]byte(`{"desktop":{"strict":true}}`)) {
		t.Fatal("strict intent lost")
	}
}

package main

import (
	"encoding/json"
	"testing"
)

func TestLinuxTLSUsesNativeSystemTrustWithoutImportingCAOrInsecureFlags(t *testing.T) {
	for _, clientPolicy := range []bool{false, true} {
		f := fixture()
		stream := f["outbounds"].([]any)[0].(map[string]any)["streamSettings"].(map[string]any)
		tls := stream["tlsSettings"].(map[string]any)
		tls["useSystemCA"] = clientPolicy
		tls["disableSystemRoot"] = true
		tls["allowInsecure"] = true
		tls["verifyPeerCertByName"] = "attacker.invalid"
		tls["certificates"] = []any{map[string]any{"usage": "verify", "certificateFile": "/tmp/untrusted-ca.pem"}}
		data, err := json.Marshal(f)
		if err != nil {
			t.Fatal(err)
		}
		clean, err := sanitizeConfig(data)
		if err != nil {
			t.Fatal(err)
		}
		native := proxyMap(clean)["streamSettings"].(map[string]any)["tlsSettings"].(map[string]any)
		if native["useSystemCA"] != true || native["serverName"] != "example.invalid" || native["fingerprint"] != "chrome" {
			t.Fatal("native trust/hostname policy not preserved", native)
		}
		for _, key := range []string{"disableSystemRoot", "allowInsecure", "verifyPeerCertByName", "certificates", "pinnedPeerCertSha256"} {
			if _, exists := native[key]; exists {
				t.Fatal("unsafe imported TLS option survived", key)
			}
		}
	}
}

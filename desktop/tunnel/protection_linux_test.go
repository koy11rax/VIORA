package main

import (
	"strings"
	"testing"
)

func TestProtectionRejectsMissingOrPermissiveKernelState(t *testing.T) {
	// Regression: the previous test erroneously accepted four unconditional
	// accept rules. Rule count does not prove a drop policy is effective.
	rows := []string{
		`{"table":{"family":"inet","name":"viora_lockdown"}}`,
		`{"chain":{"family":"inet","table":"viora_lockdown","name":"output","type":"filter","hook":"output","prio":-10,"policy":"drop"}}`,
		`{"chain":{"family":"inet","table":"viora_lockdown","name":"forward","type":"filter","hook":"forward","prio":-10,"policy":"drop"}}`,
	}
	for i := 0; i < 4; i++ {
		rows = append(rows, `{"rule":{"family":"inet","table":"viora_lockdown","chain":"output","expr":[{"accept":null}]}}`)
	}
	if validPolicyState([]byte(`{"nftables":[` + strings.Join(rows, ",") + `]}`)) {
		t.Fatal("unconditional accept rules falsely reported protection")
	}
}

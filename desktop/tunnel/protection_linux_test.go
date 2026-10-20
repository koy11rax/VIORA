package main

import (
	"fmt"
	"strings"
	"testing"
)

func TestProtectionRejectsMissingOrPermissiveKernelState(t *testing.T) {
	chain := func(name, policy string) string {
		return fmt.Sprintf(`{"chain":{"family":"inet","table":"viora_lockdown","name":"%s","type":"filter","hook":"%s","prio":-10,"policy":"%s"}}`, name, name, policy)
	}
	rule := `{"rule":{"family":"inet","table":"viora_lockdown","chain":"output","expr":[{"accept":null}]}}`
	document := func(output, forward string, n int) []byte {
		rows := []string{chain("output", output), chain("forward", forward)}
		for i := 0; i < n; i++ {
			rows = append(rows, rule)
		}
		return []byte(`{"nftables":[` + strings.Join(rows, ",") + `]}`)
	}
	if !validPolicyState(document("drop", "drop", 4)) {
		t.Fatal("kernel chain schema was not recognized")
	}
	for _, value := range [][]byte{document("accept", "drop", 4), document("drop", "accept", 4), document("drop", "drop", 0), document("drop", "drop", 5), []byte(`{"nftables":[]}`)} {
		if validPolicyState(value) {
			t.Fatal("incomplete/permissive state falsely reported protection")
		}
	}
}

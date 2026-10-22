package main

import (
	"encoding/json"
	"strconv"
	"strings"
)

// A table name and drop policy are insufficient evidence: an earlier accept
// verdict can still allow every packet. Recognize only our four fixed rules,
// including every predicate and verdict, before reporting protection as ON.
// Kept platform independent so the validator can be tested without nft/root.
func validPolicyState(data []byte) bool {
	var document struct {
		Nftables []map[string]json.RawMessage `json:"nftables"`
	}
	if json.Unmarshal(data, &document) != nil || len(document.Nftables) == 0 {
		return false
	}
	chains := map[string]bool{}
	rules := map[string]bool{}
	table := false
	for _, item := range document.Nftables {
		if len(item) != 1 {
			return false
		}
		for kind, raw := range item {
			switch kind {
			case "metainfo":
				// nft's version metadata has no packet filtering effect.
			case "table":
				var value struct {
					Name, Family string
					Flags        []string
				}
				if table || json.Unmarshal(raw, &value) != nil || value.Name != "viora_lockdown" || value.Family != "inet" || len(value.Flags) != 0 {
					return false
				}
				table = true
			case "chain":
				var chain struct {
					Name, Table, Family, Type, Hook, Policy string
					Prio                                    int
				}
				if json.Unmarshal(raw, &chain) != nil || chain.Table != "viora_lockdown" || chain.Family != "inet" || chain.Type != "filter" || chain.Policy != "drop" || chain.Prio != -10 {
					return false
				}
				if chain.Name != chain.Hook || (chain.Name != "output" && chain.Name != "forward") || chains[chain.Name] {
					return false
				}
				chains[chain.Name] = true
			case "rule":
				var rule struct {
					Chain, Table, Family string
					Expr                 []map[string]json.RawMessage
				}
				if json.Unmarshal(raw, &rule) != nil || rule.Chain != "output" || rule.Table != "viora_lockdown" || rule.Family != "inet" {
					return false
				}
				name := policyRule(rule.Expr)
				if name == "" || rules[name] {
					return false
				}
				rules[name] = true
			default:
				// Extra sets, chains, verdict maps and unknown statements may
				// change semantics. Fail closed rather than assume protection.
				return false
			}
		}
	}
	return table && len(chains) == 2 && len(rules) == 4
}

func policyRule(expressions []map[string]json.RawMessage) string {
	if len(expressions) < 2 || len(expressions[len(expressions)-1]) != 1 || string(expressions[len(expressions)-1]["accept"]) != "null" {
		return ""
	}
	conditions := map[string]bool{}
	for _, expression := range expressions[:len(expressions)-1] {
		if len(expression) != 1 {
			return ""
		}
		var match map[string]json.RawMessage
		if json.Unmarshal(expression["match"], &match) != nil || len(match) != 3 || string(match["op"]) != `"=="` {
			return ""
		}
		var left map[string]map[string]string
		if json.Unmarshal(match["left"], &left) != nil || len(left) != 1 {
			return ""
		}
		var key string
		if meta, ok := left["meta"]; ok && len(meta) == 1 {
			key = "meta:" + meta["key"]
		} else if payload, ok := left["payload"]; ok && len(payload) == 2 && payload["protocol"] == "udp" {
			key = "udp:" + payload["field"]
		} else {
			return ""
		}
		value := string(match["right"])
		if strings.HasPrefix(value, `"`) {
			if json.Unmarshal(match["right"], &value) != nil {
				return ""
			}
		}
		if key == "meta:mark" {
			// nft versions may print mark values as an integer or hex string.
			number, err := strconv.ParseUint(value, 0, 32)
			if err != nil || number != uint64(protectionMark) {
				return ""
			}
			value = "viora"
		}
		condition := key + "=" + value
		if conditions[condition] {
			return ""
		}
		conditions[condition] = true
	}
	if len(conditions) == 1 {
		for _, name := range []string{"meta:oifname=lo", "meta:oifname=viora0", "meta:mark=viora"} {
			if conditions[name] {
				return name
			}
		}
	}
	// A separately serialized UDP dependency is restrictive and equivalent.
	if conditions["meta:l4proto=udp"] {
		delete(conditions, "meta:l4proto=udp")
	}
	if len(conditions) == 3 && conditions["meta:nfproto=ipv4"] && conditions["udp:sport=68"] && conditions["udp:dport=67"] {
		return "dhcp"
	}
	return ""
}

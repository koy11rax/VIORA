package main

import (
	"fmt"
	"strings"
	"testing"
)

func policyFixture() string {
	return `{"nftables":[
 {"metainfo":{"json_schema_version":1}},
 {"table":{"family":"inet","name":"viora_lockdown","handle":1}},
 {"chain":{"family":"inet","table":"viora_lockdown","name":"output","type":"filter","hook":"output","prio":-10,"policy":"drop"}},
 {"chain":{"family":"inet","table":"viora_lockdown","name":"forward","type":"filter","hook":"forward","prio":-10,"policy":"drop"}},
 {"rule":{"family":"inet","table":"viora_lockdown","chain":"output","expr":[{"match":{"op":"==","left":{"meta":{"key":"oifname"}},"right":"lo"}},{"accept":null}]}},
 {"rule":{"family":"inet","table":"viora_lockdown","chain":"output","expr":[{"match":{"op":"==","left":{"meta":{"key":"oifname"}},"right":"viora0"}},{"accept":null}]}},
 {"rule":{"family":"inet","table":"viora_lockdown","chain":"output","expr":[{"match":{"op":"==","left":{"meta":{"key":"mark"}},"right":"0x56494f52"}},{"accept":null}]}},
 {"rule":{"family":"inet","table":"viora_lockdown","chain":"output","expr":[{"match":{"op":"==","left":{"meta":{"key":"nfproto"}},"right":"ipv4"}},{"match":{"op":"==","left":{"payload":{"protocol":"udp","field":"sport"}},"right":68}},{"match":{"op":"==","left":{"payload":{"protocol":"udp","field":"dport"}},"right":67}},{"accept":null}]}}
 ]}`
}

func TestProtectionRejectsPermissiveOrAlteredRuleExpressions(t *testing.T) {
	valid := policyFixture()
	for name, data := range map[string]string{
		"canonical":               valid,
		"integer mark":            strings.Replace(valid, `"0x56494f52"`, fmt.Sprint(protectionMark), 1),
		"explicit UDP dependency": strings.Replace(valid, `{"match":{"op":"==","left":{"payload":{"protocol":"udp","field":"sport"}}`, `{"match":{"op":"==","left":{"meta":{"key":"l4proto"}},"right":"udp"}},{"match":{"op":"==","left":{"payload":{"protocol":"udp","field":"sport"}}`, 1),
	} {
		t.Run(name, func(t *testing.T) {
			if !validPolicyState([]byte(data)) {
				t.Fatal("fixed policy was rejected")
			}
		})
	}
	for name, data := range map[string]string{
		"unconditional accept":     strings.Replace(valid, `{"match":{"op":"==","left":{"meta":{"key":"oifname"}},"right":"lo"}},`, "", 1),
		"wrong adapter":            strings.Replace(valid, `"viora0"`, `"eth0"`, 1),
		"inverted match":           strings.Replace(valid, `"op":"=="`, `"op":"!="`, 1),
		"wrong socket mark":        strings.Replace(valid, `"0x56494f52"`, `"0x1"`, 1),
		"duplicate interface rule": strings.Replace(valid, `"viora0"`, `"lo"`, 1),
		"wrong DHCP source":        strings.Replace(valid, `"right":68`, `"right":1`, 1),
		"wrong DHCP destination":   strings.Replace(valid, `"right":67`, `"right":53`, 1),
		"wrong DHCP protocol":      strings.ReplaceAll(valid, `"protocol":"udp"`, `"protocol":"tcp"`),
		"wrong family":             strings.Replace(valid, `"right":"ipv4"`, `"right":"ipv6"`, 1),
		"chain permits all":        strings.Replace(valid, `"policy":"drop"`, `"policy":"accept"`, 1),
		"dormant table":            strings.Replace(valid, `"name":"viora_lockdown","handle":1`, `"name":"viora_lockdown","flags":["dormant"],"handle":1`, 1),
		"missing forward chain":    strings.Replace(valid, `"name":"forward"`, `"name":"input"`, 1),
		"extra expression":         strings.Replace(valid, `{"accept":null}`, `{"counter":{"packets":0,"bytes":0}},{"accept":null}`, 1),
		"unknown top level entity": strings.Replace(valid, `{"metainfo":{"json_schema_version":1}}`, `{"set":{"name":"bypass"}}`, 1),
		"missing rules":            `{"nftables":[]}`,
		"invalid JSON":             "broken",
	} {
		t.Run(name, func(t *testing.T) {
			if validPolicyState([]byte(data)) {
				t.Fatal("unsafe/unknown policy falsely reported ON")
			}
		})
	}
}

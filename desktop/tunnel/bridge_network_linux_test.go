package main

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"strings"
	"testing"
	"time"
)

func TestLinuxPolicyLeaseRecognizesOnlyOwnedReservedRules(t *testing.T) {
	data := []byte(`[{"priority":19000,"table":22089},{"priority":19001,"goto":19010},{"priority":19010,"action":"nop"},{"priority":32766,"table":"main"},{"priority":18999,"table":22089},{"priority":19000,"table":100},{"priority":19000,"goto":20000},{"priority":19001,"action":"nop"}]`)
	rules, err := parseLinuxPolicy(data)
	if err != nil || len(rules) != 8 {
		t.Fatal(err)
	}
	for index, rule := range rules {
		if linuxPolicyOwned(rule) != (index < 3) {
			t.Fatalf("foreign policy selected: %d %s", index, data)
		}
	}
	for _, bad := range []string{"", "{}", "[true]", strings.Repeat(" ", 1024*1024+1)} {
		if _, err := parseLinuxPolicy([]byte(bad)); err == nil {
			t.Fatal("bad metadata accepted")
		}
	}
	if !linuxPolicyTable(json.RawMessage(`"22089"`)) || linuxPolicyTable(json.RawMessage(`"main"`)) {
		t.Fatal("table metadata invalid")
	}
	rules, err = parseLinuxPolicy([]byte(`[{"priority":19002,"table":254,"not":true,"dport":53,"suppress_prefixlength":0},{"priority":19002,"table":254,"not":true,"dport":443,"suppress_prefixlength":0},{"priority":19002,"table":254,"not":false,"dport":53,"suppress_prefixlength":0},{"priority":19003,"table":254,"not":true,"dport":53,"suppress_prefixlength":0}]`))
	if err != nil {
		t.Fatal(err)
	}
	for index, rule := range rules {
		if linuxPolicyOwned(rule) != (index == 0) {
			t.Fatal("wrong main-table bypass ownership", index)
		}
	}
}

func TestLinuxDNSReadinessRequiresEverySuccessfulCommandAndExactState(t *testing.T) {
	for failAt := -1; failAt < 5; failAt++ {
		calls := 0
		run := func(ctx context.Context, tool string, args ...string) ([]byte, error) {
			if tool != "resolvectl" || len(args) < 2 || args[1] != "viora0" {
				t.Fatal("escaped fixed DNS operation")
			}
			index := calls
			calls++
			if index == failAt {
				return nil, errors.New("fixture failure")
			}
			if index == 3 {
				return []byte("Link 7 (viora0): 172.29.255.2\n"), nil
			}
			if index == 4 {
				return []byte("Link 7 (viora0): ~.\n"), nil
			}
			return nil, nil
		}
		err := applyBridgeDNSOnce(context.Background(), run)
		if (err == nil) != (failAt == -1) {
			t.Fatalf("DNS error was ignored at command %d", failAt)
		}
		if failAt == -1 && calls != 5 {
			t.Fatal("DNS state was never checked")
		}
	}
	for _, state := range []string{"Link 7 (viora0): 8.8.8.8", "Link 7 (viora0): 172.29.255.2 8.8.8.8", "invalid"} {
		err := applyBridgeDNSOnce(context.Background(), func(context.Context, string, ...string) ([]byte, error) { return []byte(state), nil })
		if err == nil {
			t.Fatal("wrong system DNS accepted")
		}
	}
}

func TestLinuxDNSReadinessRetriesActualTransientFailureUntilVerified(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	calls := 0
	err := readyBridgeDNSWith(ctx, func(ctx context.Context, tool string, args ...string) ([]byte, error) {
		calls++
		if calls <= 2 {
			return nil, errors.New("link not registered yet")
		}
		if len(args) == 2 && args[0] == "dns" {
			return []byte("Link 7 (viora0): 172.29.255.2"), nil
		}
		if len(args) == 2 && args[0] == "domain" {
			return []byte("Link 7 (viora0): ~."), nil
		}
		return nil, nil
	})
	if err != nil || calls != 7 {
		t.Fatal("transient link registration failure was not recovered and verified", calls, err)
	}
}

func TestLinuxDNSReadinessHonorsSharedDeadlineAndCancellation(t *testing.T) {
	for _, cancelled := range []bool{false, true} {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
		if cancelled {
			cancel()
		}
		started := time.Now()
		err := readyBridgeDNSWith(ctx, func(_ context.Context, _ string, _ ...string) ([]byte, error) {
			return nil, errors.New("link unavailable")
		})
		cancel()
		if err == nil || time.Since(started) > time.Second {
			t.Fatal("cancel/deadline was ignored", cancelled, err)
		}
	}
}

func TestLinuxDNSProbeRequiresARealAnswerOrNXDOMAINThroughFixedTUN(t *testing.T) {
	for _, name := range []string{"answer", "nxdomain", "timeout", "transport", "empty", "cancel"} {
		t.Run(name, func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			err := probeBridgeDNSWith(ctx, func(ctx context.Context, network, host string) ([]net.IP, error) {
				if network != "ip4" || host != bridgeDNSProbeName || !strings.HasSuffix(host, ".invalid.") {
					t.Fatal("probe escaped fixed absolute IPv4 question")
				}
				switch name {
				case "answer":
					return []net.IP{net.IPv4(198, 51, 100, 10)}, nil
				case "nxdomain":
					return nil, &net.DNSError{IsNotFound: true}
				case "timeout":
					return nil, &net.DNSError{IsNotFound: true, IsTimeout: true}
				case "cancel":
					cancel()
					return []net.IP{net.IPv4(198, 51, 100, 10)}, nil
				case "empty":
					return nil, nil
				default:
					return nil, errors.New("transport failed")
				}
			})
			want := name == "answer" || name == "nxdomain"
			if (err == nil) != want {
				t.Fatal("incorrect DNS readiness result", name, err)
			}
		})
	}
}

func TestLinuxSystemMetadataOutputIsBounded(t *testing.T) {
	var output limitedBridgeOutput
	if _, err := output.Write(make([]byte, 1024*1024)); err != nil {
		t.Fatal(err)
	}
	if _, err := output.Write([]byte("x")); err == nil {
		t.Fatal("unbounded system metadata")
	}
}

func TestLinuxPolicyParsesCapturedUbuntuNullFlagsAndPrefixlen(t *testing.T) {
	rules, err := parseLinuxPolicy([]byte(`[
	{"priority":19002,"not":null,"src":"all","dport":53,"table":"254","suppress_prefixlen":0},
	{"priority":19010,"src":"all","nop":null},
	{"priority":19002,"not":false,"src":"all","dport":53,"table":"254","suppress_prefixlen":0},
	{"priority":19010,"src":"all","nop":false},
	{"priority":19002,"not":null,"src":"192.0.2.0/24","dport":53,"table":"254","suppress_prefixlen":0},
	{"priority":19010,"src":"all","nop":false,"action":"nop"},
	{"priority":19002,"not":null,"src":"all","dport":53,"table":"254","suppress_prefixlen":1,"suppress_prefixlength":0}
	]`))
	if err != nil || len(rules) != 7 {
		t.Fatal(err)
	}
	for index, rule := range rules {
		if linuxPolicyOwned(rule) != (index < 2) {
			t.Fatal("captured policy ownership mismatch", index)
		}
	}
	for _, value := range []string{"", "false", "0", `"true"`} {
		if linuxPolicyFlag(json.RawMessage(value)) {
			t.Fatal("invalid present flag accepted", value)
		}
	}
	// Actual IPv6 dump uses +1, rather than the IPv4 +2 offset.
	rules, err = parseLinuxPolicy([]byte(`[{"priority":19001,"not":null,"src":"all","dport":53,"table":"254","suppress_prefixlen":0}]`))
	if err != nil || len(rules) != 1 || !linuxPolicyOwned(rules[0]) {
		t.Fatal("captured IPv6 MAIN rule not owned", err)
	}
}

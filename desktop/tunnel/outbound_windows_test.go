package main

import (
	"encoding/json"
	"errors"
	"net"
	"net/netip"
	"reflect"
	"testing"
)

// All tests supply in-memory dependencies; none calls the WinAPI adapter or
// routing wrappers, opens sockets, or starts an installed helper/service.
func outboundFixture() map[string]any {
	return map[string]any{"outbounds": []any{
		map[string]any{"tag": "proxy", "protocol": "vless", "settings": map[string]any{"vnext": []any{map[string]any{"address": "192.0.2.20", "port": 443, "users": []any{map[string]any{"id": "fixture-user", "encryption": "none"}}}}}, "streamSettings": map[string]any{"network": "ws", "security": "tls", "tlsSettings": map[string]any{"serverName": "vpn.example", "allowInsecure": false}, "wsSettings": map[string]any{"path": "/fixture", "headers": map[string]any{"Host": "front.example"}}, "sockopt": map[string]any{"mark": 42, "domainStrategy": "UseIPv4", "interface": "untrusted-old-value"}}},
		map[string]any{"tag": "direct", "protocol": "freedom", "settings": map[string]any{}, "streamSettings": map[string]any{"sockopt": map[string]any{"domainStrategy": "UseIPv4", "mark": 51}}},
		map[string]any{"tag": "block", "protocol": "blackhole", "settings": map[string]any{}},
	}}
}

type outboundTestState struct {
	adapters                      []desktopOutboundAdapter
	iface                         net.Interface
	bestCalls                     int
	bestErr, adapterErr, ifaceErr error
}

func newOutboundTestState() *outboundTestState {
	return &outboundTestState{adapters: []desktopOutboundAdapter{{index: 7, luid: 77, ifType: 6, up: true, ipv4: []netip.Addr{netip.MustParseAddr("198.51.100.2"), netip.MustParseAddr("198.51.100.3")}}}, iface: net.Interface{Index: 7, Name: "Wired uplink fixture", Flags: net.FlagUp}}
}

func (s *outboundTestState) dependencies() desktopOutboundDependencies {
	return desktopOutboundDependencies{
		bestInterface: func(endpoint netip.Addr) (uint32, error) {
			s.bestCalls++
			if endpoint != netip.MustParseAddr("192.0.2.20") {
				return 0, errors.New("wrong endpoint")
			}
			return 7, s.bestErr
		},
		adapters: func() ([]desktopOutboundAdapter, error) { return s.adapters, s.adapterErr },
		interfaceByIndex: func(index int) (*net.Interface, error) {
			if index != 7 {
				return nil, errors.New("wrong index")
			}
			return &s.iface, s.ifaceErr
		},
	}
}

func outboundJSON(t *testing.T, config map[string]any) string {
	t.Helper()
	data, err := json.Marshal(config)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func TestBindDesktopOutboundPreservesProtocolAndProtection(t *testing.T) {
	config := outboundFixture()
	before := outboundJSON(t, config)
	state := newOutboundTestState()
	check, err := bindDesktopOutboundWith(config, state.dependencies())
	if err != nil {
		t.Fatal(err)
	}
	if !check() || state.bestCalls != 1 {
		t.Fatal("guard reselected route after initial binding")
	}
	out := config["outbounds"].([]any)
	proxy := out[0].(map[string]any)
	direct := out[1].(map[string]any)
	for _, row := range []map[string]any{proxy, direct} {
		stream := row["streamSettings"].(map[string]any)
		if stream["sockopt"].(map[string]any)["interface"] != state.iface.Name {
			t.Fatal("trusted OS interface name was not injected")
		}
		delete(stream["sockopt"].(map[string]any), "interface")
	}
	proxy["streamSettings"].(map[string]any)["sockopt"].(map[string]any)["interface"] = "untrusted-old-value"
	if after := outboundJSON(t, config); after != before {
		t.Fatalf("binding changed unrelated protocol/mark/TLS/Host/UUID fields\nbefore=%s\nafter=%s", before, after)
	}
}

func TestBindDesktopOutboundStrictHasNoNewDirectRoute(t *testing.T) {
	config := outboundFixture()
	restrictDirect(config)
	state := newOutboundTestState()
	check, err := bindDesktopOutboundWith(config, state.dependencies())
	if err != nil || !check() {
		t.Fatalf("strict binding failed: %v", err)
	}
	rows := config["outbounds"].([]any)
	if rows[1].(map[string]any)["protocol"] != "blackhole" {
		t.Fatal("interface binding restored direct bypass in strict session")
	}
	if _, exists := rows[1].(map[string]any)["streamSettings"]; exists {
		t.Fatal("strict blackhole was modified")
	}
}

func TestBindDesktopOutboundAcceptsSupportedUnderlays(t *testing.T) {
	for _, ifType := range []uint32{6, 71, 23} {
		t.Run(netInterfaceTypeName(ifType), func(t *testing.T) {
			state := newOutboundTestState()
			state.adapters[0].ifType = ifType
			check, err := bindDesktopOutboundWith(outboundFixture(), state.dependencies())
			if err != nil || !check() {
				t.Fatalf("supported underlay rejected: %v", err)
			}
		})
	}
}

func netInterfaceTypeName(value uint32) string {
	switch value {
	case 6:
		return "Ethernet"
	case 71:
		return "WiFi"
	case 23:
		return "PPP"
	}
	return "unsupported"
}

func TestBindDesktopOutboundRejectsUnusableInterfaceWithoutMutation(t *testing.T) {
	tests := []struct {
		name   string
		change func(*outboundTestState)
	}{
		{"virtual53", func(s *outboundTestState) { s.adapters[0].ifType = 53 }},
		{"tunnel131", func(s *outboundTestState) { s.adapters[0].ifType = 131 }},
		{"loopback24", func(s *outboundTestState) { s.adapters[0].ifType = 24 }},
		{"nativeDown", func(s *outboundTestState) { s.adapters[0].up = false }},
		{"interfaceDown", func(s *outboundTestState) { s.iface.Flags = 0 }},
		{"interfaceLoopback", func(s *outboundTestState) { s.iface.Flags |= net.FlagLoopback }},
		{"ownName", func(s *outboundTestState) { s.iface.Name = "VIORA0" }},
		{"missingIndex", func(s *outboundTestState) { s.adapters[0].index = 8 }},
		{"wrongInterfaceIndex", func(s *outboundTestState) { s.iface.Index = 8 }},
		{"emptyName", func(s *outboundTestState) { s.iface.Name = "" }},
		{"noIPv4", func(s *outboundTestState) {
			s.adapters[0].ipv4 = []netip.Addr{netip.MustParseAddr("2001:db8::2"), netip.MustParseAddr("0.0.0.0"), netip.MustParseAddr("127.0.0.1"), netip.MustParseAddr("169.254.1.1"), netip.MustParseAddr("224.0.0.1")}
		}},
		{"routeFailure", func(s *outboundTestState) { s.bestErr = errors.New("fixture") }},
		{"enumerationFailure", func(s *outboundTestState) { s.adapterErr = errors.New("fixture") }},
		{"nameFailure", func(s *outboundTestState) { s.ifaceErr = errors.New("fixture") }},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			config := outboundFixture()
			before := outboundJSON(t, config)
			state := newOutboundTestState()
			test.change(state)
			check, err := bindDesktopOutboundWith(config, state.dependencies())
			if err == nil || check != nil {
				t.Fatal("unusable interface accepted")
			}
			if outboundJSON(t, config) != before {
				t.Fatal("failed selection partially changed config")
			}
		})
	}
}

func TestBindDesktopOutboundGuardDetectsLinkIdentityChanges(t *testing.T) {
	tests := []struct {
		name   string
		change func(*outboundTestState)
		want   bool
	}{
		{"unchanged", func(s *outboundTestState) {}, true},
		{"addressOrderAndDuplicates", func(s *outboundTestState) {
			s.adapters[0].ipv4 = []netip.Addr{netip.MustParseAddr("198.51.100.3"), netip.MustParseAddr("198.51.100.2"), netip.MustParseAddr("198.51.100.2")}
		}, true},
		{"interfaceGone", func(s *outboundTestState) { s.adapters = nil }, false},
		{"nativeDown", func(s *outboundTestState) { s.adapters[0].up = false }, false},
		{"interfaceDown", func(s *outboundTestState) { s.iface.Flags = 0 }, false},
		{"renamed", func(s *outboundTestState) { s.iface.Name = "New fixture name" }, false},
		{"indexReused", func(s *outboundTestState) { s.adapters[0].luid = 88 }, false},
		{"dhcpChange", func(s *outboundTestState) { s.adapters[0].ipv4 = []netip.Addr{netip.MustParseAddr("198.51.100.4")} }, false},
		{"lostIPv4", func(s *outboundTestState) { s.adapters[0].ipv4 = nil }, false},
		{"enumerationError", func(s *outboundTestState) { s.adapterErr = errors.New("fixture") }, false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			state := newOutboundTestState()
			check, err := bindDesktopOutboundWith(outboundFixture(), state.dependencies())
			if err != nil {
				t.Fatal(err)
			}
			test.change(state)
			if got := check(); got != test.want {
				t.Fatalf("guard=%v want%v", got, test.want)
			}
			if state.bestCalls != 1 {
				t.Fatal("guard queried best route after TUN")
			}
		})
	}
}

func TestBindDesktopOutboundInvalidConfigIsAtomic(t *testing.T) {
	tests := []struct {
		name   string
		change func(map[string]any)
	}{
		{"unresolvedEndpoint", func(c map[string]any) {
			c["outbounds"].([]any)[0].(map[string]any)["settings"].(map[string]any)["vnext"].([]any)[0].(map[string]any)["address"] = "vpn.example"
		}},
		{"IPv6Endpoint", func(c map[string]any) {
			c["outbounds"].([]any)[0].(map[string]any)["settings"].(map[string]any)["vnext"].([]any)[0].(map[string]any)["address"] = "2001:db8::1"
		}},
		{"lateInvalidStream", func(c map[string]any) { c["outbounds"].([]any)[1].(map[string]any)["streamSettings"] = "bad" }},
		{"lateInvalidSockopt", func(c map[string]any) {
			c["outbounds"].([]any)[1].(map[string]any)["streamSettings"].(map[string]any)["sockopt"] = "bad"
		}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			config := outboundFixture()
			test.change(config)
			before := outboundJSON(t, config)
			state := newOutboundTestState()
			check, err := bindDesktopOutboundWith(config, state.dependencies())
			if err == nil || check != nil {
				t.Fatal("invalid config accepted")
			}
			if outboundJSON(t, config) != before {
				t.Fatal("invalid config partially modified")
			}
		})
	}
	state := newOutboundTestState()
	if _, err := bindDesktopOutboundWith(nil, state.dependencies()); err == nil || state.bestCalls != 0 {
		t.Fatal("nil config reached platform lookup")
	}
}

func TestBindDesktopOutboundBuildsMissingStreamOptions(t *testing.T) {
	config := outboundFixture()
	rows := config["outbounds"].([]any)
	delete(rows[1].(map[string]any), "streamSettings")
	state := newOutboundTestState()
	check, err := bindDesktopOutboundWith(config, state.dependencies())
	if err != nil || !check() {
		t.Fatal(err)
	}
	want := map[string]any{"sockopt": map[string]any{"interface": state.iface.Name}}
	if !reflect.DeepEqual(rows[1].(map[string]any)["streamSettings"], want) {
		t.Fatal("missing direct stream options were not constructed correctly")
	}
}

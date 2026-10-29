package main

import (
	"bytes"
	"encoding/binary"
	"errors"
	"net/netip"
	"testing"

	"golang.org/x/sys/unix"
)

func TestLinuxUnderlayPinsInterfaceMarkAndObservesChange(t *testing.T) {
	config := linuxBridgeFixture(t, "all", false)
	identity := linuxOutboundSnapshot{index: 2, name: "eth0", hardware: "fixture", addresses: []netip.Addr{netip.MustParseAddr("192.0.2.2")}}
	deps := linuxOutboundDependencies{
		route: func(endpoint netip.Addr) (int, error) {
			if endpoint.String() != "192.0.2.10" {
				t.Fatal(endpoint)
			}
			return 2, nil
		},
		iface: func(int) (linuxOutboundSnapshot, error) { return identity, nil },
	}
	check, err := bindLinuxOutboundWith(config, deps)
	if err != nil || check == nil || !check() {
		t.Fatal("valid underlay rejected", err)
	}
	options := proxyMap(config)["streamSettings"].(map[string]any)["sockopt"].(map[string]any)
	if options["interface"] != "eth0" || options["mark"] != protectionMark {
		t.Fatal("underlay and mark not pinned")
	}
	identity.name = "different0"
	if check() {
		t.Fatal("changed interface accepted")
	}
}

func TestLinuxUnderlayFailsWithoutMutatingInput(t *testing.T) {
	for _, bad := range []string{"no-route", "down", "viora0", "lo", "too-long-interface-name"} {
		t.Run(bad, func(t *testing.T) {
			config := linuxBridgeFixture(t, "all", false)
			before := linuxBridgeJSON(t, config)
			deps := linuxOutboundDependencies{
				route: func(netip.Addr) (int, error) {
					if bad == "no-route" {
						return 0, errors.New("fixture")
					}
					return 2, nil
				},
				iface: func(int) (linuxOutboundSnapshot, error) {
					if bad == "down" {
						return linuxOutboundSnapshot{}, errors.New("down")
					}
					return linuxOutboundSnapshot{index: 2, name: bad, addresses: []netip.Addr{netip.MustParseAddr("192.0.2.2")}}, nil
				},
			}
			if check, err := bindLinuxOutboundWith(config, deps); err == nil || check != nil {
				t.Fatal("bad underlay accepted")
			}
			if !bytes.Equal(before, linuxBridgeJSON(t, config)) {
				t.Fatal("failed selection mutated config")
			}
		})
	}
}

func TestLinuxRouteReplyRequiresKernelUnicastInterface(t *testing.T) {
	data := make([]byte, 36)
	binary.NativeEndian.PutUint32(data[:4], uint32(len(data)))
	binary.NativeEndian.PutUint16(data[4:6], unix.RTM_NEWROUTE)
	binary.NativeEndian.PutUint32(data[8:12], 1)
	data[16], data[23] = unix.AF_INET, unix.RTN_UNICAST
	binary.NativeEndian.PutUint16(data[28:30], 8)
	binary.NativeEndian.PutUint16(data[30:32], unix.RTA_OIF)
	binary.NativeEndian.PutUint32(data[32:36], 7)
	if index, err := parseLinuxRouteReply(data); err != nil || index != 7 {
		t.Fatal(index, err)
	}
	for _, change := range []func([]byte){func(b []byte) { b[8] = 2 }, func(b []byte) { b[4] = unix.NLMSG_ERROR }, func(b []byte) { b[23] = unix.RTN_BLACKHOLE }, func(b []byte) { b[32] = 0 }} {
		bad := append([]byte(nil), data...)
		change(bad)
		if _, err := parseLinuxRouteReply(bad); err == nil {
			t.Fatal("malformed/unsafe route accepted")
		}
	}
	for n := 0; n < len(data); n++ {
		if _, err := parseLinuxRouteReply(data[:n]); err == nil {
			t.Fatal("truncated metadata accepted")
		}
	}
}

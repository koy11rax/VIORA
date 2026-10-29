package route

import (
	"errors"
	"net"
	"net/netip"
	"testing"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing/common/control"
)

type localSourceFixtureFinder struct {
	control.InterfaceFinder
	rows []control.Interface
}

func (f localSourceFixtureFinder) Interfaces() []control.Interface { return f.rows }

type localSourceFixtureNetwork struct {
	adapter.NetworkManager
	finder control.InterfaceFinder
}

func (n localSourceFixtureNetwork) InterfaceFinder() control.InterfaceFinder { return n.finder }

func TestVioraLocalSourceCachedMissUsesExactLiveKernelAddress(t *testing.T) {
	for _, row := range []struct {
		name, source, live string
		want               bool
	}{
		{"new TUN IPv4", "172.29.255.1", "172.29.255.1", true},
		{"same subnet is not local", "172.29.255.2", "172.29.255.1", false},
		{"unrelated address", "198.51.100.10", "172.29.255.1", false},
		{"IPv4 mapped", "::ffff:172.29.255.1", "172.29.255.1", true},
		{"IPv6 exact", "fd71:7669:6f72::1", "fd71:7669:6f72::1", true},
		{"IPv6 subnet is not local", "fd71:7669:6f72::2", "fd71:7669:6f72::1", false},
	} {
		t.Run(row.name, func(t *testing.T) {
			router := Router{network: localSourceFixtureNetwork{finder: localSourceFixtureFinder{}}}
			calls := 0
			got := router.isLocalSourceWith(netip.MustParseAddr(row.source), func() ([]net.Addr, error) {
				calls++
				return []net.Addr{&net.IPNet{IP: net.ParseIP(row.live), Mask: net.CIDRMask(24, 32)}}, nil
			})
			if got != row.want || calls != 1 {
				t.Fatalf("locality=%t want=%t enumeration=%d", got, row.want, calls)
			}
		})
	}
}

func TestVioraLocalSourceCachedHitDoesNotEnumerateLiveInterfaces(t *testing.T) {
	finder := localSourceFixtureFinder{rows: []control.Interface{{Addresses: []netip.Prefix{netip.MustParsePrefix("172.29.255.1/30")}}}}
	router := Router{network: localSourceFixtureNetwork{finder: finder}}
	if !router.isLocalSourceWith(netip.MustParseAddr("172.29.255.1"), func() ([]net.Addr, error) { t.Fatal("cached hit performed a fresh query"); return nil, nil }) {
		t.Fatal("cached address lost")
	}
	if !router.isLocalSourceWith(netip.MustParseAddr("127.0.0.1"), func() ([]net.Addr, error) { t.Fatal("loopback performed a fresh query"); return nil, nil }) {
		t.Fatal("loopback lost")
	}
}

func TestVioraLocalSourceLiveMetadataFailureRemainsClosed(t *testing.T) {
	router := Router{network: localSourceFixtureNetwork{finder: localSourceFixtureFinder{}}}
	for _, enumerate := range []func() ([]net.Addr, error){
		func() ([]net.Addr, error) { return nil, errors.New("kernel unavailable") },
		func() ([]net.Addr, error) { return nil, nil },
		func() ([]net.Addr, error) { return []net.Addr{&net.IPAddr{}}, nil },
	} {
		if router.isLocalSourceWith(netip.MustParseAddr("172.29.255.1"), enumerate) {
			t.Fatal("unknown source became trusted")
		}
	}
}

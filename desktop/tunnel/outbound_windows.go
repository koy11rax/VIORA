package main

import (
	"errors"
	"net"
	"net/netip"
	"runtime"
	"slices"
	"strings"
	"unsafe"

	"golang.org/x/sys/windows"
)

type desktopOutboundAdapter struct {
	index  uint32
	luid   uint64
	ifType uint32
	up     bool
	ipv4   []netip.Addr
}

type desktopOutboundDependencies struct {
	bestInterface    func(netip.Addr) (uint32, error)
	adapters         func() ([]desktopOutboundAdapter, error)
	interfaceByIndex func(int) (*net.Interface, error)
}

type desktopOutboundIdentity struct {
	index uint32
	luid  uint64
	name  string
	ipv4  []netip.Addr
}

// Called only after endpoint bootstrap and before creating a TUN. These APIs
// query local routing/interface metadata; they do not send a probe or packet.
func bindDesktopOutbound(config map[string]any) (func() bool, error) {
	return bindDesktopOutboundWith(config, desktopOutboundDependencies{
		bestInterface: func(endpoint netip.Addr) (uint32, error) {
			var index uint32
			err := windows.GetBestInterfaceEx(&windows.SockaddrInet4{Addr: endpoint.As4()}, &index)
			return index, err
		},
		adapters:         desktopOutboundAdapters,
		interfaceByIndex: net.InterfaceByIndex,
	})
}

func bindDesktopOutboundWith(config map[string]any, deps desktopOutboundDependencies) (func() bool, error) {
	outbounds, ok := config["outbounds"].([]any)
	if !ok || len(outbounds) == 0 {
		return nil, errors.New("outbound interface config invalid")
	}
	proxy, ok := outbounds[0].(map[string]any)
	if !ok || proxy["protocol"] != "vless" {
		return nil, errors.New("outbound interface proxy invalid")
	}
	settings, ok := proxy["settings"].(map[string]any)
	if !ok {
		return nil, errors.New("outbound interface settings invalid")
	}
	servers, ok := settings["vnext"].([]any)
	if !ok || len(servers) != 1 {
		return nil, errors.New("outbound interface endpoint invalid")
	}
	server, ok := servers[0].(map[string]any)
	if !ok {
		return nil, errors.New("outbound interface endpoint invalid")
	}
	address, ok := server["address"].(string)
	if !ok {
		return nil, errors.New("outbound interface endpoint invalid")
	}
	endpoint, err := netip.ParseAddr(address)
	if err != nil || !endpoint.Is4() || endpoint.IsUnspecified() || endpoint.IsLoopback() || endpoint.IsMulticast() {
		return nil, errors.New("outbound interface requires numeric IPv4 endpoint")
	}
	index, err := deps.bestInterface(endpoint)
	if err != nil || index == 0 {
		return nil, errors.New("outbound interface route unavailable")
	}
	identity, err := desktopOutboundSnapshot(index, deps)
	if err != nil {
		return nil, err
	}

	// Stage shallow copies so malformed input or a failed selection never leaves
	// a partially modified configuration. TLS/REALITY/HTTP metadata is untouched.
	type update struct{ row, stream map[string]any }
	updates := make([]update, 0, len(outbounds))
	for position, entry := range outbounds {
		row, valid := entry.(map[string]any)
		if !valid {
			return nil, errors.New("outbound interface row invalid")
		}
		if position != 0 && row["protocol"] != "freedom" {
			continue
		}
		stream := map[string]any{}
		if value, exists := row["streamSettings"]; exists {
			original, valid := value.(map[string]any)
			if !valid {
				return nil, errors.New("outbound interface stream invalid")
			}
			for key, value := range original {
				stream[key] = value
			}
		}
		sockopt := map[string]any{}
		if value, exists := stream["sockopt"]; exists {
			original, valid := value.(map[string]any)
			if !valid {
				return nil, errors.New("outbound interface options invalid")
			}
			for key, value := range original {
				sockopt[key] = value
			}
		}
		sockopt["interface"] = identity.name
		stream["sockopt"] = sockopt
		updates = append(updates, update{row: row, stream: stream})
	}
	for _, item := range updates {
		item.row["streamSettings"] = item.stream
	}
	return func() bool {
		// Do not repeat GetBestInterfaceEx after TUN activation: the TUN's own
		// default route would be selected. Observe the pinned underlay instead.
		current, err := desktopOutboundSnapshot(identity.index, deps)
		return err == nil && current.luid == identity.luid && current.name == identity.name && slices.Equal(current.ipv4, identity.ipv4)
	}, nil
}

func desktopOutboundSnapshot(index uint32, deps desktopOutboundDependencies) (desktopOutboundIdentity, error) {
	adapters, err := deps.adapters()
	if err != nil {
		return desktopOutboundIdentity{}, errors.New("outbound interface enumeration failed")
	}
	for _, adapter := range adapters {
		if adapter.index != index {
			continue
		}
		// IF_TYPE_PROP_VIRTUAL(53), TUNNEL(131), loopback and all other types
		// are excluded. Ethernet can include a system-managed virtual uplink;
		// this is an interface-type policy, not proof of physical hardware.
		if !adapter.up || (adapter.ifType != windows.IF_TYPE_ETHERNET_CSMACD && adapter.ifType != windows.IF_TYPE_IEEE80211 && adapter.ifType != windows.IF_TYPE_PPP) {
			return desktopOutboundIdentity{}, errors.New("outbound interface is not a usable underlay")
		}
		iface, err := deps.interfaceByIndex(int(index))
		if err != nil || iface == nil || iface.Index != int(index) || iface.Name == "" || strings.EqualFold(iface.Name, "viora0") || iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			return desktopOutboundIdentity{}, errors.New("outbound interface identity unavailable")
		}
		addresses := make([]netip.Addr, 0, len(adapter.ipv4))
		for _, address := range adapter.ipv4 {
			if address.Is4() && !address.IsUnspecified() && !address.IsLoopback() && !address.IsMulticast() && !address.IsLinkLocalUnicast() {
				addresses = append(addresses, address)
			}
		}
		slices.SortFunc(addresses, func(a, b netip.Addr) int { return a.Compare(b) })
		addresses = slices.Compact(addresses)
		if len(addresses) == 0 {
			return desktopOutboundIdentity{}, errors.New("outbound interface IPv4 unavailable")
		}
		return desktopOutboundIdentity{index: index, luid: adapter.luid, name: iface.Name, ipv4: addresses}, nil
	}
	return desktopOutboundIdentity{}, errors.New("outbound interface disappeared")
}

func desktopOutboundAdapters() ([]desktopOutboundAdapter, error) {
	// Microsoft recommends an initial 15 KiB buffer. Retry only bounded size
	// changes during local adapter enumeration, never unbounded allocation.
	size := uint32(15000)
	for attempt := 0; attempt < 3; attempt++ {
		if size == 0 || size > 1024*1024 {
			return nil, errors.New("outbound adapter data too large")
		}
		buffer := make([]byte, int(size))
		first := (*windows.IpAdapterAddresses)(unsafe.Pointer(&buffer[0]))
		flags := uint32(windows.GAA_FLAG_SKIP_ANYCAST | windows.GAA_FLAG_SKIP_MULTICAST | windows.GAA_FLAG_SKIP_DNS_SERVER)
		err := windows.GetAdaptersAddresses(windows.AF_INET, flags, 0, first, &size)
		if errors.Is(err, windows.ERROR_BUFFER_OVERFLOW) {
			continue
		}
		if err != nil {
			return nil, err
		}
		result := make([]desktopOutboundAdapter, 0, 8)
		for adapter := first; adapter != nil; adapter = adapter.Next {
			row := desktopOutboundAdapter{index: adapter.IfIndex, luid: adapter.Luid, ifType: adapter.IfType, up: adapter.OperStatus == windows.IfOperStatusUp}
			for unicast := adapter.FirstUnicastAddress; unicast != nil; unicast = unicast.Next {
				if unicast.Address.Sockaddr == nil || unicast.ValidLifetime == 0 || (unicast.DadState != windows.IpDadStatePreferred && unicast.DadState != windows.IpDadStateDeprecated) {
					continue
				}
				if address, ok := netip.AddrFromSlice(unicast.Address.IP()); ok {
					row.ipv4 = append(row.ipv4, address.Unmap())
				}
			}
			result = append(result, row)
		}
		runtime.KeepAlive(buffer)
		return result, nil
	}
	return nil, errors.New("outbound adapter enumeration changed repeatedly")
}

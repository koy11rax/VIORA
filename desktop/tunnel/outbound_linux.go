package main

import (
	"encoding/binary"
	"errors"
	"net"
	"net/netip"
	"slices"
	"strings"
	"syscall"

	"golang.org/x/sys/unix"
)

type linuxOutboundSnapshot struct {
	index     int
	name      string
	hardware  string
	addresses []netip.Addr
}

type linuxOutboundDependencies struct {
	route func(netip.Addr) (int, error)
	iface func(int) (linuxOutboundSnapshot, error)
}

// RTM_GETROUTE reads kernel metadata, without sending a probe to the server.
func bindDesktopOutbound(config map[string]any) (func() bool, error) {
	return bindLinuxOutboundWith(config, linuxOutboundDependencies{route: linuxRouteInterface, iface: snapshotLinuxInterface})
}

func bindLinuxOutboundWith(config map[string]any, deps linuxOutboundDependencies) (func() bool, error) {
	copy, err := cloneBridgeMap(config)
	if err != nil {
		return nil, err
	}
	outs, ok := copy["outbounds"].([]any)
	if !ok || len(outs) == 0 {
		return nil, errors.New("missing outbound")
	}
	proxy, ok := outs[0].(map[string]any)
	if !ok || proxy["protocol"] != "vless" {
		return nil, errors.New("invalid outbound")
	}
	settings, ok := proxy["settings"].(map[string]any)
	if !ok {
		return nil, errors.New("invalid settings")
	}
	servers, ok := settings["vnext"].([]any)
	if !ok || len(servers) != 1 {
		return nil, errors.New("invalid endpoint")
	}
	server, ok := servers[0].(map[string]any)
	if !ok {
		return nil, errors.New("invalid endpoint")
	}
	address, ok := server["address"].(string)
	if !ok {
		return nil, errors.New("invalid endpoint")
	}
	endpoint, err := netip.ParseAddr(address)
	if err != nil || !endpoint.Is4() || endpoint.IsUnspecified() || endpoint.IsLoopback() || endpoint.IsMulticast() {
		return nil, errors.New("numeric IPv4 endpoint required")
	}
	index, err := deps.route(endpoint)
	if err != nil || index <= 0 {
		return nil, errors.New("no endpoint route")
	}
	identity, err := deps.iface(index)
	if err != nil || !validLinuxOutboundSnapshot(identity) {
		return nil, errors.New("no usable underlay")
	}
	stream, ok := proxy["streamSettings"].(map[string]any)
	if !ok {
		return nil, errors.New("invalid transport")
	}
	options := map[string]any{}
	if value, exists := stream["sockopt"]; exists {
		original, ok := value.(map[string]any)
		if !ok {
			return nil, errors.New("invalid socket options")
		}
		for key, value := range original {
			options[key] = value
		}
	}
	options["interface"] = identity.name
	options["mark"] = protectionMark
	stream["sockopt"] = options
	// Commit only after all native observations and validation have succeeded.
	config["outbounds"] = copy["outbounds"]
	return func() bool {
		current, err := deps.iface(identity.index)
		return err == nil && validLinuxOutboundSnapshot(current) && current.index == identity.index && current.name == identity.name && current.hardware == identity.hardware && slices.Equal(current.addresses, identity.addresses)
	}, nil
}

func validLinuxOutboundSnapshot(value linuxOutboundSnapshot) bool {
	return value.index > 0 && value.name != "" && len(value.name) < 16 && value.name != "viora0" && value.name != "lo" && !strings.ContainsAny(value.name, "/:\x00\r\n\t ") && len(value.addresses) > 0
}

func snapshotLinuxInterface(index int) (linuxOutboundSnapshot, error) {
	iface, err := net.InterfaceByIndex(index)
	if err != nil {
		return linuxOutboundSnapshot{}, err
	}
	if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
		return linuxOutboundSnapshot{}, errors.New("underlay down")
	}
	raw, err := iface.Addrs()
	if err != nil {
		return linuxOutboundSnapshot{}, err
	}
	var addresses []netip.Addr
	for _, raw := range raw {
		prefix, err := netip.ParsePrefix(raw.String())
		if err != nil {
			continue
		}
		address := prefix.Addr().Unmap()
		if address.Is4() && !address.IsUnspecified() && !address.IsLoopback() && !address.IsMulticast() && !address.IsLinkLocalUnicast() {
			addresses = append(addresses, address)
		}
	}
	slices.SortFunc(addresses, func(a, b netip.Addr) int { return a.Compare(b) })
	addresses = slices.Compact(addresses)
	return linuxOutboundSnapshot{index: index, name: iface.Name, hardware: iface.HardwareAddr.String(), addresses: addresses}, nil
}

func linuxRouteInterface(endpoint netip.Addr) (int, error) {
	if !endpoint.Is4() {
		return 0, errors.New("IPv4 required")
	}
	fd, err := unix.Socket(unix.AF_NETLINK, unix.SOCK_RAW|unix.SOCK_CLOEXEC, unix.NETLINK_ROUTE)
	if err != nil {
		return 0, err
	}
	defer unix.Close(fd)
	timeout := unix.NsecToTimeval(1000000000)
	if err = unix.SetsockoptTimeval(fd, unix.SOL_SOCKET, unix.SO_RCVTIMEO, &timeout); err != nil {
		return 0, err
	}
	if err = unix.SetsockoptTimeval(fd, unix.SOL_SOCKET, unix.SO_SNDTIMEO, &timeout); err != nil {
		return 0, err
	}
	if err = unix.Bind(fd, &unix.SockaddrNetlink{Family: unix.AF_NETLINK}); err != nil {
		return 0, err
	}
	request := make([]byte, 44) // nlmsghdr + rtmsg + aligned RTA_DST/RTA_MARK
	binary.NativeEndian.PutUint32(request[0:4], uint32(len(request)))
	binary.NativeEndian.PutUint16(request[4:6], unix.RTM_GETROUTE)
	binary.NativeEndian.PutUint16(request[6:8], unix.NLM_F_REQUEST)
	binary.NativeEndian.PutUint32(request[8:12], 1)
	request[16], request[17] = unix.AF_INET, 32
	binary.NativeEndian.PutUint16(request[28:30], 8)
	binary.NativeEndian.PutUint16(request[30:32], unix.RTA_DST)
	address := endpoint.As4()
	copy(request[32:36], address[:])
	binary.NativeEndian.PutUint16(request[36:38], 8)
	binary.NativeEndian.PutUint16(request[38:40], unix.RTA_MARK)
	binary.NativeEndian.PutUint32(request[40:44], protectionMark)
	if err = unix.Sendto(fd, request, 0, &unix.SockaddrNetlink{Family: unix.AF_NETLINK}); err != nil {
		return 0, err
	}
	buffer := make([]byte, 64*1024)
	length, from, err := unix.Recvfrom(fd, buffer, 0)
	if err != nil {
		return 0, err
	}
	peer, ok := from.(*unix.SockaddrNetlink)
	if !ok || peer.Pid != 0 || length >= len(buffer) {
		return 0, errors.New("invalid route reply")
	}
	return parseLinuxRouteReply(buffer[:length])
}

func parseLinuxRouteReply(data []byte) (int, error) {
	messages, err := syscall.ParseNetlinkMessage(data)
	if err != nil {
		return 0, err
	}
	for _, message := range messages {
		if message.Header.Seq != 1 {
			return 0, errors.New("route sequence mismatch")
		}
		if message.Header.Type != unix.RTM_NEWROUTE || len(message.Data) < unix.SizeofRtMsg || message.Data[0] != unix.AF_INET || message.Data[7] != unix.RTN_UNICAST {
			return 0, errors.New("no unicast route")
		}
		attributes, err := syscall.ParseNetlinkRouteAttr(&message)
		if err != nil {
			return 0, err
		}
		for _, attr := range attributes {
			if attr.Attr.Type == unix.RTA_OIF && len(attr.Value) == 4 {
				index := binary.NativeEndian.Uint32(attr.Value)
				if index == 0 || index > 1<<30 {
					return 0, errors.New("invalid route interface")
				}
				return int(index), nil
			}
		}
	}
	return 0, errors.New("route has no interface")
}

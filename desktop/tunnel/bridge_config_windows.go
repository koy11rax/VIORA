package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"net/netip"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"
)

var invalidWindowsBridge = errors.New("invalid Windows bridge configuration")

// buildWindowsBridge is pure. The caller supplies a sanitized configuration
// after numeric endpoint bootstrap and trusted native interface selection.
// Xray owns only VLESS transport; sing-box 1.14.4 owns the Windows system TUN.
func buildWindowsBridge(config map[string]any, port uint16, user, password string) (map[string]any, map[string]any, error) {
	if port == 0 || !bridgeCredential(user, 1) || !bridgeCredential(password, 16) {
		return nil, nil, invalidWindowsBridge
	}
	copy, err := cloneBridgeMap(config)
	if err != nil {
		return nil, nil, invalidWindowsBridge
	}
	out, ok := copy["outbounds"].([]any)
	if !ok || (len(out) != 3 && len(out) != 4) {
		return nil, nil, invalidWindowsBridge
	}
	proxy, ok := out[0].(map[string]any)
	if !ok || proxy["tag"] != "proxy" || proxy["protocol"] != "vless" {
		return nil, nil, invalidWindowsBridge
	}
	settings, ok := proxy["settings"].(map[string]any)
	if !ok {
		return nil, nil, invalidWindowsBridge
	}
	servers, ok := settings["vnext"].([]any)
	if !ok || len(servers) != 1 {
		return nil, nil, invalidWindowsBridge
	}
	server, ok := servers[0].(map[string]any)
	if !ok {
		return nil, nil, invalidWindowsBridge
	}
	endpoint, ok := server["address"].(string)
	if !ok {
		return nil, nil, invalidWindowsBridge
	}
	ip, err := netip.ParseAddr(endpoint)
	if err != nil || !ip.Is4() {
		return nil, nil, invalidWindowsBridge
	}
	stream, ok := proxy["streamSettings"].(map[string]any)
	if !ok {
		return nil, nil, invalidWindowsBridge
	}
	sockopt, ok := stream["sockopt"].(map[string]any)
	if !ok {
		return nil, nil, invalidWindowsBridge
	}
	underlay, ok := sockopt["interface"].(string)
	if !ok || underlay == "" || len(underlay) > 256 || strings.ContainsAny(underlay, "\x00\r\n") || strings.EqualFold(underlay, "viora0") {
		return nil, nil, invalidWindowsBridge
	}
	protocols := map[string]string{}
	for _, item := range out {
		row, ok := item.(map[string]any)
		if !ok {
			return nil, nil, invalidWindowsBridge
		}
		tag, ok := row["tag"].(string)
		if !ok {
			return nil, nil, invalidWindowsBridge
		}
		protocol, ok := row["protocol"].(string)
		if !ok {
			return nil, nil, invalidWindowsBridge
		}
		if _, exists := protocols[tag]; exists {
			return nil, nil, invalidWindowsBridge
		}
		switch tag {
		case "proxy":
			if protocol != "vless" {
				return nil, nil, invalidWindowsBridge
			}
		case "direct":
		case "block":
		case "dns-out":
			if protocol != "dns" {
				return nil, nil, invalidWindowsBridge
			}
		default:
			return nil, nil, invalidWindowsBridge
		}
		protocols[tag] = protocol
	}
	if protocols["direct"] != "freedom" && protocols["direct"] != "blackhole" {
		return nil, nil, invalidWindowsBridge
	}
	if protocols["block"] != "blackhole" {
		return nil, nil, invalidWindowsBridge
	}
	inbounds, ok := copy["inbounds"].([]any)
	if !ok || len(inbounds) != 1 {
		return nil, nil, invalidWindowsBridge
	}
	inbound, ok := inbounds[0].(map[string]any)
	if !ok || inbound["protocol"] != "tun" {
		return nil, nil, invalidWindowsBridge
	}
	tunSettings, ok := inbound["settings"].(map[string]any)
	if !ok {
		return nil, nil, invalidWindowsBridge
	}
	mtu, err := bridgeInt(tunSettings["mtu"])
	if err != nil || (mtu != 1280 && mtu != 1420 && mtu != 1500) {
		return nil, nil, invalidWindowsBridge
	}
	dnsServer, err := bridgeDNSServer(copy["dns"])
	if err != nil {
		return nil, nil, err
	}
	routing, ok := copy["routing"].(map[string]any)
	if !ok {
		return nil, nil, invalidWindowsBridge
	}
	rawRules, ok := routing["rules"].([]any)
	if !ok || len(rawRules) < 5 {
		return nil, nil, invalidWindowsBridge
	}
	if !bridgeSafetyPrefix(rawRules) {
		return nil, nil, invalidWindowsBridge
	}
	// Preserve the service-owned DNS/IPv6 prefix. Domain sniffing comes after
	// it, so ordinary DNS and unsupported IPv6 never wait for stream sniffing.
	frontRules := []any{}
	for index, item := range rawRules {
		if index == 5 {
			frontRules = append(frontRules, map[string]any{"network": "icmp", "action": "reject"})
			frontRules = append(frontRules, map[string]any{"action": "sniff", "sniffer": []string{"http", "tls", "quic"}, "timeout": "300ms"})
		}
		row, ok := item.(map[string]any)
		if !ok {
			return nil, nil, invalidWindowsBridge
		}
		translated, skip, err := translateWindowsBridgeRule(row, protocols)
		if err != nil {
			return nil, nil, err
		}
		if !skip {
			frontRules = append(frontRules, translated)
		}
	}
	if len(rawRules) == 5 {
		frontRules = append(frontRules, map[string]any{"action": "sniff", "sniffer": []string{"http", "tls", "quic"}, "timeout": "300ms"})
	}
	frontOut := []any{map[string]any{"type": "socks", "tag": "proxy", "server": "127.0.0.1", "server_port": port, "version": "5", "username": user, "password": password}}
	if protocols["direct"] == "freedom" {
		frontOut = append(frontOut, map[string]any{"type": "direct", "tag": "direct", "bind_interface": underlay, "domain_resolver": "dns-remote"})
	}
	backend := map[string]any{
		"log":       map[string]any{"loglevel": "warning", "access": "none", "dnsLog": false},
		"inbounds":  []any{map[string]any{"tag": "bridge-socks", "listen": "127.0.0.1", "port": port, "protocol": "socks", "settings": map[string]any{"auth": "password", "accounts": []any{map[string]any{"user": user, "pass": password}}, "udp": true, "ip": "127.0.0.1", "userLevel": 8}, "sniffing": map[string]any{"enabled": false}}},
		"outbounds": []any{proxy}, "stats": map[string]any{}, "policy": map[string]any{"system": map[string]any{"statsOutboundUplink": true, "statsOutboundDownlink": true}},
	}
	frontend := map[string]any{
		"log":       map[string]any{"level": "warn", "timestamp": false},
		"dns":       map[string]any{"servers": []any{dnsServer}, "final": "dns-remote", "strategy": "ipv4_only", "timeout": "8s", "reverse_mapping": false, "rules": []any{map[string]any{"query_type": []string{"AAAA"}, "action": "predefined", "rcode": "NOERROR"}}},
		"inbounds":  []any{map[string]any{"type": "tun", "tag": "tun", "interface_name": "viora0", "address": []string{"172.29.255.1/30", "fd71:7669:6f72::1/126"}, "mtu": mtu, "auto_route": true, "strict_route": true, "stack": "system", "dns_mode": "hijack", "dns_address": []string{"172.29.255.2"}}},
		"outbounds": frontOut, "route": map[string]any{"rules": frontRules, "final": "proxy", "auto_detect_interface": true, "default_domain_resolver": "dns-remote"},
	}
	return backend, frontend, nil
}

func cloneBridgeMap(value map[string]any) (map[string]any, error) {
	encoded, err := json.Marshal(value)
	if err != nil {
		return nil, err
	}
	decoder := json.NewDecoder(bytes.NewReader(encoded))
	decoder.UseNumber()
	var result map[string]any
	err = decoder.Decode(&result)
	return result, err
}

func bridgeCredential(value string, minimum int) bool {
	return len(value) >= minimum && len(value) <= 255 && utf8.ValidString(value) && !strings.ContainsAny(value, "\x00\r\n")
}

func bridgeInt(value any) (int, error) {
	switch value := value.(type) {
	case json.Number:
		return strconv.Atoi(string(value))
	case int:
		return value, nil
	default:
		return 0, invalidWindowsBridge
	}
}

func bridgeStrings(value any) ([]string, error) {
	values, ok := value.([]any)
	if !ok {
		return nil, invalidWindowsBridge
	}
	result := make([]string, 0, len(values))
	for _, item := range values {
		text, ok := item.(string)
		if !ok || text == "" {
			return nil, invalidWindowsBridge
		}
		result = append(result, text)
	}
	if len(result) == 0 {
		return nil, invalidWindowsBridge
	}
	return result, nil
}

func bridgeDNSServer(value any) (map[string]any, error) {
	dns, ok := value.(map[string]any)
	if !ok {
		return nil, invalidWindowsBridge
	}
	servers, err := bridgeStrings(dns["servers"])
	if err != nil || len(servers) != 1 {
		return nil, invalidWindowsBridge
	}
	result := map[string]any{"tag": "dns-remote", "detour": "proxy"}
	if servers[0] == "https://1.1.1.1/dns-query" {
		result["type"] = "https"
		result["server"] = "1.1.1.1"
		result["server_port"] = 443
		result["path"] = "/dns-query"
		result["tls"] = map[string]any{"enabled": true, "server_name": "1.1.1.1"}
		return result, nil
	}
	ip, err := netip.ParseAddr(servers[0])
	if err != nil || !ip.Is4() {
		return nil, invalidWindowsBridge
	}
	result["type"] = "udp"
	result["server"] = ip.String()
	result["server_port"] = 53
	return result, nil
}

func translateWindowsBridgeRule(row map[string]any, protocols map[string]string) (map[string]any, bool, error) {
	if row["type"] != "field" {
		return nil, false, invalidWindowsBridge
	}
	tag, ok := row["outboundTag"].(string)
	if !ok {
		return nil, false, invalidWindowsBridge
	}
	if value, exists := row["inboundTag"]; exists {
		tags, err := bridgeStrings(value)
		if err != nil || len(tags) != 1 || tags[0] != "dns-internal" || tag != "proxy" || len(row) != 3 {
			return nil, false, invalidWindowsBridge
		}
		// The new typed DNS transport has a fixed SOCKS detour; it does not
		// traverse TUN route rules and cannot recurse through the DNS hijack.
		return nil, true, nil
	}
	conditions := []any{}
	keys := make([]string, 0, len(row))
	for key := range row {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		value := row[key]
		condition := map[string]any{}
		switch key {
		case "type", "outboundTag":
			continue
		case "domain":
			values, err := bridgeStrings(value)
			if err != nil {
				return nil, false, err
			}
			domains := make([]string, 0, len(values))
			for _, domain := range values {
				if !strings.HasPrefix(domain, "domain:") {
					return nil, false, invalidWindowsBridge
				}
				domain = strings.TrimPrefix(domain, "domain:")
				if domain == "" || len(domain) > 253 || strings.ContainsAny(domain, "\x00\r\n /\\:*?[]") {
					return nil, false, invalidWindowsBridge
				}
				domains = append(domains, domain)
			}
			condition["domain_suffix"] = domains
		case "ip":
			values, err := bridgeStrings(value)
			if err != nil {
				return nil, false, err
			}
			prefixes := make([]string, 0, len(values))
			for _, raw := range values {
				if prefix, err := netip.ParsePrefix(raw); err == nil {
					prefixes = append(prefixes, prefix.Masked().String())
				} else if address, err := netip.ParseAddr(raw); err == nil {
					prefixes = append(prefixes, netip.PrefixFrom(address, address.BitLen()).String())
				} else {
					return nil, false, invalidWindowsBridge
				}
			}
			condition["ip_cidr"] = prefixes
		case "port":
			ports, ok := value.(string)
			if !ok {
				return nil, false, invalidWindowsBridge
			}
			single, ranges, err := bridgePorts(ports)
			if err != nil {
				return nil, false, err
			}
			if len(single) > 0 {
				condition["port"] = single
			}
			if len(ranges) > 0 {
				condition["port_range"] = ranges
			}
		case "process":
			paths, err := bridgeStrings(value)
			if err != nil || len(paths) > 1000 {
				return nil, false, invalidWindowsBridge
			}
			patterns := make([]string, 0, len(paths))
			for _, path := range paths {
				if !validProcessPath(path) {
					return nil, false, invalidWindowsBridge
				}
				// Xray normalizes paths to forward slashes. sing-box compares
				// native Windows paths exactly, so preserve Windows case/slash
				// semantics with a quoted, anchored case-insensitive matcher.
				patterns = append(patterns, "(?i)^"+regexp.QuoteMeta(strings.ReplaceAll(path, "/", `\`))+"$")
			}
			condition["process_path_regex"] = patterns
		case "network":
			text, ok := value.(string)
			if !ok {
				return nil, false, invalidWindowsBridge
			}
			networks := strings.Split(text, ",")
			for _, network := range networks {
				if network != "tcp" && network != "udp" {
					return nil, false, invalidWindowsBridge
				}
			}
			condition["network"] = networks
		default:
			return nil, false, invalidWindowsBridge
		}
		conditions = append(conditions, condition)
	}
	if len(conditions) == 0 {
		return nil, false, invalidWindowsBridge
	}
	result := map[string]any{}
	if len(conditions) == 1 {
		for key, value := range conditions[0].(map[string]any) {
			result[key] = value
		}
	} else {
		result["type"] = "logical"
		result["mode"] = "and"
		result["rules"] = conditions
	}
	switch tag {
	case "proxy":
		result["action"] = "route"
		result["outbound"] = "proxy"
	case "direct":
		if protocols["direct"] == "blackhole" {
			result["action"] = "reject"
		} else {
			result["action"] = "route"
			result["outbound"] = "direct"
		}
	case "block":
		result["action"] = "reject"
	case "dns-out":
		result["action"] = "hijack-dns"
	default:
		return nil, false, invalidWindowsBridge
	}
	return result, false, nil
}

func bridgeSafetyPrefix(rules []any) bool {
	expected := []any{
		map[string]any{"type": "field", "ip": []string{"::/0"}, "outboundTag": "block"},
		map[string]any{"type": "field", "inboundTag": []string{"dns-internal"}, "outboundTag": "proxy"},
		map[string]any{"type": "field", "port": "53", "outboundTag": "dns-out"},
		map[string]any{"type": "field", "ip": []string{"172.29.255.2"}, "port": "853", "outboundTag": "block"},
		map[string]any{"type": "field", "port": "853", "outboundTag": "proxy"},
	}
	left, err := json.Marshal(rules[:5])
	if err != nil {
		return false
	}
	right, _ := json.Marshal(expected)
	return bytes.Equal(left, right)
}

func bridgePorts(value string) ([]int, []string, error) {
	if len(value) == 0 || len(value) > 1024 {
		return nil, nil, invalidWindowsBridge
	}
	ports := []int{}
	ranges := []string{}
	for _, part := range strings.Split(value, ",") {
		ends := strings.Split(part, "-")
		if len(ends) > 2 {
			return nil, nil, invalidWindowsBridge
		}
		first, err := strconv.Atoi(ends[0])
		if err != nil || first < 1 || first > 65535 {
			return nil, nil, invalidWindowsBridge
		}
		if len(ends) == 1 {
			ports = append(ports, first)
			continue
		}
		last, err := strconv.Atoi(ends[1])
		if err != nil || last < first || last > 65535 {
			return nil, nil, invalidWindowsBridge
		}
		ranges = append(ranges, strconv.Itoa(first)+":"+strconv.Itoa(last))
	}
	return ports, ranges, nil
}

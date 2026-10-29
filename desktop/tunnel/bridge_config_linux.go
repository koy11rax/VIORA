package main

import (
	"net/netip"
	"strings"
)

// Linux uses the same validated transport/rule conversion as Windows. Only
// kernel routing controls differ: marked backend sockets and bound direct
// sockets must retain the selected underlay after TUN policy routing starts.
func buildPlatformBridge(config map[string]any, port uint16, user, password string) (map[string]any, map[string]any, error) {
	backend, frontend, err := buildDesktopBridge(config, port, user, password)
	if err != nil {
		return nil, nil, err
	}
	proxy := backend["outbounds"].([]any)[0].(map[string]any)
	stream := proxy["streamSettings"].(map[string]any)
	options := stream["sockopt"].(map[string]any)
	mark, err := bridgeInt(options["mark"])
	if err != nil || mark != protectionMark {
		return nil, nil, invalidWindowsBridge
	}
	interfaceName := options["interface"].(string)
	if len(interfaceName) >= 16 || strings.ContainsAny(interfaceName, "/:\t ") {
		return nil, nil, invalidWindowsBridge
	}
	server := proxy["settings"].(map[string]any)["vnext"].([]any)[0].(map[string]any)
	endpoint, err := netip.ParseAddr(server["address"].(string))
	if err != nil || !endpoint.Is4() || endpoint.IsUnspecified() || endpoint.IsLoopback() || endpoint.IsMulticast() {
		return nil, nil, invalidWindowsBridge
	}
	tun := frontend["inbounds"].([]any)[0].(map[string]any)
	// Excluding the numeric transport peer is the kernel-level backstop against
	// routing Xray's outer connection back into its own frontend. Under strict
	// nft protection only the privileged marked transport can use this route.
	tun["route_exclude_address"] = []string{netip.PrefixFrom(endpoint, 32).String()}
	tun["iproute2_table_index"] = linuxBridgeTable
	tun["iproute2_rule_index"] = linuxBridgeRuleStart
	for _, item := range frontend["outbounds"].([]any) {
		row := item.(map[string]any)
		if row["type"] == "direct" {
			row["routing_mark"] = protectionMark
		}
	}
	// Selection is a security boundary. If the process lookup is not ready or
	// cannot identify a socket, neither the default direct route (only mode) nor
	// the default proxy route (except mode) may silently override that choice.
	processSelection := false
	for _, item := range config["routing"].(map[string]any)["rules"].([]any) {
		if _, exists := item.(map[string]any)["process"]; exists {
			processSelection = true
			break
		}
	}
	if processSelection {
		route := frontend["route"].(map[string]any)
		rules := route["rules"].([]any)
		guarded := make([]any, 0, len(rules)+1)
		inserted := false
		for _, item := range rules {
			guarded = append(guarded, item)
			if !inserted && item.(map[string]any)["action"] == "sniff" {
				guarded = append(guarded, map[string]any{"process_path_regex": []string{"^.+$"}, "invert": true, "action": "reject"})
				inserted = true
			}
		}
		if !inserted {
			return nil, nil, invalidWindowsBridge
		}
		route["rules"] = guarded
		route["find_process"] = true
	}
	return backend, frontend, nil
}

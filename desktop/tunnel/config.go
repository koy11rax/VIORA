package main

import (
	"encoding/json"
	"net"
	"regexp"
	"runtime"
	"strings"
)

// Rebuild the document, copying only supported network fields. File paths, API
// handlers, inbound listeners and arbitrary native core options cannot cross IPC.
func sanitizeConfig(data []byte) (map[string]any, error) {
	var raw map[string]json.RawMessage
	if json.Unmarshal(data, &raw) != nil {
		return nil, invalidConfig
	}
	for key := range raw {
		if key != "log" && key != "dns" && key != "inbounds" && key != "outbounds" && key != "routing" && key != "desktop" {
			return nil, invalidConfig
		}
	}
	var dns struct {
		Servers []string `json:"servers"`
	}
	if json.Unmarshal(raw["dns"], &dns) != nil || len(dns.Servers) != 1 || (dns.Servers[0] != "https://1.1.1.1/dns-query" && net.ParseIP(dns.Servers[0]).To4() == nil) {
		return nil, invalidConfig
	}
	var desktop struct {
		AppMode      string   `json:"appMode"`
		Applications []string `json:"applications"`
		Reconnect    bool     `json:"reconnect"`
		Retries      int      `json:"retries"`
		Strict       bool     `json:"strict"`
	}
	if value, ok := raw["desktop"]; ok {
		if json.Unmarshal(value, &desktop) != nil || desktop.Retries < 1 || desktop.Retries > 5 {
			return nil, invalidConfig
		}
	}
	if desktop.AppMode == "" {
		desktop.AppMode = "all"
	}
	if desktop.AppMode != "all" && desktop.AppMode != "only" && desktop.AppMode != "except" {
		return nil, invalidConfig
	}
	processes := []string{}
	if desktop.AppMode != "all" {
		if len(desktop.Applications) == 0 || len(desktop.Applications) > 1000 {
			return nil, invalidConfig
		}
		for _, id := range desktop.Applications {
			prefix := runtime.GOOS + ":"
			if !strings.HasPrefix(id, prefix) {
				return nil, invalidConfig
			}
			path := strings.TrimPrefix(id, prefix)
			if !validProcessPath(path) {
				return nil, invalidConfig
			}
			processes = append(processes, strings.ReplaceAll(path, "\\", "/"))
		}
	}
	var inbound []struct {
		Protocol string `json:"protocol"`
		Settings struct {
			MTU int `json:"MTU"`
		} `json:"settings"`
	}
	if json.Unmarshal(raw["inbounds"], &inbound) != nil || len(inbound) != 1 || inbound[0].Protocol != "tun" {
		return nil, invalidConfig
	}
	mtu := inbound[0].Settings.MTU
	if mtu != 1280 && mtu != 1420 && mtu != 1500 {
		return nil, invalidConfig
	}
	var outbounds []struct {
		Tag      string `json:"tag"`
		Protocol string `json:"protocol"`
		Settings struct {
			Vnext []struct {
				Address string `json:"address"`
				Port    int    `json:"port"`
				Users   []struct {
					ID         string `json:"id"`
					Encryption string `json:"encryption"`
					Flow       string `json:"flow,omitempty"`
					Level      int    `json:"level"`
				} `json:"users"`
			} `json:"vnext"`
		} `json:"settings"`
		Stream struct {
			Network  string `json:"network"`
			Security string `json:"security"`
			TLS      *struct {
				ServerName  string   `json:"serverName"`
				Fingerprint string   `json:"fingerprint"`
				ALPN        []string `json:"alpn,omitempty"`
			} `json:"tlsSettings,omitempty"`
			Reality *struct {
				ServerName  string `json:"serverName"`
				Fingerprint string `json:"fingerprint"`
				Password    string `json:"password"`
				ShortID     string `json:"shortId"`
				SpiderX     string `json:"spiderX,omitempty"`
			} `json:"realitySettings,omitempty"`
			WS *struct {
				Path    string            `json:"path"`
				Headers map[string]string `json:"headers,omitempty"`
			} `json:"wsSettings,omitempty"`
			XHTTP *struct {
				Path string `json:"path"`
				Mode string `json:"mode"`
				Host string `json:"host,omitempty"`
			} `json:"xhttpSettings,omitempty"`
		} `json:"streamSettings"`
	}
	if json.Unmarshal(raw["outbounds"], &outbounds) != nil || (len(outbounds) != 3 && len(outbounds) != 4) {
		return nil, invalidConfig
	}
	if outbounds[1].Tag != "direct" || outbounds[1].Protocol != "freedom" || outbounds[2].Tag != "block" || outbounds[2].Protocol != "blackhole" {
		return nil, invalidConfig
	}
	if len(outbounds) == 4 && (outbounds[3].Tag != "dns-out" || outbounds[3].Protocol != "dns") {
		return nil, invalidConfig
	}
	p := outbounds[0]
	if p.Tag != "proxy" || p.Protocol != "vless" || len(p.Settings.Vnext) != 1 {
		return nil, invalidConfig
	}
	server := p.Settings.Vnext[0]
	host := regexp.MustCompile(`^[A-Za-z0-9._:-]{1,253}$`)
	if !host.MatchString(server.Address) || server.Port < 1 || server.Port > 65535 || len(server.Users) != 1 {
		return nil, invalidConfig
	}
	user := server.Users[0]
	if !regexp.MustCompile(`^[a-fA-F0-9-]{36}$`).MatchString(user.ID) || user.Encryption != "none" {
		return nil, invalidConfig
	}
	if user.Flow != "" && user.Flow != "xtls-rprx-vision" {
		return nil, invalidConfig
	}
	if p.Stream.Security != "tls" && p.Stream.Security != "reality" {
		return nil, invalidConfig
	}
	if p.Stream.Security == "tls" && (p.Stream.TLS == nil || !host.MatchString(p.Stream.TLS.ServerName)) {
		return nil, invalidConfig
	}
	if p.Stream.Security == "reality" && (p.Stream.Reality == nil || !host.MatchString(p.Stream.Reality.ServerName) || !regexp.MustCompile(`^[A-Za-z0-9_-]{43}$`).MatchString(p.Stream.Reality.Password)) {
		return nil, invalidConfig
	}
	switch p.Stream.Network {
	case "raw":
	case "ws":
		if p.Stream.WS == nil {
			return nil, invalidConfig
		}
	case "xhttp":
		if p.Stream.XHTTP == nil {
			return nil, invalidConfig
		}
	default:
		return nil, invalidConfig
	}
	var routing struct {
		DomainStrategy string `json:"domainStrategy"`
		Rules          []struct {
			Type        string   `json:"type"`
			IP          []string `json:"ip,omitempty"`
			Domain      []string `json:"domain,omitempty"`
			Port        string   `json:"port,omitempty"`
			InboundTag  []string `json:"inboundTag,omitempty"`
			OutboundTag string   `json:"outboundTag"`
		} `json:"rules"`
	}
	if json.Unmarshal(raw["routing"], &routing) != nil || len(routing.Rules) > 300 {
		return nil, invalidConfig
	}
	for _, r := range routing.Rules {
		if r.Type != "field" || (r.OutboundTag != "proxy" && r.OutboundTag != "direct" && r.OutboundTag != "block" && r.OutboundTag != "dns-out") {
			return nil, invalidConfig
		}
		for _, d := range r.Domain {
			if len(d) > 300 || len(d) < 8 || d[:7] != "domain:" {
				return nil, invalidConfig
			}
		}
	}
	routing.DomainStrategy = "IPIfNonMatch"
	rules := []any{
		map[string]any{"type": "field", "ip": []string{"::/0"}, "outboundTag": "block"},
		map[string]any{"type": "field", "inboundTag": []string{"dns-internal"}, "outboundTag": "proxy"},
		map[string]any{"type": "field", "port": "53", "outboundTag": "dns-out"},
		map[string]any{"type": "field", "ip": []string{"172.29.255.2"}, "port": "853", "outboundTag": "block"},
		map[string]any{"type": "field", "port": "853", "outboundTag": "proxy"},
	}
	if desktop.AppMode == "except" {
		rules = append(rules, map[string]any{"type": "field", "process": processes, "outboundTag": "direct"})
	}
	for _, rule := range routing.Rules {
		// DNS policy belongs to the service, before any app/domain exceptions.
		if rule.OutboundTag == "dns-out" || len(rule.InboundTag) != 0 {
			continue
		}
		encoded, _ := json.Marshal(rule)
		var row map[string]any
		_ = json.Unmarshal(encoded, &row)
		if desktop.AppMode == "only" {
			row["process"] = processes
		}
		rules = append(rules, row)
	}
	if desktop.AppMode == "only" {
		rules = append(rules, map[string]any{"type": "field", "process": processes, "outboundTag": "proxy"}, map[string]any{"type": "field", "network": "tcp,udp", "outboundTag": "direct"})
	}
	result := map[string]any{
		"log": map[string]any{"loglevel": "warning"},
		"dns": map[string]any{"servers": dns.Servers, "queryStrategy": "UseIPv4", "tag": "dns-internal"},
		"inbounds": []any{map[string]any{"tag": "tun", "protocol": "tun", "settings": map[string]any{
			"name": "viora0", "desc": "Viora", "mtu": mtu, "userLevel": 8,
			"gateway": []string{"172.29.255.1/30", "fd71:7669:6f72::1/126"}, "dns": []string{"172.29.255.2"},
			"autoSystemRoutingTable": []string{"0.0.0.0/0", "::/0"}, "autoOutboundsInterface": "auto",
		}, "sniffing": map[string]any{"enabled": true, "destOverride": []string{"http", "tls", "quic"}, "routeOnly": true}}},
		"outbounds": []any{p, map[string]any{"tag": "direct", "protocol": "freedom", "settings": map[string]any{}, "streamSettings": map[string]any{"sockopt": map[string]any{"domainStrategy": "UseIPv4"}}}, map[string]any{"tag": "block", "protocol": "blackhole", "settings": map[string]any{}}},
		"routing":   map[string]any{"domainStrategy": routing.DomainStrategy, "rules": rules}, "stats": map[string]any{}, "policy": map[string]any{"system": map[string]any{"statsOutboundUplink": true, "statsOutboundDownlink": true}},
	}
	settings := result["inbounds"].([]any)[0].(map[string]any)["settings"].(map[string]any)
	result["outbounds"] = append(result["outbounds"].([]any), map[string]any{"tag": "dns-out", "protocol": "dns", "settings": map[string]any{"userLevel": 8, "rules": []any{map[string]any{"action": "return", "qType": 28, "rCode": 0}}}})
	applySystemProtection(settings)
	applyPlatformConfig(result)
	return result, nil
}

func validProcessPath(path string) bool {
	if len(path) == 0 || len(path) > 4096 || strings.ContainsAny(path, "\x00\r\n*?\"<>|") || strings.HasSuffix(path, "/") || strings.HasSuffix(path, "\\") {
		return false
	}
	if runtime.GOOS == "windows" {
		return len(path) > 7 && ((path[0] >= 'A' && path[0] <= 'Z') || (path[0] >= 'a' && path[0] <= 'z')) && path[1] == ':' && (path[2] == '/' || path[2] == '\\') && strings.HasSuffix(strings.ToLower(path), ".exe")
	}
	return strings.HasPrefix(path, "/") && !strings.Contains(path, "/../") && !strings.HasSuffix(path, "/..")
}

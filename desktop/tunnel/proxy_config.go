package main

import (
	"encoding/base64"
	"encoding/json"
	"regexp"
	"strings"
	"unicode/utf8"
)

var endpointPattern = regexp.MustCompile(`^[A-Za-z0-9._:-]{1,253}$`)
var proxyUUID = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

type proxyInput struct {
	Tag, Protocol string
	Settings      struct {
		Version int
		Address string
		Port    int
		Vnext   []struct {
			Address string
			Port    int
			Users   []struct {
				ID, Encryption, Flow, Security string
				AlterID                        int `json:"alterId"`
			}
		}
		Servers []struct {
			Address, Password, Method string
			Port                      int
		}
	}
	Stream struct {
		Network, Security string
		TLS               *struct {
			ServerName, Fingerprint string
			ALPN                    []string
			AllowInsecure           bool
		}
		Reality *struct{ ServerName, Fingerprint, Password, ShortID, SpiderX string }
		WS      *struct {
			Path    string
			Headers map[string]string
		}
		XHTTP    *struct{ Path, Mode, Host string }
		Hysteria *struct {
			Version int
			Auth    string
		}
		FinalMask *struct {
			UDP []struct {
				Type     string
				Settings struct{ Password string }
			}
			TCP        []json.RawMessage
			QuicParams json.RawMessage
		}
	} `json:"streamSettings"`
}

// Decode explicit transport fields instead of embedding arbitrary native core
// objects. Imported file paths, callbacks, listeners and socket controls never
// cross the broker boundary; interface/marks belong to the privileged service.
func sanitizeProxy(data []byte) (map[string]any, error) {
	var p proxyInput
	// The structs use named fields where Xray uses a Settings suffix.
	var fields struct {
		Tag, Protocol string
		Settings      json.RawMessage
		Stream        json.RawMessage `json:"streamSettings"`
	}
	if json.Unmarshal(data, &fields) != nil || fields.Tag != "proxy" {
		return nil, invalidConfig
	}
	p.Tag, p.Protocol = fields.Tag, fields.Protocol
	if json.Unmarshal(fields.Settings, &p.Settings) != nil {
		return nil, invalidConfig
	}
	var stream struct {
		Network, Security string
		TLS               json.RawMessage `json:"tlsSettings"`
		Reality           json.RawMessage `json:"realitySettings"`
		WS                json.RawMessage `json:"wsSettings"`
		XHTTP             json.RawMessage `json:"xhttpSettings"`
		Hysteria          json.RawMessage `json:"hysteriaSettings"`
		FinalMask         json.RawMessage `json:"finalmask"`
	}
	if len(fields.Stream) == 0 && p.Protocol == "shadowsocks" {
		// The application intentionally omits transport settings for native
		// Shadowsocks. Supply the only supported application-owned transport;
		// do not require the UI to invent Xray socket/TLS fields.
		stream.Network, stream.Security = "raw", "none"
	} else if json.Unmarshal(fields.Stream, &stream) != nil {
		return nil, invalidConfig
	}
	p.Stream.Network, p.Stream.Security = stream.Network, stream.Security
	for _, field := range []struct {
		data   json.RawMessage
		target any
	}{
		{stream.TLS, &p.Stream.TLS}, {stream.Reality, &p.Stream.Reality}, {stream.WS, &p.Stream.WS},
		{stream.XHTTP, &p.Stream.XHTTP}, {stream.Hysteria, &p.Stream.Hysteria}, {stream.FinalMask, &p.Stream.FinalMask},
	} {
		if len(field.data) != 0 && json.Unmarshal(field.data, field.target) != nil {
			return nil, invalidConfig
		}
	}
	var settings map[string]any
	switch p.Protocol {
	case "vless", "vmess":
		if len(p.Settings.Vnext) != 1 {
			return nil, invalidConfig
		}
		s := p.Settings.Vnext[0]
		if !validProxyEndpoint(s.Address, s.Port) || len(s.Users) != 1 || !proxyUUID.MatchString(s.Users[0].ID) {
			return nil, invalidConfig
		}
		u := s.Users[0]
		user := map[string]any{"id": u.ID, "level": 8}
		if p.Protocol == "vless" {
			if u.Encryption != "none" || (u.Flow != "" && u.Flow != "xtls-rprx-vision") {
				return nil, invalidConfig
			}
			user["encryption"] = "none"
			if u.Flow != "" {
				user["flow"] = u.Flow
			}
		} else {
			if u.AlterID != 0 || !oneOf(u.Security, "auto", "aes-128-gcm", "chacha20-poly1305") {
				return nil, invalidConfig
			}
			user["security"] = u.Security
		}
		settings = map[string]any{"vnext": []any{map[string]any{"address": s.Address, "port": float64(s.Port), "users": []any{user}}}}
	case "trojan", "shadowsocks":
		if len(p.Settings.Servers) != 1 {
			return nil, invalidConfig
		}
		s := p.Settings.Servers[0]
		if !validProxyEndpoint(s.Address, s.Port) || !validProxySecret(s.Password) {
			return nil, invalidConfig
		}
		server := map[string]any{"address": s.Address, "port": float64(s.Port), "password": s.Password, "level": 8}
		if p.Protocol == "shadowsocks" {
			if !validShadowsocksSecret(s.Method, s.Password) {
				return nil, invalidConfig
			}
			server["method"] = s.Method
		}
		settings = map[string]any{"servers": []any{server}}
	case "hysteria":
		if p.Settings.Version != 2 || !validProxyEndpoint(p.Settings.Address, p.Settings.Port) {
			return nil, invalidConfig
		}
		settings = map[string]any{"version": 2, "address": p.Settings.Address, "port": float64(p.Settings.Port)}
	default:
		return nil, invalidConfig
	}
	transport := map[string]any{"network": p.Stream.Network, "security": p.Stream.Security}
	switch p.Stream.Security {
	case "tls":
		t := p.Stream.TLS
		if t == nil || !endpointPattern.MatchString(t.ServerName) || t.AllowInsecure || !validALPN(t.ALPN) || !validFingerprint(t.Fingerprint) {
			return nil, invalidConfig
		}
		transport["tlsSettings"] = map[string]any{"serverName": t.ServerName, "fingerprint": t.Fingerprint, "alpn": t.ALPN, "allowInsecure": false}
	case "reality":
		r := p.Stream.Reality
		if p.Protocol != "vless" || p.Stream.Network != "raw" || r == nil || !endpointPattern.MatchString(r.ServerName) || !regexp.MustCompile(`^[A-Za-z0-9_-]{43}$`).MatchString(r.Password) || !regexp.MustCompile(`^(?:[A-Fa-f0-9]{2}){0,8}$`).MatchString(r.ShortID) || !validFingerprint(r.Fingerprint) || !validProxyText(r.SpiderX, 4096) {
			return nil, invalidConfig
		}
		transport["realitySettings"] = map[string]any{"serverName": r.ServerName, "fingerprint": r.Fingerprint, "password": r.Password, "shortId": r.ShortID, "spiderX": r.SpiderX}
	case "", "none":
		if p.Protocol != "vmess" && p.Protocol != "shadowsocks" {
			return nil, invalidConfig
		}
		transport["security"] = "none"
	default:
		return nil, invalidConfig
	}
	switch p.Stream.Network {
	case "raw":
		if p.Protocol == "hysteria" {
			return nil, invalidConfig
		}
	case "ws":
		w := p.Stream.WS
		if w == nil || p.Protocol == "hysteria" || !validProxyText(w.Path, 4096) || len(w.Headers) > 1 {
			return nil, invalidConfig
		}
		headers := map[string]any{}
		for key, value := range w.Headers {
			if !strings.EqualFold(key, "Host") || !validProxyText(value, 253) || value == "" {
				return nil, invalidConfig
			}
			headers["Host"] = value
		}
		transport["wsSettings"] = map[string]any{"path": w.Path, "headers": headers}
	case "xhttp":
		x := p.Stream.XHTTP
		if x == nil || p.Protocol == "hysteria" || !validProxyText(x.Path, 4096) || !validProxyText(x.Host, 253) || !oneOf(x.Mode, "auto", "packet-up", "stream-up", "stream-one") {
			return nil, invalidConfig
		}
		transport["xhttpSettings"] = map[string]any{"path": x.Path, "mode": x.Mode, "host": x.Host}
	case "hysteria":
		h := p.Stream.Hysteria
		if p.Protocol != "hysteria" || p.Stream.Security != "tls" || h == nil || h.Version != 2 || !validProxySecret(h.Auth) {
			return nil, invalidConfig
		}
		transport["hysteriaSettings"] = map[string]any{"version": 2, "auth": h.Auth}
	default:
		return nil, invalidConfig
	}
	if f := p.Stream.FinalMask; f != nil {
		if p.Protocol != "hysteria" || len(f.UDP) != 1 || len(f.TCP) != 0 || len(f.QuicParams) != 0 || f.UDP[0].Type != "salamander" || !validProxySecret(f.UDP[0].Settings.Password) {
			return nil, invalidConfig
		}
		transport["finalmask"] = map[string]any{"udp": []any{map[string]any{"type": "salamander", "settings": map[string]any{"password": f.UDP[0].Settings.Password}}}}
	}
	return map[string]any{"tag": "proxy", "protocol": p.Protocol, "settings": settings, "streamSettings": transport}, nil
}

func validProxyEndpoint(address string, port int) bool {
	return endpointPattern.MatchString(address) && port > 0 && port <= 65535
}

func validProxyText(value string, maximum int) bool {
	if len(value) > maximum || !utf8.ValidString(value) {
		return false
	}
	for _, char := range value {
		if char < 0x20 || char == 0x7f {
			return false
		}
	}
	return true
}

func validProxySecret(value string) bool { return value != "" && validProxyText(value, 4096) }

func validALPN(values []string) bool {
	if len(values) > 16 {
		return false
	}
	for _, value := range values {
		if value == "" || !validProxyText(value, 64) {
			return false
		}
	}
	return true
}

func validFingerprint(value string) bool {
	return oneOf(value, "", "chrome", "firefox", "safari", "ios", "android", "edge", "360", "qq", "random", "randomized")
}

func oneOf(value string, allowed ...string) bool {
	for _, item := range allowed {
		if value == item {
			return true
		}
	}
	return false
}

func validShadowsocksSecret(method, password string) bool {
	if oneOf(method, "aes-128-gcm", "aes-256-gcm", "chacha20-ietf-poly1305", "chacha20-poly1305") {
		return true
	}
	length := 0
	switch method {
	case "2022-blake3-aes-128-gcm":
		length = 16
	case "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305":
		length = 32
	default:
		return false
	}
	for _, key := range strings.Split(password, ":") {
		decoded, err := base64.StdEncoding.DecodeString(key)
		if err != nil || len(decoded) != length {
			return false
		}
	}
	return true
}

// The service calls this only on rebuilt, validated configs. Keeping endpoint
// selection in one place prevents one protocol accidentally retaining a domain
// after the TUN has replaced system DNS or binding the wrong transport socket.
func proxyEndpoint(proxy map[string]any) (map[string]any, error) {
	settings, ok := proxy["settings"].(map[string]any)
	if !ok {
		return nil, invalidConfig
	}
	protocol, _ := proxy["protocol"].(string)
	if protocol == "hysteria" {
		return settings, nil
	}
	key := "vnext"
	if protocol == "trojan" || protocol == "shadowsocks" {
		key = "servers"
	} else if protocol != "vless" && protocol != "vmess" {
		return nil, invalidConfig
	}
	servers, ok := settings[key].([]any)
	if !ok || len(servers) != 1 {
		return nil, invalidConfig
	}
	server, ok := servers[0].(map[string]any)
	if !ok {
		return nil, invalidConfig
	}
	return server, nil
}

package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"sync"
	"time"
)

const protectionMark = 0x56494f52

var policyMutex sync.Mutex

// Only fixed verbs cross the privileged boundary. The per-platform functions
// never accept user supplied shell, firewall expressions or installation paths.
func protectionCommand(action string) string {
	return protectionCommandWith(action, systemProtection)
}

func protectionCommandWith(action string, protection func(string) (bool, error)) string {
	if action != "enable" && action != "disable" && action != "status" {
		return "ERROR"
	}
	if action != "status" {
		if !policyMutex.TryLock() {
			return "BUSY"
		}
		defer policyMutex.Unlock()
		release, err := policyProcessLock()
		if err != nil {
			return "BUSY"
		}
		defer release()
	}
	on, err := protection(action)
	if err != nil {
		return "ERROR"
	}
	if on {
		return "ON"
	}
	return "OFF"
}

func strictRequested(data []byte) bool {
	var value struct {
		Desktop struct {
			Strict bool `json:"strict"`
		} `json:"desktop"`
	}
	return json.Unmarshal(data, &value) == nil && value.Desktop.Strict
}

func restrictDirect(config map[string]any) {
	// Keep explicit direct exclusions blocked, including Russian-service and
	// process exceptions. No freedom outbound may bypass a strict session.
	out := config["outbounds"].([]any)
	proxyMap(config)
	for i, item := range out {
		row := item.(map[string]any)
		if row["protocol"] == "freedom" {
			out[i] = map[string]any{"tag": row["tag"], "protocol": "blackhole", "settings": map[string]any{}}
		}
	}
	markProxy(config)
}

// Resolve only the validated VPN endpoint, never arbitrary app DNS, through
// a fixed HTTPS bootstrap resolver. This avoids requiring cleartext system DNS
// after a reboot with protection already armed. No credentials leave the PC.
func proxyMap(config map[string]any) map[string]any {
	out := config["outbounds"].([]any)
	if row, ok := out[0].(map[string]any); ok {
		return row
	}
	encoded, _ := json.Marshal(out[0])
	var row map[string]any
	_ = json.Unmarshal(encoded, &row)
	out[0] = row
	return row
}

func resolveProtectedEndpoint(config map[string]any) error {
	outbound := proxyMap(config)
	server := outbound["settings"].(map[string]any)["vnext"].([]any)[0].(map[string]any)
	host := server["address"].(string)
	if ip := net.ParseIP(host); ip != nil {
		if ip.To4() == nil {
			return errors.New("IPv4 endpoint required")
		}
		return nil
	}
	dialer := &net.Dialer{Timeout: 8 * time.Second, Control: bootstrapSocket}
	transport := &http.Transport{Proxy: nil, DialContext: dialer.DialContext, ForceAttemptHTTP2: true}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 10 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return errors.New("redirect forbidden") }}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, "GET", "https://1.1.1.1/dns-query?type=A&name="+url.QueryEscape(host), nil)
	if err != nil {
		return err
	}
	request.Header.Set("Accept", "application/dns-json")
	reply, err := client.Do(request)
	if err != nil {
		return err
	}
	defer reply.Body.Close()
	if reply.StatusCode != 200 {
		return errors.New("bootstrap failed")
	}
	var record struct {
		Status int
		Answer []struct {
			Type int
			Data string
		}
	}
	if json.NewDecoder(io.LimitReader(reply.Body, 32768)).Decode(&record) != nil || record.Status != 0 {
		return errors.New("invalid DNS response")
	}
	for _, answer := range record.Answer {
		if answer.Type == 1 {
			if ip := net.ParseIP(answer.Data).To4(); ip != nil {
				server["address"] = ip.String()
				stream := outbound["streamSettings"].(map[string]any)
				if ws, ok := stream["wsSettings"].(map[string]any); ok {
					headers, ok := ws["headers"].(map[string]any)
					if !ok {
						headers = map[string]any{}
						ws["headers"] = headers
					}
					if _, exists := headers["Host"]; !exists {
						headers["Host"] = host
					}
				}
				if xhttp, ok := stream["xhttpSettings"].(map[string]any); ok {
					if value, _ := xhttp["host"].(string); value == "" {
						xhttp["host"] = host
					}
				}
				return nil
			}
		}
	}
	return errors.New("no endpoint IPv4")
}

func protectionCLI() bool {
	if len(os.Args) != 3 || os.Args[1] != "--protection" {
		return false
	}
	// Windows uses authenticated broker IPC; Linux is mediated by pkexec.
	if !protectionAdministrator() {
		os.Exit(2)
	}
	result := "ERROR"
	if os.Args[2] == "recover" {
		// Administrator-only emergency/uninstall path, even if a VPN session or
		// crashed GUI still holds the policy lock. Never exposed through broker IPC.
		on, err := systemProtection("disable")
		if err == nil && !on {
			result = "OFF"
		}
	} else {
		result = protectionCommand(os.Args[2])
	}
	fmt.Println(result)
	if result != "ON" && result != "OFF" {
		os.Exit(3)
	}
	return true
}

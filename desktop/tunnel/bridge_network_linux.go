package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const linuxBridgeTable = 22089
const linuxBridgeRuleStart = 19000
const linuxBridgeRuleEnd = 19020

type linuxPolicyRule struct {
	Priority    int             `json:"priority"`
	Table       json.RawMessage `json:"table"`
	Goto        int             `json:"goto"`
	Action      string          `json:"action"`
	Not         json.RawMessage `json:"not"`
	Nop         json.RawMessage `json:"nop"`
	Dport       json.RawMessage `json:"dport"`
	Suppress    *int            `json:"suppress_prefixlength"`
	SuppressLen *int            `json:"suppress_prefixlen"`
	Source      string          `json:"src"`
}

// All commands use fixed system binaries and argument arrays, never a shell.
// A timeout and bounded output also apply when a local system service hangs.
func linuxBridgeCommand(ctx context.Context, tool string, args ...string) ([]byte, error) {
	path, err := trustedLinuxTool(tool)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, path, args...)
	cmd.WaitDelay = 200 * time.Millisecond
	cmd.Env = cleanEnvironment()
	var output limitedBridgeOutput
	cmd.Stdout = &output
	cmd.Stderr = io.Discard
	err = cmd.Run()
	return output.Bytes(), err
}

type limitedBridgeOutput struct{ bytes.Buffer }

func (b *limitedBridgeOutput) Write(data []byte) (int, error) {
	if b.Len()+len(data) > 1024*1024 {
		return 0, errors.New("system metadata too large")
	}
	return b.Buffer.Write(data)
}

func trustedLinuxTool(name string) (string, error) {
	if name != "ip" && name != "resolvectl" {
		return "", errors.New("unknown system tool")
	}
	for _, directory := range []string{"/usr/sbin", "/usr/bin"} {
		path, err := filepath.EvalSymlinks(filepath.Join(directory, name))
		if err != nil || !strings.HasPrefix(path, "/usr/") {
			continue
		}
		info, err := os.Lstat(path)
		if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0111 == 0 {
			continue
		}
		trusted := true
		for check := path; check != "/"; check = filepath.Dir(check) {
			row, err := os.Lstat(check)
			if err != nil {
				trusted = false
				break
			}
			owner, ok := row.Sys().(*syscall.Stat_t)
			if !ok || owner.Uid != 0 || row.Mode().Perm()&0022 != 0 || row.Mode()&os.ModeSymlink != 0 {
				trusted = false
				break
			}
		}
		if trusted {
			return path, nil
		}
	}
	return "", errors.New("trusted system tool unavailable")
}

func parseLinuxPolicy(data []byte) ([]linuxPolicyRule, error) {
	var rules []linuxPolicyRule
	if len(data) > 1024*1024 || json.Unmarshal(data, &rules) != nil || len(rules) > 65536 {
		return nil, errors.New("invalid policy metadata")
	}
	return rules, nil
}

func linuxPolicyTable(value json.RawMessage) bool {
	return string(value) == strconv.Itoa(linuxBridgeTable) || string(value) == `"`+strconv.Itoa(linuxBridgeTable)+`"`
}

func linuxPolicyReserved(rule linuxPolicyRule) bool {
	return rule.Priority >= linuxBridgeRuleStart && rule.Priority <= linuxBridgeRuleEnd
}

func linuxPolicyOwned(rule linuxPolicyRule) bool {
	// Only the lease's table lookup, internal goto and final NOP are ours.
	return linuxPolicyReserved(rule) && (linuxPolicyTable(rule.Table) || (rule.Goto >= linuxBridgeRuleStart && rule.Goto <= linuxBridgeRuleEnd) || linuxNoopRule(rule) || linuxMainLookupRule(rule))
}

// iproute2 versions emit flag presence either as null or true; absence and
// explicit false must remain different. Never use a plain bool for these flags.
func linuxPolicyFlag(value json.RawMessage) bool {
	return string(value) == "null" || string(value) == "true"
}

func linuxNoopRule(rule linuxPolicyRule) bool {
	action := rule.Action == "nop" && len(rule.Nop) == 0
	flag := linuxPolicyFlag(rule.Nop) && (rule.Action == "" || rule.Action == "nop")
	return rule.Priority == linuxBridgeRuleStart+10 && (rule.Source == "" || rule.Source == "all") && (action || flag)
}

func linuxMainLookupRule(rule linuxPolicyRule) bool {
	main := string(rule.Table) == "254" || string(rule.Table) == `"main"` || string(rule.Table) == `"254"`
	dnsPort := string(rule.Dport) == "53" || string(rule.Dport) == `"53"` || string(rule.Dport) == `"53-53"`
	suppress := rule.Suppress
	if suppress == nil {
		suppress = rule.SuppressLen
	}
	consistent := rule.Suppress == nil || rule.SuppressLen == nil || *rule.Suppress == *rule.SuppressLen
	// IPv4 has a preceding TUN-subnet lookup; IPv6 does not. Their MAIN
	// suppression rules therefore occupy offsets +2 and +1 respectively.
	priority := rule.Priority == linuxBridgeRuleStart+1 || rule.Priority == linuxBridgeRuleStart+2
	return priority && main && linuxPolicyFlag(rule.Not) && dnsPort && consistent && suppress != nil && *suppress == 0 && (rule.Source == "" || rule.Source == "all")
}

func prepareBridgeNetwork(ctx context.Context) (func() error, error) {
	if _, err := trustedLinuxTool("resolvectl"); err != nil {
		return nil, err
	}
	for _, family := range []string{"-4", "-6"} {
		data, err := linuxBridgeCommand(ctx, "ip", family, "-N", "-j", "rule", "show")
		if err != nil {
			return nil, err
		}
		rules, err := parseLinuxPolicy(data)
		if err != nil {
			return nil, err
		}
		for _, rule := range rules {
			if linuxPolicyReserved(rule) || linuxPolicyTable(rule.Table) {
				return nil, errors.New("routing policy lease conflict")
			}
		}
		data, err = linuxBridgeCommand(ctx, "ip", family, "-N", "-j", "route", "show", "table", "all")
		if err != nil {
			return nil, err
		}
		var routes []struct {
			Table json.RawMessage `json:"table"`
		}
		if json.Unmarshal(data, &routes) != nil {
			return nil, errors.New("invalid routes metadata")
		}
		for _, route := range routes {
			if linuxPolicyTable(route.Table) {
				return nil, errors.New("routing table lease conflict")
			}
		}
	}
	var once sync.Once
	var cleanupError error
	return func() error {
		once.Do(func() { cleanupError = cleanupBridgeNetwork() })
		return cleanupError
	}, nil
}

func cleanupBridgeNetwork() error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	// Reverting a non-existent link fails harmlessly after sing-box cleanup.
	_, _ = linuxBridgeCommand(ctx, "resolvectl", "revert", "viora0")
	for _, family := range []string{"-4", "-6"} {
		data, err := linuxBridgeCommand(ctx, "ip", family, "-N", "-j", "rule", "show")
		if err != nil {
			return err
		}
		rules, err := parseLinuxPolicy(data)
		if err != nil {
			return err
		}
		removed := 0
		for _, rule := range rules {
			if !linuxPolicyOwned(rule) {
				continue
			}
			removed++
			if removed > 64 {
				return errors.New("unexpected number of owned policies")
			}
			args := []string{family, "rule", "del", "priority", strconv.Itoa(rule.Priority)}
			if linuxPolicyTable(rule.Table) {
				args = append(args, "table", strconv.Itoa(linuxBridgeTable))
			}
			if rule.Goto > 0 {
				args = append(args, "goto", strconv.Itoa(rule.Goto))
			}
			if linuxMainLookupRule(rule) {
				args = append(args, "not", "dport", "53", "suppress_prefixlength", "0", "table", "254")
			}
			if linuxNoopRule(rule) {
				args = append(args, "type", "nop")
			}
			if _, err = linuxBridgeCommand(ctx, "ip", args...); err != nil {
				return err
			}
		}
		data, err = linuxBridgeCommand(ctx, "ip", family, "-N", "-j", "rule", "show")
		if err != nil {
			return err
		}
		rules, err = parseLinuxPolicy(data)
		if err != nil {
			return err
		}
		for _, rule := range rules {
			if linuxPolicyOwned(rule) {
				return errors.New("owned policy remains")
			}
		}
	}
	return nil
}

func readyBridgeDNS(ctx context.Context) error {
	if err := readyBridgeDNSWith(ctx, linuxBridgeCommand); err != nil {
		return err
	}
	return probeBridgeDNSWith(ctx, lookupBridgeDNS)
}

const bridgeDNSProbeName = "viora-connectivity.invalid."

func lookupBridgeDNS(ctx context.Context, network, name string) ([]net.IP, error) {
	resolver := net.Resolver{
		PreferGo: true, StrictErrors: true,
		Dial: func(ctx context.Context, network, _ string) (net.Conn, error) {
			if network != "udp" && network != "tcp" {
				return nil, errors.New("invalid DNS transport")
			}
			// Deliberately no bypass mark or physical binding: this must cross
			// the real TUN/frontend DNS path, even if applications cache all DNS.
			dialer := net.Dialer{Timeout: 500 * time.Millisecond}
			return dialer.DialContext(ctx, network+"4", "172.29.255.2:53")
		},
	}
	return resolver.LookupIP(ctx, network, name)
}

func probeBridgeDNSWith(parent context.Context, lookup func(context.Context, string, string) ([]net.IP, error)) error {
	ctx, cancel := context.WithTimeout(parent, 5*time.Second)
	defer cancel()
	if ctx.Err() != nil {
		return ctx.Err()
	}
	addresses, err := lookup(ctx, "ip4", bridgeDNSProbeName)
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if err == nil && len(addresses) > 0 {
		return nil
	}
	var dnsError *net.DNSError
	// Reserved .invalid normally yields NXDOMAIN. That is a real DNS reply,
	// unlike a local timeout, failed socket or an unresponsive proxy backend.
	if errors.As(err, &dnsError) && dnsError.IsNotFound && !dnsError.IsTimeout && !dnsError.IsTemporary {
		return nil
	}
	return errors.New("VPN DNS path did not answer")
}

func readyBridgeDNSWith(ctx context.Context, run func(context.Context, string, ...string) ([]byte, error)) error {
	// The TUN can be up before systemd-resolved has registered its DBus link.
	// Retry real failed operations/state checks, retaining the supervisor's
	// shared startup deadline; a private caller without a deadline is bounded too.
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	ticker := time.NewTicker(50 * time.Millisecond)
	defer ticker.Stop()
	for {
		if ctx.Err() != nil {
			return errors.New("system DNS readiness cancelled or timed out")
		}
		if applyBridgeDNSOnce(ctx, run) == nil && ctx.Err() == nil {
			return nil
		}
		select {
		case <-ctx.Done():
			return errors.New("system DNS readiness cancelled or timed out")
		case <-ticker.C:
		}
	}
}

func applyBridgeDNSOnce(ctx context.Context, run func(context.Context, string, ...string) ([]byte, error)) error {
	for _, args := range [][]string{{"domain", "viora0", "~."}, {"default-route", "viora0", "yes"}, {"dns", "viora0", "172.29.255.2"}} {
		if _, err := run(ctx, "resolvectl", args...); err != nil {
			return errors.New("system DNS setup failed")
		}
	}
	for _, expected := range []struct{ command, value string }{{"dns", "172.29.255.2"}, {"domain", "~."}} {
		data, err := run(ctx, "resolvectl", expected.command, "viora0")
		if err != nil {
			return errors.New("system DNS state unavailable")
		}
		line := strings.TrimSpace(string(data))
		_, values, ok := strings.Cut(line, ":")
		if !ok || strings.TrimSpace(values) != expected.value {
			return errors.New("system DNS state mismatch")
		}
	}
	return nil
}

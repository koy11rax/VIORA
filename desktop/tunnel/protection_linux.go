package main

import (
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"strings"
	"syscall"
)

const policyDirectory = "/var/lib/viora"
const policyMarker = policyDirectory + "/protection.enabled"
const nftBinary = "/usr/sbin/nft"

func protectionAdministrator() bool { return os.Geteuid() == 0 }
func policyProcessLock() (func(), error) {
	f, err := os.OpenFile("/run/viora-policy.lock", os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		return nil, err
	}
	if err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		return nil, err
	}
	return func() { syscall.Flock(int(f.Fd()), syscall.LOCK_UN); f.Close() }, nil
}
func nftPath() string {
	// Arch places nft in /usr/bin; Fedora/Debian use /usr/sbin.
	if _, err := os.Stat(nftBinary); err == nil {
		return nftBinary
	}
	return "/usr/bin/nft"
}
func policyPresent() (bool, error) {
	cmd := exec.Command(nftPath(), "list", "tables")
	cmd.Env = cleanEnvironment()
	output, err := cmd.Output()
	if err != nil {
		return false, err
	}
	for _, line := range strings.Split(string(output), "\n") {
		if strings.TrimSpace(line) == "table inet viora_lockdown" {
			return true, nil
		}
	}
	return false, nil
}
func nftPolicy(replace bool) string {
	prefix := ""
	if replace {
		prefix = "delete table inet viora_lockdown\n"
	}
	return prefix + `table inet viora_lockdown {
 chain output {
  type filter hook output priority -10; policy drop;
  oifname "lo" accept
  oifname "viora0" accept
  meta mark 0x56494f52 accept
  meta nfproto ipv4 udp sport 68 udp dport 67 accept
 }
 chain forward {
  type filter hook forward priority -10; policy drop;
 }
}
`
}
func systemProtection(action string) (bool, error) {
	present, err := policyPresent()
	if err != nil {
		return false, err
	}
	_, markerErr := os.Lstat(policyMarker)
	armed := markerErr == nil
	if markerErr != nil && !os.IsNotExist(markerErr) {
		return false, markerErr
	}
	if action == "status" {
		if present != armed {
			return false, errors.New("persistent policy mismatch")
		}
		if present {
			cmd := exec.Command(nftPath(), "-j", "list", "table", "inet", "viora_lockdown")
			cmd.Env = cleanEnvironment()
			data, err := cmd.Output()
			if err != nil {
				return false, err
			}
			if !validPolicyState(data) {
				return false, errors.New("altered firewall policy")
			}
		}
		return present, nil
	}
	if action == "disable" {
		if present {
			cmd := exec.Command(nftPath(), "delete", "table", "inet", "viora_lockdown")
			cmd.Env = cleanEnvironment()
			if err = cmd.Run(); err != nil {
				return true, err
			}
		}
		err = os.Remove(policyMarker)
		if os.IsNotExist(err) {
			err = nil
		}
		return false, err
	}
	if action != "enable" {
		return false, errors.New("invalid verb")
	}
	if err = os.MkdirAll(policyDirectory, 0755); err != nil {
		return false, err
	}
	info, err := os.Lstat(policyDirectory)
	if err != nil {
		return false, err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != 0 || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm()&0022 != 0 {
		return false, errors.New("untrusted state directory")
	}
	// Persist intent before committing the atomic nft transaction. A partial
	// failure is reported as an error, never falsely as enabled/disabled.
	tmp, err := os.CreateTemp(policyDirectory, "policy-")
	if err != nil {
		return false, err
	}
	name := tmp.Name()
	defer os.Remove(name)
	if _, err = tmp.WriteString("viora-lockdown-v1\n"); err == nil {
		err = tmp.Sync()
	}
	tmp.Close()
	if err != nil {
		return false, err
	}
	if err = os.Chmod(name, 0644); err != nil {
		return false, err
	}
	if err = os.Rename(name, policyMarker); err != nil {
		return false, err
	}
	directory, err := os.Open(policyDirectory)
	if err != nil {
		return false, err
	}
	err = directory.Sync()
	directory.Close()
	if err != nil {
		return false, err
	}
	cmd := exec.Command(nftPath(), "-f", "-")
	cmd.Env = cleanEnvironment()
	cmd.Stdin = strings.NewReader(nftPolicy(present))
	if err = cmd.Run(); err != nil {
		return false, err
	}
	return true, nil
}

func validPolicyState(data []byte) bool {
	var document struct {
		Nftables []map[string]json.RawMessage `json:"nftables"`
	}
	if json.Unmarshal(data, &document) != nil {
		return false
	}
	chains := map[string]bool{}
	rules := 0
	for _, item := range document.Nftables {
		if raw, ok := item["chain"]; ok {
			var chain struct {
				Name, Table, Family, Type, Hook, Policy string
				Prio                                    int
			}
			if json.Unmarshal(raw, &chain) != nil || chain.Table != "viora_lockdown" || chain.Family != "inet" || chain.Type != "filter" || chain.Policy != "drop" || chain.Prio != -10 {
				return false
			}
			if chain.Name != chain.Hook || (chain.Name != "output" && chain.Name != "forward") {
				return false
			}
			chains[chain.Name] = true
		}
		if raw, ok := item["rule"]; ok {
			var rule struct{ Chain, Table, Family string }
			if json.Unmarshal(raw, &rule) != nil || rule.Chain != "output" || rule.Table != "viora_lockdown" || rule.Family != "inet" {
				return false
			}
			rules++
		}
	}
	return chains["output"] && chains["forward"] && rules == 4
}
func markProxy(config map[string]any) {
	proxy := proxyMap(config)
	stream := proxy["streamSettings"].(map[string]any)
	stream["sockopt"] = map[string]any{"mark": protectionMark}
}
func bootstrapSocket(_, _ string, raw syscall.RawConn) error {
	var err error
	control := raw.Control(func(fd uintptr) {
		err = syscall.SetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_MARK, protectionMark)
	})
	if control != nil {
		return control
	}
	return err
}
func restoreProtection() bool {
	if len(os.Args) != 2 || os.Args[1] != "--restore-protection" {
		return false
	}
	if !protectionAdministrator() {
		os.Exit(2)
	}
	if _, err := os.Lstat(policyMarker); os.IsNotExist(err) {
		return true
	}
	if protectionCommand("enable") != "ON" {
		os.Exit(3)
	}
	return true
}
func refreshProtection() error { return nil }

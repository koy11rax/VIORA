package main

import (
	"errors"
	"golang.org/x/sys/windows"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
)

var firewallSHA string

func protectionAdministrator() bool      { return windows.GetCurrentProcessToken().IsElevated() }
func policyProcessLock() (func(), error) { return func() {}, nil }
func systemProtection(action string) (bool, error) {
	exe, err := os.Executable()
	if err != nil {
		return false, err
	}
	dir := filepath.Dir(exe)
	path := filepath.Join(dir, "viora_firewall.exe")
	if !trustedInstall(dir) || !verifiedFile(path, firewallSHA) {
		return false, errors.New("firewall integrity")
	}
	cmd := exec.Command(path, action)
	cmd.Env = cleanEnvironment()
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	output, err := cmd.Output()
	if err != nil {
		return false, err
	}
	switch strings.TrimSpace(string(output)) {
	case "ON":
		return true, nil
	case "OFF":
		return false, nil
	}
	return false, errors.New("invalid firewall status")
}
func markProxy(map[string]any)                              {}
func bootstrapSocket(string, string, syscall.RawConn) error { return nil }
func restoreProtection() bool                               { return false }
func refreshProtection() error                              { _, err := systemProtection("enable"); return err }

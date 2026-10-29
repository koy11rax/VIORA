package main

import (
	"errors"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
)

func openControl() (io.ReadCloser, io.Writer, error) {
	if len(os.Args) != 1 || os.Geteuid() != 0 {
		return nil, nil, errors.New("elevation required")
	}
	return os.Stdin, os.Stdout, nil
}
func coreName() string                              { return "xray" }
func applySystemProtection(settings map[string]any) { settings["autoSystemDnsToGateway"] = true }
func applyPlatformConfig(config map[string]any) {
	// Follow the administrator-managed OS trust store, as Windows does. Current
	// Xray otherwise defaults to its bundled roots on Linux and silently ignores
	// system-installed CAs. This native policy cannot be selected by imported IPC.
	proxy := proxyMap(config)
	stream := proxy["streamSettings"].(map[string]any)
	if stream["security"] == "tls" {
		stream["tlsSettings"].(map[string]any)["useSystemCA"] = true
	}
}
func trustedInstall(directory string) bool {
	if directory != "/usr/lib/viora" {
		return false
	}
	for _, path := range []string{"/usr", "/usr/lib", directory, filepath.Join(directory, "core"), filepath.Join(directory, "core", "xray")} {
		info, err := os.Lstat(path)
		if err != nil || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm()&0022 != 0 {
			return false
		}
		stat, ok := info.Sys().(*syscall.Stat_t)
		if !ok || stat.Uid != 0 {
			return false
		}
	}
	return true
}
func verifiedDriver(string, string) bool { return true }
func platformEnvironment() []string {
	return []string{"PATH=/usr/sbin:/usr/bin:/sbin:/bin", "LANG=C", "HOME=/root"}
}
func configureChild(cmd *exec.Cmd) error {
	cmd.SysProcAttr = &syscall.SysProcAttr{Pdeathsig: syscall.SIGTERM}
	return nil
}
func containChild(cmd *exec.Cmd) (func(), error) { return func() {}, nil }
func interruptChild(cmd *exec.Cmd)               { _ = cmd.Process.Signal(syscall.SIGTERM) }
func tunReady() bool {
	iface, err := net.InterfaceByName("viora0")
	return err == nil && iface.Flags&net.FlagUp != 0
}

func platformService() bool { return false }

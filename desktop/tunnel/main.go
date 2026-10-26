// The privileged helper owns only a validated Xray TUN session. No shell commands,
// imported config files, persistent credentials or general-purpose execution API.
package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"
)

var coreSHA, driverSHA, frontendSHA string // pinned at build time, never supplied by the client

type status struct {
	State    string `json:"state"`
	Duration string `json:"duration"`
	Upload   int64  `json:"upload"`
	Download int64  `json:"download"`
	Code     string `json:"code,omitempty"`
	Lockdown bool   `json:"lockdown"`
}

func verifiedFile(path, expected string) bool {
	if len(expected) != 64 {
		return false
	}
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	defer f.Close()
	h := sha256.New()
	if _, err = io.Copy(h, f); err != nil {
		return false
	}
	return hex.EncodeToString(h.Sum(nil)) == expected
}

func run(input io.ReadCloser, output io.Writer) {
	runWithProtection(input, output, systemProtection)
}

func runWithProtection(input io.ReadCloser, output io.Writer, protection func(string) (bool, error)) {
	defer input.Close()
	diagnostics := newSessionDiagnostics(time.Now())
	defer func() { writeSessionDiagnostics(diagnostics.snapshot(time.Now())) }()
	encoder := json.NewEncoder(output)
	var emitMutex sync.Mutex
	protected := false
	emit := func(s status) {
		emitMutex.Lock()
		defer emitMutex.Unlock()
		diagnostics.setStatus(s.State, s.Code)
		s.Lockdown = protected
		_ = encoder.Encode(s)
	}
	fail := func(code string) { emit(status{State: "FAILED", Code: code}) }
	reader := bufio.NewReaderSize(input, 128*1024)
	line, err := reader.ReadSlice('\n')
	if timed, ok := input.(interface{ SetReadDeadline(time.Time) error }); ok {
		timed.SetReadDeadline(time.Time{})
	}
	if err != nil || len(line) > 120*1024 {
		fail("invalid_config")
		return
	}
	strict := strictRequested(line)
	config, err := sanitizeConfig(line)
	clear(line)
	if err != nil {
		fail("invalid_config")
		return
	}
	bootstrapContext, cancelBootstrap := context.WithCancel(context.Background())
	defer cancelBootstrap()
	stop := make(chan struct{})
	go func() {
		// After the validated profile, any further input or EOF cancels startup
		// as well as an active session. One producer owns this channel.
		_, _ = reader.ReadSlice('\n')
		close(stop)
		cancelBootstrap()
	}()
	cancelled := func() bool {
		select {
		case <-stop:
			emit(status{State: "DISCONNECTED"})
			return true
		default:
			return false
		}
	}
	if cancelled() {
		return
	}
	exe, err := os.Executable()
	if err != nil {
		fail("missing_core")
		return
	}
	directory := filepath.Dir(exe)
	core := filepath.Join(directory, "core", coreName())
	if !trustedInstall(directory) || !verifiedFile(core, coreSHA) || !verifiedDriver(directory, driverSHA) {
		fail("core_integrity")
		return
	}
	// Only a private local metrics listener is added, never a public control API.
	if !policyMutex.TryLock() {
		fail("policy_busy")
		return
	}
	defer policyMutex.Unlock()
	release, err := policyProcessLock()
	if err != nil {
		fail("policy_busy")
		return
	}
	defer release()
	protected, err = protection("status")
	if err != nil {
		fail("protection_failed")
		return
	}
	if strict && !protected {
		protected, err = protection("enable")
		if err != nil || !protected {
			fail("protection_failed")
			return
		}
	}
	if protected {
		restrictDirect(config)
	}
	if cancelled() {
		return
	}
	if prepareEndpoint(bootstrapContext, config, protected) != nil {
		if cancelled() {
			return
		}
		fail("endpoint_dns_failed")
		return
	}
	if cancelled() {
		return
	}
	if runPlatformBridge(bootstrapContext, config, directory, protected, emit, diagnostics) {
		return
	}
	port, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		fail("metrics_failed")
		return
	}
	address := port.Addr().String()
	port.Close()
	config["metrics"] = map[string]any{"listen": address}
	encoded, _ := json.Marshal(config)
	cmd := exec.Command(core, "run", "-format", "json", "-config", "stdin:")
	cmd.Dir = filepath.Dir(core)
	cmd.Env = cleanEnvironment()
	cmd.Stdin = bytes.NewReader(encoded)
	logs, err := cmd.StdoutPipe()
	if err != nil {
		fail("start_failed")
		return
	}
	defer logs.Close()
	if writer, ok := cmd.Stdout.(io.Closer); ok {
		defer writer.Close()
	}
	cmd.Stderr = cmd.Stdout
	if err = configureChild(cmd); err != nil {
		fail("start_failed")
		return
	}
	if cancelled() {
		return
	}
	if err = cmd.Start(); err != nil {
		fail("start_failed")
		return
	}
	cleanup, err := containChild(cmd)
	if err != nil {
		cmd.Process.Kill()
		cmd.Wait()
		fail("containment_failed")
		return
	}
	defer cleanup()
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	started := make(chan struct{}, 1)
	logsDone := make(chan struct{})
	go func() {
		defer close(logsDone)
		captureCoreDiagnostics(logs, diagnostics, started)
	}()
	defer func() {
		select {
		case <-logsDone:
		case <-time.After(time.Second):
			diagnostics.record(diagLogReadError)
		}
	}()
	interrupt := func() {
		interruptChild(cmd)
		select {
		case <-done:
		case <-time.After(3 * time.Second):
			cmd.Process.Kill()
			<-done
		}
	}
	emit(status{State: "CONNECTING"})
	timeout := time.NewTimer(20 * time.Second)
	defer timeout.Stop()
	select {
	case <-stop:
		interrupt()
		emit(status{State: "DISCONNECTED"})
		return
	case <-done:
		fail("core_start_failed")
		return
	case <-timeout.C:
		interrupt()
		fail("core_start_timeout")
		return
	case <-started:
	}
	if !tunReady() {
		interrupt()
		fail("tun_not_ready")
		return
	}
	connected := time.Now()
	if protected && refreshProtection() != nil {
		interrupt()
		fail("protection_failed")
		return
	}
	client := &http.Client{Timeout: 800 * time.Millisecond, Transport: &http.Transport{Proxy: nil}}
	defer client.CloseIdleConnections()
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	emit(status{State: "CONNECTED", Duration: "00:00:00"})
	var uploaded, downloaded int64
	for {
		select {
		case <-stop:
			interrupt()
			emit(status{State: "DISCONNECTED"})
			return
		case <-done:
			fail("core_exited")
			return
		case <-ticker.C:
			elapsed := int(time.Since(connected).Seconds())
			s := status{State: "CONNECTED", Duration: fmt.Sprintf("%02d:%02d:%02d", elapsed/3600, elapsed/60%60, elapsed%60)}
			response, err := client.Get("http://" + address + "/debug/vars")
			if err == nil {
				var v struct {
					Stats struct {
						Outbound map[string]struct {
							Uplink   int64 `json:"uplink"`
							Downlink int64 `json:"downlink"`
						} `json:"outbound"`
					} `json:"stats"`
				}
				if json.NewDecoder(io.LimitReader(response.Body, 128*1024)).Decode(&v) == nil {
					uploaded = max(uploaded, v.Stats.Outbound["proxy"].Uplink)
					downloaded = max(downloaded, v.Stats.Outbound["proxy"].Downlink)
				}
				response.Body.Close()
			}
			s.Upload, s.Download = uploaded, downloaded
			emit(s)
		}
	}
}

func main() {
	if installerCLI() || protectionCLI() || restoreProtection() {
		return
	}
	if platformService() {
		return
	}
	if len(os.Args) == 2 && os.Args[1] == "--version" {
		fmt.Println("Viora tunnel 0.8.2")
		return
	}
	input, output, err := openControl()
	if err != nil {
		os.Exit(2)
	}
	run(input, output)
}

func cleanEnvironment() []string {
	// Do not inherit XRAY_LOCATION_*, TLS key logs, imported config paths or a user PATH.
	return platformEnvironment()
}

var invalidConfig = errors.New("invalid tunnel config")

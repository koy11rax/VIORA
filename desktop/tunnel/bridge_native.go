package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Desktop has two narrowly scoped engines: sing-box owns the system TUN,
// while Xray owns only authenticated local SOCKS and the existing VLESS transport.
// Neither configuration is written to disk or passed in a process argument.
func runPlatformBridge(parent context.Context, config map[string]any, directory string, protected bool, emit func(status), diagnostics *sessionDiagnostics) bool {
	fail := func(code string) { emit(bridgeFailureStatus(parent.Err() != nil, code)) }
	if parent.Err() != nil {
		emit(status{State: "DISCONNECTED"})
		return true
	}
	if !verifiedFrontend(directory) {
		fail("frontend_integrity")
		return true
	}
	checkNetwork, err := bindDesktopOutbound(config)
	if err != nil || checkNetwork == nil {
		fail("outbound_interface_unavailable")
		return true
	}
	cleanupNetwork, err := prepareBridgeNetwork(parent)
	if err != nil {
		fail("routing_setup_failed")
		return true
	}
	defer cleanupNetwork()
	reservation, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		fail("bridge_config_failed")
		return true
	}
	proxyPort := uint16(reservation.Addr().(*net.TCPAddr).Port)
	metricsReservation, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		reservation.Close()
		fail("metrics_failed")
		return true
	}
	metricsAddress := metricsReservation.Addr().String()
	metricsPort := uint16(metricsReservation.Addr().(*net.TCPAddr).Port)
	secret := make([]byte, 48)
	if _, err = rand.Read(secret); err != nil {
		reservation.Close()
		metricsReservation.Close()
		fail("bridge_config_failed")
		return true
	}
	username, password := hex.EncodeToString(secret[:16]), hex.EncodeToString(secret[16:])
	clear(secret)
	backend, frontend, err := buildPlatformBridge(config, proxyPort, username, password)
	if err != nil {
		reservation.Close()
		metricsReservation.Close()
		fail("bridge_config_failed")
		return true
	}
	backend["metrics"] = map[string]any{"listen": metricsAddress}
	// Startup readiness is a fixed engine message. Raw info lines are classified
	// in memory and discarded, just like Xray's existing bounded diagnostics.
	frontend["log"] = map[string]any{"level": "info", "timestamp": false, "disabled": false}
	backendBytes, backendErr := json.Marshal(backend)
	frontendBytes, frontendErr := json.Marshal(frontend)
	defer clear(backendBytes)
	defer clear(frontendBytes)
	reservation.Close()
	metricsReservation.Close()
	if backendErr != nil || frontendErr != nil {
		fail("bridge_config_failed")
		return true
	}
	ctx, cancel := context.WithCancel(parent)
	defer cancel()
	runtimeFailure := make(chan string, 1)
	noteFailure := func(code string) {
		select {
		case runtimeFailure <- code:
		default:
		}
	}
	start := func(lifetime context.Context, stage string) (bridgeProcess, error) {
		if !checkNetwork() {
			noteFailure("network_changed")
			return nil, errors.New("underlay changed")
		}
		if stage == "backend" {
			cmd := exec.Command(filepath.Join(directory, "core", coreName()), "run", "-format", "json", "-config", "stdin:")
			return startBridgeChild(cmd, backendBytes, stage, diagnostics, func(ready context.Context, child *desktopBridgeProcess) error {
				address := net.JoinHostPort("127.0.0.1", fmt.Sprint(proxyPort))
				for {
					if ownedBridgeListener(uint32(child.cmd.Process.Pid), proxyPort) && ownedBridgeListener(uint32(child.cmd.Process.Pid), metricsPort) {
						if authenticateBridgeProxy(ready, address, username, password) == nil && ownedBridgeListener(uint32(child.cmd.Process.Pid), proxyPort) {
							return nil
						}
					}
					select {
					case <-ready.Done():
						return ready.Err()
					case <-child.Done():
						return errors.New("backend exited")
					case <-time.After(50 * time.Millisecond):
					}
				}
			})
		}
		cmd := exec.Command(frontendPath(directory), "run", "-c", "stdin")
		return startBridgeChild(cmd, frontendBytes, stage, diagnostics, func(ready context.Context, _ *desktopBridgeProcess) error {
			if !checkNetwork() {
				noteFailure("network_changed")
				return errors.New("underlay changed")
			}
			if !tunReady() {
				return errors.New("system TUN not ready")
			}
			if err := readyBridgeDNS(ready); err != nil {
				noteFailure("system_dns_failed")
				return err
			}
			return nil
		})
	}
	monitorDone := make(chan struct{})
	monitorStarted := false
	emit(status{State: "CONNECTING"})
	code := superviseBridge(ctx, start, func() string {
		if !checkNetwork() {
			return "network_changed"
		}
		if protected && refreshProtection() != nil {
			return "protection_failed"
		}
		emit(status{State: "CONNECTED", Duration: "00:00:00"})
		monitorStarted = true
		go func() {
			defer close(monitorDone)
			monitorBridge(ctx, metricsAddress, checkNetwork, emit, func() {
				noteFailure("network_changed")
				cancel()
			})
		}()
		return ""
	}, func() {
		cancel()
		if monitorStarted {
			<-monitorDone
		}
	})
	cancel()
	if monitorStarted {
		<-monitorDone
	}
	// Both children have now stopped. A forced frontend exit may leave routing
	// policy behind; clear only this session's reserved kernel policy lease.
	cleanupError := cleanupNetwork()
	runtimeCode := ""
	select {
	case reported := <-runtimeFailure:
		runtimeCode = reported
	default:
	}
	code = bridgeSessionResult(parent.Err() != nil, code, runtimeCode, cleanupError)
	if code == "" {
		emit(status{State: "DISCONNECTED"})
	} else {
		fail(code)
	}
	return true
}

type desktopBridgeProcess struct {
	cmd      *exec.Cmd
	done     chan struct{}
	marked   chan struct{}
	logsDone chan struct{}
	logs     io.ReadCloser
	cleanup  func()
	stopOnce sync.Once
	ready    func(context.Context, *desktopBridgeProcess) error
}

func startBridgeChild(cmd *exec.Cmd, config []byte, stage string, diagnostics *sessionDiagnostics, ready func(context.Context, *desktopBridgeProcess) error) (*desktopBridgeProcess, error) {
	cmd.Dir = filepath.Dir(cmd.Path)
	cmd.Env = cleanEnvironment()
	cmd.Stdin = bytes.NewReader(config) // EOF is required by sing-box's stdin loader.
	logs, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	closePipes := func() {
		logs.Close()
		if writer, ok := cmd.Stdout.(io.Closer); ok {
			writer.Close()
		}
	}
	cmd.Stderr = cmd.Stdout
	if err = configureChild(cmd); err != nil {
		closePipes()
		return nil, err
	}
	if err = cmd.Start(); err != nil {
		closePipes()
		return nil, err
	}
	cleanup, err := containChild(cmd)
	if err != nil {
		cmd.Process.Kill()
		cmd.Wait()
		closePipes()
		return nil, err
	}
	child := &desktopBridgeProcess{cmd: cmd, done: make(chan struct{}), marked: make(chan struct{}), logsDone: make(chan struct{}), logs: logs, cleanup: cleanup, ready: ready}
	go func() {
		defer close(child.logsDone)
		marked := false
		scan := bufio.NewScanner(logs)
		scan.Buffer(make([]byte, 4096), maxDiagnosticLineBytes)
		for scan.Scan() {
			line := scan.Text()
			diagnostics.observe(line)
			if !marked && ((stage == "backend" && strings.Contains(line, "Xray") && strings.Contains(line, "started")) ||
				(stage == "frontend" && strings.Contains(line, "sing-box started ("))) {
				marked = true
				close(child.marked)
			}
		}
		if scan.Err() != nil {
			diagnostics.record(diagLogReadError)
			_, _ = io.Copy(io.Discard, logs)
		}
	}()
	go func() {
		_ = cmd.Wait()
		close(child.done)
	}()
	return child, nil
}

func (child *desktopBridgeProcess) Done() <-chan struct{} { return child.done }

func (child *desktopBridgeProcess) Ready(ctx context.Context) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-child.done:
		return errors.New("engine exited")
	case <-child.marked:
	}
	return child.ready(ctx, child)
}

func (child *desktopBridgeProcess) Stop() {
	child.stopOnce.Do(func() {
		defer child.cleanup()
		select {
		case <-child.done:
		default:
			interruptChild(child.cmd)
			select {
			case <-child.done:
			case <-time.After(3 * time.Second):
				_ = child.cmd.Process.Kill()
				<-child.done
			}
		}
		child.logs.Close()
		<-child.logsDone
	})
}

func authenticateBridgeProxy(ctx context.Context, address, user, password string) error {
	dialer := net.Dialer{Timeout: 300 * time.Millisecond}
	conn, err := dialer.DialContext(ctx, "tcp4", address)
	if err != nil {
		return err
	}
	defer conn.Close()
	deadline := time.Now().Add(300 * time.Millisecond)
	if parent, ok := ctx.Deadline(); ok && parent.Before(deadline) {
		deadline = parent
	}
	conn.SetDeadline(deadline)
	return authenticateBridgeStream(conn, user, password)
}

func authenticateBridgeStream(conn net.Conn, user, password string) error {
	var err error
	if len(user) < 1 || len(user) > 255 || len(password) < 16 || len(password) > 255 {
		return errors.New("invalid local credentials")
	}
	if _, err = conn.Write([]byte{5, 1, 2}); err != nil {
		return err
	}
	var reply [2]byte
	if _, err = io.ReadFull(conn, reply[:]); err != nil || reply != [2]byte{5, 2} {
		return errors.New("SOCKS authentication unavailable")
	}
	request := append([]byte{1, byte(len(user))}, []byte(user)...)
	request = append(request, byte(len(password)))
	request = append(request, []byte(password)...)
	defer clear(request)
	if _, err = conn.Write(request); err != nil {
		return err
	}
	if _, err = io.ReadFull(conn, reply[:]); err != nil || reply != [2]byte{1, 0} {
		return errors.New("SOCKS authentication rejected")
	}
	return nil
}

func monitorBridge(ctx context.Context, address string, networkOK func() bool, emit func(status), networkLost func()) {
	client := bridgeMetricsClient()
	defer client.CloseIdleConnections()
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	started := time.Now()
	var uploaded, downloaded int64
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if !networkOK() {
				networkLost()
				return
			}
			request, _ := http.NewRequestWithContext(ctx, "GET", "http://"+address+"/debug/vars", nil)
			response, err := client.Do(request)
			if err == nil {
				var v struct {
					Stats struct {
						Outbound map[string]struct{ Uplink, Downlink int64 } `json:"outbound"`
					} `json:"stats"`
				}
				if json.NewDecoder(io.LimitReader(response.Body, 128*1024)).Decode(&v) == nil {
					uploaded = max(uploaded, v.Stats.Outbound["proxy"].Uplink)
					downloaded = max(downloaded, v.Stats.Outbound["proxy"].Downlink)
				}
				response.Body.Close()
			}
			if ctx.Err() != nil {
				return
			}
			elapsed := int(time.Since(started).Seconds())
			emit(status{State: "CONNECTED", Duration: fmt.Sprintf("%02d:%02d:%02d", elapsed/3600, elapsed/60%60, elapsed%60), Upload: uploaded, Download: downloaded})
		}
	}
}

func bridgeMetricsClient() *http.Client {
	return &http.Client{
		Timeout: 800 * time.Millisecond, Transport: &http.Transport{Proxy: nil},
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
}

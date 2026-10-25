package main

import (
	"bufio"
	"io"
	"regexp"
	"strings"
	"sync"
	"time"
)

const diagnosticLimit uint32 = 65535
const maxDiagnosticLineBytes = 128 * 1024
const maxDiagnosticReportBytes = 8 * 1024

type diagnosticClass int

const (
	diagCoreStarted diagnosticClass = iota
	diagTunReady
	diagInboundTCP
	diagInboundUDP
	diagOutboundAttempt
	diagDNSError
	diagTLSError
	diagWebSocketError
	diagRouteError
	diagTunError
	diagCoreError
	diagTimeoutError
	diagCertificateError
	diagConnectionRefused
	diagConnectionReset
	diagHTTPRejected
	diagLogReadError
	diagUnclassified
	diagnosticClassCount
)

var diagnosticNames = [diagnosticClassCount]string{
	"core_started", "tun_ready", "inbound_tcp", "inbound_udp", "outbound_attempt",
	"dns_error", "tls_error", "websocket_error", "route_error", "tun_error",
	"core_error", "timeout_error", "certificate_error", "connection_refused", "connection_reset",
	"transport_http_rejected", "log_read_error", "unclassified",
}

var diagnosticHTTPRejected = regexp.MustCompile(`\b(?:http/[0-9.]+|status(?:\s+code)?|response(?:\s+status)?)[:= ]+(?:400|401|403|404|405|429|5[0-9]{2})\b`)

// Raw core lines exist only while being classified. Neither the session nor its
// report retains line text, destinations, profile names, UUIDs or executable paths.
type sessionDiagnostics struct {
	mu      sync.Mutex
	started time.Time
	lines   uint32
	counts  [diagnosticClassCount]uint32
	state   string
	code    string
}

type diagnosticsReport struct {
	Schema      int               `json:"schema"`
	StartedUTC  string            `json:"started_utc"`
	FinishedUTC string            `json:"finished_utc"`
	FinalState  string            `json:"final_state"`
	FinalCode   string            `json:"final_code,omitempty"`
	Lines       uint32            `json:"lines"`
	Counts      map[string]uint32 `json:"counts"`
}

func newSessionDiagnostics(now time.Time) *sessionDiagnostics {
	return &sessionDiagnostics{started: now, state: "UNKNOWN"}
}

func incrementDiagnostic(value *uint32) {
	if *value < diagnosticLimit {
		*value++
	}
}

func (d *sessionDiagnostics) record(class diagnosticClass) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if class >= 0 && class < diagnosticClassCount {
		incrementDiagnostic(&d.counts[class])
	}
}

func containsAny(line string, terms ...string) bool {
	for _, term := range terms {
		if strings.Contains(line, term) {
			return true
		}
	}
	return false
}

func (d *sessionDiagnostics) observe(raw string) {
	if len(raw) > maxDiagnosticLineBytes {
		raw = raw[:maxDiagnosticLineBytes]
	}
	line := strings.ToLower(raw)
	d.mu.Lock()
	defer d.mu.Unlock()
	incrementDiagnostic(&d.lines)
	matched := false
	add := func(class diagnosticClass) {
		incrementDiagnostic(&d.counts[class])
		matched = true
	}
	if strings.Contains(line, "xray") && strings.Contains(line, "started") {
		add(diagCoreStarted)
	}
	if strings.Contains(line, "proxy/tun:") && strings.Contains(line, " up") {
		add(diagTunReady)
	}
	if strings.Contains(line, "processing from") {
		if strings.Contains(line, " to tcp:") {
			add(diagInboundTCP)
		}
		if strings.Contains(line, " to udp:") {
			add(diagInboundUDP)
		}
	}
	if containsAny(line, "tunneling request", "creating connection to", "transport/internet: dialing") {
		add(diagOutboundAttempt)
	}
	reset := containsAny(line, "connection reset", "reset by peer", "broken pipe", "forcibly closed", " eof") || strings.TrimSpace(line) == "eof"
	certificate := containsAny(line, "x509:", "bad certificate", "failed to verify certificate", "certificate signed by unknown", "certificate has expired")
	httpRejected := strings.Contains(line, "bad handshake") || diagnosticHTTPRejected.MatchString(line)
	if containsAny(line, "failed", "failure", "error", "timeout", "timed out", "deadline exceeded", "refused", "unreachable", "unable to") || reset || certificate || httpRejected {
		add(diagCoreError)
		if containsAny(line, "timeout", "timed out", "deadline") {
			add(diagTimeoutError)
		}
		if containsAny(line, "x509", "certificate") {
			add(diagCertificateError)
		}
		if strings.Contains(line, "refused") {
			add(diagConnectionRefused)
		}
		if reset {
			add(diagConnectionReset)
		}
		if httpRejected {
			add(diagHTTPRejected)
		}
		if containsAny(line, "dns", "lookup") {
			add(diagDNSError)
		}
		if containsAny(line, "tls", "x509", "certificate", "reality") {
			add(diagTLSError)
		}
		if strings.Contains(line, "websocket") {
			add(diagWebSocketError)
		}
		if containsAny(line, "route", "interface", "socket options", "iface not found") {
			add(diagRouteError)
		}
		if containsAny(line, "proxy/tun", "wintun", "gvisor") {
			add(diagTunError)
		}
	}
	if !matched {
		add(diagUnclassified)
	}
}

func (d *sessionDiagnostics) setStatus(state, code string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	switch state {
	case "CONNECTING", "CONNECTED", "DISCONNECTED", "FAILED":
		d.state = state
	default:
		d.state = "UNKNOWN"
	}
	switch code {
	case "", "invalid_config", "missing_core", "core_integrity", "policy_busy",
		"protection_failed", "endpoint_dns_failed", "metrics_failed", "start_failed",
		"containment_failed", "core_start_failed", "core_start_timeout", "tun_not_ready", "core_exited":
		d.code = code
	default:
		d.code = "unclassified"
	}
}

func (d *sessionDiagnostics) snapshot(now time.Time) diagnosticsReport {
	d.mu.Lock()
	defer d.mu.Unlock()
	counts := make(map[string]uint32, diagnosticClassCount)
	for class, name := range diagnosticNames {
		counts[name] = d.counts[class]
	}
	return diagnosticsReport{Schema: 1, StartedUTC: d.started.UTC().Format(time.RFC3339),
		FinishedUTC: now.UTC().Format(time.RFC3339), FinalState: d.state, FinalCode: d.code,
		Lines: d.lines, Counts: counts}
}

func captureCoreDiagnostics(logs io.Reader, diagnostics *sessionDiagnostics, started chan<- struct{}) {
	scan := bufio.NewScanner(logs)
	scan.Buffer(make([]byte, 4096), maxDiagnosticLineBytes)
	for scan.Scan() {
		line := scan.Text()
		diagnostics.observe(line)
		if strings.Contains(line, "started") && strings.Contains(line, "Xray") {
			select {
			case started <- struct{}{}:
			default:
			}
		}
	}
	if scan.Err() != nil {
		diagnostics.record(diagLogReadError)
		// A too-long line must not leave the child's stdout pipe full. Drain
		// without retaining or classifying any subsequent raw data.
		_, _ = io.Copy(io.Discard, logs)
	}
}

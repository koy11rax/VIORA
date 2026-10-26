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
	diagDialAttempt
	diagOutboundEstablished
	diagTargetForward
	diagWebSocketDialError
	diagWebSocketClose
	diagnosticClassCount
)

var diagnosticNames = [diagnosticClassCount]string{
	"core_started", "tun_ready", "inbound_tcp", "inbound_udp", "outbound_attempt",
	"dns_error", "tls_error", "websocket_error", "route_error", "tun_error",
	"core_error", "timeout_error", "certificate_error", "connection_refused", "connection_reset",
	"transport_http_rejected", "log_read_error", "unclassified",
	"dial_attempt", "outbound_established", "target_forward", "ws_dial_error", "ws_close",
}

var diagnosticHTTPRejected = regexp.MustCompile(`\b(?:http/[0-9.]+|status(?:\s+code)?|response(?:\s+status)?)[:= ]+(?:400|401|403|404|405|429|5[0-9]{2})\b`)
var diagnosticEnvelope = regexp.MustCompile(`^\s*(?:[0-9]{4}[/-][0-9]{2}[/-][0-9]{2}\s+[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?\s+)?(?:\[(debug|info|warning|warn|error)\]\s*)?(?:\[[0-9]{1,10}\]\s*)?`)
var diagnosticFailure = regexp.MustCompile(`\b(?:failed|falied|failure|error|timeout|refused|unreachable)\b`)
var diagnosticWSClose = regexp.MustCompile(`(?:^|websocket:\s*)close\s+(1000|1001|1002|1003|1005|1006|1007|1008|1009|1010|1011|1012|1013|1015)\b`)

// Only these socket codes can become report keys. OS message templates are
// loaded once on Windows; raw log/error text is never retained in the session.
var diagnosticSocketCodes = [...]uint32{10013, 10049, 10051, 10053, 10054, 10055, 10060, 10061, 10065}

// Raw core lines exist only while being classified. Neither the session nor its
// report retains line text, destinations, profile names, UUIDs or executable paths.
type sessionDiagnostics struct {
	mu      sync.Mutex
	started time.Time
	lines   uint32
	counts  [diagnosticClassCount]uint32
	sockets [len(diagnosticSocketCodes)]uint32
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
	SocketCodes map[uint32]uint32 `json:"socket_codes"`
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

// Strip logger metadata before looking for failure words. In particular,
// "common/errors" is a caller name, not evidence that a warning is an error.
func diagnosticMessage(line string) (caller, message string, errorLevel bool) {
	location := diagnosticEnvelope.FindStringSubmatchIndex(line)
	if location != nil {
		if location[2] >= 0 {
			errorLevel = line[location[2]:location[3]] == "error"
		}
		line = line[location[1]:]
	}
	if end := strings.Index(line, ": "); end > 0 && end <= 128 {
		valid := true
		for _, char := range line[:end] {
			if !(char >= 'a' && char <= 'z' || char >= '0' && char <= '9' || char == '/' || char == '_' || char == '-') {
				valid = false
				break
			}
		}
		if valid {
			return line[:end], line[end+2:], errorLevel
		}
	}
	return "", line, errorLevel
}

func (d *sessionDiagnostics) observe(raw string) {
	if len(raw) > maxDiagnosticLineBytes {
		raw = raw[:maxDiagnosticLineBytes]
	}
	line := strings.ToLower(raw)
	caller, message, errorLevel := diagnosticMessage(line)
	context := caller + ": " + message
	dialAttempt := containsAny(message, "creating connection to", "dialing to")
	targetForward := strings.HasPrefix(message, "tunneling request to ")
	// Deferred WebSocket early-data connections can log a target before the
	// network handshake. Only an explicit transport event proves establishment.
	established := caller == "transport/internet/websocket" && message == "websocket connection established"
	phaseEvent := dialAttempt || targetForward || established
	var socketCode uint32
	if !phaseEvent {
		socketCode = diagnosticSocketCode(strings.Join(strings.Fields(message), " "))
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	incrementDiagnostic(&d.lines)
	matched := false
	add := func(class diagnosticClass) {
		incrementDiagnostic(&d.counts[class])
		matched = true
	}
	if strings.Contains(message, "xray") && strings.Contains(message, "started") {
		add(diagCoreStarted)
	}
	if caller == "proxy/tun" && strings.Contains(message, " up") {
		add(diagTunReady)
	}
	if strings.Contains(message, "processing from") {
		if strings.Contains(message, " to tcp:") {
			add(diagInboundTCP)
		}
		if strings.Contains(message, " to udp:") {
			add(diagInboundUDP)
		}
	}
	if dialAttempt || targetForward {
		add(diagOutboundAttempt)
	}
	if dialAttempt {
		add(diagDialAttempt)
	}
	if targetForward {
		add(diagTargetForward)
	}
	if established {
		add(diagOutboundEstablished)
	}
	websocket := strings.Contains(context, "websocket")
	closeCode := diagnosticWSClose.FindStringSubmatch(message)
	wsClose := websocket && (closeCode != nil || strings.Contains(message, "close sent"))
	if wsClose {
		add(diagWebSocketClose)
	}
	abnormalClose := closeCode != nil && closeCode[1] != "1000" && closeCode[1] != "1001"
	reset := containsAny(message, "connection reset", "reset by peer", "broken pipe", "forcibly closed", " eof") || strings.TrimSpace(message) == "eof" || socketCode == 10053 || socketCode == 10054
	certificate := containsAny(message, "x509:", "bad certificate", "failed to verify certificate", "certificate signed by unknown", "certificate has expired") || caller == "x509"
	httpRejected := strings.Contains(message, "bad handshake") || diagnosticHTTPRejected.MatchString(message)
	failure := errorLevel || diagnosticFailure.MatchString(message) || containsAny(message, "timed out", "deadline exceeded", "unable to") || reset || certificate || httpRejected || abnormalClose || socketCode != 0
	// An endpoint named "error.example" must not turn a successful dial/target
	// announcement into an error. Actual Error-level logs remain errors.
	if phaseEvent && !errorLevel {
		failure = false
	}
	if failure {
		add(diagCoreError)
		if containsAny(message, "timeout", "timed out", "deadline") || socketCode == 10060 {
			add(diagTimeoutError)
		}
		if certificate {
			add(diagCertificateError)
		}
		if strings.Contains(message, "refused") || socketCode == 10061 {
			add(diagConnectionRefused)
		}
		if reset {
			add(diagConnectionReset)
		}
		if httpRejected {
			add(diagHTTPRejected)
		}
		if containsAny(context, "dns", "lookup") {
			add(diagDNSError)
		}
		if containsAny(context, "tls", "x509", "certificate", "reality") {
			add(diagTLSError)
		}
		if websocket {
			add(diagWebSocketError)
			if !wsClose && strings.Contains(message, "failed to dial") {
				add(diagWebSocketDialError)
			}
		}
		if containsAny(context, "route", "interface", "socket options", "iface not found") || socketCode == 10013 || socketCode == 10049 || socketCode == 10051 || socketCode == 10065 {
			add(diagRouteError)
		}
		if containsAny(context, "proxy/tun", "wintun", "gvisor") {
			add(diagTunError)
		}
		for index, code := range diagnosticSocketCodes {
			if code == socketCode {
				incrementDiagnostic(&d.sockets[index])
				break
			}
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
		"containment_failed", "core_start_failed", "core_start_timeout", "tun_not_ready", "core_exited",
		"outbound_interface_unavailable", "network_changed", "frontend_integrity", "bridge_config_failed",
		"backend_start_failed", "backend_not_ready", "frontend_start_failed", "frontend_not_ready", "backend_exited", "frontend_exited":
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
	sockets := make(map[uint32]uint32, len(diagnosticSocketCodes))
	for index, code := range diagnosticSocketCodes {
		sockets[code] = d.sockets[index]
	}
	return diagnosticsReport{Schema: 1, StartedUTC: d.started.UTC().Format(time.RFC3339),
		FinishedUTC: now.UTC().Format(time.RFC3339), FinalState: d.state, FinalCode: d.code,
		Lines: d.lines, Counts: counts, SocketCodes: sockets}
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

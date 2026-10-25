package main

import (
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestSessionDiagnosticsFixedVocabularyAndRedaction(t *testing.T) {
	startedAt := time.Date(2026, 10, 25, 12, 0, 0, 0, time.FixedZone("fixture", 3*3600))
	d := newSessionDiagnostics(startedAt)
	secret := "https://private.example.invalid/sub/fixture-token"
	profile := "00000000-0000-4000-8000-000000000001"
	lines := []string{
		"Xray fixture started",
		"proxy/tun: viora0 up",
		"proxy/tun: processing from tcp:192.0.2.10:1234 to tcp:198.51.100.5:443",
		"proxy/tun: processing from udp:192.0.2.10:1234 to udp:198.51.100.5:53",
		"transport/internet/websocket: creating connection to tcp:198.51.100.5:443",
		"app/dns: failed to lookup " + secret,
		"transport/internet/websocket: failed to dial > tls: failed to verify certificate " + profile,
		"proxy/tun: unable to set interface C:/fixture/private-app.exe",
		"unknown line containing " + secret + " " + profile,
	}
	started := make(chan struct{}, 1)
	captureCoreDiagnostics(strings.NewReader(strings.Join(lines, "\n")+"\n"), d, started)
	if len(started) != 1 {
		t.Fatal("core startup acknowledgement was lost")
	}
	d.setStatus("FAILED", secret)
	report := d.snapshot(startedAt.Add(time.Minute))
	encoded, err := json.Marshal(report)
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{secret, profile, "192.0.2.10", "198.51.100.5", "private-app.exe", "unknown line"} {
		if strings.Contains(string(encoded), forbidden) {
			t.Fatalf("diagnostic output retained a raw line fragment")
		}
	}
	want := map[string]uint32{
		"core_started": 1, "tun_ready": 1, "inbound_tcp": 1, "inbound_udp": 1,
		"outbound_attempt": 1, "dns_error": 1, "tls_error": 1, "websocket_error": 1,
		"route_error": 1, "tun_error": 1, "core_error": 3, "log_read_error": 0, "unclassified": 1,
		"timeout_error": 0, "certificate_error": 1, "connection_refused": 0,
		"connection_reset": 0, "transport_http_rejected": 0,
	}
	if len(report.Counts) != len(want) {
		t.Fatal("diagnostic vocabulary changed or grew from raw input")
	}
	for category, count := range want {
		if report.Counts[category] != count {
			t.Errorf("category %s: got %d want %d", category, report.Counts[category], count)
		}
	}
	if report.Schema != 1 || report.FinalState != "FAILED" || report.FinalCode != "unclassified" || report.Lines != uint32(len(lines)) {
		t.Fatal("unexpected report metadata")
	}
	if report.StartedUTC != "2026-10-25T09:00:00Z" || report.FinishedUTC != "2026-10-25T09:01:00Z" {
		t.Fatal("timestamps are not normalized to UTC")
	}
	if len(encoded) > maxDiagnosticReportBytes {
		t.Fatal("diagnostic report exceeded its storage bound")
	}
}

func TestSessionDiagnosticsCountersStayBoundedAndSnapshotsAreDetached(t *testing.T) {
	d := newSessionDiagnostics(time.Unix(0, 0))
	for i := uint32(0); i < diagnosticLimit+20; i++ {
		d.observe("app/dns: query failed: fixture-private-name")
	}
	report := d.snapshot(time.Unix(1, 0))
	if report.Lines != diagnosticLimit || report.Counts["dns_error"] != diagnosticLimit || report.Counts["core_error"] != diagnosticLimit {
		t.Fatal("diagnostic counters overflowed or exceeded their fixed cap")
	}
	report.Counts["dns_error"] = 0
	report.Counts["untrusted-key"] = 100
	next := d.snapshot(time.Unix(2, 0))
	if next.Counts["dns_error"] != diagnosticLimit || len(next.Counts) != int(diagnosticClassCount) {
		t.Fatal("a report mutation changed the live diagnostics")
	}
}

type diagnosticBrokenReader struct{}

func (diagnosticBrokenReader) Read([]byte) (int, error) {
	return 0, errors.New("untrusted-reader-location-and-token")
}

func TestSessionDiagnosticsReaderFailuresAndOversizedLinesAreFixedCountsOnly(t *testing.T) {
	for _, oversized := range []bool{false, true} {
		d := newSessionDiagnostics(time.Unix(0, 0))
		if oversized {
			input := strings.NewReader(strings.Repeat("secret", maxDiagnosticLineBytes))
			captureCoreDiagnostics(input, d, nil)
			if input.Len() != 0 {
				t.Fatal("an oversized line left unread bytes in the child pipe")
			}
		} else {
			captureCoreDiagnostics(diagnosticBrokenReader{}, d, nil)
		}
		report := d.snapshot(time.Unix(1, 0))
		encoded, err := json.Marshal(report)
		if err != nil || report.Counts["log_read_error"] != 1 || report.Lines != 0 {
			t.Fatal("reader failure was not represented by one fixed count")
		}
		if strings.Contains(string(encoded), "secret") || strings.Contains(string(encoded), "untrusted-reader") {
			t.Fatal("reader diagnostics retained raw input or error text")
		}
	}
}

func TestSessionDiagnosticsSeparatesFixedTransportFailureCauses(t *testing.T) {
	for _, fixture := range []struct{ line, category string }{
		{"websocket: failed to dial: i/o timeout", "timeout_error"},
		{"websocket: failed to dial: context deadline exceeded", "timeout_error"},
		{"websocket: failed to dial: EOF", "connection_reset"},
		{"websocket: failed to dial: connection reset by peer", "connection_reset"},
		{"websocket: failed to dial: connection refused", "connection_refused"},
		{"tls: x509: certificate signed by unknown authority", "certificate_error"},
		{"websocket: bad handshake", "transport_http_rejected"},
	} {
		t.Run(fixture.category+fixture.line, func(t *testing.T) {
			d := newSessionDiagnostics(time.Unix(0, 0))
			d.observe(fixture.line)
			report := d.snapshot(time.Unix(1, 0))
			if report.Counts[fixture.category] != 1 || report.Counts["core_error"] != 1 {
				t.Fatal("transport failure cause was lost")
			}
		})
	}
	for _, status := range []string{"400", "401", "403", "404", "405", "429", "500", "502", "599"} {
		d := newSessionDiagnostics(time.Unix(0, 0))
		d.observe("websocket: HTTP/1.1 " + status + " fixture-private-response")
		if d.snapshot(time.Unix(1, 0)).Counts["transport_http_rejected"] != 1 {
			t.Fatalf("fixed HTTP rejection category missed status %s", status)
		}
	}
	d := newSessionDiagnostics(time.Unix(0, 0))
	d.observe("websocket: HTTP/1.1 200 fixture-private-response")
	if d.snapshot(time.Unix(1, 0)).Counts["transport_http_rejected"] != 0 {
		t.Fatal("successful HTTP response was treated as rejected")
	}
}

func TestSessionDiagnosticsConcurrentObservationsAndStatusValidation(t *testing.T) {
	d := newSessionDiagnostics(time.Unix(0, 0))
	var workers sync.WaitGroup
	for range 4 {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for range 1000 {
				d.observe("transport/internet: dialing to fixture-private-endpoint")
				_ = d.snapshot(time.Unix(1, 0))
			}
		}()
	}
	workers.Wait()
	d.setStatus("DISCONNECTED", "")
	report := d.snapshot(time.Unix(2, 0))
	if report.Lines != 4000 || report.Counts["outbound_attempt"] != 4000 || report.FinalState != "DISCONNECTED" || report.FinalCode != "" {
		t.Fatal("concurrent observations or valid final status were lost")
	}
	d.setStatus("arbitrary-private-state", "arbitrary-private-code")
	report = d.snapshot(time.Unix(3, 0))
	if report.FinalState != "UNKNOWN" || report.FinalCode != "unclassified" {
		t.Fatal("untrusted status text crossed the diagnostic allowlist")
	}
}

func TestSessionDiagnosticsConfigUsesInfoWithoutAccessOrDNSQueryLogs(t *testing.T) {
	data, _ := json.Marshal(fixture())
	config, err := sanitizeConfig(data)
	if err != nil {
		t.Fatal(err)
	}
	log, ok := config["log"].(map[string]any)
	if !ok || len(log) != 3 || log["loglevel"] != "info" || log["access"] != "none" || log["dnsLog"] != false {
		t.Fatal("diagnostic build must explicitly disable access/query logs")
	}
}

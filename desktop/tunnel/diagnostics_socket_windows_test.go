package main

import (
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/sys/windows"
)

func TestDiagnosticSocketCodesMatchInstalledWindowsLanguages(t *testing.T) {
	checked := 0
	for _, code := range diagnosticSocketCodes {
		for _, language := range []uint32{0, 0x0409, 0x0419} {
			buffer := make([]uint16, 2048)
			n, err := windows.FormatMessage(windows.FORMAT_MESSAGE_FROM_SYSTEM|windows.FORMAT_MESSAGE_IGNORE_INSERTS,
				0, code, language, buffer, nil)
			if err != nil || n == 0 {
				continue // Optional language packs are not installed on every host.
			}
			message := windows.UTF16ToString(buffer[:n])
			d := newSessionDiagnostics(time.Unix(0, 0))
			d.observe("[Info] transport/internet/websocket: failed to dial to fixture > dial tcp: connectex: " + message)
			report := d.snapshot(time.Unix(1, 0))
			if report.SocketCodes[code] != 1 || report.Counts["core_error"] != 1 || report.Counts["ws_dial_error"] != 1 {
				t.Fatalf("fixed native socket code %d/language %04x not recognized", code, language)
			}
			if code == 10060 && report.Counts["timeout_error"] != 1 || code == 10061 && report.Counts["connection_refused"] != 1 {
				t.Fatal("native socket failure category was lost")
			}
			encoded, err := json.Marshal(report)
			if err != nil || len(encoded) > maxDiagnosticReportBytes || strings.Contains(string(encoded), strings.TrimSpace(message)) {
				t.Fatal("raw OS message escaped or report bound changed")
			}
			checked++
		}
	}
	if checked < len(diagnosticSocketCodes) {
		t.Fatal("host could not format the fixed socket-code vocabulary")
	}
	t.Logf("checked %d installed-language/code combinations without sockets", checked)
}

func TestDiagnosticSocketCodeRejectsPortsAndUnknownNumericValues(t *testing.T) {
	for _, line := range []string{
		"tcp:192.0.2.1:10060", "status 10060", "winapi error #100601", "winapi error #99999",
		"[Info] transport/internet/websocket: creating connection to tcp:fixture.invalid:10060",
	} {
		if diagnosticSocketCode(strings.ToLower(line)) != 0 {
			t.Fatal("an arbitrary raw number or port became a native socket code")
		}
	}
	for _, code := range diagnosticSocketCodes {
		if diagnosticSocketCode(fmt.Sprintf("connectex: winapi error #%d", code)) != code {
			t.Fatal("fixed Go numeric fallback was lost")
		}
	}
}

func TestDiagnosticSocketPatternsAreStableAndConcurrent(t *testing.T) {
	diagnosticSocketCode("")
	if len(diagnosticSocketPatterns) == 0 || len(diagnosticSocketPatterns) > len(diagnosticSocketCodes)*3 {
		t.Fatal("precomputed message set is empty or unbounded")
	}
	var workers sync.WaitGroup
	for range 4 {
		workers.Go(func() {
			for range 100 {
				if diagnosticSocketCode("winapi error #10060") != 10060 {
					t.Error("concurrent fixed-code lookup was lost")
				}
			}
		})
	}
	workers.Wait()
}

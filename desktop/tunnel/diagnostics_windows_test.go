//go:build windows

package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestSessionDiagnosticsSinkRefusesAnUntrustedExecutableDirectory(t *testing.T) {
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	directory := filepath.Dir(executable)
	if trustedInstall(directory) {
		t.Skip("run this test from the ordinary Go test directory")
	}
	destination := filepath.Join(directory, "session-diagnostics.json")
	before, beforeErr := os.Stat(destination)
	writeSessionDiagnostics(newSessionDiagnostics(time.Unix(0, 0)).snapshot(time.Unix(1, 0)))
	after, afterErr := os.Stat(destination)
	if os.IsNotExist(beforeErr) && !os.IsNotExist(afterErr) {
		t.Fatal("sink created a report outside the trusted Engine directory")
	}
	if beforeErr == nil && (afterErr != nil || before.Size() != after.Size() || !before.ModTime().Equal(after.ModTime())) {
		t.Fatal("sink changed a file outside the trusted Engine directory")
	}
}

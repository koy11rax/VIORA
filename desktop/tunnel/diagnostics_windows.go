//go:build windows

package main

import (
	"encoding/json"
	"os"
	"path/filepath"

	"golang.org/x/sys/windows"
)

// The destination is derived only from the trusted helper executable. No IPC or
// log string chooses a path. New files inherit the protected Engine directory ACL.
func writeSessionDiagnostics(report diagnosticsReport) {
	executable, err := os.Executable()
	if err != nil {
		return
	}
	directory := filepath.Dir(executable)
	if !trustedInstall(directory) {
		return
	}
	encoded, err := json.Marshal(report)
	if err != nil || len(encoded)+1 > maxDiagnosticReportBytes {
		return
	}
	destination := filepath.Join(directory, "session-diagnostics.json")
	wide, err := windows.UTF16PtrFromString(destination)
	if err != nil {
		return
	}
	attributes, err := windows.GetFileAttributes(wide)
	if err != nil && err != windows.ERROR_FILE_NOT_FOUND {
		return
	}
	if err == nil && attributes&(windows.FILE_ATTRIBUTE_REPARSE_POINT|windows.FILE_ATTRIBUTE_DIRECTORY) != 0 {
		return
	}
	file, err := os.CreateTemp(directory, ".session-diagnostics-*.tmp")
	if err != nil {
		return
	}
	defer os.Remove(file.Name())
	defer file.Close()
	if _, err = file.Write(append(encoded, '\n')); err != nil {
		return
	}
	if err = file.Sync(); err != nil {
		return
	}
	if err = file.Close(); err != nil {
		return
	}
	// Replace the old report atomically. On failure retain it, never truncate it.
	_ = os.Rename(file.Name(), destination)
}

package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"
)

var trustServiceReasons = [...]installTrustReason{
	installTrustExecutable, installTrustKnownFolder, installTrustDirectoryMismatch,
	installTrustEngineAttributes, installTrustCoreAttributes, installTrustXrayAttributes,
	installTrustDriverAttributes, installTrustReparse,
}

func trustServiceCode(err error) uint32 {
	var reason installTrustReason
	if errors.As(err, &reason) {
		for index, known := range trustServiceReasons {
			if reason == known {
				return 0x2101 + uint32(index)
			}
		}
	}
	return 0x2100
}

func serviceTrustReason(code uint32) string {
	if code >= 0x2101 && code < 0x2101+uint32(len(trustServiceReasons)) {
		return string(trustServiceReasons[code-0x2101])
	}
	return ""
}

type installStartReport struct {
	Schema      int    `json:"schema"`
	Outcome     string `json:"outcome"`
	TrustReason string `json:"trust_reason,omitempty"`
	SystemCode  uint32 `json:"system_code,omitempty"`
	ServiceCode uint32 `json:"service_code,omitempty"`
}

func installReport(outcome string, err error) installStartReport {
	report := installStartReport{Schema: 1, Outcome: outcome}
	var code syscall.Errno
	if errors.As(err, &code) {
		report.SystemCode = uint32(code)
	}
	return report
}

type installService interface {
	Config() (mgr.Config, error)
	Query() (svc.Status, error)
	Start(...string) error
}

// Only SCM service startup is checked. This never sends a VPN configuration,
// creates a TUN, changes firewall policy or contacts a network endpoint.
func startInstalledService(ctx context.Context, service installService, executable string) installStartReport {
	if ctx.Err() != nil {
		return installReport("cancelled", nil)
	}
	config, err := service.Config()
	if err != nil {
		return installReport("service_config_unavailable", err)
	}
	if !strings.EqualFold(config.BinaryPathName, `"`+executable+`" --service`) ||
		!strings.EqualFold(config.ServiceStartName, "LocalSystem") || config.StartType != mgr.StartAutomatic {
		return installReport("service_config_mismatch", nil)
	}
	status, err := service.Query()
	if err != nil {
		return installReport("service_query_failed", err)
	}
	if status.State == svc.Running {
		return installReport("service_running", nil)
	}
	if ctx.Err() != nil {
		return installReport("cancelled", nil)
	}
	if status.State == svc.Stopped {
		if err := service.Start(); err != nil {
			return installReport("service_start_failed", err)
		}
	} else if status.State != svc.StartPending {
		return installReport("service_not_startable", nil)
	}
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return installReport("service_start_timeout", nil)
		case <-ticker.C:
			status, err = service.Query()
			if err != nil {
				return installReport("service_query_failed", err)
			}
			if status.State == svc.Running {
				return installReport("service_running", nil)
			}
			if status.State == svc.Stopped {
				report := installReport("service_stopped", nil)
				report.SystemCode, report.ServiceCode = status.Win32ExitCode, status.ServiceSpecificExitCode
				report.TrustReason = serviceTrustReason(status.ServiceSpecificExitCode)
				return report
			}
		}
	}
}

// A fixed, administrator-only installation verb; it is not broker IPC.
func installerCLI() bool {
	if len(os.Args) != 2 || os.Args[1] != "--install-start" {
		return false
	}
	if !windows.GetCurrentProcessToken().IsElevated() {
		os.Exit(5)
	}
	executable, err := os.Executable()
	if err != nil {
		os.Exit(6)
	}
	directory := filepath.Dir(executable)
	report := installReport("checking_payload", nil)
	if reason := trustedInstallFailure(directory); reason != installTrustOK {
		report.Outcome, report.TrustReason = "trust_failed", string(reason)
	} else if !verifiedFile(filepath.Join(directory, "core", coreName()), coreSHA) {
		report.Outcome = "core_hash_mismatch"
	} else if !verifiedDriver(directory, driverSHA) {
		report.Outcome = "driver_hash_mismatch"
	} else if !verifiedFile(filepath.Join(directory, "viora_firewall.exe"), firewallSHA) {
		report.Outcome = "firewall_hash_mismatch"
	} else {
		manager, connectErr := mgr.Connect()
		if connectErr != nil {
			report = installReport("service_manager_unavailable", connectErr)
		} else {
			service, openErr := manager.OpenService(serviceName)
			if openErr != nil {
				report = installReport("service_missing", openErr)
			} else {
				ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
				report = startInstalledService(ctx, service, executable)
				cancel()
				service.Close()
			}
			manager.Disconnect()
		}
	}
	writeInstallStartReport(directory, report)
	if report.Outcome != "service_running" {
		os.Exit(7)
	}
	return true
}

// Even when a payload file is absent, the report may be written only in the
// fixed, protected Engine root. No file name or error text comes from IPC.
func writeInstallStartReport(directory string, report installStartReport) {
	root, err := windows.KnownFolderPath(windows.FOLDERID_ProgramFiles, 0)
	if err != nil || !strings.EqualFold(directory, filepath.Join(root, "Viora", "Engine")) {
		return
	}
	for _, path := range []string{filepath.Join(root, "Viora"), directory} {
		wide, err := windows.UTF16PtrFromString(path)
		if err != nil {
			return
		}
		attributes, err := windows.GetFileAttributes(wide)
		if err != nil || attributes&windows.FILE_ATTRIBUTE_DIRECTORY == 0 || attributes&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
			return
		}
	}
	encoded, err := json.Marshal(report)
	if err != nil || len(encoded) > 2048 {
		return
	}
	destination := filepath.Join(directory, "installation-diagnostics.json")
	wide, err := windows.UTF16PtrFromString(destination)
	if err != nil {
		return
	}
	attributes, err := windows.GetFileAttributes(wide)
	if err != nil && err != windows.ERROR_FILE_NOT_FOUND {
		return
	}
	if err == nil && attributes&(windows.FILE_ATTRIBUTE_DIRECTORY|windows.FILE_ATTRIBUTE_REPARSE_POINT) != 0 {
		return
	}
	file, err := os.CreateTemp(directory, ".install-diagnostics-*.tmp")
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
	_ = os.Rename(file.Name(), destination)
}

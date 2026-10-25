package main

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"syscall"
	"testing"
	"time"

	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"
)

type fixtureInstallService struct {
	config                        mgr.Config
	states                        []svc.Status
	configErr, queryErr, startErr error
	starts, queries               int
}

func (s *fixtureInstallService) Config() (mgr.Config, error) { return s.config, s.configErr }
func (s *fixtureInstallService) Query() (svc.Status, error) {
	s.queries++
	if s.queryErr != nil {
		return svc.Status{}, s.queryErr
	}
	index := s.queries - 1
	if index >= len(s.states) {
		index = len(s.states) - 1
	}
	return s.states[index], nil
}
func (s *fixtureInstallService) Start(...string) error { s.starts++; return s.startErr }
func installFixture() *fixtureInstallService {
	return &fixtureInstallService{config: mgr.Config{BinaryPathName: `"C:\Program Files\Viora\Engine\viora_tunnel.exe" --service`, ServiceStartName: "LocalSystem", StartType: mgr.StartAutomatic}, states: []svc.Status{{State: svc.Stopped}, {State: svc.StartPending}, {State: svc.Running}}}
}

const installFixtureExecutable = `C:\Program Files\Viora\Engine\viora_tunnel.exe`

func TestInstallerStartsOnlyTheValidatedService(t *testing.T) {
	for _, field := range []string{"path", "account", "starttype"} {
		t.Run(field, func(t *testing.T) {
			service := installFixture()
			switch field {
			case "path":
				service.config.BinaryPathName = `"C:\fixture\arbitrary.exe"`
			case "account":
				service.config.ServiceStartName = "fixture-user"
			case "starttype":
				service.config.StartType = mgr.StartDisabled
			}
			report := startInstalledService(context.Background(), service, installFixtureExecutable)
			if report.Outcome != "service_config_mismatch" || service.starts != 0 || service.queries != 0 {
				t.Fatal("unvalidated service was used")
			}
		})
	}
}
func TestInstallerWaitsForRunningWithoutRetryingFailedStart(t *testing.T) {
	service := installFixture()
	report := startInstalledService(context.Background(), service, installFixtureExecutable)
	if report.Outcome != "service_running" || service.starts != 1 || service.queries != 3 {
		t.Fatal("running transition not verified")
	}
	service = installFixture()
	service.states = []svc.Status{{State: svc.Running}}
	if startInstalledService(context.Background(), service, installFixtureExecutable).Outcome != "service_running" || service.starts != 0 {
		t.Fatal("running service was restarted")
	}
	service = installFixture()
	service.states = []svc.Status{{State: svc.Stopped}, {State: svc.Stopped, Win32ExitCode: 1066, ServiceSpecificExitCode: trustServiceCode(installTrustDriverAttributes)}}
	report = startInstalledService(context.Background(), service, installFixtureExecutable)
	if report.Outcome != "service_stopped" || report.TrustReason != "driverattrs" || report.SystemCode != 1066 || service.starts != 1 {
		t.Fatal("failure was hidden or retried")
	}
}
func TestInstallerCancelledOrTimedOutDoesNotClaimSuccess(t *testing.T) {
	service := installFixture()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if startInstalledService(ctx, service, installFixtureExecutable).Outcome != "cancelled" || service.starts != 0 || service.queries != 0 {
		t.Fatal("cancelled installer touched service")
	}
	service = installFixture()
	service.states = []svc.Status{{State: svc.StartPending}}
	ctx, cancel = context.WithTimeout(context.Background(), 5*time.Millisecond)
	defer cancel()
	started := time.Now()
	report := startInstalledService(ctx, service, installFixtureExecutable)
	if report.Outcome != "service_start_timeout" || service.starts != 0 || time.Since(started) > time.Second {
		t.Fatal("pending service did not time out")
	}
}
func TestInstallerErrorsNeverRetainRawText(t *testing.T) {
	for _, stage := range []string{"config", "query", "start"} {
		t.Run(stage, func(t *testing.T) {
			service := installFixture()
			secretErr := errors.New("private-path-token-profile.example.invalid")
			switch stage {
			case "config":
				service.configErr = secretErr
			case "query":
				service.queryErr = secretErr
			case "start":
				service.startErr = secretErr
			}
			report := startInstalledService(context.Background(), service, installFixtureExecutable)
			data, err := json.Marshal(report)
			if err != nil || strings.Contains(string(data), "private") || report.Outcome == "service_running" {
				t.Fatal("raw error retained or error accepted")
			}
		})
	}
	report := installReport("service_start_failed", syscall.Errno(5))
	if report.SystemCode != 5 {
		t.Fatal("safe numeric system code lost")
	}
}
func TestInstallerTrustServiceCodesRoundTrip(t *testing.T) {
	for _, reason := range trustServiceReasons {
		code := trustServiceCode(reason)
		if code < 0x2101 || serviceTrustReason(code) != string(reason) {
			t.Fatal("trust reason lost")
		}
	}
	if trustServiceCode(errors.New("private-error")) != 0x2100 || serviceTrustReason(3) != "" || serviceTrustReason(0xffffffff) != "" {
		t.Fatal("unknown code or raw error accepted")
	}
}

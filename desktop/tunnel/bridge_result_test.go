package main

import (
	"errors"
	"testing"
)

func TestBridgeCleanupFailurePreventsAutomaticRetryAndSurvivesCancellation(t *testing.T) {
	for _, cancelled := range []bool{false, true} {
		for _, lifecycle := range []string{"", "frontend_exited", "backend_exited"} {
			for _, runtime := range []string{"", "network_changed", "system_dns_failed"} {
				if result := bridgeSessionResult(cancelled, lifecycle, runtime, errors.New("cleanup failed")); result != "routing_cleanup_failed" {
					t.Fatal("lost recovery error", result)
				}
			}
		}
	}
	if bridgeSessionResult(true, "frontend_exited", "network_changed", nil) != "" {
		t.Fatal("cancellation did not stop")
	}
	if bridgeSessionResult(false, "frontend_exited", "network_changed", nil) != "network_changed" {
		t.Fatal("runtime reason lost")
	}
	if bridgeSessionResult(false, "frontend_exited", "", nil) != "frontend_exited" {
		t.Fatal("lifecycle reason lost")
	}
}

func TestBridgeCancellationDuringPreflightDoesNotReportRoutingFailure(t *testing.T) {
	for _, code := range []string{"routing_setup_failed", "outbound_interface_unavailable", "bridge_config_failed", "metrics_failed", "frontend_integrity"} {
		cancelled := bridgeFailureStatus(true, code)
		if cancelled.State != "DISCONNECTED" || cancelled.Code != "" {
			t.Fatal("cancelled preflight reported a failure", cancelled)
		}
		active := bridgeFailureStatus(false, code)
		if active.State != "FAILED" || active.Code != code {
			t.Fatal("real preflight failure hidden", active)
		}
	}
	cleanup := bridgeFailureStatus(true, "routing_cleanup_failed")
	if cleanup.State != "FAILED" || cleanup.Code != "routing_cleanup_failed" {
		t.Fatal("cleanup failure hidden by cancellation", cleanup)
	}
}

package main

import (
	"context"
	"time"
)

// A failed network cleanup requires deliberate recovery, even when the user
// cancelled or an engine/network failure would otherwise trigger auto-retry.
func bridgeSessionResult(cancelled bool, lifecycleCode, runtimeCode string, cleanupError error) string {
	if cleanupError != nil {
		return "routing_cleanup_failed"
	}
	if cancelled {
		return ""
	}
	if runtimeCode != "" {
		return runtimeCode
	}
	return lifecycleCode
}

func bridgeFailureStatus(cancelled bool, code string) status {
	if cancelled && code != "routing_cleanup_failed" {
		return status{State: "DISCONNECTED"}
	}
	return status{State: "FAILED", Code: code}
}

// A session owns both children. No child, readiness task, or local proxy is
// allowed to outlive the connection which created it.
type bridgeProcess interface {
	Ready(context.Context) error
	Done() <-chan struct{}
	Stop()
}

type bridgeStart func(context.Context, string) (bridgeProcess, error)

func superviseBridge(ctx context.Context, start bridgeStart, onReady func() string, beforeStop ...func()) string {
	return superviseBridgeWithTimeout(ctx, start, onReady, 20*time.Second, beforeStop...)
}

func superviseBridgeWithTimeout(ctx context.Context, start bridgeStart, onReady func() string, budget time.Duration, beforeStop ...func()) string {
	children := make([]bridgeProcess, 0, 2)
	defer func() {
		for i := len(children) - 1; i >= 0; i-- {
			children[i].Stop()
		}
	}()
	// Stop status/metrics producers before a failed child can release its local
	// listener or its peer is torn down. Cleanup still always runs afterward.
	defer func() {
		for _, stop := range beforeStop {
			if stop != nil {
				stop()
			}
		}
	}()
	startup, cancelStartup := context.WithTimeout(ctx, budget)
	defer cancelStartup()
	for _, stage := range []string{"backend", "frontend"} {
		if ctx.Err() != nil {
			return ""
		}
		if startup.Err() != nil {
			return stage + "_not_ready"
		}
		// Pass the session lifetime, not the shorter readiness deadline. The
		// completed startup deadline must never terminate a working session.
		child, err := start(ctx, stage)
		if child != nil {
			children = append(children, child)
		}
		if err != nil || child == nil {
			if ctx.Err() != nil {
				return ""
			}
			return stage + "_start_failed"
		}
		if child.Ready(startup) != nil {
			if ctx.Err() != nil {
				return ""
			}
			return stage + "_not_ready"
		}
		if ctx.Err() != nil {
			return ""
		}
		if startup.Err() != nil {
			return stage + "_not_ready"
		}
		for index, running := range children {
			select {
			case <-running.Done():
				if index == 0 {
					return "backend_exited"
				}
				return "frontend_exited"
			default:
			}
		}
	}
	if onReady != nil {
		if code := onReady(); code != "" {
			return code
		}
	}
	select {
	case <-ctx.Done():
		return ""
	case <-children[0].Done():
		if ctx.Err() != nil {
			return ""
		}
		return "backend_exited"
	case <-children[1].Done():
		if ctx.Err() != nil {
			return ""
		}
		return "frontend_exited"
	}
}

package main

import "context"

// Linux retains its existing privileged TUN implementation in this Windows fix.
func runPlatformBridge(context.Context, map[string]any, string, bool, func(status), *sessionDiagnostics) bool {
	return false
}

package main

// Kept as a small platform wrapper to preserve the tested Windows contract.
func buildWindowsBridge(config map[string]any, port uint16, user, password string) (map[string]any, map[string]any, error) {
	return buildDesktopBridge(config, port, user, password)
}

func buildPlatformBridge(config map[string]any, port uint16, user, password string) (map[string]any, map[string]any, error) {
	return buildWindowsBridge(config, port, user, password)
}

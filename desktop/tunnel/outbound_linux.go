package main

// Linux keeps its existing routing policy. The Windows interface pin is not
// portable and must not silently change Linux routing or protection rules.
func bindDesktopOutbound(config map[string]any) (func() bool, error) {
	return func() bool { return true }, nil
}

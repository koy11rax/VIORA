package main

import "context"

// Normal Windows sessions also need endpoint resolution before TUN starts.
// Strict/protected sessions never fall back to cleartext system DNS.
func prepareEndpoint(ctx context.Context, config map[string]any, protected bool) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	return resolveEndpoint(ctx, config, !protected)
}

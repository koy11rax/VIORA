package main

import "context"

// The backend must receive a numeric endpoint before TUN routes/DNS are active.
// Strict protection never falls back to an ordinary cleartext DNS lookup.
func prepareEndpoint(ctx context.Context, config map[string]any, protected bool) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	return resolveEndpoint(ctx, config, !protected)
}

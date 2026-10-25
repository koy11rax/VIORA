package main

import "context"

// Keep the existing Linux policy: protected sessions bootstrap through fixed
// HTTPS; ordinary sessions retain their platform resolver behavior.
func prepareEndpoint(ctx context.Context, config map[string]any, protected bool) error {
	if protected {
		return resolveEndpoint(ctx, config, false)
	}
	return ctx.Err()
}

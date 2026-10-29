package main

import "context"

func prepareBridgeNetwork(context.Context) (func() error, error) {
	return func() error { return nil }, nil
}

func readyBridgeDNS(context.Context) error { return nil }

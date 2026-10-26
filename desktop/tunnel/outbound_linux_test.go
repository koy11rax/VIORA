package main

import "testing"

func TestBindDesktopOutboundLinuxKeepsExistingPolicy(t *testing.T) {
	config := map[string]any{"unchanged": true}
	check, err := bindDesktopOutbound(config)
	if err != nil || check == nil || !check() || len(config) != 1 || config["unchanged"] != true {
		t.Fatal("Windows interface selection changed Linux policy")
	}
}

package main

import "testing"

func TestLinuxBridgeListenerRequiresExactLoopbackPortAndOwnedInode(t *testing.T) {
	good := []byte("  sl local_address rem_address st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode\n 0: 0100007F:7969 00000000:0000 0A 00000000:00000000 00:00000000 00000000 1000 0 1234\n")
	if !linuxBridgeListenerInTable(good, 31081, map[string]bool{"1234": true}) {
		t.Fatal("owned listener rejected")
	}
	if linuxBridgeListenerInTable(good, 31082, map[string]bool{"1234": true}) || linuxBridgeListenerInTable(good, 31081, map[string]bool{"1235": true}) || linuxBridgeListenerInTable(good, 0, map[string]bool{"1234": true}) {
		t.Fatal("wrong listener accepted")
	}
	for _, row := range []string{
		"0: 00000000:7969 00000000:0000 0A 0 0 0 1000 0 1234",
		"0: 0100007F:7969 00000000:0000 01 0 0 0 1000 0 1234",
		"0: 0100007F:7969 00000000:0000 0A",
	} {
		if linuxBridgeListenerInTable([]byte(row), 31081, map[string]bool{"1234": true}) {
			t.Fatal("unsafe listener accepted")
		}
	}
}

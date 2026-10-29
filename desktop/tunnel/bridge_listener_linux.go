package main

import (
	"bufio"
	"bytes"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// /proc is kernel-owned. The ephemeral SOCKS/metrics listener is accepted only
// when its inode belongs to the verified child, rather than a bind racer.
func ownedBridgeListener(pid uint32, port uint16) bool {
	if pid == 0 || port == 0 {
		return false
	}
	base := filepath.Join("/proc", strconv.FormatUint(uint64(pid), 10))
	entries, err := os.ReadDir(filepath.Join(base, "fd"))
	if err != nil || len(entries) > 65536 {
		return false
	}
	inodes := map[string]bool{}
	for _, entry := range entries {
		link, err := os.Readlink(filepath.Join(base, "fd", entry.Name()))
		if err == nil && strings.HasPrefix(link, "socket:[") && strings.HasSuffix(link, "]") {
			inodes[strings.TrimSuffix(strings.TrimPrefix(link, "socket:["), "]")] = true
		}
	}
	file, err := os.Open(filepath.Join(base, "net", "tcp"))
	if err != nil {
		return false
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, 4*1024*1024+1))
	if err != nil || len(data) > 4*1024*1024 {
		return false
	}
	return linuxBridgeListenerInTable(data, port, inodes)
}

func linuxBridgeListenerInTable(data []byte, port uint16, inodes map[string]bool) bool {
	if port == 0 {
		return false
	}
	expected := fmt.Sprintf("0100007F:%04X", port)
	scanner := bufio.NewScanner(bytes.NewReader(data))
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) >= 10 && fields[1] == expected && fields[3] == "0A" && inodes[fields[9]] {
			return true
		}
	}
	return false
}

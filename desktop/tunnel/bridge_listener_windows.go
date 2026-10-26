package main

import (
	"bytes"
	"encoding/binary"
	"unsafe"

	"golang.org/x/sys/windows"
)

// The local proxy port must belong to the verified child, rather than a process
// which raced its ephemeral bind. This API only reads kernel socket metadata.
func ownedBridgeListener(pid uint32, port uint16) bool {
	proc := windows.NewLazySystemDLL("iphlpapi.dll").NewProc("GetExtendedTcpTable")
	size := uint32(15000)
	for attempt := 0; attempt < 3; attempt++ {
		if size < 4 || size > 4*1024*1024 {
			return false
		}
		buffer := make([]byte, size)
		result, _, _ := proc.Call(uintptr(unsafe.Pointer(&buffer[0])), uintptr(unsafe.Pointer(&size)), 0, windows.AF_INET, 3, 0)
		if result == uintptr(windows.ERROR_INSUFFICIENT_BUFFER) {
			continue
		}
		if result != 0 || size > uint32(len(buffer)) {
			return false
		}
		return bridgeListenerInTable(buffer[:size], pid, port)
	}
	return false
}

func bridgeListenerInTable(table []byte, pid uint32, port uint16) bool {
	if len(table) < 4 || pid == 0 || port == 0 {
		return false
	}
	count := uint64(binary.LittleEndian.Uint32(table[:4]))
	if count > uint64((len(table)-4)/24) {
		return false
	}
	for index := uint64(0); index < count; index++ {
		row := table[4+index*24 : 4+(index+1)*24]
		if binary.LittleEndian.Uint32(row[:4]) == 2 && bytes.Equal(row[4:8], []byte{127, 0, 0, 1}) &&
			binary.BigEndian.Uint16(row[8:10]) == port && binary.LittleEndian.Uint32(row[20:24]) == pid {
			return true
		}
	}
	return false
}

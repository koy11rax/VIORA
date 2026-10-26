package main

import (
	"bytes"
	"encoding/binary"
	"io"
	"net"
	"testing"
	"time"
)

func listenerFixture(pid uint32, port uint16) []byte {
	data := make([]byte, 28)
	binary.LittleEndian.PutUint32(data[:4], 1)
	row := data[4:]
	binary.LittleEndian.PutUint32(row[:4], 2)
	copy(row[4:8], []byte{127, 0, 0, 1})
	binary.BigEndian.PutUint16(row[8:10], port)
	binary.LittleEndian.PutUint32(row[20:24], pid)
	return data
}

func TestBridgeListenerRequiresExactChildLoopbackPort(t *testing.T) {
	valid := listenerFixture(123, 32000)
	if !bridgeListenerInTable(valid, 123, 32000) {
		t.Fatal("valid child listener rejected")
	}
	for _, size := range []int{0, 3, 4, 27} {
		if bridgeListenerInTable(valid[:size], 123, 32000) {
			t.Fatalf("accepted truncated table: %d", size)
		}
	}
	for _, test := range []struct {
		name   string
		mutate func([]byte)
	}{
		{"wrong-owner", func(b []byte) { binary.LittleEndian.PutUint32(b[24:28], 124) }},
		{"not-listening", func(b []byte) { binary.LittleEndian.PutUint32(b[4:8], 5) }},
		{"any-address", func(b []byte) { clear(b[8:12]) }},
		{"other-loopback", func(b []byte) { b[11] = 2 }},
		{"wrong-port", func(b []byte) { binary.BigEndian.PutUint16(b[12:14], 32001) }},
		{"overflow-count", func(b []byte) { binary.LittleEndian.PutUint32(b[:4], ^uint32(0)) }},
	} {
		t.Run(test.name, func(t *testing.T) {
			data := bytes.Clone(valid)
			test.mutate(data)
			if bridgeListenerInTable(data, 123, 32000) {
				t.Fatal("accepted foreign or malformed listener")
			}
		})
	}
	if bridgeListenerInTable(valid, 0, 32000) || bridgeListenerInTable(valid, 123, 0) {
		t.Fatal("accepted zero identity")
	}
}

func TestBridgeAuthenticatesLocalProxyWithoutRemoteRequest(t *testing.T) {
	for _, test := range []struct {
		name            string
		method, outcome byte
		want            bool
	}{
		{"authenticated", 2, 0, true}, {"no-auth-forbidden", 0, 0, false}, {"bad-password", 2, 1, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			client, server := net.Pipe() // memory only; no OS socket/listener.
			defer client.Close()
			defer server.Close()
			client.SetDeadline(time.Now().Add(time.Second))
			server.SetDeadline(time.Now().Add(time.Second))
			serverDone := make(chan error, 1)
			go func() {
				var greeting [3]byte
				if _, err := io.ReadFull(server, greeting[:]); err != nil {
					serverDone <- err
					return
				}
				if greeting != [3]byte{5, 1, 2} {
					serverDone <- io.ErrUnexpectedEOF
					return
				}
				if _, err := server.Write([]byte{5, test.method}); err != nil {
					serverDone <- err
					return
				}
				if test.method != 2 {
					serverDone <- nil
					return
				}
				var header [2]byte
				if _, err := io.ReadFull(server, header[:]); err != nil {
					serverDone <- err
					return
				}
				if header[0] != 1 {
					serverDone <- io.ErrUnexpectedEOF
					return
				}
				username := make([]byte, header[1])
				if _, err := io.ReadFull(server, username); err != nil {
					serverDone <- err
					return
				}
				var size [1]byte
				if _, err := io.ReadFull(server, size[:]); err != nil {
					serverDone <- err
					return
				}
				password := make([]byte, size[0])
				if _, err := io.ReadFull(server, password); err != nil {
					serverDone <- err
					return
				}
				if string(username) != "fixture" || string(password) != "0123456789abcdef0123456789abcdef" {
					serverDone <- io.ErrUnexpectedEOF
					return
				}
				_, err := server.Write([]byte{1, test.outcome})
				serverDone <- err
			}()
			err := authenticateBridgeStream(client, "fixture", "0123456789abcdef0123456789abcdef")
			if (err == nil) != test.want {
				t.Fatalf("authentication success=%v want %v", err == nil, test.want)
			}
			if err := <-serverDone; err != nil {
				t.Fatal(err)
			}
		})
	}
}

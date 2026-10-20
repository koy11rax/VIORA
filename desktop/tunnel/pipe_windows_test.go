package main

import (
	"fmt"
	"golang.org/x/sys/windows"
	"io"
	"os"
	"testing"
	"time"
)

func TestControlPipeReportsStatusWhileWaitingForStop(t *testing.T) {
	name := fmt.Sprintf(`\\.\pipe\Viora-test-%d-%d`, os.Getpid(), time.Now().UnixNano())
	wide, _ := windows.UTF16PtrFromString(name)
	handle, err := windows.CreateNamedPipe(wide,
		windows.PIPE_ACCESS_DUPLEX|windows.FILE_FLAG_OVERLAPPED,
		windows.PIPE_TYPE_BYTE|windows.PIPE_WAIT|windows.PIPE_REJECT_REMOTE_CLIENTS,
		1, 4096, 4096, 0, nil)
	if err != nil {
		t.Fatal(err)
	}
	server := os.NewFile(uintptr(handle), name)
	defer server.Close()
	client, err := openControlPipe(name)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	readDone := make(chan error, 1)
	go func() { b := make([]byte, 1); _, e := client.Read(b); readDone <- e }()
	// Let the helper's stop reader pend before it reports startup success.
	time.Sleep(50 * time.Millisecond)
	writeDone := make(chan error, 1)
	go func() { _, e := client.Write([]byte("CONNECTED\n")); writeDone <- e }()
	received := make(chan string, 1)
	go func() {
		b := make([]byte, 10)
		_, e := io.ReadFull(server, b)
		if e != nil {
			received <- e.Error()
		} else {
			received <- string(b)
		}
	}()
	select {
	case message := <-received:
		if message != "CONNECTED\n" {
			t.Fatalf("unexpected fixture status %q", message)
		}
	case <-time.After(time.Second):
		t.Fatal("pending stop read blocked startup status")
	}
	if err := <-writeDone; err != nil {
		t.Fatal(err)
	}
	if _, err := server.Write([]byte("x")); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-readDone:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("stop read did not finish")
	}
}

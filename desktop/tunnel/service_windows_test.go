package main

import (
	"bufio"
	"errors"
	"fmt"
	"golang.org/x/sys/windows"
	"io"
	"os"
	"strings"
	"testing"
	"time"
)

func fixturePipe(t *testing.T, name string) *os.File {
	t.Helper()
	wide, _ := windows.UTF16PtrFromString(name)
	handle, err := windows.CreateNamedPipe(wide, windows.PIPE_ACCESS_DUPLEX|windows.FILE_FLAG_OVERLAPPED|windows.FILE_FLAG_FIRST_PIPE_INSTANCE,
		windows.PIPE_TYPE_BYTE|windows.PIPE_WAIT|windows.PIPE_REJECT_REMOTE_CLIENTS, 1, 4096, 4096, 0, nil)
	if err != nil {
		t.Fatal(err)
	}
	f := os.NewFile(uintptr(handle), name)
	t.Cleanup(func() { f.Close() })
	return f
}
func TestServiceSessionPipeChecksOwnerAndRejectsArbitraryPaths(t *testing.T) {
	for _, name := range []string{`C:\config`, `\\remote\pipe\Viora-` + strings.Repeat("a", 32), brokerPipe, `\\.\pipe\Viora-x`} {
		if pipe, err := sessionPipe(name, uint32(os.Getpid())); err == nil {
			pipe.Close()
			t.Fatal("accepted arbitrary endpoint")
		}
	}
	name := fmt.Sprintf(`\\.\pipe\Viora-%032x`, time.Now().UnixNano())
	fixturePipe(t, name)
	if pipe, err := sessionPipe(name, uint32(os.Getpid()+100000)); err == nil {
		pipe.Close()
		t.Fatal("accepted different owner")
	}
}
func TestServiceBrokerFullDuplexAndShutdown(t *testing.T) {
	name := fmt.Sprintf(`\\.\pipe\Viora-broker-test-%d-%d`, os.Getpid(), time.Now().UnixNano())
	listener := fixturePipe(t, name)
	stop, done := make(chan struct{}), make(chan struct{})
	sessions := &serviceSessions{}
	owners := &memoryOwnerStore{}
	policyOn := true
	mutations := 0
	fixtureProtection := func(action string) (bool, error) {
		if action == "disable" {
			mutations++
			policyOn = false
		}
		if action == "enable" {
			mutations++
			policyOn = true
		}
		return policyOn, nil
	}
	go func() {
		defer close(done)
		serveBroker(listener, stop, sessions, func(input io.ReadCloser, output io.Writer, _ func(string) (bool, error)) {
			defer input.Close()
			reader := bufio.NewReader(input)
			line, err := reader.ReadString('\n')
			if err == nil && line == "fixture-only\n" {
				io.WriteString(output, "CONNECTED\n")
			}
			reader.ReadString('\n')
		}, owners, fixtureProtection)
	}()
	t.Cleanup(func() { close(stop); listener.Close(); <-done; sessions.close(); sessions.wait.Wait() })
	exchange := func(request string) string {
		t.Helper()
		var client *os.File
		var err error
		for attempt := 0; attempt < 100; attempt++ {
			client, err = openControlPipe(name)
			if err == nil {
				break
			}
			time.Sleep(10 * time.Millisecond)
		}
		if err != nil {
			t.Fatal(err)
		}
		defer client.Close()
		client.SetDeadline(time.Now().Add(time.Second))
		if _, err = io.WriteString(client, request+"\n"); err != nil {
			t.Fatal(err)
		}
		response, err := bufio.NewReader(client).ReadString('\n')
		if err != nil {
			t.Fatal(err)
		}
		io.WriteString(client, "ACK\n")
		return response
	}
	if response := exchange(`C:\untrusted-config`); response != "ERROR\n" {
		t.Fatalf("accepted arbitrary request: %q", response)
	}
	// Exercise the actual pipe/token path with a fake policy backend. A failed
	// ownership check must not reach the privileged mutation, even for an admin.
	owners.readErr = errors.New("fixture unreadable ownership")
	if response := exchange("PROTECTION disable"); response != "ERROR\n" || mutations != 0 || !policyOn {
		t.Fatal("broker bypassed protection ownership")
	}
	owners.readErr = nil
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		t.Fatal(err)
	}
	owners.value = user.User.Sid.String()
	if response := exchange("PROTECTION disable"); response != "OFF\n" || mutations != 1 || policyOn || owners.value != "" {
		t.Fatal("authenticated owner's broker flow failed")
	}
	if response := exchange("PROTECTION recover"); response != "ERROR\n" || mutations != 1 {
		t.Fatal("emergency operation exposed through broker")
	}
	privateName := fmt.Sprintf(`\\.\pipe\Viora-%032x`, time.Now().UnixNano())
	private := fixturePipe(t, privateName)
	private.SetDeadline(time.Now().Add(3 * time.Second))
	if response := exchange(privateName); response != "READY\n" {
		t.Fatalf("session rejected: %q", response)
	}
	io.WriteString(private, "fixture-only\n")
	response, err := bufio.NewReader(private).ReadString('\n')
	if err != nil || response != "CONNECTED\n" {
		t.Fatalf("full duplex failed: %q %v", response, err)
	}
	if response = exchange(privateName); response != "BUSY\n" {
		t.Fatalf("concurrent session accepted: %q", response)
	}
	// Cleanup stops the listener and active fixture session, without launching
	// Xray, requesting elevation, altering routes, or touching the real service.
}

// Explicit opt-in smoke check: only invalid fixture data is sent, so no Xray,
// network routes, subscription or credentials are involved.
func TestInstalledServiceRejectsInvalidFixture(t *testing.T) {
	if os.Getenv("VIORA_TEST_SERVICE") != "1" {
		t.Skip("requires explicitly enabled installed-service fixture")
	}
	name := fmt.Sprintf(`\\.\pipe\Viora-%032x`, time.Now().UnixNano())
	private := fixturePipe(t, name)
	private.SetDeadline(time.Now().Add(5 * time.Second))
	broker, err := openControlPipe(brokerPipe)
	if err != nil {
		t.Fatal(err)
	}
	defer broker.Close()
	broker.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err = io.WriteString(broker, name+"\n"); err != nil {
		t.Fatal(err)
	}
	response, err := bufio.NewReader(broker).ReadString('\n')
	if err != nil || response != "READY\n" {
		t.Fatalf("broker: %q %v", response, err)
	}
	io.WriteString(broker, "ACK\n")
	if _, err = io.WriteString(private, "{}\n"); err != nil {
		t.Fatal(err)
	}
	response, err = bufio.NewReader(private).ReadString('\n')
	if err != nil || !strings.Contains(response, `"code":"invalid_config"`) {
		t.Fatalf("invalid fixture: %q %v", response, err)
	}
}

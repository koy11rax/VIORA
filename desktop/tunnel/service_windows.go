package main

import (
	"bufio"
	"errors"
	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"runtime/debug"
	"strings"
	"sync"
	"time"
	"unsafe"
)

const serviceName = "VioraTunnel"
const brokerPipe = `\\.\pipe\Viora.Control.v1`

var privatePipePattern = regexp.MustCompile(`^\\\\\.\\pipe\\Viora-[a-f0-9]{32}$`)

type tunnelService struct{}

func platformService() bool {
	if len(os.Args) != 2 || os.Args[1] != "--service" {
		return false
	}
	// Keep a crash trace in the administrator-protected engine directory.
	// No imported config, subscription URL or child output is logged.
	if executable, err := os.Executable(); err == nil && trustedInstall(filepath.Dir(executable)) {
		if output, err := os.OpenFile(filepath.Join(filepath.Dir(executable), "service-crash.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600); err == nil {
			debug.SetCrashOutput(output, debug.CrashOptions{})
			output.Close()
		}
	}
	if err := svc.Run(serviceName, tunnelService{}); err != nil {
		os.Exit(2)
	}
	return true
}
func (tunnelService) Execute(_ []string, requests <-chan svc.ChangeRequest, changes chan<- svc.Status) (bool, uint32) {
	changes <- svc.Status{State: svc.StartPending}
	configureServiceRecovery()
	// Only interactive local users can request a validated VPN session. The
	// endpoint never accepts commands, executable paths, keys or config files.
	descriptor, err := windows.SecurityDescriptorFromString("D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;IU)")
	if err != nil {
		return false, 1
	}
	attrs := windows.SecurityAttributes{Length: uint32(unsafe.Sizeof(windows.SecurityAttributes{})), SecurityDescriptor: descriptor}
	name, _ := windows.UTF16PtrFromString(brokerPipe)
	handle, err := windows.CreateNamedPipe(name, windows.PIPE_ACCESS_DUPLEX|windows.FILE_FLAG_OVERLAPPED|windows.FILE_FLAG_FIRST_PIPE_INSTANCE,
		windows.PIPE_TYPE_BYTE|windows.PIPE_WAIT|windows.PIPE_REJECT_REMOTE_CLIENTS, 1, 4096, 4096, 0, &attrs)
	if err != nil {
		return false, 2
	}
	listener := os.NewFile(uintptr(handle), brokerPipe)
	stop := make(chan struct{})
	done := make(chan struct{})
	sessions := &serviceSessions{}
	owners, err := installedOwnerStore()
	if err != nil {
		listener.Close()
		// This is an application validation failure, not Win32 PATH_NOT_FOUND.
		return true, trustServiceCode(err)
	}
	go func() {
		defer close(done)
		serveBroker(listener, stop, sessions, runWithProtection, owners, systemProtection)
	}()
	current := svc.Status{State: svc.Running, Accepts: svc.AcceptStop | svc.AcceptShutdown}
	changes <- current
	for {
		var request svc.ChangeRequest
		select {
		case <-done:
			listener.Close()
			sessions.close()
			sessions.wait.Wait()
			return false, 1
		case next, ok := <-requests:
			if !ok {
				close(stop)
				listener.Close()
				<-done
				sessions.close()
				sessions.wait.Wait()
				return false, 0
			}
			request = next
		}
		switch request.Cmd {
		case svc.Interrogate:
			changes <- current
		case svc.Stop, svc.Shutdown:
			changes <- svc.Status{State: svc.StopPending, WaitHint: 10000}
			close(stop)
			listener.Close()
			<-done
			sessions.close()
			sessions.wait.Wait()
			return false, 0
		}
	}
}

func configureServiceRecovery() {
	manager, err := mgr.Connect()
	if err != nil {
		return
	}
	defer manager.Disconnect()
	service, err := manager.OpenService(serviceName)
	if err != nil {
		return
	}
	defer service.Close()
	// SCM restarts only the service after a failure, never the user's machine.
	service.SetRecoveryActions([]mgr.RecoveryAction{
		{Type: mgr.ServiceRestart, Delay: time.Second},
		{Type: mgr.ServiceRestart, Delay: 5 * time.Second},
		{Type: mgr.NoAction},
	}, 86400)
	service.SetRecoveryActionsOnNonCrashFailures(true)
}

type serviceSessions struct {
	mutex  sync.Mutex
	active *os.File
	wait   sync.WaitGroup
}

func (s *serviceSessions) close() {
	s.mutex.Lock()
	defer s.mutex.Unlock()
	if s.active != nil {
		s.active.Close()
	}
}

func sessionPipe(name string, owner uint32) (*os.File, error) {
	if !privatePipePattern.MatchString(name) || owner == 0 {
		return nil, errors.New("invalid endpoint")
	}
	pipe, err := openControlPipe(name)
	if err != nil {
		return nil, err
	}
	var actual uint32
	if err = windows.GetNamedPipeServerProcessId(windows.Handle(pipe.Fd()), &actual); err != nil || actual != owner {
		pipe.Close()
		return nil, errors.New("endpoint owner mismatch")
	}
	pipe.SetReadDeadline(time.Now().Add(5 * time.Second))
	return pipe, nil
}

func serveBroker(listener *os.File, stop <-chan struct{}, sessions *serviceSessions, session func(io.ReadCloser, io.Writer, func(string) (bool, error)), owners ownerStore, system func(string) (bool, error)) {
	handle := windows.Handle(listener.Fd())
	for {
		select {
		case <-stop:
			return
		default:
		}
		event, err := windows.CreateEvent(nil, 1, 0, nil)
		if err != nil {
			return
		}
		operation := windows.Overlapped{HEvent: event | 1}
		err = windows.ConnectNamedPipe(handle, &operation)
		if err == windows.ERROR_IO_PENDING {
			for {
				select {
				case <-stop:
					windows.CancelIoEx(handle, &operation)
				default:
				}
				result, _ := windows.WaitForSingleObject(event, 100)
				if result == windows.WAIT_OBJECT_0 {
					var n uint32
					err = windows.GetOverlappedResult(handle, &operation, &n, false)
					break
				}
			}
		}
		windows.CloseHandle(event)
		if err != nil && err != windows.ERROR_PIPE_CONNECTED {
			return
		}
		listener.SetDeadline(time.Now().Add(3 * time.Second))
		var owner uint32
		identityErr := windows.GetNamedPipeClientProcessId(handle, &owner)
		line, readErr := bufio.NewReader(io.LimitReader(listener, 1024)).ReadString('\n')
		var principal brokerPrincipal
		if identityErr == nil && readErr == nil {
			principal, identityErr = pipePrincipal(handle)
		}
		protection := ownedProtection{principal: principal, owners: owners, system: system}
		response := "ERROR\n"
		if identityErr == nil && readErr == nil && strings.HasPrefix(line, "PROTECTION ") {
			response = protectionCommandWith(strings.TrimSpace(strings.TrimPrefix(line, "PROTECTION ")), protection.command) + "\n"
		} else if identityErr == nil && readErr == nil {
			sessions.mutex.Lock()
			if sessions.active != nil {
				response = "BUSY\n"
			} else {
				pipe, err := sessionPipe(strings.TrimSuffix(line, "\n"), owner)
				if err == nil {
					sessions.active = pipe
					sessions.wait.Add(1)
					response = "READY\n"
					go func() {
						defer sessions.wait.Done()
						session(pipe, pipe, protection.session)
						pipe.Close()
						sessions.mutex.Lock()
						sessions.active = nil
						sessions.mutex.Unlock()
					}()
				}
			}
			sessions.mutex.Unlock()
		}
		io.WriteString(listener, response)
		// Wait for receipt rather than disconnecting with unread response data.
		// A deadline bounds an unresponsive interactive client.
		bufio.NewReader(io.LimitReader(listener, 8)).ReadString('\n')
		listener.SetDeadline(time.Time{})
		windows.DisconnectNamedPipe(handle)
	}
}

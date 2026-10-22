package main

import (
	"errors"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"unsafe"

	"golang.org/x/sys/windows"
)

var errPolicyOwner = errors.New("protection belongs to another account or requires administrator migration")

type brokerPrincipal struct {
	SID           string
	Administrator bool
}

// Only Windows' authenticated pipe token is used for authorization. The PID
// check still binds the private session pipe, but a caller-supplied identity is
// never accepted. Impersonation must stay on one OS thread and be reverted
// before any privileged filesystem, firewall or process operation.
func pipePrincipal(handle windows.Handle) (brokerPrincipal, error) {
	runtime.LockOSThread()
	impersonate := windows.NewLazySystemDLL("advapi32.dll").NewProc("ImpersonateNamedPipeClient")
	result, _, callErr := impersonate.Call(uintptr(handle))
	if result == 0 {
		runtime.UnlockOSThread()
		return brokerPrincipal{}, callErr
	}
	defer func() {
		if windows.RevertToSelf() != nil {
			panic("broker impersonation could not be reverted")
		}
		runtime.UnlockOSThread()
	}()
	var token windows.Token
	if err := windows.OpenThreadToken(windows.CurrentThread(), windows.TOKEN_QUERY, true, &token); err != nil {
		return brokerPrincipal{}, err
	}
	defer token.Close()
	user, err := token.GetTokenUser()
	if err != nil {
		return brokerPrincipal{}, err
	}
	administrators, err := windows.CreateWellKnownSid(windows.WinBuiltinAdministratorsSid)
	if err != nil {
		return brokerPrincipal{}, err
	}
	member, err := token.IsMember(administrators)
	if err != nil {
		return brokerPrincipal{}, err
	}
	var elevation uint32
	var size uint32
	if err := windows.GetTokenInformation(token, windows.TokenElevation, (*byte)(unsafe.Pointer(&elevation)), uint32(unsafe.Sizeof(elevation)), &size); err != nil {
		return brokerPrincipal{}, err
	}
	return brokerPrincipal{SID: user.User.Sid.String(), Administrator: member && elevation != 0}, nil
}

type ownerStore interface {
	Read() (string, error)
	Write(string) error
	Clear() error
}

type fileOwnerStore struct{ path string }

func installedOwnerStore() (ownerStore, error) {
	executable, err := os.Executable()
	if err != nil || !trustedInstall(filepath.Dir(executable)) {
		return nil, errors.New("untrusted owner directory")
	}
	return fileOwnerStore{filepath.Join(filepath.Dir(executable), "protection-owner.sid")}, nil
}

func validOwnerSID(value string) bool {
	if value == "" || len(value) > 184 || strings.ContainsAny(value, "\r\n\x00") {
		return false
	}
	_, err := windows.StringToSid(value)
	return err == nil
}

func (s fileOwnerStore) Read() (string, error) {
	info, err := os.Lstat(s.path)
	if os.IsNotExist(err) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	wide, err := windows.UTF16PtrFromString(s.path)
	if err != nil {
		return "", err
	}
	attributes, err := windows.GetFileAttributes(wide)
	if err != nil || attributes&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 || !info.Mode().IsRegular() || info.Size() > 185 {
		return "", errors.New("invalid owner marker")
	}
	file, err := os.Open(s.path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, 186))
	if err != nil {
		return "", err
	}
	value := strings.TrimSuffix(string(data), "\n")
	if !validOwnerSID(value) {
		return "", errors.New("invalid owner SID")
	}
	return value, nil
}

func (s fileOwnerStore) Write(value string) error {
	if !validOwnerSID(value) {
		return errors.New("invalid owner SID")
	}
	file, err := os.CreateTemp(filepath.Dir(s.path), "protection-owner-")
	if err != nil {
		return err
	}
	name := file.Name()
	defer os.Remove(name)
	if _, err = file.WriteString(value + "\n"); err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(name, s.path)
}

func (s fileOwnerStore) Clear() error {
	err := os.Remove(s.path)
	if os.IsNotExist(err) {
		return nil
	}
	return err
}

type ownedProtection struct {
	principal brokerPrincipal
	owners    ownerStore
	system    func(string) (bool, error)
}

func (p ownedProtection) apply(action string, session bool) (bool, error) {
	if !validOwnerSID(p.principal.SID) || p.owners == nil || p.system == nil {
		return false, errPolicyOwner
	}
	if action != "status" && action != "enable" && action != "disable" {
		return false, errors.New("invalid protection verb")
	}
	on, err := p.system("status")
	if err != nil {
		return false, err
	}
	// A read-only status query is available to all local users; a tunnel may
	// not replace another account's armed connection even in non-strict mode.
	if action == "status" && !session {
		return on, nil
	}
	if on {
		owner, readErr := p.owners.Read()
		if readErr != nil {
			return true, readErr
		}
		if !p.principal.Administrator && (owner == "" || owner != p.principal.SID) {
			return true, errPolicyOwner
		}
		if (action == "enable" || session) && owner == "" {
			if err := p.owners.Write(p.principal.SID); err != nil {
				return true, err
			}
		}
	}
	if action == "status" {
		return on, nil
	}
	if action == "enable" && !on {
		// Persist intent first; failure never silently arms an ownerless policy.
		if err := p.owners.Write(p.principal.SID); err != nil {
			return false, err
		}
	}
	result, err := p.system(action)
	if err != nil {
		return result, err
	}
	if action == "disable" && !result {
		if err := p.owners.Clear(); err != nil {
			return false, err
		}
	}
	return result, nil
}

func (p ownedProtection) command(action string) (bool, error) { return p.apply(action, false) }
func (p ownedProtection) session(action string) (bool, error) { return p.apply(action, true) }

package main

import (
	"errors"
	"golang.org/x/sys/windows"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"unsafe"
)

func openControl() (io.ReadCloser, io.Writer, error) {
	if len(os.Args) != 3 || os.Args[1] != "--pipe" || !regexp.MustCompile(`^\\\\\.\\pipe\\Viora-[a-f0-9]{32}$`).MatchString(os.Args[2]) || !windows.GetCurrentProcessToken().IsElevated() {
		return nil, nil, errors.New("invalid control")
	}
	f, err := openControlPipe(os.Args[2])
	return f, f, err
}

// Pending stop reads must not serialize status writes on the same pipe handle.
// Go 1.27 recognizes FILE_FLAG_OVERLAPPED in OpenFile and registers the handle
// with its I/O completion port, supporting full duplex reads and writes.
func openControlPipe(name string) (*os.File, error) {
	return os.OpenFile(name, os.O_RDWR|int(windows.FILE_FLAG_OVERLAPPED), 0)
}
func coreName() string                   { return "xray.exe" }
func applyPlatformConfig(map[string]any) {}
func applySystemProtection(settings map[string]any) {
	settings["autoSystemWfpBlockLeak"] = []string{"dns", "misconfigtun"}
}

type installTrustReason string

const (
	installTrustOK                installTrustReason = ""
	installTrustExecutable        installTrustReason = "executable"
	installTrustKnownFolder       installTrustReason = "knownfolder"
	installTrustDirectoryMismatch installTrustReason = "directorymismatch"
	installTrustEngineAttributes  installTrustReason = "engineattrs"
	installTrustCoreAttributes    installTrustReason = "coreattrs"
	installTrustXrayAttributes    installTrustReason = "xrayattrs"
	installTrustDriverAttributes  installTrustReason = "driverattrs"
	installTrustReparse           installTrustReason = "reparse"
)

// Reasons are fixed diagnostic identifiers, never OS error text or paths.
func (reason installTrustReason) Error() string {
	switch reason {
	case installTrustExecutable, installTrustKnownFolder, installTrustDirectoryMismatch,
		installTrustEngineAttributes, installTrustCoreAttributes, installTrustXrayAttributes,
		installTrustDriverAttributes, installTrustReparse:
		return string(reason)
	default:
		return "unknown"
	}
}

func trustedInstall(directory string) bool {
	return trustedInstallFailure(directory) == installTrustOK
}

func trustedInstallFailure(directory string) installTrustReason {
	return trustedInstallFailureWith(directory,
		func() (string, error) { return windows.KnownFolderPath(windows.FOLDERID_ProgramFiles, 0) },
		func(path string) (uint32, error) {
			wide, err := windows.UTF16PtrFromString(path)
			if err != nil {
				return 0, err
			}
			return windows.GetFileAttributes(wide)
		})
}

func trustedInstallFailureWith(directory string, knownRoot func() (string, error), attributes func(string) (uint32, error)) installTrustReason {
	root, err := knownRoot()
	if err != nil {
		return installTrustKnownFolder
	}
	if !strings.EqualFold(directory, filepath.Join(root, "Viora", "Engine")) {
		return installTrustDirectoryMismatch
	}
	for _, item := range []struct {
		path   string
		reason installTrustReason
	}{
		{directory, installTrustEngineAttributes},
		{filepath.Join(directory, "core"), installTrustCoreAttributes},
		{filepath.Join(directory, "core", "xray.exe"), installTrustXrayAttributes},
		{filepath.Join(directory, "core", "wintun.dll"), installTrustDriverAttributes},
	} {
		attrs, err := attributes(item.path)
		if err != nil {
			return item.reason
		}
		if attrs&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
			return installTrustReparse
		}
	}
	return installTrustOK
}
func verifiedDriver(directory, hash string) bool {
	return verifiedFile(filepath.Join(directory, "core", "wintun.dll"), hash)
}
func platformEnvironment() []string {
	root, err := windows.GetSystemDirectory()
	if err != nil {
		return nil
	}
	return []string{"SystemRoot=" + filepath.Dir(root), "WINDIR=" + filepath.Dir(root), "PATH=" + root, "TEMP=" + os.TempDir()}
}
func configureChild(cmd *exec.Cmd) error {
	kernel := windows.NewLazySystemDLL("kernel32.dll")
	kernel.NewProc("AllocConsole").Call()
	window, _, _ := kernel.NewProc("GetConsoleWindow").Call()
	if window != 0 {
		windows.NewLazySystemDLL("user32.dll").NewProc("ShowWindow").Call(window, 0)
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: windows.CREATE_NEW_PROCESS_GROUP, HideWindow: true}
	return nil
}
func containChild(cmd *exec.Cmd) (func(), error) {
	job, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return nil, err
	}
	cleanup := func() { windows.CloseHandle(job) }
	limits := windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION{}
	limits.BasicLimitInformation.LimitFlags = windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	_, err = windows.SetInformationJobObject(job, windows.JobObjectExtendedLimitInformation, uintptr(unsafe.Pointer(&limits)), uint32(unsafe.Sizeof(limits)))
	if err != nil {
		cleanup()
		return nil, err
	}
	process, err := windows.OpenProcess(windows.PROCESS_SET_QUOTA|windows.PROCESS_TERMINATE, false, uint32(cmd.Process.Pid))
	if err != nil {
		cleanup()
		return nil, err
	}
	defer windows.CloseHandle(process)
	if err = windows.AssignProcessToJobObject(job, process); err != nil {
		cleanup()
		return nil, err
	}
	return cleanup, nil
}
func interruptChild(cmd *exec.Cmd) {
	windows.NewLazySystemDLL("kernel32.dll").NewProc("GenerateConsoleCtrlEvent").Call(1, uintptr(cmd.Process.Pid))
}
func tunReady() bool {
	iface, err := net.InterfaceByName("viora0")
	return err == nil && iface.Flags&net.FlagUp != 0
}

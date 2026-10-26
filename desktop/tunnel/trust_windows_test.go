//go:build windows

package main

import (
	"errors"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"golang.org/x/sys/windows"
)

func TestTrustedInstallFailuresUseFixedReasonsForEveryCheck(t *testing.T) {
	const root = `C:\Program Files`
	directory := filepath.Join(root, "Viora", "Engine")
	paths := []string{directory, filepath.Join(directory, "core"), filepath.Join(directory, "core", "xray.exe"), filepath.Join(directory, "core", "wintun.dll"), filepath.Join(directory, "core", "sing-box.exe")}
	for _, fixture := range []struct {
		name      string
		rootError bool
		failAt    int
		reparseAt int
		want      installTrustReason
	}{
		{"success", false, -1, -1, installTrustOK},
		{"known folder", true, -1, -1, installTrustKnownFolder},
		{"engine attributes", false, 0, -1, installTrustEngineAttributes},
		{"core attributes", false, 1, -1, installTrustCoreAttributes},
		{"xray attributes", false, 2, -1, installTrustXrayAttributes},
		{"driver attributes", false, 3, -1, installTrustDriverAttributes},
		{"frontend attributes", false, 4, -1, installTrustFrontendAttributes},
		{"engine reparse", false, -1, 0, installTrustReparse},
		{"core reparse", false, -1, 1, installTrustReparse},
		{"xray reparse", false, -1, 2, installTrustReparse},
		{"driver reparse", false, -1, 3, installTrustReparse},
		{"frontend reparse", false, -1, 4, installTrustReparse},
	} {
		t.Run(fixture.name, func(t *testing.T) {
			var calls []string
			reason := trustedInstallFailureWith(directory, func() (string, error) {
				if fixture.rootError {
					return "", errors.New("private system path and diagnostic detail")
				}
				return root, nil
			}, func(path string) (uint32, error) {
				index := len(calls)
				calls = append(calls, path)
				if index == fixture.failAt {
					return 0, errors.New("private system path and diagnostic detail")
				}
				if index == fixture.reparseAt {
					return windows.FILE_ATTRIBUTE_REPARSE_POINT, nil
				}
				return windows.FILE_ATTRIBUTE_ARCHIVE, nil
			})
			if reason != fixture.want {
				t.Fatalf("reason = %q, want %q", reason, fixture.want)
			}
			count := len(paths)
			if fixture.rootError {
				count = 0
			} else if fixture.failAt >= 0 {
				count = fixture.failAt + 1
			} else if fixture.reparseAt >= 0 {
				count = fixture.reparseAt + 1
			}
			if len(calls) != count || !reflect.DeepEqual(calls, paths[:count]) && count != 0 {
				t.Fatal("trust checks were reordered, skipped, or continued after failure")
			}
			if reason != installTrustOK && (strings.Contains(reason.Error(), "private") || strings.Contains(reason.Error(), "C:")) {
				t.Fatal("underlying OS details crossed the static reason boundary")
			}
		})
	}
}

func TestTrustedFrontendMustBeAFile(t *testing.T) {
	const root = `C:\Program Files`
	directory := filepath.Join(root, "Viora", "Engine")
	reason := trustedInstallFailureWith(directory, func() (string, error) { return root, nil }, func(path string) (uint32, error) {
		if path == frontendPath(directory) {
			return windows.FILE_ATTRIBUTE_DIRECTORY, nil
		}
		return windows.FILE_ATTRIBUTE_ARCHIVE, nil
	})
	if reason != installTrustFrontendAttributes {
		t.Fatal("a directory at the frontend executable path was trusted")
	}
}

func TestTrustedInstallCanonicalDirectoryChecksAreNotRelaxed(t *testing.T) {
	const root = `C:\Program Files`
	canonical := filepath.Join(root, "Viora", "Engine")
	for _, directory := range []string{
		`D:\Viora\Engine`, `C:\Program Files\Other\Engine`,
		canonical + `\`, canonical + `\..\Engine`,
		`C:\PROGRA~1\Viora\Engine`, `\\?\` + canonical,
		`relative\Viora\Engine`,
	} {
		t.Run(directory, func(t *testing.T) {
			reason := trustedInstallFailureWith(directory, func() (string, error) { return root, nil }, func(string) (uint32, error) {
				t.Fatal("attribute checks reached an untrusted directory")
				return 0, nil
			})
			if reason != installTrustDirectoryMismatch {
				t.Fatal("a previously rejected directory became trusted")
			}
		})
	}
	if reason := trustedInstallFailureWith(strings.ToLower(canonical), func() (string, error) { return root, nil }, func(string) (uint32, error) { return 0, nil }); reason != installTrustOK {
		t.Fatal("the existing case-insensitive canonical comparison changed")
	}
}

func TestInstallTrustErrorsRemainTypedAndCannotExposeArbitraryText(t *testing.T) {
	var err error = installTrustCoreAttributes
	var reason installTrustReason
	if !errors.As(err, &reason) || reason != installTrustCoreAttributes || reason.Error() != "coreattrs" {
		t.Fatal("caller cannot recover the fixed typed owner-store reason")
	}
	for _, unsafe := range []installTrustReason{"https://private.example.invalid/token", "C:/private/path", "os_error_detail"} {
		if unsafe.Error() != "unknown" {
			t.Fatal("arbitrary text was accepted as a diagnostic error")
		}
	}
}

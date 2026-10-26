package main

import (
	"path/filepath"

	"golang.org/x/sys/windows"
)

// The privileged frontend path and expected digest never come from IPC, a
// subscription or the user-selected UI installation directory.
func frontendPath(directory string) string {
	return filepath.Join(directory, "core", "sing-box.exe")
}

func verifiedFrontend(directory string) bool {
	return verifiedFrontendWithHash(directory, frontendSHA)
}

func verifiedFrontendWithHash(directory, expected string) bool {
	path := frontendPath(directory)
	wide, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return false
	}
	attributes, err := windows.GetFileAttributes(wide)
	if err != nil || attributes&(windows.FILE_ATTRIBUTE_REPARSE_POINT|windows.FILE_ATTRIBUTE_DIRECTORY) != 0 {
		return false
	}
	return verifiedFile(path, expected)
}

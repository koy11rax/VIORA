package main

import (
	"os"
	"path/filepath"
	"syscall"
)

func frontendPath(directory string) string {
	return filepath.Join(directory, "core", "sing-box")
}

func verifiedFrontend(directory string) bool {
	return trustedInstall(directory) && verifiedFrontendWithHash(directory, frontendSHA)
}

func verifiedFrontendWithHash(directory, expected string) bool {
	path := frontendPath(directory)
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm()&0022 != 0 || info.Mode().Perm()&0111 == 0 {
		return false
	}
	owner, ok := info.Sys().(*syscall.Stat_t)
	return ok && owner.Uid == 0 && verifiedFile(path, expected)
}

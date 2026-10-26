package main

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"
)

func TestVerifiedFrontendUsesOnlyFixedFileAndBuildHash(t *testing.T) {
	directory := t.TempDir()
	if frontendPath(directory) != filepath.Join(directory, "core", "sing-box.exe") {
		t.Fatal("frontend path is not the fixed private component path")
	}
	if err := os.Mkdir(filepath.Join(directory, "core"), 0700); err != nil {
		t.Fatal(err)
	}
	content := []byte("offline fixture bytes, never an executable")
	digest := sha256.Sum256(content)
	expected := hex.EncodeToString(digest[:])
	if verifiedFrontendWithHash(directory, expected) {
		t.Fatal("a missing frontend passed verification")
	}
	if err := os.WriteFile(frontendPath(directory), content, 0600); err != nil {
		t.Fatal(err)
	}
	if !verifiedFrontendWithHash(directory, expected) {
		t.Fatal("matching frontend bytes were rejected")
	}
	for _, badHash := range []string{"", "bad", expected[:63], expected[:63] + "!"} {
		if verifiedFrontendWithHash(directory, badHash) {
			t.Fatal("an absent or invalid build digest passed verification")
		}
	}
	if err := os.WriteFile(frontendPath(directory), append(content, 'x'), 0600); err != nil {
		t.Fatal(err)
	}
	if verifiedFrontendWithHash(directory, expected) {
		t.Fatal("modified frontend bytes passed verification")
	}
}

func TestVerifiedFrontendRejectsDirectoryInsteadOfExecutable(t *testing.T) {
	directory := t.TempDir()
	if err := os.MkdirAll(frontendPath(directory), 0700); err != nil {
		t.Fatal(err)
	}
	if verifiedFrontendWithHash(directory, "0000000000000000000000000000000000000000000000000000000000000000") {
		t.Fatal("directory was accepted as executable content")
	}
}

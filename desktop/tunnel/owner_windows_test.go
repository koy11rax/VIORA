package main

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"golang.org/x/sys/windows"
)

const ownerA = "S-1-5-21-100-200-300-1001"
const ownerB = "S-1-5-21-100-200-300-1002"

type memoryOwnerStore struct {
	value    string
	writeErr error
	readErr  error
}

func (m *memoryOwnerStore) Read() (string, error) { return m.value, m.readErr }
func (m *memoryOwnerStore) Write(value string) error {
	if m.writeErr != nil {
		return m.writeErr
	}
	m.value = value
	return nil
}
func (m *memoryOwnerStore) Clear() error { m.value = ""; return nil }

func TestProtectionOwnerRejectsOtherAccountAndSurvivesRestart(t *testing.T) {
	owners := &memoryOwnerStore{}
	on := false
	mutations := 0
	system := func(action string) (bool, error) {
		switch action {
		case "enable":
			on = true
			mutations++
		case "disable":
			on = false
			mutations++
		}
		return on, nil
	}
	a := ownedProtection{brokerPrincipal{SID: ownerA}, owners, system}
	if active, err := a.command("enable"); err != nil || !active || owners.value != ownerA {
		t.Fatal("owner enable failed")
	}
	// A new service object sees the same persistent marker after restart.
	b := ownedProtection{brokerPrincipal{SID: ownerB}, owners, system}
	for _, action := range []string{"enable", "disable"} {
		if _, err := b.command(action); !errors.Is(err, errPolicyOwner) {
			t.Fatalf("other account accepted for %s", action)
		}
	}
	if _, err := b.session("status"); !errors.Is(err, errPolicyOwner) {
		t.Fatal("other account could take over armed tunnel")
	}
	if status, err := b.command("status"); err != nil || !status {
		t.Fatal("read-only status was denied")
	}
	if mutations != 1 || !on || owners.value != ownerA {
		t.Fatal("rejected request changed policy/ownership")
	}
	a = ownedProtection{brokerPrincipal{SID: ownerA}, owners, system}
	if _, err := a.session("status"); err != nil {
		t.Fatal("same owner's reconnect denied after restart")
	}
	if active, err := a.command("disable"); err != nil || active || owners.value != "" {
		t.Fatal("owner disable failed")
	}
	if _, err := b.command("enable"); err != nil || owners.value != ownerB {
		t.Fatal("disabled policy could not acquire new owner")
	}
}

func TestProtectionLegacyMigrationAndAdministrativeRecovery(t *testing.T) {
	owners := &memoryOwnerStore{}
	on := true
	mutations := 0
	system := func(action string) (bool, error) {
		if action == "disable" {
			on = false
			mutations++
		}
		return on, nil
	}
	regular := ownedProtection{brokerPrincipal{SID: ownerA}, owners, system}
	if _, err := regular.command("disable"); !errors.Is(err, errPolicyOwner) {
		t.Fatal("unattributed legacy policy could be disabled")
	}
	if _, err := regular.session("status"); !errors.Is(err, errPolicyOwner) {
		t.Fatal("legacy protection silently attributed")
	}
	admin := ownedProtection{brokerPrincipal{SID: ownerB, Administrator: true}, owners, system}
	if _, err := admin.command("enable"); err != nil || owners.value != ownerB {
		t.Fatal("elevated migration failed")
	}
	if active, err := admin.command("disable"); err != nil || active || mutations != 1 || owners.value != "" {
		t.Fatal("administrator recovery failed")
	}
}

func TestProtectionOwnerPersistenceFailureNeverArmsPolicy(t *testing.T) {
	owners := &memoryOwnerStore{writeErr: errors.New("fixture storage failure")}
	mutations := 0
	p := ownedProtection{brokerPrincipal{SID: ownerA}, owners, func(action string) (bool, error) {
		if action != "status" {
			mutations++
		}
		return false, nil
	}}
	if _, err := p.command("enable"); err == nil || mutations != 0 {
		t.Fatal("ownerless policy was armed")
	}
	if _, err := p.command("recover"); err == nil || mutations != 0 {
		t.Fatal("broker accepted emergency verb")
	}
	p.principal.SID = "untrusted"
	if _, err := p.command("disable"); err == nil || mutations != 0 {
		t.Fatal("invalid identity accepted")
	}
}

func TestProtectionOwnerWritePrecedesEnableAndDisableFailureRetainsOwner(t *testing.T) {
	owners := &memoryOwnerStore{}
	on := false
	p := ownedProtection{brokerPrincipal{SID: ownerA}, owners, func(action string) (bool, error) {
		if action == "enable" {
			if owners.value != ownerA {
				t.Fatal("firewall enable preceded durable ownership")
			}
			on = true
		}
		if action == "disable" {
			return true, errors.New("fixture firewall failure")
		}
		return on, nil
	}}
	if _, err := p.session("enable"); err != nil {
		t.Fatal(err)
	}
	if _, err := p.command("disable"); err == nil || owners.value != ownerA {
		t.Fatal("failed disable forgot owner")
	}
	owners.readErr = errors.New("corrupt owner fixture")
	if _, err := p.session("status"); err == nil {
		t.Fatal("corrupt ownership accepted for tunnel")
	}
}

func TestOwnerMarkerAtomicReloadAndInvalidData(t *testing.T) {
	store := fileOwnerStore{filepath.Join(t.TempDir(), "owner.sid")}
	if value, err := store.Read(); err != nil || value != "" {
		t.Fatal("missing fixture marker failed")
	}
	for _, value := range []string{ownerA, ownerB} {
		if err := store.Write(value); err != nil {
			t.Fatal(err)
		}
		if got, err := store.Read(); err != nil || got != value {
			t.Fatal("owner reload did not match")
		}
	}
	for _, data := range []string{"invalid\n", ownerA + "\nextra", string(make([]byte, 300))} {
		if err := os.WriteFile(store.path, []byte(data), 0600); err != nil {
			t.Fatal(err)
		}
		if _, err := store.Read(); err == nil {
			t.Fatal("invalid owner marker accepted")
		}
	}
	if err := store.Clear(); err != nil {
		t.Fatal(err)
	}
}

func TestPipePrincipalFailsClosedForInvalidHandle(t *testing.T) {
	if principal, err := pipePrincipal(windows.InvalidHandle); err == nil || principal.SID != "" {
		t.Fatal("invalid pipe produced identity")
	}
}

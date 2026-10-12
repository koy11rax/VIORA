package libv2ray

import (
	"errors"
	"sync"
	"syscall"

	"github.com/xtls/xray-core/transport/internet"
)

// V2RayProtector routes core sockets outside Android's VPN interface.
// Java implements this with VpnService.protect(fd).
type V2RayProtector interface {
	Protect(fd int64) bool
}

var protectorState struct {
	sync.RWMutex
	protector V2RayProtector
}
var registerProtector sync.Once
var protectorRegistrationError error

// UseProtector installs one controller for all core outbound sockets. A missing
// or rejected protector fails the dial instead of feeding packets into the TUN.
func UseProtector(protector V2RayProtector) error {
	if protector == nil {
		return errors.New("VPN protector required")
	}
	protectorState.Lock()
	protectorState.protector = protector
	protectorState.Unlock()
	registerProtector.Do(func() {
		protectorRegistrationError = internet.RegisterDialerController(func(network, address string, conn syscall.RawConn) error {
			protectorState.RLock()
			current := protectorState.protector
			protectorState.RUnlock()
			if current == nil {
				return errors.New("VPN protector unavailable")
			}
			protected := false
			if err := conn.Control(func(fd uintptr) { protected = current.Protect(int64(fd)) }); err != nil {
				return errors.New("VPN socket control failed")
			}
			if !protected {
				return errors.New("VPN socket protection failed")
			}
			return nil
		})
	})
	return protectorRegistrationError
}

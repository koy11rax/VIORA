# Android socket protection

Base Xray: `701af60772cda123492f86e383e1fdba066614a9`, MPL-2.0.
Base file: `transport/internet/system_dialer.go`.
SHA-256: `9b9a498177bed28ce5ad0ccbc260fcd3f714a2eef0061802024aace91f00f595`.

The two outbound TCP/UDP controller loops return the controller error instead
of logging and continuing after a rejected `VpnService.protect(fd)` call.
This is required for Hysteria2's UDP transport as well as existing TCP transports.
Socket-option handling and all transport/TLS behavior remain unchanged.

`scripts/build-android-core.ps1` verifies the base hash and supplies this file
with an explicit Go overlay. The upstream module cache and vendor source are
not edited. It runs `TestProtectorRejectsTCPAndUDPBeforeDial` against the same
overlay before building all three Android ABIs.

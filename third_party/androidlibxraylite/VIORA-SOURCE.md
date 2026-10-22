# AndroidLibXrayLite — VIORA Android 0.7.2

Upstream: https://github.com/2dust/AndroidLibXrayLite
Tag: v26.10.10
Commit: 0a02333081243df017453ccb432ad3cafcfd69e3
License: LGPL-3.0 (LICENSE retained).

The baseline .go files, go.mod and go.sum were copied from that commit, with
the additional viora_protector.go bridge. It registers Android socket
protection using the core's system dialer controller. Its failures reject the
dial. It does not add DNS, TLS, routing or implicit bypass configuration.

Core: github.com/xtls/xray-core
v1.260327.1-0.20261010092107-701af60772cd (go.mod/go.sum).
Go: 1.27.2. gomobile/gobind: golang.org/x/mobile
v0.0.0-20260908204917-8b95e45f8d3e.

Built using scripts/build-android-core.ps1 (NDK 27.0.12077973, Android API 26,
arm64-v8a, armeabi-v7a, x86_64). Two builds on the same Windows host produced
SHA-256 87d921a767b604f1102295f7867cb0960ddd16f4a9d5cc084f1503fb74fc63d8.
This is evidence of repeatability on that host, not cross-host reproducibility.
The 0.7.2 signed APK uses this AAR and was tested on TECNO LJ9 / Android API 36.
The older 0.7.1 APK uses the legacy binary and is not covered by this provenance.

vendor/ contains dependencies copied by Go 1.27.2 go mod vendor, including
their license files and vendor/modules.txt. go.mod/go.sum pin module downloads.
Build tools and Android SDK/NDK remain separate prerequisites. No signing keys
are included. The Java integration source is in third_party/flutter_v2ray_client.

## Audited bridge revision — 2026-10-22

The current bridge also changes libv2ray_main.go and libv2ray_utils.go:
partial instances are closed on start failure/stop, and state/statistics reads
are synchronized with lifecycle changes. The private isRunning field has an
explicit GetIsRunning method, preserving the Java getIsRunning API and removing
the unlocked field setter. Resource/lifecycle regression tests accompany these
changes. No upstream transport implementation or dependency version changed.
go.sum adds four checksums for the pinned x/mobile generator's x/mod and x/tools
dependencies. The runtime vendor tree is unchanged.

An actual arm64-v8a/armeabi-v7a/x86_64 AAR was built and its Java classes inspected:
SHA-256 7c7028f5eac63f429507549ed081cf39cc68ece8d3fc355721922392b1823afb.
The earlier 87d921... hash above describes the historical baseline only.
The audited AAR is now the fetch-android-core.ps1 pin. Its compiled artifact
has not been used to claim successful live VPN/leak testing or reproducibility
across hosts. The build script checks exact tool versions and avoids gomobile
init, which could internally replace gobind with an unpinned @latest install.


## VIORA1.0 security toolchain revision — 2026-10-22

Go1.27.3 rebuilds the same audited Android bridge and unchanged runtime module
pins. It includes the crypto/x509 denylist fix in GO-2026-6809 / CVE-2026-111943;
Go1.27.2 is no longer the release build toolchain. The official Windows archive
metadata is https://go.dev/dl/?mode=json. Its SHA-256 was independently matched:
`f26081f438319757f8a1b46d7d0b2c5ec7583d4038e485e0aa725cfde7885fff`.
The archive was transported via the Aliyun Go mirror after official binary
endpoints returned404/403; its byte count and digest match official Go metadata.

The Android API26 / NDK27.0.12077973 source build produced the actual AAR
SHA-256 `92bb2f7dc8129b02c3f2de947e97395474a5ccc057a9aaec5edf37f8f35677cc`.
All three included ELF libraries (arm64-v8a, armeabi-v7a and x86_64) identify
Go1.27.3 in embedded build information. ZIP CRC and Java bridge API were checked.
fetch-android-core.ps1 now enforces this digest. Earlier hashes above remain
historical records; a single successful rebuild is not a claim of cross-host
reproducibility or a live VPN/leak test.

GHSA-259r-337f-4rfw affects compress/s2.NewDict and Dict.Encode. The locked
compress module is version1.18.2, but its s2 package is absent from the Android
vendor/runtime import set; this application uses zstd through uTLS. No blanket
module upgrade was applied for this unreachable advisory.

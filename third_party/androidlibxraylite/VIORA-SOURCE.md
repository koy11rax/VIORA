# AndroidLibXrayLite — VIORA Android 0.7.2

Upstream: https://github.com/2dust/AndroidLibXrayLite
Tag: v26.10.10
Commit: 0a02333081243df017453ccb432ad3cafcfd69e3
License: LGPL-3.0 (LICENSE retained).

The .go files, go.mod and go.sum are copied verbatim from that commit, except
for the additional viora_protector.go bridge. It registers Android socket
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

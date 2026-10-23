# Viora Android integration of flutter_v2ray_client 3.5.0

Upstream: https://github.com/amir-zr/flutter_v2ray_client (MIT, LICENSE retained).
Published pub archive SHA-256:
`d3f4282294379956705b3a1391f10bde83e8a9c6e6e3a642c236f9db18926085`.
Pinned source-built libv2ray.aar SHA-256 (Android 0.7.2):
`87d921a767b604f1102295f7867cb0960ddd16f4a9d5cc084f1503fb74fc63d8`.
Fetch/verify native artifact with `scripts/fetch-android-core.ps1`.

Source: `third_party/androidlibxraylite/VIORA-SOURCE.md`; build with
`scripts/build-android-core.ps1`. The local Go bridge protects outbound sockets
using VpnService.protect. Removed the legacy binary's server-specific protector
API call. Strict lockdown is checked after establishing the TUN and before
starting the core: Android's API requires active VPN ownership. System always-on
restore is identified by the protected android.net.VpnService start action.

Legacy 0.7.1 and earlier: AAR SHA-256
`a7096e4d6e4a71dcd49dfe57687a1b7907dc70af729029b38fa8258e9596c4aa`.
The upstream package advertises Xray 26.9.9. Embedded Go build metadata identifies
Xray `v1.260327.1-0.20260908222543-52a412d9e2f5`; AndroidLibXrayLite is a local
replacement with no recoverable revision. The AAR is an upstream binary,
not a locally reproducible source build. Its exact embedded dependency revisions
have not yet been audited; do not claim a full source/supply-chain audit.
Source build and complete redistribution materials are required before public
distribution. Retain AndroidLibXrayLite LGPL-3.0 and Xray MPL-2.0 notices.

Local modifications (Android only; other upstream platforms are not registered):
- 0.7.4: leave IPv6 unconfigured so Android blocks the unsupported family
  rather than advertising an IPv6 interface whose packets the core discards.
  Legacy DNS and optional subnet routes cannot implicitly enable IPv6.
- 0.7.3: advertise a virtual DNS address for the app's DNS handler; preserve
  legacy DNS addresses when restoring an older encrypted configuration.
- Match project's AGP 8.9.1 and compile SDK 36.
- Remove READ_EXTERNAL_STORAGE; omit unused legacy tun2socks JNI libraries.
- Remove implicit direct DNS routes from ensureTunInbound. Viora's validated
  config owns routing; DNS stays through proxy and IPv6 is captured/blocked.
- Add native allowed_apps handling, reject empty/conflicting lists, preserve
  except mode, never combine allowed/disallowed Android builder lists.
- Propagate validated MTU through Android interface and Xray TUN.
- Brand foreground notification as Viora, use its own monochrome icon.
- Return sanitized start errors. Android always-on support now restores the last
  configuration from an atomic AES-256-GCM file in noBackupFilesDir; its key is
  held in Android Keystore. A sticky restart restores only a wanted session;
  an Android always-on request may restore the last explicitly stopped profile.
- Recover the native tunnel after underlying network changes or core shutdown,
  with bounded retries and increasing delays. Manual stop cancels recovery.
- Require Android lockdown for strict mode; never silently downgrade protection.
- Acknowledge manual stop after service destruction, rather than before stopSelf:
  otherwise switching servers can destroy the newly started foreground service.
- Stop the service properly on failed startup and confirm native core is running
  before emitting CONNECTED. Preserve gomobile names/callbacks during release R8.

Native transport implementation is otherwise upstream. The Viora app
uses its own owned/cancelled status stream and does not use upstream Dart URL
parsers or implicit configuration generation. Configuration travels in explicit
service intents and is encrypted locally for restart; profile storage also uses
Android Keystore. No configuration is written to logs or Android backups.

## Audited native bridge — 2026-10-22

The active source-built AAR pin is now
7c7028f5eac63f429507549ed081cf39cc68ece8d3fc355721922392b1823afb.
It includes synchronized running/statistics access and cleanup of partially
started core instances. The Java getIsRunning method used here was inspected
in the newly built classes.jar and retains its signature. See
../androidlibxraylite/VIORA-SOURCE.md for source changes, provenance and limits.

## Android recovery and active probe — 2026-10-23

- Track physical networks using callback snapshots. Protected sockets follow
  Android's default network; do not advertise explicit Network.bindSocket use
  when no sockets are bound that way. Keep callback lifecycle on one handler.
- Broadcast the beginning of accepted tile/system starts with a private source
  marker so Flutter can distinguish a fresh session from late old events.
- Pass the active HTTPS probe URL across the daemon boundary explicitly, using
  a request ID, receiver-before-send ordering, bounded wait and final cleanup.
  Permit only the designated HTTPS generate_204 endpoints; retain certificate
  and hostname verification. The existing source-built AAR is unchanged.
- A successful active-core probe is not a TUN/DNS/leak test. No certificate
  bypass, plaintext fallback, user-data reset or host network change is added.

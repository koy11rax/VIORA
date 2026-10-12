# Android release sources

`Viora-Android-0.7.4-source.zip` contains the Android Flutter client, tests,
assets/license notices, Java integration, pinned AndroidLibXrayLite sources
and vendored Go dependencies. It excludes backend code, signing keys, user
profiles, databases, generated outputs and the native AAR binary.

Extract the archive preserving its directory structure. Prerequisites:
Flutter 3.35.5 / Dart 3.9.2, JDK 21, Android SDK platform 36,
NDK 27.0.12077973, Go 1.27.2, gomobile/gobind pinned by the core build script.
Additional Flutter/Gradle build dependencies require network access and are
resolved using pubspec.lock / Gradle configuration. See the upstream provenance
in third_party/androidlibxraylite/VIORA-SOURCE.md and the plugin VIORA-CHANGES.md.

On Windows, provide your own installed tool paths to
`scripts/build-android-core.ps1` (GoBin, MobileBin, JavaHome, AndroidSdk).
It creates artifacts/libv2ray-source-candidate.aar from the included sources.
Then run `scripts/fetch-android-core.ps1` to check the pinned checksum and copy
the AAR into the plugin. It does not fetch the legacy binary. Build the core
before running the app. Repeatability was checked on the original host, not
every toolchain host. A deliberately modified core requires updating the local
checksum in fetch-android-core.ps1 and replacing the plugin's AAR with your build;
do not describe that build as the original verified release.

In apps/client, run `flutter pub get`, `flutter analyze --no-pub`,
`flutter test --no-pub`, and `flutter build apk --debug` for a locally signed
test build. Configure android/local.properties for your SDK/Flutter paths if
your Flutter installation does not create it automatically.

To make a release build, use your own external signing profile with
`scripts/build-android-release.ps1 -SigningDirectory <external-directory>
-JavaHome <jdk> -AndroidSdk <sdk> -VersionName 0.7.4 -VersionCode 24`.
`-InitializeKey` is only for a new independent signing identity. Never replace
the owner's existing key. A build signed with another key cannot update the
official VIORA installation. The script's default tool paths describe the
original build machine and must be adapted to your environment.

Included licenses retain their terms. The original signed APK is supplied
separately. These materials enable rebuilding/modifying the Android client;
they do not include production server credentials or deployment access.

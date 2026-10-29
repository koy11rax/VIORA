#!/usr/bin/env bash
set -euo pipefail
export VIORA_VERSION="${VIORA_VERSION:-1.0.5}"
export VIORA_BUILD_NUMBER="${VIORA_BUILD_NUMBER:-35}"
cd "$(dirname "${BASH_SOURCE[0]}")/../apps/client"
command -v flutter >/dev/null || { echo 'Install Flutter 3.35.5 and add it to PATH'; exit 1; }
pkg-config --exists gtk+-3.0 libsecret-1 ayatana-appindicator3-0.1 || { echo 'Install GTK 3, libsecret and libayatana-appindicator3 development packages'; exit 1; }
flutter pub get --enforce-lockfile
flutter analyze --no-pub
if [[ "${VIORA_SKIP_TESTS:-0}" != 1 ]]; then flutter test --no-pub; fi
flutter build linux --release --no-pub --build-name "$VIORA_VERSION" --build-number "$VIORA_BUILD_NUMBER"
../../scripts/package-linux.sh
echo 'Install the .deb package with your distribution package manager.'
echo 'An unlocked Secret Service keyring is required for accounts and saved profiles.'

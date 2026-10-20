#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../apps/client"
command -v flutter >/dev/null || { echo 'Install Flutter 3.35.5 and add it to PATH'; exit 1; }
pkg-config --exists gtk+-3.0 libsecret-1 ayatana-appindicator3-0.1 || { echo 'Install GTK 3, libsecret and libayatana-appindicator3 development packages'; exit 1; }
flutter pub get
flutter analyze
if [[ "${VIORA_SKIP_TESTS:-0}" != 1 ]]; then flutter test; fi
flutter build linux --release --build-name "${VIORA_VERSION:-0.8.2}" --build-number 27
../../scripts/package-linux.sh
echo 'Install the .deb package with your distribution package manager.'
echo 'An unlocked Secret Service keyring is required for accounts and saved profiles.'

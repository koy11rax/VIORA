#!/usr/bin/env bash
set -euo pipefail
umask 022
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bundle="${1:-$root/apps/client/build/linux/x64/release/bundle}"
version="${VIORA_VERSION:-1.0.5}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid version'; exit 1; }
suffix="${VIORA_PACKAGE_SUFFIX:-}"
[[ "$suffix" =~ ^[A-Za-z0-9_-]*$ ]] || { echo 'Invalid package suffix'; exit 1; }
stage="$root/artifacts/Viora-Linux-$version$suffix-deb"
output="$root/artifacts/Viora-Linux-$version$suffix-amd64.deb"
[[ ! -e "$stage" && ! -e "$output" ]] || { echo 'Output already exists'; exit 1; }
source_archive="$root/toolchains/sing-box/sing-box-v1.14.4-source.zip"
for file in "$bundle/viora_client" "$root/artifacts/desktop-core/linux/xray" "$root/artifacts/desktop-core/linux/viora_tunnel" "$root/artifacts/desktop-core/linux/sing-box" \
 "$root/apps/client/assets/licenses/sing-box-GPL-3.0.txt" "$root/third_party/sing-box/COPYING" "$source_archive" \
 "$root/docs/linux-install-variants-$version.md" "$root/docs/linux-sing-box-provenance-1.0.5.md" \
 "$root/patches/sing-box-desktop/process_cache.go" "$root/patches/sing-box-desktop/process_cache_test.go" \
 "$root/patches/sing-box-desktop/README.md" "$root/scripts/build-linux-frontend.py" \
 "$root/docs/linux-frontend-source-pins-1.0.5.json"; do
  [[ -f "$file" && ! -L "$file" ]] || { echo "Missing or linked file: $file"; exit 1; }
done
[[ -d "$bundle/data" && -d "$bundle/lib" ]] || { echo 'Missing Flutter runtime'; exit 1; }
[[ -z "$(find "$bundle" -type l -print -quit)" ]] || { echo 'Linked file in Flutter bundle'; exit 1; }
# The TUN executable and corresponding source archive must be the reviewed pins.
# The privileged helper independently verifies the same executable at runtime.
frontend_sha="c555912d5dfe2a1dc541666bf4c404a13a7630a711898ceb1a7482e07b0b4032"
[[ "$(sha256sum "$root/artifacts/desktop-core/linux/sing-box" | cut -d' ' -f1)" == "$frontend_sha" ]] || { echo 'Unexpected sing-box frontend'; exit 1; }
[[ "$(sha256sum "$source_archive" | cut -d' ' -f1)" == 9037718f85b67a004517c6a9190b98c68483de643f57c62eb6c889e01beae4bc ]] || { echo 'Unexpected sing-box source archive'; exit 1; }
[[ "$(sha256sum "$root/patches/sing-box-desktop/process_cache.go" | cut -d' ' -f1)" == b418d8cbb9f19b1e02094421de778db61b3b9b13c6cbc95b0f803f0a324eeaa6 ]] || { echo 'Unexpected sing-box source overlay'; exit 1; }
[[ "$(sha256sum "$root/patches/sing-box-desktop/process_cache_test.go" | cut -d' ' -f1)" == f4f0458e2052d2f21a9d87c9c82459b8a4705ba1b7095599b85b4ebdbd8d5590 ]] || { echo 'Unexpected sing-box overlay tests'; exit 1; }
install -d "$stage/DEBIAN" "$stage/usr/lib/viora/core" "$stage/usr/lib/viora/licenses" "$stage/usr/bin" "$stage/usr/share/applications" "$stage/usr/share/icons/hicolor/256x256/apps" "$stage/usr/share/polkit-1/actions"
cp -a "$bundle/." "$stage/usr/lib/viora/"
install -m755 "$root/artifacts/desktop-core/linux/xray" "$stage/usr/lib/viora/core/xray"
install -m755 "$root/artifacts/desktop-core/linux/sing-box" "$stage/usr/lib/viora/core/sing-box"
install -m755 "$root/artifacts/desktop-core/linux/viora_tunnel" "$stage/usr/lib/viora/viora_tunnel"
install -m644 "$root/desktop/linux/dev.viora.tunnel.policy" "$stage/usr/share/polkit-1/actions/"
install -m644 "$root/desktop/linux/viora.desktop" "$stage/usr/share/applications/"
install -Dm644 "$root/desktop/linux/viora-lockdown.service" "$stage/usr/lib/systemd/system/viora-lockdown.service"
install -d "$stage/usr/lib/systemd/system/network-pre.target.wants"
ln -s ../viora-lockdown.service "$stage/usr/lib/systemd/system/network-pre.target.wants/viora-lockdown.service"
for service in NetworkManager systemd-networkd; do
 install -d "$stage/usr/lib/systemd/system/$service.service.d"
 printf '%s\n' '[Unit]' 'Requires=viora-lockdown.service' 'After=viora-lockdown.service' > "$stage/usr/lib/systemd/system/$service.service.d/50-viora-protection.conf"
done
install -m644 "$root/apps/client/assets/viora.png" "$stage/usr/share/icons/hicolor/256x256/apps/viora.png"
install -m644 "$root/apps/client/assets/licenses/Xray-MPL-2.0.txt" "$stage/usr/lib/viora/licenses/"
install -m644 "$root/apps/client/assets/licenses/sing-box-GPL-3.0.txt" "$stage/usr/lib/viora/licenses/"
install -m644 "$root/third_party/sing-box/COPYING" "$stage/usr/lib/viora/licenses/COPYING-sing-box-GPL-3.0.txt"
install -m644 "$source_archive" "$stage/usr/lib/viora/licenses/sing-box-1.14.4-source.zip"
install -m644 "$root/docs/linux-sing-box-provenance-1.0.5.md" "$stage/usr/lib/viora/licenses/sing-box-PROVENANCE.md"
install -d "$stage/usr/lib/viora/licenses/sing-box-viora"
install -m644 "$root/patches/sing-box-desktop/"{process_cache.go,process_cache_test.go,README.md} "$stage/usr/lib/viora/licenses/sing-box-viora/"
install -m644 "$root/scripts/build-linux-frontend.py" "$stage/usr/lib/viora/licenses/sing-box-viora/"
install -m644 "$root/docs/linux-frontend-source-pins-1.0.5.json" "$stage/usr/lib/viora/licenses/sing-box-viora/SOURCE-PINS.json"
printf '%s\n' '#!/bin/sh' 'exec /usr/lib/viora/viora_client "$@"' > "$stage/usr/bin/viora"
chmod 755 "$stage/usr/bin/viora"
cat > "$stage/DEBIAN/control" <<EOF
Package: viora
Version: $version
Architecture: amd64
Maintainer: VIORA <koy11rax@users.noreply.github.com>
Section: net
Priority: optional
Depends: libgtk-3-0, libsecret-1-0, libayatana-appindicator3-1, libstdc++6, libc6 (>= 2.35), policykit-1, nftables, iproute2, ca-certificates, systemd-resolved | systemd (<< 251)
Recommends: gnome-keyring
Description: VIORA VPN — клиент VPN и управление подпиской
 VLESS, выбор программ, маршрутизация, аккаунт Telegram и управление устройствами.
EOF
install -m644 "$root/docs/linux-install-variants-$version.md" "$stage/usr/lib/viora/READ-ME-RU.txt"
install -m644 "$root/apps/client/assets/licenses/flutter_v2ray_client-MIT.txt" "$stage/usr/lib/viora/licenses/"
cat > "$stage/usr/lib/viora/licenses/VIORA.txt" <<EOF
Отдельная лицензия собственного кода VIORA пока не назначена.
Публикация исходников сама по себе не предоставляет общую лицензию.
LicenseRef-VIORA обозначает этот статус, а не лицензию сторонних компонентов.
Сторонние лицензии: Xray MPL-2.0, sing-box GPL-3.0, Flutter BSD-3-Clause,
flutter_v2ray_client MIT. sing-box запускается отдельным процессом.
Полная GPL, уведомление и исходники sing-box находятся в этой папке.
Linux sing-box 1.14.4-viora.1 собран VIORA с опубликованным исправлением;
это не неизменённый официальный Linux binary. Overlay и сборщик — в sing-box-viora.
Полный набор уведомлений Flutter расположен в data/flutter_assets/NOTICES.Z.
Исходники клиента и закреплённых движков: Viora-Linux-$version-source.zip.
EOF
printf '%s\n' 'Xray source: https://github.com/XTLS/Xray-core/tree/701af60772cda123492f86e383e1fdba066614a9' > "$stage/usr/lib/viora/licenses/Xray-source.txt"
cat > "$stage/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = configure ] && command -v systemctl >/dev/null; then systemctl daemon-reload || true; fi
EOF
cat > "$stage/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = remove ] || [ "$1" = deconfigure ]; then
 /usr/lib/viora/viora_tunnel --protection recover
fi
EOF
chmod 755 "$stage/DEBIAN/postinst" "$stage/DEBIAN/prerm"
cat > "$stage/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
if command -v systemctl >/dev/null; then systemctl daemon-reload || true; fi
EOF
chmod 755 "$stage/DEBIAN/postrm"
find "$stage" -type d -exec chmod 755 {} +
find "$stage" -type f -exec chmod go-w {} +
dpkg-deb -Zgzip -z6 --root-owner-group --build "$stage" "$output"
(cd "$(dirname "$output")"; sha256sum "$(basename "$output")" > "$(basename "$output").sha256")
echo "$output"

#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bundle="${1:-$root/apps/client/build/linux/x64/release/bundle}"
version="${VIORA_VERSION:-0.8.2}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid version'; exit 1; }
suffix="${VIORA_PACKAGE_SUFFIX:-}"
[[ "$suffix" =~ ^[A-Za-z0-9_-]*$ ]] || { echo 'Invalid package suffix'; exit 1; }
stage="$root/artifacts/Viora-Linux-$version$suffix-deb"
output="$root/artifacts/Viora-Linux-$version$suffix-amd64.deb"
[[ ! -e "$stage" && ! -e "$output" ]] || { echo 'Output already exists'; exit 1; }
for file in "$bundle/viora_client" "$root/artifacts/desktop-core/linux/xray" "$root/artifacts/desktop-core/linux/viora_tunnel"; do
  [[ -f "$file" && ! -L "$file" ]] || { echo "Missing or linked file: $file"; exit 1; }
done
install -d "$stage/DEBIAN" "$stage/usr/lib/viora/core" "$stage/usr/lib/viora/licenses" "$stage/usr/bin" "$stage/usr/share/applications" "$stage/usr/share/icons/hicolor/256x256/apps" "$stage/usr/share/polkit-1/actions"
cp -a "$bundle/." "$stage/usr/lib/viora/"
install -m755 "$root/artifacts/desktop-core/linux/xray" "$stage/usr/lib/viora/core/xray"
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
printf '%s\n' '#!/bin/sh' 'exec /usr/lib/viora/viora_client "$@"' > "$stage/usr/bin/viora"
chmod 755 "$stage/usr/bin/viora"
cat > "$stage/DEBIAN/control" <<EOF
Package: viora
Version: $version
Architecture: amd64
Maintainer: VIORA <koy11rax@users.noreply.github.com>
Section: net
Priority: optional
Depends: libgtk-3-0, libsecret-1-0, libayatana-appindicator3-1, libstdc++6, libc6 (>= 2.35), policykit-1, nftables, systemd-resolved | systemd (<< 251)
Recommends: gnome-keyring
Description: VIORA VPN — клиент VPN и управление подпиской
 VLESS, выбор программ, маршрутизация, аккаунт Telegram и управление устройствами.
EOF
cat > "$stage/usr/lib/viora/READ-ME-RU.txt" <<EOF
VIORA Linux $version

Установка: sudo apt install ./$(basename "$output")
Запуск: VIORA в меню приложений или команда viora.
Требуются Debian/Ubuntu с glibc 2.35+, GTK 3 и разблокированным Secret Service.
Для первого сохранения аккаунта разблокируй системную связку ключей.
При подключении VPN Linux запрашивает разрешение polkit.

Список программ доступен в разделе «Приложения». Можно выбрать исполняемый
файл вручную, импортировать/экспортировать выбор через буфер обмена.
Для программ с обёртками, Flatpak или несколькими процессами может потребоваться
добавление фактического исполняемого файла. DNS остаётся через VPN.
Постоянная блокировка доступна в настройках защиты и сохраняется после выхода. Прямые исключения при ней блокируются. Для восстановления интернета без VPN выключи защиту в приложении либо выполни sudo /usr/lib/viora/viora_tunnel --protection recover.

Трей использует AppIndicator/StatusNotifier. В некоторых окружениях GNOME
потребуется поддержка индикаторов в панели. Если хост трея отсутствует,
крестик минимизирует окно, чтобы приложение не стало недоступным.
Меню трея: подключение, отключение, серверы, подписки, пинг, настройки и выход.
Повторный запуск открывает существующее окно. Полный выход останавливает VPN.

По просьбе владельца реальное VPN-соединение при подготовке сборки
не запускалось и не проверялось. Сборка не является проверкой маршрутов
или утечек. SHA-256 файл подтверждает целостность пакета, а не подпись издателя.
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
sha256sum "$output" > "$output.sha256"
echo "$output"

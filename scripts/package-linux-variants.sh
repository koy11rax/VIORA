#!/usr/bin/env bash
# Native package formats from the same verified Linux payload; never runs VPN.
set -euo pipefail
umask 022
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="${VIORA_VERSION:-1.0.0}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
deb="${1:-$root/artifacts/Viora-Linux-$version-amd64.deb}"
for tool in dpkg-deb rpmbuild makepkg bsdtar fakeroot zstd sha256sum; do
  command -v "$tool" >/dev/null || { echo "Missing tool: $tool"; exit 1; }
done
[[ -f "$deb" && ! -L "$deb" && -f "$deb.sha256" ]] || { echo 'Missing verified DEB'; exit 1; }
expected="$(awk 'NR==1 {print $1}' "$deb.sha256")"
[[ "$expected" =~ ^[0-9a-f]{64}$ && "$(sha256sum "$deb" | cut -d' ' -f1)" == "$expected" ]] || exit 1
[[ "$(dpkg-deb -f "$deb" Version)" == "$version" && "$(dpkg-deb -f "$deb" Architecture)" == amd64 ]] || exit 1
work="$root/artifacts/linux-variants-$version"
[[ ! -e "$work" ]] || { echo 'Variant work directory already exists'; exit 1; }
mkdir -p "$work/payload" "$work/rpm/"{SOURCES,SPECS,BUILD,BUILDROOT,RPMS,SRPMS} "$work/arch"
dpkg-deb -x "$deb" "$work/payload"
install -m644 "$root/docs/linux-install-variants-$version.md" "$work/payload/usr/lib/viora/READ-ME-RU.txt"
install -m644 "$root/apps/client/assets/licenses/flutter_v2ray_client-MIT.txt" "$work/payload/usr/lib/viora/licenses/"
cat > "$work/payload/usr/lib/viora/licenses/VIORA.txt" <<EOF
Отдельная лицензия собственного кода VIORA пока не назначена.
Публикация исходников сама по себе не предоставляет общую лицензию.
LicenseRef-VIORA обозначает этот статус, а не лицензию сторонних компонентов.
Сторонние лицензии: Xray MPL-2.0, Flutter BSD-3-Clause, flutter_v2ray_client MIT.
Полный набор уведомлений Flutter расположен в data/flutter_assets/NOTICES.Z.
Исходники клиента и закреплённого движка: Viora-Desktop-$version-source.zip.
EOF
find "$work/payload" -type d -exec chmod 755 {} +
find "$work/payload" -type f -exec chmod go-w {} +
# No privileged ownership changes required on the build host.
payload="Viora-Linux-$version-payload.tar.gz"
tar --sort=name --owner=0 --group=0 --numeric-owner -C "$work/payload" -cf - usr | gzip -6 > "$work/$payload"
payload_sha="$(sha256sum "$work/$payload" | cut -d' ' -f1)"
cp "$work/$payload" "$work/rpm/SOURCES/"
sed "s/@VERSION@/$version/g" "$root/desktop/linux/viora.spec.in" > "$work/rpm/SPECS/viora.spec"
rpmbuild -bb --target x86_64 --define "_topdir $work/rpm" "$work/rpm/SPECS/viora.spec"
rpm="$root/artifacts/Viora-Linux-$version-1.x86_64.rpm"
[[ ! -e "$rpm" ]] || { echo 'RPM output already exists'; exit 1; }
cp "$work/rpm/RPMS/x86_64/viora-$version-1.x86_64.rpm" "$rpm"
cp "$work/$payload" "$work/arch/"
cp "$root/desktop/linux/viora.install" "$work/arch/"
sed -e "s/@VERSION@/$version/g" -e "s/@SHA256@/$payload_sha/g" "$root/desktop/linux/PKGBUILD.in" > "$work/arch/PKGBUILD"
(
  cd "$work/arch"
  # The payload was compiled already. The build VM is Ubuntu, so dependency
  # resolution is performed by pacman on the target, never faked on this VM.
  PKGEXT='.pkg.tar.zst' makepkg --nodeps --noconfirm --nosign
  makepkg --printsrcinfo > .SRCINFO
)
arch="$root/artifacts/viora-bin-$version-1-x86_64.pkg.tar.zst"
[[ ! -e "$arch" ]] || { echo 'Arch output already exists'; exit 1; }
cp "$work/arch/viora-bin-$version-1-x86_64.pkg.tar.zst" "$arch"
for package in "$rpm" "$arch"; do
  (cd "$(dirname "$package")"; sha256sum "$(basename "$package")" > "$(basename "$package").sha256")
done
# Reusable local recipes include the exact binary source and its hash.
tar --owner=0 --group=0 --numeric-owner -C "$work/arch" -czf "$root/artifacts/Viora-Linux-$version-Arch-recipe.tar.gz" PKGBUILD .SRCINFO viora.install "$payload"
cp "$work/rpm/SPECS/viora.spec" "$root/artifacts/Viora-Linux-$version.spec"
echo "$rpm"
echo "$arch"

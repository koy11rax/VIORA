#!/usr/bin/env bash
# Native package formats from the same verified Linux payload; never runs VPN.
set -euo pipefail
umask 022
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="${VIORA_VERSION:-1.0.5}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
deb="${1:-$root/artifacts/Viora-Linux-$version-amd64.deb}"
for tool in dpkg-deb rpmbuild makepkg pacman bsdtar fakeroot zstd sha256sum; do
  command -v "$tool" >/dev/null || { echo "Missing tool: $tool"; exit 1; }
done
# makepkg may continue after a failing pacman subprocess while constructing
# BUILDINFO. Reject a broken tool runtime before producing any variants.
pacman --version >/dev/null
[[ -f "$deb" && ! -L "$deb" && -f "$deb.sha256" ]] || { echo 'Missing verified DEB'; exit 1; }
expected="$(awk 'NR==1 {print $1}' "$deb.sha256")"
[[ "$expected" =~ ^[0-9a-f]{64}$ && "$(sha256sum "$deb" | cut -d' ' -f1)" == "$expected" ]] || exit 1
[[ "$(dpkg-deb -f "$deb" Version)" == "$version" && "$(dpkg-deb -f "$deb" Architecture)" == amd64 ]] || exit 1
work="$root/artifacts/linux-variants-$version"
[[ ! -e "$work" ]] || { echo 'Variant work directory already exists'; exit 1; }
mkdir -p "$work/payload" "$work/rpm/"{SOURCES,SPECS,BUILD,BUILDROOT,RPMS,SRPMS} "$work/arch"
dpkg-deb -x "$deb" "$work/payload"
# Keep the DEB's verified payload byte for byte, including license/source files.
# Metadata recipes below supply only target package-manager dependencies/hooks.
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
cp "$work/$payload" "$root/artifacts/$payload"
for artifact in "$root/artifacts/Viora-Linux-$version-Arch-recipe.tar.gz" "$root/artifacts/Viora-Linux-$version.spec" "$root/artifacts/$payload"; do
  (cd "$(dirname "$artifact")"; sha256sum "$(basename "$artifact")" > "$(basename "$artifact").sha256")
done
echo "$rpm"
echo "$arch"

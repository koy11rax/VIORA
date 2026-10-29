"""Verify RPM/pacman metadata and every payload byte without installation/VPN."""
from pathlib import Path
import hashlib
import json
import os
import re
import stat
import subprocess
import zipfile

# RPM does not own shared parent directories such as /usr. libarchive creates
# these while extracting, using the verifier's umask rather than package data.
os.umask(0o022)

repo = Path(__file__).resolve().parent.parent
version = os.environ.get('VIORA_VERSION', '1.0.5')
if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version):
    raise ValueError('Invalid version')
work = repo / 'artifacts' / f'linux-variants-{version}'
baseline = work / 'payload'


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify_checksum(path):
    fields = path.with_name(path.name + '.sha256').read_text().split()
    require(len(fields) == 2 and fields[1] == path.name,
            f'Invalid checksum sidecar: {path.name}')
    require(fields[0] == digest(path), f'Checksum mismatch: {path.name}')


def require_x64_elf(path):
    with path.open('rb') as stream:
        header = stream.read(20)
    require(len(header) == 20 and header[:6] == b'\x7fELF\x02\x01'
            and int.from_bytes(header[18:20], 'little') == 62,
            f'Expected Linux x86_64 ELF: {path.name}')


def snapshot(root, *, build_output=False):
    result = {}
    for path in sorted(root.rglob('*')):
        name = path.relative_to(root).as_posix()
        info = path.lstat()
        if path.is_symlink():
            if name == 'usr/lib/systemd/system/network-pre.target.wants/viora-lockdown.service' and os.readlink(path) == '../viora-lockdown.service':
                result[name] = {'link': '../viora-lockdown.service'}
                continue
            raise ValueError(f'Unexpected payload symlink: {name}')
        forbidden = stat.S_ISUID | stat.S_ISGID
        if not build_output:
            forbidden |= stat.S_IWGRP | stat.S_IWOTH
        if info.st_mode & forbidden:
            raise ValueError(f'Unexpected permissions: {name}')
        if path.is_file():
            result[name] = {'sha256': digest(path), 'mode': stat.S_IMODE(info.st_mode) & ~0o022}
    return result


expected = snapshot(baseline)
require(bool(expected), 'Missing baseline payload')
for name in ['xray', 'sing-box', 'viora_tunnel']:
    relative = ('usr/lib/viora/' if name == 'viora_tunnel' else 'usr/lib/viora/core/') + name
    payload = baseline / relative
    require_x64_elf(payload)
    require(digest(payload) == digest(repo / 'artifacts/desktop-core/linux' / name),
            f'Packaged native binary differs from build output: {name}')
    require(stat.S_IMODE(payload.stat().st_mode) == 0o755,
            f'Invalid executable permissions: {name}')
require_x64_elf(baseline / 'usr/lib/viora/viora_client')
require(digest(baseline / 'usr/lib/viora/core/sing-box') ==
        'c555912d5dfe2a1dc541666bf4c404a13a7630a711898ceb1a7482e07b0b4032',
        'Unexpected source-built sing-box 1.14.4-viora.1 frontend')
helper_bytes = (baseline / 'usr/lib/viora/viora_tunnel').read_bytes()
for component in ['xray', 'sing-box']:
    require(digest(baseline / 'usr/lib/viora/core' / component).encode('ascii') in helper_bytes,
            f'Helper does not embed the installed {component} integrity pin')
require(b'go1.27.3' in helper_bytes, 'Unexpected helper compiler version')
for relative, source in {
    'COPYING-sing-box-GPL-3.0.txt': 'third_party/sing-box/COPYING',
    'sing-box-GPL-3.0.txt': 'apps/client/assets/licenses/sing-box-GPL-3.0.txt',
    'sing-box-PROVENANCE.md': 'docs/linux-sing-box-provenance-1.0.5.md',
    'sing-box-1.14.4-source.zip': 'toolchains/sing-box/sing-box-v1.14.4-source.zip',
    'sing-box-viora/process_cache.go': 'patches/sing-box-desktop/process_cache.go',
    'sing-box-viora/process_cache_test.go': 'patches/sing-box-desktop/process_cache_test.go',
    'sing-box-viora/README.md': 'patches/sing-box-desktop/README.md',
    'sing-box-viora/build-linux-frontend.py': 'scripts/build-linux-frontend.py',
    'sing-box-viora/SOURCE-PINS.json': 'docs/linux-frontend-source-pins-1.0.5.json',
}.items():
    require(digest(baseline / 'usr/lib/viora/licenses' / relative) == digest(repo / source),
            f'Missing or modified upstream source/license: {relative}')
require(digest(baseline / 'usr/lib/viora/licenses/sing-box-1.14.4-source.zip') ==
        '9037718f85b67a004517c6a9190b98c68483de643f57c62eb6c889e01beae4bc',
        'Unexpected sing-box source archive')
pins = json.loads((baseline / 'usr/lib/viora/licenses/sing-box-viora/SOURCE-PINS.json').read_text())
require(pins['version'] == '1.14.4-viora.1' and pins['compiler'] == 'go1.27.3'
        and pins['goos'] == 'linux' and pins['goarch'] == 'amd64'
        and pins['cgo_enabled'] == '0' and pins['build_tags'] == [],
        'Unexpected frontend source/build identity')
for relative, expected_hash in pins['files'].items():
    require(digest(repo / relative) == expected_hash, f'Modified frontend build input: {relative}')
require(digest(baseline / 'usr/lib/viora/core/sing-box') == pins['binary_sha256'],
        'Frontend binary differs from source manifest')
with zipfile.ZipFile(baseline / 'usr/lib/viora/licenses/sing-box-1.14.4-source.zip') as archive:
    upstream_process_cache = archive.read('sing-box-1.14.4/route/process_cache.go')
require(hashlib.sha256(upstream_process_cache.replace(b'\r\n', b'\n')).hexdigest() ==
        pins['upstream_route_process_cache_sha256'], 'Unexpected upstream file for the overlay')
# Compare all UI bytes with the actual Flutter build, not just the DEB baseline.
bundle_files = snapshot(repo / 'apps/client/build/linux/x64/release/bundle', build_output=True)
require(bool(bundle_files), 'Missing Flutter build output')
for relative, value in bundle_files.items():
    require(expected.get('usr/lib/viora/' + relative) == value,
            f'Flutter bundle differs from build output: {relative}')
report = {'version': version, 'runtimeTests': 'vpn-and-firewall-not-run', 'packages': {}}
for kind, name in [
    ('deb', f'Viora-Linux-{version}-amd64.deb'),
    ('rpm', f'Viora-Linux-{version}-1.x86_64.rpm'),
    ('arch', f'viora-bin-{version}-1-x86_64.pkg.tar.zst'),
]:
    package = repo / 'artifacts' / name
    verify_checksum(package)
    dest = work / f'verified-{kind}'
    dest.mkdir()  # Never overwrite a prior verification tree.
    if kind == 'deb':
        subprocess.run(['dpkg-deb', '-x', str(package), str(dest)], check=True)
    else:
        for entry in run('bsdtar', '-tf', str(package)).splitlines():
            relative = Path(entry)
            if relative.is_absolute() or '..' in relative.parts:
                raise ValueError(f'Unsafe archive path: {entry}')
        subprocess.run(['bsdtar', '-xf', str(package), '-C', str(dest)], check=True)
    actual = {n: v for n, v in snapshot(dest).items() if n.startswith('usr/')}
    if actual != expected:
        raise ValueError(f'{kind}: payload differs from the verified binary source')
    if kind == 'deb':
        metadata = run('dpkg-deb', '-f', str(package), 'Package', 'Version', 'Architecture', 'Depends')
        require(run('dpkg-deb', '-f', str(package), 'Package') == 'viora', 'Invalid DEB package name')
        require(run('dpkg-deb', '-f', str(package), 'Version') == version, 'Invalid DEB version')
        require(run('dpkg-deb', '-f', str(package), 'Architecture') == 'amd64', 'Invalid DEB architecture')
        require('iproute2' in metadata and 'nftables' in metadata
                and 'ca-certificates' in metadata and 'systemd-resolved' in metadata,
                'Missing Linux routing/DNS dependencies')
        controls = work / 'verified-deb-controls'
        subprocess.run(['dpkg-deb', '-e', str(package), str(controls)], check=True)
        prerm = (controls / 'prerm').read_text()
        require('--protection recover' in prerm and '"$1" = remove' in prerm,
                'DEB full-removal recovery missing')
        require('--protection enable' not in (controls / 'postinst').read_text(),
                'DEB installation must not enable protection')
        listing = run('dpkg-deb', '-c', str(package))
        require(all('root/root' in line for line in listing.splitlines()), 'DEB ownership mismatch')
    elif kind == 'rpm':
        require(run('rpm', '-qp', '--qf', '%{NAME} %{VERSION} %{ARCH}', str(package)) == f'viora {version} x86_64', 'Invalid RPM identity')
        scripts = run('rpm', '-qp', '--scripts', str(package))
        require('--protection recover' in scripts and 'daemon-reload' in scripts
                and '"$1" = 0' in scripts, 'RPM full-removal recovery missing')
        require('--protection enable' not in scripts and '--restore-protection' not in scripts,
                'RPM installation must not enable protection')
        metadata = run('rpm', '-qp', '--requires', str(package))
        require('systemd-resolved' in metadata and 'iproute' in metadata
                and 'ca-certificates' in metadata and 'libflutter_linux_gtk.so' not in metadata,
                'Invalid RPM dependencies')
        require('GPL-3.0-or-later' in run('rpm', '-qp', '--qf', '%{LICENSE}', str(package)),
                'Missing sing-box license metadata')
        # RPM contains ownership separately from unprivileged extraction.
        ownership = run('rpm', '-qp', '--qf', '[%{FILEUSERNAME}:%{FILEGROUPNAME}\n]', str(package))
        require(set(ownership.splitlines()) == {'root:root'}, 'RPM ownership mismatch')
        check = run('rpm', '-K', str(package))
        require('digests OK' in check, 'RPM digest verification failed')
    else:
        metadata = run('pacman', '-Qip', str(package))
        require('viora-bin' in metadata and f'{version}-1' in metadata, 'Invalid Arch identity')
        require((dest / '.MTREE').is_file() and (dest / '.BUILDINFO').is_file(), 'Missing Arch build metadata')
        info = (dest / '.PKGINFO').read_text()
        require('arch = x86_64' in info and 'depend = systemd' in info
                and 'depend = iproute2' in info and 'depend = ca-certificates' in info,
                'Invalid Arch dependencies')
        require('license = GPL-3.0-or-later' in info, 'Missing sing-box license metadata')
        install = (dest / '.INSTALL').read_text()
        require('pre_remove()' in install and '--protection recover' in install,
                'Arch full-removal recovery missing')
        require('--protection enable' not in install, 'Arch installation must not enable protection')
        listing = run('bsdtar', '-tvf', str(package))
        require(all('root' in line for line in listing.splitlines()), 'Arch ownership mismatch')
    report['packages'][name] = {
        'sha256': digest(package), 'payloadFilesVerified': len(actual),
        'metadata': metadata, 'installed': False,
    }
    print(f'{name}: {len(actual)} payload entries match; metadata and removal recovery verified')
output = repo / 'artifacts' / f'Viora-Linux-{version}-variants-verification.json'
output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
print(output)

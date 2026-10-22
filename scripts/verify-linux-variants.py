"""Verify RPM/pacman metadata and every payload byte without installation/VPN."""
from pathlib import Path
import hashlib
import json
import os
import re
import stat
import subprocess

# RPM does not own shared parent directories such as /usr. libarchive creates
# these while extracting, using the verifier's umask rather than package data.
os.umask(0o022)

repo = Path(__file__).resolve().parent.parent
version = os.environ.get('VIORA_VERSION', '1.0.0')
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


def snapshot(root):
    result = {}
    for path in sorted(root.rglob('*')):
        name = path.relative_to(root).as_posix()
        info = path.lstat()
        if path.is_symlink():
            if name == 'usr/lib/systemd/system/network-pre.target.wants/viora-lockdown.service' and os.readlink(path) == '../viora-lockdown.service':
                result[name] = {'link': '../viora-lockdown.service'}
                continue
            raise ValueError(f'Unexpected payload symlink: {name}')
        if info.st_mode & (stat.S_ISUID | stat.S_ISGID | stat.S_IWGRP | stat.S_IWOTH):
            raise ValueError(f'Unexpected permissions: {name}')
        if path.is_file():
            result[name] = {'sha256': digest(path), 'mode': stat.S_IMODE(info.st_mode)}
    return result


expected = snapshot(baseline)
assert expected
report = {'version': version, 'runtimeTests': 'vpn-and-firewall-not-run', 'packages': {}}
for kind, name in [
    ('deb', f'Viora-Linux-{version}-amd64.deb'),
    ('rpm', f'Viora-Linux-{version}-1.x86_64.rpm'),
    ('arch', f'viora-bin-{version}-1-x86_64.pkg.tar.zst'),
]:
    package = repo / 'artifacts' / name
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
        assert run('dpkg-deb', '-f', str(package), 'Package') == 'viora'
        assert run('dpkg-deb', '-f', str(package), 'Version') == version
        assert run('dpkg-deb', '-f', str(package), 'Architecture') == 'amd64'
        controls = work / 'verified-deb-controls'
        subprocess.run(['dpkg-deb', '-e', str(package), str(controls)], check=True)
        assert '--protection recover' in (controls / 'prerm').read_text()
        assert '--protection enable' not in (controls / 'postinst').read_text()
        listing = run('dpkg-deb', '-c', str(package))
        assert all('root/root' in line for line in listing.splitlines())
    elif kind == 'rpm':
        assert run('rpm', '-qp', '--qf', '%{NAME} %{VERSION} %{ARCH}', str(package)) == f'viora {version} x86_64'
        scripts = run('rpm', '-qp', '--scripts', str(package))
        assert '--protection recover' in scripts and 'daemon-reload' in scripts
        assert '--protection enable' not in scripts and '--restore-protection' not in scripts
        metadata = run('rpm', '-qp', '--requires', str(package))
        assert 'systemd-resolved' in metadata and 'libflutter_linux_gtk.so' not in metadata
        # RPM contains ownership separately from unprivileged extraction.
        ownership = run('rpm', '-qp', '--qf', '[%{FILEUSERNAME}:%{FILEGROUPNAME}\n]', str(package))
        assert set(ownership.splitlines()) == {'root:root'}
        check = run('rpm', '-K', str(package))
        assert 'digests OK' in check
    else:
        metadata = run('pacman', '-Qip', str(package))
        assert 'viora-bin' in metadata and f'{version}-1' in metadata
        assert (dest / '.MTREE').is_file() and (dest / '.BUILDINFO').is_file()
        info = (dest / '.PKGINFO').read_text()
        assert 'arch = x86_64' in info and 'depend = systemd' in info
        install = (dest / '.INSTALL').read_text()
        assert 'pre_remove()' in install and '--protection recover' in install
        assert '--protection enable' not in install
        listing = run('bsdtar', '-tvf', str(package))
        assert all('root' in line for line in listing.splitlines())
    report['packages'][name] = {
        'sha256': digest(package), 'payloadFilesVerified': len(actual),
        'metadata': metadata, 'installed': False,
    }
    print(f'{name}: {len(actual)} payload entries match; metadata and removal recovery verified')
# The privileged helper's pinned core must survive both packaging tools.
assert digest(baseline / 'usr/lib/viora/core/xray') == digest(repo / 'artifacts/desktop-core/linux/xray')
output = repo / 'artifacts' / f'Viora-Linux-{version}-variants-verification.json'
output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
print(output)

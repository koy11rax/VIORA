"""Package compiled desktop installers and a whitelisted source snapshot.

This script never installs an application or runs a VPN component.
"""
from pathlib import Path
import argparse
import hashlib
import json
import zipfile

VERSION = '0.8.2'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--platform', choices=['Windows', 'Linux', 'all'], default='all')
options = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
artifacts = repo / 'artifacts'


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def check_zip(path):
    with zipfile.ZipFile(path) as archive:
        if archive.testzip() is not None:
            raise ValueError(f'ZIP integrity failure: {path.name}')


def checksum(path):
    path.with_suffix(path.suffix + '.sha256').write_text(
        f'{sha(path)}  {path.name}\n', encoding='utf-8')


pinned = {
    'toolchains/xray-main/source.zip': '8b64534d8f3b91d902528ebba5cbfa05dccaf991efae49edf415dec7c0e3587f',
    'toolchains/wintun-0.14.1.zip': '07c256185d6ee3652e09fa55c0b673e2624b565e02c4b9091c79ca7d2f24ef51',
}
for name, expected in pinned.items():
    if sha(repo / name) != expected:
        raise ValueError(f'Upstream archive checksum mismatch: {name}')

roots = ['apps/client/lib', 'apps/client/test', 'apps/client/assets',
         'apps/client/windows', 'apps/client/linux', 'desktop',
         'third_party/flutter_v2ray_client/lib']
names = ['.gitignore', 'apps/client/pubspec.yaml', 'apps/client/pubspec.lock',
         'apps/client/analysis_options.yaml',
         'third_party/flutter_v2ray_client/pubspec.yaml',
         'third_party/flutter_v2ray_client/LICENSE',
         'scripts/build-desktop-core.ps1', 'scripts/prepare-windows-bundle.ps1',
         'scripts/build-windows-msi.ps1', 'scripts/verify-windows-msi.ps1',
         'scripts/build-linux.sh', 'scripts/package-linux.sh',
         'scripts/package-linux-variants.sh', 'scripts/verify-linux-variants.py',
         'scripts/package-desktop-release.py',
         f'docs/windows-release-{VERSION}.md', f'docs/linux-release-{VERSION}.md',
         f'docs/desktop-source-build-{VERSION}.md', f'docs/desktop-user-guide-{VERSION}.md',
         f'docs/linux-install-variants-{VERSION}.md',
         *pinned.keys()]
files = {repo / name for name in names}
ignored = {'.git', '.dart_tool', 'ephemeral', 'build', '__pycache__', 'vendor'}
for name in roots:
    for path in (repo / name).rglob('*'):
        if path.is_file() and not path.is_symlink() and not ignored.intersection(path.relative_to(repo).parts):
            files.add(path)
for path in files:
    if path.is_symlink() or not path.is_file():
        raise ValueError(f'Missing or linked source: {path.relative_to(repo)}')
    if path.suffix.lower() in {'.jks', '.key', '.pem', '.keystore', '.p12', '.pfx', '.sqlite', '.db', '.exe', '.dll', '.so', '.aar'} or path.name in {'.env', 'local.properties', 'key.properties'}:
        raise ValueError(f'Unexpected source artifact: {path.relative_to(repo)}')

source = artifacts / f'Viora-Desktop-{VERSION}-source.zip'
with zipfile.ZipFile(source, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
    for path in sorted(files):
        archive.write(path, path.relative_to(repo).as_posix())
    archive.write(repo / f'docs/desktop-source-build-{VERSION}.md', 'BUILD-SOURCE-RU.md')
check_zip(source)
checksum(source)

for platform, binaries in {
    'Windows': [(artifacts / f'Viora-Windows-{VERSION}-Setup.exe', f'Viora-Windows-{VERSION}-Setup.exe'),
                (artifacts / f'Viora-Windows-{VERSION}.msi', 'Viora.msi')],
    'Linux': [(artifacts / name, name) for name in [
        f'Viora-Linux-{VERSION}-amd64.deb', f'Viora-Linux-{VERSION}-1.x86_64.rpm',
        f'viora-bin-{VERSION}-1-x86_64.pkg.tar.zst',
        f'Viora-Linux-{VERSION}-Arch-recipe.tar.gz', f'Viora-Linux-{VERSION}.spec']],
}.items():
    if options.platform not in ('all', platform):
        continue
    contents = {name: path.read_bytes() for path, name in binaries}
    contents[source.name] = source.read_bytes()
    contents['INSTALL-RU.md'] = (repo / f'docs/desktop-user-guide-{VERSION}.md').read_bytes()
    contents['RELEASE-NOTES-RU.md'] = (repo / f'docs/{platform.lower()}-release-{VERSION}.md').read_bytes()
    contents['BUILD-SOURCE-RU.md'] = (repo / f'docs/desktop-source-build-{VERSION}.md').read_bytes()
    if platform == 'Linux':
        contents['FEDORA-ARCH-INSTALL-RU.md'] = (repo / f'docs/linux-install-variants-{VERSION}.md').read_bytes()
        contents['FEDORA-ARCH-VERIFICATION.json'] = (artifacts / f'Viora-Linux-{VERSION}-variants-verification.json').read_bytes()
    for name in ['Xray-MPL-2.0.txt', 'flutter_v2ray_client-MIT.txt']:
        contents['licenses/' + name] = (repo / 'apps/client/assets/licenses' / name).read_bytes()
    if platform == 'Windows':
        contents['licenses/Wintun-LICENSE.txt'] = (repo / 'toolchains/wintun/wintun/LICENSE.txt').read_bytes()
    manifest = {'version': VERSION, 'platform': platform, 'architecture': 'amd64',
                'tunnelRuntimeTests': 'not-run-at-owner-request',
                'sha256': {name: hashlib.sha256(data).hexdigest() for name, data in contents.items()}}
    contents['release.json'] = (json.dumps(manifest, indent=2) + '\n').encode('utf-8')
    contents['SHA256SUMS.txt'] = ''.join(
        f'{hashlib.sha256(data).hexdigest()}  {name}\n' for name, data in sorted(contents.items())
    ).encode('utf-8')
    output = artifacts / f'Viora-{platform}-{VERSION}-release-package.zip'
    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for name, data in contents.items():
            archive.writestr(name, data, compress_type=zipfile.ZIP_STORED
                             if name.endswith(('.zip', '.exe', '.msi', '.deb', '.rpm', '.zst', '.tar.gz')) else zipfile.ZIP_DEFLATED)
    check_zip(output)
    with zipfile.ZipFile(output) as archive:
        for name, data in contents.items():
            if hashlib.sha256(archive.read(name)).digest() != hashlib.sha256(data).digest():
                raise ValueError(f'Packaged file mismatch: {name}')
    checksum(output)
    for path, _ in binaries:
        checksum(path)
    print(f'{output.name}: {output.stat().st_size} bytes, SHA-256 {sha(output)}')
print(f'{source.name}: {len(files)} source/build files, SHA-256 {sha(source)}')

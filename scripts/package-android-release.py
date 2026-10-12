"""Package the already tested Android APK and corresponding Android sources."""
import hashlib
import json
from pathlib import Path
import re
import zipfile

repo = Path(__file__).resolve().parent.parent
pubspec = (repo / 'apps/client/pubspec.yaml').read_text(encoding='utf-8')
match = re.search(r'^version: (\d+\.\d+\.\d+)\+(\d+)$', pubspec, re.M)
if not match:
    raise ValueError('Expected explicit release version')
version, code = match.group(1), int(match.group(2))
artifacts = repo / 'artifacts'
apk = artifacts / f'Viora-Android-{version}-release.apk'


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


if digest(apk) != apk.with_suffix('.apk.sha256').read_text(encoding='utf-8').split()[0]:
    raise ValueError('APK does not match its verified checksum')

# Explicit whitelist: never walk a checkout containing user profiles, signing
# configuration, backend databases, build outputs or local SDK configuration.
roots = [
    'apps/client/lib', 'apps/client/test', 'apps/client/assets',
    'apps/client/android/app/src', 'apps/client/android/gradle/wrapper',
    'third_party/flutter_v2ray_client/lib',
    'third_party/flutter_v2ray_client/android/src',
    'third_party/androidlibxraylite',
]
names = [
    'apps/client/pubspec.yaml', 'apps/client/pubspec.lock',
    'apps/client/analysis_options.yaml',
    'apps/client/android/app/build.gradle.kts',
    'apps/client/android/app/proguard-rules.pro',
    'apps/client/android/build.gradle.kts',
    'apps/client/android/settings.gradle.kts',
    'apps/client/android/gradle.properties',
    'apps/client/android/gradlew', 'apps/client/android/gradlew.bat',
    'third_party/flutter_v2ray_client/pubspec.yaml',
    'third_party/flutter_v2ray_client/LICENSE',
    'third_party/flutter_v2ray_client/VIORA-CHANGES.md',
    'third_party/flutter_v2ray_client/android/build.gradle',
    'scripts/build-android-core.ps1', 'scripts/fetch-android-core.ps1',
    'scripts/build-android-release.ps1', 'scripts/android-google-mirror.init.gradle',
    'scripts/package-android-release.py', 'scripts/package-android-core-source.py',
    'scripts/test-dns-forwarding.py', 'docs/android-source-build.md',
    'docs/android-user-guide.md', f'docs/android-release-{version}.md',
    f'docs/android-release-notes-{version}.md',
]
files = {repo / name for name in names}
for name in roots:
    root = repo / name
    if not root.is_dir():
        raise FileNotFoundError(name)
    files.update(p for p in root.rglob('*') if p.is_file())

source = artifacts / f'Viora-Android-{version}-source.zip'
for path in files:
    relative = path.relative_to(repo)
    if path.is_symlink() or path.suffix.lower() in {
        '.jks', '.keystore', '.pfx', '.p12', '.db', '.sqlite', '.aar', '.apk',
    } or path.name in {'local.properties', 'key.properties', 'signing.properties', '.env'}:
        raise ValueError(f'Forbidden source file: {relative}')
    if not path.is_file():
        raise FileNotFoundError(relative)

with zipfile.ZipFile(source, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
    for path in sorted(files):
        archive.write(path, path.relative_to(repo).as_posix())
with zipfile.ZipFile(source) as archive:
    if archive.testzip() is not None:
        raise ValueError('Source ZIP failed integrity check')

contents = {
    apk.name: apk.read_bytes(),
    source.name: source.read_bytes(),
    'INSTALL-RU.md': (repo / 'docs/android-user-guide.md').read_bytes(),
    'RELEASE-NOTES-RU.md': (repo / f'docs/android-release-notes-{version}.md').read_bytes(),
    'BUILD-SOURCE.md': (repo / 'docs/android-source-build.md').read_bytes(),
}
for path in (repo / 'apps/client/assets/licenses').glob('*.txt'):
    contents['licenses/' + path.name] = path.read_bytes()
manifest = {
    'applicationId': 'dev.viora.viora_client',
    'versionName': version, 'versionCode': code,
    'minSdk': 26, 'targetSdk': 36,
    'abis': ['arm64-v8a', 'armeabi-v7a', 'x86_64'],
    'certificateSha256': 'b742e4983218a9cb47e86589b200bb3442b7579cd27a03b3b5f3db5096214722',
    'sha256': {name: hashlib.sha256(data).hexdigest() for name, data in contents.items()},
}
contents['release.json'] = (json.dumps(manifest, indent=2) + '\n').encode('utf-8')
contents['SHA256SUMS.txt'] = ''.join(
    f'{hashlib.sha256(data).hexdigest()}  {name}\n'
    for name, data in sorted(contents.items())
).encode('utf-8')
bundle = artifacts / f'Viora-Android-{version}-release-package.zip'
with zipfile.ZipFile(bundle, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
    for name, data in contents.items():
        # APK/source are already compressed; storing them also preserves bytes.
        archive.writestr(name, data, compress_type=zipfile.ZIP_STORED
                         if name.endswith(('.apk', '.zip')) else zipfile.ZIP_DEFLATED)
with zipfile.ZipFile(bundle) as archive:
    if archive.testzip() is not None:
        raise ValueError('Release ZIP failed integrity check')
    for name, data in contents.items():
        if hashlib.sha256(archive.read(name)).digest() != hashlib.sha256(data).digest():
            raise ValueError(f'Packaged file mismatch: {name}')
for path in (source, bundle):
    path.with_suffix(path.suffix + '.sha256').write_text(
        f'{digest(path)}  {path.name}\n', encoding='utf-8')
    print(f'{path.name}: {path.stat().st_size} bytes, SHA-256 {digest(path)}')

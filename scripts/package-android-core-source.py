"""Package pinned Android core source and its Java integration, without keys."""
from pathlib import Path
import argparse
import hashlib
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument('--version', default='0.7.4')
version = parser.parse_args().version
if not version or any(c not in '0123456789.' for c in version):
    raise ValueError('Invalid version')
repo = Path(__file__).resolve().parent.parent
destination = repo / 'artifacts' / f'Viora-Android-{version}-core-source.zip'
roots = [repo / 'third_party/androidlibxraylite',
         repo / 'third_party/flutter_v2ray_client/android/src',
         repo / 'apps/client/assets/licenses']
files = [repo / 'scripts/build-android-core.ps1',
         repo / 'scripts/fetch-android-core.ps1',
         repo / 'scripts/package-android-core-source.py',
         repo / 'third_party/flutter_v2ray_client/VIORA-CHANGES.md',
         repo / 'third_party/flutter_v2ray_client/LICENSE',
         repo / 'third_party/flutter_v2ray_client/android/build.gradle',
         repo / 'docs/android-user-guide.md',
         repo / f'docs/android-release-{version}.md']
for root in roots:
    files.extend(p for p in root.rglob('*') if p.is_file())
destination.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(destination, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
    for source in sorted(set(files)):
        if source.suffix.lower() in {'.jks', '.keystore', '.apk', '.aar'}:
            raise ValueError(f'Unexpected binary/signing file: {source.name}')
        archive.write(source, source.relative_to(repo).as_posix())
with zipfile.ZipFile(destination) as archive:
    if archive.testzip() is not None:
        raise ValueError('Source archive verification failed')
digest = hashlib.sha256(destination.read_bytes()).hexdigest()
destination.with_suffix(destination.suffix + '.sha256').write_text(
    f'{digest}  {destination.name}\n', encoding='utf-8')
print(f'{destination.name}: {len(files)} source/license files, SHA-256 {digest}')

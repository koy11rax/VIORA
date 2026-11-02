"""Archive committed source plus pinned upstream source; never development state."""
import argparse
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import zipfile

repo = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--upstream-root', type=Path, default=repo)
parser.add_argument('--asset', action='append', default=[])
args = parser.parse_args()

def git(*arguments):
    return subprocess.check_output(['git', *arguments], cwd=repo)

def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

if git('status', '--porcelain').strip():
    raise SystemExit('Commit the reviewed source before packaging')
head = git('rev-parse', 'HEAD').decode().strip()
pubspec = git('show', 'HEAD:apps/client/pubspec.yaml').decode()
version = re.search(r'^version: (\d+\.\d+\.\d+)\+(\d+)$', pubspec, re.M)
if version is None:
    raise SystemExit('Expected explicit release version')
name, build = version.groups()
pins = {
    'toolchains/xray-main/source.zip': '8b64534d8f3b91d902528ebba5cbfa05dccaf991efae49edf415dec7c0e3587f',
    'toolchains/wintun-0.14.1.zip': '07c256185d6ee3652e09fa55c0b673e2624b565e02c4b9091c79ca7d2f24ef51',
    'toolchains/sing-box/sing-box-v1.14.4-source.zip': '9037718f85b67a004517c6a9190b98c68483de643f57c62eb6c889e01beae4bc',
}
for relative, expected in pins.items():
    if digest(args.upstream_root / relative) != expected:
        raise SystemExit('Pinned source archive mismatch: ' + relative)
artifacts = repo / 'artifacts'
artifacts.mkdir(exist_ok=True)
output = artifacts / f'Viora-{name}-source.zip'
prefix = f'VIORA-{name}/'
forbidden = {'.jks', '.keystore', '.key', '.pem', '.pfx', '.p12', '.db', '.sqlite', '.vault', '.exe', '.dll', '.so', '.aar', '.apk'}
with zipfile.ZipFile(io.BytesIO(git('archive', '--format=zip', head))) as source, zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as target:
    for entry in source.infolist():
        if entry.is_dir():
            continue
        path = PurePosixPath(entry.filename)
        data = source.read(entry)
        if entry.filename.startswith('toolchains/'):
            if entry.filename not in pins or hashlib.sha256(data).hexdigest() != pins[entry.filename]:
                raise SystemExit('Unexpected tracked toolchain archive')
            continue
        if path.is_absolute() or '..' in path.parts or path.suffix.lower() in forbidden or path.name in {'.env', 'local.properties', 'key.properties', 'signing.properties'} or entry.filename.startswith(('.git/', 'artifacts/')):
            raise SystemExit('Forbidden release source: ' + entry.filename)
        if (entry.external_attr >> 16) & 0o170000 == 0o120000:
            raise SystemExit('Linked release source: ' + entry.filename)
        item = zipfile.ZipInfo(prefix + entry.filename, date_time=entry.date_time)
        item.external_attr = entry.external_attr
        target.writestr(item, data, compress_type=zipfile.ZIP_DEFLATED)
    for relative in pins:
        target.write(args.upstream_root / relative, prefix + relative, compress_type=zipfile.ZIP_STORED)
    target.writestr(prefix + 'RELEASE-SOURCE.json', json.dumps({
        'version': name, 'build': int(build), 'sourceCommit': head,
        'upstreamSHA256': pins,
    }, indent=2) + '\n')
with zipfile.ZipFile(output) as archive:
    if archive.testzip() is not None:
        raise SystemExit('Source archive CRC failure')
assets = [output]
for asset in args.asset:
    if Path(asset).name != asset or not (artifacts / asset).is_file() or (artifacts / asset).is_symlink():
        raise SystemExit('Expected ordinary artifact filename')
    assets.append(artifacts / asset)
records = [{'name': p.name, 'bytes': p.stat().st_size, 'sha256': digest(p)} for p in assets]
for record in records:
    (artifacts / (record['name'] + '.sha256')).write_text(record['sha256'] + '  ' + record['name'] + '\n', encoding='utf-8')
(artifacts / f'SHA256SUMS-{name}.txt').write_text(''.join(r['sha256'] + '  ' + r['name'] + '\n' for r in records), encoding='utf-8')
(artifacts / f'Viora-{name}-publication.json').write_text(json.dumps({'sourceCommit': head, 'assets': records}, indent=2) + '\n', encoding='utf-8')
print(json.dumps({'sourceCommit': head, 'assets': records}, indent=2))

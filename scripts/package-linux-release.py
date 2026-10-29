"""Package a committed Linux source snapshot and verified installers; never runs VPN."""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parent.parent
VERSION = '1.0.5'
ARTIFACTS = ROOT / 'artifacts'
PREFIX = f'VIORA-Linux-{VERSION}/'
PINNED_SOURCES = {
    'toolchains/xray-main/source.zip': '8b64534d8f3b91d902528ebba5cbfa05dccaf991efae49edf415dec7c0e3587f',
    'toolchains/sing-box/sing-box-v1.14.4-source.zip': '9037718f85b67a004517c6a9190b98c68483de643f57c62eb6c889e01beae4bc',
}


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT).decode('utf-8').strip()


def main():
    if git('status', '--porcelain'):
        raise ValueError('Commit the reviewed source before creating a release archive')
    commit = git('rev-parse', 'HEAD')
    names = [f'Viora-Linux-{VERSION}-amd64.deb', f'Viora-Linux-{VERSION}-1.x86_64.rpm',
             f'viora-bin-{VERSION}-1-x86_64.pkg.tar.zst', f'Viora-Linux-{VERSION}-Arch-recipe.tar.gz',
             f'Viora-Linux-{VERSION}.spec', f'Viora-Linux-{VERSION}-payload.tar.gz']
    for name in names:
        path = ARTIFACTS / name
        if path.is_symlink() or not path.is_file():
            raise ValueError('Missing regular release artifact: ' + name)
        sidecar = path.with_name(path.name + '.sha256').read_text().split()
        if len(sidecar) != 2 or sidecar[0] != sha(path) or sidecar[1] != name:
            raise ValueError('Artifact checksum mismatch: ' + name)
    for name, expected in PINNED_SOURCES.items():
        if sha(ROOT / name) != expected:
            raise ValueError('Pinned source archive differs: ' + name)
    report = ARTIFACTS / f'Viora-Linux-{VERSION}-variants-verification.json'
    evidence = json.loads(report.read_text())
    if evidence['version'] != VERSION or set(evidence['packages']) != set(names[:3]):
        raise ValueError('Missing Linux package verification report')
    for name in names[:3]:
        if (evidence['packages'][name]['sha256'] != sha(ARTIFACTS / name)
                or evidence['packages'][name]['payloadFilesVerified'] <= 0):
            raise ValueError('Package verification evidence differs: ' + name)
    results = ARTIFACTS / f'Viora-Linux-{VERSION}-test-results.json'
    checks = json.loads(results.read_text())
    if (checks.get('version') != VERSION or checks.get('build') != 35
            or checks.get('runtimePassed') is not True
            or checks.get('cleanupVerified') is not True
            or not checks.get('runtimeChecks')
            or checks.get('runtimeChecksPassed') != len(checks['runtimeChecks'])
            or not all(check.get('passed') is True for check in checks['runtimeChecks'])
            or checks.get('packageVerification') != evidence):
        raise ValueError('Missing or mismatched isolated verification results')
    for name, expected in checks['nativeSHA256'].items():
        if name not in {'xray', 'sing-box', 'viora_tunnel'} or sha(ARTIFACTS / 'desktop-core' / 'linux' / name) != expected:
            raise ValueError('Tested native component differs: ' + name)
    if set(checks['nativeSHA256']) != {'xray', 'sing-box', 'viora_tunnel'}:
        raise ValueError('Incomplete tested component hashes')
    source = ARTIFACTS / f'Viora-Linux-{VERSION}-source.zip'
    if source.exists():
        raise FileExistsError(source)
    tracked = git('ls-files', '-z').split('\0')
    forbidden = {'.key', '.pem', '.p12', '.pfx', '.jks', '.keystore', '.sqlite', '.db', '.exe', '.dll', '.so', '.aar'}
    for name in tracked:
        if Path(name).suffix.lower() in forbidden or Path(name).name in {
                '.env', 'local.properties', 'key.properties', 'signing.properties'}:
            raise ValueError('Unexpected tracked source artifact: ' + name)
    subprocess.run(['git', 'archive', '--format=zip', '--prefix=' + PREFIX,
                    '-o', str(source), commit], cwd=ROOT, check=True)
    with zipfile.ZipFile(source, 'a', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        existing = set(archive.namelist())
        for name in PINNED_SOURCES:
            if PREFIX + name not in existing:
                archive.write(ROOT / name, PREFIX + name)
        archive.writestr(PREFIX + 'RELEASE-SOURCE.json', json.dumps({
            'version': VERSION, 'build': 35, 'platform': 'Linux x86_64', 'sourceCommit': commit,
            'pinnedSourceArchives': PINNED_SOURCES,
            'verification': 'docs/linux-release-1.0.5.md',
        }, ensure_ascii=False, indent=2) + '\n')
    with zipfile.ZipFile(source) as archive:
        if archive.testzip() is not None:
            raise ValueError('Source archive CRC check failed')
        for name, expected in PINNED_SOURCES.items():
            if hashlib.sha256(archive.read(PREFIX + name)).hexdigest() != expected:
                raise ValueError('Packaged upstream source mismatch')
    names.append(source.name)
    instructions = ARTIFACTS / f'INSTALL-Linux-{VERSION}-RU.md'
    shutil.copyfile(ROOT / f'docs/linux-install-variants-{VERSION}.md', instructions)
    names.extend([instructions.name, report.name, results.name])
    sums = []
    for name in names:
        path = ARTIFACTS / name
        line = f'{sha(path)}  {name}\n'
        path.with_name(name + '.sha256').write_text(line, encoding='utf-8', newline='\n')
        sums.append(line)
    (ARTIFACTS / f'SHA256SUMS-Linux-{VERSION}.txt').write_text(''.join(sums), encoding='utf-8', newline='\n')
    print(f'Linux {VERSION}: {len(names)} verified release/source files; source commit {commit}')


if __name__ == '__main__':
    main()

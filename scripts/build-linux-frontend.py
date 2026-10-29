"""Build the pinned Linux TUN frontend with the reviewed process-owner fix.

No VPN or network configuration is started. Go may fetch checksum-locked modules.
"""
from pathlib import Path, PurePosixPath
import argparse
import hashlib
import json
import os
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent
ARCHIVE_SHA = '9037718f85b67a004517c6a9190b98c68483de643f57c62eb6c889e01beae4bc'
BASE_SHA = '7ebba50b44a1f8ee12430ee0ebd085c5c78cd751b15407746d282acf595c4263'
PATCH_SHA = 'b418d8cbb9f19b1e02094421de778db61b3b9b13c6cbc95b0f803f0a324eeaa6'
TEST_SHA = 'f4f0458e2052d2f21a9d87c9c82459b8a4705ba1b7095599b85b4ebdbd8d5590'
VERSION = '1.14.4-viora.1'


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--go', default='go', help='Go 1.27.3 executable')
    parser.add_argument('--test-binary', action='store_true', help='Also compile Linux-only pure regression tests')
    args = parser.parse_args()
    version = subprocess.check_output([args.go, 'version'], text=True)
    if 'go1.27.3 ' not in version:
        raise ValueError('Use Go 1.27.3')
    archive = ROOT / 'toolchains/sing-box/sing-box-v1.14.4-source.zip'
    if digest(archive.read_bytes()) != ARCHIVE_SHA:
        raise ValueError('Pinned sing-box source archive differs')
    source = archive.parent / 'sing-box-1.14.4'
    if not source.exists():
        with zipfile.ZipFile(archive) as z:
            if any(not m.filename.startswith('sing-box-1.14.4/')
                   or '..' in PurePosixPath(m.filename).parts for m in z.infolist()):
                raise ValueError('Unsafe source archive path')
            z.extractall(archive.parent)
    with zipfile.ZipFile(archive) as z:
        expected = {m.filename.removeprefix('sing-box-1.14.4/'): digest(z.read(m))
                    for m in z.infolist() if not m.is_dir()}
    actual = {p.relative_to(source).as_posix(): digest(p.read_bytes())
              for p in source.rglob('*') if p.is_file()}
    if actual != expected or any(p.is_symlink() for p in source.rglob('*')):
        raise ValueError('Expanded upstream source differs from the pinned archive')
    base = source / 'route/process_cache.go'
    if digest(base.read_bytes().replace(b'\r\n', b'\n')) != BASE_SHA:
        raise ValueError('Original process-cache source differs')
    patch = ROOT / 'patches/sing-box-desktop/process_cache.go'
    tests = ROOT / 'patches/sing-box-desktop/process_cache_test.go'
    for path, expected in [(patch, PATCH_SHA), (tests, TEST_SHA)]:
        if digest(path.read_bytes().replace(b'\r\n', b'\n')) != expected:
            raise ValueError('Reviewed overlay differs: ' + path.name)
    env = os.environ.copy()
    env.update(GOOS='linux', GOARCH='amd64', CGO_ENABLED='0', GOWORK='off',
               GOFLAGS='', GOPRIVATE='', GONOSUMDB='')
    # Module checksums and readonly go.mod/go.sum remain enabled.
    env['GOSUMDB'] = 'sum.golang.org'
    output = ROOT / 'artifacts/desktop-core/linux'
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='viora-frontend-build-') as temporary:
        overlay = Path(temporary) / 'overlay.json'
        overlay.write_text(json.dumps({'Replace': {str(base): str(patch)}}), encoding='utf-8')
        subprocess.run([args.go, 'build', '-mod=readonly', '-buildvcs=false', '-trimpath',
                        '-overlay', str(overlay), '-ldflags',
                        '-s -w -X github.com/sagernet/sing-box/constant.Version=' + VERSION,
                        '-o', str(output / 'sing-box'), './cmd/sing-box'], cwd=source, env=env, check=True)
        if args.test_binary:
            overlay.write_text(json.dumps({'Replace': {
                str(base): str(patch), str(source / 'route/viora_process_cache_test.go'): str(tests),
            }}), encoding='utf-8')
            subprocess.run([args.go, 'test', '-mod=readonly', '-trimpath', '-overlay', str(overlay),
                            '-c', '-o', str(output / 'sing-box-local-source.test'), './route'],
                           cwd=source, env=env, check=True)
    print('Linux frontend', VERSION, digest((output / 'sing-box').read_bytes()), flush=True)
    print('Pure tests were compiled only; run the .test binary on Linux with -test.run ^TestViora')


if __name__ == '__main__':
    main()

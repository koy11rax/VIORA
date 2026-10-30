"""Exercise production Dart outbounds against loopback-only Android Xray fixtures."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--go', default='go')
parser.add_argument('--dart', default='dart')
args = parser.parse_args()
repo = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='viora-android-protocols-') as temporary:
    generated = Path(temporary) / 'protocols.json'
    subprocess.run([args.dart, str(repo / 'desktop/tunnel/testdata/export_protocol_fixtures.dart'), str(generated)],
                   cwd=repo / 'apps/client', check=True)
    environment = dict(os.environ, GOTOOLCHAIN='local', VIORA_TEST_DART_PROTOCOLS=str(generated))
    subprocess.run([args.go, 'test', '-mod=readonly', '-count=1', '-v', '.'],
                   cwd=repo / 'tests/android-protocols', env=environment, check=True)

"""Exercise package rejection paths in temporary fixtures; never install or run VPN.

Run on Linux with Python 3 and bash. These negative checks complement the real
DEB/RPM/Arch payload verification; they are not substitutes for a full build.
"""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
SCRIPT = (ROOT / 'scripts/package-linux.sh').read_bytes()


class PackagePreflightTests(unittest.TestCase):
    def test_invalid_inputs_leave_no_stage_or_overwritten_output(self):
        cases = [
            ('invalid-version', 'Invalid version'),
            ('invalid-suffix', 'Invalid package suffix'),
            ('existing-output', 'Output already exists'),
            ('missing-frontend', 'Missing or linked file'),
            ('linked-frontend', 'Missing or linked file'),
            ('linked-bundle', 'Linked file in Flutter bundle'),
            ('modified-frontend', 'Unexpected sing-box frontend'),
            ('missing-overlay', 'Missing or linked file'),
        ]
        for label, reason in cases:
            with self.subTest(case=label), tempfile.TemporaryDirectory(
                    prefix='viora-package-preflight-') as location:
                root = Path(location)
                packager = root / 'scripts/package-linux.sh'
                packager.parent.mkdir()
                packager.write_bytes(SCRIPT)
                for item in [
                    'apps/client/build/linux/x64/release/bundle/viora_client',
                    'artifacts/desktop-core/linux/xray',
                    'artifacts/desktop-core/linux/viora_tunnel',
                    'artifacts/desktop-core/linux/sing-box',
                    'apps/client/assets/licenses/sing-box-GPL-3.0.txt',
                    'third_party/sing-box/COPYING',
                    'toolchains/sing-box/sing-box-v1.14.4-source.zip',
                    'docs/linux-install-variants-1.0.5.md',
                    'docs/linux-sing-box-provenance-1.0.5.md',
                    'patches/sing-box-desktop/process_cache.go',
                    'patches/sing-box-desktop/process_cache_test.go',
                    'patches/sing-box-desktop/README.md',
                    'scripts/build-linux-frontend.py',
                    'docs/linux-frontend-source-pins-1.0.5.json',
                ]:
                    path = root / item
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text('fixture', encoding='utf-8')
                bundle = root / 'apps/client/build/linux/x64/release/bundle'
                for item in ['data', 'lib']:
                    (bundle / item).mkdir()
                env = os.environ.copy()
                env['VIORA_VERSION'] = '1.0.5'
                env['VIORA_PACKAGE_SUFFIX'] = ''
                frontend = root / 'artifacts/desktop-core/linux/sing-box'
                output = root / 'artifacts/Viora-Linux-1.0.5-amd64.deb'
                if label == 'invalid-version':
                    env['VIORA_VERSION'] = '../escape'
                elif label == 'invalid-suffix':
                    env['VIORA_PACKAGE_SUFFIX'] = '../../escape'
                elif label == 'existing-output':
                    output.write_text('do-not-overwrite', encoding='utf-8')
                elif label == 'missing-frontend':
                    frontend.unlink()
                elif label == 'linked-frontend':
                    frontend.unlink()
                    frontend.symlink_to(root / 'artifacts/desktop-core/linux/xray')
                elif label == 'linked-bundle':
                    (bundle / 'linked').symlink_to(root / 'docs')
                elif label == 'missing-overlay':
                    (root / 'patches/sing-box-desktop/process_cache.go').unlink()
                result = subprocess.run(['bash', str(packager)], env=env,
                                        capture_output=True, text=True, timeout=15)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(reason, result.stdout + result.stderr)
                self.assertFalse((root / 'artifacts/Viora-Linux-1.0.5-deb').exists())
                if label == 'existing-output':
                    self.assertEqual(output.read_text(), 'do-not-overwrite')


if __name__ == '__main__':
    unittest.main(verbosity=2)

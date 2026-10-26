"""Exercise pinned Xray TUN routing using only gVisor/channels/net.Pipe."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

COMMIT = "701af60772cda123492f86e383e1fdba066614a9"
FILES = ("fixture_device_test.go", "fixture_dispatcher_test.go", "fixture_tls_test.go", "routing_dns_gap_test.go")
CASES = ("named_fastDNS_before", "numeric_slowDNS_before", "named_slowDNS_before", "named_slowDNS_terminalProxy")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--go", default="go", help="Local Go 1.27.3 executable")
    args = parser.parse_args()
    fixture = Path(__file__).resolve().parent
    repo = fixture.parent.parent
    source = repo / "toolchains" / "xray-main" / f"Xray-core-{COMMIT}"
    pins = json.loads((fixture / "source-pins.json").read_text(encoding="utf-8"))

    def verify_source() -> None:
        for relative, expected in pins.items():
            path = source / relative
            if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
                raise SystemExit(f"Pinned source mismatch: {relative}; no source was modified")

    verify_source()
    env = os.environ.copy()
    env.update(GOTOOLCHAIN="local", GOPROXY="off", GOSUMDB="off", GOWORK="off", GOFLAGS="", CGO_ENABLED="0")
    env.pop("GOOS", None)
    env.pop("GOARCH", None)
    env.pop("VIORA_TEST_CORE", None)
    version = subprocess.run([args.go, "version"], env=env, capture_output=True, text=True, check=True).stdout
    if "go1.27.3 " not in version:
        raise SystemExit("Use the pinned local Go 1.27.3 toolchain")

    # Overlay injects test files only. No upstream source is rewritten, and
    # no installer, service, TUN adapter or operating-system socket is invoked.
    mapping = {str(source / "proxy" / "tun" / ("viora_" + name)): str(fixture / name) for name in FILES}
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", suffix=".json", delete=False) as handle:
        overlay = Path(handle.name)
        json.dump({"Replace": mapping}, handle)
    try:
        command = [args.go, "test", "-mod=readonly", "-overlay", str(overlay), "-count=1", "-timeout=30s", "-run", "^TestOfflineTunRoutingDNSGap$", "-v", "./proxy/tun"]
        result = subprocess.run(command, cwd=source, env=env, capture_output=True, text=True, timeout=120)
        print(result.stdout, end="", flush=True)
        print(result.stderr, end="", flush=True)
        if result.returncode != 0 or any(f"--- PASS: TestOfflineTunRoutingDNSGap/{case}" not in result.stdout for case in CASES):
            raise SystemExit("Isolated TUN/DNS regressions failed")
        print("PASS: baseline DNS-dependent failure and terminal-route recovery reproduced without OS sockets", flush=True)
    finally:
        overlay.unlink(missing_ok=True)
        verify_source()


if __name__ == "__main__":
    main()

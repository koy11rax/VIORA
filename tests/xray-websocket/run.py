"""Run the pinned real Xray WebSocket regression without OS sockets or downloads."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

COMMIT = "701af60772cda123492f86e383e1fdba066614a9"
UPSTREAM_SHA256 = "247b1512b2c868f7766a7f40dca88ab69ce248ddc5a58bd9ae57d06deaa01c56"
SNIFFER_SHA256 = "75f4b79a0f98dda3a615ab1b34f202458a3ad68d76cd232c64f5b6cd8640426c"
TESTS = (
    "TestPinnedWebsocketPassesHandshakeDeadlineToTLSNetworkDial",
    "TestPinnedWebsocketClosesStreamAfterFailedTLSHandshake",
    "TestPinnedTLSSniffRequestsMoreDataForFragmentedClientHello",
)
BASELINE_FAILURES = (
    "transport ignored its eight-second handshake deadline",
    "failed TLS handshake leaked the returned underlying stream",
    "TLS record prefix did not request more data",
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--go", default="go", help="Local Go 1.27.3 executable")
    parser.add_argument(
        "--verify-baseline", action="store_true",
        help="First require both known regressions to fail on unmodified source",
    )
    args = parser.parse_args()
    fixture = Path(__file__).resolve().parent
    repo = fixture.parent.parent
    upstream = repo / "toolchains" / "xray-main" / f"Xray-core-{COMMIT}" / "transport" / "internet" / "websocket" / "dialer.go"
    patched = repo / "patches" / "xray-desktop" / "websocket_dialer.go"
    sniffer = upstream.parents[3] / "common" / "protocol" / "tls" / "sniff.go"
    patched_sniffer = repo / "patches" / "xray-desktop" / "tls_sniff.go"
    if sha256(upstream) != UPSTREAM_SHA256:
        raise SystemExit("Pinned WebSocket source hash mismatch; no test was run")
    if not patched.is_file():
        raise SystemExit("Missing tracked WebSocket overlay")
    if sha256(sniffer) != SNIFFER_SHA256 or not patched_sniffer.is_file():
        raise SystemExit("Pinned TLS sniffer source mismatch or missing overlay")

    # These settings apply to child test processes only. A pre-populated module
    # cache and the checked-in go.sum are required; nothing is downloaded.
    env = os.environ.copy()
    env.update(GOTOOLCHAIN="local", GOPROXY="off", GOSUMDB="off", GOWORK="off", GOFLAGS="", CGO_ENABLED="0")
    env.pop("GOOS", None)
    env.pop("GOARCH", None)
    version = subprocess.run([args.go, "version"], env=env, capture_output=True, text=True, check=True).stdout
    if "go1.27.3 " not in version:
        raise SystemExit("Use the pinned local Go 1.27.3 toolchain")
    command = [args.go, "test", "-mod=readonly", "-count=1", "-timeout=30s", "-run", "^TestPinned", "-v"]

    def run(extra: list[str]) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(command + extra + ["."], cwd=fixture, env=env, capture_output=True, text=True)
        print(result.stdout, end="", flush=True)
        print(result.stderr, end="", flush=True)
        return result

    try:
        if args.verify_baseline:
            baseline = run([])
            output = baseline.stdout + baseline.stderr
            if (baseline.returncode != 1
                    or any(f"--- FAIL: {name}" not in output for name in TESTS)
                    or any(message not in output for message in BASELINE_FAILURES)):
                raise SystemExit("Baseline did not reproduce both expected failures")
            print("BASELINE: all expected failures reproduced", flush=True)

        # Absolute build paths are generated only in a disposable local file;
        # the repository contains no machine-specific overlay paths.
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", suffix=".json", delete=False) as handle:
            overlay = Path(handle.name)
            json.dump({"Replace": {str(upstream): str(patched), str(sniffer): str(patched_sniffer)}}, handle)
        try:
            result = run(["-overlay", str(overlay)])
        finally:
            overlay.unlink(missing_ok=True)
        if result.returncode != 0 or any(f"--- PASS: {name}" not in result.stdout for name in TESTS):
            raise SystemExit("Patched WebSocket regressions failed")
        print(f"OVERLAY: PASS; upstream SHA-256 {UPSTREAM_SHA256}", flush=True)
        print(f"Patched source SHA-256 {sha256(patched)}", flush=True)
    finally:
        if sha256(upstream) != UPSTREAM_SHA256:
            raise SystemExit("Upstream source changed while running tests")
        if sha256(sniffer) != SNIFFER_SHA256:
            raise SystemExit("Upstream TLS sniffer changed while running tests")


if __name__ == "__main__":
    main()

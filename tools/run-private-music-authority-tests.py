#!/usr/bin/env python3
"""Run a Swift authority harness against one isolated real taskd database."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: run-private-music-authority-tests.py <taskd-binary> <swift-harness>")
    binary = Path(sys.argv[1]).resolve(strict=True)
    harness = Path(sys.argv[2]).resolve(strict=True)
    repository = Path(__file__).resolve().parents[1]
    if not harness.is_relative_to(repository / "tools") or harness.suffix != ".swift":
        raise SystemExit("harness must be an explicit repository tools Swift file")
    scratch = Path(tempfile.mkdtemp(prefix="gmgn-music-authority-private-")).resolve(strict=True)
    endpoint = scratch / "endpoint.json"
    process = None
    succeeded = False
    try:
        with (scratch / "daemon.log").open("wb") as log:
            process = subprocess.Popen([str(binary), "--root", str(scratch), "--endpoint-file", str(endpoint), "--concurrency", "1"], stdout=log, stderr=log)
            deadline = time.monotonic() + 15
            while not endpoint.exists():
                if process.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError("private daemon did not publish its endpoint")
                time.sleep(0.05)
            descriptor = json.loads(endpoint.read_text())
            if not descriptor["address"].startswith("127.0.0.1:"):
                raise RuntimeError("private endpoint was not loopback")
            environment = os.environ.copy()
            environment["GMGN_MUSIC_LIBRARY_FIXTURE_URL"] = "http://" + descriptor["address"] + "/rpc"
            environment["GMGN_MUSIC_LIBRARY_FIXTURE_TOKEN"] = descriptor["token"]
            environment["GMGN_MUSIC_LIBRARY_FIXTURE_ROOT"] = str(scratch)
            code = subprocess.run(["/usr/bin/swift", str(harness)], cwd=repository, env=environment).returncode
            succeeded = code == 0
            return code
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        if not succeeded:
            # Preserve only diagnostic output, never the endpoint/token or database.
            fd, path = tempfile.mkstemp(prefix="gmgn-music-authority-failure-", suffix=".log")
            with os.fdopen(fd, "wb") as evidence:
                log = scratch / "daemon.log"
                if log.exists():
                    with log.open("rb") as source:
                        shutil.copyfileobj(source, evidence)
            print("private daemon exit:", process.returncode if process else "not-started", "diagnostic log:", path, file=sys.stderr)
        shutil.rmtree(scratch)


if __name__ == "__main__":
    sys.exit(main())

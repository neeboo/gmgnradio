#!/usr/bin/env python3
"""Compile/run actual typed places client against an explicit private taskd only."""
import argparse
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--daemon", type=Path)
    args = parser.parse_args()
    if args.run and (args.daemon is None or not args.daemon.is_absolute()):
        parser.error("--run requires explicitly approved absolute --daemon")
    repo = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="gmgn-approach-places-") as temporary:
        parent = Path(temporary).resolve()
        root = parent / "TaskService"
        root.mkdir(mode=0o700)
        endpoint = root / "taskd.endpoint.json"
        executable = parent / "typed-places-test"
        source = repo / "apps/macos/Sources/GMGNRadio/Presence"
        flags = subprocess.check_output(["sh", str(repo / "tools/world-runtime-harness-flags.sh")], text=True).splitlines()
        subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library", *flags,
            str(source / "RustPropCapabilityClient.swift"), str(source / "WorldAuthorityClient.swift"),
            str(source / "RustWorldActivityClient.swift"),
            str(source / "TaskdHTTPTransport.swift"), str(source / "RetryBackoff.swift"),
            str(Path(__file__).with_name("test-rust-approach-places-client.swift")), "-o", str(executable)], check=True)
        if not args.run:
            print("PASS compile/link production typed places client; no daemon/UI/physics execution")
            return
        with open("/tmp/gmgn-approach-places-private-daemon.log", "w") as log:
            daemon = subprocess.Popen([str(args.daemon), "--root", str(root), "--endpoint-file", str(endpoint), "--concurrency", "2"],
                stdout=log, stderr=log, start_new_session=True)
            print(f"PRIVATE daemon PID/PGID={daemon.pid} root={root}", flush=True)
            try:
                for _ in range(1500):
                    assert daemon.poll() is None, "private daemon exited before readiness"
                    if endpoint.exists(): break
                    time.sleep(.02)
                else: raise AssertionError("private readiness timeout")
                subprocess.run([str(executable), str(endpoint)], check=True)
                database = next(p for p in root.glob("*.sqlite*") if not p.name.endswith(("-wal", "-shm")))
                with sqlite3.connect(database) as db:
                    assert db.execute("SELECT count(*) FROM world_records WHERE domain='worlds' AND key='state' AND tombstone=0").fetchone()[0] == 2
                    assert db.execute("SELECT count(*) FROM world_device_catalog").fetchone()[0] == 1
                print("PASS actual SQLite: two private imported worlds and one valid explicit catalog binding", flush=True)
            finally:
                os.killpg(daemon.pid, signal.SIGTERM)
                try: daemon.wait(timeout=5)
                except subprocess.TimeoutExpired: os.killpg(daemon.pid, signal.SIGKILL); daemon.wait(timeout=5)
                for target in (lambda: os.kill(daemon.pid, 0), lambda: os.killpg(daemon.pid, 0)):
                    try: target(); raise AssertionError("private process survived cleanup")
                    except ProcessLookupError: pass
                print(f"REAPED private daemon PID/PGID={daemon.pid} exit={daemon.returncode}", flush=True)
    assert not parent.exists()
    print("PASS exact private root removed", flush=True)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Private Swift consumer fixture; no daemon/provider/App/audio execution."""
from pathlib import Path
import subprocess
import tempfile
import argparse
import os
import signal
import sqlite3
import time

repo = Path(__file__).resolve().parents[1]
source = repo / "apps/macos/Sources/GMGNRadio/Presence"
flags = subprocess.check_output(["sh", str(repo / "tools/world-runtime-harness-flags.sh")],text=True).splitlines()
parser=argparse.ArgumentParser(); parser.add_argument("--daemon",type=Path); args=parser.parse_args()
if args.daemon and not args.daemon.is_absolute(): parser.error("explicit absolute private daemon required")
with tempfile.TemporaryDirectory(prefix="gmgn-activity-prepare-",dir="/private/tmp") as temporary:
    executable = Path(temporary) / "test"
    subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library", *flags,
        str(source / "RustPropCapabilityClient.swift"), str(source / "WorldAuthorityClient.swift"),
        str(source / "RustWorldActivityClient.swift"), str(source / "TaskdHTTPTransport.swift"),
        str(source / "RetryBackoff.swift"), str(Path(__file__).with_suffix(".swift")), "-o", str(executable)],check=True)
    subprocess.run([str(executable)],check=True)
    if args.daemon:
        root=Path(temporary)/"TaskService"; root.mkdir(mode=0o700); endpoint=root/"taskd.endpoint.json"
        with open(Path(temporary)/"daemon.log","w") as log:
            daemon=subprocess.Popen([str(args.daemon),"--root",str(root),"--endpoint-file",str(endpoint),"--concurrency","2"],stdout=log,stderr=log,start_new_session=True)
            print(f"PRIVATE daemon PID/PGID={daemon.pid} root={root}",flush=True)
            try:
                for _ in range(1500):
                    assert daemon.poll() is None
                    if endpoint.exists(): break
                    time.sleep(.02)
                else: raise AssertionError("private daemon readiness timeout")
                subprocess.run([str(executable),str(endpoint)],check=True)
                database=next(p for p in root.glob("*.sqlite*") if not p.name.endswith(("-wal","-shm")))
                with sqlite3.connect(database) as db:
                    assert db.execute("SELECT count(*) FROM world_activity_commands").fetchone()[0] == 7
                    assert db.execute("SELECT count(*) FROM world_activity_runs").fetchone()[0] == 3
                print("PASS actual SQLite three catalogs/three starts/one receipt; async raw physics consumer included, preparation/rejected plans/replay add no command rows")
            finally:
                os.killpg(daemon.pid,signal.SIGTERM)
                try: daemon.wait(timeout=5)
                except subprocess.TimeoutExpired: os.killpg(daemon.pid,signal.SIGKILL); daemon.wait(timeout=5)
                for target in (lambda:os.kill(daemon.pid,0),lambda:os.killpg(daemon.pid,0)):
                    try: target(); raise AssertionError("private daemon survived cleanup")
                    except ProcessLookupError: pass
                print(f"REAPED private daemon PID/PGID={daemon.pid} exit={daemon.returncode}")
assert not Path(temporary).exists()
print("PASS exact private root and fixture executable removed")

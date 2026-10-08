#!/usr/bin/env python3
"""Production native PNG/store/Unity + private taskd. Never builds or launches the user app.

Default is compile-only. Use --run --daemon <root-verified-schema22-binary> once
the integration owner has built and approved that exact daemon.
"""
import argparse
import hashlib
import http.client
import json
import os
import pathlib
import signal
import sqlite3
import subprocess
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
APP = ROOT / "apps/macos/Sources/GMGNRadio/Presence"

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--daemon", type=pathlib.Path)
    parser.add_argument("--consumer-source", type=pathlib.Path, action="append", default=[])
    parser.add_argument("--consumer-script", type=pathlib.Path)
    args = parser.parse_args()
    if args.run and not args.daemon:
        parser.error("--run requires an explicitly verified schema22 daemon")
    with tempfile.TemporaryDirectory(prefix="gmgn-private-attachment-fixture-") as temp:
        root = pathlib.Path(temp).resolve()
        executable = root / "attachment-checks"
        sources = [APP / "TaskdHTTPTransport.swift", APP / "RustChatAttachmentClient.swift",
                   APP / "PropImagePreparation.swift", APP / "ResidentImageAttachment.swift",
                   ROOT / "apps/macos/UnityHost/UnityChatImageBridge.swift",
                   ROOT / "tools/fixtures/PrivateAttachmentAuthority.swift",
                   *(args.consumer_source or [pathlib.Path(__file__).with_suffix(".swift")])]
        if args.consumer_script:
            subprocess.run(["/usr/bin/swift", str(args.consumer_script.resolve()), "--compile-only"],
                           cwd=ROOT, check=True, timeout=120)
        else:
            subprocess.run(["/usr/bin/swiftc", "-j1", "-swift-version", "6", "-parse-as-library",
                            *map(str, sources), "-o", str(executable)], check=True, timeout=120)
        print("PASS consumer script compile-only checks" if args.consumer_script else
              "PASS Swift 6: complete production client/store/preparation/Unity bridge compiled")
        if not args.run:
            return
        service = root / "service"
        service.mkdir(mode=0o700)
        endpoint = service / "taskd.endpoint.json"
        daemon = None
        def stop():
            nonlocal daemon
            if daemon is None:
                return
            pid = daemon.pid
            if daemon.poll() is None:
                os.killpg(pid, signal.SIGTERM)
                try:
                    daemon.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(pid, signal.SIGKILL)
                    daemon.wait(timeout=3)
            daemon.communicate(timeout=3)
            print(f"owned daemon PID {pid} exit {daemon.returncode}", flush=True)
            for test in (lambda: os.kill(pid, 0), lambda: os.killpg(pid, 0)):
                try:
                    test()
                except ProcessLookupError:
                    pass
                else:
                    raise AssertionError("owned private daemon PID/process group survived stop")
            print(f"PASS owned daemon PID/process group {pid} reaped", flush=True)
            daemon = None
        def rpc(method, params):
            descriptor = json.loads(endpoint.read_text())
            host, port = descriptor["address"].split(":")
            assert host == "127.0.0.1"
            connection = http.client.HTTPConnection(host, int(port), timeout=10)
            connection.request("POST", "/rpc", json.dumps({"id":"attachment-fixture", "method":method, "params":params}),
                               {"Authorization":"Bearer " + descriptor["token"], "Content-Type":"application/json"})
            response = connection.getresponse()
            result = json.loads(response.read())
            connection.close()
            assert response.status == 200
            return result
        def start():
            nonlocal daemon
            daemon = subprocess.Popen([str(args.daemon.resolve()), "--root", str(service), "--endpoint-file", str(endpoint), "--concurrency", "1"],
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
            print(f"private daemon PID {daemon.pid} root {service}", flush=True)
            for _ in range(300):
                if daemon.poll() is not None:
                    raise AssertionError("private daemon exited before readiness")
                try:
                    reply = rpc("capability_contract", {})
                    if "result" in reply:
                        return
                except (OSError, ValueError, KeyError):
                    pass
                time.sleep(.02)
            raise AssertionError("private daemon readiness timed out")
        try:
            start()
            database = next(service.glob("*.sqlite*"))
            with sqlite3.connect(database) as db:
                schema_version = db.execute("SELECT MAX(version) FROM schema_migrations").fetchone()[0]
                assert schema_version >= 22, "refusing pre-schema22 daemon"
                print(f"PASS actual SQLite schema {schema_version}", flush=True)
                db.execute("SELECT value FROM chat_attachment_authority LIMIT 1").fetchall()
            command = (["/usr/bin/swift", str(args.consumer_script.resolve())] if args.consumer_script else [str(executable)])
            subprocess.run([*command, str(endpoint), str(root)], cwd=ROOT, check=True, timeout=120)
            if args.consumer_source or args.consumer_script:
                with sqlite3.connect(database) as db:
                    rows = db.execute("SELECT value FROM chat_attachment_authority").fetchall()
                    assert rows, "actual consumer did not persist attachment authority"
                    snapshots = [json.loads(row[0]) for row in rows]
                    references = sum(len(s["submissions"]) for s in snapshots)
                    print(f"PASS actual SQLite: {len(rows)} owners / {references} durable submission bindings", flush=True)
                print("PASS additional production attachment consumer against real private schema22 daemon")
                return
            with sqlite3.connect(database) as db:
                values = {owner:json.loads(value) for owner,value in db.execute("SELECT owner,value FROM chat_attachment_authority")}
            assert len(values) == 6, len(values)
            actor = values["fixture-actor"]
            assert actor["session"] == "next-host" and not actor["draft"]
            assert any(v["state"] == "unknown" for v in actor["submissions"].values())
            assert all(pathlib.Path(f["attachment"]["localPath"]).exists() for f in actor["facts"].values() if f["ever_submitted"])
            for value in values.values():
                for fact in value["facts"].values():
                    path = pathlib.Path(fact["attachment"]["localPath"])
                    if fact["ever_submitted"]:
                        assert path.exists(), "submitted image removed"
                    if path.exists():
                        contents = path.read_bytes()
                        assert hashlib.sha256(contents).hexdigest() == fact["attachment"]["sha256"]
                        assert len(contents) == fact["attachment"]["byteCount"] <= 8 * 1024 * 1024
                        assert path.stat().st_mode & 0o777 == 0o600
                    if fact["deletion_offered"]:
                        assert not path.exists(), "native did not enact Rust deletion receipt"
            before = values
            stop(); stop(); start()
            with sqlite3.connect(database) as db:
                after = {owner:json.loads(value) for owner,value in db.execute("SELECT owner,value FROM chat_attachment_authority")}
            assert before == after, "daemon restart changed persisted attachment facts/references"
            print("PASS real SQLite: submitted files retained, native deletion receipts honored, unknown refs/session/order durable across restart")
        finally:
            stop(); stop()
        print("PASS private daemon PID and session group reaped twice; temporary directory cleaned")

if __name__ == "__main__":
    main()

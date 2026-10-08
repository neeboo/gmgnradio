#!/usr/bin/env python3
"""Real control RPC and typed client; raw native facts/initial SQL records are private fixtures.

Does not execute navigation, renderer, player, or audio hardware.
"""
import argparse
import http.client
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import tempfile
import time
import uuid

repo = Path(__file__).resolve().parents[1]
source = repo / "apps/macos/Sources/GMGNRadio"

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--daemon", required=True, type=Path)
    parser.add_argument("--compile-only", action="store_true")
    args = parser.parse_args()
    log_path = Path("/tmp") / ("gmgn-jukebox-" + str(uuid.uuid4()) + ".log")
    with log_path.open("w") as log, tempfile.TemporaryDirectory(prefix="gmgn-jukebox-private-") as raw:
        root = Path(raw).resolve(); root.chmod(0o700)
        endpoint = root / "endpoint.json"
        authority = (source / "Presence/WorldAuthorityClient.swift").read_text()
        errors = "enum WorldAuthorityError" + authority.split("enum WorldAuthorityError", 1)[1].split("\n}\n", 1)[0] + "\n}\n"
        transport = "final class TaskdHTTPAuthorityClient" + authority.split("final class TaskdHTTPAuthorityClient", 1)[1].split("/// 世界状态权威的门面", 1)[0]
        leaves = root / "Leaves.swift"; leaves.write_text("import Foundation\nimport os\n" + errors + transport)
        executable = root / "acceptance"
        code = subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library", str(leaves),
            str(source / "Presence/TaskdHTTPTransport.swift"), str(source / "Presence/RustJukeboxClient.swift"),
            str(repo / "tools/test-rust-jukebox-daemon.swift"), "-o", str(executable)], stdout=log, stderr=log).returncode
        if code: print("compile exit", code, "log", log_path); return code
        if args.compile_only: print("PASS actual jukebox typed client Swift6 compile; log", log_path); return 0
        processes = []
        def start():
            endpoint.unlink(missing_ok=True)
            process = subprocess.Popen([str(args.daemon.resolve()), "--root", str(root), "--endpoint-file", str(endpoint)],
                stdout=log, stderr=log, start_new_session=True)
            processes.append(process); print("START PID/PGID", process.pid, file=log, flush=True)
            deadline = time.monotonic() + 15
            while not endpoint.exists():
                if process.poll() is not None or time.monotonic() >= deadline: raise RuntimeError("private daemon failed")
                time.sleep(0.02)
            return process
        def stop(process):
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL); process.wait(timeout=5)
            try: os.killpg(process.pid, 0)
            except ProcessLookupError:
                print("STOP PID/PGID absent", process.pid, "exit", process.returncode, file=log, flush=True); return
            raise AssertionError("owned private group survived")
        def rpc(method, params):
            descriptor = json.loads(endpoint.read_text()); host, port = descriptor["address"].split(":")
            assert host == "127.0.0.1"
            connection = http.client.HTTPConnection(host, int(port), timeout=5)
            connection.request("POST", "/rpc", json.dumps({"jsonrpc":"2.0", "id":"fixture", "method":method, "params":params}),
                {"Authorization":"Bearer " + descriptor["token"], "Content-Type":"application/json"})
            response = connection.getresponse(); result = json.loads(response.read()); connection.close(); return result
        try:
            first = start()
            # Explicit initial authority state fixture. These are not claims or renderer/player executions.
            database = sqlite3.connect(root / "tasks.sqlite3"); database.execute("PRAGMA busy_timeout=5000")
            state = {"worldID":"fixture", "revision":1, "agentTransform":{"position":{"x":0,"y":0,"z":0}}}
            import hashlib
            payload = json.dumps(state, separators=(",", ":"), sort_keys=True)
            database.execute("INSERT INTO world_records VALUES(?,?,?,?,?,?,?,?,?)",
                ("fixture", "worlds", "state", 1, 0, "fixture", 0, hashlib.sha256(payload.encode()).hexdigest(), payload))
            # The authority materializes objectStates from separate object rows, never
            # from embedded world JSON. Mirror the persisted schema exactly.
            object_payload = json.dumps({"isEnabled":True}, separators=(",", ":"), sort_keys=True)
            database.execute("INSERT INTO world_records VALUES(?,?,?,?,?,?,?,?,?)",
                ("fixture", "objects", "jukebox", 1, 0, "fixture", 0,
                 hashlib.sha256(object_payload.encode()).hexdigest(), object_payload))
            run = {"requestID":"fixture-run", "generation":7, "hostSessionID":"actual-activity-host",
                "definition":{"id":"music.listen", "phases":[{"phase":"loop", "motionIDs":[], "propIDs":["jukebox"]}]},
                "status":"running", "phase":"loop", "phaseGeneration":3, "target":{"x":0,"y":0,"z":0}, "arrivalTolerance":0.02}
            database.execute("INSERT INTO world_activity_runs VALUES(?,?)", ("fixture", json.dumps({"run":run})))
            database.commit(); database.close()
            materialized = rpc("world_snapshot", {"worldID":"fixture", "includeState":True})["result"]
            assert materialized["record"]["state"]["objectStates"]["jukebox"]["isEnabled"] is True
            receipt = root / "restart.json"
            code = subprocess.run([str(executable), str(endpoint), str(receipt)], stdout=log, stderr=log, timeout=30).returncode
            if code: print("consumer exit", code, "log", log_path); return code
            pending = json.loads(receipt.read_text()); stop(first); second = start()
            identity = {"worldID":"restart", "scopeID":"resident-private", "hostSessionID":"private-host", **pending}
            assert rpc("jukebox_read", identity)["result"]["action"]["status"] == "unknown"
            assert "error" in rpc("jukebox_claim", identity)
            assert "error" in rpc("jukebox_begin", {**identity, "requestID":"new-business", "operation":{"kind":"resume_music", "args":{}}})
            database = sqlite3.connect(root / "tasks.sqlite3")
            states = [json.loads(row[0])["state"] for row in database.execute("SELECT payload FROM jukebox_compounds")]
            actions = database.execute("SELECT count(*) FROM jukebox_actions").fetchone()[0]; database.close()
            print("SQL compounds", states, "actions", actions, file=log, flush=True)
            stop(second); print("PASS actual jukebox control/typed client/restart; log", log_path); return 0
        finally:
            for process in processes: stop(process)

if __name__ == "__main__": raise SystemExit(main())

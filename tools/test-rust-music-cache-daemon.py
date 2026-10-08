#!/usr/bin/env python3
"""Actual production Swift consumer + private taskd, no provider/audio requests."""
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
    log_path = Path("/tmp") / ("gmgn-music-cache-" + str(uuid.uuid4()) + ".log")
    processes = []
    with log_path.open("w") as log, tempfile.TemporaryDirectory(prefix="gmgn-music-cache-private-") as raw:
        root = Path(raw).resolve(); root.chmod(0o700)
        endpoint = root / "endpoint.json"
        authority = (source / "Presence/WorldAuthorityClient.swift").read_text()
        errors = "enum WorldAuthorityError" + authority.split("enum WorldAuthorityError", 1)[1].split("\n}\n", 1)[0] + "\n}\n"
        transport = "final class TaskdHTTPAuthorityClient" + authority.split("final class TaskdHTTPAuthorityClient", 1)[1].split("/// 世界状态权威的门面", 1)[0]
        leaves = root / "Leaves.swift"; leaves.write_text("import Foundation\nimport os\n" + errors + transport)
        http_source = (source / "MusicSources/MusicProviderHTTPTransport.swift").read_text()
        http_source = http_source.split("extension MusicProviderSession", 1)[0] + "func checkedProviderResponse" + http_source.split("func checkedProviderResponse", 1)[1]
        raw_http = root / "HTTP.swift"; raw_http.write_text(http_source)
        executable = root / "acceptance"
        compile_code = subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library",
            str(leaves), str(raw_http), str(source / "Presence/TaskdHTTPTransport.swift"),
            str(source / "MusicSources/RustMusicCacheClient.swift"), str(source / "MusicSources/StreamingMusicCache.swift"),
            str(repo / "tools/test-rust-music-cache-daemon.swift"), "-o", str(executable)], stdout=log, stderr=log).returncode
        if compile_code:
            print("compile exit", compile_code, "log", log_path); return compile_code
        if args.compile_only:
            print("PASS actual music cache private fixture Swift6 compile; log", log_path); return 0
        def start():
            endpoint.unlink(missing_ok=True)
            process = subprocess.Popen([str(args.daemon.resolve()), "--root", str(root), "--endpoint-file", str(endpoint)],
                stdout=log, stderr=log, start_new_session=True)
            processes.append(process)
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
            assert process.poll() is not None
            try: os.killpg(process.pid, 0)
            except ProcessLookupError: return
            raise AssertionError("owned private group survived")
        def rpc(method, params):
            descriptor = json.loads(endpoint.read_text())
            host, port = descriptor["address"].split(":")
            assert host == "127.0.0.1"
            connection = http.client.HTTPConnection(host, int(port), timeout=5)
            payload = json.dumps({"jsonrpc": "2.0", "id": "fixture", "method": method, "params": params})
            connection.request("POST", "/rpc", payload, {"Authorization": "Bearer " + descriptor["token"], "Content-Type": "application/json"})
            response = connection.getresponse(); data = json.loads(response.read()); connection.close()
            return data
        try:
            first = start()
            code = subprocess.run([str(executable), str(root), str(endpoint)], stdout=log, stderr=log, timeout=30).returncode
            if code: print("consumer exit", code, "log", log_path); return code
            identity = {"hostSessionID": "restart-session", "requestID": "restart-request", "providerID": "netease", "trackID": "netease:restart", "extension": "mp3"}
            planned = rpc("music_cache_prepare", identity)["result"]
            bound = {"hostSessionID": "restart-session", "actionID": planned["actionID"]}
            assert rpc("music_cache_claim", bound)["result"]["state"] == "claimed"
            stop(first)
            second = start()
            assert rpc("music_cache_read", bound)["result"]["state"] == "unknown"
            assert "error" in rpc("music_cache_claim", bound)
            assert rpc("music_cache_prepare", {**identity, "requestID": "different-request"})["result"]["state"] == "unknown"
            assert "error" in rpc("music_cache_read", {**bound, "hostSessionID": "foreign"})
            database = sqlite3.connect(root / "tasks.sqlite3")
            counts = database.execute("SELECT state,count(*) FROM music_cache_entries GROUP BY state").fetchall()
            stored = "\n".join(str(row) for row in database.iterdump()); database.close()
            assert "private-secret" not in stored and "private-cookie-never-persist" not in stored and "not-contacted.invalid" not in stored
            print("SQL", counts, file=log); stop(second)
            print("PASS actual private cache/restart/no-secrets; log", log_path)
            return 0
        finally:
            for process in processes: stop(process)

if __name__ == "__main__": raise SystemExit(main())

#!/usr/bin/env python3
"""Real Rust/SQLite + real Swift Library, localhost raw provider facts only."""
import argparse
import http.client
import http.server
import json
import os
from pathlib import Path
import signal
import socket
import sqlite3
import subprocess
import tempfile
import threading
import time
import uuid

repo = Path(__file__).resolve().parents[1]
source = repo / "apps/macos/Sources/GMGNRadio"

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--daemon", required=True, type=Path)
    parser.add_argument("--client-tests", action="store_true", help="Run actual migrated six Swift Testing contracts")
    parser.add_argument("--log", type=Path, default=Path("/tmp") / ("gmgn-marble-library-" + str(uuid.uuid4()) + ".log"))
    args = parser.parse_args()
    counts = {"list": 0, "generate": 0, "operation": 0, "world": 0, "asset": 0, "echo": 0}
    class Provider(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def respond(self, value):
            data = value if isinstance(value, bytes) else json.dumps(value).encode()
            self.send_response(200); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
        def do_POST(self):
            assert self.headers.get("WLT-Api-Key") == "fixture-memory-key"
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            if self.path == "/marble/v1/worlds:list":
                counts["list"] += 1
                assert body == {"page_size": 50, "sort_by": "created_at", "status": "SUCCEEDED"}
                base = f"http://127.0.0.1:{self.server.server_port}"
                def world(identity, name):
                    return {"world_id": identity, "display_name": name, "assets": {"splats": {"spz_urls": {"500k": base + "/assets/" + identity + ".spz"}}}}
                self.respond({"worlds": [world("catalog-dj", "gmgn DJ House"), world("catalog-cabin", "gmgn Cosy Wood House")]})
            elif self.path == "/marble/v1/worlds:generate":
                counts["generate"] += 1
                assert body["world_prompt"]["type"] == "image"
                if counts["generate"] == 1:
                    self.connection.shutdown(socket.SHUT_RDWR); self.connection.close()
                else:
                    assert counts["generate"] == 2, "paid generation replay"
                    self.respond({"operation_id": "operation-exact", "done": False})
            else: raise AssertionError(self.path)
        def do_GET(self):
            if self.path.startswith("/assets/"):
                counts["asset"] += 1
                # Cache leaf copies raw bytes. This case does not claim SPZ/package validation.
                self.respond(b"private-cache-fact")
            elif self.path == "/marble/v1/echo":
                counts["echo"] += 1; self.respond(b"fixture-memory-key")
            elif self.path == "/marble/v1/operations/operation-exact":
                counts["operation"] += 1
                self.respond({"operation_id": "operation-exact", "done": counts["operation"] >= 2,
                              "metadata": {"progress": {"percentage": 25}}, "response": {"world_id": "generated-exact"}})
            elif self.path == "/marble/v1/worlds/generated-exact":
                counts["world"] += 1
                base = f"http://127.0.0.1:{self.server.server_port}"
                self.respond({"world_id": "generated-exact", "display_name": "name-is-not-identity",
                              "assets": {"mesh": {"collider_mesh_url": base + "/assets/real-required.glb"},
                                         "splats": {"spz_urls": {"500k": base + "/assets/real-required.spz"}}}})
            else: raise AssertionError(self.path)
    provider = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    thread = threading.Thread(target=provider.serve_forever, daemon=True); thread.start()
    evidence = []
    try:
        with tempfile.TemporaryDirectory(prefix="gmgn-marble-library-private-") as raw:
            root = Path(raw).resolve(); root.chmod(0o700)
            authority = root / "TaskService"; authority.mkdir(mode=0o700)
            endpoint = authority / "taskd.endpoint.json"
            spatial = (source / "VisualEngine/SpatialStageStore.swift").read_text()
            preset = "enum SpatialScenePreset" + spatial.split("enum SpatialScenePreset", 1)[1].split("enum SpatialMovement", 1)[0]
            authority_source = (source / "Presence/WorldAuthorityClient.swift").read_text()
            errors = "enum WorldAuthorityError" + authority_source.split("enum WorldAuthorityError", 1)[1].split("\n}\n", 1)[0] + "\n}\n"
            transport = "final class TaskdHTTPAuthorityClient" + authority_source.split("final class TaskdHTTPAuthorityClient", 1)[1].split("/// 世界状态权威的门面", 1)[0]
            leaves = root / "Leaves.swift"
            leaf_text = '''import Foundation
import os
@MainActor final class SpatialStageStore {
    func selectScene(_ scene: SpatialScenePreset) {}
    func selectWorld(id: String?) {}
}
enum LivingWorldBootstrap { static let marbleCabinDirectoryName = "private-fixture" }
''' + preset + errors + transport
            test_source = repo / "tools/test-marble-library-daemon.swift"
            if args.client_tests:
                builder = (source / "VisualEngine/MarblePackagePreparation.swift").read_text()
                projection = "extension RustMarbleControlClient.World" + builder.split("extension RustMarbleControlClient.World", 1)[1].split("enum UnityMarbleError", 1)[0]
                leaf_text += projection + '''
@MainActor final class PrivateMusicAuthorityFixture {
    var root: URL { fatalError("no default root in standalone tests") }
    static func start() async throws -> PrivateMusicAuthorityFixture { fatalError("private endpoint must be injected") }
}
'''
                test_source = root / "Tests.swift"
                test_source.write_text((repo / "apps/macos/Tests/GMGNRadioTests/VisualEngine/MarbleWorldClientTests.swift").read_text().replace("@testable import GMGNRadio", ""))
                leaf_text += '''
@main struct TestMain { static func main() async { let code: CInt = await Testing.__swiftPMEntryPoint(); exit(code) } }
'''
                leaf_text = "import Testing\n" + leaf_text
            leaves.write_text(leaf_text)
            binary = root / "library-fixture"
            flags = subprocess.check_output(["sh", str(repo / "tools/world-runtime-harness-flags.sh")], text=True).splitlines()
            if args.client_tests:
                frameworks = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks"
                flags += ["-F", frameworks, "-Xlinker", "-rpath", "-Xlinker", frameworks,
                          "-load-plugin-library", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"]
            paths = ["VisualEngine/MarbleWorld.swift", "VisualEngine/MarbleWorldCache.swift", "VisualEngine/MarbleWorldClient.swift",
                     "VisualEngine/MarbleWorldLibrary.swift", "Presence/RustMarbleControlClient.swift", "Presence/RustMarbleGeometryClient.swift", "Presence/TaskdHTTPTransport.swift"]
            compile_result = subprocess.run(["swiftc", "-swift-version", "6", *flags, str(leaves), *[str(source / path) for path in paths],
                                             str(test_source), "-o", str(binary)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            args.log.write_bytes(compile_result.stdout); compile_result.check_returncode()
            process = None
            def stop():
                nonlocal process
                if process is None: return
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGTERM)
                    try: process.wait(timeout=3)
                    except subprocess.TimeoutExpired: os.killpg(process.pid, signal.SIGKILL); process.wait(timeout=3)
                process.communicate(timeout=3)
                for check in (lambda: os.kill(process.pid, 0), lambda: os.killpg(process.pid, 0)):
                    try: check()
                    except ProcessLookupError: pass
                    else: raise AssertionError("private daemon PID/process group survived")
            def start():
                nonlocal process
                process = subprocess.Popen([str(args.daemon.resolve()), "--root", str(authority), "--endpoint-file", str(endpoint), "--concurrency", "1"],
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
                for _ in range(300):
                    if process.poll() is not None: raise AssertionError("private daemon exited")
                    try:
                        desc = json.loads(endpoint.read_text()); host, port = desc["address"].split(":")
                        assert host == "127.0.0.1"
                        conn = http.client.HTTPConnection(host, int(port), timeout=2)
                        conn.request("GET", "/health", headers={"Authorization": "Bearer " + desc["token"]})
                        response = conn.getresponse(); response.read(); conn.close()
                        if response.status == 200: return
                    except (OSError, ValueError, KeyError): pass
                    time.sleep(.02)
                raise AssertionError("private readiness timeout")
            def run(mode):
                arguments = [str(binary)] if args.client_tests else [str(binary), str(endpoint), str(root), f"http://127.0.0.1:{provider.server_port}", mode]
                env = dict(os.environ, GMGN_MARBLE_TEST_ENDPOINT=str(endpoint))
                result = subprocess.run(arguments, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=50)
                with args.log.open("ab") as log: log.write(result.stdout)
                print(result.stdout.decode(errors="replace"), end=""); result.check_returncode()
            try:
                start(); run("initial")
                if args.client_tests:
                    database = next(authority.glob("*.sqlite*"))
                    with sqlite3.connect(database) as db:
                        assert db.execute("SELECT COUNT(*) FROM marble_control_libraries").fetchone()[0] == 7
                        rows = db.execute("SELECT input FROM marble_control_actions").fetchall()
                        assert len(rows) == 7
                        assert sum(json.loads(row[0])["status"] == "inflight" for row in rows) == 6
                        assert sum(json.loads(row[0])["status"] == "queued" for row in rows) == 1
                        assert db.execute("SELECT COUNT(*) FROM marble_control_actions WHERE receipt IS NOT NULL").fetchone()[0] == 4
                    assert all(value == 0 for value in counts.values()), counts
                    evidence.append("PASS actual 6 migrated Swift Testing contracts, 7 private SQL owners/7 actions/6 claims/4 receipts/1 next queued poll; no provider request")
                    return
                assert counts == {"list": 1, "generate": 2, "operation": 3, "world": 2, "asset": 2, "echo": 1}, counts
                database = next(authority.glob("*.sqlite*"))
                with sqlite3.connect(database) as db:
                    assert db.execute("SELECT MAX(version) FROM schema_migrations").fetchone()[0] >= 30
                    selected = json.loads(db.execute("SELECT payload FROM marble_control_libraries WHERE owner='library-owner'").fetchone()[0])
                    assert selected["selectedWorldID"] == "catalog-dj"
                    rows = db.execute("SELECT owner,input,receipt FROM marble_control_actions ORDER BY owner").fetchall()
                    assert len(rows) == 11, rows
                    assert sum(row[2] is not None for row in rows) == 10
                    assert all("fixture-memory-key" not in (row[2] or "") for row in rows)
                    task = json.loads(db.execute("SELECT payload FROM marble_control_tasks WHERE owner='generation-owner'").fetchone()[0])
                    assert task["status"] == "failed" and task["operationID"] == "operation-exact"
                    assert db.execute("SELECT COUNT(*) FROM marble_control_presets WHERE owner='generation-owner'").fetchone()[0] == 0
                stop(); stop(); start(); run("restart-check")
                assert counts["generate"] == 2
                evidence += ["PASS SQLite: schema>=30, SQL selected catalog-dj, 11 actual actions/10 receipts; operation-exact retained with native failure; no package binding; private key absent",
                             "PASS provider counts: list=1 generate=2 operation=3 world=2 asset=2 echo=1; explicit resume/restart/unknown never re-executed paid POST",
                             "BOUNDARY: native preparation failure covered; real SPZ+GLB successful manifest registration is covered separately"]
            finally:
                stop(); stop()
                evidence.append("PASS owned private daemon PID/PG double-stop; temporary root cleanup")
    finally:
        provider.shutdown(); provider.server_close(); thread.join(timeout=3)
        with args.log.open("ab") as log: log.write(("\n" + "\n".join(evidence) + "\n").encode())
        print("actual log:", args.log)
        for line in evidence: print(line)

if __name__ == "__main__": main()

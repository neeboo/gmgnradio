#!/usr/bin/env python3
"""Private HTTP fixture consumes the actual native bridge; no GUI/audio/model."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import uuid
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

repo = Path(__file__).resolve().parents[3]
calls = []
token = str(uuid.uuid4())
leases = {}

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_POST(self):
        assert self.path == "/rpc"
        assert self.headers["Authorization"] == "Bearer " + token
        wire = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        method, p = wire["method"], wire["params"]
        calls.append(method)
        if method == "world_blob_put":
            assert Path(p["localPath"]).parent == fixture_root
            assert hashlib.sha256(Path(p["localPath"]).read_bytes()).hexdigest() == p["sha256"]
            self.respond(wire["id"], {"stored": True}); return
        assert p["worldID"] == "actual-world" and p["residentScope"] == "actual-ui-scope" and p["hostSessionID"] == "actual-ui-host"
        assert p["expectedRevision"] == 7
        if method == "world_prop_observe":
            assert p["layoutRevision"] == 3
            if p["facts"] != {"fixtureMeasuredMesh": True}:
                f = p["facts"]
                assert f["environmentBlobRef"] == "sha256:" + hashlib.sha256((fixture_root / "environment.private-fixture").read_bytes()).hexdigest()
                assert f["objects"]["sofa"]["assetID"] == "sha256:" + hashlib.sha256((fixture_root / "prop.private-fixture").read_bytes()).hexdigest()
                assert f["avatar"]["assetID"] == "actual-avatar" and f["avatar"]["slots"] == ["rightHand"]
                assert f["environment"]["triangles"]["indices"] == [[0,1,2]]
            result = {"geometryID": "actual-measurement", "meshSHA256": "a" * 64, "layoutRevision": 3}
        elif method == "world_prop_ui_intent":
            assert p["command"] == {"op": "place", "objectID": "sofa", "position": [1, 2, 3], "yaw": .25}
            intent, capability = str(uuid.uuid4()), str(uuid.uuid4())
            expires = int(time.time() * 1000) + 10000
            leases[intent] = (capability, expires)
            result = {"intentID": intent, "capability": capability, "expiresAtMS": expires}
        else:
            assert method == "world_prop_command" and calls.count(method) <= 2
            a = p["authority"]
            capability, expires = leases.pop(a["intentID"])
            assert a == {"kind": "ui", "intentID": a["intentID"], "capability": capability} and int(time.time() * 1000) < expires
            assert p["geometryID"] == "actual-measurement" and p["expectedLayoutRevision"] == 3
            assert "command" not in p and "state" not in p and "runID" not in p
            result = {"actualCommit": True}
        self.respond(wire["id"], result)
    def respond(self, identity, result):
        data = json.dumps({"id": identity, "result": result}).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)

with tempfile.TemporaryDirectory(prefix="gmgn-private-prop-ui-") as tmp:
    root = Path(tmp)
    fixture_root = root
    (root / "environment.private-fixture").write_bytes(b"private measured collision bytes")
    (root / "prop.private-fixture").write_bytes(b"private loaded source prop bytes")
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    endpoint = root / "endpoint.json"
    endpoint.write_text(json.dumps({"version": 2, "address": "127.0.0.1:" + str(server.server_port), "token": token}))
    os.chmod(endpoint, 0o600)
    binary = root / "checks"
    subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library",
        str(repo / "apps/macos/Sources/GMGNRadio/Presence/TaskdHTTPTransport.swift"),
        str(repo / "apps/macos/Sources/GMGNRadio/Presence/RustWorldPropClient.swift"),
        str(repo / "apps/macos/UnityHost/UnityWorldBridge.swift"),
        str(Path(__file__).with_suffix(".swift")), "-o", str(binary)], check=True)
    subprocess.run([str(binary), str(root)], check=True)
    assert calls == ["world_prop_observe", "world_prop_ui_intent", "world_prop_command", "world_blob_put", "world_blob_put", "world_prop_observe", "world_prop_ui_intent", "world_prop_command"]
    server.shutdown()

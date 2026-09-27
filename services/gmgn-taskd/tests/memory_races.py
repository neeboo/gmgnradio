"""Offline race regressions for the VoiceMem Rust memory IPC (real taskd child,
private temp roots, loopback provider fixture on the OpenAI-compatible wire).

Mirrors the main agent's independent checks
(/tmp/gmgn-memory-independent-20260908.py MemoryRaceChecks) against the daemon's
own binary and fixture, covering the two acceptance failures:

1. test_disconnect_cancels_uncommitted_compaction — a client that disconnects
   while its memory_compact is still inside the compaction provider must not
   commit the late provider response; the snapshot stays absent and the pending
   turn survives.
2. test_concurrent_compaction_checks_captured_base_generation — a compaction
   that captured the old snapshot generation must be rejected
   (memory_conflict) once another writer committed first, even when
   expectedVectorGeneration was omitted; the later writer's output never
   overwrites the earlier commit and its pending turns are preserved.

Only temporary directories, the taskd child and the loopback fixture are used.
"""
import json
import os
import socket
import threading
import time
import unittest
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import tempfile

BIN = os.environ.get(
    "TASKD_BIN",
    "/Users/ghostcorn/dev/gmgnradio/services/gmgn-taskd/target/debug/gmgn-taskd",
)

TOKEN = "memory-races-secret-do-not-persist"
MODEL = "fixture-embed"
MODEL_COMP = "fixture-compact"


def scope(world="world-a", resident="resident-a"):
    return {"worldID": world, "residentScope": resident}


class Daemon:
    """Real gmgn-taskd child over its Unix socket (one request per connection;
    connect() keeps a connection open for the disconnect test)."""

    def __init__(self, root):
        self.root = Path(root)
        self.path = str(self.root / "taskd.sock")
        self.start()

    def start(self, extra=()):
        self.p = __import__("subprocess").Popen(
            [BIN, "--root", str(self.root), "--socket", self.path,
             "--concurrency", "2", *extra],
            stdout=__import__("subprocess").PIPE,
            stderr=__import__("subprocess").PIPE)
        for _ in range(500):
            if self.p.poll() is not None:
                break
            try:
                with self.connect():
                    return
            except OSError:
                time.sleep(.02)
        if self.p.poll() is None:
            self.p.kill()
        raise AssertionError(
            "daemon did not expose its socket: " +
            self.p.communicate(timeout=2)[1].decode())

    def connect(self):
        s = socket.socket(socket.AF_UNIX)
        s.settimeout(8)
        try:
            s.connect(self.path)
        except Exception:
            s.close()
            raise
        return s

    def request(self, method, params=None):
        params = params or {}
        with self.connect() as s:
            s.sendall(json.dumps(dict(id="t", method=method,
                                      params=params)).encode() + b"\n")
            with s.makefile("rb") as stream:
                return json.loads(stream.readline())

    def stop(self):
        if self.p.poll() is None:
            self.p.kill()
        self.p.communicate(timeout=3)


class FixtureServer:
    """OpenAI-compatible compaction/embedding fixture with per-request gates:
    the first two /v1/chat/completions calls each block until released, exactly
    like the independent fixture the main agent uses."""

    def __init__(self):
        self.entered = [threading.Event(), threading.Event()]
        self.release = [threading.Event(), threading.Event()]
        self.count = 0
        self.lock = threading.Lock()
        self.requests = []
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                body = json.loads(self.rfile.read(
                    int(self.headers["Content-Length"])))
                owner.requests.append((self.path, body))
                if self.path == "/v1/chat/completions":
                    with owner.lock:
                        index = owner.count
                        owner.count += 1
                    owner.entered[index].set()
                    if not owner.release[index].wait(5):
                        self.send_error(504)
                        return
                    compact = {
                        "facts": [{"category": "fact",
                                   "text": f"snapshot-{index}",
                                   "observedAt": "2026-09-08"}],
                        "notes": [], "removed": [],
                    }
                    result = {
                        "model": body.get("model", MODEL_COMP),
                        "choices": [{"message": {"role": "assistant",
                                                 "content": json.dumps(compact)}}],
                    }
                elif self.path == "/v1/embeddings":
                    result = {
                        "model": MODEL,
                        "data": [{"index": index, "embedding": [1.0, 0.0]}
                                 for index, _ in enumerate(body.get("input", []))],
                    }
                else:
                    self.send_error(404)
                    return
                data = json.dumps(result).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever,
                                       daemon=True)
        self.thread.start()

    def configure(self, daemon):
        for kind in ["compaction", "embedding"]:
            reply = daemon.request("memory_configure", {
                "kind": kind,
                "endpoint": f"http://127.0.0.1:{self.server.server_port}",
                "token": TOKEN, "model": MODEL_COMP if kind == "compaction" else MODEL})
            assert "result" in reply, reply

    def stop(self):
        for event in self.release:
            event.set()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(2)


class MemoryRaceChecks(unittest.TestCase):
    def setUp(self):
        if not Path(BIN).is_file():
            self.skipTest("gmgn-taskd binary not found; cargo build first")
        self.temp = tempfile.TemporaryDirectory(prefix="taskd-memory-races-",
                                                dir="/tmp")
        self.daemon = Daemon(self.temp.name)
        self.scope = scope()
        self.fixture = FixtureServer()
        self.addCleanup(self.fixture.stop)
        self.addCleanup(self.daemon.stop)
        self.addCleanup(self.temp.cleanup)
        self.fixture.configure(self.daemon)

    def tearDown(self):
        pass

    def call(self, method, **params):
        return self.daemon.request(method, {"scope": self.scope, **params})

    def test_disconnect_cancels_uncommitted_compaction(self):
        self.call("memory_turn", role="user", text="pending-before-cancel")
        client = self.daemon.connect()
        client.sendall(json.dumps({"id": "disconnect", "method": "memory_compact",
                                   "params": {"scope": self.scope,
                                              "requestID": str(uuid.uuid4())}}).encode()
                       + b"\n")
        self.assertTrue(self.fixture.entered[0].wait(3),
                        "provider call never arrived")
        client.close()
        time.sleep(.1)
        self.fixture.release[0].set()
        time.sleep(.4)
        self.assertIsNone(self.call("memory_read")["result"]["memory"],
                          "disconnected compaction must not commit a late snapshot")
        self.assertEqual(len(self.call("memory_pending")["result"]["turns"]), 1)

    def test_concurrent_compaction_checks_captured_base_generation(self):
        results = [None, None]

        def compact(index):
            results[index] = self.call("memory_compact",
                                       requestID=str(uuid.uuid4()))

        self.call("memory_turn", role="user", text="input-A")
        first = threading.Thread(target=compact, args=(0,))
        first.start()
        self.assertTrue(self.fixture.entered[0].wait(3))
        self.call("memory_turn", role="user", text="input-B")
        second = threading.Thread(target=compact, args=(1,))
        second.start()
        self.assertTrue(self.fixture.entered[1].wait(3))
        self.fixture.release[0].set()
        first.join(3)
        self.assertIn("result", results[0])
        self.fixture.release[1].set()
        second.join(3)
        self.assertIn("error", results[1],
                      "stale captured snapshot must not overwrite a newer commit")
        self.assertEqual(results[1]["error"]["code"], "memory_conflict")
        # The committed snapshot is the first writer's output; the second
        # writer's turns stay pending for a later, correctly based retry.
        read = self.call("memory_read")["result"]["memory"]
        self.assertEqual(read["revision"], 1)
        texts = [f["text"] for f in read["sections"]["facts"]]
        self.assertEqual(texts, ["snapshot-0"])
        pending = self.call("memory_pending")["result"]["turns"]
        self.assertEqual([turn["text"] for turn in pending], ["input-B"])


if __name__ == "__main__":
    unittest.main(verbosity=2)

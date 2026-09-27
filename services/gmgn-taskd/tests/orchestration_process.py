"""Offline orchestration contract tests for the VoiceMem Rust memory IPC.

Drives the real gmgn-taskd child over its Unix socket with loopback provider
fixtures only: background two-lane consolidation scheduling (batch trigger,
independence from the short IPC connection), memory_ingest atomic/idempotent
volatile semantics, memory_recall per-lane quotas/shared embedding, and the
memory_status.orchestration surface. Every wait is bounded by a hard deadline;
no test sleeps for the idle (30s) policy.

Private temp roots and local Unix sockets only: never starts the macOS app,
never touches the keychain or any real provider/model.
"""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid

BIN = os.environ.get("TASKD_BIN", "/tmp/gmgn-taskd-target-rust-worker/debug/gmgn-taskd")
TOKEN = "orchestration-offline-secret-do-not-persist"
MODEL = "fixture-embed-1"
MODEL_COMP = "fixture-compact-1"
WORLD = "world-a"
RESIDENT = "resident-a"


def scope(world=WORLD, resident=RESIDENT):
    return {"worldID": world, "residentScope": resident}


def chat_user_data(body):
    for message in body.get("messages", []):
        if message.get("role") == "user":
            return json.loads(message["content"])
    raise AssertionError("chat request has no user content")


class Remote:
    """Loopback OpenAI-compatible fixture. Compaction always returns the same
    two facts plus one grounded note (so unchanged ids must stay stable across
    consolidations); embeddings are content derived ([1,0] facts, [0.8,0.2]
    notes) so recall lane distances are predictable."""

    def __init__(self):
        self.lock = threading.Lock()
        self.chat_bodies = []
        self.embedding_bodies = []
        import http.server

        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def reply(self, value, code=200):
                data = json.dumps(value).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def chat_reply(self, model, envelope):
                return {
                    "id": "chatcmpl-fixture",
                    "object": "chat.completion",
                    "model": model,
                    "choices": [{
                        "index": 0,
                        "message": {"role": "assistant",
                                    "content": json.dumps(envelope)},
                        "finish_reason": "stop",
                    }],
                }

            def do_POST(self):
                length = int(self.headers["Content-Length"])
                body = json.loads(self.rfile.read(length))
                if self.path == "/v1/chat/completions":
                    with outer.lock:
                        outer.chat_bodies.append(body)
                    model = body.get("model")
                    envelope = {
                        "facts": [
                            {"category": "fact", "text": "alice hikes near the cabin",
                             "observedAt": "2026-09-08", "grounding": "turn:1"},
                            {"category": "fact", "text": "the resident owns a grey cat",
                             "observedAt": "2026-09-08", "grounding": "turn:1"},
                        ],
                        "notes": [
                            {"category": "experience",
                             "text": "resident stays calm when tired",
                             "observedAt": "2026-09-08", "grounding": "turn:1"},
                        ],
                        "removed": [],
                    }
                    return self.reply(self.chat_reply(model, envelope))
                if self.path == "/v1/embeddings":
                    with outer.lock:
                        outer.embedding_bodies.append(body)
                    texts = body.get("input", [])
                    data = []
                    for index, text in enumerate(texts):
                        lowered = text.lower()
                        if "alice" in lowered:
                            vector = [1.0, 0.0, 0.0]
                        elif "grey cat" in lowered:
                            vector = [0.0, 1.0, 0.0]
                        elif "calm" in lowered:
                            vector = [0.7, 0.7, 0.0]
                        else:
                            vector = [0.4, 0.4, 0.4]
                        data.append({"object": "embedding", "index": index,
                                     "embedding": vector})
                    return self.reply({"object": "list", "data": data, "model": MODEL})
                return self.reply({"error": "not found"}, 404)

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.endpoint = "http://127.0.0.1:" + str(self.server.server_port)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


class Daemon:
    def __init__(self, root):
        self.root = Path(root)
        self.path = str(self.root / "taskd.sock")
        self.start()

    def start(self, extra=()):
        self.p = subprocess.Popen(
            [BIN, "--root", str(self.root), "--socket", self.path, "--concurrency", "2", *extra],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
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
        raise AssertionError("daemon did not expose its socket: " +
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

    def request(self, method, params=None, request_id="t"):
        params = params or {}
        with self.connect() as s:
            s.sendall(json.dumps({"id": request_id, "method": method,
                                  "params": params}).encode() + b"\n")
            with s.makefile("rb") as stream:
                return json.loads(stream.readline())

    def stop(self):
        if self.p.poll() is None:
            self.p.kill()
        self.p.communicate(timeout=3)


class OrchestrationProcessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="taskd-orchestration-", dir="/tmp")
        self.remote = Remote()
        self.daemon = None
        self.addCleanup(self.remote.close)

    def tearDown(self):
        if self.daemon:
            self.daemon.stop()
        self.temp.cleanup()

    def start(self):
        self.daemon = Daemon(self.temp.name)
        return self.daemon

    def configure(self):
        d = self.daemon
        self.assertIn("result", d.request("memory_configure", {
            "kind": "compaction", "endpoint": self.remote.endpoint, "token": TOKEN,
            "model": MODEL_COMP}))
        self.assertIn("result", d.request("memory_configure", {
            "kind": "embedding", "endpoint": self.remote.endpoint, "token": TOKEN,
            "model": MODEL}))

    def ingest(self, user="真实转写", reply="确已交付的答复", request_id=None, source="voice"):
        return self.daemon.request("memory_ingest", {
            "scope": scope(), "requestID": request_id or str(uuid.uuid4()),
            "userText": user, "agentReply": reply, "source": source,
            "observedAt": "2026-09-08T11:00:00+08:00"})

    def wait_for(self, predicate, what, deadline=8.0):
        started = time.time()
        while time.time() - started < deadline:
            try:
                if predicate():
                    return
            except AssertionError:
                raise
            except Exception:
                pass
            time.sleep(.1)
        raise AssertionError("timed out waiting for " + what)

    def status(self):
        return self.daemon.request("memory_status", {"scope": scope()})["result"]

    def assert_token_not_persisted(self):
        for path in Path(self.temp.name).rglob("*"):
            if path.is_file():
                self.assertFalse(TOKEN.encode() in path.read_bytes(),
                                 "credential persisted to " + path.name)

    def test_ingest_is_atomic_idempotent_volatile_and_visible_in_status(self):
        d = self.start()
        self.configure()
        request_id = str(uuid.uuid4())
        marker = "raw-volatile-" + uuid.uuid4().hex
        accepted = self.ingest(marker, request_id=request_id)
        self.assertEqual(accepted["result"]["pendingTurns"], 2)
        self.assertFalse(accepted["result"]["replayed"])
        self.assertIn(accepted["result"]["consolidation"],
                      ("pending", "running", "idle"))
        replay = self.ingest(marker, request_id=request_id)
        self.assertTrue(replay["result"]["replayed"])
        conflict = self.ingest("不同的文本", request_id=request_id)
        self.assertEqual(conflict["error"]["code"], "memory_request_conflict")
        pending = d.request("memory_pending", {"scope": scope()})["result"]["turns"]
        self.assertEqual(len(pending), 2)
        invalid = self.ingest("would-be-half", request_id=str(uuid.uuid4()), reply="")
        self.assertIn("error", invalid)
        self.assertEqual(len(d.request("memory_pending", {"scope": scope()})["result"]["turns"]), 2)
        orch = self.status()["orchestration"]
        self.assertIn(orch["state"], ("idle", "pending", "running", "unconfigured", "failed"))
        self.assertIn("lastError", orch)

        d.stop()
        for path in Path(self.temp.name).glob("tasks.sqlite3*"):
            self.assertNotIn(marker.encode(), path.read_bytes(),
                             "raw ingest text leaked to the private root")
        d.start()
        self.assertEqual(d.request("memory_pending", {"scope": scope()})["result"]["turns"], [])
        self.assert_token_not_persisted()

    def test_background_batch_consolidation_runs_without_explicit_compact(self):
        d = self.start()
        self.configure()
        # 4 pending turns reaches the batch threshold: the daemon consolidates
        # on its own after the short batch delay (no memory_compact call).
        first = self.ingest("第一轮用户", "第一轮答复")
        self.assertEqual(first["result"]["pendingTurns"], 2)
        second = self.ingest("第二轮用户", "第二轮答复")
        self.assertEqual(second["result"]["pendingTurns"], 4)

        def settled():
            result = self.status()
            return (result.get("memory") is not None
                    and result.get("pendingTurns") == 0)
        self.wait_for(settled, "background batch consolidation", deadline=10.0)
        status = self.status()
        self.assertGreaterEqual(status["memory"]["revision"], 1)
        self.assertEqual(status["memory"]["vectorGeneration"], status["memory"]["revision"])
        read = d.request("memory_read", {"scope": scope()})["result"]["memory"]
        self.assertEqual(read["sections"]["notes"][0]["grounding"], "turn:1")
        self.assertEqual(d.request("memory_pending", {"scope": scope()})["result"]["turns"], [])
        with self.remote.lock:
            chats = len(self.remote.chat_bodies)
        self.assertEqual(chats, 1, "exactly one automatic consolidation ran")
        self.assertEqual(status["orchestration"]["state"], "idle")
        # Raw transcripts never reached the disk (background commit included).
        for path in Path(self.temp.name).glob("tasks.sqlite3*"):
            content = path.read_bytes()
            self.assertNotIn("第一轮用户".encode(), content)
            self.assertNotIn("第一轮答复".encode(), content)

    def test_accepted_ingest_survives_short_connection_lifetime(self):
        d = self.start()
        self.configure()

        # Negative: an ingest whose connection dies before the reply is never
        # accepted — no half pair may linger in the volatile buffer.
        payload = json.dumps(
            {"id": "disconnect-me", "method": "memory_ingest",
             "params": {"scope": scope(), "requestID": str(uuid.uuid4()),
                        "userText": "断连即取消不应留下半对",
                        "agentReply": "未确认送达",
                        "source": "voice",
                        "observedAt": "2026-09-08T11:00:00+08:00"}}
        ).encode() + b"\n"
        with d.connect() as s:
            s.sendall(payload)
            # Close before reading any reply: the request is canceled, nothing
            # accepted (distinct from memory_compact's cancel-gate semantics:
            # there is no durable write to gate here).
        self.assertEqual(self.status().get("pendingTurns"), 0,
                         "an un-accepted ingest must not leave a half pair")
        self.assertIsNone(self.status().get("memory"))

        # Positive: accepted, delivered turns consolidate on the daemon's own
        # schedule even though every connection that delivered them was short
        # lived and is already closed (four pending turns cross the batch
        # threshold, so this happens without any explicit memory_compact and
        # without waiting for the idle timer).
        self.assertIn("result", self.ingest("第一轮真实用户", "第一轮答复"))
        self.assertIn("result", self.ingest("第二轮真实用户", "第二轮答复"))
        self.assertEqual(self.status().get("pendingTurns"), 4)
        self.wait_for(
            lambda: self.status().get("pendingTurns") == 0
            and self.status().get("memory") is not None,
            "background consolidation after connections closed",
            deadline=10.0)
        status = self.status()
        self.assertGreaterEqual(status["memory"]["revision"], 1)
        self.assertEqual(status["orchestration"]["state"], "idle")
        read = d.request("memory_read", {"scope": scope()})["result"]["memory"]
        facts = [entry["text"] for entry in read["sections"]["facts"]]
        self.assertIn("alice hikes near the cabin", facts)

    def test_recall_lane_quotas_shared_embedding_and_stable_ids(self):
        d = self.start()
        self.configure()
        self.ingest("第一次", "第一次答复")
        compact = d.request("memory_compact", {"scope": scope(),
                                               "requestID": str(uuid.uuid4())})["result"]
        first = d.request("memory_read", {"scope": scope()})["result"]["memory"]
        self.assertGreaterEqual(compact["vectorGeneration"], 1)
        with self.remote.lock:
            before = len(self.remote.embedding_bodies)
        result = d.request("memory_recall", {"scope": scope(), "query": "alice",
                                             "factLimit": 1, "noteLimit": 1,
                                             "freshSession": False})["result"]
        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["vectorGeneration"], compact["vectorGeneration"])
        self.assertEqual(len(result["facts"]), 1)
        self.assertEqual(len(result["notes"]), 1,
                         "facts must not crowd out the notes lane")
        self.assertEqual(result["facts"][0]["text"], "alice hikes near the cabin")
        self.assertEqual(result["notes"][0]["text"], "resident stays calm when tired")
        self.assertLessEqual(len(result["context"]), 8000)
        self.assertIn("禁止照读", result["context"])
        with self.remote.lock:
            after = len(self.remote.embedding_bodies)
        self.assertEqual(after - before, 1, "both lanes share one query embedding")

        # Unchanged entries keep their ids across the next consolidation.
        self.ingest("第二次", "第二次答复")
        d.request("memory_compact", {"scope": scope(), "requestID": str(uuid.uuid4())})
        second = d.request("memory_read", {"scope": scope()})["result"]["memory"]
        self.assertEqual(
            [entry["id"] for entry in first["sections"]["facts"]],
            [entry["id"] for entry in second["sections"]["facts"]],
            "unchanged entries must retain stable ids")
        # A different resident scope shares no semantic memory.
        other = d.request("memory_recall", {
            "scope": scope(resident="another-resident"), "query": "alice",
            "factLimit": 6, "noteLimit": 4})["result"]
        self.assertEqual(other["facts"], [])
        self.assertEqual(other["notes"], [])
        self.assertEqual(other["revision"], 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)

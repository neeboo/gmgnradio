"""Offline contract tests for the VoiceMem Rust memory IPC: real taskd child,
private temp roots, loopback provider fixtures only."""
import hashlib
import http.server
import json
import math
import os
from pathlib import Path
import re
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid

BIN = os.environ.get("TASKD_BIN", "/tmp/gmgn-taskd-target-rust-worker/debug/gmgn-taskd")
TOKEN = "memory-offline-secret-do-not-persist"
MODEL = "fixture-embed-1"
MODEL_COMP = "fixture-compact-1"
DIMS = 8
WORLD = "world-a"
RESIDENT = "resident-a"


def embed_text(text):
    v = [0.0] * DIMS
    for token in re.findall(r"[a-z0-9]+", text.lower()):
        digest = hashlib.sha256(token.encode()).digest()
        v[digest[0] % DIMS] += 1.0 + digest[1] / 255.0
    if not any(v):
        v[0] = 1.0
    norm = math.sqrt(sum(x * x for x in v)) or 1.0
    return [round(x / norm, 6) for x in v]


def scope(world=WORLD, resident=RESIDENT):
    return {"worldID": world, "residentScope": resident}


def chat_user_data(body):
    """Decode the compaction user content of an OpenAI-compatible chat request."""
    for message in body.get("messages", []):
        if message.get("role") == "user":
            return json.loads(message["content"])
    raise AssertionError("chat request has no user content")


def chat_reply(model, envelope):
    """OpenAI-compatible chat completion whose assistant content is the frozen
    compaction envelope JSON."""
    return {
        "id": "chatcmpl-fixture",
        "object": "chat.completion",
        "model": model,
        "choices": [{
            "index": 0,
            "message": {"role": "assistant", "content": json.dumps(envelope)},
            "finish_reason": "stop",
        }],
    }


class MemoryRemote:
    """Offline loopback stub for the daemon's compaction/embedding providers,
    speaking the documented OpenAI-compatible wire: /v1/chat/completions for
    compaction (configured model + system rules + user data, JSON content) and
    /v1/embeddings (data[index].embedding + model)."""

    def __init__(self):
        self.compaction_bodies = []
        self.embedding_bodies = []
        self.lock = threading.Lock()
        self.fail_compaction = False
        self.fail_embedding = False
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def reply(self, value, code=200):
                data = json.dumps(value).encode()
                self.send_response(code)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                try:
                    self.wfile.write(data)
                except (BrokenPipeError, ConnectionResetError):
                    pass

            def do_POST(self):
                if self.headers.get("Authorization") != "Bearer " + TOKEN:
                    return self.reply({"error": "unauthorized"}, 401)
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                if self.path == "/v1/chat/completions":
                    with outer.lock:
                        outer.compaction_bodies.append(body)
                        fail = outer.fail_compaction
                    if fail:
                        return self.reply({"error": "fixture compaction down"}, 500)
                    model = body.get("model")
                    if model != MODEL_COMP:
                        return self.reply({"error": "wrong model"}, 400)
                    system = [m["content"] for m in body.get("messages", [])
                              if m.get("role") == "system"]
                    if not system:
                        return self.reply({"error": "missing rules"}, 400)
                    user = chat_user_data(body)
                    facts = []
                    for turn in user.get("turns", []):
                        facts.append({
                            "category": "fact",
                            "text": "remembered:" + turn["text"],
                            "observedAt": "2026-09-08",
                            "grounding": "turn:" + str(turn["watermark"]),
                        })
                    previous = user.get("previous")
                    for old in (previous or {}).get("sections", {}).get("facts", []):
                        facts.append({
                            "category": "fact",
                            "text": old["text"],
                            "observedAt": old.get("observedAt"),
                            "grounding": old.get("grounding"),
                        })
                    return self.reply(chat_reply(
                        model, {"facts": facts, "notes": [], "removed": []}))
                if self.path == "/v1/embeddings":
                    with outer.lock:
                        outer.embedding_bodies.append(body)
                        fail = outer.fail_embedding
                    if fail:
                        return self.reply({"error": "fixture embedding down"}, 500)
                    texts = body.get("input", [])
                    return self.reply({
                        "object": "list",
                        "data": [{
                            "object": "embedding",
                            "index": index,
                            "embedding": embed_text(text),
                        } for index, text in enumerate(texts)],
                        "model": MODEL,
                    })
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

    def request(self, method, params=None):
        params = params or {}
        with self.connect() as s:
            s.sendall(json.dumps(dict(id="t", method=method, params=params)).encode() + b"\n")
            with s.makefile("rb") as stream:
                return json.loads(stream.readline())

    def stop(self):
        if self.p.poll() is None:
            self.p.kill()
        self.p.communicate(timeout=3)


class MemoryProcessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="taskd-memory-", dir="/tmp")
        self.remote = MemoryRemote()
        self.daemon = None

    def tearDown(self):
        if self.daemon:
            self.daemon.stop()
        self.remote.close()
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

    def assert_token_not_persisted(self):
        for path in Path(self.temp.name).rglob("*"):
            if path.is_file():
                self.assertFalse(TOKEN.encode() in path.read_bytes(),
                                 "credential persisted to " + path.name)
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_status_read_pending_before_any_configuration(self):
        d = self.start()
        status = d.request("memory_status", {"scope": scope()})["result"]
        self.assertEqual(status["configured"], {"compaction": False, "embedding": False})
        self.assertIsNone(status["memory"])
        self.assertEqual(status["pendingTurns"], 0)
        self.assertIsNone(d.request("memory_read", {"scope": scope()})["result"]["memory"])
        self.assertEqual(d.request("memory_pending", {"scope": scope()})["result"]["turns"], [])
        query = d.request("memory_query", {"scope": scope(), "query": "anything"})["result"]
        self.assertEqual(query["status"], "unconfigured")
        self.assertEqual(query["results"], [])
        self.assert_token_not_persisted()

    def test_invalid_inputs_are_rejected_with_stable_codes(self):
        d = self.start()
        s = scope()
        cases = [
            ("memory_turn", {"scope": {"worldID": "", "residentScope": RESIDENT}, "role": "user", "text": "x"},
             "invalid_scope"),
            ("memory_turn", {"scope": s, "role": "system", "text": "x"}, "invalid_role"),
            ("memory_turn", {"scope": s, "role": "user", "text": "   "}, "invalid_turn_text"),
            ("memory_turn", {"scope": s, "role": "user", "text": "line\nbreak"}, "invalid_turn_text"),
            ("memory_turn", {"scope": s, "role": "user", "text": "x" * 2001}, "turn_text_too_large"),
            ("memory_query", {"scope": s, "query": "", "topK": 3}, "invalid_query"),
            ("memory_query", {"scope": s, "query": "x" * 501}, "invalid_query"),
            ("memory_query", {"scope": s, "query": "x", "topK": 0}, "invalid_topk"),
            ("memory_query", {"scope": s, "query": "x", "topK": 21}, "invalid_topk"),
            ("memory_compact", {"scope": s, "requestID": "not-a-uuid"}, "invalid_memory_compact"),
            ("memory_compact", {"scope": s, "requestID": str(uuid.uuid4()),
                                "expectedVectorGeneration": -1}, "invalid_memory_compact"),
            ("memory_turn", {"scope": s, "role": "user", "text": "x", "typoField": 1},
             "invalid_memory_turn"),
            ("memory_status", {"scope": s, "typo": 1}, "invalid_memory_status"),
            ("memory_read", {"scope": s, "extra": True}, "invalid_memory_read"),
            ("memory_query", {"scope": s, "query": "x", "topK": 3, "extra": 1}, "invalid_memory_query"),
            ("memory_pending", {"scope": s, "extra": 1}, "invalid_memory_pending"),
            ("memory_compact", {"scope": s, "requestID": str(uuid.uuid4()), "extra": 1},
             "invalid_memory_compact"),
        ]
        for method, params, code in cases:
            response = d.request(method, params)
            self.assertEqual(response.get("error", {}).get("code"), code, (method, params))

    def test_full_lifecycle_turn_compact_read_query_and_scope_isolation(self):
        d = self.start()
        self.configure()
        s = scope()
        first = d.request("memory_turn", {"scope": s, "role": "user",
                                          "text": "my dog is named Biscuit"})["result"]
        self.assertEqual((first["watermark"], first["pendingTurns"]), (1, 1))
        second = d.request("memory_turn", {"scope": s, "role": "agent",
                                           "text": "I will remember Biscuit"})["result"]
        self.assertEqual(second["watermark"], 2)
        third = d.request("memory_turn", {"scope": s, "role": "user",
                                          "text": "my childhood friend is Maria",
                                          "interrupted": False})["result"]
        self.assertEqual(third["watermark"], 3)
        pending = d.request("memory_pending", {"scope": s})["result"]["turns"]
        self.assertEqual([t["watermark"] for t in pending], [1, 2, 3])
        self.assertEqual(pending[2]["role"], "user")

        request_id = str(uuid.uuid4())
        compacted = d.request("memory_compact", {"scope": s, "requestID": request_id,
                                                 "expectedVectorGeneration": 0})["result"]
        self.assertEqual(compacted, {"revision": 1, "vectorGeneration": 1, "replayed": False,
                                     "processedWatermark": 3, "pendingTurns": 0})
        # The compaction provider really received an OpenAI-compatible chat
        # request with the configured model, the frozen rules and the captured
        # turns/previous in the user content.
        first_body = self.remote.compaction_bodies[0]
        self.assertEqual(first_body["model"], MODEL_COMP)
        system = [m["content"] for m in first_body["messages"] if m.get("role") == "system"]
        self.assertTrue(system and "facts" in system[0] and "grounding" in system[0],
                        "semantic rules are sent to the compaction provider")
        first_user = chat_user_data(first_body)
        self.assertEqual(first_user["schemaVersion"], 1)
        self.assertEqual(first_user["turns"][0]["text"], "my dog is named Biscuit")
        self.assertIsNone(first_user["previous"])
        embedded = self.remote.embedding_bodies[0]["input"]
        self.assertTrue(any("Biscuit" in t for t in embedded))

        status = d.request("memory_status", {"scope": s})["result"]
        self.assertEqual(status["memory"]["revision"], 1)
        self.assertEqual(status["memory"]["vectorGeneration"], 1)
        self.assertEqual(status["memory"]["processedWatermark"], 3)
        self.assertEqual(status["memory"]["embedding"], {"model": MODEL, "dimensions": DIMS})
        self.assertEqual(status["memory"]["entryCounts"], {"facts": 3, "notes": 0})
        self.assertEqual(status["pendingTurns"], 0)

        read = d.request("memory_read", {"scope": s})["result"]["memory"]
        self.assertEqual(read["schemaVersion"], 1)
        texts = [f["text"] for f in read["sections"]["facts"]]
        self.assertTrue(any(t == "remembered:my dog is named Biscuit" for t in texts))
        self.assertTrue(all(t.startswith("remembered:") for t in texts))

        query = d.request("memory_query", {"scope": s, "query": "Biscuit dog", "topK": 2})["result"]
        self.assertEqual(query["status"], "ok")
        results = query["results"]
        self.assertLessEqual(len(results), 2)
        distances = [r["distance"] for r in results]
        self.assertEqual(distances, sorted(distances))
        self.assertIn("Biscuit", results[0]["text"])
        self.assertTrue(all(r["section"] == "facts" for r in results))

        # A second compaction carries the previous snapshot forward and its
        # fixture echoes it, so revision 2 keeps old facts plus the new turn.
        d.request("memory_turn", {"scope": s, "role": "user", "text": "likes cold brew"})
        request_id_2 = str(uuid.uuid4())
        second_compact = d.request("memory_compact", {"scope": s, "requestID": request_id_2,
                                                      "expectedVectorGeneration": 1})["result"]
        self.assertEqual(second_compact["revision"], 2)
        previous_sent = chat_user_data(self.remote.compaction_bodies[1])["previous"]
        self.assertEqual(previous_sent["revision"], 1)
        read = d.request("memory_read", {"scope": s})["result"]["memory"]
        self.assertEqual(len(read["sections"]["facts"]), 4)

        # World/resident isolation: a sibling scope has no snapshot and its own
        # pending buffer; it cannot see the first scope's memory.
        other = {"worldID": WORLD, "residentScope": "resident-b"}
        other_status = d.request("memory_status", {"scope": other})["result"]
        self.assertIsNone(other_status["memory"])
        d.request("memory_turn", {"scope": other, "role": "user", "text": "private to b"})
        other_pending = d.request("memory_pending", {"scope": other})["result"]["turns"]
        self.assertEqual(len(other_pending), 1)
        a_pending = d.request("memory_pending", {"scope": s})["result"]["turns"]
        self.assertEqual(a_pending, [])
        self.assertEqual(d.request("memory_query", {"scope": other, "query": "Biscuit"})["result"],
                         {"status": "unconfigured", "results": []})
        self.assert_token_not_persisted()

    def test_replay_and_generation_conflict_and_request_conflict(self):
        d = self.start()
        self.configure()
        s = scope()
        d.request("memory_turn", {"scope": s, "role": "user", "text": "keep me"})
        request_id = str(uuid.uuid4())
        first = d.request("memory_compact", {"scope": s, "requestID": request_id})["result"]
        self.assertEqual((first["revision"], first["replayed"]), (1, False))
        calls = len(self.remote.compaction_bodies)
        replay = d.request("memory_compact", {"scope": s, "requestID": request_id})["result"]
        self.assertTrue(replay["replayed"])
        self.assertEqual(replay["revision"], 1)
        self.assertEqual(len(self.remote.compaction_bodies), calls,
                         "replay must not call the compaction provider again")

        # A stale expectedVectorGeneration conflicts.
        d.request("memory_turn", {"scope": s, "role": "user", "text": "second turn"})
        conflict = d.request("memory_compact", {"scope": s,
                                                "requestID": str(uuid.uuid4()),
                                                "expectedVectorGeneration": 0})
        self.assertEqual(conflict["error"]["code"], "memory_conflict")
        # The failed compact leaves pending untouched.
        status = d.request("memory_status", {"scope": s})["result"]
        self.assertEqual(status["pendingTurns"], 1)
        self.assertEqual(status["memory"]["revision"], 1)

        # Same requestID with a different CAS expectation is different content.
        same_id_conflict = d.request("memory_compact", {"scope": s, "requestID": request_id,
                                                        "expectedVectorGeneration": 9})
        self.assertEqual(same_id_conflict["error"]["code"], "memory_request_conflict")
        self.assert_token_not_persisted()

    def test_unavailable_and_failure_keep_pending_and_old_snapshot(self):
        d = self.start()
        s = scope()
        d.request("memory_turn", {"scope": s, "role": "user", "text": "first attempt"})
        unconfigured = d.request("memory_compact", {"scope": s,
                                                    "requestID": str(uuid.uuid4())})
        self.assertEqual(unconfigured["error"]["code"], "compaction_unavailable")
        # Embedding configured only: compaction still unavailable.
        d.request("memory_configure", {"kind": "embedding", "endpoint": self.remote.endpoint,
                                       "token": TOKEN})
        still = d.request("memory_compact", {"scope": s, "requestID": str(uuid.uuid4())})
        self.assertEqual(still["error"]["code"], "compaction_unavailable")

        self.configure()
        d.request("memory_turn", {"scope": s, "role": "user", "text": "goes through"})
        good = d.request("memory_compact", {"scope": s,
                                            "requestID": str(uuid.uuid4()),
                                            "expectedVectorGeneration": 0})["result"]
        self.assertEqual(good["revision"], 1)

        # Provider outage: compaction fails and the pending turn + snapshot
        # survive untouched.
        self.remote.fail_compaction = True
        d.request("memory_turn", {"scope": s, "role": "user", "text": "during outage"})
        failed = d.request("memory_compact", {"scope": s,
                                              "requestID": str(uuid.uuid4()),
                                              "expectedVectorGeneration": 1})
        self.assertEqual(failed["error"]["code"], "memory_compact_failed")
        status = d.request("memory_status", {"scope": s})["result"]
        self.assertEqual(status["pendingTurns"], 1)
        self.assertEqual(status["memory"]["revision"], 1)
        self.remote.fail_compaction = False

        # Query-time embedding outage is an explicit error, never a fake result.
        self.remote.fail_embedding = True
        self.assertIn("error", d.request("memory_query", {"scope": s, "query": "Biscuit"}))
        self.remote.fail_embedding = False
        query = d.request("memory_query", {"scope": s, "query": "Biscuit"})["result"]
        self.assertEqual(query["status"], "ok")
        self.assert_token_not_persisted()

    def test_restart_keeps_snapshot_loses_volatile_pending_and_requires_reconfigure(self):
        d = self.start()
        self.configure()
        s = scope()
        volatile_marker = "volatile-marker-7f8e2b not compacted"
        d.request("memory_turn", {"scope": s, "role": "user", "text": "durable fact one"})
        d.request("memory_turn", {"scope": s, "role": "user", "text": "durable fact two"})
        request_id = str(uuid.uuid4())
        compacted = d.request("memory_compact", {"scope": s, "requestID": request_id,
                                                 "expectedVectorGeneration": 0})["result"]
        self.assertEqual(compacted["processedWatermark"], 2)
        durable_next = d.request("memory_status", {"scope": s})["result"]["memory"]["nextWatermark"]
        self.assertEqual(durable_next, 3)
        d.request("memory_turn", {"scope": s, "role": "user", "text": volatile_marker})
        d.stop()
        # No raw conversation text is persisted anywhere: the volatile turn was
        # never compacted and the committed snapshot only holds fixture facts.
        for path in Path(self.temp.name).rglob("*"):
            if path.is_file():
                self.assertFalse(volatile_marker.encode() in path.read_bytes())
        d.start()
        status = d.request("memory_status", {"scope": s})["result"]
        self.assertEqual(status["pendingTurns"], 0, "volatile pending lost on restart")
        self.assertEqual(status["memory"]["revision"], 1)
        self.assertEqual(status["configured"], {"compaction": False, "embedding": False},
                         "providers must be reconfigured after restart")
        # Snapshot and vectors survive; query needs the provider reconfigured.
        unconfigured = d.request("memory_query", {"scope": s, "query": "durable fact"})["result"]
        self.assertEqual(unconfigured["status"], "unconfigured")
        d.request("memory_configure", {"kind": "embedding", "endpoint": self.remote.endpoint,
                                       "token": TOKEN, "model": MODEL})
        query = d.request("memory_query", {"scope": s, "query": "durable fact one"})["result"]
        self.assertEqual(query["status"], "ok")
        self.assertTrue(any("durable fact one" in r["text"] for r in query["results"]))
        # Watermark counter resumes from the durable snapshot.
        turned = d.request("memory_turn", {"scope": s, "role": "user",
                                           "text": "after restart"})["result"]
        self.assertEqual(turned["watermark"], durable_next)
        # A retried requestID from before the restart replays without providers.
        replay = d.request("memory_compact", {"scope": s, "requestID": request_id,
                                              "expectedVectorGeneration": 0})["result"]
        self.assertTrue(replay["replayed"])
        self.assertEqual(replay["revision"], 1)
        self.assert_token_not_persisted()

    def test_credential_hygiene_rejects_token_anywhere_in_params(self):
        d = self.start()
        d.request("memory_configure", {"kind": "compaction", "endpoint": self.remote.endpoint,
                                       "token": TOKEN})
        s = scope()
        for params in [
            {"scope": s, "role": "user", "text": "please remember " + TOKEN},
            {"scope": s, "role": "user", "text": "normal", "interrupted": True},
        ]:
            if TOKEN in params.get("text", ""):
                response = d.request("memory_turn", params)
                self.assertEqual(response["error"]["code"], "invalid_memory_turn")
        # Even a nested occurrence inside a typo'd unknown field is rejected.
        response = d.request("memory_turn", {"scope": s, "role": "user", "text": "x",
                                             "blob": {"leak": TOKEN}})
        self.assertEqual(response["error"]["code"], "invalid_memory_turn")
        self.assert_token_not_persisted()

    def test_late_superseded_compaction_cannot_overwrite(self):
        d = self.start()
        self.configure()
        s = scope()
        d.request("memory_turn", {"scope": s, "role": "user", "text": "race turn"})
        # First writer commits generation 1.
        first = d.request("memory_compact", {"scope": s,
                                             "requestID": str(uuid.uuid4()),
                                             "expectedVectorGeneration": 0})["result"]
        self.assertEqual(first["vectorGeneration"], 1)
        # A late second writer that observed generation 0 cannot land.
        late = d.request("memory_compact", {"scope": s,
                                            "requestID": str(uuid.uuid4()),
                                            "expectedVectorGeneration": 0})
        self.assertEqual(late["error"]["code"], "memory_conflict")
        read = d.request("memory_read", {"scope": s})["result"]["memory"]
        self.assertEqual(read["revision"], 1)
        texts = [f["text"] for f in read["sections"]["facts"]]
        self.assertEqual(texts.count("remembered:race turn"), 1,
                         "the late duplicate must not double-commit the same turns")


if __name__ == "__main__":
    unittest.main()

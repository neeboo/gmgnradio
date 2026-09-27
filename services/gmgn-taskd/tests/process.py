"""Offline contract tests: real taskd child, private temp roots, loopback HTTP only."""
import base64
import hashlib
import http.server
import json
import os
from pathlib import Path
import socket
import sqlite3
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid
import zlib

BIN = os.environ.get("TASKD_BIN", "/tmp/gmgn-taskd-target-rust-worker/debug/gmgn-taskd")
TOKEN = "offline-secret-do-not-persist"


def png(color=b"\xff\xff\xff\xff"):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(b"\0"+color)) + chunk(b"IEND", b"")


GLB = b"glTF" + struct.pack("<II", 2, 24) + struct.pack("<I", 4) + b"JSON" + b"{}  "


class Remote:
    def __init__(self):
        self.jobs = {}
        self.posts = 0
        self.active = 0
        self.max_active = 0
        self.lock = threading.Lock()
        self.release = threading.Event()
        self.download_started = threading.Event()
        self.download_release = threading.Event()
        self.mode = "ok"
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def reply(self, value, code=200):
                data = json.dumps(value).encode()
                if outer.mode == "escaped_secret":
                    data = data.replace(TOKEN.encode(), "".join("\\u%04x" % ord(c) for c in TOKEN).encode())
                self.send_response(code)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                try:
                    self.wfile.write(data)
                except (BrokenPipeError, ConnectionResetError):
                    pass

            def do_POST(self):
                assert self.headers.get("Authorization") == "Bearer " + TOKEN
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                if self.path.endswith("/cancel"):
                    rid = self.path.split("/")[-2]
                    for job in outer.jobs.values():
                        if job["id"] == rid:
                            job["state"] = "cancelled"
                            return self.reply(job)
                key = self.headers["Idempotency-Key"]
                with outer.lock:
                    outer.posts += 1
                    outer.active += 1
                    outer.max_active = max(outer.max_active, outer.active)
                    if key not in outer.jobs:
                        outer.jobs[key] = dict(id=uuid.uuid4().hex, state="running", reason=None, name=body["name"], source=body["source"], height_meters=body["height_meters"], result=None, compute_may_continue=False, created_at=1.0, updated_at=1.0)
                outer.release.wait(4)
                with outer.lock:
                    outer.active -= 1
                if outer.mode == "redirect":
                    self.send_response(302)
                    self.send_header("Location", "/leak")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                elif outer.mode == "bad_json":
                    self.reply({"token": TOKEN})
                elif outer.mode == "bad_id":
                    self.reply(dict(outer.jobs[key], id="../../unsafe"))
                elif outer.mode == "escaped_secret":
                    self.reply(dict(outer.jobs[key], debug=TOKEN))
                else:
                    self.reply(outer.jobs[key])

            def do_GET(self):
                assert self.headers.get("Authorization") == "Bearer " + TOKEN
                if self.path == "/leak":
                    raise AssertionError("redirect followed")
                rid = self.path.split("/")[3]
                job = next(x for x in outer.jobs.values() if x["id"] == rid)
                if self.path.endswith("model.glb"):
                    if outer.mode == "blocked_download":
                        outer.download_started.set()
                        outer.download_release.wait(6)
                    if outer.mode == "download_redirect":
                        self.send_response(302)
                        self.send_header("Location", "/leak")
                        self.send_header("Content-Length", "0")
                        self.end_headers()
                        return
                    data = GLB if outer.mode != "bad_glb" else b"x" * len(GLB)
                    self.send_response(200)
                    if outer.mode == "stream_oversized":
                        self.send_header("Transfer-Encoding", "chunked")
                        self.end_headers()
                        try:
                            for _ in range(33):
                                self.wfile.write(b"100000\r\n" + b"x" * (1024 * 1024) + b"\r\n")
                            self.wfile.write(b"0\r\n\r\n")
                        except (BrokenPipeError, ConnectionResetError):
                            pass
                        return
                    self.send_header("Content-Length", str(33 * 1024 * 1024 if outer.mode == "oversized" else len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                    return
                if outer.mode == "running":
                    return self.reply(job)
                if outer.mode == "status_oversized":
                    return self.reply({"huge": "x" * (1024 * 1024)})
                if outer.mode == "status_mismatch":
                    return self.reply(dict(job, id=uuid.uuid4().hex))
                if job["state"] != "cancelled":
                    job["state"] = "completed"
                    job["result"] = dict(model_url=f"/v1/jobs/{rid}/model.glb", source=job["source"], suggested_height_meters=0.5, scale_requires_confirmation=True, interaction_status="unbound", workflow_profile="test", affordance_candidates=["inspect"], interaction_bindings=[], inspection=dict(sha256="0" * 64 if outer.mode == "bad_hash" else hashlib.sha256(GLB).hexdigest(), bytes=len(GLB), triangles=0, primitives=0, materials=0, accessors=0, accessor_bounds={}, bounds=dict(min=[0,0,0], max=[1,1,1]), scale_calibrated=False, scene_transform_count=0))
                    if outer.mode == "unsafe_url":
                        job["result"]["model_url"] = "http://127.0.0.1:1/leak"
                self.reply(job)

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.endpoint = "http://127.0.0.1:" + str(self.server.server_port)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.release.set()
        self.download_release.set()
        self.server.shutdown()
        self.server.server_close()


class Daemon:
    def __init__(self, root):
        self.root = Path(root)
        self.path = str(self.root / "taskd.sock")
        self.start()

    def start(self, extra=()):
        self.p = subprocess.Popen([BIN, "--root", str(self.root), "--socket", self.path, "--concurrency", "2", *extra], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
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
        raise AssertionError("daemon did not expose its socket: " + self.p.communicate(timeout=2)[1].decode())

    def connect(self):
        s = socket.socket(socket.AF_UNIX)
        s.settimeout(8)
        try:
            s.connect(self.path)
        except Exception:
            s.close()
            raise
        return s

    def request(self, method, params={}):
        with self.connect() as s:
            s.sendall(json.dumps(dict(id="test", method=method, params=params)).encode() + b"\n")
            with s.makefile("rb") as stream:
                return json.loads(stream.readline())

    def submit(self, endpoint, identity=None, context=None):
        params = dict(id=identity or str(uuid.uuid4()), endpoint=endpoint, name="test prop", pngBase64=base64.b64encode(png()).decode(), source=dict(author="test", license="CC0"), heightMeters=.5)
        if context:
            params["context"] = context
        return self.request("submit", params)

    def stop(self):
        if self.p.poll() is None:
            self.p.kill()
        self.p.communicate(timeout=3)

    def wait_stage(self, identity, stages):
        end = time.monotonic() + 12
        while time.monotonic() < end:
            jobs = self.request("snapshot")["result"]["jobs"]
            job = next(j for j in jobs if j["id"].lower() == identity.lower())
            if job["backendStage"] in stages:
                return job
            time.sleep(.05)
        raise AssertionError("stage timeout: " + repr(job))


class ProcessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="taskd-", dir="/tmp")
        self.remote = Remote()
        self.daemon = None

    def tearDown(self):
        if self.daemon:
            self.daemon.stop()
        self.remote.close()
        self.temp.cleanup()

    def start(self):
        self.daemon = Daemon(self.temp.name)
        self.assertIn("result", self.daemon.request("configure", dict(endpoint=self.remote.endpoint, token=TOKEN)))
        return self.daemon

    def test_concurrency_disconnect_events_restart_and_idempotency(self):
        d = self.start()
        start = time.monotonic()
        first = d.submit(self.remote.endpoint)["result"]["job"]
        second = d.submit(self.remote.endpoint)["result"]["job"]
        self.assertLess(time.monotonic() - start, 1)
        sub = d.connect()
        sub.sendall(b'{"id":"s","method":"subscribe","params":{"after":0}}\n')
        stream = sub.makefile("rb")
        self.assertTrue(json.loads(stream.readline())["result"]["subscribed"])
        end = time.monotonic() + 3
        while self.remote.max_active < 2 and time.monotonic() < end:
            time.sleep(.02)
        self.assertEqual(self.remote.max_active, 2)
        self.remote.release.set()
        ready = set()
        sequence = 0
        while len(ready) < 2:
            event = json.loads(stream.readline())["event"]
            self.assertGreater(event["sequence"], sequence)
            sequence = event["sequence"]
            if event["job"]["backendStage"] == "ready":
                ready.add(event["job"]["id"])
        stream.close()
        sub.close()
        second_process = subprocess.run([BIN, "--root", self.temp.name, "--socket", d.path], capture_output=True, timeout=3)
        self.assertNotEqual(second_process.returncode, 0)
        self.assertEqual(len(d.request("snapshot")["result"]["jobs"]), 2)
        d.stop()
        d.start()
        replay = d.connect()
        replay.sendall(b'{"id":"s","method":"subscribe","params":{"after":0}}\n')
        with replay.makefile("rb") as rs:
            rs.readline()
            self.assertGreater(json.loads(rs.readline())["event"]["sequence"], 0)
        replay.close()
        self.assertIn("result", d.submit(self.remote.endpoint, first["id"]))
        self.assertEqual(self.remote.posts, 2)
        for path in Path(self.temp.name).rglob("*"):
            if path.is_file():
                self.assertFalse(TOKEN.encode() in path.read_bytes(), "credential persisted to " + path.name)
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_cancel_during_submission_is_durable(self):
        d = self.start()
        identity = d.submit(self.remote.endpoint)["result"]["job"]["id"]
        d.wait_stage(identity, {"submitting"})
        cancelled = d.request("cancel", {"id": identity})["result"]["job"]
        self.assertTrue(cancelled["cancelRequested"])
        self.assertNotEqual(cancelled["backendStage"], "cancelled")
        self.remote.release.set()
        self.assertEqual(d.wait_stage(identity, {"cancelled"})["receipt"]["state"], "cancelled")

    def test_restart_running_waits_for_credentials(self):
        self.remote.mode = "running"
        self.remote.release.set()
        d = self.start()
        identity = d.submit(self.remote.endpoint)["result"]["job"]["id"]
        d.wait_stage(identity, {"running"})
        d.stop()
        d.start()
        d.wait_stage(identity, {"awaiting_configuration"})
        d.request("configure", dict(endpoint=self.remote.endpoint, token=TOKEN))
        self.remote.mode = "ok"
        d.wait_stage(identity, {"ready"})
        self.assertEqual(self.remote.posts, 1)

    def test_invalid_models_never_ready(self):
        self.remote.release.set()
        d = self.start()
        for mode in ("bad_hash", "bad_glb", "oversized", "stream_oversized", "unsafe_url", "bad_json", "redirect", "download_redirect", "bad_id", "status_oversized", "status_mismatch"):
            self.remote.mode = mode
            identity = d.submit(self.remote.endpoint)["result"]["job"]["id"]
            job = d.wait_stage(identity, {"failed", "submission_uncertain", "interrupted"})
            self.assertFalse(job.get("localModelPath"), mode)

    def test_invalid_input_and_conflicting_identity(self):
        d = self.start()
        for endpoint in ("http://example.com", "https://user:pass@example.com", "https://example.com/path", "https://example.com?x=1"):
            self.assertIn("error", d.request("configure", dict(endpoint=endpoint, token=TOKEN)))
        identity = str(uuid.uuid4())
        self.assertIn("result", d.submit(self.remote.endpoint, identity))
        request = dict(id=identity, endpoint=self.remote.endpoint, name="different", pngBase64=base64.b64encode(png()).decode(), source=dict(author="test", license="CC0"), heightMeters=.5)
        self.assertEqual(d.request("submit", request)["error"]["code"], "idempotency_conflict")
        request["id"] = str(uuid.uuid4())
        request["pngBase64"] = base64.b64encode(b"bad png").decode()
        self.assertIn("error", d.request("submit", request))

    def test_uncertain_submission_needs_explicit_idempotent_retry(self):
        d = self.start()
        identity = d.submit(self.remote.endpoint)["result"]["job"]["id"]
        end = time.monotonic() + 3
        while not self.remote.jobs and time.monotonic() < end:
            time.sleep(.02)
        self.assertEqual(len(self.remote.jobs), 1)
        d.request("cancel", {"id":identity})
        d.stop()
        d.start()
        job = d.wait_stage(identity, {"submission_uncertain"})
        self.assertTrue(job["cancelRequested"])
        d.request("configure", dict(endpoint=self.remote.endpoint, token=TOKEN))
        time.sleep(.7)
        self.assertEqual(self.remote.posts, 1)
        self.remote.release.set()
        self.assertIn("result", d.request("retry", {"id":identity}))
        d.wait_stage(identity, {"cancelled"})
        self.assertEqual(self.remote.posts, 2)
        self.assertEqual(len(self.remote.jobs), 1)

    def test_local_cancel_and_symlink_input_rejection(self):
        self.daemon = Daemon(self.temp.name)
        d = self.daemon
        first = d.submit(self.remote.endpoint)["result"]["job"]
        self.assertEqual(d.request("cancel", {"id": first["id"]})["result"]["job"]["backendStage"], "cancelled")
        second = d.submit(self.remote.endpoint)["result"]["job"]
        path = Path(second["imagePath"])
        path.unlink()
        path.symlink_to(first["imagePath"])
        self.remote.release.set()
        d.request("configure", dict(endpoint=self.remote.endpoint, token=TOKEN))
        d.wait_stage(second["id"], {"submission_uncertain", "failed", "interrupted"})
        self.assertEqual(self.remote.posts, 0)

    def test_messages_replay_independent_consumers_and_scopes(self):
        d = self.start()
        context = dict(worldID="world-a", residentScope="resident-a")
        identity = d.submit(self.remote.endpoint, context=context)["result"]["job"]["id"]
        message = dict(id=str(uuid.uuid4()), taskId=identity, **context, kind="wish.outputReady", payload={"fact":"test renderer ready"})
        published = d.request("publish_message", message)["result"]["message"]
        self.assertEqual(d.request("publish_message", message)["result"]["message"], published)
        self.assertIn("error", d.request("publish_message", dict(message, payload={"fact":"different"})))

        def receive(consumer, until):
            s = d.connect()
            s.sendall(json.dumps(dict(id="subscription", method="subscribe_messages", params=dict(consumer=consumer, **context))).encode()+b"\n")
            found = []
            with s.makefile("rb") as stream:
                self.assertTrue(json.loads(stream.readline())["result"]["subscribed"])
                while True:
                    item = json.loads(stream.readline())["message"]
                    found.append(item)
                    if item["id"] == until:
                        break
            s.close()
            return found

        for consumer in ("ui", "world", "agent"):
            got = receive(consumer, published["id"])
            self.assertTrue(any(m["kind"] == "task.stateChanged" for m in got))
        self.assertIn("error", d.request("ack_message", dict(id=published["id"], consumer="agent", worldID="wrong", residentScope="resident-a")))
        self.assertTrue(d.request("ack_message", dict(id=published["id"], consumer="ui", **context))["result"]["acknowledged"])
        d.stop()
        d.start()
        self.assertTrue(any(m["id"] == published["id"] for m in receive("agent", published["id"])))
        later = dict(message, id=str(uuid.uuid4()), kind="wish.claimed")
        later_id = d.request("publish_message", later)["result"]["message"]["id"]
        self.assertFalse(any(m["id"] == published["id"] for m in receive("ui", later_id)))

    def test_legacy_import_is_read_only_and_no_receipt_is_not_resubmitted(self):
        d = self.start()
        d.stop()
        legacy = Path(self.temp.name) / "legacy"
        legacy.mkdir(mode=0o700)
        image = legacy / "old.png"
        image.write_bytes(png())
        identity = str(uuid.uuid4()).upper()
        record = dict(id=identity, name="legacy prop", endpoint=self.remote.endpoint, imagePath=str(image), imageSHA256=hashlib.sha256(png()).hexdigest(), heightMeters=.5, source=dict(author="test", license="CC0"), idempotencyKey=identity)
        tasks = legacy / "tasks.json"
        raw = json.dumps([record]).encode()
        tasks.write_bytes(raw)
        d.start(("--legacy-root", str(legacy)))
        self.assertEqual(d.wait_stage(identity, {"submission_uncertain"})["id"], identity)
        d.request("configure", dict(endpoint=self.remote.endpoint, token=TOKEN))
        time.sleep(.7)
        self.assertEqual(self.remote.posts, 0)
        d.stop()
        d.start(("--legacy-root", str(legacy)))
        self.assertEqual(len(d.request("snapshot")["result"]["jobs"]), 1)
        self.assertEqual(tasks.read_bytes(), raw)
        self.assertEqual(image.read_bytes(), png())

    def test_corrupt_legacy_fails_without_modifying_source(self):
        legacy = Path(self.temp.name) / "legacy"
        legacy.mkdir()
        tasks = legacy / "tasks.json"
        tasks.write_bytes(b"corrupt")
        p = subprocess.run([BIN, "--root", self.temp.name, "--socket", str(Path(self.temp.name)/"taskd.sock"), "--legacy-root", str(legacy)], capture_output=True, timeout=5)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn(b"legacy_unavailable", p.stderr)
        self.assertEqual(tasks.read_bytes(), b"corrupt")

    def test_remote_cannot_persist_json_escaped_credentials(self):
        self.remote.mode = "escaped_secret"
        self.remote.release.set()
        d = self.start()
        identity = d.submit(self.remote.endpoint)["result"]["job"]["id"]
        d.wait_stage(identity, {"ready", "submission_uncertain", "failed"})
        for path in Path(self.temp.name).rglob("*"):
            if path.is_file():
                self.assertFalse(TOKEN.encode() in path.read_bytes(), "credential persisted to " + path.name)

    def test_cancel_interrupted_observation_preserves_remote_control(self):
        self.remote.mode = "status_mismatch"
        self.remote.release.set()
        d = self.start()
        identity = d.submit(self.remote.endpoint)["result"]["job"]["id"]
        d.wait_stage(identity, {"interrupted"})
        self.remote.mode = "running"
        job = d.request("cancel", {"id":identity})["result"]["job"]
        self.assertTrue(job["cancelRequested"])
        self.assertEqual(d.wait_stage(identity, {"cancelled"})["receipt"]["state"], "cancelled")

    def test_requests_continue_on_an_event_subscription_connection(self):
        d = self.start()
        with d.connect() as connection:
            with connection.makefile("rb") as stream:
                connection.sendall(b'{"id":"subscribe","method":"subscribe","params":{"after":0}}\n')
                self.assertTrue(json.loads(stream.readline())["result"]["subscribed"])
                connection.sendall(b'{"id":"snapshot","method":"snapshot","params":{}}\n')
                line = stream.readline()
                self.assertTrue(line, "daemon closed multiplexed connection after subscribe")
                response = json.loads(line)
                self.assertEqual(response["id"], "snapshot")
                self.assertEqual(response["result"]["jobs"], [])

    def test_message_cannot_persist_a_token_with_json_escapes(self):
        d = self.start()
        identity = d.submit(self.remote.endpoint)["result"]["job"]["id"]
        secret = 'offline-token-"quote"-\\slash'
        self.assertIn("result", d.request("configure", dict(endpoint="https://offline.invalid", token=secret)))
        for payload in ({"detail":secret}, {secret:"value"}, {"nested":[{"detail":secret}]}):
            request = dict(id=str(uuid.uuid4()), taskId=identity, worldID="world-a", residentScope="resident-a", kind="wish.outputReady", payload=payload)
            self.assertEqual(d.request("publish_message", request).get("error", {}).get("code"), "invalid_message")

    def test_large_snapshot_pages_are_bounded_and_frozen_at_one_sequence(self):
        self.daemon = Daemon(self.temp.name)
        d = self.daemon
        identities = [d.submit(self.remote.endpoint)["result"]["job"]["id"] for _ in range(13)]
        d.stop()
        # Create valid historical receipts in the offline fixture while taskd is stopped.
        # No second writer runs alongside the daemon.
        with sqlite3.connect(Path(self.temp.name)/"tasks.sqlite3") as connection:
            for identity in identities:
                stored = json.loads(connection.execute("SELECT data FROM jobs WHERE id=?", (identity,)).fetchone()[0])
                job = stored["job"]
                job["receipt"] = dict(id=uuid.uuid4().hex, state="running", reason=None, name=job["name"], source=job["source"], height_meters=job["heightMeters"], compute_may_continue=False, created_at=1.0, updated_at=1.0, debug="x"*(1000*1024))
                job["backendStage"] = "running"
                stored["attempted"] = True
                connection.execute("UPDATE jobs SET data=? WHERE id=?", (json.dumps(stored), identity))
                connection.execute("INSERT INTO events(job) VALUES (?)", (json.dumps(job),))
        d.start()
        time.sleep(.4)

        def page(params):
            with d.connect() as socket_:
                socket_.sendall(json.dumps(dict(id="page", method="snapshot", params=params)).encode()+b"\n")
                with socket_.makefile("rb") as stream:
                    raw = stream.readline()
                self.assertLessEqual(len(raw), 2 * 1024 * 1024)
                return json.loads(raw)["result"]

        first = page({})
        self.assertTrue(first.get("nextCursor"))
        frozen_sequence = first["sequence"]
        target = first["jobs"][0]["id"]
        self.assertFalse(first["jobs"][0]["cancelRequested"])
        d.request("cancel", {"id":target})
        new_identity = d.submit(self.remote.endpoint)["result"]["job"]["id"]
        all_jobs = list(first["jobs"])
        cursor = first.get("nextCursor")
        while cursor:
            result = page({"cursor":cursor})
            self.assertEqual(result["sequence"], frozen_sequence)
            all_jobs.extend(result["jobs"])
            cursor = result.get("nextCursor")
        self.assertEqual({j["id"] for j in all_jobs}, set(identities))
        self.assertNotIn(new_identity, {j["id"] for j in all_jobs})
        self.assertFalse(next(j for j in all_jobs if j["id"] == target)["cancelRequested"])
        with d.connect() as connection:
            connection.sendall(json.dumps(dict(id="events", method="subscribe", params=dict(after=frozen_sequence))).encode()+b"\n")
            with connection.makefile("rb") as stream:
                stream.readline()
                while True:
                    event = json.loads(stream.readline())["event"]
                    if event["job"]["id"] == target and event["job"]["cancelRequested"]:
                        break
        self.assertIn("error", d.request("snapshot", {"cursor":"invalid"}))

    def test_tampered_png_cannot_be_retried_under_original_identity(self):
        self.remote.mode = "bad_json"
        self.remote.release.set()
        d = self.start()
        job = d.submit(self.remote.endpoint)["result"]["job"]
        d.wait_stage(job["id"], {"submission_uncertain"})
        Path(job["imagePath"]).write_bytes(png(b"\xff\0\0\xff"))
        self.remote.mode = "ok"
        self.assertIn("result", d.request("retry", {"id":job["id"]}))
        result = d.wait_stage(job["id"], {"submission_uncertain", "interrupted", "failed"})
        self.assertEqual(result["lastError"], "image_integrity_failed")
        self.assertEqual(self.remote.posts, 1)
        self.assertEqual(result["idempotencyKey"], job["idempotencyKey"])

    def test_credentials_are_bound_to_exact_origin(self):
        d = self.start()
        other = Remote()
        try:
            job = d.submit(other.endpoint)["result"]["job"]
            d.wait_stage(job["id"], {"awaiting_configuration"})
            self.assertEqual(other.posts, 0)
            self.assertEqual(self.remote.posts, 0)
            other.release.set()
            d.request("configure", dict(endpoint=other.endpoint, token=TOKEN))
            d.wait_stage(job["id"], {"ready"})
            self.assertEqual(other.posts, 1)
            self.assertEqual(self.remote.posts, 0)
        finally:
            other.close()

    def test_cancel_during_download_never_publishes_a_model(self):
        self.remote.mode = "blocked_download"
        self.remote.release.set()
        d = self.start()
        job = d.submit(self.remote.endpoint)["result"]["job"]
        self.assertTrue(self.remote.download_started.wait(5))
        cancelled = d.request("cancel", {"id":job["id"]})["result"]["job"]
        self.assertTrue(cancelled["cancelRequested"])
        self.remote.download_release.set()
        result = d.wait_stage(job["id"], {"cancelled", "interrupted"})
        self.assertTrue(result["cancelRequested"])
        self.assertFalse(result.get("localModelPath"))

    def test_request_id_is_a_bounded_string(self):
        d = self.start()
        for identity in (None, 42, {}, [], "", "i"*201, "界"*100, "i"*(12*1024*1024-100)):
            with d.connect() as connection:
                connection.sendall(json.dumps(dict(id=identity,method="snapshot",params={})).encode()+b"\n")
                with connection.makefile("rb") as stream:
                    raw = stream.readline()
                self.assertLess(len(raw), 1024)
                response = json.loads(raw)
                self.assertEqual(response.get("error", {}).get("code"), "invalid_request_id")
                self.assertIsNone(response["id"])


if __name__ == "__main__":
    unittest.main()

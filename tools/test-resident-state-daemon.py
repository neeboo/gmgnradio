"""Offline resident storage contract tests.

Exercises the real gmgn-taskd helper process over its HTTP endpoint: scope
isolation, CAS revisions, requestID idempotent replay across restarts, event
stream pagination, per-consumer message acks that survive restarts, whole
transaction rollback on failure, and upgrade compatibility of a pre-made v1
(tasks.sqlite3 without resident tables) database.

Only touches its own temporary directories, the taskd child process and the
local HTTP endpoint; it never starts the macOS app, never touches the keychain,
production services or business databases.
"""
import json
import sys
sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parents[1] / "services/gmgn-taskd/tests"))
from http_transport import Connection
import os
from pathlib import Path
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


class Daemon:
    def __init__(self, root):
        self.root = Path(root).resolve()
        self.path = str(self.root / "taskd.endpoint.json")
        self.start()

    def start(self, extra=()):
        self.p = subprocess.Popen(
            [BIN, "--root", str(self.root), "--endpoint-file", self.path, "--concurrency", "2", *extra],
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
        raise AssertionError("daemon did not expose its HTTP endpoint: " + self.p.communicate(timeout=2)[1].decode())

    def connect(self):
        connection = Connection(self.path)
        self.auth = connection.auth
        return connection

    def request(self, method, params=None, request_id="test"):
        params = {} if params is None else params
        with self.connect() as s:
            s.sendall(json.dumps(dict(auth=self.auth, id=request_id, method=method, params=params)).encode() + b"\n")
            with s.makefile("rb") as stream:
                return json.loads(stream.readline())

    def stop(self):
        if self.p.poll() is None:
            self.p.kill()
        self.p.communicate(timeout=3)

    def subscribe(self, method, params):
        s = self.connect()
        s.sendall(json.dumps(dict(auth=self.auth, id="sub", method=method, params=params)).encode() + b"\n")
        return s, s.makefile("rb")


def scope(world="world-a", resident="resident-a"):
    return {"worldID": world, "residentScope": resident}


def item(seed=None, kind="wish.placed", payload=None):
    return {
        "id": seed or str(uuid.uuid4()),
        "kind": kind,
        "payload": payload if payload is not None else {"index": 0},
    }


class ResidentStateTests(unittest.TestCase):
    def setUp(self):
        if not os.path.exists(BIN):
            self.skipTest("gmgn-taskd binary not found; set TASKD_BIN (cargo build first)")
        self.temp = tempfile.TemporaryDirectory(prefix="taskd-resident-", dir="/tmp")
        self.daemon = None

    def tearDown(self):
        if self.daemon:
            self.daemon.stop()
        self.temp.cleanup()

    def start(self):
        self.daemon = Daemon(self.temp.name)
        return self.daemon

    def commit(self, d, domain="resident", key="mood", value=None, expected=0,
               request_id=None, events=None, messages=None, world="world-a",
               resident="resident-a"):
        params = {
            "scope": scope(world, resident),
            "domain": domain,
            "key": key,
            "expectedRevision": expected,
            "requestID": request_id or str(uuid.uuid4()),
            "value": {"state": "content"} if value is None else value,
        }
        if events is not None:
            params["events"] = events
        if messages is not None:
            params["messages"] = messages
        return d.request("state_commit", params)

    def read(self, d, key="mood", domain="resident", world="world-a", resident="resident-a"):
        return d.request("state_read", {
            "scope": scope(world, resident), "domain": domain, "key": key})["result"]["record"]

    def test_cas_revision_and_request_id_idempotency(self):
        d = self.start()
        self.assertIsNone(self.read(d))
        created = self.commit(d, value={"state": "content"})
        self.assertEqual(created["result"], {"revision": 1, "replayed": False})
        record = self.read(d)
        self.assertEqual(record, {"revision": 1, "value": {"state": "content"}})

        # A new request that tries to create over revision 1 is rejected.
        self.assertEqual(
            self.commit(d, expected=0, request_id=str(uuid.uuid4()))["error"]["code"],
            "revision_conflict")
        # A stale expected revision (2 vs current 1) is rejected.
        stale = self.commit(d, value={"state": "ready"}, expected=2,
                            request_id=str(uuid.uuid4()))
        self.assertEqual(stale["error"]["code"], "revision_conflict")
        # Correct CAS advances the revision.
        updated = self.commit(d, value={"state": "ready"}, expected=1,
                              request_id=str(uuid.uuid4()))
        self.assertEqual(updated["result"], {"revision": 2, "replayed": False})
        # Revision counts successful commits: the same value with a fresh
        # requestID still advances the revision to 3.
        same = self.commit(d, value={"state": "ready"}, expected=2,
                           request_id=str(uuid.uuid4()))
        self.assertEqual(same["result"], {"revision": 3, "replayed": False})

        # requestID replay: identical content returns the recorded revision,
        # and a UUID requestID replays regardless of client casing.
        request_id = str(uuid.uuid4())
        first = self.commit(d, value={"state": "ready"}, expected=3, request_id=request_id,
                            events=[item(seed="11111111-1111-4111-8111-111111111111")])
        self.assertEqual(first["result"]["revision"], 4)
        replay = self.commit(d, value={"state": "ready"}, expected=4,
                             request_id=request_id.upper(),
                             events=[item(seed="11111111-1111-4111-8111-111111111111")])
        self.assertEqual(replay["result"], {"revision": 4, "replayed": True})
        events = d.request("event_read", {"scope": scope()})["result"]["events"]
        self.assertEqual(len(events), 1, "replay must not append the event twice")
        # Same requestID but different content conflicts.
        conflict = self.commit(d, value={"state": "different"}, expected=3,
                               request_id=request_id)
        self.assertEqual(conflict["error"]["code"], "request_id_conflict")

    def test_idempotent_replay_survives_a_restart(self):
        d = self.start()
        request_id = str(uuid.uuid4())
        events = [item(seed="22222222-2222-4222-8222-222222222222", kind="wish.claimed")]
        first = self.commit(d, request_id=request_id, events=events)
        self.assertEqual(first["result"], {"revision": 1, "replayed": False})
        d.stop()
        d.start()
        # After restart the same request replays its recorded revision.
        replay = self.commit(d, request_id=request_id, events=events)
        self.assertEqual(replay["result"], {"revision": 1, "replayed": True})
        events_after = d.request("event_read", {"scope": scope()})["result"]["events"]
        self.assertEqual(len(events_after), 1)
        # The state itself survived too.
        self.assertEqual(self.read(d)["value"], {"state": "content"})

    def test_events_messages_pagination_and_ack_recovery_across_restart(self):
        d = self.start()
        first = self.commit(
            d, events=[
                item(seed="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", kind="wish.placed",
                     payload={"at": 1}),
                item(seed="bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", kind="wish.placed",
                     payload={"at": 2}),
            ],
            messages=[item(seed="cccccccc-cccc-4ccc-8ccc-cccccccccccc",
                           kind="wish.outputReady", payload={"path": "model.glb"})])
        self.assertEqual(first["result"]["revision"], 1)

        # event_read paginates in order; nextCursor is always the integer
        # watermark: the last returned sequence, or the requested after on an
        # empty page. It is the polling high-water mark, not a has-more flag.
        page = d.request("event_read", {"scope": scope(), "limit": 1})
        events = page["result"]["events"]
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["kind"], "wish.placed")
        self.assertEqual(events[0]["payload"], {"at": 1})
        self.assertIsInstance(page["result"]["nextCursor"], int)
        self.assertEqual(page["result"]["nextCursor"], events[0]["sequence"])
        page = d.request("event_read", {
            "scope": scope(), "after": page["result"]["nextCursor"]})
        self.assertEqual(len(page["result"]["events"]), 1)
        self.assertEqual(page["result"]["events"][0]["payload"], {"at": 2})
        self.assertEqual(page["result"]["nextCursor"],
                         page["result"]["events"][0]["sequence"])
        tail = d.request("event_read", {
            "scope": scope(), "after": page["result"]["nextCursor"]})
        self.assertEqual(len(tail["result"]["events"]), 0)
        self.assertEqual(tail["result"]["nextCursor"],
                         page["result"]["nextCursor"],
                         "an empty page returns the caller's watermark")
        # after is accepted as a resume boundary on its own, and nextCursor
        # mirrors the page tail when rows matched.
        resumed = d.request("event_read", {
            "scope": scope(), "after": events[0]["sequence"]})
        self.assertEqual(len(resumed["result"]["events"]), 1)
        self.assertEqual(resumed["result"]["nextCursor"],
                         resumed["result"]["events"][0]["sequence"])

        # Every consumer sees the unacked message once.
        for consumer in ("world", "ui", "agent"):
            result = d.request("message_read", {
                "scope": scope(), "consumer": consumer})
            messages = result["result"]["messages"]
            self.assertEqual(len(messages), 1)
            self.assertEqual(messages[0]["id"], "cccccccc-cccc-4ccc-8ccc-cccccccccccc")
            self.assertIsInstance(result["result"]["nextCursor"], int)
            self.assertEqual(result["result"]["nextCursor"], messages[0]["sequence"])
        ack = d.request("message_ack", {
            "scope": scope(), "consumer": "ui",
            "id": "cccccccc-cccc-4ccc-8ccc-cccccccccccc"})
        self.assertEqual(ack["result"], {"acknowledged": True})
        # Ack is idempotent and only clears that one consumer.
        self.assertEqual(
            d.request("message_ack", {
                "scope": scope(), "consumer": "ui",
                "id": "cccccccc-cccc-4ccc-8ccc-cccccccccccc"})["result"],
            {"acknowledged": True})
        drained = d.request("message_read", {
            "scope": scope(), "consumer": "ui"})
        self.assertEqual(len(drained["result"]["messages"]), 0)
        self.assertEqual(drained["result"]["nextCursor"], 0,
                         "no data: nextCursor mirrors the requested after (0)")
        self.assertEqual(
            len(d.request("message_read", {
                "scope": scope(), "consumer": "agent"})["result"]["messages"]), 1)
        # Wrong scope or unknown message cannot be acked.
        self.assertEqual(
            d.request("message_ack", {
                "scope": scope(world="world-other"), "consumer": "agent",
                "id": "cccccccc-cccc-4ccc-8ccc-cccccccccccc"})["error"]["code"],
            "message_not_found")
        self.assertEqual(
            d.request("message_ack", {
                "scope": scope(), "consumer": "admin",
                "id": "cccccccc-cccc-4ccc-8ccc-cccccccccccc"})["error"]["code"],
            "invalid_consumer")

        d.stop()
        d.start()
        # Acks and state survive the restart; pending messages do not resend to ui.
        self.assertEqual(
            len(d.request("message_read", {
                "scope": scope(), "consumer": "ui"})["result"]["messages"]), 0)
        self.assertEqual(
            len(d.request("message_read", {
                "scope": scope(), "consumer": "agent"})["result"]["messages"]), 1)
        self.assertEqual(
            len(d.request("event_read", {"scope": scope()})["result"]["events"]), 2)
        # New message after restart is delivered to ui too.
        self.commit(d, expected=1,
                    messages=[item(seed="dddddddd-dddd-4ddd-8ddd-dddddddddddd",
                                   kind="wish.claimed", payload={"prop": "chair"})])
        later = d.request("message_read", {
            "scope": scope(), "consumer": "ui"})["result"]["messages"]
        self.assertEqual(len(later), 1)
        self.assertEqual(later[0]["id"], "dddddddd-dddd-4ddd-8ddd-dddddddddddd")

    def test_failed_commit_rolls_back_everything_over_http(self):
        d = self.start()
        self.commit(d, events=[item(seed="eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")],
                    value={"state": "first"})
        # A second commit repeats the first event id with different content
        # while also carrying a new event: it must fail and roll back both.
        request_id = str(uuid.uuid4())
        bad = self.commit(
            d, value={"state": "must not land"}, expected=1, request_id=request_id,
            events=[
                item(seed="ffffffff-ffff-4fff-8fff-ffffffffffff"),
                item(seed="eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", payload={"changed": True}),
            ])
        self.assertEqual(bad["error"]["code"], "event_id_conflict")
        record = self.read(d)
        self.assertEqual(record, {"revision": 1, "value": {"state": "first"}})
        events = d.request("event_read", {"scope": scope()})["result"]["events"]
        self.assertEqual(len(events), 1, "new event from the failed commit must not land")
        # The failed requestID was not recorded: a corrected retry reusing the
        # same requestID commits fresh (replayed=false).
        fixed = self.commit(
            d, value={"state": "landed"}, expected=1, request_id=request_id,
            events=[item(seed="ffffffff-ffff-4fff-8fff-ffffffffffff")])
        self.assertEqual(fixed["result"], {"revision": 2, "replayed": False})
        self.assertEqual(self.read(d), {"revision": 2, "value": {"state": "landed"}})

    def test_scopes_are_isolated_and_ids_may_repeat_across_scopes(self):
        d = self.start()
        self.commit(d, world="world-a", resident="resident-a",
                    events=[item(seed="55555555-5555-4555-8555-555555555555")])
        self.commit(d, world="world-a", resident="resident-b",
                    events=[item(seed="55555555-5555-4555-8555-555555555555",
                                 payload={"other": True})])
        # Same event id with different content is fine in another scope.
        self.assertEqual(
            len(d.request("event_read", {"scope": scope()})["result"]["events"]), 1)
        self.assertEqual(
            len(d.request("event_read", {
                "scope": scope(world="world-a", resident="resident-b")})["result"]["events"]), 1)
        self.assertIsNotNone(self.read(d))
        self.assertIsNotNone(self.read(d, resident="resident-b"))
        self.assertIsNone(self.read(d, world="world-z"))
        self.assertEqual(
            d.request("event_read", {
                "scope": scope(world="world-z")})["result"]["events"], [])
        # Acknowledging in the wrong resident scope cannot see the message.
        self.commit(d, world="world-a", resident="resident-a", expected=1,
                    messages=[item(seed="66666666-6666-4666-8666-666666666666")])
        self.assertEqual(
            d.request("message_ack", {
                "scope": scope(world="world-a", resident="resident-b"),
                "consumer": "agent",
                "id": "66666666-6666-4666-8666-666666666666"})["error"]["code"],
            "message_not_found")
        self.assertEqual(
            d.request("message_ack", {
                "scope": scope(world="world-a", resident="resident-a"),
                "consumer": "agent",
                "id": "66666666-6666-4666-8666-666666666666"})["result"],
            {"acknowledged": True})

    def test_limits_validation_and_credential_scanning(self):
        d = self.start()
        self.assertEqual(
            d.request("event_read", {"scope": scope(), "limit": 501})["error"]["code"],
            "limit_exceeded")
        self.assertEqual(
            d.request("event_read", {"scope": scope(), "after": -1})["error"]["code"],
            "invalid_cursor")
        self.assertEqual(
            d.request("message_read", {
                "scope": scope(), "consumer": "bot"})["error"]["code"],
            "invalid_consumer")
        self.assertEqual(
            d.request("state_read", {
                "scope": scope(), "domain": "pod", "key": "mood"})["error"]["code"],
            "invalid_domain")
        self.assertEqual(
            self.commit(d, value=["not", "an", "object"])["error"]["code"],
            "invalid_state_value")
        created = self.commit(d, domain="resident")
        self.assertEqual(created["result"]["revision"], 1)
        # A commit whose payload carries a configured credential is rejected.
        d.request("configure", dict(endpoint="https://offline.invalid", token="top-secret"))
        leaked = self.commit(d, world="world-c", value={"secret": "top-secret"})
        self.assertEqual(leaked["error"]["code"], "invalid_state_commit")
        # The rejected world never received the state.
        self.assertIsNone(self.read(d, world="world-c"))

    def test_missing_and_malformed_scopes_fail_loudly(self):
        d = self.start()
        for method, params in [
            ("state_read", {"scope": {"worldID": "", "residentScope": "x"}, "domain": "resident",
                            "key": "k"}),
            ("state_commit", {"domain": "resident", "key": "k", "expectedRevision": 0,
                              "requestID": str(uuid.uuid4()), "value": {}}),
            ("event_read", {"scope": scope(), "bogus": 1}),
            ("event_read", {"scope": scope(), "cursor": "removed-protocol-field"}),
            ("message_read", {"scope": scope(), "consumer": "agent",
                              "cursor": "removed-protocol-field"}),
        ]:
            response = d.request(method, params)
            self.assertIn("error", response, method)
        self.assertEqual(
            d.request("state_commit", {
                "scope": scope(), "domain": "resident", "key": "k",
                "expectedRevision": -1, "requestID": str(uuid.uuid4()), "value": {}})
            ["error"]["code"],
            "invalid_revision")

    def test_concurrent_commits_with_same_expected_only_one_succeeds(self):
        d = self.start()
        self.commit(d, value={"state": "content"})
        # Two writers observed revision 1 and race with the SAME value but
        # different facts. The single-writer daemon serializes them and the
        # winner advances the revision, so the loser's CAS must fail: CAS stays
        # effective even when both sides write an identical value.
        barrier = threading.Barrier(2)
        outcomes = [None, None]

        def race(index, seed):
            barrier.wait()
            outcomes[index] = self.commit(
                d, value={"state": "content"}, expected=1,
                request_id=str(uuid.uuid4()),
                events=[item(seed=seed, kind="wish.placed",
                             payload={"racer": seed})])

        threads = [
            threading.Thread(target=race, args=(
                0, "99999999-9999-4999-8999-999999999991")),
            threading.Thread(target=race, args=(
                1, "99999999-9999-4999-8999-999999999992")),
        ]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        winners = [r for r in outcomes if "result" in r]
        conflicts = [r for r in outcomes if "error" in r]
        self.assertEqual(len(winners), 1, "only one racer may commit")
        self.assertEqual(len(conflicts), 1)
        self.assertEqual(winners[0]["result"], {"revision": 2, "replayed": False})
        self.assertEqual(conflicts[0]["error"]["code"], "revision_conflict")
        events = d.request("event_read", {"scope": scope()})["result"]["events"]
        self.assertEqual(len(events), 1, "the loser's fact must roll back")
        self.assertEqual(self.read(d), {"revision": 2, "value": {"state": "content"}})


V1_DDL = """
CREATE TABLE jobs(id TEXT PRIMARY KEY, data TEXT NOT NULL);
CREATE TABLE events(sequence INTEGER PRIMARY KEY AUTOINCREMENT, job TEXT NOT NULL);
CREATE TABLE migrations(path TEXT PRIMARY KEY);
CREATE TABLE messages(
  sequence INTEGER PRIMARY KEY AUTOINCREMENT,
  id TEXT NOT NULL UNIQUE,
  task_id TEXT NOT NULL REFERENCES jobs(id),
  world_id TEXT NOT NULL,
  resident_scope TEXT NOT NULL,
  kind TEXT NOT NULL,
  payload TEXT NOT NULL);
CREATE TABLE message_acks(
  message_id TEXT NOT NULL REFERENCES messages(id),
  consumer TEXT NOT NULL CHECK (consumer IN ('world','ui','agent')),
  PRIMARY KEY(message_id, consumer));
"""


class UpgradeCompatibilityTests(unittest.TestCase):
    """A database built exactly like the pre-resident v1 binary must open
    read-only-compatible: legacy rows stay, old message contract works, and
    the resident tables are added by the schema migration."""

    def setUp(self):
        if not os.path.exists(BIN):
            self.skipTest("gmgn-taskd binary not found; set TASKD_BIN (cargo build first)")
        self.temp = tempfile.TemporaryDirectory(prefix="taskd-upgrade-", dir="/tmp")
        root = Path(self.temp.name)
        identity = "91B2F6C2-96EE-4D4B-8593-7E9EBFC18263"
        self.identity = identity
        message_id = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        job = {
            "id": identity, "name": "legacy prop", "endpoint": "http://127.0.0.1:1",
            "imagePath": "/unused/legacy.png", "imageSHA256": "0" * 64,
            "heightMeters": 0.5, "source": {"author": "test", "license": "CC0"},
            "idempotencyKey": identity, "backendStage": "queued", "cancelRequested": False,
        }
        with sqlite3.connect(root / "tasks.sqlite3") as connection:
            connection.executescript(V1_DDL)
            connection.execute(
                "INSERT INTO jobs(id,data) VALUES(?,?)",
                (identity, json.dumps({"job": job, "attempted": False})))
            connection.execute("INSERT INTO events(job) VALUES(?)", (json.dumps(job),))
            connection.execute(
                "INSERT INTO messages(id,task_id,world_id,resident_scope,kind,payload) "
                "VALUES(?,?,?,?,?,?)",
                (message_id, identity, "world-a", "resident-a", "wish.outputReady",
                 json.dumps({"path": "model.glb"})))
            connection.execute(
                "INSERT INTO message_acks(message_id,consumer) VALUES(?,'ui')", (message_id,))
        self.message_id = message_id
        self.daemon = Daemon(str(root))

    def tearDown(self):
        self.daemon.stop()
        self.temp.cleanup()

    def test_v1_database_upgrades_and_keeps_old_contract(self):
        d = self.daemon
        jobs = d.request("snapshot")["result"]["jobs"]
        self.assertEqual([j["id"] for j in jobs], [self.identity])
        # Old event subscription still replays the stored event.
        socket_, stream = d.subscribe("subscribe", {"after": 0})
        try:
            self.assertTrue(json.loads(stream.readline())["result"]["subscribed"])
            seen = None
            end = time.monotonic() + 3
            while time.monotonic() < end and seen is None:
                envelope = json.loads(stream.readline())
                if "event" in envelope and envelope["event"]["job"]["id"] == self.identity:
                    seen = envelope["event"]
            self.assertIsNotNone(seen)
        finally:
            stream.close()
            socket_.close()
        # Old message inbox for agent replays the stored unacked message.
        socket_, stream = d.subscribe("subscribe_messages", {
            "consumer": "agent", "worldID": "world-a", "residentScope": "resident-a"})
        try:
            self.assertTrue(json.loads(stream.readline())["result"]["subscribed"])
            found = None
            end = time.monotonic() + 3
            while time.monotonic() < end and found is None:
                envelope = json.loads(stream.readline())
                if envelope.get("message", {}).get("id", "").lower() == self.message_id:
                    found = envelope["message"]
            self.assertIsNotNone(found)
            self.assertEqual(found["kind"], "wish.outputReady")
        finally:
            stream.close()
            socket_.close()
        # The old ui ack is respected on the migrated database.
        socket_, stream = d.subscribe("subscribe_messages", {
            "consumer": "ui", "worldID": "world-a", "residentScope": "resident-a"})
        try:
            self.assertTrue(json.loads(stream.readline())["result"]["subscribed"])
            socket_.settimeout(.5)
            try:
                stream.readline()
                raise AssertionError("ui must not receive an already-acked v1 message")
            except (TimeoutError, socket.timeout):
                pass
        finally:
            stream.close()
            socket_.close()
        # Resident storage is live on the same migrated database.
        commit = d.request("state_commit", {
            "scope": scope(), "domain": "resident", "key": "mood", "expectedRevision": 0,
            "requestID": str(uuid.uuid4()), "value": {"state": "migrated"},
            "events": [item(seed="77777777-7777-4777-8777-777777777777")]})
        self.assertEqual(commit["result"], {"revision": 1, "replayed": False})
        events = d.request("event_read", {"scope": scope()})["result"]["events"]
        self.assertEqual(len(events), 1)
        d.stop()
        # The migration recorded itself and the resident rows are persistent.
        with sqlite3.connect(Path(self.temp.name) / "tasks.sqlite3") as connection:
            version = connection.execute(
                "SELECT COALESCE(MAX(version),0) FROM schema_migrations").fetchone()[0]
            # Resident, memory, world and music migrations preserve v1 data.
            self.assertEqual(version, 5)
            states = connection.execute("SELECT COUNT(*) FROM resident_states").fetchone()[0]
            self.assertEqual(states, 1)


if __name__ == "__main__":
    unittest.main()

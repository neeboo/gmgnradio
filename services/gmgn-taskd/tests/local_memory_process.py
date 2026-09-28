"""Offline process tests for the local VoiceMem memory IPC.

Drives the real gmgn-taskd child over its Unix socket with **no provider at
all**: the external compaction/embedding service layer has been removed, so
this suite proves the local paths still work end to end — volatile turn
buffers, delivered-pair ingest with in-memory idempotency, scope isolation,
status/read/pending, and the honest "semantic retrieval unavailable" answers
of memory_query/memory_recall.

Private temp roots and local Unix sockets only: never starts the macOS app,
never touches the keychain, never opens a network fixture.
"""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

DEFAULT_BIN = Path(__file__).resolve().parents[1] / "target" / "debug" / "gmgn-taskd"
BIN = os.environ.get("TASKD_BIN", str(DEFAULT_BIN))
WORLD = "world-a"
RESIDENT = "resident-a"
# 语义检索不可用时 recall context 的固定声明前缀。
UNAVAILABLE_MARKER = "语义记忆检索当前不可用"


def scope(world=WORLD, resident=RESIDENT):
    return {"worldID": world, "residentScope": resident}


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


class LocalMemoryProcessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="taskd-local-memory-", dir="/tmp")
        self.daemon = None

    def tearDown(self):
        if self.daemon:
            self.daemon.stop()
        self.temp.cleanup()

    def start(self):
        self.daemon = Daemon(self.temp.name)
        return self.daemon

    def ingest(self, user="真实转写", reply="确已交付的答复", request_id=None,
               source="voice", world=WORLD, resident=RESIDENT):
        return self.daemon.request("memory_ingest", {
            "scope": scope(world, resident), "requestID": request_id or str(uuid.uuid4()),
            "userText": user, "agentReply": reply, "source": source,
            "observedAt": "2026-09-08T11:00:00+08:00"})

    def status(self, world=WORLD, resident=RESIDENT):
        return self.daemon.request("memory_status", {"scope": scope(world, resident)})["result"]

    def pending(self, world=WORLD, resident=RESIDENT):
        return self.daemon.request("memory_pending", {"scope": scope(world, resident)})["result"]["turns"]

    def test_status_and_ingest_report_local_fields_only(self):
        d = self.start()
        # status 只有本地字段：没有 provider 配置、没有压缩编排状态。
        status = self.status()
        self.assertEqual(status, {"memory": None, "pendingTurns": 0})
        self.assertNotIn("configured", status)
        self.assertNotIn("orchestration", status)

        request_id = str(uuid.uuid4())
        marker = "raw-volatile-" + uuid.uuid4().hex
        accepted = self.ingest(marker, request_id=request_id)
        # ingest 只承诺"进易失缓冲"，不再有 consolidation 字段冒充落库状态。
        self.assertEqual(accepted["result"],
                         {"accepted": True, "replayed": False, "pendingTurns": 2})

        replay = self.ingest(marker, request_id=request_id)
        self.assertTrue(replay["result"]["replayed"])
        self.assertEqual(replay["result"]["pendingTurns"], 2)
        conflict = self.ingest("不同的文本", request_id=request_id)
        self.assertEqual(conflict["error"]["code"], "memory_request_conflict")
        half = self.ingest("would-be-half", reply="", request_id=str(uuid.uuid4()))
        self.assertEqual(half["error"]["code"], "invalid_turn_text")

        turns = self.pending()
        self.assertEqual(len(turns), 2, "被拒的投递不留痕")
        self.assertLess(turns[0]["watermark"], turns[1]["watermark"])
        self.assertEqual(turns[0]["role"], "user")
        self.assertEqual(turns[1]["role"], "agent")
        self.assertEqual(turns[0]["text"], marker)
        self.assertEqual(self.status()["pendingTurns"], 2)

        # 原始对话文本绝不落盘：整个私有 root 里搜不到 marker。
        d.stop()
        for path in Path(self.temp.name).rglob("*"):
            if path.is_file():
                self.assertNotIn(marker.encode(), path.read_bytes(),
                                 "raw ingest text leaked to " + path.name)
        # 重启丢掉易失缓冲与易失幂等，只有持久层留下。
        d.start()
        self.assertEqual(self.pending(), [])
        self.assertEqual(self.status(), {"memory": None, "pendingTurns": 0})

    def test_turn_pending_and_read_round_trip(self):
        d = self.start()
        read = d.request("memory_read", {"scope": scope()})["result"]
        self.assertIn("memory", read)
        self.assertIsNone(read["memory"], "没有提交过快照就是显式 null，不是空记忆")

        first = d.request("memory_turn", {"scope": scope(), "role": "user", "text": "本地回合一"})
        self.assertEqual(first["result"]["watermark"], 1)
        self.assertEqual(first["result"]["pendingTurns"], 1)
        second = d.request("memory_turn", {"scope": scope(), "role": "agent", "text": "本地回合二",
                                           "interrupted": False})
        self.assertEqual(second["result"]["watermark"], 2)

        turns = self.pending()
        self.assertEqual([turn["text"] for turn in turns], ["本地回合一", "本地回合二"])
        self.assertEqual([turn["role"] for turn in turns], ["user", "agent"])

        for params, code in [
            ({"scope": scope(), "role": "system", "text": "x"}, "invalid_role"),
            ({"scope": scope(), "role": "user", "text": "   "}, "invalid_turn_text"),
            ({"scope": scope(), "role": "user", "text": "x" * 2001}, "turn_text_too_large"),
            ({"scope": scope("", RESIDENT), "role": "user", "text": "x"}, "invalid_scope"),
        ]:
            self.assertEqual(d.request("memory_turn", params)["error"]["code"], code)

    def test_recall_and_query_report_semantics_unavailable(self):
        d = self.start()
        query = d.request("memory_query", {"scope": scope(), "query": "任何话题", "topK": 8})
        self.assertEqual(query["result"], {"status": "unconfigured", "results": []})
        self.assertEqual(
            d.request("memory_query", {"scope": scope(), "query": "   "})["error"]["code"],
            "invalid_query")
        self.assertEqual(
            d.request("memory_query", {"scope": scope(), "query": "q", "topK": 21})["error"]["code"],
            "invalid_topk")

        recall = d.request("memory_recall", {"scope": scope(), "query": "任何话题",
                                             "freshSession": False})["result"]
        self.assertEqual(recall["status"], "unconfigured")
        self.assertEqual(recall["facts"], [])
        self.assertEqual(recall["notes"], [])
        self.assertEqual(recall["revision"], 0)
        self.assertEqual(recall["vectorGeneration"], 0)
        self.assertIn(UNAVAILABLE_MARKER, recall["context"])
        self.assertNotIn("新会话恢复", recall["context"])

        # 全新会话仍然恢复本地可确认的易失回合（这不是检索命中）。
        self.ingest("还没入库的用户话", "还没入库的答复")
        fresh = d.request("memory_recall", {"scope": scope(), "query": "任何话题",
                                            "freshSession": True,
                                            "factLimit": 6, "noteLimit": 4})["result"]
        self.assertEqual(fresh["status"], "unconfigured")
        self.assertEqual(fresh["pendingTurns"], 2)
        self.assertIn("新会话恢复", fresh["context"])
        self.assertIn("还没入库的用户话", fresh["context"])
        self.assertIn(UNAVAILABLE_MARKER, fresh["context"])
        self.assertLessEqual(len(fresh["context"]), 8000)

        for params, code in [
            ({"scope": scope(), "query": "   "}, "invalid_query"),
            ({"scope": scope(), "query": "x" * 501}, "invalid_query"),
            ({"scope": scope(), "query": "q", "factLimit": 13}, "invalid_topk"),
            ({"scope": scope(), "query": "q", "noteLimit": 9}, "invalid_topk"),
        ]:
            self.assertEqual(d.request("memory_recall", params)["error"]["code"], code)

    def test_scope_isolation_between_worlds_and_residents(self):
        d = self.start()
        d.request("memory_turn", {"scope": scope(WORLD, RESIDENT), "role": "user", "text": "只在 A"})
        d.request("memory_turn", {"scope": scope(WORLD, "resident-b"), "role": "user", "text": "只在 B"})
        d.request("memory_turn", {"scope": scope("world-b", RESIDENT), "role": "user", "text": "只在另一个世界"})
        self.assertEqual([turn["text"] for turn in self.pending()], ["只在 A"])
        self.assertEqual([turn["text"] for turn in self.pending(WORLD, "resident-b")], ["只在 B"])
        self.assertEqual([turn["text"] for turn in self.pending("world-b", RESIDENT)], ["只在另一个世界"])
        other = d.request("memory_recall", {"scope": scope(WORLD, "resident-b"), "query": "任何话题",
                                            "freshSession": True})["result"]
        self.assertEqual(other["revision"], 0)
        self.assertNotIn("只在 A", other["context"])


if __name__ == "__main__":
    if not Path(BIN).is_file():
        print("gmgn-taskd binary not found at " + BIN +
              " (build it or set TASKD_BIN)", file=sys.stderr)
        sys.exit(2)
    unittest.main()

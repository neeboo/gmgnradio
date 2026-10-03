"""Offline process tests for the local VoiceMem memory IPC.

Drives the real gmgn-taskd child over authenticated loopback TCP with **no provider at
all**: the external compaction/embedding service layer has been removed, and so
has the **原文层** (volatile pending turns / delivered-pair ingest). What this
suite proves end to end is therefore:

* the three original-text methods (`memory_turn` / `memory_pending` /
  `memory_ingest`) fail **visibly** with `memory_original_text_layer_removed`
  — never accepted-then-dropped, never a vague `unknown_method`;
* no raw conversation text reaches the private root (searched byte-for-byte);
* scope isolation still holds across both dimensions;
* `memory_read` reports an explicit `null` (not an empty memory);
* `memory_query` / `memory_recall` give honest "semantic retrieval unavailable"
  answers, with `pendingTurns` pinned at 0 because there is no longer a buffer
  to count.

Private temp roots and local loopback endpoints only: never starts the macOS app,
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

DEFAULT_BIN = Path(__file__).resolve().parents[3] / "target" / "debug" / ("gmgn-taskd.exe" if os.name == "nt" else "gmgn-taskd")
BIN = os.environ.get("TASKD_BIN", str(DEFAULT_BIN))
WORLD = "world-a"
RESIDENT = "resident-a"
# 语义检索不可用时 recall context 的固定声明前缀。
UNAVAILABLE_MARKER = "语义记忆检索当前不可用"


def scope(world=WORLD, resident=RESIDENT):
    return {"worldID": world, "residentScope": resident}


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
        raise AssertionError("daemon did not expose its TCP endpoint: " +
                             self.p.communicate(timeout=2)[1].decode())

    def connect(self):
        endpoint = json.loads(Path(self.path).read_text())
        host, port = endpoint["address"].rsplit(":", 1)
        if endpoint["version"] != 1 or host != "127.0.0.1" or not 0 < int(port) < 65536:
            raise OSError("invalid local endpoint")
        self.auth = endpoint["token"]
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(8)
        try:
            s.connect((host, int(port)))
        except Exception:
            s.close()
            raise
        return s

    def request(self, method, params=None, request_id="t"):
        params = params or {}
        with self.connect() as s:
            s.sendall(json.dumps({"auth": self.auth, "id": request_id, "method": method,
                                  "params": params}).encode() + b"\n")
            with s.makefile("rb") as stream:
                return json.loads(stream.readline())

    def stop(self):
        if self.p.poll() is None:
            self.p.kill()
        self.p.communicate(timeout=3)


class LocalMemoryProcessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="taskd-local-memory-", dir=Path(tempfile.gettempdir()).resolve())
        self.daemon = None

    def tearDown(self):
        if self.daemon:
            self.daemon.stop()
        self.temp.cleanup()

    def start(self):
        self.daemon = Daemon(self.temp.name)
        return self.daemon

    def status(self, world=WORLD, resident=RESIDENT):
        return self.daemon.request("memory_status", {"scope": scope(world, resident)})["result"]

    def test_status_reports_local_fields_and_zero_pending(self):
        """status 只有本地字段；原文层移除后 `pendingTurns` 恒为 0。"""
        self.start()
        status = self.status()
        self.assertEqual(status, {"memory": None, "pendingTurns": 0})
        self.assertNotIn("configured", status)
        self.assertNotIn("orchestration", status)

    def test_original_text_layer_methods_fail_visibly(self):
        """原文层已整体移除：三个方法必须**显式报错**，绝不接受后丢弃。

        这一条是本套件里最重要的负向断言。老客户端仍会调用它们，而"回合
        原文没能进记忆"必须是一个说得出口的失败 —— 静默成功正是要消灭的形状。
        """
        d = self.start()
        marker = "raw-volatile-" + uuid.uuid4().hex
        cases = [
            ("memory_turn", {"scope": scope(), "role": "user", "text": marker}),
            ("memory_pending", {"scope": scope()}),
            ("memory_ingest", {"scope": scope(), "requestID": str(uuid.uuid4()),
                               "userText": marker, "agentReply": "答复"}),
        ]
        for method, params in cases:
            response = d.request(method, params)
            self.assertEqual(response["error"]["code"], "memory_original_text_layer_removed",
                             method + " 必须显式报告原文层已移除")
            self.assertNotIn("unknown_method", json.dumps(response),
                             method + " 不能含糊成 unknown_method（那会看起来像拼错了方法名）")

        # 被拒的投递不留任何痕迹：没有 pending、也没有已提交快照。
        self.assertEqual(self.status(), {"memory": None, "pendingTurns": 0})

        # **原始对话文本绝不落盘**：整个私有 root 里搜不到那个 marker。
        # 这条断言在原文层删除后依然成立，而且比过去更强 —— 现在连
        # "先进易失缓冲"这一步都不存在了。
        d.stop()
        for path in Path(self.temp.name).rglob("*"):
            if path.is_file():
                self.assertNotIn(marker.encode(), path.read_bytes(),
                                 "raw conversation text leaked to " + path.name)

    def test_read_reports_explicit_null_not_empty_memory(self):
        d = self.start()
        read = d.request("memory_read", {"scope": scope()})["result"]
        self.assertIn("memory", read)
        self.assertIsNone(read["memory"], "没有提交过快照就是显式 null，不是空记忆")

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
        self.assertEqual(recall["pendingTurns"], 0, "原文层已移除：恒为 0")
        self.assertIn(UNAVAILABLE_MARKER, recall["context"])
        self.assertNotIn("新会话恢复", recall["context"])
        # 没有快照 ⇒ 全新会话也没有东西可恢复，且**不得**宣称有未入库缓冲。
        fresh = d.request("memory_recall", {"scope": scope(), "query": "任何话题",
                                            "freshSession": True,
                                            "factLimit": 6, "noteLimit": 4})["result"]
        self.assertEqual(fresh["pendingTurns"], 0)
        self.assertNotIn("尚未入库的近期回合", fresh["context"])
        self.assertLessEqual(len(fresh["context"]), 8000)

        for params, code in [
            ({"scope": scope(), "query": "   "}, "invalid_query"),
            ({"scope": scope(), "query": "x" * 501}, "invalid_query"),
            ({"scope": scope(), "query": "q", "factLimit": 13}, "invalid_topk"),
            ({"scope": scope(), "query": "q", "noteLimit": 9}, "invalid_topk"),
        ]:
            self.assertEqual(d.request("memory_recall", params)["error"]["code"], code)

    def test_scope_isolation_between_worlds_and_residents(self):
        """两个维度都参与隔离：一个 scope 里没有东西，不该从别处借来。

        注意 `freshSession=true` 时会**无条件**带上"新会话恢复"这一段标题
        （即使没有快照，也如实写 `revision=0`）——所以这里断言的不是"标题不在"，
        而是"**没有任何别人的内容**"，那才是隔离真正要保证的事。
        """
        d = self.start()
        for world, resident in [(WORLD, "resident-b"), ("world-b", RESIDENT)]:
            other = d.request("memory_recall",
                              {"scope": scope(world, resident), "query": "任何话题",
                               "freshSession": True})["result"]
            self.assertEqual(other["revision"], 0)
            self.assertEqual(other["vectorGeneration"], 0)
            self.assertEqual(other["pendingTurns"], 0)
            self.assertEqual(other["facts"], [])
            self.assertEqual(other["notes"], [])
            # 没有快照 ⇒ 恢复段里不该有任何条目。
            self.assertNotIn("长期事实/偏好", other["context"])
            self.assertNotIn("相处/经验笔记", other["context"])
            self.assertNotIn("尚未入库的近期回合", other["context"])


if __name__ == "__main__":
    if not Path(BIN).is_file():
        print("gmgn-taskd binary not found at " + BIN +
              " (build it or set TASKD_BIN)", file=sys.stderr)
        sys.exit(2)
    unittest.main()

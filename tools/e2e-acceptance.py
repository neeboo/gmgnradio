#!/usr/bin/env python3
"""端到端验收：真实 gmgn-taskd（UDS）+ 真实生成后端（回环 HTTP）+ 真实 gmgn-mcpd（stdio）。

设计纪律（与仓库其它门禁一致）
--------------------------------
* **真进程、真协议、真存储**：本脚本不 import 生产 Swift/Rust 源码，也不手抄替身来
  顶替权威。它启动仓库里编出来的 `gmgn-taskd` 二进制（临时私有 root + Unix socket），
  用一个**真的 HTTP 服务器**充当生成后端，再启动真的 `gmgn-mcpd`，全程走线上 JSON
  协议。世界状态只在 taskd 的 `world_records/world_facts` 里落地。
* **每个边界都记证据**：每一次 request/params、每一个 job/request/event/object id、
  server 的原始回执、断言前后的状态，都写进 JSON 账本（`--ledger`）。
* **断言必须能失败**：每个正判据都配一个负对照（陈旧 revision、requestID 复用、
  三轴尺寸对不上、删除后再删、没授权就动作）。负对照不红就是门禁失效。
* **不碰用户数据**：只用自己的临时目录；不启动、不重启已安装的宿主 app；不碰
  Keychain、不读用户存档、不打印任何凭据（token 由本脚本临时生成，账本里只留掩码）。

它覆盖的边界（对应验收文档 §边界）
  意图 → 真实生成任务 → 权威入库 → 三轴尺寸 / 权威尺寸一致 → 摆放 / 手持 →
  许愿通知 → 已读落盘 → 重载仍已读且不重复 → 删除 / 恢复 → MCP 只读与授权动作。

用法::

    python3 tools/e2e-acceptance.py                 # 全跑
    python3 tools/e2e-acceptance.py --skip-swift     # 只跑 taskd/MCP 进程层
    python3 tools/e2e-acceptance.py --skip-player    # 不跑真实播放器（离线环境）
    TASKD_BIN=... MCPD_BIN=... python3 tools/e2e-acceptance.py
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import http.server
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import uuid
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_TASKD = ROOT / "target/debug/gmgn-taskd"
DEFAULT_MCPD = ROOT / "target/debug/gmgn-mcpd"
TOKEN = "e2e-" + uuid.uuid4().hex  # 每次运行临时生成，绝不落进账本正文

# ---------------------------------------------------------------------------
# 账本
# ---------------------------------------------------------------------------


class Ledger:
    def __init__(self) -> None:
        self.entries: list[dict] = []
        self.step = "boot"
        self.assertions = 0
        self.failures = 0

    def section(self, name: str) -> None:
        self.step = name
        self.entries.append({"step": name, "kind": "section"})

    def record(self, kind: str, **fields) -> None:
        entry = {"step": self.step, "kind": kind}
        for key, value in fields.items():
            if key in ("params", "response", "value") and isinstance(value, (dict, list)):
                entry[key] = value
            else:
                entry[key] = value
        self.entries.append(entry)

    def exchange(self, transport: str, method: str, params, response) -> None:
        # 凭据绝不入账：把出现的 token 掩掉。
        blob = json.dumps(response, ensure_ascii=False)
        if TOKEN in blob:
            response = json.loads(blob.replace(TOKEN, "<redacted>"))
        self.record("exchange", transport=transport, method=method,
                    params=params, response=response)

    def check(self, condition: bool, message: str, **evidence) -> bool:
        self.assertions += 1
        ok = bool(condition)
        if not ok:
            self.failures += 1
        self.record("assert", ok=ok, message=message, **evidence)
        mark = "PASS" if ok else "FAIL"
        print(f"  [{mark}] {message}")
        return ok


# ---------------------------------------------------------------------------
# 生成后端（真 HTTP；进程内线程，协议与 services/gmgn-taskd/tests/process.py 的
# Remote 同一形状，另加 authoritative_size 这一块）
# ---------------------------------------------------------------------------


def png_bytes() -> bytes:
    def chunk(kind: bytes, data: bytes) -> bytes:
        return (struct.pack(">I", len(data)) + kind + data
                + struct.pack(">I", zlib.crc32(kind + data)))

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"\0\xff\xff\xff\xff"))
            + chunk(b"IEND", b""))


GLB = b"glTF" + struct.pack("<II", 2, 24) + struct.pack("<I", 4) + b"JSON" + b"{}  "
GLB_SHA = hashlib.sha256(GLB).hexdigest()

# 权威里对象条目的**线上形状**（逐字对齐 `services/gmgn-taskd/src/world.rs`
# `validate_object_entry`）：只允许 `isEnabled` / `transform`（position+rotation+scale）/
# `metadata`（值都必须是字符串）；三轴 size 住在 `gmgn.generated-prop.v1` 那个 **JSON 字符串**
# 里。`objectID` 由 op 的 `objectID` 字段给出（entry 里顶层没有它）。
GENERATED_PROP_KEY = "gmgn.generated-prop.v1"


def prop_blob(object_id: str, size: tuple, display_name: str, wish_id: str = "wish") -> str:
    return json.dumps({
        "objectID": object_id,
        "sourceWishID": wish_id,
        "displayName": display_name,
        "sourceHeight": size[1],
        "size": {"x": size[0], "y": size[1], "z": size[2]},
    }, ensure_ascii=False)


def object_entry(object_id: str, size: tuple, display_name: str,
                 position=None, rotation=None, enabled: bool = True,
                 wish_id: str = "wish") -> dict:
    return {
        "isEnabled": enabled,
        "transform": {
            "position": position or {"x": 0.0, "y": 0.0, "z": 0.0},
            "rotation": rotation or {"x": 0.0, "y": 0.0, "z": 0.0, "w": 1.0},
            "scale": {"x": 1.0, "y": 1.0, "z": 1.0},
        },
        "metadata": {GENERATED_PROP_KEY: prop_blob(object_id, size, display_name, wish_id)},
    }


def entry_size(entry: dict) -> dict:
    return json.loads(entry["metadata"][GENERATED_PROP_KEY])["size"]


class Provider:
    """一个真的回环 HTTP 生成后端。"""

    def __init__(self, authoritative_size=None, dimensions_seen=None) -> None:
        self.authoritative_size = authoritative_size
        self.dimensions_seen = dimensions_seen
        self.requests: list[dict] = []
        self.jobs: dict[str, dict] = {}
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):  # noqa: D401
                return

            def _auth(self) -> bool:
                return self.headers.get("Authorization") == "Bearer " + TOKEN

            def _reply(self, value, code=200) -> None:
                data = json.dumps(value).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                try:
                    self.wfile.write(data)
                except (BrokenPipeError, ConnectionResetError):
                    pass

            def _capture(self, body) -> None:
                outer.requests.append({
                    "path": self.path,
                    "method": self.command,
                    "idempotency_key": self.headers.get("Idempotency-Key"),
                    "body": body,
                })

            def do_GET(self):
                if not self._auth():
                    self._reply({"error": "unauthorized"}, 401)
                    return
                outer.requests.append({"path": self.path, "method": "GET"})
                if self.path == "/health":
                    self._reply({
                        "status": "api_ready",
                        "generation": {"ready": True},
                        "provider": {
                            "id": "e2e-provider",
                            "kind": "remote_http",
                            "max_input_px": 2048,
                            "size_intent": {
                                "axes": ["height", "longest"],
                                "min_meters": 0.01,
                                "max_meters": 3.0,
                                "applies": "echo",
                            },
                        },
                    })
                    return
                parts = self.path.strip("/").split("/")
                # /v1/jobs/<id>[/model.glb|/collider.glb]
                rid = parts[2] if len(parts) > 2 else ""
                match = next((j for j in outer.jobs.values() if j["id"] == rid), None)
                if match is None:
                    self._reply({"error": "not_found"}, 404)
                    return
                if self.path.endswith("model.glb") or self.path.endswith("collider.glb"):
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(GLB)))
                    self.end_headers()
                    self.wfile.write(GLB)
                    return
                if match["state"] != "cancelled":
                    match["state"] = "completed"
                    inspection = {
                        "sha256": GLB_SHA, "bytes": len(GLB), "triangles": 0,
                        "primitives": 0, "materials": 0, "accessors": 0,
                        "accessor_bounds": {}, "bounds": {"min": [0, 0, 0], "max": [1, 1, 1]},
                        "scale_calibrated": False, "scene_transform_count": 0,
                    }
                    if outer.dimensions_seen is not None:
                        inspection["dimensions"] = outer.dimensions_seen
                    match["result"] = {
                        "model_url": f"/v1/jobs/{rid}/model.glb",
                        "source": match["source"],
                        "suggested_height_meters": 0.5,
                        "scale_requires_confirmation": True,
                        "interaction_status": "unbound",
                        "workflow_profile": "e2e",
                        "affordance_candidates": [],
                        "interaction_bindings": [],
                        "inspection": inspection,
                    }
                    if outer.authoritative_size is not None:
                        match["result"]["authoritative_size"] = {
                            "dimensions": outer.authoritative_size,
                            "units": "m",
                            "up_axis": "+Y",
                            "forward_axis": "+Z",
                        }
                self._reply(match)

            def do_POST(self):
                if not self._auth():
                    self._reply({"error": "unauthorized"}, 401)
                    return
                length = int(self.headers.get("Content-Length", "0"))
                raw = self.rfile.read(length) if length else b""
                body = json.loads(raw or b"{}")
                self._capture(body)
                if self.path.endswith("/cancel"):
                    rid = self.path.split("/")[3]
                    for job in outer.jobs.values():
                        if job["id"] == rid:
                            job["state"] = "cancelled"
                            self._reply(job)
                            return
                    self._reply({"error": "not_found"}, 404)
                    return
                key = self.headers.get("Idempotency-Key", "")
                if key not in outer.jobs:
                    outer.jobs[key] = {
                        "id": uuid.uuid4().hex, "state": "running", "reason": None,
                        "name": body["name"], "source": body["source"],
                        "height_meters": body["height_meters"], "result": None,
                        "compute_may_continue": False, "created_at": 1.0, "updated_at": 1.0,
                    }
                self._reply(outer.jobs[key])

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.endpoint = "http://127.0.0.1:" + str(self.server.server_port)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self) -> None:
        try:
            self.server.shutdown()
            self.server.server_close()
        except Exception:
            pass


# ---------------------------------------------------------------------------
# gmgn-taskd（真子进程 + UDS）
# ---------------------------------------------------------------------------


class Taskd:
    def __init__(self, binary: Path, root: Path) -> None:
        self.binary = binary
        self.root = root
        self.socket_path = root / "taskd.sock"
        self.process: subprocess.Popen | None = None
        self.stderr = b""

    def start(self) -> None:
        self.root.mkdir(parents=True, exist_ok=True)
        self.process = subprocess.Popen(
            [str(self.binary), "--root", str(self.root), "--socket",
             str(self.socket_path), "--concurrency", "2"],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                break
            try:
                with socket.socket(socket.AF_UNIX) as probe:
                    probe.settimeout(1)
                    probe.connect(str(self.socket_path))
                return
            except OSError:
                time.sleep(0.02)
        if self.process.poll() is None:
            self.process.kill()
        raise RuntimeError("taskd 没有暴露出 socket: " + self._drain_stderr())

    def _drain_stderr(self) -> str:
        if self.process and self.process.stderr:
            try:
                return self.process.stderr.read().decode(errors="replace")[-2000:]
            except Exception:
                return ""
        return ""

    def request(self, method: str, params: dict | None = None, request_id: str | None = None):
        rid = request_id or str(uuid.uuid4())
        frame = json.dumps({"id": rid, "method": method, "params": params or {}})
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(20)
            connection.connect(str(self.socket_path))
            connection.sendall(frame.encode() + b"\n")
            buffer = b""
            while b"\n" not in buffer:
                chunk = connection.recv(65536)
                if not chunk:
                    break
                buffer += chunk
                if len(buffer) > 8 * 1024 * 1024:
                    raise RuntimeError("taskd 回帧过大")
        line = buffer.split(b"\n", 1)[0]
        return json.loads(line)

    def stop(self) -> None:
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=3)

    def restart(self) -> None:
        self.stop()
        start = time.monotonic()
        self.start()
        self.restart_seconds = time.monotonic() - start


# ---------------------------------------------------------------------------
# gmgn-mcpd（真子进程 + stdio JSON-RPC）
# ---------------------------------------------------------------------------


class Mcp:
    def __init__(self, binary: Path, socket_path: Path, grant: Path | None = None) -> None:
        self.binary = binary
        self.socket_path = socket_path
        self.grant = grant
        self.process: subprocess.Popen | None = None
        self.next_id = 1

    def start(self) -> None:
        args = [str(self.binary), "--socket", str(self.socket_path)]
        if self.grant is not None:
            args += ["--grant", str(self.grant)]
        self.process = subprocess.Popen(
            args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.handshake()

    def send(self, message: dict) -> None:
        assert self.process and self.process.stdin
        self.process.stdin.write((json.dumps(message) + "\n").encode())
        self.process.stdin.flush()

    def read(self) -> dict:
        assert self.process and self.process.stdout
        while True:
            line = self.process.stdout.readline()
            if not line:
                raise RuntimeError("gmgn-mcpd 在应答前退出了")
            line = line.strip()
            if line:
                return json.loads(line)

    def request(self, method: str, params: dict) -> dict:
        rid = self.next_id
        self.next_id += 1
        self.send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        while True:
            reply = self.read()
            if reply.get("id") == rid:
                return reply

    def handshake(self) -> dict:
        reply = self.request("initialize", {
            "protocolVersion": "2025-11-25",
            "capabilities": {},
            "clientInfo": {"name": "gmgn-e2e-acceptance", "version": "0.1.0"},
        })
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        return reply

    def call(self, tool: str, arguments: dict) -> dict:
        return self.request("tools/call", {"name": tool, "arguments": arguments})

    def stop(self) -> None:
        if self.process and self.process.poll() is None:
            self.process.kill()
            self.process.wait(timeout=3)


# ---------------------------------------------------------------------------
# 边界 1：意图 → 真实生成任务 → 权威入库 → 三轴尺寸
# ---------------------------------------------------------------------------


def run_authority_layer(ledger: Ledger, taskd: Taskd, work: Path) -> dict:
    ledger.section("1 意图→生成任务→权威入库")
    provider = Provider(authoritative_size=[1.443, 0.862, 0.302])
    configured = taskd.request("configure", {"endpoint": provider.endpoint, "token": TOKEN})
    ledger.exchange("taskd", "configure", {"endpoint": provider.endpoint, "token": "<redacted>"}, configured)
    ledger.check("result" in configured, "taskd 接受回环生成后端的凭据")

    # 1a. 三轴意图：远端**只**收到 height_meters（三轴恒定不发，见 model.rs
    #     `SizeIntentSupport::accepts`），归一发生在 app 侧。
    wish_id = str(uuid.uuid4())
    three_axis = {"mode": "dimensions", "millimeters": {"x": 1443, "y": 862, "z": 302},
                  "source": "user"}
    submit = taskd.request("submit", {
        "id": wish_id, "endpoint": provider.endpoint, "name": "E2E 超大荧幕电视",
        "pngBase64": base64.b64encode(png_bytes()).decode(),
        "source": {"author": "e2e", "license": "CC0"},
        "heightMeters": 0.862, "sizeIntent": three_axis,
    })
    ledger.exchange("taskd", "submit", {"id": wish_id, "heightMeters": 0.862,
                                        "sizeIntent": three_axis}, submit)
    job_id = submit["result"]["job"]["id"]
    ledger.record("job", job_id=job_id, wish_id=wish_id)

    job = wait_stage(taskd, ledger, job_id, {"ready", "failed"})
    ledger.check(job.get("backendStage") == "ready",
                 "三轴意图：真实生成任务落地为 ready", job_id=job_id,
                 stage=job.get("backendStage"), lastError=job.get("lastError"))
    posted = [r for r in provider.requests if r["method"] == "POST" and r["path"] == "/v1/jobs"]
    remote_body = posted[0]["body"] if posted else {}
    ledger.record("provider_request", path="/v1/jobs", body=remote_body)
    ledger.check("size_intent" not in remote_body and remote_body.get("height_meters") == 0.862,
                 "三轴意图不发 `size_intent`，远端只收到 height_meters=0.862（fail-closed 方向）",
                 remote=remote_body.get("size_intent"), height=remote_body.get("height_meters"))
    receipt = job.get("receipt", {})
    auth = (receipt.get("result") or {}).get("authoritative_size")
    ledger.check(auth is not None and auth["dimensions"] == [1.443, 0.862, 0.302],
                 "生成回执带着三轴权威尺寸 [1.443, 0.862, 0.302]（逐轴）", authoritative_size=auth)

    # 1b. 世界入库：先用 replaceState 建世界，再 upsertObject 落那件物件。
    world = "e2e-world-" + uuid.uuid4().hex[:8]
    state = {"worldID": world, "revision": 1, "weather": "clear",
             "layoutRevision": 1, "objectStates": {}}
    state_json = json.dumps(state, ensure_ascii=False)
    imported = taskd.request("world_import", {
        "worldID": world, "requestID": "e2e-import", "packageID": "e2e",
        "packageVersion": "1.0.0",
        "stateSha256": hashlib.sha256(state_json.encode()).hexdigest(),
        "stateJson": state_json,
    })
    ledger.exchange("taskd", "world_import", {"worldID": world}, imported)
    ledger.check(imported.get("result", {}).get("revision") == 1,
                 "世界文档读入权威（revision=1）", worldID=world)

    object_id = "wish-prop-" + wish_id
    three = (1.443, 0.862, 0.302)
    commit = taskd.request("world_commit", {
        "worldID": world, "requestID": "e2e-place-1", "expectedRevision": 1,
        "producer": "e2e", "intent": {"kind": "place"},
        "ops": [{"op": "upsertObject", "objectID": object_id,
                 "object": object_entry(object_id, three, "超大荧幕电视", wish_id=wish_id)}],
    })
    ledger.exchange("taskd", "world_commit", {"op": "upsertObject", "objectID": object_id}, commit)
    ledger.check(commit.get("result", {}).get("changedObjects") == [object_id],
                 "物件入库：changedObjects 恰是这一件", changed=commit.get("result", {}).get("changedObjects"))
    snapshot = taskd.request("world_snapshot", {"worldID": world})
    stored = snapshot["result"]["record"]["state"]["objectStates"][object_id]
    ledger.record("object_state", objectID=object_id, state=stored)
    size = entry_size(stored)
    ledger.check(size == {"x": 1.443, "y": 0.862, "z": 0.302},
                 "三轴尺寸逐轴落在世界状态里（1.443 × 0.862 × 0.302）", size=size)

    # 1c. 三轴一致性负对照：同一份意图、后端回一个对不上的厚度 ⇒ 任务必须失败。
    bad_provider = Provider(authoritative_size=[1.443, 0.9, 0.302])
    taskd.request("configure", {"endpoint": bad_provider.endpoint, "token": TOKEN})
    bad_submit = taskd.request("submit", {
        "id": str(uuid.uuid4()), "endpoint": bad_provider.endpoint, "name": "E2E 错尺寸电视",
        "pngBase64": base64.b64encode(png_bytes()).decode(),
        "source": {"author": "e2e", "license": "CC0"},
        "heightMeters": 0.862, "sizeIntent": three_axis,
    })
    bad_id = bad_submit["result"]["job"]["id"]
    bad_job = wait_stage(taskd, ledger, bad_id, {"ready", "failed"})
    ledger.record("negative_control", name="authoritative_size_conflicts_with_intent",
                  job_id=bad_id, stage=bad_job.get("backendStage"), lastError=bad_job.get("lastError"))
    ledger.check(bad_job.get("backendStage") in ("failed", "interrupted")
                 and bad_job.get("lastError") == "authoritative_size_conflicts_with_intent",
                 "负对照：后端权威尺寸与三轴意图对不上 ⇒ 任务失败且错误码具名",
                 stage=bad_job.get("backendStage"), lastError=bad_job.get("lastError"))
    bad_provider.close()

    # 1d. 旧形状（一根轴）必须真的把 size_intent 发到线上 —— 证明协商通路存在。
    axis_provider = Provider(authoritative_size=[1.1, 0.133, 0.057])
    taskd.request("configure", {"endpoint": axis_provider.endpoint, "token": TOKEN})
    axis_submit = taskd.request("submit", {
        "id": str(uuid.uuid4()), "endpoint": axis_provider.endpoint, "name": "E2E 长剑",
        "pngBase64": base64.b64encode(png_bytes()).decode(),
        "source": {"author": "e2e", "license": "CC0"}, "heightMeters": 0.5,
        "sizeIntent": {"axis": "longest", "meters": 1.1, "source": "user"},
    })
    axis_id = axis_submit["result"]["job"]["id"]
    wait_stage(taskd, ledger, axis_id, {"ready", "failed"})
    axis_posts = [r for r in axis_provider.requests
                  if r["method"] == "POST" and r["path"] == "/v1/jobs"]
    axis_body = axis_posts[0]["body"] if axis_posts else {}
    ledger.record("provider_request", path="/v1/jobs", body=axis_body)
    ledger.check(axis_body.get("size_intent") == {"axis": "longest", "meters": 1.1, "source": "user"},
                 "协商通过后，旧形状 size_intent 真的发到了线上（逐字段）",
                 size_intent=axis_body.get("size_intent"))
    axis_provider.close()
    return {"world": world, "object_id": object_id, "job_id": job_id, "provider": provider}


def wait_stage(taskd: Taskd, ledger: Ledger, job_id: str, stages: set[str]) -> dict:
    deadline = time.monotonic() + 20
    job = {}
    while time.monotonic() < deadline:
        snapshot = taskd.request("snapshot")
        jobs = snapshot.get("result", {}).get("jobs", [])
        job = next((j for j in jobs if j["id"].lower() == job_id.lower()), {})
        if job.get("backendStage") in stages:
            return job
        time.sleep(0.05)
    ledger.record("timeout", job_id=job_id, last=job)
    return job


# ---------------------------------------------------------------------------
# 边界 2：摆放 → 手持 → 删除 / 恢复
# ---------------------------------------------------------------------------


def run_placement_layer(ledger: Ledger, taskd: Taskd, ctx: dict) -> None:
    world = ctx["world"]
    object_id = ctx["object_id"]
    ledger.section("2 摆放→手持→删除→恢复")

    placed = taskd.request("world_commit", {
        "worldID": world, "requestID": "e2e-place-2", "expectedRevision": 2,
        "producer": "e2e", "intent": {"kind": "place"},
        "ops": [{"op": "upsertObject", "objectID": object_id, "object": object_entry(
            object_id, (1.443, 0.862, 0.302), "超大荧幕电视",
            position={"x": -2.7, "y": 0.52, "z": -5.0},
            rotation={"x": 0.0, "y": 0.3826834, "z": 0.0, "w": 0.9238795})}],
    })
    ledger.exchange("taskd", "world_commit", {"op": "upsertObject", "phase": "place"}, placed)
    record = taskd.request("world_snapshot", {"worldID": world})["result"]["record"]
    transform = record["state"]["objectStates"][object_id]["transform"]
    ledger.check(transform["position"] == {"x": -2.7, "y": 0.52, "z": -5.0},
                 "摆放：位置逐分量落进权威", position=transform["position"])

    held = taskd.request("world_commit", {
        "worldID": world, "requestID": "e2e-hold", "expectedRevision": 3,
        "producer": "e2e", "intent": {"kind": "hold"},
        "ops": [{"op": "setWorldFacts", "facts": {"heldProp": {"objectID": object_id,
                                                                "slot": "rightHand"}}}],
    })
    ledger.exchange("taskd", "world_commit", {"op": "setWorldFacts", "heldProp": object_id}, held)
    held_state = taskd.request("world_snapshot", {"worldID": world})["result"]["record"]["state"]
    ledger.check(held_state.get("heldProp", {}).get("objectID") == object_id,
                 "手持：heldProp 指向同一件物件", heldProp=held_state.get("heldProp"))

    removed = taskd.request("world_commit", {
        "worldID": world, "requestID": "e2e-delete", "expectedRevision": 4,
        "producer": "e2e", "intent": {"kind": "delete"},
        "ops": [{"op": "deleteObject", "objectID": object_id}],
    })
    ledger.exchange("taskd", "world_commit", {"op": "deleteObject", "objectID": object_id}, removed)
    after_delete = taskd.request("world_records", {"worldID": world, "domain": "objects"})["result"]["records"]
    row = next((r for r in after_delete if r["key"] == object_id), {})
    ledger.record("tombstone", objectID=object_id, row=row)
    ledger.check(row.get("tombstone") is True,
                 "删除：墓碑落库（不是硬删行）", tombstone=row.get("tombstone"))
    facts = taskd.request("world_facts_read", {"worldID": world, "after": 0})["result"]["facts"]
    kinds = [f["kind"] for f in facts]
    ledger.check("object.removed" in kinds, "删除：事实流里有 object.removed", facts=kinds)
    kept = taskd.request("world_snapshot", {"worldID": world})["result"]["record"]["state"]["objectStates"]
    ledger.check(object_id not in kept, "删除：活物件里不再有它（投影不撒谎）",
                 live=sorted(kept))

    # 负对照：再删一次同一件 —— 不得凭空再写一条墓碑。
    facts_before = len(facts)
    again = taskd.request("world_commit", {
        "worldID": world, "requestID": "e2e-delete-again", "expectedRevision": 5,
        "producer": "e2e", "ops": [{"op": "deleteObject", "objectID": object_id}],
    })
    ledger.exchange("taskd", "world_commit", {"op": "deleteObject", "objectID": object_id, "again": True}, again)
    facts_after = taskd.request("world_facts_read", {"worldID": world, "after": 0})["result"]["facts"]
    removed_facts = [f for f in facts_after if f["kind"] == "object.removed"]
    ledger.check("error" not in again or len(removed_facts) == 1,
                 "负对照：重复删除不会凭空再写墓碑（已墓碑就跳过）", removed=len(removed_facts),
                 error=again.get("error"))

    # 恢复：同一 objectID 重新入库 = 合法的新变更（墓碑清除、revision +1）。
    readd = taskd.request("world_commit", {
        "worldID": world, "requestID": "e2e-readd", "expectedRevision": 6,
        "producer": "e2e", "intent": {"kind": "readd"},
        "ops": [{"op": "upsertObject", "objectID": object_id, "object": object_entry(
            object_id, (1.443, 0.862, 0.302), "超大荧幕电视",
            position={"x": 1.0, "y": 0.0, "z": 1.0})}],
    })
    ledger.exchange("taskd", "world_commit", {"op": "upsertObject", "phase": "readd"}, readd)
    readded = taskd.request("world_records", {"worldID": world, "domain": "objects"})["result"]["records"]
    readded_row = next((r for r in readded if r["key"] == object_id), {})
    ledger.check(readded_row.get("tombstone") is False and readded_row.get("revision", 0) >= 4,
                 "恢复：重新入库清除墓碑、revision 前进（合法的新变更）",
                 tombstone=readded_row.get("tombstone"), revision=readded_row.get("revision"))
    restored_live = taskd.request("world_snapshot", {"worldID": world})["result"]["record"]["state"]["objectStates"]
    ledger.check(object_id in restored_live, "恢复：物件回到活物件投影里")

    # 负对照：陈旧 expectedRevision 必须可见地失败，不许静默覆盖。
    stale = taskd.request("world_commit", {
        "worldID": world, "requestID": "e2e-stale", "expectedRevision": 1,
        "ops": [{"op": "setWorldFacts", "facts": {"layoutRevision": 1}}],
    })
    ledger.exchange("taskd", "world_commit", {"expectedRevision": 1, "stale": True}, stale)
    ledger.check(stale.get("error", {}).get("code") == "revision_conflict",
                 "负对照：陈旧 expectedRevision ⇒ revision_conflict（不静默覆盖）",
                 error=stale.get("error"))

    # 负对照：同一 requestID 换内容 ⇒ request_id_conflict。
    rid = "e2e-replay-" + uuid.uuid4().hex[:8]
    world_revision = readd["result"]["revision"]
    first = taskd.request("world_commit", {
        "worldID": world, "requestID": rid, "expectedRevision": world_revision,
        "ops": [{"op": "setWorldFacts", "facts": {"layoutRevision": 10}}],
    })
    second = taskd.request("world_commit", {
        "worldID": world, "requestID": rid, "expectedRevision": world_revision,
        "ops": [{"op": "setWorldFacts", "facts": {"layoutRevision": 99}}],
    })
    ledger.exchange("taskd", "world_commit", {"requestID": rid, "replay": "different content"}, second)
    ledger.check(second.get("error", {}).get("code") == "request_id_conflict",
                 "负对照：requestID 复用但内容不同 ⇒ request_id_conflict",
                 first="result" in first, error=second.get("error"))


# ---------------------------------------------------------------------------
# 边界 3：许愿通知 → 已读落盘 → 重载仍已读且不重复
# ---------------------------------------------------------------------------


def run_wish_layer(ledger: Ledger, taskd: Taskd, ctx: dict) -> None:
    ledger.section("3 许愿通知→已读→重载")
    world = "e2e-wish-world"
    resident = "resident-e2e"
    scope = {"worldID": world, "residentScope": resident}
    message_id = str(uuid.uuid4())

    # 居民收件箱的**真实**写入面是 `state_commit` 的 `messages`（落 `resident_messages`），
    # 不是 legacy 的 `publish_message`（那张 `messages` 表是另一条已退役的投递面）。
    def commit_message(mid: str, kind: str, payload: dict, expected: int, request_id: str) -> dict:
        return taskd.request("state_commit", {
            "scope": scope, "domain": "resident", "key": "inbox",
            "expectedRevision": expected, "requestID": request_id,
            "value": {"entries": [{"id": mid, "read": False}]},
            "messages": [{"id": mid, "kind": kind, "payload": payload}],
        })

    first = commit_message(message_id, "wish.placed",
                           {"status": "已摆放", "title": "「超大荧幕电视」已摆放。"},
                           0, "e2e-wish-1")
    ledger.exchange("taskd", "state_commit", {"domain": "resident", "message": message_id}, first)
    ledger.check(first.get("result", {}).get("revision") == 1,
                 "许愿终态以一条消息进收件箱（resident 消息表，只有一个写入者）", result=first)

    read = taskd.request("message_read", {"scope": scope, "consumer": "ui"})
    ledger.exchange("taskd", "message_read", {"scope": scope, "consumer": "ui"}, read)
    messages = read["result"]["messages"]
    ledger.check([m["id"] for m in messages] == [message_id],
                 "未读消息读得到，且恰一条（不重复）", ids=[m["id"] for m in messages])

    ack = taskd.request("message_ack", {"scope": scope, "consumer": "ui", "id": message_id})
    ledger.exchange("taskd", "message_ack", {"consumer": "ui", "id": message_id}, ack)
    drained = taskd.request("message_read", {"scope": scope, "consumer": "ui"})
    ledger.check(drained["result"]["messages"] == [],
                 "已读：ack 后 ui 侧不再收到（角标少一）", messages=drained["result"]["messages"])

    taskd.restart()
    ledger.record("restart", seconds=round(getattr(taskd, "restart_seconds", 0), 3))
    after = taskd.request("message_read", {"scope": scope, "consumer": "ui"})
    ledger.exchange("taskd", "message_read", {"scope": scope, "consumer": "ui", "after_restart": True}, after)
    ledger.check(after["result"]["messages"] == [],
                 "重载后仍然已读：ack 跨重启存活，不再重发（不重复）",
                 messages=after["result"]["messages"])

    # 负对照：另一消费者仍然看得到未读（ack 只清一个消费者，不是全局静音）。
    agent = taskd.request("message_read", {"scope": scope, "consumer": "agent"})
    ledger.check([m["id"] for m in agent["result"]["messages"]] == [message_id],
                 "负对照：ack 只清 ui 这一个消费者，agent 仍能看到这一条",
                 agent=[m["id"] for m in agent["result"]["messages"]])

    # 新消息在重载后仍然未读（"新消息仍未读"）。
    fresh = str(uuid.uuid4())
    commit_message(fresh, "wish.failed", {"status": "已删除"}, 1, "e2e-wish-2")
    fresh_read = taskd.request("message_read", {"scope": scope, "consumer": "ui"})
    ledger.check([m["id"] for m in fresh_read["result"]["messages"]] == [fresh],
                 "重载之后的新消息仍未读（恰一条）", ids=[m["id"] for m in fresh_read["result"]["messages"]])


# ---------------------------------------------------------------------------
# 边界 4：MCP 只读 + 授权动作
# ---------------------------------------------------------------------------


def run_mcp_layer(ledger: Ledger, taskd: Taskd, mcpd_binary: Path, work: Path) -> None:
    ledger.section("4 MCP 只读与授权动作")
    if not mcpd_binary.exists():
        ledger.check(False, f"gmgn-mcpd 不存在：{mcpd_binary}")
        return
    # 只读会话（无授权文件）。
    read_session = Mcp(mcpd_binary, taskd.socket_path)
    read_session.start()
    tools = read_session.request("tools/list", {})
    names = sorted(t["name"] for t in tools["result"]["tools"])
    ledger.record("mcp_tools", names=names)
    ledger.check(names == sorted([
        "gmgn_capability_contract", "gmgn_prop_cancel", "gmgn_prop_jobs_read",
        "gmgn_prop_retry", "gmgn_prop_submit", "gmgn_world_commit",
        "gmgn_world_cursors_read", "gmgn_world_facts_read", "gmgn_world_read",
        "gmgn_world_records_read"]),
        "MCP 工具面是权威常量生成的那 10 条", names=names)

    world_read = read_session.call("gmgn_world_read", {"worldID": "e2e-wish-world"})
    structured = world_read["result"]["structuredContent"]
    ledger.record("mcp_result", tool="gmgn_world_read", result=structured)
    ledger.check(structured.get("ok") is True,
                 "只读工具在无授权时照常工作（world_read 成功）", result=structured)

    refused = read_session.call("gmgn_world_commit", {
        "worldID": "e2e-wish-world", "requestID": "mcp-no-grant", "expectedRevision": 0,
        "ops": [{"op": "setWorldFacts", "facts": {"layoutRevision": 3}}]})
    refusal_text = json.dumps(refused, ensure_ascii=False)
    ledger.record("mcp_result", tool="gmgn_world_commit", result=refused)
    ledger.check("mcp_grant_not_configured" in refusal_text,
                 "负对照：没有授权文件时动作工具被拒（不是静默放行）", reply=refused)
    read_session.stop()
    # 杀掉 MCP 面，权威照旧活着（MCP 不是第二个权威）。
    alive = taskd.request("snapshot")
    ledger.check("result" in alive, "负对照：杀掉 MCP 面不影响权威（gmgn-taskd 仍然应答）")

    # 授权动作：armed + 点名 gmgn_world_commit。
    grant = work / "grant.json"
    grant.write_text(json.dumps({
        "state": "armed", "socketPath": str(taskd.socket_path), "secret": "not-used",
        "tools": [{"name": "gmgn_world_commit"}],
    }))
    armed = Mcp(mcpd_binary, taskd.socket_path, grant=grant)
    armed.start()
    committed = armed.call("gmgn_world_commit", {
        "worldID": "e2e-mcp-world", "requestID": "mcp-armed", "expectedRevision": 0,
        "ops": [{"op": "replaceState", "state": {
            "worldID": "e2e-mcp-world", "revision": 1, "layoutRevision": 5,
            "objectStates": {}}}]})
    ledger.record("mcp_result", tool="gmgn_world_commit", result=committed)
    committed_ok = (committed.get("result", {}).get("isError") is not True
                    and "mcp_tool_not_granted" not in json.dumps(committed)
                    and committed.get("result", {}).get("structuredContent", {}).get("ok") is True)
    ledger.check(committed_ok, "armed 且点名后动作工具真的落到权威", reply=committed)
    armed.stop()

    # 负对照：授权文件指向别的 socket ⇒ 拒绝沿用（防串权威）。
    foreign = work / "foreign-grant.json"
    foreign.write_text(json.dumps({
        "state": "armed", "socketPath": str(work / "other.sock"), "secret": "not-used",
        "tools": [{"name": "gmgn_world_commit"}],
    }))
    foreign_session = Mcp(mcpd_binary, taskd.socket_path, grant=foreign)
    foreign_session.start()
    mismatch = foreign_session.call("gmgn_world_commit", {
        "worldID": "e2e-wish-world", "requestID": "mcp-foreign", "expectedRevision": 2,
        "ops": [{"op": "setWorldFacts", "facts": {"layoutRevision": 6}}]})
    ledger.record("mcp_result", tool="gmgn_world_commit", result=mismatch)
    ledger.check("mcp_grant_socket_mismatch" in json.dumps(mismatch),
                 "负对照：授权文件指向别的权威 ⇒ 拒绝沿用", reply=mismatch)
    foreign_session.stop()


# ---------------------------------------------------------------------------
# Swift 业务层（现编现跑生产源码，非进程级；明确标为 layer B）
# ---------------------------------------------------------------------------

SWIFT_LAYERS = [
    ("test-resident-prop-size-intent.swift", "三轴尺寸意图 → 世界 size（app 侧归一）"),
    ("test-resident-prop-world-collision.swift", "碰撞盒与三轴尺寸同源"),
    ("test-resident-prop-placement.swift", "摆放判定"),
    ("test-resident-prop-hold.swift", "手持 / 挂点"),
    ("test-resident-screen-app-wiring.swift", "屏幕工具并进当轮 lease 的接线"),
    ("test-resident-screen-capability.swift", "屏幕功能点注册到物件（三断言 + 四条注入）"),
    ("test-resident-screen-idle-and-motion.swift", "待机不挂 WebView / 运动降载停下恢复（五条注入）"),
    ("test-resident-inbox-state-storage.swift", "收件箱已读跨重启（真实 taskd）"),
    ("test-resident-system-inbox.swift", "收件箱已读 / 角标 / 终态锚点"),
    ("test-wish-task-messages.swift", "许愿消息出口 / 幂等 / 人话"),
    ("test-resident-tool-schema-keys.swift", "工具 schema 约束键门禁"),
    ("test-stage-resident-chat.swift", "居民聊天状态与键盘仲裁"),
]


def run_swift_layer(ledger: Ledger, taskd_binary: Path, work: Path) -> None:
    ledger.section("5 Swift 业务层（现编现跑生产源码）")
    env = dict(os.environ)
    env["TASKD_BIN"] = str(taskd_binary)
    env["PATH"] = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    for script, label in SWIFT_LAYERS:
        path = ROOT / "tools" / script
        if not path.exists():
            ledger.check(False, f"Swift 判据缺失：{script}")
            continue
        started = time.monotonic()
        result = subprocess.run(["swift", str(path)], cwd=ROOT, env=env,
                                capture_output=True, text=True, timeout=1800)
        seconds = round(time.monotonic() - started, 2)
        tail = "\n".join(result.stdout.strip().splitlines()[-3:])
        ledger.record("swift_harness", script=script, label=label,
                      exit=result.returncode, seconds=seconds, tail=tail)
        ledger.check(result.returncode == 0, f"Swift 判据通过：{label}（{script}）",
                     exit=result.returncode, seconds=seconds, tail=tail,
                     stderr=result.stderr.strip().splitlines()[-2:] if result.returncode else [])


# ---------------------------------------------------------------------------
# 边界 6：官方播放器真实加载 + 播放时间前进（WKWebView + 真网络）
# ---------------------------------------------------------------------------


def run_player_layer(ledger: Ledger) -> None:
    ledger.section("6 官方播放器加载与播放时间前进")
    embed = "https://www.youtube.com/embed/aqz-KE-bpKQ"  # 官方嵌入 URL（Big Buck Bunny）
    probe = ROOT / "tools/probe-screen-embed-playback.swift"
    if not probe.exists():
        ledger.check(False, "播放探针不存在：tools/probe-screen-embed-playback.swift")
        return
    started = time.monotonic()
    try:
        result = subprocess.run(
            ["swift", str(probe), "e2e-youtube", embed, "18"], cwd=ROOT,
            env={**os.environ, "PATH": "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                 # 探针必须把 web 视图放进一个**离屏 NSWindow**：不在窗口里的离屏视图在
                 # WebKit 眼里是"页面不可见"，视频页据此不开始播（实测 currentTime 恒 0）。
                 # 生产里覆盖层当然在舞台窗口里，所以这才是与生产同形的量法。
                 "SCREEN_PLAYBACK_WINDOW": "1"},
            capture_output=True, text=True, timeout=180)
    except subprocess.TimeoutExpired:
        ledger.check(False, "播放探针超时（网络或 WebKit 卡住）")
        return
    seconds = round(time.monotonic() - started, 2)
    output = result.stdout
    advanced = [line for line in output.splitlines() if line.startswith((
        "PLAYBACK-VERDICT", "PLAYBACK-NAV", "PLAYBACK-CASE", "PLAYBACK-ORIGIN",
        "PLAYBACK-IFRAME-SRC"))]
    ledger.record("player_probe", embed=embed, exit=result.returncode,
                  seconds=seconds, lines=advanced[-12:], stderr=result.stderr[-600:])
    ledger.check(result.returncode == 0 and "PLAYBACK-VERDICT PLAYING" in output,
                 "官方嵌入页在真实 WKWebView（离屏窗口）里加载、播放时间真的前进",
                 exit=result.returncode, seconds=seconds)


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--skip-swift", action="store_true", help="不跑 Swift 业务层")
    parser.add_argument("--skip-player", action="store_true", help="不跑真实播放器")
    parser.add_argument("--ledger", default=str(ROOT / "tmp/e2e-acceptance/ledger.json"))
    parser.add_argument("--only", default="", help="逗号分隔：authority,placement,wish,mcp,swift,player")
    args = parser.parse_args()

    taskd_binary = Path(os.environ.get("TASKD_BIN", DEFAULT_TASKD)).resolve()
    mcpd_binary = Path(os.environ.get("MCPD_BIN", DEFAULT_MCPD)).resolve()
    selected = set(args.only.split(",")) if args.only else set()

    def want(name: str) -> bool:
        return not selected or name in selected

    ledger = Ledger()
    ledger.record("environment", taskd=str(taskd_binary), mcpd=str(mcpd_binary),
                  taskd_exists=taskd_binary.exists(), mcpd_exists=mcpd_binary.exists(),
                  git_rev=subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT,
                                         capture_output=True, text=True).stdout.strip(),
                  python=sys.version.split()[0])
    if not taskd_binary.exists():
        print(f"FAIL: 找不到 gmgn-taskd：{taskd_binary}（先 `cargo build`）")
        return 2

    work = Path(tempfile.mkdtemp(prefix="gmgn-e2e-"))
    taskd = Taskd(taskd_binary, work / "authority")
    exit_code = 0
    try:
        taskd.start()
        ledger.record("process", name="gmgn-taskd", pid=taskd.process.pid,
                      socket=str(taskd.socket_path))
        ctx = run_authority_layer(ledger, taskd, work)
        if want("placement"):
            run_placement_layer(ledger, taskd, ctx)
        if want("wish"):
            run_wish_layer(ledger, taskd, ctx)
        if want("mcp"):
            run_mcp_layer(ledger, taskd, mcpd_binary, work)
        ctx["provider"].close()
    finally:
        taskd.stop()

    if want("swift") and not args.skip_swift:
        run_swift_layer(ledger, taskd_binary, work)
    if want("player") and not args.skip_player:
        run_player_layer(ledger)

    ledger_path = Path(args.ledger)
    ledger_path.parent.mkdir(parents=True, exist_ok=True)
    ledger_path.write_text(json.dumps({
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "role": "end-to-end-acceptance-ledger",
        "assertions": ledger.assertions,
        "failures": ledger.failures,
        "entries": ledger.entries,
    }, ensure_ascii=False, indent=2))

    print()
    print(f"E2E 断言 {ledger.assertions} 条，失败 {ledger.failures} 条；账本 {ledger_path}")
    exit_code = 0 if ledger.failures == 0 else 1
    print(f"E2E_EXIT={exit_code}")
    return exit_code


if __name__ == "__main__":
    sys.exit(main())

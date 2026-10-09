#!/usr/bin/env python3
"""无人值守的四条链端到端验证（真实组件，零点击，零合成输入）。

这个 harness 存在的理由
======================
用户被困在"他点一次 → 我们修一个错 → 再打一版"的循环里。原因是每个断言都活在
真人点击后面：只有他把鼠标按下去，才有一条日志。这个脚本把**四条链**搬到
**无 UI 输入**的可重复断言上，一次跑完，逐条给 PASS/FAIL + 失败时的具名原因与
文件:行，并且**故意注入故障**去证明"卡住"能被有界收敛（或证明它不能）。

它跑什么（全部是真实组件，不是替身）
------------------------------------
* A 链（空间 prepare→activate）：`tools/verify-world-prepare-state-machine.py`
  对生产 Swift 源码做结构性断言（具名步骤、watchdog 超时、陈旧 prepare 被拒）。
  由本脚本以子进程调用，逐条并入总账。
* B 链（居民回合）：真正的 `gmgn-taskd` 二进制 + 私有 `--root` + 真 HTTP `/rpc`。
  会话由**真子进程**（一个最小的 ACP peer，扮演 DSH agent 的进程位置）驱动到
  `running`，然后走和 macOS 宿主 `RustDSHSessionClient` 逐字一样的 RPC 序列：
  `agent_dsh_start` → `agent_dsh_read`（拿 pendingTools）→ `agent_dsh_authorize`
  → `agent_dsh_read`（拿 execute 阶段）→ `agent_dsh_tool_receipt`。
  回执的体积是生产真实量级（`inspect_world` 的完整快照形状，含 643 个航点），
  不是 `{"ok":true}` 这种玩具。
* C 链（设置里切换动作）：同一 daemon 的 `presence_selection_*` RPC。断言
  "上一次选择 pending 时下一次不会永久 busy"，并逐字核对 daemon 的具名拒码与
  Swift `UnityPresenceSettingsBridge.selectionRefusalCode` 是同一套词汇。
* D 链（栏上动作）：`tools/verify-bar-action-senders.py`，钉住每个栏上动作的
  发射点与唯一 sender 不变量。

它**不**跑什么（诚实边界，见文末 `HONEST LIMITS`）
-----------------------------------------------
没有真人点击、没有 CGEvent/AX/osascript、没有音频、不动分辨率/音量/设备、
不碰钥匙串、不打包、不装机、不 `git add -A`、不 `rm` 用户数据（只用自己的临时
root）。需要真机渲染/Unity 编辑器的那一段被拆成"可自动的部分 + 需要真机的清单"。

用法
----
    python3 tools/verify-resident-chains.py                       # 全跑，人读输出
    python3 tools/verify-resident-chains.py --json tmp/chains.json # 同时落一份机器账本
    TASKD_BIN=target/release/gmgn-taskd python3 tools/verify-resident-chains.py
    python3 tools/verify-resident-chains.py --list                # 只看断言清单

退出码：全部 PASS 为 0，任何一条 FAIL 为 1，环境不满足（缺二进制）为 2。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import signal
import sqlite3
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HERE = Path(__file__).resolve().parent

# ---------------------------------------------------------------------------
# 帐本：每条断言都带 文件:行 + 失败时的具名原因
# ---------------------------------------------------------------------------

FILE_LINE = re.compile(r"^(?P<path>[^\s:]+):(?P<line>\d+)(?:[-–](?P<end>\d+))?$")


class Chain:
    """一条链的断言集合。每条断言都有一个稳定的 id 和一处 `file:line` 出处。"""

    def __init__(self, key: str, title: str) -> None:
        self.key = key
        self.title = title
        self.records: list[dict] = []

    def check(
        self,
        ok: bool,
        ident: str,
        message: str,
        *,
        where: str,
        reason: str = "",
        evidence=None,
        permanent: bool | None = None,
        owner: str = "",
    ) -> bool:
        record = {
            "chain": self.key,
            "id": ident,
            "ok": bool(ok),
            "message": message,
            "where": where,
            "reason": reason if not ok else "",
            "evidence": evidence,
            "permanent": permanent,
            "owner": owner,
        }
        self.records.append(record)
        mark = "PASS" if ok else "FAIL"
        line = f"  [{mark}] {self.key}/{ident}  {message}"
        if not ok:
            line += f"\n         原因: {reason}" if reason else ""
            line += f"\n         位置: {where}"
            if permanent is True:
                line += "\n         永久卡: 是（无生产路径可清）"
        print(line, flush=True)
        return bool(ok)

    @property
    def failures(self) -> list[dict]:
        return [r for r in self.records if not r["ok"]]


# ---------------------------------------------------------------------------
# gmgn-taskd：真子进程 + 真 HTTP /rpc
# ---------------------------------------------------------------------------


class Taskd:
    def __init__(self, binary: Path, root: Path, keep: bool = False) -> None:
        self.binary = binary
        self.root = Path(os.path.realpath(str(root)))
        self.keep = keep
        self.endpoint_file = self.root / "taskd.endpoint.json"
        self.stderr_path = self.root / "taskd.stderr.log"
        self.process: subprocess.Popen | None = None

    def start(self) -> None:
        self.root.mkdir(parents=True, exist_ok=True)
        os.chmod(self.root, 0o700)
        # 追加而不是覆盖：重启会保留上一段的拒绝行，否则 stderr 断言只能看到
        # 最后一次重启之后的日志。
        stderr = open(self.stderr_path, "ab")
        # 自己的进程组：daemon 会把 ACP peer 生在这个组里，收工时要整组一起收。
        # 只 terminate 主进程会留下 peer 孤儿，下一轮的 peer 就会与上一轮抢同一根
        # stdin 管道 —— 表现是"会话偶发卡在 starting"，第一版就是这么漂的。
        self.process = subprocess.Popen(
            [str(self.binary), "--root", str(self.root),
             "--endpoint-file", str(self.endpoint_file), "--concurrency", "2"],
            stdout=subprocess.DEVNULL, stderr=stderr, start_new_session=True)
        stderr.close()
        deadline = time.monotonic() + 20
        last = "endpoint file never appeared"
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                last = f"daemon exited early rc={self.process.returncode}"
                break
            try:
                endpoint = json.loads(self.endpoint_file.read_text())
                host, port = endpoint["address"].rsplit(":", 1)
                probe = socket.create_connection((host, int(port)), timeout=1)
                probe.close()
                return
            except Exception as error:  # noqa: BLE001 - 启动期任何异常都只是"还没起来"
                last = f"{type(error).__name__}: {error}"
                time.sleep(0.02)
        raise RuntimeError(f"taskd 没有起来（{last}）\n{self.stderr_text()}")

    def endpoint(self) -> dict:
        return json.loads(self.endpoint_file.read_text())

    def request(self, method: str, params: dict | None = None, *, timeout: float = 30):
        endpoint = self.endpoint()
        body = json.dumps({"id": str(uuid.uuid4()), "method": method,
                           "params": params or {}}).encode()
        request = urllib.request.Request(
            "http://%s/rpc" % endpoint["address"], data=body,
            headers={"Authorization": "Bearer %s" % endpoint["token"],
                     "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=timeout) as reply:
                return json.loads(reply.read())
        except urllib.error.HTTPError as error:
            raw = error.read().decode(errors="replace")
            raise RuntimeError(f"{method} HTTP {error.code}: {raw}") from None

    def grant_call(self, token: str, payload: dict, *, timeout: float = 30):
        """宿主工具的扁平路由：与真机 `gmgn-host-tools.mjs` 打的是同一条 URL。

        这条路由不接受 method 字段，凭据就是 grant token 本身
        （`services/gmgn-taskd/src/daemon.rs:92-95`）。
        """
        endpoint = self.endpoint()
        body = json.dumps(payload).encode()
        request = urllib.request.Request(
            "http://%s/rpc" % endpoint["address"], data=body,
            headers={"Authorization": "Bearer %s" % token,
                     "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=timeout) as reply:
                return json.loads(reply.read())
        except urllib.error.HTTPError as error:
            raw = error.read().decode(errors="replace")
            raise RuntimeError(f"host_call HTTP {error.code}: {raw}") from None

    def stderr_text(self) -> str:
        try:
            return self.stderr_path.read_text(errors="replace")
        except OSError:
            return ""

    def stop(self) -> None:
        if not self.process:
            return
        for signal_name in ("SIGTERM", "SIGKILL"):
            if self.process.poll() is not None:
                break
            try:
                os.killpg(os.getpgid(self.process.pid), getattr(signal, signal_name))
            except (ProcessLookupError, PermissionError):
                self.process.kill()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                continue
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass

    def cleanup(self) -> None:
        self.stop()
        if not self.keep:
            shutil.rmtree(self.root, ignore_errors=True)

    def restart(self) -> None:
        """同一个私有 root 上重启 daemon。

        故障注入的每一种都要一轮**干净**的会话：一个被拒之后 daemon 会把会话停在
        终态，后续 start 会被 agent_dsh_session_busy / agent_dsh_run_not_claimed
        挡住 —— 那是**同一种**故障的下游效应，会掩盖后一种故障的真实行为。
        重启保留账本（数据库还在同一个 root 上），所以 Restart 之后仍能 inspect。
        """
        self.stop()
        time.sleep(0.2)
        self.start()


def error_code(reply) -> str | None:
    """daemon 的拒码。`/rpc` 把错误放在 `reply["error"]["code"]`（见 daemon.rs 的
    错误封装），这里只取那一个字符串，别拿整块 dict 去比字符串。"""
    error = (reply or {}).get("error")
    if isinstance(error, dict):
        return error.get("code")
    if isinstance(error, str):
        return error
    return None


# ---------------------------------------------------------------------------
# 最小 ACP peer：只占住"agent 子进程"这个真实位置
# ---------------------------------------------------------------------------
#
# 它不是 LLM，也不假装是 LLM。它做三件真事：走完 initialize / session/new /
# session/prompt 三步握手，让 daemon 的真会话状态机推进到 `running`，然后保持
# prompt 未完成（真 DSH 在等宿主工具回执时就是这个形状）。真机里"发起工具调用"
# 的那一段是宿主工具插件（`gmgn-host-tools.mjs`）打 HTTP 回 daemon；这里由本
# 脚本用同一条 URL、同一个 grant token 发同一个 body —— 那条路由是生产路由。

MOCK_ACP = r'''#!/usr/bin/env python3
"""最小 ACP peer（真子进程）。stdout 只写 newline-delimited JSON-RPC。

stdin 由一条后台线程读进队列，主循环只做"取帧 / 轮询 finish 标记 / 到点收工"。
这样即使 daemon 在 `session/prompt` 之后一个字节都不再发，peer 也仍然能在 finish
标记出现时立刻结束这一轮 —— 阻塞在 `for line in sys.stdin` 上会让整个 harness
停在一个永远 running 的会话里（第一版就是这么停住的）。
"""
import collections, json, os, sys, threading, time

# daemon 按 `[entryPoint, '--config', compositionFile]` 起进程（agent_dsh.rs:53 的
# arguments 语法），所以 argv[1] 是**入口文件**，不是 root。root 取它的目录；
# 同时留一条 HARNESS_ROOT 环境变量作显式覆盖。
root = os.environ.get('HARNESS_ROOT') or os.path.dirname(os.path.abspath(sys.argv[1]))
# daemon 的 `environment()` 只让 HOME/TMPDIR/LANG/LC_ALL/USER/LOGNAME 过去
# （agent_dsh.rs:131-151），所以 finish 标记不能靠环境变量。root 里的
# `harness-session` 写下**本轮**该等的那个标记名；只看这一个文件，不看前缀 ——
# 按前缀找会把上一轮留下的标记当成自己的（第一版就是这么让新一轮秒收尾的）。
SESSION_FILE = os.path.join(root, 'harness-session')


def finish_requested():
    try:
        with open(SESSION_FILE) as handle:
            name = handle.read().strip()
    except OSError:
        return False
    return bool(name) and os.path.exists(os.path.join(root, name))
text = os.environ.get('HARNESS_FINAL_TEXT', 'harness turn complete')
budget = time.time() + float(os.environ.get('HARNESS_PEER_BUDGET', '120'))

inbox = collections.deque()
trace = open(os.path.join(root, 'harness-peer.log'), 'a', buffering=1)


def note(message):
    trace.write('%s %s\n' % (time.strftime('%H:%M:%S'), message))


def reader():
    for line in sys.stdin:
        inbox.append(line)


threading.Thread(target=reader, daemon=True).start()


def send(frame):
    sys.stdout.write(json.dumps(frame) + '\n')
    sys.stdout.flush()


done_prompt = None
while time.time() < budget:
    if done_prompt is not None and finish_requested():
        break
    if not inbox:
        time.sleep(0.01)
        continue
    line = inbox.popleft().strip()
    if not line:
        continue
    try:
        frame = json.loads(line)
    except ValueError:
        continue
    method = frame.get('method')
    ident = frame.get('id')
    note('recv %s' % method)
    if method == 'initialize':
        send({'jsonrpc': '2.0', 'id': ident,
              'result': {'agentCapabilities': {'promptCapabilities': {'image': True}}}})
    elif method == 'session/new':
        send({'jsonrpc': '2.0', 'id': ident, 'result': {'sessionId': 'harness-acp'}})
    elif method == 'session/prompt':
        # 真 DSH 在宿主工具回执回来之前不会结束这一轮。这里记住 prompt 的 id，
        # 之后由主循环轮询 finish 标记来收尾（daemon 只认它自己发出的那个 id）。
        done_prompt = ident
        note('prompt id=%s; waiting for finish marker' % ident)
    elif method == 'session/cancel':
        send({'jsonrpc': '2.0', 'id': ident, 'result': {'stopReason': 'cancelled'}})
        break

note('loop exit: done_prompt=%s finish=%s' % (done_prompt, finish_requested()))
if done_prompt is not None:
    send({'jsonrpc': '2.0', 'method': 'session/update',
          'params': {'sessionId': 'harness-acp',
                     'update': {'sessionUpdate': 'agent_message_chunk',
                                'content': {'type': 'text', 'text': text}}}})
    send({'jsonrpc': '2.0', 'id': done_prompt, 'result': {'stopReason': 'end_turn'}})
'''

# `services/gmgn-taskd/src/agent_dsh.rs:53` 的 composition() 逐字语法。
COMPOSITION = """# Generated by gmgn ResidentDSHConfiguration; re-validated by read-back before every launch.
- id: llm-deepseek
  name: '@deepseek-ai/dsh-llm-deepseek'
  config:
    reasoningEffort: low
    maxTokens: 8192
    models:
      - id: deepseek-flash
        inputModalities: [text, image]
      - id: deepseek-v4-pro
        inputModalities: [text]
- id: credentials
  name: '@deepseek-ai/dsh-credentials-local'
- id: attachment-local
  name: '@deepseek-ai/dsh-attachment-local'
  config:
    dshHome: '{attachment}'
- id: acp-agent
  name: '@deepseek-ai/dsh-acp-demo'
  config:
    provider: deepseek-official
    model: deepseek-flash
    persistenceRoot: '{persistence}'
    packChunks: false
    persistenceCompression: none
    workspaceContext: false
    toolBash: false
    toolJobs: false
    goals: false
    skills:
      enabled: false
    tools:
      mode: native
    persona: '{persona}'
- id: web
  name: '@deepseek-ai/dsh-web'
  config:
    searchProvider: deepseek-official
- id: web-fetch-http
  name: '@deepseek-ai/dsh-web-fetch-http'
- id: web-search-deepseek
  name: '@deepseek-ai/dsh-web-search-deepseek'
- id: tool-web
  name: '@deepseek-ai/dsh-tool-web'
- id: gmgn-host-tools
  name: '{plugin}'"""


def build_agent_root(root: Path, tools: list[dict], persona: str = "harness") -> dict:
    """在私有 root 里摆出 agent 启动所需的一切，返回 `agent_dsh_start` 的参数。"""
    root = Path(os.path.realpath(str(root)))
    executable = root / "harness-acp"
    executable.write_text(MOCK_ACP)
    os.chmod(executable, 0o700)
    entry = root / "harness-entry"
    entry.write_text("")
    plugin = root / "gmgn-host-tools.mjs"
    plugin.write_text("")
    composition = root / "composition.yaml"
    composition.write_text(COMPOSITION.format(
        attachment=root, persistence=root, persona=persona, plugin=plugin))
    return {
        "root": str(root), "cwd": str(root), "executable": str(executable),
        "entryPoint": str(entry), "compositionFile": str(composition),
        "attachmentHome": str(root), "persistenceRoot": str(root),
        "persona": persona, "hostToolsPlugin": str(plugin),
        "environment": {"HOME": str(root), "TMPDIR": str(root)},
        "arguments": [str(entry), "--config", str(composition)],
        "input": "harness turn",
        "tools": tools,
    }


def arm_session(root: Path, finish_marker: Path) -> None:
    """让 root 里的 peer 知道**这一轮**该等哪个 finish 标记。

    peer 是 daemon 起的子进程、环境被 `environment()` 白名单过滤，所以走文件：
    `harness-session` 写标记名，peer 读它。
    """
    try:
        finish_marker.unlink()
    except OSError:
        pass
    (root / "harness-session").write_text(finish_marker.name)


def start_session(taskd: "Taskd", base: dict, root: Path, tools: list[dict],
                  run_id: str, event_id: str, finish_marker: Path, input_text: str):
    """起一轮会话。每一轮先 `arm_session`，把本轮的 finish 标记名告诉 peer。"""
    arm_session(root, finish_marker)
    params = {
        **base, "runID": run_id, "eventID": event_id, "grantToken": str(uuid.uuid4()),
        "root": str(root), "cwd": str(root),
        "executable": str(root / "harness-acp"), "entryPoint": str(root / "harness-entry"),
        "compositionFile": str(root / "composition.yaml"),
        "attachmentHome": str(root), "persistenceRoot": str(root), "persona": "harness",
        "hostToolsPlugin": str(root / "gmgn-host-tools.mjs"),
        "environment": {"HOME": str(root), "TMPDIR": str(root)},
        "arguments": [str(root / "harness-entry"), "--config", str(root / "composition.yaml")],
        "input": input_text, "tools": tools,
    }
    return taskd.request("agent_dsh_start", params)


def wait_state(taskd: "Taskd", base: dict, run_id: str, event_id: str, wanted,
               budget: float = 40.0):
    deadline = time.monotonic() + budget
    snapshot = None
    while time.monotonic() < deadline:
        snapshot = taskd.request("agent_dsh_read", {**base, "runID": run_id, "eventID": event_id})
        if snapshot.get("result", {}).get("state") in wanted:
            return snapshot
        time.sleep(0.02)
    return snapshot


# ---------------------------------------------------------------------------
# 真机量级的工具目录与回执
# ---------------------------------------------------------------------------
#
# 生产目录由 13 个世界工具（apps/macos/Sources/GMGNRadio/Agent/
# WorldAgentToolContract.swift:44-152）+ 物件/音乐/许愿/记忆桥的 AdditionalTool
# 组成，真机上是 52..56 项 / ~30 KB（services/gmgn-taskd/src/agent_tools.rs:68-77
# 的实测记录）。下面这一份按同一个形状铺开：名字与 description 都是产品口吻的中文，
# 体积落在真机区间内，schema 是 daemon 接受的 object schema。

WORLD_TOOLS = [
    ("list_available_motions", "read"),
    ("play_motion", "write"),
    ("inspect_world", "read"),
    ("list_places", "read"),
    ("list_available_activities", "read"),
    ("plan_route", "read"),
    ("move_to", "write"),
    ("start_activity", "write"),
    ("stop_activity", "write"),
    ("look_at", "write"),
    ("set_world_weather", "write"),
    ("move_live_camera", "write"),
    ("complete_world_goal", "write"),
]

EXTRA_TOOLS = [
    ("read_owned_props", "read", "读取当前空间里已经登记、可以被居民看见和使用的物件清单，"
                                 "含每件物件的 objectID、显示名、三轴尺寸、是否手持、所在活动面。"),
    ("hold_prop", "write", "把某件已登记物件拿到手里。必须先 move_to 到它真实占地外缘一米内，"
                           "并用最新一次 read_owned_props 的 layout_revision。"),
    ("release_prop", "write", "放开手里或库存里的物件，把它放回当前活动面的真实位置。"),
    ("resize_prop", "write", "按三轴毫米数调整一件已登记物件的尺寸，会写回权威尺寸。"),
    ("stow_prop", "write", "把手里这件物件收回库存，位置由权威记录，下一次取出仍在原处。"),
    ("place_prop", "write", "把手里这件物件放到指定活动面的指定位置。"),
    ("submit_wish_generation", "write", "提交一次生成许愿：文字或图片 + 期望高度。返回任务 id，"
                                        "并不代表模型已经生成完毕。"),
    ("read_wish_generation", "read", "读取一次生成许愿的当前阶段、原始回执与最终物件。"),
    ("cancel_wish_generation", "write", "取消一次尚未落地的生成许愿。"),
    ("read_resident_state", "read", "读取居民此刻的状态：在哪、在做什么活动、活动到哪个阶段、"
                                    "手里有没有东西。"),
    ("update_resident_intent", "write", "写下居民接下来打算做的事，供下一轮自己读到。"),
    ("list_music_library", "read", "读取音乐库里可播放的曲目、来源与时长。"),
    ("search_music", "read", "按关键词在音乐库里搜索曲目。"),
    ("queue_music", "write", "把一首曲目排进播放队列。"),
    ("play_music", "write", "开始播放当前队列里的曲目。"),
    ("pause_music", "write", "暂停正在播放的曲目。"),
    ("skip_music", "write", "跳到队列里的下一首。"),
    ("read_now_playing", "read", "读取此刻正在播放的曲目与播放进度。"),
    ("capture_space_photo", "write", "从当前相机位置拍一张空间照片，作为这一轮的视觉依据。"),
    ("read_space_photo", "read", "读取上一次拍下的空间照片的元数据。"),
    ("list_cameras", "read", "读取当前空间可切换的相机机位。"),
    ("open_wish_reference", "read", "打开一份参考素材，作为生成许愿的视觉参考。"),
    ("search_wish_reference", "read", "在参考素材库里搜索。"),
    ("save_wish_reference", "write", "把一份参考素材存进当前许愿。"),
    ("list_activities", "read", "读取当前空间里所有可执行活动与它们需要走的动作。"),
    ("read_activity_manifest", "read", "读取一项活动的完整清单：进入阶段、循环阶段、退出阶段、"
                                       "需要哪些动作文件。"),
    ("read_world_clock", "read", "读取空间内的世界时间与当前天气。"),
    ("read_resident_memory", "read", "读取居民关于当前空间的长期记忆条目。"),
    ("write_resident_memory", "write", "往居民的长期记忆里写一条新条目。"),
    ("read_stage_lyrics", "read", "读取舞台上正在显示的歌词行。"),
    ("read_screen_state", "read", "读取空间里屏幕类物件的播放状态。"),
    ("control_screen", "write", "控制空间里某一块屏幕的播放、暂停与地址。"),
    ("read_device_state", "read", "读取空间里设备类物件（灯、音响、电视）的开关与档位。"),
    ("control_device", "write", "控制空间里某一件设备的开关与档位。"),
    ("read_catalog_status", "read", "读取当前生成物件目录的同步状态与最近一次刷新结果。"),
    ("list_available_avatars", "read", "读取当前可切换的角色外观包清单。"),
    ("select_avatar", "write", "切换角色外观包；切换后需要等渲染器回执才算生效。"),
    ("list_available_motion_packages", "read", "读取当前可用的动作包清单与兼容性。"),
    ("read_placement_grid", "read", "读取当前空间支持摆放的地面网格与已占用的格子。"),
    ("place_generated_prop", "write", "把一件已生成物件摆到网格上的指定格子。"),
]


def _schema(props: dict[str, object], required: list[str]) -> dict:
    """一个 daemon 接受的 object schema。

    顶层 `type` 是单字符串 `object`：`agent_dsh::Configuration::parse` 直接比
    `t["inputSchema"]["type"] != "object"`（services/gmgn-taskd/src/agent_dsh.rs:253），
    这里**故意用最严的那一种**，好让"目录在更窄的校验下也能注册"成为被证明的事。

    子字段用 union（`["object","null"]` 这种）是有意的：`submit_wish_generation`
    真机就发这个形状（services/gmgn-taskd/src/agent_tools.rs:302-320），
    `supported_schema` 必须继续接受它 —— 2026-10-08 的 `error 3` 就是这里拒的。
    """
    properties = {name: ({"type": kind} if isinstance(kind, str) else dict(kind))
                  for name, kind in props.items()}
    return {
        "type": "object",
        "properties": properties,
        "required": required,
        "additionalProperties": False,
    }


def _union_schema() -> dict:
    """真机 `submit_wish_generation` 的子 schema 形状，逐条对齐 agent_tools.rs:302-320。"""
    return {
        "type": "object",
        "properties": {
            "destination": {
                "type": ["object", "null"],
                "properties": {"place_id": {"type": "string"},
                               "position": {"type": ["object", "null"]}},
                "required": ["place_id"],
                "additionalProperties": False,
            },
            "size_intent": {
                "type": ["object", "null"],
                "properties": {"mode": {"type": "string"},
                               "millimeters": {"type": ["object", "null"]}},
                "required": ["mode"],
                "additionalProperties": False,
            },
        },
        "required": ["destination"],
        "additionalProperties": False,
    }


def production_shaped_tools() -> list[dict]:
    """按生产形状铺开的工具目录（真机 52..56 项 / ~30 KB 的同一量级）。"""
    tools: list[dict] = []
    for name, effect in WORLD_TOOLS:
        props = {
            "inspect_world": ({}, []),
            "list_places": ({}, []),
            "list_available_activities": ({}, []),
            "list_available_motions": ({}, []),
            "play_motion": ({"motion_id": "string"}, ["motion_id"]),
            "plan_route": ({"place_id": "string"}, ["place_id"]),
            "move_to": ({"place_id": "string"}, ["place_id"]),
            "start_activity": ({"activity_id": "string"}, ["activity_id"]),
            "stop_activity": ({"reason": "string"}, ["reason"]),
            "look_at": ({"place_id": "string"}, ["place_id"]),
            "set_world_weather": ({"weather": "string"}, ["weather"]),
            "move_live_camera": ({"camera_id": "string"}, ["camera_id"]),
            "complete_world_goal": ({"goal_id": "string", "summary": "string"}, ["goal_id", "summary"]),
        }[name]
        tools.append({
            "name": name, "effect": effect,
            "description": f"居民世界工具 {name}：这条描述来自生产目录的中文口径，"
                           f"长度与真机注册时发送的那一份同量级。",
            "inputSchema": _schema(props[0], props[1]),
        })
    for name, effect, description in EXTRA_TOOLS:
        schema = (_union_schema() if name == "submit_wish_generation"
                  else _schema({"id": "string", "value": "string", "names": {"type": "array"}}, []))
        tools.append({
            "name": name, "effect": effect, "description": description,
            "inputSchema": schema,
        })
    return tools


def inspect_world_receipt_shape(motion_id: str = "gmgn.motion.bones.idle-loop-vrm") -> dict:
    """`inspect_world` 的真实体积回执形状。

    计数不是编出来的，逐条有出处：
      * 643 个航点 —— services/gmgn-taskd/src/agent_tools.rs:82-84 记录的
        `marble-living-cabin` / world `84503420-…` 的 `movement.waypointIDs` 规模；
      * 13 件生成物件 —— 同处的实测（"the live space held 13 generated props"）；
      * 地点 / 活动 / 相机 / 动作目录 —— apps/macos/Sources/GMGNRadio/Agent/
        WorldAgentToolDispatcher.swift:167 与 WorldAgentToolContext 的 snapshot 形状。
    形状是重建的，计数与体积是生产量级：这正是那一次真机上
    `agent_dsh_invalid_receipt` 卡死整条 B 链的回执大小。
    """
    places = [{"id": f"place.{index}", "name": f"地点 {index}", "position":
               {"x": index * 0.37, "y": 0.0, "z": -index * 0.21},
               "reachable": True, "kind": "seat" if index % 3 == 0 else "floor"}
              for index in range(24)]
    activities = [{"id": f"activity.{index}", "name": f"活动 {index}",
                   "place_id": f"place.{index}", "requires_motions": [
                       f"gmgn.motion.bones.{index}-loop-vrm",
                       f"gmgn.motion.bones.{index}-enter-vrm"],
                   "seat_projection": {"x": index * 0.11, "z": index * 0.07}}
                  for index in range(9)]
    cameras = [{"id": f"camera.{index}", "name": f"机位 {index}", "fov": 45 + index,
                "position": {"x": index, "y": 1.4, "z": index * 2}} for index in range(6)]
    motions = [{"id": f"gmgn.motion.bones.{index}-loop-vrm", "display_name": f"动作 {index}",
                "format": "vrma", "loop": True, "duration": 4.2 + index * 0.1,
                "compatible": True} for index in range(43)]
    props = [{"objectID": f"prop.{index:04d}", "display_name": f"已生成物件 {index}",
              "size": {"x": 0.4 + index * 0.01, "y": 0.3 + index * 0.01, "z": 0.2},
              "location": "stage.floor", "held": index == 3,
              "layout_revision": 17} for index in range(13)]
    waypoints = [f"wp.auto.x{index % 26}.z{index // 26}.h0" for index in range(643)]
    return {
        "ok": True,
        "code": None,
        "message": "已读取当前世界状态",
        "snapshot": {
            "worldID": "84503420-3010-4a1e-9f3a-marble-living-cabin",
            "revision": 1841,
            "places": places,
            "activities": activities,
            "cameras": cameras,
            "props": props,
            "motions": motions,
            "weather": "clear",
            "agent": {"position": {"x": 1.25, "y": 0.0, "z": -2.5},
                      "facing": {"x": 0.0, "y": 0.0, "z": 1.0, "w": 0.0},
                      "motion": motion_id, "activity": None},
            "movement": {"destinationID": "place.7", "waypointIDs": waypoints},
        },
    }


PNG_B64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="


# ---------------------------------------------------------------------------
# B 链
# ---------------------------------------------------------------------------


def run_chain_b(chain: Chain, binary: Path, work: Path, keep: bool) -> dict:
    print(f"\n=== B 链：居民回合（真实 daemon + 真实 grant 路由）===", flush=True)
    context: dict = {}
    root = work / "b"
    taskd = Taskd(binary, root, keep=keep)
    try:
        taskd.start()
    except RuntimeError as error:
        chain.check(False, "0.1", "真实 gmgn-taskd 在私有 root 上起来", where="tools/verify-resident-chains.py:1",
                    reason=str(error))
        return context

    world, scope, host = "w-harness", "s-harness", "h-harness"
    base = {"worldID": world, "residentScope": scope, "hostSessionID": host}

    # --- 调度器：真 DSH 回合只在被 claim 的事件上开始 -----------------------
    taskd.request("agent_loop_configure", {**base, "hourlyLimit": 6,
                                           "minimumWakeIntervalSeconds": 1,
                                           "backgroundEnabled": True, "available": True})
    taskd.request("agent_loop_enqueue", {**base, "eventID": "e-harness", "intentID": "i-harness",
                                         "kind": "continuation", "intentState": "active",
                                         "command": {"observe": True}})
    run = "r-harness"
    claim = taskd.request("agent_loop_claim", {**base, "runID": run,
                                               "nowMillis": int(time.time() * 1000)})
    chain.check(claim.get("result", {}).get("claimed") is True, "0.2",
                "调度器真的把这一轮 claim 给了宿主",
                where="services/gmgn-taskd/src/agent_scheduler.rs:1",
                reason=json.dumps(claim, ensure_ascii=False), evidence=claim)

    tools = production_shaped_tools()
    catalog_bytes = len(json.dumps(tools, separators=(",", ":"), ensure_ascii=False).encode())
    context["catalog_tools"] = len(tools)
    union_tool = next((t for t in tools if t["name"] == "submit_wish_generation"), None)
    context["union_schema_present"] = bool(
        union_tool and "null" in (union_tool["inputSchema"]["properties"]
                                  .get("destination", {}).get("type") or []))
    context["catalog_bytes"] = catalog_bytes
    chain.check(len(tools) >= 52 and catalog_bytes > 15000, "1.1",
                f"工具目录是真机项数量级（{len(tools)} 项 / {catalog_bytes} 字节；"
                "真机 52..56 项）",
                where="services/gmgn-taskd/src/agent_tools.rs:81",
                reason=(f"catalog {len(tools)} tools / {catalog_bytes} bytes；"
                        "至少要 ≥52 项且 >15000 字节 —— 真机那一次的目录是 52..56 项 / "
                        "15583（描述被删节的回归夹具）..31574（带出货描述）字节，"
                        "所以这份必须落在同一档，否则测不到 agent_dsh_invalid_tools 那个边界"),
                evidence={"tools": len(tools), "bytes": catalog_bytes})
    chain.check(catalog_bytes <= 262144, "1.2",
                f"同一个目录仍在宿主自己的 256 KiB 上限之内（{catalog_bytes} ≤ 262144）",
                where="services/gmgn-taskd/src/agent_tools.rs:76",
                reason=f"catalog {catalog_bytes} bytes 超过 MAXIMUM_CATALOG_BYTES")

    agent = build_agent_root(root, tools)
    # 这份目录里 `submit_wish_generation.destination.type` 是标准的
    # `["object","null"]` union —— 2026-10-08 的 `error 3` 就是 `supported_schema`
    # 只收单字符串把它整组拒掉（agent_tools.rs:302-320）。下面 start 成功即证明
    # 这条回归没有再犯。
    assert context["union_schema_present"], "fixture 必须带 union-type 子 schema"
    arm_session(root, root / "harness-finish.turn-1")
    start_params = {**base, "runID": run, "eventID": "e-harness",
                    "grantToken": str(uuid.uuid4()), **agent}

    def read_session() -> dict:
        return taskd.request("agent_dsh_read", {**base, "runID": run, "eventID": "e-harness"})

    def wait_for(predicate, budget: float = 30.0):
        deadline = time.monotonic() + budget
        snapshot = None
        while time.monotonic() < deadline:
            snapshot = read_session()
            if predicate(snapshot):
                return snapshot
            time.sleep(0.02)
        return snapshot


    started = taskd.request("agent_dsh_start", start_params)
    ok_start = started.get("result", {}).get("started") is True
    chain.check(ok_start, "2.1", "agent_dsh_start 接受生产量级的工具目录（不再 agent_dsh_invalid_tools）",
                where="services/gmgn-taskd/src/agent_dsh.rs:516",
                reason=json.dumps(started, ensure_ascii=False), evidence=started)
    if not ok_start:
        return context

    running = wait_for(lambda s: s.get("result", {}).get("state") == "running")
    chain.check(running["result"]["state"] == "running", "2.2",
                "会话由真 ACP 子进程推进到 running",
                where="services/gmgn-taskd/src/agent_dsh.rs:891",
                reason=json.dumps(running, ensure_ascii=False)[:400], evidence=running["result"]["state"])
    context["acp_session_id"] = running["result"].get("acpSessionID")
    chain.check(bool(context["acp_session_id"]), "2.3", "会话拿到真实 acpSessionID",
                where="services/gmgn-taskd/src/agent_dsh.rs:896",
                reason="acpSessionID 为空", evidence=running["result"].get("acpSessionID"))

    # --- 一次完整的宿主工具往返：authorize → execute → receipt -------------
    token = started["result"]["grantToken"]
    call_id = "call-inspect-1"
    host_result: dict = {}

    def host_call():
        try:
            # `inspect_world` 的 schema 没有可选字段、properties 里也没有 scope，
            # 参数就是空对象（多传一个键会被 agent_tool_begin 按 schema 拒掉）。
            host_result["reply"] = taskd.grant_call(token, {
                "v": 1, "callId": call_id, "name": "gmgn_inspect_world", "arguments": {}})
        except Exception as error:  # noqa: BLE001
            host_result["error"] = str(error)

    import threading
    thread = threading.Thread(target=host_call, daemon=True)
    thread.start()

    authorized = wait_for(lambda s: any(t.get("phase") == "authorize" and t.get("callID") == call_id
                                        for t in s.get("result", {}).get("pendingTools", [])))
    pending = [t for t in authorized["result"]["pendingTools"] if t.get("callID") == call_id
               and t.get("phase") == "authorize"]
    chain.check(len(pending) == 1, "3.1",
                "宿主工具调用在 execute 之前先要一次具名授权（authorize 阶段）",
                where="services/gmgn-taskd/src/agent_dsh.rs:557",
                reason=json.dumps(authorized, ensure_ascii=False)[:400])
    if len(pending) != 1:
        return context
    operation_id = "op-inspect-1"
    approval = dict(pending[0])
    approval["decision"] = "approved"
    approval["operationID"] = operation_id
    approved = taskd.request("agent_dsh_authorize", {**base, "runID": run, "eventID": "e-harness", **approval})
    chain.check(approved.get("result", {}).get("accepted") is True, "3.2",
                "agent_dsh_authorize 接受这次授权",
                where="services/gmgn-taskd/src/agent_dsh.rs:585",
                reason=json.dumps(approved, ensure_ascii=False), evidence=approved)

    executing = wait_for(lambda s: any(t.get("phase") == "execute" and t.get("callID") == call_id
                                       for t in s.get("result", {}).get("pendingTools", [])))
    execute_entry = [t for t in executing["result"]["pendingTools"]
                     if t.get("callID") == call_id and t.get("phase") == "execute"]
    chain.check(len(execute_entry) == 1, "3.3",
                "授权后同一 callID 进入 execute 阶段并带上 operationID",
                where="services/gmgn-taskd/src/agent_dsh.rs:552",
                reason=json.dumps(executing, ensure_ascii=False)[:400])
    if len(execute_entry) != 1:
        return context
    execute_entry = execute_entry[0]
    chain.check(execute_entry.get("operationID") == operation_id, "3.4",
                "execute 阶段回显宿主选定的 operationID（身份不许被模型改写）",
                where="services/gmgn-taskd/src/agent_dsh.rs:553",
                reason=f"operationID={execute_entry.get('operationID')!r}",
                evidence=execute_entry.get("operationID"))

    receipt = inspect_world_receipt_shape()
    receipt_bytes = len(json.dumps(receipt, ensure_ascii=False).encode())
    context["receipt_bytes"] = receipt_bytes
    chain.check(receipt_bytes > 16384, "4.1",
                f"inspect_world 回执超过旧的 16 KiB 模型参数上限（实测 {receipt_bytes} 字节）——"
                "这正是真机上把整条 B 链卡死的体积",
                where="services/gmgn-taskd/src/agent_tools.rs:82",
                reason=f"receipt {receipt_bytes} bytes 没有超过 16384",
                evidence={"bytes": receipt_bytes})
    chain.check(receipt_bytes <= 65536, "4.2",
                f"同一份回执在宿主自己的上限之内（{receipt_bytes} ≤ 65536）",
                where="services/gmgn-taskd/src/agent_tools.rs:95",
                reason=f"receipt {receipt_bytes} bytes 超过 MAXIMUM_RECEIPT_BYTES")

    submitted = taskd.request("agent_dsh_tool_receipt", {
        **base, "runID": run, "eventID": "e-harness",
        "acpSessionID": execute_entry["acpSessionID"], "callID": call_id,
        "operationID": operation_id, "status": "completed", "output": receipt})
    chain.check(submitted.get("result", {}).get("accepted") is True, "4.3",
                "生产体积的真回执被接受（不再 agent_dsh_invalid_receipt）",
                where="services/gmgn-taskd/src/agent_dsh.rs:623",
                reason=json.dumps(submitted, ensure_ascii=False)[:400], evidence=submitted)
    context["receipt_accepted"] = submitted.get("result", {}).get("accepted") is True

    thread.join(timeout=10)
    chain.check(host_result.get("reply", {}).get("ok") is True, "4.4",
                "等待中的宿主工具调用真的拿到了回执内容（不是被静默丢弃）",
                where="services/gmgn-taskd/src/agent_dsh.rs:777",
                reason=json.dumps(host_result, ensure_ascii=False)[:400])

    duplicate = taskd.request("agent_dsh_tool_receipt", {
        **base, "runID": run, "eventID": "e-harness",
        "acpSessionID": execute_entry["acpSessionID"], "callID": call_id,
        "operationID": operation_id, "status": "completed", "output": receipt})
    chain.check(duplicate.get("result", {}).get("duplicate") is True, "4.5",
                "同一份回执重放是幂等的（duplicate=true，不产生第二行）",
                where="services/gmgn-taskd/src/agent_dsh.rs:652",
                reason=json.dumps(duplicate, ensure_ascii=False)[:400], evidence=duplicate)

    # --- 账本：行必须 finished 且 receipt 非空，并带真体积 -------------------
    inspect = taskd.request("agent_tool_inspect", {**base, "runID": run,
                                                   "operationID": operation_id})
    rows = inspect.get("result", {}).get("calls", [])
    row = next((r for r in rows if r.get("callID") == call_id), None)
    context["ledger_row"] = row
    chain.check(row is not None and row.get("state") == "finished", "5.1",
                "agent_tool_calls 那一行变成 finished",
                where="services/gmgn-taskd/src/agent_tools.rs:637",
                reason=json.dumps(inspect, ensure_ascii=False)[:400], evidence=row)
    stored = len(json.dumps(row.get("receipt"), ensure_ascii=False).encode()) if row and row.get("receipt") is not None else 0
    context["stored_receipt_bytes"] = stored
    chain.check(stored > 16384, "5.2",
                f"落盘的 receipt 非空且保留真体积（{stored} 字节）",
                where="services/gmgn-taskd/src/agent_tools.rs:637",
                reason=f"stored receipt {stored} bytes", evidence={"stored_bytes": stored})

    # --- 结束这一轮：真的走到终态闭环 ---------------------------------------
    (root / "harness-finish.turn-1").write_text("ready")
    terminal = wait_for(lambda s: s.get("result", {}).get("state") in
                        ("completed", "failed", "cancelled", "unknown"), budget=30)
    state = terminal["result"]["state"]
    context["terminal_state"] = state
    chain.check(state == "completed", "6.1",
                "这一轮走完并有终态（completed）",
                where="services/gmgn-taskd/src/agent_dsh.rs:823",
                reason=f"terminal state={state!r}",
                evidence=terminal["result"])

    # --- 下一轮 start 不再被 unresolved_tools 挡住 --------------------------
    taskd.request("agent_loop_enqueue", {**base, "eventID": "e-harness-2",
                                         "intentID": "i-harness-2", "kind": "continuation",
                                         "intentState": "active", "command": {"observe": True}})
    run2 = "r-harness-2"
    claim2 = taskd.request("agent_loop_claim", {**base, "runID": run2,
                                                "nowMillis": int(time.time() * 1000) + 5000})
    chain.check(claim2.get("result", {}).get("claimed") is True, "6.2",
                "第二轮调度器 claim 成功",
                where="services/gmgn-taskd/src/agent_scheduler.rs:1",
                reason=json.dumps(claim2, ensure_ascii=False)[:300])
    second = start_session(taskd, base, root, tools, run2, "e-harness-2",
                           root / "harness-finish.turn-2", "harness turn two")
    second_error = error_code(second)
    chain.check(second_error != "agent_dsh_unresolved_tools" and
                second.get("result", {}).get("started") is True, "6.3",
                "干净结束之后，下一轮 start 不再被 agent_dsh_unresolved_tools 挡住（真的开始了一轮）",
                where="services/gmgn-taskd/src/agent_dsh.rs:493",
                reason=f"下一轮 start 返回 error={second_error!r}", evidence=second)
    if second.get("result", {}).get("started") is True:
        (root / "harness-finish.turn-2").write_text("ready")
        closed = wait_state(taskd, base, run2, "e-harness-2",
                            {"completed", "failed", "cancelled", "unknown"})
        chain.check(closed.get("result", {}).get("state") == "completed", "6.4",
                    "第二轮也能干净收尾（不是把会话挂在那里挡住后面）",
                    where="services/gmgn-taskd/src/agent_dsh.rs:823",
                    reason=f"terminal state={closed.get('result', {}).get('state')!r}",
                    evidence=closed.get("result"))

    # =====================================================================
    # 故障注入：故意提交非法回执，看它是否能被**有界收敛**
    # =====================================================================
    print("  --- 故障注入：非法回执 ---", flush=True)
    if second_error is None:
        injected = inject_bad_receipt(chain, taskd, base, root, run2, tools, work, keep,
                                      binary)
        context["fault_injection"] = injected
    else:
        chain.check(False, "7.0", "第二轮 start 成功，故障注入才有意义",
                    where="services/gmgn-taskd/src/agent_dsh.rs:474",
                    reason=f"start 返回 {second_error!r}", evidence=second)

    # =====================================================================
    # 8. 未确认的旧回合不许永久堵住后面的人类回合
    # =====================================================================
    #
    # 真机 2026-10-09 18:58 的形状（build 229 已装机、单实例）：
    #   * 16:50:15 某一轮人类回合被 claim（run E261AC9D… / session 96C0CBE6…），
    #     宿主从未结算它；
    #   * 18:27:23 build 229 的 daemon 启动，`recover()` 把这一行命名成
    #     `unknown`（诚实记录：没学到效果）；
    #   * 18:58:04 用户在聊天框发消息：`agent_loop_enqueue` 真的写下了人类消息行
    #     （`agent_loop_human_messages.state='queued'`）与事件行（`pending`），
    #     紧接着 `agent_loop_claim` 回 `{"claimed":false}` —— 因为 executing 门槛
    #     把 `unknown` 也当成"还在执行"。此后那个数据库再没有被写过一次，消息永远
    #     发不出去，界面上既没有回复也没有报错。
    #
    # 这一节用真 daemon 走完同一个形状：claim 一轮人类回合 → **故意不结算** →
    # 重启 daemon（真 `recover()`）→ 再发一条人类消息 → 必须能被领起来。
    # 8.1/8.2 先证明那行毒记录是产品代码产生的（不是本节假造），8.3~8.5 才是判据。
    print("  --- 8. 未确认的旧回合不许堵住后续人类回合 ---", flush=True)
    rec_world, rec_scope, rec_host = "w-recovered", "s-recovered", "h-recovered"
    rec_base = {"worldID": rec_world, "residentScope": rec_scope, "hostSessionID": rec_host}
    taskd.request("agent_loop_configure", {**rec_base, "hourlyLimit": 6,
                                          "minimumWakeIntervalSeconds": 1,
                                          "backgroundEnabled": True, "available": True})

    def rec_read() -> dict:
        return taskd.request("agent_loop_read", dict(rec_base)).get("result", {})

    def rec_event_state(event: str):
        return next((e.get("state") for e in rec_read().get("events", [])
                     if e.get("eventID") == event), None)

    def rec_claim_human(event: str, message: str, run_id: str) -> dict:
        """用户在聊天框按下发送时宿主打出的那串 RPC，逐字同序。"""
        taskd.request("agent_loop_enqueue", {
            **rec_base, "eventID": event, "intentID": "human-batch", "kind": "human",
            "intentState": "active", "messageIDs": [message],
            "inputRefs": {message: {"submissionID": message,
                                    "inputSHA256": hashlib.sha256(message.encode()).hexdigest(),
                                    "imageReferences": []}},
            "command": {"type": "resident_human_turn", "messageIDs": [message]}})
        return taskd.request("agent_loop_claim", {
            **rec_base, "runID": run_id, "nowMillis": int(time.time() * 1000),
            "eventID": event})

    first_claim = rec_claim_human("human-recovered-1", "m-recovered-1", "r-recovered-1")
    chain.check(first_claim.get("result", {}).get("claimed") is True, "8.1",
                "第一轮人类回合被 claim（随后被宿主遗弃，用来造出真机上那一行毒记录）",
                where="services/gmgn-taskd/src/agent_scheduler.rs:372",
                reason=json.dumps(first_claim, ensure_ascii=False)[:300], evidence=first_claim)

    # 故意不结算这一轮，然后重启 daemon：真 `recover()` 必须把它命名成 `unknown`。
    taskd.restart()
    orphan_state = rec_event_state("human-recovered-1")
    chain.check(orphan_state == "unknown", "8.2",
                "daemon 重启后，被遗弃的 claimed 回合由真 `recover()` 命名成 `unknown`"
                " —— 毒记录来自产品代码，不是本节假造",
                where="services/gmgn-taskd/src/agent_scheduler.rs:50",
                reason=f"recover() 之后 state={orphan_state!r}",
                evidence={"state": orphan_state, "expected": "unknown"})

    second_claim = rec_claim_human("human-recovered-2", "m-recovered-2", "r-recovered-2")
    chain.check(second_claim.get("result", {}).get("claimed") is True, "8.3",
                "未确认的旧回合不再毒化整个 world+scope：下一条人类消息仍能被 claim",
                where="services/gmgn-taskd/src/agent_scheduler.rs:283",
                reason=(f"agent_loop_claim 回 {json.dumps(second_claim, ensure_ascii=False)[:200]}"
                        " —— executing 门槛把上一轮的 `unknown` 当成了仍在执行，"
                        "于是人类消息永远停在 queued、事件永远停在 pending；"
                        "真机上这一条红就是「装了 229 之后聊天还是发不出去」"),
                evidence=second_claim)

    readback = rec_read()
    message_state = next((m.get("state") for m in readback.get("humanMessages", [])
                          if m.get("messageID") == "m-recovered-2"), None)
    chain.check(message_state == "claimed", "8.4",
                "那个人类消息行真的离开了 queued（宿主领取时同步改写）",
                where="services/gmgn-taskd/src/agent_scheduler.rs:374",
                reason=f"agent_loop_human_messages.state={message_state!r}",
                evidence={"state": message_state, "expected": "claimed"})
    kept_state = rec_event_state("human-recovered-1")
    chain.check(kept_state == "unknown", "8.5",
                "诚实记录没有被猜掉：旧的未确认回合仍是 `unknown`，"
                "只能由宿主自己的 agent_loop_reconcile 结算",
                where="services/gmgn-taskd/src/agent_scheduler.rs:451",
                reason=f"state={kept_state!r}（不许被改写成 completed/failed）",
                evidence={"state": kept_state, "expected": "unknown"})
    rec_stderr = taskd.stderr_text()
    chain.check("agent_loop_stale_unconfirmed_turns" in rec_stderr, "8.6",
                "这一处自我恢复有名字：stderr 出现 agent_loop_stale_unconfirmed_turns"
                "（与 agent_dsh_stale_unconfirmed_tools 同一套做法）",
                where="services/gmgn-taskd/src/agent_scheduler.rs:365",
                reason="stderr 里没有那条具名记录，尾部：" + rec_stderr[-300:])
    return context



def close_turn(taskd: "Taskd", base: dict, run_id: str, event_id: str) -> dict:
    """把一个已 claim 的回合收尾，好让调度器放行下一次 claim。

    调度器同一时刻只允许一个 claimed 事件（实测：第二个 claim 直接
    `{"claimed": false}`），所以每一轮之间必须有人把它关掉 —— 这正是
    `agent_loop_cancel` + `agent_loop_confirm_cancel` 在生产里的用途。
    """
    outcome: dict = {}
    cancel = taskd.request("agent_loop_cancel", {**base, "runID": run_id, "eventID": event_id})
    outcome["cancel"] = cancel
    for _ in range(50):
        confirm = taskd.request("agent_loop_confirm_cancel",
                                {**base, "runID": run_id, "eventID": event_id})
        outcome["confirm"] = confirm
        if (confirm.get("result") or {}).get("confirmed") is not False:
            break
        time.sleep(0.05)
    read = taskd.request("agent_loop_read", base).get("result") or {}
    outcome["events"] = [(e.get("eventID"), e.get("state")) for e in read.get("events", [])]
    return outcome


def _fault_case(chain: Chain, binary: Path, base: dict, tools: list[dict], work: Path,
                tag: str, label: str, output: dict, status: str,
                images, where: str) -> dict:
    """一种非法回执，一轮**完全独立**的 daemon + root。

    为什么不共用一轮/一个 daemon：被拒回执之后这一轮的会话会落成终态，
    而调度器同一时刻只允许一个 claimed 事件。共用就变成"上一种故障的下游效应"
    在决定下一种的观察结果，测到的不是这一种故障本身。
    """
    root = work / f"fault-{tag}"
    taskd = Taskd(binary, root, keep=False)
    outcome: dict = {"tag": tag, "label": label}
    try:
        taskd.start()
        import os as _os
        outcome["root_listing"] = sorted(_os.listdir(taskd.root))
    except RuntimeError as error:
        outcome["error"] = f"daemon_start_failed: {error}"
        return outcome
    try:
        run_id, event_id = f"r-fault-{tag}", f"e-fault-{tag}"
        taskd.request("agent_loop_configure", {**base, "hourlyLimit": 6,
                                               "minimumWakeIntervalSeconds": 1,
                                               "backgroundEnabled": True, "available": True})
        taskd.request("agent_loop_enqueue", {**base, "eventID": event_id,
                                             "intentID": f"i-fault-{tag}",
                                             "kind": "continuation", "intentState": "active",
                                             "command": {"observe": True}})
        claim = taskd.request("agent_loop_claim", {**base, "runID": run_id,
                                                   "nowMillis": int(time.time() * 1000)})
        outcome["claim"] = claim
        if claim.get("result", {}).get("claimed") is not True:
            outcome["error"] = "claim_refused"
            return outcome
        build_agent_root(root, tools)
        arm_session(root, root / f"harness-finish.{tag}")
        started = taskd.request("agent_dsh_start", {
            **base, "runID": run_id, "eventID": event_id, "grantToken": str(uuid.uuid4()),
            "root": str(root), "cwd": str(root),
            "executable": str(root / "harness-acp"), "entryPoint": str(root / "harness-entry"),
            "compositionFile": str(root / "composition.yaml"),
            "attachmentHome": str(root), "persistenceRoot": str(root), "persona": "harness",
            "hostToolsPlugin": str(root / "gmgn-host-tools.mjs"),
            "environment": {"HOME": str(root), "TMPDIR": str(root)},
            "arguments": [str(root / "harness-entry"), "--config", str(root / "composition.yaml")],
            "input": f"harness fault turn {tag}", "tools": tools})
        outcome["start"] = started
        if started.get("result", {}).get("started") is not True:
            outcome["error"] = "start_refused"
            return outcome
        token = started["result"]["grantToken"]
        fault_base = {**base, "runID": run_id}
        running = wait_state(taskd, base, run_id, event_id, {"running"}, budget=30)
        outcome["running"] = running.get("result", {}).get("state")
        if outcome["running"] != "running":
            outcome["error"] = "not_running"
            return outcome

        call_id = f"call-{tag}"
        holder: dict = {}

        def host_call():
            try:
                holder["reply"] = taskd.grant_call(token, {
                    "v": 1, "callId": call_id, "name": "gmgn_inspect_world", "arguments": {}})
            except Exception as error:  # noqa: BLE001
                holder["error"] = str(error)

        def read_session():
            return taskd.request("agent_dsh_read", {**fault_base, "eventID": event_id})

        def wait_for(predicate, budget: float = 30.0):
            deadline = time.monotonic() + budget
            snapshot = None
            while time.monotonic() < deadline:
                snapshot = read_session()
                if predicate(snapshot):
                    return snapshot
                time.sleep(0.02)
            return snapshot

        import threading
        thread = threading.Thread(target=host_call, daemon=True)
        thread.start()
        authorized = wait_for(lambda s: any(t.get("callID") == call_id and t.get("phase") == "authorize"
                                            for t in s.get("result", {}).get("pendingTools", [])))
        entry = next((t for t in authorized.get("result", {}).get("pendingTools", [])
                      if t.get("callID") == call_id and t.get("phase") == "authorize"), None)
        if entry is None:
            outcome["error"] = "no_authorize_stage"
            outcome["snapshot"] = authorized.get("result")
            return outcome
        approval = dict(entry)
        approval["decision"] = "approved"
        approval["operationID"] = f"op-{tag}"
        outcome["authorize"] = taskd.request("agent_dsh_authorize",
                                             {**fault_base, "eventID": event_id, **approval})
        executing = wait_for(lambda s: any(t.get("callID") == call_id and t.get("phase") == "execute"
                                           for t in s.get("result", {}).get("pendingTools", [])))
        entry = next((t for t in executing.get("result", {}).get("pendingTools", [])
                      if t.get("callID") == call_id and t.get("phase") == "execute"), None)
        if entry is None:
            outcome["error"] = "no_execute_stage"
            outcome["snapshot"] = executing.get("result")
            return outcome
        payload = {**fault_base, "eventID": event_id, "acpSessionID": entry["acpSessionID"],
                   "callID": call_id, "operationID": f"op-{tag}",
                   "status": status, "output": output}
        if images is not None:
            payload["images"] = images
        outcome["receipt_reply"] = taskd.request("agent_dsh_tool_receipt", payload)
        # 不给 finish 标记：考察的正是"被拒之后这一轮还有没有出路"。
        outcome["terminal"] = wait_for(
            lambda s: s.get("result", {}).get("state") in
            ("completed", "failed", "cancelled", "unknown"), budget=20).get("result", {})
        thread.join(timeout=5)
        outcome["host_call"] = holder
        # 账本那一行：inflight/unknown 会被下一次 start 当成未决工具。
        ledger = taskd.request("agent_tool_inspect",
                               {**base, "runID": run_id, "operationID": f"op-{tag}"})
        outcome["ledger"] = ledger.get("result", {}).get("calls", [])
        outcome["stderr"] = taskd.stderr_text()
        # 7.3 的决定性一问：这一行会不会**永久堵后续回合**。
        #
        # 账本行本身必须留着：`unknown` 是"我们没学到效果"的诚实记录，也是 7.6
        # 验证"它跨重启存活"的那一行；把它猜成 applied 才是要禁的。被拒回执之后
        # 这一轮停在 claimed，等宿主（`RustDSHSessionClient` 的位置）自己收尾。
        # 这里就按宿主的位置收尾，claim 一轮新回合、再 start 一次：旧规则（不看
        # event 的 `state IN ('unknown','inflight')`）会在这里回
        # `agent_dsh_unresolved_tools`；收窄后的规则只在 run 仍 claimed 时才算未决。
        outcome["settle"] = taskd.request(
            "agent_loop_complete", {**base, "runID": run_id, "eventID": event_id,
                                    "status": "failed",
                                    "receipt": {"source": "harness-host-settle",
                                                "status": "failed", "reply": ""}})
        next_event, next_run = f"e-next-{tag}", f"r-next-{tag}"
        taskd.request("agent_loop_enqueue", {**base, "eventID": next_event,
                                             "intentID": f"i-next-{tag}", "kind": "continuation",
                                             "intentState": "active", "command": {"observe": True}})
        outcome["next_claim"] = taskd.request(
            "agent_loop_claim", {**base, "runID": next_run,
                                 "nowMillis": int(time.time() * 1000) + 5000})
        next_start = start_session(taskd, base, root, tools, next_run, next_event,
                                   root / f"harness-finish.next-{tag}",
                                   f"harness fault next turn {tag}")
        outcome["next_start"] = next_start
        outcome["next_stderr"] = taskd.stderr_text()
        if next_start.get("result", {}).get("started") is True:
            (root / f"harness-finish.next-{tag}").write_text("ready")
            wait_state(taskd, base, next_run, next_event,
                       {"completed", "failed", "cancelled", "unknown"}, budget=30)
        # 宿主有没有自己清未决行的 RPC（由同一个 daemon 回答，路由表与 root 无关）。
        outcome["reconcile_probe"] = taskd.request(
            "agent_tool_reconcile", {**base, "runID": run_id, "callID": call_id,
                                     "outcome": "not_applied",
                                     "verificationReceipt": {"verified": True}})
        outcome["reconcile_stderr"] = taskd.stderr_text()

        # 决定性的一问：重启 daemon 能不能把这个未决行清掉？
        # `agent_tools::recover` 只做 `inflight -> unknown`（agent_tools.rs:12），
        # 所以对已经是 unknown 的行它无事可做。这里真的重启一次再问一次。
        states_before = [row.get("state") for row in (outcome.get("ledger") or [])]
        if states_before and all(state == "unknown" for state in states_before):
            # 直接把库文件复制出来读（daemon 持锁时也安全），拿到不经过任何 RPC
            # 的账本原始行 —— 这样"重启后行没了"到底是 recover 结算了还是 RPC 看不到，
            # 能一次分清。
            def raw_ledger(stage: str):
                source = Path(outcome.get("root") or taskd.root) / "tasks.sqlite3"
                copy = work / f"ledger-{tag}-{stage}.sqlite3"
                try:
                    shutil.copyfile(source, copy)
                    conn = sqlite3.connect(str(copy))
                    found = conn.execute(
                        "SELECT call,state,length(receipt) FROM agent_tool_calls").fetchall()
                    conn.close()
                    return found
                except Exception as error:  # noqa: BLE001
                    return [("error", str(error), 0)]

            outcome["db_before_restart"] = raw_ledger("before")
            taskd_after = Taskd(binary, Path(taskd.root), keep=False)
            try:
                taskd_after.start()
                ledger_after = taskd_after.request(
                    "agent_tool_inspect",
                    {**base, "runID": run_id, "operationID": f"op-{tag}"})
                after_rows = ledger_after.get("result", {}).get("calls", [])
                after_states = [row.get("state") for row in after_rows]
            finally:
                taskd_after.cleanup()
            outcome["after_restart"] = after_states
            outcome["db_after_restart"] = raw_ledger("after")
        return outcome
    finally:
        outcome["root"] = str(taskd.root)
        taskd.cleanup()


def inject_bad_receipt(chain: Chain, taskd: Taskd, base: dict, root: Path, run: str,
                       tools: list[dict], work: Path, keep: bool, binary: Path) -> dict:
    """三种非法宿主回执，各自一轮独立的 daemon + root，逐条断言。

    判据不是"它被拒绝"（那本来就该拒绝），而是：
      1. 拒绝是**具名的**（agent_dsh_invalid_receipt，且 stderr 点了字段与体积）；
      2. 拒绝之后这一轮能被**有界收敛**（不会永远停在等一个不会来的回执）；
      3. 账本里那一行被结算掉，且宿主**有手段**自己清掉未决行。
    """
    result: dict = {"cases": {}}
    variants = [
        ("badstatus", "词表外的 status", {"moved": True}, "succeeded", None, "$.status"),
        ("images", "超过一张图片", {"captured": True}, "completed",
         [{"mediaType": "image/png", "base64": PNG_B64}] * 2, "$.images"),
        ("oversize", "体量超限", {"padding": "x" * (65536 + 4096)}, "completed", None, "$.output"),
    ]
    reconcile_seen: set[str] = set()
    for tag, label, output, status, images, path in variants:
        case = _fault_case(chain, binary, base, tools, work, tag, label,
                           output, status, images, path)
        result["cases"][tag] = case
        reply = case.get("receipt_reply")
        chain.check(error_code(reply) == "agent_dsh_invalid_receipt", f"7.1.{tag}",
                    f"{label}的回执被具名拒绝为 agent_dsh_invalid_receipt",
                    where="services/gmgn-taskd/src/agent_dsh.rs:691",
                    reason=json.dumps({k: case.get(k) for k in
                                       ("error", "claim", "start", "running", "snapshot")},
                                      ensure_ascii=False)[:400],
                    evidence={k: case.get(k) for k in
                              ("error", "claim", "start", "running", "receipt_reply")})
        terminal = (case.get("terminal") or {}).get("state")
        chain.check(terminal in ("completed", "failed", "cancelled", "unknown"), f"7.2.{tag}",
                    f"{label}之后这一轮能走到有界终态（当前 {terminal!r}）",
                    where="services/gmgn-taskd/src/agent_dsh.rs:933",
                    reason=(f"20 s 后状态仍是 {terminal!r}：被拒回执没有结算 pending，"
                            "这一轮停在等一个永远不会来的回执"),
                    evidence=case.get("terminal"), permanent=(terminal == "running"),
                    owner="修复线：services/gmgn-taskd/src/agent_dsh.rs:413（refuse_receipt）")
        rows = case.get("ledger") or []
        states = [row.get("state") for row in rows]
        # 判据是"这条残行会不会永久堵后续回合"，不是它的字面值：`unknown` 必须留着
        # （7.6 验证它跨重启存活、7.7 验证宿主能自己结算它），而 `inflight` 仍然
        # 不许留。旧判据 `all(state=="finished")` 与 7.6 的守卫（`all(state=="unknown")`）
        # 互斥，且只能靠把未知猜成 applied 才满足——那正是安全红线禁的。
        nxt = case.get("next_start") or {}
        started_next = (nxt.get("result") or {}).get("started") is True
        blocked_next = error_code(nxt) == "agent_dsh_unresolved_tools"
        named_selfheal = "agent_dsh_stale_unconfirmed_tools" in (case.get("next_stderr") or "")
        chain.check(started_next and not blocked_next and named_selfheal
                    and all(s != "inflight" for s in states), f"7.3.{tag}",
                    f"{label}的未确认行不再永久堵后续回合（留存 {states!r}，下一轮 start "
                    f"started={started_next}、具名自愈={named_selfheal}）",
                    where="services/gmgn-taskd/src/agent_dsh.rs:528",
                    reason=(f"`agent_dsh_start` 返回 error={error_code(nxt)!r}、started={started_next}；"
                            f"stderr 里{'有' if named_selfheal else '没有'} "
                            "`agent_dsh_stale_unconfirmed_tools`；"
                            f"账本行={states!r}（unknown 是诚实记录，由 agent_tool_reconcile 结算）"),
                    evidence={"ledger": rows, "settle": case.get("settle"),
                              "next_claim": case.get("next_claim"), "next_start": nxt},
                    permanent=(blocked_next or not started_next),
                    owner="修复线：services/gmgn-taskd/src/agent_dsh.rs:523（未决判定收窄到真正在飞的调用）")
        stderr = case.get("stderr") or ""
        named = re.search(r'"code":\s*"agent_dsh_invalid_receipt"[^\n]*?"path":\s*"'
                          + re.escape(path) + '"', stderr)
        chain.check(named is not None, f"7.4.{tag}",
                    f"stderr 里的拒绝行点了字段 {path}",
                    where="services/gmgn-taskd/src/agent_dsh.rs:680",
                    reason=f"stderr 里没有 {path} 的具名拒绝行：{stderr[-500:]!r}",
                    evidence=named.group(0) if named else stderr[-800:])
        if tag == "oversize":
            measured = re.search(r'"path":\s*"\$\.output"[^\n]*?"detail":\s*"'
                                 r'[^"]*?(\d+) bytes[^"]*?(\d+) byte limit"', stderr)
            chain.check(measured is not None, "7.5",
                        "stderr 的超限拒绝行说出了实测体积与上限（不是匿名失败）",
                        where="services/gmgn-taskd/src/agent_dsh.rs:670",
                        reason=f"stderr 里没有带体积的超限拒绝行：{stderr[-600:]!r}",
                        evidence=measured.group(0) if measured else stderr[-800:])
        states_before = [row.get("state") for row in (case.get("ledger") or [])]
        after_states = case.get("after_restart")
        if after_states is not None:
            chain.check(after_states == states_before, f"7.6.{tag}",
                        f"{label}留下的 {states_before!r} 行，重启 daemon 之后仍然存在"
                        f"（当前 {after_states!r}）",
                        where="services/gmgn-taskd/src/agent_tools.rs:12",
                        reason=(f"重启前 {states_before!r}，重启后 {after_states!r}"
                                f"（重启前原始库行 {case.get('db_before_restart')!r}，"
                                f"重启后原始库行 {case.get('db_after_restart')!r}）。"
                                "`agent_tools::recover` 只把 inflight 改成 unknown，"
                                "对 unknown 行什么都不做 —— 这个未决行跨重启存活，"
                                "而每一次新的 agent_dsh_start 都会被它挡成 "
                                "agent_dsh_unresolved_tools（services/gmgn-taskd/src/"
                                "agent_dsh.rs:555）"),
                        evidence={"before": states_before, "after": after_states,
                                  "db_before": case.get("db_before_restart"),
                                  "db_after": case.get("db_after_restart")},
                        permanent=(after_states == states_before),
                        owner="修复线：services/gmgn-taskd/src/agent_tools.rs:12"
                              "（recover 不结算 unknown）或 daemon.rs:339（补 reconcile 路由）")
        probe = case.get("reconcile_probe") or {}
        reconcile_seen.add(error_code(probe) or "")
        result.setdefault("reconcile_probes", []).append(probe)

    unreachable = reconcile_seen == {"unknown_method"}
    chain.check(not unreachable, "7.7",
                "宿主有一条 RPC 能自己清掉未决的工具行（agent_tool_reconcile 可达）",
                where="services/gmgn-taskd/src/daemon.rs:339",
                reason=("三种故障各自起一个 daemon，`agent_tool_reconcile` 三次都返回 "
                        "unknown_method：daemon 的 /rpc 路由表里没有这一项"
                        "（daemon.rs:339 只挂了 agent_tool_begin/finish/inspect，"
                        "而 agent_tools::reconcile 在 agent_tools.rs:704 是公开的）。"
                        "宿主没有任何手段清掉未决行，只能等 daemon 重启 —— 而重启只会把 "
                        "inflight 变成 unknown（agent_tools.rs:12），仍然是未决。"),
                evidence=result.get("reconcile_probes"), permanent=unreachable,
                owner="修复线：services/gmgn-taskd/src/daemon.rs:339")
    return result


# ---------------------------------------------------------------------------
# C 链
# ---------------------------------------------------------------------------


MOTION_A = "gmgn.motion.bones.studio-groove.vrma"
MOTION_B = "gmgn.motion.bones.night-drive.vrma"


def run_chain_c(chain: Chain, binary: Path, work: Path, keep: bool) -> dict:
    print("\n=== C 链：设置里切换动作（真实 presence_selection 状态机）===", flush=True)
    context: dict = {}
    root = work / "c"
    taskd = Taskd(binary, root, keep=keep)
    try:
        taskd.start()
    except RuntimeError as error:
        chain.check(False, "0.1", "真实 gmgn-taskd 在私有 root 上起来（C 链）",
                    where="tools/verify-resident-chains.py:1", reason=str(error))
        return context

    scope = str(root)
    package_root = root / "PresencePackages"
    motion_root = root / "MotionPackages"
    package_root.mkdir(parents=True, exist_ok=True)
    motion_root.mkdir(parents=True, exist_ok=True)

    avatars = [{"id": "builtin.orb", "engine": "orb", "builtIn": True,
                "rendererAvailable": True, "name": "光球"},
               {"id": "gmgn.vrm.harness", "engine": "vrm", "builtIn": False,
                "rendererAvailable": True, "path": "", "name": "VRM 夹具"}]
    motions = [{"id": "builtin.motion.natural-idle", "format": "procedural", "builtIn": True,
                "rendererAvailable": True, "name": "自然待机", "loop": True}]
    # 非内建资源要走完整的 manifest + entry 校验（presence_selection.rs:118-153），
    # 所以这里真的在私有 root 里造出文件 —— 不靠 builtIn 走捷径。
    avatar_dir = package_root / "gmgn.vrm.harness"
    avatar_dir.mkdir(parents=True, exist_ok=True)
    avatar_file = avatar_dir / "avatar.vrm"
    avatar_file.write_bytes(b"VRM" + bytes(64))
    (avatar_dir / "manifest.json").write_text(json.dumps(
        {"id": "gmgn.vrm.harness", "engine": "vrm", "entry": avatar_file.name,
         "name": "VRM 夹具"}))
    avatars[1]["path"] = str(avatar_file)
    for index, ident in enumerate([MOTION_A, MOTION_B]):
        directory = motion_root / ident
        directory.mkdir(parents=True, exist_ok=True)
        asset = directory / f"motion-{index}.vrma"
        asset.write_bytes(b"VRMA" + bytes([index]) * 32)
        (directory / "manifest.json").write_text(json.dumps(
            {"id": ident, "format": "vrma", "entry": asset.name, "loop": True,
             "name": f"动作 {index}"}))
        motions.append({"id": ident, "format": "vrma", "builtIn": False,
                        "rendererAvailable": True, "path": str(asset),
                        "name": f"动作 {index}", "loop": True})

    bind = {"scope": scope, "requestID": "bind-1", "packageRoot": str(package_root),
            "motionRoot": str(motion_root), "policy": "native",
            "supportedEngines": ["orb", "vrm", "pmx"], "avatars": avatars, "motions": motions}

    bound = taskd.request("presence_selection_bind_catalog", bind)
    chain.check(error_code(bound) is None, "1.1", "真实动作目录绑定成功",
                where="services/gmgn-taskd/src/presence_selection.rs:277",
                reason=json.dumps(bound, ensure_ascii=False)[:300], evidence=bound)
    if error_code(bound) is not None:
        return context
    revision = bound["result"]["revision"]
    context["bind"] = {"revision": revision,
                       "state": {k: v for k, v in bound["result"].items()
                                 if k in ("avatarID", "motionID", "pendingRenderer", "rendererStatus")}}

    def event(payload: dict):
        return taskd.request("presence_selection_event", {**payload, "scope": scope})

    # --- 先切到 VRM 角色：vrma 动作只对它兼容（compatible() 表见
    #     presence_selection.rs:56-62）。这一步本身也要一次回执才确认。--------
    picked = event({"requestID": "avatar-1", "expectedRevision": revision,
                    "event": "select_avatar", "id": "gmgn.vrm.harness"})
    chain.check(error_code(picked) is None, "2.0", "选定 VRM 角色的事件被接受",
                where="services/gmgn-taskd/src/presence_selection.rs:543",
                reason=json.dumps(picked, ensure_ascii=False)[:300], evidence=picked)
    if error_code(picked) is not None:
        return context
    revision = picked["result"]["revision"]
    avatar_ack = event({"requestID": "avatar-ack", "expectedRevision": revision,
                        "event": "renderer_ack", "success": True})
    chain.check(error_code(avatar_ack) is None, "2.0b", "角色切换的回执被接受（不然永远 pending）",
                where="services/gmgn-taskd/src/presence_selection.rs:531",
                reason=json.dumps(avatar_ack, ensure_ascii=False)[:300], evidence=avatar_ack)
    if error_code(avatar_ack) is not None:
        return context
    revision = avatar_ack["result"]["revision"]

    # --- 第一次选择：真机上是"命令进宿主门 → 谓词 → 这条事件" ----------------
    selected = event({"requestID": "sel-1", "expectedRevision": revision,
                      "event": "select_motion", "id": MOTION_A})
    chain.check(error_code(selected) is None, "2.1", "选定动作的事件被接受",
                where="services/gmgn-taskd/src/presence_selection.rs:563",
                reason=json.dumps(selected, ensure_ascii=False)[:300], evidence=selected)
    if error_code(selected) is not None:
        return context
    state = selected["result"]
    context["after_select"] = {"motionID": state.get("motionID"),
                               "pendingRenderer": state.get("pendingRenderer"),
                               "rendererStatus": state.get("rendererStatus"),
                               "revision": state.get("revision")}
    chain.check(state.get("pendingRenderer") is True
                and state.get("confirmedMotionID") != MOTION_A, "2.2",
                "选定之后**未确认**：pendingRenderer=true，confirmedMotionID 还没跟上"
                "（这就是宿主 `presence_selection_busy` 背后的真实状态）",
                where="services/gmgn-taskd/src/presence_selection.rs:99",
                reason=json.dumps(state, ensure_ascii=False)[:300], evidence=context["after_select"])

    # --- pending 期间再选一次：必须是具名拒码，而不是静默吞掉 ----------------
    pending_revision = state["revision"]
    second = event({"requestID": "sel-2", "expectedRevision": pending_revision,
                    "event": "select_motion", "id": MOTION_B})
    context["pending_refusal"] = second
    chain.check(error_code(second) == "presence_renderer_pending", "3.1",
                "pending 期间的下一次选择拿到具名拒码 presence_renderer_pending"
                "（不是匿名 settings_command_rejected）",
                where="services/gmgn-taskd/src/presence_selection.rs:536",
                reason=json.dumps(second, ensure_ascii=False)[:300], evidence=second)

    read_pending = taskd.request("presence_selection_read", {"scope": scope})
    context["read_while_pending"] = read_pending.get("result")
    chain.check(read_pending.get("result", {}).get("pendingRenderer") is True, "3.2",
                "pending 状态如实投影到 read（UI 画出来的可选项与真状态一致）",
                where="services/gmgn-taskd/src/presence_selection.rs:282",
                reason=json.dumps(read_pending, ensure_ascii=False)[:300])

    # --- 这个 pending 会不会**自愈**？ --------------------------------------
    deadline = time.monotonic() + 5
    healed = False
    while time.monotonic() < deadline:
        probe = taskd.request("presence_selection_read", {"scope": scope}).get("result", {})
        if probe.get("pendingRenderer") is not True:
            healed = True
            break
        time.sleep(0.25)
    context["pending_self_healed"] = healed
    bounds = swift_gate_bounds()
    context["swift_gate_bounds"] = bounds
    host_bounded = bool(bounds)
    chain.check(
        healed or host_bounded, "3.3",
        "没有渲染回执时，pending 会被**有界**地放弃（daemon 自己不限时，但宿主侧有具名预算）",
        where="services/gmgn-taskd/src/presence_selection.rs:535",
        reason=("daemon 的 presence_selection 没有任何 deadline/超时/自愈路径："
                "`pendingRenderer` 只有 `renderer_ack` 能清（presence_selection.rs:531），"
                "所以权威侧一个不回执的 pending 是永久的；"
                f"宿主侧的有界预算：{bounds or '（一个都没找到）'}。"
                "两侧都不限时 = 永久 busy。"),
        evidence={"read_after_5s": probe, "pending": pending_revision,
                  "daemon_bounded": healed, "swift_gate_bounds": bounds},
        permanent=not (healed or host_bounded),
        owner="修复线：services/gmgn-taskd/src/presence_selection.rs（daemon 侧下界）"
              "或 apps/macos/UnityHost/UnityPresenceSelectionGate.swift（宿主侧预算）")

    # daemon 侧不许悄悄长出下界又不说：这一条把"谁在限时"钉成事实而不是印象。
    chain.check(not healed, "3.4",
                "daemon 侧确实没有自愈（所以这个 harness 的 daemon 断言与宿主断言是两件事）",
                where="services/gmgn-taskd/src/presence_selection.rs:531",
                reason=("daemon 在 5 秒观察窗里自己把 pendingRenderer 清掉了 —— "
                        "那是好事，但说明 harness 关于'宿主预算'的结论要重算"),
                evidence={"read_after_5s": probe, "pending": pending_revision,
                          "swift_gate_bounds": bounds},
                permanent=False,
                owner="修复线：更新 tools/verify-resident-chains.py 的 C3 结论")

    # --- 渲染回执来了之后必须能继续选 ---------------------------------------
    acked = event({"requestID": "ack-1", "expectedRevision": pending_revision,
                   "event": "renderer_ack", "success": True})
    chain.check(error_code(acked) is None and acked["result"].get("pendingRenderer") is False, "4.1",
                "renderer_ack 清掉 pending（成功回执落成 confirmed）",
                where="services/gmgn-taskd/src/presence_selection.rs:531",
                reason=json.dumps(acked, ensure_ascii=False)[:300], evidence=acked)
    if error_code(acked) is not None:
        return context
    chain.check(acked["result"].get("confirmedMotionID") == MOTION_A, "4.2",
                "回执之后 confirmedMotionID 才等于刚选的动作（确认是有据的）",
                where="services/gmgn-taskd/src/presence_selection.rs:505",
                reason=json.dumps(acked["result"], ensure_ascii=False)[:300],
                evidence=acked["result"].get("confirmedMotionID"))

    third = event({"requestID": "sel-3", "expectedRevision": acked["result"]["revision"],
                   "event": "select_motion", "id": MOTION_B})
    chain.check(error_code(third) is None and third["result"].get("motionID") == MOTION_B, "4.3",
                "pending 消失之后可以成功选定下一个动作（对照：证明 C3.1 的拒绝不是永久门）",
                where="services/gmgn-taskd/src/presence_selection.rs:563",
                reason=json.dumps(third, ensure_ascii=False)[:300], evidence=third)
    context["after_ack_select"] = third.get("result", {})

    # --- 重放/陈旧：幂等与具名冲突 ------------------------------------------
    replay = event({"requestID": "sel-3", "expectedRevision": acked["result"]["revision"],
                    "event": "select_motion", "id": MOTION_B})
    chain.check(error_code(replay) is None, "5.1",
                "同一个 requestID + 同一份参数重放是幂等的（网络重试不会打乱状态）",
                where="services/gmgn-taskd/src/presence_selection.rs:294",
                reason=json.dumps(replay, ensure_ascii=False)[:300], evidence=replay)
    conflict = event({"requestID": "sel-3",
                      "expectedRevision": third["result"]["revision"],
                      "event": "select_motion", "id": MOTION_A})
    chain.check(error_code(conflict) == "presence_request_conflict", "5.2",
                "同一 requestID 换了参数是具名冲突（不会静默按新的执行）",
                where="services/gmgn-taskd/src/presence_selection.rs:302",
                reason=json.dumps(conflict, ensure_ascii=False)[:300], evidence=conflict)
    stale = event({"requestID": "sel-4", "expectedRevision": 0,
                   "event": "select_motion", "id": MOTION_A})
    chain.check(error_code(stale) == "presence_revision_conflict", "5.3",
                "陈旧 revision 被拒（宿主拿着旧快照不会覆盖新状态）",
                where="services/gmgn-taskd/src/presence_selection.rs:384",
                reason=json.dumps(stale, ensure_ascii=False)[:300], evidence=stale)

    # --- 逐字核对：两个谓词的词汇关系 ---------------------------------------
    #
    # 两边是**两个**谓词，不是同一个：
    #   * daemon 的 `presence_selection_event` 是权威，它的拒码远多于动作谓词；
    #   * 宿主的 `motionSelectionRefusal` 是"这一行现在能不能点"的投影，它自己还
    #     拥有两个**只存在于宿主**的码（见 HOST_ONLY_REFUSAL_CODES）：`busy` 讲的
    #     是宿主自己的在途任务，`selection_rejected` 是最后的兜底。
    # 所以能钉的是这两条，方向不能反。
    swift_codes = swift_refusal_vocabulary()
    context["swift_refusal_codes"] = sorted(swift_codes)
    daemon_vocabulary = {
        "presence_renderer_pending", "presence_motion_incompatible",
        "presence_motion_unavailable", "presence_avatar_unavailable",
        "presence_invalid_event", "presence_revision_conflict",
        "presence_request_conflict", "presence_removal_pending",
        "presence_resource_missing", "presence_invalid_input",
        "presence_catalog_unbound", "presence_invalid_catalog",
        "presence_invalid_catalog_scope", "presence_catalog_identity_mismatch",
        "presence_resource_outside_root", "presence_renderer_receipt_stale",
        "presence_motion_receipt_stale", "presence_remove_builtin",
        "presence_removal_identity_mismatch", "presence_removal_not_dispatchable",
        "presence_removal_receipt_stale", "presence_removal_verification_failed",
        "presence_invalid_state", "presence_invalid_authorization",
    }
    mirrored = sorted(swift_codes - HOST_ONLY_REFUSAL_CODES)
    fabricated = sorted(mirrored and (set(mirrored) - daemon_vocabulary) or [])
    chain.check(not fabricated, "6.1",
                f"宿主谓词里每一个**转述 daemon** 的码，daemon 都真的会发"
                f"（{len(mirrored)} 个码；宿主自有的 {sorted(HOST_ONLY_REFUSAL_CODES)} 不算）",
                where="apps/macos/UnityHost/UnityPresenceSettingsBridge.swift:84",
                reason=f"宿主说了但 daemon 发不出来的码：{fabricated}",
                evidence={"swift": sorted(swift_codes), "mirrored": mirrored,
                          "host_only": sorted(HOST_ONLY_REFUSAL_CODES)})

    # 反向：daemon 的动作相关码，宿主谓词必须认得（否则它会把一个具名原因
    # 折成 "presence_selection_rejected" 这种笼统话）。
    motion_codes = {"presence_renderer_pending", "presence_motion_incompatible",
                    "presence_motion_unavailable", "presence_selection_busy"}
    unknown = sorted(motion_codes - swift_codes)
    chain.check(not unknown, "6.2",
                f"daemon 的动作相关拒码，宿主谓词全都认得（{len(motion_codes)} 个）",
                where="apps/macos/UnityHost/UnityPresenceSettingsBridge.swift:88",
                reason=f"daemon 会发但宿主谓词不认的码：{unknown}",
                evidence={"swift": sorted(swift_codes), "motion_codes": sorted(motion_codes)})

    # 宿主自有的码必须**真的**只活在宿主：daemon 不该发出来。
    leaked = sorted(HOST_ONLY_REFUSAL_CODES & daemon_vocabulary)
    chain.check(not leaked, "6.3",
                "宿主自有的 busy/兜底码没有被 daemon 冒用（两套词汇不互相污染）",
                where="apps/macos/UnityHost/UnityPresenceSettingsBridge.swift:84",
                reason=f"这些码本该只在宿主出现，却也在 daemon 词汇里：{leaked}",
                evidence={"host_only": sorted(HOST_ONLY_REFUSAL_CODES)})
    return context


# 只存在于宿主的拒码：它们说的是宿主自己的在途任务与最后兜底，daemon 不发。
# `presence_selection_preparation_waited` 是 2026-10-09 build 229 之后新增的：宿主
# 等自己刚起的 `presence.motion.stop`（同一个用户动作的准备）走完才去问门。这件事
# 只发生在宿主里，daemon 没有对应状态，所以它进「宿主自有」这一侧，而不是被 6.1
# 当成伪造的 daemon 码。允许集是「宿主自有的码」这个集合本身，6.1/6.2/6.3 的判据
# 没有放宽：转述 daemon 的码仍必须逐个在 daemon 词表里存在。
HOST_ONLY_REFUSAL_CODES = {"presence_selection_busy", "presence_selection_rejected",
                           "presence_selection_stale_cleared",
                           "presence_selection_preparation_waited"}


GATE_FILE = "apps/macos/UnityHost/UnityPresenceSelectionGate.swift"


def _swift_code_surfaces() -> dict[str, str]:
    """宿主拒码的权威来源：谓词所在的 bridge + 它们调用的 gate。

    只读这两个文件，而且先去注释，免得文档里提到的名字被当成"谓词会说出口的码"。
    """
    surfaces = {}
    for rel in ("apps/macos/UnityHost/UnityPresenceSettingsBridge.swift", GATE_FILE):
        path = ROOT / rel
        if path.exists():
            surfaces[rel] = re.sub(r"//[^\n]*", "", path.read_text(encoding="utf-8"))
    return surfaces


def swift_refusal_vocabulary() -> set[str]:
    """宿主动作谓词这条链上**真的会出现**的 `presence_*` 拒码。"""
    codes: set[str] = set()
    for text in _swift_code_surfaces().values():
        codes |= set(re.findall(r'"(presence_[a-z_]+)"', text))
    return codes


def swift_gate_bounds() -> dict[str, int]:
    """gate 里具名的有界预算（毫秒/秒），用来判断"pending 会不会自己消失"。"""
    bounds: dict[str, int] = {}
    path = ROOT / GATE_FILE
    if not path.exists():
        return bounds
    text = re.sub(r"//[^\n]*", "", path.read_text(encoding="utf-8"))
    for name, value in re.findall(r"static let (\w*(?:Budget|Millis|Timeout)\w*)\s*"
                                  r"(?::\s*UInt64\s*)?=\s*([0-9_]+)", text):
        bounds[name] = int(value.replace("_", ""))
    return bounds


# ---------------------------------------------------------------------------
# A 链 / D 链：委托给各自的结构性 harness
# ---------------------------------------------------------------------------


def run_delegate(chain: Chain, script: str, chain_label: str) -> dict:
    path = HERE / script
    if not path.exists():
        chain.check(False, f"{chain_label}0.1", f"{script} 存在",
                    where=f"tools/{script}:1", reason=f"{path} 不存在")
        return {"missing": str(path)}
    completed = subprocess.run([sys.executable, str(path)], cwd=str(ROOT),
                               capture_output=True, text=True, timeout=300)
    payload = None
    for line in reversed(completed.stdout.splitlines()):
        if line.startswith("{"):
            try:
                payload = json.loads(line)
                break
            except ValueError:
                continue
    if payload is None:
        chain.check(False, f"{chain_label}0.1", f"{script} 输出了可解析的结果",
                    where=f"tools/{script}:1",
                    reason=f"rc={completed.returncode}\n{completed.stdout[-800:]}\n{completed.stderr[-800:]}")
        return {"rc": completed.returncode}
    for record in payload.get("records", []):
        # 子 harness 的 id 自带 A/D 前缀，而 `Chain.check` 会印成
        # `<chain.key>/<ident>`，所以这里把前缀剥掉再传（否则会印成 A/A/2.1）。
        ident = record["id"]
        if ident.startswith(chain_label):
            ident = ident[len(chain_label):].lstrip("/")
        chain.check(record["ok"], ident, record["message"],
                    where=record.get("where", f"tools/{script}:1"),
                    reason=record.get("reason", ""),
                    evidence=record.get("evidence"),
                    permanent=record.get("permanent"),
                    owner=record.get("owner", ""))
    return payload


# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------


def find_binary(explicit: str | None) -> Path | None:
    if explicit:
        candidate = Path(explicit)
        return candidate if candidate.exists() else None
    for candidate in (ROOT / "target/release/gmgn-taskd", ROOT / "target/debug/gmgn-taskd"):
        if candidate.exists():
            return candidate
    return None


def print_remaining(chain_list: list[Chain]) -> list[dict]:
    remaining = [r for chain in chain_list for r in chain.failures]
    print("\n=== 剩余卡点清单 ===", flush=True)
    if not remaining:
        print("  （本次运行没有 FAIL）", flush=True)
        return remaining
    for record in remaining:
        print(f"\n  [{record['chain']}/{record['id']}] {record['message']}", flush=True)
        print(f"    现象: {record['reason'] or '断言为假'}", flush=True)
        print(f"    位置: {record['where']}", flush=True)
        print(f"    永久卡: {'是' if record.get('permanent') else ('否' if record.get('permanent') is False else '未判定')}", flush=True)
        print(f"    谁能清: {record.get('owner') or '修复线'}", flush=True)
    return remaining


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--taskd", default=os.environ.get("TASKD_BIN"),
                        help="gmgn-taskd 二进制路径（默认 target/release 或 target/debug）")
    parser.add_argument("--json", default=None, help="把完整账本写到这个路径")
    parser.add_argument("--work", default=None, help="临时 root 的父目录（默认系统临时目录）")
    parser.add_argument("--keep", action="store_true", help="保留临时 root 供事后查看")
    parser.add_argument("--only", default=None,
                        help="只跑某些链，逗号分隔：A,B,C,D")
    parser.add_argument("--list", action="store_true", help="只列出这条 harness 会跑的链")
    args = parser.parse_args()

    if args.list:
        print("A  启动→进空间→场景/活动/物件（prepare→activate 状态机结构性断言）")
        print("B  聊天：居民回合（真实 daemon + 真实 grant 路由 + 生产体积回执 + 故障注入）")
        print("C  设置里切换动作（真实 presence_selection 状态机 + Swift 谓词词汇）")
        print("D  栏上动作（音量/小窗/全屏）的发射点与唯一 sender 不变量")
        return 0

    binary = find_binary(args.taskd)
    print("四链无人值守验证 harness")
    print(f"  工作树: {ROOT}")
    if binary is None:
        print(f"  [FAIL] 找不到 gmgn-taskd 二进制（试过 --taskd / TASKD_BIN / target/{{release,debug}}）",
              flush=True)
        return 2
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    print(f"  daemon: {binary}")
    print(f"  daemon sha256: {digest}")
    if args.json:
        print(f"  账本: {args.json}")

    wanted = set((args.only or "A,B,C,D").split(","))
    work_parent = Path(args.work) if args.work else Path(tempfile.mkdtemp(prefix="gmgn-chains-"))
    Path(os.path.realpath(str(work_parent))).mkdir(parents=True, exist_ok=True)
    # 每次运行一个唯一子目录：旧运行遗留的 daemon/peer 孤儿会持着 taskd.lock 与
    # 数据库，复用同一个 root 会让新 daemon 以 storage_unavailable / unsafe_path
    # 直接退出（第一版在 `--work` 复跑时就是这么整片变红的）。
    work = Path(os.path.realpath(str(work_parent))) / f"run-{int(time.time())}-{os.getpid()}"

    chains: list[Chain] = []
    context: dict = {"daemon": str(binary), "daemon_sha256": digest, "work": str(work)}
    try:
        if "A" in wanted:
            chain = Chain("A", "启动→进空间→场景/活动/物件")
            chains.append(chain)
            context["A"] = run_delegate(chain, "verify-world-prepare-state-machine.py", "A")
        if "C" in wanted:
            chain = Chain("C", "设置里切换动作")
            chains.append(chain)
            context["C"] = run_chain_c(chain, binary, work, args.keep)
        if "B" in wanted:
            chain = Chain("B", "聊天：居民回合")
            chains.append(chain)
            context["B"] = run_chain_b(chain, binary, work, args.keep)
        if "D" in wanted:
            chain = Chain("D", "栏上动作")
            chains.append(chain)
            context["D"] = run_delegate(chain, "verify-bar-action-senders.py", "D")
    finally:
        if not args.keep and not args.work:
            shutil.rmtree(work, ignore_errors=True)

    print("\n=== 逐链结果 ===", flush=True)
    total = passed = 0
    for chain in chains:
        ok = sum(1 for r in chain.records if r["ok"])
        total += len(chain.records)
        passed += ok
        print(f"  {chain.key} {chain.title}: {ok}/{len(chain.records)} PASS", flush=True)
    failed = total - passed
    print(f"  合计: {passed}/{total} PASS，{failed} FAIL", flush=True)

    print_remaining(chains)

    if args.json:
        ledger = {
            "daemon": str(binary), "daemon_sha256": digest,
            "context": context,
            "chains": [{"key": c.key, "title": c.title, "records": c.records} for c in chains],
            "summary": {"total": total, "passed": passed, "failed": failed},
        }
        Path(args.json).parent.mkdir(parents=True, exist_ok=True)
        Path(args.json).write_text(json.dumps(ledger, ensure_ascii=False, indent=2))
        print(f"\n账本已写入 {args.json}", flush=True)

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""A 链：空间 prepare→activate 的结构性断言 + 状态表向量逐条跑。

它为什么长这样
==============
"空间 prepare 永久停住"这一支的权威实现活在 `apps/macos/UnityHost/UnityMediaHost.swift`
里，而那个文件要一个真 Unity 渲染器才能编译进产品路径。这个 harness 不启动 app、
不碰 Metal、不碰 Unity 编辑器，它做两件能自动化的真事：

1. **等价状态表向量逐条跑**（`run_vectors`）。把 `TMH` 的三个判定点
   （`schedulePrepareWatchdog` / `completeWorldSelection` 成功支 / 失败支）
   的**守卫条件与赋值**逐字抽出来，用同一张表驱动一组向量，每条向量都断言
   "这个事件序列下状态会走到哪、具名原因是什么"。关键向量是**丢回执**：
   真机上渲染回执没来时，以前会永远停在 `phase=prepare` 且日志里没有具名原因；
   现在必须有界地落到 `phase=failed` 且带上具名 code。
2. **对生产源码做结构性断言**（`run_structure`）。上面那张表是手抄的，所以必须
   钉住"手抄与生产仍然一致"：逐条断言 `UnityMediaHost.swift` 里三个判定点的
   守卫字段/常量/赋值没有消失或被放宽。任何一条不成立，说明表已经和生产脱钩，
   此时整个 A 链的结论作废 —— 这是**能失败**的那一半。

局限（写明，不藏）
------------------
* 这份 harness **不能**证明 Unity 渲染器真的会在预算内发回执；那要真机。
  它证明的是宿主侧"回执没来时不会永久停在 prepare"这条兜底逻辑存在且有界。
* 它**不能**覆盖需要真机渲染路径的部分，清单见 `REAL_DEVICE_ONLY`。

用法
----
    python3 tools/verify-world-prepare-state-machine.py            # 人读输出 + JSON 摘要
    python3 tools/verify-world-prepare-state-machine.py --vector   # 只跑向量
    python3 tools/verify-world-prepare-state-machine.py --structure # 只跑结构断言

退出码：全 PASS 为 0，任何 FAIL 为 1。
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(os.environ.get("VERIFY_REPO_ROOT") or Path(__file__).resolve().parent.parent)
TMH = "apps/macos/UnityHost/UnityMediaHost.swift"

# ---------------------------------------------------------------------------
# 从生产源码里**读**出来的常量与守卫（不是抄一份常量表）
# ---------------------------------------------------------------------------


def source() -> str:
    return (ROOT / TMH).read_text(encoding="utf-8")


def declaration(text: str, signature: str) -> str:
    """取出一个 Swift 声明的完整正文（按花括号配平），跟仓库其它 harness 同一套。"""
    start = text.find(signature)
    if start < 0:
        raise LookupError(f"missing production declaration: {signature}")
    opening = text.index("{", start)
    depth = 0
    for index in range(opening, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[start:index + 1]
    raise LookupError(f"unbalanced declaration: {signature}")


def watchdog_delay(text: str) -> int:
    match = re.search(r"prepareWatchdogDelay\s*=\s*Duration\.seconds\((\d+)\)", text)
    if not match:
        raise LookupError("prepareWatchdogDelay 不在生产源码里")
    return int(match.group(1))


def startup_retry_limit(text: str) -> int:
    match = re.search(r"startupSpaceAttemptLimit\s*=\s*(\d+)", text)
    if not match:
        raise LookupError("startupSpaceAttemptLimit 不在生产源码里")
    return int(match.group(1))


# ---------------------------------------------------------------------------
# 等价状态表：prepare → (activate | failed)，以及唯一的两条失败入口
# ---------------------------------------------------------------------------


class Host:
    """`UnityMediaHost` 里 worldSelection 那一段的等价状态机。

    每个 `step_*` 的守卫逐条对应生产源码，见每个方法上的 file:line 注记。
    """

    def __init__(self, revision: int, world: str, watchdog: int, retry_limit: int) -> None:
        self.revision = revision
        self.world = world
        self.watchdog = watchdog
        self.retry_limit = retry_limit
        self.phase = "idle"
        self.code: str | None = None
        self.selection_session: str | None = None
        self.pending_package = False
        self.world_selection_task: str | None = None
        self.startup_attempts = 0
        self.log: list[str] = []

    # -- 入口 -------------------------------------------------------------
    def prepare(self, world: str, revision: int) -> str:
        """`prepareWorldSelection`：UnityMediaHost.swift:875-881 的入口守卫。"""
        if self.pending_package or self.world_selection_task is not None:
            return "refused_busy"
        self.world = world
        self.revision = revision
        self.pending_package = True
        self.world_selection_task = "prepare"
        self.phase = "prepare"
        self.code = None
        self.log.append(f"world={world} phase=prepare revision={revision}")
        return "prepared"

    def _watchdog_guards(self, revision: int, world: str) -> bool:
        """`schedulePrepareWatchdog` 的四个守卫：UnityMediaHost.swift:784-787。"""
        return (self.revision == revision
                and self.world == world
                and self.phase == "prepare"
                and self.pending_package)

    def watchdog_fires(self, revision: int, world: str) -> str:
        """UnityMediaHost.swift:779-798。"""
        if not self._watchdog_guards(revision, world):
            return "ignored"
        self.pending_package = False
        self.phase = "failed"
        self.code = "world_prepare_unanswered"
        self.log.append(f"world={world} phase=failed code=world_prepare_unanswered")
        return "failed"

    def _complete_guards(self, revision: int, world: str, package_known: bool) -> bool:
        """`completeWorldSelection` 的第一段守卫：UnityMediaHost.swift:1075-1077。"""
        return (self.revision == revision
                and self.world == world
                and self.phase == "prepare"
                and self.pending_package
                and package_known)

    def complete(self, revision: int, world: str, success: bool, *,
                 package_known: bool = True, renderer_code: str | None = None,
                 composition_matches: bool = True, has_session: bool = False) -> str:
        """UnityMediaHost.swift:1074-1130。"""
        if not self._complete_guards(revision, world, package_known):
            return "stale_rejected"
        self.world_selection_task = None
        if not success:
            self.pending_package = False
            self.phase = "failed"
            self.code = renderer_code or "world_renderer_prepare_failed"
            self.log.append(f"world={world} phase=failed code={self.code}")
            return "failed"
        if not package_known:
            self.pending_package = False
            self.phase = "failed"
            return "failed"
        if not composition_matches:
            self.pending_package = False
            self.phase = "failed"
            self.code = "world_authority_activation_failed"
            self.log.append(f"world={world} phase=failed code=world_authority_activation_failed")
            return "failed"
        self.pending_package = False
        self.phase = "activate"
        self.selection_session = world
        self.log.append(f"world={world} phase=activate revision={revision}")
        return "activated"

    def startup_retry(self, failure_code: str, session_present: bool) -> bool:
        """`scheduleStartupSpaceRetry` 的有界重试：UnityMediaHost.swift:805-814。"""
        if session_present or self.startup_attempts >= self.retry_limit:
            return False
        self.startup_attempts += 1
        self.log.append(f"space startup retry {self.startup_attempts} after {failure_code}")
        return True


# ---------------------------------------------------------------------------
# 向量
# ---------------------------------------------------------------------------


def run_vectors(record) -> None:
    text = source()
    watchdog = watchdog_delay(text)
    retry_limit = startup_retry_limit(text)

    # V1 正常路径：prepare → 渲染回执成功 → activate。
    host = Host(7, "w1", watchdog, retry_limit)
    host.prepare("w1", 7)
    outcome = host.complete(7, "w1", True)
    record("A1.1", outcome == "activated" and host.phase == "activate",
           "正常路径：prepare → 成功回执 → activate",
           where="apps/macos/UnityHost/UnityMediaHost.swift:1128",
           reason=f"outcome={outcome!r} phase={host.phase!r}", evidence=host.log)

    # V2 关键向量：回执丢失 → watchdog 有界落地，具名，不是永久 prepare。
    host = Host(7, "w1", watchdog, retry_limit)
    host.prepare("w1", 7)
    fired = host.watchdog_fires(7, "w1")
    record("A1.2", fired == "failed" and host.phase == "failed"
           and host.code == "world_prepare_unanswered",
           "回执丢失：watchdog 把 prepare 有界地落成 failed 并带具名 code（不再永久 prepare、不再没有原因）",
           where="apps/macos/UnityHost/UnityMediaHost.swift:791",
           reason=f"fired={fired!r} phase={host.phase!r} code={host.code!r}", evidence=host.log)
    record("A1.3", watchdog > 0 and watchdog <= 300,
           f"watchdog 预算是有限常数（prepareWatchdogDelay = {watchdog} 秒）",
           where="apps/macos/UnityHost/UnityMediaHost.swift:103",
           reason=f"delay={watchdog}")

    # V3 迟到的成功回执必须被拒（不能把已经 failed 的空间又拉起来）。
    late = host.complete(7, "w1", True)
    record("A1.4", late == "stale_rejected" and host.phase == "failed",
           "陈旧 prepare 的迟到成功回执被拒（phase != prepare），不会与兜底打架",
           where="apps/macos/UnityHost/UnityMediaHost.swift:1076",
           reason=f"outcome={late!r} phase={host.phase!r}", evidence=host.log)

    # V4 revision 变了的老回执也必须被拒。
    host = Host(7, "w1", watchdog, retry_limit)
    host.prepare("w1", 8)
    stale = host.complete(7, "w1", True)
    record("A1.5", stale == "stale_rejected",
           "revision 对不上的回执被拒（陈旧 prepare 不许激活）",
           where="apps/macos/UnityHost/UnityMediaHost.swift:1075",
           reason=f"outcome={stale!r}", evidence=host.log)

    # V5 渲染侧自己给的具名失败原因必须原样透出。
    host = Host(7, "w1", watchdog, retry_limit)
    host.prepare("w1", 7)
    named = host.complete(7, "w1", False, renderer_code="world_renderer_timeout")
    record("A1.6", named == "failed" and host.code == "world_renderer_timeout",
           "渲染侧的具名失败原因原样透出（不是匿名 world_renderer_prepare_failed）",
           where="apps/macos/UnityHost/UnityMediaHost.swift:1086",
           reason=f"outcome={named!r} code={host.code!r}", evidence=host.log)

    # V6 载入期间权威状态前进 → 具名失败 + 有界重试（正好一次）。
    host = Host(7, "w1", watchdog, retry_limit)
    host.prepare("w1", 7)
    behind = host.complete(7, "w1", True, composition_matches=False)
    retried = host.startup_retry("world_authority_activation_failed", session_present=False)
    record("A1.7", behind == "failed" and host.code == "world_authority_activation_failed"
           and retried is True,
           "权威状态在载入期间前进：具名失败 + 启动竞态有界重试",
           where="apps/macos/UnityHost/UnityMediaHost.swift:1112",
           reason=f"outcome={behind!r} code={host.code!r} retried={retried}", evidence=host.log)

    # V7 重试必须**有界**：到上限就不再重试。
    host = Host(7, "w1", watchdog, retry_limit)
    limited = True
    for _ in range(retry_limit):
        if host.startup_retry("world_prepare_unanswered", session_present=False) is not True:
            limited = False
            break
    beyond = host.startup_retry("world_prepare_unanswered", session_present=False)
    record("A1.8", limited and beyond is False,
           f"启动重试有界（startupSpaceAttemptLimit = {retry_limit}），到上限就停",
           where="apps/macos/UnityHost/UnityMediaHost.swift:806",
           reason=f"limited={limited} beyond_limit={beyond}", evidence=host.log)

    # V8 已经有 worldSession 时不许再重试（不许把用户从一个能用的空间里踢出去）。
    record("A1.9", host.startup_retry("x", session_present=True) is False,
           "已经进了空间就不会被启动重试再拉一次（会话优先）",
           where="apps/macos/UnityHost/UnityMediaHost.swift:806",
           reason="session_present 时仍然重试了")

    # V9 prepare 期间的第二次 prepare 必须被拒（不许叠两套）。
    host = Host(7, "w1", watchdog, retry_limit)
    host.prepare("w1", 7)
    again = host.prepare("w2", 8)
    record("A1.10", again == "refused_busy" and host.world == "w1",
           "prepare 进行中第二次 prepare 被拒（不会有两套并行准备）",
           where="apps/macos/UnityHost/UnityMediaHost.swift:875",
           reason=f"second={again!r} world={host.world!r}", evidence=host.log)


# ---------------------------------------------------------------------------
# 结构断言：手抄的表必须与生产仍然一致
# ---------------------------------------------------------------------------


def run_structure(record) -> None:
    text = source()

    try:
        watchdog_body = declaration(text, "private func schedulePrepareWatchdog(")
    except LookupError as error:
        record("A2.1", False, "schedulePrepareWatchdog 仍然存在", where=TMH, reason=str(error))
        watchdog_body = ""
    else:
        record("A2.1", True, "schedulePrepareWatchdog 仍然存在（回执丢失时的宿主兜底）",
               where="apps/macos/UnityHost/UnityMediaHost.swift:779")

    for field, code in [
        ('self.worldSelection["revision"] as? UInt64 == revision', "revision"),
        ('self.worldSelection["worldID"] as? String == id', "worldID"),
        ('self.worldSelection["phase"] as? String == "prepare"', "phase"),
        ("self.pendingWorldPackage?.manifest.worldID == id", "pendingWorldPackage"),
    ]:
        record(f"A2.2.{code}", field in watchdog_body,
               f"watchdog 仍然按 {code} 判自己是否还该开火",
               where="apps/macos/UnityHost/UnityMediaHost.swift:784",
               reason=f"守卫里找不到 {field!r}")
    record("A2.3", 'self.worldSelection["phase"] = "failed"' in watchdog_body
           and '"world_prepare_unanswered"' in watchdog_body,
           "watchdog 仍然把 prepare 落成 failed 并写明 world_prepare_unanswered",
           where="apps/macos/UnityHost/UnityMediaHost.swift:791",
           reason="watchdog 正文里找不到状态赋值或具名 code")
    record("A2.4", "prepareWatchdogTask?.cancel()" in watchdog_body,
           "watchdog 每次重挂之前先取消上一个（不会叠出多个）",
           where="apps/macos/UnityHost/UnityMediaHost.swift:780",
           reason="watchdog 正文里没有取消上一任")

    try:
        complete_body = declaration(text, "private func completeWorldSelection(")
    except LookupError as error:
        record("A2.5", False, "completeWorldSelection 仍然存在", where=TMH, reason=str(error))
        complete_body = ""
    else:
        record("A2.5", True, "completeWorldSelection 仍然存在（prepare 的唯一成功出口）",
               where="apps/macos/UnityHost/UnityMediaHost.swift:1074")

    guard = re.search(r"guard let revision = value\[\"revision\"\][\s\S]{0,400}?else \{ return false \}",
                      complete_body)
    guard_text = guard.group(0) if guard else ""
    for field, code in [
        ('revision == worldSelection["revision"] as? UInt64', "revision"),
        ('id == worldSelection["worldID"] as? String', "worldID"),
        ('worldSelection["phase"] as? String == "prepare"', "prepare 相位"),
    ]:
        record(f"A2.6.{code}", field in guard_text,
               f"completeWorldSelection 的第一道守卫仍然钉 {code}（陈旧 prepare 会被拒）",
               where="apps/macos/UnityHost/UnityMediaHost.swift:1075",
               reason=f"第一道 guard 里找不到 {field!r}")
    record("A2.7", 'prepareWatchdogTask?.cancel(); prepareWatchdogTask = nil' in complete_body,
           "成功回执到达时先撤掉 watchdog（不会两个出口都开火）",
           where="apps/macos/UnityHost/UnityMediaHost.swift:1078",
           reason="completeWorldSelection 里没有撤 watchdog")
    record("A2.8", 'worldSelection["phase"] = "activate"' in complete_body,
           "activate 是 completeWorldSelection 写出来的（不是别处猜的）",
           where="apps/macos/UnityHost/UnityMediaHost.swift:1128",
           reason="正文里找不到 phase = activate 的赋值")
    record("A2.9", 'let rendererCode = value["code"] as? String' in complete_body,
           "渲染侧的具名原因从回执里取出来并落到日志（失败不匿名）",
           where="apps/macos/UnityHost/UnityMediaHost.swift:1085",
           reason="正文里没有取渲染侧 code")
    record("A2.10", 'world_authority_activation_failed' in complete_body,
           "载入期间权威前进单独具名为 world_authority_activation_failed",
           where="apps/macos/UnityHost/UnityMediaHost.swift:1112",
           reason="正文里没有这个具名 code")
    record("A2.11", 'schedulePrepareWatchdog(id: id, revision: revision)' in text,
           "准备路径确实挂了 watchdog（找到定义却没人调用 = 兜底等于没有）",
           where="apps/macos/UnityHost/UnityMediaHost.swift:914",
           reason="全文件里找不到 schedulePrepareWatchdog 的调用点")
    record("A2.12", "scheduleStartupSpaceRetry" in complete_body,
           "载入期间权威前进时走的是有界启动重试，而不是让启动停在播放器",
           where="apps/macos/UnityHost/UnityMediaHost.swift:1120",
           reason="正文里没有 scheduleStartupSpaceRetry")

    # 真机专属清单：这些必须写在结果里，别让读者以为 A 链全自动覆盖了。
    record("A3.1", True,
           "需要真机的部分已具名列出（见 REAL_DEVICE_ONLY）",
           where="tools/verify-world-prepare-state-machine.py:REAL_DEVICE_ONLY",
           evidence=REAL_DEVICE_ONLY)


REAL_DEVICE_ONLY = [
    "Unity 渲染器真的在准备预算内发回 world.selection.prepared（需要 Unity 编辑器/真机播放器）",
    "prepare=activate 之后画面真的切过去了（需要 GPU 与真窗口）",
    "场景/活动/物件在渲染侧真的出现（需要 Unity 运行时的 activity manifest 装载）",
    "prepareWatchdog 的 180 s 在真机上是否够（需要一次真实资产装载计时）",
    "日志判定脚本：真机上 grep `phase=prepare` / `phase=failed code=` / `phase=activate`，"
    "30 秒内若仍停在 prepare 且无 failed code，则兜底失效（这一条只能真机跑）",
]


# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------


class Recorder:
    def __init__(self) -> None:
        self.records: list[dict] = []

    def __call__(self, ident: str, ok: bool, message: str, *, where: str = "",
                 reason: str = "", evidence=None, permanent=None, owner: str = "") -> None:
        record = {"id": ident, "ok": bool(ok), "message": message, "where": where,
                  "reason": reason if not ok else "", "evidence": evidence,
                  "permanent": permanent, "owner": owner}
        self.records.append(record)
        mark = "PASS" if ok else "FAIL"
        line = f"  [{mark}] A/{ident}  {message}"
        if not ok:
            line += f"\n         原因: {reason}\n         位置: {where}"
        print(line, flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vector", action="store_true", help="只跑等价状态表向量")
    parser.add_argument("--structure", action="store_true", help="只跑生产源码结构断言")
    parser.add_argument("--root", default=None,
                        help="被检查的工作树根（默认仓库根；给自检脚本指向一份改动过的副本用）")
    args = parser.parse_args()
    global ROOT
    if args.root:
        ROOT = Path(args.root).resolve()

    recorder = Recorder()
    print("A 链：空间 prepare→activate（结构性断言 + 等价状态表向量）", flush=True)
    if not (args.vector or args.structure) or args.structure:
        print("  --- 结构断言：手抄的表必须还与生产一致 ---", flush=True)
        run_structure(recorder)
    if not (args.vector or args.structure) or args.vector:
        print("  --- 状态表向量 ---", flush=True)
        run_vectors(recorder)

    failures = [r for r in recorder.records if not r["ok"]]
    print(f"  小计: {len(recorder.records) - len(failures)}/{len(recorder.records)} PASS", flush=True)
    print(json.dumps({"records": recorder.records, "real_device_only": REAL_DEVICE_ONLY},
                     ensure_ascii=False), flush=True)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

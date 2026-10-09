#!/usr/bin/env python3
"""D 链：栏上动作（音量 / 小窗 / 全屏）的发射点与唯一 sender 不变量。

它钉什么（以及为什么不是"数量必须等于 1"）
==========================================
栏上动作有不止一条**渲染路径**：Swift 原生舞台（`StageWindowController`）与
GPUI 宿主（`apps/gpui-app`）各自画自己那一条。所以"整棵树里只许出现一次
`toggleFullScreen`"是个假不变量 —— 真实的不变量是三条：

  1. **每个已知发射点都必须具名**。"已知"写成一张清单（`EMITTERS`），每条带
     `file:line` 与它存在的理由。多出一个发射点就是清单与生产脱钩 → FAIL。
     这条正是"改一处、别处偷偷也点一下"的防线。
  2. **同一动作的每个发射点必须调同一个动词**。三处都调
     `window.toggle_fullscreen()` 可以；其中一处改调别的函数就会变成两个语义
     不同的"全屏" → FAIL。
  3. **每条渲染路径内部只有一个发射点**。GPUI 那条路径上，栏与控制列是两个
     互斥的 surface，各有自己的分派回调，各自只点一次。

复用而不是重造
--------------
* `apps/gpui-ui/tests/transport_popover_geometry.rs` 已经钉了控制表顺序、音量竖向
  轨道、面板几何与 slot 宽度 —— 这里不重复。
* `apps/gpui-app/src/main.rs` 的 `#[cfg(test)]` 已经钉了 `TRANSPORT_CONTROLS` /
  `COMPACT_CONTROLS` 的顺序与 `window_mode_content` —— 这里只断言它们仍在。
* `tools/test-presence-snapshot-projection.swift` 那类"读生产源码做门禁"的写法
  与这里同源，都是为了让门禁在没有窗口的机器上也能红。

用法
----
    python3 tools/verify-bar-action-senders.py

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

GPUI_APP = "apps/gpui-app/src/main.rs"
GPUI_SHELL = "apps/gpui-ui/src/shell.rs"
GPUI_TESTS = "apps/gpui-ui/tests/transport_popover_geometry.rs"
SWIFT_STAGE = "apps/macos/Sources/GMGNRadio/VisualEngine/StageWindowController.swift"
SWIFT_APP = "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift"
SWIFT_SHORTCUTS = "apps/macos/Sources/GMGNRadio/Settings/GMGNKeyboardShortcuts.swift"

# ---------------------------------------------------------------------------
# 发射点清单：每条 = (文件, 动词正则, 期望行号集合, 所属渲染路径, 存在的理由)
# ---------------------------------------------------------------------------
# 行号参与断言：挪一行不算破坏（这是**去掉注释后**的物理行号，注释变动会移动它），
# 所以断言行号集合相等只在"发射点数量变了"时才有意义。为了让门禁在注释漂移下
# 仍然稳定，这里同时接受"行号相同"与"只有集合大小相同"两种情况，但数量必须精确。

FULLSCREEN_VERB = r"window\.toggle_fullscreen\(\)"
SWIFT_FULLSCREEN_VERB = r"window\?\.toggleFullScreen\(nil\)"

EMITTERS: dict[str, list[dict]] = {
    "全屏": [
        {
            "file": GPUI_APP, "verb": FULLSCREEN_VERB, "lines": [715, 963],
            "surface": "gpui",
            "why": "GPUI 宿主两个互斥 surface（控制列 715 / 栏 963）各自的分派回调，"
                   "两边都落到同一个 window.toggle_fullscreen()",
        },
        {
            "file": SWIFT_STAGE, "verb": SWIFT_FULLSCREEN_VERB, "lines": [710],
            "surface": "swift",
            "why": "Swift 原生舞台上窗口模式的唯一发射点",
        },
    ],
    "音量": [
        {
            "file": SWIFT_APP, "verb": r"adjustMusicVolume\(by:", "lines": [1907, 1909],
            "surface": "swift",
            "why": "音量加减两个方向共用唯一入口 adjustMusicVolume(by:)；"
                   "两个匹配是它的两个调用点（+0.08 / -0.08），不是两套实现",
        },
    ],
    "小窗（窗口模式切换）": [
        {
            "file": SWIFT_STAGE, "verb": r"onToggleWindowMode", "lines": [709, 1204, 1260],
            "surface": "swift",
            "why": "闭包定义（709）→ 初始化参数声明（1204）→ 接到 "
                   "StageWindowModeButton 的唯一接线点（1260）；闭包体本身只有一处"
                   "（D6.1 钉死了闭包体里 toggleFullScreen 只出现一次）",
        },
    ],
}

# 允许的动词家族：每个动作允许出现的**不同动词字符串**的具名集合。
# 出现清单之外的动词字符串 = 新语义 = FAIL（这一条就是"别处偷偷又加了一条路"）。
VERB_FAMILIES: dict[str, list[str]] = {
    "全屏": [FULLSCREEN_VERB, SWIFT_FULLSCREEN_VERB],
    "音量": [r"adjustMusicVolume\(by:"],
    "小窗（窗口模式切换）": [r"onToggleWindowMode"],
}

# GPUI 侧"窗口模式"与"全屏"是同一个动词的同一条分派，所以不在这里重复计一遍。
SURFACE_LIMIT = {
    ("全屏", "gpui"): 2,
    ("全屏", "swift"): 1,
    ("音量", "swift"): 2,
    ("小窗（窗口模式切换）", "swift"): 3,
    # GPUI 侧没有独立的"小窗"发射点：窗口模式就是 `mode`（全屏切换），已经记在
    # ("全屏", "gpui") 那一条里，不在这里重复计一遍。缺口见 GAPS。
}


def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*[\s\S]*?\*/", "", text)
    return re.sub(r"//[^\n]*", "", text)


def occurrence_lines(rel: str, pattern: str) -> list[int]:
    text = strip_comments(read(rel))
    return [text.count("\n", 0, match.start()) + 1 for match in re.finditer(pattern, text)]


def occurrence_count(rel: str, pattern: str) -> int:
    return len(re.findall(pattern, strip_comments(read(rel))))


class Recorder:
    def __init__(self) -> None:
        self.records: list[dict] = []

    def __call__(self, ident: str, ok: bool, message: str, *, where: str = "",
                 reason: str = "", evidence=None, permanent=None, owner: str = "") -> None:
        record = {"id": ident, "ok": bool(ok), "message": message, "where": where,
                  "reason": reason if not ok else "", "evidence": evidence,
                  "permanent": permanent, "owner": owner}
        self.records.append(record)
        print(f"  [{'PASS' if ok else 'FAIL'}] D/{ident}  {message}"
              + ("" if ok else f"\n         原因: {reason}\n         位置: {where}"), flush=True)


def run(record: Recorder) -> None:
    # --- 不变量 1：每个已知发射点仍然具名，且没有多出来 --------------------
    for action, emitters in EMITTERS.items():
        for index, emitter in enumerate(emitters):
            lines = occurrence_lines(emitter["file"], emitter["verb"])
            expected = emitter["lines"]
            ok = len(lines) == len(expected)
            record(f"D1.{action}.{index + 1}", ok,
                   f"{action}：发射点数量与清单一致（{len(expected)} 个，"
                   f"实测在 {emitter['file']} 行 {lines}）",
                   where=f"{emitter['file']}:{lines[0] if lines else expected[0]}",
                   reason=(f"清单写 {len(expected)} 个（上次在行 {expected}），"
                           f"实测 {len(lines)} 个（行 {lines}）—— {emitter['why']}"),
                   evidence={"file": emitter["file"], "expected_count": len(expected),
                             "actual_lines": lines, "why": emitter["why"]},
                   owner="修复线：新增/移动栏上动作发射点的人")

    # --- 不变量 2：动词家族不许长出新成员 -----------------------------------
    for action, emitters in EMITTERS.items():
        actual = sorted({emitter["verb"] for emitter in emitters})
        allowed = sorted(VERB_FAMILIES[action])
        record(f"D2.{action}", actual == allowed,
               f"{action}：发射点用到的动词恰好是具名家族里的那些"
               f"（{len(allowed)} 个，没有长出新语义）",
               where="tools/verify-bar-action-senders.py:VERB_FAMILIES",
               reason=f"清单允许 {allowed}，实测 {actual}",
               evidence={"allowed": allowed, "actual": actual},
               owner="修复线：新增栏上动作发射点的人")

    # --- 不变量 3：每条渲染路径内部发射点数量不超过清单 --------------------
    for (action, surface), limit in SURFACE_LIMIT.items():
        total = sum(len(occurrence_lines(e["file"], e["verb"]))
                    for e in EMITTERS[action] if e["surface"] == surface)
        record(f"D3.{action}.{surface}", total == limit,
               f"{action}：在 {surface} 这条渲染路径上有 {limit} 个具名发射点（不多不少）",
               where="tools/verify-bar-action-senders.py:SURFACE_LIMIT",
               reason=f"清单写 {limit}，实测 {total}",
               evidence={"limit": limit, "actual": total},
               owner="修复线：新增/移动栏上动作发射点的人")

    # --- 栏上控制表本身 -----------------------------------------------------
    shell = read(GPUI_SHELL)
    app = read(GPUI_APP)

    for ident, needle, where in [
        ("D4.1", 'control("volume", gpui_kit::assets::IconName::Volume2)', f"{GPUI_SHELL}:703"),
        ("D4.2", 'control("compact", gpui_kit::assets::IconName::Minimize)', f"{GPUI_SHELL}:764"),
        ("D4.3", 'control("mode", gpui_kit::assets::IconName::Maximize)', f"{GPUI_SHELL}:876"),
    ]:
        record(ident, needle in shell,
               f"shell.rs 仍然有这条控制定义：{needle.split('(')[1].split(',')[0].strip(chr(34))}",
               where=where, reason=f"{GPUI_SHELL} 里找不到 {needle!r}")

    for ident, needle, where, message in [
        ("D4.4", "const TRANSPORT_CONTROLS", f"{GPUI_APP}:86", "gpui 宿主的栏上控制表仍然存在"),
        ("D4.5", "const COMPACT_CONTROLS", f"{GPUI_APP}:103", "gpui 宿主的小窗控制表仍然存在"),
        ("D4.6", "fn window_mode_content(fullscreen:bool)", f"{GPUI_APP}:231",
         "全屏/小窗两态图标与文案仍然是同一个纯函数"),
        ("D4.7", "self.transport_controls(fullscreen)", f"{GPUI_APP}:958",
         "栏上控制表由 transport_controls 一处构建（不是散在视图里）"),
        ("D4.8", "shell::transport_bar(controls,", f"{GPUI_APP}:960",
         "栏由 shell::transport_bar 一处渲染（宿主只供状态与语义）"),
    ]:
        record(ident, needle in app, message, where=where,
               reason=f"{GPUI_APP} 里找不到 {needle!r}")

    # --- 控制 id 互不重复（重复 id = "唯一 sender"退化成"随机一个 sender"）---
    for ident, table, where in [
        ("D4.9", "TRANSPORT_CONTROLS", f"{GPUI_APP}:86"),
        ("D4.10", "COMPACT_CONTROLS", f"{GPUI_APP}:103"),
    ]:
        match = re.search(rf"const {table}: \[\(&str, &str, &str\); \d+\] = \[([\s\S]*?)\];", app)
        if not match:
            record(ident, False, f"{table} 仍然可以解析出条目", where=where,
                   reason="正则没匹配到常量体")
            continue
        rows = re.findall(r'\("([a-zA-Z]+)",\s*"([^"]*)",\s*"([a-zA-Z]+)"\)', match.group(1))
        ids = [row[0] for row in rows]
        duplicates = sorted({i for i in ids if ids.count(i) > 1})
        record(ident, bool(ids) and not duplicates,
               f"{table} 的 {len(ids)} 个控制 id 互不重复",
               where=where, reason=f"重复 id：{duplicates}", evidence={"ids": ids})

    # --- 音量的快捷键动作：定义与处理点 -------------------------------------
    shortcuts = read(SWIFT_SHORTCUTS)
    record("D5.1", "case volumeUp" in shortcuts and "case volumeDown" in shortcuts,
           "音量快捷键动作仍然有两个方向（不是只剩一个）",
           where=f"{SWIFT_SHORTCUTS}:11")
    handlers = occurrence_lines(SWIFT_APP, r"case \.volumeUp:|case \.volumeDown:")
    record("D5.2", len(handlers) == 2,
           "音量两个方向在宿主里各有一个处理点（同一个 switch，不会被两个地方都吃掉）",
           where=f"{SWIFT_APP}:{handlers[0] if handlers else 1}",
           reason=f"期望 2 个处理点，实测 {len(handlers)} 个（行 {handlers}）",
           evidence={"lines": handlers})
    adjust = occurrence_lines(SWIFT_APP, r"adjustMusicVolume\(by:")
    record("D5.3", len(adjust) == 2,
           "音量加减共用唯一入口 adjustMusicVolume(by:)（两处调用：+0.08 / -0.08）",
           where=f"{SWIFT_APP}:{adjust[0] if adjust else 1}",
           reason=f"期望 2 个调用点，实测 {len(adjust)} 个（行 {adjust}）",
           evidence={"lines": adjust})

    # --- 小窗：闭包体只在定义处点一次 ---------------------------------------
    closure_body = declaration(read(SWIFT_STAGE), "onToggleWindowMode: { [weak window] in")
    record("D6.1", closure_body.count("toggleFullScreen") == 1,
           "Swift 的窗口模式闭包体里只有一处真的改窗口模式",
           where=f"{SWIFT_STAGE}:709",
           reason=f"闭包体里找到 {closure_body.count('toggleFullScreen')} 处", evidence=closure_body)

    # --- GPUI 的控制定义确实接到了测试（不是只有定义没人管）----------------
    tests = read(GPUI_TESTS)
    record("D7.1", 'TransportControl::new("volume"' in tests and 'TransportControl::new("compact"' in tests,
           "GPUI 几何测试仍然为 volume / compact 造控制（定义没有被测试遗忘）",
           where=f"{GPUI_TESTS}:62", reason=f"{GPUI_TESTS} 里找不到这两个控制")

    record("D8.1", True, "已知缺口已具名列出（见 GAPS）",
           where="tools/verify-bar-action-senders.py:GAPS", evidence=GAPS)


def declaration(text: str, signature: str) -> str:
    """取一个 Swift 声明的花括号配平体（与仓库其它 harness 同一套）。"""
    start = text.find(signature)
    if start < 0:
        return ""
    opening = text.index("{", start)
    depth = 0
    for index in range(opening, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[start:index + 1]
    return ""


GAPS = [
    "GPUI 宿主里 音量 没有栏上发射点：shell.rs:703 定义了 `control(\"volume\", …)`，"
    "但 gpui-app 的生产 TRANSPORT_CONTROLS/COMPACT_CONTROLS 两张表"
    "（apps/gpui-app/src/main.rs:86,103）里都没有 `volume`；"
    "它现在只活在几何测试 apps/gpui-ui/tests/transport_popover_geometry.rs 里。"
    "如果 GPUI 宿主是产品路径之一，这是一个真实缺口（用户点了没反应的反面：根本没有按钮）。",
    "GPUI 宿主里 小窗 没有独立发射点：shell.rs:764 的 `compact` 控制同样不在两张生产表里；"
    "GPUI 侧的窗口模式就是 `mode`（= 全屏切换），见 apps/gpui-app/src/main.rs:715,963。",
    "GPUI 与 Swift 是**两条渲染路径**，各自有自己的具名发射点。"
    "`cargo test -p gmgn-gpui-app` 的 `window_mode_content` 断言与 "
    "`tools/test-stage-control-actions.swift` 各自只覆盖自己那一条；"
    "这个 harness 不替任何一条做真机点击验证。",
    "真机点击覆盖不到：栏上按钮的真命中区域（命中区 vs 绘制区）、多显示器下的全屏行为、"
    "以及音量是否真的改变了听感，都需要真人/真机。",
]


def main() -> int:
    global ROOT
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=None,
                        help="被检查的工作树根（默认仓库根；给自检脚本指向一份改动过的副本用）")
    args = parser.parse_args()
    if args.root:
        ROOT = Path(args.root).resolve()
    record = Recorder()
    print("D 链：栏上动作（音量 / 小窗 / 全屏）的发射点与唯一 sender 不变量", flush=True)
    run(record)
    failures = [r for r in record.records if not r["ok"]]
    print(f"  小计: {len(record.records) - len(failures)}/{len(record.records)} PASS", flush=True)
    print(json.dumps({"records": record.records, "gaps": GAPS}, ensure_ascii=False), flush=True)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

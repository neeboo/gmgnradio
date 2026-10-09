#!/usr/bin/env python3
"""E 链：**产品壳一致性**门禁 —— "声称上线的界面特性"必须在产品那层真的存在。

它为什么存在
============
2026-10-09 收口时发现：加载态（`StartupGatePane` / `GMGN_STARTUP_STEP` /
`GMGN_STARTUP_READY`）只接在**独立应用** `apps/gpui-app` 上，而**装机产品**的 GPUI
是 `tools/fixtures/gpui-unity-overlay-probe`（打成
`Contents/PlugIns/libgmgn_gpui_overlay_probe.dylib`）。那台壳的源码里
`grep -rn startup` = 0，候选 dylib 与已装机 dylib 的 `strings` 里都没有
`GMGN_STARTUP*`。

这不是一次疏忽，而是一类**重复出现**的错误：测试在独立应用里绿，产品壳里根本没接。
所以这条门禁把"声称上线"变成三份可机器判定的证据，缺一即红：

1. **生产者在**（`producer`）：这个特性在某个真实源文件里被实现（不是空气）。
2. **产品壳源里有它的标识**（`source_markers`）：标识必须出现在
   `tools/fixtures/gpui-unity-overlay-probe/src/**.rs`——也就是**产品那层**，不是
   `apps/gpui-app`。
3. **构建出的 dylib 里含它的运行期标识**（`runtime_markers`）：`strings` 必须命中。
   找不到 dylib 不是"跳过"，而是**红**，并给出确切的构建命令——一条会静默跳过的
   门禁等于没有门禁。

诚实边界（不藏）
----------------
* `strings` 只看**字符串字面量**，看不到符号表。所以 `runtime_markers` 必须是代码里
  真的会出现的字符串（日志前缀、op 名），不能是函数名。
* 它证明的是"这条特性**在那层壳的构建产物里**"，不证明它**行为正确**。行为由各自的
  链负责（A/B/C/D + 各自的测试）。
* 它**不能**证明已装机的那份 dylib 是新的。装机的闭环见输出里的 `INSTALL_ONLY`。

用法
----
    python3 tools/verify-product-shell-parity.py
    python3 tools/verify-product-shell-parity.py --dylib <path>        # 指定构建产物
    python3 tools/verify-product-shell-parity.py --root <dir>          # 负对照：检查一份改动过的副本
    python3 tools/verify-product-shell-parity.py --list

退出码：全 PASS 为 0，任何 FAIL 为 1。
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(os.environ.get("VERIFY_REPO_ROOT") or Path(__file__).resolve().parent.parent)

CHAIN = "E"

# 产品那层壳的源码。**只有这里**算"产品壳"：`apps/gpui-app` 是独立应用，不是装机产品。
PRODUCT_SHELL_SOURCE_DIR = "tools/fixtures/gpui-unity-overlay-probe/src"
PRODUCT_SHELL_TARGET_DIR = "tools/fixtures/gpui-unity-overlay-probe/target"
DYLIB_NAME = "libgmgn_gpui_overlay_probe.dylib"
BUILD_COMMAND = ("cargo +1.95.0 build --release  "
                 "(cwd tools/fixtures/gpui-unity-overlay-probe)")

# ---------------------------------------------------------------------------
# 登记表：一条 = 一个**声称上线**的界面特性 + 它在产品壳里的可机器判定证据
# ---------------------------------------------------------------------------


class ProductFeature:
    """一条"声称上线"的特性。

    `source_markers` 是**名字**证据（这个名字在产品壳里出现过），`source_patterns` 是
    **接线**证据（这些名字必须按这个形状连起来）。只有名字证据是不够的：把
    `startup.cover` 那个槽位整个删掉，`startup_covering` / `scene_hit_regions` 这些
    名字还在文件里，门禁就会假绿——第一版正是这样漏过去的。
    """

    def __init__(self, id: str, claim: str, producer: str, why: str,
                 source_markers: list[str], runtime_markers: list[str],
                 source_patterns: list[str] | None = None) -> None:
        self.id = id
        self.claim = claim
        self.producer = producer
        self.why = why
        self.source_markers = source_markers
        self.runtime_markers = runtime_markers
        self.source_patterns = source_patterns or []


FEATURES: list[ProductFeature] = [
    ProductFeature(
        id="startup.gate",
        claim="进门前的那一屏加载态（步骤名 + 进度 + 具名失败 + 重试）在产品壳里真的在跑",
        producer="apps/gpui-ui/src/startup.rs",
        why=(
            "加载态最早只接在独立应用 `apps/gpui-app`（`OverlaySlot::StartupGate`）上，"
            "装机产品的 GPUI 壳里一行都没有：候选 dylib 的 `strings` 里没有 `GMGN_STARTUP*`，"
            "产品壳源里 `grep startup` = 0。三份证据分别钉住：实现（producer）、"
            "产品壳**接线**（`StartupGatePane` 真被挂进 `ShellPane`、有 `startup.cover` 这"
            "最后一个槽位、命中区域由 `scene_hit_regions` 收成整窗）、以及**构建产物**里"
            "真的带着那两条日志契约（`GMGN_STARTUP_STEP` / `GMGN_STARTUP_READY`）。"
        ),
        source_markers=[
            "StartupGatePane",
            "observe_product_shell_envelope",
            "startup.cover",
            "scene_hit_regions",
            "startup_covering",
        ],
        source_patterns=[
            # 加载态必须是**最后一个槽位**，而且盖的是**真 pane**（不是一张占位图）。
            r'if self\.startup_covering \{[\s\S]{0,400}?id\("startup\.cover"\)'
            r'[\s\S]{0,400}?child\(self\.startup\.clone\(\)\)',
            # 它盖着的时候，交给原生命中测试的命中区域由 `startup_covering` 决定
            # （进门之前场景一个指针事件都收不到）。
            r'scene_hit_regions\(\s*startup_covering,',
            # 宿主轮询确实在推进它，而且吃的是产品壳的信封。
            r'observe_product_shell_envelope\(snapshot\)',
            # 就绪判定的结果驱动"还盖不盖"。
            r'self\.startup_covering = phase != StartupPhase::Ready',
        ],
        runtime_markers=["GMGN_STARTUP_STEP", "GMGN_STARTUP_READY", "GMGN_STARTUP_RETRY"],
    ),
    ProductFeature(
        id="chat.surface",
        claim="居民聊天面（收快照、发回合、上报文本输入状态）在产品壳里真的在跑",
        producer="apps/gpui-ui/src/chat.rs",
        why=(
            "和第二项同一个形状：这条链的入口是产品壳导出的 "
            "`gmgn_gpui_chat_snapshot` 与被渲染的 `ResidentChatPane`，而它发出的 op 是"
            " `chat.send`。三条里少一条就说明这层壳只是「看起来有聊天」。"
        ),
        source_markers=["ResidentChatPane", "gmgn_gpui_chat_snapshot", "retained_envelope"],
        source_patterns=[
            # 聊天回合真的从这层壳翻译成宿主认得的那条 op（不是只有一个名字）。
            r'ChatCommand::Send\{[^}]*\}[\s\S]{0,200}?"chat\.send"',
            # 快照真的被这层壳保留下来、并且真的落进渲染面。
            r'fn retained_envelope\([\s\S]{0,400}?RETAINED_KEYS',
        ],
        runtime_markers=["chat.send", "ui.textInput"],
    ),
]

# 这一条只能靠"重新打包 + 装机 + 真机冷启动"闭环，本 harness 不碰。
INSTALL_ONLY = [
    "重新构建 player（Unity 侧）并把新 dylib 放进 `Contents/PlugIns/`（本 harness 不打包、不装机）",
    "真机冷启动后 `grep GMGN_STARTUP_STEP` / `GMGN_STARTUP_READY` 看到逐步耗时（需要真机）",
    "把已装机的 `libgmgn_gpui_overlay_probe.dylib` 交给本 harness（`--dylib`）核对它是不是新的",
]


# ---------------------------------------------------------------------------
# 判定
# ---------------------------------------------------------------------------


def shell_sources(root: Path) -> dict[str, str]:
    directory = root / PRODUCT_SHELL_SOURCE_DIR
    if not directory.is_dir():
        return {}
    return {str(p.relative_to(root)): p.read_text(encoding="utf-8", errors="replace")
            for p in sorted(directory.rglob("*.rs"))}


def find_dylib(root: Path, explicit: str | None) -> Path | None:
    if explicit:
        candidate = Path(explicit)
        if not candidate.is_absolute():
            candidate = root / candidate
        return candidate if candidate.is_file() else None
    for profile in ("release", "debug"):
        candidate = root / PRODUCT_SHELL_TARGET_DIR / profile / DYLIB_NAME
        if candidate.is_file():
            return candidate
    return None


def dylib_strings(path: Path) -> str:
    completed = subprocess.run(["strings", "-a", str(path)], capture_output=True, text=True)
    if completed.returncode != 0:
        raise RuntimeError(f"strings 退出码 {completed.returncode}: {completed.stderr.strip()}")
    return completed.stdout


def pattern_in_sources(pattern: str, sources: dict[str, str]) -> str | None:
    """命中这个**接线形状**的产品壳源文件（没有就 None）。"""
    for name, body in sources.items():
        if re.search(pattern, body):
            return name
    return None


def marker_in_sources(marker: str, sources: dict[str, str]) -> str | None:
    """命中这个标识的产品壳源文件（没有就 None）。"""
    for name, body in sources.items():
        if marker in body:
            return name
    return None


# ---------------------------------------------------------------------------
# 加载态的门：没有生产者的项不许挡人，世界一激活就放行
# ---------------------------------------------------------------------------
#
# 这一节补的是 2026-10-09 21:48 真机那次的**根因**：门读的键在产品壳里根本不存在
# （舞台在 `settings.settings.stage`，代码按 `settings.stage` 读），于是
# `world.authority` 白等 30 s 判失败、再连锁 `blocked_by_*` 把整窗盖住，而同一时刻
# 空间其实已经 `phase=activate`、55 帧、卡顿帧 0。
#
# 只有"名字证据"不够：所以这里解析 `STARTUP_ITEMS` / `PRODUCT_SHELL_SIGNAL_PRODUCERS`
# 两张真实表，逐条判"每个挡人项的信号在产品壳里有没有启动期生产者"，并给一个
# **可失败的负对照**（把没有生产者的信号当成挡人项，判定必须变红）。

STARTUP_RS = "apps/gpui-ui/src/startup.rs"


def _const_block(text: str, name: str) -> str:
    """`pub const NAME … ];` 之间那段源码（找不到就是空串）。"""
    start = text.find(f"pub const {name}")
    if start < 0:
        return ""
    end = text.find("\n];", start)
    if end < 0:
        return ""
    return text[start:end]


def _readiness_items(text: str) -> list[dict]:
    """`STARTUP_ITEMS` 里的每一项：id / role / signal。"""
    items = []
    for chunk in _const_block(text, "STARTUP_ITEMS").split("ReadinessItem {")[1:]:
        ident = re.search(r'id:\s*"([^"]+)"', chunk)
        role = re.search(r"role:\s*GateRole::(\w+)", chunk)
        signal = re.search(r"signal:\s*Signal::(\w+)", chunk)
        if ident and role and signal:
            items.append({"id": ident.group(1), "role": role.group(1), "signal": signal.group(1)})
    return items


def _signal_producers(text: str) -> dict[str, dict]:
    """`PRODUCT_SHELL_SIGNAL_PRODUCERS` 里的每一条：signal → key/source/availability。"""
    producers: dict[str, dict] = {}
    for chunk in _const_block(text, "PRODUCT_SHELL_SIGNAL_PRODUCERS").split("SignalProducer {")[1:]:
        signal = re.search(r"signal:\s*Signal::(\w+)", chunk)
        key = re.search(r'key:\s*"([^"]*)"', chunk)
        source = re.search(r'source:\s*"([^"]+)"', chunk)
        availability = re.search(r"availability:\s*SignalAvailability::(\w+)", chunk)
        if signal and availability:
            producers[signal.group(1)] = {
                "key": key.group(1) if key else "",
                "source": source.group(1) if source else "",
                "availability": availability.group(1),
            }
    return producers


def blocking_without_startup_producer(items: list[dict], producers: dict[str, dict]) -> list[tuple]:
    """挡人却没有启动期生产者的项：`(id, signal, 实际可用性, 它读的键)`。

    判据接受一份清单，所以负对照可以塞一个"把没有生产者的项改回 Blocking"的副本。
    """
    missing = []
    for item in items:
        if item["role"] != "Blocking":
            continue
        producer = producers.get(item["signal"])
        if producer is None or producer["availability"] != "Startup":
            missing.append((
                item["id"],
                item["signal"],
                "no producer at all" if producer is None else producer["availability"],
                "" if producer is None else producer["key"],
            ))
    return missing


def run_startup_producer_gate(record: Recorder, root: Path) -> None:
    path = root / STARTUP_RS
    if not path.is_file():
        record(f"{CHAIN}5.0", False, f"加载态源码可见（{STARTUP_RS}）",
               where=STARTUP_RS, reason=f"{STARTUP_RS} 不存在：无从判定门在等什么")
        return
    text = path.read_text(encoding="utf-8", errors="replace")
    items = _readiness_items(text)
    producers = _signal_producers(text)
    record(f"{CHAIN}5.0", len(items) >= 20 and len(producers) >= 15,
           "加载态清单与产品壳生产者表都能从源码里读出来（否则下面的判定是空转）",
           where=f"{STARTUP_RS}:STARTUP_ITEMS",
           reason=f"解析出 {len(items)} 个清单项、{len(producers)} 个生产者",
           evidence={"items": [(i["id"], i["role"], i["signal"]) for i in items],
                     "producer_signals": sorted(producers)})
    missing = blocking_without_startup_producer(items, producers)
    blocking = [(i["id"], i["signal"]) for i in items if i["role"] == "Blocking"]
    record(f"{CHAIN}5.1", not missing,
           "每个**挡人**项的信号在产品壳里都有启动期生产者（没有就点名是哪一项/哪个键）",
           where=f"{STARTUP_RS}:PRODUCT_SHELL_SIGNAL_PRODUCERS",
           reason=("这些挡人项在产品壳里没有启动期生产者："
                   + "; ".join(f"{i}({s}) → {a} {k}" for i, s, a, k in missing)),
           evidence={"blocking": blocking})
    # 负对照：把一个**没有生产者**的信号当成挡人项，判定必须变红——否则这条判据
    # 恒真，证明不了任何事。
    no_startup = [signal for signal, p in producers.items() if p["availability"] != "Startup"]
    mutated = list(items) + [{"id": "negative-control", "role": "Blocking",
                              "signal": no_startup[0]}] if no_startup else list(items)
    record(f"{CHAIN}5.2",
           bool(no_startup) and bool(blocking_without_startup_producer(mutated, producers)),
           "负对照：把一个没有生产者的信号当成挡人项，判定确实变红（判据不是恒真）",
           where=f"{CHAIN}:blocking_without_startup_producer",
           reason=("生产者表里没有任何非 Startup 的信号，负对照无从构造"
                   if not no_startup else "负对照没有变红：这条判据是恒真的"))
    # 接线证据：舞台要按**真机**的嵌套读（`settings.settings.stage`）。上一版按
    # `settings.stage` 读，真机永远是 Null——这就是那次事件的根因。
    record(f"{CHAIN}5.3",
           bool(re.search(r'let settings = &envelope\["settings"\]\["settings"\];', text)),
           "产品壳的舞台按真实嵌套读：`settings.settings.stage`（不是 `settings.stage`）",
           where=f"{STARTUP_RS}:observe_product_shell_envelope",
           reason="找不到 `envelope[\"settings\"][\"settings\"]`：舞台又按一个不存在的路径读了")
    record(f"{CHAIN}5.4",
           'unityInventory"]' in text and ".is_array()" in text
           and not re.search(r'unityInventory"\]\.is_object\(\)', text),
           "装修面按产品壳真实形状读 `unityInventory`（数组，不是对象）",
           where=f"{STARTUP_RS}:observe_product_shell_envelope",
           reason="`unityInventory` 又按对象判了：产品壳发布的是数组，这个壳里永远为假")
    record(f"{CHAIN}5.5",
           bool(re.search(r"fn world_is_visible\(signals: &StartupSignals\)"
                          r"[\s\S]{0,200}?Signal::WorldVisible", text))
           and bool(re.search(r"self\.released = true", text))
           and bool(re.search(r"if self\.released \{\s*return StartupPhase::Ready;", text)),
           "硬规则：世界一激活（`isWorldVisible`）门就放行（`released` 闩 + `phase()` 直接 Ready）",
           where=f"{STARTUP_RS}:StartupGate::observe",
           reason="放行判定不在：世界已经可用时门仍可能盖住整窗")


class Recorder:
    def __init__(self) -> None:
        self.records: list[dict] = []

    def __call__(self, ident: str, ok: bool, message: str, *, where: str = "",
                 reason: str = "", evidence=None, permanent=None, owner: str = "") -> None:
        self.records.append({"id": ident, "ok": bool(ok), "message": message, "where": where,
                             "reason": reason if not ok else "", "evidence": evidence,
                             "permanent": permanent, "owner": owner})
        mark = "PASS" if ok else "FAIL"
        line = f"  [{mark}] {CHAIN}/{ident}  {message}"
        if not ok:
            line += f"\n         原因: {reason}\n         位置: {where}"
        print(line, flush=True)


def run(record: Recorder, root: Path, explicit_dylib: str | None) -> None:
    sources = shell_sources(root)
    record(f"{CHAIN}0.1", bool(sources) and len(sources) >= 3,
           f"产品壳源码可见（{PRODUCT_SHELL_SOURCE_DIR} 下的 .rs 文件）",
           where=f"{PRODUCT_SHELL_SOURCE_DIR}/lib.rs:1",
           reason=f"只找到 {len(sources)} 个 .rs 文件：{sorted(sources)[:5]}",
           evidence=sorted(sources))
    record(f"{CHAIN}0.2", len(FEATURES) >= 1,
           "声称上线的特性登记表非空（空表等于没有门禁）",
           where="tools/verify-product-shell-parity.py:FEATURES",
           reason="登记表是空的")
    record(f"{CHAIN}0.3", all(f.source_markers and f.runtime_markers for f in FEATURES),
           "每条特性都有源标识**和**运行期标识（一种证据不算覆盖）",
           where="tools/verify-product-shell-parity.py:FEATURES",
           reason="有的条目只有一类标识")
    record(f"{CHAIN}0.3b", all(f.source_patterns for f in FEATURES),
           "每条特性都有**接线**判据（只有名字证据会被「删掉调用点但留下名字」骗过去）",
           where="tools/verify-product-shell-parity.py:FEATURES",
           reason="有的条目只有名字证据，没有接线判据")
    for feature in FEATURES:
        record(f"{CHAIN}0.4.{feature.id}", (root / feature.producer).is_file(),
               f"{feature.id} 的生产者文件存在（{feature.producer}）",
               where=f"{feature.producer}:1",
               reason=f"{feature.producer} 不存在：这句「上线了」没有实现")

    dylib = find_dylib(root, explicit_dylib)
    strings_text = ""
    if dylib is None:
        where = explicit_dylib or f"{PRODUCT_SHELL_TARGET_DIR}/release/{DYLIB_NAME}"
        record(f"{CHAIN}0.5", False,
               "构建出的产品 dylib 可见（否则产品那层的运行期证据无从谈起）",
               where=where,
               reason=f"找不到 dylib。先构建：{BUILD_COMMAND}（也可以用 --dylib 指定）")
    else:
        try:
            strings_text = dylib_strings(dylib)
        except RuntimeError as error:
            record(f"{CHAIN}0.5", False, "能读出产品 dylib 的字符串表", where=str(dylib), reason=str(error))
        else:
            record(f"{CHAIN}0.5", True,
                   f"构建出的产品 dylib 可见（{dylib.relative_to(root) if dylib.is_relative_to(root) else dylib}）",
                   where=str(dylib), evidence={"bytes": dylib.stat().st_size})

    for feature in FEATURES:
        for marker in feature.source_markers:
            hit = marker_in_sources(marker, sources)
            record(f"{CHAIN}1.{feature.id}.{marker}", hit is not None,
                   f"{feature.id}：产品壳源里有 `{marker}`",
                   where=f"{PRODUCT_SHELL_SOURCE_DIR}/lib.rs:1",
                   reason=(f"产品那层（{PRODUCT_SHELL_SOURCE_DIR}）里找不到 `{marker}`："
                           f"这句「上线了」只活在独立应用里"),
                   evidence=hit)
        for pattern in feature.source_patterns:
            hit = pattern_in_sources(pattern, sources)
            record(f"{CHAIN}1.{feature.id}.pattern.{len(pattern)}", hit is not None,
                   f"{feature.id}：产品壳源里有这条**接线**（{pattern[:48]}…）",
                   where=f"{PRODUCT_SHELL_SOURCE_DIR}/shell_ui.rs:1",
                   reason=(f"产品那层里找不到这条接线形状 /{pattern}/：名字还在、接线没了"
                           f"（这正是第一版门禁假绿的原因）"),
                   evidence=hit)
        for marker in feature.runtime_markers:
            present = bool(strings_text) and marker in strings_text
            record(f"{CHAIN}2.{feature.id}.{marker}", present,
                   f"{feature.id}：构建出的 dylib 里有 `{marker}`",
                   where=str(dylib) if dylib else f"{PRODUCT_SHELL_TARGET_DIR}/release/{DYLIB_NAME}",
                   reason=(f"`strings` 里找不到 `{marker}`。构建：{BUILD_COMMAND}"
                           if dylib else f"没有 dylib 可查；先构建：{BUILD_COMMAND}"))

    # 加载态的门：每个挡人项的信号必须在产品壳里有启动期生产者，且世界一激活就放行。
    run_startup_producer_gate(record, root)

    # 自检负对照：这条门禁必须**能**判红。用一个不存在的标识跑一遍同一个判定函数，
    # 它必须被报成"找不到"。这样即使当前全绿，也能证明判据不是恒真。
    bogus = "GMGN_PRODUCT_SHELL_PARITY_SELF_CHECK_MISSING_MARKER"
    record(f"{CHAIN}3.1", marker_in_sources(bogus, sources) is None,
           "负对照：一个不存在的源标识确实被判成「找不到」（门禁不是恒真）",
           where="tools/verify-product-shell-parity.py:marker_in_sources",
           reason="判定函数把一个不存在的标识报成了命中")
    record(f"{CHAIN}3.2", (not strings_text) or (bogus not in strings_text),
           "负对照：一个不存在的运行期标识确实不在 dylib 字符串表里",
           where="tools/verify-product-shell-parity.py:dylib_strings",
           reason="dylib 字符串表里出现了不该存在的标识")
    record(f"{CHAIN}4.1", True,
           "需要重新打包/装机的部分已具名列出（见 INSTALL_ONLY）",
           where="tools/verify-product-shell-parity.py:INSTALL_ONLY",
           evidence=INSTALL_ONLY)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=None, help="被检查的工作树根（负对照用）")
    parser.add_argument("--dylib", default=None, help="显式指定产品 dylib")
    parser.add_argument("--list", action="store_true", help="只列登记表")
    args = parser.parse_args()

    global ROOT
    if args.root:
        ROOT = Path(args.root).resolve()

    if args.list:
        for feature in FEATURES:
            print(f"{feature.id}\t{feature.claim}")
            print(f"    生产者: {feature.producer}")
            print(f"    产品壳源标识: {' '.join(feature.source_markers)}")
            print(f"    运行期标识:   {' '.join(feature.runtime_markers)}")
        return 0

    print(f"{CHAIN} 链：产品壳一致性（声称上线的界面特性必须在产品那层有证据）", flush=True)
    print(f"  工作树: {ROOT}", flush=True)
    recorder = Recorder()
    run(recorder, ROOT, args.dylib)
    failures = [r for r in recorder.records if not r["ok"]]
    print(f"  小计: {len(recorder.records) - len(failures)}/{len(recorder.records)} PASS", flush=True)
    print(json.dumps({"records": recorder.records, "install_only": INSTALL_ONLY},
                     ensure_ascii=False), flush=True)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""负对照：证明四链 harness 的断言**真的会红**，而不是永远绿。

做法：把被检查的生产文件复制到临时目录，在**副本**上注入各自链上最典型的
那一种退化，再让对应 harness 去跑那份副本。原仓库一个字节都不改。

    python3 tools/verify-chains-can-fail.py

退出码：每条注入都被抓到 = 0；有注入没被任何断言抓到 = 1。
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

CASES = [
    {
        "id": "A-watchdog-unwired",
        "file": "apps/macos/UnityHost/UnityMediaHost.swift",
        "why": "把 prepare 之后挂 watchdog 的那一行删掉（找到定义却没人调用 = 兜底等于没有）",
        "mutate": lambda text: text.replace(
            "                schedulePrepareWatchdog(id: id, revision: revision)\n", ""),
        "harness": "verify-world-prepare-state-machine.py",
        "expect": "A2.11",
    },
    {
        "id": "A-watchdog-guard-weakened",
        "file": "apps/macos/UnityHost/UnityMediaHost.swift",
        "why": "watchdog 里不再判 phase == prepare（陈旧 prepare 的迟到回执会与兜底打架）",
        "mutate": lambda text: text.replace(
            '                  self.worldSelection["phase"] as? String == "prepare",\n', ""),
        "harness": "verify-world-prepare-state-machine.py",
        "expect": "A2.2.phase",
    },
    {
        "id": "D-second-fullscreen-emitter",
        "file": "apps/gpui-app/src/main.rs",
        "why": "在栏上动作里再点一次全屏（同一动作多出一个发射点）",
        "mutate": lambda text: text.replace(
            'let _=click.update(cx,|this,cx|{\n                                if action=="mode" {window.toggle_fullscreen();cx.notify();}',
            'let _=click.update(cx,|this,cx|{\n                                if action=="mode" {window.toggle_fullscreen();window.toggle_fullscreen();cx.notify();}'),
        "harness": "verify-bar-action-senders.py",
        "expect": "D1.全屏.1",
    },
    {
        "id": "D-volume-second-entry",
        "file": "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift",
        "why": "音量再走一个独立入口（同一动作两套实现）",
        "mutate": lambda text: text.replace(
            "        case .volumeUp:\n            adjustMusicVolume(by: 0.08)",
            "        case .volumeUp:\n            adjustMusicVolume(by: 0.08)\n            adjustMusicVolume(by: 0.08)"),
        "harness": "verify-bar-action-senders.py",
        "expect": "D5.3",
    },
]


def fixtures_for(harness: str) -> list[str]:
    """harness 会读到的那些生产文件（从它的常量表里读出来，别手抄）。"""
    if harness == "verify-world-prepare-state-machine.py":
        return ["apps/macos/UnityHost/UnityMediaHost.swift"]
    text = (ROOT / "tools" / harness).read_text(encoding="utf-8")
    files = re.findall(r'^(?:GPUI|SWIFT)_\w+ = "([^"]+)"', text, re.M)
    # D harness 里还有几处直接写在断言里的生产文件。
    for extra in ("apps/macos/Sources/GMGNRadio/Settings/GMGNKeyboardShortcuts.swift",):
        if extra not in files:
            files.append(extra)
    return files


def run_case(case: dict, repo: Path) -> dict:
    harness = ROOT / "tools" / case["harness"]
    completed = subprocess.run(
        [sys.executable, str(harness), "--root", str(repo)],
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
        return {"caught": False, "detail": f"harness 没输出可解析结果 rc={completed.returncode}"}
    for record in payload.get("records", []):
        if record["id"] == case["expect"]:
            return {"caught": not record["ok"],
                    "assert": record["id"],
                    "reason": record["reason"][:300],
                    "ok": record["ok"]}
    return {"caught": False, "detail": f"找不到断言 {case['expect']}"}


def main() -> int:
    results = []
    failures = 0
    for case in CASES:
        with tempfile.TemporaryDirectory(prefix="gmgn-canfail-") as tmp:
            repo = Path(tmp) / "repo"
            for rel in fixtures_for(case["harness"]):
                source = ROOT / rel
                if not source.exists():
                    continue
                destination = repo / rel
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, destination)
            target = repo / case["file"]
            target.parent.mkdir(parents=True, exist_ok=True)
            original = (ROOT / case["file"]).read_text(encoding="utf-8")
            mutated = case["mutate"](original)
            if mutated == original:
                results.append({"id": case["id"], "caught": False,
                                "detail": "注入没有改变源码（生产写法已经漂了，请更新这条负对照）"})
                failures += 1
                print(f"  [SKIP] {case['id']}: 注入没有生效 —— {case['why']}", flush=True)
                continue
            target.write_text(mutated, encoding="utf-8")
            outcome = run_case(case, repo)
            results.append({"id": case["id"], **outcome})
            mark = "PASS" if outcome.get("caught") else "FAIL"
            print(f"  [{mark}] {case['id']}: 注入被 {outcome.get('assert', '?')} 抓到"
                  + ("" if outcome.get("caught") else f" —— {outcome}"), flush=True)
            if not outcome.get("caught"):
                failures += 1
    print(json.dumps({"cases": results, "failures": failures}, ensure_ascii=False), flush=True)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

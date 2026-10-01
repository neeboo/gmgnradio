#!/usr/bin/env python3
"""注入 → 跑 harness → 逐字还原 → 校验 sha256。每次注入都自己校验还原是否逐字。

用法：python3 tools/.inject-check.py <case-id>
只改"我这条线"的文件；GMGNRadioApp.swift 的那两条会在运行前记录 sha256、
运行后核对（若期间被别的 agent 改过，脚本会打印冲突并拒绝声称还原成功）。
"""
import hashlib
import json
import subprocess
import sys

ROOT = "/Users/ghostcorn/dev/gmgnradio"
APP = f"{ROOT}/apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift"
PRESENT = f"{ROOT}/apps/macos/Sources/GMGNRadio/Presence/PropSupportGridPresentation.swift"
REBASE = f"{ROOT}/apps/macos/Packages/WorldRuntime/Sources/WorldRuntime/WorldPropArchiveRebase.swift"

CASES = {
    # ① 问题一：注入"静默改写"（把可见记录那一行删掉）⇒ 必须 FAIL
    "silent-rewrite": {
        "file": APP,
        "old": '                        orientationNotices[job.objectID] = record.summary\n',
        "new": '                        // 注入：静默改写（可见记录那一行被拿掉）\n',
        "harness": ["swift", "tools/test-resident-prop-placement.swift"],
    },
    # ② 问题一：注入"不一致不可见"（拒绝改成 break，静默跳过）⇒ 必须 FAIL
    "invisible-mismatch": {
        "file": APP,
        "old": '                    case let .refuse(detail):\n'
               '                        // 不静默：把**具体差异**说出来（身份不同 / 不是等比缩放 / 尺寸非法）。\n'
               '                        throw ResidentPropHostError.archiveNotRepairable(detail)\n',
        "new": '                    case let .refuse(detail):\n'
               '                        // 不静默：把**具体差异**说出来（身份不同 / 不是等比缩放 / 尺寸非法）。\n'
               '                        break\n',
        "harness": ["swift", "tools/test-resident-prop-placement.swift"],
    },
    # ③ 问题一：注入"把来路不明的尺寸也硬对齐"（去掉等比缩放那道闸）⇒ 必须 FAIL
    "explainability-gate": {
        "file": REBASE,
        "old": '        guard rawFactor != nil || orientedFactor != nil else {\n',
        "new": '        guard rawFactor != nil || orientedFactor != nil || true else {\n',
        "harness": ["swift", "tools/test-resident-prop-placement.swift"],
        # WorldRuntime 的 harness 用的是 SwiftPM 预编译产物（.build/…/*.swift.o），
        # 改了源码必须重新编译那一次，否则注入根本进不了被跑的那个二进制。
        "rebuild": ["swift", "build", "--package-path", "apps/macos/Packages/WorldRuntime"],
    },
    # ④ 问题二：注入"全部隐藏"（焦点窗口永远为空）⇒ 必须 FAIL
    "hide-everything": {
        "file": PRESENT,
        "old": '        let core = Set(states.filter { $0.value != .wallPlaceable }.keys)\n        guard !core.isEmpty else { return Focus(core: [], cells: []) }\n',
        "new": '        let core = Set<Cell>()\n        guard !core.isEmpty else { return Focus(core: [], cells: []) }\n',
        "harness": ["swift", "tools/test-resident-prop-render.swift"],
    },
    # ⑤ 问题二：注入"丢掉颜色语义"（靠墙提示被染成"能放"同一色）⇒ 必须 FAIL
    "drop-colour": {
        "file": PRESENT,
        "old": '            case .wallPlaceable: SIMD4(0.25, 0.72, 0.95, 1)\n',
        "new": '            case .wallPlaceable: SIMD4(0.30, 0.85, 0.45, 1)\n',
        "harness": ["swift", "tools/test-resident-prop-render.swift"],
    },
    # ⑥ 问题二：把回归**改回去**（锚点重新取全部 states，靠墙提示又变成锚点）⇒ 新断言必须 FAIL
    "restore-regression": {
        "file": PRESENT,
        "old": '        let core = Set(states.filter { $0.value != .wallPlaceable }.keys)\n',
        "new": '        let core = Set(states.keys)\n',
        "harness": ["swift", "tools/test-resident-prop-render.swift"],
    },
}


def sha(path):
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def main():
    case_id = sys.argv[1]
    case = CASES[case_id]
    if not case["new"]:
        print("INJECT-FAIL: empty replacement is not allowed (revert would be ambiguous)")
        return 2
    path = case["file"]
    before = sha(path)
    with open(path, "r", encoding="utf-8") as handle:
        text = handle.read()
    if text.count(case["old"]) != 1:
        print(f"INJECT-FAIL: pattern not unique ({text.count(case['old'])}) in {path}")
        return 2
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text.replace(case["old"], case["new"]))
    injected = sha(path)
    if case.get("rebuild"):
        subprocess.run(case["rebuild"], cwd=ROOT, capture_output=True, text=True)
    result = subprocess.run(case["harness"], cwd=ROOT, capture_output=True, text=True)
    with open(path, "r", encoding="utf-8") as handle:
        now = handle.read()
    if now.count(case["new"]) != 1:
        print("REVERT-ABORT: the injected text is gone (another writer touched the file) — not touching it")
        return 3
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(now.replace(case["new"], case["old"], 1))
    if case.get("rebuild"):
        subprocess.run(case["rebuild"], cwd=ROOT, capture_output=True, text=True)
    after = sha(path)
    fails = [line for line in (result.stdout + result.stderr).splitlines() if line.startswith("FAIL")]
    print(json.dumps({
        "case": case_id,
        "file": path,
        "sha256_before": before,
        "sha256_injected": injected,
        "sha256_after_revert": after,
        "restored_verbatim": before == after,
        "harness_exit": result.returncode,
        "fail_lines": fails[:3],
    }, ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())

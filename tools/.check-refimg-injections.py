#!/usr/bin/env python3
"""参考图线：注入 → 跑 harness → 逐字还原 → 校验 sha256。

每条注入只改**本线自己的**文件（`Agent/ResidentWishReferenceTools.swift` 与
`tools/test-resident-wish-reference-tools.swift`），绝不碰别的线在改的文件。

用法：
    python3 tools/.check-refimg-injections.py            # 全部
    python3 tools/.check-refimg-injections.py 1 3        # 只跑第 1、3 条
"""
import hashlib
import subprocess
import sys

ROOT = "/Users/ghostcorn/dev/gmgnradio"
TOOLS = f"{ROOT}/apps/macos/Sources/GMGNRadio/Agent/ResidentWishReferenceTools.swift"
DIAG = f"{ROOT}/apps/macos/Sources/GMGNRadio/Agent/ResidentWishReferenceDiagnosis.swift"
HARNESS = f"{ROOT}/tools/test-resident-wish-reference-tools.swift"

CASES = {
    # 断言 1：「每种失败都有具名原因（不只是"找图失败"）」——注入模糊文案 ⇒ FAIL
    "1-blurred-wording": {
        "file": DIAG,
        "old": '            message: "\\(operation.label)\\(classification.cause)：\\(reason)。\\(classification.guidance)",\n',
        "new": '            message: "找图失败。",\n',
        "expect": ["survives verbatim", "where to configure"],
    },
    # 断言 2：「根因是连不上/没配 ⇒ 明确说去哪里配，且不冒充在搜」——注入静默重试 ⇒ FAIL
    # 注入点在**调用处**而不是 `coolingDownSearchFact` 内部：后者拿掉 `guard let` 会留下
    # 未解包的 `cooldown`，直接编译不过（注入必须能编过，否则跑的根本不是被注入的逻辑）。
    "2-silent-retry": {
        "file": TOOLS,
        "old": ('        // 冷却期内不再撞墙，但回执必须说清"这一次没有发起搜索"，而不是假装搜过。\n'
                '        if let cooling = coolingDownSearchFact() {\n'
                '            WishReferenceLog.cooldownSkipped(code: cooling.code, reason: cooling.reason)\n'
                '            return failure(callID, cooling.code, cooling.message)\n'
                '        }\n'),
        "new": '        // 注入：静默重试（关掉冷却，每次失败都重新撞墙）\n',
        "expect": ["cooldown"],
    },
    # 断言 2b：拿掉「去哪里配」的具体指引 ⇒ FAIL
    "2b-no-guidance": {
        "file": DIAG,
        "old": '        + "请在网络层给本 app 放行 dns.google:443 与 commons.wikimedia.org:443"\n',
        "new": '        + "请稍后重试"\n',
        "expect": ["where to configure"],
    },
    # 断言 3：「结果为空 ≠ 失败：两者文案必须不同」——注入混为一谈 ⇒ FAIL
    "3-empty-as-failure": {
        "file": TOOLS,
        "old": ('        if results.isEmpty {\n'
                '            WishReferenceLog.emptyResults(query: query)\n'
                '            // 空结果也上屏，但走**普通信息**这一档：它绝不是失败。\n'
                '            WishReferenceAvailabilityNotice.postInfo(WishReferenceDiagnosis.emptyResultsScreenText)\n'
                '        }\n'),
        "new": ('        if results.isEmpty {\n'
                '            return report(callID, .search, WishReferenceDiagnosis.searchUnparseable())\n'
                '        }\n'),
        "expect": ["empty", "失败"],
    },
    # 断言 4：「失败上屏 + 落日志」——注入只写回执 ⇒ FAIL
    "4-receipt-only": {
        "file": TOOLS,
        "old": ('        WishReferenceLog.failure(fact, operation: operation.rawValue)\n'
                '        if fact.isConnectivity { cooldown = (fact, now().addingTimeInterval(Self.cooldownInterval)) }\n'
                '        if lastReportedScreen != fact.screen {\n'
                '            lastReportedScreen = fact.screen\n'
                '            WishReferenceLog.availabilityChanged(fact.screen, isFailure: true)\n'
                '            WishReferenceAvailabilityNotice.postFailure(fact.screen)\n'
                '        }\n'),
        "new": ('        if fact.isConnectivity { cooldown = (fact, now().addingTimeInterval(Self.cooldownInterval)) }\n'
                '        // 注入：只写回执，日志与屏上都不发\n'),
        "expect": ["logged", "screen exit"],
    },
}

ORDER = ["1-blurred-wording", "2-silent-retry", "2b-no-guidance", "3-empty-as-failure", "4-receipt-only"]


def sha256(path):
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def run_harness():
    done = subprocess.run(["swift", HARNESS], cwd=ROOT, capture_output=True, text=True)
    return done.stdout + done.stderr


def main():
    wanted = sys.argv[1:]
    names = [n for n in ORDER if not wanted or n.split("-")[0] in wanted or n in wanted]
    overall_ok = True
    # 本线的两个生产文件：每次注入前后都核对 sha256，证明「逐字还原」不是靠印象。
    baseline = {p: sha256(p) for p in (TOOLS, DIAG)}
    for name in names:
        case = CASES[name]
        path = case["file"]
        original = open(path, encoding="utf-8").read()
        if original.count(case["old"]) != 1:
            print(f"[{name}] SKIP: 注入锚点出现 {original.count(case['old'])} 次（应为 1）")
            overall_ok = False
            continue
        try:
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(original.replace(case["old"], case["new"], 1))
            output = run_harness()
        finally:
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(original)
        restored = {p: sha256(p) for p in (TOOLS, DIAG)}
        restore_ok = restored == baseline
        fails = [line for line in output.splitlines() if line.startswith("FAIL")]
        compile_errors = [line for line in output.splitlines() if ": error:" in line]
        ran = "resident wish reference tool checks" in output
        caught = bool(fails) and ran
        hit = [f for f in fails if any(k in f for k in case["expect"])]
        print(f"[{name}] 注入后 FAIL={len(fails)} 命中预期={len(hit)} 逐字还原={restore_ok} 跑起来了={ran}")
        for line in fails[:4]:
            print("    " + line)
        if compile_errors:
            print(f"    !! 注入把代码改到编译不过（{len(compile_errors)} 条 error），注入本身要重做")
            print("    " + compile_errors[0])
            overall_ok = False
        elif not caught:
            print("    !! 注入没有被抓住（harness 仍然 PASS）")
            overall_ok = False
        if not restore_ok:
            for p in (TOOLS, DIAG):
                if restored[p] != baseline[p]:
                    print(f"    !! 还原后 sha256 不一致 {p}\n       before={baseline[p]}\n       after ={restored[p]}")
            overall_ok = False
        print()
    for p in (TOOLS, DIAG):
        print(f"final sha256 {p.split('/')[-1]}: {sha256(p)}  == baseline {sha256(p) == baseline[p]}")
    print("ALL INJECTIONS CAUGHT AND RESTORED" if overall_ok else "SOME INJECTIONS FAILED")
    return 0 if overall_ok else 1


if __name__ == "__main__":
    sys.exit(main())

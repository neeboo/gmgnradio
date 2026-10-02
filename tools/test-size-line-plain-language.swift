// 「尺寸那一行是**人话**」的判据（用户 2026-10-02 原话 + 截图）。
//
// 面板上原来那一行是：
//   「尺寸：用户指定的三轴尺寸 1.443 × 0.862 × 0.302 米（宽 × 高 × 深；你说的
//     1443 × 862 × 302 毫米），按最长边等比归一，另外两维只是期望值」
// 用户要的是**一句短的、他原话里的数**。这一条判据守两件事：
//   ① 三轴档与单轴档说成**同一句话的形状**，而且都是人话；
//   ② 那句工程腔、还有末尾那半句**假话**（三轴早就是逐轴兑现了，不再"只是期望值"）
//      一个字都不许回来。
//
// 判据不自己再写一遍文案 —— 那会变成第二份真相。所以这里从**真源码**
// `Presence/PropGenerationClient.swift` 里把 `var summary` 与 `millimetersText`
// **逐字抽出来**（只补一个最小的类型壳），**真的编译并驱动它**，读它渲染出来的字符串。
//
// 现场演示：`WISH_SIZE_LINE_INJECT=legacy swift tools/test-size-line-plain-language.swift`
// 会把**真源码**换成改造前那一版，于是主判据自己打出 FAIL。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let clientPath = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/PropGenerationClient.swift")
let coordinatorPath = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/WishMachineCoordinator.swift")

var failureCount = 0
func check(_ condition: Bool, _ message: String) {
    print(condition ? "PASS \(message)" : "FAIL \(message)")
    if !condition { failureCount += 1 }
}
func require(_ condition: Bool, _ message: String) {
    guard condition else { print("FAIL \(message)"); exit(1) }
}

// ---------------------------------------------------------------------------
// MARK: 从真源码里抽出文案那一处
// ---------------------------------------------------------------------------

/// 从 `start` 起做花括号配平，返回整段声明文本（含首尾）。
func extractBalanced(_ source: String, startingAt needle: String) -> String? {
    guard let start = source.range(of: needle) else { return nil }
    var depth = 0
    var index = start.lowerBound
    var seenBrace = false
    while index < source.endIndex {
        let character = source[index]
        if character == "{" { depth += 1; seenBrace = true }
        if character == "}" {
            depth -= 1
            if seenBrace && depth == 0 { return String(source[start.lowerBound...index]) }
        }
        index = source.index(after: index)
    }
    return nil
}

let clientSource = try String(contentsOf: clientPath, encoding: .utf8)
let coordinatorSource = try String(contentsOf: coordinatorPath, encoding: .utf8)

let pristineSummary = extractBalanced(clientSource, startingAt: "var summary: String {")
let pristineMillimetersText = extractBalanced(clientSource, startingAt: "static func millimetersText(")
let pristineMetersText = extractBalanced(clientSource, startingAt: "private static func metersText(")
require(pristineSummary != nil, "真源码里找不到 `var summary: String {` —— 文案的宿主没了")
require(pristineMillimetersText != nil, "真源码里找不到 `millimetersText`")
require(pristineMetersText != nil, "真源码里找不到 `metersText`")

/// 改造前那一版（**负对照的正身**）。只在内存里用，绝不写回源码。
let legacySummary = """
var summary: String {
        let who = switch source {
        case .user: "用户指定"
        case .suggested: "服务建议"
        case .fallback: "默认值"
        }
        switch mode {
        case .axes:
            return "\\(who)的\\(axis == .longest ? "最长边" : "高度") \\(String(format: "%.2f", meters)) 米"
        case .dimensions:
            guard let millimeters else { return "\\(who)的三轴尺寸（读不出来）" }
            return "\\(who)的三轴尺寸 \\(Self.metersText(millimeters.x)) × \\(Self.metersText(millimeters.y))"
                + " × \\(Self.metersText(millimeters.z)) 米（宽 × 高 × 深；"
                + "你说的 \\(Self.millimetersText(millimeters)) 毫米），"
                + "按最长边等比归一，另外两维只是期望值"
        }
    }
"""

/// 把它落成一份可执行源码：补一个**最小**的类型壳，文案与两个 helper 逐字来自真源码。
func probeSource(summary: String, millimetersText: String, metersText: String) -> String {
    """
    import Foundation

    struct PropSizeIntent {
        enum Axis: String { case longest, height }
        enum Source: String { case user, suggested; case fallback = "default" }
        enum Mode { case axes, dimensions }
        struct Millimeters {
            let x: Double, y: Double, z: Double
            var edges: [Double] { [x, y, z] }
        }
        let mode: Mode
        let axis: Axis
        let meters: Double
        let millimeters: Millimeters?
        let source: Source

    \(summary)

    \(millimetersText)

    \(metersText)
    }

    var failures = 0
    func expect(_ condition: Bool, _ message: String) {
        print((condition ? "PASS " : "FAIL ") + message); if !condition { failures += 1 }
    }
    func rendered(_ mode: PropSizeIntent.Mode, axis: PropSizeIntent.Axis = .longest,
                  meters: Double = 0, millimeters: PropSizeIntent.Millimeters? = nil,
                  source: PropSizeIntent.Source) -> String {
        PropSizeIntent(mode: mode, axis: axis, meters: meters, millimeters: millimeters, source: source).summary
    }

    let three = PropSizeIntent.Millimeters(x: 1443, y: 862, z: 302)
    let cases: [(String, String)] = [
        ("三轴", rendered(.dimensions, millimeters: three, source: .user)),
        ("三轴-建议", rendered(.dimensions, millimeters: three, source: .suggested)),
        ("单轴-最长边", rendered(.axes, axis: .longest, meters: 1.1, source: .user)),
        ("单轴-高度", rendered(.axes, axis: .height, meters: 0.6, source: .user)),
        ("三轴-读不出来", rendered(.dimensions, source: .user)),
    ]

    // ① 用户原话里的数**逐位**在那一句里（不是换算过的近似值）。
    let threeText = cases[0].1
    expect(threeText.contains("1443 × 862 × 302"), "\\(cases[0].0) 那一句逐位回读你说的三个毫米数（实测「\\(threeText)」）")
    expect(threeText.contains("毫米"), "\\(cases[0].0) 那一句说得出单位是毫米（实测「\\(threeText)」）")
    expect(cases[2].1.contains("1.10") && cases[2].1.contains("最长边"),
        "\\(cases[2].0) 那一句说得出是哪根轴、哪个数（实测「\\(cases[2].1)」）")
    expect(cases[3].1.contains("高度") && cases[3].1.contains("0.60"),
        "\\(cases[3].0) 那一句说得出是哪根轴、哪个数（实测「\\(cases[3].1)」）")

    // ② 出处只说「是谁说的」，而且**不许**在 source 不是 user 时冒充"你说的"。
    expect(cases[0].1.hasPrefix("你说的大小："), "source=user ⇒ 出处说「你说的大小」（实测「\\(cases[0].1)」）")
    expect(cases[1].1.hasPrefix("建议的大小："), "source=suggested ⇒ 出处说「建议的大小」，不冒充你说的（实测「\\(cases[1].1)」）")

    // ③ **工程腔一个字都不许回来**。这一条就是用户那句抱怨的正身。
    let jargon = ["用户指定", "服务建议", "默认值", "三轴尺寸", "宽 × 高 × 深", "宽×高×深",
                  "按最长边等比归一", "另外两维只是期望值", "期望值", "…", "..."]
    for (label, text) in cases {
        for word in jargon where text.contains(word) {
            expect(false, "\\(label) 那一句出现了工程腔/省略号「\\(word)」（实测「\\(text)」）")
        }
    }
    expect(true, "五档文案里没有「用户指定的三轴尺寸…（宽 × 高 × 深；…）」这类工程腔，也没有省略号堆叠")

    // ④ 两档是**同一句话的形状**：都以出处开头、都是"一句话"（没有换行、没有第二个标签）。
    for (label, text) in cases {
        expect(!text.contains("\\n") && !text.contains("尺寸："),
            "\\(label) 是**一句**话，没有叠第二个标签（实测「\\(text)」）")
    }

    print("RENDERED " + cases.map { "\\($0.0)=\\($0.1)" }.joined(separator: " | "))
    exit(failures == 0 ? 0 : 1)
    """
}

func runProbe(summary: String) throws -> (status: Int32, output: String) {
    let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("size-line-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let file = scratch.appendingPathComponent("probe.swift")
    try probeSource(summary: summary,
                    millimetersText: pristineMillimetersText ?? "",
                    metersText: pristineMetersText ?? "").write(to: file, atomically: true, encoding: .utf8)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
    process.arguments = [file.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

let injectLegacy = ProcessInfo.processInfo.environment["WISH_SIZE_LINE_INJECT"] == "legacy"
if injectLegacy { print("·· WISH_SIZE_LINE_INJECT=legacy：把真源码当成改造前那一版来判") }

let observedSummary = injectLegacy ? legacySummary : (pristineSummary ?? "")
if injectLegacy { check(observedSummary != pristineSummary, "注入负对照「旧文案」确实改到了源码副本") }

let observed = try runProbe(summary: observedSummary)
for line in observed.output.split(separator: "\n") {
    print(line.hasPrefix("RENDERED ") ? "   · \(line)" : "   · \(line)")
}
print("   · 退出码 \(observed.status)")
check(observed.status == 0, "① 驱动**真源码抽出来的 `summary`**：两处文案都是人话、都是同一个形状")

// ---------------------------------------------------------------------------
// MARK: 那一行在任务行上不能再叠一个「尺寸：」
// ---------------------------------------------------------------------------

let coordinatorLine = coordinatorSource
    .components(separatedBy: .newlines)
    .first { $0.contains("return sizeIntent.summary") || $0.contains("\"尺寸：\\(sizeIntent.summary)\"") }
check(coordinatorLine?.contains("\"尺寸：\\(sizeIntent.summary)\"") == false,
    "② 任务行不再自己拼「尺寸：」前缀（否则会叠成「尺寸：你说的大小：…」）；实测：\(coordinatorLine?.trimmingCharacters(in: .whitespaces) ?? "（找不到）")")

// ---------------------------------------------------------------------------
// MARK: 注入负对照
// ---------------------------------------------------------------------------

enum SizeLineInjection: String, CaseIterable {
    /// 改造前那一版（工程腔 + 假话 + 省略号）。
    case legacy

    func apply(to summary: inout String) {
        switch self {
        case .legacy: summary = legacySummary
        }
    }
}

for injection in SizeLineInjection.allCases {
    var injected = pristineSummary ?? ""
    injection.apply(to: &injected)
    check(injected != pristineSummary, "注入负对照「\(injection.rawValue)」确实改到了源码副本")
    let result = try runProbe(summary: injected)
    let firstFailure = result.output
        .split(separator: "\n")
        .first { $0.hasPrefix("FAIL ") }
        .map { String($0.dropFirst("FAIL ".count)) } ?? "（没有）"
    check(result.status != 0, "注入负对照「\(injection.rawValue)」⇒ 判据必须变红（第一条：\(firstFailure)）")
}

print(failureCount == 0
    ? "PASS 尺寸那一行的人话判据全部通过"
    : "FAIL 尺寸那一行的判据有 \(failureCount) 条不通过")
exit(failureCount == 0 ? 0 : 1)

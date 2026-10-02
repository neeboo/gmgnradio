// 居民"失败了自己再来"的判据。
//
// 两件事一起钉：
//   A. **退避在一处定义**（`Presence/RetryBackoff.swift`），六处读它；连续失败等待递增、
//      带抖动、有上限、不忙转。
//   B. 居民把失败当成一次尝试：同一个失败连续两次必须换招；预算（次数 + 时长）用尽才
//      交给用户，且只有**一句人话**；需要人类确认的动作照旧必须问；结构上不可能靠重试
//      解决的失败第一次就具名，不空转。
//
// 读的是**真源码**：把 `Presence/RetryBackoff.swift` 原文（或注入后的副本）和下面的
// `checksSource` 一起 swiftc，跑真逻辑。每条断言都配一条注入，注入必须让门禁变红 ——
// 注入不红就是门禁自己失效（这个仓库反复踩过的坑）。
//
// 运行：
//   swift tools/test-resident-loop-retry.swift
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceRoot = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
let backoffRelative = "Presence/RetryBackoff.swift"

func fail(_ message: String) -> Never {
    print("FAIL: \(message)")
    exit(1)
}

// ---------------------------------------------------------------------------
// MARK: - 六处必须读同一份策略（源码接线判据）
// ---------------------------------------------------------------------------

struct Wiring {
    let path: String
    let marker: String
}

/// 六处退避各自的接线点。`Agent/ResidentWishReferenceTools.swift` **文件冻结**
/// （并发线占用，本次不许碰），所以它不读符号，而是由下面的"漂移闸"把它的常量
/// 与唯一策略逐位钉在一起：谁单方面改了一边，门禁就红。
let wirings: [Wiring] = [
    Wiring(path: "Agent/ResidentDSHHostToolsBridge.swift", marker: "RetryBackoffSite.hostToolBridge"),
    Wiring(path: "Presence/WorldAuthorityClient.swift", marker: "RetryBackoffSite.authorityReconnect"),
    Wiring(path: "Presence/WishMachineCoordinator.swift", marker: "RetryBackoffSite.generationConfirmation"),
    Wiring(path: "Presence/ResidentPropEditorState.swift", marker: "RetryBackoffSite.propPlacement"),
    Wiring(path: "Agent/ResidentActivityOutcome.swift", marker: "RetryBackoffSite.jukeboxActivity"),
    Wiring(path: "Agent/ResidentWorldToolSession.swift", marker: "ResidentRetryLedger"),
]

let frozenReferencePath = "Agent/ResidentWishReferenceTools.swift"
let frozenReferenceAnchor = "cooldownInterval: TimeInterval = "

/// 六处接线 + 冻结线漂移闸。`content` 返回 nil 表示读不到那份源码。
func wiringFailures(_ content: (String) -> String?, referenceBase: Double) -> [String] {
    var failures: [String] = []
    for wiring in wirings {
        guard let text = content(wiring.path) else {
            failures.append("读不到 \(wiring.path)")
            continue
        }
        if !text.contains(wiring.marker) {
            failures.append("\(wiring.path) 回退到自己的常量（缺 \(wiring.marker)）")
        }
    }
    guard let text = content(frozenReferencePath) else {
        failures.append("读不到 \(frozenReferencePath)")
        return failures
    }
    guard let anchor = text.range(of: frozenReferenceAnchor) else {
        failures.append("\(frozenReferencePath) 的冷却常量换了形状，漂移闸核不到")
        return failures
    }
    let digits = text[anchor.upperBound...].prefix { $0.isNumber || $0 == "." }
    let value = Double(digits) ?? -1
    if abs(value - referenceBase) > 1e-9 {
        failures.append("\(frozenReferencePath) 的冷却 \(value) 与唯一策略 \(referenceBase) 漂移了")
    }
    return failures
}

func read(_ relative: String) -> String? {
    try? String(contentsOf: sourceRoot.appendingPathComponent(relative), encoding: .utf8)
}

// ---------------------------------------------------------------------------
// MARK: - 编译并运行真逻辑
// ---------------------------------------------------------------------------

/// 与 `RetryBackoff.swift` 一起编译的判据程序。注入只改前者，所以这里一个字都不许
/// 跟着注入变 —— 判据测的就是被注入的那份真源码。
let checksSource = #"""
import Foundation

var failures: [String] = []
@MainActor func expect(_ condition: Bool, _ message: String) {
    if !condition { failures.append(message) }
}

let six: [RetryBackoffSite] = [
    .referenceSearch, .hostToolBridge, .authorityReconnect,
    .generationConfirmation, .propPlacement, .jukeboxActivity,
]
for site in six {
    let policy = site.policy
    expect(policy.maximumAttempts >= 1, "\(site.rawValue) 没有次数上限")
    expect(policy.maximumDuration > 0, "\(site.rawValue) 没有时长上限")
}

// 第一跳与既有数值逐位一致： unification 不许顺手放宽。
expect(RetryBackoffSite.referenceSearch.policy.baseDelay == 30, "参考图第一跳不再是 30 秒")
expect(RetryBackoffSite.hostToolBridge.policy.baseDelay == 0.05, "宿主桥第一跳变了")
expect(RetryBackoffSite.authorityReconnect.policy.baseDelay == 1, "权威重连第一跳变了")
expect(RetryBackoffSite.generationConfirmation.policy.maximumAttempts == 3, "生成确认次数上限变了")
expect(RetryBackoffSite.generationConfirmation.policy.baseDelay == 30, "生成确认间隔变了")
expect(RetryBackoffSite.propPlacement.policy.maximumAttempts == 32, "摆放试算上限变了")
expect(RetryBackoffSite.jukeboxActivity.policy.maximumDuration == 180, "点唱机总时限变了")

// 退避真的退：递增 + 抖动 + 封顶 + 不忙转；抖动只向上。
for site in [RetryBackoffSite.referenceSearch, .hostToolBridge, .authorityReconnect, .generationConfirmation] {
    let policy = site.policy
    expect(policy.growth > 1, "\(site.rawValue) 不递增（growth ≤ 1）")
    expect(policy.jitterFraction > 0, "\(site.rawValue) 没有抖动")
    expect(policy.baseDelay > 0, "\(site.rawValue) 忙转（第一跳为 0）")
    let d1 = policy.delay(afterFailure: 1)
    let d2 = policy.delay(afterFailure: 2)
    let d3 = policy.delay(afterFailure: 3)
    expect(d1 >= policy.baseDelay - 1e-9, "\(site.rawValue) 第一跳比既有值短")
    expect(d1 < d2 && d2 <= d3, "\(site.rawValue) 连续失败等待不递增：\(d1), \(d2), \(d3)")
    expect(policy.delay(afterFailure: policy.maximumAttempts + 5) <= policy.maximumDelay + 1e-9,
           "\(site.rawValue) 没有封顶")
    expect(policy.delay(afterFailure: 2, jitterUnit: 0) >= policy.delay(afterFailure: 2) - 1e-9,
           "\(site.rawValue) 的抖动把等待缩短了")
    expect(policy.delay(afterFailure: 2, jitterUnit: 1) > policy.delay(afterFailure: 2),
           "\(site.rawValue) 的抖动没有作用")
}
expect(RetryBackoffSite.referenceSearch.policy.delay(afterFailure: 99)
       == RetryBackoffSite.referenceSearch.policy.maximumDelay, "等待没有被上限截断")

// 预算用尽：次数与时长两条都要能触发，也不能提前触发。
let iteration = RetryBackoffSite.residentIteration.policy
expect(iteration.isExhausted(attempts: iteration.maximumAttempts, elapsed: 0), "次数上限不生效")
expect(iteration.isExhausted(attempts: 0, elapsed: iteration.maximumDuration), "时长上限不生效")
expect(!iteration.isExhausted(attempts: 1, elapsed: 1), "预算提前用尽")

// -- B. 居民自主 iterate ------------------------------------------------------

let t0 = Date(timeIntervalSince1970: 1_000)

// 第一次失败不交用户，同一个失败两次必须换招，三次才交。
var first = ResidentRetryLedger()
expect(first.noteFailure(tool: "move_to", code: "route_blocked", at: t0) == .retrySameApproach,
       "第一次失败就交给用户了")
let twice = first.noteFailure(tool: "move_to", code: "route_blocked", at: t0.addingTimeInterval(5))
if case let .changeApproach(directive) = twice {
    expect(!directive.isEmpty, "换招指令是空的")
} else {
    failures.append("同一个失败连续两次没有换招：\(twice)")
}
let thrice = first.noteFailure(tool: "move_to", code: "route_blocked", at: t0.addingTimeInterval(10))
if case .handOff = thrice {} else { failures.append("预算用尽没有交给用户：\(thrice)") }

// 换了招（换了错误码）就只算一次新尝试：三次仍然是上限。
var changed = ResidentRetryLedger()
_ = changed.noteFailure(tool: "a", code: "c1", at: t0)
_ = changed.noteFailure(tool: "a", code: "c2", at: t0.addingTimeInterval(1))
if case .handOff = changed.noteFailure(tool: "a", code: "c3", at: t0.addingTimeInterval(2)) {
} else { failures.append("三次失败没有交给用户") }
// 成功清空账本。
changed.noteSuccess()
expect(changed.noteFailure(tool: "a", code: "c1", at: t0) == .retrySameApproach, "成功后账本没有清零")
expect(changed.attemptCount == 1, "成功后尝试数没有清零")

// 交给用户只有一句人话：不念编号 / 字段 / 路径 / 内部术语。
let handoff = ResidentRetryLedger.handoffText
expect(handoff.range(of: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}", options: .regularExpression) == nil,
       "人话里念了编号")
expect(handoff.range(of: "[A-Za-z_][A-Za-z0-9_]*\\s*=\\s*\\S", options: .regularExpression) == nil,
       "人话里念了字段名")
expect(!handoff.contains("/Users/") && !handoff.contains(".json") && !handoff.contains(".swift"),
       "人话里念了路径")
expect(!handoff.contains("tool_call") && !handoff.contains("schema") && !handoff.contains("revision"),
       "人话里念了内部术语")
expect(handoff.split(whereSeparator: { "。！？；".contains($0) }).count == 1, "人话不止一句")
expect(handoff.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count <= 40, "人话太长")

// 需要人类确认的动作照旧必须问，且不占自主重试预算。
var human = ResidentRetryLedger()
expect(human.noteFailure(tool: "apply_prop_placement", code: "human_guidance_required") == .needsHuman,
       "human_guidance_required 被当成可重试失败")
_ = human.noteFailure(tool: "x", code: "human_guidance_required")
_ = human.noteFailure(tool: "x", code: "human_guidance_required")
expect(human.attemptCount == 0, "需要人类确认的动作占了自主重试预算")
expect(human.noteFailure(tool: "x", code: "delegation_violation") == .needsHuman,
       "delegation_violation 没有走人类确认")

// 结构上不可能靠重试解决：第一次就具名，不空转、不占预算。
var structural = ResidentRetryLedger()
if case let .structural(named) = structural.noteFailure(tool: "generate_wish", code: "asset_missing") {
    expect(!named.isEmpty, "结构失败没有具名")
} else {
    failures.append("结构失败没有第一次具名")
}
expect(structural.attemptCount == 0, "结构失败占了重试预算")
for code in ["network_egress_blocked", "playback_source_unsupported", "not_installed", "permission_denied"] {
    var probe = ResidentRetryLedger()
    if case .structural = probe.noteFailure(tool: "x", code: code) {
    } else { failures.append("\(code) 没有第一次具名") }
}

for failure in failures { print("FAIL: \(failure)") }
print("POLICY_REFERENCE_BASE=\(RetryBackoffSite.referenceSearch.policy.baseDelay)")
exit(failures.isEmpty ? 0 : 1)
"""#

struct RunResult {
    let status: Int32
    let output: String
}

let work = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-resident-loop-retry-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

/// 把 `source` 当成 `RetryBackoff.swift` 与判据一起编译运行。
func runChecks(_ source: String, label: String) -> RunResult {
    // 判据文件必须叫 main.swift：swiftc 只给 main.swift 顶层语句。
    let directory = work.appendingPathComponent("run-\(label)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let policyURL = directory.appendingPathComponent("RetryBackoff.swift")
    let checksURL = directory.appendingPathComponent("main.swift")
    let binaryURL = work.appendingPathComponent("checks-\(label)")
    try? source.write(to: policyURL, atomically: true, encoding: .utf8)
    try? checksSource.write(to: checksURL, atomically: true, encoding: .utf8)
    let compile = Process()
    compile.executableURL = URL(fileURLWithPath: "/usr/bin/nice")
    compile.arguments = ["-n", "15", "/usr/bin/swiftc", "-j1", "-swift-version", "6",
                         policyURL.path, checksURL.path,
                         "-o", binaryURL.path]
    let compileError = Pipe()
    compile.standardError = compileError
    try? compile.run()
    compile.waitUntilExit()
    guard compile.terminationStatus == 0 else {
        let text = String(decoding: compileError.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return RunResult(status: compile.terminationStatus, output: "COMPILE FAILED: \(text.suffix(400))")
    }
    let run = Process()
    run.executableURL = binaryURL
    let pipe = Pipe()
    run.standardOutput = pipe
    run.standardError = pipe
    try? run.run()
    run.waitUntilExit()
    let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return RunResult(status: run.terminationStatus, output: text)
}

guard let baselineSource = read(backoffRelative) else { fail("读不到 \(backoffRelative)") }

// ---------------------------------------------------------------------------
// MARK: - 基线必须全绿
// ---------------------------------------------------------------------------

let baseline = runChecks(baselineSource, label: "baseline")
guard baseline.status == 0 else {
    fail("基线就是红的：\n\(baseline.output)")
}
guard let baseLine = baseline.output.split(separator: "\n").first(where: { $0.hasPrefix("POLICY_REFERENCE_BASE=") }),
      let referenceBase = Double(baseLine.dropFirst("POLICY_REFERENCE_BASE=".count)) else {
    fail("基线没有报出唯一策略里的参考图第一跳：\n\(baseline.output)")
}
print("PASS: 基线 — 退避递增/抖动/封顶/预算与居民 iterate 判据全绿（参考图第一跳 \(referenceBase) 秒）")

let baselineWiring = wiringFailures(read, referenceBase: referenceBase)
guard baselineWiring.isEmpty else {
    fail("接线判据基线就是红的：\(baselineWiring.joined(separator: "；"))")
}
print("PASS: 基线 — 六处退避读同一份策略，冻结的参考图常量与策略逐位一致")

// ---------------------------------------------------------------------------
// MARK: - 注入：每一条都必须 FAIL
// ---------------------------------------------------------------------------

struct Injection {
    let name: String
    let old: String
    let new: String
}

let injections: [Injection] = [
    Injection(name: "固定第一跳为零（忙转）",
              old: "baseDelay: 30, growth: 2, maximumDelay: 300, jitterFraction: 0.2",
              new: "baseDelay: 0, growth: 1, maximumDelay: 0, jitterFraction: 0"),
    Injection(name: "不再递增（growth 全部压成 1）", old: "growth: 2", new: "growth: 1"),
    Injection(name: "去掉抖动", old: "jitterFraction: 0.2", new: "jitterFraction: 0"),
    Injection(name: "去掉单跳封顶",
              old: "return min(baseDelay * pow(growth, Double(step)), maximumDelay)",
              new: "return baseDelay * pow(growth, Double(step))"),
    Injection(name: "关掉预算上限",
              old: "attempts >= maximumAttempts || elapsed >= maximumDuration",
              new: "false"),
    Injection(name: "第一次失败就交给用户",
              old: "if policy.isExhausted(attempts: attempts, elapsed: elapsed) {",
              new: "if true {"),
    Injection(name: "同一失败两次不换招（放到第三次）",
              old: "if sameCount >= 2 {",
              new: "if sameCount >= 3 {"),
    Injection(name: "绕过需要人类确认的动作",
              old: "if Self.humanRequiredCodes.contains(normalized) {",
              new: "if false {"),
    Injection(name: "结构失败也当可重试",
              old: "if let named = Self.structuralReason(normalized) {",
              new: "if let named = Optional<String>.none {"),
    Injection(name: "交给用户时念编号",
              old: "public static let handoffText = \"这件事我试了几次都没做成，需要你拿个主意。\"",
              new: "public static let handoffText = \"任务 3f2b9c41-8d7e-4a06-9b1f-2c5ae0d7bb31 没有完成，请稍后重试。\""),
    Injection(name: "交给用户时念字段名",
              old: "public static let handoffText = \"这件事我试了几次都没做成，需要你拿个主意。\"",
              new: "public static let handoffText = \"生成失败：reason=network，请稍后重试。\""),
]

var injectionFailures: [String] = []
for (index, injection) in injections.enumerated() {
    guard baselineSource.contains(injection.old) else {
        injectionFailures.append("注入「\(injection.name)」找不到注入点，门禁失效")
        continue
    }
    let injected = baselineSource.replacingOccurrences(of: injection.old, with: injection.new)
    let result = runChecks(injected, label: "inj\(index)")
    if result.status == 0 {
        injectionFailures.append("注入「\(injection.name)」没有被抓住（门禁失效）")
    } else {
        let firstFail = result.output.split(separator: "\n").first(where: { $0.hasPrefix("FAIL:") })
            .map(String.init) ?? "（编译失败）"
        print("PASS: 注入「\(injection.name)」⇒ FAIL 原话：\(firstFail)")
    }
}

// 接线注入：任一处回退到自己的常量 ⇒ 红。
for wiring in wirings {
    var contents: [String: String] = [:]
    for other in wirings { contents[other.path] = read(other.path) }
    contents[frozenReferencePath] = read(frozenReferencePath)
    guard var text = contents[wiring.path], text.contains(wiring.marker) else {
        injectionFailures.append("接线注入找不到 \(wiring.path) 的注入点")
        continue
    }
    text = text.replacingOccurrences(of: wiring.marker, with: "自己的常量")
    contents[wiring.path] = text
    let failures = wiringFailures({ contents[$0] }, referenceBase: referenceBase)
    if failures.isEmpty {
        injectionFailures.append("注入「\(wiring.path) 回退到自己的常量」没有被抓住")
    } else {
        print("PASS: 注入「\(wiring.path) 回退到自己的常量」⇒ FAIL 原话：\(failures[0])")
    }
}

// 冻结线漂移注入：单方面改参考图的 30 ⇒ 红。
do {
    var contents: [String: String] = [:]
    for wiring in wirings { contents[wiring.path] = read(wiring.path) }
    if var frozen = contents[frozenReferencePath] ?? read(frozenReferencePath) {
        frozen = frozen.replacingOccurrences(of: frozenReferenceAnchor + "30",
                                             with: frozenReferenceAnchor + "5")
        contents[frozenReferencePath] = frozen
        let failures = wiringFailures({ contents[$0] }, referenceBase: referenceBase)
        if failures.isEmpty {
            injectionFailures.append("注入「参考图冷却漂移」没有被抓住")
        } else {
            print("PASS: 注入「参考图冷却漂移」⇒ FAIL 原话：\(failures[0])")
        }
    } else {
        injectionFailures.append("冻结线漂移注入读不到源码")
    }
}

guard injectionFailures.isEmpty else {
    for failure in injectionFailures { print("FAIL: \(failure)") }
    print("FAIL: 注入自测有 \(injectionFailures.count) 条没红 —— 门禁自己失效了")
    exit(1)
}
print("PASS: 注入自测 \(injections.count + wirings.count + 1) 条全部被抓红（退避/换招/预算/人话/人类确认/结构失败/六处接线/冻结漂移）")
print("PASS: 居民自主 iterate 判据全绿")

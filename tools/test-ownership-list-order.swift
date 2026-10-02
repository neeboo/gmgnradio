// ---------------------------------------------------------------------------
// 「我的物件」列表**新的排前面**真的生效吗？
//
// 这条以前从来没生效过：宿主提供事实的那一侧写的是
//     order[f.objectID] = index
// 而唯一投影 `ResidentOwnershipProjection.ordered` 查的是
//     order[key.identifier]        // "<jobID>/<objectID>"
// 两边键不一致 ⇒ 每一次查都是 nil ⇒ 全部退回 `objectID` 字典序，「越新越前」形同虚设。
//
// 投影被冻结（`tools/test-ownership-list-plain-interface.swift` 逐字节钉着它），
// 所以只能改提供事实的那一侧 —— 这一份 harness 就是那一条的判据：
//
//   ① **键对上了**：宿主那一行**逐字抽出来**（不是在这里另写一遍），在真源码编译起来的
//      探针里驱动，三个 job 必须排出「最新 → 最旧」；
//   ② **旧写法确实不生效**（负对照的"缺陷原件"）：同一份投影换成裸 `objectID` 键，
//      排出来就不再是"新的在前" —— 证明这条判据真的抓得住那个 bug；
//   ③ 注入「改回旧写法」⇒ ① 必须 FAIL。
//   ④ 唯一投影的状态语义未被修改（与 HEAD 比**语义**，文案字符串放行）。
//
// 注入只改**内存副本**或**临时副本**，落盘的源码一个字不改。
//
// 用法：swift tools/test-ownership-list-order.swift
// ---------------------------------------------------------------------------
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let appRelative = "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift"
let projectionRelative = "apps/macos/Sources/GMGNRadio/Presence/ResidentOwnershipProjection.swift"

var failureCount = 0
func check(_ condition: Bool, _ message: String) {
    if condition {
        print("PASS \(message)")
    } else {
        print("FAIL \(message)")
        failureCount += 1
    }
}
func read(_ relative: String) throws -> String {
    try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
}

let appSource = try read(appRelative)
let projectionSource = try read(projectionRelative)

// ---------------------------------------------------------------------------
// ① 宿主那一行的键表达式**逐字抽出来**（不在这里另写一遍）
// ---------------------------------------------------------------------------
/// 抽 `order[<表达式>] = index` 里的 `<表达式>`。
func hostOrderKeyExpression(in source: String) -> String? {
    guard let start = source.range(of: "order[") else { return nil }
    let rest = source[start.upperBound...]
    guard let end = rest.range(of: "] = index") else { return nil }
    return String(rest[rest.startIndex..<end.lowerBound])
}

let keyExpression = hostOrderKeyExpression(in: appSource) ?? ""
check(!keyExpression.isEmpty, "宿主里找得到提供事实的那一行 `order[...] = index`（逐字抽出来：\(keyExpression)）")
check(keyExpression.contains("OwnershipRowKey(") && keyExpression.contains(".identifier"),
    "① 键由**唯一投影自己的类型**现算（`OwnershipRowKey(...).identifier`），不在这里手拼字符串")
check(!keyExpression.contains("f.objectID"),
    "① 键不再是裸 `objectID`（那正是与 `ordered` 查的 `key.identifier` 对不上的成因）")

/// 违规项：宿主那一行又退回旧写法。**注入负对照要的就是「这里非空」。**
func orderKeyViolations(app: String) -> [String] {
    var out: [String] = []
    guard let expression = hostOrderKeyExpression(in: app) else {
        return ["宿主里找不到 `order[...] = index` —— 「新的排前面」的键没了"]
    }
    if expression.contains("f.objectID") {
        out.append("提供事实的键又退回裸 `objectID`（\(expression)）—— 它永远查不到 `ordered` 要的 `key.identifier`")
    }
    if !expression.contains("OwnershipRowKey(") {
        out.append("键不是由投影的 `OwnershipRowKey` 现算的（\(expression)）—— 手拼一份就是第二份真相")
    }
    return out
}

// ---------------------------------------------------------------------------
// ④ 唯一投影的**状态语义**未被修改（不是整文件哈希）
//
// 这一条过去是「与 HEAD 逐字节相同」。它的本意是「不许长出第二套状态推导」，但逐字节
// 连**文案**一起钉死了：2026-10-02 文案简化线要改投影里那三条大字面（`:430` /
// `:491` / `:493`），只能记成 `OPEN(frozen)` 欠账。现在钉语义那一半：类型与唯一出口的
// 签名逐字还在、五种对外状态 + 七个动作的**集合**不变、`Codable` / `init(rawValue:)` /
// 解码器仍然没有。**文案字符串不在判据里** —— 文案要能改，状态不许长第二套
// （同一套判据见 `tools/test-ownership-list-plain-interface.swift` 判据 5）。
// ---------------------------------------------------------------------------
func gitShowHead(_ relative: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["show", "HEAD:\(relative)"]
    let pipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = pipe
    process.standardError = errorPipe
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        print("   · git show HEAD:\(relative) 失败：退出码 \(process.terminationStatus) stderr=\(String(decoding: errorData, as: UTF8.self).prefix(200))")
        return nil
    }
    return String(decoding: data, as: UTF8.self)
}
func codeOnly(_ source: String) -> String {
    source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
        guard let range = line.range(of: "//") else { return String(line) }
        return String(line[line.startIndex..<range.lowerBound])
    }.joined(separator: "\n")
}
/// 一个 enum 的**顶层** case 名集合（`switch` 分支里的 `case .x:` 不算）。
func enumCaseNames(_ source: String, _ signature: String) -> Set<String> {
    let parts = source.components(separatedBy: signature)
    guard parts.count > 1, let body = parts[1].components(separatedBy: "\n}").first else { return [] }
    var names: Set<String> = []
    for line in body.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("case ") else { continue }
        for name in trimmed.dropFirst("case ".count).split(separator: ",") {
            let token = name.trimmingCharacters(in: .whitespaces)
            guard !token.isEmpty, token.allSatisfy({ $0.isLetter || $0.isNumber }) else { continue }
            names.insert(token)
        }
    }
    return names
}
/// 唯一投影的**状态语义核心**：签名在不在 + 两个枚举的 case 集合 + 派生结论不许落盘的记号。
/// **文案不在里面**：改文案核心不变；长出第二套状态它就变。
let semanticOutlets = [
    "enum OwnershipDisplayState: String, Sendable, CaseIterable {",
    "enum OwnershipRowAction: String, Sendable, CaseIterable {",
    "struct OwnershipRow: Equatable, Sendable, Identifiable {",
    "static func row(_ facts: OwnershipRowFacts) -> OwnershipRow {",
    "static func ordered(_ rows: [OwnershipRow], order: [String: Int]) -> [OwnershipRow] {",
    "static func list(_ rows: [OwnershipRow], order: [String: Int] = [:],",
    "static func group(for state: OwnershipDisplayState) -> OwnershipGroup {",
    "static func sentence(generation: String, ownership: String, placement: String,",
]
let semanticForbidden = ["Codable", "Decodable", "init(rawValue:", "init?(rawValue:", "JSONDecoder"]
func semanticCore(_ source: String) -> String {
    let code = codeOnly(source)
    var parts: [String] = []
    for outlet in semanticOutlets { parts.append(code.contains(outlet) ? "有" : "缺") }
    parts.append(enumCaseNames(code, "enum OwnershipDisplayState: String, Sendable, CaseIterable {").sorted().joined(separator: ","))
    parts.append(enumCaseNames(code, "enum OwnershipRowAction: String, Sendable, CaseIterable {").sorted().joined(separator: ","))
    for forbidden in semanticForbidden { parts.append(code.contains(forbidden) ? "有" : "无") }
    return parts.joined(separator: "\n")
}
if let head = gitShowHead(projectionRelative) {
    check(semanticCore(projectionSource) == semanticCore(head),
          "④ 唯一投影的状态语义与 HEAD 相同：签名 / 五种对外状态 + 七个动作的集合 / 不许 Codable / 不许 init(rawValue:)（文案字符串放行）")
    // 负对照：把语义改坏 ⇒ 核心必须与 HEAD 不同（只改内存副本，落盘源码一个字不改）。
    let codableInjected = projectionSource.replacingOccurrences(
        of: "enum OwnershipDisplayState: String, Sendable, CaseIterable {",
        with: "enum OwnershipDisplayState: String, Sendable, CaseIterable, Codable {")
    check(codableInjected != projectionSource && semanticCore(codableInjected) != semanticCore(head),
          "④ 负对照「给对外状态加 Codable」：注入 ⇒ 语义核心与 HEAD 不同（这一条抓得住）")
    let sixthStateInjected = projectionSource.replacingOccurrences(
        of: "    case generating\n", with: "    case generating\n    case pendingReview\n")
    check(sixthStateInjected != projectionSource && semanticCore(sixthStateInjected) != semanticCore(head),
          "④ 负对照「长出第六种对外状态」：注入 ⇒ 语义核心与 HEAD 不同")
    // 正对照：文案改回工程腔 ⇒ 核心**不变**（文案归文案门禁管，语义门禁不管）。
    let copyBack = projectionSource.replacingOccurrences(of: "来自你的许愿", with: "按 sourceWishID 认到所属许愿")
    check(copyBack != projectionSource && semanticCore(copyBack) == semanticCore(head),
          "④ 正对照「文案改回工程腔」：语义核心不变 —— 语义门禁不管文案")
} else {
    check(false, "④ 读不到 HEAD 那一份投影，语义判据无法成立")
}

// ---------------------------------------------------------------------------
// ② 编译真源码，用**宿主那一行逐字抽出来的键**驱动
// ---------------------------------------------------------------------------
let testSource = """
import Foundation

var failures = 0
func expect(_ condition: Bool, _ message: String) {
    print((condition ? "PASS " : "FAIL ") + message)
    if !condition { failures += 1 }
}

struct FakeJob { let id: UUID; let objectID: String }

/// **逐字来自宿主**（`GMGNRadioApp.residentPropWishFacts` 里那一行）的键表达式。
func hostOrder(_ jobs: [FakeJob]) -> [String: Int] {
    var order: [String: Int] = [:]
    for (index, job) in jobs.enumerated() {
        let objectID = job.objectID
        order[\(keyExpression)] = index
    }
    return order
}

/// 缺陷原件：键是裸 `objectID`（与 `ordered` 查的 `key.identifier` 对不上）。
func buggyOrder(_ jobs: [FakeJob]) -> [String: Int] {
    var order: [String: Int] = [:]
    for (index, job) in jobs.enumerated() {
        _ = job.id
        order[job.objectID] = index
    }
    return order
}

func facts(_ job: FakeJob, name: String, index: Int) -> OwnershipRowFacts {
    var value = OwnershipRowFacts(objectID: job.objectID)
    value.jobID = job.id
    value.jobName = name
    value.jobStage = .generating
    value.processOrder = index
    return value
}

// 宿主的 job 顺序 = 旧 → 新（`residentPropWishFacts` 按 `jobs` 的枚举序给 index）。
let oldest = FakeJob(id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!, objectID: "wish-prop-a")
let middle = FakeJob(id: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!, objectID: "wish-prop-b")
let newest = FakeJob(id: UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000003")!, objectID: "wish-prop-c")
let jobs = [oldest, middle, newest]
let names = ["一号", "二号", "三号"]
let rows = zip(jobs, names).enumerated().map { index, pair in
    ResidentOwnershipProjection.row(facts(pair.0, name: pair.1, index: index))
}

let ordered = ResidentOwnershipProjection.ordered(rows, order: hostOrder(jobs))
print("ORDER[host]  \\(ordered.map(\\.key.objectID).joined(separator: " → "))")
expect(ordered.map(\\.key.objectID) == [newest.objectID, middle.objectID, oldest.objectID],
    "① 键对上了：最新的排在最前面（\\(ordered.map(\\.key.objectID).joined(separator: " → "))）")

let buggy = ResidentOwnershipProjection.ordered(rows, order: buggyOrder(jobs))
print("ORDER[buggy] \\(buggy.map(\\.key.objectID).joined(separator: " → "))")
expect(buggy.map(\\.key.objectID) != [newest.objectID, middle.objectID, oldest.objectID],
    "② 旧写法（裸 objectID 键）确实不生效 —— 这就是那个 bug 的正身")

// 没有 job 的孤儿行不参与这个顺序（宿主也只给有 job 的行排）。
var orphanFacts = OwnershipRowFacts(objectID: "wish-prop-orphan")
orphanFacts.objectPresent = true
orphanFacts.objectHasGeneratedProp = true
orphanFacts.objectIsEnabled = true
let orphan = ResidentOwnershipProjection.row(orphanFacts)
expect(orphan.key.jobID == nil && orphan.key.identifier == "-/wish-prop-orphan",
    "孤儿行的键是 `-/<objectID>`（它本来就不在宿主的 order 里，不许误伤）")

print(failures == 0 ? "PASS 排序键判据全部通过" : "FAIL 排序键判据有 \\(failures) 条不通过")
exit(failures == 0 ? 0 : 1)
"""

func runProbe() throws -> (status: Int32, output: String) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gmgn-ownership-order-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let projectionFile = directory.appendingPathComponent("ResidentOwnershipProjection.swift")
    let mainFile = directory.appendingPathComponent("main.swift")
    let binary = directory.appendingPathComponent("tests")
    try projectionSource.write(to: projectionFile, atomically: true, encoding: .utf8)
    // 探针里的键表达式就是上面从**宿主真源码**里逐字抽出来的那一段（不是在这里另写一遍）。
    try testSource.write(to: mainFile, atomically: true, encoding: .utf8)
    let compile = Process()
    compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
    compile.arguments = ["-j1", "-target", "arm64-apple-macos14.0",
                         projectionFile.path, mainFile.path, "-o", binary.path]
    let compilePipe = Pipe()
    compile.standardOutput = compilePipe
    compile.standardError = compilePipe
    try compile.run()
    let compileData = compilePipe.fileHandleForReading.readDataToEndOfFile()
    compile.waitUntilExit()
    guard compile.terminationStatus == 0 else {
        return (compile.terminationStatus, String(decoding: compileData, as: UTF8.self))
    }
    let process = Process()
    process.executableURL = binary
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

let pristine = try runProbe()
if pristine.output.contains("ORDER[") {
    for line in pristine.output.split(separator: "\n") where line.hasPrefix("ORDER[") {
        print("   · 顺序证据 \(line)")
    }
}
guard pristine.status == 0 else {
    for line in pristine.output.split(separator: "\n") { print("   · \(line)") }
    check(false, "① 驱动真源码抽出来的键：最新的排在最前面、旧写法确实不生效")
    print("FAIL 排序键判据有 \(failureCount) 条不通过")
    exit(1)
}
check(true, "① 驱动真源码抽出来的键：最新的排在最前面；旧写法（裸 objectID）确实不生效")

// ---------------------------------------------------------------------------
// ③ 注入负对照：把提供事实的键改回旧写法（只在内存副本上）
// ---------------------------------------------------------------------------
func injectLegacyKey(into app: String) -> String {
    guard let expression = hostOrderKeyExpression(in: app) else { return app }
    return app.replacingOccurrences(of: "order[\(expression)] = index", with: "order[f.objectID] = index")
}

let injected = injectLegacyKey(into: appSource)
check(injected != appSource, "注入负对照「改回旧写法」确实改到了源码副本")
let injectedViolations = orderKeyViolations(app: injected)
check(!injectedViolations.isEmpty,
    "注入负对照「改回旧写法」⇒ 判据必须变红（第一条：\(injectedViolations.first ?? "（没有）")）")

print(failureCount == 0
    ? "PASS 「新的排前面」排序键判据全部通过"
    : "FAIL 「新的排前面」排序键判据有 \(failureCount) 条不通过")
exit(failureCount == 0 ? 0 : 1)

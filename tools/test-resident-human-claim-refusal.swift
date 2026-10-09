// Gate: 人类轮次「领取被拒」必须是**具名、可见、有界**的，不能再静默返回。
//
// 缺陷（真机 2026-10-09，build 229）：`agent_loop_claim` 回 `{"claimed":false}` 时
// 宿主 `ResidentAgentLoop.drainRustHumanMessages` 里那一句
// `guard let ticket else { return }` 直接返回 —— 用户发出去的消息停在 `queued`，
// 既没有回复、也没有任何错误，界面只剩「等待居民回应…」。同一现象的另一半
// （daemon 把 `unknown` 也算"在飞"）已在 `services/gmgn-taskd/src/agent_scheduler.rs`
// 收窄（`state IN ('claimed','cancel_requested')`）。
//
// 这个 harness 钉住宿主这一半：
//   ① 纯判定：`RustResidentSchedulerClient.swift` 里 `resident-human-claim-refusal`
//      标记块被**逐字**抽出来单独编译，驱动它跑"在等什么"的每一条分支；
//   ② 注入回归：把行为改回旧样子（`unknown` 又算在飞、`cancel_requested` 不算在飞、
//      判定匿名化、具名失败无上界）必须变红 —— 判据是可falsify 的，不是装饰；
//   ③ 接线：两个生产文件里"被拒要具名/可见/有界"必须真的被调用，且**没有**
//      自行发明 daemon 路由（Swift 侧出现的每个 `agent_loop_*` 方法都能在
//      `agent_scheduler.rs` 的 match 分支里找到）。
//
// `swift tools/test-resident-human-claim-refusal.swift`
import Foundation

let root = FileManager.default.currentDirectoryPath
func source(_ relative: String) throws -> String {
    try String(contentsOfFile: root + "/" + relative, encoding: .utf8)
}

var failures: [String] = []
func check(_ condition: Bool, _ what: String) {
    if condition { print("   · ok  \(what)") } else { failures.append(what); print("   · FAIL \(what)") }
}

// ---------------------------------------------------------------------------
// The driver compiled *against the extracted pure block*. Same text for the
// pristine block and for every injected mutation, so a mutation that breaks a
// behaviour makes the driver's exit status non-zero.
// ---------------------------------------------------------------------------
let driver = #"""
import Foundation

var failures: [String] = []
func check(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }

func ev(_ available: Bool = true, _ editing: Bool = false, _ executing: Int = 0, _ stale: Int = 0,
        _ ourState: String? = "pending", _ otherPendingHuman: Int = 0) -> ResidentHumanClaimEvidence {
    var e = ResidentHumanClaimEvidence()
    e.available = available; e.editing = editing; e.executing = executing
    e.staleUnconfirmed = stale; e.ourEventState = ourState; e.otherPendingHuman = otherPendingHuman
    return e
}

// ① config 的 blocked 先说话，而且是具名的。
let unavailable = residentHumanClaimRefusal(ev(false, false, 0, 0, "pending"))
check(unavailable.code == "agent_loop_unavailable", "不可用要具名：agent_loop_unavailable")
check(!unavailable.waiting.isEmpty, "不可用也要说人话")
check(residentHumanClaimRefusal(ev(true, true, 0, 0, "pending")).code == "agent_loop_editing",
      "装修中要具名：agent_loop_editing")

// ② 真正挡人的是"在飞"，且必须说清"上一轮尚未结算"。
let inFlight = residentHumanClaimRefusal(ev(true, false, 1, 0, "pending"))
check(inFlight.code == "agent_loop_turn_in_flight", "在飞要具名：agent_loop_turn_in_flight")
check(inFlight.waiting.contains("尚未结算"), "在飞要说清在等什么：上一轮尚未结算")
check(inFlight.waiting.contains("1"), "在飞要带上条数")

// ③ 遗留 unknown **不再**冒充"在飞"（daemon 侧已收窄，宿主不得把它说成在飞）。
let staleOnly = residentHumanClaimRefusal(ev(true, false, 0, 3, "pending"))
check(staleOnly.code != "agent_loop_turn_in_flight", "遗留 unknown 不得再说成在飞")
check(staleOnly.code == "agent_loop_claim_refused", "遗留 unknown + 本批 pending ⇒ 仍然只是被拒")
check(staleOnly.waiting == "上一轮尚未结算", "兜底也必须点名在等什么")
check(staleOnly.waiting != "" && !staleOnly.waiting.isEmpty, "兜底不得为空")

// ④ 本批事件自己的状态。
check(residentHumanClaimRefusal(ev(true, false, 0, 0, "unknown")).code == "agent_loop_stale_unconfirmed_turns",
      "本批 unknown 要具名：agent_loop_stale_unconfirmed_turns")
check(residentHumanClaimRefusal(ev(true, false, 0, 0, "cancelled")).code == "agent_loop_event_not_pending",
      "本批非 pending 要具名：agent_loop_event_not_pending")
check(residentHumanClaimRefusal(ev(true, false, 0, 0, nil)).code == "agent_loop_event_missing",
      "权威里没有本批行要具名：agent_loop_event_missing")
check(residentHumanClaimRefusal(ev(true, false, 0, 0, "pending", 2)).code == "agent_loop_prior_human_event_pending",
      "更早的 human 事件挡着要具名：agent_loop_prior_human_event_pending")

// ⑤ 折叠权威事件行：`cancel_requested` 与 daemon 的 `state IN (...)` 一致地算在飞。
var fold = ResidentHumanClaimEvidence()
fold.ourEventID = "human.A"
residentHumanClaimEvidenceFoldingEvent(&fold, eventID: "human.A", state: "cancel_requested", kind: "human")
check(fold.executing == 1, "cancel_requested 也算在飞（与 daemon 的 state IN 一致）")
check(fold.ourEventState == "cancel_requested", "本批状态被记下")
residentHumanClaimEvidenceFoldingEvent(&fold, eventID: "human.B", state: "pending", kind: "human")
check(fold.otherPendingHuman == 1, "别的 pending human 事件被记下")
residentHumanClaimEvidenceFoldingEvent(&fold, eventID: "human.C", state: "unknown", kind: "background")
check(fold.staleUnconfirmed == 1, "unknown 只进旁证计数")
check(fold.executing == 1, "unknown 不得进在飞计数")
residentHumanClaimEvidenceFoldingEvent(&fold, eventID: nil, state: nil, kind: nil)
check(fold.executing == 1 && fold.staleUnconfirmed == 1, "缺字段的行不得改变任何计数")

// ⑥ 可见文案：等的时候与超时的时候都要说人话，且超时要带 code。
let notice = inFlight.waitingNotice(attempts: 4)
check(notice.contains("尚未结算"), "等待提示要说清在等什么")
check(notice.contains("4"), "等待提示要带上重试次数")
check(notice.contains("队列"), "等待提示要说清消息还在队列里")
let failure = inFlight.namedFailure(waitedSeconds: 15, attempts: 4)
check(failure.contains("agent_loop_turn_in_flight"), "具名失败必须带 code")
check(failure.contains("15") && failure.contains("4"), "具名失败要带等待秒数与次数")
check(failure.contains("队列"), "具名失败要说清消息还在不在")

// ⑦ 有界：具名失败必须有有限的门槛，报告间隔不得为 0。
check(residentHumanClaimNamedFailureSeconds > 0 && residentHumanClaimNamedFailureSeconds <= 60,
      "具名失败门槛有界（0 < x ≤ 60 秒）")
check(residentHumanClaimReportIntervalSeconds >= 1, "报告间隔 ≥ 1 秒（不刷屏）")

if failures.isEmpty { print("PASS driver: claim-refusal behaviours named") ; exit(0) }
for failure in failures { print("FAIL \(failure)") }
exit(1)
"""#

func compileAndRun(blockSource: String, tag: String) throws -> (status: Int32, output: String) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gmgn-claim-refusal-\(tag)-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let blockFile = directory.appendingPathComponent("ResidentHumanClaimRefusal.swift")
    let mainFile = directory.appendingPathComponent("main.swift")
    let binary = directory.appendingPathComponent("harness")
    try ("import Foundation\n" + blockSource).write(to: blockFile, atomically: true, encoding: .utf8)
    try driver.write(to: mainFile, atomically: true, encoding: .utf8)
    let compile = Process()
    compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
    compile.arguments = ["-j1", "-target", "arm64-apple-macos14.0",
                         blockFile.path, mainFile.path, "-o", binary.path]
    let compilePipe = Pipe()
    compile.standardOutput = compilePipe
    compile.standardError = compilePipe
    try compile.run()
    let compileData = compilePipe.fileHandleForReading.readDataToEndOfFile()
    compile.waitUntilExit()
    guard compile.terminationStatus == 0 else {
        return (compile.terminationStatus, "compile failed:\n" + String(decoding: compileData, as: UTF8.self))
    }
    let run = Process()
    run.executableURL = binary
    let pipe = Pipe()
    run.standardOutput = pipe
    run.standardError = pipe
    try run.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    run.waitUntilExit()
    return (run.terminationStatus, String(decoding: data, as: UTF8.self))
}

// ---------------------------------------------------------------------------
// The pure block, extracted *verbatim* from the production client.
// ---------------------------------------------------------------------------
let clientPath = "apps/macos/Sources/GMGNRadio/Presence/RustResidentSchedulerClient.swift"
let loopPath = "apps/macos/Sources/GMGNRadio/Agent/ResidentAgentLoop.swift"
let daemonPath = "services/gmgn-taskd/src/agent_scheduler.rs"
let beginMarker = "// >>> resident-human-claim-refusal"
let endMarker = "// <<< resident-human-claim-refusal"
let clientSource = try source(clientPath)
let loopSource = try source(loopPath)
guard let begin = clientSource.range(of: beginMarker),
      let end = clientSource.range(of: endMarker), begin.upperBound < end.lowerBound else {
    print("FAIL 抽不到 \(beginMarker) … \(endMarker)（判定块被删/被改名）")
    exit(1)
}
let pristineBlock = String(clientSource[begin.upperBound..<end.lowerBound])
    .trimmingCharacters(in: .whitespacesAndNewlines)
check(!pristineBlock.isEmpty, "① 生产判定块非空（\(pristineBlock.count) 字符，来自 \(clientPath)）")

// ---------------------------------------------------------------------------
// ① Pristine: the driver must pass.
// ---------------------------------------------------------------------------
let pristine = try compileAndRun(blockSource: pristineBlock, tag: "pristine")
guard pristine.status == 0, pristine.output.contains("PASS") else {
    for line in pristine.output.split(separator: "\n") { print("   · \(line)") }
    check(false, "① 生产判定块必须通过：被拒要具名（code + 在等什么）、遗留 unknown 不再冒充在飞、超时文案带 code、门槛有界")
    print("FAIL resident human claim refusal harness has \(failures.count) failing checks")
    exit(1)
}
check(true, "① 生产判定：每一类被拒都有稳定 code、`waiting` 说清在等什么、超时文案带 code、门槛 15 秒有界")

// ---------------------------------------------------------------------------
// ② Injection: changing each behaviour back to the old one must go red.
// ---------------------------------------------------------------------------
struct Mutation {
    let name: String
    let apply: (String) -> String?
}
let mutations: [Mutation] = [
    // 这正是 daemon 侧刚修掉的那条旧规则，回到宿主就是"unknown 又算在飞"。
    Mutation(name: "遗留 unknown 又算在飞（`case \"unknown\": staleUnconfirmed += 1` → `executing += 1`）") { text in
        let anchor = "    case \"unknown\": evidence.staleUnconfirmed += 1"
        guard text.contains(anchor) else { return nil }
        return text.replacingOccurrences(of: anchor, with: "    case \"unknown\": evidence.executing += 1")
    },
    // daemon 的"在飞"是 claimed **和** cancel_requested；少一个就漏报真挡人的回合。
    Mutation(name: "cancel_requested 不算在飞（`case \"claimed\", \"cancel_requested\"` → `case \"claimed\"`）") { text in
        let anchor = "    case \"claimed\", \"cancel_requested\": evidence.executing += 1"
        guard text.contains(anchor) else { return nil }
        return text.replacingOccurrences(of: anchor, with: "    case \"claimed\": evidence.executing += 1")
    },
    // 匿名化：这正是缺陷的形态 —— 被拒了却不说被什么挡住。
    Mutation(name: "判定匿名化（`waiting: \"上一轮尚未结算（还有 ...` → `waiting: \"等待中`）") { text in
        let anchor = "waiting: \"上一轮尚未结算（还有 \\(evidence.executing) 个回合在进行中）\")"
        guard text.contains(anchor) else { return nil }
        return text.replacingOccurrences(of: anchor, with: "waiting: \"等待中\"")
    },
    // 没有上界的"超时"等于永远不超时。
    Mutation(name: "具名失败门槛无界（`NamedFailureSeconds: Double = 15` → `.infinity`）") { text in
        let anchor = "let residentHumanClaimNamedFailureSeconds: Double = 15"
        guard text.contains(anchor) else { return nil }
        return text.replacingOccurrences(of: anchor, with: "let residentHumanClaimNamedFailureSeconds: Double = .infinity")
    },
    // 兜底：把执行的判定整个短路，等价于"被拒了什么都不说"。
    Mutation(name: "在飞判定短路（`if evidence.executing > 0 {` → `if false {`）") { text in
        let anchor = "    if evidence.executing > 0 {"
        guard text.contains(anchor) else { return nil }
        return text.replacingOccurrences(of: anchor, with: "    if false {")
    },
]
for mutation in mutations {
    guard let mutated = mutation.apply(pristineBlock), mutated != pristineBlock else {
        check(false, "② 注入锚点漂移：\(mutation.name)")
        continue
    }
    let result = try compileAndRun(blockSource: mutated, tag: "mutated")
    let wentRed = result.status != 0
    check(wentRed, "② 注入必须红：\(mutation.name)")
    if wentRed, let first = result.output.split(separator: "\n").first(where: { $0.hasPrefix("FAIL ") }) {
        print("      ↳ \(first)")
    }
}

// ---------------------------------------------------------------------------
// ③ Wiring: the two production files must actually *use* it, and must not
//    invent a daemon route.
// ---------------------------------------------------------------------------
// 旧行为的确切文本：静默返回。它必须**不再存在**。
check(!loopSource.contains("guard let ticket else { return }"),
      "③ 宿主不得再有静默返回 `guard let ticket else { return }`")
check(loopSource.contains("humanClaimRefusalEvidence("),
      "③ 被拒时宿主必须做只读取证（`humanClaimRefusalEvidence`）")
check(loopSource.contains("residentHumanClaimRefusal("),
      "③ 宿主必须用纯判定把「被什么挡住」具名")
check(loopSource.contains(".waitingNotice(attempts:"),
      "③ 等待期间必须给出用户可见的「在等什么」（`waitingNotice`）")
check(loopSource.contains(".namedFailure(waitedSeconds:"),
      "③ 超时必须给出具名失败（`namedFailure`）")
check(loopSource.contains("residentHumanClaimNamedFailureSeconds")
      && loopSource.contains("residentHumanClaimReportIntervalSeconds"),
      "③ 门槛与报告间隔必须读唯一那份常量，不得另抄一套数字")
check(loopSource.contains("progress = failure"),
      "③ 具名失败必须真的落到用户可见状态行（`progress`），不能只写不渲染的 `lastFailure`")
check(loopSource.contains("rustHumanClaimRefusalEvidence"),
      "③ 证据必须落到宿主状态里（否则只是算完就丢）")
check(clientSource.contains("agent_loop_read"),
      "③ 取证必须走既有只读路由 `agent_loop_read`（不新增路由）")

// Swift 侧出现的每个 agent_loop_* 方法都必须在 daemon 的 match 分支里存在。
func swiftRequestedMethods(_ text: String) -> Set<String> {
    var methods = Set<String>()
    var rest = Substring(text)
    while let open = rest.range(of: "request(\"") {
        let tail = rest[open.upperBound...]
        guard let close = tail.firstIndex(of: "\"") else { break }
        let name = String(tail[..<close])
        if name.hasPrefix("agent_loop_") { methods.insert(name) }
        rest = tail[close...]
    }
    return methods
}
func daemonRoutedMethods(_ text: String) -> Set<String> {
    var methods = Set<String>()
    let name = try! NSRegularExpression(pattern: "agent_loop_[a-z_]+")
    for line in text.split(separator: "\n") {
        let trimmed = line.drop(while: { $0 == " " })
        guard trimmed.hasPrefix("\"agent_loop_"), line.contains("=>") else { continue }
        let ns = String(line) as NSString
        for match in name.matches(in: String(line), range: NSRange(location: 0, length: ns.length)) {
            methods.insert(ns.substring(with: match.range))
        }
    }
    return methods
}
let swiftMethods = swiftRequestedMethods(clientSource)
let daemonMethods = daemonRoutedMethods((try? source(daemonPath)) ?? "")
if daemonMethods.isEmpty {
    print("   · 跳过路由对照：读不到 \(daemonPath) 的 match 分支（不因为读不到而放宽）")
} else {
    let invented = swiftMethods.subtracting(daemonMethods).sorted()
    check(invented.isEmpty, "③ 不得自行发明 daemon 路由；Swift 侧请求=\(swiftMethods.sorted().joined(separator: ","))；未路由的=\(invented.joined(separator: ","))")
    check(swiftMethods.contains("agent_loop_read"), "③ 取证用的 `agent_loop_read` 确实已被 daemon 路由")
}

if failures.isEmpty {
    print("PASS resident human claim refusal harness: ① 具名判定 green, ② \(mutations.count) 注入回归 red, ③ 接线（宿主不再静默 + 可见 + 有界 + 不发明路由）")
    exit(0)
}
for failure in failures { print("FAIL \(failure)") }
print("FAIL resident human claim refusal harness has \(failures.count) failing checks")
exit(1)

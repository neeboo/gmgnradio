// Gate: the manual-motion gate is a *bounded, named, read-exempt* state machine.
//
// 2026-10-09 (build 228), user report 选定动作报错: `presence.motion` was answered
// `presence_selection_busy` ⇒ `discarded`, while the only operation running was a
// read (`presence.load` binding the whole catalog). The same marker had no upper
// bound, so any `await` that never returned (an authority call with no timeout /
// a `URLSession` download) made every later click busy for ever. `pendingSelection`
// is a *different* code (`presence_renderer_pending`) and the renderer receipt was
// identified by an ever-advancing publish counter, so a real load's receipt was
// rejected and `pendingRenderer` never cleared (W2).
//
// This harness drives the *pure* state machine (`apps/macos/UnityHost/
// UnityPresenceSelectionGate.swift`, compiled from the production file) with the
// behaviours that regression broke, and then proves the harness can fail:
//   ① pristine gate ⇒ PASS;
//   ② three injected "改回旧行为" sources ⇒ each must FAIL (compile + run), so the
//      assertions are falsifiable rather than decorative;
//   ③ the *wiring* is pinned in the production sources (the gate must actually be
//      used by the bridge / media host / model / client), and the production
//      `Serial` actor is driven with a predecessor that never returns: pristine
//      ⇒ bounded, "no timeout" ⇒ red;
//   ④ the read-only discriminator that tells a host-side refusal from a daemon one
//      (`presence_selection_requests` row count unchanged across the refused click)
//      is exercised against the read-only `.bak-*` copy of taskd's DB, and never
//      against the live `tasks.sqlite3`.
//
// `make test-harnesses` runs it with `swift tools/test-presence-selection-gate.swift`.
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
// The driver compiled *against the production gate file*. It is the same text
// for every source (pristine and injected), so a mutation that breaks a
// behaviour makes the driver's exit status non-zero.
// ---------------------------------------------------------------------------
let driver = #"""
import Foundation

var failures: [String] = []
func check(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }

// ① Classification: a read is exactly the ops that never own the selection.
check(PresenceSelectionGate.Kind.classify(op: "presence.load") == .read, "presence.load is a read")
check(PresenceSelectionGate.Kind.classify(op: "presence.catalog") == .read, "presence.catalog is a read")
check(PresenceSelectionGate.Kind.classify(op: "presence.catalog.refresh") == .read, "presence.catalog.refresh is a read")
check(PresenceSelectionGate.Kind.classify(op: "presence.motion") == .selection, "presence.motion is a selection")
check(PresenceSelectionGate.Kind.classify(op: "presence.activate") == .selection, "presence.activate is a selection")
check(PresenceSelectionGate.Kind.classify(op: "presence.remove") == .write, "presence.remove is a write")
check(PresenceSelectionGate.Kind.classify(op: "presence.download") == .write, "presence.download is a write")
check(PresenceSelectionGate.Kind.classify(op: "presence.catalog.install") == .write, "presence.catalog.install is a write")

// ② A read never refuses a selection (the 2026-10-09 root cause).
var readGate = PresenceSelectionGate()
_ = readGate.begin(op: "presence.load", nowMillis: 1_000)
check(readGate.refusal(isWorking: false, hasPendingSelection: false) == nil,
      "an in-flight presence.load must not refuse a selection")
// presence.catalog's refresh sets the model's own working flag while it runs;
// the read explains it, so it must still not refuse.
var catalogGate = PresenceSelectionGate()
_ = catalogGate.begin(op: "presence.catalog", nowMillis: 1_000)
check(catalogGate.refusal(isWorking: true, hasPendingSelection: false) == nil,
      "a read explains isWorking and must not refuse")
check(catalogGate.refusal(isWorking: false, hasPendingSelection: true) == PresenceSelectionGate.codeRendererPending,
      "pendingSelection is presence_renderer_pending, not busy")

// ③ No loosening: a live selection/write, or isWorking with no read in flight,
//    still refuses serialisation between selections.
var busy = PresenceSelectionGate()
_ = busy.begin(op: "presence.motion", nowMillis: 1_000)
check(busy.refusal(isWorking: false, hasPendingSelection: false) == PresenceSelectionGate.codeBusy,
      "a live selection refuses another selection")
check(busy.refusal(isWorking: false, hasPendingSelection: true) == PresenceSelectionGate.codeBusy,
      "busy wins over pending, as before")
var writeBusy = PresenceSelectionGate()
_ = writeBusy.begin(op: "presence.download", nowMillis: 0)
check(writeBusy.refusal(isWorking: false, hasPendingSelection: false) == PresenceSelectionGate.codeBusy,
      "a live write refuses a selection")
var bareWorking = PresenceSelectionGate()
check(bareWorking.refusal(isWorking: true, hasPendingSelection: false) == PresenceSelectionGate.codeBusy,
      "isWorking with no read in flight refuses a selection")

// ④ A completion only clears the generation that began it.
var gen = PresenceSelectionGate()
let g1 = gen.begin(op: "presence.motion", nowMillis: 0)
let g2 = gen.begin(op: "presence.motion", nowMillis: 10)
check(gen.finish(generation: g1) == nil, "a late completion clears nothing")
check(gen.refusal(isWorking: false, hasPendingSelection: false) == PresenceSelectionGate.codeBusy,
      "the replacing marker is still live")
check(gen.finish(generation: g2) == .operation, "the current generation clears the operation slot")
check(gen.refusal(isWorking: false, hasPendingSelection: false) == nil, "and then the gate is free")

// ⑤ Stale reclaim: a marker has an upper bound, the clear is named, the
//    selection continues, and the reclaimed op's completion is late.
var stale = PresenceSelectionGate()
let sg = stale.begin(op: "presence.motion", nowMillis: 1_000)
check(stale.reclaimIfStale(nowMillis: 20_999) == nil, "a marker inside its deadline is not stale")
if let cleared = stale.reclaimIfStale(nowMillis: 21_000) {
    check(cleared.op == "presence.motion", "the stale clear names the operation")
    check(cleared.ageMs == 20_000, "the stale clear names the age")
} else {
    check(false, "a marker past its deadline must be reclaimed")
}
check(stale.staleClearCount == 1, "one stale clear is counted")
check(stale.refusal(isWorking: false, hasPendingSelection: false) == nil, "the selection continues after reclaim")
check(stale.finish(generation: sg) == nil, "the reclaimed operation's completion is late")

// ⑥ Reads are never reclaimed and never counted as staleness.
var readStale = PresenceSelectionGate()
_ = readStale.begin(op: "presence.load", nowMillis: 0)
check(readStale.reclaimIfStale(nowMillis: 1_000_000) == nil, "reads are never reclaimed")
check(readStale.staleClearCount == 0, "a read is not a stale marker")

// ⑦ The busy diagnostic is the required shape, and the snapshot fields are the
//    marker's own identity.
var detail = PresenceSelectionGate()
_ = detail.begin(op: "presence.motion", nowMillis: 500)
check(detail.busyDetail(nowMillis: 900, isWorking: false, hasPendingSelection: true)
        == "busy=presence.motion ageMs=400 isWorking=false pending=true",
      "busy detail is busy=<op> ageMs=<n> isWorking=<b> pending=<b>")
check(detail.busyOperation == "presence.motion" && detail.busySinceMillis == 500, "snapshot busy fields")

// ⑧ The read slot is a distinct slot: finishing a read does not clear the
//    selection marker, and vice versa.
var slots = PresenceSelectionGate()
let rsl = slots.begin(op: "presence.catalog", nowMillis: 0)
let ssl = slots.begin(op: "presence.motion", nowMillis: 1)
check(slots.finish(generation: rsl) == .read, "the read finishes its own slot")
check(slots.finish(generation: ssl) == .operation, "the selection finishes its own slot")

if failures.isEmpty { print("PASS presence selection gate: reads exempt, marker bounded, generations honoured, no loosening") ; exit(0) }
for failure in failures { print("FAIL \(failure)") }
exit(1)
"""#

func compileAndRun(gateSource: String, tag: String) throws -> (status: Int32, output: String) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gmgn-presence-gate-\(tag)-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let gateFile = directory.appendingPathComponent("PresenceSelectionGate.swift")
    let mainFile = directory.appendingPathComponent("main.swift")
    let binary = directory.appendingPathComponent("harness")
    try gateSource.write(to: gateFile, atomically: true, encoding: .utf8)
    try driver.write(to: mainFile, atomically: true, encoding: .utf8)
    let compile = Process()
    compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
    compile.arguments = ["-j1", "-target", "arm64-apple-macos14.0",
                         gateFile.path, mainFile.path, "-o", binary.path]
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
// ① Pristine gate: the driver must pass.
// ---------------------------------------------------------------------------
let gatePath = "apps/macos/UnityHost/UnityPresenceSelectionGate.swift"
let pristineGate = try source(gatePath)
let pristine = try compileAndRun(gateSource: pristineGate, tag: "pristine")
guard pristine.status == 0, pristine.output.contains("PASS") else {
    for line in pristine.output.split(separator: "\n") { print("   · \(line)") }
    check(false, "① 生产 `PresenceSelectionGate.swift` 必须通过：读不拒绝选择 / 标记有上界 / 世代生效 / 不放宽串行化")
    print("FAIL presence selection gate has \(failures.count) failing checks")
    exit(1)
}
check(true, "① 生产 gate：读操作不拒绝选择、标记有上界、迟到完成不清新标记、串行化未放宽")

// ---------------------------------------------------------------------------
// ② Injection: changing each behaviour back to the old one must go red.
// ---------------------------------------------------------------------------
struct Mutation {
    let name: String
    let apply: (String) -> String?
}
let mutations: [Mutation] = [
    Mutation(name: "reads block selection again (`kind == .read` → the operation slot)") { text in
        guard text.contains("return .read") else { return nil }
        return text.replacingOccurrences(of: "return .read", with: "return .write")
    },
    Mutation(name: "marker has no upper bound (`defaultBudgetMillis` → UInt64.max)") { text in
        guard text.contains("static let defaultBudgetMillis: UInt64 = 20_000") else { return nil }
        return text.replacingOccurrences(of: "static let defaultBudgetMillis: UInt64 = 20_000",
                                         with: "static let defaultBudgetMillis: UInt64 = UInt64.max")
    },
    Mutation(name: "completion ignores its generation (`operation?.generation == generation` → `operation != nil`)") { text in
        guard text.contains("if operation?.generation == generation {") else { return nil }
        return text.replacingOccurrences(of: "if operation?.generation == generation {",
                                         with: "if operation != nil {")
    },
]
for mutation in mutations {
    guard let mutated = mutation.apply(pristineGate), mutated != pristineGate else {
        check(false, "② 注入锚点漂移：\(mutation.name)")
        continue
    }
    let result = try compileAndRun(gateSource: mutated, tag: "mutated")
    let wentRed = result.status != 0
    check(wentRed, "② 注入必须红：\(mutation.name)")
    if wentRed, let first = result.output.split(separator: "\n").first(where: { $0.hasPrefix("FAIL ") }) {
        print("      ↳ \(first)")
    }
}

// ---------------------------------------------------------------------------
// ③ Wiring: the gate is only a fix if the production sources use it.
// ---------------------------------------------------------------------------
let bridge = try source("apps/macos/UnityHost/UnityPresenceSettingsBridge.swift")
check(bridge.contains("gate.refusal(isWorking:"), "③ 桥的拒绝谓词委托给 gate（不再是裸 `operation/isWorking`）")
check(!bridge.contains("if operation != nil || model.isWorking { return \"presence_selection_busy\" }"),
      "③ 旧谓词 `operation != nil || model.isWorking` 已不存在")
check(bridge.contains("reclaimStaleSelectionMarker"), "③ 下一次选择会回收陈旧标记")
check(bridge.contains("PresenceSelectionGate.codeStaleCleared"), "③ 陈旧回收打具名码 presence_selection_stale_cleared")
check(bridge.contains("\"busyOperation\"") && bridge.contains("\"busySinceMillis\""),
      "③ 快照含非破坏性 busyOperation / busySinceMillis")
check(bridge.contains("run(\"presence.load\")") && bridge.contains("run(\"presence.catalog\", kind: .read)"),
      "③ 读操作走 gate 的 read 槽")
check(bridge.contains("rendererSelectionRevision") && bridge.contains("acceptsRendererReceipt"),
      "③ 回执身份来自 pending 的权威 revision")

let mediaHost = try source("apps/macos/UnityHost/UnityMediaHost.swift")
check(mediaHost.contains("presenceSettings.acceptsRendererReceipt(revision: revision)"),
      "③ 媒体宿主按 pending 判回执，不再按 `characterSelectionRevision` 相等")
check(mediaHost.contains("presenceSettings.rendererSelectionRevision"),
      "③ 发布给渲染器的身份是权威 revision（不随每次刷新前进）")
check(mediaHost.contains("presenceSettings.selectionRefusalDetail(for: id)"),
      "③ 拒绝的 detail 带 gate 诊断")

let model = try source("apps/macos/Sources/GMGNRadio/Settings/PresenceSettingsModel.swift")
if let runStart = model.range(of: "private func runSelection("),
   let runEnd = model.range(of: "\n    }", range: runStart.upperBound..<model.endIndex) {
    let body = String(model[runStart.lowerBound..<runEnd.upperBound])
    let deferIndex = body.range(of: "defer { self?.isWorking = false")
    let guardIndex = body.range(of: "guard let self else { return }")
    check(deferIndex != nil, "③ 模型 runSelection 的清理用 defer")
    check(guardIndex != nil, "③ 模型 runSelection 仍有 guard let self")
    if let deferIndex, let guardIndex {
        check(deferIndex.lowerBound < guardIndex.lowerBound, "③ 清理的 defer 装在 guard let self 之前")
    }
    check(body.contains("selectionStaleAfter") && body.contains("presence_selection_stale_cleared"),
          "③ 陈旧 selectionTask 被取消 + 具名日志")
} else {
    check(false, "③ 找不到 runSelection 函数体")
}

let client = try source("apps/macos/Sources/GMGNRadio/Presence/RustPresenceSelectionClient.swift")
check(client.contains("priorWaitMillis") && client.contains("awaitPrior"),
      "③ 权威调用的串行等待有上界（死请求不再卡死后续）")

// ---------------------------------------------------------------------------
// ④ The serial-wait bound, driven for real: extract the production `Serial`
//    actor from the client source and run it with a predecessor that never
//    returns. Pristine ⇒ the second call runs after the bound; the old
//    unbounded `await previous.value` ⇒ the driver must time out.
// ---------------------------------------------------------------------------
func extractActor(_ name: String, from text: String) -> String? {
    guard let start = text.range(of: "    private \(name) {") else { return nil }
    var depth = 0
    var index = start.lowerBound
    var opened = false
    while index < text.endIndex {
        switch text[index] {
        case "{": depth += 1; opened = true
        case "}":
            depth -= 1
            if opened && depth == 0 { return String(text[start.lowerBound...index]) }
        default: break
        }
        index = text.index(after: index)
    }
    return nil
}

let serialDriver = #"""
import Foundation
struct Snapshot: Equatable, Sendable { let revision: Int64 }

private let serial = Serial()
let hung = Task { () -> Snapshot in
    try await serial.run {
        try await Task.sleep(nanoseconds: 60_000_000_000)
        return Snapshot(revision: 1)
    }
}
try? await Task.sleep(nanoseconds: 200_000_000)
let started = Date()
let second = try await serial.run { Snapshot(revision: 2) }
let elapsed = Date().timeIntervalSince(started)
hung.cancel()
if second.revision != 2 { print("FAIL the call behind a hung predecessor never ran"); exit(1) }
if elapsed >= 8 { print("FAIL the call behind a hung predecessor waited \(elapsed)s"); exit(1) }
print("PASS serial prior-wait bounded: second call ran after \(String(format: "%.2f", elapsed))s behind a 60s predecessor")
exit(0)
"""#

func compileAndRunBounded(serialSource: String, tag: String, timeout: TimeInterval) throws -> (status: Int32, output: String, timedOut: Bool) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gmgn-presence-serial-\(tag)-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let mainFile = directory.appendingPathComponent("main.swift")
    let binary = directory.appendingPathComponent("harness")
    // The actor is extracted verbatim from production and placed in `main.swift`
    // (file-private visibility keeps it usable by the top-level driver).
    try (serialDriver + "\n" + serialSource + "\n").write(to: mainFile, atomically: true, encoding: .utf8)
    let compile = Process()
    compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
    compile.arguments = ["-j1", "-target", "arm64-apple-macos14.0", mainFile.path, "-o", binary.path]
    let compilePipe = Pipe()
    compile.standardOutput = compilePipe
    compile.standardError = compilePipe
    try compile.run()
    let compileData = compilePipe.fileHandleForReading.readDataToEndOfFile()
    compile.waitUntilExit()
    guard compile.terminationStatus == 0 else {
        return (compile.terminationStatus, "compile failed:\n" + String(decoding: compileData, as: UTF8.self), false)
    }
    let run = Process()
    run.executableURL = binary
    let pipe = Pipe()
    run.standardOutput = pipe
    run.standardError = pipe
    try run.run()
    let deadline = Date().addingTimeInterval(timeout)
    while run.isRunning && Date() < deadline { usleep(50_000) }
    if run.isRunning {
        run.terminate(); run.waitUntilExit()
        return (-99, "timed out after \(timeout)s (the predecessor was never abandoned)", true)
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    run.waitUntilExit()
    return (run.terminationStatus, String(decoding: data, as: UTF8.self), false)
}

if let serialSource = extractActor("actor Serial", from: client) {
    let bounded = try compileAndRunBounded(serialSource: serialSource, tag: "pristine", timeout: 15)
    check(bounded.status == 0 && bounded.output.contains("PASS"),
          "④ 生产 Serial：死请求不再卡死后续权威调用")
    if bounded.status != 0 { print("      ↳ \(bounded.output.split(separator: "\n").joined(separator: " | "))") }
    let unboundedAnchor = "if let previous { await Self.awaitPrior(previous, timeoutMillis: Self.priorWaitMillis) }"
    if serialSource.contains(unboundedAnchor) {
        let mutated = serialSource.replacingOccurrences(of: unboundedAnchor,
                                                        with: "if let previous { _ = try? await previous.value }")
        let unbounded = try compileAndRunBounded(serialSource: mutated, tag: "unbounded", timeout: 12)
        check(unbounded.timedOut,
              "④ 注入必须红：改回 `_ = try? await previous.value` 后，后续调用被死请求卡死")
        if unbounded.timedOut { print("      ↳ \(unbounded.output)") }
    } else {
        check(false, "④ 注入锚点漂移：找不到串行等待的加界点")
    }
} else {
    check(false, "④ 找不到生产 `Serial` actor")
}

// ---------------------------------------------------------------------------
// ⑤ The read-only discriminator: "no new presence_selection_requests row ⇒ the
//    host refused it". Also exercised against the real `.bak-*` DB copy.
// ---------------------------------------------------------------------------
// A click refused on the host returns before the bridge touches the authority,
// so taskd never records a request row. Unchanged count ⇒ host-side refusal.
func refusalWasHostSide(requestsBefore: Int, requestsAfter: Int) -> Bool { requestsAfter == requestsBefore }
check(refusalWasHostSide(requestsBefore: 100, requestsAfter: 100),
      "⑤ 判别法：请求行数不变 ⇒ 拒绝发生在宿主侧（点击没到 daemon）")
check(!refusalWasHostSide(requestsBefore: 100, requestsAfter: 101),
      "⑤ 判别法：出现新请求行 ⇒ 拒绝来自 daemon，不是宿主")

let taskService = NSHomeDirectory() + "/Library/Application Support/gmgn radio/TaskService"
let backups = (try? FileManager.default.contentsOfDirectory(atPath: taskService))?
    .filter { $0.hasPrefix("tasks.sqlite3.bak-") }.sorted() ?? []
if let newest = backups.last {
    let path = taskService + "/" + newest
    func sqlite(_ query: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        // Read-only URI + `?mode=ro`; the live `tasks.sqlite3` is never opened.
        process.arguments = ["-readonly", "file:\(path)?mode=ro", query]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let rows = sqlite("select count(*) from presence_selection_requests;"),
       let pending = sqlite("select count(*) from presence_selection where state like '%\"pendingPreference\":null%';") {
        print("   · 只读证据（\(newest)）：presence_selection_requests=\(rows) 行；pendingPreference=null 的 scope=\(pending)")
        print("     复现：sqlite3 -readonly \"file:\(path)?mode=ro\" \"select count(*) from presence_selection_requests;\"")
        print("     拒绝前后这个数不变 ⇒ 宿主拦下；变多 ⇒ daemon 拦下。全程只读 .bak 副本，不碰 tasks.sqlite3。")
    } else {
        print("   · 只读证据：无法查询 .bak 副本（sqlite3 不可用或表缺失），跳过计数")
    }
} else {
    print("   · 只读证据：未找到 tasks.sqlite3.bak-* 副本，跳过真实计数（判别法仍由上面两条断言覆盖）")
}

if failures.isEmpty {
    print("PASS presence selection gate harness: ① green, ② \(mutations.count) injected regressions red, ③ wiring + bounded serial wait, ④ discriminator covered")
    exit(0)
}
for failure in failures { print("FAIL \(failure)") }
print("FAIL presence selection gate harness has \(failures.count) failing checks")
exit(1)

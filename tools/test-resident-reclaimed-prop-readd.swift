// ---------------------------------------------------------------------------
// 「删掉之后重新入库」= 一次新的、合法的变更；而且面板上的「重试入库」不许撒谎。
//
// 真机缺陷（2026-10-02）：job `2F633C0F-A868-4442-AD2A-C73D2A1D04E1`（超大荧幕电视）
// 的 `stage = claimed`，权威 `world_records(domain='objects')` 里那一行 `tombstone = 1`
// （用户把那个方块电视删了），而权威 `worlds/state` 的 `layoutReceipts` 里
// `claimed.2F633C0F-…` **还在**。`WorldSimulation.applyPropLayout` 的旧回执判据是
//
//     if let receipt = state.layoutReceipts[requestID] {
//         guard receipt == command else { throw WorldPropLayoutError.requestConflict }
//         return                                     // ← 在任何写入之前
//     }
//
// 于是这件**永远补不进去**：内容一致时它静默空转（调用方还以为成功），内容不一致时
// （今天的推导与旧回执的字节不再相同 —— 尺寸意图 / 基础几何 / 朝向归一都会让同一件
// 东西的字节重算）它每次都 `throw .requestConflict`。这是"给用户一个做不到的承诺"。
//
// 这一份钉五件事，每条都带**注入负对照**（把缺陷注入回生产源码必须 FAIL）：
//
// 1. **删除后重新入库是合法的、能落地**（真机 jobID + 真墓碑 + 真回执，跑生产代码；
//    注入旧判据 ⇒ FAIL）；
// 2. **幂等**：同一轮重放不产生第二条、`layoutRevision` 只 +1、重放后状态逐位不变
//    （注入"回执永远不去重" ⇒ FAIL）；
// 3. **真正的重复（非墓碑、已完成）仍然去重**；
// 4. **删除语义不变**：墓碑 + 事实、不可恢复（注入"删除不写墓碑" ⇒ FAIL）；
// 5. **按钮不许撒谎**：结构上做不到的路径不出现该动作，判据与写入同源
//    （注入"无条件给按钮" ⇒ FAIL；注入"补做判据放行墓碑" ⇒ FAIL）。
//
// 注入的做法与仓里其它 harness 同一套：拿生产源码的副本做手术，编一份**独立**的
// 程序跑同一组断言 —— 只有让判据真的红，才算证明它抓得住这个缺陷。
// 注入点找不到 / 注入后仍然全绿，都算这个 harness 自己失败。
//
// 用法：swift tools/test-resident-reclaimed-prop-readd.swift
// ---------------------------------------------------------------------------
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let runtime = root.appendingPathComponent("apps/macos/Packages/WorldRuntime/Sources/WorldRuntime")
let simulationPath = runtime.appendingPathComponent("WorldSimulation.swift")
let appPath = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift")
let projectionPath = root.appendingPathComponent(
    "apps/macos/Sources/GMGNRadio/Presence/ResidentOwnershipProjection.swift")

func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
func fail(_ message: String) -> Never { print("FAIL: \(message)"); exit(1) }

let simulationSource = try read(simulationPath)
let appSource = try read(appPath)
let projectionSource = try read(projectionPath)

// 真机那三件的身份（jobID / objectID）——判据、断言与打印都读这三个常量，不散落字面量。
let televisionJobID = "2F633C0F-A868-4442-AD2A-C73D2A1D04E1"
let televisionObjectID = "wish-prop-2f633c0f-a868-4442-ad2a-c73d2a1d04e1"
let swordJobID = "4210DB95-9253-4CAF-83A3-3C45F090B099"
let swordObjectID = "wish-prop-4210db95-9253-4caf-83a3-3c45f090b099"
let lampJobID = "B8594EB9-AD6C-46D4-A754-99BE7F510042"
let lampObjectID = "wish-prop-b8594eb9-ad6c-46d4-a754-99be7f510042"

// ── 接线（纯文本）判据：判据**只有一处**，两个消费者读同一份 ────────────────────
// 回执去重必须问"那次变更今天还立不立"，而不是"这条 requestID 处理过"。
guard simulationSource.contains(
    "if let receipt = state.layoutReceipts[requestID], state.receiptIsStillInEffect(receipt) {") else {
    fail("回执去重没有问「那次变更今天还立不立」——`claimed.<jobID>` 又被读成永久的了")
}
guard simulationSource.contains("func receiptIsStillInEffect(_ command: WorldPropLayoutCommand) -> Bool") else {
    fail("找不到回执效力判据 `receiptIsStillInEffect`（它必须是唯一那一处）")
}
guard simulationSource.contains("func canRedoInventoryRegistration(objectID: String) -> Bool") else {
    fail("找不到「重试入库走得通吗」的判据 `canRedoInventoryRegistration`")
}
// 按钮那一侧：可用性读的是世界层那个函数，不是面板自己编的阶段判据。
guard appSource.contains(
    "for job in jobs where context.state.canRedoInventoryRegistration(objectID: job.objectID) {") else {
    fail("入库补做/「重试入库」那一轮没有读同源判据（放行条件与写入判据分家了）")
}
guard appSource.contains(
    "f.canRedoInventoryRegistration = context.state.canRedoInventoryRegistration(objectID: objectID)") else {
    fail("宿主没有把同源判据读成事实（面板就只能自己编一套）")
}
guard projectionSource.contains(
    "actions = facts.canRedoInventoryRegistration ? [.retryInventoryRegistration] : []") else {
    fail("「重试入库」按钮不是由同源判据摆出来的（做不到的动作会出现在列表里）")
}
for word in ["已删除", "不再补做入库"] where !projectionSource.contains(word) {
    fail("「已删除」那一行必须说得出来不再补做入库（沉默 = 用户以为等一会儿就有了），缺「\(word)」")
}

// ── 编译与运行 ──────────────────────────────────────────────────────────────
let temporary = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("reclaimed-prop-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }

@discardableResult
func run(_ binary: String, _ arguments: [String]) -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try? process.run()
    process.waitUntilExit()
    return (process.terminationStatus,
            String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
}

/// WorldRuntime 的模块搜索路径 + 目标文件**只有一处定义**（与仓里其它 harness 同一条纪律）。
func worldRuntimeFlags() -> [String] {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [root.appendingPathComponent("tools/world-runtime-harness-flags.sh").path]
    process.standardOutput = pipe
    try? process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(separator: "\n").map(String.init)
}
let flags = worldRuntimeFlags()
let modules = flags[1]
let build = URL(fileURLWithPath: modules).deletingLastPathComponent()
let allObjects = try FileManager.default
    .contentsOfDirectory(at: build.appendingPathComponent("WorldRuntime.build"),
                         includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "o" }
let objectsExcludingSimulation = allObjects
    .filter { $0.lastPathComponent != "WorldSimulation.swift.o" }.map(\.path)

/// 「把生产源码的一份**副本**拿去编」：拿它替掉 `WorldSimulation.swift.o` 再链接。
///
/// 之所以可行：`WorldSimulation.swift` 不被同模块的其它文件引用（判据也刻意住在那里，
/// 见文件头的说明），所以它可以在 harness 自己的模块里重编一次而不欠任何符号。
/// 副本必须补两处**只因为换了模块**才缺的东西（都与本次判据无关）：
/// `import WorldRuntime`（同名类型由模块提供），以及一个 `internal` 常量的字面量。
let usageMetadataKey = try { () -> String in
    let capability = try read(runtime.appendingPathComponent("PropCapability.swift"))
    guard let range = capability.range(of: "static let metadataKey = \"") else {
        fail("找不到 `WorldPropUsageState.metadataKey`（注入副本要用它的字面量）")
    }
    let rest = capability[range.upperBound...]
    guard let end = rest.firstIndex(of: "\"") else { fail("metadataKey 的字面量抽不出来") }
    return String(rest[rest.startIndex..<end])
}()

func simulationCopy(_ mutate: (String) throws -> String) throws -> String {
    var copy = simulationSource.replacingOccurrences(
        of: "import Foundation", with: "import Foundation\nimport WorldRuntime", options: [], range: nil)
    // 只影响"注入副本能编过"，与回执/墓碑判据无关；字面量逐字取自生产源码。
    copy = copy.replacingOccurrences(of: "WorldPropUsageState.metadataKey",
                                     with: "\"\(usageMetadataKey)\"")
    return try mutate(copy)
}

/// 编译并运行一份程序：模块目标文件（可替换其中一个）+ 生产源码副本 + 程序。
func buildAndRun(program: String, injection: String?, arguments: [String]) -> (Int32, String) {
    let binary = temporary.appendingPathComponent("bin-\(UUID().uuidString)")
    let programFile = temporary.appendingPathComponent("p-\(UUID().uuidString).swift")
    try? program.write(to: programFile, atomically: true, encoding: .utf8)
    var sources: [String] = []
    var objects = allObjects.map(\.path)
    if let injection {
        let copyFile = temporary.appendingPathComponent("s-\(UUID().uuidString).swift")
        try? injection.write(to: copyFile, atomically: true, encoding: .utf8)
        sources = [copyFile.path]
        objects = objectsExcludingSimulation
    }
    // 固定顺序（`objects` 按目录读出，顺序不保证）：同一份输入必须同一条命令行。
    objects.sort()
    let compiled = run("/usr/bin/swiftc", ["-j1", "-parse-as-library", "-I", modules]
        + sources + [programFile.path, "-o", binary.path] + objects)
    guard FileManager.default.fileExists(atPath: binary.path) else {
        return (127, "compile failed:\n" + compiled.1)
    }
    return run(binary.path, arguments)
}

// ── 真机数据：权威库（`world_records`）⇒ 一份 materialize 过的世界文档 ─────────
// `worlds/state` 那一份 blob **加上** `objects` 域里的每一条非墓碑物件 —— 与 Rust
// `world.rs` 的 `materialize()` 同一口径（`state.json` 是冻结的前像，不是现状）。
let authorityDatabase = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent("Library/Application Support/gmgn radio/TaskService/tasks.sqlite3")

func sqlite(_ sql: String) -> String? {
    guard FileManager.default.fileExists(atPath: authorityDatabase.path) else { return nil }
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = ["file:\(authorityDatabase.path)?mode=ro", sql]
    process.standardOutput = pipe
    process.standardError = Pipe()
    try? process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
}

var realWorldPath: String?
if let blob = sqlite("select value from world_records where domain='worlds' and key='state';"),
   let blobData = blob.data(using: .utf8),
   var document = (try? JSONSerialization.jsonObject(with: blobData)) as? [String: Any],
   let rows = sqlite("select key, value from world_records where domain='objects';") {
    var live: [String: Any] = [:]
    var records: [(objectID: String, tombstone: Bool, isEnabled: Bool)] = []
    // `select key, value` 用 `|` 分隔不可靠（JSON 里会有 `|`），所以按行首的 key 切。
    let tombstones = sqlite("select key, tombstone from world_records where domain='objects';") ?? ""
    var tombstoneFlags: [String: Bool] = [:]
    for line in tombstones.split(separator: "\n") {
        let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { continue }
        tombstoneFlags[String(parts[0])] = String(parts[1]).trimmingCharacters(in: .whitespaces) == "1"
    }
    for line in rows.split(separator: "\n") {
        let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { continue }
        let objectID = String(parts[0])
        guard tombstoneFlags[objectID] != true,
              let data = String(parts[1]).data(using: .utf8),
              let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
        live[objectID] = value
        records.append((objectID, false, value["isEnabled"] as? Bool ?? false))
    }
    document["objectStates"] = live
    if let data = try? JSONSerialization.data(withJSONObject: document) {
        let url = temporary.appendingPathComponent("real-world.json")
        try? data.write(to: url)
        realWorldPath = url.path
    }
    print("真机权威：world_records 物件行 \(tombstoneFlags.count) 条"
        + "（活 \(live.count) / 墓碑 \(tombstoneFlags.values.filter { $0 }.count)）；"
        + "materialize 出的 layoutRevision = \(document["layoutRevision"] ?? "?")")
    for record in records.sorted(by: { $0.objectID < $1.objectID }) where
        [televisionObjectID, swordObjectID, lampObjectID].contains(record.objectID) {
        print("  · \(record.objectID)：tombstone=\(tombstoneFlags[record.objectID] == true) isEnabled=\(record.isEnabled)")
    }
} else {
    print("SKIP: 这台机器上读不到权威库（\(authorityDatabase.path)），真机那一段没跑")
}

// ── 断言程序（同一份文本喂给"修好的"与每一份"注入过缺陷的"构建）────────────────
let driver = #"""
import Foundation
import WorldRuntime

/// 真机那三件的身份（与 harness 上层同一份字面量）。
let televisionJobID = "2F633C0F-A868-4442-AD2A-C73D2A1D04E1"
let televisionObjectID = "wish-prop-2f633c0f-a868-4442-ad2a-c73d2a1d04e1"
let swordJobID = "4210DB95-9253-4CAF-83A3-3C45F090B099"
let swordObjectID = "wish-prop-4210db95-9253-4caf-83a3-3c45f090b099"
let lampJobID = "B8594EB9-AD6C-46D4-A754-99BE7F510042"
let lampObjectID = "wish-prop-b8594eb9-ad6c-46d4-a754-99be7f510042"

@main struct ReclaimedPropReadd {
    static var failures: [String] = []
    static func check(_ ok: Bool, _ message: String) { if !ok { failures.append(message) } }

    static func base(worldID: String = "room") -> WorldState {
        WorldState(revision: 0, worldID: worldID,
                   worldTime: Date(timeIntervalSince1970: 0),
                   lastObservedWallTime: Date(timeIntervalSince1970: 0),
                   weather: .clear,
                   agentTransform: WorldTransform(
                       position: WorldVector3(x: 0, y: 0, z: 0),
                       rotation: WorldQuaternion(x: 0, y: 0, z: 0, w: 1),
                       scale: WorldVector3(x: 1, y: 1, z: 1)))
    }

    /// 走遍保留窗口数「这一件的删除事实」有几条（不是"有没有"：
    /// 第二次删除必须**自己**留一条，不能靠第一次留下的那条冒充）。
    static func deletedEvents(_ events: [WorldEvent], _ objectID: String) -> Int {
        events.reduce(into: 0) { count, event in
            if case let .propDeleted(id, _, _, _, _) = event.kind, id == objectID { count += 1 }
        }
    }

    static func main() {
        // ── 合成 fixture：入库 → 真正的重复 → 删除 → 重新入库 → 重放 ──────────
        let requestID = "claimed." + televisionJobID
        let prop = WorldGeneratedProp(
            objectID: televisionObjectID, sourceWishID: televisionJobID,
            assetID: "sha256:" + String(repeating: "a", count: 64),
            displayName: "超大荧幕电视",
            size: WorldVector3(x: 1.4429951, y: 0.90049934, z: 1.443), sourceHeight: 0.6289793,
            sizeIntent: WorldPropSizeIntent(axis: .longest, meters: 1.443, source: .user))
        var sim = WorldSimulation(restoring: base())

        // (1) 第一次入库
        do { try sim.applyPropLayout(.register(prop), expectedLayoutRevision: 0, requestID: requestID) }
        catch { check(false, "第一次入库就不该失败：\(error)") }
        check(sim.state.layoutRevision == 1, "入库后 layoutRevision 必须是 1，实测 \(sim.state.layoutRevision)")
        check(sim.state.objectStates[televisionObjectID] != nil, "入库必须落下库存记录")
        check(sim.state.receiptIsStillInEffect(.register(prop)),
              "入库完成之后，那条回执必须**还在生效**（否则重放会写第二条）")
        check(sim.state.canRedoInventoryRegistration(objectID: televisionObjectID) == false,
              "已经在库存里 ⇒ 「重试入库」不可用（那是空转，不是补做）")

        // (2) 真正的重复（非墓碑、已完成）：仍然去重。
        //     期望版本**故意给旧值** —— 回执去重在版本检查之前，重放不许被重判。
        let afterFirst = sim.state
        do { try sim.applyPropLayout(.register(prop), expectedLayoutRevision: 0, requestID: requestID) }
        catch { check(false, "同一轮重放不许报错（回执去重在版本检查之前）：\(error)") }
        check(sim.state == afterFirst, "重放不许写第二条记录（状态必须逐位不变）")
        check(sim.state.layoutRevision == 1, "重放不许涨 layoutRevision，实测 \(sim.state.layoutRevision)")
        //     同一条 requestID 换了内容、而那次变更**还在生效** ⇒ 请求冲突（具名，不静默）
        let impostor = WorldGeneratedProp(
            objectID: televisionObjectID, sourceWishID: televisionJobID,
            assetID: "sha256:" + String(repeating: "b", count: 64),
            displayName: "超大荧幕电视",
            size: WorldVector3(x: 1.4429951, y: 0.90049934, z: 1.443), sourceHeight: 0.6289793)
        do {
            try sim.applyPropLayout(.register(impostor),
                                    expectedLayoutRevision: sim.state.layoutRevision, requestID: requestID)
            check(false, "同一条 requestID 换了内容、而那次变更还在生效 ⇒ 必须请求冲突")
        } catch let error as WorldPropLayoutError {
            check(error == .requestConflict, "期望 requestConflict，实测 \(error)")
        } catch { check(false, "期望 requestConflict，实测 \(error)") }

        // (3) 用户**有意删掉**这一件（真机就是这样）
        do {
            try sim.applyPropLayout(.delete(objectID: televisionObjectID, reason: "用户把那个方块电视删掉了"),
                                    expectedLayoutRevision: sim.state.layoutRevision, requestID: "delete.2F633C0F")
        } catch { check(false, "删除不该失败：\(error)") }
        check(sim.state.objectStates[televisionObjectID] == nil, "删除必须把物件移出 objectStates")
        check(sim.state.propTombstones?[televisionObjectID]?.previous == prop,
              "删除必须留下身份逐位匹配的墓碑（身份冻结，不是硬删行）")
        check(deletedEvents(sim.events, televisionObjectID) == 1,
              "删除必须在事件日志里留下**一条**具名事实 propDeleted，实测 \(deletedEvents(sim.events, televisionObjectID))")
        check(sim.state.layoutUndo == nil, "删除必须作废指向它的撤销槽（undo 不能把删掉的东西复活）")
        check(sim.state.canRedoInventoryRegistration(objectID: televisionObjectID) == false,
              "删掉的那一件：「重试入库」必须判为不可行 —— 补做与按钮走同一条重入路径，"
              + "放开它就等于用户每删一件、下一个同步周期它自己长回来")
        check(sim.state.receiptIsStillInEffect(.register(prop)) == false,
              "物件已经被删 ⇒ 入库那一笔的效力已经不在了（旧回执不再去重）")
        //     删除自己也要幂等：同一 requestID 重放不写第二遍
        let deletedFactCount = deletedEvents(sim.events, televisionObjectID)
        let afterDelete = sim.state
        do {
            try sim.applyPropLayout(.delete(objectID: televisionObjectID, reason: "用户把那个方块电视删掉了"),
                                    expectedLayoutRevision: 0, requestID: "delete.2F633C0F")
        } catch { check(false, "删除重放不许报错：\(error)") }
        check(sim.state == afterDelete, "删除重放不许写第二条")
        check(deletedEvents(sim.events, televisionObjectID) == deletedFactCount, "删除重放不许留下第二条删除事实")

        // (4) **删除之后重新入库**：这是一次新的、合法的变更 —— 旧回执不许把它挡死。
        //     内容按**今天的推导**（原尺寸锁定 ⇒ 与旧回执逐位不同）提交。
        let today = prop.withSize(prop.size)
        check(today != prop, "（前提）今天的推导与旧回执的字节不同（尺寸锁定/基础几何/朝向归一都会重算）")
        check(today.matchesIdentity(of: prop), "（前提）换的只是派生字段，身份逐位不变")
        let beforeRedo = sim.state
        do {
            try sim.applyPropLayout(.register(today),
                                    expectedLayoutRevision: beforeRedo.layoutRevision, requestID: requestID)
        } catch {
            check(false, "删除之后重新入库必须能落地（旧回执不许把它挡死），实测 \(error)")
        }
        check(sim.state.layoutRevision == beforeRedo.layoutRevision + 1,
              "重新入库：layoutRevision 只 +1，实测 \(beforeRedo.layoutRevision) → \(sim.state.layoutRevision)")
        check(sim.state.objectStates[televisionObjectID] != nil, "重新入库必须落下库存记录")
        check(sim.state.objectStates.count == beforeRedo.objectStates.count + 1,
              "重新入库只多**一条**库存记录（实测 \(beforeRedo.objectStates.count) → \(sim.state.objectStates.count)）")
        check(sim.state.objectStates.values.filter { $0.generatedProp?.sourceWishID == televisionJobID }.count == 1,
              "objectStates 里这一件许愿**恰好一条**")
        check(sim.state.propTombstones?[televisionObjectID] != nil,
              "删除是永久的：重新入库**不许**擦掉墓碑（那条事实留着才对得上权威的 object.removed）")
        check(sim.state.receiptIsStillInEffect(.register(today)),
              "重新入库成功之后，回执必须重新生效（否则这一轮的重放会写第二条）")

        // (5) 幂等：同一轮重放不产生第二条、layoutRevision 只 +1、状态逐位不变
        let afterRedo = sim.state
        do {
            try sim.applyPropLayout(.register(today),
                                    expectedLayoutRevision: beforeRedo.layoutRevision, requestID: requestID)
        } catch { check(false, "重新入库之后的重放不许报错：\(error)") }
        check(sim.state == afterRedo, "重放后状态必须逐位不变")
        check(sim.state.layoutRevision == beforeRedo.layoutRevision + 1,
              "重放不许再涨 layoutRevision，实测 \(sim.state.layoutRevision)")
        check(sim.state.objectStates.count == beforeRedo.objectStates.count + 1,
              "重放不许产生第二条库存记录")

        // (6) 删除语义不变：再删一次仍然成立；删过的再删是**具名失败**；undo 不能恢复
        do {
            try sim.applyPropLayout(.delete(objectID: televisionObjectID, reason: nil),
                                    expectedLayoutRevision: sim.state.layoutRevision, requestID: "delete.2F633C0F.again")
        } catch { check(false, "重新入库之后的那一件必须照旧删得掉：\(error)") }
        check(sim.state.objectStates[televisionObjectID] == nil, "第二次删除必须把它移出 objectStates")
        check(sim.state.propTombstones?[televisionObjectID] != nil, "第二次删除必须留下墓碑")
        check(deletedEvents(sim.events, televisionObjectID) == 2,
              "第二次删除必须**自己**再留一条具名事实（实测 \(deletedEvents(sim.events, televisionObjectID))）")
        do {
            try sim.applyPropLayout(.delete(objectID: televisionObjectID, reason: nil),
                                    expectedLayoutRevision: sim.state.layoutRevision, requestID: "delete.2F633C0F.third")
            check(false, "已经在墓碑里的那一件再删一次必须**具名失败**（不许静默成功）")
        } catch let error as WorldPropLayoutError {
            check(error == .objectAlreadyDeleted(objectID: televisionObjectID),
                  "期望 objectAlreadyDeleted，实测 \(error)")
        } catch { check(false, "期望 objectAlreadyDeleted，实测 \(error)") }
        do {
            try sim.applyPropLayout(.undo, expectedLayoutRevision: sim.state.layoutRevision, requestID: "undo.1")
            check(false, "undo 不许把删掉的东西复活")
        } catch let error as WorldPropLayoutError {
            check(error == .nothingToUndo, "删除之后撤销槽必须是空的，实测 \(error)")
        } catch { check(false, "期望 nothingToUndo，实测 \(error)") }

        // ── 真机那 3 件（真 jobID + 真权威记录 + 真回执）─────────────────────
        if CommandLine.arguments.count > 1 {
            realData(path: CommandLine.arguments[1])
        } else {
            print("SKIP(real): 没有权威文档可读")
        }

        for failure in failures { print("FAIL: " + failure) }
        print(failures.isEmpty ? "PASS: 删除后重新入库能落地、幂等、真重复仍去重、删除语义不变、按钮不撒谎"
                               : "FAILED: \(failures.count) 条")
        exit(failures.isEmpty ? 0 : 1)
    }

    /// 真机：`2F633C0F`（墓碑 + 回执，这一件**永远补不进去**的那件）、
    /// `4210DB95` / `B8594EB9`（权威里活着，用来钉"真正的重复仍然去重"）。
    static func realData(path: String) {
        guard let data = FileManager.default.contents(atPath: path) else {
            check(false, "真机权威文档读不到：\(path)"); return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let state = try? decoder.decode(WorldState.self, from: data) else {
            check(false, "真机权威文档解不成 WorldState（形状变了）"); return
        }
        let requestID = "claimed." + televisionJobID
        print("── 真机：layoutRevision = \(state.layoutRevision)｜objectStates = \(state.objectStates.count)"
            + "｜墓碑 = \(state.propTombstones?.count ?? 0)｜回执 = \(state.layoutReceipts.count) ──")
        guard let receipt = state.layoutReceipts[requestID], case let .register(receiptProp) = receipt else {
            check(false, "真机权威里没有 \(requestID) 的入库回执（那这一条就不是「回执挡死」的形状了）")
            return
        }
        print("  回执 \(requestID)：sizeIntent=\(receiptProp.sizeIntent?.summary ?? "无")"
            + "｜size=(\(receiptProp.size.x), \(receiptProp.size.y), \(receiptProp.size.z))"
            + "｜sourceHeight=\(receiptProp.sourceHeight)")
        check(state.propTombstones?[televisionObjectID] != nil,
              "真机权威里 \(televisionObjectID) 必须有墓碑（用户把那个方块电视删了）")
        check(state.objectStates[televisionObjectID] == nil, "真机权威里这一件必须已经不在库存记录里")
        check(state.canRedoInventoryRegistration(objectID: televisionObjectID) == false,
              "真机：删掉的那一件，「重试入库」必须判为不可行（删除永久）")
        check(state.receiptIsStillInEffect(receipt) == false,
              "真机：物件已被删 ⇒ 那条入库回执的效力已经不在了（旧判据正是拿它挡死写入的）")
        // 同族那两件：权威里活着 ⇒ 回执照旧生效、真正的重复照旧去重。
        for (name, jobID, objectID) in [("2B 白色长剑", swordJobID, swordObjectID),
                                        ("暖光落地灯", lampJobID, lampObjectID)] {
            let key = "claimed." + jobID
            guard let other = state.layoutReceipts[key] else {
                check(false, "真机权威里 \(name) 的入库回执不见了（\(key)）"); continue
            }
            check(state.objectStates[objectID] != nil, "真机权威里 \(name) 必须在库存记录里（活着的）")
            check(state.receiptIsStillInEffect(other),
                  "真机：\(name) 还在库存里 ⇒ 那条回执必须照旧生效（真正的重复仍然去重）")
            check(state.canRedoInventoryRegistration(objectID: objectID) == false,
                  "真机：\(name) 已经在库存里 ⇒ 「重试入库」不可用")
            print("  · \(name)：在库存记录里（isEnabled=\(state.objectStates[objectID]?.isEnabled == true)）"
                + "，回执仍生效 ⇒ 不补做")
        }
        // 端到端：把真机状态装进生产 `WorldSimulation`，用真 jobID 的幂等键补做一次。
        var sim = WorldSimulation(restoring: state)
        let today = receiptProp.withSize(receiptProp.size)
        check(today != receiptProp, "（前提）真机那条回执的字节与今天的推导不同")
        let before = sim.state.layoutRevision
        do {
            try sim.applyPropLayout(.register(today), expectedLayoutRevision: before, requestID: requestID)
        } catch {
            check(false, "真机 2F633C0F 的补做入库必须能落地，实测 \(error)")
        }
        check(sim.state.layoutRevision == before + 1,
              "真机补做：layoutRevision 只 +1（\(before) → \(sim.state.layoutRevision)）")
        check(sim.state.objectStates[televisionObjectID] != nil, "真机补做必须落下库存记录")
        check(sim.state.objectStates.values.filter { $0.generatedProp?.sourceWishID == televisionJobID }.count == 1,
              "真机补做：objectStates 里恰好一条")
        check(sim.state.propTombstones?[televisionObjectID] != nil, "真机补做不许擦掉墓碑")
        let after = sim.state
        do {
            try sim.applyPropLayout(.register(today), expectedLayoutRevision: before, requestID: requestID)
        } catch { check(false, "真机补做的重放不许报错：\(error)") }
        check(sim.state == after, "真机补做的重放必须逐位不变")
        check(sim.state.layoutRevision == before + 1, "真机补做的重放不许再涨 layoutRevision")
        check(sim.state.objectStates.count == after.objectStates.count, "真机补做的重放不许写第二条")
        print("PASS[real]: 真机 \(televisionJobID) 补做入库落地 —— layoutRevision \(before) → \(sim.state.layoutRevision)"
            + "、objectStates 里恰好一条、重放逐位不变；同族两件（活着的）照旧不补做")
    }
}
"""#

// ── 固定构建（生产代码原样）──────────────────────────────────────────────────
let realArguments = realWorldPath.map { [$0] } ?? []
let fixed = buildAndRun(program: driver, injection: nil, arguments: realArguments)
print(fixed.1.trimmingCharacters(in: .whitespacesAndNewlines))
guard fixed.0 == 0 else { fail("生产代码没通过这一组判据（上面的 FAIL 就是缺陷本身）") }

// ── 注入负对照：把缺陷注入回生产源码的一份副本，判据必须**真的红** ─────────────
/// 注入点找不到、或注入后仍然全绿 ⇒ 这个 harness 自己失败（一条抓不到缺陷的判据
/// 等于没有判据）。
func expectFailure(_ name: String, anchor: String, replacement: String) {
    guard simulationSource.contains(anchor) else {
        fail("负对照「\(name)」的注入点找不到（注入本身失效）")
    }
    let mutated = try? simulationCopy { copy in
        let next = copy.replacingOccurrences(of: anchor, with: replacement)
        guard next != copy else { throw NSError(domain: "injection", code: 1) }
        return next
    }
    guard let mutated, mutated != simulationSource else {
        fail("负对照「\(name)」注入没有改变源码")
    }
    let result = buildAndRun(program: driver, injection: mutated, arguments: realArguments)
    guard result.0 != 0 else {
        fail("负对照「\(name)」注入回去之后判据竟然还是绿的 —— 这个判据抓不到该缺陷")
    }
    let line = result.1.split(separator: "\n").first(where: { $0.hasPrefix("FAIL") })
        .map(String.init) ?? "(无 FAIL 行：\(result.1.suffix(200)))"
    print("PASS[negative-\(name)]: 注入 ⇒ FAIL：\(line)")
}

// 1) 旧判据：回执存在就在**任何写入之前** return（真机缺陷的原形）。
expectFailure(
    "legacy-receipt-blocks-readd",
    anchor: [
        "        if let receipt = state.layoutReceipts[requestID], state.receiptIsStillInEffect(receipt) {",
        "            guard receipt == command else { throw WorldPropLayoutError.requestConflict }",
        "            return",
        "        }",
    ].joined(separator: "\n"),
    replacement: [
        "        if let receipt = state.layoutReceipts[requestID] {",
        "            guard receipt == command else { throw WorldPropLayoutError.requestConflict }",
        "            return",
        "        }",
    ].joined(separator: "\n"))

// 2) 回执永远不去重（无条件放行）：真重复会写第二条 / 重放会被重判成版本过期。
expectFailure(
    "receipt-never-dedupes",
    anchor: "            return objectStates[prop.objectID] != nil",
    replacement: "            return false")

// 3) 删除不写墓碑：删除语义被偷偷改成硬删。
expectFailure(
    "delete-skips-tombstone",
    anchor: "            tombstones[id] = tombstone",
    replacement: "            _ = tombstone")

// 4) 「重试入库」判据放行墓碑：用户删掉的东西会被自动补做复活。
expectFailure(
    "redo-ignores-tombstone",
    anchor: "        objectStates[objectID] == nil && propTombstones?[objectID] == nil",
    replacement: "        objectStates[objectID] == nil")

// ── 投影那一侧：「按钮不许撒谎」必须能实测抓住 ────────────────────────────────
/// 投影 + 一小段程序，编译运行两次（原样 / 注入）。与仓里其它 harness 同一套做法。
func runProjection(_ projection: String, _ program: String) -> (Int32, String) {
    let binary = temporary.appendingPathComponent("proj-\(UUID().uuidString)")
    let file = binary.appendingPathExtension("swift")
    let text = "import Foundation\n\(projection)\n\(program)"
    try? text.write(to: file, atomically: true, encoding: .utf8)
    _ = run("/usr/bin/swiftc", ["-j1", "-parse-as-library", "-swift-version", "6", file.path, "-o", binary.path])
    guard FileManager.default.fileExists(atPath: binary.path) else { return (127, "compile failed") }
    return run(binary.path, [])
}

let buttonProgram = #"""
@main struct Harness {
    static func main() {
        var failures: [String] = []
        func check(_ ok: Bool, _ message: String) { if !ok { failures.append(message) } }
        // 「已领取、还没写进库存、而且不是墓碑」：这一行的按钮只能来自同源判据。
        var row = OwnershipRowFacts(objectID: "wish-prop-2f633c0f-a868-4442-ad2a-c73d2a1d04e1")
        row.jobID = UUID(uuidString: "2F633C0F-A868-4442-AD2A-C73D2A1D04E1")
        row.jobName = "超大荧幕电视"
        row.jobStage = .claimed
        row.claimReceiptPresent = true
        let impossible = ResidentOwnershipProjection.row(row)
        check(impossible.actions.isEmpty,
              "判据说这条补做走不通时，列表里不许出现「重试入库」（那是一句做不到的承诺），实测 \(impossible.actions)")
        check(!impossible.actions.contains(.retryInventoryRegistration),
              "判据说走不通却有「重试入库」")
        row.canRedoInventoryRegistration = true
        let possible = ResidentOwnershipProjection.row(row)
        check(possible.actions == [.retryInventoryRegistration],
              "判据说走得通时必须给得出「重试入库」，实测 \(possible.actions)")
        // 墓碑那一行（用户有意删掉）：不给动作，而且要说清楚不再补做。
        var deleted = OwnershipRowFacts(objectID: "wish-prop-2f633c0f-a868-4442-ad2a-c73d2a1d04e1")
        deleted.jobID = UUID(uuidString: "2F633C0F-A868-4442-AD2A-C73D2A1D04E1")
        deleted.jobName = "超大荧幕电视"
        deleted.jobStage = .claimed
        deleted.tombstoneName = "超大荧幕电视"
        let tombstoned = ResidentOwnershipProjection.row(deleted)
        check(tombstoned.actions.isEmpty, "删除过的行不许给动作，实测 \(tombstoned.actions)")
        check(tombstoned.reasonText?.contains("不再补做入库") == true,
              "删除过的那一行必须说得出「不再补做入库」，实测 \(tombstoned.reasonText ?? "nil")")
        for failure in failures { print("FAIL: " + failure) }
        exit(failures.isEmpty ? 0 : 1)
    }
}
"""#
let projectionFixed = runProjection(projectionSource, buttonProgram)
guard projectionFixed.0 == 0 else {
    print(projectionFixed.1.trimmingCharacters(in: .whitespacesAndNewlines))
    fail("「重试入库」的可用性不是由同源判据摆出来的")
}
print("PASS[button]: 「重试入库」只在同源判据说走得通时出现；删除过的那一行不给动作并说清「不再补做入库」")

let buttonAnchor = "actions = facts.canRedoInventoryRegistration ? [.retryInventoryRegistration] : []"
guard projectionSource.contains(buttonAnchor) else { fail("按钮负对照的注入点找不到") }
let buttonInjected = projectionSource.replacingOccurrences(
    of: buttonAnchor, with: "actions = [.retryInventoryRegistration]")
guard buttonInjected != projectionSource else { fail("按钮负对照注入没有改变源码") }
let projectionInjected = runProjection(buttonInjected, buttonProgram)
guard projectionInjected.0 != 0 else {
    fail("负对照「无条件给按钮」注入后竟然还是绿的 —— 这个判据抓不到「做不到却给动作」")
}
let buttonLine = projectionInjected.1.split(separator: "\n").first(where: { $0.hasPrefix("FAIL") })
    .map(String.init) ?? "(无 FAIL 行)"
print("PASS[negative-unconditional-retry-button]: 注入 ⇒ FAIL：\(buttonLine)")

// ── 宿主接线那一侧的负对照：补做循环退回"按 objectStates 空不空"──── ──────────
let guardAnchor = "for job in jobs where context.state.canRedoInventoryRegistration(objectID: job.objectID) {"
let guardInjected = appSource.replacingOccurrences(
    of: guardAnchor, with: "for job in jobs where context.state.objectStates[job.objectID] == nil {")
guard guardInjected != appSource else { fail("宿主接线负对照的注入点找不到") }
guard !guardInjected.contains("canRedoInventoryRegistration(objectID: job.objectID)") else {
    fail("宿主接线负对照注入后判据还在")
}
print("PASS[negative-app-loop-guard]: 注入（补做循环退回按 objectStates 空不空判）⇒ "
    + "同源判据的接线断言失败：入库补做/「重试入库」那一轮没有读同源判据")

print("")
print("PASS: 「删掉之后重新入库」—— 真机 2F633C0F 端到端可落地、幂等、真重复仍去重、删除语义不变、按钮不撒谎（全部含注入负对照）")

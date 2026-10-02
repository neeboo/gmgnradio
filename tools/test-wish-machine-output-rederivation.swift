// 「等待入库，但托盘上什么都没有，也领不了」——**派生结论必须能从权威重新推导**。
//
// 真机现场（2026-10-02，HEAD 074ebd2）：job `0C285296-9164-4A2B-8FB7-6648E549A4AE`
// （`stage == .ready`、`sizeIntent {mode:dimensions, mm:{1443,862,302}}`、资产 3,251,732 B 完好），
// events 里留着**修复前**那次推导的结论
//   `{"kind":"failed","stage":"ready","failureSource":"renderer","message":"…尺寸无效…"}`
// —— 托盘/领取原来读的就是它（`outputRenderFailure`），于是"推导逻辑被修好"这件事
// **永远不会被重新推导**：那台电视**永久**从托盘上消失、也永远领不了（用户撞了两次）。
//
// 这个 harness 钉四条，每条都对应一种"悄悄变坏"的方式：
//
//   A1 陈旧失败在**重新推导成功**后必须消失（托盘可见 + 可领取）；
//      注入"永久信记录"（HEAD 那套 `failedIDs` 减件）⇒ 必须 FAIL。
//   A2 真失败不许被清掉：重新推导**仍失败**时保留，而且带**字段与数值**；
//      注入"无条件清"⇒ 必须 FAIL。
//   A3 任务行与托盘永远说同一件事：产物就绪那一档说**唯一投影**那一句「未领取」
//      （2026-10-02 收口；旧那套自造的「可领取」已退役），托盘上还没有它时改说同一句
//      具名原因（`hostSentenceWins`）；
//      注入"两者分叉"⇒ 必须 FAIL。
//   A4 可领取 ⇒ 入库：三轴尺寸 → **基础几何**平面电视，`layoutRevision` 只 +1、幂等；
//      注入"旧行为"（拿生成网格，不拼基础几何）⇒ 必须 FAIL。
//
// 判据分两层，缺一不可：
//   * **源码级**（唯一一份 predicate，跑在内存副本上，注入负对照直接改副本再问一次）；
//   * **行为级**（编**真** `WishMachineOutputReachability` / `WishMachineTaskPresentation` /
//     `WishMachineCoordinator` / `WorldSimulation`，真的跑一遍，不看文本猜）。
// 注入只改内存里的字符串，**一个字节都不写盘**：跑完逐文件校验 sha256 与注入前一致。
import Foundation
import CryptoKit

// WorldRuntime 的模块搜索路径与目标文件**只有一处定义**：tools/world-runtime-harness-flags.sh。
func worldRuntimeHarnessFlags() -> [String] {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [FileManager.default.currentDirectoryPath + "/tools/world-runtime-harness-flags.sh"]
    process.standardOutput = pipe
    try? process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(separator: "\n").map(String.init)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourcesDir = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
let descriptorPath = "Presence/WishMachineOutputDescriptor.swift"
let presentationPath = "Presence/WishMachineTaskPresentation.swift"
let coordinatorPath = "Presence/WishMachineCoordinator.swift"
let appPath = "App/GMGNRadioApp.swift"
let watched = [descriptorPath, presentationPath, coordinatorPath, appPath]

func readSource(_ relative: String) -> String {
    guard let text = try? String(contentsOf: sourcesDir.appendingPathComponent(relative), encoding: .utf8) else {
        print("FAIL: 读不到 \(relative)"); exit(1)
    }
    return text
}
func sha256(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// 抽出一个顶层声明（按大括号配对），于是判据跑在**真源码文本**上，不是抄一份。
func declaration(_ signature: String, in text: String) -> String? {
    guard let start = text.range(of: signature)?.lowerBound,
          let open = text[start...].firstIndex(of: "{") else { return nil }
    var depth = 0
    for index in text[open...].indices {
        if text[index] == "{" { depth += 1 }
        if text[index] == "}" { depth -= 1 }
        if depth == 0 { return String(text[start...index]) }
    }
    return nil
}

/// 去掉整行注释后再看"代码里有没有那个词"。
///
/// 为什么必须有它：判据里有一条是"**代码**里不许再出现 HEAD 那套 `failedIDs` 减件"，
/// 而本次修复的注释里**故意**引用了那套旧写法（说明它为什么被删掉）。不剥注释，
/// 判据就会被自己的说明文字打红 —— 一条连注释都分不清的门禁等于没有门禁。
func code(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
        guard let marker = line.range(of: "//") else { return String(line) }
        return String(line[line.startIndex..<marker.lowerBound])
    }.joined(separator: "\n")
}

// MARK: - 唯一一份源码级判据（空 = 全绿）

func rederivationProblems(descriptor: String, presentation: String,
                          coordinator: String, app: String) -> [String] {
    var problems: [String] = []
    func require(_ value: Bool, _ message: String) { if !value { problems.append(message) } }

    guard let syncBody = declaration("private func synchronizeWishMachinePresentation()", in: app),
          let task = declaration("private func wishMachineTaskPresentation(for job: WishMachineJob)", in: app),
          let evidence = declaration("private func wishMachineClaimEvidence(for job: WishMachineJob)", in: app) else {
        return ["找不到 synchronizeWishMachinePresentation / wishMachineTaskPresentation / wishMachineClaimEvidence"]
    }
    let sync = code(syncBody)

    // ── A1：判据只能有一条，而且读的是**现场推导** ─────────────────────────────
    require(descriptor.contains("enum WishMachineOutputReachability"),
            "A1: 唯一判据 WishMachineOutputReachability 不见了")
    require(descriptor.contains("static func resolve(isTrayHolder: Bool, live: WishMachineOutputStatus"),
            "A1: 判据没有共同的 resolve（托盘/任务行/领取会各判各的）")
    require(descriptor.contains("case .ready(let id) where id == objectID: return .claimable"),
            "A1: 现场推导成功不再算可领取")
    require(descriptor.contains("return .deriving(reason: recordedFailure)"),
            "A1: 记录开始当权威（没有现场结论时不是 deriving）")
    require(sync.contains("objectIDs.contains($0.id)"),
            "A1: 托盘不再直接由 job 事实（stage/modelPath/意图）派生")
    require(!sync.contains("failedIDs"),
            "A1: 托盘又在按持久化的 outputRenderFailure 减件（陈旧结论当权威 ⇒ 修好也永不重新推导）")
    require(!sync.contains("subtracting("),
            "A1: 托盘仍在做 identities 减法")
    require(sync.contains("case .ready(let id) where id == job.objectID:"),
            "A1: 清失败没有绑在「现场推导成功」那一档上")
    require(sync.contains("let pool = healthy.isEmpty ? ready : healthy"),
            "A1: 现场失败的产物被直接清出托盘 ⇒ 渲染端会被推进「装载→失败→清空→再装载」的循环")
    require(sync.contains("clearOutputRenderFailure("),
            "A1: 现场推导成功后没有清掉那条陈旧失败（托盘/领取会永久停在旧结论上）")
    require(evidence.contains("WishMachineOutputReachability.resolve(") && evidence.contains(".isClaimable"),
            "A1: 领取依据没有读那**唯一**一份判据（会出现「行说可领取、手却领不了」）")

    // ── A2：真失败不许被清掉，而且必须具名（字段 + 数值） ───────────────────────
    if let clear = sync.range(of: "clearOutputRenderFailure(")?.lowerBound,
       let ready = sync.range(of: "case .ready(let id) where id == job.objectID:")?.lowerBound {
        require(ready < clear, "A2: 清失败跑在「现场推导成功」之前 ⇒ 等于无条件清，真失败会被抹掉")
    }
    if let clear = sync.range(of: "clearOutputRenderFailure(")?.lowerBound,
       let failed = sync.range(of: "case .failed(let id, let message) where id == job.objectID:")?.lowerBound {
        require(clear < failed, "A2: 清失败与「现场推导失败」那一档的次序反了")
    }
    require(sync.contains("case .failed(let id, let message) where id == job.objectID:"),
            "A2: 现场推导失败不再被记录（真失败会静默消失）")
    require(sync.contains("recordOutputRenderFailure("),
            "A2: 现场推导失败没有写回记录")
    require(coordinator.contains("func clearOutputRenderFailure("),
            "A2: 没有可幂等清除的记录入口")
    require(coordinator.contains("events.removeAll"),
            "A2: 清除不是幂等的删除（没有 removeAll）")
    require(coordinator.contains("events[index].message = text"),
            "A2: 重新推导失败时记录没有被**替换**（旧那句没有字段/数值的文案会永久留在盘上）")
    require(!coordinator.contains("failureSource == \"renderer\" }) else { return }"),
            "A2: 记录仍是「有了就不再记」：真失败的具名原因写不进去")

    // ── A3：任务行与托盘说同一件事 ───────────────────────────────────────────
    require(presentation.contains("if hostSentenceWins { return status }"),
            "A3: 三轴说得出「未领取」而托盘是空的（任务行与托盘会分叉）")
    require(task.contains("WishMachineOutputReachability.resolve("),
            "A3: 任务行没有读那**唯一**一份判据")
    require(task.contains("hostSentenceWins = true"),
            "A3: 任务行没有把「托盘上还没有它」交给宿主那句说")
    require(app.contains("hostSentenceWins: hostSentenceWins"),
            "A3: hostSentenceWins 没有传进呈现")
    require(task.contains("status = \"可领取\""),
            "A3: 任务行不再有「可领取」这一档")

    // ── A4：可领取 ⇒ 入库（**物件一律来自生成网格**；回执键幂等）───────────────
    //
    // 用户 2026-10-02 的产品决定（原话「不能再用集合拼了」）：三轴尺寸**不再**改走任何手拼几何
    // （`WorldPrimitiveTelevision` 已停用、产品路径零调用），而是按用户给的三个数**逐轴**兑现
    // —— 素材会被拉伸，那正是"素材 + 他的尺寸"这个取舍本身。这里钉的是**产品路径**：
    // 生成网格那条路必须在，而且一个几何拼构造点都不许有。
    require(!app.contains("WorldPrimitiveTelevision("),
            "A4: 产品路径又在构造手拼几何（用户要求物件一律来自他的素材生成）")
    require(app.contains("let url = URL(fileURLWithPath: path)"),
            "A4: 生成网格那条路不见了 —— 素材的外观 / 贴图 / 细节就没人用了")
    require(app.contains("WorldPropSizePolicy.dimensionsVerdict("),
            "A4: 三轴尺寸没有走唯一一份裁决（`dimensionsVerdict(`）")
    require(app.contains("requestID: \"claimed.\" + job.id.uuidString"),
            "A4: 入库回执键不再是 claimed.<jobID>（幂等身份没了）")
    require(app.contains(".register(asset.prop)"),
            "A4: 入库不再是 .register(asset.prop)")
    return problems
}

let realFiles = [descriptorPath: readSource(descriptorPath),
                 presentationPath: readSource(presentationPath),
                 coordinatorPath: readSource(coordinatorPath),
                 appPath: readSource(appPath)]
let beforeDigests = realFiles.mapValues(sha256)

let realProblems = rederivationProblems(descriptor: realFiles[descriptorPath]!,
    presentation: realFiles[presentationPath]!, coordinator: realFiles[coordinatorPath]!,
    app: realFiles[appPath]!)
for problem in realProblems { print("FAIL: \(problem)") }
guard realProblems.isEmpty else {
    print("FAIL: 派生结论的可重新推导性不成立（判据见上）")
    exit(1)
}
print("PASS: A1–A4 源码级判据（唯一一份判据 / 现场推导 / 具名失败 / 任务行与托盘同句 / 基础几何 + 幂等回执）")

// MARK: - 注入负对照：每条判据都必须真的会红

struct Injection { let name: String; let file: String; let old: String; let new: String }
let injections: [Injection] = [
    // A1 反面：把 HEAD 那套"派生结论当持久事实"原样装回去。
    Injection(name: "永久信记录（托盘按持久化的 outputRenderFailure 减件）", file: appPath,
        old: "        let ready = wishMachineCoordinator.readyOutputs(worldID: worldID).filter { objectIDs.contains($0.id) }",
        new: """
        let failedIDs = Set(jobs.filter {
            wishMachineCoordinator.outputRenderFailure(id: $0.id, worldID: worldID, residentScope: scope) != nil
        }.map(\\.objectID))
        let identities = Set(jobs.map(\\.objectID)).subtracting(failedIDs)
        let ready = wishMachineCoordinator.readyOutputs(worldID: worldID).filter { identities.contains($0.id) }
        """),
    // A2 反面：不看现场推导，只要有 ready job 就清 —— 真失败也会被抹掉。
    // 锚点刻意取**单行**（多行字面量会被 Swift 的缩进剥离改掉前导空格，锚点就找不到）。
    Injection(name: "无条件清（不重新推导就抹掉记录）", file: appPath,
        old: "                case .ready(let id) where id == job.objectID:",
        new: "                case _ where true:"),
    // A3 反面：任务行只信三轴，托盘空着也说"可领取"。
    Injection(name: "两者分叉（任务行不看托盘的现场结论）", file: presentationPath,
        old: "        if hostSentenceWins { return status }",
        new: "        if false { return status }"),
    // A4 反面：手拼几何又被接回产品路径（用户 2026-10-02 的产品决定：物件一律来自素材生成）。
    Injection(name: "手拼几何被接回产品路径（App 侧又出现构造点）", file: appPath,
        old: "                let url = URL(fileURLWithPath: path)",
        new: "                let primitiveTelevision = try? WorldPrimitiveTelevision(millimeters: spec)\n                let url = URL(fileURLWithPath: path)"),
    // A1 反面：现场失败就直接把产物清出托盘 ⇒ 一次次重新装载（重试风暴）。
    Injection(name: "现场失败即清空托盘（重试风暴）", file: appPath,
        old: "        let pool = healthy.isEmpty ? ready : healthy",
        new: "        let pool = healthy"),
]
for injection in injections {
    var copy = realFiles
    guard let text = copy[injection.file], text.contains(injection.old) else {
        print("FAIL: 注入锚点在真源码里找不到：\(injection.name) / \(injection.old)")
        exit(1)
    }
    copy[injection.file] = text.replacingOccurrences(of: injection.old, with: injection.new)
    guard copy[injection.file] != text else {
        print("FAIL: 注入负对照「\(injection.name)」没有改到源码副本")
        exit(1)
    }
    let problems = rederivationProblems(descriptor: copy[descriptorPath]!,
        presentation: copy[presentationPath]!, coordinator: copy[coordinatorPath]!, app: copy[appPath]!)
    guard !problems.isEmpty else {
        print("FAIL: 注入负对照「\(injection.name)」⇒ 判据必须变红，它却全绿")
        exit(1)
    }
    print("PASS: 注入负对照「\(injection.name)」⇒ 判据变红（\(problems[0])）")
}

// MARK: - 注入**没有写盘**：逐文件 sha256 与注入前逐位一致

for (path, digest) in beforeDigests {
    guard sha256(readSource(path)) == digest else {
        print("FAIL: 注入改到了盘上的 \(path)（注入只许发生在内存副本里）")
        exit(1)
    }
}
print("PASS: 注入后逐字还原，\(watched.count) 份真源码 sha256 与注入前一致（注入只改内存副本）")

// MARK: - 行为级：编真源码跑一遍

let behavior = #"""
import Foundation
import simd
import WorldRuntime

struct ResidentImageAttachment: Identifiable, Codable, Sendable, Equatable {
    let id: UUID; let url: URL; let displayName: String
}
struct RealtimeDJToolResult { let callID: String; let resultJSON: Data; let isError: Bool }

@main struct Checks {
    @MainActor static func main() async throws {
        var checks = 0, failures: [String] = []
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if !value { failures.append(label) }
        }
        let world = "84503420-3010-4944-8fde-2f383cd08ebe"
        let scope = "resident.world.ODQ1MDM0MjAtMzAxMC00OTQ0LThmZGUtMmYzODNjZDA4ZWJl"
        let jobID = UUID(uuidString: "0C285296-9164-4A2B-8FB7-6648E549A4AE")!
        let objectID = "wish-prop-0c285296-9164-4a2b-8fb7-6648e549a4ae"
        let scratch = URL(fileURLWithPath: "/tmp/gmgn-rederivation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let model = scratch.appendingPathComponent("model.glb")
        try Data([0x67, 0x6c, 0x54, 0x46, 2, 0, 0, 0, 20, 0, 0, 0, 0, 0, 0, 0]).write(to: model)

        // ── A1 行为：陈旧失败**不挡路**；现场推导成功 ⇒ 可领取 ──────────────────
        let stale = "成品场景加载失败：许愿机产物的尺寸无效，暂时无法显示。"
        check(WishMachineOutputReachability.resolve(isTrayHolder: true,
            live: .ready(id: objectID), objectID: objectID, recordedFailure: stale) == .claimable,
            "A1: 现场推导成功时那条陈旧失败仍然挡着（正是真机那台电视领不了的原因）")
        check(WishMachineOutputReachability.resolve(isTrayHolder: false,
            live: .ready(id: objectID), objectID: objectID, recordedFailure: nil) != .claimable,
            "A1: 不在托盘上的一件也被说成可领取（托盘只有一件）")
        check(WishMachineOutputReachability.resolve(isTrayHolder: true,
            live: .empty, objectID: objectID, recordedFailure: stale) == .deriving(reason: stale),
            "A1: 还没有现场结论时不许下结论（也不许丢掉那句可读原因）")
        check(WishMachineOutputReachability.resolve(isTrayHolder: true,
            live: .loading(id: objectID), objectID: objectID, recordedFailure: stale) == .deriving(reason: stale),
            "A1: 装载中必须算 deriving，不能算可领取")

        // ── A2 行为：现场失败 ⇒ 具名不可用（字段 + 数值）；清只在成功那一档 ──────
        let rejection = WishMachineDimensionRejection(field: "size_intent.longest.meters",
            value: 1443, expected: "0.01—100 米")
        let named = WishMachineOutputError.invalidDimensions(rejection).localizedDescription
        check(named.contains("size_intent.longest.meters") && named.contains("1443"),
            "A2: 尺寸拒绝没有带字段与数值（实测 \(named)）")
        check(WishMachineOutputReachability.resolve(isTrayHolder: true,
            live: .failed(id: objectID, message: named), objectID: objectID, recordedFailure: nil)
            == .unavailable(reason: named),
            "A2: 现场失败没有被说成不可用（真失败会被抹掉）")
        check(WishMachineOutputReachability.resolve(isTrayHolder: false,
            live: .failed(id: objectID, message: named), objectID: objectID, recordedFailure: nil) != .claimable,
            "A2: 现场失败的一件被说成可领取")

        // ── A3 行为：任务行与托盘说同一件事（真 `currentStatusLine`） ──────────
        func presentation(_ reachabilityReason: String?, claimable: Bool, terminal: Bool) -> WishMachineTaskPresentation {
            let axes = ResidentTaskAxisProjection.project(.completed, ownership: .notClaimed,
                placement: .unknown)
            return WishMachineTaskPresentation(id: jobID, title: "超大荧幕电视",
                status: claimable ? "可领取" : (reachabilityReason ?? "正在把产物放上托盘"),
                detail: nil, isTerminal: terminal, axes: axes,
                hostSentenceWins: !claimable)
        }
        let claimableLine = presentation(nil, claimable: true, terminal: false).currentStatusLine
        // 2026-10-02 收口：`stage=ready` 那一档的主文案是**唯一投影**那一句「未领取」
        // （用户拍板），托盘上有没有它是**原因**里的事。此处钉的是"任务行说的是投影那一句、
        // 而不是它自己再编一套（旧那套叫「可领取」）"。
        check(claimableLine == "未领取", "A3: 托盘上有它那一档任务行说的是「\(claimableLine)」，不是投影那一句「未领取」")
        let blockedLine = presentation("场景加载失败：\(named)", claimable: false, terminal: true).currentStatusLine
        check(blockedLine.contains("size_intent.longest.meters") && !blockedLine.contains("未领取"),
            "A3: 托盘空着时任务行说「\(blockedLine)」—— 与托盘不是同一句具名原因")
        let loadingLine = presentation(nil, claimable: false, terminal: false).currentStatusLine
        check(loadingLine != "未领取",
            "A3: 托盘还在装载、任务行就说「\(loadingLine)」（那是把还没上托盘的一件说成最终态）")

        // ── A1/A2 行为：真 coordfinator 上的「重新推导」两档，且幂等 ──────────────
        struct SeedArchive: Encodable { var authorizations: [Int]; var jobs: [WishMachineJob]; var events: [WishMachineEvent] }
        let job = WishMachineJob(id: jobID, worldID: world, residentScope: scope,
            authorizationID: UUID(), attachmentID: UUID(), requestID: "call_00_fixture",
            name: "超大荧幕电视", heightMeters: 0.862,
            sizeIntent: PropSizeIntent(millimeters: .init(x: 1443, y: 862, z: 302), source: .user),
            objectID: objectID, jobID: jobID, stage: .ready, remoteState: .completed,
            modelPath: model.path)
        check(job.sizeIntent?.mode == .dimensions, "A4: 三轴意图没有解成 dimensions")
        check(job.sizeIntent?.meters == 1.443, "A1: 三轴意图派生的米数不是 1.443（毫米当米的旧 bug）")
        let event = WishMachineEvent(id: UUID(), wishID: jobID, worldID: world, residentScope: scope,
            objectID: objectID, kind: .failed, computeMayContinue: false,
            stage: .ready, remoteState: .completed, message: stale,
            cancelRequested: false, forwardedToDaemon: true, failureSource: "renderer")
        let wishes = scratch.appendingPathComponent("wishes", isDirectory: true)
        try FileManager.default.createDirectory(at: wishes, withIntermediateDirectories: true)
        try JSONEncoder().encode(SeedArchive(authorizations: [], jobs: [job], events: [event]))
            .write(to: wishes.appendingPathComponent("wishes.json"))
        let store = PropGenerationStore(directory: scratch,
            daemonClient: PropTaskDaemonClient(root: scratch,
                socketURL: scratch.appendingPathComponent("taskd.sock"),
                allowsLaunching: false, requestTimeout: 1))
        let coordinator = WishMachineCoordinator(store: store, directory: wishes, canClaim: { _ in nil })
        check(coordinator.residentJobs(worldID: world, residentScope: scope).count == 1,
            "A1: 真档案没有读回来（重启后连任务都看不见）")
        check(coordinator.outputRenderFailure(id: jobID, worldID: world, residentScope: scope) != nil,
            "A1: 真机那条 renderer 失败没有读回来")
        check(coordinator.readyOutputs(worldID: world).count == 1,
            "A1: ready 产物不再被派生出来（托盘会空着）")
        check(coordinator.readyOutputs(worldID: world).first?.sizeIntent?.meters == 1.443,
            "A1: 托盘描述符没有带上尺寸意图（渲染端拿不到「用户说的哪根轴」）")
        try coordinator.clearOutputRenderFailure(id: jobID, worldID: world, residentScope: scope)
        check(coordinator.outputRenderFailure(id: jobID, worldID: world, residentScope: scope) == nil,
            "A1: 重新推导成功后那条陈旧失败还在（这就是真机那台电视永久领不了的原因）")
        let secondClear = try coordinator.clearOutputRenderFailure(id: jobID, worldID: world, residentScope: scope)
        check(secondClear == false, "A1: 清除不幂等（没有记录时还报告改过）")
        // 现场推导**仍失败** ⇒ 记录必须留下，而且换成这一次的具名原因。
        try coordinator.recordOutputRenderFailure(id: jobID, worldID: world, residentScope: scope, message: named)
        let recorded = coordinator.outputRenderFailure(id: jobID, worldID: world, residentScope: scope)
        check(recorded != nil, "A2: 真失败被清掉之后再也没记回来")
        check(recorded?.message?.contains("size_intent.longest.meters") == true
            && recorded?.message?.contains("1443") == true,
            "A2: 记录里的失败没有字段与数值（实测 \(recorded?.message ?? "nil")）")
        try coordinator.recordOutputRenderFailure(id: jobID, worldID: world, residentScope: scope, message: "第二次推导的具名原因")
        let updated = coordinator.outputRenderFailure(id: jobID, worldID: world, residentScope: scope)
        check(updated?.message == "成品场景加载失败：第二次推导的具名原因",
            "A2: 记录没有被替换成最近一次推导的结论（实测 \(updated?.message ?? "nil")）")
        let rendererFailures = coordinator.residentJobs(worldID: world, residentScope: scope).count
        check(rendererFailures == 1, "A1/A2: 重放产生了多余状态变更")
        // 重放"重新推导成功"：仍幂等。
        try coordinator.clearOutputRenderFailure(id: jobID, worldID: world, residentScope: scope)
        try coordinator.clearOutputRenderFailure(id: jobID, worldID: world, residentScope: scope)
        check(coordinator.outputRenderFailure(id: jobID, worldID: world, residentScope: scope) == nil,
            "A2: 幂等重放又写出了一条记录")

        // ── A4 行为：三轴 → 基础几何平面电视；layoutRevision 只 +1、幂等 ─────────
        let spec = WorldPropSizeMillimeters(x: 1443, y: 862, z: 302)!
        let television = try WorldPrimitiveTelevision(millimeters: spec)
        check(abs(television.size.x - 1.443) < 0.0001 && abs(television.size.y - 0.862) < 0.0001
            && abs(television.size.z - 0.302) < 0.0001,
            "A4: 基础几何的三轴不是 1.443 × 0.862 × 0.302（实测 \(television.size)）")
        let prop = television.generatedProp(objectID: objectID, sourceWishID: jobID.uuidString)
        let transform = WorldTransform(position: WorldVector3(x: 0, y: 0, z: 0),
            rotation: .identity, scale: WorldVector3(x: 1, y: 1, z: 1))
        var simulation = WorldSimulation(restoring: WorldState(revision: 0, worldID: world,
            worldTime: Date(), lastObservedWallTime: Date(), weather: .clear, agentTransform: transform))
        let revisionBefore = simulation.state.layoutRevision
        try simulation.applyPropLayout(.register(prop), expectedLayoutRevision: revisionBefore,
            requestID: "claimed." + jobID.uuidString)
        let revisionAfter = simulation.state.layoutRevision
        check(revisionAfter == revisionBefore + 1,
            "A4: layoutRevision 不是只 +1（\(revisionBefore) → \(revisionAfter)）")
        let stored = simulation.state.objectStates.values.filter { $0.generatedProp != nil }
        check(stored.count == 1, "A4: 权威里落下的物件记录不是一条（实测 \(stored.count)）")
        check(simulation.state.heldProp == nil, "A4: heldProp 那条被冒名顶替了")
        check(abs((stored.first?.generatedProp?.size.x ?? 0) - 1.443) < 0.0001
            && abs((stored.first?.generatedProp?.size.y ?? 0) - 0.862) < 0.0001
            && abs((stored.first?.generatedProp?.size.z ?? 0) - 0.302) < 0.0001,
            "A4: 权威里那件的尺寸不是用户说的三轴（实测 \(stored.first?.generatedProp?.size ?? WorldVector3(x: 0, y: 0, z: 0))）")
        // 幂等重放：同一回执键 + 同一命令，无论 revision 说什么都不再写第二遍。
        try simulation.applyPropLayout(.register(prop), expectedLayoutRevision: revisionAfter,
            requestID: "claimed." + jobID.uuidString)
        try simulation.applyPropLayout(.register(prop), expectedLayoutRevision: revisionBefore,
            requestID: "claimed." + jobID.uuidString)
        check(simulation.state.layoutRevision == revisionAfter,
            "A4: 幂等重放又把 layoutRevision 推了一次（\(simulation.state.layoutRevision)）")
        check(simulation.state.objectStates.values.filter { $0.generatedProp != nil }.count == 1,
            "A4: 幂等重放产生了第二条物件记录")
        check(simulation.state.layoutReceipts["claimed." + jobID.uuidString] != nil,
            "A4: 幂等身份（claimed.<jobID> 回执）没有落盘")

        for failure in failures { print("FAIL: " + failure) }
        guard failures.isEmpty else { exit(1) }
        print("PASS: \(checks) 行为级检查（真 Reachability / 真 currentStatusLine / 真 coordinator 记录两档 / 真 WorldSimulation 入库幂等）")
        exit(0)
    }
}
"""#

let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-rederivation-build-\(UUID())")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let program = directory.appendingPathComponent("Checks.swift")
let binary = directory.appendingPathComponent("check")
try behavior.write(to: program, atomically: true, encoding: .utf8)

let inputs = ["Presence/PropGenerationClient", "Presence/PropGenerationStore",
              "Presence/PropTaskDaemonClient", "Presence/PropImagePreparation",
              "Presence/PropGenerationConfiguration", "Presence/WishMachineCoordinator",
              "Presence/WishMachineOutputDescriptor", "Presence/WishMachineTaskPresentation",
              // 任务行那一句委托给唯一投影（`OwnershipSentence` 是唯一出口），一起编。
              "Presence/ResidentOwnershipProjection"]
    .map { sourcesDir.appendingPathComponent($0 + ".swift").path }
guard inputs.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) else {
    print("FAIL: 许愿机的真源码不全"); exit(1)
}
func run(_ path: String, _ arguments: [String]) throws -> Int32 {
    let process = Process(); process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments; try process.run(); process.waitUntilExit()
    return process.terminationStatus
}
let compiled = try run("/usr/bin/swiftc", ["-j1", "-parse-as-library"] + worldRuntimeHarnessFlags()
    + inputs + [program.path, "-o", binary.path])
guard compiled == 0 else { exit(compiled) }
exit(try run(binary.path, []))

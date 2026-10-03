// ---------------------------------------------------------------------------
// 许愿任务 = **一条条系统消息**，出口是**收件箱**（用户 2026-10-02 原话：
// 「许愿任务变成消息提示，不要单独做窗口了」＋「这个任务消息变成了 append 到对话了……
// 如果不放，就放收件箱啊」）。
//
// 这一份钉七件事，**每一条都带注入负对照**（注入回内存 / 临时副本必须 FAIL）：
//
// 1. **没有单独的许愿任务窗口/列表**：产品路径（`apps/macos/Sources/**`）里零个
//    许愿任务列表标识（`resident.wish-tasks` / `resident.wish-task.`），
//    `WishMachineTaskStatusView` 里也没有 `state.tasks` / `ForEach` / 「许愿任务」标题。
//    注入「把列表装回去」⇒ FAIL。
// 2. **出口是收件箱、不再是对话记录**：宿主把消息经**既有**的收件箱入口
//    （`residentSystemInboxStore.apply` / `kind: "wish.task"`）落库，而
//    `publishResidentTranscript` 里**一个**许愿任务消息的痕迹都没有（`wishTaskMessageFeed` /
//    `speaker: .notice` / `ResidentChatTranscriptLine`）。注入「追加回对话」或
//    「摘掉收件箱那条线」⇒ 两个方向都必须 FAIL。
// 3. **状态变化各发一条、同一状态不重复**（幂等）：真源码编译起来驱动。
//    注入「去掉去重」⇒ FAIL。
// 4. **失败消息不自动消失**（留到用户处理完）：用的是**唯一投影**的
//    `OwnershipDisplayState.failed`（没有第二份真相）。注入「照样过期」⇒ FAIL。
// 5. **消息文案是人话**：没有 `key=value` / UUID / 路径 / 内部字段名 / 省略号堆叠。
//    注入「旧文案」（把原始 reason 与省略号塞回去）⇒ FAIL。
// 6. **唯一投影的状态语义没改**（与 HEAD 比**语义**：签名 / 五种对外状态 + 七个动作的
//    集合 / 不许 `Codable` / 不许 `init(rawValue:)`；文案字符串放行）。
// 7. **「什么时候占屏幕」仍然只有一处判据**（`WishMachineTaskPrompt`，跟着消息走）。
//
// 注入只改**内存副本**（源码字符串）或**临时副本**（编译到 NSTemporaryDirectory），
// 落盘的产品源码一个字不改。
//
// 用法：swift tools/test-wish-task-messages.swift
// ---------------------------------------------------------------------------
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sources = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
let overlayRelative = "VisualEngine/StageOverlayView.swift"
let appRelative = "App/GMGNRadioApp.swift"
let messageRelative = "Presence/WishMachineTaskMessage.swift"
let projectionRelative = "Presence/ResidentOwnershipProjection.swift"

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
    try String(contentsOf: sources.appendingPathComponent(relative), encoding: .utf8)
}
/// 从签名到配对的 `}`。
func declaration(_ source: String, _ signature: String) -> String? {
    guard let start = source.range(of: signature)?.lowerBound,
          let open = source[start...].firstIndex(of: "{") else { return nil }
    var depth = 0
    for index in source[open...].indices {
        if source[index] == "{" { depth += 1 }
        if source[index] == "}" { depth -= 1 }
        if depth == 0 { return String(source[start...index]) }
    }
    return nil
}

// ---------------------------------------------------------------------------
// 判据 1 / 2：源码级（**产品路径零调用** + 消息通道接线）
// ---------------------------------------------------------------------------
/// 一段源码里的违规项（「许愿任务列表又回来了」/「消息通道没接上」）。
/// **注入负对照要的就是「这里非空」。**
func panelViolations(overlay: String, repositorySources: [String: String]) -> [String] {
    var out: [String] = []
    guard let view = declaration(overlay, "struct WishMachineTaskStatusView: View {") else {
        out.append("抽不出 WishMachineTaskStatusView —— 那是「没有许愿任务列表」的宿主")
        return out
    }
    for token in ["state.tasks", "ForEach", "Text(\"许愿任务\")", "resident.wish-tasks", "resident.wish-task."]
    where view.contains(token) {
        out.append("许愿任务窗口/列表的痕迹「\(token)」又出现在视图里了 —— 产品路径必须零调用（消息通道才是出口）")
    }
    for (relative, source) in repositorySources.sorted(by: { $0.key < $1.key }) {
        for token in ["resident.wish-tasks", "resident.wish-task."] where source.contains(token) {
            out.append("\(relative) 里还有许愿任务列表标识「\(token)」")
        }
    }
    return out
}

func channelViolations(app: String) -> [String] {
    var out: [String] = []
    // ① 出口必须是**既有**的收件箱入口：条目自带时间戳、按时间倒序、未读由它自己算。
    for token in ["residentSystemInboxStore.apply(", "kind: \"wish.task\"",
                  "residentSystemInboxStore.restore(", "pushSystemInboxSnapshots()"]
    where !app.contains(token) {
        out.append("许愿任务的状态消息没有走收件箱：宿主里找不到「\(token)」")
    }
    guard let push = declaration(app, "private func pushWishTaskMessages(") else {
        out.append("抽不出 `pushWishTaskMessages` —— 那是把唯一投影的消息送进收件箱的那一处")
        return out
    }
    // ② 送进收件箱的那一条必须是唯一投影的消息（既有幂等键 + 既有一句话模板），
    //    不是在这里另拼一份文案、也不是退回任务行那条原始字段通道（那会把字段名/原因
    //    原样带进用户可见的那一行）。
    for token in ["wishTaskMessageFeed.sync(", "message.id", "message.text",
                  "title: message.text", "taskID: jobID.uuidString",
                  "residentSystemInboxStore.apply("] where !push.contains(token) {
        out.append("收件箱那条出口没有用唯一投影的消息：`pushWishTaskMessages` 里找不到「\(token)」")
    }
    for token in ["task.detail", "task.status"] where push.contains(token) {
        out.append("收件箱那一行的文案又回到任务行的原始字段了：`pushWishTaskMessages` 里还有「\(token)」")
    }
    // ③ 出口**不是**对话记录：那里不许再追加许愿任务消息（用户 2026-10-02 真机原话）。
    guard let publish = declaration(app, "private func publishResidentTranscript()") else {
        out.append("抽不出 `publishResidentTranscript` —— 那是「对话里只有人和居民」的宿主")
        return out
    }
    for token in ["wishTaskMessageFeed", "speaker: .notice", "ResidentChatTranscriptLine"]
    where publish.contains(token) {
        out.append("对话记录里又追加了许愿任务消息：`publishResidentTranscript` 里还有「\(token)」"
            + " —— 系统通知不许 append 进对话，它该走收件箱（跟着收件箱的时间走）")
    }
    // ④ 消息的类别只有一个：同一个收件箱条目不许被两处按两套文案写（"两边都放一半"）。
    let appliers = app.components(separatedBy: "residentSystemInboxStore.apply(").count - 1
    if appliers != 1 {
        out.append("投递许愿任务消息的写入者有 \(appliers) 处 —— 收件箱条目只许有一个写入者")
    }
    // ⑤ 幂等键就是**消息自己的 id**（`WishMachineTaskMessageBuilder.identifier` = 行标识 +
    //    投影状态）：不许在这里另造一个，尤其不许掺时间/随机 —— 那会让同一条消息每次启动
    //    都变成"另一条"，于是已读永远回不来、条目还会重复。注入「掺时间/随机」⇒ 必须红。
    guard let deliveryStart = app.range(of: "let deliveries: [ResidentSystemDelivery]")?.lowerBound,
          let deliveryEnd = app.range(of: "guard !deliveries.isEmpty", range: deliveryStart..<app.endIndex)?.lowerBound else {
        out.append("抽不出投递构造（`let deliveries: [ResidentSystemDelivery]` … `guard !deliveries.isEmpty`）")
        return out
    }
    let construction = String(app[deliveryStart..<deliveryEnd])
    if !construction.contains("eventID: message.id") {
        out.append("收件箱那条消息的幂等键不是消息自己的 id：投递构造里找不到「eventID: message.id」")
    }
    for token in ["UUID()", "Date()", "arc4random", "randomElement", "timeIntervalSince", ".now"]
    where construction.contains(token) {
        out.append("消息的幂等键掺了时间/随机：投递构造里出现「\(token)」"
            + " —— 同一条消息每次启动都会变成另一条，已读永远回不来")
    }
    return out
}

func repositorySourceMap() throws -> [String: String] {
    var map: [String: String] = [:]
    let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
    while let url = enumerator?.nextObject() as? URL {
        guard url.pathExtension == "swift" else { continue }
        let relative = url.path.replacingOccurrences(of: sources.path + "/", with: "")
        map[relative] = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
    return map
}

let overlaySource = try read(overlayRelative)
let appSource = try read(appRelative)
let repositorySources = try repositorySourceMap()

let cleanPanelFailures = panelViolations(overlay: overlaySource, repositorySources: repositorySources)
guard cleanPanelFailures.isEmpty else {
    for failure in cleanPanelFailures { print("FAIL: " + failure) }
    exit(1)
}
print("PASS[no-wish-panel]: 产品路径上零个许愿任务窗口/列表（扫过 \(repositorySources.count) 个 Swift 源文件）")
let cleanChannelFailures = channelViolations(app: appSource)
guard cleanChannelFailures.isEmpty else {
    for failure in cleanChannelFailures { print("FAIL: " + failure) }
    exit(1)
}
print("PASS[inbox-channel]: 状态变化走既有的收件箱入口（residentSystemInboxStore.apply / kind: wish.task），对话记录里零追加")

// ---------------------------------------------------------------------------
// 判据 1 / 2 的注入负对照（只在内存副本上做手术）
// ---------------------------------------------------------------------------
/// 把「许愿任务」列表装回去 —— 就是用户要求删掉的那一块。
func injectWishTaskPanel(into overlay: String) -> String {
    overlay.replacingOccurrences(
        of: "struct WishMachineTaskStatusView: View {",
        with: """
        struct WishMachineTaskStatusView: View {
            // 注入负对照（只在内存副本里）：把许愿任务列表装回去
            @ViewBuilder private var injectedWishTaskList: some View {
                Text("许愿任务")
                ForEach(state.tasks) { task in Text(task.currentStatusLine) }
            }
        """)
}

/// 注入回**旧行为**：把许愿任务消息又 append 到对话记录末尾（没有会话时间的那些行）。
func injectTranscriptAppend(into app: String) -> String {
    app.replacingOccurrences(
        of: "        let lines = residentChatTranscript.lines()\n",
        with: """
                let lines = residentChatTranscript.lines() + wishTaskMessageFeed.messages.map { message in
                    ResidentChatTranscriptLine(
                        turnID: UUID(),
                        speaker: .notice,
                        text: message.text)
                }
        """)
}

/// 把收件箱那条出口摘掉 —— 状态变化于是哪里都没有出口。
func injectDetachedInbox(into app: String) -> String {
    app.replacingOccurrences(of: "residentSystemInboxStore.apply(", with: "// 注入：收件箱出口摘掉\n            _ = (")
}

/// 把收件箱那一行的文案退回任务行的**原始字段**（原因里带着字段名/数值的那种）。
func injectRawFieldCopy(into app: String) -> String {
    app.replacingOccurrences(of: "                title: message.text,\n",
                             with: "                title: tasks.first?.status ?? \"\",\n")
        .replacingOccurrences(of: "                taskID: jobID.uuidString,\n",
                              with: "                taskID: jobID.uuidString, detail: task.detail ?? \"\",\n")
}

/// 幂等键掺**时间**：同一条消息每次启动都变成另一条 —— 已读永远回不来、条目重复。
func injectUnstableEventID(into app: String) -> String {
    app.replacingOccurrences(of: "                eventID: message.id,\n",
        with: "                eventID: message.id + \"-\" + String(Date().timeIntervalSince1970),\n")
}

let panelInjection = ("把许愿任务列表装回去", injectWishTaskPanel(into: overlaySource), { (source: String) in
    panelViolations(overlay: source, repositorySources: repositorySources)
}) as (String, String, (String) -> [String])
let appendInjection = ("把许愿任务消息追加回对话", injectTranscriptAppend(into: appSource), { (source: String) in
    channelViolations(app: source)
}) as (String, String, (String) -> [String])
let detachedInjection = ("把收件箱那条出口摘掉", injectDetachedInbox(into: appSource), { (source: String) in
    channelViolations(app: source)
}) as (String, String, (String) -> [String])
let rawFieldInjection = ("把收件箱那一行的文案退回原始字段", injectRawFieldCopy(into: appSource), { (source: String) in
    channelViolations(app: source)
}) as (String, String, (String) -> [String])
let unstableEventIDInjection = ("幂等键掺时间（每次启动都是另一条消息）", injectUnstableEventID(into: appSource), { (source: String) in
    channelViolations(app: source)
}) as (String, String, (String) -> [String])

for (name, injected, violations, pristine) in [
    (panelInjection.0, panelInjection.1, panelInjection.2, overlaySource),
    (appendInjection.0, appendInjection.1, appendInjection.2, appSource),
    (detachedInjection.0, detachedInjection.1, detachedInjection.2, appSource),
    (rawFieldInjection.0, rawFieldInjection.1, rawFieldInjection.2, appSource),
    (unstableEventIDInjection.0, unstableEventIDInjection.1, unstableEventIDInjection.2, appSource)
] {
    check(injected != pristine, "注入负对照「\(name)」确实改到了源码副本")
    let injectedFailures = violations(injected)
    check(!injectedFailures.isEmpty,
          "注入负对照「\(name)」⇒ 判据必须变红（第一条：\(injectedFailures.first ?? "（没有）")）")
}

// ---------------------------------------------------------------------------
// 判据 6：唯一投影的**状态语义**没改（不是整文件哈希）。
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
    process.arguments = ["show", "HEAD:apps/macos/Sources/GMGNRadio/\(relative)"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return String(decoding: data, as: UTF8.self)
}
/// 去掉行注释：判据看的是**声明**，不是注释里提到这些名字。
func codeOnly(_ source: String) -> String {
    source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
        guard let range = line.range(of: "//") else { return String(line) }
        return String(line[line.startIndex..<range.lowerBound])
    }.joined(separator: "\n")
}
/// **顶层** case 名集合（`switch` 分支里的 `case .x:` 不算）—— 本文件已有 `declaration`。
func enumCaseNames(_ source: String, _ signature: String) -> Set<String> {
    guard let body = declaration(source, signature) else { return [] }
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
    "static func group(for state: OwnershipDisplayState) -> OwnershipGroup {",
    "static func sentence(generation: String, ownership: String, placement: String,",
    "static func inventoryNotSavedReason(_ facts: OwnershipRowFacts) -> String {",
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
let projectionSource = try read(projectionRelative)
if let head = gitShowHead(projectionRelative) {
    check(semanticCore(projectionSource) == semanticCore(head),
          "判据 6：唯一投影的状态语义与 HEAD 相同：签名 / 五种对外状态 + 七个动作的集合 / 不许 Codable / 不许 init(rawValue:)（文案字符串放行）")
    // 负对照：把语义改坏 ⇒ 核心必须与 HEAD 不同（只改内存副本，落盘源码一个字不改）。
    let codableInjected = projectionSource.replacingOccurrences(
        of: "enum OwnershipDisplayState: String, Sendable, CaseIterable {",
        with: "enum OwnershipDisplayState: String, Sendable, CaseIterable, Codable {")
    check(codableInjected != projectionSource && semanticCore(codableInjected) != semanticCore(head),
          "判据 6 负对照「给对外状态加 Codable」：注入 ⇒ 语义核心与 HEAD 不同（这一条抓得住）")
    let rawValueInitInjected = projectionSource.replacingOccurrences(
        of: "    var label: String {", with: "    init(rawValue: String) { self = .placed }\n    var label: String {")
    check(rawValueInitInjected != projectionSource && semanticCore(rawValueInitInjected) != semanticCore(head),
          "判据 6 负对照「加 init(rawValue:)（从存档读状态的入口）」：注入 ⇒ 语义核心与 HEAD 不同")
    // 正对照：文案改回工程腔 ⇒ 核心**不变**（文案归文案门禁管，语义门禁不管）。
    let copyBack = projectionSource.replacingOccurrences(of: "这次入库没有成功，东西还没进到库存。",
                                                        with: "世界没有接受这次入库：layoutReceipts 里没有 claimed.<uuid>，objectStates 里也没有它。")
    check(copyBack != projectionSource && semanticCore(copyBack) == semanticCore(head),
          "判据 6 正对照「文案改回工程腔」：语义核心不变 —— 语义门禁不管文案")
} else {
    check(false, "读不到 HEAD 那一份投影，语义判据无法成立")
}

// ---------------------------------------------------------------------------
// 判据 3 / 4 / 5 / 7：把**真源码**编译起来驱动
// ---------------------------------------------------------------------------
let messageSource = try read(messageRelative)

let testSource = #"""
import Foundation

var failures = 0
func expect(_ condition: Bool, _ message: String) {
    print((condition ? "PASS " : "FAIL ") + message)
    if !condition { failures += 1 }
}

let base = Date(timeIntervalSince1970: 1_700_000_000)

func job(_ stage: OwnershipJobStage, objectID: String, name: String?) -> OwnershipRowFacts {
    var facts = OwnershipRowFacts(objectID: objectID)
    facts.jobID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    facts.jobName = name
    facts.jobStage = stage
    return facts
}

// ── 六个状态，**全部经唯一投影**得到（facts → row）──
let generatingRow = ResidentOwnershipProjection.row(job(.generating, objectID: "prop-a", name: "暖光落地灯"))
let awaitingClaimRow = ResidentOwnershipProjection.row(job(.ready, objectID: "prop-b", name: "木质书架"))
// 「已领取但入库没保存」：stage == .claimed，世界里却没有这一件。
let inventoryNotSavedRow = ResidentOwnershipProjection.row(job(.claimed, objectID: "prop-c", name: "白色长剑"))
// 「失败」：生成失败，而且**原始 reason 里就带着 key=value**（旧文案的来源）。
var failedFacts = job(.failed, objectID: "prop-d", name: "平面电视")
failedFacts.lastError = "size_intent.longest.meters = 1443，期望 有限数"
let failedRow = ResidentOwnershipProjection.row(failedFacts)
// 「完成」：真的进了世界、也摆出来了。
var placedFacts = job(.claimed, objectID: "prop-e", name: "超大荧幕电视")
placedFacts.objectPresent = true
placedFacts.objectHasGeneratedProp = true
placedFacts.objectIsEnabled = true
let placedRow = ResidentOwnershipProjection.row(placedFacts)
// 「已取消」：终态，但**不是**失败待办。
let cancelledRow = ResidentOwnershipProjection.row(job(.cancelled, objectID: "prop-f", name: "旧台灯"))

// ── 投影先说清楚它判成了哪一档（消息的状态来源就是它，不许在这里另判）──
expect(generatingRow.state == .generating && generatingRow.statusText == OwnershipSentence.generating.rawValue,
    "投影：开始生成 = .generating /「\(OwnershipSentence.generating.rawValue)」")
expect(awaitingClaimRow.state == .awaitingClaim && awaitingClaimRow.statusText == OwnershipSentence.awaitingClaim.rawValue,
    "投影：待领取 = .awaitingClaim /「\(OwnershipSentence.awaitingClaim.rawValue)」")
expect(inventoryNotSavedRow.state == .failed && inventoryNotSavedRow.statusText == OwnershipSentence.inventoryNotSaved.rawValue,
    "投影：已领取但入库没保存 = .failed /「\(OwnershipSentence.inventoryNotSaved.rawValue)」")
expect(failedRow.state == .failed && failedRow.statusText == OwnershipSentence.generationFailed.rawValue,
    "投影：失败 = .failed /「\(OwnershipSentence.generationFailed.rawValue)」")
expect(placedRow.state == .placed && placedRow.statusText == OwnershipSentence.placed.rawValue,
    "投影：完成 = .placed /「\(OwnershipSentence.placed.rawValue)」")
expect(cancelledRow.state == .ended, "投影：已取消落在 .ended（与失败待办分开）")

// ── 判据 5：文案是人话（正则词表与「我的物件」那一份同源）──
let uuidPattern = "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
let keyValuePattern = "[A-Za-z_][A-Za-z0-9_.]*[ \t]*=[ \t]*[^ \t]"
let pathPattern = "(/Users/|/Library/|/private/|/var/|\\.json|file://)"
let internalTerms = ["sourceWishID", "objectID", "jobID", "wishes.json", "state.json",
                     "layoutReceipts", "remoteState", "size_intent", "lastError"]
func humanViolations(_ text: String) -> [String] {
    var out: [String] = []
    if text.range(of: uuidPattern, options: .regularExpression) != nil { out.append("UUID") }
    if text.range(of: keyValuePattern, options: .regularExpression) != nil { out.append("key=value") }
    if text.range(of: pathPattern, options: .regularExpression) != nil { out.append("路径") }
    for term in internalTerms where text.contains(term) { out.append("内部字段名「\(term)」") }
    // 省略号堆叠：两个以上的 `…`，或四个以上的 `.` 连在一起。
    if text.range(of: "(…{2,}|\\.{4,})", options: .regularExpression) != nil { out.append("省略号堆叠") }
    return out
}

let rows = [generatingRow, awaitingClaimRow, inventoryNotSavedRow, failedRow, placedRow, cancelledRow]
var messages: [WishMachineTaskMessage] = []
for row in rows {
    guard let message = WishMachineTaskMessageBuilder.message(row) else {
        expect(false, "投影判成 .\(row.state.rawValue) 却没有消息出来")
        continue
    }
    messages.append(message)
}
expect(messages.count == rows.count, "六个状态各生成一条消息（\(messages.count)/\(rows.count)）")
for message in messages {
    let violations = humanViolations(message.text)
    expect(violations.isEmpty, "消息是人话：\(message.text)（违规：\(violations.joined(separator: "、"))）")
}
let texts = Set(messages.map(\.text))
expect(texts.count == messages.count, "六条消息文案各不相同（\(texts.count) 种）")
expect(messages.contains { $0.keepsUntilHandled && $0.text.contains(OwnershipSentence.generationFailed.rawValue) },
    "失败那条：状态词逐字来自投影，并且明说会留到处理完")
expect(messages.contains { $0.keepsUntilHandled && $0.text.contains(OwnershipSentence.inventoryNotSaved.rawValue) },
    "已领取未入库那条也按失败待办处理（同样是投影的 .failed）")
expect(messages.filter(\.keepsUntilHandled).count == 2,
    "只有投影判成 .failed 的两条是失败待办（拿到 \(messages.filter(\.keepsUntilHandled).count) 条）")

// ── 判据 3：状态变化各发一条、同一状态不重复（幂等）──
var feed = WishMachineTaskMessageFeed()
let allCandidates = rows.map { WishMachineTaskMessageFeed.Candidate(row: $0, promptExpiresAt: nil) }
let firstSync = feed.sync(allCandidates, now: base)
expect(firstSync.count == rows.count, "第一次同步：六个状态六条消息（\(firstSync.count) 条）")
let secondSync = feed.sync(allCandidates, now: base.addingTimeInterval(5))
expect(secondSync.count == firstSync.count,
    "同一状态不重复：再同步一次仍然只有 \(firstSync.count) 条（拿到 \(secondSync.count) 条）")
// ── 判据 4：失败待办不自动消失（与时钟无关）──
var retention = WishMachineTaskMessageFeed()
let longAgo = base.addingTimeInterval(-86_400)
let failingCandidates = [failedRow, inventoryNotSavedRow].map {
    WishMachineTaskMessageFeed.Candidate(row: $0, promptExpiresAt: longAgo)
}
let atStart = retention.sync(failingCandidates, now: base)
expect(atStart.count == 2, "两条失败待办先发出来（\(atStart.count) 条）")
let muchLater = retention.sync(failingCandidates, now: base.addingTimeInterval(86_400))
expect(muchLater.count == 2,
    "失败待办不自动消失：到期锚点在过去、又过了一整天，两条都还在（拿到 \(muchLater.count) 条）")
let handled = retention.sync([WishMachineTaskMessageFeed.Candidate(row: generatingRow, promptExpiresAt: nil)],
                             now: base.addingTimeInterval(90_000))
expect(handled.count == 1 && handled[0].text.contains(OwnershipSentence.generating.rawValue),
    "用户处理完（投影不再说失败）之后，那两条失败待办才收起")
expect(handled.allSatisfy { !$0.keepsUntilHandled }, "此时留下的那条不再是失败待办")

let progressed = feed.sync([WishMachineTaskMessageFeed.Candidate(row: placedRow, promptExpiresAt: nil)],
                           now: base.addingTimeInterval(10))
expect(progressed.count == 1
        && progressed[0].text == messages.last(where: { $0.taskID == placedRow.key.identifier })?.text,
    "状态推进后，通道里只剩当前那一档那一条（旧的自动让位）")

// ── 判据 4 的另一半：其它终态按**既有**窗口过期 ──
var window = WishMachineTaskMessageFeed()
let expiry = base.addingTimeInterval(30)
let windowCandidates = [WishMachineTaskMessageFeed.Candidate(row: cancelledRow, promptExpiresAt: expiry)]
_ = window.sync(windowCandidates, now: base)
let stillVisible = window.sync(windowCandidates, now: base.addingTimeInterval(29))
expect(stillVisible.count == 1, "已取消的消息在既有窗口内还在")
let expired = window.sync(windowCandidates, now: base.addingTimeInterval(31))
expect(expired.isEmpty, "已取消的消息按既有窗口收起（其它终态可以过期）")

// ── 判据 7：占不占屏幕仍然只有一处判据 ──
expect(WishMachineTaskPrompt.isShown(promptExpiresAt: nil, at: base),
    "未了结（没有到期锚点）⇒ 判据说「还在屏幕上」")
expect(WishMachineTaskPrompt.isShown(promptExpiresAt: base.addingTimeInterval(30), at: base),
    "终态、窗口没过 ⇒ 判据说「还在屏幕上」")
expect(!WishMachineTaskPrompt.isShown(promptExpiresAt: base, at: base),
    "提示窗到点那一刻就收起（边界不是「再多留一拍」）")

// ── 没有许愿记录的行不是许愿任务的状态：不产生消息 ──
var orphanFacts = OwnershipRowFacts(objectID: "wish-prop-orphan")
orphanFacts.objectPresent = true
orphanFacts.objectHasGeneratedProp = true
orphanFacts.objectIsEnabled = true
let orphanRow = ResidentOwnershipProjection.row(orphanFacts)
expect(WishMachineTaskMessageBuilder.message(orphanRow) == nil, "没有许愿记录的行不产生消息")

// ── 拿不到人给的名字时，绝不把内部编号当名字说出去 ──
let unnamedFacts = job(.generating, objectID: "wish-prop-11111111-2222-3333-4444-555555555555", name: nil)
let unnamedRow = ResidentOwnershipProjection.row(unnamedFacts)
if let unnamed = WishMachineTaskMessageBuilder.message(unnamedRow) {
    expect(humanViolations(unnamed.text).isEmpty, "没有名字时不把内部编号说出去：\(unnamed.text)")
} else {
    expect(false, "没有名字的那一行也该有一条消息")
}

// ── 幂等键是**稳定派生**的（同一个状态每次同步都得到同一个 id）──
expect(messages[0].id == WishMachineTaskMessageBuilder.identifier(rows[0]),
    "同一条消息的幂等键稳定：\(messages[0].id)")
expect(Set(messages.map(\.id)).count == messages.count, "不同状态的幂等键互不相同")

// ── 幂等键在**两次启动**里必须是同一个：同一个投影行、**独立重建**的事实、
//    不同的时刻；不掺 UUID、不掺时间。注入「掺随机/时间」⇒ 必须 FAIL。──
var relaunchFacts = job(.claimed, objectID: "prop-e", name: "超大荧幕电视")
relaunchFacts.objectPresent = true
relaunchFacts.objectHasGeneratedProp = true
relaunchFacts.objectIsEnabled = true
let relaunchedRow = ResidentOwnershipProjection.row(relaunchFacts)
expect(relaunchedRow.key.identifier == placedRow.key.identifier,
    "重启后同一行的行标识不变（都是 \(relaunchedRow.key.identifier)）")
let relaunchID = WishMachineTaskMessageBuilder.identifier(relaunchedRow)
let earlierID = WishMachineTaskMessageBuilder.identifier(placedRow)
expect(relaunchID == earlierID,
    "重启后同一条消息的幂等键不变：两次独立推导都是 \(relaunchID)")
expect(WishMachineTaskMessageBuilder.message(relaunchedRow)?.id == relaunchID,
    "消息的 id 就是那一个稳定派生的幂等键")
let rowIdentity = "11111111-2222-3333-4444-555555555555"
let withoutRowIdentity = relaunchID.replacingOccurrences(of: rowIdentity, with: "")
expect(withoutRowIdentity.range(of: uuidPattern, options: .regularExpression) == nil,
    "幂等键里除了这一行的许愿编号，没有第二个 UUID（不掺随机）：\(relaunchID)")

print(failures == 0 ? "PASS 许愿任务消息判据全部通过" : "FAIL 许愿任务消息判据有 \(failures) 条不通过")
exit(failures == 0 ? 0 : 1)
"""#

/// 跑一份（真源码 / 注入副本）的组合，返回 (退出码, 输出)。
func runProbe(message: String) throws -> (status: Int32, output: String) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gmgn-wish-messages-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let messageFile = directory.appendingPathComponent("WishMachineTaskMessage.swift")
    let projectionFile = directory.appendingPathComponent("ResidentOwnershipProjection.swift")
    let testsFile = directory.appendingPathComponent("main.swift")
    let binary = directory.appendingPathComponent("tests")
    try message.write(to: messageFile, atomically: true, encoding: .utf8)
    try projectionSource.write(to: projectionFile, atomically: true, encoding: .utf8)
    try testSource.write(to: testsFile, atomically: true, encoding: .utf8)
    let compile = Process()
    compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
    compile.arguments = ["-j1", "-target", "arm64-apple-macos14.0",
                         messageFile.path, projectionFile.path, testsFile.path, "-o", binary.path]
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

let pristine = try runProbe(message: messageSource)
guard pristine.status == 0 else {
    for line in pristine.output.split(separator: "\n") { print("   · \(line)") }
    check(false, "驱动**真源码**：状态变化各发一条、同一状态不重复、失败不消失、文案是人话")
    print("FAIL 许愿任务消息判据有 \(failureCount) 条不通过")
    exit(1)
}
check(true, "驱动**真源码**：状态变化各发一条、同一状态不重复、失败不消失、文案是人话")

// ---------------------------------------------------------------------------
// 判据 3 / 4 / 5 的注入负对照（只在**临时副本**上做手术）
// ---------------------------------------------------------------------------
enum MessageInjection: String, CaseIterable {
    /// 去掉幂等去重 —— 同一状态会被重复发。
    case duplicateStates
    /// 失败待办照样按时间窗过期 —— 用户还没处理，提示先没了。
    case failureExpires
    /// 把旧文案塞回去：原始 reason（`key=value`）+ 省略号堆叠。
    case oldCopy
    /// 幂等键掺随机 —— 同一条消息每次启动都是另一条（已读永远回不来）。
    case unstableID

    func apply(to source: String) -> String {
        switch self {
        case .duplicateStates:
            return source.replacingOccurrences(
                of: "guard issued[message.id] == nil else { continue }",
                with: "order.append(message.id)")
        case .failureExpires:
            return source.replacingOccurrences(
                of: "return failingTaskIDs.contains(message.taskID) ? message : nil",
                with: "return WishMachineTaskPrompt.isShown(promptExpiresAt: anchors[id] ?? nil, at: now) ? message : nil")
        case .oldCopy:
            return source.replacingOccurrences(
                of: "var text = \"「\\(displayName(row))」\\(sentence)。\"",
                with: "var text = \"「\\(displayName(row))」\\(sentence)：\\(row.reasonText ?? \"\")……\"")
        case .unstableID:
            return source.replacingOccurrences(
                of: "    static func identifier(_ row: OwnershipRow) -> String {\n        \"\\(row.key.identifier)#\\(stateKey(row))\"\n    }",
                with: "    static func identifier(_ row: OwnershipRow) -> String {\n        \"\\(row.key.identifier)#\\(stateKey(row))#\\(UUID().uuidString)\"\n    }")
        }
    }
}

for injection in MessageInjection.allCases {
    let injected = injection.apply(to: messageSource)
    check(injected != messageSource, "注入负对照「\(injection.rawValue)」确实改到了源码副本")
    let result = try runProbe(message: injected)
    let firstFailure = result.output
        .split(separator: "\n")
        .first { $0.hasPrefix("FAIL ") }
        .map { String($0.dropFirst("FAIL ".count)) } ?? "（没有）"
    check(result.status != 0, "注入负对照「\(injection.rawValue)」⇒ 判据必须变红（第一条：\(firstFailure)）")
}

print(failureCount == 0
    ? "PASS 许愿任务「消息提示」判据全部通过"
    : "FAIL 许愿任务「消息提示」判据有 \(failureCount) 条不通过")
exit(failureCount == 0 ? 0 : 1)

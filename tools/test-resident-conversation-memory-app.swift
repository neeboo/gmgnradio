// 居民长期记忆 App 交付门的离线行为核对。
//
// 从真实 GMGNRadioApp.swift 提取（非重写）registerResidentMemoryTurn /
// presentResidentReply / confirmResidentMemoryTurn / presentResidentMemoryDelivery-
// Failure / showResidentMemoryDeliveryNotice / sendLiveCamMessage 六个生产方法体，
// 用 fake 记忆/语音/显示表面编译运行。行为覆盖：
//   - userMessage 只在守卫通过后登记；source 随 runID 最小绑定（voice/text）；
//   - 显示/语音完成前绝无 ingest；autoSpeak 开启只认整段语音自然播完
//     （.finished），取消/失败/停止后迟到完成一律不写；
//   - 朗读与记忆确认解耦：无记忆 slot 的后台/自驱回复在 autoSpeak 下照常朗读
//     （原 autoSpeak 行为），无 slot 不是错误、不弹提示；
//   - 静音文本以「至少一个显示表面真实存在并显示」为交付；所有显示表面都 nil
//     且无语音时不记为已显示、不 ingest；
//   - 已确认回合恰一次入库；重复/迟到确认 notCurrent 不写；
//   - confirm 的 rejectedText/queueFull/unavailable 结果有可见的「未写入长期
//     记忆」提示（不冒充 durable、不打扰聊天）；accepted 正常易失入队静默。
// 真实 Service 层的每轮召回/缺配置/原生续聊行为由
// test-agent-conversation-memory-service.swift 覆盖（本文件不重复）。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let appSourceURL = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift")
let source = try String(contentsOf: appSourceURL, encoding: .utf8)

func declaration(_ signature: String) -> String {
    guard let start = source.range(of: signature)?.lowerBound else {
        print("FAIL: missing declaration \(signature)")
        exit(1)
    }
    guard let open = source[start...].firstIndex(of: "{") else {
        print("FAIL: unterminated declaration \(signature)")
        exit(1)
    }
    var depth = 0
    for index in source[open...].indices {
        if source[index] == "{" { depth += 1 }
        if source[index] == "}" { depth -= 1 }
        if depth == 0 { return String(source[start...index]) }
    }
    print("FAIL: unbalanced braces in \(signature)")
    exit(1)
}

let registerTurn = declaration("private func registerResidentMemoryTurn(")
let presentReply = declaration("private func presentResidentReply(")
let confirmTurn = declaration("private func confirmResidentMemoryTurn(")
let deliveryFailure = declaration("private func presentResidentMemoryDeliveryFailure(")
let deliveryNotice = declaration("private func showResidentMemoryDeliveryNotice(")
let sendLiveCam = declaration("private func sendLiveCamMessage(")
let loopSourceURL = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/ResidentAgentLoop.swift")
let loopSource = try String(contentsOf: loopSourceURL, encoding: .utf8)
func loopDeclaration(_ signature: String) -> String {
    guard let start = loopSource.range(of: signature)?.lowerBound,
          let open = loopSource[start...].firstIndex(of: "{") else {
        print("FAIL: missing loop declaration \(signature)")
        exit(1)
    }
    var depth = 0
    for index in loopSource[open...].indices {
        if loopSource[index] == "{" { depth += 1 }
        if loopSource[index] == "}" { depth -= 1 }
        if depth == 0 { return String(loopSource[start...index]) }
    }
    print("FAIL: unbalanced braces in \(signature)")
    exit(1)
}
let transcriptTypes = [
    loopDeclaration("struct ResidentChatTurn:"),
    loopDeclaration("struct ResidentChatTranscriptLine:"),
    loopDeclaration("struct ResidentChatTranscript {"),
].joined(separator: "\n")

// 结构性核对：朗读与记忆确认解耦——presentResidentReply 不在 announce 之前
// return；没有匹配记忆 slot 的后台回复在 autoSpeak 下照常朗读（原行为回归），
// 记忆确认只限定有匹配 slot 且整段语音 .finished / 静音已真实显示的回合。
guard !presentReply.contains("guard let slot, slot.reply") else {
    print("FAIL: presentResidentReply must not gate automatic speech on the memory slot")
    exit(1)
}
guard presentReply.contains("if outcome == .finished, let slot, memoryTurn"),
      presentReply.contains("agentSpeechAnnouncer.announce(reply)") else {
    print("FAIL: presentResidentReply must announce regardless of slot and confirm only a matching finished slot")
    exit(1)
}
guard deliveryFailure.contains("case .rejectedText:"),
      deliveryFailure.contains("case .queueFull:"),
      deliveryFailure.contains("case .unavailable:"),
      deliveryFailure.contains("showResidentMemoryDeliveryNotice(") else {
    print("FAIL: confirm failure results must reach a visible delivery notice")
    exit(1)
}

// 结构性核对：performResidentTurn 以真实用户文字传 userMessage、在 run/world
// 守卫全部通过后才登记；onReply 走 presentResidentReply、onCancel 清待确认凭据；
// 语音最终转写入口把新回合绑定为 .voice。
let performResidentTurn = declaration("private func performResidentTurn(")
let ensureResidentLoop = declaration("private func ensureResidentLoop()")
guard source.contains("registerResidentMemoryTurn(runID: messageID, realUserText: realUserText, reply: reply)") else {
    print("FAIL: performResidentTurn does not register the delivery credential after guards")
    exit(1)
}
guard performResidentTurn.contains("userMessage: realUserText"),
      performResidentTurn.contains("let realUserText = input.userMessages.isEmpty"),
      !performResidentTurn.contains("userMessage: input.promptText") else {
    print("FAIL: performResidentTurn must pass real user text as userMessage, never the host prompt")
    exit(1)
}
guard performResidentTurn.range(of: "registerResidentMemoryTurn")!.lowerBound
        > performResidentTurn.range(of: "worldTools == nil || livingWorldContext === requestWorld")!.lowerBound else {
    print("FAIL: credential registration must happen after the run/world guards")
    exit(1)
}
guard ensureResidentLoop.contains("self.presentResidentReply(reply)"),
      ensureResidentLoop.contains("self?.residentMemoryTurnSlot = nil") else {
    print("FAIL: onReply must present through the delivery gate and onCancel must clear it")
    exit(1)
}
guard sendLiveCam.contains("residentTurnSourceByRunID[runID] = .voice") else {
    print("FAIL: voice final transcript must bind its new run source to voice")
    exit(1)
}

/// 提取出的生产方法保持 private；harness 里需要从外部驱动它们做行为断言，
/// 因此只放宽访问级别（不改动任何语句）。
func publicized(_ body: String) -> String {
    body.replacingOccurrences(of: "private func ", with: "func ")
}

let harness = #"""
import Foundation

\#(transcriptTypes)

enum ResidentMemorySource: Equatable { case text, voice }

enum AgentSpeechOutcome: Equatable { case finished, cancelled, failed }
typealias AgentSpeechCompletion = @MainActor (AgentSpeechOutcome) -> Void

enum AgentConversationMemoryDeliveryResult: Equatable {
    case accepted, notCurrent, unavailable, rejectedText, queueFull
}

/// 记忆/语音交付门用的服务 fake：镜像 shared 的 lastTurnDeliveryRequestID 与
/// confirmDeliveredTurn（accepted 后即消费；被取消/新一轮取代即 notCurrent）。
/// forcedResult 可注入受控的失败结果（rejectedText/queueFull/unavailable），
/// 镜像真实 Service：失败不消费 staged 凭据（可重试），accept/notCurrent 消费。
@MainActor
final class AgentConversationService {
    struct Preferences { var autoSpeakReplies = false }
    static let shared = AgentConversationService()
    var preferenceStore = Preferences()
    var stagedRequestID: UUID?
    private(set) var confirmed: [(requestID: UUID, userText: String, reply: String, source: ResidentMemorySource)] = []
    var lastTurnDeliveryRequestID: UUID? { stagedRequestID }
    /// 受控结果：非 nil 时下一次 confirm 直接返回并清空。
    var forcedResult: AgentConversationMemoryDeliveryResult?

    func stage(requestID: UUID) { stagedRequestID = requestID }
    func clearStaged() { stagedRequestID = nil }

    @discardableResult
    func confirmDeliveredTurn(requestID: UUID, userText: String, reply: String,
                              source: ResidentMemorySource, observedAt: String?) -> AgentConversationMemoryDeliveryResult {
        if let forced = forcedResult {
            forcedResult = nil
            if forced == .accepted {
                stagedRequestID = nil
                confirmed.append((requestID, userText, reply, source))
            } else if forced == .notCurrent {
                stagedRequestID = nil
            }
            return forced
        }
        guard stagedRequestID == requestID else { return .notCurrent }
        stagedRequestID = nil
        confirmed.append((requestID, userText, reply, source))
        return .accepted
    }
}

@MainActor
final class FakeAnnouncer {
    var isEnabled = true
    var announced: [String] = []
    private var pendingCompletion: AgentSpeechCompletion?

    func announce(_ text: String) {
        announced.append(text)
    }

    func announce(_ text: String, completion: @escaping AgentSpeechCompletion) {
        announced.append(text)
        pendingCompletion = completion
    }

    func finish(_ outcome: AgentSpeechOutcome) {
        let completion = pendingCompletion
        pendingCompletion = nil
        completion?(outcome)
    }
}

@MainActor
final class FakeLiveCam {
    private(set) var replies: [String] = []
    private(set) var statuses: [String] = []
    func finishAgentReply(_ text: String) { replies.append(text) }
    func showChatStatus(_ text: String) { statuses.append(text) }
}

@MainActor
final class FakeStage {
    private(set) var replies: [String] = []
    private(set) var statuses: [String] = []
    func finishResidentReply(_ text: String, autoRevealsChat: Bool = true) { replies.append(text) }
    func showResidentChatStatus(_ text: String, autoRevealsChat: Bool = true) { statuses.append(text) }
}

@MainActor
final class FakeResidentLoop {
    var lastFinishedRunWasBackground = false
    var lastFinishedTurnSubmissionIDs: [UUID] = []
}

struct ResidentMemoryTurnSlot {
    let runID: UUID
    let requestID: UUID
    let userText: String
    let reply: String
    let source: ResidentMemorySource
}

@MainActor
final class App {
    let service = AgentConversationService.shared
    var agentSpeechAnnouncer = FakeAnnouncer()
    var liveCamWindowController: FakeLiveCam? = FakeLiveCam()
    var stageWindowController: FakeStage? = FakeStage()
    var residentTurnSourceByRunID: [UUID: ResidentMemorySource] = [:]
    var residentMemoryTurnSlot: ResidentMemoryTurnSlot?
    var residentAgentLoop: FakeResidentLoop?
    var residentChatTranscript = ResidentChatTranscript()
    var residentTranscriptScopeKey: String { "test-scope" }
    func publishResidentTranscript() {}

    // sendLiveCamMessage 的 runID→.voice 来源绑定行为在
    // test-resident-loop-app.swift 中编译真实方法验证，本文件只做结构性核对。

    \#(publicized(registerTurn))
    \#(publicized(presentReply))
    \#(publicized(confirmTurn))
    \#(publicized(deliveryFailure))
    \#(publicized(deliveryNotice))

    private static func residentMemoryObservedAt() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

@main struct Test {
    @MainActor static func main() {
        var checks = 0
        var failures = 0
        func check(_ value: Bool, _ message: String) {
            checks += 1
            if !value { failures += 1; print("FAIL: \(message)") }
        }

        let app = App()
        let runID = UUID()
        let service = AgentConversationService.shared

        // 1. 静音文本 + 显示表面存在：显示完成后才 ingest，source=voice 随 runID
        //    绑定；重复 confirm 不再写。
        service.stage(requestID: UUID())
        service.preferenceStore.autoSpeakReplies = false
        app.residentTurnSourceByRunID[runID] = .voice
        app.registerResidentMemoryTurn(runID: runID, realUserText: "看看有什么", reply: "好的")
        check(app.residentMemoryTurnSlot != nil, "guarded turn registers a delivery slot")
        app.presentResidentReply("好的")
        check(app.liveCamWindowController?.replies.last == "好的", "text reply displayed on the live surface")
        check(service.confirmed.count == 1, "silent text turn ingests once after real display")
        check(service.confirmed.last?.source == .voice, "voice run source is forwarded on ingest")
        check(service.confirmed.last?.userText == "看看有什么", "ingest carries the real user text")
        app.presentResidentReply("好的")
        check(service.confirmed.count == 1, "slot cleared after accepted confirmation; no second ingest")

        // 2. autoSpeak 开启：显示完成不 ingest；整段语音 .finished 才 ingest 一次。
        app.liveCamWindowController = FakeLiveCam()
        app.stageWindowController = nil
        service.preferenceStore.autoSpeakReplies = true
        let spokenRequestID = UUID()
        service.stage(requestID: spokenRequestID)
        app.residentMemoryTurnSlot = nil
        app.registerResidentMemoryTurn(runID: UUID(), realUserText: "播首歌", reply: "正在播放")
        app.presentResidentReply("正在播放")
        check(service.confirmed.count == 1, "previous turn count unchanged before speech finishes")
        check(app.agentSpeechAnnouncer.announced.last == "正在播放", "autoSpeak announces the reply")
        app.agentSpeechAnnouncer.finish(.finished)
        check(service.confirmed.count == 2, "full speech completion confirms exactly once")
        check(service.confirmed.last?.reply == "正在播放", "spoken completion confirms the spoken turn")

        // 3. autoSpeak .cancelled（用户停止/被替换）：语音是唯一交付通道，不写。
        let cancelRequestID = UUID()
        service.stage(requestID: cancelRequestID)
        app.residentMemoryTurnSlot = nil
        app.registerResidentMemoryTurn(runID: UUID(), realUserText: "读一下", reply: "好，读给你")
        app.presentResidentReply("好，读给你")
        let countAfterStart = service.confirmed.count
        app.agentSpeechAnnouncer.finish(.cancelled)
        check(service.confirmed.count == countAfterStart, "cancelled speech never ingests")

        // 4. autoSpeak .failed（朗读失败）：不确认、不写。
        let failedRequestID = UUID()
        service.stage(requestID: failedRequestID)
        app.residentMemoryTurnSlot = nil
        app.registerResidentMemoryTurn(runID: UUID(), realUserText: "再读", reply: "再读一遍")
        app.presentResidentReply("再读一遍")
        let countAfterFailedStart = service.confirmed.count
        app.agentSpeechAnnouncer.finish(.failed)
        check(service.confirmed.count == countAfterFailedStart, "failed speech never ingests")

        // 5. 停止后迟到完成：onCancel 已清凭据与 slot，.finished 迟到 notCurrent 不写。
        let stoppedRequestID = UUID()
        service.stage(requestID: stoppedRequestID)
        app.residentMemoryTurnSlot = nil
        app.registerResidentMemoryTurn(runID: UUID(), realUserText: "迟到", reply: "迟到的回复")
        app.presentResidentReply("迟到的回复")
        // 镜像 stop：service.cancel 清凭据 + onCancel 清 slot。
        service.clearStaged()
        app.residentMemoryTurnSlot = nil
        app.agentSpeechAnnouncer.finish(.finished)
        check(service.confirmed.count == countAfterFailedStart,
              "stopped turn's late speech completion writes nothing")

        // 6. 所有显示表面都 nil 且静音文本：不算已显示、不 ingest。
        app.liveCamWindowController = nil
        app.stageWindowController = nil
        service.preferenceStore.autoSpeakReplies = false
        service.stage(requestID: UUID())
        app.residentMemoryTurnSlot = nil
        app.registerResidentMemoryTurn(runID: UUID(), realUserText: "无显示", reply: "无显示的回复")
        app.presentResidentReply("无显示的回复")
        check(service.confirmed.count == countAfterFailedStart,
              "no display surface and no speech never counts as delivered")

        // 7. 语音成为唯一交付通道：无显示表面 + autoSpeak .finished 仍算交付。
        service.preferenceStore.autoSpeakReplies = true
        service.stage(requestID: UUID())
        app.residentMemoryTurnSlot = nil
        app.registerResidentMemoryTurn(runID: UUID(), realUserText: "只听", reply: "只听这一段")
        app.presentResidentReply("只听这一段")
        app.agentSpeechAnnouncer.finish(.finished)
        check(service.confirmed.count == countAfterFailedStart + 1,
              "fully spoken reply counts as delivered even without a text surface")

        // 8. 无记忆 slot 的后台/自驱回复 + autoSpeak：朗读不被记忆门禁压制
        //    （原 autoSpeak 行为回归）；文本照常显示；没有 slot 只是没有记忆可
        //    写，不是错误——不确认、不弹失败提示。
        app.liveCamWindowController = FakeLiveCam()
        app.stageWindowController = FakeStage()
        service.preferenceStore.autoSpeakReplies = true
        service.clearStaged()
        app.residentMemoryTurnSlot = nil
        service.forcedResult = nil
        let announcedBefore = app.agentSpeechAnnouncer.announced.count
        let confirmedBeforeBackground = service.confirmed.count
        let statusesBeforeBackground = app.liveCamWindowController?.statuses.count ?? 0
        app.presentResidentReply("正常后台回复，无记忆写入回合")
        check(app.agentSpeechAnnouncer.announced.count == announcedBefore + 1,
              "autoSpeak announces replies even without a memory slot")
        check(app.liveCamWindowController?.replies.last == "正常后台回复，无记忆写入回合",
              "background text still displays without a memory slot")
        check(service.confirmed.count == confirmedBeforeBackground,
              "no memory slot never confirms an ingest")
        check(app.liveCamWindowController?.statuses.count == statusesBeforeBackground,
              "no memory slot is not an error: no failure notice is raised")

        // 9. rejectedText：整轮不写记忆但聊天不受影响——确认结果必须可见，
        //    不能默默冒充记忆成功；slot 保留（失败凭据未消费，可重试）。
        service.preferenceStore.autoSpeakReplies = false
        app.liveCamWindowController = FakeLiveCam()
        app.stageWindowController = FakeStage()
        service.stage(requestID: UUID())
        service.forcedResult = .rejectedText
        app.residentMemoryTurnSlot = nil
        app.registerResidentMemoryTurn(runID: UUID(), realUserText: "超长文本", reply: "已显示的回复")
        app.presentResidentReply("已显示的回复")
        check(service.confirmed.count == confirmedBeforeBackground,
              "rejectedText never ingests")
        check(app.liveCamWindowController?.statuses.last?.contains("未写入长期记忆") == true,
              "rejectedText shows a visible not-written notice")
        check(app.liveCamWindowController?.statuses.last?.contains("控制字符") == true,
              "rejectedText notice names the stable reason")
        check(app.residentMemoryTurnSlot != nil,
              "rejectedText keeps the unconsumed slot for a possible retry")

        // 10. queueFull：同样可见「未写入（队列满、未进易失缓冲）」，不入队不冒充。
        service.forcedResult = nil
        service.stage(requestID: UUID())
        service.forcedResult = .queueFull
        app.residentMemoryTurnSlot = nil
        app.registerResidentMemoryTurn(runID: UUID(), realUserText: "排队", reply: "队列满的回复")
        app.presentResidentReply("队列满的回复")
        check(service.confirmed.count == confirmedBeforeBackground,
              "queueFull never ingests")
        check(app.liveCamWindowController?.statuses.last?.contains("队列已满") == true,
              "queueFull shows a visible queue-full notice")
        check(app.liveCamWindowController?.statuses.last?.contains("易失缓冲") == true,
              "queueFull notice does not claim durable storage")

        // 11. unavailable（记忆未接线）：可见、不写；accepted 静默（正常易失入队，
        //     不冒充 durable，也不需要失败提示）。
        service.forcedResult = nil
        service.stage(requestID: UUID())
        service.forcedResult = .unavailable
        app.residentMemoryTurnSlot = nil
        app.registerResidentMemoryTurn(runID: UUID(), realUserText: "未接线", reply: "未接线的回复")
        app.presentResidentReply("未接线的回复")
        check(service.confirmed.count == confirmedBeforeBackground,
              "unavailable never ingests")
        // 文案已随"外部 provider 接线移除"校准：适配器现在恒为挂载，
        // "未接线"不再准确，改为说明记忆服务暂时不可用。
        check(app.liveCamWindowController?.statuses.last?.contains("暂时不可用") == true,
              "unavailable shows a visible memory-service-unavailable notice")
        let statusCountBeforeAccepted = app.liveCamWindowController?.statuses.count ?? 0
        service.forcedResult = nil
        service.stage(requestID: UUID())
        app.residentMemoryTurnSlot = nil
        app.registerResidentMemoryTurn(runID: UUID(), realUserText: "正常", reply: "正常回复")
        app.presentResidentReply("正常回复")
        check(service.confirmed.count == confirmedBeforeBackground + 1,
              "accepted confirmation still ingests once")
        check(app.liveCamWindowController?.statuses.count == statusCountBeforeAccepted,
              "accepted volatile enqueue is not presented as a failure notice")

        // 12. notCurrent（迟到/被取代）：凭据已消费，静默清理，无失败提示。
        service.forcedResult = nil
        service.stage(requestID: UUID())
        app.residentMemoryTurnSlot = nil
        app.registerResidentMemoryTurn(runID: UUID(), realUserText: "迟到", reply: "迟到的回复")
        service.clearStaged()
        let statusCountBeforeNotCurrent = app.liveCamWindowController?.statuses.count ?? 0
        app.presentResidentReply("迟到的回复")
        check(service.confirmed.count == confirmedBeforeBackground + 1,
              "notCurrent late confirmation never ingests")
        check(app.liveCamWindowController?.statuses.count == statusCountBeforeNotCurrent,
              "notCurrent is a normal superseded outcome, no failure notice")
        check(app.residentMemoryTurnSlot == nil,
              "notCurrent consumes the stale slot silently")

        print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) resident conversation memory app-gate checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#

let work = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-conv-memory-app-\(UUID())")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: work) }
let file = work.appendingPathComponent("Test.swift")
try harness.write(to: file, atomically: true, encoding: .utf8)
let binary = work.appendingPathComponent("check").path
func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}
let compiled = try run("/usr/bin/swiftc", ["-swift-version", "6", "-j1", "-parse-as-library", file.path, "-o", binary])
guard compiled == 0 else { exit(compiled) }
exit(try run(binary, []))

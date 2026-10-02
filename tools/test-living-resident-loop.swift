// Runs the real conversation service and Live Cam send method without the app,
// credentials, a model request, or an Xcode test host.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sources = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
let app = try String(contentsOf: sources.appendingPathComponent("App/GMGNRadioApp.swift"), encoding: .utf8)
func declaration(_ signature: String, in source: String) -> String {
    guard let start = source.range(of: signature)?.lowerBound else { fatalError("Missing \(signature)") }
    // 默认参数里可能自带闭包（`humanOrderedClaim: ... = { false }`）：按第一处
    // `{` 起算会把方法体截断在默认闭包里。只有签名里先出现 `(` 时（函数声明）
    // 才先配平参数表；枚举/结构体（`(` 出现在类型体里或没有）仍按第一个 `{`
    // 起算，避免把类型体当参数表。
    let opening: String.Index
    let firstBrace = source[start...].firstIndex(of: "{")
    if let paren = source.range(of: "(", range: start..<(firstBrace ?? source.endIndex))?.lowerBound {
        var depth = 0
        var cursor = paren
        while cursor < source.endIndex {
            if source[cursor] == "(" { depth += 1 }
            if source[cursor] == ")" {
                depth -= 1
                if depth == 0 { break }
            }
            cursor = source.index(after: cursor)
        }
        guard cursor < source.endIndex, let body = source[cursor...].firstIndex(of: "{") else {
            fatalError("Missing \(signature)")
        }
        opening = body
    } else {
        guard let body = source[start...].firstIndex(of: "{") else { fatalError("Missing \(signature)") }
        opening = body
    }
    var depth = 0
    for i in source[opening...].indices {
        if source[i] == "{" { depth += 1 }
        if source[i] == "}" { depth -= 1 }
        if depth == 0 { return String(source[start...i]) }
    }
    fatalError("Unbalanced \(signature)")
}
let sendMethod = declaration("private func sendLiveCamMessage(", in: app)
let submissionMethod = declaration("private func sendResidentSubmission(", in: app)
let submissionSource = declaration("private enum ResidentSubmissionSource", in: app)
let imageSource = try String(contentsOf: sources.appendingPathComponent("Presence/ResidentImageAttachment.swift"), encoding: .utf8)
let imageDeclarations = ["struct ResidentImageAttachment", "struct ResidentChatSubmission"].map { declaration($0, in: imageSource) }.joined(separator: "\n")
let machineSource = try String(contentsOf: sources.appendingPathComponent("Presence/WishMachineScene.swift"), encoding: .utf8)
let machineIDs = machineSource.components(separatedBy: .newlines).filter { $0.contains("static let worldID =") || $0.contains("static let propID =") }.joined(separator: "\n")
let loopMethods = ["private func ensureResidentLoop(", "private func synchronizeResidentLoopPresentation(",
                   // 生产把回合失败出口从内联的可见状态改成了具名的
                   // presentResidentLoopFailure：失败文本仍写进同一可见表面，
                   // 只是后台回合不再替用户展开聊天。整套方法原文抽取，行为不变。
                   "private func presentResidentLoopFailure(",
                   // 宿主自己把一轮**停下**（更新的指令超车 / 进入装修）时的具名出口：
                   // 与失败出口分开，所以这里也编译**真实**实现 —— 才能证明它不会
                   // 被写成"未送达"。它用 livingWorldLogger 留一行真机可查的原因，
                   // 所以仿真宿主也提供同名 Logger（真的会写日志，不是空桩）。
                   "private func presentResidentInterruption(ids: [UUID],",
                   // synchronizeResidentLoopPresentation 现在还会在空闲时给出
                   // 「一个后端都没装」的设置指引；指引文案与判断逻辑由
                   // test-first-use-guidance 专测，这里必须编译同一份真实实现，
                   // 才能证明它不会盖掉真实失败状态。
                   "private func refreshResidentBackendGuidance(",
                   // 原文层已整体移除（2026-10-01）：原先这里还要抽编
                   // `ResidentMemoryTurnSlot` / `registerResidentMemoryTurn` /
                   // `confirmResidentMemoryTurn` / `residentMemoryObservedAt`。
                   // 那四个生产声明已随 `memory_ingest` 一起删除，所以抽取列表
                   // 也必须去掉它们 —— 抽取式宿主**不能**靠写死桩来假装它们还在。
                   "private func presentResidentReply(",
                   "private func performResidentTurn(",
                   "private func returnHeldPropBeforeResidentStop(reason: String) -> Bool",
                   "private func stopResidentLoop(reason: String, userIntent: Bool = false) -> Bool",
                   // 摆放读回（"已领产物是否真的在当前空间里摆好"）现在由面板的
                   // 一次"恢复"和后台续办共用同一份宿主事实，所以这里必须编译
                   // 同一份真实实现。
                   "private func residentWishPlacementAlreadyCompleted(",
                   "private func cancelResidentMessage("].map {
    declaration($0, in: app)
}.joined(separator: "\n")
// `userIntent` 是**因果**，不是措辞：只有界面上的停止控件才是用户意图，那条取消才允许
// 写持久的许愿/自主暂停。换空间、退出、可用性（网络）回收一律走 `cancel()`，绝不伪装成
// "用户按过停止"——否则一次网络抖动就会留下一个只有人工能解除的暂停。
let stopLoopMethod = declaration("private func stopResidentLoop(reason: String, userIntent: Bool = false) -> Bool", in: app)
guard stopLoopMethod.contains("if userIntent { residentAgentLoop.stop() } else { residentAgentLoop.cancel() }") else {
    print("FAIL: only an explicit user stop may mark user intent; availability/world-switch cancellation must not")
    exit(1)
}
let contextMethod = app.contains("private func currentResidentWorldContext(")
    ? declaration("private func currentResidentWorldContext(", in: app) : ""
let toolsMethod = app.contains("private func makeResidentWorldTools(")
    ? declaration("private func makeResidentWorldTools(", in: app) : ""
let controller = try String(contentsOf: sources.appendingPathComponent("DesktopPresence/LiveCamWindowController.swift"), encoding: .utf8)
// 失败出口改为 showFailureStatus（LiveCam）与 showResidentFailureStatus（舞台），
// residentStatusText 是「空闲时是否已有提示」的判断依据；三者都按当前生产签名原文抽取。
let replyMethods = ["func beginAgentReply(", "func finishAgentReply(", "func showChatStatus(", "func setResidentThinking(",
                    "func showFailureStatus(", "var residentStatusText"].map { declaration($0, in: controller) }.joined(separator: "\n")
let harness = #"""
import Foundation
import os
import WorldRuntime
// No render host is created; the real vision contracts compile below, while
// this conversation fixture deliberately has no available capture surface.
\#(imageDeclarations)
enum WishMachineScene { \#(machineIDs) }
enum ResidentPropHostError: LocalizedError { case editorOpen; var errorDescription:String? { "请先结束摆放。" } }
enum StageVisualMood: String, CaseIterable { case afterglow, liquid, pulse }
enum StageLyricsVisualMode: String { case auto; static let agentValues = ["auto"]; init?(agentValue: String) { self.init(rawValue: agentValue) } }
enum SpatialScenePreset: String, CaseIterable { case cabin }
enum SpatialWeather: String, CaseIterable { case clear }
enum SpatialCameraCommandDirection: String, CaseIterable { case reset }

struct RealtimeDJToolCall: Codable, Equatable, Sendable {
    let id: String; let name: String; let argumentsJSON: Data
}
struct RealtimeDJToolResult: Codable, Equatable, Sendable {
    let callID: String; let resultJSON: Data; let isError: Bool
}

// The real web-reference tools compile here; their network seam is stubbed because
// this suite never registers an image (the fixture authorize step returns nil).
struct ResidentWebImageResponse: Sendable {
    let data: Data; let mimeType: String; let finalURL: URL
}
struct ResidentWebImageDownloader: Sendable {
    func download(_ url: URL) async throws -> Data { throw URLError(.unsupportedURL) }
    func fetchPublicData(_ url: URL, maximumBytes: Int) async throws -> ResidentWebImageResponse { throw URLError(.unsupportedURL) }
}

@MainActor final class FormalRunner {
    var tools: [ResidentConversationTools] = []
    var prompts: [String] = []
    var pending: [Int: CheckedContinuation<AgentConversationOutcome, Error>] = [:]
    func run(_ prompt: String, _ tools: ResidentConversationTools) async throws -> AgentConversationOutcome {
        let index = self.tools.count
        self.tools.append(tools)
        prompts.append(prompt)
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }
    func waitForCalls(_ count: Int) async {
        for _ in 0..<100_000 {
            if tools.count >= count { return }
            await Task.yield()
        }
        print("FAIL: actual Live Cam send did not reach formal resident sender")
        exit(1)
    }
    func finish(_ index: Int) {
        pending.removeValue(forKey: index)!.resume(returning: AgentConversationOutcome(reply: "formal reply", sessionID: "formal-session"))
    }
}

final class FixtureLocator: AgentExecutableLocating, @unchecked Sendable {
    private let lock = NSLock()
    private var available = true
    func setAvailable(_ value: Bool) { lock.lock(); available = value; lock.unlock() }
    func locate(executableNames: [String]) -> URL? {
        lock.lock(); defer { lock.unlock() }
        return available ? URL(fileURLWithPath: "/fixture/" + executableNames[0]) : nil
    }
}
// The process boundary alone is simulated, including a process that ignores
// cancellation and delivers stdout after the user starts another request.
actor ControlledRunner: CodexCommandRunning {
    struct Call: Sendable { let arguments: [String]; let input: String? }
    var calls: [Call] = []
    var pending: [Int: CheckedContinuation<CodexCommandResult, Error>] = [:]
    func run(arguments: [String], standardInput: String?) async throws -> CodexCommandResult {
        let index = calls.count
        calls.append(Call(arguments: arguments, input: standardInput))
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }
    func waitForCalls(_ count: Int) async {
        for _ in 0..<100_000 {
            if calls.count >= count { return }
            await Task.yield()
        }
        fatalError("Request never reached process boundary")
    }
    func finish(_ index: Int, session: String = "resident", reply: String = "hello", exit: Int32 = 0, backend: AgentConversationBackendID = .codex) {
        let events: String
        switch backend {
        case .codex: events = [
            "{\"type\":\"thread.started\",\"thread_id\":\"\(session)\"}",
            "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"\(reply)\"}}"
        ].joined(separator: "\n")
        case .claudeCode, .workbuddy, .qoder:
            events = "{\"session_id\":\"\(session)\",\"result\":\"\(reply)\"}"
        case .pi:
            events = "{\"type\":\"session\",\"id\":\"\(session)\"}\n{\"type\":\"message_end\",\"message\":{\"content\":\"\(reply)\"}}"
        case .dsh: events = reply
        }
        pending.removeValue(forKey: index)!.resume(returning: CodexCommandResult(exitCode: exit, output: events))
    }
}

struct FixtureWorldState: WorldStatePersisting {
    let state: WorldState
    func load() throws -> WorldState? { state }
    func save(_ state: WorldState) throws {}
}

final class RejectWishNetwork: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { fatalError("Conversation fixtures must never make a generation request") }
    override func stopLoading() {}
}

func worldPayload(_ prompt: String) throws -> [String: Any] {
    let json = prompt.components(separatedBy: "空间资料：\n")[1]
        .components(separatedBy: "\n用户消息：")[0]
    return try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
}

typealias RealConversationService = AgentConversationService
@MainActor final class LiveCamPanel {
    var replies: [String] = []
    // 真实 LiveCamPanel 只有一个可见状态槽（residentStatusText），并用生产的
    // ResidentStatusNoticeMerge 按类别合并：failure 不被后续 info/voice 覆盖。
    // statuses 记录每次真正改变可见状态槽的发布，供断言使用。
    var statuses: [String] = []
    private var statusNotice: String?
    private var statusKind: ResidentStatusNoticeKind = .info
    var text = ""
    var thinking = false
    func setResidentThinking(_ value: Bool) { thinking = value }
    func showAgentReply(_ reply: String) {
        text = reply
        if reply != "…" && !reply.isEmpty { replies.append(reply) }
    }
    // 普通提示与失败提示共用同一个可见槽，并按真实面板的类别规则合并：居民回合
    // 失败（含后端预检失败）走 showFailureStatus，绝不会被后续普通提示盖掉。
    func showChatStatus(_ value: String) { apply(value, kind: .info) }
    func showFailureStatus(_ value: String) { apply(value, kind: .failure) }
    // 真实面板正是用这个属性回答「当前是否已有提示」；生产据此决定要不要补设置指引。
    var residentStatusText: String? { statusNotice }
    private func apply(_ value: String, kind: ResidentStatusNoticeKind) {
        let decision = ResidentStatusNoticeMerge.resolve(incoming: value, kind: kind,
            current: statusNotice, currentKind: statusKind)
        let changed = decision.text != statusNotice || decision.kind != statusKind
        statusNotice = decision.text
        statusKind = decision.kind
        text = decision.text ?? ""
        if let notice = decision.text, changed { statuses.append(notice) }
    }
}
@MainActor final class Surface {
    let panel = LiveCamPanel()
    var window: AnyObject? { panel }
    var agentReplyBuffer = ""
    var replies: [String] { panel.replies }
    var statuses: [String] { panel.statuses }
    var waiting: Bool { panel.thinking }
    var deliveryNotice: String?
    var progress: String?
    func setResidentProgress(_ value: String?) { progress = value }
    func setResidentDeliveryNotice(_ value: String?) { deliveryNotice = value }
    func setResidentCanStop(_ value: Bool) {}
    /// 全局开关横幅的宿主推入口（状态收敛）：授权不再由任务行表达。
    func setResidentAutonomyStop(_ stopped: Bool) {}
    func setWishMachineConnectivity(_ text: String?) {}
    func restoreResidentSubmission(_ submission: ResidentChatSubmission, notice: String) { showChatStatus(notice) }
    \#(replyMethods)
}
@MainActor final class Speech {
    enum Outcome { case finished, cancelled, failed }
    var isEnabled = false
    var spoken: [String] = []
    var completions: [(Outcome) -> Void] = []
    func announce(_ reply: String) { spoken.append(reply) }
    func announce(_ reply: String, completion: @escaping (Outcome) -> Void) {
        spoken.append(reply)
        completions.append(completion)
    }
    func complete(_ outcome: Outcome) {
        let callbacks = completions; completions.removeAll()
        callbacks.forEach { $0(outcome) }
    }
    func stop() { complete(.cancelled) }
}
@MainActor final class AppHarness: DJAgentRadioActions {
    final class Avatar {
        var thinkingID: UUID?
        func beginResidentThinking(runID: UUID) { thinkingID = runID }
        func endResidentThinking(runID: UUID) { if thinkingID == runID { thinkingID = nil } }
        func clearResidentThinking() { thinkingID = nil }
    }
    let avatarRuntime = Avatar()
    private let wishMachineCoordinator: WishMachineCoordinator
    // This suite exercises conversation/tool leases with no image or wish event.
    // Image grants, persistence, rendering and pause are exercised by the focused
    // test-wish-machine-app-runtime and coordinator suites, not simulated here.
    //
    // 只读参数接口（`read_wish_machine_contract`）的 `serviceFacts` 闭包要读这两个成员
    // （生产里在 `GMGNRadioApp.swift:3518/3519`）。本仿真宿主既然原文抽编
    // `makeResidentWorldTools`，就得照同一种方式把它们桩出来 —— 否则门禁红在一个
    // 与断言无关的成员缺失上。
    private var wishMachineConfiguration: PropGenerationConfiguration?
    private var wishMachineServiceNotice = ""
    // 电视机：`App/GMGNRadioApp.swift` 的接线补丁（2026-10-01 22:16 落盘）让
    // `makeResidentWorldTools` 里多了一段 `screenStore.map { … ResidentScreenTools … }`。
    // 本仿真宿主既然**原文抽编**那个方法，就得照上面 `read_wish_machine_contract`
    // 同一种方式把这两个名字桩出来 —— 否则门禁红在一个与断言无关的成员缺失上。
    //
    // 桩的语义刻意与生产一致：这里 `screenStore == nil`，正是生产里"没有接线 ⇒
    // 不注册电视工具"的那一支（`?? []`）。三条屏幕工具本身由
    // `tools/test-resident-screen-overlay.swift` 专测，不在本仿真里假装。
    struct ScreenToolStub {
        struct Reply { let payloadJSON: Data; let isError: Bool }
        let name: String
        let description: String
        let inputSchema: [String: Any]
        let handle: @MainActor (String, Data) async -> Reply
    }
    struct ResidentScreenTools {
        init(control: WorldScreenStore, isCurrent: @escaping @MainActor () -> Bool) {}
        var tools: [ScreenToolStub] { [] }
    }
    final class WorldScreenStore {}
    private var screenStore: WorldScreenStore?
    private func bindResidentWishScope(_ context: ResidentWorldContext, loop: ResidentAgentLoop) {}
    private func rebindResidentLoopMemory() {}
    private func residentSelfState() -> ResidentSelfState? { nil }
    private func residentVisionSession(messageID: UUID) -> ResidentVisionToolbox.Session? { nil }
    struct RenderSurface {
        struct View { var residentVisionSurfaceHandle: (any ResidentVisionSurface)? { nil } }
        let surfaceView = View()
    }
    private let stageRenderSurfaceController: RenderSurface? = nil
    private func pauseResidentWishContinuations() {}
    private func authorizeWishImages(_ input: ResidentAgentLoop.Input, worldContext: ResidentWorldContext) throws -> UUID? {
        precondition(input.imageURLs.isEmpty); return nil
    }
    private func registerWishImages(_ attachments: [ResidentImageAttachment], loop: ResidentAgentLoop, worldScope: String) { precondition(attachments.isEmpty) }
    private func acknowledgeWishEvents(_ events: [ResidentAgentLoop.Event], worldContext: ResidentWorldContext) async throws { precondition(!events.contains { $0.id.hasPrefix("wish.") }) }
    private func synchronizeWishMachinePresentation() {}
    private func wishMachinePromptContext(_ context: ResidentWorldContext) -> String { "" }
    private func reconcileResidentWishPlacements(_ context: ResidentWorldContext) throws {}
    private func isResidentActivityAvailable(_ id: String) -> Bool { true }
    var musicSelectionGeneration: UInt64 = 0
    // Resolve the production method's singleton lookup to the injected real
    // service; the method itself is compiled unchanged, UI/TTS are inert sinks.
    enum AgentConversationService { static var shared: RealConversationService! }
    private var liveCamMessageID: UUID?
    // 原文层已移除：原先这里还桩着 `residentTurnSourceByRunID` /
    // `residentMemoryTurnSlot` / `presentResidentMemoryDeliveryFailure` 与
    // `memoryDeliveryResults`。生产里那一整条链（登记交付凭据 → 显示/语音完成后
    // 确认 → `memory_ingest`）已经删掉，所以这里不再有可桩的东西：
    // "记忆写没写" 这个观测点在生产里已经不存在了。
    private var residentAgentLoop: ResidentAgentLoop?
    // 「未确认送达」界面提示的生命周期策略：生产在 GMGNRadioApp 里就是
    // `private var residentUnconfirmedNotice = ResidentUnconfirmedNoticePolicy()`，
    // 这里保留同名同类型，让抽取出的调用点编译到真实实现上（不是空桩）。
    private var residentUnconfirmedNotice = ResidentUnconfirmedNoticePolicy()
    private var residentChatTranscript = ResidentChatTranscript()
    // 生产把"这一轮为什么被停下"写进真机可查的一行日志（`livingWorldLogger`）；
    // 仿真宿主给同名的真实 Logger，让抽编的那份实现照原样编译并真的写日志。
    private let livingWorldLogger = Logger(subsystem: "ai.gmgn.radio", category: "Harness")
    private var residentTranscriptScopeKey: String { "harness-scope" }
    private func publishResidentTranscript() {}
    private func settleSilentResidentTurnIfNeeded() {}
    private var residentPropEditingWorldID: String?
    private let residentActivityOwnership = ResidentActivityOwnership()
    private var residentActivityOutcome: ResidentActivityOutcome?
    var liveCamWindowController: Surface? = Surface()
    final class StageReply {
        func beginResidentReply() {}
        // 舞台的居民呈现方法现在都带 autoRevealsChat：后台/自驱回合只更新状态，
        // 不替用户展开聊天。签名与默认值同 StageWindowController 现状一致。
        func finishResidentReply(_ text: String, autoRevealsChat: Bool = true) {}
        func showResidentChatStatus(_ text: String, autoRevealsChat: Bool = true) {}
        func showResidentFailureStatus(_ text: String, autoRevealsChat: Bool = false) {}
        func setResidentThinking(_ thinking: Bool, autoRevealsChat: Bool = true) {}
        var residentStatusText: String? { nil }
        var progress: String?
        func setResidentProgress(_ value: String?) { progress = value }
        func setResidentDeliveryNotice(_ notice: String?) {}
        func setResidentCanStop(_ canStop: Bool) {}
        /// 全局开关横幅的宿主推入口（状态收敛）：授权不再由任务行表达，
        /// 所以这两个表面各有一个全局推入口。这里补同名可编译的桩，不假装覆盖其行为。
        func setResidentAutonomyStop(_ stopped: Bool) {}
        func setWishMachineConnectivity(_ text: String?) {}
        func restoreResidentSubmission(_ submission: ResidentChatSubmission, notice: String) {}
    }
    var stageWindowController: StageReply? = StageReply()
    func disconnectRealtimeVoice() { agentSpeechAnnouncer.stop() }
    func showResidentVoiceStatus(_ text: String) {
        liveCamWindowController?.showChatStatus(text)
        stageWindowController?.showResidentChatStatus(text)
    }
    var agentSpeechAnnouncer = Speech()
    struct Stage { var selectedWorldID = "unloaded-world" }
    var spatialStage = Stage()
    var livingWorldContext: WorldAgentContext?
    private func residentPropPlacementService(context:WorldAgentContext,isCurrent:@escaping @MainActor ()->Bool) -> ResidentPropPlacementService {
        ResidentPropPlacementService(context:context,isCurrent:isCurrent)
    }
    private func synchronizeResidentPropPresentation() {}
    // `read_owned_props` 回执里那两句从**唯一投影**现算（生产里是
    // `GMGNRadioApp.residentOwnershipRow`）。这个仿真宿主没有世界文档，
    // 桩成"读不到"（nil ⇒ 回执里不写那两个键），语义与生产的"读不到 ⇒ 不编一句"一致。
    private func residentOwnershipRow(objectID:String,context:WorldAgentContext) -> OwnershipRow? { nil }
    private func prepareResidentPropMutation(_ command:WorldPropLayoutCommand,context:WorldAgentContext) async throws {}
    private func synchronizeOwnedResidentProps() async {}
    private func residentWishPlacementGrant(objectID:String,placement:WorldPropPlacement,worldID:String,residentScope:String) throws -> ResidentPropDelegatedGrant {
        throw WishMachineError.unauthorized
    }
    private func recordResidentWishPlacement(_ grant:ResidentPropDelegatedGrant,placement:WorldPropPlacement,worldID:String,residentScope:String) throws {
        throw WishMachineError.unauthorized
    }
    init(_ service: RealConversationService) {
        AgentConversationService.shared = service
        // Inherits this executable's temporary fixture directory. Never reads
        // Application Support or configures a remote generation service.
        let directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RejectWishNetwork.self]
        let store = fixtureWishStore(directory: directory.appendingPathComponent("core"), session: URLSession(configuration: configuration))
        wishMachineCoordinator = WishMachineCoordinator(store: store, directory: directory.appendingPathComponent("wish"), canClaim: { _ in nil })
    }
    \#(sendMethod)
    \#(submissionSource)
    \#(submissionMethod)
    \#(loopMethods)
    \#(contextMethod)
    \#(toolsMethod)
    // Test-only entry: the production method above is compiled unchanged. This
    // seam only pins liveCamMessageID exactly like performResidentTurn does and
    // returns the real short-lived lease; it adds no production behavior.
    func makeLiveResidentTools(messageID: UUID) -> ResidentConversationTools? {
        liveCamMessageID = messageID
        return makeResidentWorldTools(messageID: messageID)
    }
    func releaseLiveResidentMessage(messageID: UUID) {
        if liveCamMessageID == messageID { liveCamMessageID = nil }
    }
    func currentResidentRunID() -> UUID? { residentAgentLoop?.snapshot.runID }
    private func resumeResidentJukebox(owner: UUID) async throws { fatalError("Use the jukebox outcome suite for playback") }
    private func pauseResidentJukebox(owner: UUID?) async throws { fatalError("Use the jukebox outcome suite for playback") }
    /// 抽编进来的 `makeResidentWorldTools` 把点唱机报告出口接到这个方法上
    /// （生产里是"日志 + 屏上"的唯一漏斗）。本仿真宿主不跑播放，所以这里只记下来：
    /// 与那两行 `resumeResidentJukebox`/`pauseResidentJukebox` 是同一类桩。
    private var jukeboxReports: [JukeboxReport] = []
    private func applyResidentJukeboxReport(_ report: JukeboxReport) { jukeboxReports.append(report) }
    func snapshot(takeoverEnabled: Bool) -> DJAgentRadioState { .init(takeoverEnabled: takeoverEnabled, playbackState: "idle", activeTrackID: nil, activeSlotIndex: nil, program: []) }
    func currentTrackSnapshot() -> DJAgentCurrentTrackSnapshot? { nil }
    func playProgramTrack(trackID: String?, slotIndex: Int?) async throws { fatalError("unexpected playback") }
    func playNextTrack() async throws { fatalError("unexpected playback") }
    func playPreviousTrack() async throws { fatalError("unexpected playback") }
    func pauseMusic() async throws { fatalError("unexpected playback") }
    func resumeMusic() async throws { fatalError("unexpected playback") }
    func replanProgram(immediateInstruction: String?) async throws { fatalError("unexpected replan") }
    func activatePreparedProgram() async throws { fatalError("unexpected playback") }
    func insertTrack(immediateInstruction: String) async throws { fatalError("unexpected insert") }
    func setVisualMood(_ mood: StageVisualMood) async throws { fatalError("unexpected visual") }
    func searchMusic(query: String, limit: Int) async throws -> [DJAgentMusicTrack] { fatalError("unexpected search") }
    func setLyricsMode(_ mode: StageLyricsVisualMode) async throws { fatalError("unexpected visual") }
    func setSpatialEnvironment(scene: SpatialScenePreset?, weather: SpatialWeather?) async throws { fatalError("unexpected world change") }
    func moveSpatialCamera(direction: SpatialCameraCommandDirection, distance: Float) async throws { fatalError("unexpected camera") }
    func enqueue(_ message: String) async { await sendLiveCamMessage(message) }
    func stop() { cancelResidentMessage(userIntent: true) }
    func waitUntilIdle() async {
        for _ in 0..<500_000 {
            if residentAgentLoop?.snapshot.isRunning != true { return }
            await Task.yield()
        }
        fatalError("Resident loop did not become idle")
    }
    func send(_ message: String) async {
        await sendLiveCamMessage(message)
        await waitUntilIdle()
    }
    func sendSubmission(_ message: String) async throws {
        try await sendResidentSubmission(.init(text: message), source: .liveCam)
        await waitUntilIdle()
    }
}

@MainActor var checks = 0
@MainActor var failures = 0
@MainActor func check(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition { failures += 1; print("FAIL: \(message)") }
}
// Deep JSON value comparison: proves the Claude-selected manifest is the same
// value the Codex path assembled, not a re-listed or synthetic copy.
func jsonEqual(_ lhs: Any, _ rhs: Any) -> Bool {
    (lhs as AnyObject).isEqual(rhs)
}
@MainActor func cancelled(_ task: Task<String, Error>) async -> Bool {
    do { _ = try await task.value; return false }
    catch is CancellationError { return true }
    catch AgentConversationError.cancelled { return true }
    catch { return false }
}
@MainActor func fixture(locator: FixtureLocator = FixtureLocator()) -> (RealConversationService, ControlledRunner, UserDefaults, String) {
    let suite = "gmgn-resident-test-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    let runner = ControlledRunner()
    let service = RealConversationService(locator: locator, defaults: defaults, runnerFactory: { _ in runner },
        claudeRunnerFactory: { _, _, _, _ in runner },
        claudeEnvironmentProvider: { configDir in
            // Fixture-only credential: the real whitelist builder runs, but the
            // secret is a literal here so no process environment is read.
            ResidentClaudeEnvironment.make(base: ["ANTHROPIC_API_KEY": "fixture"], configDirectory: configDir)
        })
    service.selectBackend(.codex)
    return (service, runner, defaults, suite)
}

@main struct Tests {
    @MainActor static func main() async throws {
        for mode in ["finish", "cancel", "selected-world", "replaced-context"] {
            let suite = "gmgn-formal-app-test-\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let formal = FormalRunner()
            let textRunner = ControlledRunner()
            let service = RealConversationService(locator: FixtureLocator(), defaults: defaults,
                runnerFactory: { _ in textRunner }, residentSender: { _, prompt, _, tools in
                    try await formal.run(prompt, tools)
                })
            service.selectBackend(.codex)
            let manifest = try JSONDecoder().decode(WorldManifest.self, from: Data(contentsOf:
                URL(fileURLWithPath: "apps/macos/Resources/Worlds/marble-living-cabin/world.json")))
            let context = try WorldAgentContext(manifest: manifest)
            let app = AppHarness(service)
            app.livingWorldContext = context
            app.spatialStage.selectedWorldID = manifest.worldID
            let request = Task {
                if mode == "finish" { try await app.sendSubmission("去做个活动") }
                else { await app.send("去做个活动") }
            }
            await formal.waitForCalls(1)
            let tools = formal.tools[0]
            check(tools.worldID == manifest.worldID, "\(mode): App binds actual world to formal tools")
            let schemas = try JSONSerialization.jsonObject(with: tools.schemasJSON) as! [[String: Any]]
            let names = Set(schemas.compactMap { $0["name"] as? String })
            let previousNames: Set<String> = ["inspect_world", "list_places", "list_available_activities", "plan_route", "move_to",
                "start_activity", "stop_activity", "look_at",
                "read_resident_state", "update_resident_intent", "read_radio_state", "read_current_track",
                "list_music_playlists", "read_music_playlist", "prepare_music_track"]
            let wishNames: Set<String> = ["submit_wish_generation", "read_wish_generation", "read_wish_machine_contract", "retry_wish_generation", "cancel_wish_generation", "claim_wish_output", "resume_wish_continuation"]
            let referenceNames: Set<String> = ["search_wish_reference_images", "register_wish_reference_image"]
            let propNames: Set<String> = ["read_owned_props", "list_placement_surfaces", "preview_prop_placement", "apply_prop_placement", "withdraw_prop", "undo_prop_placement",
                "hold_prop", "adjust_held_prop_grip", "return_held_prop", "enable_prop_capability",
                // 2026-10-01 22:16 落的 `delete_prop`（WorldRuntime 的 `WorldPropDeletion`）：
                // 仿真宿主**原文抽编** `makeResidentWorldTools`，所以 App 一多一条工具，
                // 这里的名单与总数就必须跟着走 —— 否则门禁红在一个与断言无关的数字上。
                "delete_prop"]
            check(previousNames.isSubset(of: names), "\(mode): App retains eight world, two loop and five music tools")
            check(names == previousNames.union(wishNames).union(referenceNames).union(propNames) && schemas.count == 35, "\(mode): App exposes seven wish (six actions + one read-only parameter interface), two reference and eleven owned-prop tools")
            check(formal.prompts[0].contains("这是居民生活循环的一轮"), "\(mode): actual App supplies generic loop instructions")
            let observed = await tools.call("loop-read", "read_resident_state", Data("{}".utf8))
            check(!observed.isError && !tools.allowsSilentCompletion(), "\(mode): reading state alone does not authorize silent completion")
            let planned = await tools.call("loop-intent", "update_resident_intent",
                Data(#"{"summary":"保留当前委托，等待下一条引导","status":"waiting_user"}"#.utf8))
            check(!planned.isError && tools.allowsSilentCompletion(), "\(mode): actual App loop tool records intent for this turn")
            let started = await tools.call("start", "start_activity", Data(#"{"activity_id":"home.idle"}"#.utf8))
            check(!started.isError && context.state.activeActivity?.activityID == "home.idle", "\(mode): actual App-to-service callback starts real activity")
            let stopped = await tools.call("stop", "stop_activity", Data("{}".utf8))
            check(!stopped.isError && context.state.activeActivity == nil, "\(mode): actual callback stops activity")
            switch mode {
            case "cancel": app.stop()
            case "selected-world": app.spatialStage.selectedWorldID = "other-world"
            case "replaced-context": app.livingWorldContext = try WorldAgentContext(manifest: manifest)
            default: break
            }
            if mode != "finish" {
                let stale = await tools.call("stale", "start_activity", Data(#"{"activity_id":"home.idle"}"#.utf8))
                check(stale.isError && context.state.activeActivity == nil, "\(mode): old App lease rejects mutations immediately")
            }
            formal.finish(0)
            try await request.value
            let after = await tools.call("after", "start_activity", Data(#"{"activity_id":"home.idle"}"#.utf8))
            check(after.isError && context.state.activeActivity == nil, "\(mode): completed request releases formal capability lease")
            let latePlan = await tools.call("late-plan", "update_resident_intent", Data(#"{"summary":"迟到的修改","status":"active"}"#.utf8))
            check(latePlan.isError && !tools.allowsSilentCompletion(), "\(mode): ended or stopped turn cannot mutate intent")
            check(app.liveCamWindowController?.waiting == false, "\(mode): request always ends waiting bubble")
            check(app.liveCamWindowController?.replies == (mode == "finish" ? ["formal reply"] : []),
                  "\(mode): only current world receives formal reply")
            app.agentSpeechAnnouncer.complete(.finished)
            check(app.agentSpeechAnnouncer.spoken == (mode == "finish" ? ["formal reply"] : []),
                  "\(mode): only current successfully delivered reply reaches speech")
        }
        // Use the shipping manifest and actual WorldAgentContext, with only the
        // external CLI process mocked. No real backend or saved world is read.
        do {
            let (service, runner, defaults, suite) = fixture()
            defer { defaults.removePersistentDomain(forName: suite) }
            service.preferenceStore.saveSessionID("personal-session", for: .codex)
            let manifestData = try Data(contentsOf: URL(fileURLWithPath:
                "apps/macos/Resources/Worlds/marble-living-cabin/world.json"))
            let manifest = try JSONDecoder().decode(WorldManifest.self, from: manifestData)
            let context = try WorldAgentContext(manifest: manifest)
            let app = AppHarness(service)
            app.livingWorldContext = context
            app.spatialStage.selectedWorldID = manifest.worldID
            let first = Task { await app.send("你在什么地方，能做什么？") }
            await runner.waitForCalls(1)
            let firstCall = await runner.calls[0]
            let input = firstCall.input ?? firstCall.arguments.joined(separator: " ")
            check(input.contains(manifest.worldID), "current world ID reaches actual model input")
            check(input.contains("residentPosition"), "resident position reaches model input")
            check(input.contains("prop.jukebox") && input.contains("点唱机"), "declared jukebox has public identity")
            check(input.contains("music.listen") && input.contains("availableActivities"), "declared activities reach model input")
            check(input.contains("只读") && input.contains("不能声称"), "text backend explicitly cannot claim execution")
            check(input.contains("未知"), "absent object runtime position remains unknown")
            check(!input.contains(".glb") && !input.contains("/Users/") && !input.contains("resources"), "resource and private paths are not context")
            check(!firstCall.arguments.contains("personal-session"), "room does not resume personal chat session")
            if input.contains("空间资料：\n") {
                let payload = try worldPayload(input)
                let props = payload["objects"] as? [[String: Any]] ?? []
                check((payload["residentPosition"] as? [NSNumber])?.map(\.floatValue) == [context.state.agentTransform.position.x,
                    context.state.agentTransform.position.y, context.state.agentTransform.position.z], "resident position is actual runtime position")
                check(props.first?["position"] == nil && props.first?["isEnabled"] == nil, "unavailable object state is not fabricated from activity anchor")
                check(props.first?["activityIDs"] as? [String] == ["music.listen"], "object links to its declared activity")
            }
            await runner.finish(0, session: "cabin-session")
            await first.value
            check(service.preferenceStore.sessionID(for: .codex) == "personal-session", "room session does not replace personal chat session")

            try context.startActivity(id: "home.idle")
            let next = Task { await app.send("现在在做什么？") }
            await runner.waitForCalls(2)
            let secondCall = await runner.calls[1]
            check(secondCall.arguments.contains("cabin-session"), "same room resumes resident session")
            check(secondCall.input != firstCall.input && secondCall.input?.contains("activeActivity") == true,
                  "next turn gets updated live activity snapshot")
            if let prompt = secondCall.input, prompt.contains("空间资料：\n") {
                check(try worldPayload(prompt)["activeActivity"] as? String == "home.idle", "current activity value comes from executor snapshot")
            }
            await runner.finish(1, session: "cabin-session")
            await next.value

            // Selection can change before the old context has been replaced.
            app.spatialStage.selectedWorldID = "other-room"
            let switched = Task { await app.send("看看新房间") }
            await runner.waitForCalls(3)
            let switchedCall = await runner.calls[2]
            check(!switchedCall.arguments.contains("cabin-session"), "world mismatch never resumes old room session")
            check(switchedCall.input?.contains("prop.jukebox") != true && switchedCall.input?.contains("music.listen") != true,
                  "world mismatch does not expose old facilities")
            check(switchedCall.input?.contains("未知") == true, "unloaded world is explicitly unknown")
            await runner.finish(2, session: "unavailable-session")
            await switched.value

            app.spatialStage.selectedWorldID = manifest.worldID
            let delayed = Task { await app.send("旧空间的回答") }
            await runner.waitForCalls(4)
            let replies = app.liveCamWindowController?.replies
            let speech = app.agentSpeechAnnouncer.spoken
            app.spatialStage.selectedWorldID = "other-room"
            await runner.finish(3, reply: "old-room-reply")
            await delayed.value
            check(app.liveCamWindowController?.replies == replies, "world switch suppresses delayed room reply")
            check(app.agentSpeechAnnouncer.spoken == speech, "world switch suppresses delayed room speech")

            var state = WorldSimulation(manifest: manifest, startedAt: Date()).state
            state.objectStates["prop.jukebox"] = WorldObjectState(isEnabled: false,
                transform: WorldTransform(position: WorldVector3(x: 2, y: 3, z: 4),
                    rotation: manifest.spawn.rotation, scale: manifest.spawn.scale),
                metadata: ["apiKey": "DO-NOT-SEND-SECRET", "resource": "/private/test.glb"])
            state.objectStates["unpublished-object"] = WorldObjectState(transform: manifest.spawn)
            app.livingWorldContext = try WorldAgentContext(manifest: manifest, persistence: FixtureWorldState(state: state))
            app.spatialStage.selectedWorldID = manifest.worldID
            let restored = Task { await app.send("检查物件") }
            await runner.waitForCalls(5)
            let restoredInput = await runner.calls[4].input ?? ""
            check(!restoredInput.contains("DO-NOT-SEND-SECRET") && !restoredInput.contains("/private/") && !restoredInput.contains("unpublished-object"), "only declared public object state crosses prompt boundary")
            if restoredInput.contains("空间资料：\n") {
                let props = try worldPayload(restoredInput)["objects"] as! [[String: Any]]
                check(props[0]["position"] as? [Int] == [2, 3, 4] && props[0]["isEnabled"] as? Bool == false,
                      "known object position and enabled status are preserved")
            }
            await runner.finish(4)
            await restored.value
        }
        for backend in AgentConversationBackendID.allCases {
            let (service, runner, defaults, suite) = fixture()
            defer { defaults.removePersistentDomain(forName: suite) }
            service.selectBackend(backend)
            service.preferenceStore.saveSessionID("personal-session", for: backend)
            let roomA = ResidentWorldContext.unavailable(selectedWorldID: "room-A")
            let roomB = ResidentWorldContext.unavailable(selectedWorldID: "room-B")
            let first = Task { try await service.send("only-room-A-history", worldContext: roomA) }
            await runner.waitForCalls(1)
            check(await !runner.calls[0].arguments.contains("personal-session"), "\(backend): room starts outside personal session")
            await runner.finish(0, session: "room-A-session", backend: backend)
            _ = try await first.value
            let second = Task { try await service.send("same-room", worldContext: roomA) }
            await runner.waitForCalls(2)
            let sameArguments = await runner.calls[1].arguments
            let sameInput = await runner.calls[1].input
            let continues: Bool
            switch backend {
            case .dsh:
                continues = sameArguments.last?.contains("only-room-A-history") == true
            case .claudeCode:
                // Claude Code has no native resume: same-room continuity must come
                // from the bounded in-memory history replayed on stdin, and argv
                // must never carry --resume or the previous session id.
                continues = sameInput?.contains("only-room-A-history") == true
                    && !sameArguments.contains("--resume")
                    && !sameArguments.contains("room-A-session")
            default:
                continues = sameArguments.contains("room-A-session")
            }
            check(continues, "\(backend): room session continues")
            await runner.finish(1, session: "room-A-session", backend: backend)
            _ = try await second.value
            let third = Task { try await service.send("other-room", history: [.init(role: .user, text: "unsafe-external-history")], worldContext: roomB) }
            await runner.waitForCalls(3)
            let otherArguments = await runner.calls[2].arguments
            check(!otherArguments.contains("room-A-session") && !otherArguments.joined().contains("only-room-A-history") && !otherArguments.joined().contains("unsafe-external-history"), "\(backend): other room never inherits history")
            await runner.finish(2, session: "room-B-session", backend: backend)
            _ = try await third.value
            service.resetSession()
            check(service.preferenceStore.sessionID(for: backend) == "personal-session", "\(backend): resetting room preserves personal session")
            let reset = Task { try await service.send("reset-room", worldContext: roomB) }
            await runner.waitForCalls(4)
            check(await !runner.calls[3].arguments.contains("room-B-session"), "\(backend): reset starts fresh room session")
            await runner.finish(3, backend: backend)
            _ = try await reset.value
        }
        for backend in AgentConversationBackendID.allCases {
            let (service, runner, defaults, suite) = fixture()
            defer { defaults.removePersistentDomain(forName: suite) }
            service.selectBackend(backend)
            let first = Task { try await service.send("my-name-is-resident") }
            await runner.waitForCalls(1)
            await runner.finish(0, reply: "remembered", backend: backend)
            check(try await first.value == "remembered", "\(backend): first turn parses provider output")
            let second = Task { try await service.send("what-is-my-name") }
            await runner.waitForCalls(2)
            let arguments = await runner.calls[1].arguments
            let secondInput = await runner.calls[1].input
            let retains: Bool
            switch backend {
            case .dsh:
                retains = arguments.last?.contains("my-name-is-resident") == true
            case .claudeCode:
                // Claude context lives only in the bounded stdin history; argv is
                // always a fresh session with no --resume or session id.
                retains = secondInput?.contains("my-name-is-resident") == true
                    && !arguments.contains("--resume")
                    && !arguments.contains("resident")
            default:
                retains = arguments.contains("resident")
            }
            check(retains, "\(backend): second turn retains context")
            await runner.finish(1, backend: backend)
            _ = try await second.value
            service.resetSession()
            let third = Task { try await service.send("fresh") }
            await runner.waitForCalls(3)
            let freshArguments = await runner.calls[2].arguments
            let freshInput = await runner.calls[2].input
            // Reset must clear the argv session id and, for Claude, the stdin history.
            check(!freshArguments.contains("resident")
                  && freshArguments.last?.contains("my-name-is-resident") != true
                  && (backend != .claudeCode || freshInput?.contains("my-name-is-resident") != true),
                  "\(backend): reset clears context")
            await runner.finish(2, backend: backend)
            _ = try await third.value
        }
        // Successful turns retain the provider session; failure cannot replace it.
        do {
            let (service, runner, defaults, suite) = fixture()
            defer { defaults.removePersistentDomain(forName: suite) }
            let first = Task { try await service.send("first") }
            await runner.waitForCalls(1)
            await runner.finish(0)
            check(try await first.value == "hello", "first turn returns parsed process output")
            let second = Task { try await service.send("second") }
            await runner.waitForCalls(2)
            check(await runner.calls[1].arguments.contains("resident"), "second turn resumes the same session")
            await runner.finish(1, session: "bad", exit: 1)
            do { _ = try await second.value; check(false, "failed process must throw") } catch { check(true, "failed process surfaced") }
            check(service.preferenceStore.sessionID(for: .codex) == "resident", "failure keeps last valid session")
            let third = Task { try await service.send("retry") }
            await runner.waitForCalls(3)
            check(await runner.calls[2].arguments.contains("resident"), "retry resumes last successful session")
            await runner.finish(2, reply: "recovered")
            check(try await third.value == "recovered", "failure permits next request")
        }
        for action in ["cancel", "reset", "switch", "supersede", "caller-cancel"] {
            let (service, runner, defaults, suite) = fixture()
            defer { defaults.removePersistentDomain(forName: suite) }
            let old = Task { try await service.send("old") }
            await runner.waitForCalls(1)
            switch action {
            case "cancel": service.cancel()
            case "reset": service.resetSession()
            case "switch": service.selectBackend(.dsh); service.selectBackend(.codex)
            case "caller-cancel": old.cancel()
            default: break
            }
            let current = Task { try await service.send("new") }
            await runner.waitForCalls(2)
            await runner.finish(1, session: "new-session", reply: "new-reply")
            check(try await current.value == "new-reply", "\(action): new request succeeds")
            await runner.finish(0, session: "stale-session", reply: "stale-reply")
            check(await cancelled(old), "\(action): delayed reply is cancelled")
            check(service.preferenceStore.sessionID(for: .codex) == "new-session", "\(action): stale reply cannot overwrite session")
        }
        for callerCancellation in [false, true] {
            let (service, runner, defaults, suite) = fixture()
            defer { defaults.removePersistentDomain(forName: suite) }
            let request = Task { try await service.send("cancel-without-new-request") }
            await runner.waitForCalls(1)
            if callerCancellation { request.cancel() } else { service.cancel() }
            await runner.finish(0)
            check(await cancelled(request), "cancel without superseding request discards result")
            check(service.preferenceStore.sessionID(for: .codex) == nil, "cancel cannot create a session")
        }
        do {
            let (service, runner, defaults, suite) = fixture()
            defer { defaults.removePersistentDomain(forName: suite) }
            service.selectBackend(.dsh)
            let old = Task { try await service.send("discard-this-history") }
            await runner.waitForCalls(1)
            service.resetSession()
            await runner.finish(0, backend: .dsh)
            check(await cancelled(old), "DSH reset discards delayed output")
            let current = Task { try await service.send("new-history") }
            await runner.waitForCalls(2)
            check(await runner.calls[1].arguments.last?.contains("discard-this-history") != true, "DSH reset cannot restore stale history")
            await runner.finish(1, backend: .dsh)
            _ = try await current.value
        }
        // Old cleanup must not remove the new request's cancellation handle.
        do {
            let (service, runner, defaults, suite) = fixture()
            defer { defaults.removePersistentDomain(forName: suite) }
            let old = Task { try await service.send("old") }
            await runner.waitForCalls(1)
            let current = Task { try await service.send("new") }
            await runner.waitForCalls(2)
            await runner.finish(0)
            _ = await cancelled(old)
            service.cancel()
            await runner.finish(1)
            check(await cancelled(current), "old cleanup cannot detach current request cancellation")
        }
        // Late errors and replies cannot overwrite the visible reply or trigger TTS.
        for staleExit: Int32 in [0, 1] {
            let (service, runner, defaults, suite) = fixture()
            defer { defaults.removePersistentDomain(forName: suite) }
            let app = AppHarness(service)
            let old = Task { await app.send("old") }
            await runner.waitForCalls(1)
            app.stop()
            let current = Task { await app.send("new") }
            await runner.waitForCalls(2)
            await runner.finish(1, session: "new", reply: "current")
            await current.value
            await runner.finish(0, reply: "stale", exit: staleExit)
            await old.value
            check(app.liveCamWindowController?.replies == ["current"], "UI never publishes a stale reply")
            // 长期记忆决定不做之后，这里不再有任何"非错误的合法提示"需要排除
            // —— 可见状态槽必须干干净净。
            check(app.liveCamWindowController?.statuses == [], "UI never publishes a stale error")
            check(app.agentSpeechAnnouncer.spoken == ["current"], "TTS never announces stale output")
        }
        for staleExit: Int32 in [0, 1] {
            let locator = FixtureLocator()
            let (service, runner, defaults, suite) = fixture(locator: locator)
            defer { defaults.removePersistentDomain(forName: suite) }
            let app = AppHarness(service)
            let old = Task { await app.send("old") }
            await runner.waitForCalls(1)
            app.stop()
            locator.setAvailable(false)
            await app.send("provider-disappeared")
            // 生产现在会在没有可用后端时先由 refreshResidentBackendGuidance 发布
            // 「未安装后端」的设置指引（同属 failure 类别），真实预检失败随后按
            // ResidentStatusNoticeMerge 的 (.failure, .failure) 规则覆盖它：发布日志
            // 因此会多出一条，可见槽里只剩预检失败。断言直接看可见提示本身，
            // 既不放过「指引冒充失败」，也不因为中间那条指引而误报。
            // 2026-10-02 文案规则：预检失败那句是「<名字> 还没安装，请打开…装一个。」，
            // 设置指引那句是「还没有可用的对话模型，请打开…装一个。」——「还没安装」
            // 只出现在预检失败里，所以它仍然能把两者分开。
            let failureNotice = app.liveCamWindowController?.residentStatusText
            check(failureNotice?.contains("还没安装") == true, "new preflight failure is visible")
            await runner.finish(0, session: "stale-session", reply: "stale-reply", exit: staleExit)
            await old.value
            check(app.liveCamWindowController?.residentStatusText == failureNotice, "old failure cannot replace newer preflight error")
            check(app.liveCamWindowController?.replies.isEmpty == true, "old success cannot replace newer preflight error")
            check(app.agentSpeechAnnouncer.spoken.isEmpty, "old success after preflight failure cannot trigger TTS")
            check(service.preferenceStore.sessionID(for: .codex) == nil, "preflight failure cancels old session persistence")
        }
        for action in ["cancel", "reset", "switch", "stop-button"] {
            let (service, runner, defaults, suite) = fixture()
            defer { defaults.removePersistentDomain(forName: suite) }
            let app = AppHarness(service)
            let request = Task { await app.send("waiting") }
            await runner.waitForCalls(1)
            check(app.liveCamWindowController?.waiting == true, "\(action): actual begin shows waiting")
            app.stop()
            switch action {
            case "reset": service.resetSession()
            case "switch": service.selectBackend(.dsh)
            default: break
            }
            check(app.liveCamWindowController?.waiting == false, "\(action): cancellation immediately ends waiting before process exits")
            await runner.finish(0)
            await request.value
            check(app.liveCamWindowController?.replies.isEmpty == true, "\(action): cancelled request never finishes a reply")
        }
        do {
            let (service, runner, defaults, suite) = fixture()
            defer { defaults.removePersistentDomain(forName: suite) }
            let app = AppHarness(service)
            let old = Task { await app.send("old") }
            await runner.waitForCalls(1)
            await app.enqueue("current")
            for _ in 0..<100 { await Task.yield() }
            check(await runner.calls.count == 1, "unsupported steering queues guidance without cancelling active request")
            check(app.liveCamWindowController?.waiting == true, "queued guidance retains current thinking state")
            await runner.finish(0, session: "continued", reply: "first reply")
            await runner.waitForCalls(2)
            check(await runner.calls[1].arguments.contains("continued"), "queued guidance resumes completed session")
            check(app.liveCamWindowController?.waiting == true, "next queued turn remains visibly thinking")
            await runner.finish(1, reply: "current")
            await old.value
            check(app.liveCamWindowController?.waiting == false, "actual finish ends waiting")
            check(app.liveCamWindowController?.replies == ["first reply", "current"], "both serial turns publish their own completed reply")
        }
        do {
            let (service, runner, defaults, suite) = fixture()
            defer { defaults.removePersistentDomain(forName: suite) }
            let app = AppHarness(service)
            let failed = Task { await app.send("failure") }
            await runner.waitForCalls(1)
            await runner.finish(0, exit: 1)
            await failed.value
            check(app.liveCamWindowController?.statuses.count == 1, "current failure is visible")
            check(app.liveCamWindowController?.replies.isEmpty == true, "current failure cannot appear as a reply")
            check(app.agentSpeechAnnouncer.spoken.isEmpty, "current failure cannot trigger TTS")
            let retry = Task { await app.send("retry") }
            await runner.waitForCalls(2)
            await runner.finish(1, reply: "recovered")
            await retry.value
            check(app.liveCamWindowController?.replies == ["recovered"], "UI accepts reply after failure")
        }
        // Integration regression: selecting the real .claudeCode backend must not
        // change the production world-tool manifest or the per-turn authority that
        // App.makeResidentWorldTools assembles. Only the CLI process boundary is
        // stubbed; no Claude/DSH process, MCP host, UDS, UI, Keychain, window, GPU
        // or network runs, and no static tool list is asserted against.
        do {
            let suite = "gmgn-resident-claude-world-tools-\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let codexRunner = ControlledRunner()
            let claudeRunner = ControlledRunner()
            let service = RealConversationService(locator: FixtureLocator(), defaults: defaults,
                runnerFactory: { _ in codexRunner },
                residentSender: { _, _, _, _ in
                    AgentConversationOutcome(reply: "unused", sessionID: nil)
                },
                claudeRunnerFactory: { _, _, _, _ in claudeRunner },
                claudeEnvironmentProvider: { _ in ["ANTHROPIC_API_KEY": "fixture"] })
            service.selectBackend(.codex)
            let manifest = try JSONDecoder().decode(WorldManifest.self, from: Data(contentsOf:
                URL(fileURLWithPath: "apps/macos/Resources/Worlds/marble-living-cabin/world.json")))
            let context = try WorldAgentContext(manifest: manifest)
            let app = AppHarness(service)
            app.livingWorldContext = context
            app.spatialStage.selectedWorldID = manifest.worldID
            check(service.supportsWorldTools, "codex: production capability wires world tools")

            // Capture the actual manifest the real Codex selection assembles.
            let codexMessageID = UUID()
            let codexTools = app.makeLiveResidentTools(messageID: codexMessageID)
            check(codexTools != nil, "codex: real App.makeResidentWorldTools returns a lease")
            let codexSchemas: [[String: Any]] = codexTools.flatMap {
                try? JSONSerialization.jsonObject(with: $0.schemasJSON) as? [[String: Any]]
            } ?? []
            check(codexSchemas.count == 35, "codex: actual App manifest exposes all 35 production schemas")
            check(codexTools?.visionCapable == false
                  && !codexSchemas.contains { ($0["name"] as? String) == "capture_space_photo" },
                  "codex: absent GPU vision surface registers no capture schema")
            codexTools?.cancel()
            app.releaseLiveResidentMessage(messageID: codexMessageID)

            // Same real App assembly, now with the production Claude branch selected.
            service.selectBackend(.claudeCode)
            check(service.supportsWorldTools, "claudeCode: production capability wires world tools")

            // Start a real Claude-selected resident run with world tools suppressed
            // (selected world temporarily mismatched) so the turn suspends on the
            // stubbed CLI boundary without starting the MCP host/UDS or any process.
            // The real lease is then assembled against that live run.
            app.spatialStage.selectedWorldID = "claude-lease-probe-world"
            await app.enqueue("claude lease probe")
            await claudeRunner.waitForCalls(1)
            app.spatialStage.selectedWorldID = manifest.worldID
            let runID = app.currentResidentRunID()
            check(runID != nil, "claudeCode: a real resident run is active")
            let claudeTools = runID.flatMap { app.makeLiveResidentTools(messageID: $0) }
            check(claudeTools != nil, "claudeCode: real App.makeResidentWorldTools returns a lease")
            let claudeSchemas: [[String: Any]] = claudeTools.flatMap {
                try? JSONSerialization.jsonObject(with: $0.schemasJSON) as? [[String: Any]]
            } ?? []
            check(claudeSchemas.count == 35, "claudeCode: actual App manifest exposes the same 35 production schemas")
            check((codexSchemas as NSArray).isEqual(claudeSchemas as NSArray),
                  "claudeCode: actual manifest equals codex manifest as a whole JSON value")
            var fieldsMatch = codexSchemas.count == claudeSchemas.count
            if fieldsMatch {
                for (codex, claude) in zip(codexSchemas, claudeSchemas) {
                    fieldsMatch = (codex["name"] as? String) == (claude["name"] as? String)
                        && (codex["description"] as? String) == (claude["description"] as? String)
                        && jsonEqual(codex["inputSchema"] ?? [:], claude["inputSchema"] ?? [:])
                    if !fieldsMatch { break }
                }
            }
            check(fieldsMatch, "claudeCode: every schema name/description/inputSchema matches codex field-for-field")
            check(claudeTools?.worldID == manifest.worldID, "claudeCode: lease binds the real selected world")

            if let claudeTools {
                let observed = await claudeTools.call("claude-read", "read_resident_state", Data("{}".utf8))
                check(!observed.isError, "claudeCode: real App lease reads resident state")
                let started = await claudeTools.call("claude-start", "start_activity", Data(#"{"activity_id":"home.idle"}"#.utf8))
                check(!started.isError && context.state.activeActivity?.activityID == "home.idle",
                      "claudeCode: real App-to-service callback starts activity")
                let stopped = await claudeTools.call("claude-stop", "stop_activity", Data("{}".utf8))
                check(!stopped.isError && context.state.activeActivity == nil,
                      "claudeCode: real callback stops activity")
                claudeTools.cancel()
                let afterCancel = await claudeTools.call("claude-cancelled", "start_activity", Data(#"{"activity_id":"home.idle"}"#.utf8))
                check(afterCancel.isError && context.state.activeActivity == nil,
                      "claudeCode: cancelled lease rejects mutations")
            }

            // A fresh Claude-selected lease over the same live run is current until
            // the selected world moves; then it must reject mutations.
            let switchedTools = runID.flatMap { app.makeLiveResidentTools(messageID: $0) }
            check(switchedTools != nil, "claudeCode: a fresh real lease assembles")
            if let switchedTools {
                let live = await switchedTools.call("claude-live", "read_resident_state", Data("{}".utf8))
                check(!live.isError, "claudeCode: fresh lease is current in the selected world")
                app.spatialStage.selectedWorldID = "other-world"
                let stale = await switchedTools.call("claude-stale", "start_activity", Data(#"{"activity_id":"home.idle"}"#.utf8))
                check(stale.isError && context.state.activeActivity == nil,
                      "claudeCode: old lease rejects mutations after the selected world changes")
            }

            // Let the suspended pure-chat turn finish; nothing external ever ran.
            await claudeRunner.finish(0, session: "claude-lease-session", reply: "probe reply", backend: .claudeCode)
            await app.waitUntilIdle()

            // Only Codex/Claude/DSH carry world tools; the remaining backends stay off.
            for backend in [AgentConversationBackendID.workbuddy, .qoder, .pi] {
                service.selectBackend(backend)
                check(!service.supportsWorldTools, "\(backend): production capability keeps world tools off")
                let messageID = UUID()
                let unsupportedTools = app.makeLiveResidentTools(messageID: messageID)
                check(unsupportedTools == nil, "\(backend): real App exposes no world-tool lease")
                app.releaseLiveResidentMessage(messageID: messageID)
            }
        }
        print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) resident conversation checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#

let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-resident-loop-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let program = temporary.appendingPathComponent("ResidentLoop.swift")
try harness.write(to: program, atomically: true, encoding: .utf8)
let executable = temporary.appendingPathComponent("resident-loop")
func run(_ binary: String, _ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}
// WorldRuntime 的模块搜索路径 + 目标文件**只有一处定义**：tools/world-runtime-harness-flags.sh。
// 不要在这里拼 `.build/...`：27 份各自拼写正是 SwiftPM 与 xcodebuild 两份模块并存的根因。
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
let worldRuntimeFlags = worldRuntimeHarnessFlags()
let worldRuntimeObjects = URL(fileURLWithPath: worldRuntimeFlags[1])
    .deletingLastPathComponent().appendingPathComponent("WorldRuntime.build")
let compilerArguments: [String] = ["-j1", "-parse-as-library",
    "-I", worldRuntimeFlags[1],
    sources.appendingPathComponent("Agent/CodexCLI.swift").path,
    sources.appendingPathComponent("Agent/AgentConversationService.swift").path,
    sources.appendingPathComponent("Agent/ResidentDSHAgentToolBridge.swift").path,
    sources.appendingPathComponent("Agent/ResidentDSHHostToolsBridge.swift").path,
    // 退避/重试预算的**唯一**定义（六处读它）—— 编它，不另抄一套常量。
    sources.appendingPathComponent("Presence/RetryBackoff.swift").path,
    sources.appendingPathComponent("Agent/ResidentClaudeToolBridge.swift").path,
    sources.appendingPathComponent("Agent/ResidentClaudeProcessRunner.swift").path,
    sources.appendingPathComponent("Agent/ResidentDSHTransport.swift").path,
    sources.appendingPathComponent("Agent/ResidentDSHConfiguration.swift").path,
    sources.appendingPathComponent("Agent/WorldAgentContext.swift").path,
    sources.appendingPathComponent("Agent/WorldAgentToolContract.swift").path,
    sources.appendingPathComponent("Agent/WorldAgentToolDispatcher.swift").path,
    sources.appendingPathComponent("Agent/ResidentWorldToolSession.swift").path,
    sources.appendingPathComponent("Agent/ResidentActivityOutcome.swift").path,
    sources.appendingPathComponent("Agent/ResidentCodexPolicy.swift").path,
    sources.appendingPathComponent("Agent/ResidentCodexTransport.swift").path,
    sources.appendingPathComponent("Agent/ResidentCodexAgent.swift").path,
    sources.appendingPathComponent("Agent/ResidentSteeringDelivery.swift").path,
    sources.appendingPathComponent("Agent/ResidentAgentLoop.swift").path,
    sources.appendingPathComponent("Agent/ResidentMemoryStore.swift").path,
    sources.appendingPathComponent("Agent/ResidentStateClient.swift").path,
    sources.appendingPathComponent("Agent/ResidentMemoryClient.swift").path,
    sources.appendingPathComponent("Agent/ResidentConversationMemory.swift").path,
    sources.appendingPathComponent("Presence/ResidentVisionCapture.swift").path,
    sources.appendingPathComponent("Agent/ResidentVisionTools.swift").path,
    sources.appendingPathComponent("Agent/ResidentVisionImageBox.swift").path,
    sources.appendingPathComponent("Agent/ResidentLoopTools.swift").path,
    sources.appendingPathComponent("Agent/ResidentActivityOwnership.swift").path,
    sources.appendingPathComponent("Agent/DJAgentToolDispatcher.swift").path,
    sources.appendingPathComponent("Agent/ResidentMusicToolBridge.swift").path,
    sources.appendingPathComponent("Presence/ResidentPropPlacementService.swift").path,
    // 挂点（slot）：`ResidentPropPlacementService` 与 `ResidentPropToolBridge` 的签名/回执读
    // `PropAttachmentPoint` 与 `PropAttachmentSlots`。挂点表的**真定义**在
    // `Presence/PropAttachmentSlot.swift`（别名表、显示名、净空文案都要真的一份，回执断言才
    // 不是测替身），它要 `PropGripInference`；`PropAttachmentPoint` 的真定义在依赖渲染侧类型的
    // `PropAttachment.swift` 里，离线编不动 ⇒ 类型用 `tools/fixtures/PropAttachmentPointShim.swift`
    // （只有三个 case，数值/骨名一条都不在它里面，那些由 tools/test-resident-prop-hold.swift 钉）。
    sources.appendingPathComponent("Presence/PropGripInference.swift").path,
    sources.appendingPathComponent("Presence/PropAttachmentSlot.swift").path,
    root.appendingPathComponent("tools/fixtures/PropAttachmentPointShim.swift").path,
    sources.appendingPathComponent("Agent/ResidentPropToolBridge.swift").path,
    sources.appendingPathComponent("Presence/PropGenerationClient.swift").path,
    // 抽编进来的 `makeResidentWorldTools` 会读 `wishMachineConfiguration`，所以它那份
    // 生产类型也必须一起编（编同一份，不是另写一个同名结构）。
    sources.appendingPathComponent("Presence/PropGenerationConfiguration.swift").path,
    sources.appendingPathComponent("Presence/PropGenerationStore.swift").path,
    sources.appendingPathComponent("Presence/PropTaskDaemonClient.swift").path,
    root.appendingPathComponent("tools/fixtures/WishMachineDaemonFixture.swift").path,
    sources.appendingPathComponent("Presence/PropImagePreparation.swift").path,
    sources.appendingPathComponent("Presence/WishMachineOutputDescriptor.swift").path,
    // 连通性词汇只有**一份**：coordinator 的 `isNetworkClassSubmissionError` 现在委托给
    // `ResidentConnectivityFact`，所以那份生产文件必须一起编进来（编同一份，不是抄一份）。
    sources.appendingPathComponent("Presence/WishMachineTaskPresentation.swift").path,
    // 状态文案也只有**一份**：任务行那一句与 `read_owned_props` 回执都委托给唯一投影
    // `ResidentOwnershipProjection`，所以那一份生产源码也必须一起编（编同一份）。
    sources.appendingPathComponent("Presence/ResidentOwnershipProjection.swift").path,
    sources.appendingPathComponent("Presence/WishMachineCoordinator.swift").path,
    sources.appendingPathComponent("Agent/WishMachineContract.swift").path,
    sources.appendingPathComponent("Agent/ResidentWishMachineTools.swift").path,
    sources.appendingPathComponent("Agent/ResidentWishReferenceTools.swift").path,
    // 参考图工具链的具名诊断（`WishReferenceDiagnosis` / `WishReferenceLog` /
    // `WishReferenceAvailabilityNotice`）住在自己那份生产文件里；上面那个工具文件
    // 引用它，所以这里必须**编同一份**，否则整个 harness 编译不过（编同一份，不是抄一份）。
    sources.appendingPathComponent("Agent/ResidentWishReferenceDiagnosis.swift").path,
    // `ResidentPropPlacementService` 的手持上限读 `ResidentPropAttachmentEligibility`，
    // 而 `PropAttachment.swift` 依赖 app 目标的渲染侧类型、编不进离线 harness。
    // 共用那一份替身（它从生产源码取那一行，本身不含数字），上限仍然只有一处定义。
    root.appendingPathComponent("tools/fixtures/ResidentPropHoldLimitShim.swift").path,
    program.path, "-o", executable.path]
let runtimeObjects = try FileManager.default.contentsOfDirectory(
        at: worldRuntimeObjects,
        includingPropertiesForKeys: nil).filter { $0.pathExtension == "o" }.map(\.path)
let compiled = try run("/usr/bin/swiftc", compilerArguments + runtimeObjects)
guard compiled == 0 else { exit(compiled) }
exit(try run(executable.path, []))

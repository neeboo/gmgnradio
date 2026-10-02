// Runs extracted production App methods against local state fixtures, without the app host.
import Foundation
let source = try String(contentsOfFile: "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift", encoding: .utf8)
func declaration(_ name: String) -> String {
    let start = source.range(of: name)!.lowerBound
    let open = source[start...].firstIndex(of: "{")!
    var depth = 0
    for index in source[open...].indices {
        if source[index] == "{" { depth += 1 }
        if source[index] == "}" { depth -= 1 }
        if depth == 0 { return String(source[start...index]) }
    }
    fatalError("unterminated method")
}
let methods = ["private func wishMachineClaimEvidence(", "private func synchronizeWishMachinePresentation()",
               "private func wishMachineTaskPresentation(for",
               "private func refreshWishMachine()", "private func acknowledgeWishEvents(", "private func retryWishAcknowledgements()",
               "private func configureWishMessageDelivery()", "private func updateWishMessageScope()",
               "private func receiveWishMessage(", "private func refreshWishMachineMessages()",
               "private func publishWishMachineEvents(", "private func projectWishMessages(",
               "private func wishMachineEventPayload(", "private func projectLocalWishFacts(",
               "private func deliverWishFactToAgent(", "private struct ResidentWishDelivery",
               "private func registerWishImages(", "private func authorizeWishImages(",
               "private struct ResidentWishImageRegistration", "private func performResidentTurn(",
               "private struct ResidentWishScope", "private func bindResidentWishScope(",
               "private func pauseResidentWishContinuations()",
               "private func pushResidentConnectivityNotice(",
               // 许愿任务 = 消息：宿主把唯一投影喂给 `WishMachineTaskMessageFeed` 这条
               // **真源码**（`synchronizeWishMachinePresentation` 现在就调它）。逐字抽取，
               // 不在 harness 里抄一份宿主逻辑（抄一份正是"两份真相"最容易被放过去的地方）。
               "private func pushWishTaskMessages(",
               "private func residentWishPlacementAlreadyCompleted(",
               "private func resumeWishAutomaticContinuation("].map(declaration).joined(separator: "\n")
// 「已领取 → 入库」的**唯一一份**事实与文案（生产文本，逐字抽取）：任务行/系统消息
// 里那个"已领取并入库"就是它决定的，所以断言必须打在真正跑在 App 里的那份上。
let inventoryBacklogSource = declaration("struct ResidentPropInventoryBacklog {")
let messageStateStart = source.range(of: "    private var residentWishMessageScope:")!.lowerBound
let messageStateEnd = source.range(of: "    private struct ResidentOwnedPropAsset")!.lowerBound
let messageState = String(source[messageStateStart..<messageStateEnd])
let stageSource = try String(contentsOfFile: "apps/macos/Sources/GMGNRadio/VisualEngine/SpatialStageStore.swift", encoding: .utf8)
let outputStatusStart = stageSource.range(of: "    var wishMachineOutputStatus:")!.lowerBound
let outputStatusEnd = stageSource.range(of: "    var residentPropOutputs:")!.lowerBound
let outputStatusState = String(stageSource[outputStatusStart..<outputStatusEnd])
// 三轴的判据、连通性词汇与任务投影：**逐字抽取生产声明**，不在 harness 里抄第二份。
// 「任务行说了什么」必须由跑在 App 里的那一份决定 —— 连同 `WishMachineTaskPresentation`
// 本身一起抽，省掉了原来那个手写副本（那里正是"另存一份"最容易被放过去的地方）。
let presentationSource = try String(contentsOfFile:
    "apps/macos/Sources/GMGNRadio/Presence/WishMachineTaskPresentation.swift", encoding: .utf8)
func presentationDeclaration(_ name: String) -> String {
    let start = presentationSource.range(of: name)!.lowerBound
    let open = presentationSource[start...].firstIndex(of: "{")!
    var depth = 0
    for index in presentationSource[open...].indices {
        if presentationSource[index] == "{" { depth += 1 }
        if presentationSource[index] == "}" { depth -= 1 }
        if depth == 0 { return String(presentationSource[start...index]) }
    }
    fatalError("unterminated declaration")
}
let taskAxisSource = ["enum ResidentGenerationAxis:", "enum ResidentOwnershipAxis:",
                      "enum ResidentPlacementAxis:", "struct ResidentTaskAxes:",
                      "enum ResidentTaskAxisProjection", "enum ResidentConnectivityFact",
                      "struct WishMachineTaskPresentation:"]
    .map(presentationDeclaration).joined(separator: "\n")
// 尺寸意图（`size_intent`）：同样**逐字抽取生产声明**（类型 + 任务行那一行），
// 不在 harness 里抄第二份 —— 抄一份正是"两份真相"最容易被放过去的地方。
let propClientSource = try String(contentsOfFile:
    "apps/macos/Sources/GMGNRadio/Presence/PropGenerationClient.swift", encoding: .utf8)
func sourceDeclaration(_ text: String, _ name: String) -> String {
    let start = text.range(of: name)!.lowerBound
    let open = text[start...].firstIndex(of: "{")!
    var depth = 0
    for index in text[open...].indices {
        if text[index] == "{" { depth += 1 }
        if text[index] == "}" { depth -= 1 }
        if depth == 0 { return String(text[start...index]) }
    }
    fatalError("unterminated declaration")
}
let sizeIntentSource = sourceDeclaration(propClientSource, "struct PropSizeIntent: Codable")
let coordinatorSource = try String(contentsOfFile:
    "apps/macos/Sources/GMGNRadio/Presence/WishMachineCoordinator.swift", encoding: .utf8)
let sizeIntentLineSource = sourceDeclaration(coordinatorSource, "extension WishMachineJob {")
// 托盘可见性 / 领取依据的**唯一**判据：逐字抽取生产声明（`WishMachineOutputReachability`
// 与它依赖的 `WishMachineOutputStatus`）。任务行与托盘"说同一件事"靠的就是它，
// 所以它绝不能在 harness 里再抄一份（抄一份正是"两份真相"最容易被放过去的地方）。
let descriptorSource = try String(contentsOfFile:
    "apps/macos/Sources/GMGNRadio/Presence/WishMachineOutputDescriptor.swift", encoding: .utf8)
let reachabilitySource = sourceDeclaration(descriptorSource, "enum WishMachineOutputStatus")
    + "\n" + sourceDeclaration(descriptorSource, "enum WishMachineOutputReachability")
// 唯一投影**整份**编进来：任务行那一句现在委托给它（`OwnershipSentence` 是唯一出口），
// 所以它不能在这里被抄成一份副本 —— 编的就是跑在 App 里的那一份。
let ownershipProjectionSource = try String(contentsOfFile:
    "apps/macos/Sources/GMGNRadio/Presence/ResidentOwnershipProjection.swift", encoding: .utf8)
    .split(separator: "\n", omittingEmptySubsequences: false)
    .filter { !$0.hasPrefix("import ") }
    .joined(separator: "\n")
// 许愿任务 = **一条条消息**：`WishMachineTaskMessageFeed` 的唯一实现在生产源码里，
// 宿主（`pushWishTaskMessages`）与去重/保留规则读的是同一份 ⇒ 逐字编进来，不抄第二份。
// 它只依赖 Foundation 与唯一投影（`OwnershipRow` / `OwnershipDisplayState` /
// `OwnershipSentence`），所以能在没有 app、没有 UI 的情况下被驱动。
let wishTaskMessageSource = try String(contentsOfFile:
    "apps/macos/Sources/GMGNRadio/Presence/WishMachineTaskMessage.swift", encoding: .utf8)
    .split(separator: "\n", omittingEmptySubsequences: false)
    .filter { !$0.hasPrefix("import ") }
    .joined(separator: "\n")

let program = #"""
import Foundation
import Observation
\#(ownershipProjectionSource)
\#(wishTaskMessageSource)
\#(sizeIntentSource)
enum FixtureError: Error { case failed }
enum WishMachineError: Error { case unknownAttachment }
enum AgentConversationError: Error { case cancelled }
enum ResidentPropHostError: Error { case editorOpen }
enum PropTaskDaemonError: Error { case invalidFrame }
struct PropTaskContext: Equatable { let worldID: String; let residentScope: String }
enum PropTaskJSON: Encodable, Equatable {
    case string(String), bool(Bool)
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self { case .string(let value): try container.encode(value); case .bool(let value): try container.encode(value) }
    }
}
struct PropTaskMessage: Equatable {
    let id: UUID; let sequence: UInt64; let taskId: UUID; let worldID: String
    let residentScope: String; let kind: String; let payload: [String: PropTaskJSON]
}
struct ResidentImageAttachment { let id: UUID; let url: URL; let displayName: String }
struct PropGenerationSource { let author: String; let license: String }
enum WishMachineStage: String { case submitting, submissionUncertain, generating, generated, ready, failed, cancelled, interrupted, claimed }
enum PropGenerationState: String {
    case queued, preflight, waitingResources, submitting, remotePending
    case running, cancelRequested, completed, failed, cancelled, interrupted
}
struct WishMachineJob {
    let id: UUID; let worldID: String; let residentScope: String; let objectID: String
    var stage: WishMachineStage; var autoContinuationPaused: Bool? = nil
    var name = "测试愿望"; var lastError: String?; var remoteState: PropGenerationState?
    var cancelRequested: Bool?; var computeMayContinue = false
    var sizeIntent: PropSizeIntent?
    var jobID: UUID? { id }
}
\#(sizeIntentLineSource)
struct WishPlacementDelegation {
    enum State { case placed, pending, failed, revoked }
    var state: State; var lastError: String?
}
\#(taskAxisSource)
@MainActor final class TaskPanel {
    var tasks: [WishMachineTaskPresentation] = []
    func setWishMachineTasks(_ tasks: [WishMachineTaskPresentation]) { self.tasks = tasks }
    /// 全局连通性是一条**全局提示**，不属于任何任务行；这里只记下宿主推了什么，
    /// 好让断言能证明连通性事实真的走到了全局面，而不是"被谁吃掉了"。
    var connectivityNotices: [String?] = []
    func setWishMachineConnectivity(_ text: String?) { connectivityNotices.append(text) }
}
struct WishMachineEvent {
    enum Kind: String { case stateChanged, generationCompleted, outputReady, failed, cancelled, interrupted, claimed, placed }
    let id: UUID; let wishID: UUID; let worldID: String; let residentScope: String
    let objectID: String; let kind: Kind; let computeMayContinue = false
    var stage: WishMachineStage?; var remoteState: PropGenerationState?; var message: String?; var cancelRequested: Bool?
    var failureSource: String?
    var autoContinuationPaused: Bool?
    var continuationResumeAuthorizationID: UUID?
}
struct WishMachineClaimEvidence { let worldID: String; let activityID: String?; let phase: String?; let distanceMeters: Double; let outputAvailable: Bool }
struct WishMachineOutputDescriptor: Equatable { let id: String; let worldID: String }
\#(reachabilitySource)
enum WishMachineScene {
    enum State { case idle, generating, ready, failed }
    static let worldID = "room"
    static let activityID = "wish_machine.collect"
}
struct ResidentWorldContext { let worldID: String?; let sessionScope: String }
@MainActor final class ResidentAgentLoop {
    struct Event { let id: String; let kind: String; let summary: String }
    struct Input { let runID: UUID; let userMessages: [String]; let imageURLs: [URL]; let events: [Event]; var isBackground = false; var promptText: String { "input" } }
    var active: UUID?
    var canCompleteSilently = false
    var observations: [Event] = []
    var continuations: [Event] = []
    var stopped = false
    var invalidated = false
    var intentPaused = false
    struct Snapshot {
        let isRunning: Bool; let isStopped: Bool; let isInvalidated: Bool; let intentPausedByUser: Bool
        var isAutonomyPausedByUser: Bool { isStopped || intentPausedByUser }
    }
    var snapshot: Snapshot { .init(isRunning: active != nil, isStopped: stopped, isInvalidated: invalidated, intentPausedByUser: intentPaused) }
    var humanInputRuns = Set<UUID>()
    var releases = 0
    func isCurrent(runID: UUID) -> Bool { active == runID }
    func runHasHumanInput(runID: UUID) -> Bool { !invalidated && active == runID && humanInputRuns.contains(runID) }
    @discardableResult
    func resumeAutonomyByUser() -> Bool {
        var changed = false
        if intentPaused { intentPaused = false; changed = true }
        if stopped, active == nil { stopped = false; changed = true }
        if changed { releases += 1 }
        return changed
    }
    func allowsSilentCompletion(runID: UUID) -> Bool { active == runID && canCompleteSilently }
    func receiveEvent(_ event: Event) { if !observations.contains(where: { $0.id == event.id }) && !continuations.contains(where: { $0.id == event.id }) { observations.append(event) } }
    func receiveContinuationEvent(_ event: Event) { if !continuations.contains(where: { $0.id == event.id }) { continuations.append(event) } }
}
@MainActor final class Coordinator {
    var onChange: (() -> Void)?
    var placement: WishPlacementDelegation?
    func placementDelegation(worldID: String, residentScope: String, objectID: String) -> WishPlacementDelegation? { placement }
    var jobs: [WishMachineJob] = []
    var events: [WishMachineEvent] = []
    var published = Set<UUID>()
    var publicationMarkerFails = false
    var renderFailurePersistenceFails = false
    var acknowledged: [UUID] = []
    var refreshLimits: [Int] = []
    var authorizationFails = false
    var acknowledgementFails = false
    var granted: [UUID] = []
    var pauseFails = false
    var pausedScopes: [String] = []
    func pauseContinuations(worldID: String, residentScope: String) throws {
        pausedScopes.append(worldID + ":" + residentScope)
        for index in jobs.indices where jobs[index].worldID == worldID && jobs[index].residentScope == residentScope { jobs[index].autoContinuationPaused = true }
        if pauseFails { throw FixtureError.failed }
    }
    var resumeAuthorizations: [UUID] = []
    var resumeFails = false
    func read(id: UUID, worldID: String, residentScope: String) throws -> WishMachineJob {
        guard let job = jobs.first(where: { $0.id == id && $0.worldID == worldID && $0.residentScope == residentScope }) else { throw FixtureError.failed }
        return job
    }
    @discardableResult
    func resumeContinuations(id: UUID, worldID: String, residentScope: String, authorizationID: UUID,
                             placementAlreadyCompleted: Bool? = nil) throws -> WishMachineJob {
        if resumeFails { throw FixtureError.failed }
        guard let index = jobs.firstIndex(where: { $0.id == id && $0.worldID == worldID && $0.residentScope == residentScope }),
              jobs[index].autoContinuationPaused == true else { throw FixtureError.failed }
        guard !resumeAuthorizations.contains(authorizationID) else { throw FixtureError.failed }
        resumeAuthorizations.append(authorizationID)
        jobs[index].autoContinuationPaused = false
        events.append(.init(id: UUID(), wishID: id, worldID: worldID, residentScope: residentScope,
            objectID: jobs[index].objectID, kind: .stateChanged, autoContinuationPaused: false,
            continuationResumeAuthorizationID: authorizationID))
        onChange?()
        return jobs[index]
    }
    func automaticContinuationEvents(worldID: String, residentScope: String) -> [WishMachineEvent] {
        pendingEvents(worldID: worldID, residentScope: residentScope).filter { event in jobs.contains { $0.id == event.wishID && $0.autoContinuationPaused != true } }
    }
    func authorize(attachments: [ResidentImageAttachment], worldID: String, residentScope: String, authorizationID: UUID, source: PropGenerationSource) throws {
        if authorizationFails { throw FixtureError.failed }
        granted.append(authorizationID)
    }
    func registerImages(_ attachments: [ResidentImageAttachment], worldID: String, residentScope: String, conversationID: String) throws {}
    func authorize(registeredImageIDs: [UUID], worldID: String, residentScope: String, conversationID: String, authorizationID: UUID, source: PropGenerationSource) throws {
        if authorizationFails { throw FixtureError.failed }
        granted.append(authorizationID)
    }
    func residentJobs(worldID: String, residentScope: String) -> [WishMachineJob] { jobs.filter { $0.worldID == worldID && $0.residentScope == residentScope } }
    func readyOutputs(worldID: String) -> [WishMachineOutputDescriptor] { jobs.filter { $0.worldID == worldID && $0.stage == .ready }.map { .init(id: $0.objectID, worldID: worldID) } }
    func pendingEvents(worldID: String, residentScope: String) -> [WishMachineEvent] { events.filter { $0.worldID == worldID && $0.residentScope == residentScope && !acknowledged.contains($0.id) } }
    func unpublishedEvents(worldID: String, residentScope: String) -> [WishMachineEvent] {
        pendingEvents(worldID: worldID, residentScope: residentScope).filter { !published.contains($0.id) }
    }
    func markEventPublished(id: UUID) throws {
        if publicationMarkerFails { throw FixtureError.failed }
        published.insert(id)
        onChange?()
    }
    func recordOutputRenderFailure(id: UUID, worldID: String, residentScope: String, message: String) throws {
        if renderFailurePersistenceFails { throw FixtureError.failed }
        guard let job = residentJobs(worldID: worldID, residentScope: residentScope).first(where: { $0.id == id && $0.stage == .ready }) else { throw FixtureError.failed }
        let text = "成品场景加载失败：" + message
        // 与真 coordinator **同一份**语义：记录是"最近一次推导"的结论，同一件产物永远只有
        // 一条；结论变了就**替换**它，而不是"有了就不再记"（那会把旧文案永久留在盘上）。
        if let index = events.firstIndex(where: { $0.wishID == id && $0.failureSource == "renderer" }) {
            guard events[index].message != text else { return }
            events[index].message = text
            onChange?()
            return
        }
        events.append(.init(id: UUID(), wishID: id, worldID: worldID, residentScope: residentScope,
            objectID: job.objectID, kind: .failed, message: text, failureSource: "renderer"))
        onChange?()
    }
    /// 现场推导**成功** ⇒ 那条陈旧结论必须消失（同真 coordinator：幂等，没记录时不写入）。
    @discardableResult
    func clearOutputRenderFailure(id: UUID, worldID: String, residentScope: String) throws -> Bool {
        if renderFailurePersistenceFails { throw FixtureError.failed }
        let before = events.count
        events.removeAll { $0.wishID == id && $0.worldID == worldID && $0.residentScope == residentScope
            && $0.kind == .failed && $0.failureSource == "renderer" }
        guard events.count != before else { return false }
        onChange?()
        return true
    }
    func outputRenderFailure(id: UUID, worldID: String, residentScope: String) -> WishMachineEvent? {
        events.first { $0.wishID == id && $0.worldID == worldID && $0.residentScope == residentScope && $0.kind == .failed && $0.failureSource == "renderer" }
    }
    func acknowledgeEvent(id: UUID) throws {
        if acknowledgementFails { throw FixtureError.failed }
        acknowledged.append(id)
    }
    func refreshPending(limit: Int) async { refreshLimits.append(limit) }
}
@MainActor @Observable final class Stage {
    var selectedWorldID: String? = "room"
    var wishMachineOutput: WishMachineOutputDescriptor?
    \#(outputStatusState)
    var wishMachineState = WishMachineScene.State.idle
}
@MainActor final class World {
    struct Manifest { let worldID = "room" }
    struct Transform { var position = SIMD3<Float>(0.8, 0, -3.55) }
    enum Phase: String { case loop, traveling, approach, enter }
    struct Activity { let id: String; let phase: Phase }
    /// 模拟状态的"这件活动是 active"：**不是**领取判据要用的"真的在跑"。
    struct Snapshot { var agentTransform = Transform(); var activeActivity: Activity? = .init(id: "wish_machine.collect", phase: .loop) }
    /// 执行器的一手事实：没有 run 就是 nil。与 `snapshot.activeActivity` 分开建模，
    /// 因为两者确实可以不一致（模拟状态说在跑、执行器空转时相位会回落到 loop）。
    struct Running { let id: String; let phase: Phase }
    var runningActivity: Running? = .init(id: "wish_machine.collect", phase: .loop)
    /// 注册出来的取物锚点：领取位置的**唯一**来源。
    struct Anchor { let id: String; let position: SIMD3<Float> }
    struct AnchorRegistry {
        var anchor: Anchor? = .init(id: "wish_machine.device#pickup", position: SIMD3(0.8, 0, -3.55))
        func entry(activityID: String) -> Anchor? { activityID == WishMachineScene.activityID ? anchor : nil }
    }
    var propAnchorRegistry = AnchorRegistry()
    let manifest = Manifest()
    var snapshot = Snapshot()
    struct GeneratedProp { let sourceWishID: String }
    struct ObjectState { var generatedProp: GeneratedProp?; var isEnabled = false }
    struct State { var objectStates: [String: ObjectState] = [:] }
    var state = State()
}
@MainActor final class Avatar {
    var thinkingID: UUID?
    func beginResidentThinking(runID: UUID) { thinkingID = runID }
    func endResidentThinking(runID: UUID) { if thinkingID == runID { thinkingID = nil } }
}
@MainActor final class ResidentConversationTools {
    var cancellations = 0
    func cancel() { cancellations += 1 }
}
@MainActor final class AgentConversationService {
    static let shared = AgentConversationService()
    var calls = 0
    var supportsWorldTools = true
    var error: Error?
    var reply = "done"
    var onSend: (() -> Void)?
    func send(_ text: String, imageURLs: [URL], worldContext: ResidentWorldContext, worldTools: ResidentConversationTools?, userMessage: String? = nil, onCancel: @escaping @MainActor () -> Void) async throws -> String {
        calls += 1
        if let error { throw error }
        onSend?()
        return reply
    }
}
\#(inventoryBacklogSource)
@MainActor final class App {
    var residentAgentLoop: ResidentAgentLoop? = ResidentAgentLoop()
    let spatialStage = Stage()
    var stageWindowController: TaskPanel? = TaskPanel()
    var liveCamWindowController: TaskPanel? = TaskPanel()
    var livingWorldContext: World? = World()
    let wishMachineCoordinator = Coordinator()
    let propGenerationStore = MessageStore()
    let avatarRuntime = Avatar()
    var liveCamMessageID: UUID?
    var residentPropEditingWorldID: String?
    var residentPropTemporaryCancellation = false
    var residentOwnedPropAssets: [String: Bool] = [:]
    var residentPropAssetFailures: [String: String] = [:]
    var residentPropInventoryBacklog = ResidentPropInventoryBacklog()
    var scope = "resident"
    private var residentWishImages: [URL: ResidentWishImageRegistration] = [:]
    private var residentWishScope: ResidentWishScope?
    \#(messageState)
    var notices: [String] = []
    func showResidentVoiceStatus(_ message: String) { notices.append(message) }
    let tools = ResidentConversationTools()
    func currentResidentWorldContext() -> ResidentWorldContext { .init(worldID: spatialStage.selectedWorldID, sessionScope: scope) }
    func ensureResidentLoop() -> ResidentAgentLoop { residentAgentLoop! }
    func makeResidentWorldTools(messageID: UUID, wishAuthorizationID: UUID?, allowsPausedWishClaim: Bool, humanOrderedClaim: @escaping @MainActor () -> Bool = { false }, allowsPropMutation: Bool) -> ResidentConversationTools? { tools }
    func synchronizeOwnedResidentProps() async {}
    func wishMachinePromptContext(_ world: ResidentWorldContext) -> String { "" }
    func reconcileResidentWishPlacements(_ world: ResidentWorldContext) throws {}
    /// 生产里这两条是**呈现侧管道**：把系统信箱未读数推给两个表面、把许愿任务提示
    /// 按代次投递给统一状态域。本 harness 断言的是**持久域**那一侧（MessageStore 的
    /// subscriptions / acknowledged 由被抽取的方法直接驱动），不覆盖这两条管道，
    /// 所以只补签名可编译，不假装覆盖其行为。
    var wishTaskPromptGeneration = 0
    func pushSystemInboxSnapshots() {}
    /// 生产里这条先落统一状态域（system inbox）再投影到两个表面。本 harness 断言的是
    /// 两个表面看到同一份持久任务，不覆盖 inbox 落库，所以只按**同一个 tasks 值**
    /// 同步投影到两个面板 —— 不假装覆盖 inbox 那条管道。
    func pushWishTaskPrompts(_ tasks: [WishMachineTaskPresentation], worldID: String, scope: String) {
        wishTaskPromptGeneration += 1
        stageWindowController?.setWishMachineTasks(tasks)
        liveCamWindowController?.setWishMachineTasks(tasks)
    }
    /// 许愿任务消息的出口状态：**真源码** `WishMachineTaskMessageFeed`（生产里就是
    /// `GMGNRadioApp.wishTaskMessageFeed`）。抽取出来的 `pushWishTaskMessages` 直接驱动它。
    private var wishTaskMessageFeed = WishMachineTaskMessageFeed()
    /// 生产里到期锚点来自共享系统收件箱（`ResidentSystemInboxStore.promptExpiry`，终态后
    /// 30 秒）。本 harness 不落收件箱 ⇒ 锚点恒为 nil（= 投影说还没了结）。「失败不自动消失 /
    /// 其它终态按既有窗口过期」这两条由 tools/test-wish-task-messages.swift 用真规则逐条驱动。
    final class ResidentSystemInboxStoreStub {
        func promptExpiry(taskKey: String, worldID: String, residentScope: String) -> Date? { nil }
    }
    let residentSystemInboxStore = ResidentSystemInboxStoreStub()
    /// 生产里这条从**权威世界状态**投影出唯一投影的输入（jobs ∪ 世界物件）。本 harness
    /// 断言的是消息通道/呈现那一侧，不建模世界文档 ⇒ 按**同一个签名**返回空事实；宿主真的
    /// 把消息接进既有对话通道（`ResidentChatTranscriptLine` / `speaker: .notice`）由
    /// tools/test-wish-task-messages.swift 判据 2 逐字钉住。
    func residentPropWishFacts(worldID: String, context: World) -> (facts: [OwnershipRowFacts], order: [String: Int]) {
        ([], [:])
    }
    /// 生产里这条把最近对话 + 许愿任务消息推给两个聊天表面。本 harness 的两个面板是呈现
    /// 替身（不建模转录行），所以与 `pushSystemInboxSnapshots` 同一个理由：只补呈现管道签名，
    /// 不假装覆盖它 —— 消息本身仍由上面抽取的 `pushWishTaskMessages`（真源码）驱动，出口
    /// 形状由 tools/test-wish-task-messages.swift 钉。
    func publishResidentTranscript() {}
    \#(methods)
    func refresh() async { await refreshWishMachine() }
    func settle() async {
        await Task.yield()
        await refreshWishMachineMessages()
        while residentWishMessageRefreshRunning { await Task.yield() }
    }
    func drainScheduledWork() async {
        for _ in 0..<30 { await Task.yield() }
        while residentWishMessageRefreshRunning { await Task.yield() }
    }
    func evidence(_ job: WishMachineJob) -> WishMachineClaimEvidence? { wishMachineClaimEvidence(for: job) }
    // 原文层已整体移除（2026-10-01）：这里原先桩着 `registerResidentMemoryTurn`
    // 让 harness 能编译。生产里该方法已随 `memory_ingest` 一起删除，所以这个桩
    // 也必须去掉 —— 留着一个生产里不存在的签名只会掩盖"抽取到的调用点已经没了"。
    func perform(_ input: ResidentAgentLoop.Input) async throws -> String { try await performResidentTurn(input) }
    /// 生产里作用域在 ensureResidentLoop()/回合入口绑定；harness 直接绑定一次。
    func bindWishScope() { bindResidentWishScope(currentResidentWorldContext(), loop: residentAgentLoop!) }
    /// 面板的"恢复自动领取"控件就是这一次调用（生产里由两个窗口的 handler 接线）。
    func resume(_ id: UUID) -> Bool { resumeWishAutomaticContinuation(id: id) }
    func register(_ image: ResidentImageAttachment) { registerWishImages([image], loop: residentAgentLoop!, worldScope: scope) }
    func prepare(_ input: ResidentAgentLoop.Input) throws -> UUID? { try authorizeWishImages(input, worldContext: currentResidentWorldContext()) }
    func pause() { pauseResidentWishContinuations() }
    /// 本地直达的记账是私有的：这层只读包装让断言能看见"同一个事实只本地投递一次"。
    func localFactsQueued() -> Set<UUID> { residentWishLocalFactsQueued }
}
@MainActor final class MessageStore {
    var subscriptions = Set<String>()
    var unsubscribed = Set<String>()
    var jobs: [WishMachineJob] = []
    var errorMessage: String?
    var onMessage: ((String, PropTaskMessage) -> Void)?
    var published: [UUID: PropTaskMessage] = [:]
    var publishAttempts: [UUID] = []
    var publishFails = false
    var acknowledgementFails = Set<String>()
    var acknowledgements: [String: Set<UUID>] = [:]
    var acknowledgeAttempts: [String: Int] = [:]
    var refreshes = 0
    func refreshSnapshot() async { refreshes += 1 }
    func subscribeMessages(consumer: String, worldID: String, residentScope: String) async throws {
        subscriptions.insert(consumer + ":" + worldID + ":" + residentScope)
        for message in published.values where message.worldID == worldID && message.residentScope == residentScope { deliver(message, consumer: consumer) }
    }
    func unsubscribeMessages(consumer: String, worldID: String, residentScope: String) {
        let key = consumer + ":" + worldID + ":" + residentScope
        subscriptions.remove(key); unsubscribed.insert(key)
    }
    func publishMessage(id: UUID, taskId: UUID, worldID: String, residentScope: String, kind: String, payload: [String: PropTaskJSON]) async throws -> PropTaskMessage {
        publishAttempts.append(id)
        if publishFails { throw FixtureError.failed }
        if let previous = published[id] { return previous }
        let message = PropTaskMessage(id: id, sequence: UInt64(published.count + 1), taskId: taskId,
            worldID: worldID, residentScope: residentScope, kind: kind, payload: payload)
        published[id] = message
        for consumer in ["world", "ui", "agent"] { deliver(message, consumer: consumer) }
        return message
    }
    func acknowledgeMessage(id: UUID, consumer: String, worldID: String, residentScope: String) async throws {
        acknowledgeAttempts[consumer, default: 0] += 1
        if acknowledgementFails.contains(consumer) { throw FixtureError.failed }
        guard let message = published[id], message.worldID == worldID, message.residentScope == residentScope else { throw FixtureError.failed }
        acknowledgements[consumer, default: []].insert(id)
    }
    func acknowledged(_ consumer: String) -> Set<UUID> { acknowledgements[consumer] ?? [] }
    func deliver(_ message: PropTaskMessage, consumer: String) {
        guard subscriptions.contains(consumer + ":" + message.worldID + ":" + message.residentScope), !acknowledged(consumer).contains(message.id) else { return }
        onMessage?(consumer, message)
    }
    func replay() { for message in published.values { for consumer in ["world", "ui", "agent"] { deliver(message, consumer: consumer) } } }
}
@main struct Tests {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ message: String) { count += 1; if !value { fatalError("FAIL: " + message) } }
        let app = App(), id = UUID()
        let job = WishMachineJob(id: id, worldID: "room", residentScope: "resident", objectID: "item", stage: .ready)
        let event = WishMachineEvent(id: UUID(), wishID: id, worldID: "room", residentScope: "resident", objectID: "item", kind: .outputReady)
        app.wishMachineCoordinator.jobs = [job]
        app.wishMachineCoordinator.events = [event]
        app.propGenerationStore.jobs = [job]
        await app.refresh()
        check(app.propGenerationStore.subscriptions == ["world:room:resident", "ui:room:resident", "agent:room:resident"], "world, UI and agent subscribe independently to the durable scoped inbox")
        check(app.stageWindowController!.tasks.map(\.id) == [id] && app.liveCamWindowController!.tasks.map(\.id) == [id], "both panels show the same persisted wish independent of a resident turn")
        check(app.stageWindowController!.tasks[0].status != "可领取", "downloaded output is not presented as collectible before render success")
        check(app.spatialStage.wishMachineOutput?.id == "item", "verified downloaded job selects the physical tray output")
        check(app.residentAgentLoop!.continuations.isEmpty, "download alone cannot wake pickup before the renderer")
        check(app.propGenerationStore.published.isEmpty && app.wishMachineCoordinator.published.isEmpty, "outputReady remains an unpublished fact until the renderer is ready")
        app.spatialStage.wishMachineOutputStatus = .ready(id: "wrong-item")
        await app.refresh()
        check(app.residentAgentLoop!.continuations.isEmpty && app.evidence(job)?.outputAvailable == false, "another mesh's ready state cannot authorize notification or pickup")
        app.spatialStage.wishMachineOutputStatus = .ready(id: "item")
        await app.refresh()
        check(app.residentAgentLoop!.continuations.count == 1, "matching completed renderer emits the original job's continuation")
        check(app.propGenerationStore.acknowledged("world") == [event.id] && app.propGenerationStore.acknowledged("ui") == [event.id], "world and UI independently acknowledge successful projection")
        check(app.propGenerationStore.acknowledged("agent").isEmpty, "mere agent notification receipt does not acknowledge the durable message")
        check(app.wishMachineCoordinator.published == [event.id] && app.wishMachineCoordinator.acknowledged.isEmpty, "coordinator records publication only and never substitutes local delivery acknowledgements")
        app.scope = "other-resident"; app.spatialStage.selectedWorldID = "other-world"
        app.wishMachineCoordinator.pauseFails = true
        app.pause()
        check(app.wishMachineCoordinator.pausedScopes == ["room:resident"], "stop after world selection uses the original bound resident scope")
        check(!app.notices.isEmpty, "pause persistence failure is visible rather than silently swallowed")
        app.scope = "resident"; app.spatialStage.selectedWorldID = "room"
        let continuationCount = app.residentAgentLoop!.continuations.count
        await app.refresh()
        check(app.residentAgentLoop!.continuations.count == continuationCount, "paused job cannot issue another automatic continuation")
        check(app.wishMachineCoordinator.acknowledged.isEmpty && app.spatialStage.wishMachineOutput?.id == "item", "pause retains completion fact and displayed asset")
        let oldLoop = app.residentAgentLoop
        app.residentAgentLoop = ResidentAgentLoop()
        app.pause()
        check(app.wishMachineCoordinator.pausedScopes.count == 1, "old binding cannot pause a replacement resident loop")
        app.residentAgentLoop = oldLoop
        check(app.evidence(job)?.outputAvailable == true && app.evidence(job)?.distanceMeters == 0, "claim evidence uses actual rendered output and resident location")
        // ── 领取位置只有一个来源：运行时注册的取物锚点 ─────────────────────────
        app.livingWorldContext!.propAnchorRegistry.anchor = .init(
            id: "wish_machine.device#pickup", position: SIMD3(3.5, 0.25, -7.25)) // 与烘焙值不同的位置
        check(app.evidence(job)?.distanceMeters ?? 0 > 0.25,
              "the comparison point must follow the registered anchor, not the resident's own coordinates")
        app.livingWorldContext!.snapshot.agentTransform.position = SIMD3(3.5, 0.25, -7.25)
        check(app.evidence(job)?.distanceMeters == 0 && app.evidence(job) != nil,
              "standing on the moved registered anchor must supply claim evidence")
        app.livingWorldContext!.propAnchorRegistry.anchor = nil
        check(app.evidence(job) == nil, "no registered pickup anchor means no claim evidence at all")
        app.livingWorldContext!.propAnchorRegistry.anchor = .init(
            id: "wish_machine.device#pickup", position: SIMD3(0.8, 0, -3.55))
        app.livingWorldContext!.snapshot.agentTransform.position = SIMD3(0.8, 0, -3.55)
        // ── "真的在跑"只认执行器一份事实，不认模拟状态 + 相位回落拼出来的假象 ──
        check(app.evidence(job)?.activityID == "wish_machine.collect" && app.evidence(job)?.phase == "loop",
              "a genuinely running collection loop supplies the activity and phase")
        app.livingWorldContext!.runningActivity = nil
        check(app.evidence(job)?.activityID == nil && app.evidence(job)?.phase == nil,
              "an idle executor cannot be described as a running activity, even while the simulation still records one")
        check(app.livingWorldContext!.snapshot.activeActivity?.phase == .loop,
              "the simulation snapshot still reports its safe-idle loop phase, which is exactly why evidence must not read it")
        app.livingWorldContext!.runningActivity = .init(id: "wish_machine.collect", phase: .loop)
        app.livingWorldContext!.snapshot.agentTransform.position.x += 1
        check(app.evidence(job)!.distanceMeters > 0.25, "resident away from pickup cannot satisfy arrival distance")
        app.livingWorldContext!.snapshot.agentTransform.position.x -= 1
        app.spatialStage.wishMachineOutputStatus = .loading(id: "item")
        check(app.evidence(job)?.outputAvailable == false && app.evidence(job) != nil,
              "standing on the registered anchor with an unrendered tray still refuses the pickup")
        app.spatialStage.wishMachineOutputStatus = .ready(id: "item")
        app.scope = "other"
        check(app.evidence(job) == nil, "another resident scope cannot supply claim evidence")
        app.scope = "resident"
        let runID = UUID()
        app.residentAgentLoop!.active = runID
        let image = ResidentImageAttachment(id: UUID(), url: URL(fileURLWithPath: "/fixture/prepared.png"), displayName: "用户图片")
        app.register(image)
        let input = ResidentAgentLoop.Input(runID: runID, userMessages: ["领取"], imageURLs: [image.url], events: app.residentAgentLoop!.continuations)
        var background = input; background.isBackground = true
        check(try app.prepare(background) == nil && app.wishMachineCoordinator.granted.isEmpty, "background continuation cannot gain manufacturing permission even with an image URL")
        app.scope = "another-resident"
        do { _ = try app.prepare(input); check(false, "another scope should not reuse image registration") } catch WishMachineError.unknownAttachment { }
        app.scope = "resident"
        let originalLoop = app.residentAgentLoop
        app.residentAgentLoop = ResidentAgentLoop(); app.residentAgentLoop!.active = runID
        do { _ = try app.prepare(input); check(false, "replacement loop should not reuse old image registration") } catch WishMachineError.unknownAttachment { }
        app.residentAgentLoop = originalLoop
        let followup = ResidentAgentLoop.Input(runID: runID, userMessages: ["用刚才的图片做一个42厘米的摆件"], imageURLs: [], events: [])
        check(try app.prepare(followup) == runID, "later text-only human instruction can reference the same scoped image")
        app.wishMachineCoordinator.authorizationFails = true
        do { _ = try await app.perform(input); check(false, "authorization failure should throw") } catch { }
        check(app.avatarRuntime.thinkingID == nil && app.liveCamMessageID == nil, "authorization persistence failure clears thinking and message lease")
        check(AgentConversationService.shared.calls == 0 && app.wishMachineCoordinator.acknowledged.isEmpty, "failed authorization neither invokes model nor acknowledges job")
        app.wishMachineCoordinator.authorizationFails = false
        AgentConversationService.shared.error = AgentConversationError.cancelled
        do { _ = try await app.perform(input); check(false, "cancelled provider should throw") } catch is CancellationError { }
        check(app.wishMachineCoordinator.acknowledged.isEmpty && app.avatarRuntime.thinkingID == nil, "cancelled turn preserves durable completion and clears thinking")
        AgentConversationService.shared.error = nil
        app.propGenerationStore.acknowledgementFails = ["agent"]
        do {
            check(try await app.perform(input) == "done", "acknowledgement persistence failure retains the successful reply")
        } catch { check(false, "acknowledgement persistence failure must not swallow the reply") }
        check(app.propGenerationStore.acknowledged("agent").isEmpty, "failed acknowledgement remains durable and pending")
        let successfulModelCalls = AgentConversationService.shared.calls
        let receivedBeforeRetry = app.residentAgentLoop!.continuations.count
        app.propGenerationStore.replay()
        await app.refresh()
        check(app.residentAgentLoop!.continuations.count == receivedBeforeRetry, "already consumed events awaiting persistence are not redelivered")
        app.propGenerationStore.acknowledgementFails = []
        await app.refresh()
        check(AgentConversationService.shared.calls == successfulModelCalls, "retrying acknowledgement never reruns the model or business actions")
        check(app.propGenerationStore.acknowledged("agent") == [event.id], "only successful current turn acknowledges its consumed completion")
        let emptyApp = App()
        emptyApp.wishMachineCoordinator.jobs = [job]
        emptyApp.wishMachineCoordinator.events = [event]
        emptyApp.propGenerationStore.jobs = [job]
        emptyApp.spatialStage.wishMachineOutputStatus = .ready(id: "item")
        await emptyApp.refresh()
        emptyApp.residentAgentLoop!.active = runID
        let emptyInput = ResidentAgentLoop.Input(runID: runID, userMessages: [], imageURLs: [], events: input.events)
        AgentConversationService.shared.reply = "  "
        _ = try await emptyApp.perform(emptyInput)
        check(emptyApp.propGenerationStore.acknowledged("agent").isEmpty, "unapproved empty reply must not acknowledge the durable notification")
        emptyApp.residentAgentLoop!.canCompleteSilently = true
        _ = try await emptyApp.perform(emptyInput)
        check(emptyApp.propGenerationStore.acknowledged("agent") == [event.id], "authorized silent completion acknowledges the durable notification")
        AgentConversationService.shared.reply = "done"
        app.wishMachineCoordinator.jobs[0].stage = .claimed
        await app.refresh()
        check(app.spatialStage.wishMachineOutput == nil, "claimed asset leaves tray and belongs to inventory, never duplicated on tray")
        let placedApp = App()
        var claimedJob = job; claimedJob.stage = .claimed
        placedApp.wishMachineCoordinator.jobs = [claimedJob]
        placedApp.propGenerationStore.jobs = [claimedJob]
        placedApp.wishMachineCoordinator.placement = .init(state: .revoked)
        placedApp.livingWorldContext!.state.objectStates[job.objectID] = .init(generatedProp: .init(sourceWishID: job.id.uuidString), isEnabled: true)
        await placedApp.refresh()
        check(placedApp.stageWindowController!.tasks.first?.status == "已摆放", "actual manual placement is displayed even when the earlier automatic delegation remains revoked")
        check(placedApp.wishMachineCoordinator.placement?.state == .revoked, "displaying manual placement never revives or completes the revoked automatic delegation")
        placedApp.livingWorldContext!.state.objectStates[job.objectID]!.isEnabled = false
        await placedApp.refresh()
        check(placedApp.stageWindowController!.tasks.first?.status == "摆放已停止", "disabled inventory state does not masquerade as a current placement")
        // 「已领取 → 入库」的可见状态：**说"已入库"必须与「我的物件」列表读同一个事实**
        // （库存记录 `objectStates`），而不是"模型已备好"（`residentOwnedPropAssets`）。
        //
        // 真机 2026-10-01 `2B 白色长剑`：`WishMachine/wishes.json` stage=claimed、资产
        // sha256 与回执一致、`layoutReceipts` 里**没有** `claimed.<jobID>`、
        // `state.json` 的 `objectStates` 里也没有它 —— 而任务行与系统消息写着
        // "已领取并入库"，那句话还随终态 30 秒过期消失（用户："库存没有看到，
        // 只看到左上角的状态说已进库存"）。
        let pendingApp = App()
        var pendingJob = job; pendingJob.stage = .claimed
        pendingApp.wishMachineCoordinator.jobs = [pendingJob]
        pendingApp.propGenerationStore.jobs = [pendingJob]
        // 模型**已经**备好：旧口径（`residentOwnedPropAssets != nil`）正是在这里撒谎。
        pendingApp.residentOwnedPropAssets[job.objectID] = true
        await pendingApp.refresh()
        check(pendingApp.stageWindowController!.tasks.first?.status == "领取后入库中",
              "a prepared asset alone must never read as stored inventory")
        pendingApp.residentPropInventoryBacklog.record(.init(objectID: job.objectID, name: pendingJob.name,
            reason: "空间碰撞数据尚未准备好，请稍后再摆放。", waitsForSupportGeometry: true))
        await pendingApp.refresh()
        check(pendingApp.stageWindowController!.tasks.first?.status == "已领取，等待入库",
              "a refused inventory registration must be visible as waiting, never as stored")
        check(pendingApp.stageWindowController!.tasks.first?.isTerminal == false,
              "an unregistered claim must stay on the panel (a terminal row expires after 30 seconds)")
        check(pendingApp.stageWindowController!.tasks.first?.detail?.contains("空间就绪后会自动补做") == true,
              "the waiting row must say it will self-heal instead of staying silent")
        pendingApp.livingWorldContext!.state.objectStates[job.objectID] =
            .init(generatedProp: .init(sourceWishID: job.id.uuidString), isEnabled: false)
        await pendingApp.refresh()
        check(pendingApp.stageWindowController!.tasks.first?.status == "已领取并入库",
              "a real inventory record must turn the row into the stored state (the waiting state disappears)")
        check(pendingApp.stageWindowController!.tasks.first?.isTerminal == true
                && pendingApp.stageWindowController!.tasks.first?.detail == nil,
              "the stored row is terminal and keeps no stale waiting reason")
        // 资产没就绪是**另一条**事实：库存里有它 ⇒ 列表里不许消失，原因必须可读。
        pendingApp.residentPropAssetFailures[job.objectID] = "已领取物件的本地文件缺失或校验失败，没有删除或重新生成，请检查许愿任务。"
        await pendingApp.refresh()
        check(pendingApp.stageWindowController!.tasks.first?.status == "已入库，资产未就绪",
              "a stored object whose asset failed must say so instead of claiming it is ready")
        check(pendingApp.stageWindowController!.tasks.first?.detail?.hasPrefix("资产未就绪：") == true,
              "the asset failure reason must stay readable")
        let nextID = UUID()
        app.wishMachineCoordinator.jobs.append(.init(id: nextID, worldID: "room", residentScope: "resident", objectID: "new-item", stage: .ready))
        app.propGenerationStore.jobs = app.wishMachineCoordinator.jobs
        app.wishMachineCoordinator.events.append(.init(id: UUID(), wishID: nextID, worldID: "room", residentScope: "resident", objectID: "new-item", kind: .outputReady))
        app.spatialStage.wishMachineOutputStatus = .ready(id: "new-item")
        app.residentAgentLoop!.active = nil
        await app.refresh()
        check(app.residentAgentLoop!.continuations.count == continuationCount + 1, "new unpaused job still receives its delegated continuation")
        app.spatialStage.selectedWorldID = "other-world"
        await app.refresh()
        check(app.spatialStage.wishMachineOutput == nil && app.evidence(job) == nil, "world change removes old presentation and claim authority")
        check(app.propGenerationStore.subscriptions.isEmpty && app.propGenerationStore.unsubscribed == ["world:room:resident", "ui:room:resident", "agent:room:resident"], "scope exit cancels all three old subscriptions")
        check(app.wishMachineCoordinator.refreshLimits.allSatisfy { $0 == 2 }, "host refresh stays bounded")

        let stoppedApp = App()
        var failedJob = job; failedJob.stage = .failed
        let failedEvent = WishMachineEvent(id: UUID(), wishID: id, worldID: "room", residentScope: "resident", objectID: "item", kind: .failed)
        stoppedApp.wishMachineCoordinator.jobs = [failedJob]
        stoppedApp.wishMachineCoordinator.events = [failedEvent]
        stoppedApp.propGenerationStore.jobs = [failedJob]
        stoppedApp.residentAgentLoop!.stopped = true
        await stoppedApp.refresh()
        check(stoppedApp.propGenerationStore.acknowledged("world") == [failedEvent.id] && stoppedApp.propGenerationStore.acknowledged("ui") == [failedEvent.id], "stopping the resident leaves independent world and UI projections running")
        check(stoppedApp.residentAgentLoop!.continuations.isEmpty && stoppedApp.propGenerationStore.acknowledged("agent").isEmpty, "paused resident neither runs nor acknowledges a terminal message")
        stoppedApp.residentAgentLoop!.stopped = false
        stoppedApp.residentAgentLoop!.active = UUID()
        await stoppedApp.refresh()
        check(stoppedApp.residentAgentLoop!.continuations.map(\.id) == ["wish." + failedEvent.id.uuidString] && stoppedApp.propGenerationStore.acknowledged("agent").isEmpty, "busy resident queues the durable message for its next input without acknowledging or replacing the active turn")
        stoppedApp.residentAgentLoop!.active = nil
        await stoppedApp.refresh()
        check(stoppedApp.residentAgentLoop!.continuations.map(\.id) == ["wish." + failedEvent.id.uuidString], "terminal failure uses a delegated continuation independent of ambient chat enablement")

        let pausedApp = App()
        pausedApp.wishMachineCoordinator.jobs = [failedJob]
        pausedApp.wishMachineCoordinator.events = [failedEvent]
        pausedApp.propGenerationStore.jobs = [failedJob]
        pausedApp.residentAgentLoop!.intentPaused = true
        await pausedApp.refresh()
        check(pausedApp.residentAgentLoop!.continuations.map(\.id) == ["wish." + failedEvent.id.uuidString], "intent pause retains observations for the next human turn")
        check(pausedApp.residentAgentLoop!.intentPaused && pausedApp.residentAgentLoop!.active == nil && pausedApp.propGenerationStore.acknowledged("agent").isEmpty, "queuing during intent pause neither resumes autonomy nor claims successful consumption")

        let resumeApp = App()
        var resumedJob = job; resumedJob.autoContinuationPaused = false
        let resumedEvent = WishMachineEvent(id: UUID(), wishID: id, worldID: "room", residentScope: "resident", objectID: "item", kind: .stateChanged, autoContinuationPaused: false, continuationResumeAuthorizationID: UUID())
        resumeApp.wishMachineCoordinator.jobs = [resumedJob]
        resumeApp.wishMachineCoordinator.events = [resumedEvent]
        resumeApp.propGenerationStore.jobs = [resumedJob]
        await resumeApp.refresh()
        check(resumeApp.residentAgentLoop!.continuations.map(\.id) == ["wish." + resumedEvent.id.uuidString], "persisted explicit restoration grants a new continuation even after the old output-ready event was consumed")
        check(resumeApp.propGenerationStore.published[resumedEvent.id]?.payload["resume_authorization_id"] == .string(resumedEvent.continuationResumeAuthorizationID!.uuidString), "restoration notification preserves the real foreground authorization identity")
        check(resumeApp.propGenerationStore.published[resumedEvent.id]?.payload["auto_continuation_paused"] == .bool(false), "restoration notification reports the persisted pause state")

        // ── 停止后仍然没有"不请自来"的自主续办，但事实照样入队 ──────────────
        // 旧实现里 isStopped 直接把这台产物的就绪事实整条丢掉，与紧邻注释
        // （"停止期间也照样排队给下一次人类输入看"）自相矛盾；居民因此只能
        // 靠碰运气再查一次。现在事实入队，自主授权仍然挂起。
        let factApp = App()
        var factJob = job; factJob.autoContinuationPaused = true
        let readyFact = WishMachineEvent(id: UUID(), wishID: id, worldID: "room", residentScope: "resident",
            objectID: "item", kind: .outputReady)
        factApp.wishMachineCoordinator.jobs = [factJob]
        factApp.wishMachineCoordinator.events = [readyFact]
        factApp.propGenerationStore.jobs = [factJob]
        factApp.spatialStage.wishMachineOutputStatus = .ready(id: "item")
        factApp.residentAgentLoop!.stopped = true
        await factApp.refresh()
        check(factApp.residentAgentLoop!.observations.contains { $0.id == "wish." + readyFact.id.uuidString },
              "a stop still queues the ready fact for the next human turn instead of dropping it")
        check(factApp.residentAgentLoop!.continuations.isEmpty,
              "a stop never turns that same fact into an autonomous continuation")
        check(factApp.propGenerationStore.acknowledged("agent").isEmpty,
              "queuing a fact during a stop is not consumption")
        factApp.residentAgentLoop!.stopped = false // 新的真实人类消息
        factApp.residentAgentLoop!.active = UUID()
        await factApp.refresh()
        check(factApp.residentAgentLoop!.continuations.isEmpty && factApp.wishMachineCoordinator.jobs[0].autoContinuationPaused == true,
              "a fresh human turn clears the run stop but never the task-level pause")

        // ── 解除停止是一个动作：任务级续办与 run 级停止各自可观测 ────────────
        let releaseApp = App()
        var releaseJob = job; releaseJob.autoContinuationPaused = true
        releaseApp.wishMachineCoordinator.jobs = [releaseJob]
        releaseApp.propGenerationStore.jobs = [releaseJob]
        releaseApp.spatialStage.wishMachineOutputStatus = .ready(id: "item")
        releaseApp.residentAgentLoop!.stopped = true
        releaseApp.residentAgentLoop!.intentPaused = true
        await releaseApp.refresh()
        let pausedTask = releaseApp.stageWindowController!.tasks.first!
        // **新契约**（状态收敛，2026-10-01）：任务行只表达它自己的三轴状态，
        // **不表达授权**。任务级暂停仍然是宿主读得到的内部事实（下面的
        // `autoContinuationPaused` 断言保证它没丢），但它不再是任务行上的文案、
        // 更不是按任务的"恢复"控件 —— 授权由全局开关横幅表达，解除只需一个动作。
        check(pausedTask.autoContinuationPaused,
              "the task-level pause stays an internal fact the host can still read")
        check(pausedTask.detail?.contains("自主行动已停止") != true,
              "the task row must not render authorization: the stop is a global banner, not a task property")
        check(pausedTask.detail?.contains("直接下达指令仍可当轮执行") != true,
              "the per-task reassurance text is gone from the row; it now lives in the global banner")
        check(pausedTask.detail?.contains("恢复自动领取") != true,
              "no per-task resume affordance or copy survives on the task row")
        // 三轴状态本身仍然成立：这一件任务是 `.ready`（还没领取），所以归属轴停在
        // 未领取，摆放轴还没开始 —— 它**不许**说「在库存」，那会是一句假话。
        check(pausedTask.axes?.ownership == .unclaimed,
              "a ready-but-unclaimed task's ownership axis is 未领取")
        check(pausedTask.axes?.placement == .notYetPlaced,
              "and its placement axis has not started: 未摆放, never a false 在库存")
        // 已领取但库存里还没有它（真机 2026-10-01 `2B 白色长剑`）：归属轴前进到
        // 「已领取」，摆放轴仍然不许说「在库存」——两条轴读的是同一份库存读回。
        var notYetStoredJob = job
        notYetStoredJob.stage = .claimed
        let notYetStoredApp = App()
        notYetStoredApp.wishMachineCoordinator.jobs = [notYetStoredJob]
        notYetStoredApp.propGenerationStore.jobs = [notYetStoredJob]
        await notYetStoredApp.refresh()
        let notYetStoredTask = notYetStoredApp.stageWindowController!.tasks.first!
        check(notYetStoredTask.axes?.ownership == .claimed,
              "a claimed task whose artifact is not in inventory yet is 已领取, not 已入库")
        check(notYetStoredTask.axes?.placement == .notYetPlaced,
              "归属未到已入库时，摆放轴不许说在库存：两条轴读同一份库存读回")
        check(notYetStoredTask.axes?.generation == .completed,
              "a claimed task's generation axis is done: the artifact was generated and verified")
        // 连通性事实**不再作为任务属性**：同一个作用域里有一件 `network_unavailable`
        // 的任务时，它不会出现在任何任务行上，而是走到全局面（横幅）。
        let connectivityApp = App()
        var offlineJob = job
        offlineJob.lastError = "network_unavailable"
        connectivityApp.wishMachineCoordinator.jobs = [offlineJob]
        connectivityApp.propGenerationStore.jobs = [offlineJob]
        await connectivityApp.refresh()
        check(connectivityApp.stageWindowController!.tasks.allSatisfy {
            $0.detail?.contains("network_unavailable") != true
        }, "connectivity facts must not be rendered as task properties on any task row")
        check(connectivityApp.stageWindowController!.connectivityNotices.contains {
            $0?.contains("暂时连不上") == true
        }, "the same connectivity fact must appear once, globally, as one human sentence")
        check(connectivityApp.stageWindowController!.connectivityNotices.contains {
            $0?.contains("network_unavailable") == true
        } == false, "the raw reason code must never reach the banner (engineering words stay in the log)")
        check(releaseApp.residentAgentLoop!.snapshot.isAutonomyPausedByUser
              && releaseApp.wishMachineCoordinator.jobs[0].autoContinuationPaused == true,
              "run stop and task-level pause are two observably separate states")
        releaseApp.bindWishScope()
        check(releaseApp.resume(id),
              "the panel's single resume action succeeds on a stopped task")
        check(releaseApp.wishMachineCoordinator.jobs[0].autoContinuationPaused == false
              && releaseApp.residentAgentLoop!.snapshot.isAutonomyPausedByUser == false
              && releaseApp.residentAgentLoop!.releases == 1,
              "one host action clears both the task-level pause and the run-level stop")
        check(releaseApp.wishMachineCoordinator.resumeAuthorizations.count == 1,
              "the release uses exactly one fresh host authorization")
        check(releaseApp.wishMachineCoordinator.jobs[0].stage == .ready,
              "resuming automatic continuation never claims the artifact by itself")
        await releaseApp.settle()
        let releasedFacts = releaseApp.wishMachineCoordinator.automaticContinuationEvents(worldID: "room", residentScope: "resident")
        check(releasedFacts.count == 1
              && releasedFacts[0].continuationResumeAuthorizationID == releaseApp.wishMachineCoordinator.resumeAuthorizations[0],
              "the release grants exactly one trusted continuation carrying the host's own authorization")
        check(releaseApp.residentAgentLoop!.continuations.count == 1,
              "the released resident receives one continuation and no ambient autonomy")
        // 再次停止后再按一次"恢复"用的是全新宿主授权：旧授权不会被复用。
        try releaseApp.wishMachineCoordinator.pauseContinuations(worldID: "room", residentScope: "resident")
        releaseApp.residentAgentLoop!.stopped = true
        releaseApp.residentAgentLoop!.intentPaused = true
        check(releaseApp.resume(id)
              && releaseApp.wishMachineCoordinator.resumeAuthorizations.count == 2
              && releaseApp.wishMachineCoordinator.resumeAuthorizations[0] != releaseApp.wishMachineCoordinator.resumeAuthorizations[1],
              "each stop needs its own fresh release authorization; the old one is never replayed")
        check(releaseApp.residentAgentLoop!.releases == 2,
              "the second release is another explicit human action, not an ambient recovery")

        let isolatedApp = App()
        isolatedApp.wishMachineCoordinator.jobs = [failedJob]
        isolatedApp.wishMachineCoordinator.events = [failedEvent]
        isolatedApp.propGenerationStore.jobs = [failedJob]
        isolatedApp.propGenerationStore.acknowledgementFails = ["ui"]
        await isolatedApp.refresh()
        check(isolatedApp.propGenerationStore.acknowledged("world") == [failedEvent.id] && isolatedApp.propGenerationStore.acknowledged("ui").isEmpty, "UI confirmation failure cannot block the world's confirmation")
        let beforeReplay = isolatedApp.residentAgentLoop!.continuations.count
        isolatedApp.propGenerationStore.replay(); await isolatedApp.settle()
        check(isolatedApp.residentAgentLoop!.continuations.count == beforeReplay, "unacknowledged replay retains one logical agent observation")
        isolatedApp.propGenerationStore.acknowledgementFails = []
        await isolatedApp.refresh()
        check(isolatedApp.propGenerationStore.acknowledged("ui") == [failedEvent.id] && isolatedApp.propGenerationStore.acknowledged("agent").isEmpty, "retrying UI confirmation does not consume the agent's message")
        let isolatedRun = UUID()
        isolatedApp.residentAgentLoop!.active = isolatedRun
        AgentConversationService.shared.onSend = { isolatedApp.scope = "replacement" }
        let isolatedInput = ResidentAgentLoop.Input(runID: isolatedRun, userMessages: [], imageURLs: [], events: isolatedApp.residentAgentLoop!.continuations)
        do { _ = try await isolatedApp.perform(isolatedInput); check(false, "scope change should cancel the old turn") } catch is CancellationError { }
        AgentConversationService.shared.onSend = nil
        check(isolatedApp.propGenerationStore.acknowledged("agent").isEmpty, "a reply returning after a scope change cannot acknowledge the old scope")
        await isolatedApp.refresh()
        let scopedCount = isolatedApp.residentAgentLoop!.continuations.count
        isolatedApp.propGenerationStore.onMessage?("agent", isolatedApp.propGenerationStore.published[failedEvent.id]!)
        await isolatedApp.settle()
        check(isolatedApp.residentAgentLoop!.continuations.count == scopedCount && isolatedApp.propGenerationStore.subscriptions == ["world:room:replacement", "ui:room:replacement", "agent:room:replacement"], "late callback from an unsubscribed resident is isolated from all three new subscriptions")

        let outboxApp = App()
        outboxApp.wishMachineCoordinator.jobs = [failedJob]
        outboxApp.wishMachineCoordinator.events = [failedEvent]
        outboxApp.propGenerationStore.jobs = [failedJob]
        outboxApp.propGenerationStore.publishFails = true
        await outboxApp.refresh()
        check(outboxApp.wishMachineCoordinator.published.isEmpty && outboxApp.propGenerationStore.published.isEmpty, "a failed publication never marks the local fact as forwarded")
        outboxApp.propGenerationStore.publishFails = false
        outboxApp.wishMachineCoordinator.publicationMarkerFails = true
        await outboxApp.refresh()
        check(outboxApp.propGenerationStore.published.count == 1 && outboxApp.wishMachineCoordinator.published.isEmpty, "Rust acceptance remains durable when saving the local publication marker fails")
        outboxApp.wishMachineCoordinator.publicationMarkerFails = false
        await outboxApp.refresh()
        check(outboxApp.propGenerationStore.published.count == 1 && outboxApp.wishMachineCoordinator.published == [failedEvent.id], "publication-marker retry reuses the original event UUID")

        let callbackApp = App()
        callbackApp.wishMachineCoordinator.jobs = [failedJob]
        callbackApp.propGenerationStore.jobs = [failedJob]
        await callbackApp.refresh()
        let beforeCallback = callbackApp.wishMachineCoordinator.refreshLimits.count
        callbackApp.wishMachineCoordinator.events = [failedEvent]
        callbackApp.wishMachineCoordinator.onChange?()
        await callbackApp.settle()
        check(callbackApp.propGenerationStore.published[failedEvent.id] != nil && callbackApp.wishMachineCoordinator.refreshLimits.count == beforeCallback, "persisted coordinator changes publish immediately without a chat turn or periodic backend poll")
        let stateID = UUID()
        _ = try await callbackApp.propGenerationStore.publishMessage(id: stateID, taskId: id, worldID: "room", residentScope: "resident", kind: "task.stateChanged", payload: ["backendStage": .string("failed")])
        await callbackApp.settle()
        check(callbackApp.propGenerationStore.refreshes > 0 && callbackApp.propGenerationStore.acknowledged("world").contains(stateID), "task-state inbox delivery refreshes the durable snapshot before acknowledging world projection")

        let queueApp = App()
        let secondJob = WishMachineJob(id: UUID(), worldID: "room", residentScope: "resident", objectID: "second-item", stage: .ready)
        let secondEvent = WishMachineEvent(id: UUID(), wishID: secondJob.id, worldID: "room", residentScope: "resident", objectID: "second-item", kind: .outputReady)
        queueApp.wishMachineCoordinator.jobs = [job, secondJob]
        queueApp.wishMachineCoordinator.events = [event, secondEvent]
        queueApp.propGenerationStore.jobs = [job, secondJob]
        await queueApp.refresh()
        await queueApp.drainScheduledWork()
        check(queueApp.spatialStage.wishMachineOutput?.id == "item", "first ready artifact initially receives the tray")
        queueApp.spatialStage.wishMachineOutputStatus = .failed(id: "item", message: "first mesh is broken")
        await queueApp.drainScheduledWork()
        check(queueApp.spatialStage.wishMachineOutput?.id == "second-item", "a persisted renderer failure releases the tray for the next ready artifact")
        let firstFailure = queueApp.wishMachineCoordinator.outputRenderFailure(id: job.id, worldID: "room", residentScope: "resident")!
        check(queueApp.propGenerationStore.published[firstFailure.id]?.payload["failure_source"] == .string("renderer"), "the first artifact's failure fact is retained and published before its renderer status disappears")
        check(queueApp.stageWindowController!.tasks.first(where: { $0.id == job.id })?.status == "场景加载失败", "failed artifact keeps its own error card after another artifact takes the tray")
        queueApp.spatialStage.wishMachineOutputStatus = .ready(id: "second-item")
        await queueApp.drainScheduledWork()
        check(queueApp.propGenerationStore.published[secondEvent.id] != nil && queueApp.evidence(secondJob)?.outputAvailable == true && queueApp.evidence(job)?.outputAvailable == false, "second artifact can publish outputReady and supply real claim evidence while first cannot")
        queueApp.spatialStage.wishMachineOutputStatus = .failed(id: "item", message: "late first-renderer callback")
        await queueApp.refresh()
        check(queueApp.spatialStage.wishMachineOutput?.id == "second-item" && queueApp.wishMachineCoordinator.outputRenderFailure(id: job.id, worldID: "room", residentScope: "resident")?.id == firstFailure.id, "late callbacks and repeated refresh never return the failed artifact to the tray")
        check(queueApp.stageWindowController!.tasks.first(where: { $0.id == job.id })?.detail == firstFailure.message, "failed artifact keeps the original persisted diagnostic after callback text changes")
        queueApp.spatialStage.wishMachineOutputStatus = .ready(id: "second-item")
        let otherScopeJob = WishMachineJob(id: UUID(), worldID: "room", residentScope: "different-resident", objectID: "item", stage: .ready)
        queueApp.wishMachineCoordinator.jobs.append(otherScopeJob)
        queueApp.propGenerationStore.jobs.append(otherScopeJob)
        queueApp.scope = "different-resident"
        await queueApp.refresh()
        check(queueApp.spatialStage.wishMachineOutput?.id == "item" && queueApp.stageWindowController!.tasks.map(\.id) == [otherScopeJob.id], "persisted render failures cannot exclude another resident's distinct artifact")
        queueApp.scope = "resident"
        await queueApp.refresh()
        check(queueApp.spatialStage.wishMachineOutput?.id == "second-item", "returning to the original scope still excludes its failed artifact")

        let unsavedFailureApp = App()
        unsavedFailureApp.wishMachineCoordinator.jobs = [job, secondJob]
        unsavedFailureApp.wishMachineCoordinator.events = [event, secondEvent]
        unsavedFailureApp.propGenerationStore.jobs = [job, secondJob]
        await unsavedFailureApp.refresh()
        await unsavedFailureApp.drainScheduledWork()
        unsavedFailureApp.wishMachineCoordinator.renderFailurePersistenceFails = true
        unsavedFailureApp.spatialStage.wishMachineOutputStatus = .failed(id: "item", message: "cannot save failure")
        await unsavedFailureApp.drainScheduledWork()
        check(unsavedFailureApp.spatialStage.wishMachineOutput?.id == "item" && unsavedFailureApp.wishMachineCoordinator.outputRenderFailure(id: job.id, worldID: "room", residentScope: "resident") == nil, "failure persistence must succeed before changing the selected artifact")

        let renderApp = App()
        renderApp.wishMachineCoordinator.jobs = [job]
        renderApp.wishMachineCoordinator.events = [event]
        renderApp.propGenerationStore.jobs = [job]
        renderApp.spatialStage.wishMachineOutputStatus = .failed(id: "other-item", message: "old mesh failed")
        await renderApp.refresh()
        check(renderApp.spatialStage.wishMachineState != .failed && renderApp.propGenerationStore.published.isEmpty, "another object's stale renderer error must not fail this wish")
        renderApp.spatialStage.wishMachineOutputStatus = .loading(id: "item")
        await renderApp.refresh()
        check(renderApp.propGenerationStore.published.isEmpty, "a mesh still loading has no renderer failure fact")
        renderApp.spatialStage.wishMachineOutputStatus = .failed(id: "item", message: "mesh unavailable")
        await renderApp.refresh()
        check(renderApp.spatialStage.wishMachineState == .failed && renderApp.stageWindowController!.tasks[0].status == "场景加载失败", "actual renderer failure reaches both the physical machine and UI")
        let renderFailures = renderApp.propGenerationStore.published.values.filter { $0.kind == "wish.failed" && $0.payload["failure_source"] == .string("renderer") }
        check(renderFailures.count == 1 && renderApp.residentAgentLoop!.continuations.count == 1, "actual renderer failure publishes a durable failure notification for the resident")
        renderApp.spatialStage.wishMachineOutputStatus = .failed(id: "item", message: "same renderer, new diagnostic")
        await renderApp.refresh()
        check(renderApp.propGenerationStore.published.count == 1 && renderApp.wishMachineCoordinator.jobs[0].stage == .ready, "repeated renderer failure retains one event UUID and keeps backend completion intact")
        await renderApp.drainScheduledWork()
        renderApp.spatialStage.wishMachineOutputStatus = .ready(id: "item")
        await renderApp.drainScheduledWork()
        // **契约变更（2026-10-02 真机「超大荧幕电视」，HEAD 074ebd2 之前）**：旧断言写的是
        // "一次 ready 回调**不许**把带持久化失败的产物弄回托盘"。那正是本次要修的缺陷 ——
        // 派生结论（那条 `failureSource == "renderer"` 的失败）被当成持久事实，于是"推导逻辑
        // 被修好了"这件事**永远不会被重新推导**，用户**永久**领不了（撞了两次）。
        // 现在的契约：`.ready(id:)` 就是一次**重新推导成功**（渲染端用代次守卫丢掉了迟到的
        // 旧回调之后才报的），它必须清掉那条陈旧结论、让托盘重新看得见它、也重新领得了。
        check(renderApp.wishMachineCoordinator.outputRenderFailure(id: job.id, worldID: "room", residentScope: "resident") == nil
              && renderApp.spatialStage.wishMachineOutput?.id == "item"
              && renderApp.evidence(job)?.outputAvailable == true
              && renderApp.wishMachineCoordinator.jobs[0].stage == .ready,
              "重新推导成功 ⇒ 那条陈旧失败必须消失、托盘重新看得见它、也重新领得了（后端完成态不受影响）")

        let readyCallbackApp = App()
        readyCallbackApp.wishMachineCoordinator.jobs = [job]
        readyCallbackApp.wishMachineCoordinator.events = [event]
        readyCallbackApp.propGenerationStore.jobs = [job]
        await readyCallbackApp.refresh()
        await readyCallbackApp.drainScheduledWork()
        let renderRefreshCount = readyCallbackApp.wishMachineCoordinator.refreshLimits.count
        readyCallbackApp.spatialStage.wishMachineOutputStatus = .ready(id: "item")
        await readyCallbackApp.drainScheduledWork()
        check(readyCallbackApp.propGenerationStore.published[event.id] != nil && readyCallbackApp.wishMachineCoordinator.refreshLimits.count == renderRefreshCount, "renderer-ready callback publishes the ready fact without invoking the periodic refresh")

        let failureCallbackApp = App()
        failureCallbackApp.wishMachineCoordinator.jobs = [job]
        failureCallbackApp.wishMachineCoordinator.events = [event]
        failureCallbackApp.propGenerationStore.jobs = [job]
        await failureCallbackApp.refresh()
        await failureCallbackApp.drainScheduledWork()
        let failureRefreshCount = failureCallbackApp.wishMachineCoordinator.refreshLimits.count
        failureCallbackApp.spatialStage.wishMachineOutputStatus = .failed(id: "item", message: "renderer rejected mesh")
        await failureCallbackApp.drainScheduledWork()
        check(failureCallbackApp.propGenerationStore.published.values.contains(where: { $0.payload["failure_source"] == .string("renderer") }) && failureCallbackApp.wishMachineCoordinator.refreshLimits.count == failureRefreshCount, "renderer-failed callback publishes its failure fact without invoking the periodic refresh")
        let outputStatusFixture = Stage()
        var statusChanges = 0
        outputStatusFixture.onWishMachineOutputStatusChanged = { statusChanges += 1 }
        outputStatusFixture.wishMachineOutputStatus = .ready(id: "item")
        check(statusChanges == 1, "a changed renderer status invokes its observer once")
        outputStatusFixture.wishMachineOutputStatus = .ready(id: "item")
        check(statusChanges == 1, "identical renderer status writes do not retrigger the observer")
        outputStatusFixture.wishMachineOutputStatus = .failed(id: "item", message: "failed")
        outputStatusFixture.wishMachineOutputStatus = .failed(id: "item", message: "failed")
        check(statusChanges == 2, "identical renderer failure writes are also deduplicated")
        let attemptsBeforeSameState = failureCallbackApp.propGenerationStore.publishAttempts.count
        failureCallbackApp.spatialStage.wishMachineOutputStatus = .failed(id: "item", message: "renderer rejected mesh")
        await failureCallbackApp.drainScheduledWork()
        check(failureCallbackApp.propGenerationStore.publishAttempts.count == attemptsBeforeSameState, "same renderer state does not republish an already forwarded fact")
        // ── 事实通知 vs 自主授权：消息通道断掉时，本地持久事实照样送达 agent ─────
        // 真机 2026-10-01：网络故障那段窗口里守护进程的发布与订阅都不可用，
        // "产物已经好了"只躺在耐久事件里，agent 什么都没收到（面板却已经能写"可领取"）。
        // 事实本该走两条通道：守护进程消息往返，以及本地持久事件直达。
        let localFactApp = App()
        localFactApp.wishMachineCoordinator.jobs = [job]
        localFactApp.wishMachineCoordinator.events = [event]
        localFactApp.propGenerationStore.jobs = [job]
        localFactApp.spatialStage.wishMachineOutputStatus = .ready(id: "item")
        localFactApp.propGenerationStore.publishFails = true
        await localFactApp.refresh()
        check(localFactApp.residentAgentLoop!.continuations.map(\.id) == ["wish." + event.id.uuidString],
              "a ready fact reaches the resident locally even while the daemon message channel is down")
        check(localFactApp.propGenerationStore.published.isEmpty && localFactApp.wishMachineCoordinator.published.isEmpty,
              "local delivery never pretends the fact was published to the daemon")
        check(localFactApp.propGenerationStore.acknowledged("agent").isEmpty
                && localFactApp.localFactsQueued() == [event.id],
              "local delivery is queuing once, not consumption")
        localFactApp.propGenerationStore.publishFails = false
        await localFactApp.settle()
        check(localFactApp.residentAgentLoop!.continuations.count == 1
                && localFactApp.propGenerationStore.published[event.id] != nil,
              "the recovered daemon channel never grants a second continuation for the same durable fact")

        // 同一个事实在任务级暂停下仍然要通知 agent，但**不得**变成自主授权。
        let pausedFactApp = App()
        var pausedFactJob = job; pausedFactJob.autoContinuationPaused = true
        pausedFactApp.wishMachineCoordinator.jobs = [pausedFactJob]
        pausedFactApp.wishMachineCoordinator.events = [event]
        pausedFactApp.propGenerationStore.jobs = [pausedFactJob]
        pausedFactApp.spatialStage.wishMachineOutputStatus = .ready(id: "item")
        pausedFactApp.propGenerationStore.publishFails = true
        await pausedFactApp.refresh()
        check(pausedFactApp.residentAgentLoop!.observations.contains { $0.id == "wish." + event.id.uuidString },
              "a paused task still gets the ready fact as a plain observation for the next human turn")
        check(pausedFactApp.residentAgentLoop!.continuations.isEmpty,
              "the same paused fact grants no autonomous continuation")

        // 托盘没有真的显示出来之前，"产物就绪"不是既成事实：本地通道也必须守同一条判据。
        let trayMissingApp = App()
        trayMissingApp.wishMachineCoordinator.jobs = [job]
        trayMissingApp.wishMachineCoordinator.events = [event]
        trayMissingApp.propGenerationStore.jobs = [job]
        trayMissingApp.propGenerationStore.publishFails = true
        await trayMissingApp.refresh()
        check(trayMissingApp.residentAgentLoop!.observations.isEmpty
                && trayMissingApp.residentAgentLoop!.continuations.isEmpty,
              "the local fact path obeys the same renderer gate as the published fact")

        print("PASS: \(count) wish-machine App runtime checks (local fixtures only)")
    }
}
"""#
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-wish-app-\(UUID())")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let main = directory.appendingPathComponent("main.swift"), binary = directory.appendingPathComponent("checks")
try program.write(to: main, atomically: true, encoding: .utf8)
let compiler = Process(); compiler.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compiler.arguments = ["-j1", "-swift-version", "6", "-parse-as-library", main.path, "-o", binary.path]
try compiler.run(); compiler.waitUntilExit(); guard compiler.terminationStatus == 0 else { exit(compiler.terminationStatus) }
let run = Process(); run.executableURL = binary; try run.run(); run.waitUntilExit(); exit(run.terminationStatus)

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
               "private func deliverWishMessageToAgent(", "private struct ResidentWishDelivery",
               "private func registerWishImages(", "private func authorizeWishImages(",
               "private struct ResidentWishImageRegistration", "private func performResidentTurn(",
               "private struct ResidentWishScope", "private func bindResidentWishScope(",
               "private func pauseResidentWishContinuations()"].map(declaration).joined(separator: "\n")
let messageStateStart = source.range(of: "    private var residentWishMessageScope:")!.lowerBound
let messageStateEnd = source.range(of: "    private struct ResidentOwnedPropAsset")!.lowerBound
let messageState = String(source[messageStateStart..<messageStateEnd])
let stageSource = try String(contentsOfFile: "apps/macos/Sources/GMGNRadio/VisualEngine/SpatialStageStore.swift", encoding: .utf8)
let outputStatusStart = stageSource.range(of: "    var wishMachineOutputStatus:")!.lowerBound
let outputStatusEnd = stageSource.range(of: "    var residentPropOutputs:")!.lowerBound
let outputStatusState = String(stageSource[outputStatusStart..<outputStatusEnd])
let program = #"""
import Foundation
import Observation
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
enum PropGenerationState: String { case queued, waitingResources, preflight, running }
struct WishMachineJob {
    let id: UUID; let worldID: String; let residentScope: String; let objectID: String
    var stage: WishMachineStage; var autoContinuationPaused: Bool? = nil
    var name = "测试愿望"; var lastError: String?; var remoteState: PropGenerationState?
    var cancelRequested: Bool?; var computeMayContinue = false
    var jobID: UUID? { id }
}
struct WishPlacementDelegation {
    enum State { case placed, pending, failed, revoked }
    var state: State; var lastError: String?
}
struct WishMachineTaskPresentation { let id: UUID; let title: String; let status: String; let detail: String?; let isTerminal: Bool }
@MainActor final class TaskPanel {
    var tasks: [WishMachineTaskPresentation] = []
    func setWishMachineTasks(_ tasks: [WishMachineTaskPresentation]) { self.tasks = tasks }
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
enum WishMachineOutputStatus: Equatable { case empty, loading(id: String), ready(id: String), failed(id: String, message: String) }
enum WishMachineScene {
    enum State { case idle, generating, ready, failed }
    static let worldID = "room"
    static let pickupPosition = SIMD3<Float>(0.8, 0, -3.55)
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
    struct Snapshot { let isRunning: Bool; let isStopped: Bool; let isInvalidated: Bool; let intentPausedByUser: Bool }
    var snapshot: Snapshot { .init(isRunning: active != nil, isStopped: stopped, isInvalidated: invalidated, intentPausedByUser: intentPaused) }
    func isCurrent(runID: UUID) -> Bool { active == runID }
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
        guard !events.contains(where: { $0.wishID == id && $0.failureSource == "renderer" }) else { return }
        events.append(.init(id: UUID(), wishID: id, worldID: worldID, residentScope: residentScope,
            objectID: job.objectID, kind: .failed, message: "成品场景加载失败：" + message, failureSource: "renderer"))
        onChange?()
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
    enum Phase: String { case loop, traveling }
    struct Activity { let id: String; let phase: Phase }
    struct Snapshot { var agentTransform = Transform(); var activeActivity: Activity? = .init(id: "wish_machine.collect", phase: .loop) }
    let manifest = Manifest()
    var snapshot = Snapshot()
    struct ObjectState { var generatedProp: Bool?; var isEnabled = false }
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
    func send(_ text: String, imageURLs: [URL], worldContext: ResidentWorldContext, worldTools: ResidentConversationTools?, onCancel: @escaping @MainActor () -> Void) async throws -> String {
        calls += 1
        if let error { throw error }
        onSend?()
        return reply
    }
}
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
    var scope = "resident"
    private var residentWishImages: [URL: ResidentWishImageRegistration] = [:]
    private var residentWishScope: ResidentWishScope?
    \#(messageState)
    var notices: [String] = []
    func showResidentVoiceStatus(_ message: String) { notices.append(message) }
    let tools = ResidentConversationTools()
    func currentResidentWorldContext() -> ResidentWorldContext { .init(worldID: spatialStage.selectedWorldID, sessionScope: scope) }
    func ensureResidentLoop() -> ResidentAgentLoop { residentAgentLoop! }
    func makeResidentWorldTools(messageID: UUID, wishAuthorizationID: UUID?, allowsPausedWishClaim: Bool, allowsPropMutation: Bool) -> ResidentConversationTools? { tools }
    func synchronizeOwnedResidentProps() async {}
    func wishMachinePromptContext(_ world: ResidentWorldContext) -> String { "" }
    func reconcileResidentWishPlacements(_ world: ResidentWorldContext) throws {}
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
    func perform(_ input: ResidentAgentLoop.Input) async throws -> String { try await performResidentTurn(input) }
    func register(_ image: ResidentImageAttachment) { registerWishImages([image], loop: residentAgentLoop!, worldScope: scope) }
    func prepare(_ input: ResidentAgentLoop.Input) throws -> UUID? { try authorizeWishImages(input, worldContext: currentResidentWorldContext()) }
    func pause() { pauseResidentWishContinuations() }
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
        app.livingWorldContext!.snapshot.agentTransform.position.x += 1
        check(app.evidence(job)!.distanceMeters > 0.25, "resident away from pickup cannot satisfy arrival distance")
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
        placedApp.livingWorldContext!.state.objectStates[job.objectID] = .init(generatedProp: true, isEnabled: true)
        await placedApp.refresh()
        check(placedApp.stageWindowController!.tasks.first?.status == "已摆放", "actual manual placement is displayed even when the earlier automatic delegation remains revoked")
        check(placedApp.wishMachineCoordinator.placement?.state == .revoked, "displaying manual placement never revives or completes the revoked automatic delegation")
        placedApp.livingWorldContext!.state.objectStates[job.objectID]!.isEnabled = false
        await placedApp.refresh()
        check(placedApp.stageWindowController!.tasks.first?.status == "摆放已停止", "disabled inventory state does not masquerade as a current placement")
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
        check(renderApp.propGenerationStore.published[event.id] == nil && renderApp.spatialStage.wishMachineOutput == nil, "a late ready callback cannot implicitly retry an artifact with a persisted renderer failure")

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

import Foundation

/// Background scheduling shares the Host's conversation owner and authority context.
/// The run callback must expose background tools without a human generation grant.
@MainActor
final class UnityResidentAgentLoopBridge {
    static let enabledKey = "resident.autonomous.enabled.v1"
    let context: WorldAgentContext
    private let defaults: UserDefaults
    private let now: @MainActor () -> Date
    private let available: @MainActor () -> Bool
    private let run: @MainActor (ResidentAgentLoop.Input) async throws -> String
    private let cancelRun: @MainActor () -> Void
    private let reply: @MainActor (String) -> Void
    private let changed: @MainActor () -> Void
    private var ticker: Task<Void, Never>?
    private var closed = false
    private var humanTurn = false
    private var pausedForEditing = false
    private var started = false
    private var backgroundOwner: UUID?
    private(set) lazy var loop = ResidentAgentLoop(
        now: now,
        run: { [weak self] input in
            guard let self, !self.closed, !self.humanTurn, !self.pausedForEditing,
                  self.available(), input.isBackground, !input.isHumanOrderedTurn else {
                throw CancellationError()
            }
            self.backgroundOwner = input.runID
            defer {
                if self.backgroundOwner == input.runID { self.backgroundOwner = nil }
            }
            return try await self.run(input)
        },
        onReply: { [weak self] text in self?.reply(text) },
        onChange: { [weak self] in self?.changed() },
        onCancel: { [weak self] in
            guard let self, self.backgroundOwner != nil else { return }
            self.backgroundOwner = nil
            self.cancelRun()
        })

    init(context: WorldAgentContext, defaults: UserDefaults,
         now: @escaping @MainActor () -> Date = { Date() },
         available: @escaping @MainActor () -> Bool,
         run: @escaping @MainActor (ResidentAgentLoop.Input) async throws -> String,
         cancelRun: @escaping @MainActor () -> Void,
         onReply: @escaping @MainActor (String) -> Void,
         onChange: @escaping @MainActor () -> Void = {}) {
        self.context = context
        self.defaults = defaults
        self.now = now
        self.available = available
        self.run = run
        self.cancelRun = cancelRun
        reply = onReply
        changed = onChange
    }

    func start() {
        guard !closed, !started else { return }
        started = true
        refresh()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { break }
                guard let self, !self.closed else { break }
                self.refresh()
            }
        }
    }

    func refresh() {
        guard !closed else { return }
        if (!available() || humanTurn || pausedForEditing) && loop.snapshot.isBackgroundRun {
            loop.cancel()
        }
        let enabled = defaults.object(forKey: Self.enabledKey) == nil
            || defaults.bool(forKey: Self.enabledKey)
        loop.setBackgroundTurnsPerHour(ResidentPreferences(defaults: defaults).backgroundTurnsPerHour)
        loop.setBackgroundEnabled(started && enabled && available() && !humanTurn && !pausedForEditing)
        if started && available() && !humanTurn && !pausedForEditing { loop.tick() }
    }

    /// Call before chat.send, after validating the draft. Cancel only the background
    /// lease, then let the regular chat owner deliver the actual human submission.
    func humanTurnWillBegin() {
        guard !closed else { return }
        humanTurn = true
        if loop.snapshot.isBackgroundRun { loop.cancel() }
        loop.setBackgroundEnabled(false)
    }

    func humanTurnDidFinish() { humanTurn = false; refresh() }

    func setEditing(_ editing: Bool) { pausedForEditing = editing; refresh() }

    func pauseByUser() {
        guard !closed else { return }
        defaults.set(false, forKey: Self.enabledKey)
        loop.stop()
        refresh()
    }

    func resumeByUser() {
        guard !closed else { return }
        defaults.set(true, forKey: Self.enabledKey)
        _ = loop.resumeAutonomyByUser()
        refresh()
    }

    func receive(_ event: ResidentAgentLoop.Event) {
        guard !closed else { return }
        loop.receiveEvent(event)
    }

    /// An origin-scoped durable task result grants one existing-task continuation,
    /// subject to the loop's stop, budget, user-turn and editing gates.
    func receiveWish(_ event: ResidentAgentLoop.Event, continuation: Bool) -> Bool {
        guard !closed, !loop.snapshot.isInvalidated else { return false }
        if continuation && !loop.snapshot.isStopped { loop.receiveContinuationEvent(event) }
        else { loop.receiveEvent(event) }
        refresh()
        return true
    }

    func tools(runID: UUID) -> ResidentLoopTools {
        ResidentLoopTools(loop: loop, runID: runID, selfState: { [weak self] in
            guard let self, !self.closed else { return nil }
            let state = self.context.snapshot
            return ResidentSelfState(space: state.worldID,
                position: [Double(state.agentTransform.position.x), Double(state.agentTransform.position.y),
                           Double(state.agentTransform.position.z)],
                yawDegrees: nil, avatarFormat: nil, activityID: state.activeActivity?.id,
                activityPhase: state.activeActivity?.phase.rawValue,
                heldPropID: self.context.state.heldProp?.objectID)
        })
    }

    func snapshot() -> [String: Any] {
        let encoded = try? JSONEncoder().encode(loop.snapshot)
        var value = encoded.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        value["worldID"] = context.snapshot.worldID
        value["humanTurnActive"] = humanTurn
        value["status"] = closed ? "closed" : (!available() ? "backend_or_world_unavailable" : "ready")
        return value
    }

    func close() {
        guard !closed else { return }
        closed = true
        ticker?.cancel()
        ticker = nil
        loop.invalidate()
    }
}

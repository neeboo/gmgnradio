import Foundation

/// Planning owns proposals only; playback remains owned by UnityMediaHost.
@MainActor
final class UnityDJProgramBridge {
    struct Hooks {
        let plan: @MainActor (String) async throws -> ProgramPlan
        /// Must prepare and start through the host's existing player before returning.
        let activate: @MainActor (ProgramPlan) async throws -> Int
        let replaceUpcoming: @MainActor (ProgramPlan, Int) async throws -> Void
        let notify: @MainActor (String) async -> Void
        let restore: (@MainActor (ProgramPlan, Int) async throws -> Int)?
        let selectHistorical: (@MainActor (ProgramPlan, Int) async throws -> Int)?
        init(plan: @escaping @MainActor (String) async throws -> ProgramPlan,
             activate: @escaping @MainActor (ProgramPlan) async throws -> Int,
             replaceUpcoming: @escaping @MainActor (ProgramPlan, Int) async throws -> Void,
             notify: @escaping @MainActor (String) async -> Void,
             restore: (@MainActor (ProgramPlan, Int) async throws -> Int)? = nil,
             selectHistorical: (@MainActor (ProgramPlan, Int) async throws -> Int)? = nil) {
            self.plan = plan; self.activate = activate; self.replaceUpcoming = replaceUpcoming
            self.notify = notify; self.restore = restore
            self.selectHistorical = selectHistorical
        }
    }

    var historySnapshot: [String: Any] {
        let history = store.recentPrograms
        return ["status": "completed", "operation": "program-history", "programs": history.map { saved in
            ["id": saved.plan.brief.id, "name": saved.plan.title ?? "节目", "count": saved.plan.slots.count,
             "active": ownsPlayback && store.plan?.brief.id == saved.plan.brief.id,
             "pending": store.pendingPlan?.brief.id == saved.plan.brief.id,
             "activeSlotIndex": saved.activeSlotIndex as Any? ?? NSNull(),
             "tracks": saved.plan.slots.enumerated().map { index, slot in
                 ["index": index, "id": slot.track.id, "title": slot.track.title,
                  "artist": slot.track.artist, "duration": slot.track.duration] as [String: Any]
             }] as [String: Any]
        }]
    }

    /// History track clicks match SceneKit's explicit play selection semantics.
    /// Do not change archive/store selection until the sole player accepts it.
    func selectProgram(id: String, slotIndex: Int) async throws {
        guard !closed else { throw Failure.closed }
        guard !activating else { throw Failure.activating }
        guard let select = hooks.selectHistorical,
              let plan = store.recentPrograms.first(where: { $0.plan.brief.id == id })?.plan,
              plan.slots.indices.contains(slotIndex) else { throw Failure.noPreparedProgram }
        activating = true
        defer { activating = false }
        playbackLease &+= 1
        let lease = playbackLease
        task?.cancel(); task = nil; requestID = nil
        let index = try await select(plan, slotIndex)
        try Task.checkCancellation()
        guard !closed, playbackLease == lease else { throw CancellationError() }
        store.publish(plan)
        store.activateSlot(at: index)
        try await store.flush()
        ownsPlayback = true
    }
    enum Failure: LocalizedError {
        case noPreparedProgram, emptyProgram, closed, activating, noNewTrack
        var errorDescription: String? {
            switch self {
            case .noPreparedProgram: "尚无待切换节目。"
            case .emptyProgram: "编排没有返回可播歌曲。"
            case .closed: "节目服务已关闭。"
            case .activating: "正在切换节目，请稍后再编排。"
            case .noNewTrack: "编排没有找到尚未播放的插播歌曲。"
            }
        }
    }
    let store: DJProgramStore
    private let hooks: Hooks
    private var task: Task<Void, Never>?
    private var requestID: UUID?
    private var closed = false
    private var activating = false
    private var ownsPlayback = false
    private var playbackLease: UInt64 = 0
    private var attemptedRestore = false
    var activePlaybackPlan: ProgramPlan? { ownsPlayback ? store.plan : nil }

    init(archiveRoot: URL, hooks: Hooks, storage: MusicStorageClient) {
        store = DJProgramStore(archive: DJProgramArchive(storage: storage))
        self.hooks = hooks
    }

    /// Startup restoration prepares the archived slot paused. It never replans
    /// or calls the autoplay activation hook, and never repeats after takeover.
    @discardableResult
    func restoreSavedPlayback() async throws -> Bool {
        guard !closed else { throw Failure.closed }
        guard !attemptedRestore else { return false }
        await store.restoreLatest()
        if case let .failed(message) = store.status {
            throw NSError(domain: "MusicStorage", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        attemptedRestore = true
        guard let plan = store.plan, !plan.slots.isEmpty else { return false }
        guard let restore = hooks.restore else { return false }
        guard !activating else { throw Failure.activating }
        activating = true
        defer { activating = false }
        let lease = playbackLease
        do {
            let index = try await restore(plan, store.activeSlotIndex ?? 0)
            try Task.checkCancellation()
            guard !closed, lease == playbackLease else { throw CancellationError() }
            store.activateSlot(at: index)
            try await store.flush()
            ownsPlayback = true
            return true
        } catch {
            if !closed, lease == playbackLease, !(error is CancellationError) {
                store.fail("上次节目暂时无法继续播放：\(error.localizedDescription)")
            }
            throw error
        }
    }

    static func livePlanner(runtime: MusicRuntime, preferences: DJAgentPreferences) -> @MainActor (String) async throws -> ProgramPlan {
        { instruction in
            // Preferences holds UserDefaults, not model/persona values. Read them
            // when each request starts so saved settings affect the next plan.
            let agent = try CodexTrackRankingAgent.live(preferences: preferences)
            let hour = Calendar.current.component(.hour, from: Date())
            let tags = hour < 6 ? ["深夜", "松弛", "陪伴"] : hour < 11 ? ["清晨", "清醒", "明亮"] : hour < 18 ? ["白天", "专注", "流动"] : ["夜晚", "放松", "氛围"]
            let arc: [Double] = hour < 6 ? [0.2, 0.35, 0.25] : hour < 11 ? [0.35, 0.65, 0.55] : hour < 18 ? [0.45, 0.7, 0.55] : [0.4, 0.7, 0.35]
            return try await runtime.makeProgramPlan(brief: ProgramBrief(id: "program-\(UUID().uuidString)", targetDuration: 1_800, moodTags: tags, energyArc: arc, conversationMode: .ambient, immediateUserInstruction: instruction), agent: agent)
        }
    }

    func replan(immediateInstruction: String?) throws {
        try schedule(instruction: immediateInstruction ?? "根据当前状态重新编排后续节目", insertion: false)
    }
    func insert(immediateInstruction: String) throws {
        try schedule(instruction: immediateInstruction, insertion: true)
    }
    private func schedule(instruction: String, insertion: Bool) throws {
        guard !closed else { throw Failure.closed }
        guard !activating else { throw Failure.activating }
        task?.cancel()
        let id = UUID()
        requestID = id
        store.beginPlanning()
        task = Task { [weak self] in
            guard let self else { return }
            defer { if requestID == id { task = nil; requestID = nil } }
            do {
                let proposal = try await hooks.plan(insertion ? "只为下一首找一首可播歌曲。用户的插播要求：\(instruction)" : instruction)
                try Task.checkCancellation()
                guard !closed, requestID == id else { return }
                guard !proposal.slots.isEmpty else { throw Failure.emptyProgram }
                if insertion, ownsPlayback, let current = store.plan, let index = store.activeSlotIndex {
                    let playedIDs = Set(current.slots.prefix(index + 1).map { $0.track.id })
                    guard proposal.slots.contains(where: { !playedIDs.contains($0.track.id) }) else { throw Failure.noNewTrack }
                    let revised = DJProgramEditor.revise(current: current, activeSlotIndex: index, proposal: proposal, mode: .insertNext)
                    try await hooks.replaceUpcoming(revised, index)
                    try Task.checkCancellation()
                    guard !closed, requestID == id else { return }
                    store.publish(revised)
                    store.activateSlot(at: index)
                    try await store.flush()
                    await hooks.notify("后台插播完成，歌曲已排在当前歌曲之后；当前播放未切换。用户要求：\(instruction)")
                } else {
                    store.publishDraft(proposal)
                    try await store.flush()
                    await hooks.notify("后台节目已准备好：\(proposal.title ?? "新节目")，共 \(proposal.slots.count) 首。请告知用户并等待确认后调用 activate_prepared_program；此刻不要切换。用户要求：\(instruction)")
                }
            } catch is CancellationError {
            } catch {
                guard !closed, requestID == id else { return }
                store.fail(error.localizedDescription)
                await hooks.notify("后台编排失败：\(error.localizedDescription)。不要声称节目已准备好。")
            }
        }
    }
    func activate() async throws {
        guard !closed else { throw Failure.closed }
        guard !activating else { throw Failure.activating }
        guard let proposal = store.pendingPlan else { throw Failure.noPreparedProgram }
        activating = true
        playbackLease &+= 1
        defer { activating = false }
        // Cancel an outstanding proposal before the player yields. Otherwise a
        // newer draft could be published while activation is committing.
        task?.cancel()
        task = nil
        requestID = nil
        let index = try await hooks.activate(proposal)
        guard !closed else { throw Failure.closed }
        store.publish(proposal)
        store.activateSlot(at: index)
        try await store.flush()
        ownsPlayback = true
    }
    func activateSlot(at index: Int) { store.activateSlot(at: index) }
    func refreshHistory() async throws -> [String: Any] {
        try await store.refreshRecentPrograms()
        return historySnapshot
    }
    func releasePlayback() { playbackLease &+= 1; ownsPlayback = false }
    func shutdown() { closed = true; playbackLease &+= 1; requestID = nil; task?.cancel(); task = nil }
}

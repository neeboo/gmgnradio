import Foundation
import os

enum ProgramPlaybackQueueError: Error, Equatable, LocalizedError {
    case noPlayableSlots(failedTrackIDs: [String])

    var errorDescription: String? {
        switch self {
        case .noPlayableSlots:
            "这档节目里的歌曲暂时都无法播放。"
        }
    }
}

enum ProgramPlaybackToggleRoute: Equatable {
    case pauseLocal
    case resumeLocal
    case startPreparedProgram
    case unavailable

    static func resolve(
        playerState: LocalMusicPlaybackState,
        hasPreparedProgram: Bool
    ) -> ProgramPlaybackToggleRoute {
        switch playerState {
        case .playing:
            .pauseLocal
        case .ready, .paused, .finished:
            .resumeLocal
        case .idle:
            hasPreparedProgram ? .startPreparedProgram : .unavailable
        }
    }
}

enum ProgramPlaybackStartRoute: Equatable {
    case alreadyPlaying
    case resumeLocal
    case startPreparedProgram
    case unavailable

    static func resolve(
        playerState: LocalMusicPlaybackState,
        hasPreparedProgram: Bool
    ) -> ProgramPlaybackStartRoute {
        switch playerState {
        case .playing:
            .alreadyPlaying
        case .ready, .paused, .finished:
            .resumeLocal
        case .idle:
            hasPreparedProgram ? .startPreparedProgram : .unavailable
        }
    }
}

struct RestoredProgramPlayback {
    let plan: ProgramPlan
    let prepared: PreparedProgramPlayback
    let playbackState: LocalMusicPlaybackState
}

@MainActor
struct SavedProgramPlaybackRestorer {
    let queue: ProgramPlaybackQueue

    func restore(
        from store: DJProgramStore
    ) async throws -> RestoredProgramPlayback? {
        guard let plan = store.plan, !plan.slots.isEmpty else {
            return nil
        }
        try await queue.load(
            plan,
            startingAt: store.activeSlotIndex ?? 0
        )
        guard let prepared = queue.current else {
            return nil
        }
        return RestoredProgramPlayback(
            plan: plan,
            prepared: prepared,
            playbackState: .ready
        )
    }
}

@MainActor
final class ProgramPlaybackQueue {
    private struct Entry: Decodable { let slot: ProgramSlot; let resourceHandle: String }
    private struct State: Decodable {
        let generation: UInt64
        let current: Entry?
        let locked: [Entry]
        let reserve: [ProgramSlot]
        let failedTrackIDs: [String]
        let history: [Entry]
    }
    private struct Ticket: Decodable { let ticketID: String; let generation: UInt64; let slot: ProgramSlot; let kind: String }
    private struct Reply: Decodable { let state: State; let ticket: Ticket?; let selected: Entry? }
    private let preflight: PlaybackPreflight
    private let lockedCapacity: Int
    private let call: RustMusicProgramClient.Call
    private let queueID = UUID().uuidString
    private let hostSessionID = UUID().uuidString
    private var generation: UInt64 = 0
    private var resources: [String: PreparedProgramPlayback] = [:]
    private(set) var current: PreparedProgramPlayback?
    private(set) var locked: [PreparedProgramPlayback] = []
    private(set) var reserve: [ProgramSlot] = []
    private(set) var failedTrackIDs: [String] = []
    private(set) var history: [PreparedProgramPlayback] = []
    var canReturnToPrevious: Bool { !history.isEmpty }
    var canAdvance: Bool { !locked.isEmpty || !reserve.isEmpty }
    init(preflight: PlaybackPreflight, lockedCapacity: Int = 2, call: RustMusicProgramClient.Call? = nil) {
        self.preflight = preflight; self.lockedCapacity = max(0, lockedCapacity)
        let daemon = PropTaskDaemonClient()
        self.call = call ?? { try await daemon.call(method: $0, params: $1) }
    }
    private func request(_ op: String, _ input: [String: PropTaskJSON] = [:]) async throws -> Reply {
        var params = input
        params["op"] = .string(op); params["queueID"] = .string(queueID)
        params["hostSessionID"] = .string(hostSessionID); params["generation"] = .number(Double(generation))
        let result = try await call("music_program_playback_command", params)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let reply = try decoder.decode(Reply.self, from: JSONEncoder().encode(result))
        func prepared(_ entry: Entry) throws -> PreparedProgramPlayback {
            guard let value = resources[entry.resourceHandle], value.slot.track.id == entry.slot.track.id else {
                throw PropTaskDaemonError.invalidFrame
            }
            return value
        }
        let projectedCurrent = try reply.state.current.map(prepared)
        let projectedLocked = try reply.state.locked.map(prepared)
        let projectedHistory = try reply.state.history.map(prepared)
        generation = reply.state.generation; current = projectedCurrent
        locked = projectedLocked; history = projectedHistory
        reserve = reply.state.reserve; failedTrackIDs = reply.state.failedTrackIDs
        let liveHandles = Set(([reply.state.current].compactMap { $0 } + reply.state.locked + reply.state.history).map(\.resourceHandle))
        resources = resources.filter { liveHandles.contains($0.key) }
        return reply
    }
    private func execute(_ reply: Reply) async throws {
        var next = reply.ticket
        while let ticket = next {
            let prepared: PreparedProgramPlayback
            do { prepared = try await preflight.prepare(ticket.slot) }
            catch {
                let result = try await request("prepare_receipt", ["ticketID": .string(ticket.ticketID),
                    "trackID": .string(ticket.slot.track.id), "accepted": .bool(false)])
                if ticket.kind == "select" { throw error }
                next = result.ticket
                continue
            }
            let handle = UUID().uuidString; resources[handle] = prepared
            do {
                next = try await request("prepare_receipt", ["ticketID": .string(ticket.ticketID),
                    "trackID": .string(ticket.slot.track.id), "resourceHandle": .string(handle),
                    "accepted": .bool(true)]).ticket
            } catch { resources.removeValue(forKey: handle); throw error }
        }
    }
    func load(_ plan: ProgramPlan, startingAt requestedIndex: Int = 0) async throws {
        try await execute(request("load", ["programID": .string(plan.brief.id),
            "programRevision": .number(Double(plan.revision)),
            "startingIndex": .number(Double(requestedIndex)), "lockedCapacity": .number(Double(lockedCapacity))]))
        guard current != nil else { throw ProgramPlaybackQueueError.noPlayableSlots(failedTrackIDs: failedTrackIDs) }
    }
    func select(_ plan: ProgramPlan, at requestedIndex: Int) async throws {
        guard !plan.slots.isEmpty else { throw ProgramPlaybackQueueError.noPlayableSlots(failedTrackIDs: []) }
        try await execute(request("select", ["programID": .string(plan.brief.id), "programRevision": .number(Double(plan.revision)), "startingIndex": .number(Double(requestedIndex))]))
    }
    func replaceUpcoming(programID: String, programRevision: Int, startingAt index: Int) async throws {
        try await execute(request("replace_upcoming", ["programID": .string(programID), "programRevision": .number(Double(programRevision)), "startingIndex": .number(Double(index))]))
    }
    @discardableResult func advanceAfterCompletion() async throws -> PreparedProgramPlayback? {
        try await execute(request("advance")); return current
    }
    @discardableResult func returnToPrevious() async throws -> PreparedProgramPlayback? {
        let reply = try await request("previous")
        return reply.selected == nil ? nil : current
    }
    @discardableResult func replaceCurrentAfterFailure() async throws -> PreparedProgramPlayback? {
        try await execute(request("current_failed")); return current
    }
}

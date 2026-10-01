import Foundation

enum ResidentActivityOutcomeError: Error, LocalizedError, Equatable {
    case unsupportedPlaybackSource, effectAlreadyHandled, interrupted, timedOut
    case musicNotPrepared
    /// 这一轮的点唱机操作**不是被取消**，而是它的授权上下文变了（换了世界 / 换了
    /// 对话轮次 / 空间进了装修模式）。原因必须逐字带出来：真机上用户问的就是
    /// "为什么没出声"，"已取消"不是答案。
    case contextChanged(String)
    var errorDescription: String? {
        switch self {
        case .unsupportedPlaybackSource: "当前点唱机操作暂不支持该播放源，请使用播放器手动操作。"
        case .effectAlreadyHandled: "这次点唱机操作已经处理，无法再次确认播放结果。"
        case .interrupted: "本次点唱机操作已取消或被其他活动替换。"
        case .timedOut: "居民未能及时完成点唱机操作。"
        case .musicNotPrepared: "当前没有已准备的曲目，音乐尚未播放。可通过可用音乐工具查询状态和已有歌单。"
        case let .contextChanged(reason): "点唱机操作被提前结束：\(reason)。音乐尚未播放。"
        }
    }
}

/// Waits for one existing activity and player operation; it does not run a player.
@MainActor
final class ResidentActivityOutcome {
    @TaskLocal static var playbackOwner: UUID?

    private struct OwnedActivity {
        let callID: String
        let requestID: String
        let playbackID: UUID
        var playbackAttempted = false
    }
    private let context: WorldAgentContext
    private let isCurrent: @MainActor () -> Bool
    private let currentBlocker: @MainActor () -> String?
    private let play: @MainActor (UUID) async throws -> Void
    private let pause: @MainActor (UUID?) async throws -> Void
    private let sleep: @MainActor () async throws -> Void
    private let deadline: Date
    private var pendingStarts: Set<String> = []
    private var musicStops: Set<String> = []
    private var owned: OwnedActivity?
    private var aborted = false

    init(
        context: WorldAgentContext,
        isCurrent: @escaping @MainActor () -> Bool,
        currentBlocker: @escaping @MainActor () -> String? = { nil },
        play: @escaping @MainActor (UUID) async throws -> Void,
        pause: @escaping @MainActor (UUID?) async throws -> Void,
        sleep: @escaping @MainActor () async throws -> Void = {
            try await Task.sleep(nanoseconds: 50_000_000)
        },
        deadline: Date = Date().addingTimeInterval(180)
    ) {
        self.context = context
        self.isCurrent = isCurrent
        self.currentBlocker = currentBlocker
        self.play = play
        self.pause = pause
        self.sleep = sleep
        self.deadline = deadline
    }

    func prepare(callID: String, name: String, argumentsJSON: Data) {
        if name == "start_activity", isMusic(argumentsJSON) { pendingStarts.insert(callID) }
        if name == "stop_activity", context.state.activeActivity?.activityID == "music.listen" {
            musicStops.insert(callID)
        }
    }

    func suppressesAutomaticEffect(_ snapshot: WorldAgentSnapshot) -> Bool {
        guard snapshot.worldID == context.manifest.worldID,
              snapshot.activeActivity?.id == "music.listen" else { return false }
        return !pendingStarts.isEmpty || (owned != nil && ownsCurrentActivity())
    }

    func abort() {
        aborted = true
        guard let owned else { return }
        stopOwnedActivity()
        if owned.playbackAttempted {
            Task { try? await pause(owned.playbackID) }
        }
    }

    func complete(name: String, argumentsJSON: Data, result: RealtimeDJToolResult) async -> RealtimeDJToolResult {
        let wasMusicStop = musicStops.remove(result.callID) != nil
        pendingStarts.remove(result.callID)
        guard !result.isError else { return result }
        if name == "stop_activity", wasMusicStop {
            do {
                guard !aborted, !Task.isCancelled, isCurrent() else { throw ResidentActivityOutcomeError.interrupted }
                try await pause(nil)
                return response(result.callID, ok: true, code: "music_paused", message: "角色已停止活动，点唱机音乐已暂停。")
            } catch {
                return response(result.callID, ok: false, code: "music_pause_failed", message: "角色已停止活动，但音乐暂停失败，请检查播放器。")
            }
        }
        guard name == "start_activity", isMusic(argumentsJSON) else { return result }
        guard context.state.activeActivity?.activityID == "music.listen",
              let requestID = context.currentActivityRequestID else {
            return response(result.callID, ok: false, code: "activity_cancelled", message: "点唱机活动已经结束或被替换。")
        }
        let instance = OwnedActivity(callID: result.callID, requestID: requestID, playbackID: UUID())
        owned = instance
        defer { if owned?.callID == result.callID { owned = nil } }
        do {
            while true {
                try requireCurrent(instance)
                let phase = context.snapshot.activeActivity?.phase
                if phase == .loop { break }
                try await sleep()
            }
            try requireCurrent(instance)
            owned?.playbackAttempted = true
            try await play(instance.playbackID)
            try requireCurrent(instance)
            return response(result.callID, ok: true, code: "music_playing", message: "居民已到达点唱机，播放器正在播放音乐。")
        } catch {
            let attempted = owned?.callID == instance.callID && owned?.playbackAttempted == true
            if owned?.callID == instance.callID { stopOwnedActivity() }
            if attempted { try? await pause(instance.playbackID) }
            let code: String
            let message: String
            if let changed = error as? ResidentActivityOutcomeError,
               case let .contextChanged(reason) = changed {
                // 先判它：`contextChanged` 也满足 `!isCurrent()`，混进下一个分支就
                // 又变回"已取消"，原因再次丢失。
                code = "activity_context_changed"
                message = ResidentActivityOutcomeError.contextChanged(reason).localizedDescription
            } else if error is CancellationError || aborted || !isCurrent() || (error as? ResidentActivityOutcomeError) == .interrupted {
                code = "activity_cancelled"; message = "本次点唱机操作已取消或被其他活动替换。"
            } else if (error as? ResidentActivityOutcomeError) == .unsupportedPlaybackSource {
                code = "playback_source_unsupported"; message = ResidentActivityOutcomeError.unsupportedPlaybackSource.localizedDescription
            } else if (error as? ResidentActivityOutcomeError) == .timedOut {
                code = "activity_timed_out"; message = "居民未能及时完成点唱机操作。"
            } else if (error as? ResidentActivityOutcomeError) == .musicNotPrepared {
                code = "music_not_prepared"; message = ResidentActivityOutcomeError.musicNotPrepared.localizedDescription
            } else {
                code = "music_playback_failed"; message = "点唱机未能开始播放，音乐尚未播放。可通过可用音乐工具检查播放器状态。"
            }
            return response(result.callID, ok: false, code: code, message: message)
        }
    }

    private func requireCurrent(_ instance: OwnedActivity) throws {
        guard !aborted, !Task.isCancelled, owned?.callID == instance.callID,
              ownsCurrentActivity() else { throw ResidentActivityOutcomeError.interrupted }
        // 「不再 current」和「被取消」是两件事。混在一起报，用户只能听到"已取消"，
        // 而真实原因（换了世界 / 换了轮次 / 空间进了装修模式）无人知晓。
        guard isCurrent() else {
            throw ResidentActivityOutcomeError.contextChanged(
                currentBlocker() ?? "本轮点唱机操作的授权已经失效"
            )
        }
        guard Date() < deadline else { throw ResidentActivityOutcomeError.timedOut }
    }

    private func ownsCurrentActivity() -> Bool {
        guard let owned, let active = context.state.activeActivity else { return false }
        return active.activityID == "music.listen" && context.currentActivityRequestID == owned.requestID
    }

    private func stopOwnedActivity() {
        if ownsCurrentActivity() { try? context.stopActivity(reason: "点唱机操作结束") }
    }

    private func isMusic(_ data: Data) -> Bool {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["activity_id"] as? String == "music.listen"
    }

    private func response(_ callID: String, ok: Bool, code: String, message: String) -> RealtimeDJToolResult {
        let value = WorldAgentToolResponse(ok: ok, code: code, message: message, snapshot: context.snapshot, route: nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(value)) ?? Data("{\"ok\":false}".utf8)
        return RealtimeDJToolResult(callID: callID, resultJSON: data, isError: !ok)
    }
}

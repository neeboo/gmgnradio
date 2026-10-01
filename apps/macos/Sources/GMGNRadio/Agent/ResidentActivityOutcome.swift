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

/// 「点唱机这一次会不会出声、为什么」的报告单。
///
/// 宿主把它实现成**两个出口**：日志与屏上。每一条守卫都必须报——真机 2026-10-01 20:25
/// 的缺陷形态正是"工具回执里有一句 `music_not_prepared`，用户与日志里什么都没有"；
/// 静默的失败在真机上与"什么都没发生"无法区分。
enum JukeboxReport: Equatable {
    /// 过程中的事实（谁持有了这次尝试、走到哪一步、取消/替换）。
    case progress(String)
    /// 这一次不会出声，附**具名**原因。
    case silence(String)
    /// 已经真的开始播放。
    case playing(String)
}

/// 自动效果（`performLivingCabinJukeboxEffect`）这一次该不该自己动手。
///
/// **必须带名字**：被抑制也是一个事实（谁持有、为什么），屏幕与日志都要看得到。
/// `suppressesAutomaticEffect` 只是它的布尔投影，留给需要布尔判定的调用方。
enum JukeboxAutomaticEffectOwnership: Equatable {
    case automatic
    case held(reason: String)

    var suppressesEffect: Bool {
        if case .held = self { return true }
        return false
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
    /// 点唱机效果的唯一报告出口。**没有默认值**：构造它就必须给出"日志 + 屏上"的实现，
    /// 否则这条链又会退化成静默。
    private let report: @MainActor (JukeboxReport) -> Void
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
        report: @escaping @MainActor (JukeboxReport) -> Void,
        deadline: Date = Date().addingTimeInterval(180)
    ) {
        self.context = context
        self.isCurrent = isCurrent
        self.currentBlocker = currentBlocker
        self.play = play
        self.pause = pause
        self.sleep = sleep
        self.report = report
        self.deadline = deadline
    }

    func prepare(callID: String, name: String, argumentsJSON: Data) {
        if name == "start_activity", isMusic(argumentsJSON) {
            pendingStarts.insert(callID)
            report(.progress(
                "居民工具调用 start_activity 接管这次点唱机播放（call=\(callID)），自动效果不再重复触发"
            ))
        }
        if name == "stop_activity", context.state.activeActivity?.activityID == "music.listen" {
            musicStops.insert(callID)
            report(.progress("居民工具调用 stop_activity 接管这次点唱机暂停（call=\(callID)）"))
        }
    }

    /// 自动效果的持有者判定，**带名字**。真机必须用带名字的这一个：静默的抑制正是
    /// "点唱机没有声音却查不出原因"的来源（2026-10-01 20:25 的真机轨迹）。
    func automaticEffectOwnership(_ snapshot: WorldAgentSnapshot) -> JukeboxAutomaticEffectOwnership {
        guard snapshot.worldID == context.manifest.worldID,
              snapshot.activeActivity?.id == "music.listen" else { return .automatic }
        if !pendingStarts.isEmpty {
            return .held(
                reason: "这次播放由居民工具调用的 start_activity 持有（\(pendingStarts.count) 个调用在途），等它的回执"
            )
        }
        if owned != nil, ownsCurrentActivity() {
            return .held(reason: "这次播放由居民工具调用持有（居民正在走向点唱机，抵达 loop 后由它播放）")
        }
        return .automatic
    }

    func suppressesAutomaticEffect(_ snapshot: WorldAgentSnapshot) -> Bool {
        automaticEffectOwnership(snapshot).suppressesEffect
    }

    func abort() {
        aborted = true
        guard let owned else { return }
        report(.progress("点唱机操作被宿主中止（abort），这次播放尝试不再继续"))
        stopOwnedActivity()
        if owned.playbackAttempted {
            Task { try? await pause(owned.playbackID) }
        }
    }

    func complete(name: String, argumentsJSON: Data, result: RealtimeDJToolResult) async -> RealtimeDJToolResult {
        let wasMusicStop = musicStops.remove(result.callID) != nil
        pendingStarts.remove(result.callID)
        guard !result.isError else {
            if wasMusicStop || (name == "start_activity" && isMusic(argumentsJSON)) {
                report(.progress("居民工具调用 \(name) 本身失败了，点唱机不做额外动作（call=\(result.callID)）"))
            }
            return result
        }
        if name == "stop_activity", wasMusicStop {
            do {
                guard !aborted, !Task.isCancelled, isCurrent() else { throw ResidentActivityOutcomeError.interrupted }
                try await pause(nil)
                report(.progress("居民已停止活动，点唱机音乐已暂停"))
                return response(result.callID, ok: true, code: "music_paused", message: "角色已停止活动，点唱机音乐已暂停。")
            } catch {
                report(.silence("角色已停止活动，但音乐暂停失败（\(error.localizedDescription)）"))
                return response(result.callID, ok: false, code: "music_pause_failed", message: "角色已停止活动，但音乐暂停失败，请检查播放器。")
            }
        }
        guard name == "start_activity", isMusic(argumentsJSON) else { return result }
        guard context.state.activeActivity?.activityID == "music.listen",
              let requestID = context.currentActivityRequestID else {
            report(.silence("这一次的点唱机活动已经结束或被替换，播放没有发生"))
            return response(result.callID, ok: false, code: "activity_cancelled", message: "点唱机活动已经结束或被替换。")
        }
        let instance = OwnedActivity(callID: result.callID, requestID: requestID, playbackID: UUID())
        owned = instance
        defer { if owned?.callID == result.callID { owned = nil } }
        do {
            var announcedPhase = ""
            while true {
                try requireCurrent(instance)
                let phase = context.snapshot.activeActivity?.phase
                if phase == .loop { break }
                if let phase, phase.rawValue != announcedPhase {
                    announcedPhase = phase.rawValue
                    report(.progress(
                        "居民正在走向点唱机（phase=\(phase.rawValue)），抵达 loop 后开始播放（请求 \(requestID)）"
                    ))
                }
                try await sleep()
            }
            try requireCurrent(instance)
            owned?.playbackAttempted = true
            report(.progress("居民已抵达点唱机 loop，开始这一次播放尝试（请求 \(requestID)）"))
            try await play(instance.playbackID)
            try requireCurrent(instance)
            report(.playing("居民已抵达点唱机，播放器正在播放音乐（请求 \(requestID)）"))
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
            // 播放尝试**发出去之后**的失败（没有已准备曲目 / 播放源不支持 / 播放器没出声 /
            // 授权变了）由发起尝试的那一层具名上报（`resumeResidentJukebox` 逐条守卫都报），
            // 这里只补"尝试还没发出就失败"的那几种，避免同一次失败上屏两遍。
            if !attempted {
                report(.silence(jukeboxSilenceName(code: code, message: message)))
            }
            return response(result.callID, ok: false, code: code, message: message)
        }
    }

    /// 「为什么没出声」的具名说法。**按失败代码逐条命名**，不把通用文案当原因。
    private func jukeboxSilenceName(code: String, message: String) -> String {
        switch code {
        case "music_not_prepared": "没有已准备的曲目（\(message)）"
        case "playback_source_unsupported": "点唱机不支持这种播放源：曲目只有在线音源引用"
        case "activity_timed_out": "居民未能在时限内走到点唱机，播放没有发生"
        case "activity_context_changed": "这次点唱机操作失去了授权：\(message)"
        case "activity_cancelled": "这次点唱机操作已取消或被替换，播放没有发生"
        case "music_playback_failed": "播放器没有出声（\(message)）"
        default: message
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

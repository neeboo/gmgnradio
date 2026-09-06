import Foundation
import WorldRuntime

/// Translates committed in-memory world facts. Reasons remain data, never event type selectors.
enum ResidentWorldObservation {
    static func event(
        _ event: WorldEvent,
        worldID: String,
        scopeID: String
    ) -> ResidentAgentLoop.Event? {
        let kind: String
        let summary: String
        switch event.kind {
        case .worldLoaded:
            kind = "world_loaded"
            summary = "生活空间已载入，可以查询当前环境与可用活动。"
        case .worldRestored:
            kind = "world_restored"
            summary = "生活空间已恢复，请查询当前状态再继续安排活动。"
        case let .weatherChanged(weather):
            kind = "weather_changed"
            summary = "天气已变为：\(weather.rawValue)。"
        case let .activityStarted(id):
            kind = "activity_started"
            summary = "活动已开始：\(id)。开始不代表完成。"
        case let .activityCompleted(id):
            kind = "activity_completed"
            summary = "活动已完成：\(id)。"
        case let .activityCancelled(id, reason):
            kind = "activity_cancelled"
            summary = "活动已取消：\(id)。" + (reason.map { "记录原因：\($0)" } ?? "")
        case let .activityInterrupted(id, reason):
            kind = "activity_interrupted"
            summary = "活动已中断：\(id)。记录原因：\(reason)"
        case let .activityResumed(id):
            kind = "activity_resumed"
            summary = "活动已恢复：\(id)。"
        case let .goalCompleted(id):
            kind = "goal_completed"
            summary = "目标已完成：\(id)。"
        case .timeAdvanced, .timeCaughtUp, .agentTransformUpdated, .liveCameraChanged:
            return nil
        }
        return .init(
            id: "world:\(scopeID):\(worldID):\(event.sequence)",
            kind: kind,
            summary: String(summary.prefix(2000))
        )
    }
}

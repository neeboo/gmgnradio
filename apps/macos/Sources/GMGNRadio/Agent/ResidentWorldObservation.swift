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
        case .observationGap:
            // An honest delivery notice, never a world fact: the consumer lagged
            // beyond the retained event cache and some events were evicted before
            // they could be delivered. The world was NOT restored, so this is never
            // mapped to `world_restored` and never claims the living space recovered.
            kind = "observation_gap"
            summary = "世界事件观察存在缺口：序号 \(event.sequence) 之前你尚未读取的事件已超出保留窗口、无法补送；"
                + "这只是观察缺口，不代表世界已恢复或重置。请重新查询当前世界状态后再继续。"
        case let .weatherChanged(weather):
            kind = "weather_changed"
            summary = "天气已变为：\(weather.rawValue)。"
        case let .activityStarted(id):
            kind = "activity_started"
            summary = "活动已开始：\(id)。开始不代表完成。"
        case let .activityCompleted(id):
            kind = "activity_completed"
            summary = "活动已完成：\(id)。"
        case let .activityFailed(id, reason):
            kind = "activity_failed"
            summary = "活动执行失败：\(id)。记录原因：\(reason)"
        case let .movementCompleted(requestID, destinationID):
            kind = "movement_completed"
            summary = "已沿路线抵达：\(destinationID)。移动请求：\(requestID)。"
        case let .movementFailed(requestID, destinationID, reason):
            kind = "movement_failed"
            summary = "移动未完成：\(destinationID)。移动请求：\(requestID)。记录原因：\(reason)"
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
        case let .propLayoutChanged(objectID, layoutRevision):
            kind = "prop_layout_changed"
            summary = "物件布局已更新：\(objectID)，布局版本 \(layoutRevision)。请查询物件当前状态和位置，不沿用旧布局。"
        case let .propDeleted(objectID, displayName, layoutRevision, settled, _):
            kind = "prop_deleted"
            // 删除是一等事实：居民必须知道"这件东西**永久**没了"，否则它会照着旧清单
            // 去找一件已经不存在的物件，并把它读成"丢了"。
            summary = "物件已永久删除：\(displayName)（\(objectID)），布局版本 \(layoutRevision)，"
                + "收场方式 \(settled)。它不会再出现在库存里；不要重新生成、也不要继续引用它。"
        case .timeAdvanced, .timeCaughtUp, .agentTransformUpdated, .liveCameraChanged:
            return nil
        }
        // Real world events are deduplicated by `world:<scope>:<worldID>:<sequence>`.
        // The observation-gap notice is not a world event (it never entered the
        // simulation log) and its sequence is the eviction watermark, which can equal
        // a real event's sequence; it therefore gets its own identity namespace so the
        // resident's id-dedupe can neither swallow it nor confuse it with a real fact.
        let dedupeID: String
        if case .observationGap = event.kind {
            dedupeID = "observation-gap:\(scopeID):\(worldID):\(event.sequence)"
        } else {
            dedupeID = "world:\(scopeID):\(worldID):\(event.sequence)"
        }
        return .init(
            id: dedupeID,
            kind: kind,
            summary: String(summary.prefix(2000))
        )
    }
}

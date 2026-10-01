import Foundation

public enum WorldEventKind: Codable, Equatable, Sendable {
    case worldLoaded(worldID: String)
    case worldRestored(worldID: String)
    /// Host delivery notice, never a world mutation: a consumer lagged beyond the
    /// retained event cache, so its observation stream has an unfillable gap. The
    /// simulation never records this kind. `WorldAgentContext.publishObservations`
    /// emits it only as an honest re-observation signal whose identity never
    /// collides with a real `world:<scope>:<worldID>:<sequence>` event, and
    /// `ResidentWorldObservation` maps it to an `observation_gap` notice — never to
    /// `world_restored`, because the world has not been restored.
    case observationGap(worldID: String)
    case timeAdvanced(duration: TimeInterval)
    case timeCaughtUp(duration: TimeInterval)
    case agentTransformUpdated(transform: WorldTransform)
    case weatherChanged(weather: WorldWeather)
    case liveCameraChanged(camera: WorldCameraState)
    case activityStarted(activityID: String)
    case activityInterrupted(activityID: String, reason: String)
    case activityResumed(activityID: String)
    case activityCompleted(activityID: String)
    case activityCancelled(activityID: String, reason: String?)
    case activityFailed(activityID: String, reason: String)
    case movementCompleted(requestID: String, destinationID: String)
    case movementFailed(requestID: String, destinationID: String, reason: String)
    case goalCompleted(goalID: String)
    case propLayoutChanged(objectID: String, layoutRevision: UInt64)
    /// 一件生成资产被**永久删除**（墓碑 + 事实）。与权威 `world_facts` 里的
    /// `object.removed` 同族：删除是一件**具名事实**，不是"布局数值变了一下"。
    ///
    /// 负载里带上名字、结算动作与被释放的内容引用：回执与对账要回答的
    /// "删了什么、怎么收场的、释放了哪些共享内容" 在这一条事件里就齐了。
    case propDeleted(objectID: String, displayName: String, layoutRevision: UInt64,
                     settled: String, releasedBlobRefs: [String])
}

public struct WorldEvent: Codable, Equatable, Sendable {
    public let sequence: UInt64
    public let revision: UInt64
    public let worldTime: Date
    public let kind: WorldEventKind

    public init(
        sequence: UInt64,
        revision: UInt64,
        worldTime: Date,
        kind: WorldEventKind
    ) {
        self.sequence = sequence
        self.revision = revision
        self.worldTime = worldTime
        self.kind = kind
    }
}

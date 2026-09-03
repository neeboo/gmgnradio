import Foundation

public enum WorldEventKind: Codable, Equatable, Sendable {
    case worldLoaded(worldID: String)
    case worldRestored(worldID: String)
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
    case goalCompleted(goalID: String)
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

import Foundation

public enum WorldSimulationError: Error, Equatable, Sendable {
    case staleRevision(submitted: UInt64, current: UInt64)
    case invalidDuration(TimeInterval)
    case activityAlreadyActive(activityID: String)
    case noActiveActivity
    case activityIsNotInterrupted(activityID: String)
    case goalAlreadyCompleted(goalID: String)
}

public struct WorldSimulation: Sendable {
    public private(set) var state: WorldState
    public private(set) var events: [WorldEvent]

    public init(
        manifest: WorldManifest,
        startedAt: Date,
        weather: WorldWeather = .clear
    ) {
        state = WorldState(
            revision: 0,
            worldID: manifest.worldID,
            worldTime: startedAt,
            lastObservedWallTime: startedAt,
            weather: weather,
            agentTransform: manifest.spawn
        )
        events = [
            WorldEvent(
                sequence: 0,
                revision: 0,
                worldTime: startedAt,
                kind: .worldLoaded(worldID: manifest.worldID)
            ),
        ]
    }

    public init(restoring state: WorldState) {
        self.state = state
        events = [
            WorldEvent(
                sequence: 0,
                revision: state.revision,
                worldTime: state.worldTime,
                kind: .worldRestored(worldID: state.worldID)
            ),
        ]
    }

    @discardableResult
    public mutating func advance(
        by duration: TimeInterval,
        expectedRevision: UInt64
    ) throws -> WorldEvent {
        try validateRevision(expectedRevision)
        guard duration.isFinite, duration >= 0 else {
            throw WorldSimulationError.invalidDuration(duration)
        }

        state.worldTime = state.worldTime.addingTimeInterval(duration)
        if state.activeActivity?.status == .running {
            state.activeActivity?.elapsedActiveTime += duration
        }
        return record(.timeAdvanced(duration: duration))
    }

    @discardableResult
    public mutating func catchUp(
        to wallTime: Date,
        expectedRevision: UInt64
    ) throws -> WorldEvent {
        try validateRevision(expectedRevision)
        let duration = wallTime.timeIntervalSince(state.lastObservedWallTime)
        guard duration.isFinite, duration >= 0 else {
            throw WorldSimulationError.invalidDuration(duration)
        }

        state.worldTime = state.worldTime.addingTimeInterval(duration)
        state.lastObservedWallTime = wallTime
        if state.activeActivity?.status == .running {
            state.activeActivity?.elapsedActiveTime += duration
        }
        return record(.timeCaughtUp(duration: duration))
    }

    @discardableResult
    public mutating func updateAgentTransform(
        _ transform: WorldTransform,
        expectedRevision: UInt64
    ) throws -> WorldEvent {
        try validateRevision(expectedRevision)
        state.agentTransform = transform
        return record(.agentTransformUpdated(transform: transform))
    }

    @discardableResult
    public mutating func setWeather(
        _ weather: WorldWeather,
        expectedRevision: UInt64
    ) throws -> WorldEvent {
        try validateRevision(expectedRevision)
        state.weather = weather
        return record(.weatherChanged(weather: weather))
    }

    @discardableResult
    public mutating func setLiveCamera(
        _ camera: WorldCameraState,
        expectedRevision: UInt64
    ) throws -> WorldEvent {
        try validateRevision(expectedRevision)
        state.liveCamera = camera
        return record(.liveCameraChanged(camera: camera))
    }

    @discardableResult
    public mutating func startActivity(
        _ activityID: String,
        expectedRevision: UInt64
    ) throws -> WorldEvent {
        try validateRevision(expectedRevision)
        if let activeActivity = state.activeActivity {
            throw WorldSimulationError.activityAlreadyActive(
                activityID: activeActivity.activityID
            )
        }

        state.activeActivity = WorldActivityState(
            activityID: activityID,
            status: .running,
            startedAt: state.worldTime
        )
        return record(.activityStarted(activityID: activityID))
    }

    @discardableResult
    public mutating func interruptActivity(
        reason: String,
        expectedRevision: UInt64
    ) throws -> WorldEvent {
        try validateRevision(expectedRevision)
        guard var activity = state.activeActivity else {
            throw WorldSimulationError.noActiveActivity
        }
        guard activity.status == .running else {
            throw WorldSimulationError.activityIsNotInterrupted(
                activityID: activity.activityID
            )
        }

        activity.status = .interrupted
        activity.interruptionReason = reason
        state.activeActivity = activity
        return record(
            .activityInterrupted(
                activityID: activity.activityID,
                reason: reason
            )
        )
    }

    @discardableResult
    public mutating func resumeActivity(
        expectedRevision: UInt64
    ) throws -> WorldEvent {
        try validateRevision(expectedRevision)
        guard var activity = state.activeActivity else {
            throw WorldSimulationError.noActiveActivity
        }
        guard activity.status == .interrupted else {
            throw WorldSimulationError.activityIsNotInterrupted(
                activityID: activity.activityID
            )
        }

        activity.status = .running
        activity.interruptionReason = nil
        state.activeActivity = activity
        return record(.activityResumed(activityID: activity.activityID))
    }

    @discardableResult
    public mutating func completeActivity(
        expectedRevision: UInt64
    ) throws -> WorldEvent {
        try validateRevision(expectedRevision)
        guard let activity = state.activeActivity else {
            throw WorldSimulationError.noActiveActivity
        }

        state.activeActivity = nil
        return record(.activityCompleted(activityID: activity.activityID))
    }

    @discardableResult
    public mutating func cancelActivity(
        reason: String? = nil,
        expectedRevision: UInt64
    ) throws -> WorldEvent {
        try validateRevision(expectedRevision)
        guard let activity = state.activeActivity else {
            throw WorldSimulationError.noActiveActivity
        }

        state.activeActivity = nil
        return record(.activityCancelled(
            activityID: activity.activityID,
            reason: reason
        ))
    }

    @discardableResult
    public mutating func completeGoal(
        _ goalID: String,
        summary: String? = nil,
        expectedRevision: UInt64
    ) throws -> WorldEvent {
        try validateRevision(expectedRevision)
        guard state.completedGoals[goalID] == nil else {
            throw WorldSimulationError.goalAlreadyCompleted(goalID: goalID)
        }

        state.completedGoals[goalID] = WorldGoalState(
            goalID: goalID,
            completedAt: state.worldTime,
            summary: summary
        )
        return record(.goalCompleted(goalID: goalID))
    }

    private func validateRevision(_ submitted: UInt64) throws {
        guard submitted == state.revision else {
            throw WorldSimulationError.staleRevision(
                submitted: submitted,
                current: state.revision
            )
        }
    }

    private mutating func record(_ kind: WorldEventKind) -> WorldEvent {
        state.revision += 1
        let event = WorldEvent(
            sequence: events.last.map { $0.sequence + 1 } ?? 0,
            revision: state.revision,
            worldTime: state.worldTime,
            kind: kind
        )
        events.append(event)
        return event
    }
}

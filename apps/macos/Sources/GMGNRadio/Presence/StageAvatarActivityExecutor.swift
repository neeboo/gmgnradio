import Foundation
import WorldRuntime
import os
import simd

enum StageAvatarActivityApplyOutcome: Equatable, Sendable {
    case applied(StageAvatarWorldActivitySnapshot)
    case unchanged(sourceRevision: UInt64)
    case cleared(sourceRevision: UInt64)
    case rejectedStale(submitted: UInt64, latest: UInt64)
}

/// Smooths horizontal ground speed from consecutive world transform samples.
///
/// The executor consumes one agent snapshot per world tick; each sample is the
/// horizontal displacement since the previous sample divided by the measured
/// wall time, low-passed with an exponential filter. Long gaps decay the
/// estimate so a stalled or suspended world reports standstill instead of
/// keeping a stale walking rate, and curves/blocks (which reduce per-tick
/// displacement) are reflected immediately rather than assumed at the authored
/// navigation speed.
struct StageAvatarGroundSpeedMeter: Equatable, Sendable {
    /// Low-pass time constant; ~3 world ticks at 30 Hz to react to stop/start.
    static let smoothingTimeConstant: Float = 0.12

    private(set) var measuredSpeed: Float = 0
    private var lastPositionXZ: SIMD2<Float>?
    private var lastSampleTime: TimeInterval?
    private var hasEstimate = false

    mutating func record(
        horizontalX: Float,
        horizontalZ: Float,
        at time: TimeInterval
    ) -> Float {
        guard horizontalX.isFinite, horizontalZ.isFinite else {
            return measuredSpeed
        }
        let xz = SIMD2<Float>(horizontalX, horizontalZ)
        defer {
            lastPositionXZ = xz
            lastSampleTime = time
        }
        guard let lastPositionXZ,
              let lastSampleTime,
              time > lastSampleTime,
              (time - lastSampleTime).isFinite
        else {
            return measuredSpeed
        }
        let dt = Float(time - lastSampleTime)
        guard dt > 0, dt.isFinite else { return measuredSpeed }
        let displacement = simd_length(xz - lastPositionXZ)
        guard displacement.isFinite else { return measuredSpeed }
        let instantaneous = displacement / dt
        guard instantaneous.isFinite else { return measuredSpeed }
        // Long gaps make the sample an average over the whole pause; alpha -> 1.
        let alpha = 1 - exp(-dt / Self.smoothingTimeConstant)
        let updated = hasEstimate
            ? measuredSpeed + alpha * (instantaneous - measuredSpeed)
            : instantaneous
        measuredSpeed = max(0, min(max(updated, 0), 64))
        hasEstimate = true
        return measuredSpeed
    }

    mutating func reset() {
        measuredSpeed = 0
        lastPositionXZ = nil
        lastSampleTime = nil
        hasEstimate = false
    }
}

/// Commits a world tick to the visible avatar without mutating the user's
/// selected model/motion revision or the independent voice/facial overlay.
@MainActor
final class StageAvatarActivityExecutor {
    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ai.gmgn.radio",
        category: "StageAvatarActivityExecutor"
    )

    private let runtime: StageAvatarRuntimeStore
    private let spatialStage: SpatialStageStore
    private let worldSpawn: WorldTransform
    private let clock: () -> TimeInterval
    private var latestSourceRevision: UInt64?
    private var groundSpeedMeter = StageAvatarGroundSpeedMeter()

    init(
        runtime: StageAvatarRuntimeStore,
        spatialStage: SpatialStageStore,
        worldSpawn: WorldTransform,
        clock: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.runtime = runtime
        self.spatialStage = spatialStage
        self.worldSpawn = worldSpawn
        self.clock = clock
    }

    @discardableResult
    func apply(
        transform: WorldTransform,
        activity: LifeActivity,
        phase: LifeActivityPhase,
        sourceRevision: UInt64,
        activityRequestID: String? = nil,
        phaseContract: ActivityPhaseContract? = nil,
        approvedMotions: [String: StageMotionAsset] = [:]
    ) -> StageAvatarActivityApplyOutcome {
        if let latestSourceRevision, sourceRevision <= latestSourceRevision {
            return .rejectedStale(
                submitted: sourceRevision,
                latest: latestSourceRevision
            )
        }

        let matchingContract = phaseContract?.phase == phase
            ? phaseContract
            : nil
        let playback = StageAvatarMotionPlayback.resolve(
            activity: activity,
            phase: phase,
            phaseContract: matchingContract,
            approvedMotions: approvedMotions
        )
        // Ground-speed telemetry is recorded before the unchanged short-circuit
        // so a standing or moving world keeps reporting on every applied tick.
        let measuredSpeed = groundSpeedMeter.record(
            horizontalX: transform.position.x,
            horizontalZ: transform.position.z,
            at: clock()
        )
        let locomotionTelemetry = StageAvatarLocomotionTelemetry(
            measuredSpeed: measuredSpeed,
            isLocomotionActive: locomotionAsset(from: playback) != nil,
            sourceRevision: sourceRevision
        )
        runtime.updateLocomotion(locomotionTelemetry)
        let snapshot = StageAvatarWorldActivitySnapshot(
            transform: transform,
            activity: activity,
            phase: phase,
            motionPlayback: playback,
            sourceRevision: sourceRevision,
            activityRequestID: activityRequestID
        )
        let placement = StageAvatarPlacement(
            position: SIMD3<Float>(
                transform.position.x - worldSpawn.position.x,
                transform.position.y - worldSpawn.position.y,
                transform.position.z - worldSpawn.position.z
            ),
            scale: spatialStage.avatarPlacement.scale,
            yaw: Self.yaw(from: transform.rotation)
                - Self.yaw(from: worldSpawn.rotation)
        )

        if let current = runtime.worldActivity,
           current.transform == snapshot.transform,
           current.activity == snapshot.activity,
           current.phase == snapshot.phase,
           current.activityRequestID == snapshot.activityRequestID,
           current.motionPlayback == snapshot.motionPlayback
        {
            latestSourceRevision = sourceRevision
            return .unchanged(sourceRevision: sourceRevision)
        }

        // Playback resolution is completed before either observable store is
        // changed, keeping the visible transform and activity snapshot in one
        // main-actor commit.
        let playbackChanged = runtime.worldActivity?.motionPlayback != playback
        let phaseChanged = runtime.worldActivity?.phase != phase
        latestSourceRevision = sourceRevision
        runtime.installWorldActivity(snapshot)
        spatialStage.setWorldAvatarPlacement(placement)

        if case let .temporary(motion) = playback,
           playbackChanged || phaseChanged
        {
            let fileName = motion.url?.lastPathComponent ?? "nil"
            Self.log.notice(
                "Resolved activity motion activity=\(activity.typeID, privacy: .public) phase=\(phase.rawValue, privacy: .public) id=\(motion.id, privacy: .public) file=\(fileName, privacy: .public)"
            )
        } else if let fallback = playback.fallback {
            let requested = fallback.requestedMotionIDs.joined(separator: ",")
            Self.log.notice(
                "Falling back to natural idle activity=\(fallback.activityTypeID, privacy: .public) phase=\(fallback.phase.rawValue, privacy: .public) reason=\(fallback.reason.rawValue, privacy: .public) requested=\(requested, privacy: .public)"
            )
        }
        return .applied(snapshot)
    }

    @discardableResult
    func finish(sourceRevision: UInt64) -> StageAvatarActivityApplyOutcome {
        clear(sourceRevision: sourceRevision)
    }

    @discardableResult
    func clear(sourceRevision: UInt64) -> StageAvatarActivityApplyOutcome {
        if let latestSourceRevision, sourceRevision <= latestSourceRevision {
            return .rejectedStale(
                submitted: sourceRevision,
                latest: latestSourceRevision
            )
        }

        latestSourceRevision = sourceRevision
        runtime.clearWorldActivity()
        runtime.updateLocomotion(.standing)
        groundSpeedMeter.reset()
        spatialStage.clearTransientAvatarPlacement()
        return .cleared(sourceRevision: sourceRevision)
    }

    private func locomotionAsset(
        from playback: StageAvatarMotionPlayback
    ) -> StageMotionAsset? {
        guard case let .temporary(motion) = playback,
              motion.isLocomotionLoop
        else { return nil }
        return motion
    }

    private static func yaw(from rotation: WorldQuaternion) -> Float {
        let numerator = 2 * (
            rotation.w * rotation.y + rotation.x * rotation.z
        )
        let denominator = 1 - 2 * (
            rotation.y * rotation.y + rotation.z * rotation.z
        )
        return atan2(numerator, denominator)
    }
}

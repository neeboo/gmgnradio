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
    private var latestSourceRevision: UInt64?

    init(
        runtime: StageAvatarRuntimeStore,
        spatialStage: SpatialStageStore,
        worldSpawn: WorldTransform
    ) {
        self.runtime = runtime
        self.spatialStage = spatialStage
        self.worldSpawn = worldSpawn
    }

    @discardableResult
    func apply(
        transform: WorldTransform,
        activity: LifeActivity,
        phase: LifeActivityPhase,
        sourceRevision: UInt64,
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
        let snapshot = StageAvatarWorldActivitySnapshot(
            transform: transform,
            activity: activity,
            phase: phase,
            motionPlayback: playback,
            sourceRevision: sourceRevision
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
        spatialStage.clearTransientAvatarPlacement()
        return .cleared(sourceRevision: sourceRevision)
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

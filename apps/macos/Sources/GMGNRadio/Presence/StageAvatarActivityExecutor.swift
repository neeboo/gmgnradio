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
    /// Long-window companion used to retime the visible clip. The snapshot
    /// cadence is not the render cadence, so single samples can land on a
    /// stalled tick; the gait must not read that as "stopped".
    static let sustainedTimeConstant: Float = 0.4

    private(set) var measuredSpeed: Float = 0
    /// Smooth travel estimate over ``sustainedTimeConstant``.
    private(set) var sustainedSpeed: Float = 0
    /// True when the latest sample showed real displacement: the world is
    /// translating the avatar, as opposed to a sample that merely arrived.
    private(set) var isTranslating = false
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
            isTranslating = false
            return measuredSpeed
        }
        let dt = Float(time - lastSampleTime)
        guard dt > 0, dt.isFinite else { return measuredSpeed }
        let displacement = simd_length(xz - lastPositionXZ)
        guard displacement.isFinite else { return measuredSpeed }
        isTranslating = displacement > 0.00001
        let instantaneous = displacement / dt
        guard instantaneous.isFinite else { return measuredSpeed }
        // Long gaps make the sample an average over the whole pause; alpha -> 1.
        let alpha = 1 - exp(-dt / Self.smoothingTimeConstant)
        let updated = hasEstimate
            ? measuredSpeed + alpha * (instantaneous - measuredSpeed)
            : instantaneous
        measuredSpeed = max(0, min(max(updated, 0), 64))
        let sustainedAlpha = 1 - exp(-dt / Self.sustainedTimeConstant)
        let sustained = hasEstimate
            ? sustainedSpeed + sustainedAlpha * (instantaneous - sustainedSpeed)
            : instantaneous
        sustainedSpeed = max(0, min(max(sustained, 0), 64))
        hasEstimate = true
        return measuredSpeed
    }

    mutating func reset() {
        measuredSpeed = 0
        sustainedSpeed = 0
        isTranslating = false
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
    /// Last (activity, phase) whose locomotion had no playable clip at all.
    /// Keeps "moving without a walking pose" a single report per episode
    /// instead of a per-tick flood, without ever letting it go unreported.
    private var lastUnwalkableKey: String?

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
        // Ground-speed telemetry is recorded before the motion is resolved: the
        // visible decision ("this avatar's ground is moving, so it must have a
        // walking pose") comes from the same measurement the renderer retimes
        // the clip with, so selection and playback can never disagree.
        let measuredSpeed = groundSpeedMeter.record(
            horizontalX: transform.position.x,
            horizontalZ: transform.position.z,
            at: clock()
        )
        let isLocomoting = Self.isLocomoting(
            phase: phase,
            measuredSpeed: measuredSpeed
        )
        let avatarFormat = runtime.snapshot.avatar?.format
        // The renderer can only load a container that matches the active
        // avatar: handing a `.vrma` to the PMX path is a silent `clearMotion()`
        // (rest pose), not a fallback. Drop those before selection, so a
        // declared-but-unplayable clip is treated exactly like "declared
        // nothing" — and reported as the substitution it is.
        let playableMotions = approvedMotions.filter {
            ResidentLocomotionMotionPolicy.isPlayable($0.value, on: avatarFormat)
        }
        let declaredMotionIDs = matchingContract?.motionIDs ?? []
        let defaultMotionIDs = Self.defaultMotionIDs(
            phase: phase,
            matchingContract: matchingContract,
            isLocomoting: isLocomoting,
            approvedMotions: playableMotions,
            avatarFormat: avatarFormat
        )
        let playback = StageAvatarMotionPlayback.resolve(
            activity: activity,
            phase: phase,
            phaseContract: Self.effectiveContract(
                matchingContract: matchingContract,
                phase: phase,
                isLocomoting: isLocomoting,
                defaultMotionIDs: defaultMotionIDs
            ),
            approvedMotions: playableMotions
        )
        let locomotionTelemetry = StageAvatarLocomotionTelemetry(
            measuredSpeed: measuredSpeed,
            sustainedSpeed: groundSpeedMeter.sustainedSpeed,
            isWorldMoving: groundSpeedMeter.isTranslating
                || isLocomoting,
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
            // A default substitution is reported as loudly as the resolution
            // itself: "the world declared no walking motion" is a fact the
            // operator needs, not an implementation detail.
            if !declaredMotionIDs.contains(motion.id) {
                let declared = declaredMotionIDs.isEmpty
                    ? "none"
                    : declaredMotionIDs.joined(separator: ",")
                Self.log.notice(
                    "Defaulting to built-in \(isLocomoting ? "walk" : "idle", privacy: .public) motion activity=\(activity.typeID, privacy: .public) phase=\(phase.rawValue, privacy: .public) id=\(motion.id, privacy: .public) reason=\(isLocomoting ? "locomotion" : "phaseDeclaredNoMotion", privacy: .public) declared=\(declared, privacy: .public)"
                )
            }
            lastUnwalkableKey = nil
        } else if let fallback = playback.fallback {
            let requested = fallback.requestedMotionIDs.joined(separator: ",")
            Self.log.notice(
                "Falling back to natural idle activity=\(fallback.activityTypeID, privacy: .public) phase=\(fallback.phase.rawValue, privacy: .public) reason=\(fallback.reason.rawValue, privacy: .public) requested=\(requested, privacy: .public)"
            )
        }
        // Moving with no playable walking clip is the one degradation that must
        // never be silent: the world keeps translating the avatar, so a still
        // body reads as "sliding". Report it once per (activity, phase) and
        // never hide it behind the ordinary fallback line above.
        if isLocomoting, case .naturalIdle = playback {
            let key = "\(activityRequestID ?? "none")#\(activity.typeID)#\(phase.rawValue)"
            if lastUnwalkableKey != key {
                lastUnwalkableKey = key
                let candidates = (
                    declaredMotionIDs + defaultMotionIDs
                ).joined(separator: ",")
                Self.log.error(
                    "No usable walking motion: the avatar is moving without a walk clip activity=\(activity.typeID, privacy: .public) phase=\(phase.rawValue, privacy: .public) avatarFormat=\(avatarFormat?.rawValue ?? "none", privacy: .public) candidates=\(candidates, privacy: .public)"
                )
            }
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

    /// Is this avatar's ground actually moving?
    ///
    /// `.approach` is the executor's own walking phase — `ActivityExecutor`
    /// only ever leaves it by arriving, so it is authoritative from the first
    /// tick, before a second position sample exists to measure. Every other
    /// phase is judged by the measured ground speed, so a patrol that keeps
    /// walking through `.loop` still counts, and a settled avatar does not.
    static func isLocomoting(
        phase: LifeActivityPhase,
        measuredSpeed: Float
    ) -> Bool {
        if phase == .approach { return true }
        return measuredSpeed.isFinite && measuredSpeed > StageLocomotionGait.freezeSpeed
    }

    /// Motion ids to append after a phase's declared ids.
    ///
    /// `.enter` and `.exit` are deliberately untouched: a generated-prop
    /// capability's enter phase is a receipt-driven gate the host fails closed
    /// on (`isNaturalIdleFallback` + `isPropCapabilityActivity`), so silently
    /// giving it a clip would turn "the motion is missing" into "the usage
    /// succeeded". `.failed`/`.interrupt` resolve to the inactive-phase
    /// fallback before any id is read. `matchingContract == nil` is genuine
    /// user idle: the user's selected/thinking/idle chain owns that case
    /// unless the ground is moving, in which case locomotion wins.
    static func defaultMotionIDs(
        phase: LifeActivityPhase,
        matchingContract: ActivityPhaseContract?,
        isLocomoting: Bool,
        approvedMotions: [String: StageMotionAsset],
        avatarFormat: StageAvatarFormat?
    ) -> [String] {
        switch phase {
        case .failed, .interrupt, .enter, .exit:
            return []
        case .approach:
            return ResidentLocomotionMotionPolicy.defaultMotionIDs(
                isLocomoting: true,
                approvedMotions: approvedMotions,
                avatarFormat: avatarFormat
            )
        case .loop:
            guard matchingContract != nil || isLocomoting else { return [] }
            return ResidentLocomotionMotionPolicy.defaultMotionIDs(
                isLocomoting: isLocomoting,
                approvedMotions: approvedMotions,
                avatarFormat: avatarFormat
            )
        }
    }

    /// The contract handed to the resolver: the world's declaration first, the
    /// locomotion/idle default after it. `nil` only for genuine user idle that
    /// is not moving, which keeps the pre-existing selected-motion chain.
    static func effectiveContract(
        matchingContract: ActivityPhaseContract?,
        phase: LifeActivityPhase,
        isLocomoting: Bool,
        defaultMotionIDs: [String]
    ) -> ActivityPhaseContract? {
        if matchingContract == nil, !isLocomoting { return nil }
        if defaultMotionIDs.isEmpty, let matchingContract { return matchingContract }
        return ActivityPhaseContract(
            phase: phase,
            requiredAnchorIDs: matchingContract?.requiredAnchorIDs ?? [],
            motionIDs: (matchingContract?.motionIDs ?? []) + defaultMotionIDs,
            propIDs: matchingContract?.propIDs ?? [],
            durationSeconds: matchingContract?.durationSeconds
        )
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

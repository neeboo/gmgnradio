import Foundation
import WorldRuntime

/// The temporary full-body playback selected for a living-world activity.
///
/// Only motions supplied through `approvedMotions` may be selected. The
/// user's long-lived `MotionPackageStore` selection is deliberately outside
/// this resolver, so an unrelated or license-restricted dance never becomes
/// an implicit walk, sit, gaze, or listening animation.
enum StageAvatarMotionPlayback: Equatable, Sendable {
    case temporary(StageMotionAsset)
    case naturalIdle(fallback: StageAvatarMotionFallback?)

    var fallback: StageAvatarMotionFallback? {
        guard case let .naturalIdle(fallback) = self else { return nil }
        return fallback
    }

    var isNaturalIdleFallback: Bool {
        fallback != nil
    }

    static func resolve(
        activity: LifeActivity,
        phase: LifeActivityPhase,
        phaseContract: ActivityPhaseContract?,
        approvedMotions: [String: StageMotionAsset]
    ) -> StageAvatarMotionPlayback {
        guard phase != .failed, phase != .interrupt else {
            return .naturalIdle(
                fallback: StageAvatarMotionFallback(
                    activityTypeID: activity.typeID,
                    phase: phase,
                    requestedMotionIDs: [],
                    reason: .inactivePhase
                )
            )
        }

        let requestedMotionIDs = phaseContract?.motionIDs ?? []
        if let motion = requestedMotionIDs.lazy.compactMap({
            approvedMotions[$0]
        }).first {
            return .temporary(motion)
        }

        if activity == .idle, requestedMotionIDs.isEmpty {
            return .naturalIdle(fallback: nil)
        }

        return .naturalIdle(
            fallback: StageAvatarMotionFallback(
                activityTypeID: activity.typeID,
                phase: phase,
                requestedMotionIDs: requestedMotionIDs,
                reason: requestedMotionIDs.isEmpty
                    ? .phaseHasNoApprovedMotion
                    : .approvedMotionUnavailable
            )
        )
    }
}

/// The full-body motion that should be visible after combining the user's
/// long-lived selection with the living-world activity overlay.
///
/// A genuine idle state may keep the user's selected dance. When a semantic
/// activity requested an unavailable motion, the safe fallback is the
/// authored rest/natural-idle pose instead of pretending that the dance is a
/// walk, sit, gaze, or cooking motion.
enum StageAvatarResolvedMotion: Equatable, Sendable {
    case asset(StageMotionAsset)
    case naturalIdle

    static func resolve(
        selectedMotion: StageMotionAsset?,
        worldPlayback: StageAvatarMotionPlayback?,
        residentThinkingMotion: StageMotionAsset? = nil,
        heldDisplayMotion: StageMotionAsset? = nil,
        naturalIdleMotion: StageMotionAsset? = nil
    ) -> StageAvatarResolvedMotion {
        switch worldPlayback {
        case let .temporary(motion):
            return .asset(motion)
        case .naturalIdle(fallback: .some):
            return naturalIdleMotion.map(Self.asset) ?? .naturalIdle
        case .naturalIdle(fallback: nil), nil:
            return (heldDisplayMotion ?? residentThinkingMotion ?? selectedMotion ?? naturalIdleMotion)
                .map(Self.asset) ?? .naturalIdle
        }
    }
}

struct StageAvatarMotionFallback: Equatable, Sendable {
    let activityTypeID: String
    let phase: LifeActivityPhase
    let requestedMotionIDs: [String]
    let reason: StageAvatarMotionFallbackReason
}

enum StageAvatarMotionFallbackReason: String, Equatable, Sendable {
    case phaseHasNoApprovedMotion
    case approvedMotionUnavailable
    case inactivePhase
}

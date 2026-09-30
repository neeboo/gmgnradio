import Foundation

/// Which clip the visible avatar must play when the world/activity declaration
/// is silent.
///
/// The user-visible contract this exists for: **an avatar whose ground is
/// moving always has a walking pose.** Before this policy the resolver only
/// ever played what a phase contract declared; a contract that declared
/// nothing (`wish_machine.collect.approach` is `motionIDs: []` in the cabin
/// package) produced "natural idle", and *no* contract at all produced the
/// user's selected or thinking clip — in both cases the world kept translating
/// the avatar, so it glided across the floor in a standing pose. Nothing in
/// that chain was wrong "loudly": the phase was legal, the motion list was
/// legal, and the result was a still body that moved.
///
/// The defaults are deliberately *clips*, never invented keyframes
/// (`PMXStageAvatarRenderer.naturalIdleMotion` keeps its "never invent a
/// replacement motion" contract): every candidate below must already be
/// approved by the host's motion allow-list with a usable URL and a format the
/// active avatar can play. A user's dance can therefore never turn into a walk
/// (`approvedInstalledMotions` still owns that allow-list), and a missing
/// package is reported instead of papered over.
enum ResidentLocomotionMotionPolicy {
    static let walkLoopIDPrefix = "gmgn.motion.bones.walk-loop-"
    static let idleLoopIDPrefix = "gmgn.motion.bones.idle-loop-"

    /// Preferred → tail walking clips for one avatar format. The first entry is
    /// the resident's own navigation clip: `LivingWorldBootstrap` already
    /// derives the world's walking cadence from exactly this id, so a moving
    /// avatar plays the clip its travel speed was authored against.
    static func walkMotionIDs(avatarFormat: StageAvatarFormat?) -> [String] {
        guard let avatarFormat else { return [] }
        let suffix = avatarFormat.rawValue
        return [
            "\(walkLoopIDPrefix)\(suffix)",
            "gmgn.motion.bones.arpg.walk-forward-loop-\(suffix)",
            "gmgn.motion.bones.arpg.arc-walk-loop-\(suffix)",
        ]
    }

    /// The default standing clip ("待机微动") for one avatar format.
    static func idleMotionIDs(avatarFormat: StageAvatarFormat?) -> [String] {
        guard let avatarFormat else { return [] }
        return ["\(idleLoopIDPrefix)\(avatarFormat.rawValue)"]
    }

    /// Locomotion clips already approved by the host whose ids are not the
    /// canonical walk but *are* a walking loop. Used only as a tail: a machine
    /// whose motion library ships a differently-named walk must still walk.
    ///
    /// The filter is walk-only and deterministic: forward loops first, then the
    /// rest by id. Nothing that is not a walk loop can be selected, so this can
    /// never promote a dance, a sit, or a one-shot into a gait.
    static func libraryWalkMotionIDs(
        approvedMotions: [String: StageMotionAsset],
        avatarFormat: StageAvatarFormat?
    ) -> [String] {
        approvedMotions.values
            .filter { motion in
                motion.isLocomotionLoop
                    && isPlayable(motion, on: avatarFormat)
                    && motion.id.lowercased().contains("walk")
            }
            .map(\.id)
            .sorted { lhs, rhs in
                let lhsForward = lhs.lowercased().contains("forward")
                let rhsForward = rhs.lowercased().contains("forward")
                if lhsForward != rhsForward { return lhsForward }
                return lhs < rhs
            }
    }

    /// The first candidate the avatar can actually play, in priority order.
    static func firstPlayable(
        _ ids: [String],
        approvedMotions: [String: StageMotionAsset],
        avatarFormat: StageAvatarFormat?
    ) -> StageMotionAsset? {
        for id in ids {
            guard let motion = approvedMotions[id],
                  isPlayable(motion, on: avatarFormat)
            else { continue }
            return motion
        }
        return nil
    }

    /// Motion ids to append *after* a phase's declared ids. Locomotion gets the
    /// walking defaults (declared ids still win); everything else that is not a
    /// locomotion phase gets the standing default, so "待机" always has
    /// micro-motion instead of an empty pose.
    static func defaultMotionIDs(
        isLocomoting: Bool,
        approvedMotions: [String: StageMotionAsset],
        avatarFormat: StageAvatarFormat?
    ) -> [String] {
        if isLocomoting {
            return walkMotionIDs(avatarFormat: avatarFormat)
                + libraryWalkMotionIDs(
                    approvedMotions: approvedMotions,
                    avatarFormat: avatarFormat
                )
        }
        return idleMotionIDs(avatarFormat: avatarFormat)
    }

    /// A clip is playable when the *renderer* can load it: the format must
    /// match the active avatar's loader and the file must exist as a URL.
    /// Handing a `.vrma` to the PMX path is not a fallback, it is a silent
    /// `clearMotion()` (rest pose) in the renderer.
    static func isPlayable(
        _ motion: StageMotionAsset,
        on avatarFormat: StageAvatarFormat?
    ) -> Bool {
        guard let avatarFormat, motion.url != nil else { return false }
        switch avatarFormat {
        case .pmx: return motion.format == .vmd
        case .vrm: return motion.format == .vrma
        }
    }
}

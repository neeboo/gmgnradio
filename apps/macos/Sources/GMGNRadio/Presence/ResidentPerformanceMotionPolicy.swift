import Foundation

/// Reuses locally installed product motions; no downloaded asset is bundled.
/// Horizontal root motion belongs to the world, even during a performance.
enum ResidentPerformanceMotionPolicy {
    static let motionIDs: Set<String> = [
        "gmgn.motion.ardy-backflip", "gmgn.motion.bones.jumping-jacks-pmx",
    ]

    static func requiredMotionID(for activityID: String) -> String? {
        switch activityID {
        case "performance.backflip": "gmgn.motion.ardy-backflip"
        case "performance.jumping_jacks": "gmgn.motion.bones.jumping-jacks-pmx"
        default: nil
        }
    }

    static func approvedMotion(_ motion: StageMotionAsset) -> StageMotionAsset? {
        guard motionIDs.contains(motion.id), motion.format == .vmd, motion.url != nil else { return nil }
        return StageMotionAsset(
            id: motion.id, name: motion.name, format: motion.format, url: motion.url,
            version: motion.version, sha256: motion.sha256,
            loop: motion.id != "gmgn.motion.ardy-backflip",
            playbackRate: 1, inPlace: true
        )
    }

    static func isAvailable(
        activityID: String,
        avatarFormat: StageAvatarFormat?,
        approvedMotions: [String: StageMotionAsset]
    ) -> Bool {
        guard let motionID = requiredMotionID(for: activityID) else { return true }
        guard avatarFormat == .pmx, let motion = approvedMotions[motionID] else { return false }
        return motion.format == .vmd && motion.url != nil && motion.inPlace == true
    }
}

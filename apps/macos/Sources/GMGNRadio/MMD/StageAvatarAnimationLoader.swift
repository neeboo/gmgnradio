import Foundation
import VRMMetalKit

enum StageAvatarAnimationLoader {
    static func loadClip(
        for motion: StageMotionAsset?,
        model: VRMModel
    ) throws -> AnimationClip? {
        guard let motion else { return nil }
        switch motion.format {
        case .procedural:
            return nil
        case .vrma:
            guard let url = motion.url else {
                throw MotionPackageError.motionNotFound
            }
            return try VRMAnimationLoader.loadVRMA(from: url, model: model)
        case .vmd:
            guard let url = motion.url else {
                throw MotionPackageError.motionNotFound
            }
            let document = try NanoemVMDLoader.load(from: url)
            return VMDToVRMClipAdapter.makeClip(from: document, model: model)
        }
    }

    static func makeLoopingPlayer(
        for motion: StageMotionAsset?,
        model: VRMModel
    ) throws -> AnimationPlayer? {
        guard let clip = try loadClip(for: motion, model: model) else {
            return nil
        }
        let player = AnimationPlayer()
        player.isLooping = motion?.loop ?? true
        player.applyRootMotion = false
        player.load(clip)
        return player
    }
}

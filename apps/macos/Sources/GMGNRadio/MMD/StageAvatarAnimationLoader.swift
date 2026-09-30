import Foundation
import VRMMetalKit

/// Result of loading a looping clip together with its locomotion calibration
/// (nil when the clip is not a locomotion loop).
struct StageAvatarAnimationLoad {
    let player: AnimationPlayer?
    let gait: StageLocomotionGait?
}

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
        try makeLoopingPlayerWithGait(for: motion, model: model).player
    }

    /// Loads the looped clip and computes the locomotion gait in one pass, so
    /// renderers that retime walking never decode the same VRMA twice.
    static func makeLoopingPlayerWithGait(
        for motion: StageMotionAsset?,
        model: VRMModel
    ) throws -> StageAvatarAnimationLoad {
        guard var clip = try loadClip(for: motion, model: model) else {
            return StageAvatarAnimationLoad(player: nil, gait: nil)
        }
        if motion?.inPlace == true {
            clip.jointTracks = clip.jointTracks.map { track in
                guard track.bone == .hips,
                      let translation = track.translationSampler
                else { return track }
                let anchor = translation(0)
                return JointTrack(
                    bone: track.bone,
                    rotationSampler: track.rotationSampler,
                    translationSampler: { time in
                        let sample = translation(time)
                        return SIMD3<Float>(anchor.x, sample.y, anchor.z)
                    },
                    scaleSampler: track.scaleSampler
                )
            }
        }
        let player = AnimationPlayer()
        player.isLooping = motion?.loop ?? true
        player.applyRootMotion = true
        player.speed = motion?.playbackRate ?? 1
        player.load(clip)
        let gait = locomotionGait(
            for: motion,
            clip: clip,
            model: model
        )
        return StageAvatarAnimationLoad(player: player, gait: gait)
    }

    /// Resolves the gait for a locomotion motion on a concrete VRM rig:
    /// authored step speed comes from the manifest `strideSpeed` (falling back
    /// to the clip's VRMA locomotion metadata), the reference hips height from
    /// the clip's VRMA `sourceHipsHeight`, and the target hips height is
    /// measured from the model's bind pose. Non-locomotion clips yield nil.
    static func locomotionGait(
        for motion: StageMotionAsset?,
        clip: AnimationClip? = nil,
        model: VRMModel? = nil
    ) -> StageLocomotionGait? {
        guard let motion, motion.isLocomotionLoop else { return nil }
        let clipLocomotion = clip?.locomotion
        guard let authoredStepSpeed = motion.strideSpeed
            ?? clipLocomotion?.strideSpeed
        else { return nil }
        return StageLocomotionGait(
            authoredStepSpeed: authoredStepSpeed,
            sourceHipsHeight: clipLocomotion?.sourceHipsHeight,
            targetHipsHeight: model.map(Self.measureHipsRestHeight) ?? nil
        )
    }

    /// Rest height of the hips above the model origin, accumulated from the
    /// bind-pose translations of the hips-to-root chain. Nil when the rig has
    /// no VRM humanoid hips (e.g. a legacy/anonymous skeleton).
    static func measureHipsRestHeight(model: VRMModel) -> Float? {
        guard let humanoid = model.humanoid,
              let hipsIndex = humanoid.getBoneNode(.hips),
              model.nodes.indices.contains(hipsIndex)
        else { return nil }
        var node: VRMNode? = model.nodes[hipsIndex]
        var height: Float = 0
        var hops = 0
        while let current = node, hops < 128 {
            height += current.initialTranslation.y
            node = current.parent
            hops += 1
        }
        return height.isFinite && height > 0 ? height : nil
    }

    /// Retimes an active locomotion player from measured ground telemetry.
    /// Rate changes only (or a freeze at rate 0 when standing); the clip is
    /// never reloaded or restarted, so playback phase stays continuous. When
    /// the resolved playback is not locomotion (idle/dance/sit), or no gait is
    /// available, the player keeps its authored speed untouched.
    ///
    /// The speed comes from ``StageAvatarLocomotionTelemetry/gaitGroundSpeed``:
    /// while the world is translating the avatar the smooth sustained estimate
    /// is authoritative, so a snapshot that landed on a stalled tick can never
    /// freeze the feet of a body that is visibly sliding across the floor.
    static func applyLocomotion(
        telemetry: StageAvatarLocomotionTelemetry,
        gait: StageLocomotionGait?,
        player: AnimationPlayer?
    ) {
        guard let player, let gait, telemetry.isLocomotionActive else { return }
        let rate = gait.playbackRate(forGroundSpeed: telemetry.gaitGroundSpeed)
        player.speed = rate
    }
}

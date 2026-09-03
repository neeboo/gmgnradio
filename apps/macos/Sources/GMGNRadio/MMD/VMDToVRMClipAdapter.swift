import Foundation
import simd
import VRMMetalKit

struct VMDVRMRestPose {
    let rotations: [VRMHumanoidBone: simd_quatf]
    let translations: [VRMHumanoidBone: SIMD3<Float>]

    init(
        rotations: [VRMHumanoidBone: simd_quatf],
        translations: [VRMHumanoidBone: SIMD3<Float>]
    ) {
        self.rotations = rotations
        self.translations = translations
    }

    init(model: VRMModel?) {
        guard let model, let humanoid = model.humanoid else {
            rotations = [:]
            translations = [:]
            return
        }

        var rotations: [VRMHumanoidBone: simd_quatf] = [:]
        var translations: [VRMHumanoidBone: SIMD3<Float>] = [:]
        for bone in VRMHumanoidBone.allCases {
            guard let nodeIndex = humanoid.getBoneNode(bone),
                  model.nodes.indices.contains(nodeIndex)
            else { continue }
            rotations[bone] = model.nodes[nodeIndex].initialRotation
            translations[bone] = model.nodes[nodeIndex].initialTranslation
        }
        self.rotations = rotations
        self.translations = translations
    }
}

enum VMDToVRMClipAdapter {
    enum RootMotionPolicy {
        case locked
        case preserved
    }

    struct Configuration {
        var rootMotion: RootMotionPolicy = .locked
        var translationScale: Float = 0.08

        init(
            rootMotion: RootMotionPolicy = .locked,
            translationScale: Float = 0.08
        ) {
            self.rootMotion = rootMotion
            self.translationScale = translationScale
        }
    }

    static func makeClip(
        from document: VMDMotionDocument,
        model: VRMModel? = nil,
        configuration: Configuration = Configuration()
    ) -> AnimationClip {
        makeClip(
            from: document,
            restPose: VMDVRMRestPose(model: model),
            configuration: configuration
        )
    }

    static func makeClip(
        from document: VMDMotionDocument,
        restPose: VMDVRMRestPose,
        configuration: Configuration = Configuration()
    ) -> AnimationClip {
        var clip = AnimationClip(duration: max(document.duration, 1 / VMDMotionDocument.framesPerSecond))
        appendJointTracks(
            from: document,
            restPose: restPose,
            configuration: configuration,
            to: &clip
        )
        appendMorphTracks(from: document, to: &clip)
        return clip
    }

    private struct BoneSequence {
        let sourceName: String
        let keyframes: [VMDBoneKeyframe]
    }

    private static func appendJointTracks(
        from document: VMDMotionDocument,
        restPose: VMDVRMRestPose,
        configuration: Configuration,
        to clip: inout AnimationClip
    ) {
        let framesBySource = Dictionary(grouping: document.boneKeyframes, by: \.boneName)
        var sequencesByTarget: [VRMHumanoidBone: [BoneSequence]] = [:]

        for (sourceName, frames) in framesBySource {
            let sequence = BoneSequence(
                sourceName: sourceName,
                keyframes: frames.sorted { $0.frameIndex < $1.frameIndex }
            )
            for bone in VMDHumanoidMap.bones(named: sourceName) {
                sequencesByTarget[bone, default: []].append(sequence)
            }
        }

        for bone in VRMHumanoidBone.allCases {
            guard var sequences = sequencesByTarget[bone], !sequences.isEmpty else { continue }
            sequences.sort { sourcePriority($0.sourceName) < sourcePriority($1.sourceName) }
            let restRotation = normalizedOrIdentity(restPose.rotations[bone] ?? identityQuaternion)

            let rotationSampler: (Float) -> simd_quatf = { time in
                var combined = identityQuaternion
                for sequence in sequences {
                    let source = sampleBone(sequence.keyframes, at: time).rotation
                    combined = simd_normalize(combined * convertedRotation(source))
                }
                return simd_normalize(restRotation * combined)
            }

            var translationSampler: ((Float) -> SIMD3<Float>)?
            if bone == .hips {
                let restTranslation = restPose.translations[bone] ?? .zero
                translationSampler = { time in
                    var delta = SIMD3<Float>.zero
                    for sequence in sequences {
                        delta += convertedTranslation(
                            sampleBone(sequence.keyframes, at: time).translation,
                            scale: configuration.translationScale
                        )
                    }
                    if configuration.rootMotion == .locked {
                        delta.x = 0
                        delta.z = 0
                    }
                    return restTranslation + delta
                }
            }

            clip.addJointTrack(
                JointTrack(
                    bone: bone,
                    rotationSampler: rotationSampler,
                    translationSampler: translationSampler
                )
            )
        }
    }

    private static func appendMorphTracks(
        from document: VMDMotionDocument,
        to clip: inout AnimationClip
    ) {
        let framesBySource = Dictionary(grouping: document.morphKeyframes, by: \.morphName)
        var framesByTarget: [String: [[VMDMorphKeyframe]]] = [:]
        for (sourceName, frames) in framesBySource {
            let target = VMDHumanoidMap.expressionName(for: sourceName)
            framesByTarget[target, default: []].append(
                frames.sorted { $0.frameIndex < $1.frameIndex }
            )
        }

        for target in framesByTarget.keys.sorted() {
            guard let sequences = framesByTarget[target] else { continue }
            let sampler: (Float) -> Float = { time in
                min(max(sequences.reduce(0) { $0 + sampleMorph($1, at: time) }, 0), 1)
            }
            clip.addMorphTrack(MorphTrack(key: target, sampler: sampler))
            if let preset = VRMExpressionPreset(rawValue: target) {
                clip.addExpressionTrack(ExpressionTrack(expression: preset, sampler: sampler))
            }
        }
    }

    private static func sampleBone(
        _ keyframes: [VMDBoneKeyframe],
        at time: Float
    ) -> (translation: SIMD3<Float>, rotation: simd_quatf) {
        guard let first = keyframes.first else { return (.zero, identityQuaternion) }
        guard keyframes.count > 1 else { return (first.translation, first.rotation) }

        let frame = max(time, 0) * VMDMotionDocument.framesPerSecond
        if frame <= Float(first.frameIndex) { return (first.translation, first.rotation) }
        guard let last = keyframes.last else { return (first.translation, first.rotation) }
        guard frame < Float(last.frameIndex) else {
            return (last.translation, last.rotation)
        }

        let nextIndex = firstIndex(after: frame, in: keyframes.map(\.frameIndex))
        let previous = keyframes[nextIndex - 1]
        let next = keyframes[nextIndex]
        let interval = Float(next.frameIndex - previous.frameIndex)
        let progress = interval > 0 ? (frame - Float(previous.frameIndex)) / interval : 1
        let interpolation = next.interpolation

        let tx = VMDBezierSampler.value(at: progress, controlPoints: interpolation.translationX)
        let ty = VMDBezierSampler.value(at: progress, controlPoints: interpolation.translationY)
        let tz = VMDBezierSampler.value(at: progress, controlPoints: interpolation.translationZ)
        let rotationProgress = VMDBezierSampler.value(at: progress, controlPoints: interpolation.rotation)
        return (
            SIMD3<Float>(
                mix(previous.translation.x, next.translation.x, tx),
                mix(previous.translation.y, next.translation.y, ty),
                mix(previous.translation.z, next.translation.z, tz)
            ),
            simd_slerp(
                normalizedOrIdentity(previous.rotation),
                normalizedOrIdentity(next.rotation),
                rotationProgress
            )
        )
    }

    private static func sampleMorph(_ keyframes: [VMDMorphKeyframe], at time: Float) -> Float {
        guard let first = keyframes.first else { return 0 }
        guard keyframes.count > 1 else { return first.weight }
        let frame = max(time, 0) * VMDMotionDocument.framesPerSecond
        if frame <= Float(first.frameIndex) { return first.weight }
        guard let last = keyframes.last else { return first.weight }
        guard frame < Float(last.frameIndex) else { return last.weight }

        let nextIndex = firstIndex(after: frame, in: keyframes.map(\.frameIndex))
        let previous = keyframes[nextIndex - 1]
        let next = keyframes[nextIndex]
        let interval = Float(next.frameIndex - previous.frameIndex)
        let progress = interval > 0 ? (frame - Float(previous.frameIndex)) / interval : 1
        return mix(previous.weight, next.weight, progress)
    }

    private static func firstIndex(after frame: Float, in keyframes: [UInt32]) -> Int {
        var lower = 0
        var upper = keyframes.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if Float(keyframes[middle]) <= frame {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return min(max(lower, 1), keyframes.count - 1)
    }

    private static func sourcePriority(_ name: String) -> String {
        let priorities = ["センター": "00", "グルーブ": "01", "下半身": "02"]
        return (priorities[name] ?? "10") + name
    }

    private static func convertedRotation(_ source: simd_quatf) -> simd_quatf {
        let source = normalizedOrIdentity(source)
        return simd_quatf(
            ix: -source.imag.x,
            iy: -source.imag.y,
            iz: source.imag.z,
            r: source.real
        )
    }

    private static func convertedTranslation(
        _ source: SIMD3<Float>,
        scale: Float
    ) -> SIMD3<Float> {
        SIMD3<Float>(source.x, source.y, -source.z) * scale
    }

    private static func mix(_ lhs: Float, _ rhs: Float, _ progress: Float) -> Float {
        lhs + (rhs - lhs) * progress
    }

    private static func normalizedOrIdentity(_ value: simd_quatf) -> simd_quatf {
        let lengthSquared = simd_length_squared(value.vector)
        guard lengthSquared.isFinite, lengthSquared > 0.000_001 else { return identityQuaternion }
        return simd_normalize(value)
    }

    private static let identityQuaternion = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
}

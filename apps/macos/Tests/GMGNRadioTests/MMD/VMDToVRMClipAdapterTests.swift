import simd
import Testing
import VRMMetalKit
@testable import GMGNRadio

@Test
func vmdAdapterUsesThirtyFramesPerSecondAndPreservesBezierTiming() throws {
    let document = VMDMotionDocument(
        targetModelName: "test",
        boneKeyframes: [
            boneFrame(name: "上半身", frame: 0, angle: 0),
            boneFrame(
                name: "上半身",
                frame: 30,
                angle: .pi / 2,
                interpolation: VMDBoneInterpolation(
                    translationX: .linear,
                    translationY: .linear,
                    translationZ: .linear,
                    rotation: VMDBezierControlPoints(
                        normalizedX1: 0.25,
                        normalizedY1: 0.1,
                        normalizedX2: 0.25,
                        normalizedY2: 1
                    )
                )
            ),
        ]
    )

    let clip = VMDToVRMClipAdapter.makeClip(from: document)
    let track = try #require(clip.jointTracks.first { $0.bone == .spine })
    let sampled = try #require(track.rotationSampler?(0.5))
    let expected = Float.pi / 2 * 0.8024

    #expect(clip.duration == 1)
    #expect(abs(quaternionAngle(sampled) - expected) < 0.002)
}

@Test
func vmdAdapterConvertsMMDCoordinatesAndAppliesTargetRestRotation() throws {
    let sourceRotation = simd_quatf(angle: .pi / 3, axis: SIMD3<Float>(0, 1, 0))
    let targetRest = simd_quatf(angle: .pi / 6, axis: SIMD3<Float>(0, 0, 1))
    let document = VMDMotionDocument(
        targetModelName: "test",
        boneKeyframes: [
            VMDBoneKeyframe(
                boneName: "上半身",
                frameIndex: 0,
                translation: .zero,
                rotation: sourceRotation,
                interpolation: .linear
            ),
        ]
    )
    let restPose = VMDVRMRestPose(
        rotations: [.spine: targetRest],
        translations: [:]
    )

    let clip = VMDToVRMClipAdapter.makeClip(from: document, restPose: restPose)
    let track = try #require(clip.jointTracks.first { $0.bone == .spine })
    let sampled = try #require(track.rotationSampler?(0))
    let convertedDelta = simd_quatf(
        ix: -sourceRotation.imag.x,
        iy: -sourceRotation.imag.y,
        iz: sourceRotation.imag.z,
        r: sourceRotation.real
    )
    let expected = simd_normalize(targetRest * convertedDelta)

    #expect(abs(simd_dot(sampled.vector, expected.vector)) > 0.9999)
}

@Test
func vmdAdapterLocksHorizontalRootMotionByDefault() throws {
    let document = VMDMotionDocument(
        targetModelName: "test",
        boneKeyframes: [
            VMDBoneKeyframe(
                boneName: "センター",
                frameIndex: 0,
                translation: SIMD3<Float>(10, 2, 5),
                rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)),
                interpolation: .linear
            ),
        ]
    )
    let restPose = VMDVRMRestPose(
        rotations: [:],
        translations: [.hips: SIMD3<Float>(0.25, 0.9, -0.5)]
    )

    let clip = VMDToVRMClipAdapter.makeClip(from: document, restPose: restPose)
    let hips = try #require(clip.jointTracks.first { $0.bone == .hips })
    let translation = try #require(hips.translationSampler?(0))

    #expect(translation.x == 0.25)
    #expect(abs(translation.y - 1.06) < 0.0001)
    #expect(translation.z == -0.5)
}

@Test
func vmdAdapterCanPreserveRootMotionExplicitly() throws {
    let document = VMDMotionDocument(
        targetModelName: "test",
        boneKeyframes: [
            VMDBoneKeyframe(
                boneName: "センター",
                frameIndex: 0,
                translation: SIMD3<Float>(10, 2, 5),
                rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)),
                interpolation: .linear
            ),
        ]
    )
    let configuration = VMDToVRMClipAdapter.Configuration(rootMotion: .preserved)

    let clip = VMDToVRMClipAdapter.makeClip(
        from: document,
        configuration: configuration
    )
    let hips = try #require(clip.jointTracks.first { $0.bone == .hips })
    let translation = try #require(hips.translationSampler?(0))

    #expect(translation == SIMD3<Float>(0.8, 0.16, -0.4))
}

@Test
func vmdAdapterBuildsPresetAndCustomExpressionTracks() throws {
    let document = VMDMotionDocument(
        targetModelName: "test",
        morphKeyframes: [
            VMDMorphKeyframe(morphName: "笑い", frameIndex: 0, weight: 0),
            VMDMorphKeyframe(morphName: "笑い", frameIndex: 30, weight: 1),
            VMDMorphKeyframe(morphName: "独自表情", frameIndex: 0, weight: 0.4),
        ]
    )

    let clip = VMDToVRMClipAdapter.makeClip(from: document)
    let happy = try #require(clip.morphTracks.first { $0.key == "happy" })
    let custom = try #require(clip.morphTracks.first { $0.key == "独自表情" })

    #expect(abs(happy.sample(at: 0.5) - 0.5) < 0.0001)
    #expect(custom.sample(at: 0) == 0.4)
    #expect(clip.expressionTracks.contains { $0.expression.rawValue == "happy" })
}

private func boneFrame(
    name: String,
    frame: UInt32,
    angle: Float,
    interpolation: VMDBoneInterpolation = .linear
) -> VMDBoneKeyframe {
    VMDBoneKeyframe(
        boneName: name,
        frameIndex: frame,
        translation: .zero,
        rotation: simd_quatf(angle: angle, axis: SIMD3<Float>(0, 0, 1)),
        interpolation: interpolation
    )
}

private func quaternionAngle(_ quaternion: simd_quatf) -> Float {
    2 * acos(min(1, abs(simd_normalize(quaternion).real)))
}

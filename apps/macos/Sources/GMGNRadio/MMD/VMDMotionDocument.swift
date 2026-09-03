import Foundation
import simd

struct VMDMotionDocument: Sendable {
    static let framesPerSecond: Float = 30

    let targetModelName: String
    let boneKeyframes: [VMDBoneKeyframe]
    let morphKeyframes: [VMDMorphKeyframe]

    init(
        targetModelName: String,
        boneKeyframes: [VMDBoneKeyframe] = [],
        morphKeyframes: [VMDMorphKeyframe] = []
    ) {
        self.targetModelName = targetModelName
        self.boneKeyframes = boneKeyframes.sorted(by: VMDBoneKeyframe.stableOrder)
        self.morphKeyframes = morphKeyframes.sorted(by: VMDMorphKeyframe.stableOrder)
    }

    var duration: Float {
        let lastBoneFrame = boneKeyframes.map(\.frameIndex).max() ?? 0
        let lastMorphFrame = morphKeyframes.map(\.frameIndex).max() ?? 0
        return Float(max(lastBoneFrame, lastMorphFrame)) / Self.framesPerSecond
    }
}

struct VMDBoneKeyframe: Sendable {
    let boneName: String
    let frameIndex: UInt32
    let translation: SIMD3<Float>
    let rotation: simd_quatf
    let interpolation: VMDBoneInterpolation

    var time: Float {
        Float(frameIndex) / VMDMotionDocument.framesPerSecond
    }

    fileprivate static func stableOrder(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.boneName != rhs.boneName {
            return lhs.boneName < rhs.boneName
        }
        return lhs.frameIndex < rhs.frameIndex
    }
}

struct VMDMorphKeyframe: Sendable {
    let morphName: String
    let frameIndex: UInt32
    let weight: Float

    var time: Float {
        Float(frameIndex) / VMDMotionDocument.framesPerSecond
    }

    fileprivate static func stableOrder(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.morphName != rhs.morphName {
            return lhs.morphName < rhs.morphName
        }
        return lhs.frameIndex < rhs.frameIndex
    }
}

struct VMDBoneInterpolation: Equatable, Sendable {
    let translationX: VMDBezierControlPoints
    let translationY: VMDBezierControlPoints
    let translationZ: VMDBezierControlPoints
    let rotation: VMDBezierControlPoints

    static let linear = VMDBoneInterpolation(
        translationX: .linear,
        translationY: .linear,
        translationZ: .linear,
        rotation: .linear
    )
}

struct VMDBezierControlPoints: Equatable, Sendable {
    static let maximumRawValue: Float = 127
    static let linear = VMDBezierControlPoints(20, 20, 107, 107)

    let x1: UInt8
    let y1: UInt8
    let x2: UInt8
    let y2: UInt8

    init(_ x1: UInt8, _ y1: UInt8, _ x2: UInt8, _ y2: UInt8) {
        self.x1 = min(x1, 127)
        self.y1 = min(y1, 127)
        self.x2 = min(x2, 127)
        self.y2 = min(y2, 127)
    }

    init(
        normalizedX1: Float,
        normalizedY1: Float,
        normalizedX2: Float,
        normalizedY2: Float
    ) {
        func raw(_ value: Float) -> UInt8 {
            UInt8((min(max(value, 0), 1) * Self.maximumRawValue).rounded())
        }
        self.init(
            raw(normalizedX1),
            raw(normalizedY1),
            raw(normalizedX2),
            raw(normalizedY2)
        )
    }

    var normalized: (x1: Float, y1: Float, x2: Float, y2: Float) {
        (
            Float(x1) / Self.maximumRawValue,
            Float(y1) / Self.maximumRawValue,
            Float(x2) / Self.maximumRawValue,
            Float(y2) / Self.maximumRawValue
        )
    }
}

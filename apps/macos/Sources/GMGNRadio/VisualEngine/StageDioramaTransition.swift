import Foundation

// Swift translation of Folia's dioramaTransition.ts one-take transition math.
// Source: chthollyphile/folia-major at
// 002b581bb2580566937f1023a3c875d2b799dbbe.
// Modified for gmgn radio on 2026-07-31 under GNU AGPL v3.

enum StageDioramaTransition {
    static let duration: Float = 3.2
    static let distance: Float = 46
    static let bank: Float = 0.14
    static let aimSweep: Float = 0.14

    static func pickOffset(
        seed: String,
        epoch: Int
    ) -> SIMD3<Float> {
        let base = hash(seed) &+ UInt64(truncatingIfNeeded: epoch &* 131)
        let azimuth = seededUnit(base &+ 1) * Float.pi * 2
        let elevation = (seededUnit(base &+ 2) - 0.35) * 1.3
        let cosineElevation = cos(elevation)
        let direction = SIMD3<Float>(
            sin(azimuth) * cosineElevation,
            sin(elevation),
            -abs(cos(azimuth) * cosineElevation) - 0.35
        )
        return normalized(direction) * distance
    }

    static func ease(_ progress: Float) -> Float {
        let value = min(max(progress, 0), 1)
        return value * value * value
            * (value * (value * 6 - 15) + 10)
    }

    static func bezierControl(
        from: SIMD3<Float>,
        to: SIMD3<Float>,
        seed: String,
        epoch: Int
    ) -> SIMD3<Float> {
        let midpoint = (from + to) * 0.5
        let flightVector = to - from
        let flightLength = max(length(flightVector), 1)
        let perpendicular = flightPerpendicular(from: from, to: to)
        let side: Float = seededUnit(
            hash(seed) &+ UInt64(truncatingIfNeeded: epoch &* 17)
        ) < 0.5 ? -1 : 1
        let bow = flightLength * 0.32
        return SIMD3<Float>(
            midpoint.x + perpendicular.x * bow * side,
            midpoint.y + bow * 0.55,
            midpoint.z + perpendicular.z * bow * side
        )
    }

    static func bezierArc(
        from: SIMD3<Float>,
        control: SIMD3<Float>,
        to: SIMD3<Float>,
        progress: Float
    ) -> SIMD3<Float> {
        let value = min(max(progress, 0), 1)
        let remaining = 1 - value
        return from * (remaining * remaining)
            + control * (2 * remaining * value)
            + to * (value * value)
    }

    static func flightPerpendicular(
        from: SIMD3<Float>,
        to: SIMD3<Float>
    ) -> SIMD3<Float> {
        let perpendicular = SIMD3<Float>(
            to.z - from.z,
            0,
            -(to.x - from.x)
        )
        let magnitude = length(perpendicular)
        guard magnitude >= 0.001 else {
            return SIMD3<Float>(1, 0, 0)
        }
        return perpendicular / magnitude
    }

    private static func normalized(
        _ vector: SIMD3<Float>
    ) -> SIMD3<Float> {
        let magnitude = max(length(vector), 0.000_001)
        return vector / magnitude
    }

    private static func length(_ vector: SIMD3<Float>) -> Float {
        sqrt(
            vector.x * vector.x
                + vector.y * vector.y
                + vector.z * vector.z
        )
    }

    private static func hash(_ seed: String) -> UInt64 {
        seed.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
            partial, byte in
            (partial ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }

    private static func seededUnit(_ seed: UInt64) -> Float {
        var value = seed &+ 0x9E37_79B9_7F4A_7C15
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        return Float(value & 0x00FF_FFFF) / Float(0x0100_0000)
    }
}

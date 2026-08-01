import Foundation

enum StageParticleRegion: UInt32, CaseIterable, Hashable, Sendable {
    case head
    case shoulders
    case headphones
    case deck
    case orbit
    case atmosphere
    case cover
    case ambientDust
    case ambientShard
    case floorSpark
}

struct StageParticleVertex: Equatable, Sendable {
    var positionAndSize: SIMD4<Float>
    var colorAndPhase: SIMD4<Float>

    var textureCoordinate: SIMD2<Float> {
        SIMD2<Float>(
            positionAndSize.x / 6 + 0.5,
            positionAndSize.y / 6 + 0.5
        )
    }
}

struct StageParticleGeometry: Equatable, Sendable {
    let vertices: [StageParticleVertex]
    let regionCounts: [StageParticleRegion: Int]

    static func djTotem(seed: UInt64) -> StageParticleGeometry {
        var builder = StageParticleBuilder(seed: seed)

        builder.appendEllipsoid(
            count: 5_600,
            center: SIMD3<Float>(0, 0.52, 0),
            radii: SIMD3<Float>(0.88, 1.05, 0.80),
            color: SIMD3<Float>(0.025, 0.22, 0.95),
            size: 1.05,
            region: .head
        )
        builder.appendEllipsoid(
            count: 4_200,
            center: SIMD3<Float>(0, -1.02, 0.02),
            radii: SIMD3<Float>(2.15, 0.78, 1.02),
            color: SIMD3<Float>(0.02, 0.12, 0.55),
            size: 0.92,
            region: .shoulders
        )
        builder.appendHeadphones(count: 2_600)
        builder.appendTorus(
            count: 3_200,
            center: SIMD3<Float>(0, -1.52, 0),
            majorRadius: 2.15,
            minorRadius: 0.14,
            tilt: SIMD2<Float>(0.08, 0),
            color: SIMD3<Float>(0.015, 0.42, 1.0),
            size: 1.18,
            region: .deck
        )
        builder.appendTorus(
            count: 2_100,
            center: SIMD3<Float>(0, -0.15, 0),
            majorRadius: 2.95,
            minorRadius: 0.055,
            tilt: SIMD2<Float>(0.72, 0.26),
            color: SIMD3<Float>(0.02, 0.52, 1.0),
            size: 0.88,
            region: .orbit
        )
        builder.appendTorus(
            count: 2_100,
            center: SIMD3<Float>(0, -0.10, 0),
            majorRadius: 3.42,
            minorRadius: 0.045,
            tilt: SIMD2<Float>(-0.48, 0.82),
            color: SIMD3<Float>(0.12, 0.30, 0.92),
            size: 0.76,
            region: .orbit
        )
        builder.appendAtmosphere(count: 2_600)

        return StageParticleGeometry(
            vertices: builder.vertices,
            regionCounts: builder.regionCounts
        )
    }

    static func albumCanvas(
        grid: Int = 144,
        seed: UInt64
    ) -> StageParticleGeometry {
        let side = max(grid, 2)
        let count = side * side
        var random = StageSeededRandom(seed: seed)
        var vertices: [StageParticleVertex] = []
        vertices.reserveCapacity(count)

        for row in 0 ..< side {
            for column in 0 ..< side {
                let u = (Float(column) + 0.5) / Float(side)
                let v = (Float(row) + 0.5) / Float(side)
                let fallbackColor = SIMD3<Float>(
                    0.03 + u * 0.08,
                    0.22 + (1 - v) * 0.50,
                    0.72 + u * 0.28
                )
                vertices.append(
                    StageParticleVertex(
                        positionAndSize: SIMD4<Float>(
                            (u - 0.5) * 6,
                            (v - 0.5) * 6,
                            0,
                            0.82 + random.unit() * 0.42
                        ),
                        colorAndPhase: SIMD4<Float>(
                            fallbackColor.x,
                            fallbackColor.y,
                            fallbackColor.z,
                            random.unit() * 2 * .pi
                        )
                    )
                )
            }
        }

        return StageParticleGeometry(
            vertices: vertices,
            regionCounts: [.cover: count]
        )
    }

    static func ambientField(
        count: Int = 1_800,
        seed: UInt64
    ) -> StageParticleGeometry {
        let total = max(count, 0)
        let dustCount = Int(Float(total) * 0.65)
        let shardCount = Int(Float(total) * 0.18)
        let floorCount = total - dustCount - shardCount
        var random = StageSeededRandom(seed: seed)
        var vertices: [StageParticleVertex] = []
        var regionCounts: [StageParticleRegion: Int] = [:]
        vertices.reserveCapacity(total)

        func color(
            _ primary: SIMD3<Float>,
            _ secondary: SIMD3<Float>,
            _ amount: Float
        ) -> SIMD3<Float> {
            primary + (secondary - primary) * amount
        }

        func vertex(
            position: SIMD3<Float>,
            size: Float,
            tint: SIMD3<Float>,
            phase: Float
        ) -> StageParticleVertex {
            StageParticleVertex(
                positionAndSize: SIMD4<Float>(
                    position.x,
                    position.y,
                    position.z,
                    size
                ),
                colorAndPhase: SIMD4<Float>(
                    tint.x,
                    tint.y,
                    tint.z,
                    phase
                )
            )
        }

        for _ in 0 ..< dustCount {
            let depth = -10.5 + random.unit() * 14.5
            let spread = 0.62 + (depth + 10.5) / 14.5 * 0.38
            vertices.append(
                vertex(
                    position: SIMD3<Float>(
                        (random.unit() * 2 - 1) * 9.5 * spread,
                        (random.unit() * 2 - 1) * 5.4 * spread,
                        depth
                    ),
                    size: 0.34 + random.unit() * 0.72,
                    tint: color(
                        SIMD3<Float>(0.28, 0.68, 1),
                        SIMD3<Float>(0.78, 0.48, 1),
                        random.unit()
                    ),
                    phase: random.unit() * 2 * .pi
                )
            )
        }
        regionCounts[.ambientDust] = dustCount

        for _ in 0 ..< shardCount {
            vertices.append(
                vertex(
                    position: SIMD3<Float>(
                        (random.unit() * 2 - 1) * 7.4,
                        (random.unit() * 2 - 1) * 4.2,
                        -4.5 + random.unit() * 7.5
                    ),
                    size: 1.4 + pow(random.unit(), 1.8) * 3.3,
                    tint: color(
                        SIMD3<Float>(0.58, 0.86, 1),
                        SIMD3<Float>(1, 0.68, 0.88),
                        random.unit()
                    ),
                    phase: random.unit() * 2 * .pi
                )
            )
        }
        regionCounts[.ambientShard] = shardCount

        for _ in 0 ..< floorCount {
            let lane = random.unit()
            vertices.append(
                vertex(
                    position: SIMD3<Float>(
                        (random.unit() * 2 - 1) * 7.8,
                        -2.82 + pow(lane, 2) * 0.92,
                        -5.8 + random.unit() * 9.2
                    ),
                    size: 0.92 + pow(random.unit(), 1.5) * 3.1,
                    tint: color(
                        SIMD3<Float>(0.40, 0.78, 1),
                        SIMD3<Float>(0.88, 0.94, 1),
                        random.unit()
                    ),
                    phase: random.unit() * 2 * .pi
                )
            )
        }
        regionCounts[.floorSpark] = floorCount

        return StageParticleGeometry(
            vertices: vertices,
            regionCounts: regionCounts
        )
    }
}

private struct StageParticleBuilder {
    private var random: StageSeededRandom
    private(set) var vertices: [StageParticleVertex] = []
    private(set) var regionCounts: [StageParticleRegion: Int] = [:]

    init(seed: UInt64) {
        random = StageSeededRandom(seed: seed)
        vertices.reserveCapacity(24_000)
    }

    mutating func appendEllipsoid(
        count: Int,
        center: SIMD3<Float>,
        radii: SIMD3<Float>,
        color: SIMD3<Float>,
        size: Float,
        region: StageParticleRegion
    ) {
        for _ in 0 ..< count {
            let y = random.unit() * 2 - 1
            let angle = random.unit() * 2 * .pi
            let radial = sqrt(max(0, 1 - y * y))
            let normal = SIMD3<Float>(
                radial * cos(angle),
                y,
                radial * sin(angle)
            )
            let grain = 0.94 + random.unit() * 0.12
            append(
                position: center + normal * radii * grain,
                color: color,
                size: size * (0.72 + random.unit() * 0.56),
                region: region
            )
        }
    }

    mutating func appendHeadphones(count: Int) {
        let color = SIMD3<Float>(0.015, 0.52, 1.0)

        for index in 0 ..< count {
            if index < count * 3 / 5 {
                let arc = random.unit() * .pi
                let tube = random.unit() * 2 * .pi
                let tubeRadius: Float = 0.085
                let position = SIMD3<Float>(
                    cos(arc) * 1.18 + cos(tube) * tubeRadius,
                    0.48 + sin(arc) * 1.28,
                    sin(tube) * tubeRadius
                )
                append(
                    position: position,
                    color: color,
                    size: 1.22,
                    region: .headphones
                )
            } else {
                let side: Float = index.isMultiple(of: 2) ? -1 : 1
                let angle = random.unit() * 2 * .pi
                let radius = sqrt(random.unit())
                let position = SIMD3<Float>(
                    side * (1.06 + random.unit() * 0.16),
                    0.34 + cos(angle) * radius * 0.42,
                    sin(angle) * radius * 0.30
                )
                append(
                    position: position,
                    color: SIMD3<Float>(0.01, 0.32, 0.88),
                    size: 1.32,
                    region: .headphones
                )
            }
        }
    }

    mutating func appendTorus(
        count: Int,
        center: SIMD3<Float>,
        majorRadius: Float,
        minorRadius: Float,
        tilt: SIMD2<Float>,
        color: SIMD3<Float>,
        size: Float,
        region: StageParticleRegion
    ) {
        let cosX = cos(tilt.x)
        let sinX = sin(tilt.x)
        let cosZ = cos(tilt.y)
        let sinZ = sin(tilt.y)

        for _ in 0 ..< count {
            let around = random.unit() * 2 * .pi
            let tube = random.unit() * 2 * .pi
            let radius = majorRadius + cos(tube) * minorRadius
            var position = SIMD3<Float>(
                cos(around) * radius,
                sin(tube) * minorRadius,
                sin(around) * radius
            )

            position = SIMD3<Float>(
                position.x,
                position.y * cosX - position.z * sinX,
                position.y * sinX + position.z * cosX
            )
            position = SIMD3<Float>(
                position.x * cosZ - position.y * sinZ,
                position.x * sinZ + position.y * cosZ,
                position.z
            )
            append(
                position: center + position,
                color: color,
                size: size * (0.76 + random.unit() * 0.48),
                region: region
            )
        }
    }

    mutating func appendAtmosphere(count: Int) {
        for _ in 0 ..< count {
            let angle = random.unit() * 2 * .pi
            let height = (random.unit() * 2 - 1) * 2.8
            let radius = 2.8 + random.unit() * 2.1
            append(
                position: SIMD3<Float>(
                    cos(angle) * radius,
                    height,
                    sin(angle) * radius
                ),
                color: SIMD3<Float>(0.24, 0.52, 0.94),
                size: 0.42 + random.unit() * 0.44,
                region: .atmosphere
            )
        }
    }

    private mutating func append(
        position: SIMD3<Float>,
        color: SIMD3<Float>,
        size: Float,
        region: StageParticleRegion
    ) {
        vertices.append(
            StageParticleVertex(
                positionAndSize: SIMD4<Float>(
                    position.x,
                    position.y,
                    position.z,
                    size
                ),
                colorAndPhase: SIMD4<Float>(
                    color.x,
                    color.y,
                    color.z,
                    random.unit() * 2 * .pi
                )
            )
        )
        regionCounts[region, default: 0] += 1
    }
}

private struct StageSeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    mutating func unit() -> Float {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        value ^= value >> 31
        return Float(value >> 40) / Float(1 << 24)
    }
}

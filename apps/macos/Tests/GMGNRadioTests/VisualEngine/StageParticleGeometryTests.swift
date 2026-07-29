import Testing
@testable import GMGNRadio

@Test
func stageParticleGeometryIsDeterministic() {
    let first = StageParticleGeometry.djTotem(seed: 42)
    let second = StageParticleGeometry.djTotem(seed: 42)

    #expect(first.vertices == second.vertices)
    #expect(first.regionCounts == second.regionCounts)
}

@Test
func stageParticleGeometryContainsTheWholeDJTotem() {
    let geometry = StageParticleGeometry.djTotem(seed: 7)

    #expect(geometry.vertices.count >= 18_000)
    #expect(geometry.vertices.count <= 30_000)
    #expect(geometry.regionCounts[.head, default: 0] > 2_000)
    #expect(geometry.regionCounts[.shoulders, default: 0] > 2_000)
    #expect(geometry.regionCounts[.headphones, default: 0] > 1_000)
    #expect(geometry.regionCounts[.deck, default: 0] > 1_000)
    #expect(geometry.regionCounts[.orbit, default: 0] > 1_000)
}

@Test
func stageParticleGeometryHasReadableDepth() {
    let geometry = StageParticleGeometry.djTotem(seed: 99)
    let positions = geometry.vertices.map {
        SIMD3<Float>(
            $0.positionAndSize.x,
            $0.positionAndSize.y,
            $0.positionAndSize.z
        )
    }

    let minimumZ = positions.map(\.z).min() ?? 0
    let maximumZ = positions.map(\.z).max() ?? 0
    let maximumY = positions.map(\.y).max() ?? 0

    #expect(maximumZ - minimumZ > 2.5)
    #expect(maximumY > 1.5)
}


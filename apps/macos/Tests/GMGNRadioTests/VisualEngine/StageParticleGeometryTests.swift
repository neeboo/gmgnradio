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

@Test
func albumParticleCanvasBuildsAnAddressableCoverGrid() {
    let geometry = StageParticleGeometry.albumCanvas(
        grid: 16,
        seed: 42
    )

    #expect(geometry.vertices.count == 256)
    #expect(geometry.regionCounts[.cover, default: 0] == 256)
    #expect(geometry.vertices.first?.textureCoordinate.x ?? 1 < 0.04)
    #expect(geometry.vertices.first?.textureCoordinate.y ?? 1 < 0.04)
    #expect(geometry.vertices.last?.textureCoordinate.x ?? 0 > 0.96)
    #expect(geometry.vertices.last?.textureCoordinate.y ?? 0 > 0.96)
}

@Test
func ambientParticleFieldHasDustShardsAndFloorDepth() {
    let geometry = StageParticleGeometry.ambientField(
        count: 1_800,
        seed: 0x4D564658
    )
    let sizes = geometry.vertices.map(\.positionAndSize.w)
    let depths = geometry.vertices.map(\.positionAndSize.z)

    #expect(geometry.vertices.count == 1_800)
    #expect(geometry.regionCounts[.ambientDust, default: 0] > 900)
    #expect(geometry.regionCounts[.ambientShard, default: 0] > 150)
    #expect(geometry.regionCounts[.floorSpark, default: 0] > 150)
    #expect((sizes.min() ?? 1) < 0.7)
    #expect((sizes.max() ?? 0) > 3)
    #expect((depths.max() ?? 0) - (depths.min() ?? 0) > 12)
}

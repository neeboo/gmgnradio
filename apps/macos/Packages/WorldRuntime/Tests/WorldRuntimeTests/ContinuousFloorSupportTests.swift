import Testing
@testable import WorldRuntime

private func floorGrid(_ heights: [Float?]) -> PropSupportGrid {
    var refs: [PropSupportLayerRef] = []
    var byColumn: [PropSupportColumn: [PropSupportLayer]] = [:]
    for x in 0..<5 {
        for z in 0..<3 {
            guard let height = heights[x] else { continue }
            let column = PropSupportColumn(x: x, z: z)
            let layer = PropSupportLayer(layer: 0, supportHeight: height,
                center: WorldVector3(x: Float(x), y: height, z: Float(z)))
            refs.append(PropSupportLayerRef(column: column, layer: layer))
            byColumn[column] = [layer]
        }
    }
    return PropSupportGrid(spacing: 1, bounds: WorldPlanarBounds(centerX: 2.5, centerZ: 1.5, halfExtentX: 2.5, halfExtentZ: 1.5),
        parameters: PropSupportGridParameters(spacing: 1), layers: refs, report: .empty,
        layersByColumn: byColumn, columnRangeX: 0...4, columnRangeZ: 0...2)
}

@Test func continuousFloorBridgeHasStableContacts() {
    let grid = floorGrid([0, -0.08, -0.16, -0.08, 0])
    let anchor = grid.layers[0]
    let collision = TriangleMeshCollisionWorld(triangles: [WorldTriangle(SIMD3(-1, -0.1, -1), SIMD3(6, -0.1, -1), SIMD3(6, -0.1, 4))])
    #expect(PropPlacementEvaluator.evaluate(footprint: WorldPlanarFootprint(size: SIMD2(5, 3)), height: 1,
        at: anchor, grid: grid, collision: collision, blockingVolumes: []) == nil)
}

@Test func continuousFloorRejectsUnsupportedCenterAndHole() {
    for heights: [Float?] in [[0, -0.015, -0.035, -0.05, -0.065], [0, 0, nil, 0, 0]] {
        let grid = floorGrid(heights)
        let collision = TriangleMeshCollisionWorld(triangles: [])
        #expect(PropPlacementEvaluator.evaluate(footprint: WorldPlanarFootprint(size: SIMD2(5, 3)), height: 1,
            at: grid.layers[0], grid: grid, collision: collision, blockingVolumes: []) == .noSupport)
    }
}

@Test func abruptRecessBelowRestingPlaneIsNotAnObstacle() {
    let grid = floorGrid([0, 0, -0.1, 0, 0])
    let slotSide = WorldTriangle(SIMD3(2, 0, 0), SIMD3(2, -0.1, 0), SIMD3(2, -0.1, 3))
    #expect(PropPlacementEvaluator.evaluate(footprint: WorldPlanarFootprint(size: SIMD2(5, 3)), height: 1,
        at: grid.layers[0], grid: grid, collision: TriangleMeshCollisionWorld(triangles: [slotSide]), blockingVolumes: []) == nil)
}

@Test func continuousFloorRejectsContactHullBoundaryAndWall() {
    let footprint = WorldPlanarFootprint(size: SIMD2(4, 3))
    let edgeGrid = floorGrid([0, -0.015, -0.035, -0.05, -0.065])
    #expect(PropPlacementEvaluator.resolvedSupportHeight(footprint: footprint, at: edgeGrid.layers[0], grid: edgeGrid) == nil)
    let grid = floorGrid([0, -0.015, -0.035, -0.015, 0])
    let wall = WorldTriangle(SIMD3(2, 0, 0), SIMD3(2, 2, 0), SIMD3(2, 0, 3))
    #expect(PropPlacementEvaluator.evaluate(footprint: WorldPlanarFootprint(size: SIMD2(5, 3)), height: 1,
        at: grid.layers[0], grid: grid, collision: TriangleMeshCollisionWorld(triangles: [wall]), blockingVolumes: []) == .blockedByMesh)
}

@Test func continuousFloorRequiresResolvedPlaneAtLowAnchor() {
    let grid = floorGrid([-0.015, 0, -0.015, 0, -0.015])
    let footprint = WorldPlanarFootprint(size: SIMD2(5, 3))
    #expect(PropPlacementEvaluator.resolvedSupportHeight(footprint: footprint, at: grid.layers[0], grid: grid) == 0)
    #expect(PropPlacementEvaluator.evaluate(footprint: footprint, height: 1,
        at: grid.layers[0], grid: grid, collision: TriangleMeshCollisionWorld(triangles: []), blockingVolumes: []) == .noSupport)
}

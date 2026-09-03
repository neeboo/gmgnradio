import Foundation
import Testing
@testable import WorldRuntime

@Test("GLB collider aligns with the rendered world and blocks a wall")
func glbColliderBlocksWall() throws {
    let transform = WorldMeshTransform(
        axisConversion: .flipYAndZ,
        origin: SIMD3<Float>(0, -1, 0),
        uniformScale: 1
    )
    let triangles = try GLBColliderDecoder().decode(
        data: makeFloorAndWallGLB(),
        transform: transform
    )
    let world = TriangleMeshCollisionWorld(
        triangles: triangles,
        cellSize: 0.25
    )
    let capsule = WorldCapsule(radius: 0.2, height: 1.8)

    #expect(triangles.count == 4)
    #expect(abs((world.groundHeight(at: SIMD3(-1, 4, 0)) ?? -1)) < 0.0001)
    #expect(world.canOccupy(capsule, at: SIMD3(-1, 0, 0)))
    #expect(!world.canOccupy(capsule, at: SIMD3(0, 0, 0)))
    #expect(!world.canTraverse(
        capsule,
        from: SIMD3(-1, 0, 0),
        to: SIMD3(1, 0, 0),
        maximumStepHeight: 0.3
    ))
}

@Test("A running world can atomically replace authored boxes with a GLB mesh")
func replaceableCollisionWorldUsesReplacement() {
    let capsule = WorldCapsule(radius: 0.2, height: 1.8)
    let authored = CollisionVolumeWorld(volumes: [])
    let mesh = TriangleMeshCollisionWorld(
        triangles: [
            WorldTriangle(
                SIMD3(0, 0, -1),
                SIMD3(0, 2, -1),
                SIMD3(0, 0, 1)
            ),
            WorldTriangle(
                SIMD3(0, 2, -1),
                SIMD3(0, 2, 1),
                SIMD3(0, 0, 1)
            ),
        ]
    )
    let world = ReplaceableCollisionWorld(initial: authored)

    #expect(world.canOccupy(capsule, at: .zero))
    world.replace(with: mesh)
    #expect(!world.canOccupy(capsule, at: .zero))
}

@Test("A room ceiling is not mistaken for the floor under the actor")
func glbColliderKeepsTheActorOnTheFloor() {
    let floor = horizontalQuad(y: 0)
    let ceiling = horizontalQuad(y: 2.5)
    let world = TriangleMeshCollisionWorld(triangles: floor + ceiling)
    let capsule = WorldCapsule(radius: 0.2, height: 1.8)

    #expect(world.groundHeight(at: SIMD3(0, 0, 0)) == 0)
    #expect(world.canTraverse(
        capsule,
        from: SIMD3(-0.5, 0, 0),
        to: SIMD3(0.5, 0, 0),
        maximumStepHeight: 0.3
    ))
}

@Test("A walkable sloped floor supports the capsule without blocking it")
func glbColliderAllowsAStandingCapsuleOnASlope() {
    let floor = [
        WorldTriangle(
            SIMD3(-2, 0, -2),
            SIMD3(2, 0.08, -2),
            SIMD3(2, 0.08, 2)
        ),
        WorldTriangle(
            SIMD3(-2, 0, -2),
            SIMD3(2, 0.08, 2),
            SIMD3(-2, 0, 2)
        ),
    ]
    let world = TriangleMeshCollisionWorld(triangles: floor)
    let capsule = WorldCapsule(radius: 0.2, height: 0.9)
    let ground = world.groundHeight(at: .zero)
    let canOccupy = world.canOccupy(
        capsule,
        at: SIMD3(0, ground ?? 0, 0)
    )

    #expect(ground != nil)
    #expect(canOccupy)
}

@Test("Tiny reconstruction seams do not interrupt walking")
func glbColliderBridgesTinyFloorSeams() {
    let left = horizontalQuad(
        y: 0,
        minimumX: -1,
        maximumX: -0.01,
        minimumZ: -1,
        maximumZ: 1
    )
    let right = horizontalQuad(
        y: 0.02,
        minimumX: 0.01,
        maximumX: 1,
        minimumZ: -1,
        maximumZ: 1
    )
    let world = TriangleMeshCollisionWorld(triangles: left + right)
    let capsule = WorldCapsule(radius: 0.12, height: 0.9)

    #expect(world.groundHeight(at: .zero) != nil)
    #expect(world.canTraverse(
        capsule,
        from: SIMD3(-0.2, 0, 0),
        to: SIMD3(0.2, 0.02, 0),
        maximumStepHeight: 0.3
    ))
}

@Test("The official Warm Kitchen collider remains decodable")
func officialWarmKitchenColliderCanary() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment[
        "GMGN_WARM_KITCHEN_COLLIDER_GLB"
    ], let manifestPath = environment[
        "GMGN_WARM_KITCHEN_WORLD_JSON"
    ] else {
        return
    }
    let transform = WorldMeshTransform(
        axisConversion: .flipYAndZ,
        origin: SIMD3(0.0076904297, -0.98046875, -1.1608887),
        uniformScale: 0.6739059
    )
    let triangles = try GLBColliderDecoder().decode(
        data: Data(contentsOf: URL(fileURLWithPath: path)),
        transform: transform
    )
    let world = TriangleMeshCollisionWorld(triangles: triangles)
    let manifest = try JSONDecoder().decode(
        WorldManifest.self,
        from: Data(contentsOf: URL(fileURLWithPath: manifestPath))
    )
    let waypoints = Dictionary(
        uniqueKeysWithValues: manifest.waypoints.map { ($0.id, $0.position.simd3) }
    )
    let capsule = WorldCapsule(radius: 0.12, height: 0.9)

    #expect(triangles.count > 100_000)
    let openWaypointIDs: Set<String> = [
        "wp.center",
        "wp.dining.table",
        "wp.kitchen.aisle",
        "wp.kitchen.counter",
    ]
    for waypoint in manifest.waypoints
        where openWaypointIDs.contains(waypoint.id)
    {
        let ground = try #require(
            world.groundHeight(at: waypoint.position.simd3)
        )
        let groundedPosition = SIMD3(
            waypoint.position.x,
            ground,
            waypoint.position.z
        )
        let canOccupy = world.canOccupy(
            capsule,
            at: groundedPosition
        )
        #expect(
            canOccupy,
            "Blocked waypoint: \(waypoint.id), ground=\(ground)"
        )
    }
    let openRouteIDs: Set<String> = [
        "route.auto.anchor.wp.center",
        "route.auto.anchor.wp.dining.table",
        "route.auto.anchor.wp.kitchen.aisle",
        "route.auto.anchor.wp.kitchen.counter",
    ]
    for route in manifest.routes where openRouteIDs.contains(route.id) {
        for (startID, endID) in zip(route.waypointIDs, route.waypointIDs.dropFirst()) {
            let start = try #require(waypoints[startID])
            let end = try #require(waypoints[endID])
            let canTraverse = world.canTraverse(
                capsule,
                from: start,
                to: end,
                maximumStepHeight: 0.3
            )
            #expect(
                canTraverse,
                "Blocked route: \(route.id) \(startID) -> \(endID)"
            )
        }
    }
    let savedSpawn = try #require(waypoints["wp.spawn"])
    let savedSpawnGround = try #require(world.groundHeight(at: savedSpawn))
    let savedSpawnIsOpen = world.canOccupy(
        capsule,
        at: SIMD3(savedSpawn.x, savedSpawnGround, savedSpawn.z)
    )
    #expect(!savedSpawnIsOpen)
}

private func makeFloorAndWallGLB() -> Data {
    // Source coordinates are World Labs OpenCV-style: +Y points down and
    // +Z points forward. The decoder flips Y/Z before applying the framing.
    let positions: [SIMD3<Float>] = [
        SIMD3(-2, 1, -2), SIMD3(2, 1, -2), SIMD3(2, 1, 2),
        SIMD3(-2, 1, 2),
        SIMD3(0, 1, -1), SIMD3(0, -1, -1), SIMD3(0, -1, 1),
        SIMD3(0, 1, 1),
    ]
    let indices: [UInt32] = [
        0, 1, 2, 0, 2, 3,
        4, 5, 6, 4, 6, 7,
    ]

    var binary = Data()
    for index in indices {
        appendLittleEndian(index, to: &binary)
    }
    let positionOffset = binary.count
    for position in positions {
        appendLittleEndian(position.x.bitPattern, to: &binary)
        appendLittleEndian(position.y.bitPattern, to: &binary)
        appendLittleEndian(position.z.bitPattern, to: &binary)
    }
    padToFourBytes(&binary, byte: 0)

    let document: [String: Any] = [
        "asset": ["version": "2.0"],
        "scene": 0,
        "scenes": [["nodes": [0]]],
        "nodes": [["mesh": 0]],
        "meshes": [[
            "primitives": [[
                "attributes": ["POSITION": 1],
                "indices": 0,
                "mode": 4,
            ]],
        ]],
        "accessors": [
            [
                "bufferView": 0,
                "componentType": 5125,
                "count": indices.count,
                "type": "SCALAR",
            ],
            [
                "bufferView": 1,
                "componentType": 5126,
                "count": positions.count,
                "type": "VEC3",
            ],
        ],
        "bufferViews": [
            ["buffer": 0, "byteOffset": 0, "byteLength": positionOffset],
            [
                "buffer": 0,
                "byteOffset": positionOffset,
                "byteLength": positions.count * 12,
            ],
        ],
        "buffers": [["byteLength": binary.count]],
    ]
    var json = try! JSONSerialization.data(withJSONObject: document)
    padToFourBytes(&json, byte: 0x20)

    var result = Data()
    result.append(contentsOf: [0x67, 0x6C, 0x54, 0x46])
    appendLittleEndian(UInt32(2), to: &result)
    appendLittleEndian(
        UInt32(12 + 8 + json.count + 8 + binary.count),
        to: &result
    )
    appendLittleEndian(UInt32(json.count), to: &result)
    appendLittleEndian(UInt32(0x4E4F534A), to: &result)
    result.append(json)
    appendLittleEndian(UInt32(binary.count), to: &result)
    appendLittleEndian(UInt32(0x004E4942), to: &result)
    result.append(binary)
    return result
}

private func horizontalQuad(
    y: Float,
    minimumX: Float = -2,
    maximumX: Float = 2,
    minimumZ: Float = -2,
    maximumZ: Float = 2
) -> [WorldTriangle] {
    let first = SIMD3<Float>(minimumX, y, minimumZ)
    let second = SIMD3<Float>(maximumX, y, minimumZ)
    let third = SIMD3<Float>(maximumX, y, maximumZ)
    let fourth = SIMD3<Float>(minimumX, y, maximumZ)
    return [
        WorldTriangle(first, second, third),
        WorldTriangle(first, third, fourth),
    ]
}

private func appendLittleEndian<T: FixedWidthInteger>(
    _ value: T,
    to data: inout Data
) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
}

private func padToFourBytes(_ data: inout Data, byte: UInt8) {
    while !data.count.isMultiple(of: 4) {
        data.append(byte)
    }
}

import Foundation

@main struct NavigationTests {
    static func main() throws {
        func check(_ condition: Bool, _ message: String) {
            if !condition { print("FAIL: \(message)"); exit(1) }
        }
        func floor(_ minX: Float, _ maxX: Float) -> [WorldTriangle] {
            [WorldTriangle(SIMD3(minX, 0, -2), SIMD3(maxX, 0, 2), SIMD3(maxX, 0, -2)),
             WorldTriangle(SIMD3(minX, 0, -2), SIMD3(minX, 0, 2), SIMD3(maxX, 0, 2))]
        }
        let anchors = [WorldWaypoint(id: "wp.spawn", position: .init(x:-2,y:0,z:0), arrivalRadius:0.2, enabled:true),
                       WorldWaypoint(id: "activity.keep", position: .init(x:2,y:0,z:0), arrivalRadius:0.2, enabled:true)]
        let obstacle = WorldCollisionVolume(id:"furniture", center:.init(x:0,y:0.8,z:0),
            halfExtents:.init(x:0.5,y:0.8,z:0.6), rotation:.init(x:0,y:0,z:0,w:1), isBlocking:true)
        let triangles = floor(-3, 3) + floor(5, 7)
        let result = try bakeCabinNavigation(triangles:triangles, volumes:[obstacle], anchors:anchors)
        check(result.waypoints.count > 30, "floor coverage must expand beyond authored anchors")
        check(anchors.allSatisfy { result.waypoints.contains($0) }, "manual anchor IDs and coordinates preserved")
        check(result.waypoints.allSatisfy { $0.position.x < 4 }, "disconnected floor island excluded")
        let mesh = TriangleMeshCollisionWorld(triangles:triangles)
        let props = CollisionVolumeWorld(volumes:[obstacle])
        let capsule = WorldCapsule(radius:0.2,height:1.8)
        let byID = Dictionary(uniqueKeysWithValues:result.waypoints.map {($0.id,$0.position.simd3)})
        var adjacency: [String:Set<String>] = [:]
        for route in result.routes {
            check(route.bidirectional && route.waypointIDs.count == 2, "explicit bidirectional edges")
            let a = route.waypointIDs[0], b = route.waypointIDs[1]
            adjacency[a,default:[]].insert(b); adjacency[b,default:[]].insert(a)
            for (start,end) in [(byID[a]!,byID[b]!),(byID[b]!,byID[a]!)] {
                check(mesh.canTraverse(capsule,from:start,to:end,maximumStepHeight:0.3), "production mesh accepts edge")
                let count = max(1,Int(ceil(worldDistance(start,end)/0.05)))
                for step in 0...count {
                    let p = start+(end-start)*Float(step)/Float(count)
                    check(props.canOccupy(capsule,at:p), "furniture clearance holds at every sample")
                }
            }
        }
        var reached: Set<String> = ["wp.spawn"], queue = ["wp.spawn"]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            for next in adjacency[current,default:[]] where reached.insert(next).inserted { queue.append(next) }
        }
        check(reached == Set(byID.keys), "every output waypoint reachable from spawn")
        check(result.routes.count > result.waypoints.count, "coverage retains route alternatives around furniture")
        let repeated = try bakeCabinNavigation(triangles:triangles.reversed(),volumes:[obstacle],anchors:anchors)
        check(result.waypoints == repeated.waypoints && result.routes == repeated.routes, "deterministic geometry order")
        let cabinFloor = [WorldTriangle(SIMD3<Float>(-4,0,-7),SIMD3<Float>(4,0,2),SIMD3<Float>(4,0,-7)),
                          WorldTriangle(SIMD3<Float>(-4,0,-7),SIMD3<Float>(-4,0,2),SIMD3<Float>(4,0,2))]
        let cabinAnchors = [WorldWaypoint(id:"wp.spawn",position:.init(x:0,y:0,z:-4.5),arrivalRadius:0.2,enabled:true),
                            WorldWaypoint(id:"wp.keep",position:.init(x:-3.8,y:0,z:-6.5),arrivalRadius:0.2,enabled:true)]
        let cabin = try bakeCabinNavigation(triangles:cabinFloor,volumes:[],anchors:cabinAnchors)
        let reserved = [WorldCollisionVolume(id:"table",center:.init(x:-2.7,y:1,z:-5),halfExtents:.init(x:0.45,y:1,z:0.325),rotation:.init(x:0,y:0,z:0,w:1),isBlocking:true),
                        WorldCollisionVolume(id:"floor",center:.init(x:-2.6,y:1,z:-3),halfExtents:.init(x:0.4,y:1,z:0.5),rotation:.init(x:0,y:0,z:0,w:1),isBlocking:true)]
        let reservationWorld = CollisionVolumeWorld(volumes:reserved)
        let tableWorld = CollisionVolumeWorld(volumes:[reserved[0]])
        check(cabin.waypoints.allSatisfy { reservationWorld.canOccupy(.init(radius:0.25,height:1.8),at:$0.position.simd3) },
              "automatic waypoints must preserve both legal prop support footprints")
        let cabinByID = Dictionary(uniqueKeysWithValues:cabin.waypoints.map {($0.id,$0.position.simd3)})
        for route in cabin.routes {
            let start = cabinByID[route.waypointIDs[0]]!, end = cabinByID[route.waypointIDs[1]]!
            for step in 0...100 {
                check(reservationWorld.canOccupy(.init(radius:0.25,height:1.8),at:start+(end-start)*Float(step)/100),
                      "automatic edges must preserve support clearance between endpoints")
                check(tableWorld.canOccupy(.init(radius:0.3,height:1.8),at:start+(end-start)*Float(step)/100),
                      "table retains the existing 0.30 m route clearance contract")
            }
        }
        check(cabinAnchors.allSatisfy { cabin.waypoints.contains($0) }, "support reservation retains all original anchors")
        print("PASS: grounded coverage, furniture clearance, disconnected pruning, anchor identity, edge traversal, determinism")
    }
}

import Foundation

struct CabinNavigation: Codable {
    let waypoints: [WorldWaypoint]
    let routes: [WorldRoute]
    let report: CabinNavigationReport
}

struct CabinNavigationReport: Codable {
    var triangleCount = 0
    var gridColumns = 0
    var surfaceCandidates = 0
    var blockedCandidates = 0
    var columnsWithoutGround = 0
    var disconnectedCandidates = 0
    var rejectedEdges: [String:Int] = [:]
    var waypointCount = 0
    var bidirectionalEdgeCount = 0
    var totalEdgeLengthMeters: Float = 0
    var furthestPathFromSpawnMeters: Float = 0
    var anchorPathLengthsMeters: [String:Float] = [:]
    var groundBounds: [String:Float] = [:]
    var spacingMeters: Float = 0.5
    var capsuleRadiusMeters: Float = 0.2
    var capsuleHeightMeters: Float = 1.8
    var maximumStepMeters: Float = 0.3
    var verificationSampleSpacingMeters: Float = 0.05
}

struct CabinNavigationFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

struct CabinNavigationPhysics: WorldCollisionQuerying {
    let mesh: TriangleMeshCollisionWorld
    let furniture: CollisionVolumeWorld
    func groundHeight(at point: SIMD3<Float>) -> Float? { mesh.groundHeight(at:point) }
    func canOccupy(_ capsule: WorldCapsule, at point: SIMD3<Float>) -> Bool {
        mesh.canOccupy(capsule,at:point) && furniture.canOccupy(capsule,at:point)
    }
}

// Use exactly the production mesh and combined furniture collision queries.
// The denser sample pass additionally checks the same grounded destinations
// the activity executor consumes while it advances along an edge.
func cabinEdgeFailure(from start: SIMD3<Float>, to end: SIMD3<Float>, physics: CabinNavigationPhysics) -> String? {
    let capsule = WorldCapsule(radius:0.2,height:1.8)
    guard physics.mesh.canTraverse(capsule,from:start,to:end,maximumStepHeight:0.3) else { return "meshTraversal" }
    guard physics.canTraverse(capsule,from:start,to:end,maximumStepHeight:0.3) else { return "combinedTraversal" }
    let count = max(1,Int(ceil(worldDistance(start,end)/0.05)))
    var previous = start
    for index in 0...count {
        let sample = start + (end-start) * Float(index)/Float(count)
        guard let ground = physics.groundHeight(at:sample) else { return "missingGround" }
        let grounded = SIMD3(sample.x,ground,sample.z)
        guard abs(ground-previous.y) <= 0.3001 else { return "stepHeight" }
        guard physics.canOccupy(capsule,at:grounded) else { return "capsuleCollision" }
        guard physics.canTraverse(capsule,from:previous,to:grounded,maximumStepHeight:0.3) else { return "sampleTraversal" }
        previous = grounded
    }
    return nil
}

private struct GridCell: Hashable { let x: Int; let z: Int }

func bakeCabinNavigation(triangles: [WorldTriangle], volumes: [WorldCollisionVolume], anchors: [WorldWaypoint]) throws -> CabinNavigation {
    guard !triangles.isEmpty, anchors.contains(where:{$0.id == "wp.spawn"}),
          Set(anchors.map(\.id)).count == anchors.count else { throw CabinNavigationFailure("Missing geometry or unique spawn anchor") }
    let physics = CabinNavigationPhysics(mesh:TriangleMeshCollisionWorld(triangles:triangles),furniture:CollisionVolumeWorld(volumes:volumes))
    let capsule = WorldCapsule(radius:0.2,height:1.8)
    let spacing: Float = 0.5
    let vertices = triangles.flatMap { [$0.first,$0.second,$0.third] }
    let minX = vertices.map(\.x).min()!, maxX = vertices.map(\.x).max()!
    let minY = vertices.map(\.y).min()!, maxY = vertices.map(\.y).max()!
    let minZ = vertices.map(\.z).min()!, maxZ = vertices.map(\.z).max()!
    var report = CabinNavigationReport()
    report.triangleCount = triangles.count
    var points = Dictionary(uniqueKeysWithValues:anchors.map {($0.id,$0)})
    var cells: [GridCell:[String]] = [:]
    for anchor in anchors {
        guard physics.canOccupy(capsule,at:anchor.position.simd3),
              let ground = physics.groundHeight(at:anchor.position.simd3), abs(ground-anchor.position.y) < 0.05 else {
            throw CabinNavigationFailure("Authored anchor does not fit the real ground: \(anchor.id)")
        }
        cells[GridCell(x:Int(round(anchor.position.x/spacing)),z:Int(round(anchor.position.z/spacing))),default:[]].append(anchor.id)
    }
    for x in Int(ceil(minX/spacing))...Int(floor(maxX/spacing)) {
        for z in Int(ceil(minZ/spacing))...Int(floor(maxZ/spacing)) {
            report.gridColumns += 1
            let px = Float(x)*spacing, pz = Float(z)*spacing
            var ceiling = maxY + 0.1, heights: [Float] = []
            // A reconstructed column may contain a floor below a table or
            // ceiling. Visit every actual ground layer; connectivity decides
            // which layer belongs to the resident's reachable area.
            while let ground = physics.groundHeight(at:SIMD3(px,ceiling,pz)), ground >= minY-0.001 {
                heights.append(ground)
                ceiling = ground-0.101
            }
            if heights.isEmpty { report.columnsWithoutGround += 1 }
            for (level,height) in heights.sorted().enumerated() {
                report.surfaceCandidates += 1
                let p = SIMD3(px,height,pz)
                guard physics.canOccupy(capsule,at:p) else { report.blockedCandidates += 1; continue }
                if anchors.contains(where:{worldDistance($0.position.simd3,p) < 0.05}) { continue }
                let id = "wp.auto.x\(x).z\(z).h\(level)"
                points[id] = WorldWaypoint(id:id,position:WorldVector3(p),arrivalRadius:0.2,enabled:true)
                cells[GridCell(x:x,z:z),default:[]].append(id)
            }
        }
    }
    var adjacency: [String:Set<String>] = [:]
    var edges: [(String,String)] = []
    for cell in cells.keys.sorted(by:{$0.x == $1.x ? $0.z < $1.z : $0.x < $1.x}) {
        for a in cells[cell]!.sorted() {
            for dx in -1...1 {
                for dz in -1...1 {
                    for b in cells[GridCell(x:cell.x+dx,z:cell.z+dz),default:[]].sorted() where a < b {
                        let start = points[a]!.position.simd3, end = points[b]!.position.simd3
                        guard worldDistance(start,end) <= 0.9 else { continue }
                        if let reason = cabinEdgeFailure(from:start,to:end,physics:physics) ?? cabinEdgeFailure(from:end,to:start,physics:physics) {
                            report.rejectedEdges[reason,default:0] += 1
                        } else {
                            edges.append((a,b)); adjacency[a,default:[]].insert(b); adjacency[b,default:[]].insert(a)
                        }
                    }
                }
            }
        }
    }
    var reached: Set<String> = ["wp.spawn"], queue = ["wp.spawn"], cursor = 0
    while cursor < queue.count {
        let id = queue[cursor]; cursor += 1
        for next in adjacency[id,default:[]].sorted() where reached.insert(next).inserted { queue.append(next) }
    }
    for anchor in anchors where !reached.contains(anchor.id) { throw CabinNavigationFailure("Authored anchor disconnected from spawn: \(anchor.id)") }
    report.disconnectedCandidates = points.count-reached.count
    let waypoints = anchors + points.values.filter { reached.contains($0.id) && !anchors.contains($0) }.sorted {$0.id < $1.id}
    let accepted = edges.filter {reached.contains($0.0) && reached.contains($0.1)}.sorted {$0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0}
    let routes = accepted.enumerated().map {index,pair in WorldRoute(id:"route.auto.\(index)",waypointIDs:[pair.0,pair.1],bidirectional:true,enabled:true)}
    report.waypointCount = waypoints.count
    report.bidirectionalEdgeCount = routes.count
    report.totalEdgeLengthMeters = accepted.reduce(0) {$0 + worldDistance(points[$1.0]!.position.simd3,points[$1.1]!.position.simd3)}
    report.groundBounds = ["minimumX":waypoints.map(\.position.x).min()!,"maximumX":waypoints.map(\.position.x).max()!,
        "minimumY":waypoints.map(\.position.y).min()!,"maximumY":waypoints.map(\.position.y).max()!,
        "minimumZ":waypoints.map(\.position.z).min()!,"maximumZ":waypoints.map(\.position.z).max()!]
    var distances: [String:Float] = ["wp.spawn":0], unsettled = reached
    while let current = unsettled.min(by:{distances[$0,default:.infinity] < distances[$1,default:.infinity]}) {
        unsettled.remove(current)
        let distance = distances[current,default:.infinity]
        for next in adjacency[current,default:[]] where unsettled.contains(next) {
            let candidate = distance + worldDistance(points[current]!.position.simd3,points[next]!.position.simd3)
            distances[next] = min(distances[next,default:.infinity],candidate)
        }
    }
    report.furthestPathFromSpawnMeters = distances.values.max() ?? 0
    report.anchorPathLengthsMeters = Dictionary(uniqueKeysWithValues:anchors.map {($0.id,distances[$0.id]!)})
    return CabinNavigation(waypoints:waypoints,routes:routes,report:report)
}

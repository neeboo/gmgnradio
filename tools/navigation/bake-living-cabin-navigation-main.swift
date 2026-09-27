import CryptoKit
import Foundation

@main struct BakeLivingCabinNavigation {
    static func main() throws {
        let args = CommandLine.arguments
        let package = URL(fileURLWithPath:args[1]), output = URL(fileURLWithPath:args[2])
        let manifestData = try Data(contentsOf:package.appendingPathComponent("world.json"))
        let configurationData = try Data(contentsOf:package.appendingPathComponent("marble.json"))
        let colliderData = try Data(contentsOf:package.appendingPathComponent("collider.glb"))
        let manifest = try JSONDecoder().decode(WorldManifest.self,from:manifestData)
        struct Configuration: Decodable {
            struct Framing: Decodable { let origin: [Float]; let scale: Float }
            let framing: Framing
        }
        let config = try JSONDecoder().decode(Configuration.self,from:configurationData)
        let origin = config.framing.origin
        let triangles = try GLBColliderDecoder().decode(data:colliderData,
            transform:WorldMeshTransform(axisConversion:.flipYAndZ,origin:SIMD3(origin[0],origin[1],origin[2]),uniformScale:config.framing.scale))
        let anchors = manifest.waypoints.filter {!$0.id.hasPrefix("wp.auto.")}
        let navigation: CabinNavigation
        if args.count == 4 {
            navigation = try JSONDecoder().decode(CabinNavigation.self,from:Data(contentsOf:URL(fileURLWithPath:args[3])))
        } else {
            navigation = try bakeCabinNavigation(triangles:triangles,volumes:manifest.collisionVolumes,anchors:anchors)
        }
        let physics = CabinNavigationPhysics(mesh:TriangleMeshCollisionWorld(triangles:triangles),furniture:CollisionVolumeWorld(manifest:manifest))
        let points = Dictionary(uniqueKeysWithValues:navigation.waypoints.map {($0.id,$0.position.simd3)})
        guard anchors.allSatisfy({navigation.waypoints.contains($0)}) else { throw CabinNavigationFailure("Authored anchors changed") }
        var adjacency: [String:Set<String>] = [:]
        for route in navigation.routes {
            guard route.enabled,route.bidirectional,route.waypointIDs.count == 2,
                  let start = points[route.waypointIDs[0]], let end = points[route.waypointIDs[1]] else {
                throw CabinNavigationFailure("Invalid edge: \(route.id)")
            }
            for (a,b) in [(start,end),(end,start)] {
                if let reason = cabinEdgeFailure(from:a,to:b,physics:physics) {
                    throw CabinNavigationFailure("Edge failed production capsule verification: \(route.id): \(reason)")
                }
            }
            let a = route.waypointIDs[0], b = route.waypointIDs[1]
            adjacency[a,default:[]].insert(b); adjacency[b,default:[]].insert(a)
        }
        var reached: Set<String> = ["wp.spawn"], queue = ["wp.spawn"], cursor = 0
        while cursor < queue.count {
            let id = queue[cursor]; cursor += 1
            for next in adjacency[id,default:[]] where reached.insert(next).inserted { queue.append(next) }
        }
        guard reached == Set(points.keys) else { throw CabinNavigationFailure("Candidate contains unreachable waypoints") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
        var document = try JSONSerialization.jsonObject(with:encoder.encode(navigation)) as! [String:Any]
        let rawManifest = try JSONSerialization.jsonObject(with:manifestData) as! [String:Any]
        let rawConfiguration = try JSONSerialization.jsonObject(with:configurationData) as! [String:Any]
        let rawAnchors = (rawManifest["waypoints"] as! [[String:Any]]).filter {!(($0["id"] as! String).hasPrefix("wp.auto."))}
        let rawAnchorByID = Dictionary(uniqueKeysWithValues:rawAnchors.map {($0["id"] as! String,$0)})
        document["waypoints"] = (document["waypoints"] as! [[String:Any]]).map {rawAnchorByID[$0["id"] as! String] ?? $0}
        var updatedManifest = rawManifest
        updatedManifest["waypoints"] = document["waypoints"]
        updatedManifest["routes"] = document["routes"]
        let candidateManifest = try JSONDecoder().decode(WorldManifest.self,from:JSONSerialization.data(withJSONObject:updatedManifest))
        let issues = WorldPackageValidator().validate(candidateManifest,packageRoot:package)
        guard issues.isEmpty else { throw CabinNavigationFailure("WorldPackageValidator rejected candidate: \(issues)") }
        document["schemaVersion"] = 1
        document["generator"] = "production-capsule-grid-v1"
        document["source"] = ["worldID":manifest.worldID,
            "colliderSHA256":SHA256.hash(data:colliderData).map {String(format:"%02x",$0)}.joined(),
            "framing":rawConfiguration["framing"]!,
            "collisionVolumes":rawManifest["collisionVolumes"]!,
            "manualWaypoints":rawAnchors]
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        try (JSONSerialization.data(withJSONObject:document,options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes])+Data("\n".utf8))
            .write(to:output.appendingPathComponent("navigation.json"))
        try (encoder.encode(navigation.report)+Data("\n".utf8)).write(to:output.appendingPathComponent("report.json"))
        print("PASS: \(navigation.waypoints.count) grounded waypoints; \(navigation.routes.count) edges verified in both directions at 0.05 m steps; all reachable from wp.spawn")
        print("Candidate: \(output.appendingPathComponent("navigation.json").path)")
        print(String(data:try encoder.encode(navigation.report),encoding:.utf8)!)
    }
}

// Hostless calibration against the shipped Marble collision mesh.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceRoot = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
let bootstrap = try String(contentsOf: sourceRoot.appendingPathComponent("App/LivingWorldBootstrap.swift"), encoding: .utf8)
let start = bootstrap.range(of: "struct MarbleLivingCabinCollisionWorld:")!.lowerBound
let end = bootstrap.range(of: "/// An effect is keyed", range: start..<bootstrap.endIndex)!.lowerBound
let harness = #"""
import Foundation
import WorldRuntime
import simd
\#(bootstrap[start..<end])
struct Config: Decodable {
    struct Framing: Decodable { let origin: [Float]; let scale: Float }
    let framing: Framing
}
@main struct Test {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath:"apps/macos/Resources/Worlds/marble-living-cabin")
        let manifest = try JSONDecoder().decode(WorldManifest.self, from: Data(contentsOf:root.appendingPathComponent("world.json")))
        let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf:root.appendingPathComponent("marble.json")))
        let origin = SIMD3(config.framing.origin[0],config.framing.origin[1],config.framing.origin[2])
        let triangles = try GLBColliderDecoder().decode(data:Data(contentsOf:root.appendingPathComponent("collider.glb")),transform:WorldMeshTransform(axisConversion:.flipYAndZ,origin:origin,uniformScale:config.framing.scale))
        let mesh = TriangleMeshCollisionWorld(triangles:triangles)
        let physics = MarbleLivingCabinCollisionWorld(environment:mesh,props:CollisionVolumeWorld(volumes:manifest.collisionVolumes))
        if !CommandLine.arguments.contains("--scan") {
            var count = 0
            func check(_ ok:Bool,_ message:String) { count += 1; guard ok else { print("FAIL: \(message)");exit(1) } }
            let fixture=try Data(contentsOf:URL(fileURLWithPath:"tmp/generated-props/espresso-machine-v1/model.glb"))
            let length=(0..<4).reduce(0){$0 | Int(fixture[12+$1]) << (8*$1)}
            let json=try JSONSerialization.jsonObject(with:fixture.subdata(in:20..<(20+length))) as! [String:Any]
            let primitive=((json["meshes"] as! [[String:Any]])[0]["primitives"] as! [[String:Any]])[0]
            let index=(primitive["attributes"] as! [String:Int])["POSITION"]!
            let accessor=(json["accessors"] as! [[String:Any]])[index]
            for node in json["nodes"] as! [[String:Any]] {
                check(node["matrix"] == nil && node["translation"] == nil && node["scale"] == nil && node["rotation"] == nil,"actual fixture has identity nodes")
            }
            check(accessor["min"] != nil && accessor["max"] != nil,"fixture geometry retains declared bounds")
            // Recorded and asserted by test-resident-prop-render-gpu.swift using the real
            // GLTF loader. Accessor metadata differs slightly from the loaded geometry.
            let size=WorldVector3(x:0.35069498,y:0.41999996,z:0.56627256)
            let prop=WorldGeneratedProp(objectID:"test.coffee",sourceWishID:"test",assetID:"test",displayName:"咖啡机",size:size,sourceHeight:0.745393)
            let context=try WorldAgentContext(manifest:manifest)
            let independent=ResidentPropPlacementConfiguration.independentCollisionVolumes(manifest)
            let combined=MarbleLivingCabinCollisionWorld(environment:mesh,props:CollisionVolumeWorld(volumes:independent))
            _=try context.installCollisionWorldAndReconcilePlacement(combined)
            let selected=ResidentPropPlacementConfiguration.nearbyTriangles(triangles)
            let service=ResidentPropPlacementService(context:context,surfaces:ResidentPropPlacementConfiguration.surfaces,
                validateEnvironment:{ box,height in
                    guard WorldPropMeshClearance.canPlace(box,supportHeight:height,triangles:selected) else { throw ResidentPropPlacementError.collision("mesh") }
                })
            _=try service.commit(.register(prop),expectedLayoutRevision:0,requestID:"register")
            for surface in service.surfaces {
                for yaw:Float in [0,.pi/4,.pi/2] {
                    _=try service.preview(objectID:prop.objectID,placement:.init(surfaceID:surface.id,position:surface.center,yaw:yaw))
                    check(true,"coffee fits \(surface.id) yaw \(yaw)")
                }
                do {
                    let p=WorldVector3(x:surface.center.x+surface.halfExtents.x,y:surface.center.y,z:surface.center.z)
                    _=try service.preview(objectID:prop.objectID,placement:.init(surfaceID:surface.id,position:p,yaw:.pi/4))
                    check(false,"overhanging rotated coffee rejected")
                } catch ResidentPropPlacementError.outsideSurface { check(true,"overhanging rotated coffee rejected") }
            }
            let stand=ResidentPropPlacementConfiguration.tableCollision
            check(WorldPropMeshClearance.canPlace(stand,supportHeight:ResidentPropPlacementConfiguration.tablePosition.y,triangles:selected),"table real box clear in mesh")
            let obstacles=CollisionVolumeWorld(volumes:[stand])
            let points=Dictionary(uniqueKeysWithValues:manifest.waypoints.map{($0.id,$0.position)})
            for route in manifest.routes {
                for pair in zip(route.waypointIDs,route.waypointIDs.dropFirst()) {
                    let a=points[pair.0]!,b=points[pair.1]!,start=SIMD3(a.x,a.y,a.z),end=SIMD3(b.x,b.y,b.z)
                    for step in 0...50 {
                        check(obstacles.canOccupy(.init(radius:0.3,height:1.8),at:start+(end-start)*Float(step)/50),"table keeps authored route clear")
                    }
                }
            }
            for surface in service.surfaces where surface.excludedCollisionID == nil {
                for x:Float in [-1,0,1] {for z:Float in [-1,0,1] {
                    let p=SIMD3(surface.center.x+x*surface.halfExtents.x,Float(0),surface.center.z+z*surface.halfExtents.z)
                    let ground=physics.groundHeight(at:p)
                    check(ground != nil && abs(ground!-surface.center.y)<0.05,"floor area within five cm of reconstructed ground")
                }}
            }
            check(context.state.objectStates[prop.objectID]?.isEnabled == false,"all previews preserve disabled inventory")
            print("PASS: \(count) real cabin + coffee surface checks; size=\(size), local triangles=\(selected.count)")
            return
        }
        for x in stride(from:Float(-3),through:Float(2),by:0.5) {
            for z in stride(from:Float(-6.5),through:Float(-2),by:0.5) {
                let p = SIMD3<Float>(x,0,z)
                guard let y = physics.groundHeight(at:p), abs(y)<0.3,
                    physics.canOccupy(WorldCapsule(radius:0.5,height:1.2),at:SIMD3(x,y,z)) else { continue }
                let routeDistance = manifest.routes.flatMap { route in zip(route.waypointIDs,route.waypointIDs.dropFirst()).map { pair -> Float in
                    let a = manifest.waypoints.first{$0.id == pair.0}!.position
                    let b = manifest.waypoints.first{$0.id == pair.1}!.position
                    let u = SIMD2<Float>(a.x,a.z),v = SIMD2<Float>(b.x,b.z),q = SIMD2<Float>(x,z)
                    let d = v-u, w = q-u, len = d.x*d.x+d.y*d.y
                    let t = max(0,min(1,(w.x*d.x+w.y*d.y)/len)), e = w-d*t
                    return sqrt(e.x*e.x+e.y*e.y)
                }}.min() ?? 0
                if routeDistance > 1 { print("CLEAR x=\(x) y=\(y) z=\(z) route=\(routeDistance)") }
            }
        }
    }
}
"""#
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-prop-surfaces-\(UUID())")
try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:true)
defer { try? FileManager.default.removeItem(at:temporary) }
let program = temporary.appendingPathComponent("Test.swift")
try harness.write(to:program,atomically:true,encoding:.utf8)
let executable = temporary.appendingPathComponent("test")
func run(_ binary:String,_ args:[String]) throws -> Int32 {
    let p = Process(); p.executableURL=URL(fileURLWithPath:binary);p.arguments=args
    try p.run();p.waitUntilExit();return p.terminationStatus
}
let build = root.appendingPathComponent("apps/macos/Packages/WorldRuntime/.build/arm64-apple-macosx/debug")
let objects = try FileManager.default.contentsOfDirectory(at:build.appendingPathComponent("WorldRuntime.build"),includingPropertiesForKeys:nil).filter{$0.pathExtension == "o"}.map(\.path)
let compiled = try run("/usr/bin/swiftc",["-j1","-parse-as-library","-I",build.appendingPathComponent("Modules").path,
    sourceRoot.appendingPathComponent("Agent/WorldAgentContext.swift").path,
    sourceRoot.appendingPathComponent("Presence/ResidentPropPlacementService.swift").path,
    sourceRoot.appendingPathComponent("Presence/ResidentPropPlacementConfiguration.swift").path,
    program.path,"-o",executable.path]+objects)
guard compiled == 0 else { exit(compiled) }
exit(try run(executable.path,Array(CommandLine.arguments.dropFirst())))

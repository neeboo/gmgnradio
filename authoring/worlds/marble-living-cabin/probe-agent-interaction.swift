// Compile the actual non-UI agent context against the already-built WorldRuntime.
// No app/test host, network, render loop, or persistent save is started.
import Foundation
let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
let build=root.appendingPathComponent("apps/macos/Packages/WorldRuntime/.build/arm64-apple-macosx/debug")
let objects=try FileManager.default.contentsOfDirectory(at:build.appendingPathComponent("WorldRuntime.build"),includingPropertiesForKeys:nil).filter {$0.pathExtension == "o"}
guard !objects.isEmpty else { fatalError("Run the serial WorldRuntime package tests first") }
let bootstrap=try String(contentsOf:root.appendingPathComponent("apps/macos/Sources/GMGNRadio/App/LivingWorldBootstrap.swift"),encoding:.utf8)
let start=bootstrap.range(of:"struct MarbleLivingCabinCollisionWorld:")!.lowerBound
let end=bootstrap.range(of:"/// An effect is keyed",range:start..<bootstrap.endIndex)!.lowerBound
let collision=String(bootstrap[start..<end])
let harness=#"""
import Foundation
import WorldRuntime
\#(collision)
struct Config:Decodable { struct Framing:Decodable {let origin:[Float];let scale:Float};let framing:Framing }
@main struct Probe {
    @MainActor static func main() throws {
        let root=URL(fileURLWithPath:"apps/macos/Resources/Worlds/marble-living-cabin")
        let manifest=try JSONDecoder().decode(WorldManifest.self,from:Data(contentsOf:root.appendingPathComponent("world.json")))
        let config=try JSONDecoder().decode(Config.self,from:Data(contentsOf:root.appendingPathComponent("marble.json")))
        let origin=SIMD3(config.framing.origin[0],config.framing.origin[1],config.framing.origin[2])
        let triangles=try GLBColliderDecoder().decode(data:Data(contentsOf:root.appendingPathComponent("collider.glb")),transform:WorldMeshTransform(axisConversion:.flipYAndZ,origin:origin,uniformScale:config.framing.scale))
        let physics=MarbleLivingCabinCollisionWorld(environment:TriangleMeshCollisionWorld(triangles:triangles),props:CollisionVolumeWorld(volumes:manifest.collisionVolumes.filter {$0.id == "collision.jukebox"}))
        let context=try WorldAgentContext(manifest:manifest,startedAt:Date(timeIntervalSince1970:1000))
        _ = try context.installCollisionWorldAndReconcilePlacement(physics)
        try context.startActivity(id:"music.listen")
        var phases:Set<String>=[]
        var arrived=false
        for _ in 0..<600 {
            try context.tick(deltaTime:1.0/30)
            if let activity=context.snapshot.activeActivity {
                phases.insert(activity.phase.rawValue)
                if activity.id == "music.listen" && activity.phase == .loop { arrived=true;break }
            }
        }
        guard arrived else { print("FAIL: music.listen never reached loop; phases=\(phases)"); exit(1) }
        let p=context.snapshot.agentTransform.position
        let anchor=manifest.activities.first {$0.id == "music.listen"}!.transform.position
        let dx=p.x-anchor.x, dz=p.z-anchor.z
        guard sqrt(dx*dx+dz*dz)<0.25 else { fatalError("FAIL: arrived outside interaction radius") }
        print("PASS: actual WorldAgentContext music.listen approach -> enter -> loop",phases.sorted(),"position",p)
    }
}
"""#
let temp=FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-agent-probe-\(UUID())")
try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
defer {try? FileManager.default.removeItem(at:temp)}
let source=temp.appendingPathComponent("probe.swift")
let executable=temp.appendingPathComponent("probe")
try harness.write(to:source,atomically:true,encoding:.utf8)
func run(_ url:URL,_ arguments:[String]) throws -> Int32 {
    let p=Process();p.executableURL=url;p.arguments=arguments
    try p.run();p.waitUntilExit();return p.terminationStatus
}
let status=try run(URL(fileURLWithPath:"/usr/bin/swiftc"),["-parse-as-library","-I",build.appendingPathComponent("Modules").path,root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/WorldAgentContext.swift").path,source.path]+objects.map(\.path)+["-o",executable.path])
guard status == 0 else {exit(status)}
exit(try run(executable,[]))

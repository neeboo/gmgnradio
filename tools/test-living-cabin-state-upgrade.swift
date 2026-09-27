// Only temporary fixtures are read/written; no user state or app host access.
import Foundation
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let bootstrap = try String(contentsOfFile: "apps/macos/Sources/GMGNRadio/App/LivingWorldBootstrap.swift", encoding: .utf8)
guard bootstrap.contains("struct LivingCabinVersion12Persistence:") else {
    print("FAIL: living cabin 1.2 drops the 1.1 save instead of inheriting it")
    exit(1)
}
func declaration(_ signature: String) -> String {
    let start = bootstrap.range(of: signature)!.lowerBound
    let opening = bootstrap[start...].firstIndex(of: "{")!
    var depth = 0
    for index in bootstrap[opening...].indices {
        if bootstrap[index] == "{" { depth += 1 }
        if bootstrap[index] == "}" { depth -= 1 }
        if depth == 0 { return String(bootstrap[start...index]) }
    }
    fatalError("unterminated source")
}
let harness = #"""
import Foundation
import WorldRuntime
enum ProductIdentity { static let bundleIdentifier = "test.gmgn.fixture" }
struct Config: Decodable { struct Framing: Decodable { let origin: [Float]; let scale: Float }; let framing: Framing }
struct Physics: WorldCollisionQuerying {
    let environment: TriangleMeshCollisionWorld
    let props: CollisionVolumeWorld
    func groundHeight(at p: SIMD3<Float>) -> Float? { environment.groundHeight(at:p) }
    func canOccupy(_ c: WorldCapsule, at p: SIMD3<Float>) -> Bool { environment.canOccupy(c,at:p) && props.canOccupy(c,at:p) }
}
\#(declaration("struct LivingCabinVersion12Persistence:"))
enum LivingWorldBootstrap {
    \#(declaration("static func sanitizedPackageVersionDirectory("))
    \#(declaration("static func stateFileURL("))
    \#(declaration("static func statePersistence("))
}
func check(_ value: Bool, _ message: String) { if !value { print("FAIL:",message); exit(1) } }
@main struct Tests {
    @MainActor static func main() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-save-upgrade-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let manifestURL = URL(fileURLWithPath: "apps/macos/Resources/Worlds/marble-living-cabin/world.json")
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(WorldManifest.self, from: data)
        func url(_ version: String, package: String = "marble-living-cabin") throws -> URL {
            try LivingWorldBootstrap.stateFileURL(packageID: package, packageVersion: version, applicationSupportBase: base)
        }
        let oldURL = try url("1.1.0"), newURL = try url("1.2.0")
        let oldStore = AtomicJSONWorldStatePersistence(fileURL: oldURL)
        let newStore = AtomicJSONWorldStatePersistence(fileURL: newURL)
        var saved = WorldSimulation(manifest: manifest, startedAt: Date(timeIntervalSince1970: 5000)).state
        saved.revision = 73
        saved.weather = .rain
        saved.objectStates["kept.user.object"] = WorldObjectState(transform: manifest.spawn, metadata: ["memory":"keep me"])
        try oldStore.save(saved)
        let untouched = try Data(contentsOf: oldURL)
        let persistence = try LivingWorldBootstrap.statePersistence(manifest: manifest, applicationSupportBase: base)
        check(try persistence.load() == saved, "prior state inherited with revision, time, weather and objects")
        check(try Data(contentsOf: oldURL) == untouched, "old file bytes unchanged after load")
        var changed = saved; changed.revision = 74
        try persistence.save(changed)
        check(try newStore.load() == changed, "saves target only the new version")
        check(try Data(contentsOf: oldURL) == untouched, "old file retained after new save")
        check(try persistence.load() == changed, "existing new save wins")
        try Data("broken unused legacy".utf8).write(to: oldURL)
        check(try persistence.load() == changed, "valid new save never reads broken legacy")
        try oldStore.save(saved)
        try Data("broken".utf8).write(to: newURL)
        do { _ = try persistence.load(); check(false, "broken new save must throw") } catch is DecodingError { }
        try FileManager.default.removeItem(at: newURL)
        try Data("broken legacy".utf8).write(to: oldURL)
        do { _ = try persistence.load(); check(false, "broken legacy must throw") } catch is DecodingError { }
        try oldStore.save(saved)
        func variant(_ key: String, _ value: String) throws -> WorldManifest {
            var json = try JSONSerialization.jsonObject(with: data) as! [String:Any]
            json[key] = value
            return try JSONDecoder().decode(WorldManifest.self, from: JSONSerialization.data(withJSONObject: json))
        }
        for (key,value) in [("worldID","other-world"),("packageID","other-package"),("packageVersion","1.3.0")] {
            if key == "packageID" { try AtomicJSONWorldStatePersistence(fileURL:url("1.1.0",package:value)).save(saved) }
            let other = try LivingWorldBootstrap.statePersistence(manifest: variant(key,value), applicationSupportBase: base)
            check(try other.load() == nil, "no cross-world/package/version inheritance: \(key)")
        }
        var foreign = saved; foreign.worldID = "foreign"
        try oldStore.save(foreign)
        do {
            _ = try WorldAgentContext(manifest: manifest, persistence: persistence)
            check(false,"foreign legacy state must not restore")
        } catch WorldAgentContextError.restoredWorldMismatch { }
        saved.agentTransform = WorldTransform(position: WorldVector3(x: 0.8,y: -0.018,z: -2.6), rotation: saved.agentTransform.rotation, scale: saved.agentTransform.scale)
        try oldStore.save(saved)
        let context = try WorldAgentContext(manifest: manifest, persistence: persistence)
        check(context.snapshot.activities.contains { $0.id == "wish_machine.collect" }, "new machine comes from current manifest while old object state survives")
        let packageRoot = manifestURL.deletingLastPathComponent()
        let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: packageRoot.appendingPathComponent("marble.json")))
        let o = config.framing.origin
        let triangles = try GLBColliderDecoder().decode(data: Data(contentsOf: packageRoot.appendingPathComponent("collider.glb")), transform: WorldMeshTransform(axisConversion:.flipYAndZ,origin:SIMD3(o[0],o[1],o[2]),uniformScale:config.framing.scale))
        let physics = Physics(environment: TriangleMeshCollisionWorld(triangles:triangles),props:CollisionVolumeWorld(manifest:manifest))
        _ = try context.installCollisionWorldAndReconcilePlacement(physics)
        check(context.state.agentTransform.position != saved.agentTransform.position, "existing collision reconciliation moves a saved resident out of the new machine")
        let p = context.state.agentTransform.position
        check(physics.canOccupy(WorldCapsule(radius:0.2,height:1.8),at:SIMD3(p.x,p.y,p.z)), "relocated resident fits actual environment and new tray collision")
        check(context.state.objectStates == saved.objectStates, "reconciliation preserves user objects")
        check(try Data(contentsOf: oldURL) == JSONEncoderLegacy.encode(saved), "legacy still preserved after reconciliation")
        print("PASS: exact 1.1-to-1.2 inheritance, new-save priority, old-save preservation, isolation, corruption errors, collision reconciliation")
    }
}
enum JSONEncoderLegacy {
    static func encode(_ state: WorldState) throws -> Data {
        let encoder=JSONEncoder();encoder.dateEncodingStrategy = .millisecondsSince1970;encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(state)
    }
}
"""#
let build=root.appendingPathComponent("apps/macos/Packages/WorldRuntime/.build/arm64-apple-macosx/debug")
let objects=try FileManager.default.contentsOfDirectory(at:build.appendingPathComponent("WorldRuntime.build"),includingPropertiesForKeys:nil).filter {$0.pathExtension == "o"}
let temp=FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-upgrade-test-\(UUID())")
try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
defer {try? FileManager.default.removeItem(at:temp)}
let source=temp.appendingPathComponent("main.swift"), executable=temp.appendingPathComponent("check")
try harness.write(to:source,atomically:true,encoding:.utf8)
func run(_ path:String,_ args:[String]) throws -> Int32 {let p=Process();p.executableURL=URL(fileURLWithPath:path);p.arguments=args;try p.run();p.waitUntilExit();return p.terminationStatus}
let result=try run("/usr/bin/nice",["-n","15","/usr/bin/swiftc","-j1","-parse-as-library","-I",build.appendingPathComponent("Modules").path,"apps/macos/Sources/GMGNRadio/Agent/WorldAgentContext.swift",source.path]+objects.map(\.path)+["-o",executable.path])
guard result == 0 else {exit(result)}
exit(try run(executable.path,[]))

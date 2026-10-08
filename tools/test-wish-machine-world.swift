// Hostless geometry and scene contract checks; no app or rendering is started.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
// WorldRuntime 的模块搜索路径 + 目标文件**只有一处定义**：tools/world-runtime-harness-flags.sh。
// 不要在这里拼 `.build/...`：27 份各自拼写正是 SwiftPM 与 xcodebuild 两份模块并存的根因。
// `build` 由那唯一一份定义**推出来**（= Modules 的上一级），本文件不持有路径字面量。
func worldRuntimeHarnessFlags() -> [String] {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [FileManager.default.currentDirectoryPath + "/tools/world-runtime-harness-flags.sh"]
    process.standardOutput = pipe
    try? process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(separator: "\n").map(String.init)
}
let worldRuntimeFlags = worldRuntimeHarnessFlags()
let build = URL(fileURLWithPath: worldRuntimeFlags[1]).deletingLastPathComponent()
let objects = try FileManager.default.contentsOfDirectory(at: build.appendingPathComponent("WorldRuntime.build"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "o" }
let harness = #"""
import Foundation
import WorldRuntime
import AppKit
import CryptoKit
import SceneKit
struct Config: Decodable { struct Framing: Decodable { let origin: [Float]; let scale: Float }; let framing: Framing }
struct Physics: WorldCollisionQuerying {
    let environment: TriangleMeshCollisionWorld
    let props: CollisionVolumeWorld
    func groundHeight(at p: SIMD3<Float>) -> Float? { environment.groundHeight(at: p) }
    func canOccupy(_ c: WorldCapsule, at p: SIMD3<Float>) -> Bool { environment.canOccupy(c, at: p) && props.canOccupy(c, at: p) }
}
func check(_ value: Bool, _ message: String) { if !value { print("FAIL:", message); exit(1) } }
@main struct Check {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: "apps/macos/Resources/Worlds/marble-living-cabin")
        let manifest = try JSONDecoder().decode(WorldManifest.self, from: Data(contentsOf: root.appendingPathComponent("world.json")))
        let findings = WorldPackageValidator().validate(manifest, packageRoot: root)
        check(findings.isEmpty, "bundled package validation: \(findings)")
        let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: root.appendingPathComponent("marble.json")))
        let o = config.framing.origin
        let triangles = try GLBColliderDecoder().decode(data: Data(contentsOf: root.appendingPathComponent("collider.glb")), transform: WorldMeshTransform(axisConversion: .flipYAndZ, origin: SIMD3(o[0], o[1], o[2]), uniformScale: config.framing.scale))
        let environment = TriangleMeshCollisionWorld(triangles: triangles)
        let capsule = WorldCapsule(radius: 0.2, height: 1.8)
        for (x,z) in [(Float(0.8),Float(-2.6)), (0.8,-3.55), (0.35,-3.0), (1.25,-3.0), (0.35,-2.2), (1.25,-2.2)] {
            let y = environment.groundHeight(at: SIMD3(x,0.4,z)) ?? -999
            print("placement sample", x,y,z,"clear",environment.canOccupy(capsule, at: SIMD3(x,y,z)))
        }
        guard let anchor = manifest.activities.first(where: { $0.id == "wish_machine.collect" }) else {
            check(false, "wish_machine.collect is missing from the actual bundled world"); return
        }
        check(anchor.entry == .functionPoint(propID: "wish_machine.device"), "the machine's anchor is a prop function point, not baked geometry")
        check(anchor.propIDs == ["wish_machine.device"], "machine prop contract")
        guard let resource = manifest.resources.first(where: { $0.id == "wish_machine.device" }) else {
            check(false, "machine resource exists"); return
        }
        let resourceBytes = try Data(contentsOf: root.appendingPathComponent(resource.path))
        check(SHA256.hash(data: resourceBytes).map { String(format: "%02x",$0) }.joined() == resource.sha256, "machine resource checksum")
        let authored = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "authoring/worlds/marble-living-cabin/layout.json"))) as! [String:Any]
        let configJSON = try JSONSerialization.jsonObject(with: resourceBytes) as! [String:Any]
        let authoredWish = authored["wishMachine"] as! [String:Any]
        for key in ["position","size","functionPoints"] {
            let a = try JSONSerialization.data(withJSONObject: authoredWish[key]!, options: [.sortedKeys])
            let b = try JSONSerialization.data(withJSONObject: configJSON[key]!, options: [.sortedKeys])
            check(a == b, "authoring and bundled machine agree: \(key)")
        }
        // 声明是几何的**唯一**来源：锚点由它 × 摆放派生。
        let declaration = try JSONDecoder().decode(WorldProceduralPropDeclaration.self, from: resourceBytes)
        // 与 App 同口径：**每一件** `prop.procedural` 都是声明来源（音箱的活动也一样）。
        let sources: [WorldPropFunctionSource] = try manifest.resources
            .filter { $0.kind == "prop.procedural" }
            .sorted { $0.id < $1.id }
            .compactMap { resource in
                try JSONDecoder().decode(
                    WorldProceduralPropDeclaration.self,
                    from: Data(contentsOf: root.appendingPathComponent(resource.path))
                ).functionSource
            }
        let registry = try WorldPropAnchorRegistry.derive(sources: sources, objectStates: [:])
        guard let pickupAnchor = registry.entry(activityID: "wish_machine.collect") else {
            check(false, "the machine declaration must register a pickup entry"); return
        }
        let physics = Physics(environment: environment, props: CollisionVolumeWorld(volumes: manifest.collisionVolumes))
        let a = pickupAnchor.position
        check(physics.canOccupy(capsule, at: SIMD3(a.x,a.y,a.z)), "pickup point is occupiable")
        WishMachineScene.install(declaration)
        let context = try WorldAgentContext(manifest: manifest, startedAt: Date(timeIntervalSince1970: 1000),
                                           propFunctionSources: sources)
        _ = try context.installCollisionWorldAndReconcilePlacement(physics)
        try context.startActivity(id: "wish_machine.collect")
        for _ in 0..<900 {
            try context.tick(deltaTime: 1.0/30)
            if context.snapshot.activeActivity?.phase == .enter { break }
        }
        check(context.snapshot.activeActivity?.phase == .enter, "navigation reaches the authored pickup enter operation")
        // Explicit native completion simulation; the authored pickup clip has
        // no wall-time duration and this hostless harness does not play avatars.
        try context.completeActivityPlayback(requestID: context.currentActivityRequestID!, phase: .enter)
        check(context.snapshot.activeActivity?.id == "wish_machine.collect" && context.snapshot.activeActivity?.phase == .loop, "resident reaches pickup loop against actual collider")
        let p = context.snapshot.agentTransform.position
        let target = pickupAnchor.position
        check(hypot(p.x-target.x,p.z-target.z) <= 0.25, "arrival within collection distance")
        check(!physics.canOccupy(capsule, at: SIMD3(0.8,-0.018,-2.6)), "machine blocks resident")
        check(WishMachineScene.shouldDisplay(worldID: manifest.worldID, drawsWorld: true), "machine visible in cabin")
        check(!WishMachineScene.shouldDisplay(worldID: manifest.worldID, drawsWorld: false), "machine hidden from Live Cam")
        check(!WishMachineScene.shouldDisplay(worldID: "other-world", drawsWorld: true), "machine hidden from other worlds")
        let propsRoot = SCNNode()
        propsRoot.name = "marble-interactive-props"
        let node: SCNNode? = WishMachineScene.reconcileMachineNode(
            in: propsRoot,
            worldID: manifest.worldID,
            drawsWorld: true
        )
        check(node != nil, "full-stage cabin creates the machine whenever the props root exists")
        guard let node else { return }
        check(node.name == "wish_machine.device", "scene and manifest share machine identity")
        check(node.childNode(withName: "wish_machine.outlet", recursively: true) != nil, "physical outlet exists")
        guard let outlet = WishMachineScene.outletPosition else {
            check(false, "the installed declaration must yield an outlet function point"); return
        }
        check(node.childNode(withName: "wish_machine.output_anchor", recursively: true)?.simdWorldPosition == outlet, "item bottom floats 25 cm above tray")
        check(node.simdPosition == WishMachineScene.position, "machine placed in metre coordinates")
        check(node.childNode(withName: "wish_machine.header", recursively: true) == nil, "tray has no lid hiding generated item")
        check(node.childNode(withName: "wish_machine.back", recursively: true) == nil, "tray has no back wall")
        check(declaration.size?.y == 0.12 && WishMachineScene.size.y == declaration.size?.y, "low tray height follows the bundled declaration")
        let visualBounds = node.boundingBox
        check(Float(visualBounds.max.x - visualBounds.min.x) >= WishMachineScene.size.x * 1.25, "machine body is enlarged without changing formal collision size")
        node.removeFromParentNode()
        check(propsRoot.childNode(withName: WishMachineScene.propID, recursively: false) == nil, "test removes the in-process machine node")
        let restored = WishMachineScene.reconcileMachineNode(
            in: propsRoot,
            worldID: manifest.worldID,
            drawsWorld: true
        )
        check(restored != nil && restored?.parent === propsRoot, "next render reconciliation restores a missing machine")
        let sameNode = WishMachineScene.reconcileMachineNode(
            in: propsRoot,
            worldID: manifest.worldID,
            drawsWorld: true
        )
        check(sameNode === restored && propsRoot.childNodes.filter { $0.name == WishMachineScene.propID }.count == 1, "reconciliation stays idempotent")
        check(WishMachineScene.reconcileMachineNode(in: propsRoot, worldID: "other-world", drawsWorld: true) == nil, "unsupported world removes or hides the machine")
        check(propsRoot.childNode(withName: WishMachineScene.propID, recursively: false)?.isHidden != false, "unsupported world cannot leave a visible machine")
        let reentered = WishMachineScene.reconcileMachineNode(
            in: propsRoot,
            worldID: manifest.worldID,
            drawsWorld: true
        )
        check(reentered != nil && reentered?.isHidden == false, "returning to the cabin restores the machine")
        for (state,color) in [(WishMachineScene.State.idle,NSColor.systemCyan), (.generating,.systemOrange), (.ready,.systemGreen), (.failed,.systemRed)] {
            WishMachineScene.update(node, state: state)
            check(node.childNode(withName: "wish_machine.status", recursively: true)?.geometry?.firstMaterial?.emission.contents as? NSColor == color, "status light accepts task state")
        }
        let sceneSource = try String(contentsOfFile: "apps/macos/Sources/GMGNRadio/VisualEngine/Metal/MarbleSpatialView.swift", encoding: .utf8)
        check(sceneSource.contains("WishMachineScene.reconcileMachineNode"), "Marble renderer reconciles machine presence every frame")
        check(sceneSource.contains("&& marbleWishMachineNode?.parent != nil"), "debug ready requires a machine attached to the props scene")
        try context.stopActivity()
        try context.startActivity(id: "music.listen")
        for _ in 0..<900 {
            try context.tick(deltaTime: 1.0/30)
            if context.snapshot.activeActivity?.phase == .enter { break }
        }
        check(context.snapshot.activeActivity?.phase == .enter, "navigation reaches the authored jukebox enter operation")
        try context.completeActivityPlayback(requestID: context.currentActivityRequestID!, phase: .enter)
        check(context.snapshot.activeActivity?.id == "music.listen" && context.snapshot.activeActivity?.phase == .loop, "jukebox remains reachable from machine")
        print("PASS: wish machine route and activity reach actual pickup point", p)
    }
}
"""#
let temp = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-wish-world-\(UUID())")
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }
let source = temp.appendingPathComponent("main.swift")
let executable = temp.appendingPathComponent("check")
try harness.write(to: source, atomically: true, encoding: .utf8)
func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
    let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
    try process.run(); process.waitUntilExit(); return process.terminationStatus
}
let authorityInputs = ["RustActivityCatalogClient", "RustWorldActivityClient", "WorldAuthorityClient", "AuthorityWorldStatePersistence", "TaskdHTTPTransport", "RetryBackoff"]
    .map { "apps/macos/Sources/GMGNRadio/Presence/" + $0 + ".swift" }
let status = try run("/usr/bin/nice", ["-n","15","/usr/bin/swiftc","-j1","-parse-as-library","-I",build.appendingPathComponent("Modules").path,"apps/macos/Sources/GMGNRadio/Agent/WorldAgentContext.swift","apps/macos/Sources/GMGNRadio/Presence/WishMachineScene.swift",source.path] + authorityInputs + objects.map(\.path) + ["-o",executable.path])
guard status == 0 else { exit(status) }
exit(try run(executable.path, []))

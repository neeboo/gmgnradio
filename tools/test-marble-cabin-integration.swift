// Headless contract tests: production helpers, no application / GPU / network.
import Foundation
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceRoot = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
let source = try String(contentsOf: sourceRoot.appendingPathComponent("App/LivingWorldBootstrap.swift"), encoding: .utf8)
func declaration(_ signature: String, in text: String) -> String {
    guard let start = text.range(of: signature)?.lowerBound,
          let opening = text[start...].firstIndex(of: "{") else {
        print("FAIL: missing production behavior \(signature)"); exit(1)
    }
    var depth = 0
    for index in text[opening...].indices {
        if text[index] == "{" { depth += 1 }
        if text[index] == "}" { depth -= 1 }
        if depth == 0 { return String(text[start...index]) }
    }
    fatalError("Unbalanced declaration")
}
let gate = declaration("struct LivingCabinJukeboxGate", in: source)
let resolver = declaration("static func bundledManifestURL(", in: source)
let document = declaration("struct MarbleLivingCabinDocument:", in: source)
let loader = declaration("static func loadMarbleCabin(", in: source)
let collision = declaration("struct MarbleLivingCabinCollisionWorld:", in: source)
let librarySource = try String(contentsOf: sourceRoot.appendingPathComponent("VisualEngine/MarbleWorldLibrary.swift"), encoding: .utf8)
let adoption = declaration("func adoptCachedWorld(", in: librarySource)
let cachedDownload = declaration("private func cacheSelectedWorld()", in: librarySource)
let colliderLookup = declaration("func localCollider(", in: librarySource)
let worldSource = try String(contentsOf: sourceRoot.appendingPathComponent("VisualEngine/MarbleWorld.swift"), encoding: .utf8)
let worldDeclarations = ["enum MarbleSplatQuality:", "struct MarbleSplatAsset:", "struct MarbleWorldSemantics:", "enum MarbleColliderSourceCoordinates:", "struct MarbleWorld:", "enum MarblePublicWorldCatalog"].map { declaration($0, in: worldSource) }.joined(separator: "\n")
let harness = #"""
import Foundation
import os
enum WorldMeshAxisConversion { case identity, flipYAndZ }
\#(worldDeclarations)
func testWorld(_ id: String) -> MarbleWorld {
    MarbleWorld(id: id, name: id, splatFallbacks: [MarbleSplatAsset(quality: .fiveHundredK, url: URL(fileURLWithPath: "/tmp/scene.spz"))])
}
struct WorldVector { var x: Float = 0; var y: Float = 0; var z: Float = 0 }
struct Quaternion { var x: Float = 0; var y: Float = 0; var z: Float = 0; var w: Float = 1 }
struct Spawn { var position = WorldVector(); var rotation = Quaternion() }
struct Manifest { let worldID: String; var spawn = Spawn(); var displayName: String { "Test Cabin" } }
struct BundledLivingWorldPackage { let manifest: Manifest; let packageRoot: URL }
struct SpatialCameraState { let position: SIMD3<Float>; let yaw: Float; let pitch: Float }
struct StageAvatarPlacement { let position: SIMD3<Float>; let scale: Float; let yaw: Float }
struct MarbleSceneFraming { let groundedOrigin: SIMD3<Float>; let uniformScale: Float; let minimum: SIMD3<Float>; let maximum: SIMD3<Float> }
struct MarbleLivingCabinPresentation {
    let worldID: String; let camera: SpatialCameraState; let avatarPlacement: StageAvatarPlacement
    let jukeboxPosition: SIMD3<Float>; let jukeboxYaw: Float; let sceneFraming: MarbleSceneFraming
}
struct BundledMarbleLivingCabin { let world: MarbleWorld; let presentation: MarbleLivingCabinPresentation; let splatURL: URL; let colliderURL: URL }
enum LivingWorldBootstrapError: Error { case invalidMarbleCabin(String) }
struct WorldCapsule {}
protocol WorldCollisionQuerying: Sendable {
    func canOccupy(_ capsule: WorldCapsule, at position: SIMD3<Float>) -> Bool
    func groundHeight(at position: SIMD3<Float>) -> Float?
}
struct CollisionVolumeWorld: WorldCollisionQuerying {
    func canOccupy(_ capsule: WorldCapsule, at position: SIMD3<Float>) -> Bool { position.x != 1 }
    func groundHeight(at position: SIMD3<Float>) -> Float? { 1.23 }
}
struct Floor: WorldCollisionQuerying {
    func canOccupy(_ capsule: WorldCapsule, at position: SIMD3<Float>) -> Bool { position.x != -1 }
    func groundHeight(at position: SIMD3<Float>) -> Float? { 0 }
}
\#(collision)
enum SpatialScenePreset { case djHouse; static func inferred(worldID: String, name: String) -> Self { .djHouse } }
class Stage {
    var selectedWorldID: String?
    func selectScene(_ scene: SpatialScenePreset) {}
    func selectWorld(id: String?) { selectedWorldID = id }
}
class Cache {
    var beforeReturn: (() -> Void)?
    func localSplat(for world: MarbleWorld, asset: MarbleSplatAsset) async throws -> URL { beforeReturn?(); return asset.url }
    func localCollider(for world: MarbleWorld) async throws -> URL? { nil }
}
class Library {
    static let log = Logger(subsystem: "test.cabin", category: "library")
    var worlds: [MarbleWorld] = []
    var selectionRevision: UInt64 = 0
    var prepareTask: Task<URL?, Never>?
    var selectedLocalWorldID: String?
    var selectedWorld: MarbleWorld?
    var localSplatURL: URL?
    var bundledColliders: [String: URL] = [:]
    var errorMessage: String?
    var isPreparing = false
    var onLocalSplatChange: ((URL) -> Void)?
    let spatialStage = Stage()
    let cache = Cache()
    \#(adoption)
    \#(cachedDownload)
    \#(colliderLookup)
    func download() async -> URL? { await cacheSelectedWorld() }
}
\#(document)
enum Bootstrap {
    static let canaryDirectoryName = "living-pod-v1"
    static let marbleCabinDirectoryName = "marble-living-cabin"
    \#(resolver)
    \#(loader)
}
\#(gate)
func check(_ value: Bool, _ message: String) {
    if !value { print("FAIL: \(message)"); exit(1) }
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let legacy = root.appendingPathComponent("Worlds/living-pod-v1")
try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
try Data("{}".utf8).write(to: legacy.appendingPathComponent("world.json"))
check(Bootstrap.bundledManifestURL(resourceRoot: root)?.path == legacy.appendingPathComponent("world.json").path, "legacy remains when no adopted cabin")
let cabin = root.appendingPathComponent("Worlds/marble-living-cabin")
try FileManager.default.createDirectory(at: cabin, withIntermediateDirectories: true)
check(Bootstrap.bundledManifestURL(resourceRoot: root)?.path == cabin.appendingPathComponent("world.json").path, "incomplete adopted package must fail on load, not silently use geometry")
try Data("{}".utf8).write(to: cabin.appendingPathComponent("world.json"))
check(Bootstrap.bundledManifestURL(resourceRoot: root)?.path == cabin.appendingPathComponent("world.json").path, "adopted cabin is preferred")
var gate = LivingCabinJukeboxGate()
let first = Date(timeIntervalSince1970: 42)
check(!gate.consume(worldID: "w", activityID: "music.listen", startedAt: first, phase: "approach"), "approach cannot start music")
check(gate.consume(worldID: "w", activityID: "music.listen", startedAt: first, phase: "enter"), "arrival starts once")
check(!gate.consume(worldID: "w", activityID: "music.listen", startedAt: first, phase: "loop"), "loop cannot replay")
check(!gate.consume(worldID: "w", activityID: "music.listen", startedAt: first, phase: "exit"), "cancel cannot start")
check(!gate.consume(worldID: "w", activityID: "coffee.brew", startedAt: first, phase: "enter"), "other activity cannot start")
check(gate.consume(worldID: "w", activityID: "music.listen", startedAt: first.addingTimeInterval(1), phase: "loop"), "new activity can play again")
let valid = """
{"world":{"id":"w"},"framing":{"origin":[0,-1,0],"scale":2,"minimum":[-4,-1,-4],"maximum":[4,3,4]},"camera":{"position":[0,2,4],"yaw":0,"pitch":-0.2},"jukebox":{"position":[2,0,-1],"yaw":1}}
"""
let document = try JSONDecoder().decode(MarbleLivingCabinDocument.self, from: Data(valid.utf8))
check(document.framing.scale == 2 && document.camera.position.value.y == 2, "explicit room scale and camera survive decoding")
try Data(valid.utf8).write(to: cabin.appendingPathComponent("marble.json"))
let package = BundledLivingWorldPackage(manifest: Manifest(worldID: "w"), packageRoot: cabin)
do {
    _ = try Bootstrap.loadMarbleCabin(package: package)
    check(false, "missing SPZ and GLB must fail instead of returning legacy room")
} catch { }
try Data([1]).write(to: cabin.appendingPathComponent("scene-500k.spz"))
try Data([2]).write(to: cabin.appendingPathComponent("collider.glb"))
let adopted = try Bootstrap.loadMarbleCabin(package: package)!
check(adopted.world.id == "w" && adopted.presentation.avatarPlacement.scale == 1, "same world ID and meter-scale avatar")
check(document.world.colliderSourceCoordinates == .glTF, "ordinary API decoder keeps existing behavior")
check(adopted.world.colliderSourceCoordinates == .worldLabsOpenCV, "adopted cabin loader explicitly aligns generated GLB with SPZ")
let adoptedLibrary = Library()
adoptedLibrary.adoptCachedWorld(adopted.world, splatURL: adopted.splatURL, colliderURL: adopted.colliderURL)
let resolvedCollider = try await adoptedLibrary.localCollider(for: adopted.world.id)
check(resolvedCollider?.1 == .worldLabsOpenCV, "actual loader to library collider lookup keeps converted coordinates")
if case .flipYAndZ = resolvedCollider?.1.axisConversion { } else { check(false, "runtime collider must flip the actual axes") }
do {
    _ = try Bootstrap.loadMarbleCabin(package: BundledLivingWorldPackage(manifest: Manifest(worldID: "wrong"), packageRoot: cabin))
    check(false, "mismatched world ID must fail")
} catch { }
check(try Bootstrap.loadMarbleCabin(package: BundledLivingWorldPackage(manifest: Manifest(worldID: "legacy"), packageRoot: legacy)) == nil, "legacy package remains supported")
for broken in [valid.replacingOccurrences(of: "[0,2,4]", with: "[0,2]"), valid.replacingOccurrences(of: "\"scale\":2", with: "\"scale\":0")] {
    do {
        _ = try JSONDecoder().decode(MarbleLivingCabinDocument.self, from: Data(broken.utf8))
        check(false, "invalid authored dimensions must be rejected")
    } catch { }
}
let library = Library()
let cabinURL = URL(fileURLWithPath: "/tmp/adopted-cabin.spz")
library.selectedWorld = testWorld("old")
var callbacks = 0
library.onLocalSplatChange = { _ in callbacks += 1 }
library.cache.beforeReturn = {
    library.adoptCachedWorld(testWorld("cabin"), splatURL: cabinURL,
                             colliderURL: URL(fileURLWithPath: "/tmp/collider.glb"))
}
_ = await library.download()
check(library.localSplatURL == cabinURL, "stale remote download cannot replace adopted SPZ")
check(library.selectedWorld?.id == "cabin" && library.spatialStage.selectedWorldID == "cabin", "logical and visual selection agree")
check(library.worlds.contains { $0.id == "cabin" }, "adopted world available for collider lookup")
check(callbacks == 1, "only adopted scene reaches renderer")
let physics = MarbleLivingCabinCollisionWorld(environment: Floor(), props: CollisionVolumeWorld())
check(physics.canOccupy(WorldCapsule(), at: .zero), "open floor stays walkable")
check(!physics.canOccupy(WorldCapsule(), at: SIMD3(1,0,0)), "independent prop remains blocking after environment collider adoption")
check(!physics.canOccupy(WorldCapsule(), at: SIMD3(-1,0,0)), "environment remains blocking")
check(physics.groundHeight(at: SIMD3(1,0,0)) == 0, "jukebox top is not a walkable floor")
print("PASS: preferred package selection, incomplete-package failure boundary, jukebox arrival and exactly-once effect")
"""#
let temp = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-cabin-test-\(UUID())")
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }
let program = temp.appendingPathComponent("main.swift")
try harness.write(to: program, atomically: true, encoding: .utf8)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
process.arguments = [program.path]
try process.run(); process.waitUntilExit(); exit(process.terminationStatus)

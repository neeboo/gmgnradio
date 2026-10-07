// Production Host preparation closure + real device CAS bridge + real context.
// Persistence/transport are isolated memory owners; no application or live writes.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let hostSource = try String(contentsOf: root.appendingPathComponent("apps/macos/UnityHost/UnityMediaHost.swift"), encoding: .utf8)
let compositionSource = try String(contentsOf: root.appendingPathComponent("apps/macos/UnityHost/UnityWorldSessionComposition.swift"), encoding: .utf8)
func slice(_ source: String, _ start: String, _ end: String) -> String {
    guard let lower = source.range(of: start), let upper = source.range(of: end, range: lower.upperBound..<source.endIndex) else { fatalError("Missing production source slice") }
    return String(source[lower.lowerBound..<upper.lowerBound])
}
let preparation = slice(hostSource, "        composition.prepareJukebox = {", "        let musicActions = makeResidentMusicActions()")
let perform = slice(compositionSource, "    var prepareJukebox:", "    private func motionProjection()")
let adoption = slice(compositionSource, "    func adoptAuthorityState(_ state:", "    static func authoritativeClaimEvidence(")
let harness = #"""
import Foundation
import WorldRuntime

enum WorldAuthorityError: Error { case daemon(String), unavailable(String), invalidResponse, stateEncodeFailed, staleProjection(local: UInt64, authority: UInt64), noAuthorityRecord }
struct WorldAuthorityEndpoint { let endpointFile = "unused", helperPath = "unused"; init(applicationSupportBase: URL) {} }
struct TaskdHTTPAuthorityClient {
    static let maximumFrame = 12 * 1024 * 1024
    init(endpointFile: String, helperPath: String, allowsLaunching: Bool, timeout: Double) {}
    func call(method: String, params: [String: Any]) throws -> [String: Any] { fatalError("Use injected transport") }
}
struct UnityWorldBridge { init(root: URL) {} ; func preparePlacementGeometry(_ value: [String: Any]) throws -> [String: Any] { value } }
struct WorldAuthorityClient {
    static func decodeState(_ value: [String: Any]) throws -> WorldState {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(WorldState.self, from: JSONSerialization.data(withJSONObject: value))
    }
}
struct Floor: WorldCollisionQuerying {
    func groundHeight(at position: SIMD3<Float>) -> Float? { 0 }
    func canOccupy(_ capsule: WorldCapsule, at position: SIMD3<Float>) -> Bool { true }
}
final class MemoryAuthority: WorldStatePersisting, @unchecked Sendable {
    let lock = NSLock()
    private var stored: WorldState
    private var recordRevision: UInt64 = 1
    private var ownerRevision: UInt64 = 1
    private(set) var ownerLoads = 0, reads = 0, commits = 0
    var failCommit = false
    init(_ state: WorldState) { stored = state }
    func load() throws -> WorldState? {
        lock.lock(); defer { lock.unlock() }; ownerLoads += 1; ownerRevision = recordRevision; return stored
    }
    func save(_ state: WorldState) throws {
        lock.lock(); defer { lock.unlock() }
        guard ownerRevision == recordRevision else { throw WorldAuthorityError.daemon("revision_conflict") }
        stored = state; recordRevision += 1; ownerRevision = recordRevision
    }
    func call(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        switch method {
        case "world_snapshot":
            reads += 1
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
            return ["record": ["recordRevision": recordRevision,
                "state": try JSONSerialization.jsonObject(with: encoder.encode(stored))]]
        case "world_commit":
            if failCommit { throw WorldAuthorityError.daemon("revision_conflict") }
            guard (params["expectedRevision"] as? NSNumber)?.uint64Value == recordRevision else { throw WorldAuthorityError.daemon("revision_conflict") }
            let value = (params["ops"] as! [[String: Any]])[0]["state"] as! [String: Any]
            stored = try WorldAuthorityClient.decodeState(value); recordRevision += 1; commits += 1
            return ["revision": recordRevision]
        default: fatalError("Unexpected transport method")
        }
    }
}
@MainActor final class UnityWorldSessionComposition {
    enum CompositionError: Error { case sessionClosed, jukeboxNotPlaced }
    let context: WorldAgentContext
    let activity: UnityActivityBridge
    var closed = false
    init(_ context: WorldAgentContext) {
        self.context = context; activity = UnityActivityBridge(context: context)
        context.waitsForRenderedActivityCompletion = { true }
        activity.motionProjection = {
            switch context.snapshot.activeActivity?.phase {
            case .enter: (true, ["id": "operate", "loop": false])
            case .loop: (true, ["id": "listen", "loop": true])
            default: (false, nil)
            }
        }
        activity.contactProjection = { [0, 1, 0] }; activity.contactObjectProjection = { "prop.jukebox" }
        activity.onFiniteMotionCompleted = { request, phase in
            if let phase = LifeActivityPhase(rawValue: phase) { try! context.completeActivityPlayback(requestID: request, phase: phase) }
        }
    }
    func scheduleNotifications() {}
    __PERFORM__
    __ADOPTION__
}
@MainActor final class Host {
    var closed = false
    let worldSession: UnityWorldSessionComposition
    let devicePlacement: UnityDevicePlacementBridge
    init(_ world: UnityWorldSessionComposition, _ placement: UnityDevicePlacementBridge) {
        worldSession = world; devicePlacement = placement
        let composition = world
        __PREPARATION__
    }
}
final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); value += 1; lock.unlock() }
}
@MainActor func require(_ value: Bool, _ message: String) {
    if !value { print("FAIL: " + message); exit(1) }
}
@MainActor func make(legacy: Bool = false) throws -> (UnityWorldSessionComposition, UnityDevicePlacementBridge, MemoryAuthority, Host) {
    let url = URL(fileURLWithPath: "apps/macos/Resources/Worlds/marble-living-cabin/world.json")
    let manifest = try JSONDecoder().decode(WorldManifest.self, from: Data(contentsOf: url))
    let data = try Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent("jukebox.json"))
    let jukebox = try JSONDecoder().decode(WorldProceduralPropDeclaration.self, from: data)
    let template = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let metadata = String(data: try JSONSerialization.data(withJSONObject: template, options: .sortedKeys), encoding: .utf8)!
    var state = WorldSimulation(manifest: manifest, startedAt: Date()).state
    state.objectStates[jukebox.objectID] = WorldObjectState(transform: WorldTransform(position: jukebox.seedPosition, rotation: .identity, scale: WorldVector3(x: 1, y: 1, z: 1)), metadata: legacy ? ["retain": "yes"] : ["gmgn.builtin-device.v1": metadata, "retain": "yes"])
    let memory = MemoryAuthority(state)
    let context = try WorldAgentContext(manifest: manifest, persistence: memory, propFunctionSources: [jukebox.functionSource!], initialCollisionWorld: Floor())
    let world = UnityWorldSessionComposition(context)
    let placement = UnityDevicePlacementBridge(worldID: manifest.worldID, templates: [template], call: memory.call)
    let host = Host(world, placement)
    return (world, placement, memory, host)
}
@MainActor func enter(_ context: WorldAgentContext) throws {
    for _ in 0..<300 where context.snapshot.activeActivity?.phase == .approach { try context.tick(deltaTime: 0.2) }
    require(context.snapshot.activeActivity?.phase == .enter, "Real context enters authored finite phase")
}
@MainActor func receipt(_ world: UnityWorldSessionComposition, completed: Bool = false, ready: Bool = true) -> [String: Any] {
    let position = world.context.state.agentTransform.position, phase = world.context.snapshot.activeActivity!.phase
    return ["worldID": world.context.manifest.worldID, "requestID": world.context.currentActivityRequestID!, "phase": phase.rawValue,
        "position": [Double(position.x), Double(position.y), Double(position.z)], "motionID": phase == .enter ? "operate" : "listen",
        "motionReady": ready, "motionPlaying": !completed, "motionCompleted": completed,
        "contactReady": true, "contactPosition": [0.0, 1.0, 0.0]]
}
@main struct Checks {
    @MainActor static func main() async throws {
        let (idle, _, idleMemory, idleHost) = try make()
        for _ in 0..<20 { try idle.context.tick(deltaTime: 0.1) }
        let volatile = idle.context.state, idleLoads = idleMemory.ownerLoads
        try await idle.prepareJukebox?()
        let idlePreserved = idle.context.state == volatile && idleMemory.ownerLoads == idleLoads
        print("OBSERVED idle no-op: preserved=\(idlePreserved) beforeRevision=\(volatile.revision) afterRevision=\(idle.context.state.revision) reads=\(idleMemory.reads) commits=\(idleMemory.commits)")
        require(idleMemory.reads == 1 && idleMemory.commits == 0, "No-op performs one official read and zero CAS writes")
        _ = idleHost

        let (active, _, activeMemory, activeHost) = try make()
        try active.context.startActivity(id: "music.listen"); try enter(active.context)
        require(active.activity.acknowledgeProjection(receipt(active)), "Existing current ENTER/contact is actually acknowledged")
        let activeRequest = active.context.currentActivityRequestID!, activeLoads = activeMemory.ownerLoads
        try active.context.tick(deltaTime: 0.5)
        let activeBefore = active.context.state
        var activeError: Error?
        do { try await active.prepareJukebox?() } catch { activeError = error }
        let activePreserved = activeError == nil && active.context.state == activeBefore && active.context.currentActivityRequestID == activeRequest
            && active.activity.snapshot()["contactConfirmedObjectID"] as? String == "prop.jukebox" && activeMemory.ownerLoads == activeLoads
        print("OBSERVED active no-op: preserved=\(activePreserved) error=\(activeError.map { String(describing: $0) } ?? "none") elapsed=\(activeBefore.activeActivity!.elapsedActiveTime) reads=\(activeMemory.reads) commits=\(activeMemory.commits)")
        _ = activeHost
        require(idlePreserved && activePreserved, "No-op must preserve high volatile revision and same-lease active elapsed phase; never force old adoption")
        print("PASS: both real no-op failure paths fixed, Context adoption guard unchanged")

        let (upgraded, placement, upgradeMemory, upgradeHost) = try make(legacy: true)
        let genericCallbacks = Counter(); placement.onCommitted = { _ in genericCallbacks.increment() }
        let upgradeLoads = upgradeMemory.ownerLoads
        try await upgraded.prepareJukebox?()
        require(upgradeMemory.commits == 1 && upgradeMemory.reads == 2 && upgradeMemory.ownerLoads == upgradeLoads + 1, "Real external CAS upgrade/readback advances owner with exactly one load")
        require(genericCallbacks.count == 0, "Explicit preparation does not trigger a second generic placement adoption")
        require(upgraded.context.state.objectStates["prop.jukebox"]!.metadata["retain"] == "yes", "Upgrade preserves existing object metadata")
        try upgraded.context.startActivity(id: "music.listen"); try enter(upgraded.context)
        let newLease = upgraded.context.currentActivityRequestID!
        let upgradedState = upgraded.context.state
        try await upgraded.prepareJukebox?()
        require(upgradeMemory.commits == 1 && upgradeMemory.ownerLoads == upgradeLoads + 1 && upgraded.context.state == upgradedState && upgraded.context.currentActivityRequestID == newLease, "Upgraded device becomes no-op without dropping active state")
        _ = upgradeHost
        print("PASS: actual upgrade still commits/readbacks/loads owner exactly once; subsequent no-op preserves it")

        let (failed, failedPlacement, failedMemory, failedHost) = try make(legacy: true)
        failedMemory.failCommit = true
        let failedBefore = failed.context.state; var failPlays = 0
        do { try await failed.performJukebox { failPlays += 1 }; require(false, "Failed upgrade must throw") } catch WorldAuthorityError.daemon("revision_conflict") {}
        require(failPlays == 0 && failed.context.state == failedBefore && failed.context.currentActivityRequestID == nil && failedMemory.commits == 0, "Upgrade failure does not start music or mutate current resident")
        _ = failedPlacement; _ = failedHost

        let (music, _, musicMemory, musicHost) = try make()
        for _ in 0..<20 { try music.context.tick(deltaTime: 0.1) }
        var plays = 0
        let work = Task { try await music.performJukebox { plays += 1 } }
        try await Task.sleep(for: .milliseconds(40)); try enter(music.context)
        require(plays == 0 && musicMemory.commits == 0, "New music operation waits, with no unnecessary function upgrade")
        require(music.activity.acknowledgeProjection(receipt(music)), "Fresh ENTER contact accepted")
        require(music.activity.acknowledgeProjection(receipt(music, completed: true)), "Fresh finite completion advances to LOOP")
        try await Task.sleep(for: .milliseconds(40)); require(plays == 0, "Music waits for real LOOP readiness")
        require(!music.activity.acknowledgeProjection(receipt(music, ready: false)), "Unready LOOP rejected")
        require(music.activity.acknowledgeProjection(receipt(music)), "Ready LOOP accepted")
        try await work.value; require(plays == 1, "Exact-once actual music closure after fresh request/contact/LOOP")
        _ = musicHost

        let (successor, _, _, successorHost) = try make()
        let cancelWork = Task { try await successor.performJukebox { require(false, "Cancelled old request may not play") } }
        try await Task.sleep(for: .milliseconds(40))
        try successor.context.startActivity(id: "performance.backflip")
        let successorRequest = successor.context.currentActivityRequestID!
        do { try await cancelWork.value; require(false, "Superseded request must cancel") } catch is CancellationError {}
        require(successor.context.currentActivityRequestID == successorRequest, "Failure cleanup never stops successor request")
        _ = successorHost
        print("PASS: failed upgrade and superseded-request cleanup; fresh contact/finite/ready LOOP permits exactly one music command")
    }
}
"""#
let temp = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-jukebox-preparation-\(UUID())")
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }
let program = temp.appendingPathComponent("Checks.swift")
try harness.replacingOccurrences(of: "__PERFORM__", with: perform).replacingOccurrences(of: "__ADOPTION__", with: adoption)
    .replacingOccurrences(of: "__PREPARATION__", with: preparation).write(to: program, atomically: true, encoding: .utf8)
let flagsProcess = Process(), flagsPipe = Pipe(); flagsProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
flagsProcess.arguments = [root.appendingPathComponent("tools/world-runtime-harness-flags.sh").path]; flagsProcess.standardOutput = flagsPipe
try flagsProcess.run(); flagsProcess.waitUntilExit(); guard flagsProcess.terminationStatus == 0 else { exit(flagsProcess.terminationStatus) }
let flags = String(decoding: flagsPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").map(String.init)
func run(_ binary: String, _ arguments: [String]) throws -> Int32 {
    let process = Process(); process.executableURL = URL(fileURLWithPath: binary); process.arguments = arguments
    try process.run(); process.waitUntilExit(); return process.terminationStatus
}
let executable = temp.appendingPathComponent("checks")
let code = try run("/usr/bin/swiftc", ["-j1", "-parse-as-library",
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/WorldAgentContext.swift").path,
    root.appendingPathComponent("apps/macos/UnityHost/UnityActivityBridge.swift").path,
    root.appendingPathComponent("apps/macos/UnityHost/UnityDevicePlacementBridge.swift").path,
    program.path, "-o", executable.path] + flags)
guard code == 0 else { exit(code) }
exit(try run(executable.path, []))

// S2/S3 的唯一写入方门禁 + 权威行为断言。
//
// 只读生产源码、只在临时目录里编译/运行，不启动 app、不碰真机存档、不写 repo。
// 判据（docs/plans/2026-10-02-rust-world-authority-and-mcp.md §3.4 / §5.7）：
//
//   R1 唯一写入方：`state.json` 的写入口必须**抛**，且生产代码里不存在第二条
//      世界状态持久化路径。**注入回旧写入必须让本门禁 FAIL**（见末尾负对照）。
//   R2 缓存不是权威：读带 `revision`，写带 `expectedRevision`；不匹配是**可见拒绝**。
//   R3 事实派生确定性：同一批记录 diff 出的 fact 序列逐字相同（两段独立冷启动比对）。
//   R4 往返保真：写入→读出**逐位相同**（含 1788821988294.7507 这类 1 ulp 浮点坑）。
//   R5 事件接线：`world_subscribe` 真的把权威事实推进 Swift 投影。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
func fail(_ message: String) -> Never { print("FAIL: \(message)"); exit(1) }
func require(_ condition: Bool, _ message: String) { if !condition { fail(message) } }
func text(_ path: String) -> String {
    guard let value = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("cannot read \(path)")
    }
    return value
}

let clientPath = "apps/macos/Sources/GMGNRadio/Presence/WorldAuthorityClient.swift"
// 退避/重试预算的**唯一**定义（权威重连读它）—— 编它，不另抄一套常量。
let backoffPath = "apps/macos/Sources/GMGNRadio/Presence/RetryBackoff.swift"
let persistencePath = "apps/macos/Sources/GMGNRadio/Presence/AuthorityWorldStatePersistence.swift"
let bootstrapPath = "apps/macos/Sources/GMGNRadio/App/LivingWorldBootstrap.swift"
let clientSource = text(clientPath)
let persistenceSource = text(persistencePath)
let bootstrapSource = text(bootstrapPath)

// ---------------------------------------------------------------------------
// 源码级唯一写入方审计
// ---------------------------------------------------------------------------

func body(of signature: String, in source: String) -> String {
    guard let start = source.range(of: signature)?.lowerBound,
          let opening = source[start...].firstIndex(of: "{") else { return "" }
    var depth = 0
    for index in source[opening...].indices {
        if source[index] == "{" { depth += 1 }
        if source[index] == "}" { depth -= 1 }
        if depth == 0 { return String(source[start...index]) }
    }
    return ""
}

/// 返回所有违反"唯一写入方"的地方；空数组 = 通过。
func singleWriterViolations(_ client: String, _ persistence: String, _ bootstrap: String) -> [String] {
    var violations: [String] = []
    // R1a 遗留写入口必须抛，且不许转发给写盘实现。
    let retired = body(of: "func save(_ state: WorldState) throws {", in: persistence)
    if !retired.contains("throw") { violations.append("legacy save no longer throws") }
    if retired.contains("archive.save") || retired.contains(".save(state)") {
        violations.append("legacy save forwards to a writing persistence")
    }
    // R1a' 唯一还持有写盘实现的预像档案必须 `private`，否则模块内处处可达。
    if !persistence.contains("private let archive: any WorldStatePersisting") {
        violations.append("LegacyWorldStatePreImage.archive is not private (a writing persistence stays reachable)")
    }
    // R1b 权威写入只能是一次 commit 意图，不得退回写盘。
    let authoritySave = body(of: "func save(_ state: WorldState) throws {\n        lock.lock()", in: persistence)
    if authoritySave.isEmpty || !authoritySave.contains("client.commit(") {
        violations.append("authority save is not a commit intent")
    }
    if authoritySave.contains("AtomicJSONWorldStatePersistence") || authoritySave.contains("archive.save") {
        violations.append("authority save writes world state to disk")
    }
    // R1c makeContext 必须把遗留存档包成只读预像，不许把它直接当写通道。
    let makeContext = body(of: "static func makeContext(", in: bootstrap)
    if makeContext.isEmpty { violations.append("makeContext not found") }
    if !makeContext.contains("LegacyWorldStatePreImage(") {
        violations.append("makeContext does not wrap the legacy archive as a read-only pre-image")
    }
    if !makeContext.contains("AuthorityWorldStatePersistence(") {
        violations.append("makeContext does not use the authority persistence")
    }
    if makeContext.contains("persistence: try statePersistence(") {
        violations.append("makeContext still hands the writing persistence to the world context")
    }
    return violations
}

let violations = singleWriterViolations(clientSource, persistenceSource, bootstrapSource)
require(violations.isEmpty, "single-writer audit: \(violations.joined(separator: "; "))")
print("  ok   R1 源码审计：state.json 写入口抛错，makeContext 只读预像 + 权威持久化")

// ---------------------------------------------------------------------------
// 负对照：把旧写入注入回去，门禁必须 FAIL
// ---------------------------------------------------------------------------

let injectedPersistence = persistenceSource.replacingOccurrences(
    of: "throw WorldStatePersistenceRetired.writeRetired",
    with: "try archive.save(state)")
require(injectedPersistence != persistenceSource, "injection did not change the source")
let injectedViolations = singleWriterViolations(clientSource, injectedPersistence, bootstrapSource)
require(!injectedViolations.isEmpty,
        "负对照失败：注入回旧写入（archive.save）没有被源码审计抓住")
print("  ok   R1 负对照：注入 `archive.save(state)` ⇒ 审计报 \(injectedViolations.count) 处违规")

// ---------------------------------------------------------------------------
// 准备 WorldRuntime 产物 + daemon 二进制
// ---------------------------------------------------------------------------

let fileManager = FileManager.default
func run(_ path: String, _ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return 127 }
    process.waitUntilExit()
    return process.terminationStatus
}

/// 探针自己的 stdout/stderr 必须**原样**透传：它的每条 `ok` / `FAIL` 就是证据。
func runVisible(_ path: String, _ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    do { try process.run() } catch { return 127 }
    process.waitUntilExit()
    return process.terminationStatus
}

// WorldRuntime 的模块搜索路径 + 目标文件**只有一处定义**：tools/world-runtime-harness-flags.sh。
// 不要在这里拼 `.build/...`：27 份各自拼写正是 SwiftPM 与 xcodebuild 两份模块并存的根因。
// `--ensure` 保留本 harness 原有的"缺产物就先 swift build 一次"的自愈；路径本身仍只有那一处。
func worldRuntimeHarnessFlags() -> [String] {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [FileManager.default.currentDirectoryPath + "/tools/world-runtime-harness-flags.sh", "--ensure"]
    process.standardOutput = pipe
    try? process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(separator: "\n").map(String.init)
}
let worldRuntimeFlags = worldRuntimeHarnessFlags()
let buildRoot = URL(fileURLWithPath: worldRuntimeFlags[1]).deletingLastPathComponent().path
let objects = Array(worldRuntimeFlags.dropFirst(2))
require(!objects.isEmpty, "WorldRuntime object files missing")

let daemon = "target/debug/gmgn-taskd"
do {
    let status = run("/usr/bin/env", ["cargo", "build", "--locked",
                                      "--manifest-path", "services/gmgn-taskd/Cargo.toml"])
    require(status == 0, "cargo build of services/gmgn-taskd failed (\(status))")
}
require(fileManager.fileExists(atPath: daemon), "gmgn-taskd binary missing at \(daemon)")

let exported = CommandLine.arguments.dropFirst().first ?? ""
require(exported.isEmpty || fileManager.fileExists(atPath: exported), "exported pre-image missing at \(exported)")

// ---------------------------------------------------------------------------
// 编译并跑行为断言
// ---------------------------------------------------------------------------

let temporary = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("gmgn-single-writer-\(UUID().uuidString.prefix(8))")
try? fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: temporary) }

let driver = #"""
import Foundation
import Darwin
import WorldRuntime

struct ResidentLeaseFloor: WorldCollisionQuerying {
    func groundHeight(at position: SIMD3<Float>) -> Float? { 0 }
    func canOccupy(_ capsule: WorldCapsule, at position: SIMD3<Float>) -> Bool { true }
}

// Independent S2/S3 verification probe. Drives the production Swift sources
// against a real `gmgn-taskd` in a throwaway root. Never touches app state.

extension JSONDecoder {
    static func worldState(from data: Data) throws -> WorldState? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(WorldState.self, from: data)
    }
}

func canonical(_ value: [String: Any]) -> String {
    (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
        .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
}

@main struct Probe {
    static var failures = 0
    static var warnings = 0

    static func check(_ condition: Bool, _ message: String) {
        if condition { print("  ok   \(message)") } else { print("  FAIL \(message)"); failures += 1 }
    }
    static func warn(_ condition: Bool, _ message: String) {
        if condition { print("  ok   \(message)") } else { print("  WARN \(message)"); warnings += 1 }
    }
    static func section(_ title: String) { print("\n== \(title) ==") }

    static let fileManager = FileManager.default
    // Isolated throwaway authority root, never production Application Support.
    // Foundation's resolvingSymlinksInPath deliberately shortens /private/var
    // back to /var on macOS. taskd correctly rejects that symlink ancestor;
    // use the physical POSIX path for this macOS-only fixture.
    static let base: URL = {
        guard let physical = realpath(NSTemporaryDirectory(), nil) else {
            fatalError("cannot resolve isolated temporary directory")
        }
        defer { free(physical) }
        return URL(fileURLWithPath: String(cString: physical))
            .appendingPathComponent("gmgn-s23-\(UUID().uuidString.prefix(8))")
    }()
    static var daemons: [Process] = []
    static var manifest: WorldManifest!

    struct World {
        let root: URL
        let endpointFile: String
        let legacyURL: URL
        let process: Process
    }

    static func startWorld(tag: String, legacyText: String) throws -> World {
        let root = base.appendingPathComponent("root-\(tag)/TaskService", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let endpointFile = root.appendingPathComponent("taskd.endpoint.json").path
        let support = base.appendingPathComponent("support-\(tag)", isDirectory: true)
        try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        let legacyURL = support.appendingPathComponent("state.json")
        try Data(legacyText.utf8).write(to: legacyURL)
        let process = Process()
        process.executableURL = daemonBinary
        process.arguments = ["--root", root.path, "--endpoint-file", endpointFile, "--concurrency", "2"]
        let logURL = base.appendingPathComponent("daemon-\(tag).log")
        fileManager.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        process.standardOutput = log
        process.standardError = log
        try process.run()
        daemons.append(process)
        let deadline = Date().addingTimeInterval(15)
        while !fileManager.fileExists(atPath: endpointFile) {
            if Date() > deadline {
                let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? "<no log>"
                throw NSError(domain: "probe", code: 1, userInfo: [
                    NSLocalizedDescriptionKey:
                        "daemon HTTP endpoint never appeared for \(tag); running=\(process.isRunning) status=\(process.terminationStatus) log=\(text)"])
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        Thread.sleep(forTimeInterval: 0.2)
        return World(root: root, endpointFile: endpointFile, legacyURL: legacyURL, process: process)
    }

    static func client(_ world: World) -> WorldAuthorityClient {
        WorldAuthorityClient(worldID: manifest.worldID, endpointFile: world.endpointFile,
                             helperPath: "/nonexistent/gmgn-taskd", allowsLaunching: false)
    }

    static func persistence(_ world: World) -> AuthorityWorldStatePersistence {
        let preImage = LegacyWorldStatePreImage(
            archive: AtomicJSONWorldStatePersistence(fileURL: world.legacyURL),
            candidateURLs: [world.legacyURL])
        return AuthorityWorldStatePersistence(
            manifest: manifest, preImage: preImage, endpointFile: world.endpointFile,
            helperPath: "/nonexistent/gmgn-taskd", allowsLaunching: false)
    }

    static func modified(_ url: URL) -> Date? {
        (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    static var daemonBinary = URL(fileURLWithPath: "target/debug/gmgn-taskd")
    static var exportStateURL = URL(fileURLWithPath:
        "backups/world-state-migration/20261001T061021Z/state/marble-living-cabin/1.2.0/state.json")

    @MainActor static func main() async throws {
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        defer {
            for process in daemons where process.isRunning { process.terminate() }
            try? fileManager.removeItem(at: base)
        }
        let arguments = CommandLine.arguments
        if arguments.count > 1 { daemonBinary = URL(fileURLWithPath: arguments[1]).standardizedFileURL }
        if !daemonBinary.path.hasPrefix("/") {
            daemonBinary = URL(fileURLWithPath: fileManager.currentDirectoryPath)
                .appendingPathComponent(daemonBinary.path)
        }
        if arguments.count > 2 { exportStateURL = URL(fileURLWithPath: arguments[2]) }
        manifest = try JSONDecoder().decode(
            WorldManifest.self,
            from: Data(contentsOf: URL(fileURLWithPath:
                "apps/macos/Resources/Worlds/marble-living-cabin/world.json")))
        let exportedText: String
        if arguments.count > 2 && !arguments[2].isEmpty {
            exportedText = try String(contentsOf: exportStateURL, encoding: .utf8)
        } else {
            // Deterministic isolated pre-image; no production backup is required.
            var state = WorldState(revision: 1, worldID: manifest.worldID,
                worldTime: Date(timeIntervalSince1970: 1788821988294.7507 / 1000),
                lastObservedWallTime: Date(timeIntervalSince1970: 1788821988294.7507 / 1000), weather: .clear,
                agentTransform: WorldTransform(position: WorldVector3(x: 0, y: 0, z: 0),
                    rotation: WorldQuaternion(x: 0, y: 0, z: 0, w: 1), scale: WorldVector3(x: 1, y: 1, z: 1)))
            state.objectStates["http-probe-object"] = WorldObjectState(transform: state.agentTransform)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
            exportedText = String(decoding: try encoder.encode(state), as: UTF8.self)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        print("daemon=\(daemonBinary.path)")
        print("pre-image=\(exportStateURL.path)")
        print("worldID=\(manifest.worldID)")

        // MARK: A. one-time import; state.json stays read-only

        section("A. 一次性导入 + state.json 只读")
        let world1 = try startWorld(tag: "a", legacyText: exportedText)
        let legacyBefore = try Data(contentsOf: world1.legacyURL)
        let mtimeBefore = modified(world1.legacyURL)
        let authority1 = persistence(world1)
        let loaded = try authority1.load()
        check(loaded != nil, "load() returns a state (imported from the read-only pre-image)")
        let importRevision = authority1.lastAppliedRevision
        check(importRevision >= 1, "authority has a world record after import (revision=\(importRevision))")
        check(try Data(contentsOf: world1.legacyURL) == legacyBefore, "state.json bytes unchanged by import")
        check(modified(world1.legacyURL) == mtimeBefore, "state.json mtime unchanged by import")
        let exportedState = try JSONDecoder.worldState(from: Data(exportedText.utf8))
        check(loaded == exportedState, "imported state decodes equal to the exported pre-image")
        let hazardMilliseconds = exportedState!.worldTime.timeIntervalSince1970 * 1000
        check(String(format: "%.4f", hazardMilliseconds).hasSuffix("7507"),
              "pre-image carries the ulp-hazard timestamp (worldTime ms=\(hazardMilliseconds))")

        // MARK: B. write→read round trip, bit for bit

        section("B. 往返保真（写入→读出逐位相同）")
        var next = loaded!
        next.weather = .rain
        next.activeActivity = nil
        let sent = try WorldAuthorityClient.encodeDocument(next)
        let sentBytes = try JSONSerialization.data(withJSONObject: sent, options: [.sortedKeys])
        try authority1.save(next)
        check(authority1.lastAppliedRevision == importRevision + 1,
              "one commit advanced the authority revision \(importRevision) → \(authority1.lastAppliedRevision)")
        let readBack = try client(world1).snapshot()!
        check(readBack.state == next, "read-back WorldState equals what was written")
        let readBytes = try JSONSerialization.data(
            withJSONObject: try WorldAuthorityClient.encodeDocument(readBack.state), options: [.sortedKeys])
        check(readBytes == sentBytes, "write→read re-encodes to identical bytes (\(sentBytes.count) B)")
        print("       rust stateSha256=\(readBack.stateSha256.prefix(16))… swift digest=\(WorldAuthorityClient.digest(sent).prefix(16))…")
        check(try Data(contentsOf: world1.legacyURL) == legacyBefore, "state.json bytes unchanged after a commit")
        check(modified(world1.legacyURL) == mtimeBefore, "state.json mtime unchanged after a commit")

        // MARK: C. stale expectedRevision ⇒ visible rejection

        section("C. 陈旧即拒（expectedRevision 不匹配）")
        let revisionBeforeStale = readBack.recordRevision
        var staleState = readBack.state
        staleState.weather = .snow
        let staleAuthority = persistence(world1)   // never loaded ⇒ revision 0
        do {
            try staleAuthority.save(staleState)
            check(false, "a commit built on a stale revision was accepted (silent overwrite)")
        } catch let error as WorldAuthorityError {
            check(error == .staleProjection(local: 0, authority: revisionBeforeStale),
                  "stale commit rejected as .staleProjection(local:0, authority:\(revisionBeforeStale))")
            print("       visible message: \(error.localizedDescription)")
        } catch {
            check(false, "stale commit threw an unexpected error: \(error)")
        }
        let afterStale = try client(world1).snapshot()!
        check(afterStale.recordRevision == revisionBeforeStale,
              "rejected commit did not advance the authority (still \(afterStale.recordRevision))")
        check(afterStale.state == readBack.state, "rejected commit did not overwrite the document")

        // Device edits use a different authority client. Reading their returned
        // state does not renew the resident owner's CAS lease; its own load does.
        let residentOwner = persistence(world1)
        _ = try residentOwner.load()
        let deviceOwner = persistence(world1)
        var deviceState = try deviceOwner.load()!
        deviceState.revision += 1
        deviceState.weather = .rain
        try deviceOwner.save(deviceState)
        var residentState = deviceState
        residentState.revision += 1
        do {
            try residentOwner.save(residentState)
            check(false, "external device readback cannot implicitly renew another CAS owner")
        } catch let error as WorldAuthorityError {
            if case .staleProjection = error { check(true, "external device commit leaves resident lease stale") }
            else { check(false, "unexpected external commit rejection") }
        }
        let durableAfterDevice = try residentOwner.load()!
        check(durableAfterDevice == deviceState, "resident owner reload preserves committed device edit")
        residentState = durableAfterDevice
        residentState.revision += 1
        try residentOwner.save(residentState)
        check(try client(world1).snapshot()!.state == residentState,
              "owner reload renews CAS and next checkpoint succeeds without replaying device edit")

        // Exercise the production Context's owner refresh, not merely the
        // persistence API: a device edit must survive subsequent stop/move.
        let seed = WorldSimulation(manifest: manifest, startedAt: Date()).state
        let seedEncoder = JSONEncoder()
        seedEncoder.dateEncodingStrategy = .millisecondsSince1970
        let contextWorld = try startWorld(tag: "resident-lease", legacyText:
            String(decoding: seedEncoder.encode(seed), as: UTF8.self))
        let contextOwner = persistence(contextWorld)
        let residentContext = try WorldAgentContext(manifest: manifest, persistence: contextOwner,
            initialCollisionWorld: ResidentLeaseFloor())
        try residentContext.startActivity(id: "home.walk")
        let contextDevice = persistence(contextWorld)
        var contextDeviceState = try contextDevice.load()!
        contextDeviceState.weather = .rain
        contextDeviceState.revision += 1
        contextDeviceState.layoutRevision += 1
        try contextDevice.save(contextDeviceState)
        let leaseBeforeReadback = contextOwner.lastAppliedRevision
        let projectionBeforeReadback = residentContext.state
        let verification = try await residentContext.readAuthoritySnapshot()!
        check(verification == contextDeviceState, "verification reads the external authority state")
        check(contextOwner.lastAppliedRevision == leaseBeforeReadback,
              "verification read does not renew the checkpoint CAS lease")
        check(residentContext.state == projectionBeforeReadback,
              "verification read preserves the active simulation projection")
        do {
            try contextOwner.save(projectionBeforeReadback)
            check(false, "verification must not admit a checkpoint from the older simulation")
        } catch let error as WorldAuthorityError {
            if case .staleProjection = error {
                check(true, "checkpoint remains rejected until the authority state is adopted")
            } else { check(false, "unexpected checkpoint rejection after verification") }
        }
        var foreignActivity = contextDeviceState
        foreignActivity.revision += 1
        foreignActivity.activeActivity?.startedAt.addTimeInterval(1)
        try contextDevice.save(foreignActivity)
        let rejectedSnapshot = try await residentContext.readPersistedAuthorityState()!
        do {
            try residentContext.adoptAuthorityState(rejectedSnapshot, propFunctionSources: [],
                replacingUncommittedProjection: true)
            check(false, "external activity without the renderer lease must be rejected")
        } catch WorldAgentContextError.activityRejected {
            check(contextOwner.lastAppliedRevision == leaseBeforeReadback,
                  "failed activity adoption preserves the original checkpoint lease")
            check(residentContext.state == projectionBeforeReadback,
                  "failed activity adoption preserves the simulation")
        }
        do {
            try contextOwner.save(projectionBeforeReadback)
            check(false, "failed adoption must not admit the stale layout checkpoint")
        } catch WorldAuthorityError.staleProjection {
            check(true, "failed adoption leaves stale checkpoints rejected")
        }
        contextDeviceState.revision = foreignActivity.revision + 1
        try contextDevice.save(contextDeviceState)
        let refreshed = try await residentContext.readPersistedAuthorityState()!
        try residentContext.adoptAuthorityState(refreshed, propFunctionSources: [],
            replacingUncommittedProjection: true)
        var interveningState = contextDeviceState
        interveningState.revision += 1
        interveningState.layoutRevision += 1
        try contextDevice.save(interveningState)
        do {
            try await residentContext.acceptAuthoritySnapshot(refreshed)
            check(false, "an intervening authority edit must reject snapshot acceptance")
        } catch WorldAuthorityError.staleProjection {
            check(contextOwner.lastAppliedRevision == leaseBeforeReadback,
                  "snapshot acceptance never renews a lease for an unadopted edit")
        }
        let latest = try await residentContext.readPersistedAuthorityState()!
        try residentContext.adoptAuthorityState(latest, propFunctionSources: [],
            replacingUncommittedProjection: true)
        try await residentContext.acceptAuthoritySnapshot(latest)
        check(contextOwner.lastAppliedRevision == contextDevice.lastAppliedRevision,
              "successful adoption renews the lease for exactly the adopted layout")
        try residentContext.stopActivity()
        _ = try residentContext.move(to: "wp.spawn")
        let afterResidentControl = try client(contextWorld).snapshot()!.state
        check(afterResidentControl.weather == .rain && afterResidentControl.activeActivity == nil,
              "external device edit survives owner refresh followed by real Context stop and move")
        check(contextOwner.lastAppliedRevision > contextDevice.lastAppliedRevision,
              "stop and move successfully commit through the refreshed resident CAS owner")

        // Reproduce a confirmed inventory document retaining collect while the
        // current actor has already stopped. Full adoption must still reject it.
        let inventoryWorld = try startWorld(tag: "inventory-actor", legacyText:
            String(decoding: seedEncoder.encode(seed), as: UTF8.self))
        let inventoryOwner = persistence(inventoryWorld)
        let inventoryContext = try WorldAgentContext(manifest: manifest, persistence: inventoryOwner,
            initialCollisionWorld: ResidentLeaseFloor())
        try inventoryContext.startActivity(id: "home.walk")
        let inventoryWriter = persistence(inventoryWorld)
        var inventoryDocument = try inventoryWriter.load()!
        inventoryDocument.activeActivity?.activityID = "wish_machine.collect"
        inventoryDocument.layoutRevision = 48
        let sofa = WorldGeneratedProp(objectID: "wish-prop-confirmed-sofa", sourceWishID: "confirmed-sofa",
            assetID: "asset-confirmed-sofa", displayName: "沙发",
            size: WorldVector3(x: 2, y: 1, z: 1), sourceHeight: 1)
        var registration = WorldSimulation(restoring: inventoryDocument)
        try registration.applyPropLayout(.register(sofa), expectedLayoutRevision: 48,
            requestID: "claimed.confirmed-sofa")
        try inventoryWriter.save(registration.state)
        do { try inventoryContext.stopActivity() }
        catch WorldAuthorityError.staleProjection {}
        let stoppedPosition = inventoryContext.state.agentTransform
        let confirmedSnapshot = try await inventoryContext.readPersistedAuthorityState()!
        check(confirmedSnapshot.activeActivity?.activityID == "wish_machine.collect"
              && confirmedSnapshot.layoutRevision == 49, "fixture retains formal collect and registered layout 49")
        do {
            try inventoryContext.adoptAuthorityState(confirmedSnapshot, propFunctionSources: [],
                replacingUncommittedProjection: true)
            check(false, "full adoption cannot resurrect the stopped collection")
        } catch WorldAgentContextError.activityRejected {}
        try inventoryContext.adoptAuthorityInventoryLayout(confirmedSnapshot, propFunctionSources: [])
        try await inventoryContext.acceptAuthoritySnapshot(confirmedSnapshot)
        check(inventoryContext.state.activeActivity == nil
              && inventoryContext.state.agentTransform == stoppedPosition,
              "inventory adoption preserves the stopped actor and its position")
        check(inventoryContext.state.objectStates[sofa.objectID]?.generatedProp == sofa
              && inventoryContext.state.objectStates[sofa.objectID]?.isEnabled == false
              && inventoryContext.state.layoutRevision == 49,
              "inventory adoption exposes the confirmed sofa without placing it")
        try inventoryOwner.save(inventoryContext.state)
        let inventoryCheckpoint = try client(inventoryWorld).snapshot()!.state
        check(inventoryCheckpoint.activeActivity == nil
              && inventoryCheckpoint.objectStates[sofa.objectID]?.generatedProp == sofa,
              "checkpoint preserves the confirmed inventory and stopped actor")
        let inventoryLease = inventoryOwner.lastAppliedRevision
        var laterInventory = try inventoryWriter.load()!
        laterInventory.revision += 1
        laterInventory.layoutRevision += 1
        try inventoryWriter.save(laterInventory)
        do {
            try await inventoryContext.acceptAuthoritySnapshot(inventoryCheckpoint)
            check(false, "inventory acceptance must reject an intervening layout update")
        } catch WorldAuthorityError.staleProjection {
            check(inventoryOwner.lastAppliedRevision == inventoryLease,
                  "intervening inventory update preserves the previous checkpoint lease")
        }
        do {
            try inventoryOwner.save(inventoryContext.state)
            check(false, "unadopted inventory update must keep old checkpoint rejected")
        } catch WorldAuthorityError.staleProjection {
            check(true, "unadopted inventory update keeps old checkpoint rejected")
        }

        // MARK: D. the legacy write path must throw

        section("D. 遗留写路径抛错")
        let retired = LegacyWorldStatePreImage(
            archive: AtomicJSONWorldStatePersistence(fileURL: world1.legacyURL),
            candidateURLs: [world1.legacyURL])
        do {
            try retired.save(staleState)
            check(false, "LegacyWorldStatePreImage.save did not throw")
        } catch WorldStatePersistenceRetired.writeRetired {
            check(true, "LegacyWorldStatePreImage.save throws .writeRetired")
        } catch {
            check(false, "LegacyWorldStatePreImage.save threw the wrong error: \(error)")
        }
        check(try Data(contentsOf: world1.legacyURL) == legacyBefore, "throwing save left state.json untouched")

        // MARK: E. is a second world-state persistence path still reachable?

        section("E. 唯一写入方：预像路径已封口")
        let forkURL = base.appendingPathComponent("fork-state.json")
        try legacyBefore.write(to: forkURL)
        let forkBefore = try Data(contentsOf: forkURL)
        let fork = LegacyWorldStatePreImage(
            archive: AtomicJSONWorldStatePersistence(fileURL: forkURL), candidateURLs: [forkURL])
        do {
            try fork.save(staleState)
            check(false, "the pre-image accepted a write")
        } catch WorldStatePersistenceRetired.writeRetired {
            check(true, "the pre-image's only write entry point throws .writeRetired")
        } catch {
            check(false, "unexpected error from the pre-image: \(error)")
        }
        check(try Data(contentsOf: forkURL) == forkBefore,
              "no reachable path through the pre-image writes state.json (archive is private)")
        print("       (`archive` is private: a module-wide `preImage.archive.save(...)` no longer compiles)")

        // MARK: F. the event channel really reaches Swift

        section("F. 事件通道 world_subscribe")
        let follower = client(world1)
        follower.startEventSubscription()
        check(follower.subscriptionIsRunning, "subscription thread is running")
        let writer = client(world1)
        let current = try writer.snapshot()!
        var pushed = current.state
        pushed.weather = .cloudy
        let commitResult = try writer.commit(state: pushed, expectedRevision: current.recordRevision,
                                             intent: ["kind": "verify.probe"])
        check(commitResult.revision == current.recordRevision + 1,
              "second writer committed revision \(commitResult.revision)")
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline, follower.projection.lastAppliedSequence < commitResult.sequence {
            Thread.sleep(forTimeInterval: 0.05)
        }
        check(follower.projection.lastAppliedSequence >= commitResult.sequence,
              "world_subscribe delivered facts up to seq \(commitResult.sequence)")
        check(follower.projection.basedOnRevision >= commitResult.revision,
              "pushed facts advanced the projection to revision \(follower.projection.basedOnRevision)")

        // MARK: G. per-object facts: does the projection accept them?

        section("G. 事实推进：world 级 vs object 级")
        var allFacts: [WorldAuthorityFact] = []
        var cursor: UInt64 = 0
        while true {
            let (batch, nextCursor) = try writer.facts(after: cursor, limit: 200)
            if batch.isEmpty { break }
            allFacts.append(contentsOf: batch)
            if nextCursor <= cursor { break }
            cursor = nextCursor
        }
        // A change that touches an object derives typed per-object facts *after*
        // the world.stateCommitted fact (higher world revision, lower object revision).
        let objectWriter = client(world1)
        let objectRecord = try objectWriter.snapshot()!
        var objectDocument = objectRecord.state
        var appliedBeforeObjectCommit = follower.projection.appliedFacts
        if let key = objectDocument.objectStates.keys.sorted().first {
            var item = objectDocument.objectStates[key]!
            let position = item.transform.position
            item.transform = WorldTransform(
                position: WorldVector3(x: position.x + 0.5, y: position.y, z: position.z),
                rotation: item.transform.rotation, scale: item.transform.scale)
            objectDocument.objectStates[key] = item
            appliedBeforeObjectCommit = follower.projection.appliedFacts
            let objectCommit = try objectWriter.commit(state: objectDocument,
                                                        expectedRevision: objectRecord.recordRevision,
                                                        intent: ["kind": "verify.objectProbe"])
            let objectDeadline = Date().addingTimeInterval(4)
            while Date() < objectDeadline,
                  follower.projection.lastAppliedSequence < objectCommit.sequence {
                Thread.sleep(forTimeInterval: 0.05)
            }
            print("       object-touching commit at seq=\(objectCommit.sequence) revision=\(objectCommit.revision)")
        }
        allFacts = []
        cursor = 0
        while true {
            let (batch, nextCursor) = try writer.facts(after: cursor, limit: 200)
            if batch.isEmpty { break }
            allFacts.append(contentsOf: batch)
            if nextCursor <= cursor { break }
            cursor = nextCursor
        }
        let objectFacts = allFacts.filter { $0.kind.hasPrefix("object.") }
        let worldFacts = allFacts.filter { $0.kind.hasPrefix("world.") }
        print("       facts: total=\(allFacts.count) world=\(worldFacts.count) object=\(objectFacts.count)")
        print("       projection: applied=\(follower.projection.appliedFacts) droppedStale=\(follower.projection.droppedStaleFacts)")
        check(follower.projection.droppedStaleFacts == 0 && follower.projection.revisionRegressions == 0,
              "no in-order fact is dropped (applied=\(follower.projection.appliedFacts) droppedSeq=\(follower.projection.droppedStaleFacts) regressions=\(follower.projection.revisionRegressions))")
        check(follower.projection.appliedFacts >= appliedBeforeObjectCommit + 2,
              "the object-touching commit applied BOTH its world fact and its object fact (\(appliedBeforeObjectCommit) → \(follower.projection.appliedFacts))")

        section("G2. 投影守卫（合成事实，不依赖 daemon）")
        var projection = WorldAuthorityProjection()
        projection.adopt(recordRevision: 3, boundarySeq: 4, stateSha256: "seed")
        func synthetic(_ sequence: UInt64, _ kind: String, _ domain: String, _ key: String,
                       _ revision: UInt64) -> WorldAuthorityFact {
            WorldAuthorityFact(sequence: sequence, id: "\(kind):\(sequence)", kind: kind,
                               subjectDomain: domain, subjectKey: key, revision: revision,
                               payload: [:], producer: "probe", atMilliseconds: 0)
        }
        let worldCommitFact = synthetic(5, "world.stateCommitted", "worlds", "state", 4)
        let objectPlacedFact = synthetic(6, "object.placed", "objects", "o1", 3)
        check(projection.apply(worldCommitFact), "同一提交的 world 事实被应用")
        check(projection.apply(objectPlacedFact),
              "同一提交里 revision 更低（物件自己的数轴）的 object 事实**也必须**被应用")
        check(projection.basedOnRevision == 4,
              "basedOnRevision 只跟随世界记录（=4），不被物件 revision 拉走")
        check(projection.appliedFacts == 2 && projection.droppedStaleFacts == 0
              && projection.revisionRegressions == 0, "两条都计入 applied，没有误丢")
        check(!projection.apply(objectPlacedFact), "重连重放同一条 ⇒ 按 seq 丢弃（不重复应用）")
        check(!projection.apply(worldCommitFact), "重放 world 事实同样丢弃")
        check(projection.lastAppliedSequence == 6, "游标越过了已应用的最高 seq")
        check(projection.appliedFacts == 2, "重放不增加 applied 计数（幂等）")
        check(!projection.apply(synthetic(7, "object.placed", "objects", "o1", 2)),
              "同一 subject 的 revision 回退被单独判为协议错")
        check(projection.revisionRegressions == 1, "revision 回退单独计数，不混进 droppedSeq")
        if let firstObject = objectFacts.first, let lastWorld = worldFacts.last {
            print("       e.g. object fact revision=\(firstObject.revision) vs world commit revision=\(lastWorld.revision)")
        }

        // MARK: H. determinism of the derived fact sequence

        section("H. 事实派生确定性（diff 派生的事实）")
        func derivedFacts(_ world: World) throws -> [String] {
            let owner = client(world)
            let record = try owner.snapshot()!
            var document = record.state
            let key = try document.objectStates.keys.sorted().first
                ?? { throw NSError(domain: "probe", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "no objects to diff"]) }()
            var item = document.objectStates[key]!
            let position = item.transform.position
            item.transform = WorldTransform(
                position: WorldVector3(x: position.x + 0.25, y: position.y, z: position.z),
                rotation: item.transform.rotation, scale: item.transform.scale)
            item.isEnabled = !item.isEnabled
            document.objectStates[key] = item
            let before = record.boundarySeq
            _ = try owner.commit(state: document, expectedRevision: record.recordRevision,
                                 intent: ["kind": "determinism.probe"])
            let (facts, _) = try owner.facts(after: before, limit: 200)
            return facts.filter { $0.kind.hasPrefix("object.") }.map { fact in
                "\(fact.kind)|\(fact.subjectDomain)|\(fact.subjectKey)|\(fact.revision)|\(canonical(fact.payload))"
            }
        }
        // Two independent cold starts with identical histories: same pre-image,
        // same first commit. Only then are the derived revisions comparable.
        let world2 = try startWorld(tag: "h2", legacyText: exportedText)
        _ = try persistence(world2).load()
        let world3 = try startWorld(tag: "h3", legacyText: exportedText)
        _ = try persistence(world3).load()
        let sequenceA = try derivedFacts(world2)
        let sequenceB = try derivedFacts(world3)
        check(!sequenceA.isEmpty, "the probe commit derived at least one typed object fact (\(sequenceA.count))")
        check(sequenceA == sequenceB,
              "same records diff to a byte-identical derived fact sequence across two runs")
        if sequenceA != sequenceB {
            for (index, pair) in zip(sequenceA, sequenceB).enumerated() where pair.0 != pair.1 {
                print("       first divergence at \(index):\n         A=\(pair.0)\n         B=\(pair.1)")
                break
            }
        }
        for fact in sequenceA { print("       A: \(fact.prefix(120))") }

        // MARK: I. the legacy file never moves again

        section("I. state.json 在整个流程后仍然只读")
        check(try Data(contentsOf: world1.legacyURL) == legacyBefore, "state.json bytes unchanged end to end")
        check(modified(world1.legacyURL) == mtimeBefore, "state.json mtime unchanged end to end")

        // MARK: J. authority unreachable ⇒ read-only downgrade, never a local write

        section("J. 权威不可达：只读降级 / fail-closed")
        let deadEndpointFile = base.appendingPathComponent("dead/taskd.endpoint.json").path
        let orphan = LegacyWorldStatePreImage(
            archive: AtomicJSONWorldStatePersistence(fileURL: world1.legacyURL),
            candidateURLs: [world1.legacyURL])
        let downgraded = AuthorityWorldStatePersistence(
            manifest: manifest, preImage: orphan, endpointFile: deadEndpointFile,
            helperPath: "/nonexistent/gmgn-taskd", allowsLaunching: false)
        let degradedState = try downgraded.load()
        check(degradedState != nil, "authority unreachable + pre-image present ⇒ world still renders (read-only)")
        check(downgraded.downgradedReason != nil, "downgrade is recorded and visible: \(downgraded.downgradedReason ?? "-")")
        do {
            try downgraded.save(readBack.state)
            check(false, "a write was accepted while the authority was unreachable")
        } catch let error as WorldAuthorityError {
            check(true, "write while downgraded is refused: \(error.localizedDescription)")
        } catch {
            check(false, "unexpected error while downgraded: \(error)")
        }
        check(try Data(contentsOf: world1.legacyURL) == legacyBefore,
              "downgraded write did not fall back to state.json")
        let emptySupport = base.appendingPathComponent("empty-support", isDirectory: true)
        try fileManager.createDirectory(at: emptySupport, withIntermediateDirectories: true)
        let missingURL = emptySupport.appendingPathComponent("state.json")
        let coldStart = AuthorityWorldStatePersistence(
            manifest: manifest,
            preImage: LegacyWorldStatePreImage(
                archive: AtomicJSONWorldStatePersistence(fileURL: missingURL),
                candidateURLs: [missingURL]),
            endpointFile: deadEndpointFile, helperPath: "/nonexistent/gmgn-taskd", allowsLaunching: false)
        do {
            _ = try coldStart.load()
            check(false, "cold start without authority and without a pre-image invented a world")
        } catch {
            check(true, "cold start without authority/pre-image is fail-closed: \(error)")
        }
        check(!fileManager.fileExists(atPath: missingURL.path),
              "fail-closed cold start did not create a state.json")

        section("K. 生产端点")
        let endpoint = WorldAuthorityEndpoint(applicationSupportBase: nil, bundle: Bundle.main)
        print("       endpointFile=\(endpoint.endpointFile)")
        print("       helper=\(endpoint.helperPath)")
        check(endpoint.endpointFile.hasSuffix("gmgn radio/TaskService/taskd.endpoint.json"),
              "production HTTP endpoint file matches PropTaskDaemonClient's default")
        let liveEndpointFile = ("~/Library/Application Support/gmgn radio/TaskService/taskd.endpoint.json" as NSString)
            .expandingTildeInPath
        check(endpoint.endpointFile == liveEndpointFile, "endpoint descriptor resolves to the live daemon")

        // MARK: L. duplicate no-op checkpoint (same document, new expectedRevision)

        section("L. 重复无变化提交")
        let replayPersistence = persistence(world2)
        let replayState = try replayPersistence.load()!
        do {
            try replayPersistence.save(replayState)
            let first = replayPersistence.lastAppliedRevision
            try replayPersistence.save(replayState)
            check(replayPersistence.lastAppliedRevision > first,
                  "a repeated no-op checkpoint is accepted, not a hard error (\(first) → \(replayPersistence.lastAppliedRevision))")
        } catch {
            check(false, "a repeated no-op checkpoint must not be a hard error: \(error)")
        }

        print("\n==== RESULT: failures=\(failures) warnings=\(warnings) ====")
        if failures > 0 { exit(1) }
        print("PASS: world authority S2/S3 probe")
    }
}

"""#

let driverURL = temporary.appendingPathComponent("main.swift")
try driver.write(to: driverURL, atomically: true, encoding: .utf8)
let executable = temporary.appendingPathComponent("probe")
let compile = run("/usr/bin/nice", ["-n", "15", "/usr/bin/swiftc", "-j1", "-parse-as-library",
                                    "-I", "\(buildRoot)/Modules", "apps/macos/Sources/GMGNRadio/Presence/TaskdHTTPTransport.swift", clientPath, persistencePath,
                                    backoffPath, "apps/macos/Sources/GMGNRadio/Agent/WorldAgentContext.swift",
                                    driverURL.path] + objects + ["-o", executable.path])
require(compile == 0, "the authority probe failed to compile (\(compile))")
let status = runVisible(executable.path, [daemon, exported])
guard status == 0 else { exit(status) }

print("PASS: single writer for world state — legacy write throws, authority owns writes, revision-guarded, deterministic, bit-faithful, subscribed")

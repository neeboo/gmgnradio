import Foundation
import WorldRuntime

// Explicit boundary doubles. Production bridge and WorldRuntime are compiled;
// this does not claim real provider, Rust daemon or Unity visual acceptance.
enum WishMachineStage: String { case ready, claimed }
enum WishMachineError: Error { case notReady, wrongScope, conflictingCall, unavailable, notAtMachine }
struct WishMachineJob: Sendable {
    let id: UUID, worldID: String, residentScope: String, objectID: String, name: String
    var stage: WishMachineStage
    var jobID: UUID? { id }
    var modelPath: String? { nil }
    var sizeIntent: TestSizeIntent? { nil }
    var heightMeters: Double { 1 }
}
struct TestSizeIntent: Sendable {
    enum Mode { case dimensions }
    enum Axis: String { case height }
    enum Source: String { case user }
    var mode: Mode; var millimeters: TestMM?; var axis: Axis; var meters: Double; var source: Source
}
struct TestMM: Sendable { let x, y, z: Double }
struct PropGenerationRecord: Sendable { let id: UUID; let receipt: TestReceipt?; let localModelPath: String?; var localCollisionPath: String? { nil } }
struct TestInspection: Sendable { let sha256: String; let bytes: Int }
struct TestResult: Sendable {
    let inspection: TestInspection
    var workflowAuthoritativeSize: WorldPropAuthoritativeSize? { nil }
    var workflowCollision: WorldPropCollisionProxy? { nil }
    var declaresWorkflowCollision: Bool { false }
}
struct TestReceipt: Sendable { enum State { case completed }; let state: State; let result: TestResult? }
@MainActor final class PropGenerationStore { var jobs: [PropGenerationRecord] = [] }
struct WorldAuthorityEndpoint { let endpointFile = ""; let helperPath = ""; init(applicationSupportBase: URL) {} }
enum WorldAuthorityError: Error { case noAuthorityRecord, invalidResponse }
struct TestWorldRecord { let state: WorldState; let recordRevision: UInt64 }
final class WorldAuthorityClient: @unchecked Sendable {
    let worldID: String
    init(worldID: String, endpointFile: String, helperPath: String, allowsLaunching: Bool) { self.worldID = worldID }
    func snapshot() throws -> TestWorldRecord? { fatalError("Inventory boundary injected; no daemon") }
    func commit(state: WorldState, expectedRevision: UInt64, intent: [String: Any]) throws -> Bool { fatalError("No daemon") }
}
struct RealtimeDJToolResult { let callID: String; let resultJSON: Data; let isError: Bool }
@MainActor final class ResidentWorldToolSession {
    struct AdditionalTool {
        let name, description: String; let inputSchema: [String: Any]
        let validate: @MainActor ([String: Any]) -> Bool
        let handle: @MainActor (String, Data) async -> RealtimeDJToolResult
    }
}
@MainActor final class ResidentWishMachineTools { var tools: [ResidentWorldToolSession.AdditionalTool] = [] }
@MainActor final class WishMachineCoordinator {
    var job: WishMachineJob
    var arrived = false
    var claims = 0
    init(_ job: WishMachineJob) { self.job = job }
    func residentJobs(worldID: String, residentScope: String) -> [WishMachineJob] { [job].filter { $0.worldID == worldID && $0.residentScope == residentScope } }
    func read(id: UUID, worldID: String, residentScope: String) throws -> WishMachineJob {
        guard id == job.id, worldID == job.worldID, residentScope == job.residentScope else { throw WishMachineError.wrongScope }; return job
    }
    func refreshPending(limit: Int) async {}
    func refresh(id: UUID, worldID: String, residentScope: String) async throws -> WishMachineJob { try read(id: id, worldID: worldID, residentScope: residentScope) }
    func retry(id: UUID, worldID: String, residentScope: String) async throws -> WishMachineJob { try read(id: id, worldID: worldID, residentScope: residentScope) }
    func claimAvailability(id: UUID, worldID: String, residentScope: String) -> Result<WishMachineJob, WishMachineError> {
        arrived || job.stage == .claimed ? .success(job) : .failure(.notAtMachine)
    }
    func claim(id: UUID, worldID: String, residentScope: String) throws -> WishMachineJob {
        _ = try read(id: id, worldID: worldID, residentScope: residentScope)
        if job.stage == .claimed { return job }
        guard arrived else { throw WishMachineError.notAtMachine }
        claims += 1; job.stage = .claimed; return job
    }
}
@main struct WishRegression {
    @MainActor static func perform(_ bridge: UnityWishMachineBridge, op: String, id: UUID) async throws -> [String: Any] {
        precondition(bridge.command(["op": op, "requestID": UUID().uuidString, "wishID": id.uuidString]))
        for _ in 0..<100 {
            let value = bridge.snapshot()
            if value["pending"] as? Bool == false, value["status"] != nil { return value }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        fatalError("Timed out")
    }
    @MainActor static func main() async throws {
        let id = UUID(), objectID = "wish-prop-test"
        let coordinator = WishMachineCoordinator(.init(id: id, worldID: "test", residentScope: "scope", objectID: objectID, name: "Test", stage: .ready))
        let prop = WorldGeneratedProp(objectID: objectID, sourceWishID: id.uuidString, assetID: "sha256:" + String(repeating: "a", count: 64), displayName: "Test", size: .init(x: 1, y: 1, z: 1), sourceHeight: 1)
        var persisted: WorldGeneratedProp?, registerCount = 0, readFails = false, callbackCount = 0
        func make() -> UnityWishMachineBridge {
            UnityWishMachineBridge(coordinator: coordinator, worldID: "test", residentScope: "scope", registerInventory: { _ in
                registerCount += 1; persisted = prop; readFails = true; return prop
            }, inventoryReadback: { _ in
                if readFails { throw WishMachineError.unavailable }; return persisted
            })
        }
        let bridge = make(); bridge.onInventoryConfirmed = { _ in callbackCount += 1 }
        let denied = try await perform(bridge, op: "wish.claim", id: id)
        precondition(denied["status"] as? String == "failed" && coordinator.claims == 0 && registerCount == 0)
        coordinator.arrived = true
        let uncertain = try await perform(bridge, op: "wish.claim", id: id)
        precondition(uncertain["status"] as? String == "failed" && coordinator.claims == 1 && registerCount == 1 && callbackCount == 0)
        readFails = false
        let confirmed = try await perform(bridge, op: "wish.inventory.retry", id: id)
        precondition(confirmed["status"] as? String == "completed" && registerCount == 1 && coordinator.claims == 1 && callbackCount == 1)
        let restarted = make()
        restarted.onInventoryConfirmed = { _ in callbackCount += 1 }
        let restored = try await perform(restarted, op: "wish.status", id: id)
        let entries = restored["entries"] as! [[String: Any]]
        precondition(entries[0]["inventoryRegistered"] as? Bool == true && registerCount == 1 && coordinator.claims == 1 && callbackCount == 2)
        bridge.close(); precondition(!bridge.command(["op": "wish.status", "requestID": "closed"]))
        print("PASS: arrival refusal/claimed-but-readback-failed/retry without duplicate/recreated bridge restores inventory/close")
    }
}

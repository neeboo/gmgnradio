import Foundation
import CryptoKit
import WorldRuntime

// Task projection doubles only; the catalog source and WorldRuntime are real.
struct PropTaskContext { let worldID, residentScope: String }
struct PropGenerationInspection { let sha256: String; let bytes: Int }
struct PropGenerationResult { let inspection: PropGenerationInspection }
struct PropGenerationReceipt { enum State { case completed, generating }; let state: State; let result: PropGenerationResult? }
struct PropGenerationRecord {
    let id: UUID
    var context: PropTaskContext?
    var receipt: PropGenerationReceipt?
    var localModelPath: String?
}
@main struct CatalogRegression {
    @MainActor static func main() throws {
        if let index = CommandLine.arguments.firstIndex(of: "--formal-inventory") {
            precondition(CommandLine.arguments.count > index + 3)
            let root = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            let worldID = CommandLine.arguments[index + 2]
            let taskID = UUID(uuidString: CommandLine.arguments[index + 3])!.uuidString
            precondition(UUID(uuidString: worldID) != nil)
            let database = root.appendingPathComponent("gmgn radio/TaskService/tasks.sqlite3").path
            func query(_ sql: String) throws -> Data {
                let process = Process(), pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
                process.arguments = ["-readonly", database, sql]
                process.standardOutput = pipe; process.standardError = Pipe()
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit(); precondition(process.terminationStatus == 0)
                return data
            }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
            var state = try decoder.decode(WorldState.self, from: query("SELECT value FROM world_records WHERE world_id='\(worldID)' AND domain='worlds' AND key='state';"))
            let objectID = "wish-prop-" + taskID.lowercased()
            state.objectStates[objectID] = try decoder.decode(WorldObjectState.self, from: query("SELECT value FROM world_records WHERE world_id='\(worldID)' AND domain='objects' AND key='\(objectID)' AND tombstone=0;"))
            let raw = try JSONSerialization.jsonObject(with: query("SELECT data FROM jobs WHERE id='\(taskID)';")) as! [String: Any]
            let job = raw["job"] as! [String: Any], context = job["context"] as! [String: Any]
            let receipt = job["receipt"] as! [String: Any], result = receipt["result"] as! [String: Any], inspection = result["inspection"] as! [String: Any]
            precondition(receipt["state"] as? String == "completed")
            let task = PropGenerationRecord(id: UUID(uuidString: job["id"] as! String)!,
                context: .init(worldID: context["worldID"] as! String, residentScope: context["residentScope"] as! String),
                receipt: .init(state: .completed, result: .init(inspection: .init(sha256: inspection["sha256"] as! String, bytes: inspection["bytes"] as! Int))),
                localModelPath: job["localModelPath"] as? String)
            let catalog = UnityGeneratedAssetCatalog(root: root, worldID: worldID, residentScope: task.context!.residentScope)
            try catalog.update(state: state, jobs: [task], revision: state.revision)
            precondition((catalog.snapshot()["entries"] as! [[String: Any]]).contains { $0["objectID"] as? String == objectID })
            try catalog.verifyPreparedAsset(state.objectStates[objectID]!.generatedProp!)
            if let fixturePath = ProcessInfo.processInfo.environment["GMGN_ASSET_PROBE_FIXTURE"] {
                let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state.objectStates[objectID]!))
                let fixture: [String: Any] = ["dataRoot": root.path, "worldID": worldID,
                    "catalog": catalog.snapshot(), "state": ["objectStates": [objectID: object]]]
                try JSONSerialization.data(withJSONObject: fixture, options: .sortedKeys).write(to: URL(fileURLWithPath: fixturePath))
            }
            print("PASS: formal SQLite owned sofa + completed task joins actual catalog and exact GLB bytes verify; no formal writes")
            return
        }
        let root = URL(fileURLWithPath: "/explicit-fixture-root"), id = UUID(), hash = String(repeating: "a", count: 64)
        let prop = WorldGeneratedProp(objectID: "object", sourceWishID: id.uuidString,
            assetID: "sha256:" + hash, displayName: "Generated", size: .init(x: 1, y: 1, z: 1), sourceHeight: 1)
        var simulation = WorldSimulation(restoring: .init(revision: 0, worldID: "world", worldTime: .distantPast,
            lastObservedWallTime: .distantPast, weather: .clear,
            agentTransform: .init(position: .init(x: 0, y: 0, z: 0), rotation: .init(x: 0, y: 0, z: 0, w: 1), scale: .init(x: 1, y: 1, z: 1))))
        try simulation.applyPropLayout(.register(prop), expectedLayoutRevision: 0, requestID: "claim")
        let exactPath = root.appendingPathComponent("gmgn radio/TaskService/" + id.uuidString.lowercased() + ".glb").path
        let task = PropGenerationRecord(id: id, context: .init(worldID: "world", residentScope: "scope"),
            receipt: .init(state: .completed, result: .init(inspection: .init(sha256: hash, bytes: 123))), localModelPath: exactPath)
        let catalog = UnityGeneratedAssetCatalog(root: root, worldID: "world", residentScope: "scope")
        func entries() -> [[String: Any]] { catalog.snapshot()["entries"] as! [[String: Any]] }
        // Store construction is not a task snapshot. This is the startup race:
        // only the subsequently received authority jobs authorize the model.
        _ = try catalog.update(state: simulation.state, jobs: [], revision: 1)
        precondition(entries().isEmpty)
        let changed = try catalog.update(state: simulation.state, jobs: [task], revision: 1); precondition(changed)
        precondition(entries().count == 1 && entries()[0]["taskID"] as? String == id.uuidString.lowercased())
        precondition(!FileManager.default.fileExists(atPath: exactPath)) // Building the DTO never reads/hashes a model.
        let generation = catalog.snapshot()["generation"] as! UInt64
        let unchanged = try catalog.update(state: simulation.state, jobs: [task], revision: 1); precondition(!unchanged)
        precondition(catalog.snapshot()["generation"] as! UInt64 == generation)
        var historical = task
        historical.localModelPath = root.appendingPathComponent("gmgn radio/TaskService/" + id.uuidString.uppercased() + ".glb").path
        _ = try catalog.update(state: simulation.state, jobs: [historical], revision: 1)
        precondition(entries().count == 1 && entries()[0]["localModelPath"] as? String == historical.localModelPath)
        var wrongUUID = task
        wrongUUID.localModelPath = root.appendingPathComponent("gmgn radio/TaskService/" + UUID().uuidString + ".glb").path
        _ = try catalog.update(state: simulation.state, jobs: [wrongUUID], revision: 1)
        precondition(entries().isEmpty)
        var wrongScope = task; wrongScope.context = .init(worldID: "other", residentScope: "scope")
        _ = try catalog.update(state: simulation.state, jobs: [wrongScope], revision: 2); precondition(entries().isEmpty)
        var wrongPath = task; wrongPath.localModelPath = "/outside/model.glb"
        _ = try catalog.update(state: simulation.state, jobs: [wrongPath], revision: 2); precondition(entries().isEmpty)
        var missingContext = task; missingContext.context = nil
        _ = try catalog.update(state: simulation.state, jobs: [missingContext], revision: 2); precondition(entries().isEmpty)
        var wrongHash = task; wrongHash.receipt = .init(state: .completed, result: .init(inspection: .init(sha256: String(repeating: "b", count: 64), bytes: 123)))
        _ = try catalog.update(state: simulation.state, jobs: [wrongHash], revision: 2); precondition(entries().isEmpty)
        _ = try catalog.update(state: simulation.state, jobs: [task, task], revision: 2); precondition(entries().isEmpty)
        var generating = task; generating.receipt = .init(state: .generating, result: task.receipt?.result)
        _ = try catalog.update(state: simulation.state, jobs: [generating], revision: 2); precondition(entries().isEmpty)
        _ = try catalog.update(state: simulation.state, jobs: [task], revision: 2); precondition(entries().count == 1)
        let reopened = UnityGeneratedAssetCatalog(root: root, worldID: "world", residentScope: "scope")
        _ = try reopened.update(state: simulation.state, jobs: [task], revision: 2)
        precondition((reopened.snapshot()["entries"] as! [[String: Any]]).count == 1)
        var foreign = simulation.state; foreign.worldID = "other"
        do { _ = try catalog.update(state: foreign, jobs: [task], revision: 3); fatalError("Wrong world accepted") }
        catch UnityGeneratedAssetCatalog.CatalogError.wrongScope {}
        precondition(entries().count == 1) // Failure preserves the last validated projection.
        let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-catalog-" + UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let taskDirectory = fixtureRoot.appendingPathComponent("gmgn radio/TaskService")
        try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
        let data = Data("verified fixture bytes".utf8)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let model = taskDirectory.appendingPathComponent(id.uuidString.lowercased() + ".glb")
        try data.write(to: model)
        let verifiedProp = WorldGeneratedProp(objectID: "verified", sourceWishID: id.uuidString,
            assetID: "sha256:" + digest, displayName: "Fixture", size: .init(x: 1, y: 1, z: 1), sourceHeight: 1)
        var verifiedState = simulation.state
        verifiedState.objectStates = [:]
        var verifiedSimulation = WorldSimulation(restoring: verifiedState)
        try verifiedSimulation.applyPropLayout(.register(verifiedProp), expectedLayoutRevision: verifiedState.layoutRevision, requestID: "fixture")
        let verifiedTask = PropGenerationRecord(id: id, context: task.context,
            receipt: .init(state: .completed, result: .init(inspection: .init(sha256: digest, bytes: data.count))), localModelPath: model.path)
        let verifiedCatalog = UnityGeneratedAssetCatalog(root: fixtureRoot, worldID: "world", residentScope: "scope")
        try verifiedCatalog.update(state: verifiedSimulation.state, jobs: [verifiedTask], revision: 3)
        try verifiedCatalog.verifyPreparedAsset(verifiedProp)
        try Data(repeating: 0, count: data.count).write(to: model)
        do { try verifiedCatalog.verifyPreparedAsset(verifiedProp); fatalError("Modified asset accepted") }
        catch UnityGeneratedAssetCatalog.CatalogError.assetUnverified {}
        try data.write(to: model)
        let redirected = taskDirectory.appendingPathComponent("redirected-fixture.glb")
        try FileManager.default.moveItem(at: model, to: redirected)
        try FileManager.default.createSymbolicLink(at: model, withDestinationURL: redirected)
        do { try verifiedCatalog.verifyPreparedAsset(verifiedProp); fatalError("Redirected asset accepted") }
        catch UnityGeneratedAssetCatalog.CatalogError.assetUnverified {}
        print("PASS: prepared asset reads actual bytes and rejects same-size tampering and symlink redirection")
        print("PASS: actual catalog precise identity/path/hash/scope/completed join, duplicate refusal, cache, recreated instance; projection remains metadata-only")
    }
}

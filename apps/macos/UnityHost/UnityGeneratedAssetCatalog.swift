import Foundation
import CryptoKit
import WorldRuntime

/// Read-only DTO over two existing authorities. No path scans, model writes,
/// duplicate registration, or per-frame file hashing. Renderer rechecks bytes
/// and SHA256 before it loads the exact receipt-authorized task output.
@MainActor final class UnityGeneratedAssetCatalog {
    private let worldID: String
    private let residentScope: String
    private let taskRoot: URL
    private var generation: UInt64 = 0
    private var content: Data?
    private var cached: [String: Any]

    init(root: URL, worldID: String, residentScope: String) {
        self.worldID = worldID; self.residentScope = residentScope
        taskRoot = root.standardizedFileURL.appendingPathComponent("gmgn radio/TaskService", isDirectory: true)
        cached = ["worldID": worldID, "revision": UInt64(0), "generation": UInt64(0), "entries": [[String: Any]]()]
    }

    /// Invoke after adopting a real world snapshot or receiving a task-store
    /// onChange event, not from the 50ms renderer snapshot poll.
    @discardableResult
    func update(state: WorldState, jobs: [PropGenerationRecord], revision: UInt64) throws -> Bool {
        guard state.worldID == worldID, !worldID.isEmpty, !residentScope.isEmpty else {
            throw CatalogError.wrongScope
        }
        // Duplicate task identities are invalid input, not "take first".
        var taskByID: [UUID: PropGenerationRecord] = [:]
        var duplicateTasks: Set<UUID> = []
        for job in jobs {
            if taskByID.updateValue(job, forKey: job.id) != nil { duplicateTasks.insert(job.id) }
        }
        let owned = state.objectStates.keys.sorted().compactMap { id -> (String, WorldGeneratedProp)? in
            guard state.propTombstones?[id] == nil, let prop = state.objectStates[id]?.generatedProp,
                  prop.isValid, prop.objectID == id else { return nil }
            return (id, prop)
        }
        // A single source wish may not be used to authorize multiple object IDs.
        var wishCounts: [UUID: Int] = [:]
        for (_, prop) in owned {
            if let identity = UUID(uuidString: prop.sourceWishID) { wishCounts[identity, default: 0] += 1 }
        }
        var entries: [[String: Any]] = []
        for (objectID, prop) in owned {
            guard let wishID = UUID(uuidString: prop.sourceWishID), wishCounts[wishID] == 1,
                  !duplicateTasks.contains(wishID),
                  let task = taskByID[wishID], task.context?.worldID == worldID,
                  task.context?.residentScope == residentScope,
                  task.receipt?.state == .completed, let result = task.receipt?.result,
                  let path = task.localModelPath else { continue }
            let inspection = result.inspection
            let hash = inspection.sha256.lowercased()
            guard hash.count == 64, hash.allSatisfy({ $0.isASCII && $0.isHexDigit }),
                  inspection.bytes > 0, inspection.bytes <= 32 * 1024 * 1024,
                  prop.assetID == "sha256:" + hash else { continue }
            let expected = taskRoot.appendingPathComponent(task.id.uuidString.lowercased() + ".glb").path
            // Historical Swift downloads used UUID.uuidString (uppercase),
            // while Rust's newer UUID outputs are lowercase. Both are exact
            // task identities, not a case-insensitive arbitrary path allowance.
            let historical = taskRoot.appendingPathComponent(task.id.uuidString.uppercased() + ".glb").path
            guard path == expected || path == historical else { continue }
            entries.append(["objectID": objectID, "sourceWishID": prop.sourceWishID,
                "taskID": task.id.uuidString.lowercased(), "assetID": prop.assetID,
                "sha256": hash, "bytes": inspection.bytes, "localModelPath": path])
        }
        let next: [String: Any] = ["worldID": worldID, "revision": revision, "entries": entries]
        let encoded = try JSONSerialization.data(withJSONObject: next, options: .sortedKeys)
        guard content != encoded else { return false }
        content = encoded; generation &+= 1
        cached = next; cached["generation"] = generation
        return true
    }
    /// Value-type cached metadata only; no filesystem IO or hashing occurs.
    func snapshot() -> [String: Any] { cached }
    @discardableResult
    func verifyPreparedAsset(_ prop: WorldGeneratedProp) throws -> URL {
        guard let entry = (cached["entries"] as? [[String: Any]])?.first(where: { $0["objectID"] as? String == prop.objectID }),
              entry["assetID"] as? String == prop.assetID,
              let path = entry["localModelPath"] as? String,
              let bytes = entry["bytes"] as? Int, let hash = entry["sha256"] as? String else {
            throw CatalogError.assetUnverified
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.resolvingSymlinksInPath().path == url.path else { throw CatalogError.assetUnverified }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue == bytes else { throw CatalogError.assetUnverified }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == hash else {
            throw CatalogError.assetUnverified
        }
        return url
    }
    enum CatalogError: Error { case wrongScope, assetUnverified }
}

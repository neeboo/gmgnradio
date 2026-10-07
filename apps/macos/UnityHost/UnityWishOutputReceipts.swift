import Foundation
import CoreFoundation

/// Render evidence is deliberately process-local. Reopening a world requires a
/// new projection and frame; a durable generation receipt cannot supply either.
struct UnityWishOutputReceipts {
    let sessionID: String
    private struct Capability: Equatable {
        let worldID: String
        let wishID: String
        let objectID: String
        let modelPath: String
        let projectionID: String
    }
    private struct Receipt {
        let sequence: UInt64
        let rendered: Bool
    }
    private var capabilities: [String: Capability] = [:]
    private var receipts: [String: Receipt] = [:]

    init(sessionID: String = UUID().uuidString) { self.sessionID = sessionID }

    mutating func update(worldID: String, entries: [[String: Any]]) {
        var next: [String: Capability] = [:]
        var duplicates = Set<String>()
        for entry in entries {
            guard entry["worldID"] as? String == worldID,
                  entry["stage"] as? String == "ready",
                  entry["projectionSessionID"] as? String == sessionID,
                  let wishID = entry["sourceWishID"] as? String, UUID(uuidString: wishID) != nil,
                  let objectID = entry["objectID"] as? String, !objectID.isEmpty,
                  let path = entry["localModelPath"] as? String, !path.isEmpty,
                  let projectionID = entry["projectionID"] as? String, UUID(uuidString: projectionID) != nil else { continue }
            if next[objectID] != nil { duplicates.insert(objectID) }
            next[objectID] = Capability(worldID: worldID, wishID: wishID, objectID: objectID,
                                        modelPath: path, projectionID: projectionID)
        }
        for objectID in duplicates { next.removeValue(forKey: objectID) }
        receipts = receipts.filter { next[$0.key] != nil && next[$0.key] == capabilities[$0.key] }
        capabilities = next
    }

    @discardableResult
    mutating func accept(_ value: [String: Any]) -> Bool {
        guard value["op"] as? String == "wish.output.projected",
              value["projectionSessionID"] as? String == sessionID,
              let objectID = value["objectID"] as? String, let capability = capabilities[objectID],
              value["worldID"] as? String == capability.worldID,
              value["wishID"] as? String == capability.wishID,
              value["modelPath"] as? String == capability.modelPath,
              value["projectionID"] as? String == capability.projectionID,
              let rawRendered = value["rendered"] as? NSNumber,
              CFGetTypeID(rawRendered) == CFBooleanGetTypeID(),
              let sequence = Self.positiveInteger(value["receiptSequence"]) else { return false }
        let rendered = rawRendered.boolValue
        if rendered && Self.positiveInteger(value["renderedFrame"]) == nil { return false }
        if let previous = receipts[objectID] {
            guard sequence >= previous.sequence else { return false }
            if sequence == previous.sequence { return rendered == previous.rendered }
        }
        receipts[objectID] = Receipt(sequence: sequence, rendered: rendered)
        return true
    }

    func isRendered(objectID: String, wishID: String, modelPath: String) -> Bool {
        guard let capability = capabilities[objectID], capability.wishID == wishID,
              capability.modelPath == modelPath else { return false }
        return receipts[objectID]?.rendered == true
    }

    var renderedObjectIDs: [String] { receipts.filter { $0.value.rendered }.keys.sorted() }

    private static func positiveInteger(_ value: Any?) -> UInt64? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, value.doubleValue > 0,
              value.doubleValue <= 9_007_199_254_740_991,
              value.doubleValue.rounded() == value.doubleValue else { return nil }
        return value.uint64Value
    }
}

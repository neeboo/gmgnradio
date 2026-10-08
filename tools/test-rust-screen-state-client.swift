import Foundation
import simd

/// Real private HTTP/Codable acceptance. No renderer, AVPlayer, provider or formal paths.
@main struct ScreenStateAcceptance {
    struct Legacy: Codable { let worlds: [String: WorldScreenPersistence.Record] }
    static func definition(_ id: String, note: String) -> WorldScreenDefinition {
        WorldScreenDefinition(objectID: id, source: .calibrated,
            quad: WorldScreenQuad(center: SIMD3<Float>(0, 1, 0), yaw: 0, pitch: .pi / 2, halfWidth: 1, halfHeight: 0.5), note: note)
    }
    static func main() async throws {
        guard CommandLine.arguments.count == 4 else { fatalError("Provide private endpoint JSON, private ScreenState.json and seed|reopen") }
        let endpoint = URL(fileURLWithPath: CommandLine.arguments[1])
        let legacy = URL(fileURLWithPath: CommandLine.arguments[2])
        let phase = CommandLine.arguments[3]
        let persistence = WorldScreenPersistence(fileURL: legacy, endpointFile: endpoint)
        if phase == "reopen" {
            let record = try await persistence.record(worldID: "fixture-world")
            precondition(record.definitions["tv"]?.note == "direct-authority")
            precondition(record.definitions["other"]?.note == "parallel-other")
            precondition(record.contents["tv"]?.url == "https://www.youtube.com/watch?v=bbbbbbbbbbb&list=PLfixture")
            print("PASS: daemon/Swift restart restores confirmed SQLite metadata without replaying legacy import")
            return
        }
        precondition(phase == "seed" && legacy.lastPathComponent == "ScreenState.json")
        let initial = WorldScreenPersistence.Record(definitions: ["tv":definition("tv", note: "legacy-original")],
            contents: ["tv":WorldScreenContent(objectID: "tv", kind: .nativeLink,
                url: "https://www.youtube.com/watch?v=aaaaaaaaaaa&list=PLfixture", title: "legacy")])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let legacyBytes = try encoder.encode(Legacy(worlds: ["fixture-world":initial]))
        try legacyBytes.write(to: legacy, options: .atomic)
        let imported = try await persistence.record(worldID: "fixture-world")
        precondition(imported == initial)
        let updated = WorldScreenContent(objectID: "tv", kind: .nativeLink,
            url: "https://www.youtube.com/watch?v=bbbbbbbbbbb&list=PLfixture", title: "updated")
        try await persistence.setContent(updated, objectID: "tv", worldID: "fixture-world")
        async let first: Void = persistence.setDefinition(definition("tv", note: "parallel-tv"), objectID: "tv", worldID: "fixture-world")
        async let second: Void = persistence.setDefinition(definition("other", note: "parallel-other"), objectID: "other", worldID: "fixture-world")
        _ = try await (first, second)
        let confirmed = try await persistence.record(worldID: "fixture-world")
        let direct = RustScreenStateClient(endpointFile: endpoint)
        let current = try await direct.read(worldID: "fixture-world")
        let data = try encoder.encode(definition("tv", note: "direct-authority"))
        let changed = try await direct.mutate(worldID: "fixture-world", objectID: "tv", expectedRevision: current.revision,
            requestID: "stable-direct", operation: "definition", value: data)
        let duplicate = try await direct.mutate(worldID: "fixture-world", objectID: "tv", expectedRevision: current.revision,
            requestID: "stable-direct", operation: "definition", value: data)
        precondition(duplicate.revision == changed.revision)
        do {
            try await persistence.setDefinition(definition("tv", note: "stale-write"), objectID: "tv", worldID: "fixture-world")
            fatalError("Stale projection cannot overwrite authority")
        } catch RustScreenStateError.daemon(let code) { precondition(code == "screen_state_revision_conflict") }
        let preserved = try await persistence.record(worldID: "fixture-world")
        precondition(preserved == confirmed, "CAS error must preserve confirmed cache")
        let bytesAfterMutation = try Data(contentsOf: legacy)
        precondition(bytesAfterMutation == legacyBytes, "Production import/mutation must never write old JSON")
        print("PASS: actual Codable legacy import → SQLite, async serialized CAS, exact duplicate, stale-write fail-closed, legacy bytes unchanged")
    }
}

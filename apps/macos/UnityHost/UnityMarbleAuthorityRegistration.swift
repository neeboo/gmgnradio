import Foundation
import WorldRuntime

/// Readback only. The Marble Rust receipt owns seed creation and world import.
actor UnityMarbleAuthorityRegistration {
    struct Services: Sendable {
        var snapshot: @Sendable () throws -> WorldAuthorityRecord?
        var facts: @Sendable (UInt64) throws -> (facts: [WorldAuthorityFact], nextCursor: UInt64)
        init(client: WorldAuthorityClient) {
            snapshot = { try client.snapshot() }; facts = { try client.facts(after: $0) }
        }
        init(snapshot: @escaping @Sendable () throws -> WorldAuthorityRecord?,
             facts: @escaping @Sendable (UInt64) throws -> (facts: [WorldAuthorityFact], nextCursor: UInt64)) {
            self.snapshot = snapshot; self.facts = facts
        }
    }
    private let services: @Sendable (String) -> Services
    init(services: @escaping @Sendable (String) -> Services) { self.services = services }
    func register(_ package: BundledLivingWorldPackage) async throws -> Bool {
        let service = services(package.manifest.worldID)
        return try await Task.detached {
            try Task.checkCancellation()
            let bytes = try Data(contentsOf: package.packageRoot.appendingPathComponent("world.json"))
            guard try JSONDecoder().decode(WorldManifest.self, from: bytes) == package.manifest,
                WorldPackageValidator().validate(package.manifest, packageRoot: package.packageRoot).isEmpty,
                try UnityMarbleRuntimeDocument.load(package: package) != nil,
                let record = try service.snapshot(), record.state.worldID == package.manifest.worldID else {
                throw UnityMarbleError.registrationRejected
            }
            var cursor: UInt64 = 0, imported = false, stateMatched = false
            while cursor < record.boundarySeq {
                try Task.checkCancellation()
                let page = try service.facts(cursor)
                guard !page.facts.isEmpty, page.nextCursor > cursor else { throw UnityMarbleError.registrationRejected }
                for fact in page.facts where fact.sequence <= record.boundarySeq && fact.subjectDomain == "worlds" && fact.subjectKey == "state" {
                    if fact.kind == "world.imported" {
                        guard fact.payload["packageID"] as? String == package.manifest.packageID,
                            fact.payload["packageVersion"] as? String == package.manifest.packageVersion else {
                            throw UnityMarbleError.packageConflict
                        }
                        imported = true
                    }
                    if ["world.imported", "world.stateCommitted"].contains(fact.kind),
                        fact.revision == record.recordRevision, fact.payload["stateSha256"] as? String == record.stateSha256 {
                        stateMatched = true
                    }
                }
                cursor = page.nextCursor
            }
            return imported && stateMatched
        }.value
    }
}

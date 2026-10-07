import CryptoKit
import Foundation
import WorldRuntime

/// A new generated world may be imported exactly once; established records are
/// read and verified, never replaced. Import provenance lives in authoritative
/// world.imported facts (world_snapshot intentionally does not expose package ID).
actor UnityMarbleAuthorityRegistration {
    struct Services: Sendable {
        var snapshot: @Sendable () throws -> WorldAuthorityRecord?
        var importState: @Sendable (String, String, String, String) throws -> WorldAuthorityCommitResult
        var facts: @Sendable (UInt64) throws -> (facts: [WorldAuthorityFact], nextCursor: UInt64)
        init(client: WorldAuthorityClient) {
            snapshot = { try client.snapshot() }
            importState = { try client.importLegacy(packageID: $0, packageVersion: $1, rawText: $2, sha256: $3) }
            facts = { try client.facts(after: $0) }
        }
        init(snapshot: @escaping @Sendable () throws -> WorldAuthorityRecord?,
             importState: @escaping @Sendable (String, String, String, String) throws -> WorldAuthorityCommitResult,
             facts: @escaping @Sendable (UInt64) throws -> (facts: [WorldAuthorityFact], nextCursor: UInt64)) {
            self.snapshot = snapshot; self.importState = importState; self.facts = facts
        }
    }
    private struct Seed: Codable {
        let packageID: String
        let packageVersion: String
        let manifestSHA256: String
        let stateJSON: String
        let preImageSHA256: String
    }
    private let root: URL
    private let services: (@Sendable (String) -> Services)?
    init(root: URL, services: (@Sendable (String) -> Services)? = nil) { self.root = root; self.services = services }

    func register(_ package: BundledLivingWorldPackage) throws -> Bool {
        try Task.checkCancellation()
        let manifestURL = package.packageRoot.appendingPathComponent("world.json")
        let manifestData = try Data(contentsOf: manifestURL)
        guard try JSONDecoder().decode(WorldManifest.self, from: manifestData) == package.manifest,
              WorldPackageValidator().validate(package.manifest, packageRoot: package.packageRoot).isEmpty,
              try UnityMarbleRuntimeDocument.load(package: package) != nil else { throw UnityMarbleError.invalidPackage }
        let manifestHash = UnityMarblePackageBuilder.digest(manifestData)
        let seed = try seed(package: package, manifestHash: manifestHash)
        let service: Services
        if let services { service = services(package.manifest.worldID) }
        else {
            let endpoint = WorldAuthorityEndpoint(applicationSupportBase: root)
            service = Services(client: WorldAuthorityClient(worldID: package.manifest.worldID,
                endpointFile: endpoint.endpointFile, helperPath: endpoint.helperPath, allowsLaunching: true))
        }
        let before = try service.snapshot()
        if let before {
            // Existing state may have legitimately evolved. Verify its current
            // authoritative digest against its commit fact and immutable package
            // import lineage, without resetting it. Swift Date/Float reencoding
            // is not Rust canonical JSON and must not invent a competing hash.
            try validateRecord(before, worldID: package.manifest.worldID)
            guard try provenance(service: service, seed: seed, record: before) else { throw UnityMarbleError.packageConflict }
            return true
        }
        try Task.checkCancellation()
        let receipt = try service.importState(seed.packageID, seed.packageVersion, seed.stateJSON, seed.preImageSHA256)
        guard isDigest(receipt.stateSha256) else { throw UnityMarbleError.registrationRejected }
        try Task.checkCancellation()
        guard let after = try service.snapshot() else { throw UnityMarbleError.registrationRejected }
        try validateRecord(after, worldID: package.manifest.worldID)
        guard after.recordRevision >= receipt.revision, after.boundarySeq >= receipt.sequence,
              after.stateSha256 == receipt.stateSha256,
              let document = try JSONSerialization.jsonObject(with: Data(seed.stateJSON.utf8)) as? [String: Any],
              after.state == (try WorldAuthorityClient.decodeState(document)),
              try provenance(service: service, seed: seed, record: after) else { throw UnityMarbleError.registrationRejected }
        return true
    }
    private func validateRecord(_ record: WorldAuthorityRecord, worldID: String) throws {
        guard record.state.worldID == worldID,
              isDigest(record.stateSha256) else { throw UnityMarbleError.registrationRejected }
    }
    private func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private func provenance(service: Services, seed: Seed, record: WorldAuthorityRecord) throws -> Bool {
        let boundary = record.boundarySeq
        var cursor: UInt64 = 0
        var packageMatched = false, stateMatched = false
        while cursor < boundary {
            try Task.checkCancellation()
            let page = try service.facts(cursor)
            guard !page.facts.isEmpty, page.nextCursor > cursor else { return false }
            for fact in page.facts where fact.sequence <= boundary && fact.subjectDomain == "worlds" && fact.subjectKey == "state" {
                if fact.kind == "world.imported" {
                    guard fact.payload["packageID"] as? String == seed.packageID,
                          fact.payload["packageVersion"] as? String == seed.packageVersion,
                          fact.payload["preImageSha256"] as? String == seed.preImageSHA256,
                          let sourceHash = fact.payload["sourceSha256"] as? String, isDigest(sourceHash) else { return false }
                    packageMatched = true
                }
                if ["world.imported", "world.stateCommitted"].contains(fact.kind),
                   fact.revision == record.recordRevision, fact.payload["stateSha256"] as? String == record.stateSha256 {
                    stateMatched = true
                }
            }
            cursor = page.nextCursor
        }
        return packageMatched && stateMatched
    }
    private func seed(package: BundledLivingWorldPackage, manifestHash: String) throws -> Seed {
        let directory = root.appendingPathComponent("gmgn radio/WorldRegistrations", isDirectory: true)
        let path = directory.appendingPathComponent(UnityMarblePackageBuilder.digest(Data(package.manifest.worldID.utf8)) + ".json")
        if FileManager.default.fileExists(atPath: path.path) {
            let seed = try JSONDecoder().decode(Seed.self, from: Data(contentsOf: path))
            guard seed.packageID == package.manifest.packageID, seed.packageVersion == package.manifest.packageVersion,
                  seed.manifestSHA256 == manifestHash,
                  WorldAuthorityClient.sha256Hex(seed.stateJSON) == seed.preImageSHA256,
                  let document = try JSONSerialization.jsonObject(with: Data(seed.stateJSON.utf8)) as? [String: Any],
                  try WorldAuthorityClient.decodeState(document).worldID == package.manifest.worldID else { throw UnityMarbleError.packageConflict }
            return seed
        }
        // Persist the initial source bytes before import; retries and restart
        // recovery keep the same dates/hash rather than creating new content.
        let state = WorldSimulation(manifest: package.manifest, startedAt: Date()).state
        let document = try WorldAuthorityClient.encodeDocument(state)
        let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        guard let raw = String(data: data, encoding: .utf8) else { throw UnityMarbleError.invalidPackage }
        let seed = Seed(packageID: package.manifest.packageID, packageVersion: package.manifest.packageVersion,
            manifestSHA256: manifestHash, stateJSON: raw, preImageSHA256: WorldAuthorityClient.sha256Hex(raw))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(seed).write(to: path, options: .atomic)
        return seed
    }
}

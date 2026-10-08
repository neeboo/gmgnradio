import Foundation
import CryptoKit

/// Authenticated geometry transport only. The Marble service must inject its
/// existing transport; this client has no endpoint, helper launch or root default.
/// Native decoding and physics produce facts. Rust owns sampling and selection.
actor RustMarbleGeometryClient {
    typealias Call = @Sendable (String, Data) throws -> Data
    struct SampleRequest: Encodable, Sendable { let pointCount: Int }
    struct SamplePlan: Decodable, Sendable {
        let sourcePointCount: Int
        let sampleStride: Int
        let indices: [Int]
    }
    struct Probe: Decodable, Sendable {
        struct Capsule: Decodable, Sendable { let radius: Float; let height: Float }
        let key: String
        let position: [Float]
        let capsule: Capsule
    }
    struct Measurement: Sendable {
        let groundHeight: Float?
        let canOccupy: Bool?
    }
    private struct Page: Decodable, Sendable {
        let planHash: String
        let probes: [Probe]
        let offset: Int
        let nextOffset: Int?
    }
    private let call: Call

    init(call: @escaping Call) { self.call = call }

    /// A byte-level shared service transport. No host paths enter geometry RPC.
    private func raw(_ method: String, bytes: Data) async throws -> Data {
        let call = self.call
        return try await Task.detached { try call(method, bytes) }.value
    }

    func firstPage(geometryManifest: Data, pageSize: Int = 64) async throws -> Data {
        let bytes = try await Task.detached {
            let geometry = try JSONSerialization.jsonObject(with:geometryManifest)
            return try JSONSerialization.data(withJSONObject:["geometry":geometry,"offset":0,"limit":pageSize],options:[.sortedKeys])
        }.value
        return try await raw("marble_geometry_plan",bytes:bytes)
    }

    /// Native immutable staging under the explicitly injected service blob root.
    /// Rust's existing blob_put owns path/hash validation and the sole DB record.
    func registerFact(_ data: Data, blobRoot: URL) async throws -> String {
        let staged = try await Task.detached {
            let sha = SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
            try FileManager.default.createDirectory(at:blobRoot,withIntermediateDirectories:true)
            let path = blobRoot.appendingPathComponent(sha + ".json")
            if FileManager.default.fileExists(atPath:path.path) {
                guard try Data(contentsOf:path) == data else { throw WorldAuthorityError.invalidResponse }
            } else { try data.write(to:path,options:.atomic) }
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
            let params: [String:Any] = ["sha256":sha,"localPath":path.path,"mime":"application/json"]
            return (sha,try JSONSerialization.data(withJSONObject:params,options:[.sortedKeys]))
        }.value
        let result = try await raw("world_blob_put",bytes:staged.1)
        struct Receipt: Decodable { let sha256: String }
        guard try JSONDecoder().decode(Receipt.self,from:result).sha256 == staged.0 else { throw WorldAuthorityError.invalidResponse }
        return staged.0
    }

    /// Native callbacks report physics facts and register the exact fact bytes
    /// under the service's existing private blob root. Selection stays in Rust.
    /// Only Rust's incomplete-proof error authorizes fetching another page.
    func resolvePaged(
        geometryManifest: Data, pageSize: Int = 64, firstPage: Data? = nil,
        measure: @Sendable (Probe) async throws -> Measurement,
        registerFact: @Sendable (Data) async throws -> String
    ) async throws -> Data {
        var offset = 0, count = 0
        var planHash: String?
        var chunks: [String] = []
        while true {
            try Task.checkCancellation()
            let expectedHash = planHash, requestedOffset = offset
            let planBytes = try await Task.detached {
                let geometry = try JSONSerialization.jsonObject(with: geometryManifest)
                var value: [String: Any] = ["geometry":geometry,"offset":requestedOffset,"limit":pageSize]
                value["planHash"] = expectedHash
                return try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])
            }.value
            let pageData: Data
            if offset == 0, let firstPage { pageData = firstPage }
            else { pageData = try await raw("marble_geometry_plan", bytes: planBytes) }
            let page = try JSONDecoder().decode(Page.self, from: pageData)
            guard page.offset == offset, !page.probes.isEmpty,
                  planHash == nil || planHash == page.planHash else { throw WorldAuthorityError.invalidResponse }
            planHash = page.planHash
            var facts: [(Probe,Measurement)] = []
            for probe in page.probes {
                try Task.checkCancellation()
                facts.append((probe,try await measure(probe)))
            }
            let currentCount = count, actualFacts = facts
            let factBytes = try await Task.detached {
                let rows: [[String:Any]] = actualFacts.map { probe,fact in
                    ["key":probe.key,"position":probe.position,
                     "groundHeight":fact.groundHeight.map { $0 as Any } ?? NSNull(),
                     "canOccupy":fact.canOccupy.map { $0 as Any } ?? NSNull()]
                }
                return try JSONSerialization.data(withJSONObject:["offset":currentCount,"measurements":rows],options:[.sortedKeys])
            }.value
            chunks.append(try await registerFact(factBytes))
            count += facts.count
            let actualCount = count, actualChunks = chunks, hash = page.planHash
            let resolveBytes = try await Task.detached {
                let geometry = try JSONSerialization.jsonObject(with:geometryManifest)
                return try JSONSerialization.data(withJSONObject:["geometry":geometry,"planHash":hash,
                    "measurementCount":actualCount,"measurementChunks":actualChunks],options:[.sortedKeys])
            }.value
            do { return try await raw("marble_geometry_resolve",bytes:resolveBytes) }
            catch WorldAuthorityError.daemon("marble_geometry_incomplete_proof") {
                guard let next = page.nextOffset, next > offset else { throw WorldAuthorityError.invalidResponse }
                offset = next
            }
        }
    }

    func samplePlan(pointCount: Int) async throws -> SamplePlan {
        try await request("marble_geometry_sample_plan", input: SampleRequest(pointCount: pointCount), output: SamplePlan.self)
    }

    /// Encoding, HTTP and response decoding all run off the actor/UI executor.
    /// Input must refer to service-verified geometry facts, not model arguments.
    private func request<Input: Encodable & Sendable, Output: Decodable & Sendable>(
        _ method: String, input: Input, output: Output.Type
    ) async throws -> Output {
        let call = self.call
        return try await Task.detached {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let bytes = try encoder.encode(input)
            let response = try call(method, bytes)
            return try JSONDecoder().decode(output, from: response)
        }.value
    }

    func samplePlan<Input: Encodable & Sendable, Output: Decodable & Sendable>(
        _ input: Input, as output: Output.Type
    ) async throws -> Output {
        try await request("marble_geometry_sample_plan", input: input, output: output)
    }

    func plan<Input: Encodable & Sendable, Output: Decodable & Sendable>(
        _ input: Input, as output: Output.Type
    ) async throws -> Output {
        try await request("marble_geometry_plan", input: input, output: output)
    }

    func resolve<Input: Encodable & Sendable, Output: Decodable & Sendable>(
        _ input: Input, as output: Output.Type
    ) async throws -> Output {
        try await request("marble_geometry_resolve", input: input, output: output)
    }
}

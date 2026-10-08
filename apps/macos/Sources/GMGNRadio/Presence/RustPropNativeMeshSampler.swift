import Foundation
import CryptoKit
import WorldRuntime

/// Raw loader evidence only. Attachment slots and asset-loaded state must come
/// from the actual renderer; this sampler cannot infer either from a filename.
enum RustPropNativeMeshSampler {
    struct Sample: Sendable {
        let sha256: String
        let trianglesJSON: Data
        let modelURL: URL
    }
    static func sample(modelURL: URL, transform: WorldMeshTransform = WorldMeshTransform()) async throws -> Sample {
        try await Task.detached(priority: .utility) {
            let bytes = try Data(contentsOf: modelURL, options: .mappedIfSafe)
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let mesh = try GLBColliderDecoder().decode(data: bytes, transform: transform)
            func vector(_ value: SIMD3<Float>) -> [Float] { [value.x,value.y,value.z] }
            let triangles = mesh.map { [vector($0.first),vector($0.second),vector($0.third)] }
            return Sample(sha256:digest, trianglesJSON:try JSONEncoder().encode(triangles), modelURL:modelURL)
        }.value
    }
}

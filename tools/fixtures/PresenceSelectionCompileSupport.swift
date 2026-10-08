import Foundation
// DTO-only compile support. These stubs must never supply an authority response.
struct PresencePackage: Sendable {
    struct Manifest: Sendable { let id: String; let engine: PresenceEngine; let entry: String }
    let manifest: Manifest; let installPath: String?; let isBuiltIn: Bool; let rendererAvailable: Bool
}
enum PresenceEngine: String, Sendable { case orb, vrm, pmx, live2d }
struct StageMotionAsset: Sendable {
    let id: String; let format: MotionFormat; let url: URL?; let loop: Bool
}
enum MotionFormat: String, Sendable { case procedural, vmd, vrma }
enum WorldAuthorityEndpoint {
    static func taskServiceRoot(applicationSupportBase: URL? = nil) -> URL { URL(fileURLWithPath: "/unused-fixture-endpoint") }
}
enum E2ERuntime { static var applicationSupportBase: URL? { nil } }
#if !PRESENCE_REAL_HTTP
final class TaskdHTTPAuthorityClient: @unchecked Sendable {
    init(endpointFile: String, helperPath: String, allowsLaunching: Bool, timeout: Double) {}
    func call(method: String, params: [String: Any]) throws -> [String: Any] {
        throw RustPresenceSelectionClient.SelectionError.unavailable
    }
}
#endif

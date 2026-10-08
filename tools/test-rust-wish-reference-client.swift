import Foundation

// Native effect boundary doubles only. Production reference handlers, client,
// diagnosis, HTTP/error mapping and Rust claimed-run checks execute unchanged.
struct PropGenerationSource { let author: String; let license: String }
struct ResidentImageAttachment { let id: UUID; let url: URL; let displayName: String }
enum WishMachineError: Error { case unauthorized, consumedAuthorization, wrongScope, conflictingCall, imageLimitReached, unavailable }
enum LeafError: Error { case forbidden }
struct ResidentWebImageDownloader {
    struct Response { let data: Data; let mimeType: String }
    func fetchPublicData(_ url: URL, maximumBytes: Int) async throws -> Response { throw LeafError.forbidden }
    func download(_ url: URL) async throws -> Data { throw LeafError.forbidden }
}
@MainActor final class WishMachineCoordinator {
    var registrations = 0
    func registerWebReference(_ attachment: ResidentImageAttachment, imageURL: URL, authorizationID: UUID,
                              worldID: String, residentScope: String, source: PropGenerationSource) async throws -> Bool {
        registrations += 1; throw LeafError.forbidden
    }
}
struct WorldAuthorityEndpoint {
    static func taskServiceRoot() -> URL { fatalError("Fixture forbids default application-support access") }
}
final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
@main @MainActor struct ReferenceAcceptance {
    static func payload(_ result: RealtimeDJToolResult) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: result.resultJSON) as! [String: Any]
    }
    static func main() async throws {
        let endpoint = CommandLine.arguments[1]
        let transport = TaskdHTTPAuthorityClient(endpointFile: endpoint, helperPath: "/fixture-no-helper", allowsLaunching: false, timeout: 5)
        let rpc = Counter(), nativeLeaves = Counter()
        let client = RustWishReferenceClient { method, data in
            rpc.increment()
            return try JSONSerialization.data(withJSONObject: transport.call(method: method,
                params: JSONSerialization.jsonObject(with: data) as! [String: Any]))
        }
        let coordinator = WishMachineCoordinator()
        let reference = ResidentWishReferenceTools(coordinator: coordinator, authorizationID: UUID(),
            worldID: "private-reference", residentScope: "fixture-scope", isCurrent: { true },
            fetcher: .init(fetchPublicData: { _, _ in nativeLeaves.increment(); throw LeafError.forbidden },
                           download: { _ in nativeLeaves.increment(); throw LeafError.forbidden }),
            referenceClient: client)
        let tools = reference.tools
        let search = tools.first { $0.name == "search_wish_reference_images" }!
        let register = tools.first { $0.name == "register_wish_reference_image" }!
        precondition(search.validate(["query": "red chair"]))
        precondition(!search.validate(["query": 4]))
        precondition(!search.validate(["query": ["nested": "chair"]]))
        precondition(!search.validate(["query": "red chair", "api_key": "not-a-provider-key"]))
        precondition(register.validate(["image_url": "https://example.org/chair.png", "display_name": "chair"]))
        precondition(!register.validate(["image_url": "https://user:pass@example.org/chair.png", "display_name": "chair"]))
        let absent = await search.handle("no-claim", Data("{\"query\":\"red chair\"}".utf8))
        precondition(absent.isError && rpc.value == 0)
        for (tool, call, arguments) in [(search, "search-claim-negative", ["query": "red chair"]),
                                        (register, "register-claim-negative", ["image_url": "https://example.org/chair.png", "display_name": "chair"])] {
            // Explicitly unclaimed identity: it must be rejected by the REAL Rust
            // ledger before any Commons fetch or native download is possible.
            let claim = ResidentWorldToolSession.RustDispatchAuthority(worldID: "private-reference", residentScope: "fixture-scope",
                hostSessionID: "fixture-host", runID: "not-claimed", callID: call, operationID: "not-authorized", toolName: tool.name)
            let data = try JSONSerialization.data(withJSONObject: arguments)
            let result = await ResidentWorldToolSession.$rustDispatchAuthority.withValue(claim) {
                await tool.handle(call, data)
            }
            precondition(result.isError)
            let actual = try payload(result)
            precondition(actual["code"] as? String == "stale_wish_reference_session", "Production HTTP daemon error must retain its real reference code")
        }
        precondition(rpc.value == 2 && nativeLeaves.value == 0 && coordinator.registrations == 0)
        print("PASS: actual reference tools/client -> private Rust claimed-ledger negatives; typed queries and real daemon codes preserved; zero native downloads/registrations")
    }
}

import Foundation

struct PropGenerationSource { let author: String; let license: String }
struct ResidentImageAttachment { let id: UUID; let url: URL; let displayName: String }
enum WishMachineError: Error { case unauthorized, consumedAuthorization, wrongScope, conflictingCall, imageLimitReached, unavailable }
enum LeafError: Error { case forbidden }
struct ResidentWebImageDownloader {
    struct Response { let data: Data; let mimeType: String }
    func fetchPublicData(_ url: URL, maximumBytes: Int) async throws -> Response { throw LeafError.forbidden }
    func download(_ url: URL) async throws -> Data { throw LeafError.forbidden }
}
struct WorldAuthorityEndpoint {
    static func taskServiceRoot() -> URL { fatalError("No formal application data access") }
}
// The coordinator boundary writes a real wish_control command and consumes its
// actual receipt. It never fabricates a successful attachment registration.
@MainActor final class WishMachineCoordinator {
    let transport: TaskdHTTPAuthorityClient
    let session: String
    var revision: Int
    var registrations = 0
    init(_ transport: TaskdHTTPAuthorityClient, session: String) throws {
        self.transport=transport;self.session=session
        revision=try transport.call(method:"wish_control_open",params:["ownerID":"positive-fixture","hostSessionID":session])["revision"] as! Int
    }
    func registerWebReference(_ attachment: ResidentImageAttachment, imageURL: URL, authorizationID: UUID,
                              worldID: String, residentScope: String, source: PropGenerationSource) async throws -> Bool {
        let receipt=try transport.call(method:"wish_control_command",params:[
            "ownerID":"positive-fixture","hostSessionID":session,"expectedRevision":revision,
            "command":"register_web_reference","worldID":worldID,"residentScope":residentScope,
            "authorizationID":authorizationID.uuidString,
            "attachment":["id":attachment.id.uuidString,"url":attachment.url.absoluteString,"displayName":attachment.displayName],
            "imageURL":imageURL.absoluteString,"source":["author":source.author,"license":source.license]])
        revision=receipt["revision"] as! Int
        precondition((receipt["result"] as? [String:Any])?["attachmentID"] as? String == attachment.id.uuidString)
        registrations += 1
        return true
    }
}
final class Counter: @unchecked Sendable {
    private let lock=NSLock(); private var count=0
    func increment(){lock.withLock {count += 1}}
    var value:Int {lock.withLock {count}}
}
@main @MainActor struct PositiveReferenceAcceptance {
    static func main() async throws {
        let identity=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2]))) as! [String:Any]
        let transport=TaskdHTTPAuthorityClient(endpointFile:CommandLine.arguments[1],helperPath:"/no-helper",allowsLaunching:false,timeout:5)
        let client=RustWishReferenceClient { method,data in
            try JSONSerialization.data(withJSONObject:transport.call(method:method,params:JSONSerialization.jsonObject(with:data) as! [String:Any]))
        }
        let downloads=Counter()
        let provider=URL(string:CommandLine.arguments[3])!
        let coordinator=try WishMachineCoordinator(transport,session:identity["hostSessionID"] as! String)
        let directory=URL(fileURLWithPath:CommandLine.arguments[4],isDirectory:true)
        let claim=ResidentWorldToolSession.RustDispatchAuthority(worldID:identity["worldID"] as! String,
            residentScope:identity["residentScope"] as! String,hostSessionID:identity["hostSessionID"] as! String,
            runID:identity["runID"] as! String,callID:identity["callID"] as! String,
            operationID:identity["operationID"] as! String,toolName:identity["toolName"] as! String)
        let reference=ResidentWishReferenceTools(coordinator:coordinator,authorizationID:UUID(uuidString:claim.runID)!,
            worldID:claim.worldID,residentScope:claim.residentScope,isCurrent:{true},fetcher:.init(
                fetchPublicData:{_,_ in throw LeafError.forbidden},download:{url in
                    precondition(url.absoluteString == "https://fixture.example/reference.png")
                    downloads.increment()
                    // Only the native image download leaf is redirected to a
                    // local raw-byte provider; Rust sees the original HTTPS fact.
                    return try await URLSession.shared.data(from:provider).0
                }),directory:directory,referenceClient:client)
        let tool=reference.tools.first {$0.name == claim.toolName}!
        let arguments=try JSONSerialization.data(withJSONObject:identity["arguments"]!)
        var first:[String:Any]=[:]
        for index in 0..<2 {
            let result=await ResidentWorldToolSession.$rustDispatchAuthority.withValue(claim) {await tool.handle(claim.callID,arguments)}
            let value=try JSONSerialization.jsonObject(with:result.resultJSON) as! [String:Any]
            precondition(!result.isError && value["ok"] as? Bool == true,"Actual registration failed: \(value)")
            if index == 0 {first=value} else {precondition(value["attachment_id"] as? String == first["attachment_id"] as? String)}
        }
        precondition(downloads.value == 1 && coordinator.registrations == 1)
        let files=try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)
        precondition(files.count == 1 && files[0].pathExtension == "png")
        let attributes=try FileManager.default.attributesOfItem(atPath:files[0].path)
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        print("PASS: actual typed reference handler + TaskLocal claimed identity -> real reference/wish_control receipt; replay downloads=1 registrations=1 private PNG mode=0600")
    }
}

import Foundation
import CryptoKit

enum WorldAuthorityError: Error { case daemon(String), unavailable(String), invalidResponse }
struct WorldAuthorityEndpoint {
    let endpointFile: String
    let helperPath: String = "/private/tmp/never-launch-fixture"
    init(applicationSupportBase: URL) { endpointFile = applicationSupportBase.appendingPathComponent("endpoint.json").path }
}
enum WorldAuthorityClient { static func decodeState(_ state: [String: Any]) throws -> Int { 0 } }
enum RustPropNativeMeshSampler {
    struct Sample: Sendable { let sha256: String; let trianglesJSON: Data; let modelURL: URL }
    static func sample(modelURL: URL) async throws -> Sample {
        let bytes = try Data(contentsOf: modelURL)
        return Sample(sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            trianglesJSON: Data("[[[0,0,0],[1,0,0],[0,1,0]]]".utf8), modelURL: modelURL)
    }
}
final class TaskdHTTPAuthorityClient {
    static let maximumFrame = 16 * 1024 * 1024
    init(endpointFile: String, helperPath: String, allowsLaunching: Bool, timeout: Int) {}
    func call(method: String, params: [String: Any]) throws -> [String: Any] { throw WorldAuthorityError.invalidResponse }
}

@main struct Fixture {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let bridge = UnityWorldBridge(root: root,
            propIdentity: { world in .init(worldID: world, residentScope: "actual-ui-scope", hostSessionID: "actual-ui-host") },
            propFacts: { identity, record, layout in
                precondition(identity.residentScope == "actual-ui-scope" && record == 7 && layout == 3)
                return Data("{\"fixtureMeasuredMesh\":true}".utf8)
            })
        let request: [String: Any] = ["op":"world.prop.command", "worldID":"actual-world", "requestID":"pointer-release",
            "expectedRevision":7, "expectedLayoutRevision":3,
            "command":["op":"place", "objectID":"sofa", "position":[1,2,3], "yaw":0.25]]
        precondition(bridge.command(request))
        try await receive(bridge, id: "pointer-release")
        let native = UnityWorldBridge(root: root, propIdentity: { world in
            .init(worldID: world, residentScope: "actual-ui-scope", hostSessionID: "actual-ui-host") })
        let environmentPath = root.appendingPathComponent("environment.private-fixture").path
        let propPath = root.appendingPathComponent("prop.private-fixture").path
        func hash(_ path: String) throws -> String {
            SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path))).map { String(format: "%02x", $0) }.joined()
        }
        let environment: [String: Any] = ["triangles": [[[0,0,0],[1,0,0],[0,0,1]]], "blockingVolumes": [],
            "seed": [0,0,0], "bounds":["minimumX":0,"maximumX":1,"minimumZ":0,"maximumZ":1]]
        let loaded: [String: Any] = ["op":"world.prop.loaded","worldID":"actual-world","payload":[
            "worldID":"actual-world","layoutRevision":3,"environmentPath":environmentPath,"environmentSHA256":try hash(environmentPath),
            "environment":environment,"avatar":["assetID":"actual-avatar","format":"vrm","selectionRevision":2,"slots":["rightHand"]],
            "objects":["sofa":["assetID":"sha256:" + (try hash(propPath)),"path":propPath]]]]
        precondition(native.command(loaded))
        var second = request; second["requestID"] = "actual-loaded-pointer"
        precondition(native.command(second))
        try await receive(native, id: "actual-loaded-pointer")
        var stale = request; stale["requestID"] = "stale-native-layout"; stale["expectedLayoutRevision"] = 4
        precondition(native.command(stale))
        try await receive(native, id: "stale-native-layout", expected: "failed")
        precondition(!native.command(["op":"world.commit","worldID":"actual-world","state":[:]]))
        print("PASS native loaded descriptor -> measured/imported asset bytes -> observed native facts; whole-state writer disabled")
    }
    static func receive(_ bridge: UnityWorldBridge, id: String, expected: String = "completed") async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let value = bridge.snapshot()
            if value["requestID"] as? String == id {
                let update = value
                precondition(update["status"] as? String == expected, "bridge authority rejected: \(update)")
                if expected == "completed" {
                    let result = update["result"] as! [String: Any]
                    precondition(result["actualCommit"] as? Bool == true)
                }
                print("PASS actual UnityWorldBridge observe -> UI intent -> one-use capability command; no agent run or state replacement")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        fatalError("bridge response timeout")
    }
}

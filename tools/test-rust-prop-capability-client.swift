import CryptoKit
import Foundation
import WorldRuntime

/// Actual production actor against an explicitly supplied private daemon.
@main struct PropCapabilityAcceptance {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Provide private endpoint file") }
        let transport = TaskdHTTPAuthorityClient(endpointFile: CommandLine.arguments[1], helperPath: "",
            allowsLaunching: false, timeout: 5)
        let client = RustPropCapabilityClient(call: { method, bytes in
            let input = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            return try JSONSerialization.data(withJSONObject: transport.call(method: method, params: input))
        })
        func point(_ x: Float, _ y: Float = 0, _ z: Float = 0) -> [String: Float] { ["x":x,"y":y,"z":z] }
        let prop: [String: Any] = ["objectID":"machine","size":point(0.4,0.7,0.4)]
        let capability = ["objectID":"machine","templateID":"coffee.brew"]
        func string(_ value: Any) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
        }
        let state: [String: Any] = ["worldID":"private-capability-client","revision":0,"layoutRevision":7,
            "objectStates":["machine":["isEnabled":true,
                "transform":["position":point(0),"rotation":["x":0,"y":0,"z":0,"w":1],"scale":point(1,1,1)],
                "metadata":["gmgn.generated-prop.v1":try string(prop),"gmgn.prop-capability.v1":try string(capability)]]]]
        let preimage = try string(state)
        _ = try transport.call(method: "world_import", params: ["worldID":"private-capability-client",
            "requestID":"private-capability-import","producer":"private-test","packageID":"fixture",
            "packageVersion":"1","stateJson":preimage,
            "stateSha256":SHA256.hash(data: Data(preimage.utf8)).map { String(format:"%02x",$0) }.joined()])
        let waypoint = try JSONDecoder().decode(WorldWaypoint.self, from: JSONSerialization.data(withJSONObject:
            ["id":"far","position":point(1),"arrivalRadius":0.05,"enabled":true]))
        var measurements = 0
        let result = try await client.resolve(worldID:"private-capability-client",hostSessionID:"private-host",
            objectID:"machine",layoutRevision:7,kind:"capability",capsuleRadius:0.2,waypoints:[waypoint]) { probe in
                measurements += 1
                return .init(key:probe.key,position:probe.position,grounded:probe.position,canTraverse:true)
            }
        precondition(measurements > 1 && measurements <= 42)
        precondition(result.definition?.id == "coffee.brew@machine")
        precondition(result.usageBinding == ["objectID":"machine","templateID":"coffee.brew"])
        precondition(result.target?.waypointID == "far")
        precondition(result.target!.standPoint.x < 1 && result.target!.standPoint.x >= 0.2)
        let blocked = try await client.resolve(worldID:"private-capability-client",hostSessionID:"private-host",
            objectID:"machine",layoutRevision:7,kind:"capability",capsuleRadius:0.2,waypoints:[waypoint]) { probe in
                .init(key:probe.key,position:probe.position,grounded:nil,canTraverse:false)
            }
        precondition(blocked.target == nil, "Blocked native facts cannot authorize remote use")
        do {
            _ = try await client.resolve(worldID:"private-capability-client",hostSessionID:"private-host",
                objectID:"machine",layoutRevision:6,kind:"capability",capsuleRadius:0.2,waypoints:[waypoint]) { probe in
                    .init(key:probe.key,position:probe.position,grounded:probe.position,canTraverse:true)
                }
            fatalError("Stale layout was accepted")
        } catch WorldAuthorityError.daemon(let code) {
            precondition(code == "prop_capability_stale_layout")
        }
        print("PASS production async capability client: SQL definition, measured target, blocked facts, stale layout")
    }
}

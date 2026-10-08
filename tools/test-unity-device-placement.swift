// Production native consumer with actual WorldRuntime; private injected daemon only.
import Foundation
import WorldRuntime
enum WorldAuthorityError: Error { case daemon(String) }
struct WorldAuthorityEndpoint { let endpointFile = "/private/tmp/unused", helperPath = "/private/tmp/unused"; init(applicationSupportBase: URL) {} }
struct TaskdHTTPAuthorityClient {
    init(endpointFile: String, helperPath: String, allowsLaunching: Bool, timeout: Double) {}
    func call(method: String, params: [String: Any]) throws -> [String: Any] { fatalError("No actual daemon") }
}
struct WorldAuthorityClient {
    static func decodeState(_ value: [String: Any]) throws -> WorldState {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(WorldState.self, from: JSONSerialization.data(withJSONObject: value))
    }
}
final class UnityWorldBridge: @unchecked Sendable {
    func nativeUIIdentity(worldID: String) -> RustWorldPropClient.Identity? { nil }
    func nativeDeviceObservation(worldID: String, expectedRevision: UInt64, layoutRevision: UInt64) async throws -> RustWorldPropClient.Observation { fatalError("No actual loaded meshes") }
}
@main struct DevicePlacementTests {
    static func main() async throws {
        let template: [String: Any] = ["id":"device", "renderer":"builtin.jukebox", "size":[0.9,1,0.8]]
        let worldID = "private-world"
        let initial = WorldState(revision: 1, worldID: worldID, worldTime: Date(timeIntervalSince1970: 0),
            lastObservedWallTime: Date(timeIntervalSince1970: 0), weather: .clear,
            agentTransform: WorldTransform(position: WorldVector3(x:0,y:0,z:0), rotation: WorldQuaternion(x:0,y:0,z:0,w:1), scale: WorldVector3(x:1,y:1,z:1)))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        var state = try JSONSerialization.jsonObject(with: encoder.encode(initial)) as! [String: Any]
        state["layoutRevision"] = 4
        var methods: [String] = [], reject = false, corrupt = false
        let call: UnityDevicePlacementBridge.Call = { method, p in
            methods.append(method)
            assert(p["worldID"] as? String == worldID)
            if method == "world_device_catalog_install" { return ["installed":1] }
            assert(p["residentScope"] as? String == "ui-scope" && p["hostSessionID"] as? String == "actual-host")
            assert((p["expectedRevision"] as! NSNumber).intValue == 7 && (p["expectedLayoutRevision"] as! NSNumber).intValue == 3)
            switch method {
            case "world_device_preview", "world_device_ui_intent":
                let raw = p["command"] as! [String: Any]
                assert(raw["templateID"] as? String == "device" && (raw["position"] as! [NSNumber]) == [1,2,3])
                assert(raw["size"] == nil && raw["allowed"] == nil)
                if method == "world_device_preview" { return ["canPlace":false,"columns":[]] }
                if reject { throw WorldAuthorityError.daemon("cannot_place") }
                return ["intentID":"private-intent", "capability":"private-cap", "expiresAtMS":1234]
            case "world_device_command":
                assert(p["command"] == nil && p["candidate"] == nil && p["allowed"] == nil)
                let authority = p["authority"] as! [String:String]
                assert(authority == ["kind":"ui","intentID":"private-intent","capability":"private-cap"])
                return ["objectID":"device", "commit":["revision":8], "snapshot":["record":["recordRevision":corrupt ? 9 : 8,"state":state]]]
            default: fatalError("unexpected mutable legacy RPC: " + method)
            }
        }
        let identity = RustWorldPropClient.Identity(worldID:worldID,residentScope:"ui-scope",hostSessionID:"actual-host")
        let geometry: UnityDevicePlacementBridge.Geometry = { revision,layout in
            assert(revision == 7 && layout == 3)
            return .init(geometryID:"actual-loaded-mesh",meshSHA256:String(repeating:"a",count:64),layoutRevision:3)
        }
        let bridge = UnityDevicePlacementBridge(worldID:worldID,templates:[template],call:call,identity:identity,geometry:geometry)
        let request: [String:Any] = ["requestID":"pointer-request","templateID":"device","expectedRevision":7,"expectedLayoutRevision":3,"position":[1,2,3],"yaw":0.4]
        assert(methods.isEmpty)
        reject = true
        do { _ = try await bridge.place(request); fatalError("rejected intent committed") } catch WorldAuthorityError.daemon("cannot_place") {}
        assert(!methods.contains("world_device_command"))
        reject = false
        let result = try await bridge.place(request); assert(result["objectID"] as? String == "device")
        assert(methods == ["world_device_catalog_install","world_device_ui_intent","world_device_ui_intent","world_device_command"])
        var malformed = request; malformed["expectedRevision"] = true
        do { _ = try await bridge.place(malformed); fatalError("bool fence accepted") } catch UnityDevicePlacementBridge.Failure.invalid_request {}
        var preview = request; preview["op"] = "world.device.preview"
        let verdict = try await bridge.place(preview); assert(verdict["canPlace"] as? Bool == false)
        corrupt = true
        do { _ = try await bridge.place(request); fatalError("inconsistent durable receipt accepted") } catch UnityDevicePlacementBridge.Failure.readback_unconfirmed {}
        let unbound = UnityDevicePlacementBridge(worldID:worldID,templates:[template],call:call)
        let before = methods.count
        do { _ = try await unbound.place(request); fatalError("unbound consumer wrote") } catch UnityDevicePlacementBridge.Failure.native_not_ready {}
        assert(methods.count == before)
        bridge.close()
        do { _ = try await bridge.place(request); fatalError("closed consumer wrote") } catch UnityDevicePlacementBridge.Failure.cancelled {}
        assert(methods.count == before)
        print("PASS typed device intent/opaque command, raw pointer, rejected support, strict receipt, bool fence, close and missing native facts")
    }
}

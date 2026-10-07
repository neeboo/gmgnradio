// Compile with production UnityDevicePlacementBridge and actual WorldRuntime.
// Only daemon transport is injected; this does not claim live App E2E.
import Foundation
import WorldRuntime
struct WorldAuthorityEndpoint { let endpointFile = "unused", helperPath = "unused"; init(applicationSupportBase: URL) {} }
struct TaskdHTTPAuthorityClient {
    static let maximumFrame = 12 * 1024 * 1024
    init(endpointFile: String, helperPath: String, allowsLaunching: Bool, timeout: Double) {}
    func call(method: String, params: [String: Any]) throws -> [String: Any] { fatalError("Use injected transport") }
}
struct WorldAuthorityClient {
    static func decodeState(_ value: [String: Any]) throws -> WorldState {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(WorldState.self, from: JSONSerialization.data(withJSONObject: value))
    }
}
struct UnityWorldBridge {
    init(root: URL) {}
    func preparePlacementGeometry(_ value: [String: Any]) throws -> [String: Any] { value }
}
@main struct DevicePlacementTests {
    static func main() throws {
        let path = CommandLine.arguments[1]
        let template = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
        let worldID = "test-world"
        let zero = WorldVector3(x: 0,y: 0,z: 0)
        let initial = WorldState(revision: 1, worldID: worldID, worldTime: Date(timeIntervalSince1970: 0),
            lastObservedWallTime: Date(timeIntervalSince1970: 0), weather: .clear,
            agentTransform: WorldTransform(position: zero, rotation: WorldQuaternion(x:0,y:0,z:0,w:1), scale: WorldVector3(x:1,y:1,z:1)))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        var state = try JSONSerialization.jsonObject(with: encoder.encode(initial)) as! [String: Any]
        state["unrelatedPreference"] = ["keep": true]
        var revision = 4, commits = 0, reads = 0, reject = false, corruptReadback = false
        let transport: UnityDevicePlacementBridge.Call = { method, params in
            switch method {
            case "world_snapshot":
                reads += 1
                var returned = state
                if corruptReadback && commits > 0 { returned["objectStates"] = [:] }
                return ["record": ["recordRevision": revision, "state": returned]]
            case "placement_evaluate":
                assert((params["footprint"] as! [String:Any])["size"] as! [NSNumber] == [0.9,0.8])
                return ["canPlace": !reject, "volume": ["center": [2.0,1.25,3.0], "yaw": Double.pi/2]]
            case "world_commit":
                assert((params["expectedRevision"] as! NSNumber).intValue == revision)
                commits += 1; revision += 1; state = (params["ops"] as! [[String:Any]])[0]["state"] as! [String:Any]
                return ["revision": revision]
            default: fatalError(method)
            }
        }
        let bridge = UnityDevicePlacementBridge(worldID: worldID, templates: [template], call: transport)
        let request: [String:Any] = ["templateID": "wish_machine.device", "requestID": "explicit-human-place", "expectedRevision": 4,
            "placementPayload": ["footprint": ["size": [999,999]], "height":999]]
        // Merely constructing a bridge/catalog must not write anything.
        assert(commits == 0 && reads == 0)
        reject = true
        do { _ = try bridge.place(request); fatalError("blocked footprint saved") } catch UnityDevicePlacementBridge.Failure.cannot_place {}
        assert(commits == 0)
        reject = false
        let result = try bridge.place(request)
        assert(commits == 1 && reads == 3 && result["objectID"] as? String == "wish_machine.device")
        assert((state["unrelatedPreference"] as! [String:Bool])["keep"] == true)
        let saved = (state["objectStates"] as! [String:[String:Any]])["wish_machine.device"]!
        let raw = (saved["metadata"] as! [String:String])["gmgn.builtin-device.v1"]!
        let declaration = try JSONDecoder().decode(WorldProceduralPropDeclaration.self,from:Data(raw.utf8))
        assert(declaration.objectID == "wish_machine.device")
        let durable = try WorldAuthorityClient.decodeState(state)
        let registry = try WorldPropAnchorRegistry.derive(sources: [declaration.functionSource!], objectStates: durable.objectStates)
        let anchor = registry.entry(activityID: "wish_machine.collect")!
        let authoredHeight = (template["size"] as! [NSNumber])[1].doubleValue
        assert(abs(anchor.position.x - 1.05) < 0.0001 && abs(Double(anchor.position.y) - (1.25-authoredHeight/2-0.019016094)) < 0.0001)
        let reloaded = try WorldAuthorityClient.decodeState(state)
        assert(reloaded.objectStates["wish_machine.device"] == durable.objectStates["wish_machine.device"])
        var duplicate = request; duplicate["expectedRevision"] = revision
        do { _ = try bridge.place(duplicate); fatalError("duplicate saved") } catch UnityDevicePlacementBridge.Failure.already_placed {}
        assert(commits == 1)
        do { _ = try bridge.place(request); fatalError("stale CAS saved") } catch UnityDevicePlacementBridge.Failure.revision_conflict {}
        assert(commits == 1)
        let cancelled = UnityDevicePlacementBridge(worldID: worldID, templates: [template], call: transport)
        cancelled.close(); corruptReadback = false
        state = try JSONSerialization.jsonObject(with: encoder.encode(initial)) as! [String:Any]; revision = 4; commits = 0
        do { _ = try cancelled.place(request); fatalError("closed placement saved") } catch UnityDevicePlacementBridge.Failure.cancelled {}
        assert(commits == 0)
        var malformed = request; malformed["expectedRevision"] = true
        do { _ = try bridge.place(malformed); fatalError("boolean CAS accepted") } catch UnityDevicePlacementBridge.Failure.invalid_request {}
        assert(commits == 0)
        // A successful commit followed by missing readback cannot activate a device.
        state = try JSONSerialization.jsonObject(with: encoder.encode(initial)) as! [String:Any]; revision = 4; commits = 0
        corruptReadback = true
        do { _ = try bridge.place(request); fatalError("missing readback accepted") } catch UnityDevicePlacementBridge.Failure.readback_unconfirmed {}
        assert(commits == 1)
        // Explicit migration updates the original ID, retaining unrelated objects.
        corruptReadback = false; revision = 4; commits = 0
        state = try JSONSerialization.jsonObject(with: encoder.encode(initial)) as! [String:Any]
        state["objectStates"] = ["wish_machine.device": ["isEnabled":true,"transform":saved["transform"]!,"metadata":[:]],
            "unrelated.object": ["isEnabled":false,"transform":saved["transform"]!,"metadata":["retain":"yes"]]]
        _ = try bridge.place(request)
        let migrated = state["objectStates"] as! [String:[String:Any]]
        assert(migrated.count == 2 && commits == 1 && (migrated["unrelated.object"]!["metadata"] as! [String:String])["retain"] == "yes")
        assert((migrated["wish_machine.device"]!["metadata"] as! [String:String])["gmgn.builtin-device.v1"] != nil)
        // The real Unity device path carries geometry beyond the small general
        // command limit; decoding, validation and CAS still run in this bridge.
        state = try JSONSerialization.jsonObject(with: encoder.encode(initial)) as! [String:Any]
        revision = 4; commits = 0
        var byteRequest = request
        byteRequest["op"] = "world.device.place"; byteRequest["worldID"] = worldID
        byteRequest["geometryFixture"] = String(repeating: "x", count: 300 * 1024)
        let bytes = try JSONSerialization.data(withJSONObject: byteRequest)
        let byteBridge = UnityDevicePlacementBridge(worldID: worldID, templates: [template], call: transport)
        assert(bytes.count > 256 * 1024 && byteBridge.enqueue(bytes))
        let deadline = Date().addingTimeInterval(5)
        while byteBridge.snapshot()["status"] == nil && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        assert(byteBridge.snapshot()["status"] as? String == "completed" && commits == 1)
        let jukeboxPath=URL(fileURLWithPath:path).deletingLastPathComponent().appendingPathComponent("jukebox.json")
        let jukebox=try JSONSerialization.jsonObject(with:Data(contentsOf:jukeboxPath)) as! [String:Any]
        let jukeboxID=jukebox["id"] as! String
        let legacy: [String:Any] = ["isEnabled":true,"transform":saved["transform"]!,"metadata":["retain":"yes"]]
        state["objectStates"]=[jukeboxID:legacy,"unrelated.object":legacy];commits=0
        let upgrade=UnityDevicePlacementBridge(worldID:worldID,templates:[jukebox],call:transport)
        let upgraded=try upgrade.refreshJukeboxFunctions(requestID:"explicit-listen-refresh")
        assert(commits == 1 && upgraded.didCommit && upgraded.state.objectStates.count == 2)
        let upgradedObject=(state["objectStates"] as! [String:[String:Any]])[jukeboxID]!
        assert(NSDictionary(dictionary:upgradedObject["transform"] as! [String:Any]).isEqual(to:legacy["transform"] as! [String:Any]))
        assert((upgradedObject["metadata"] as! [String:String])["retain"] == "yes")
        let unchanged=try upgrade.refreshJukeboxFunctions(requestID:"idempotent-listen-refresh")
        assert(commits == 1 && !unchanged.didCommit && unchanged.state == upgraded.state)
        print("PASS production device placement and same-ID function refresh: CAS/readback, exact pose and unrelated metadata preserved, idempotent. Injected transport; no live App E2E.")
    }
}

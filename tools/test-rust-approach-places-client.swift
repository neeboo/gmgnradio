import CryptoKit
import Foundation
import WorldRuntime

/// Production typed actor against an explicitly supplied private daemon; no UI/physics.
@main struct ApproachPlacesAcceptance {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Provide private endpoint file") }
        let transport = TaskdHTTPAuthorityClient(endpointFile: CommandLine.arguments[1], helperPath: "", allowsLaunching: false, timeout: 5)
        let call: RustPropCapabilityClient.Call = { method, bytes in
            let params = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            return try JSONSerialization.data(withJSONObject: transport.call(method: method, params: params))
        }
        let client = RustPropCapabilityClient(call: call)
        func request(_ method: String, _ params: [String: Any]) throws -> [String: Any] { try transport.call(method: method, params: params) }
        func point(_ x: Double, _ y: Double = 0, _ z: Double = 0) -> [String: Double] { ["x":x,"y":y,"z":z] }
        let transform: [String: Any] = ["position":point(0),"rotation":["x":0,"y":0,"z":0,"w":1],"scale":point(1,1,1)]
        let world = "private-approach-places", host = "private-host"
        let state: [String: Any] = ["worldID":world,"revision":0,"layoutRevision":7,"worldTime":1000,
            "lastObservedWallTime":1000,"weather":"clear","completedGoals":[:],"agentTransform":transform,
            "objectStates":["prop.jukebox":["isEnabled":true,"transform":transform,"metadata":["fixture-note":"preserve"]]]]
        let raw = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
        _ = try request("world_import", ["worldID":world,"requestID":"places-private-seed","packageID":"places-private-fixture","packageVersion":"1",
            "stateJson":String(decoding:raw,as:UTF8.self),"stateSha256":SHA256.hash(data:raw).map { String(format:"%02x",$0) }.joined()])
        let template: [String: Any] = ["id":"prop.jukebox","renderer":"builtin.jukebox","size":[1,2,3],
            "functionPoints":[["role":"interact","activityID":"music.listen","kind":"standingSpot","position":[-0.7,0.0068,0],"yaw":-1.57]],
            "placeBindings":[["placeID":"wp.jukebox","role":"interact"]]]
        let common: [String: Any] = ["worldID":world,"residentScope":"private-fixture","hostSessionID":host]
        var install = common; install["templates"] = [template]
        let installed = try request("world_device_catalog_install", install)
        guard let installedSnapshot = installed["snapshot"] as? [String: Any], let installedRecord = installedSnapshot["record"] as? [String: Any],
              let installedState = installedRecord["state"] as? [String: Any], let initialLayout = (installedState["layoutRevision"] as? NSNumber)?.uint64Value else { fatalError("Missing actual catalog commit") }
        precondition(initialLayout == 8)
        let original = try await client.places(worldID:world,hostSessionID:host,layoutRevision:initialLayout)
        let binding = original["wp.jukebox"]!
        precondition(binding.anchorID == "prop.jukebox#interact" && binding.activityID == "music.listen")
        precondition(abs(binding.position!.x + 0.7) < 0.00001 && abs(binding.position!.y - 0.0068) < 0.00001)
        let cachedRaw = try call("world_activity_approach_places", JSONSerialization.data(withJSONObject:
            ["worldID":world,"hostSessionID":host,"expectedLayoutRevision":initialLayout]))

        func commit(_ requestID: String, mutation: (inout [String: Any]) -> Void) throws -> UInt64 {
            let before = try request("world_snapshot", ["worldID":world,"includeState":true])
            var record = before["record"] as! [String: Any]
            var next = record["state"] as! [String: Any]
            mutation(&next)
            let revision = (next["revision"] as! NSNumber).uint64Value
            let layout = (next["layoutRevision"] as! NSNumber).uint64Value
            next["revision"] = revision + 1; next["layoutRevision"] = layout + 1
            _ = try request("world_commit", ["worldID":world,"requestID":requestID,"expectedRevision":record["recordRevision"]!,
                "ops":[["op":"replaceState","state":next]]])
            record.removeAll()
            return layout + 1
        }
        let movedLayout = try commit("places-move") { state in
            var objects = state["objectStates"] as! [String: Any]
            var object = objects["prop.jukebox"] as! [String: Any]
            object["transform"] = ["position":point(4,0.3,-2),"rotation":["x":0,"y":0.7071067811865476,"z":0,"w":0.7071067811865476],"scale":point(1,1,1)]
            objects["prop.jukebox"] = object; state["objectStates"] = objects
        }
        let moved = try await client.places(worldID:world,hostSessionID:host,layoutRevision:movedLayout)["wp.jukebox"]!
        precondition(abs(moved.position!.x - 4) < 0.00001 && abs(moved.position!.y - 0.3068) < 0.00001 && abs(moved.position!.z + 1.3) < 0.00001)
        precondition(moved.anchorID == binding.anchorID)
        do { _ = try await client.places(worldID:world,hostSessionID:host,layoutRevision:initialLayout); fatalError("Stale layout accepted") }
        catch WorldAuthorityError.daemon(let code) { precondition(code == "activity_approach_stale_layout") }
        // Replay an actual prior transport receipt, never a fabricated successful authority result.
        let staleClient = RustPropCapabilityClient(call: { _,_ in cachedRaw })
        do { _ = try await staleClient.places(worldID:world,hostSessionID:host,layoutRevision:movedLayout); fatalError("Late cached receipt adopted") }
        catch RustPropCapabilityClient.Failure.invalidReceipt {}
        var malformed = try JSONSerialization.jsonObject(with: cachedRaw) as! [String: Any]
        var malformedPlaces = malformed["places"] as! [String: Any]
        var malformedBinding = malformedPlaces["wp.jukebox"] as! [String: Any]
        malformedBinding["anchorID"] = "wrong#identity"; malformedPlaces["wp.jukebox"] = malformedBinding; malformed["places"] = malformedPlaces
        let malformedRaw = try JSONSerialization.data(withJSONObject:malformed)
        let malformedClient = RustPropCapabilityClient(call: { _,_ in malformedRaw })
        do { _ = try await malformedClient.places(worldID:world,hostSessionID:host,layoutRevision:initialLayout); fatalError("Malformed anchor receipt adopted") }
        catch RustPropCapabilityClient.Failure.invalidReceipt {}
        for badBindings in [[ ["placeID":"wp.jukebox","role":"interact"], ["placeID":"wp.jukebox","role":"interact"] ],
                            [["placeID":"wp.jukebox","role":"unknown"]], [["placeID":"invented-place","role":"interact"]]] {
            var badTemplate = template; badTemplate["placeBindings"] = badBindings
            var badInstall = common; badInstall["templates"] = [badTemplate]
            do { _ = try request("world_device_catalog_install",badInstall); fatalError("Invalid catalog binding installed") }
            catch WorldAuthorityError.daemon(let code) { precondition(code == "world_device_invalid_catalog") }
        }
        let stillMoved = try await client.places(worldID:world,hostSessionID:host,layoutRevision:movedLayout)
        precondition(stillMoved.count == 1 && stillMoved["wp.jukebox"]!.position == moved.position)
        let disabledLayout = try commit("places-disable") { state in
            var objects = state["objectStates"] as! [String: Any], object = objects["prop.jukebox"] as! [String: Any]
            object["isEnabled"] = false; objects["prop.jukebox"] = object; state["objectStates"] = objects
        }
        let disabled = try await client.places(worldID:world,hostSessionID:host,layoutRevision:disabledLayout)["wp.jukebox"]!
        precondition(disabled.anchorID == binding.anchorID && disabled.position == nil && disabled.targetYaw == nil)
        let absentLayout = try commit("places-absent") { state in state["objectStates"] = [String: Any]() }
        let absent = try await client.places(worldID:world,hostSessionID:host,layoutRevision:absentLayout)["wp.jukebox"]!
        precondition(absent.anchorID == binding.anchorID && absent.position == nil)
        let unknown = "private-no-catalog"
        var unknownState = state; unknownState["worldID"] = unknown; unknownState["objectStates"] = [String: Any]()
        let unknownRaw = try JSONSerialization.data(withJSONObject:unknownState,options:[.sortedKeys])
        _ = try request("world_import", ["worldID":unknown,"requestID":"unknown-catalog","packageID":"unknown-fixture","packageVersion":"1",
            "stateJson":String(decoding:unknownRaw,as:UTF8.self),"stateSha256":SHA256.hash(data:unknownRaw).map { String(format:"%02x",$0) }.joined()])
        let unknownPlaces = try await client.places(worldID:unknown,hostSessionID:host,layoutRevision:7)
        precondition(unknownPlaces.isEmpty)
        print("PASS production typed places client: actual catalog/current rotated pose, disable/absent identity, stale layout/cache and malformed/duplicate/unknown catalog rejection; no UI/physics claim")
    }
}

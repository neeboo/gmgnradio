import Foundation
import CoreFoundation
import WorldRuntime

/// Human-confirmed catalog placement. The authority evaluates geometry, commits
/// by CAS and supplies a separate readback before a device becomes functional.
final class UnityDevicePlacementBridge: @unchecked Sendable {
    typealias Call = (String, [String: Any]) throws -> [String: Any]
    private let call: Call
    private let templates: [[String: Any]]
    private let worldID: String
    private let prepareGeometry: ([String: Any]) throws -> [String: Any]
    private let queue = DispatchQueue(label: "ai.gmgn.unity.device-placement")
    private let lock = NSLock()
    private var busy = false, closed = false
    private var generation: UInt64 = 0
    private var response: [String: Any] = [:]
    var onCommitted: (@Sendable (WorldState) -> Void)?

    init(root: URL, worldID: String, templates: [[String: Any]]) {
        self.worldID = worldID; self.templates = templates
        let endpoint = WorldAuthorityEndpoint(applicationSupportBase: root)
        let geometry = UnityWorldBridge(root: root)
        prepareGeometry = { try geometry.preparePlacementGeometry($0) }
        call = { method, params in
            try TaskdHTTPAuthorityClient(endpointFile: endpoint.endpointFile, helperPath: endpoint.helperPath,
                allowsLaunching: false, timeout: 10).call(method: method, params: params)
        }
    }
    init(worldID: String, templates: [[String: Any]], call: @escaping Call,
         prepareGeometry: @escaping ([String: Any]) throws -> [String: Any] = { $0 }) {
        self.worldID = worldID; self.templates = templates; self.call = call
        self.prepareGeometry = prepareGeometry
    }
    func command(_ request: [String: Any]) -> Bool {
        guard request["op"] as? String == "world.device.place", request["worldID"] as? String == worldID,
              JSONSerialization.isValidJSONObject(request) else { return false }
        lock.lock(); guard !busy, !closed else { lock.unlock(); return false }; busy = true; lock.unlock()
        queue.async { [self] in
            var result: [String: Any] = ["operation": "world.device.place", "worldID": worldID,
                "requestID": request["requestID"] as? String ?? ""]
            do { result["result"] = try place(request); result["status"] = "completed" }
            catch {
                result["status"] = "failed"; result["code"] = (error as? Failure)?.rawValue ?? "authority_unavailable"
                NSLog("[UnityDevicePlacement] failed code=%@", result["code"] as? String ?? "authority_unavailable")
            }
            lock.lock(); if !closed { response = result; generation &+= 1 }; busy = false; lock.unlock()
        }
        return true
    }
    func enqueue(_ data: Data) -> Bool {
        lock.lock(); guard !busy, !closed else { lock.unlock(); return false }; busy = true; lock.unlock()
        queue.async { [self] in
            var result: [String: Any] = ["operation": "world.device.place", "worldID": worldID]
            do {
                guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      request["op"] as? String == "world.device.place", request["worldID"] as? String == worldID else { throw Failure.invalid_request }
                result["requestID"] = request["requestID"] as? String ?? ""
                result["result"] = try place(request); result["status"] = "completed"
            } catch {
                result["status"] = "failed"; result["code"] = (error as? Failure)?.rawValue ?? "authority_unavailable"
                NSLog("[UnityDevicePlacement] failed code=%@", result["code"] as? String ?? "authority_unavailable")
            }
            lock.lock(); if !closed { response = result; generation &+= 1 }; busy = false; lock.unlock()
        }
        return true
    }
    func snapshot() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        var value = response; value["pending"] = busy; value["generation"] = generation; return value
    }
    func close() { lock.lock(); closed = true; lock.unlock() }
    enum Failure: String, Error { case invalid_request, template_unavailable, revision_conflict, already_placed, cannot_place, readback_unconfirmed, cancelled }
    /// Explicit upgrade of an already placed device's functional declaration.
    /// Pose, enabled state, other metadata and every other object remain intact.
    struct JukeboxFunctionRefresh: Sendable {
        let state: WorldState
        let didCommit: Bool
    }
    func refreshJukeboxFunctions(requestID: String) throws -> JukeboxFunctionRefresh {
        guard !requestID.isEmpty, requestID.utf8.count <= 256,
              let template = templates.first(where: { $0["renderer"] as? String == "builtin.jukebox" }),
              let id = template["id"] as? String else { throw Failure.template_unavailable }
        let before = try call("world_snapshot", ["worldID":worldID,"includeState":true])
        guard let record=before["record"] as? [String:Any],let expected=record["recordRevision"] as? NSNumber,
              var state=record["state"] as? [String:Any],state["worldID"] as? String == worldID,
              var objects=state["objectStates"] as? [String:Any],var object=objects[id] as? [String:Any],
              object["isEnabled"] as? Bool == true else { throw Failure.template_unavailable }
        var metadata=object["metadata"] as? [String:String] ?? [:]
        let encoded=String(data:try JSONSerialization.data(withJSONObject:template,options:.sortedKeys),encoding:.utf8)!
        if metadata["gmgn.builtin-device.v1"] == encoded {
            return JukeboxFunctionRefresh(state: try WorldAuthorityClient.decodeState(state), didCommit: false)
        }
        metadata["gmgn.builtin-device.v1"]=encoded;object["metadata"]=metadata
        objects[id]=object;state["objectStates"]=objects
        state["revision"]=((state["revision"] as? NSNumber)?.uint64Value ?? 0)+1
        _=try WorldAuthorityClient.decodeState(state)
        lock.lock();let cancelled=closed;lock.unlock();if cancelled { throw Failure.cancelled }
        _=try call("world_commit",["worldID":worldID,"requestID":requestID,"expectedRevision":expected,
            "producer":"unity","intent":["kind":"refresh-builtin-device-functions","objectID":id],
            "ops":[["op":"replaceState","state":state]]])
        let readback=try call("world_snapshot",["worldID":worldID,"includeState":true])
        guard let persisted=readback["record"] as? [String:Any],let durable=persisted["state"] as? [String:Any],
              let saved=(durable["objectStates"] as? [String:Any])?[id] as? [String:Any],
              NSDictionary(dictionary:saved).isEqual(to:object) else { throw Failure.readback_unconfirmed }
        // The awaited preparation caller owns exactly one context-owner reload.
        // Only generic placement uses onCommitted; triggering it here would race
        // a second adoption against that caller's newly started activity.
        return JukeboxFunctionRefresh(state: try WorldAuthorityClient.decodeState(durable), didCommit: true)
    }
    func place(_ request: [String: Any]) throws -> [String: Any] {
        guard let templateID = request["templateID"] as? String,
              let template = templates.first(where: { $0["id"] as? String == templateID }),
              let size = template["size"] as? [NSNumber], size.count == 3, size.allSatisfy({ $0.doubleValue.isFinite && $0.doubleValue > 0 }),
              let requestID = request["requestID"] as? String, !requestID.isEmpty, requestID.utf8.count <= 256,
              let expected = request["expectedRevision"] as? NSNumber,
              CFGetTypeID(expected) != CFBooleanGetTypeID(), expected.doubleValue >= 0,
              expected.doubleValue <= 9_007_199_254_740_991, expected.doubleValue.rounded() == expected.doubleValue,
              var payload = request["placementPayload"] as? [String: Any] else { throw Failure.invalid_request }
        let before = try call("world_snapshot", ["worldID": worldID, "includeState": true])
        guard let record = before["record"] as? [String: Any],
              let actual = record["recordRevision"] as? NSNumber, actual == expected,
              var state = record["state"] as? [String: Any],
              state["worldID"] as? String == worldID,
              var objects = state["objectStates"] as? [String: Any] else { throw Failure.revision_conflict }
        if let existing = objects[templateID] as? [String: Any], existing["isEnabled"] as? Bool == true,
           (existing["metadata"] as? [String: String])?["gmgn.builtin-device.v1"] != nil { throw Failure.already_placed }
        // Dimensions are authored, never trusted from the renderer's template.
        var footprint = payload["footprint"] as? [String: Any] ?? [:]
        footprint["size"] = [size[0], size[2]]; payload["footprint"] = footprint; payload["height"] = size[1]
        payload = try prepareGeometry(payload)
        guard try JSONSerialization.data(withJSONObject: payload).count <= TaskdHTTPAuthorityClient.maximumFrame - 4096 else { throw Failure.invalid_request }
        let verdict = try call("placement_evaluate", payload)
        let reasonCode = (verdict["reason"] as? [String: Any])?["code"] as? String ?? "none"
        NSLog("[UnityDevicePlacement] template=%@ canPlace=%@ reason=%@", templateID,
            String(describing: verdict["canPlace"] ?? "unknown"), reasonCode)
        guard verdict["canPlace"] as? Bool == true,
              let volume = verdict["volume"] as? [String: Any],
              let center = volume["center"] as? [NSNumber], center.count == 3,
              let yaw = volume["yaw"] as? NSNumber,
              center.allSatisfy({ $0.doubleValue.isFinite }), yaw.doubleValue.isFinite else { throw Failure.cannot_place }
        let halfYaw = yaw.doubleValue / 2
        let transform: [String: Any] = ["position": ["x": center[0], "y": center[1].doubleValue - size[1].doubleValue / 2, "z": center[2]],
            "rotation": ["x": 0, "y": sin(halfYaw), "z": 0, "w": cos(halfYaw)], "scale": ["x": 1, "y": 1, "z": 1]]
        let encoded = String(data: try JSONSerialization.data(withJSONObject: template, options: .sortedKeys), encoding: .utf8)!
        let object: [String: Any] = ["isEnabled": true, "transform": transform, "metadata": ["gmgn.builtin-device.v1": encoded]]
        objects[templateID] = object; state["objectStates"] = objects
        state["revision"] = ((state["revision"] as? NSNumber)?.uint64Value ?? 0) + 1
        _ = try WorldAuthorityClient.decodeState(state)
        lock.lock(); let cancelled = closed; lock.unlock(); if cancelled { throw Failure.cancelled }
        _ = try call("world_commit", ["worldID": worldID, "requestID": requestID, "expectedRevision": expected,
            "producer": "unity", "intent": ["kind": "place-builtin-device", "objectID": templateID],
            "ops": [["op": "replaceState", "state": state]]])
        let readback = try call("world_snapshot", ["worldID": worldID, "includeState": true])
        guard let persisted = readback["record"] as? [String: Any], let durable = persisted["state"] as? [String: Any],
              let saved = (durable["objectStates"] as? [String: Any])?[templateID] as? [String: Any],
              NSDictionary(dictionary: saved).isEqual(to: object) else { throw Failure.readback_unconfirmed }
        onCommitted?(try WorldAuthorityClient.decodeState(durable))
        return ["record": persisted, "objectID": templateID]
    }
}

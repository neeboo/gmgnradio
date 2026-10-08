import Foundation
import CoreFoundation
import WorldRuntime

/// Rust owns catalog dimensions, protected IDs, support, pose and durable commit.
/// Native supplies its actual loaded mesh evidence and the original pointer pose.
final class UnityDevicePlacementBridge: @unchecked Sendable {
    typealias Call = (String, [String: Any]) throws -> [String: Any]
    typealias Geometry = @Sendable (UInt64, UInt64) async throws -> RustWorldPropClient.Observation
    private let call: Call
    private let client: RustWorldPropClient?
    private let identity: RustWorldPropClient.Identity?
    private let geometry: Geometry?
    private let templates: Data
    private let worldID: String
    private let lock = NSLock()
    private var busy = false, closed = false, installed = false
    private var generation: UInt64 = 0
    private var response: [String: Any] = [:]
    var onCommitted: (@Sendable (WorldState) -> Void)?
    init(root: URL, worldID: String, templates: [[String: Any]], worldBridge: UnityWorldBridge? = nil) {
        self.worldID = worldID; self.templates = (try? JSONSerialization.data(withJSONObject: templates)) ?? Data("[]".utf8)
        let endpoint = WorldAuthorityEndpoint(applicationSupportBase: root)
        client = RustWorldPropClient(endpointFile: URL(fileURLWithPath: endpoint.endpointFile))
        identity = worldBridge?.nativeUIIdentity(worldID: worldID)
        if let bridge = worldBridge {
            geometry = { @Sendable (revision: UInt64, layout: UInt64) async throws -> RustWorldPropClient.Observation in
                try await bridge.nativeDeviceObservation(worldID: worldID, expectedRevision: revision, layoutRevision: layout)
            }
        } else { geometry = nil }
        call = { method, params in
            try TaskdHTTPAuthorityClient(endpointFile: endpoint.endpointFile, helperPath: endpoint.helperPath,
                allowsLaunching: false, timeout: 10).call(method: method, params: params)
        }
    }
    init(worldID: String, templates: [[String: Any]], call: @escaping Call,
         identity: RustWorldPropClient.Identity? = nil, geometry: Geometry? = nil) {
        self.worldID = worldID; self.templates = (try? JSONSerialization.data(withJSONObject: templates)) ?? Data("[]".utf8)
        self.call = call; self.identity = identity; self.geometry = geometry; client = nil
    }
    enum Failure: String, Error { case invalid_request, template_unavailable, revision_conflict, already_placed, cannot_place, readback_unconfirmed, cancelled, native_not_ready }
    private func requireOpen() throws {
        lock.lock(); defer { lock.unlock() }; if closed { throw Failure.cancelled }
    }
    private func rpc(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let input = try JSONSerialization.data(withJSONObject: params)
        let data: Data
        if let client, let identity, method != "world_device_refresh" {
            let p = try JSONSerialization.jsonObject(with: input) as! [String: Any]
            let revision = (p["expectedRevision"] as? NSNumber)?.uint64Value ?? 0
            let layout = (p["expectedLayoutRevision"] as? NSNumber)?.uint64Value ?? 0
            switch method {
            case "world_snapshot": data = try await client.snapshot(identity)
            case "world_device_catalog_install": data = try await client.deviceCatalog(identity, templates: templates)
            case "world_device_ui_intent":
                let lease = try await client.deviceIntent(identity, expectedRevision: revision, layoutRevision: layout,
                    command: JSONSerialization.data(withJSONObject: p["command"]!))
                data = try JSONSerialization.data(withJSONObject: ["intentID":lease.intentID,"capability":lease.capability,"expiresAtMS":lease.expiresAtMS])
            case "world_device_preview": data = try await client.devicePreview(identity, expectedRevision: revision, layoutRevision: layout,
                geometryID: p["geometryID"] as! String, command: JSONSerialization.data(withJSONObject: p["command"]!))
            case "world_device_command":
                let a = p["authority"] as! [String: Any]
                let lease = RustWorldPropClient.UIIntent(intentID: a["intentID"] as! String, capability: a["capability"] as! String, expiresAtMS: 0)
                data = try await client.deviceCommand(identity, intent: lease, expectedRevision: revision, layoutRevision: layout,
                    geometryID: p["geometryID"] as! String, requestID: p["requestID"] as! String)
            default: throw Failure.invalid_request
            }
        } else {
            data = try await Task.detached(priority: .utility) { [self] in
                let p = try JSONSerialization.jsonObject(with: input) as! [String: Any]
                return try JSONSerialization.data(withJSONObject: call(method, p))
            }.value
        }
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.readback_unconfirmed }
        return result
    }
    private func common() throws -> [String: Any] {
        guard let identity, identity.worldID == worldID else { throw Failure.native_not_ready }
        return ["worldID":worldID,"residentScope":identity.residentScope,"hostSessionID":identity.hostSessionID]
    }
    private func installCatalog() async throws {
        try requireOpen(); if installed { return }
        var p = try common(); p["templates"] = try JSONSerialization.jsonObject(with: templates)
        _ = try await rpc("world_device_catalog_install", p); installed = true
    }
    func command(_ request: [String: Any]) -> Bool {
        guard JSONSerialization.isValidJSONObject(request), let data = try? JSONSerialization.data(withJSONObject: request) else { return false }
        return enqueue(data)
    }
    func enqueue(_ data: Data) -> Bool {
        lock.lock(); guard !busy, !closed else { lock.unlock(); return false }; busy = true; lock.unlock()
        Task { [self] in
            var result: [String: Any] = ["worldID":worldID]
            do {
                guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any], request["worldID"] as? String == worldID,
                      ["world.device.place","world.device.preview"].contains(request["op"] as? String ?? "") else { throw Failure.invalid_request }
                result["operation"] = request["op"]; result["requestID"] = request["requestID"]
                result["result"] = try await place(request); result["status"] = "completed"
            } catch {
                result["status"] = "failed"
                if case let RustWorldPropError.rejected(code) = error { result["code"] = code }
                else if case let WorldAuthorityError.daemon(code) = error { result["code"] = code }
                else { result["code"] = (error as? Failure)?.rawValue ?? "world_device_unavailable" }
            }
            publish(result)
        }
        return true
    }
    private func publish(_ value: [String: Any]) {
        lock.lock(); defer { lock.unlock() }; if !closed { response = value; generation &+= 1 }; busy = false
    }
    func snapshot() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }; var value = response; value["pending"] = busy; value["generation"] = generation; return value
    }
    func close() { lock.lock(); closed = true; lock.unlock() }
    struct JukeboxFunctionRefresh: Sendable { let state: WorldState; let didCommit: Bool }
    func refreshJukeboxFunctions(requestID: String) async throws -> JukeboxFunctionRefresh {
        try await installCatalog()
        let catalog = try JSONSerialization.jsonObject(with: templates) as! [[String: Any]]
        guard let templateID = catalog.first(where: { $0["renderer"] as? String == "builtin.jukebox" })?["id"] as? String else { throw Failure.template_unavailable }
        let before = try await rpc("world_snapshot", ["worldID":worldID,"includeState":true])
        guard let record = before["record"] as? [String: Any], let state = record["state"] as? [String: Any] else { throw Failure.readback_unconfirmed }
        var p = try common(); p["requestID"] = requestID; p["templateID"] = templateID
        p["expectedRevision"] = record["recordRevision"]; p["expectedLayoutRevision"] = state["layoutRevision"]
        try requireOpen()
        let reply = try await rpc("world_device_refresh", p)
        guard let persisted = reply["snapshot"] as? [String: Any], let durable = (persisted["record"] as? [String: Any])?["state"] as? [String: Any],
              let didCommit = reply["didCommit"] as? Bool else { throw Failure.readback_unconfirmed }
        return .init(state: try WorldAuthorityClient.decodeState(durable), didCommit: didCommit)
    }
    func place(_ request: [String: Any]) async throws -> [String: Any] {
        guard let requestID = request["requestID"] as? String, let templateID = request["templateID"] as? String,
              let revision = request["expectedRevision"] as? NSNumber, let layout = request["expectedLayoutRevision"] as? NSNumber,
              let position = request["position"], let yaw = request["yaw"], let geometry else { throw Failure.native_not_ready }
        for value in [revision, layout] {
            let number = value.doubleValue
            guard CFGetTypeID(value) != CFBooleanGetTypeID(), number.isFinite, number >= 0,
                  number <= 9_007_199_254_740_991, number.rounded(.towardZero) == number else { throw Failure.invalid_request }
        }
        try await installCatalog()
        let observed = try await geometry(revision.uint64Value, layout.uint64Value)
        var p = try common(); p["expectedRevision"] = revision; p["expectedLayoutRevision"] = layout; p["geometryID"] = observed.geometryID
        p["command"] = ["op":"place","templateID":templateID,"position":position,"yaw":yaw]
        try requireOpen()
        if request["op"] as? String == "world.device.preview" { return try await rpc("world_device_preview", p) }
        let lease = try await rpc("world_device_ui_intent", p)
        guard let intentID = lease["intentID"] as? String, let capability = lease["capability"] as? String else { throw Failure.readback_unconfirmed }
        p.removeValue(forKey: "command"); p["requestID"] = requestID
        p["authority"] = ["kind":"ui","intentID":intentID,"capability":capability]
        try requireOpen()
        let reply = try await rpc("world_device_command", p)
        guard reply["objectID"] as? String == templateID, let snapshot = reply["snapshot"] as? [String: Any],
              let record = snapshot["record"] as? [String: Any], let state = record["state"] as? [String: Any], state["worldID"] as? String == worldID,
              let commit = reply["commit"] as? [String: Any], let committedRevision = commit["revision"] as? NSNumber,
              let persistedRevision = record["recordRevision"] as? NSNumber, committedRevision == persistedRevision,
              persistedRevision.uint64Value == revision.uint64Value + 1,
              let persistedLayout = state["layoutRevision"] as? NSNumber, persistedLayout.uint64Value == layout.uint64Value + 1 else { throw Failure.readback_unconfirmed }
        onCommitted?(try WorldAuthorityClient.decodeState(state))
        return ["record":record,"objectID":templateID]
    }
}

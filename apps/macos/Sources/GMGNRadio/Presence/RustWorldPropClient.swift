import Foundation

enum RustWorldPropError: Error, Sendable {
    case unavailable, invalidResponse, executionUnknown, rejected(String)
}

/// No placement, reach, attachment or drop decisions are made by this client.
actor RustWorldPropClient {
    struct Identity: Sendable {
        let worldID: String
        let residentScope: String
        let hostSessionID: String
    }
    struct AgentAuthority: Sendable {
        let identity: Identity
        let runID: String
        let callID: String
        let operationID: String
    }
    struct Observation: Decodable, Sendable {
        let geometryID: String
        let meshSHA256: String
        let layoutRevision: UInt64
    }
    struct UIIntent: Decodable, Sendable {
        let intentID: String
        let capability: String
        let expiresAtMS: UInt64
    }
    private struct Endpoint: Decodable { let version: Int; let address: String; let token: String }
    private struct Failure: Decodable { let code: String }
    private let endpointFile: URL
    private var pendingRegistrations: [String: (method: String, params: [String: Any])] = [:]
    private var pendingLifecycleReturns: [String: [String: Any]] = [:]
    init(endpointFile: URL) { self.endpointFile = endpointFile }
    private func common(_ identity: Identity) -> [String: Any] {
        ["worldID":identity.worldID,"residentScope":identity.residentScope,"hostSessionID":identity.hostSessionID]
    }
    private func call(_ method: String, _ params: [String: Any]) async throws -> Data {
        guard let bytes = try? Data(contentsOf: endpointFile),
              let endpoint = try? JSONDecoder().decode(Endpoint.self, from: bytes) else { throw RustWorldPropError.unavailable }
        let parts = endpoint.address.split(separator: ":")
        guard endpoint.version == 2, parts.count == 2, parts[0] == "127.0.0.1",
              let port = UInt16(parts[1]), port > 0,
              let token = UUID(uuidString: endpoint.token), token.uuidString.dropFirst(14).first == "4" else { throw RustWorldPropError.invalidResponse }
        let id = UUID().uuidString
        var request = URLRequest(url: URL(string: "http://\(endpoint.address)/rpc")!, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["id":id,"method":method,"params":params])
        let data: Data
        do {
            data = try await withCheckedThrowingContinuation { continuation in
                let transport = TaskdHTTPTransport(streaming: false, maximumBytes: 16 * 1024 * 1024,
                    receive: { continuation.resume(returning: $0) },
                    completion: { error in if let error { continuation.resume(throwing: error) } })
                transport.start(request)
            }
        } catch { throw RustWorldPropError.unavailable }
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any], envelope["id"] as? String == id else { throw RustWorldPropError.invalidResponse }
        if let error = envelope["error"] as? [String: Any] {
            let code = error["code"] as? String ?? "world_prop_failed"
            guard code.utf8.count <= 96, code.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 }) else { throw RustWorldPropError.invalidResponse }
            throw RustWorldPropError.rejected(code)
        }
        guard let result = envelope["result"], JSONSerialization.isValidJSONObject(result) else { throw RustWorldPropError.invalidResponse }
        return try JSONSerialization.data(withJSONObject: result, options: .sortedKeys)
    }
    func read(_ identity: Identity) async throws -> Data { try await call("world_prop_read", common(identity)) }
    func snapshot(_ identity: Identity) async throws -> Data {
        try await call("world_snapshot", ["worldID":identity.worldID,"includeState":true])
    }
    func surfaces(_ identity: Identity, geometryID: String) async throws -> Data {
        var p = common(identity); p["geometryID"] = geometryID
        return try await call("world_prop_surfaces", p)
    }
    func observe(_ identity: Identity, expectedRevision: UInt64, layoutRevision: UInt64, facts: Data) async throws -> Observation {
        var p = common(identity)
        p["expectedRevision"] = expectedRevision; p["layoutRevision"] = layoutRevision
        p["facts"] = try JSONSerialization.jsonObject(with: facts)
        let reply = try JSONDecoder().decode(Observation.self, from: await call("world_prop_observe", p))
        guard reply.layoutRevision == layoutRevision, !reply.geometryID.isEmpty, reply.meshSHA256.count == 64 else { throw RustWorldPropError.invalidResponse }
        return reply
    }
    /// The command is reconstructed from the already-dispatched SQLite tool call.
    /// No caller candidate or human permission flag is accepted here.
    func command(_ authority: AgentAuthority, expectedRevision: UInt64, layoutRevision: UInt64,
                 geometryID: String?, requestID: String) async throws -> Data {
        var p = common(authority.identity)
        p["expectedRevision"] = expectedRevision; p["expectedLayoutRevision"] = layoutRevision; p["requestID"] = requestID
        if let geometryID { p["geometryID"] = geometryID }
        p["authority"] = ["kind":"agent","runID":authority.runID,"callID":authority.callID,"operationID":authority.operationID]
        return try await call("world_prop_command", p)
    }
    func preview(_ identity: Identity, expectedRevision: UInt64, layoutRevision: UInt64,
                 geometryID: String, command: Data) async throws -> Data {
        var p = common(identity)
        p["expectedRevision"] = expectedRevision; p["expectedLayoutRevision"] = layoutRevision; p["geometryID"] = geometryID
        p["command"] = try JSONSerialization.jsonObject(with: command)
        return try await call("world_prop_preview", p)
    }
    func uiIntent(_ identity: Identity, expectedRevision: UInt64, layoutRevision: UInt64,
                  command: Data) async throws -> UIIntent {
        var p = common(identity); p["expectedRevision"] = expectedRevision; p["expectedLayoutRevision"] = layoutRevision
        p["command"] = try JSONSerialization.jsonObject(with: command)
        return try JSONDecoder().decode(UIIntent.self, from: await call("world_prop_ui_intent", p))
    }
    func uiCommand(_ identity: Identity, intent: UIIntent, expectedRevision: UInt64,
                   layoutRevision: UInt64, geometryID: String?, requestID: String) async throws -> Data {
        var p = common(identity); p["expectedRevision"] = expectedRevision; p["expectedLayoutRevision"] = layoutRevision
        p["requestID"] = requestID; if let geometryID { p["geometryID"] = geometryID }
        p["authority"] = ["kind":"ui","intentID":intent.intentID,"capability":intent.capability]
        return try await call("world_prop_command", p)
    }
    func systemAvatarReturn(_ identity: Identity, expectedRevision: UInt64, layoutRevision: UInt64,
                            geometryID: String, requestID: String, objectID: String, previousAvatarAssetID: String,
                            avatarAssetID: String, selectionRevision: UInt64, heldBindingSHA256: String, rebind: Bool = false) async throws -> Data {
        var p = common(identity); p["expectedRevision"] = expectedRevision; p["expectedLayoutRevision"] = layoutRevision
        p["geometryID"] = geometryID; p["requestID"] = requestID
        p["event"] = ["kind":rebind ? "avatar_changed_rebind" : "avatar_changed","objectID":objectID,"previousAvatarAssetID":previousAvatarAssetID,
                      "avatarAssetID":avatarAssetID,"selectionRevision":selectionRevision,"heldBindingSHA256":heldBindingSHA256]
        return try await submitLifecycleReturn(p)
    }
    enum LifecycleReturnKind: String, Sendable { case worldDetached = "world_detached", userStop = "user_stop", residentPause = "resident_pause", applicationExit = "application_exit" }
    func systemReturnBinding(_ identity: Identity) async throws -> Data {
        var p = common(identity); p["readBinding"] = true
        return try await call("world_prop_system_avatar_return", p)
    }
    private func submitLifecycleReturn(_ params: [String: Any]) async throws -> Data {
        guard let id = params["requestID"] as? String, pendingLifecycleReturns.count < 32,
              pendingLifecycleReturns[id] == nil else { throw RustWorldPropError.executionUnknown }
        pendingLifecycleReturns[id] = params
        do {
            let receipt = try await call("world_prop_system_avatar_return", params)
            pendingLifecycleReturns.removeValue(forKey: id)
            return receipt
        } catch RustWorldPropError.rejected(let code) {
            pendingLifecycleReturns.removeValue(forKey: id)
            throw RustWorldPropError.rejected(code)
        } catch { throw RustWorldPropError.executionUnknown }
    }
    func systemLifecycleReturn(_ identity: Identity, expectedRevision: UInt64, layoutRevision: UInt64,
                               requestID: String, objectID: String, previousAvatarAssetID: String, heldBindingSHA256: String,
                               kind: LifecycleReturnKind, selectedWorldID: String? = nil) async throws -> Data {
        var p = common(identity); p["expectedRevision"] = expectedRevision; p["expectedLayoutRevision"] = layoutRevision; p["requestID"] = requestID
        var event: [String:Any] = ["kind":kind.rawValue,"objectID":objectID,"previousAvatarAssetID":previousAvatarAssetID,"heldBindingSHA256":heldBindingSHA256]
        if kind == .worldDetached, let selectedWorldID { event["selectedWorldID"] = selectedWorldID }
        p["event"] = event
        return try await submitLifecycleReturn(p)
    }
    /// Imports only the host's exact verified asset path; the daemon rehashes it.
    func outputPreview(_ identity: Identity, wishID: String, expectedRevision: UInt64, layoutRevision: UInt64,
                       blobRef: String, triangles: Data) async throws -> Data {
        var p = common(identity); p["wishID"] = wishID; p["expectedRevision"] = expectedRevision
        p["expectedLayoutRevision"] = layoutRevision; p["requestID"] = "preview." + UUID().uuidString
        p["measurement"] = ["blobRef":blobRef,"triangles":try JSONSerialization.jsonObject(with:triangles)]
        return try await call("world_prop_output_preview",p)
    }
    func putBlob(localPath: String, sha256: String, mime: String = "model/gltf-binary") async throws {
        _ = try await call("world_blob_put", ["localPath":localPath,"sha256":sha256,"mime":mime])
    }
    func deviceCatalog(_ identity: Identity, templates: Data) async throws -> Data {
        var p = common(identity); p["templates"] = try JSONSerialization.jsonObject(with: templates)
        return try await call("world_device_catalog_install", p)
    }
    func deviceIntent(_ identity: Identity, expectedRevision: UInt64, layoutRevision: UInt64, command: Data) async throws -> UIIntent {
        var p = common(identity); p["expectedRevision"] = expectedRevision; p["expectedLayoutRevision"] = layoutRevision
        p["command"] = try JSONSerialization.jsonObject(with: command)
        return try JSONDecoder().decode(UIIntent.self, from: await call("world_device_ui_intent", p))
    }
    func devicePreview(_ identity: Identity, expectedRevision: UInt64, layoutRevision: UInt64, geometryID: String, command: Data) async throws -> Data {
        var p = common(identity); p["expectedRevision"] = expectedRevision; p["expectedLayoutRevision"] = layoutRevision; p["geometryID"] = geometryID
        p["command"] = try JSONSerialization.jsonObject(with: command)
        return try await call("world_device_preview", p)
    }
    func deviceCommand(_ identity: Identity, intent: UIIntent, expectedRevision: UInt64, layoutRevision: UInt64, geometryID: String, requestID: String) async throws -> Data {
        var p = common(identity); p["expectedRevision"] = expectedRevision; p["expectedLayoutRevision"] = layoutRevision; p["geometryID"] = geometryID; p["requestID"] = requestID
        p["authority"] = ["kind":"ui","intentID":intent.intentID,"capability":intent.capability]
        return try await call("world_device_command", p)
    }
    func register(_ identity: Identity, wishID: String, expectedRevision: UInt64, layoutRevision: UInt64,
                  requestID: String, blobRef: String, triangles: Data, rebase: Bool) async throws -> Data {
        var p = common(identity)
        p["wishID"] = wishID; p["expectedRevision"] = expectedRevision
        p["expectedLayoutRevision"] = layoutRevision; p["requestID"] = requestID
        p["measurement"] = ["blobRef":blobRef,"triangles":try JSONSerialization.jsonObject(with:triangles)]
        let key = [identity.worldID,identity.residentScope,identity.hostSessionID,wishID].joined(separator:"|")
        let method = rebase ? "world_prop_rebase" : "world_prop_register"
        let pending = pendingRegistrations[key]
        let original = pending?.params ?? p
        let originalMethod = pending?.method ?? method
        if pending != nil {
            guard let originalRequestID = original["requestID"] as? String else { throw RustWorldPropError.executionUnknown }
            let receipt = try await registrationReceipt(identity, requestID:originalRequestID)
            guard let decoded = try JSONSerialization.jsonObject(with:receipt) as? [String:Any],
                  let found = decoded["found"] as? Bool else { throw RustWorldPropError.executionUnknown }
            if found {
                guard let output = decoded["output"], JSONSerialization.isValidJSONObject(output) else { throw RustWorldPropError.executionUnknown }
                pendingRegistrations.removeValue(forKey:key)
                return try JSONSerialization.data(withJSONObject:output)
            }
        }
        pendingRegistrations[key] = (originalMethod,original)
        do {
            let result = try await call(originalMethod,original)
            pendingRegistrations.removeValue(forKey:key)
            return result
        } catch RustWorldPropError.rejected(let code) {
            pendingRegistrations.removeValue(forKey:key)
            throw RustWorldPropError.rejected(code)
        } catch { throw RustWorldPropError.executionUnknown }
    }
    func registrationReceipt(_ identity: Identity, requestID: String) async throws -> Data {
        var p = common(identity); p["requestID"] = requestID
        return try await call("world_prop_receipt", p)
    }
}

import Foundation
import CoreFoundation
import CryptoKit

/// Unity projects the Rust authority; it never writes a parallel world archive.
/// Explicit commands run off the render thread. No daemon or autonomy is started.
final class UnityWorldBridge: @unchecked Sendable {
    private let endpoint: WorldAuthorityEndpoint
    typealias PropIdentity = @Sendable (String) -> RustWorldPropClient.Identity?
    typealias PropFacts = @Sendable (RustWorldPropClient.Identity, UInt64, UInt64) async throws -> Data
    private let propIdentity: PropIdentity?
    private let propFacts: PropFacts?
    private let queue = DispatchQueue(label: "ai.gmgn.unity.world-authority")
    private let geometryQueue = DispatchQueue(label: "ai.gmgn.unity.geometry-decoding")
    private let lock = NSLock()
    private var pending = false
    private var geometryDecoding = false
    private var closed = false
    private var generation: UInt64 = 0
    private var emittedGeneration: UInt64?
    private var loadedFacts: Data?
    private var meshSamples: [String: RustPropNativeMeshSampler.Sample] = [:]
    private var importedBlobs = Set<String>()
    private var loadedFactsVersion: UInt64 = 0
    private var compiledFacts: (version: UInt64, context: String, data: Data)?
    private var observedFacts: (key: String, at: Date, observation: RustWorldPropClient.Observation)?
    private var resultData = Data("{\"status\":\"idle\",\"version\":1}".utf8)
    // Accessed only on the serial authority queue. One immutable geometry cached.
    private var indexedGeometryCache: [Data: [String: Any]] = [:]
    private var indexedGeometryOrder: [Data] = []

    init(root: URL, propIdentity: PropIdentity? = nil, propFacts: PropFacts? = nil) {
        endpoint = WorldAuthorityEndpoint(applicationSupportBase: root)
        self.propIdentity = propIdentity; self.propFacts = propFacts
    }

    /// Data is copied at the ABI boundary; expensive geometry decoding stays off main.
    func enqueueGeometry(_ data: Data) -> Bool {
        lock.lock()
        guard !closed, !pending, !geometryDecoding else { lock.unlock(); return false }
        geometryDecoding = true
        lock.unlock()
        geometryQueue.async { [self] in
            defer { lock.lock(); geometryDecoding = false; lock.unlock() }
            let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if let value, value["op"] as? String == "world.prop.loaded", adoptLoadedFacts(value) { return }
            if let value, let op = value["op"] as? String,
               ["world.placement.evaluate", "world.placement.derive"].contains(op), command(value) { return }
            let failure: [String: Any] = ["version": 1, "operation": value?["op"] as? String ?? "world.placement.evaluate",
                "requestID": value?["requestID"] as? String ?? "", "status": "failed",
                "code": "placement_not_accepted", "message": "摆放校验未能开始，请稍后重试。"]
            guard let encoded = try? JSONSerialization.data(withJSONObject: failure) else { return }
            lock.lock()
            if !closed { resultData = encoded; generation &+= 1 }
            lock.unlock()
        }
        return true
    }

    /// true means accepted for background execution, not committed.
    func command(_ value: [String: Any]) -> Bool {
        if value["op"] as? String == "world.prop.loaded" { return adoptLoadedFacts(value) }
        if let operation = value["op"] as? String, ["world.prop.preview", "world.prop.command"].contains(operation) {
            return submitProp(value)
        }
        guard let operation = value["op"] as? String,
              ["world.snapshot", "world.placement.evaluate", "world.placement.derive"].contains(operation),
              let worldID = value["worldID"] as? String, !worldID.isEmpty,
              worldID.utf8.count <= 256,
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return false }
        lock.lock()
        guard !pending, !closed else { lock.unlock(); return false }
        pending = true
        lock.unlock()
        let submittedRequestID = value["requestID"] as? String
        queue.async { [self] in
            let started = Date()
            var payloadByteCount = 0
            var response: [String: Any] = ["version": 1, "worldID": worldID, "operation": operation]
            do {
                let request = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                let client = TaskdHTTPAuthorityClient(endpointFile: endpoint.endpointFile,
                    helperPath: endpoint.helperPath, allowsLaunching: false,
                    timeout: operation == "world.placement.derive" ? 60 : 5)
                if operation == "world.placement.evaluate" || operation == "world.placement.derive" {
                    guard let requestID = request["requestID"] as? String,
                          !requestID.isEmpty, requestID.utf8.count <= 256,
                          var payload = request["payload"] as? [String: Any] else {
                        throw WorldAuthorityError.daemon("invalid_request")
                    }
                    // Pure read-only evaluation, through the same authenticated
                    // taskd transport. The renderer cannot supply its own verdict.
                    let deriving = operation == "world.placement.derive"
                    payload = try preparePlacementGeometry(payload)
                    payloadByteCount = try JSONSerialization.data(withJSONObject: payload).count
                    if !deriving, let anchor = payload["anchor"] as? [String: Any],
                       let column = anchor["column"] as? [String: Any],
                       let footprint = payload["footprint"] as? [String: Any] {
                        NSLog("[UnityPlacement] column=(%@,%@) support=%@ size=%@ height=%@",
                            String(describing: column["x"] ?? "unknown"), String(describing: column["z"] ?? "unknown"),
                            String(describing: anchor["supportHeight"] ?? "unknown"), String(describing: footprint["size"] ?? "unknown"),
                            String(describing: payload["height"] ?? "unknown"))
                    }
                    // Keep the authenticated transport's 12 MiB limit unchanged.
                    // Leave bounded headroom for method/id/auth envelope.
                    guard payloadByteCount <= TaskdHTTPAuthorityClient.maximumFrame - 4096 else {
                        throw WorldAuthorityError.daemon("frame_too_large")
                    }
                    let reply = try client.call(method: deriving ? "placement_derive" : "placement_evaluate", params: payload)
                    guard deriving ? Self.validDerivedReply(reply) : Self.validPlacementReply(reply) else {
                        throw WorldAuthorityError.invalidResponse
                    }
                    response["requestID"] = requestID
                    response["result"] = reply
                } else if operation == "world.snapshot" {
                    let reply = try client.call(method: "world_snapshot",
                        params: ["worldID": worldID, "includeState": true])
                    guard reply["record"] != nil else { throw WorldAuthorityError.invalidResponse }
                    response["result"] = reply
                }
                response["status"] = "completed"
            } catch {
                response["status"] = "failed"
                var code = "authority_unavailable"
                if case let WorldAuthorityError.daemon(detail) = error { code = detail }
                if case WorldAuthorityError.invalidResponse = error { code = "invalid_world_state" }
                if case let WorldAuthorityError.unavailable(detail) = error, detail == "read timed out" {
                    code = "placement_timeout"
                }
                response["code"] = code
                response["message"] = operation.hasPrefix("world.placement.")
                    ? "摆放校验暂时失败，这次不能确认放下。请稍后重试。"
                    : code == "revision_conflict"
                    ? "空间已在其他地方更新，这次没有保存。请刷新后重新操作。"
                    : code == "request_id_conflict"
                    ? "这次操作编号已被使用，这次没有保存。请重新操作。"
                    : "空间读取或保存失败，原有数据未被覆盖。请稍后重试。"
                response["requestID"] = submittedRequestID
            }
            if operation.hasPrefix("world.placement.") {
                let code = response["status"] as? String == "completed" ? "completed" : response["code"] as? String ?? "authority_unavailable"
                let safeCodes: Set<String> = ["completed", "authority_unavailable", "invalid_world_state", "invalid_request", "invalid_placement_request", "invalid_placement_result", "frame_too_large", "placement_timeout", "method_not_found", "unauthorized"]
                NSLog("[UnityPlacement] code=%@ payloadByteCount=%d durationMs=%d", safeCodes.contains(code) ? code : "daemon_rejected",
                    payloadByteCount, Int(Date().timeIntervalSince(started) * 1000))
                if let result = response["result"] as? [String: Any] {
                    let reason = result["reason"] as? [String: Any]
                    let reasonCode = reason?["code"] as? String ?? "none"
                    let safeReason = reasonCode.range(of: "^[A-Za-z0-9_]+$", options: .regularExpression) != nil ? reasonCode : "unknown"
                    NSLog("[UnityPlacement] canPlace=%@ reason=%@", String(describing: result["canPlace"] ?? "unknown"), safeReason)
                }
            }
            let encoded = (try? JSONSerialization.data(withJSONObject: response))
                ?? Data("{\"status\":\"failed\",\"code\":\"invalid_response\"}".utf8)
            lock.lock()
            if !closed { resultData = encoded; generation &+= 1 }
            pending = false
            lock.unlock()
        }
        return true
    }

    /// Pointer intent carries no grant, verdict or replacement WorldState.
    /// The host supplies measured facts; Rust issues the single-use UI capability.
    private func submitProp(_ value: [String: Any]) -> Bool {
        guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value) else { return false }
        lock.lock()
        guard !pending, !closed else { lock.unlock(); return false }
        pending = true
        lock.unlock()
        Task { [self] in
            var response: [String: Any] = ["version": 1]
            do {
                let request = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                let operation = request["op"] as? String ?? ""
                let worldID = request["worldID"] as? String ?? ""
                response["operation"] = operation; response["worldID"] = worldID; response["requestID"] = request["requestID"]
                guard let identity = propIdentity?(worldID), identity.worldID == worldID,
                      let expected = request["expectedRevision"] as? NSNumber,
                      let layout = request["expectedLayoutRevision"] as? NSNumber,
                      CFGetTypeID(expected) != CFBooleanGetTypeID(), CFGetTypeID(layout) != CFBooleanGetTypeID(),
                      expected.doubleValue >= 0, layout.doubleValue >= 0,
                      expected.doubleValue.rounded() == expected.doubleValue, layout.doubleValue.rounded() == layout.doubleValue,
                      expected.doubleValue <= 9_007_199_254_740_991, layout.doubleValue <= 9_007_199_254_740_991,
                      let requestID = request["requestID"] as? String, !requestID.isEmpty, requestID.utf8.count <= 256,
                      let command = request["command"] as? [String: Any],
                      ["place", "withdraw", "hold", "adjustGrip", "returnHeld", "dropHeld", "delete", "undo"].contains(command["op"] as? String ?? "") else {
                    throw RustWorldPropError.rejected("world_prop_native_not_ready")
                }
                let client = RustWorldPropClient(endpointFile: URL(fileURLWithPath: endpoint.endpointFile))
                let revision = expected.uint64Value, layoutRevision = layout.uint64Value
                let factsVersion = nativeFactsVersion()
                let facts: Data
                if let propFacts { facts = try await propFacts(identity, revision, layoutRevision) }
                else { facts = try await measuredNativeFacts(identity, layoutRevision: layoutRevision, client: client) }
                guard propFacts != nil || factsVersion == nativeFactsVersion() else { throw RustWorldPropError.rejected("world_prop_stale_native_facts") }
                let observation: RustWorldPropClient.Observation
                let observationKey = identity.worldID + "|" + identity.residentScope + "|" + identity.hostSessionID + "|" + String(layoutRevision) + "|" + String(factsVersion)
                if propFacts == nil, let cached = cachedObservation(observationKey) { observation = cached }
                else {
                    observation = try await client.observe(identity, expectedRevision: revision, layoutRevision: layoutRevision, facts: facts)
                    if propFacts == nil { cacheObservation(observation, key: observationKey) }
                }
                let commandData = try JSONSerialization.data(withJSONObject: command)
                guard propFacts != nil || factsVersion == nativeFactsVersion() else { throw RustWorldPropError.rejected("world_prop_stale_native_facts") }
                let reply: Data
                if operation == "world.prop.preview" {
                    reply = try await client.preview(identity, expectedRevision: revision, layoutRevision: layoutRevision,
                        geometryID: observation.geometryID, command: commandData)
                } else {
                    let intent = try await client.uiIntent(identity, expectedRevision: revision, layoutRevision: layoutRevision, command: commandData)
                    guard propFacts != nil || factsVersion == nativeFactsVersion() else { throw RustWorldPropError.rejected("world_prop_stale_native_facts") }
                    reply = try await client.uiCommand(identity, intent: intent, expectedRevision: revision,
                        layoutRevision: layoutRevision, geometryID: observation.geometryID, requestID: requestID)
                }
                response["result"] = try JSONSerialization.jsonObject(with: reply)
                response["status"] = "completed"
            } catch {
                response["status"] = "failed"
                if case let RustWorldPropError.rejected(code) = error { response["code"] = code }
                else { response["code"] = "world_prop_unavailable" }
                response["message"] = "空间服务没有确认这次操作，预览已保留。"
            }
            publishPropResponse((try? JSONSerialization.data(withJSONObject: response)) ?? Data("{\"status\":\"failed\"}".utf8))
        }
        return true
    }
    private func publishPropResponse(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        if !closed { resultData = data; generation &+= 1 }
        pending = false
    }
    private func adoptLoadedFacts(_ value: [String: Any]) -> Bool {
        guard let worldID = value["worldID"] as? String, let identity = propIdentity?(worldID), identity.worldID == worldID,
              let payload = value["payload"] as? [String: Any], payload["worldID"] as? String == worldID,
              JSONSerialization.isValidJSONObject(payload), let bytes = try? JSONSerialization.data(withJSONObject: payload),
              bytes.count <= 64 * 1024 * 1024 else { return false }
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }
        loadedFacts = bytes
        loadedFactsVersion &+= 1; compiledFacts = nil; observedFacts = nil
        return true
    }
    private func nativeFactsInput() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let loadedFacts else { throw RustWorldPropError.rejected("world_prop_native_not_ready") }
        return loadedFacts
    }
    private func measuredNativeFacts(_ identity: RustWorldPropClient.Identity, layoutRevision: UInt64,
                                     client: RustWorldPropClient) async throws -> Data {
        let version = nativeFactsVersion()
        let context = identity.worldID + "|" + String(layoutRevision)
        if let cached = cachedCompiledFacts(version, context: context) { return cached }
        let input = try JSONSerialization.jsonObject(with: nativeFactsInput()) as! [String: Any]
        guard input["worldID"] as? String == identity.worldID,
              (input["layoutRevision"] as? NSNumber)?.uint64Value == layoutRevision,
              let environmentPath = input["environmentPath"] as? String,
              let environmentHash = input["environmentSHA256"] as? String, environmentHash.count == 64,
              let environment = input["environment"] as? [String: Any],
              let avatar = input["avatar"] as? [String: Any],
              let objects = input["objects"] as? [String: [String: Any]], objects.count <= 128 else {
            throw RustWorldPropError.rejected("world_prop_native_not_ready")
        }
        // This path was reported only after the Unity collider loader sampled it.
        // Keep the C# calibrated RH triangles; importing the original file adds its hash binding.
        try await importNativeBlob(client, path: environmentPath, hash: environmentHash)
        var meshes: [String: Any] = [:]
        for (objectID, descriptor) in objects {
            guard let assetID = descriptor["assetID"] as? String, let path = descriptor["path"] as? String else {
                throw RustWorldPropError.rejected("world_prop_invalid_native_facts")
            }
            let key = assetID + "\n" + path
            let sample: RustPropNativeMeshSampler.Sample
            if let cached = cachedMesh(key) { sample = cached }
            else {
                sample = try await RustPropNativeMeshSampler.sample(modelURL: URL(fileURLWithPath: path))
                cacheMesh(sample, key: key)
            }
            guard assetID == "sha256:" + sample.sha256 else { throw RustWorldPropError.rejected("world_prop_invalid_native_facts") }
            try await importNativeBlob(client, path: path, hash: sample.sha256)
            let triangles = try JSONSerialization.jsonObject(with: sample.trianglesJSON)
            meshes[objectID] = ["assetID": assetID, "blobRef": "sha256:" + sample.sha256,
                "triangles": try preparePlacementGeometry(["triangles":triangles])["triangles"]!]
        }
        let measured: [String: Any] = ["environmentBlobRef":"sha256:" + environmentHash,
            "environment":try preparePlacementGeometry(environment), "avatar":avatar, "objects":meshes]
        let data = try JSONSerialization.data(withJSONObject: measured)
        cacheCompiledFacts(data, version: version, context: context)
        return data
    }
    private func cachedMesh(_ key: String) -> RustPropNativeMeshSampler.Sample? {
        lock.lock(); defer { lock.unlock() }; return meshSamples[key]
    }
    private func cacheMesh(_ sample: RustPropNativeMeshSampler.Sample, key: String) {
        lock.lock(); defer { lock.unlock() }
        if meshSamples.count >= 128 { meshSamples.removeAll() }
        meshSamples[key] = sample
    }
    private func blobImported(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }; return importedBlobs.contains(key)
    }
    private func markBlobImported(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        if importedBlobs.count >= 256 { importedBlobs.removeAll() }
        importedBlobs.insert(key)
    }
    private func importNativeBlob(_ client: RustWorldPropClient, path: String, hash: String) async throws {
        let key = hash + "\n" + path
        if blobImported(key) { return }
        try await client.putBlob(localPath: path, sha256: hash)
        markBlobImported(key)
    }
    private func nativeFactsVersion() -> UInt64 {
        lock.lock(); defer { lock.unlock() }; return loadedFactsVersion
    }
    func nativeUIIdentity(worldID: String) -> RustWorldPropClient.Identity? { propIdentity?(worldID) }
    func nativePropFacts(identity: RustWorldPropClient.Identity) async throws -> Data {
        let version = nativeFactsVersion()
        let client = RustWorldPropClient(endpointFile: URL(fileURLWithPath: endpoint.endpointFile))
        let facts = try await measuredNativeFacts(identity, layoutRevision: try loadedLayoutRevision(worldID: identity.worldID), client: client)
        guard nativeFactsVersion() == version else { throw RustWorldPropError.rejected("world_prop_stale_native_facts") }
        return facts
    }
    private func loadedLayoutRevision(worldID: String) throws -> UInt64 {
        guard let value = try JSONSerialization.jsonObject(with: nativeFactsInput()) as? [String: Any],
              value["worldID"] as? String == worldID, let layout = value["layoutRevision"] as? NSNumber else {
            throw RustWorldPropError.rejected("world_prop_native_not_ready")
        }
        return layout.uint64Value
    }
    func nativeDeviceObservation(worldID: String, expectedRevision: UInt64, layoutRevision: UInt64) async throws -> RustWorldPropClient.Observation {
        guard let identity = propIdentity?(worldID), identity.worldID == worldID else { throw RustWorldPropError.rejected("world_prop_native_not_ready") }
        let version = nativeFactsVersion()
        let key = identity.worldID + "|" + identity.residentScope + "|" + identity.hostSessionID + "|" + String(layoutRevision) + "|" + String(version)
        if let cached = cachedObservation(key) { return cached }
        let client = RustWorldPropClient(endpointFile: URL(fileURLWithPath: endpoint.endpointFile))
        let facts = try await measuredNativeFacts(identity, layoutRevision: layoutRevision, client: client)
        guard nativeFactsVersion() == version else { throw RustWorldPropError.rejected("world_prop_stale_native_facts") }
        let observation = try await client.observe(identity, expectedRevision: expectedRevision, layoutRevision: layoutRevision, facts: facts)
        guard nativeFactsVersion() == version else { throw RustWorldPropError.rejected("world_prop_stale_native_facts") }
        cacheObservation(observation, key: key)
        return observation
    }
    private func cachedCompiledFacts(_ version: UInt64, context: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return compiledFacts?.version == version && compiledFacts?.context == context ? compiledFacts?.data : nil
    }
    private func cacheCompiledFacts(_ data: Data, version: UInt64, context: String) {
        lock.lock(); defer { lock.unlock() }
        if loadedFactsVersion == version { compiledFacts = (version, context, data) }
    }
    private func cachedObservation(_ key: String) -> RustWorldPropClient.Observation? {
        lock.lock(); defer { lock.unlock() }
        guard let cached = observedFacts, cached.key == key, Date().timeIntervalSince(cached.at) < 4 else { return nil }
        return cached.observation
    }
    private func cacheObservation(_ observation: RustWorldPropClient.Observation, key: String) {
        lock.lock(); defer { lock.unlock() }; observedFacts = (key, Date(), observation)
    }

    func snapshot() -> [String: Any] {
        lock.lock()
        let busy = pending, currentGeneration = generation
        let data: Data? = emittedGeneration != currentGeneration ? resultData : nil
        emittedGeneration = currentGeneration
        lock.unlock()
        var value: [String: Any] = [:]
        if let data { value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }
        value["pending"] = busy
        value["generation"] = currentGeneration
        return value
    }

    func close() {
        lock.lock()
        closed = true
        lock.unlock()
    }

    private struct VertexBits: Hashable { let x: UInt32; let y: UInt32; let z: UInt32 }
    // Internal so the boundary regression compiles this exact production code.
    // Preserve every face, winding, obstacle identity and closed-mesh flag.
    func preparePlacementGeometry(_ input: [String: Any]) throws -> [String: Any] {
        var payload = input
        if let triangles = payload["triangles"] as? [[[NSNumber]]] {
            payload["triangles"] = try indexedTriangles(triangles)
        }
        for key in ["blockingVolumes", "placedObstacles"] {
            guard var obstacles = payload[key] as? [[String: Any]] else { continue }
            for index in obstacles.indices {
                guard obstacles[index]["shape"] as? String == "mesh",
                      let triangles = obstacles[index]["triangles"] as? [[[NSNumber]]] else { continue }
                obstacles[index]["triangles"] = try indexedTriangles(triangles)
            }
            payload[key] = obstacles
        }
        return payload
    }
    private func indexedTriangles(_ triangles: [[[NSNumber]]]) throws -> [String: Any] {
        let source = try JSONSerialization.data(withJSONObject: triangles)
        let digest = Data(SHA256.hash(data: source))
        if let cached = indexedGeometryCache[digest] { return cached }
        var lookup: [VertexBits: UInt32] = [:]
        var vertices: [[Float]] = []
        var indices: [[UInt32]] = []
        indices.reserveCapacity(triangles.count)
        for triangle in triangles {
            guard triangle.count == 3 else { throw WorldAuthorityError.daemon("invalid_placement_request") }
            var face: [UInt32] = []
            for point in triangle {
                guard point.count == 3, point.allSatisfy({ CFGetTypeID($0) != CFBooleanGetTypeID() }) else {
                    throw WorldAuthorityError.daemon("invalid_placement_request")
                }
                let xyz = point.map { $0.floatValue }
                guard xyz.allSatisfy({ $0.isFinite }) else { throw WorldAuthorityError.daemon("invalid_placement_request") }
                let bits = VertexBits(x: xyz[0].bitPattern, y: xyz[1].bitPattern, z: xyz[2].bitPattern)
                if let index = lookup[bits] { face.append(index) }
                else {
                    guard vertices.count < Int(UInt32.max) else { throw WorldAuthorityError.daemon("invalid_placement_request") }
                    let index = UInt32(vertices.count)
                    lookup[bits] = index; vertices.append(xyz); face.append(index)
                }
            }
            indices.append(face)
        }
        // JSONSerialization promotes Float to Double and expands its binary
        // tail. Shortest Float decimal round-trips to the exact same f32 bits
        // used by the authority without growing every vertex coordinate.
        let wireVertices = vertices.map { point in
            point.map { NSNumber(value: Double(String($0))!) }
        }
        let result: [String: Any] = ["vertices": wireVertices, "indices": indices]
        // One collider and a handful of restored obstacles; never retain an
        // unbounded history of moved meshes. The authority owns no new state.
        if indexedGeometryOrder.count >= 8 {
            indexedGeometryCache.removeValue(forKey: indexedGeometryOrder.removeFirst())
        }
        indexedGeometryOrder.append(digest); indexedGeometryCache[digest] = result
        return result
    }

    private static func validPlacementReply(_ value: [String: Any]) -> Bool {
        guard let allowed = value["canPlace"] as? NSNumber,
              CFGetTypeID(allowed) == CFBooleanGetTypeID(),
              let columns = value["columns"] as? [[String: Any]],
              columns.allSatisfy({ column in
                  ["x", "z"].allSatisfy { key in
                      guard let number = column[key] as? NSNumber,
                            CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
                      return number.doubleValue.isFinite && number.doubleValue.rounded() == number.doubleValue
                  }
              }) else { return false }
        if !allowed.boolValue {
            return (value["reason"] as? [String: Any])?["code"] is String
        }
        guard value["reason"] is NSNull, !columns.isEmpty,
              let volume = value["volume"] as? [String: Any],
              let center = volume["center"] as? [NSNumber], center.count == 3,
              let halfExtents = volume["halfExtents"] as? [NSNumber], halfExtents.count == 3,
              let yaw = volume["yaw"] as? NSNumber,
              CFGetTypeID(yaw) != CFBooleanGetTypeID(), yaw.doubleValue.isFinite else { return false }
        return center.allSatisfy { CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue.isFinite }
            && halfExtents.allSatisfy { CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue.isFinite && $0.doubleValue > 0 }
    }

    private static func validDerivedReply(_ value: [String: Any]) -> Bool {
        guard let grid = value["grid"] as? [String: Any],
              let spacing = grid["spacing"] as? NSNumber,
              CFGetTypeID(spacing) != CFBooleanGetTypeID(),
              spacing.doubleValue.isFinite, spacing.doubleValue > 0,
              let layers = grid["layers"] as? [[String: Any]],
              let report = value["report"] as? [String: Any],
              let seeded = report["seeded"] as? NSNumber,
              CFGetTypeID(seeded) == CFBooleanGetTypeID() else { return false }
        func integer(_ value: Any?) -> Bool {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
            return number.doubleValue.isFinite && number.doubleValue.rounded() == number.doubleValue
        }
        func column(_ value: Any?) -> Bool {
            guard let column = value as? [String: Any] else { return false }
            return integer(column["x"]) && integer(column["z"])
        }
        guard column(grid["minimum"]), column(grid["maximum"]),
              ["columns", "layersBeforeFilter", "layersAfterFilter", "standableLayers", "coveredGroundLayers", "reachableLayers", "furnitureBandLayers"].allSatisfy({ integer(report[$0]) }) else { return false }
        return layers.allSatisfy { layer in
            guard column(layer["column"]), integer(layer["layer"]),
                  let height = layer["supportHeight"] as? NSNumber,
                  CFGetTypeID(height) != CFBooleanGetTypeID() else { return false }
            return height.doubleValue.isFinite
        }
    }
}

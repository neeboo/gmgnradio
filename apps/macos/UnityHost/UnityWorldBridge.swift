import Foundation
import CoreFoundation
import CryptoKit

/// Unity projects the Rust authority; it never writes a parallel world archive.
/// Explicit commands run off the render thread. No daemon or autonomy is started.
final class UnityWorldBridge: @unchecked Sendable {
    private let endpoint: WorldAuthorityEndpoint
    private let queue = DispatchQueue(label: "ai.gmgn.unity.world-authority")
    private let geometryQueue = DispatchQueue(label: "ai.gmgn.unity.geometry-decoding")
    private let lock = NSLock()
    private var pending = false
    private var geometryDecoding = false
    private var closed = false
    private var generation: UInt64 = 0
    private var emittedGeneration: UInt64?
    private var resultData = Data("{\"status\":\"idle\",\"version\":1}".utf8)
    // Accessed only on the serial authority queue. One immutable geometry cached.
    private var indexedGeometryDigest: Data?
    private var indexedGeometry: [String: Any]?

    init(root: URL) {
        endpoint = WorldAuthorityEndpoint(applicationSupportBase: root)
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
        guard let operation = value["op"] as? String,
              ["world.snapshot", "world.commit", "world.placement.evaluate", "world.placement.derive"].contains(operation),
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
                let client = LoopbackJSONClient(socketPath: endpoint.socketPath,
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
                    if let triangles = payload["triangles"] as? [[[NSNumber]]] {
                        payload["triangles"] = try indexedTriangles(triangles)
                    }
                    payloadByteCount = try JSONSerialization.data(withJSONObject: payload).count
                    // Keep the authenticated transport's 12 MiB limit unchanged.
                    // Leave bounded headroom for method/id/auth envelope.
                    guard payloadByteCount <= LoopbackJSONClient.maximumFrame - 4096 else {
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
                } else {
                    guard let requestID = request["requestID"] as? String,
                          !requestID.isEmpty, requestID.utf8.count <= 256,
                          let expected = request["expectedRevision"] as? NSNumber,
                          CFGetTypeID(expected) != CFBooleanGetTypeID(),
                          expected.doubleValue >= 0, expected.doubleValue <= 9_007_199_254_740_991,
                          expected.doubleValue.rounded() == expected.doubleValue,
                          let state = request["state"] as? [String: Any],
                          state["worldID"] as? String == worldID else {
                        throw WorldAuthorityError.daemon("invalid_request")
                    }
                    // Validate the established WorldState contract, preserving all
                    // original keys in the request rather than re-encoding it.
                    _ = try WorldAuthorityClient.decodeState(state)
                    let reply = try client.call(method: "world_commit", params: [
                        "worldID": worldID, "requestID": requestID,
                        "expectedRevision": expected, "producer": "unity",
                        "intent": request["intent"] as? [String: Any] ?? ["kind": "unity-edit"],
                        "ops": [["op": "replaceState", "state": state]]])
                    response["requestID"] = requestID
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
    private func indexedTriangles(_ triangles: [[[NSNumber]]]) throws -> [String: Any] {
        let source = try JSONSerialization.data(withJSONObject: triangles)
        let digest = Data(SHA256.hash(data: source))
        if digest == indexedGeometryDigest, let indexedGeometry { return indexedGeometry }
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
        let result: [String: Any] = ["vertices": vertices, "indices": indices]
        indexedGeometryDigest = digest; indexedGeometry = result
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

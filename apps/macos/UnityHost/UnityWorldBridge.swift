import Foundation
import CoreFoundation

/// Unity projects the Rust authority; it never writes a parallel world archive.
/// Explicit commands run off the render thread. No daemon or autonomy is started.
final class UnityWorldBridge: @unchecked Sendable {
    private let endpoint: WorldAuthorityEndpoint
    private let queue = DispatchQueue(label: "ai.gmgn.unity.world-authority")
    private let lock = NSLock()
    private var pending = false
    private var closed = false
    private var generation: UInt64 = 0
    private var emittedGeneration: UInt64?
    private var resultData = Data("{\"status\":\"idle\",\"version\":1}".utf8)

    init(root: URL) {
        endpoint = WorldAuthorityEndpoint(applicationSupportBase: root)
    }

    /// true means accepted for background execution, not committed.
    func command(_ value: [String: Any]) -> Bool {
        guard let operation = value["op"] as? String,
              ["world.snapshot", "world.commit"].contains(operation),
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
            var response: [String: Any] = ["version": 1, "worldID": worldID, "operation": operation]
            do {
                let request = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                let client = LoopbackJSONClient(socketPath: endpoint.socketPath,
                    helperPath: endpoint.helperPath, allowsLaunching: false)
                if operation == "world.snapshot" {
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
                response["code"] = code
                response["message"] = code == "revision_conflict"
                    ? "空间已在其他地方更新，这次没有保存。请刷新后重新操作。"
                    : code == "request_id_conflict"
                    ? "这次操作编号已被使用，这次没有保存。请重新操作。"
                    : "空间读取或保存失败，原有数据未被覆盖。请稍后重试。"
                response["requestID"] = submittedRequestID
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
}

import Foundation

@main struct SettingsBridgeSmoke {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-unity-settings-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var selected = "luminous"
        var mutations = 0
        let bridge = try UnitySettingsBridge(root: root, command: { command in
            guard command["op"] as? String == "stage.player.lyrics", let id = command["id"] as? String,
                  ["luminous", "monet_poster"].contains(id) else { return false }
            selected = id; mutations += 1; return true
        }, snapshot: { ["version": 1, "lyricVisual": ["configuredMode": selected], "revision": mutations] })
        defer { bridge.close() }
        let marker = root.appendingPathComponent("unity-settings-endpoint.json")
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        let data = try Data(contentsOf: marker)
        let value = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let permissions = try FileManager.default.attributesOfItem(atPath: marker.path)[.posixPermissions] as! NSNumber
        precondition(permissions.intValue == 0o600)
        let port = value["port"] as! Int, token = value["token"] as! String
        func call(_ path: String, token: String, command: [String: Any]? = nil) throws -> (Int, [String: Any]) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/\(path)")!)
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            if let command { request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: command) }
            request.timeoutInterval = 4
            let result = SmokeResult()
            URLSession.shared.dataTask(with: request) { data, response, error in result.set(data, response, error) }.resume()
            let deadline = Date().addingTimeInterval(5)
            while !result.finished, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            if let error = result.error { throw error }
            let response = result.response as! HTTPURLResponse
            return (response.statusCode, try JSONSerialization.jsonObject(with: result.data!) as! [String: Any])
        }
        let denied = try call("snapshot", token: "wrong-token"); precondition(denied.0 == 401)
        let rejected = try call("command", token: token, command: ["op": "world.commit"]); precondition(rejected.0 == 422 && mutations == 0)
        let accepted = try call("command", token: token, command: ["op": "stage.player.lyrics", "id": "monet_poster"]); precondition(accepted.0 == 200 && mutations == 1)
        let snapshot = try call("snapshot", token: token); precondition((snapshot.1["lyricVisual"] as! [String: Any])["configuredMode"] as? String == "monet_poster")
        print("PASS loopback-only endpoint, private marker, authorization, command allowlist, live mutation and readback")
    }
}
final class SmokeResult: @unchecked Sendable {
    let lock = NSLock()
    private var done = false
    var data: Data?, response: URLResponse?, error: Error?
    var finished: Bool { lock.lock(); defer { lock.unlock() }; return done }
    func set(_ data: Data?, _ response: URLResponse?, _ error: Error?) { lock.lock(); defer { lock.unlock() }; self.data = data; self.response = response; self.error = error; done = true }
}

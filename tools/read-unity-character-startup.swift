import Foundation
import Darwin
typealias Create = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> UnsafeMutableRawPointer?
typealias Snapshot = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutablePointer<CChar>?
typealias Release = @convention(c) (UnsafeMutablePointer<CChar>) -> Void
typealias Destroy = @convention(c) (UnsafeMutableRawPointer) -> Int32
guard CommandLine.arguments.count == 3, let lib = dlopen(CommandLine.arguments[1], RTLD_NOW | RTLD_LOCAL) else { exit(64) }
func symbol<T>(_ name: String, _: T.Type) -> T { unsafeBitCast(dlsym(lib, name)!, to: T.self) }
let create = symbol("gmgn_unity_host_create", Create.self), snapshot = symbol("gmgn_unity_host_snapshot", Snapshot.self)
let release = symbol("gmgn_unity_host_string_free", Release.self), destroy = symbol("gmgn_unity_host_destroy", Destroy.self)
setenv("GMGN_UNITY_REGISTERED_WORLD_PACKAGES", CommandLine.arguments[2], 1)
setenv("GMGN_UNITY_TEST_MUTED", "1", 1)
let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support").path
let suite = "ai.gmgn.unity-sample.readonly-character." + UUID().uuidString
guard let host = root.withCString({ path in suite.withCString { create(path, $0) } }) else { exit(1) }
defer { _ = destroy(host); UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
let deadline = Date().addingTimeInterval(8)
var last = ""
while Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    guard let raw = snapshot(host) else { continue }
    let data = Data(String(cString: raw).utf8); release(raw)
    guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
    var safe: [String: Any] = [:]
    let presence = value["selection"] as? [String: Any] ?? [:]
    let activity = value["activity"] as? [String: Any] ?? [:]
    for (prefix, fields) in [("selection", presence), ("activity", activity)] {
        for key in ["revision", "avatar", "motion", "motionRequired", "phase", "agentTransform"] {
            safe[prefix + "." + key] = fields[key]
        }
    }
    let line = String(data: try! JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys]), encoding: .utf8)!
    if line != last { print(line); last = line }
}

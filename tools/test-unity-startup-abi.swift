import Foundation
import Darwin

typealias Create = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> UnsafeMutableRawPointer?
typealias Snapshot = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutablePointer<CChar>?
typealias Release = @convention(c) (UnsafeMutablePointer<CChar>) -> Void
typealias Destroy = @convention(c) (UnsafeMutableRawPointer) -> Int32
guard (4...5).contains(CommandLine.arguments.count),
      let lib = dlopen(CommandLine.arguments[1], RTLD_NOW | RTLD_LOCAL) else { exit(64) }
func symbol<T>(_ name: String, _: T.Type) -> T { unsafeBitCast(dlsym(lib, name)!, to: T.self) }
let create = symbol("gmgn_unity_host_create", Create.self)
let snapshot = symbol("gmgn_unity_host_snapshot", Snapshot.self)
let release = symbol("gmgn_unity_host_string_free", Release.self)
let destroy = symbol("gmgn_unity_host_destroy", Destroy.self)
let root = CommandLine.arguments[2], package = CommandLine.arguments[3]
let expectedCode = CommandLine.arguments.count == 5 ? CommandLine.arguments[4] : "world_authority_unavailable"
guard root.contains("/tmp/unity-startup-abi-"), root.hasPrefix("/Users/ghostcorn/dev/gmgnradio/") else { exit(64) }
setenv("GMGN_UNITY_REGISTERED_WORLD_PACKAGES", package, 1)
setenv("GMGN_UNITY_WORLD_ID", "84503420-3010-4944-8fde-2f383cd08ebe", 1)
setenv("GMGN_UNITY_TEST_MUTED", "1", 1)
let suite = "ai.gmgn.unity-sample.startup-test." + UUID().uuidString
guard let host = root.withCString({ path in suite.withCString { create(path, $0) } }) else {
    fputs("FAIL: unavailable world aborted independent audio/chat host\n", stderr); exit(1)
}
defer { _ = destroy(host); UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
let deadline = Date().addingTimeInterval(8)
var confirmed = false
while Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    guard let raw = snapshot(host) else { continue }
    let data = Data(String(cString: raw).utf8); release(raw)
    let value = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    guard let world = value["worldSelection"] as? [String: Any], world["phase"] as? String == "failed" else { continue }
    precondition(world["code"] as? String == expectedCode)
    precondition(value["music"] is [String: Any])
    precondition(((value["chat"] as? [String: Any])?["capabilities"] as? [String: Any])?["streamingReplies"] as? Bool == true)
    confirmed = true; break
}
guard confirmed else { fputs("FAIL: no explicit world failure projection\n",stderr); exit(1) }
print("PASS actual Host ABI: \(expectedCode) retains music/chat; world remains explicit failed")

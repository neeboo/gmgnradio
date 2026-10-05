import Foundation
import Darwin

typealias Create = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> UnsafeMutableRawPointer?
typealias Command = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<CChar>) -> Int32
typealias Snapshot = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutablePointer<CChar>?
typealias Release = @convention(c) (UnsafeMutablePointer<CChar>) -> Void
typealias Destroy = @convention(c) (UnsafeMutableRawPointer) -> Int32
guard CommandLine.arguments.count == 3 else { exit(64) }
guard let lib = dlopen(CommandLine.arguments[1], RTLD_NOW | RTLD_LOCAL) else {
    fputs("Host loader failure: \(String(cString: dlerror()))\n", stderr); exit(1)
}
func symbol<T>(_ name: String, _: T.Type) -> T { unsafeBitCast(dlsym(lib, name)!, to: T.self) }
let create = symbol("gmgn_unity_host_create", Create.self)
let command = symbol("gmgn_unity_host_command", Command.self)
let snapshot = symbol("gmgn_unity_host_snapshot", Snapshot.self)
let release = symbol("gmgn_unity_host_string_free", Release.self)
let destroy = symbol("gmgn_unity_host_destroy", Destroy.self)
let root = CommandLine.arguments[2]
guard root.hasPrefix("/Users/ghostcorn/dev/gmgnradio/tmp/"),
      let host = root.withCString({ path in "ai.gmgn.unity-sample.library-test".withCString { create(path, $0) } }) else { fatalError("isolated host unavailable") }
defer { _ = destroy(host) }
guard "{\"op\":\"music.library\"}".withCString({ command(host, $0) }) == 1 else { fatalError("library not accepted") }
let deadline = Date().addingTimeInterval(15)
var count: Int?
while Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    guard let json = snapshot(host) else { continue }
    let data = Data(String(cString: json).utf8); release(json)
    guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let library = envelope["musicLibrary"] as? [String: Any],
          library["operation"] as? String == "library" else { continue }
    guard library["status"] as? String == "completed", let rows = library["playlists"] as? [[String: Any]] else { fatalError("real library read failed") }
    precondition(rows.allSatisfy { $0["artworkURL"] is String && $0["provider"] is String && $0["count"] is NSNumber })
    let artworkCount = rows.filter { !($0["artworkURL"] as! String).isEmpty }.count
    print("PASS real card metadata: \(artworkCount) artwork URLs; provider/count preserved")
    count = rows.count; break
}
guard let count, count > 0 else { fatalError("no real playlists") }
print("PASS real read-only music library: \(count) playlists; no playback/account writes")
var maximumPulseBytes = 0
for _ in 0..<200 {
    guard let json = snapshot(host) else { fatalError("snapshot unavailable") }
    let data = Data(String(cString: json).utf8); release(json)
    let envelope = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let library = envelope["musicLibrary"] as! [String: Any]
    precondition(library["playlists"] == nil && library["tracks"] == nil)
    precondition((envelope["music"] as? [String: Any])?["queue"] == nil)
    maximumPulseBytes = max(maximumPulseBytes, data.count)
}
print("PASS 200 unchanged snapshots: no whole library/queue retransmission; maximum bytes=\(maximumPulseBytes)")

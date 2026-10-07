import Foundation
import AVFoundation
import Darwin

// Production packaged host, isolated state and a zero-valued PCM fixture only.
typealias Create = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> UnsafeMutableRawPointer?
typealias Command = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<CChar>) -> Int32
typealias Snapshot = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutablePointer<CChar>?
typealias Release = @convention(c) (UnsafeMutablePointer<CChar>) -> Void
typealias Destroy = @convention(c) (UnsafeMutableRawPointer) -> Int32
precondition(CommandLine.arguments.count == 2)
setenv("GMGN_UNITY_TEST_MUTED", "1", 1)
let root = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-music-muted-\(UUID())")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let wave = root.appendingPathComponent("silence.wav")
let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480000)!
pcm.frameLength = pcm.frameCapacity
pcm.floatChannelData![0].initialize(repeating: 0, count: Int(pcm.frameLength))
try AVAudioFile(forWriting: wave, settings: format.settings).write(from: pcm)
guard let lib = dlopen(CommandLine.arguments[1], RTLD_NOW | RTLD_LOCAL) else { fatalError(String(cString: dlerror())) }
func symbol<T>(_ name: String, _: T.Type) -> T { unsafeBitCast(dlsym(lib, name)!, to: T.self) }
let create = symbol("gmgn_unity_host_create", Create.self)
let command = symbol("gmgn_unity_host_command", Command.self)
let snapshot = symbol("gmgn_unity_host_snapshot", Snapshot.self)
let release = symbol("gmgn_unity_host_string_free", Release.self)
let destroy = symbol("gmgn_unity_host_destroy", Destroy.self)
guard let host = root.path.withCString({ path in "ai.gmgn.unity-sample.muted-\(UUID())".withCString { create(path, $0) } }) else { fatalError("Host unavailable") }
defer { _ = destroy(host) }
func music() throws -> [String: Any] {
    guard let raw = snapshot(host) else { fatalError("Missing snapshot") }
    let data = Data(String(cString: raw).utf8)
    release(raw)
    return (try JSONSerialization.jsonObject(with: data) as! [String: Any])["music"] as! [String: Any]
}
func send(_ value: [String: Any]) throws {
    let json = String(data: try JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
    precondition(json.withCString { command(host, $0) } == 1)
}
let initial = try music()
precondition(initial["volume"] as? Double == 0)
try send(["op": "music.load", "path": wave.path, "autoplay": true])
let deadline = Date().addingTimeInterval(3)
var advanced = false
while Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    let state = try music()
    precondition(state["volume"] as? Double == 0)
    if state["isPlaying"] as? Bool == true, (state["position"] as? Double ?? 0) > 0.2 {
        advanced = true
        break
    }
}
precondition(advanced, "Muted playback failed to advance")
try send(["op": "music.pause"])
let paused = try music()
precondition(paused["isPlaying"] as? Bool == false)
try send(["op": "music.play"])
let resumed = try music()
precondition(resumed["isPlaying"] as? Bool == true)
try send(["op": "music.stop"])
print("PASS: packaged host music load/play/clock/pause/resume/stop; test-muted volume stays 0; zero PCM, no account/network playback")

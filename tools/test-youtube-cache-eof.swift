import Foundation

// Read-only real YouTube third-item cache, isolated HTTP resource loader and AVPlayer.
// The temporary player is silent; no production queue, playback or volume is changed.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let paths = ["Screen/LinkResolver/ScreenLinkContract.swift", "Screen/NativeMedia/NativeScreenMediaDescriptor.swift", "Screen/NativeMedia/ScreenLinkAssetLoader.swift", "Screen/NativeMedia/NativeLinkPlayer.swift"]
var sources: [String] = []
for path in paths {
    let source = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/" + path)
    var text = try String(contentsOf: source, encoding: .utf8)
    if path.hasSuffix("NativeLinkPlayer.swift") {
        text += "\n extension NativeLinkPlayer { func testSeek(_ seconds: Double) async { await player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }; func testMute() { player?.isMuted = true; player?.volume = 0 }; func testTracks() async throws { for asset in sourceAssets { print(\"source duration=\\(CMTimeGetSeconds(try await asset.load(.duration)))\") }; for track in try await player!.currentItem!.asset.load(.tracks) { let range = try await track.load(.timeRange); print(\"track \\(track.mediaType) start=\\(CMTimeGetSeconds(range.start)) duration=\\(CMTimeGetSeconds(range.duration))\") } } }\n"
    }
    let out = tmp.appendingPathComponent(source.lastPathComponent)
    try text.write(to: out, atomically: true, encoding: .utf8)
    sources.append(out.path)
}
let inner = #"""
import Foundation
import Metal
import AVFoundation
@main struct Probe {
 @MainActor static func main() async throws {
  let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/gmgn radio/TaskService")
  let address = ProcessInfo.processInfo.environment["GMGN_EOF_FIXTURE_ADDRESS"]!
  let sql = Process(); let pipe = Pipe(); sql.executableURL = URL(fileURLWithPath:"/usr/bin/sqlite3"); sql.arguments = [support.appendingPathComponent("tasks.sqlite3").path, "select payload from media_cache where page_url like '%T_lC2O1oIew%';"]; sql.standardOutput = pipe; try sql.run()
  let data = pipe.fileHandleForReading.readDataToEndOfFile(); sql.waitUntilExit()
  let payload = try JSONSerialization.jsonObject(with:data) as! [String:Any]
  for key in ["video","audio"] { let part = payload[key] as! [String:Any]; let asset = AVURLAsset(url:URL(string:part["url"] as! String)!); print("LOCAL \(key) duration=\(CMTimeGetSeconds(try await asset.load(.duration)))") }
  let streams = ["video","audio"].compactMap { key -> NativeScreenMediaStream? in
   guard let value = payload[key] as? [String:Any] else {return nil}
   let cacheKey = "2cd64660b7194e39dd65d4e990feef162c6a5d453c20093572a26f3ced52b066"
   return NativeScreenMediaStream(url:"http://" + address + "/media/" + cacheKey + "/" + key, formatID:value["formatID"] as! String, headers:["Authorization":"Bearer isolated-fixture"], isVideo:key == "video", isAudio:key == "audio", isManifest:false)
  }
  let descriptor = NativeScreenMediaDescriptor(pageURL:"cache-read-only",title:"third playlist item",site:.youtube,isLive:false,streams:streams,note:"real HTTP EOF",durationSeconds:payload["durationSeconds"] as? Double)
  let expected = descriptor.durationSeconds!
  let live = NativeScreenMediaDescriptor(pageURL:"live",title:"live",site:.youtube,isLive:true,streams:streams,note:"live",durationSeconds:expected)
  let unknown = NativeScreenMediaDescriptor(pageURL:"unknown",title:"unknown",site:.youtube,isLive:false,streams:streams,note:"unknown")
  let doubled = CMTime(seconds:expected*2,preferredTimescale:600)
  precondition(CMTimeGetSeconds(NativeLinkPlayer.compositionSourceDuration(doubled,descriptor:live)) == expected*2)
  precondition(CMTimeGetSeconds(NativeLinkPlayer.compositionSourceDuration(doubled,descriptor:unknown)) == expected*2)
  let ordinary = CMTime(seconds:expected+0.5,preferredTimescale:600)
  precondition(NativeLinkPlayer.compositionSourceDuration(ordinary,descriptor:descriptor) == ordinary)
  for mode in ["split-tap","split-direct","muxed"] {
   let tap = mode != "split-direct"
   let muxed = [NativeScreenMediaStream(url:"http://" + address + "/muxed",formatID:"muxed",headers:["Authorization":"Bearer isolated-fixture"],isVideo:true,isAudio:true,isManifest:false)]
   let input = mode == "split-tap" ? descriptor : NativeScreenMediaDescriptor(pageURL:descriptor.pageURL,title:descriptor.title,site:.youtube,isLive:false,streams:mode == "muxed" ? muxed : streams.map {NativeScreenMediaStream(url:$0.url,formatID:$0.formatID,headers:[:],isVideo:$0.isVideo,isAudio:$0.isAudio,isManifest:false)},note:mode,durationSeconds:expected)
   let player = NativeLinkPlayer(device:MTLCreateSystemDefaultDevice()!,descriptor:input,audioSamplingOverride:tap)!
   var ends = 0; player.onPlaybackEnded = {ends += 1}; player.start()
   for _ in 0..<300 {player.testMute(); if player.durationSeconds != nil && player.playbackRate > 0 {break}; try await Task.sleep(for:.milliseconds(100))}
   guard let duration = player.durationSeconds else {fatalError("no duration phase=\(player.preparationPhase) status=\(player.itemStatus)")}
   print("mode=\(mode) tap=\(tap) duration=\(duration) frames=\(player.decodedFrameCount)"); try await player.testTracks()
   await player.testSeek(duration - 4)
   for tick in 0..<150 {if ends > 0 {break}; try await Task.sleep(for:.milliseconds(100)); if tick % 10 == 0 {print("tap=\(tap) seconds=\(player.currentSeconds) rate=\(player.playbackRate) control=\(player.timeControlStatus) state=\(player.state) end=\(ends)")}}
   print("RESULT tap=\(tap) end=\(ends) count=\(player.playbackEndCount) seconds=\(player.currentSeconds) duration=\(duration)")
   guard ends == 1, player.playbackEndCount == 1, abs(duration-expected) < 1, player.decodedFrameCount > 1 else { exit(1) }
   player.stop()
  }
  print("PASS real YouTube third-item HTTP EOF, native frames, no doubled blank tail; live/unknown/ordinary timing unchanged")
 }
}
"""#
let program = tmp.appendingPathComponent("Probe.swift")
try inner.write(to:program,atomically:true,encoding:.utf8)
let binary = tmp.appendingPathComponent("probe")
let compile = Process(); compile.executableURL=URL(fileURLWithPath:"/usr/bin/swiftc"); compile.arguments=["-j1","-parse-as-library"] + sources + [program.path,"-o",binary.path]; try compile.run(); compile.waitUntilExit(); guard compile.terminationStatus == 0 else {exit(70)}
var env=ProcessInfo.processInfo.environment
var fixture: Process?
defer { if let fixture, fixture.isRunning { fixture.terminate(); fixture.waitUntilExit() } }
if env["GMGN_EOF_FIXTURE_ADDRESS"] == nil {
    let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/gmgn radio/TaskService/media-cache")
    let key = "2cd64660b7194e39dd65d4e990feef162c6a5d453c20093572a26f3ced52b066"
    let muxed = tmp.appendingPathComponent("muxed.mp4")
    let remux = Process(); remux.executableURL=URL(fileURLWithPath:"/opt/homebrew/bin/ffmpeg")
    remux.arguments=["-nostdin","-v","error","-i",cache.appendingPathComponent(key + ".video.mp4").path,"-i",cache.appendingPathComponent(key + ".audio.m4a").path,"-c","copy","-movflags","+faststart",muxed.path]
    try remux.run(); remux.waitUntilExit(); guard remux.terminationStatus == 0 else {exit(70)}
    let server = Process(); let portPipe = Pipe(); server.executableURL=URL(fileURLWithPath:"/usr/bin/env"); server.arguments=["python3",root.appendingPathComponent("tools/youtube-cache-eof-http-fixture.py").path]
    var serverEnv=env; serverEnv["GMGN_EOF_MUXED_FILE"]=muxed.path; server.environment=serverEnv; server.standardOutput=portPipe
    try server.run(); fixture=server
    var port=Data()
    while let byte = try portPipe.fileHandleForReading.read(upToCount:1), !byte.isEmpty {if byte.first == 10 {break}; port.append(byte)}
    env["GMGN_EOF_FIXTURE_ADDRESS"]="127.0.0.1:" + String(decoding:port,as:UTF8.self)
}
let run=Process(); run.executableURL=binary; env["GMGN_UNITY_TEST_MUTED"]="1"; run.environment=env; try run.run(); run.waitUntilExit()
if let fixture, fixture.isRunning { fixture.terminate(); fixture.waitUntilExit() }
exit(run.terminationStatus)

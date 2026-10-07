import Foundation

// Explicit diagnostic against the installed service. Never plays audio, logs
// credentials or sends conversation text. Uses a fixed synthetic paragraph.
let preferences = try String(contentsOfFile: "apps/macos/Sources/GMGNRadio/Settings/AgentSettingsModel.swift", encoding: .utf8)
let settings = try String(contentsOfFile: "apps/macos/UnityHost/UnityProductSettings.swift", encoding: .utf8)
let p0 = preferences.range(of: "final class RustSpeechPreferences {")!.lowerBound
let p1 = preferences.range(of: "\nstruct BailianRealtimeModelOption", range: p0..<preferences.endIndex)!.lowerBound
let s0 = settings.range(of: "    private static func resolveVoiceConfiguration(")!.lowerBound
let s1 = settings.range(of: "    func voiceConfiguration(for purpose:", range: s0..<settings.endIndex)!.lowerBound
let program = "import Foundation\nenum E2ERuntime { static var defaults: UserDefaults { .standard } }\nenum RealtimeVoicePreferences { static let replyVoiceIDKey = \"speech.bailian.voiceID\" }\n" + preferences[p0..<p1] + "\nenum Resolution {\n" + settings[s0..<s1].replacingOccurrences(of: "private static func", with: "static func") + "}\n" + #"""
@main struct Probe {
 @MainActor static func main() async {
  let local = UserDefaults(suiteName: "ai.gmgn.unity-sample.player")!
  let product = UserDefaults(suiteName: "ai.gmgn.radio")!
  let config = Resolution.resolveVoiceConfiguration(for: "tts", defaults: local,
    speech: RustSpeechPreferences(defaults: local), productSpeech: RustSpeechPreferences(defaults: product))
  print("configuration provider=\(config.provider.rawValue) model=\(config.model ?? "default") credentialPresent=\(!config.apiKey.isEmpty)")
  let text = String(repeating: "这是一段流式语音完整性测试。请保持每一句连续输出，直到这段测试文字全部结束。", count: 6)
  var frames = 0, bytes = 0
  let started = Date()
  do {
   let stream = try await RustVoiceClient(allowsLaunching: false).startTTS(text: text, configuration: config)
   defer { stream.close() }
   while true {
    let event = try await stream.nextEvent()
    if event.type == "audio" {
     guard let encoded = event.audioBase64, let pcm = Data(base64Encoded: encoded) else { throw RustVoiceError.invalidFrame }
     frames += 1; bytes += pcm.count
     // Match production PCM playback consumption without opening an audio device.
     if CommandLine.arguments.contains("--paced") { try await Task.sleep(for: .seconds(Double(pcm.count) / 48000)) }
    } else if event.type == "finished" {
     print("PASS finished frames=\(frames) audioSeconds=\(Double(bytes)/48000) elapsed=\(Date().timeIntervalSince(started))"); return
    } else if event.type == "error" { throw RustVoiceError.rejected(event.code ?? "voice_failed") }
    else { throw RustVoiceError.invalidFrame }
   }
  } catch {
   let category: String
   switch error {
   case RustVoiceError.invalidFrame: category = "voice.invalidFrame"
   case RustVoiceError.unavailable: category = "voice.unavailable"
   case RustVoiceError.rejected(let code):
    let safe = !code.isEmpty && code.utf8.count <= 64 && code.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
    category = "voice.rejected." + (safe ? code : "redacted")
   case TaskdHTTPError.invalidFrame: category = "http.invalidFrame"
   case TaskdHTTPError.timedOut: category = "http.timedOut"
   case TaskdHTTPError.unavailable: category = "http.unavailable"
   default: category = String(describing: type(of: error))
   }
   print("FAIL category=\(category) frames=\(frames) audioSeconds=\(Double(bytes)/48000) elapsed=\(Date().timeIntervalSince(started))"); exit(2)
  }
 }
}
"""#
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-tts-stream-probe-" + UUID().uuidString)
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
defer { try? FileManager.default.removeItem(at: scratch) }
let source = scratch.appendingPathComponent("probe.swift"), binary = scratch.appendingPathComponent("probe")
try program.write(to: source, atomically: true, encoding: .utf8)
var clientSource = "apps/macos/Sources/GMGNRadio/Agent/RustVoiceClient.swift"
if CommandLine.arguments.contains("--baseline") {
 let read = Process(); read.executableURL = URL(fileURLWithPath: "/usr/bin/git")
 read.arguments = ["show", "HEAD:" + clientSource]
 let output = Pipe(); read.standardOutput = output
 try read.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); read.waitUntilExit()
 guard read.terminationStatus == 0 else { exit(read.terminationStatus) }
 let baseline = scratch.appendingPathComponent("RustVoiceClient.swift")
 try data.write(to: baseline); clientSource = baseline.path
}
print("client=\(CommandLine.arguments.contains("--baseline") ? "HEAD baseline" : "working tree")")
let build = Process(); build.executableURL = URL(fileURLWithPath: "/usr/bin/env")
build.arguments = ["swiftc", "-j1", "-swift-version", "6", "-parse-as-library", clientSource, "apps/macos/Sources/GMGNRadio/Presence/TaskdHTTPTransport.swift", source.path, "-o", binary.path]
try build.run(); build.waitUntilExit(); guard build.terminationStatus == 0 else { exit(build.terminationStatus) }
let probe = Process(); probe.executableURL = binary; probe.arguments = Array(CommandLine.arguments.dropFirst())
try probe.run(); probe.waitUntilExit(); exit(probe.terminationStatus)

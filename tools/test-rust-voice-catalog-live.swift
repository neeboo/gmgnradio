import Foundation

// Opt-in diagnostic: uses the production Swift client against an existing
// isolated taskd. Catalog only, no ASR, audio playback, or cloud TTS.
guard CommandLine.arguments.count == 2 else { fatalError("expected isolated TaskService root") }
let preferenceSource = try String(contentsOfFile: "apps/macos/Sources/GMGNRadio/Settings/AgentSettingsModel.swift", encoding: .utf8)
let preferenceStart = preferenceSource.range(of: "final class RustSpeechPreferences {")!.lowerBound
let preferenceEnd = preferenceSource.range(of: "\nstruct BailianRealtimeModelOption", range: preferenceStart..<preferenceSource.endIndex)!.lowerBound
let program = "import Foundation\nenum E2ERuntime { static var defaults: UserDefaults { UserDefaults.standard } }\nenum RealtimeVoicePreferences { static let replyVoiceIDKey = \"speech.bailian.voiceID\" }\n" + String(preferenceSource[preferenceStart..<preferenceEnd]) + "\n" + #"""
import Foundation
@main struct Probe {
 @MainActor static func main() async {
  let root = URL(fileURLWithPath: CommandLine.arguments[1])
  do {
   let voices = try await RustVoiceClient(root: root, allowsLaunching: false).listVoices(configuration: .init(provider: .bailian, apiKey: ""))
   print("PASS: production Swift client actual taskd catalog count \(voices.count)")
   let preferences = RustSpeechPreferences(defaults: UserDefaults(suiteName: "ai.gmgn.radio")!)
   for provider in [RustVoiceProvider.fish, .elevenlabs] {
    let configuration = preferences.configuration(provider: provider, for: "tts", includesEnvironment: false)
    guard !configuration.apiKey.isEmpty else { print("SKIP: \(provider.rawValue) credentials not configured"); continue }
    do {
     let catalog = try await RustVoiceClient(root: root, allowsLaunching: false).listVoices(configuration: configuration)
     print("PASS: \(provider.rawValue) authenticated catalog count \(catalog.count)")
    } catch { print("FAIL: \(provider.rawValue) catalog unavailable"); exit(2) }
   }
  } catch RustVoiceError.invalidFrame { print("FAIL: invalidFrame"); exit(2) }
  catch RustVoiceError.unavailable { print("FAIL: unavailable"); exit(2) }
  catch RustVoiceError.rejected { print("FAIL: rejected"); exit(2) }
  catch { print("FAIL: other"); exit(2) }
 }
}
"""#
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-live-catalog-" + UUID().uuidString)
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
defer { try? FileManager.default.removeItem(at: scratch) }
let source = scratch.appendingPathComponent("probe.swift"), binary = scratch.appendingPathComponent("probe")
try program.write(to: source, atomically: true, encoding: .utf8)
let build = Process(); build.executableURL = URL(fileURLWithPath: "/usr/bin/env")
build.arguments = ["swiftc", "-swift-version", "6", "-parse-as-library", "apps/macos/Sources/GMGNRadio/Agent/RustVoiceClient.swift", "apps/macos/Sources/GMGNRadio/Presence/TaskdHTTPTransport.swift", source.path, "-o", binary.path]
try build.run(); build.waitUntilExit(); guard build.terminationStatus == 0 else { exit(build.terminationStatus) }
let probe = Process(); probe.executableURL = binary; probe.arguments = [CommandLine.arguments[1]]
try probe.run(); probe.waitUntilExit(); exit(probe.terminationStatus)

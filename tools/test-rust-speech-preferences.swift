import Foundation

// Compile the production preferences declaration. Only fake credentials and
// disposable defaults are used; no ASR, cloud request, or recording is started.
let source = try String(contentsOfFile: "apps/macos/Sources/GMGNRadio/Settings/AgentSettingsModel.swift", encoding: .utf8)
let start = source.range(of: "final class RustSpeechPreferences {")!.lowerBound
let end = source.range(of: "\nstruct BailianRealtimeModelOption", range: start..<source.endIndex)!.lowerBound
let preferences = String(source[start..<end])
let checks = #"""
import Foundation
enum RustVoiceProvider: String { case bailian, elevenlabs, fish }
struct RustVoiceConfiguration {
 let provider: RustVoiceProvider; let apiKey: String; let voiceID: String; let model: String?
}
enum E2ERuntime { static let defaults = UserDefaults.standard }
enum RealtimeVoicePreferences { static let replyVoiceIDKey = "speech.bailian.voiceID" }
"""# + "\n" + preferences + #"""

let name = "gmgn-voice-preferences-check-" + UUID().uuidString
let defaults = UserDefaults(suiteName: name)!
defer { defaults.removePersistentDomain(forName: name) }
let prefs = RustSpeechPreferences(defaults: defaults)
var checks = 0
func check(_ value: Bool) { guard value else { fatalError("voice preference behavior check failed") }; checks += 1 }
let before = prefs.configuration(provider: .elevenlabs, for: "tts")
check(before.apiKey == "fixture-env-key")
prefs.save(RustVoiceConfiguration(provider: .elevenlabs, apiKey: "", voiceID: "chosen-voice", model: nil), for: "tts")
let after = prefs.configuration(for: "tts")
check(after.apiKey == "fixture-env-key" && after.voiceID == "chosen-voice")
check(defaults.string(forKey: "speech.rust.elevenlabs.apiKey") == "")
check(!String(describing: defaults.persistentDomain(forName: name)!).contains("fixture-env-key"))
check(prefs.configuration(for: "tts", includesEnvironment: false).apiKey.isEmpty)
defaults.set(" \n ", forKey: "speech.rust.elevenlabs.apiKey")
check(prefs.configuration(for: "tts").apiKey == "fixture-env-key")
defaults.set("fixture-saved-key", forKey: "speech.rust.elevenlabs.apiKey")
check(prefs.configuration(for: "tts").apiKey == "fixture-saved-key")
defaults.set("fixture-legacy-key", forKey: "voice.bailian.apiKey")
defaults.set("  ", forKey: "speech.rust.bailian.apiKey")
check(prefs.configuration(provider: .bailian, for: "tts", includesEnvironment: false).apiKey == "fixture-legacy-key")
prefs.save(RustVoiceConfiguration(provider: .bailian, apiKey: "fixture-key", voiceID: "qwen-custom-fixture", model: "qwen3-tts-vc-realtime-2026-01-15"), for: "tts")
let custom = prefs.configuration(for: "tts", includesEnvironment: false)
check(custom.voiceID == "qwen-custom-fixture" && custom.model == "qwen3-tts-vc-realtime-2026-01-15")
prefs.save(RustVoiceConfiguration(provider: .fish, apiKey: "", voiceID: "fish-custom-fixture", model: "s2.1-pro-free"), for: "tts")
check(prefs.configuration(for: "tts", includesEnvironment: false).model == "s2.1-pro-free")
defaults.set("old-unsupported-model", forKey: "speech.rust.fish.tts.model")
check(prefs.configuration(for: "tts", includesEnvironment: false).model == "old-unsupported-model")
print("PASS: \(checks) production voice preference save and credential fallback checks; no ASR or cloud requests")
"""#
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-voice-preferences-" + UUID().uuidString)
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
defer { try? FileManager.default.removeItem(at: scratch) }
let file = scratch.appendingPathComponent("checks.swift")
try checks.write(to: file, atomically: true, encoding: .utf8)
let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
process.arguments = ["swift", file.path]
// Deliberately omit inherited provider keys so only the fake fallback is tested.
process.environment = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin", "ELEVENLABS_API_KEY": "fixture-env-key"]
try process.run(); process.waitUntilExit(); exit(process.terminationStatus)

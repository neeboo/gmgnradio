import Foundation

// Opt-in diagnostic: uses the production Swift client against an existing
// isolated taskd. Catalog only, no ASR, audio playback, or cloud TTS.
guard CommandLine.arguments.count == 2 else { fatalError("expected isolated TaskService root") }
let program = #"""
import Foundation
@main struct Probe {
 @MainActor static func main() async {
  let root = URL(fileURLWithPath: CommandLine.arguments[1])
  do {
   let voices = try await RustVoiceClient(root: root, allowsLaunching: false).listVoices(configuration: .init(provider: .bailian, apiKey: ""))
   print("PASS: production Swift client actual taskd catalog count \(voices.count)")
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
build.arguments = ["swiftc", "-swift-version", "6", "-parse-as-library", "apps/macos/Sources/GMGNRadio/Agent/RustVoiceClient.swift", source.path, "-o", binary.path]
try build.run(); build.waitUntilExit(); guard build.terminationStatus == 0 else { exit(build.terminationStatus) }
let probe = Process(); probe.executableURL = binary; probe.arguments = [CommandLine.arguments[1]]
try probe.run(); probe.waitUntilExit(); exit(probe.terminationStatus)

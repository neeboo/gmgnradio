import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = try String(contentsOf: root.appendingPathComponent("apps/macos/Sources/GMGNRadio/AudioEngine/AudioGraphController.swift"), encoding: .utf8)
let end = source.range(of: "enum BailianPCMCodecError:")!.lowerBound
let production = String(source[..<end])
let fixtures = """
struct RealtimeDJAudioLevel: Sendable { var rms: Double; var peak: Double }
enum BailianMicrophoneCaptureError: Error { case noMicrophone, cannotAddInput, cannotAddOutput, invalidAudioBuffer }
struct BailianMicrophoneDeviceOption { var id: String; var name: String }
enum BailianMicrophoneDeviceSelector {
    static func preferredID(requestedID: String?, defaultID: String?, devices: [BailianMicrophoneDeviceOption]) -> String? {
        requestedID ?? defaultID ?? devices.first?.id
    }
}
enum BailianPCMCodec {
    static func audioLevel(for data: Data) -> RealtimeDJAudioLevel { .init(rms: 0, peak: 0) }
}
enum BailianMicrophoneCapture {
    static var audioSettings: [String: Any] { [:] }
}
"""
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-ptt-capture-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: temporary) }
let file = temporary.appendingPathComponent("Capture.swift")
try (production + fixtures).write(to: file, atomically: true, encoding: .utf8)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
process.arguments = ["swiftc", "-swift-version", "6", "-strict-concurrency=complete", "-warnings-as-errors", "-typecheck", file.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
// Device capture is intentionally never instantiated here (no permission prompt).
precondition(production.contains("queue.async") && production.contains("func stop() async"))
precondition(production.contains("by: 32_768"))
precondition(!production.contains("URLSession") && !production.contains("engine.stop"))
print("PASS: production device adapter compiles with Swift 6 strict concurrency; bounded chunks and drained stop; microphone not opened")

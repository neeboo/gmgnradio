import Foundation

let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let work = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-media-helper-config-\(UUID())")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }
let harness = #"""
import Foundation
@main struct Checks {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let daemon = directory.appendingPathComponent("gmgn-taskd")
        let video = directory.appendingPathComponent("yt-dlp")
        let runtime = directory.appendingPathComponent("deno")
        var checks = 0
        func check(_ value: Bool, _ label: String) {
            precondition(value, label); checks += 1; print("PASS \(label)")
        }
        func sidecar(_ helper: URL, _ value: String) throws {
            try Data(value.utf8).write(to: helper.appendingPathExtension("sha256"))
        }
        check(TaskdBundledMediaConfiguration.arguments(nextTo: daemon).isEmpty, "missing helpers are not discovered from PATH")
        for helper in [video, runtime] {
            try Data("fixture".utf8).write(to: helper)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        }
        let videoHash = String(repeating: "a", count: 64)
        let runtimeHash = String(repeating: "b", count: 64)
        try sidecar(video, "\(videoHash)  yt-dlp\n")
        try sidecar(runtime, "\(runtimeHash)  deno\n")
        check(TaskdBundledMediaConfiguration.arguments(nextTo: daemon) == [
            "--media-helper", video.path, "--media-helper-sha256", videoHash,
            "--media-deno", runtime.path, "--media-deno-sha256", runtimeHash
        ], "both absolute bundled paths and expected hashes are passed to Rust")
        try sidecar(runtime, "\(runtimeHash)  different-binary\n")
        check(TaskdBundledMediaConfiguration.arguments(nextTo: daemon).isEmpty, "sidecar filename mismatch is rejected")
        try sidecar(runtime, "\(String(repeating: "z", count: 64))  deno\n")
        check(TaskdBundledMediaConfiguration.arguments(nextTo: daemon).isEmpty, "malformed hash is rejected")
        try sidecar(runtime, String(repeating: "a", count: 257))
        check(TaskdBundledMediaConfiguration.arguments(nextTo: daemon).isEmpty, "oversized sidecar is rejected")
        try sidecar(runtime, "\(runtimeHash)  deno\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: runtime.path)
        check(TaskdBundledMediaConfiguration.arguments(nextTo: daemon).isEmpty, "non-executable runtime is rejected")
        print("\(checks) checks passed")
    }
}
"""#
let main = work.appendingPathComponent("Checks.swift")
try Data(harness.utf8).write(to: main)
let binary = work.appendingPathComponent("checks")
func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process(); process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments; try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
}
try run("/usr/bin/swiftc", ["-swift-version", "6", "-parse-as-library",
    repository.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/TaskdHTTPTransport.swift").path,
    main.path, "-o", binary.path])
try run(binary.path, [work.path])

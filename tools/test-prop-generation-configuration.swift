import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/PropGenerationConfiguration.swift")
guard FileManager.default.fileExists(atPath: source.path) else {
    print("FAIL: prop generation configuration is missing")
    exit(1)
}
let program = #"""
import Foundation

@main struct Checks {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) {
            guard value else { fatalError("FAIL: " + label) }
            checks += 1
        }
        func rejects(_ label: String, _ action: () throws -> Void) {
            do { try action(); fatalError("FAIL: " + label) } catch { checks += 1 }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("prop-config-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("private/config.json")
        let store = PropGenerationConfigurationStore(fileURL: file)
        check(try store.load() == nil, "missing configuration is not configured")
        let config = try PropGenerationConfiguration(endpoint: URL(string: "http://127.0.0.1:8191/")!, token: "local-test-token")
        check(config.endpoint.absoluteString == "http://127.0.0.1:8191", "origin is normalized by client rules")
        try store.save(config)
        check(try store.load() == config, "configuration survives reload")
        let directoryMode = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as! NSNumber
        let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber
        check(directoryMode.intValue == 0o700, "private directory permissions")
        check(fileMode.intValue == 0o600, "private file permissions")
        check(!String(describing: config).contains("local-test-token"), "description redacts token")
        check(!String(reflecting: config).contains("local-test-token"), "debug description redacts token")
        for address in ["http://dgx.local:8191", "https://example.org/path", "https://u:p@example.org", "https://example.org?key=secret", "file:///tmp/service"] {
            rejects("unsafe origin is rejected") { _ = try PropGenerationConfiguration(endpoint: URL(string: address)!, token: "test") }
        }
        for token in ["", "   ", "test\nsecret", "test\rsecret"] {
            rejects("invalid token is rejected") { _ = try PropGenerationConfiguration(endpoint: URL(string: "https://example.org")!, token: token) }
        }
        let saved = try Data(contentsOf: file)
        rejects("malformed persisted configuration is rejected") {
            try Data(#"{"endpoint":"http://external.test","token":"test"}"#.utf8).write(to: file)
            _ = try store.load()
        }
        check(try Data(contentsOf: file) != saved, "failed load preserves file for recovery")
        try saved.write(to: file)
        check(try store.load() == config, "restored configuration remains valid")
        print("PASS: \(checks) prop generation configuration checks")
    }
}
"""#
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("prop-config-harness-" + UUID().uuidString)
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let main = temporary.appendingPathComponent("Checks.swift")
try program.write(to: main, atomically: true, encoding: .utf8)
let binary = temporary.appendingPathComponent("checks")
let compiler = Process()
compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
compiler.arguments = ["swiftc", "-j1", "-swift-version", "6", "-strict-concurrency=complete", "-parse-as-library", source.path,
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/PropGenerationClient.swift").path,
    main.path, "-o", binary.path]
try compiler.run()
compiler.waitUntilExit()
guard compiler.terminationStatus == 0 else { exit(compiler.terminationStatus) }
let runner = Process()
runner.executableURL = binary
try runner.run()
runner.waitUntilExit()
exit(runner.terminationStatus)

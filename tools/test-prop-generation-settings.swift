// Execute production settings callbacks without opening a window or accessing real credentials.
import Foundation

let path = "apps/macos/Sources/GMGNRadio/Settings/PropGenerationSettingsSection.swift"
let source = try String(contentsOfFile: path, encoding: .utf8)
func method(_ signature: String) -> String {
    let start = source.range(of: signature)!.lowerBound
    let open = source[start...].firstIndex(of: "{")!
    var depth = 0
    for index in source[open...].indices {
        if source[index] == "{" { depth += 1 }
        if source[index] == "}" { depth -= 1 }
        if depth == 0 { return String(source[start...index]) }
    }
    fatalError("Unterminated production callback")
}
let methods = ["private func cancelCheck()", "private func checkConnection()"].map(method).joined(separator: "\n")
let harness = #"""
import Foundation
enum PropGenerationError: Error { case invalidEndpoint; var errorDescription: String? { "地址不可用。" } }
struct PropGenerationConfiguration {
    let endpoint: URL; let token: String
    init(endpoint: URL, token: String) throws {
        guard endpoint.scheme == "http" || endpoint.scheme == "https" else { throw PropGenerationError.invalidEndpoint }
        self.endpoint = endpoint; self.token = token
    }
}
@MainActor final class Store {
    var value: PropGenerationConfiguration?
    var broken = false
    func load() throws -> PropGenerationConfiguration? {
        if broken { throw PropGenerationError.invalidEndpoint }
        return value
    }
}
@MainActor struct PropGenerationClient {
    struct Health { let message: String }
    static var calls: [(URL, String)] = []
    static var completions: [CheckedContinuation<Health, Error>] = []
    let endpoint: URL; let token: String
    func health() async throws -> Health {
        Self.calls.append((endpoint, token))
        return try await withCheckedThrowingContinuation { Self.completions.append($0) }
    }
}
@MainActor final class Settings {
    let store = Store()
    var endpoint = "http://127.0.0.1:8191"
    var checkID: UUID?
    var checkTask: Task<Void, Never>?
    var message: String?
    var hasError = false
    \#(methods)
    func check() { checkConnection() }
    func close() { cancelCheck() }
}
@main struct Tests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) {
            precondition(value, label); checks += 1
        }
        func settle() async { for _ in 0..<20 { await Task.yield() } }
        let ui = Settings()
        ui.check()
        check(ui.hasError && PropGenerationClient.calls.isEmpty, "unconfigured check does not send a request")
        ui.store.value = try .init(endpoint: URL(string: ui.endpoint)!, token: "fixture-only")
        ui.endpoint = "https://changed.example"
        ui.check()
        check(ui.hasError && PropGenerationClient.calls.isEmpty, "unsaved endpoint cannot receive stored credentials")
        ui.endpoint = "http://127.0.0.1:8191"
        ui.check(); await settle()
        check(ui.checkID != nil && PropGenerationClient.calls.count == 1, "connection check starts once")
        check(PropGenerationClient.calls[0].1 == "fixture-only", "check uses the saved configuration")
        PropGenerationClient.completions.removeFirst().resume(returning: .init(message: "ready"))
        await settle()
        check(ui.message == "ready" && !ui.hasError && ui.checkID == nil, "success clears busy status")
        ui.check(); await settle()
        ui.close(); ui.message = "edited"
        PropGenerationClient.completions.removeFirst().resume(returning: .init(message: "stale"))
        await settle()
        check(ui.message == "edited" && ui.checkID == nil, "closed or edited settings ignore late completion")
        ui.check(); await settle()
        let old = PropGenerationClient.completions.removeFirst()
        ui.check(); await settle()
        let newID = ui.checkID
        old.resume(returning: .init(message: "obsolete")); await settle()
        check(ui.checkID == newID && ui.message == nil, "old completion cannot clear newer in-flight check")
        PropGenerationClient.completions.removeFirst().resume(throwing: URLError(.notConnectedToInternet))
        await settle()
        check(ui.hasError && ui.message?.contains("暂时无法连接") == true && ui.checkID == nil, "network failure is actionable and not left busy")
        ui.store.broken = true; ui.check()
        check(ui.hasError && ui.message?.contains("配置无法读取") == true, "unreadable local config reports without accessing service")
        print("PASS: \(checks) production settings callback checks; no host or real credentials")
    }
}
"""#
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-health-settings-\(UUID())")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let test = directory.appendingPathComponent("Tests.swift"), binary = directory.appendingPathComponent("test")
try harness.write(to: test, atomically: true, encoding: .utf8)
func run(_ path: String, _ arguments: [String]) throws -> Int32 {
    let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
    try process.run(); process.waitUntilExit(); return process.terminationStatus
}
let status = try run("/usr/bin/swiftc", ["-j1", "-parse-as-library", test.path, "-o", binary.path])
guard status == 0 else { exit(status) }
exit(try run(binary.path, []))

// Executes the production GPUI bridge callbacks; no host, service or real credentials.
import Foundation
let source = try String(contentsOfFile: "apps/macos/ProductHost/ProductSettingsParity.swift", encoding: .utf8)
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
let methods = ["private func cancelPropCheck()", "private func checkProps("].map(method).joined(separator: "\n")
let harness = #"""
import Foundation
enum PropGenerationError: Error { case invalid; var errorDescription: String? { nil } }
struct PropGenerationConfiguration {
    let endpoint: URL; let token: String
    init(endpoint: URL, token: String) throws {
        self.endpoint = URL(string: endpoint.absoluteString.hasSuffix("/") ? String(endpoint.absoluteString.dropLast()) : endpoint.absoluteString)!
        self.token = token
    }
}
@MainActor final class Store {
    var value: PropGenerationConfiguration?
    var broken = false
    func load() throws -> PropGenerationConfiguration? {
        if broken { throw PropGenerationError.invalid }; return value
    }
}
@MainActor struct PropGenerationClient {
    struct Health { let message: String }
    static var calls: [URL] = []
    static var completions: [CheckedContinuation<Health, Error>] = []
    let endpoint: URL; let token: String
    func health() async throws -> Health {
        Self.calls.append(endpoint)
        return try await withCheckedThrowingContinuation { Self.completions.append($0) }
    }
}
@MainActor final class Settings {
    let props = Store()
    var spaceNotice: String?
    var propCheckID: UUID?
    var propCheckTask: Task<Void, Never>?
    var propChecking = false
    \#(methods)
    func check(_ endpoint: String) { checkProps(["endpoint":endpoint]) }
    func cancel() { cancelPropCheck() }
}
@main struct Tests {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ result: Bool, _ name: String) { precondition(result, name); count += 1 }
        func settle() async { for _ in 0..<30 { await Task.yield() } }
        let ui = Settings()
        ui.check("https://saved.example")
        check(PropGenerationClient.calls.isEmpty && ui.spaceNotice?.contains("先保存") == true, "missing configuration")
        ui.props.value = try .init(endpoint: URL(string:"https://saved.example")!, token:"fixture-only")
        ui.check("https://changed.example")
        check(PropGenerationClient.calls.isEmpty && ui.spaceNotice?.contains("先保存") == true, "unsaved endpoint never receives saved credential")
        ui.check(" https://saved.example/ "); await settle()
        check(ui.propChecking && PropGenerationClient.calls == [URL(string:"https://saved.example")!], "normalized saved endpoint starts check")
        PropGenerationClient.completions.removeFirst().resume(returning:.init(message:"ready")); await settle()
        check(ui.spaceNotice == "ready" && !ui.propChecking, "success clears busy")
        ui.check("https://saved.example"); await settle()
        ui.cancel(); ui.spaceNotice = "edited"
        PropGenerationClient.completions.removeFirst().resume(returning:.init(message:"late")); await settle()
        check(ui.spaceNotice == "edited" && !ui.propChecking, "cancel ignores late response")
        ui.check("https://saved.example"); await settle()
        let old = PropGenerationClient.completions.removeFirst()
        ui.check("https://saved.example"); await settle()
        let current = ui.propCheckID
        old.resume(returning:.init(message:"obsolete")); await settle()
        check(ui.propCheckID == current && ui.propChecking && ui.spaceNotice == nil, "old cleanup cannot clear newer request")
        PropGenerationClient.completions.removeFirst().resume(throwing:URLError(.notConnectedToInternet)); await settle()
        check(!ui.propChecking && ui.spaceNotice?.contains("暂时无法连接") == true, "failure clears busy")
        ui.props.broken = true; ui.check("https://saved.example")
        check(ui.spaceNotice?.contains("配置无法读取") == true, "unreadable configuration")
        print("PASS: \(count) production GPUI health callback checks; no host or real credentials")
    }
}
"""#
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-gpui-health-\(UUID())")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }
let file = dir.appendingPathComponent("main.swift")
try harness.write(to: file, atomically: true, encoding: .utf8)
let compiler = Process(); compiler.executableURL = URL(fileURLWithPath:"/usr/bin/swiftc")
let binary = dir.appendingPathComponent("tests")
compiler.arguments = ["-parse-as-library", file.path, "-o", binary.path]
try compiler.run(); compiler.waitUntilExit(); precondition(compiler.terminationStatus == 0)
let runner = Process(); runner.executableURL = binary
try runner.run(); runner.waitUntilExit(); precondition(runner.terminationStatus == 0)

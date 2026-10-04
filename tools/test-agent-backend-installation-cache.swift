import Foundation
let source = try String(contentsOfFile: "apps/macos/Sources/GMGNRadio/Agent/AgentConversationService.swift", encoding: .utf8)
let start = source.range(of: "    func installedBackends(refresh:")!.lowerBound
let opening = source[start...].firstIndex(of: "{")!
var depth = 0
var end = opening
for index in source[opening...].indices {
    if source[index] == "{" { depth += 1 }
    if source[index] == "}" { depth -= 1 }
    if depth == 0 { end = source.index(after: index); break }
}
let method = String(source[start..<end])
let harness = """
import Foundation
struct AgentConversationBackend { let kind: Int }
enum AgentConversationBackends { static let all = [AgentConversationBackend(kind: 1), AgentConversationBackend(kind: 2)] }
final class Service {
    var installedBackendCache: (checkedAt: Date, backends: [AgentConversationBackend])?
    var scans = 0
    var installed = Set([1])
    func isInstalled(_ id: Int) -> Bool { scans += 1; return installed.contains(id) }
\(method)
}
let service = Service()
for _ in 0..<50 { precondition(service.installedBackends().map(\\.kind) == [1]) }
precondition(service.scans == 2, "50 fast UI polls must perform only one directory discovery")
service.installed.insert(2)
precondition(service.installedBackends(refresh: true).map(\\.kind) == [1,2])
precondition(service.scans == 4, "explicit settings load refresh discovers new installation")
service.installed.remove(1)
service.installedBackendCache!.checkedAt = Date(timeIntervalSinceNow: -6)
precondition(service.installedBackends().map(\\.kind) == [2] && service.scans == 6)
precondition(!service.isInstalled(1) && service.scans == 7, "runtime executable checks remain uncached")
print("PASS: actual installedBackends method, 50 polls one scan, explicit refresh, five-second expiry and uncached runtime check")
"""
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-backend-cache-\(UUID())")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let file = directory.appendingPathComponent("callback.swift")
try harness.write(to: file, atomically: true, encoding: .utf8)
let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/swift"); process.arguments = [file.path]
try process.run(); process.waitUntilExit(); exit(process.terminationStatus)

// CPU-only: compile and exercise the actual App refresh method without a host.
import Foundation

let source = try String(contentsOfFile: "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift", encoding: .utf8)
let signature = "private func refreshResidentAutonomy()"
guard let start = source.range(of: signature)?.lowerBound,
      let open = source[start...].firstIndex(of: "{") else {
    fatalError("Missing production autonomy refresh method")
}
var depth = 0
var end: String.Index?
for index in source[open...].indices {
    if source[index] == "{" { depth += 1 }
    if source[index] == "}" { depth -= 1 }
    if depth == 0 { end = index; break }
}
guard let end else { fatalError("Unbalanced production method") }
let method = String(source[start...end]).replacingOccurrences(of: "private func", with: "func")
let harness = #"""
import Foundation

// Isolate the existing on/off preference; never read the user's defaults.
struct UserDefaults {
    static let standard = UserDefaults()
    func bool(forKey key: String) -> Bool { true }
}
@MainActor final class ResidentPreferences {
    static var savedLimit = 6
    var backgroundTurnsPerHour: Int { Self.savedLimit }
}
@MainActor final class AgentConversationService {
    static let shared = AgentConversationService()
    var supportsWorldTools = true
}
struct Manifest { var worldID = "cabin" }
struct World { var manifest = Manifest() }
struct Stage { var selectedWorldID = "cabin" }
@MainActor final class Loop {
    var memoryRestoreBlocksAutonomy = false
    var limit = 6
    var ticks: [Int] = []
    var backgroundUpdates: [Bool] = []
    func setBackgroundTurnsPerHour(_ value: Int) { limit = value }
    func setBackgroundEnabled(_ value: Bool) { backgroundUpdates.append(value) }
    func tick() { ticks.append(limit) }
}
@MainActor final class App {
    var residentPropEditingWorldID: String?
    var livingWorldContext: World? = World()
    var spatialStage = Stage()
    var residentAgentLoop: Loop? = Loop()
    var restores = 0
    var returns = 0
    func ensureResidentLoop() -> Loop { residentAgentLoop! }
    func scheduleResidentMemoryRestoreIfNeeded(loop: Loop) { restores += 1 }
    func returnHeldPropBeforeResidentStop(reason: String) -> Bool { returns += 1; return true }
    \#(method)
}
@main struct Check {
    @MainActor static func main() {
        var failures = 0
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures += 1; print("FAIL: \(message)") }
        }
        let app = App()
        let loop = app.residentAgentLoop!
        ResidentPreferences.savedLimit = 2
        app.refreshResidentAutonomy()
        check(loop.ticks == [2], "saved budget is applied before the first tick")
        ResidentPreferences.savedLimit = 0
        app.refreshResidentAutonomy()
        check(loop.ticks == [2, 0], "changing budget reaches the next tick without replacing the loop")
        loop.memoryRestoreBlocksAutonomy = true
        ResidentPreferences.savedLimit = 4
        app.refreshResidentAutonomy()
        check(loop.limit == 4, "budget changes are applied while waiting for memory restore")
        check(loop.ticks == [2, 0] && app.restores == 1, "restore still blocks autonomous execution")
        app.residentPropEditingWorldID = "cabin"
        app.refreshResidentAutonomy()
        check(loop.ticks == [2, 0] && app.restores == 1, "editing still suppresses autonomy")
        app.residentPropEditingWorldID = nil
        AgentConversationService.shared.supportsWorldTools = false
        app.refreshResidentAutonomy()
        check(loop.backgroundUpdates.last == false && app.returns == 1,
              "unsupported backends remain disabled")
        print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) autonomy preferences App checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-autonomy-preferences-\(UUID())")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let test = directory.appendingPathComponent("Test.swift")
try harness.write(to: test, atomically: true, encoding: .utf8)
let binary = directory.appendingPathComponent("check")
func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}
let compile = try run("/usr/bin/swiftc", ["-swift-version", "6", "-parse-as-library", test.path, "-o", binary.path])
guard compile == 0 else { exit(compile) }
exit(try run(binary.path, []))

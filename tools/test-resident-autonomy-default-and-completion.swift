import Foundation
func declaration(_ text: String, signature: String) -> String {
    let start = text.range(of: signature)!.lowerBound
    let opening = text[start...].firstIndex(of: "{")!
    var depth = 0
    for index in text[opening...].indices {
        if text[index] == "{" { depth += 1 }
        if text[index] == "}" { depth -= 1 }
        if depth == 0 { return String(text[start...index]).replacingOccurrences(of: "private func", with: "func") }
    }
    fatalError("unterminated production declaration")
}
let presentation = try String(contentsOfFile: "apps/macos/Sources/GMGNRadio/Presence/WishMachineTaskPresentation.swift", encoding: .utf8)
let coordinator = try String(contentsOfFile: "apps/macos/Sources/GMGNRadio/Presence/WishMachineCoordinator.swift", encoding: .utf8)
let app = try String(contentsOfFile: "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift", encoding: .utf8)
let product = try String(contentsOfFile: "apps/macos/ProductHost/ProductHost.swift", encoding: .utf8)
for entry in [declaration(app, signature: "func applicationDidFinishLaunching("),
              declaration(product, signature: "public func gmgnProductHostCreate(")] {
    precondition(entry.contains("E2ERuntime.bootstrap()\n        ResidentAutonomySwitch.registerDefaults()")
        || entry.contains("E2ERuntime.bootstrap()\n    ResidentAutonomySwitch.registerDefaults()"),
        "both direct GPUI creation and AppDelegate lifecycle register defaults after isolated bootstrap")
}
let harness = """
import Foundation
\(declaration(presentation, signature: "enum ResidentAutonomySwitch"))
struct WishMachineJob: Equatable { var autoContinuationPaused: Bool? = true; var autoContinuationStoppedByUser: Bool? = true; var continuationResumeAuthorizationIDs:[UUID] = [] }
enum Placement: Equatable {case revoked, placed}
struct Delegation: Equatable {var state = Placement.revoked}
enum Failure: Error {case persistence}
final class Coordinator {
    var jobs = [WishMachineJob()]
    var delegations = [Delegation()]
    var events = ["existing fact"]
    var fails = false
    func persist() throws {if fails {throw Failure.persistence}}
\(declaration(coordinator, signature: "private func finishAlreadyPlacedContinuation("))
}
let suite = "gmgn-autonomy-default-test-" + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer {defaults.removePersistentDomain(forName: suite)}
ResidentAutonomySwitch.registerDefaults(in: defaults)
precondition(defaults.bool(forKey: ResidentAutonomySwitch.defaultsKey))
defaults.set(false, forKey: ResidentAutonomySwitch.defaultsKey)
ResidentAutonomySwitch.registerDefaults(in: defaults)
precondition(!defaults.bool(forKey: ResidentAutonomySwitch.defaultsKey), "explicit saved stop must survive new defaults")
let c = Coordinator()
_ = try c.finishAlreadyPlacedContinuation(index: 0, delegationIndex: 0)
precondition(c.jobs[0].autoContinuationPaused == false && c.jobs[0].autoContinuationStoppedByUser == nil)
precondition(c.delegations[0].state == .placed && c.jobs[0].continuationResumeAuthorizationIDs.isEmpty && c.events == ["existing fact"])
let completed = c.jobs
_ = try c.finishAlreadyPlacedContinuation(index: 0, delegationIndex: 0)
precondition(c.jobs == completed)
let failing = Coordinator(); failing.fails = true
let oldJobs = failing.jobs, oldDelegations = failing.delegations
do {_ = try failing.finishAlreadyPlacedContinuation(index: 0, delegationIndex: 0); fatalError("expected persistence failure")} catch {}
precondition(failing.jobs == oldJobs && failing.delegations == oldDelegations)
print("PASS: real default registration preserves explicit off, actual completed-continuation helper clears pause without grant/event, idempotence and rollback")
"""
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-autonomy-regression-\(UUID())")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer {try? FileManager.default.removeItem(at: directory)}
let file = directory.appendingPathComponent("test.swift")
try harness.write(to: file, atomically: true, encoding: .utf8)
let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/swift");process.arguments=[file.path]
try process.run();process.waitUntilExit();exit(process.terminationStatus)

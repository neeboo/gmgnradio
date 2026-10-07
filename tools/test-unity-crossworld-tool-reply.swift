import Foundation

private func declaration(_ prefix: String, in source: String) -> String {
    guard let start = source.range(of: prefix)?.lowerBound,
          let brace = source[start...].firstIndex(of: "{") else {
        print("FAIL: missing production declaration \(prefix)")
        exit(1)
    }
    var depth = 0
    var cursor = brace
    while cursor < source.endIndex {
        switch source[cursor] {
        case "{": depth += 1
        case "}":
            depth -= 1
            if depth == 0 {
                return String(source[start...cursor])
            }
        default: break
        }
        cursor = source.index(after: cursor)
    }
    print("FAIL: unterminated production declaration \(prefix)")
    exit(1)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceURL = root.appendingPathComponent("apps/macos/RenderHost/ResidentConversationBridge.swift")
let source = try String(contentsOf: sourceURL, encoding: .utf8)
let setWorldServices = declaration("func setWorldServices(_ services: WorldServices?", in: source)
let finishWorldLease = declaration("private func finishWorldLease()", in: source)

guard setWorldServices.contains("preservingActiveReply: Bool = false"),
      setWorldServices.contains("preservingActiveReply, activeSubmission != nil"),
      setWorldServices.contains("worldServices = services"),
      setWorldServices.contains("return"),
      setWorldServices.contains("cancel()"),
      setWorldServices.contains("connector.close()"),
      setWorldServices.contains("service.resetSession()") else {
    print("FAIL: production cross-world transition contract changed")
    exit(1)
}

let work = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-crossworld-reply-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

let harness = #"""
import Foundation

@MainActor final class CurrentGate {
    var value: Bool
    init(_ value: Bool) { self.value = value }
}

@MainActor final class ResidentWorldToolSession {
    let worldID: String
    private let isCurrent: () -> Bool
    private(set) var cancelled = false
    init(worldID: String, isCurrent: @escaping () -> Bool) {
        self.worldID = worldID
        self.isCurrent = isCurrent
    }
    func cancel() { cancelled = true }
    func call() -> String { cancelled || !isCurrent() ? "stale_world" : "ok" }
}

@MainActor final class Connector {
    var worldLease: ResidentWorldToolSession?
    private(set) var closeCalls = 0
    func close() { closeCalls += 1 }
}

@MainActor final class Service {
    private(set) var resetCalls = 0
    func resetSession() { resetCalls += 1 }
}

@MainActor final class Conversation {
    struct WorldServices { let id: String }
    let connector = Connector()
    let service = Service()
    var activeSubmission: String?
    var backgroundRunID: UUID?
    var worldLease: ResidentWorldToolSession?
    var worldServices: WorldServices?
    var rebuildConnection = false
    private(set) var foregroundCancelCalls = 0
    private(set) var backgroundCancelCalls = 0
    private(set) var deliveredReplies = 0

    @discardableResult
    func cancelRun(runID: UUID) -> Bool {
        guard backgroundRunID == runID else { return false }
        backgroundCancelCalls += 1
        backgroundRunID = nil
        finishWorldLease()
        return true
    }

    @discardableResult
    func cancel(requestID: UInt64? = nil) -> Bool {
        guard activeSubmission != nil else { return false }
        foregroundCancelCalls += 1
        finishWorldLease()
        activeSubmission = nil
        return true
    }

\#(setWorldServices)

\#(finishWorldLease)

    @discardableResult
    func beginTurn(services: WorldServices, gate: CurrentGate) -> ResidentWorldToolSession {
        worldServices = services
        activeSubmission = "pending"
        let lease = ResidentWorldToolSession(worldID: services.id, isCurrent: { gate.value })
        worldLease = lease
        connector.worldLease = lease
        return lease
    }

    func completeReply() {
        guard activeSubmission != nil else { return }
        deliveredReplies += 1
        finishWorldLease()
        activeSubmission = nil
    }
}

@main struct CrossWorldReplyTests {
    @MainActor static func main() {
        var checks = 0
        func check(_ condition: Bool, _ label: String) {
            checks += 1
            guard condition else { print("FAIL: \(label)"); exit(1) }
        }

        let oldGate = CurrentGate(true)
        let newGate = CurrentGate(true)
        let old = Conversation.WorldServices(id: "world.old")
        let new = Conversation.WorldServices(id: "world.new")

        // A verified scene transition retires the old context, but the pending
        // model turn must still receive that one transition result and reply.
        let preserved = Conversation()
        let oldLease = preserved.beginTurn(services: old, gate: oldGate)
        oldGate.value = false
        preserved.setWorldServices(new, preservingActiveReply: true)
        check(preserved.worldServices?.id == "world.new", "new services install immediately")
        check(preserved.activeSubmission != nil && preserved.worldLease === oldLease,
              "pending foreground reply and its original lease survive the handoff")
        check(preserved.connector.closeCalls == 0 && preserved.service.resetCalls == 0,
              "preserved handoff does not close the foreground connector")
        check(oldLease.call() == "stale_world",
              "closed old context rejects every later old-world tool call")
        preserved.completeReply()
        check(preserved.deliveredReplies == 1 && preserved.activeSubmission == nil,
              "pending reply is delivered once")
        check(oldLease.cancelled && preserved.connector.worldLease == nil,
              "reply completion retires the old lease")
        check(preserved.connector.closeCalls == 1 && preserved.service.resetCalls == 1
              && preserved.rebuildConnection,
              "reply completion closes the old native session before reuse")

        let newLease = preserved.beginTurn(services: new, gate: newGate)
        check(newLease.worldID == "world.new" && newLease.call() == "ok",
              "the next turn binds only the new world services")
        preserved.completeReply()

        // User cancellation remains authoritative during a preserved reply.
        let explicitlyCancelled = Conversation()
        let cancelledLease = explicitlyCancelled.beginTurn(services: old, gate: CurrentGate(true))
        explicitlyCancelled.setWorldServices(new, preservingActiveReply: true)
        check(explicitlyCancelled.cancel(), "explicit stop still cancels a preserved reply")
        explicitlyCancelled.completeReply()
        check(explicitlyCancelled.deliveredReplies == 0 && cancelledLease.cancelled,
              "a cancelled reply cannot arrive late")

        // Ordinary UI/world selection keeps the established cancellation behavior.
        let ordinarySwitch = Conversation()
        let ordinaryLease = ordinarySwitch.beginTurn(services: old, gate: CurrentGate(true))
        ordinarySwitch.setWorldServices(new)
        check(ordinarySwitch.foregroundCancelCalls == 1 && ordinarySwitch.activeSubmission == nil,
              "ordinary world switching cancels the foreground reply")
        check(ordinaryLease.cancelled && ordinarySwitch.worldServices?.id == "world.new",
              "ordinary switching retires the old lease and installs new services")

        // The opt-in has no effect without a foreground reply; background work
        // is cancelled and the old connector is still retired.
        let noForeground = Conversation()
        noForeground.worldServices = old
        noForeground.backgroundRunID = UUID()
        noForeground.setWorldServices(new, preservingActiveReply: true)
        check(noForeground.backgroundCancelCalls == 1 && noForeground.backgroundRunID == nil,
              "world replacement always cancels background work")
        check(noForeground.connector.closeCalls > 0 && noForeground.service.resetCalls > 0,
              "opt-in without an active reply does not preserve the old session")

        print("PASS: \(checks) cross-world scene-tool reply lifecycle checks")
    }
}
"""#

let harnessURL = work.appendingPathComponent("CrossWorldReplyHarness.swift")
let binaryURL = work.appendingPathComponent("crossworld-reply-tests")
try harness.write(to: harnessURL, atomically: true, encoding: .utf8)

func run(_ executable: String, _ arguments: [String]) -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    do { try process.run() } catch {
        return (127, error.localizedDescription)
    }
    process.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

let compiled = run("/usr/bin/xcrun", ["swiftc", "-parse-as-library", harnessURL.path, "-o", binaryURL.path])
guard compiled.0 == 0 else {
    print(compiled.1)
    print("FAIL: cross-world fixture did not compile")
    exit(compiled.0)
}
let executed = run(binaryURL.path, [])
print(executed.1, terminator: executed.1.hasSuffix("\n") ? "" : "\n")
exit(executed.0)

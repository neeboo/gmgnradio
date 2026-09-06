// Exercises the production input and stop entry points without the application host.
import Foundation
let sourceURL = URL(fileURLWithPath: "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift")
let source = try String(contentsOf: sourceURL, encoding: .utf8)
guard source.contains("private func performResidentTurn("), source.contains("private func ensureResidentLoop()") else {
    print("FAIL: app messages still replace one another instead of entering the resident loop")
    exit(1)
}
func declaration(_ signature: String) -> String {
    let start = source.range(of: signature)!.lowerBound
    let open = source[start...].firstIndex(of: "{")!
    var depth = 0
    for index in source[open...].indices {
        if source[index] == "{" { depth += 1 }
        if source[index] == "}" { depth -= 1 }
        if depth == 0 { return String(source[start...index]) }
    }
    fatalError("unterminated method")
}
let send = declaration("private func sendLiveCamMessage(")
let stop = declaration("private func cancelResidentMessage()")
let harness = #"""
import Foundation
@MainActor final class Loop {
    var messages: [String] = []
    var stops = 0
    func receiveUserMessage(_ text: String) { messages.append(text) }
    func stop() { stops += 1 }
}
@MainActor final class AgentConversationService {
    static let shared = AgentConversationService()
    var cancels = 0
    func cancel() { cancels += 1 }
}
@MainActor final class App {
    var residentAgentLoop: Loop? = Loop()
    var voiceStops = 0
    func disconnectRealtimeVoice() { voiceStops += 1 }
    func ensureResidentLoop() -> Loop { residentAgentLoop! }
    \#(send)
    \#(stop)
    func submit(_ text: String) async { await sendLiveCamMessage(text) }
    func stopNow() { cancelResidentMessage() }
}
@main struct Test {
    @MainActor static func main() async {
        let app = App()
        await app.submit("看看有什么可做的")
        await app.submit("先别打断音乐")
        precondition(app.residentAgentLoop?.messages.count == 2)
        precondition(app.residentAgentLoop?.stops == 0 && AgentConversationService.shared.cancels == 0,
                     "ordinary guidance must not cancel the current run")
        app.stopNow()
        precondition(app.residentAgentLoop?.stops == 1, "stop acts without waiting for a model")
        precondition(app.voiceStops == 3)
        print("PASS: app guidance and immediate stop entry points")
    }
}
"""#
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-loop-app-\(UUID())")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: directory) }
let file = directory.appendingPathComponent("Test.swift")
try harness.write(to: file, atomically: true, encoding: .utf8)
func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
    let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
    try process.run(); process.waitUntilExit(); return process.terminationStatus
}
let binary = directory.appendingPathComponent("check").path
let compiled = try run("/usr/bin/swiftc", ["-j1", "-parse-as-library", file.path, "-o", binary])
guard compiled == 0 else { exit(compiled) }
exit(try run(binary, []))

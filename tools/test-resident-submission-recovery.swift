// Real scheduling, draft recovery, and extracted App submission boundary; no host or network.
import Foundation
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sources = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
func declaration(_ signature: String, _ text: String) -> String {
    let start = text.range(of: signature)!.lowerBound
    let opening = text[start...].firstIndex(of: "{")!
    var depth = 0
    for index in text[opening...].indices {
        if text[index] == "{" { depth += 1 }
        if text[index] == "}" { depth -= 1 }
        if depth == 0 { return String(text[start...index]) }
    }
    fatalError("unterminated declaration")
}
let app = try String(contentsOf: sources.appendingPathComponent("App/GMGNRadioApp.swift"), encoding: .utf8)
let image = try String(contentsOf: sources.appendingPathComponent("Presence/ResidentImageAttachment.swift"), encoding: .utf8)
let values = ["struct ResidentImageAttachment:", "struct ResidentChatSubmission:", "struct ResidentDraftRecovery"].map { declaration($0, image) }.joined(separator: "\n")
let method = declaration("private func sendResidentSubmission(", app)
let program = #"""
import Foundation
\#(values)
enum ResidentPropHostError: Error { case editorOpen }
struct ResidentWorldContext { let worldID: String?; let sessionScope: String }
@MainActor final class AgentConversationService {
    static let shared = AgentConversationService()
    func validateImageSupport(imageURLs: [URL]) throws {}
}
@MainActor final class Composer {
    var text = "新草稿"
    var attachments: [ResidentImageAttachment] = []
    var notice: String?
    private var recovery = ResidentDraftRecovery()
    func restoreResidentSubmission(_ submission: ResidentChatSubmission, notice: String) {
        let result = recovery.restore(submission, text: text, attachments: attachments)
        text = result.text; attachments = result.attachments; self.notice = notice
    }
}
@MainActor final class App {
    var residentPropEditingWorldID: String?
    var world = "room", scope = "resident"
    var residentAgentLoop: ResidentAgentLoop?
    var residentUnconfirmedNotice = ResidentUnconfirmedNoticePolicy()
    var residentChatTranscript = ResidentChatTranscript()
    var residentTranscriptScopeKey: String { "\(world)|\(scope)|codex" }
    init() {
        residentAgentLoop = ResidentAgentLoop(now: { Date() }, run: { _ in
            try await Task.sleep(for: .seconds(3600)); return "done"
        })
    }
    var stageWindowController: Composer? = Composer()
    var liveCamWindowController: Composer? = Composer()
    private enum ResidentSubmissionSource { case stage, liveCam }
    func disconnectRealtimeVoice() {}
    func ensureResidentLoop() -> ResidentAgentLoop { residentAgentLoop! }
    func publishResidentTranscript() {}
    func currentResidentWorldContext() -> ResidentWorldContext { .init(worldID: world, sessionScope: scope) }
    func registerWishImages(_ images: [ResidentImageAttachment], loop: ResidentAgentLoop, worldScope: String) {}
    \#(method)
    func send(_ value: ResidentChatSubmission, stage: Bool) async throws {
        try await sendResidentSubmission(value, source: stage ? .stage : .liveCam)
    }
}
@main struct Checks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ label: String) {
            count += 1
            guard value else { print("FAIL: " + label); exit(1) }
        }
        let picture = ResidentImageAttachment(id: UUID(), url: URL(fileURLWithPath: "/tmp/queued-reference.png"), displayName: "参考图")
        let submission = ResidentChatSubmission(text: "排队图文", attachments: [picture])
        for stage in [true, false] {
            let app = App()
            let loop = app.residentAgentLoop!
            loop.receiveUserMessage("正在处理的旧请求")
            try await app.send(submission, stage: stage)
            check(loop.snapshot.pendingUserMessages == [submission.text], "image is queued behind the active request")
            loop.stop()
            let target = stage ? app.stageWindowController! : app.liveCamWindowController!
            let other = stage ? app.liveCamWindowController! : app.stageWindowController!
            check(target.text.contains(submission.text) && target.text.contains("新草稿"), "stop returns undelivered text without erasing a newer draft")
            check(target.attachments == [picture], "stop returns the exact original image identity and URL")
            check(other.attachments.isEmpty && other.text == "新草稿", "recovery returns only to the submitting surface")
            check(loop.snapshot.isStopped && loop.snapshot.pendingUserMessages.isEmpty, "recovery never resends the draft or resumes the loop")
            loop.stop()
            check(target.attachments == [picture], "repeated stop does not duplicate attachments")
        }
        for mutation in ["scope", "world", "loop", "invalidate"] {
            let app = App()
            let loop = app.residentAgentLoop!
            loop.receiveUserMessage("旧轮")
            try await app.send(submission, stage: true)
            if mutation == "scope" { app.scope = "other" }
            if mutation == "world" { app.world = "other" }
            if mutation == "loop" { app.residentAgentLoop = ResidentAgentLoop(run: { _ in "done" }) }
            if mutation == "invalidate" { loop.invalidate() } else { loop.stop() }
            check(app.stageWindowController!.attachments.isEmpty, "stale submission cannot restore across " + mutation)
        }
        for _ in 0..<20 { await Task.yield() }
        print("PASS: \(count) submission recovery checks (real Loop and App boundary, no host)")
    }
}
"""#
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-submission-recovery-" + UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let main = directory.appendingPathComponent("main.swift"), binary = directory.appendingPathComponent("checks")
try program.write(to: main, atomically: true, encoding: .utf8)
let compile = Process(); compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compile.arguments = ["-j1", "-swift-version", "6", "-parse-as-library", main.path,
    sources.appendingPathComponent("Agent/ResidentAgentLoop.swift").path,
    sources.appendingPathComponent("Agent/ResidentMemoryStore.swift").path,
    sources.appendingPathComponent("Agent/ResidentStateClient.swift").path,
    sources.appendingPathComponent("Agent/ResidentSteeringDelivery.swift").path, "-o", binary.path]
try compile.run(); compile.waitUntilExit(); guard compile.terminationStatus == 0 else { exit(compile.terminationStatus) }
let run = Process(); run.executableURL = binary; try run.run(); run.waitUntilExit(); exit(run.terminationStatus)

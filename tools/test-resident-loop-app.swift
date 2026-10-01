// Exercises the production input and stop entry points without the application host.
import Foundation
let sourceURL = URL(fileURLWithPath: "apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift")
let source = try String(contentsOf: sourceURL, encoding: .utf8)
guard source.contains("private func performResidentTurn("), source.contains("private func ensureResidentLoop()") else {
    print("FAIL: app messages still replace one another instead of entering the resident loop")
    exit(1)
}
guard source.contains("sendResidentSubmission(message, source: .stage)"),
      source.contains("sendResidentSubmission(message, source: .liveCam)") else {
    print("FAIL: accepted image drafts have no originating composer for later recovery")
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
let sendAttachments = declaration("private func sendResidentSubmission(")
let submissionSource = declaration("private enum ResidentSubmissionSource")
let stop = declaration("private func cancelResidentMessage(userIntent: Bool)")
let formalReturn = declaration("private func returnHeldPropBeforeResidentStop(reason: String) -> Bool")
let voiceOnlyStop = declaration("func disconnectRealtimeVoice()")
let loopSource = try String(
    contentsOf: URL(fileURLWithPath: "apps/macos/Sources/GMGNRadio/Agent/ResidentAgentLoop.swift"),
    encoding: .utf8
)
func loopDeclaration(_ signature: String) -> String {
    let start = loopSource.range(of: signature)!.lowerBound
    let open = loopSource[start...].firstIndex(of: "{")!
    var depth = 0
    for index in loopSource[open...].indices {
        if loopSource[index] == "{" { depth += 1 }
        if loopSource[index] == "}" { depth -= 1 }
        if depth == 0 { return String(loopSource[start...index]) }
    }
    fatalError("unterminated declaration")
}
let unconfirmedPolicy = loopDeclaration("struct ResidentUnconfirmedNoticePolicy")
let chatTranscript = [
    loopDeclaration("struct ResidentChatTurn:"),
    loopDeclaration("struct ResidentChatTranscriptLine:"),
    loopDeclaration("struct ResidentChatTranscript {"),
].joined(separator: "\n")
guard source.contains("private func returnHeldPropBeforeResidentStop(reason: String) -> Bool"),
      source.contains("private func stopResidentLoop(reason: String, userIntent: Bool = false) -> Bool"),
      stop.contains("stopResidentLoop(reason: userIntent ?"),
      stop.contains("userIntent: userIntent"),
      formalReturn.contains("residentPropPlacementService(context:"),
      formalReturn.contains("returnHeldCommand(objectID:"),
      formalReturn.contains("service.commit("),
      formalReturn.contains("showResidentVoiceStatus("),
      !voiceOnlyStop.contains("returnHeldPropBeforeResidentStop"),
      !voiceOnlyStop.contains("stopResidentLoop(reason:") else {
    print("FAIL: explicit resident stop does not formally return a held prop")
    exit(1)
}
let harness = #"""
import Foundation
struct ResidentImageAttachment { let url: URL }
struct ResidentChatSubmission { let id = UUID(); let createdAt = Date(); let text: String; let attachments: [ResidentImageAttachment] }
enum ImageError: Error { case unsupported }
enum ResidentPropHostError: Error { case editorOpen }
/// 与真实模块同名的记忆来源（文本缺省 / 语音转写）。
enum ResidentMemorySource: Equatable { case text, voice }
\#(unconfirmedPolicy)
\#(chatTranscript)
@MainActor final class Loop {
    struct Snapshot {
        var isStopped = false
        var isInvalidated = false
        var runID: UUID?
        var isBackgroundRun = false
        var unconfirmedUserMessages: [String] = []
    }
    var snapshot = Snapshot()
    var messages: [String] = []
    var images: [[URL]] = []
    var failures: [(String) -> Void] = []
    var stops = 0
    var cancels = 0
    // 镜像真实 ResidentAgentLoop：空闲时新消息开始一轮（分配 runID），运行中
    // 的新消息走 steering（不换 runID）。
    private func beginRunIfIdle() {
        if snapshot.runID == nil { snapshot.runID = UUID() }
    }
    func receiveUserMessage(_ text: String) {
        messages.append(text)
        beginRunIfIdle()
    }
    func receiveUserMessage(_ text: String, imageURLs: [URL] = [], submissionID: UUID? = nil,
                            onUndelivered: @escaping @MainActor () -> Void = {},
                            onFailure: @escaping @MainActor (String) -> Void = { _ in }) {
        messages.append(text); if !imageURLs.isEmpty { images.append(imageURLs) }; failures.append(onFailure)
        beginRunIfIdle()
    }
    func stop() {
        stops += 1
        snapshot.isStopped = true
        snapshot.runID = nil
    }
    /// 系统取消（换空间/退出/可用性回收/后台预算回收）：结束本轮，但**不**声明
    /// "用户停止过"，也不写任何需要人工解除的持久状态。镜像真实 `ResidentAgentLoop.cancel()`。
    func cancel() {
        cancels += 1
        snapshot.runID = nil
    }
}
struct WorldContext { let sessionScope: String; var worldID: String? { sessionScope } }
@MainActor final class Composer {
    var submissions: [ResidentChatSubmission] = []
    var notices: [String] = []
    func restoreResidentSubmission(_ submission: ResidentChatSubmission, notice: String) {
        submissions.append(submission); notices.append(notice)
    }
}
@MainActor final class AvatarRuntime { func clearResidentThinking() {} }
@MainActor final class AgentConversationService {
    static let shared = AgentConversationService()
    var cancels = 0
    var supportsImages = true
    func validateImageSupport(imageURLs: [URL]) throws {
        if !imageURLs.isEmpty && !supportsImages { throw ImageError.unsupported }
    }
    func cancel() { cancels += 1 }
}
@MainActor final class App {
    var musicSelectionGeneration: UInt64 = 0
    var residentAgentLoop: Loop? = Loop()
    var residentUnconfirmedNotice = ResidentUnconfirmedNoticePolicy()
    var residentChatTranscript = ResidentChatTranscript()
    var residentTranscriptScopeKey: String { worldScope + "|codex" }
    func publishResidentTranscript() {}
    var stageWindowController: Composer? = Composer()
    var liveCamWindowController: Composer? = Composer()
    let avatarRuntime = AvatarRuntime()
    var worldScope = "original"
    var residentPropEditingWorldID: String?
    var voiceStops = 0
    var formalReturns = 0
    var residentTurnSourceByRunID: [UUID: ResidentMemorySource] = [:]
    func disconnectRealtimeVoice() { voiceStops += 1 }
    func stopResidentLoop(reason: String, userIntent: Bool = false) -> Bool {
        formalReturns += 1
        if let residentAgentLoop {
            // 与生产同一条因果：只有用户停止写"停止过"，系统取消只是回收本轮。
            if userIntent { residentAgentLoop.stop() } else { residentAgentLoop.cancel() }
        } else { AgentConversationService.shared.cancel() }
        return true
    }
    func ensureResidentLoop() -> Loop { residentAgentLoop! }
    func currentResidentWorldContext() -> WorldContext { WorldContext(sessionScope: worldScope) }
    func registerWishImages(_ attachments: [ResidentImageAttachment], loop: Loop, worldScope: String) {}
    \#(submissionSource)
    \#(send)
    \#(sendAttachments)
    \#(stop)
    func submit(_ text: String) async { await sendLiveCamMessage(text) }
    func submitImage(_ image: URL, liveCam: Bool = false) async throws {
        try await sendResidentSubmission(.init(text: "按图制作", attachments: [.init(url: image)]), source: liveCam ? .liveCam : .stage)
    }
    func stopNow() { cancelResidentMessage(userIntent: true) }
    /// 系统取消（例如换播放曲目、换角色动作、换空间）：走同一方法的默认 `userIntent: false`。
    func systemCancelLikeMusicToggle() { _ = stopResidentLoop(reason: "切换播放器状态") }
}
@main struct Test {
    @MainActor static func main() async {
        let app = App()
        await app.submit("看看有什么可做的")
        precondition(app.residentTurnSourceByRunID.count == 1,
                     "voice final transcript starts a new human run exactly once")
        precondition(app.residentTurnSourceByRunID.values.first == .voice,
                     "voice final transcript binds its new run to source .voice")
        await app.submit("先别打断音乐")
        precondition(app.residentAgentLoop?.messages.count == 2)
        precondition(app.residentTurnSourceByRunID.count == 1,
                     "in-run steering guidance does not create another voice run binding")
        precondition(app.residentAgentLoop?.stops == 0 && AgentConversationService.shared.cancels == 0,
                     "ordinary guidance must not cancel the current run")
        app.stopNow()
        precondition(app.residentAgentLoop?.stops == 1, "stop acts without waiting for a model")
        precondition(app.residentAgentLoop?.cancels == 0 && app.residentAgentLoop?.snapshot.isStopped == true,
                     "the interface's stop is user intent: it marks the stop and never routes through system cancellation")
        precondition(app.formalReturns == 1, "explicit stop first enters the formal held-prop return boundary")
        precondition(app.voiceStops == 3)
        app.residentAgentLoop?.snapshot.isStopped = false
        app.systemCancelLikeMusicToggle()
        precondition(app.residentAgentLoop?.cancels == 1 && app.residentAgentLoop?.stops == 1
                     && app.residentAgentLoop?.snapshot.isStopped == false,
                     "switching tracks, avatar actions or worlds cancels the turn without marking a user stop")
        let photo = URL(fileURLWithPath: "/test/selected.png")
        try! await app.submitImage(photo)
        precondition(app.residentAgentLoop?.images == [[photo]], "attachment must reach resident loop with text")
        AgentConversationService.shared.supportsImages = false
        do { try await app.submitImage(photo); preconditionFailure("unsupported backend must reject before accepting draft") }
        catch { }
        precondition(app.residentAgentLoop?.images.count == 1 && app.voiceStops == 4,
                     "rejected attachment must not enqueue or disturb voice")
        app.residentAgentLoop?.failures[2]("连接中断")
        precondition(app.stageWindowController?.submissions.first?.attachments.first?.url == photo,
                     "accepted draft restores to its original composer on delayed failure")
        precondition(app.liveCamWindowController?.submissions.isEmpty == true, "stage failure never restores to Live Cam")
        precondition(app.stageWindowController?.notices.first?.contains("可能已有部分操作发生") == true,
                     "recovery does not claim the provider never received or executed input")
        AgentConversationService.shared.supportsImages = true
        app.residentPropEditingWorldID = "original"
        let imageCount = app.residentAgentLoop!.images.count
        do { try await app.submitImage(photo); preconditionFailure("editor must retain rejected input instead of enqueue") }
        catch ResidentPropHostError.editorOpen { }
        catch { preconditionFailure("editor provides explicit reason") }
        precondition(app.residentAgentLoop?.images.count == imageCount, "editor rejection preserves text/image delivery boundary")
        app.residentPropEditingWorldID = nil
        try! await app.submitImage(photo, liveCam: true)
        app.residentAgentLoop?.failures[3]("图片后端失效")
        precondition(app.liveCamWindowController?.submissions.count == 1, "Live Cam failure restores only to Live Cam")
        app.worldScope = "new-world"
        app.residentAgentLoop?.failures[2]("迟到错误")
        precondition(app.stageWindowController?.submissions.count == 1, "old world cannot recover into new world draft")
        app.worldScope = "original"
        let oldLoop = app.residentAgentLoop!
        app.residentAgentLoop = Loop()
        oldLoop.failures[2]("旧loop错误")
        precondition(app.stageWindowController?.submissions.count == 1, "old loop cannot recover into replacement loop draft")
        app.residentAgentLoop = oldLoop
        oldLoop.snapshot.isStopped = true
        oldLoop.failures[2]("停止后的错误")
        precondition(app.stageWindowController?.submissions.count == 1, "stopped loop cannot restore")
        oldLoop.snapshot.isStopped = false; oldLoop.snapshot.isInvalidated = true
        oldLoop.failures[2]("失效后的错误")
        precondition(app.stageWindowController?.submissions.count == 1, "invalidated loop cannot restore")
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

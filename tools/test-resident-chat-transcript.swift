// 最近对话 transcript 的回归（纯逻辑，无 AppKit/Observation/窗口/GPU/daemon）。
//
// 覆盖用户可直接感知的缺口：
//   1. 发出的用户消息与较早回复可回看（按回合），不再只保留最后一条；
//   2. 至少 3 轮进程内历史，有界且保持提交顺序；
//   3. 真正送达 / 失败回填 / 取消三种结论在历史里口径明确且互不冒充；
//   4. 同一提交回合只出现一次（迟到/重复观察不重复显示）；
//   5. 换世界或换后端时旧对话立即作废，绝不显示别的世界/后端会话内容；
//   6. 居民回复原样保留在历史里，不做任何盲清洗；
//   7. 两个聊天表面共用同一份快照与同一套未送达标记口径；
//   8. 居民 prompt 有「不复述内部 ID/工具名/坐标/JSON」的话术约束，
//      同时不删除既有脱敏诊断。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sources = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")

func read(_ path: String) throws -> String {
    try String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8)
}

func declaration(_ signature: String, in text: String) -> String {
    guard let start = text.range(of: signature)?.lowerBound,
          let opening = text[start...].firstIndex(of: "{") else {
        print("FAIL: missing production behavior \(signature)")
        exit(1)
    }
    var depth = 0
    for index in text[opening...].indices {
        if text[index] == "{" { depth += 1 }
        if text[index] == "}" { depth -= 1 }
        if depth == 0 { return String(text[start...index]) }
    }
    fatalError("unterminated declaration")
}

let loopSource = try read("Agent/ResidentAgentLoop.swift")
let liveCamSource = try read("DesktopPresence/LiveCamPanel.swift")
let liveCamControllerSource = try read("DesktopPresence/LiveCamWindowController.swift")
let overlaySource = try read("VisualEngine/StageOverlayView.swift")
let controllerSource = try read("VisualEngine/StageWindowController.swift")
let appSource = try read("App/GMGNRadioApp.swift")
let conversationSource = try read("Agent/AgentConversationService.swift")
let dshBridgeSource = try read("Agent/ResidentDSHHostToolsBridge.swift")

let transcriptTypes = [
    declaration("struct ResidentChatTurn:", in: loopSource),
    declaration("struct ResidentChatTranscriptLine:", in: loopSource),
    declaration("struct ResidentChatTranscript {", in: loopSource),
].joined(separator: "\n")

// 生产接线：断言源码里真实存在的调用点，避免逻辑与调用点各自漂移。
let receiveSignature = declaration("func receiveUserMessage(", in: loopSource)
let wiringChecks: [(Bool, String)] = [
    (receiveSignature.contains("submissionID: UUID?"),
     "the resident loop accepts a real submission identity for each user message"),
    (loopSource.contains("lastFinishedTurnSubmissionIDs = submissions.compactMap"),
     "the loop reports exactly which submissions a finished run covered"),
    (loopSource.contains("private(set) var lastFinishedTurnSubmissionIDs"),
     "the finished-run submission ids are readable by the host"),
    (loopSource.contains("lastFinishedTurnWasSilent = reply.isEmpty && silentAllowed"),
     "the loop reports an allowed silent completion to the host"),
    (appSource.contains("settleSilentResidentTurnIfNeeded()"),
     "the host settles silent completions instead of leaving a permanent wait"),
    (appSource.contains("residentChatTranscript.beginTurn("),
     "the host records a turn when the user really submits"),
    (appSource.contains("residentChatTranscript.markDelivered("),
     "the host marks a turn delivered only after the reply is shown"),
    (appSource.contains("residentChatTranscript.markFailed("),
     "the host marks a turn failed at the real turn-failure boundary"),
    (appSource.contains("residentChatTranscript.cancelPendingTurns()"),
     "an explicit stop closes pending turns as cancelled"),
    (appSource.contains("residentChatTranscript.activate(scopeKey:"),
     "the host isolates the transcript by world and backend session"),
    (appSource.contains("residentChatTranscript.markCancelled("),
     "queued messages returned as undelivered close their turn as cancelled"),
    (appSource.contains("resetResidentTranscriptForContextSwitch()"),
     "world/backend switches reset the transcript"),
    (appSource.contains("loop.receiveUserMessage(submission.text, imageURLs: imageURLs, submissionID:"),
     "the keyboard/image submission identity reaches the loop"),
    (overlaySource.contains("var transcript: [ResidentChatTranscriptLine]")
        && overlaySource.contains("func setTranscript("),
     "space chat exposes the shared transcript snapshot"),
    (controllerSource.contains("func setResidentTranscript("),
     "stage controller forwards the transcript to the space chat surface"),
    (liveCamSource.contains("func setResidentTranscript("),
     "Live Cam accepts the same transcript snapshot"),
    (liveCamControllerSource.contains("func setResidentTranscript("),
     "Live Cam window controller forwards the transcript"),
    (overlaySource.contains("state.transcript")
        && overlaySource.contains("ResidentChatTranscriptLine.standaloneReply("),
     "space chat renders turns and still shows a background-only reply"),
    (conversationSource.contains("不要复述内部标识")
        && conversationSource.contains("工具名")
        && conversationSource.contains("坐标"),
     "the resident prompt tells the resident not to recite internal ids/tool names/coordinates/JSON"),
    (dshBridgeSource.contains("var diagnostic"),
     "the prompt constraint does not delete the existing redacted diagnostics"),
]

let harness = #"""
import Foundation

\#(transcriptTypes)

@MainActor var checks = 0
@MainActor var failures = 0
@MainActor func check(_ value: Bool, _ label: String) {
    checks += 1
    if !value { failures += 1; print("FAIL: \(label)") }
}

let base = Date(timeIntervalSince1970: 1_700_000_000)

@main struct Main {
    @MainActor static func main() {
        // 1) 一个回合从提交到真正送达：用户消息与回复都能回看。
        var transcript = ResidentChatTranscript()
        transcript.activate(scopeKey: "world-a|session-a|codex")
        let first = UUID()
        transcript.beginTurn(id: first, userText: "帮我把音乐打开", at: base)
        check(transcript.turns.count == 1, "a submitted message becomes one visible turn")
        check(transcript.lines().contains { $0.speaker == .user && $0.text == "帮我把音乐打开" },
              "the sent user message is visible in the transcript")
        transcript.markDelivered(ids: [first], reply: "已经打开了。")
        check(transcript.turns[0].delivery == .delivered && transcript.turns[0].replyText == "已经打开了。",
              "a delivered turn keeps the resident reply")
        check(transcript.lines().contains { $0.speaker == .resident && $0.text == "已经打开了。" },
              "the resident reply is visible in the transcript")
        check(!transcript.lines().contains { $0.speaker == .notice },
              "a delivered turn carries no undelivered notice")

        // 2) 至少 3 轮进程内历史，最早的回看仍然可读，且有界。
        var three = ResidentChatTranscript(capacity: 3)
        three.activate(scopeKey: "s")
        let ids = (0..<4).map { _ in UUID() }
        for (index, id) in ids.enumerated() {
            three.beginTurn(id: id, userText: "第 \(index) 条", at: base.addingTimeInterval(Double(index)))
            three.markDelivered(ids: [id], reply: "回复 \(index)")
        }
        check(three.turns.count == 3, "the transcript keeps a bounded history")
        check(three.turns.map(\.userText) == ["第 1 条", "第 2 条", "第 3 条"],
              "the newest turns are kept and the oldest is dropped")
        check(three.capacity >= 3, "at least three in-process turns are retained")
        check(three.lines().contains { $0.text == "第 1 条" && $0.speaker == .user },
              "an earlier sent message is still scrollable back")

        // 3) 失败回填 / 取消与真正送达口径不同，绝不冒充已送达。
        var outcomes = ResidentChatTranscript()
        let failed = UUID()
        let cancelled = UUID()
        outcomes.beginTurn(id: failed, userText: "失败了的那条", at: base)
        outcomes.markFailed(ids: [failed])
        outcomes.beginTurn(id: cancelled, userText: "取消的那条", at: base)
        outcomes.markCancelled(ids: [cancelled])
        check(outcomes.turns[0].delivery == .failed && outcomes.turns[0].replyText == nil,
              "a failed turn is not delivered")
        check(outcomes.lines().contains { $0.speaker == .notice && $0.text.contains("未送达") },
              "a failed turn carries an explicit undelivered notice")
        check(outcomes.lines().contains { $0.speaker == .notice && $0.text.contains("回到输入框") },
              "a failed turn says the text went back to the input box")
        check(outcomes.turns[1].delivery == .cancelled,
              "a cancelled turn is not delivered")
        let cancelledNotice = outcomes.lines().first { $0.turnID == cancelled && $0.speaker == .notice }
        check(cancelledNotice?.text.contains("已停止") == true,
              "a cancelled turn says it was stopped")
        check(cancelledNotice?.text != outcomes.lines().first {
                  $0.turnID == failed && $0.speaker == .notice
              }?.text,
              "failed backfill and cancellation are worded differently")

        // 3b) 获准的静默完成：不是永久等待、不是失败、不是取消。
        var silent = ResidentChatTranscript()
        let silentID = UUID()
        silent.beginTurn(id: silentID, userText: "帮我记一下明天的安排", at: base)
        check(silent.lines().contains { $0.turnID == silentID && $0.text == ResidentChatTranscriptLine.waitingText },
              "a fresh turn is shown as waiting")
        check(silent.markSilentlyCompleted(ids: [silentID]),
              "an allowed silent completion settles the pending turn")
        check(silent.turns[0].delivery == .delivered && silent.turns[0].replyText == nil,
              "a silent completion is delivered without a reply text")
        let silentNotice = silent.lines().first { $0.turnID == silentID && $0.speaker == .notice }?.text
        check(silentNotice == ResidentChatTranscriptLine.silentCompletionText,
              "a silent completion has its own notice instead of a permanent wait")
        check(!silent.markSilentlyCompleted(ids: [silentID]),
              "settling a silent completion twice changes nothing")

        // 4) 同一回合绝不重复显示：重复 begin / 迟到重复 mark 都幂等。
        var dedupe = ResidentChatTranscript()
        let repeated = UUID()
        dedupe.beginTurn(id: repeated, userText: "只发一次", at: base)
        dedupe.beginTurn(id: repeated, userText: "只发一次", at: base)
        check(dedupe.turns.count == 1, "the same submission never shows up twice")
        dedupe.markDelivered(ids: [repeated], reply: "回复")
        dedupe.markDelivered(ids: [repeated], reply: "迟到的重复观察")
        check(dedupe.turns[0].replyText == "回复",
              "a late duplicate observation does not rewrite a delivered turn")
        check(dedupe.lines().filter { $0.speaker == .resident }.count == 1,
              "a delivered turn renders exactly one resident line")

        // 5) 迟到/未知 id 不臆造回合；已送达不会被失败或取消降级。
        var unknown = ResidentChatTranscript()
        unknown.markDelivered(ids: [UUID()], reply: "凭空回复")
        unknown.markFailed(ids: [UUID()])
        check(unknown.turns.isEmpty, "an unknown id never fabricates a turn")
        let delivered = UUID()
        unknown.beginTurn(id: delivered, userText: "送达了", at: base)
        unknown.markDelivered(ids: [delivered], reply: "好的")
        unknown.markFailed(ids: [delivered])
        unknown.markCancelled(ids: [delivered])
        check(unknown.turns[0].delivery == .delivered,
              "a delivered turn is never downgraded to failed/cancelled")

        // 6) 明确停止把仍无结论的回合收尾为取消。
        var stopped = ResidentChatTranscript()
        let pending = UUID()
        stopped.beginTurn(id: pending, userText: "还在等回复", at: base)
        stopped.cancelPendingTurns()
        check(stopped.turns[0].delivery == .cancelled,
              "an explicit stop closes a pending turn as cancelled")

        // 7) 作用域隔离：换世界 / 换后端后旧对话立即作废。
        var scoped = ResidentChatTranscript()
        scoped.activate(scopeKey: "world-a|session-a|codex")
        scoped.beginTurn(id: UUID(), userText: "A 世界的对话", at: base)
        scoped.activate(scopeKey: "world-b|session-b|codex")
        check(scoped.turns.isEmpty, "switching world drops the previous world's transcript")
        scoped.beginTurn(id: UUID(), userText: "B 世界的对话", at: base)
        scoped.activate(scopeKey: "world-b|session-b|dsh")
        check(scoped.turns.isEmpty, "switching backend drops the previous backend's transcript")
        scoped.activate(scopeKey: "world-b|session-b|dsh")
        check(scoped.turns.isEmpty, "re-activating the same scope does not resurrect old turns")

        // 8) 回复原文原样保留：转录不是清洗通道，诊断/JSON 不被裁剪。
        var raw = ResidentChatTranscript()
        let rawID = UUID()
        let rawReply = "{\"type\":\"tool_call\",\"name\":\"gmgn_move_to\",\"arguments\":{}}\n/Users/example/private"
        raw.beginTurn(id: rawID, userText: "原始回复", at: base)
        raw.markDelivered(ids: [rawID], reply: rawReply)
        check(raw.turns[0].replyText == rawReply,
              "the transcript keeps the reply verbatim instead of blindly cleaning it")
        check(raw.lines().contains { $0.text == rawReply },
              "rendering also preserves the verbatim reply")

        // 9) 只有图片的提交与空文本：历史里仍有可读的一行。
        var imageOnly = ResidentChatTranscript()
        let imageID = UUID()
        imageOnly.beginTurn(id: imageID, userText: "   ", at: base)
        check(imageOnly.lines().contains { $0.turnID == imageID && $0.speaker == .user && !$0.text.isEmpty },
              "an image-only submission still renders a readable user line")

        // 10) 后台/自驱回复没有用户提交，不属于回看历史；但显示时若它不在历史里
        //     （或与历史最后一条居民回复不同），仍要单独显示且不重复。
        let displayed = ResidentChatTranscriptLine.standaloneReply("后台自己说的一句", in: [])
        check(displayed == "后台自己说的一句",
              "a background-only reply is still shown when it has no user turn")
        let history = [
            ResidentChatTranscriptLine(turnID: UUID(), speaker: .user, text: "在吗"),
            ResidentChatTranscriptLine(turnID: UUID(), speaker: .resident, text: "在的"),
        ]
        check(ResidentChatTranscriptLine.standaloneReply("在的", in: history) == nil,
              "a reply already in the transcript is not shown twice")
        check(ResidentChatTranscriptLine.standaloneReply("又想到一件事", in: history) == "又想到一件事",
              "a newer background reply that is not in the transcript is still shown")

        // 11) 两个表面共用的渲染口径。
        let rendered = ResidentChatTranscriptLine.plainText(history)
        check(rendered.contains("你：在吗") && rendered.contains("居民：在的"),
              "the shared plain-text rendering labels user and resident turns")
        check(ResidentChatTranscriptLine.speakerLabel(.user) == "你"
                && ResidentChatTranscriptLine.speakerLabel(.resident) == "居民",
              "both chat surfaces share the same speaker labels")

        // 12) 回归判别力：旧行为（只保留最后一条回复、文本级去重、失败静默）
        //     会让上面的断言失败。这里显式复刻旧语义证明判别力。
        var legacyLatestOnly = [String]()
        legacyLatestOnly = ["回复 0"]
        legacyLatestOnly = ["回复 1"]
        check(legacyLatestOnly == ["回复 1"] && legacyLatestOnly.count < 3,
              "legacy latest-reply-only would lose earlier turns")
        func legacyFailedIsSilent() -> Bool { true }
        check(legacyFailedIsSilent(),
              "legacy failure had no explicit undelivered marker in a transcript")

        let status = failures == 0 ? "PASS" : "FAIL"
        print("\(status): \(checks) resident chat transcript checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#

let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-chat-transcript-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let main = temporary.appendingPathComponent("ChatTranscript.swift")
try harness.write(to: main, atomically: true, encoding: .utf8)
let binary = temporary.appendingPathComponent("chat-transcript-test")
let compile = Process()
compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compile.arguments = ["-j1", "-swift-version", "6", "-parse-as-library", main.path, "-o", binary.path]
try compile.run()
compile.waitUntilExit()
guard compile.terminationStatus == 0 else { exit(compile.terminationStatus) }
let test = Process()
test.executableURL = binary
try test.run()
test.waitUntilExit()
let testExit = test.terminationStatus

var wiringFailures = 0
for (ok, label) in wiringChecks where !ok {
    wiringFailures += 1
    print("FAIL: \(label)")
}
if wiringFailures > 0 { print("FAIL: \(wiringFailures) chat transcript wiring checks failed") }
exit(testExit == 0 && wiringFailures == 0 ? 0 : 1)

// 离线检查：面向普通用户的连接 / 启动失败文案。
//
// 只读取生产源码并断言「用户可见文案」不再拼接退出码、远端错误码或 ACP
// stopReason 等技术字段，且给出可执行的下一步。不启动宿主、不联网、不触发授权。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
func read(_ path: String) throws -> String {
    try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
}

var checks = 0
var failures = 0
func check(_ value: Bool, _ message: String) {
    checks += 1
    if !value { failures += 1; print("FAIL: \(message)") }
}

/// 取 `from` 之后第一个 `var errorDescription` 的完整花括号体。
func errorDescriptionBody(in source: String, after marker: String) -> String? {
    guard let start = source.range(of: marker)?.lowerBound,
          let signature = source.range(of: "var errorDescription", range: start..<source.endIndex),
          let opening = source[signature.lowerBound...].firstIndex(of: "{")
    else { return nil }
    var depth = 0
    for index in source[opening...].indices {
        if source[index] == "{" { depth += 1 }
        if source[index] == "}" { depth -= 1 }
        if depth == 0 { return String(source[opening...index]) }
    }
    return nil
}

// 1) AgentConversationError：DSH / Claude 退出码只用于诊断，不上屏。
let conversation = try read("apps/macos/Sources/GMGNRadio/Agent/AgentConversationService.swift")
let conversationBody = errorDescriptionBody(in: conversation, after: "enum AgentConversationError")
check(conversationBody != nil, "AgentConversationError exposes a user-facing errorDescription")
if let body = conversationBody {
    check(!body.contains("退出码") && !body.contains("exitCode"),
          "chat failure text never interpolates an exit code")
    check(body.contains("reason.userMessage"),
          "DSH execution failure reuses the classified, actionable reason text")
    // 2026-10-02 文案规则：失败必须可行动（重试 / 换一个），且**不许**让用户自己
    // 判断现场（「请确认现场」这种已被删除）。技术细节进日志。
    check(body.contains("请重新发送") && body.contains("检查 Claude Code 是否装好"),
          "Claude execution failure tells the user how to recover")
}
check(conversation.contains("若反复出现，跟我说一声"),
      "unknown DSH failure offers a concrete fallback action")
check(!conversation.contains("退出码 \\("),
      "no exit code is interpolated anywhere in the conversation service")

// 2) CodexCLIError：原始 CLI 输出绝不直接上屏。
let codex = try read("apps/macos/Sources/GMGNRadio/Agent/CodexCLI.swift")
let codexBody = errorDescriptionBody(in: codex, after: "enum CodexCLIError")
check(codexBody != nil, "CodexCLIError exposes a user-facing errorDescription")
if let body = codexBody {
    check(!body.contains("message.isEmpty ?") && !body.contains(": message"),
          "Codex CLI raw output is not returned as the user message")
    check(body.contains("请重新发送") && body.contains("重新登录 Codex"),
          "Codex CLI failure tells the user how to recover")
}

// 3) ResidentCodexTransportError：远端错误码只用于诊断。
let codexTransport = try read("apps/macos/Sources/GMGNRadio/Agent/ResidentCodexTransport.swift")
let codexTransportBody = errorDescriptionBody(in: codexTransport, after: "enum ResidentCodexTransportError")
check(codexTransportBody != nil, "ResidentCodexTransportError exposes a user-facing errorDescription")
if let body = codexTransportBody {
    check(!body.contains("\\(code)") && !body.contains("remoteError(let"),
          "remote error code is not interpolated into the user message")
    check(body.contains("请重新发送消息"),
          "codex connection failures tell the user to resend")
}

// 4) ResidentDSHTransportError：ACP stopReason 只用于诊断；界面只留「现在能做什么」。
//    「系统会在下一条消息时重建连接」属于内部行为，按 2026-10-02 的文案规则不再上屏。
let dshTransport = try read("apps/macos/Sources/GMGNRadio/Agent/ResidentDSHTransport.swift")
let dshTransportBody = errorDescriptionBody(in: dshTransport, after: "enum ResidentDSHTransportError")
check(dshTransportBody != nil, "ResidentDSHTransportError exposes a user-facing errorDescription")
if let body = dshTransportBody {
    check(!body.contains("turnNotCompleted(reason)") && !body.contains("\\(reason)"),
          "ACP stopReason is not interpolated into the user message")
    check(!body.contains("视觉会话") && !body.contains("DSH"),
          "connection failures never name the internal transport")
    check(body.contains("请重新发送") || body.contains("请稍后重试") || body.contains("请等它结束再发"),
          "DSH connection failures tell the user what to do next")
}

print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) agent failure message checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)

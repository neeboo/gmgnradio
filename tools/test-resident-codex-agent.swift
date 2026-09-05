// Uses the real policy, transport and resident loop with a local fake JSONL peer.
import Foundation
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/ResidentCodexAgent.swift")
guard FileManager.default.fileExists(atPath: source.path) else { print("FAIL: resident Codex loop missing"); exit(1) }
let program = #"""
import Foundation
import Darwin
func bytes(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed) }
func json(_ value: Data) -> [String: Any] { try! JSONSerialization.jsonObject(with: value) as! [String: Any] }
func emit(_ value: [String: Any]) { FileHandle.standardOutput.write(bytes(value) + Data([10])) }
func fake() {
    let mode = CommandLine.arguments[2]
    let audit = CommandLine.arguments[3]
    func record(_ value: [String: Any]) {
        let file = try! FileHandle(forWritingTo: URL(fileURLWithPath: audit))
        _ = try! file.seekToEnd(); try! file.write(contentsOf: bytes(value) + Data([10])); try! file.close()
    }
    record(["launch": CommandLine.arguments])
    func finish(_ status: String = "completed", text: String = "已完成空间活动") {
        emit(["method": "item/completed", "params": ["threadId": "resident-session", "turnId": "turn-1", "item": ["id": "final", "type": "agentMessage", "phase": "final_answer", "text": text]]])
        var turn: [String: Any] = ["id": "turn-1", "status": status]
        if status == "failed" { turn["error"] = ["message": "PRIVATE-TURN", "codexErrorInfo": ["httpConnectionFailed": ["httpStatusCode": 401, "private": "PRIVATE"]], "additionalDetails": "PRIVATE"] }
        emit(["method": "turn/completed", "params": ["threadId": "resident-session", "turn": turn]])
    }
    while let line = readLine() {
        let frame = json(Data(line.utf8)); record(frame)
        guard let method = frame["method"] as? String else {
            if frame["id"] as? String == "tool-request" { finish() }
            continue
        }
        let id = frame["id"] ?? 0
        switch method {
        case "initialize": emit(["id": id, "result": [:]])
        case "config/read":
            if mode == "rpcFailure" {
                emit(["id": id, "error": ["code": -32603, "message": "Fatal error: failed to load rules: PRIVATE"]])
                continue
            }
            let disabled = CommandLine.arguments.contains { $0.contains("\"fixture.server\"={enabled=false}") }
            emit(["id": id, "result": ["config": [
                "features": Dictionary(uniqueKeysWithValues: ["plugins", "apps", "hooks", "multi_agent", "multi_agent_v2", "image_generation", "shell_tool"].map { ($0, false) }),
                "agents": ["enabled": false], "notify": [String](), "web_search": "disabled", "cli_auth_credentials_store": "file", "mcp_oauth_credentials_store": "file",
                "mcp_servers": ["fixture.server": ["enabled": !(disabled && mode != "unsafe"), "secret": "PRIVATE-CONFIG"]]
            ]]])
        case "thread/start", "thread/resume": emit(["id": id, "result": ["thread": ["id": "resident-session"]]])
        case "turn/start":
            emit(["method": "turn/started", "params": ["threadId": "resident-session", "turn": ["id": "turn-1", "status": "inProgress"]]])
            emit(["method": "item/completed", "params": ["threadId": "resident-session", "turnId": "turn-1", "item": ["id": "comment", "type": "agentMessage", "phase": "commentary", "text": "只是正在想"]]])
            if mode == "early" || mode == "earlyMismatch" { finish() }
            emit(["id": id, "result": ["turn": ["id": mode == "earlyMismatch" ? "other-turn" : "turn-1", "status": "inProgress"]]])
            if mode == "retry" || mode == "retryHang" {
                emit(["method": "error", "params": ["threadId": "resident-session", "turnId": "turn-1", "willRetry": true, "error": ["message": "PRIVATE-RETRY"]]])
                if mode == "retry" { finish() }
                continue
            }
            if mode == "errorFalse" || mode == "errorMissing" {
                var params: [String: Any] = ["threadId": "resident-session", "turnId": "turn-1", "error": ["message": "Missing environment variable: `PRIVATE-TERMINAL`", "codexErrorInfo": "unauthorized"]]
                if mode == "errorFalse" { params["willRetry"] = false }
                emit(["method": "error", "params": params])
                continue
            }
            if mode == "hang" { continue }
            if mode == "eof" { exit(0) }
            if mode == "failed" { finish("failed", text: "PRIVATE-SERVER-ERROR"); continue }
            if mode == "early" || mode == "earlyMismatch" { continue }
            if mode == "commentary" {
                emit(["method": "turn/completed", "params": ["threadId": "resident-session", "turn": ["id": "turn-1", "status": "completed"]]])
                continue
            }
            emit(["id": "tool-request", "method": "item/tool/call", "params": ["threadId": mode == "wrongThread" ? "other-room" : "resident-session", "turnId": mode == "wrongTurn" ? "other-turn" : "turn-1", "callId": "world-call", "namespace": NSNull(), "tool": mode == "wrongTool" ? "shell" : "inspect_world", "arguments": [:]]])
        default: break
        }
    }
}
@main struct Checks {
    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("--fake") { fake(); return }
        var checks = 0
        func check(_ condition: Bool, _ message: String) { guard condition else { fatalError("FAIL: " + message) }; checks += 1 }
        check(ResidentCodexSafeError.code(from: "unauthorized") == "unauthorized", "known safe error code")
        check(ResidentCodexSafeError.code(from: "PRIVATE-UNKNOWN") == nil, "unknown error string discarded")
        check(ResidentCodexSafeError.code(from: ["httpConnectionFailed": ["httpStatusCode": 401, "message": "PRIVATE"]]) == "httpConnectionFailed:401", "only known HTTP code projected")
        check(ResidentCodexSafeError.code(from: ["PRIVATE-UNKNOWN": ["httpStatusCode": 401]]) == nil, "unknown variant discarded")
        check(ResidentCodexSafeError.code(from: ["httpConnectionFailed": ["httpStatusCode": "PRIVATE"]]) == "httpConnectionFailed", "noninteger HTTP status discarded")
        for (message, expected) in [
            ("Fatal error: failed to read current time: PRIVATE", "clock_callback_failed"),
            ("Missing environment variable: `PRIVATE`", "missing_provider_env"),
            ("Fatal error: failed to load rules: PRIVATE", "rules_load_failed"),
            ("request timed out", "request_timeout"),
            ("request timed out PRIVATE", "unclassified"),
            ("stream disconnected before completion: PRIVATE", "stream_disconnected"),
            ("unexpected status 429: PRIVATE", "unexpected_http_status:429"),
            ("unexpected status 999: PRIVATE", "unclassified"),
            ("PRIVATE", "unclassified"),
        ] { check(ResidentCodexSafeError.category(message: message) == expected, "fixed category excludes private detail") }
        for parameter in ["model", "tools", "input", "reasoning", "service_tier", "PRIVATE"] {
            let message = String(decoding: bytes(["error": ["type": "invalid_request_error", "param": parameter, "message": "PRIVATE"]]), as: UTF8.self)
            check(ResidentCodexSafeError.category(message: message) == "upstream_invalid_request" + (parameter == "PRIVATE" ? "" : ":" + parameter), "only allowed upstream parameter name")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-loop-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tools = bytes(["inspect_world", "list_available_activities", "start_activity", "stop_activity"].map { ["name": $0, "description": "Fixture", "inputSchema": ["type": "object"]] as [String: Any] })
        func make(_ mode: String, timeout: TimeInterval = 3) throws -> (ResidentCodexAgent, URL) {
            let audit = directory.appendingPathComponent(UUID().uuidString)
            try Data().write(to: audit)
            let agent = ResidentCodexAgent(executableURL: URL(fileURLWithPath: CommandLine.arguments[0]), workingDirectoryURL: directory, environment: [:], turnTimeout: timeout, transportFactory: { executable, args, cwd, env in
                ResidentCodexTransport(executableURL: executable, arguments: ["--fake", mode, audit.path] + args, currentDirectoryURL: cwd, environment: env, requestTimeout: 1)
            })
            return (agent, audit)
        }
        func frames(_ file: URL) throws -> [[String: Any]] {
            try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map { json(Data($0.utf8)) }
        }
        var calls = 0
        let callback: @MainActor (String, String, Data) async -> ResidentCodexToolReply = { id, name, arguments in
            check(id == "world-call" && name == "inspect_world", "formal tool identity")
            check(json(arguments).isEmpty, "formal tool arguments")
            calls += 1
            return ResidentCodexToolReply(resultJSON: bytes(["ok": true]), isError: false)
        }
        let (normal, audit) = try make("normal")
        let result = try await normal.send(prompt: "查看空间", sessionID: nil, toolsJSON: tools, onToolCall: callback)
        check(result.reply == "已完成空间活动" && result.sessionID == "resident-session", "only final completed answer")
        check(calls == 1, "formal tool executed once")
        let log = try frames(audit)
        check(log.filter { $0["method"] as? String == "config/read" }.count == 2, "two process effective policy checks")
        let start = log.first { $0["method"] as? String == "thread/start" }!["params"] as! [String: Any]
        check((start["environments"] as? [Any])?.isEmpty == true && start["approvalPolicy"] as? String == "never", "thread has no environments or approval")
        check((start["dynamicTools"] as? [[String: Any]])?.allSatisfy { $0["type"] as? String == "function" } == true, "version-specific function discriminator")
        let turn = log.first { $0["method"] as? String == "turn/start" }!["params"] as! [String: Any]
        check((turn["environments"] as? [Any])?.isEmpty == true, "every turn disables environment")
        let toolResult = log.first { $0["id"] as? String == "tool-request" }?["result"] as? [String: Any]
        check(toolResult?["success"] as? Bool == true, "formal callback returns success content")

        let (resume, resumeAudit) = try make("normal")
        _ = try await resume.send(prompt: "继续", sessionID: result.sessionID, toolsJSON: tools, onToolCall: callback)
        check(try frames(resumeAudit).contains { $0["method"] as? String == "thread/resume" }, "resume same resident session")
        let (early, _) = try make("early")
        let earlyResult = try await early.send(prompt: "查看", sessionID: nil, toolsJSON: tools, onToolCall: callback)
        check(earlyResult.reply == "已完成空间活动", "completion preceding turn response is retained")
        let (retry, _) = try make("retry")
        let retryResult = try await retry.send(prompt: "查看", sessionID: nil, toolsJSON: tools, onToolCall: callback)
        check(retryResult.reply == "已完成空间活动", "retryable error waits for completed answer")

        for mode in ["wrongThread", "wrongTurn", "wrongTool"] {
            let (agent, file) = try make(mode)
            let before = calls
            _ = try await agent.send(prompt: "查看", sessionID: nil, toolsJSON: tools, onToolCall: callback)
            check(calls == before, "reject \(mode) before executing world")
            let reply = try frames(file).first { $0["id"] as? String == "tool-request" }?["result"] as? [String: Any]
            check(reply?["success"] as? Bool == false, "\(mode) formal failed result")
        }
        for mode in ["unsafe", "eof", "failed", "commentary", "hang", "earlyMismatch", "retryHang", "errorFalse", "errorMissing", "rpcFailure"] {
            let (agent, file) = try make(mode, timeout: mode == "eof" ? 3 : 0.3)
            let began = Date()
            do { _ = try await agent.send(prompt: "查看", sessionID: nil, toolsJSON: tools, onToolCall: callback); fatalError("FAIL: \(mode) must fail") }
            catch {
                check(!String(describing: error).contains("PRIVATE"), "\(mode) safe error")
                if mode == "retryHang" {
                    if case ResidentCodexAgentError.timedOut = error { check(true, "retry remains bounded by total deadline") }
                    else { fatalError("FAIL: retryable error must wait for deadline") }
                }
                if mode == "errorFalse" || mode == "errorMissing" {
                    if case ResidentCodexAgentError.turnFailed = error { check(true, "terminal error ends turn") }
                    else { fatalError("FAIL: terminal error must fail immediately") }
                    check(agent.failureCode == "unauthorized", "notification safe diagnostic survives transport")
                    check(agent.failureCategory == "missing_provider_env", "notification fixed category survives transport")
                }
                if mode == "failed" {
                    check(agent.failureCode == "httpConnectionFailed:401", "completed turn safe diagnostic")
                    check(agent.failureCategory == "unclassified", "completed private text discarded")
                }
                check(agent.failureStage != nil, "failure has fixed local stage")
                check(agent.didSendTurnStart == (mode != "unsafe" && mode != "rpcFailure"), "model turn dispatch is observable")
                if mode == "rpcFailure" { check(agent.failureCategory == "rules_load_failed", "RPC failure uses fixed safe category") }
            }
            if mode == "unsafe" { check(try !frames(file).contains { ($0["method"] as? String)?.hasPrefix("thread/") == true }, "unsafe policy never starts thread") }
            if mode == "eof" { check(Date().timeIntervalSince(began) < 1.5, "EOF ends turn without deadline") }
        }
        let (cancelled, _) = try make("hang")
        let waiting = Task { try await cancelled.send(prompt: "查看", sessionID: nil, toolsJSON: tools, onToolCall: callback) }
        try await Task.sleep(nanoseconds: 100_000_000)
        waiting.cancel()
        do { _ = try await waiting.value; fatalError("FAIL: cancellation") }
        catch { check(error is CancellationError, "task cancellation ends whole turn") }
        print("PASS: \(checks) resident Codex agent checks")
    }
}
"""#
let work = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-agent-test-" + UUID().uuidString)
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }
let main = work.appendingPathComponent("Checks.swift")
try program.write(to: main, atomically: true, encoding: .utf8)
let binary = work.appendingPathComponent("checks")
let compiler = Process(); compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
compiler.arguments = ["swiftc", "-swift-version", "6", "-parse-as-library", source.path, root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/ResidentCodexTransport.swift").path, root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/ResidentCodexPolicy.swift").path, main.path, "-o", binary.path]
try compiler.run(); compiler.waitUntilExit()
guard compiler.terminationStatus == 0 else { exit(compiler.terminationStatus) }
let test = Process(); test.executableURL = binary; try test.run(); test.waitUntilExit(); exit(test.terminationStatus)

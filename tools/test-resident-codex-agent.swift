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
struct FixtureLocator: AgentExecutableLocating {
    func locate(executableNames: [String]) -> URL? { URL(fileURLWithPath: CommandLine.arguments[0]) }
}
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
            if frame["id"] as? String == "tool-request" { finish(text: mode.hasPrefix("silent") ? "" : "已完成空间活动") }
            continue
        }
        let id = frame["id"] ?? 0
        switch method {
        case "initialize": emit(["id": id, "result": [:]])
        case "config/read":
            if mode == "rpcUpgrade" {
                emit(["id": id, "error": ["code": -32603, "message": "The PRIVATE model requires a newer version of Codex. Please update to the latest version and try again."]])
                continue
            }
            if mode == "rpcFailure" {
                emit(["id": id, "error": ["code": -32603, "message": "Fatal error: failed to load rules: PRIVATE"]])
                continue
            }
            let disabled = CommandLine.arguments.contains { $0.contains("\"fixture.server\"={enabled=false}") }
            emit(["id": id, "result": ["config": [
                "features": Dictionary(uniqueKeysWithValues: ["plugins", "apps", "hooks", "multi_agent", "multi_agent_v2", "image_generation", "shell_tool"].map { ($0, false) }),
                "agents": ["enabled": false], "notify": [String](), "web_search": "live", "cli_auth_credentials_store": "file", "mcp_oauth_credentials_store": "file",
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
            if mode == "upgrade" {
                let upstream = String(decoding: bytes(["error": ["type": "invalid_request_error", "param": "model", "message": "The PRIVATE model requires a newer version of Codex. Please update to the latest version and try again."]]), as: UTF8.self)
                emit(["method": "error", "params": ["threadId": "resident-session", "turnId": "turn-1", "willRetry": false, "error": ["message": upstream, "codexErrorInfo": "other"]]])
                continue
            }
            if mode == "errorFalse" || mode == "errorMissing" {
                var params: [String: Any] = ["threadId": "resident-session", "turnId": "turn-1", "error": ["message": "Missing environment variable: `PRIVATE-TERMINAL`", "codexErrorInfo": "unauthorized"]]
                if mode == "errorFalse" { params["willRetry"] = false }
                emit(["method": "error", "params": params])
                continue
            }
            if mode == "hang" || (mode.hasPrefix("steer") && mode != "steerDuringTool") { continue }
            if mode == "eof" { exit(0) }
            if mode == "failed" { finish("failed", text: "PRIVATE-SERVER-ERROR"); continue }
            if mode == "early" || mode == "earlyMismatch" { continue }
            if mode == "commentary" {
                emit(["method": "turn/completed", "params": ["threadId": "resident-session", "turn": ["id": "turn-1", "status": "completed"]]])
                continue
            }
            emit(["id": "tool-request", "method": "item/tool/call", "params": ["threadId": mode == "wrongThread" ? "other-room" : "resident-session", "turnId": mode == "wrongTurn" ? "other-turn" : "turn-1", "callId": "world-call", "namespace": NSNull(), "tool": mode == "wrongTool" ? "shell" : (mode.hasPrefix("silent") ? "update_resident_intent" : "inspect_world"), "arguments": [:]]])
        case "turn/steer":
            if mode == "steerRejected" {
                emit(["id": id, "error": ["code": -32600, "message": "No active turn"]])
            } else if mode == "steerEOF" { exit(0) }
            else if mode == "steerTimeout" { continue }
            else {
                emit(["id": id, "result": ["turnId": mode == "steerWrongAck" ? "other-turn" : "turn-1"]])
            }
            finish()
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
        let rejectionCases: [(String, String?, String)] = [
            ("Unsupported value: 'namespace'. PRIVATE", "tools[12].type", "unsupported_value;parameter=tools[].type;feature=namespace"),
            ("Unsupported tool namespace PRIVATE", nil, "unsupported_value;feature=namespace"),
            ("Unsupported parameter: 'environment'. PRIVATE", nil, "unsupported_parameter;parameter=environment;feature=environment"),
            ("Unsupported parameter: 'tool_choice'. PRIVATE", nil, "unsupported_parameter;parameter=tool_choice;feature=tool_choice"),
            ("Invalid schema for function PRIVATE: missing properties", "tools[0].parameters", "invalid_schema;parameter=tools[].parameters;feature=function"),
            ("Invalid schema: PRIVATE", "tools[0].parameters.additionalProperties", "invalid_schema;parameter=tools[].parameters.additionalproperties"),
            ("tools must contain at least one tool", "tools", "empty_tools;parameter=tools"),
            ("Missing required parameter: 'input'. PRIVATE", "input", "missing_required_parameter;parameter=input"),
            ("Unsupported model PRIVATE", "model", "unsupported_model;parameter=model"),
            ("The model PRIVATE does not exist", "model", "model_not_found;parameter=model"),
            ("You do not have access to model PRIVATE", "model", "model_access_denied;parameter=model"),
            ("Invalid value: PRIVATE", "tools[5].parameters.properties.PRIVATE", "invalid_value"),
            ("PRIVATE value is PRIVATE", nil, "unclassified"),
            ("PRIVATE secret", "PRIVATE.path", "unclassified"),
            ("token: high priority account", nil, "unclassified"),
            ("Store must be set to false", nil, "required_value;parameter=store"),
            ("Instructions are required", nil, "missing_required_parameter;parameter=instructions"),
            ("The PRIVATE model requires a newer version of Codex. Please update to the latest version and try again.", "model", "codex_upgrade_required;parameter=model"),
            ("This model requires a newer version of Codex.", "model", "codex_upgrade_required;parameter=model"),
        ]
        for (message, param, expected) in rejectionCases {
            let envelope = String(decoding: bytes(["error": ["type": "invalid_request_error", "message": message, "param": param as Any? ?? NSNull()]]), as: UTF8.self)
            check(ResidentCodexSafeError.detail(message: envelope) == expected, "safe upstream rejection detail")
        }
        for param in ["text.verbosity", "reasoning.effort", "service_tier", "store", "include", "parallel_tool_calls", "truncation", "max_output_tokens"] {
            check(ResidentCodexSafeError.detail(message: "Unsupported parameter: '\(param)'. PRIVATE") == "unsupported_parameter;parameter=\(param)", "fixed response field recognized without JSON param")
        }
        check(!ResidentCodexSafeError.detail(message: "The model uses this version of Codex. Please try again later.").hasPrefix("codex_upgrade_required"), "version mention alone does not request upgrade")
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
        for prompt in ["请看这张图片", ""] {
            let (agent, audit) = try make("early")
            let image = directory.appendingPathComponent("prepared image.png")
            _ = try await agent.send(prompt: prompt, imageURLs: [image], sessionID: nil, toolsJSON: tools) { _, _, _ in
                ResidentCodexToolReply(resultJSON: bytes(["ok": true]), isError: false)
            }
            let lines = try String(contentsOf: audit, encoding: .utf8).split(separator: "\n").map { json(Data($0.utf8)) }
            let turn = lines.first { $0["method"] as? String == "turn/start" }!["params"] as! [String: Any]
            let input = turn["input"] as! [[String: Any]]
            check(input.last?["type"] as? String == "localImage", "image is native localImage input")
            check(input.last?["path"] as? String == image.path, "prepared local image path preserved")
            check(input.filter { $0["type"] as? String == "text" }.count == (prompt.isEmpty ? 0 : 1), "pure image does not need a fake text prompt")
            check((turn["runtimeWorkspaceRoots"] as? [String]) == [], "image does not expand workspace access")
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
        for mode in ["unsafe", "eof", "failed", "commentary", "hang", "earlyMismatch", "retryHang", "errorFalse", "errorMissing", "rpcFailure", "upgrade", "rpcUpgrade"] {
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
                    check(agent.failureDetail == "unclassified;parameter=environment;feature=environment", "notification safe detail survives transport")
                }
                if mode == "failed" {
                    check(agent.failureCode == "httpConnectionFailed:401", "completed turn safe diagnostic")
                    check(agent.failureCategory == "unclassified", "completed private text discarded")
                    check(agent.failureDetail == "unclassified", "completed safe detail retains no private text")
                }
                check(agent.failureStage != nil, "failure has fixed local stage")
                check(agent.didSendTurnStart == (mode != "unsafe" && mode != "rpcFailure" && mode != "rpcUpgrade"), "model turn dispatch is observable")
                if mode == "rpcFailure" { check(agent.failureCategory == "rules_load_failed", "RPC failure uses fixed safe category") }
                if mode == "upgrade" || mode == "rpcUpgrade" {
                    if case ResidentCodexAgentError.codexUpgradeRequired = error { check(true, "outdated Codex has specific user-facing failure") }
                    else { fatalError("FAIL: outdated client must request upgrade") }
                    check((error as? LocalizedError)?.errorDescription?.contains("更新 Codex") == true, "user sees actionable upgrade guidance")
                }
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

        let loopTools = bytes(["inspect_world", "update_resident_intent"].map {
            ["name": $0, "description": "Fixture", "inputSchema": ["type": "object"]] as [String: Any]
        })
        let (silent, _) = try make("silent")
        var controlSucceeded = false
        let quiet = try await silent.send(prompt: "自主安排", sessionID: nil, toolsJSON: loopTools,
            allowsSilentCompletion: { controlSucceeded }, onToolCall: { _, name, _ in
                check(name == "update_resident_intent", "registered loop tool reaches caller")
                controlSucceeded = true
                return ResidentCodexToolReply(resultJSON: bytes(["ok": true]), isError: false)
            })
        check(quiet.reply.isEmpty, "explicit successful control allows quiet completion")
        let (silentDenied, _) = try make("silentDenied")
        do {
            _ = try await silentDenied.send(prompt: "自主安排", sessionID: nil, toolsJSON: loopTools,
                onToolCall: { _, _, _ in ResidentCodexToolReply(resultJSON: bytes(["ok": false]), isError: true) })
            fatalError("FAIL: empty final requires explicit current turn control success")
        } catch { check(error is ResidentCodexAgentError, "ordinary empty final remains failure") }
        let (silentNoTool, _) = try make("commentary")
        do {
            _ = try await silentNoTool.send(prompt: "自主安排", sessionID: nil, toolsJSON: loopTools,
                allowsSilentCompletion: { true }, onToolCall: callback)
            fatalError("FAIL: stale caller flag cannot authorize silence without a tool this turn")
        } catch { check(error is ResidentCodexAgentError, "silent permission also requires tool execution this turn") }
        let (silentFailedTool, _) = try make("silentFailedTool")
        do {
            _ = try await silentFailedTool.send(prompt: "自主安排", sessionID: nil, toolsJSON: loopTools,
                allowsSilentCompletion: { true }, onToolCall: { _, _, _ in
                    ResidentCodexToolReply(resultJSON: bytes(["ok": false]), isError: true)
                })
            fatalError("FAIL: a failed tool cannot authorize silence")
        } catch { check(error is ResidentCodexAgentError, "failed tool cannot authorize silent completion") }

        // 工具回执原生图片通道：响应 schema 恰为 contentItems [inputText,
        // inputImage(data:image/png;base64,…)] + success；不带 localImage/path；
        // 超预算图片按失败处理，静默完成只有在图片验证也通过后才被允许。
        func codexFixtureImage(pngBytes: Int) -> ResidentVisionImage {
            let camera = ResidentVisionCameraStamp(label: "codex-fixture", kind: .fullStageObserver,
                position: [0, 0, 0], yaw: 0, pitch: 0, fieldOfViewDegrees: 66, coordinateSpace: "world")
            let stamp = ResidentVisionRenderedStamp(surfaceProfile: "full_stage_drawable", frameIndex: 1,
                capturedAt: Date(timeIntervalSince1970: 100), worldID: "fixture", residentAvatarID: nil,
                residentAvatarFrameRevision: nil, residentPosition: nil, camera: camera)
            let frame = ResidentVisionRenderedFrame(pixelsBGRA: Data(repeating: 0x7F, count: 16),
                width: 4, height: 1, bytesPerRow: 16, stamp: stamp)
            return ResidentVisionImage(pngData: Data(repeating: 0x50, count: pngBytes),
                metadata: ResidentVisionMetadata.make(renderedFrame: frame,
                    perspective: .currentObservation, expectedWorldRevision: nil), fileURL: nil)
        }
        do {
            let (imageAgent, imageFile) = try make("silentImage")
            let imageResult = try await imageAgent.send(prompt: "自主查看", sessionID: nil, toolsJSON: loopTools,
                allowsSilentCompletion: { true }, onToolCall: { _, _, _ in
                    ResidentCodexToolReply(resultJSON: bytes(["ok": true, "message": "真实画面"]), isError: false,
                        image: codexFixtureImage(pngBytes: 256))
                })
            check(imageResult.reply.isEmpty, "a fully validated image reply permits quiet completion")
            let response = try frames(imageFile).first { $0["id"] as? String == "tool-request" }?["result"] as? [String: Any]
            let items = response?["contentItems"] as? [[String: Any]]
            check(response?["success"] as? Bool == true, "validated image reply reports success")
            check(items?.first?["type"] as? String == "inputText", "the reply text rides inputText")
            check(items?.count == 2 && items?.last?["type"] as? String == "inputImage",
                "the real PNG rides one native inputImage item")
            let imageURL = items?.last?["imageUrl"] as? String ?? ""
            check(imageURL.hasPrefix("data:image/png;base64,"), "the inputImage item carries a PNG data URL")
            check(!imageURL.hasPrefix("file:") && !imageURL.contains("/tmp/"), "no local file path leaks into the reply")
        }
        do {
            let (deniedAgent, deniedFile) = try make("silentImage")
            do {
                _ = try await deniedAgent.send(prompt: "自主查看", sessionID: nil, toolsJSON: loopTools,
                    allowsSilentCompletion: { true }, onToolCall: { _, _, _ in
                        ResidentCodexToolReply(resultJSON: bytes(["ok": true]), isError: false,
                            image: codexFixtureImage(pngBytes: 513 * 1024))
                    })
                fatalError("FAIL: an over-budget image must fail validation and deny silence")
            } catch { check(error is ResidentCodexAgentError, "an over-budget image fails the turn") }
            let deniedResponse = try frames(deniedFile).first { $0["id"] as? String == "tool-request" }?["result"] as? [String: Any]
            check(deniedResponse?["success"] as? Bool == false, "an over-budget image returns a failed result")
            let deniedItems = deniedResponse?["contentItems"] as? [[String: Any]] ?? []
            check(!deniedItems.contains { $0["type"] as? String == "inputImage" },
                "an over-budget image never ships image bytes")
        }

        let (duringTool, duringToolAudit) = try make("steerDuringTool")
        var pendingTool: CheckedContinuation<Void, Never>?
        let duringToolTask = Task {
            try await duringTool.send(prompt: "去点唱机", sessionID: nil, toolsJSON: tools, onToolCall: { _, _, _ in
                await withCheckedContinuation { pendingTool = $0 }
                return ResidentCodexToolReply(resultJSON: bytes(["ok": true]), isError: false)
            })
        }
        for _ in 0..<200 {
            if pendingTool != nil { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        check(pendingTool != nil, "world tool is genuinely pending")
        check(await duringTool.steer("先别急") == .delivered, "steer can arrive while a world tool is pending")
        check(try !frames(duringToolAudit).contains { $0["method"] as? String == "turn/interrupt" }, "ordinary guidance never interrupts current tool")
        pendingTool?.resume()
        _ = try await duringToolTask.value

        for (mode, expected) in [("steer", ResidentSteeringDelivery.delivered), ("steerRejected", .notDelivered),
                                 ("steerEOF", .unknown), ("steerWrongAck", .unknown), ("steerTimeout", .unknown)] {
            let (agent, file) = try make(mode)
            check(await agent.steer("尚未开始") == .notDelivered, "idle steer stays unsent")
            let task = Task { try await agent.send(prompt: "听歌", sessionID: nil, toolsJSON: tools, onToolCall: callback) }
            for _ in 0..<200 {
                if try frames(file).contains(where: { $0["method"] as? String == "turn/start" }) { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            try await Task.sleep(nanoseconds: 10_000_000)
            check(await agent.steer("换舒缓的") == expected, "\(mode) delivery has honest acknowledgement")
            agent.cancel()
            _ = try? await task.value
            let sent = try frames(file).filter { $0["method"] as? String == "turn/steer" }
            check(sent.count == 1, "steer is never retried automatically")
            let parameters = sent.first!["params"] as! [String: Any]
            check(parameters["expectedTurnId"] as? String == "turn-1" && parameters["threadId"] as? String == "resident-session", "steer binds active turn precondition")
            check((parameters["input"] as? [[String: Any]])?.first?["text"] as? String == "换舒缓的", "steer preserves human guidance")
            check(await agent.steer("结束后") == .notDelivered, "completed turn steer stays unsent")
        }
        let suite = "gmgn-steer-service-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let (serviceAgent, serviceAudit) = try make("steer")
        let service = AgentConversationService(locator: FixtureLocator(), defaults: defaults,
            useResidentAgent: true, residentAgentFactory: { _, _ in serviceAgent })
        service.selectBackend(.codex)
        check(await service.steerResident("闲置") == .notDelivered, "service idle steering returns unsent")
        let context = ResidentWorldContext(selectedWorldID: "fixture", worldID: "fixture", displayName: nil,
            revision: 1, residentPosition: nil, activeActivity: nil, activityPhase: nil, objects: [], availableActivities: [])
        defaults.set("legacy-session", forKey: AgentConversationPreferenceKeys.sessionKey(for: .codex) + "." + context.sessionScope + ".tools.v5")
        let serviceTools = ResidentConversationTools(worldID: "fixture", schemasJSON: tools,
            call: { _, _, _ in ResidentCodexToolReply(resultJSON: bytes(["ok": true]), isError: false) }, cancel: {})
        let serviceImage = directory.appendingPathComponent("service-image.png")
        let serviceTask = Task { try await service.send("播放", imageURLs: [serviceImage], worldContext: context, worldTools: serviceTools) }
        for _ in 0..<200 {
            if try frames(serviceAudit).contains(where: { $0["method"] as? String == "turn/start" }) { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        check(await service.steerResident("慢一点") == .delivered, "service steers the actual active resident")
        check(try await serviceTask.value == "已完成空间活动", "steering retains original reply task")
        let serviceTurn = try frames(serviceAudit).first { $0["method"] as? String == "turn/start" }!["params"] as! [String: Any]
        check((serviceTurn["input"] as? [[String: Any]])?.last?["path"] as? String == serviceImage.path, "service forwards images through actual resident agent transport")
        check(try !frames(serviceAudit).contains { $0["method"] as? String == "thread/resume" }, "new tools registry does not resume legacy session")
        check(service.preferenceStore.sessionID(for: .codex, scope: context.sessionScope + ".tools.v8") == "resident-session", "new web-reference registry session is stored separately")
        check(service.preferenceStore.sessionID(for: .codex, scope: context.sessionScope + ".tools.v7") == nil, "the previous registry session is never reused after the web-reference upgrade")
        check(service.preferenceStore.sessionID(for: .codex, scope: context.sessionScope + ".tools.v5") == "legacy-session", "old resident session remains intact after one-time tool registry upgrade")
        check(await service.steerResident("结束后") == .notDelivered, "service releases finished resident")
        service.selectBackend(.dsh)
        check(await service.steerResident("不支持") == .notDelivered, "unsupported backend steering remains unsent")
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
let agentFiles = ["ResidentCodexTransport", "ResidentCodexPolicy", "AgentConversationService", "CodexCLI",
    "ResidentSteeringDelivery", "ResidentDSHTransport", "ResidentDSHConfiguration",
    "ResidentStateClient", "ResidentMemoryClient", "ResidentConversationMemory",
    "ResidentDSHAgentToolBridge", "ResidentDSHHostToolsBridge",
    "ResidentClaudeToolBridge", "ResidentClaudeProcessRunner"].map {
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/\($0).swift").path
}
let visionFile = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/ResidentVisionCapture.swift")
// `ResidentDSHHostToolsBridge` reads the repo's single retry-backoff policy from
// `Presence/RetryBackoff.swift`; that source is self-contained and must ride along
// or the harness stops at "cannot find 'RetryBackoffSite' in scope".
let retryBackoffFile = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/RetryBackoff.swift")
compiler.arguments = ["swiftc", "-j1", "-swift-version", "6", "-parse-as-library", source.path]
    + agentFiles + [visionFile.path, retryBackoffFile.path] + [main.path, "-o", binary.path]
try compiler.run(); compiler.waitUntilExit()
guard compiler.terminationStatus == 0 else { exit(compiler.terminationStatus) }
let test = Process(); test.executableURL = binary; try test.run(); test.waitUntilExit(); exit(test.terminationStatus)

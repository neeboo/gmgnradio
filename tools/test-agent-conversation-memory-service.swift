// AgentConversationService ↔ ResidentConversationMemory 接线的离线行为核对。
// 编译真实 AgentConversationService.swift + ResidentStateClient/MemoryClient/
// ResidentConversationMemory + 所需 Agent 支持源；fake backend runner 与
// fixture transport 绝不启动 taskd/宿主、不读真实数据库/环境。覆盖：
//   - send 每轮用真实用户文字（显式 userMessage 或只读聊天 text）做 memory_recall，
//     不用宿主拼装 prompt；无真实输入的后台轮次不召回、不登记假 user turn；
//   - 只有「新原生会话 / 无 DSH 进程内历史」才 freshSession=true，续聊 false；
//     DSH 原生 ACP 会话续聊每轮仍真实召回，上下文进入该次 submit 的增量 prompt，
//     不重复整段恢复历史；
//   - 模型返回绝不 memory_ingest；App 显式 confirmDeliveredTurn（run/world 检查 +
//     显示/语音完成后）才入队，且校验 requestID/userText/scope/generation——
//     取消/重置/scope 切换/新一轮后迟到确认不写；
//   - 缺配置/召回失败/未接线记忆时聊天照常可用；
//   - 文本违反合同（空/超长/C0/C1 控制字符）合理拒绝，不写、不持久原文。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let work = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-conv-memory-service-\(UUID())")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

let harness = #"""
import Foundation

@MainActor var checks = 0
@MainActor var failures = 0
@MainActor func check(_ value: Bool, _ message: String) {
    checks += 1
    if !value { failures += 1; print("FAIL: \(message)") }
}

@MainActor func pump(_ times: Int = 12) async {
    for _ in 0..<times { await Task.yield() }
}

@MainActor func eventually(_ condition: @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(8)
    while !condition() {
        if Date() >= deadline { break }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

// MARK: - 记忆 fixture transport

func scope(_ world: String, _ resident: String) -> ResidentStateScope {
    ResidentStateScope(worldID: world, residentScope: resident)
}

func recallResponse(context: String, status: String = "ok") -> [String: ResidentStateJSON] {
    ["status": .string(status), "revision": .number(0), "vectorGeneration": .number(0),
     "facts": .array([]), "notes": .array([]), "context": .string(context),
     "pendingTurns": .number(0)]
}

func ingestResponse() -> [String: ResidentStateJSON] {
    ["accepted": .bool(true), "replayed": .bool(false),
     "pendingTurns": .number(0), "consolidation": .string("pending")]
}

/// 立即回放型记忆 transport：记录每次请求，按需返回 recall/ingest fixture。
@MainActor final class MemoryTransportStub: ResidentStateTransport, @unchecked Sendable {
    private(set) var recorded: [(method: String, params: [String: ResidentStateJSON])] = []
    var recallContext = "这位居民喜欢在雨天听爵士乐。"
    var recallStatus = "ok"
    /// freshSession=true（真正新会话）的恢复段内容；缺省回退 recallContext。
    var freshRecallContext: String?
    /// freshSession=false（续聊）的本轮相关内容；缺省回退 recallContext。
    var resumeRecallContext: String?
    /// 剩余的前 N 次任意调用抛 daemon 拒绝（召回失败路径）。
    var failNextCalls = 0

    func call(method: String, params: [String: ResidentStateJSON]) async throws -> [String: ResidentStateJSON] {
        recorded.append((method, params))
        if failNextCalls > 0 {
            failNextCalls -= 1
            throw ResidentStateError.daemon("memory_storage_failed")
        }
        switch method {
        case "memory_recall":
            let fresh = params["freshSession"]?.boolValue == true
            let context = fresh
                ? (freshRecallContext ?? recallContext)
                : (resumeRecallContext ?? recallContext)
            return recallResponse(context: context, status: recallStatus)
        case "memory_ingest":
            return ingestResponse()
        default:
            throw ResidentStateError.daemon("unsupported_method")
        }
    }

    func calls(_ method: String) -> [[String: ResidentStateJSON]] {
        recorded.filter { $0.method == method }.map(\.params)
    }
}

/// DSH 原生 ACP 会话 fake：记录每次 submit 的文本块与次数，绝不启动真实进程。
@MainActor
private final class NativeSessionConnector: ResidentDSHImageConnecting {
    var isUsable = true
    private(set) var promptCount = 0
    private(set) var textBlocks: [String] = []

    func openSession(cwd: URL) async throws -> ResidentDSHSessionHandle {
        ResidentDSHSessionHandle(sessionID: "native-session-1", imagePromptCapability: true)
    }

    func prompt(sessionID: String, blocks: [ResidentDSHPromptBlock]) async throws -> String {
        promptCount += 1
        let texts = blocks.compactMap { block -> String? in
            if case let .text(text) = block { return text }
            return nil
        }
        textBlocks.append(texts.joined(separator: "\n"))
        return "原生回复\(promptCount)"
    }

    func cancelActivePrompt() {}
    func close() { isUsable = false }
}

// MARK: - fake backends

@MainActor
private func makeWorld(id: String = "cabin") -> ResidentWorldContext {
    ResidentWorldContext(
        selectedWorldID: id, worldID: id, displayName: nil, revision: 1,
        residentPosition: nil, activeActivity: nil, activityPhase: nil,
        objects: [], availableActivities: []
    )
}

@MainActor
private func makeDefaults() -> UserDefaults {
    let name = "AgentConversationMemoryService-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

/// 按名字探测已安装后端的 locator（与既有服务测试一致）。
private struct StubLocator: AgentExecutableLocating {
    let installedNames: Set<String>
    func locate(executableNames: [String]) -> URL? {
        guard let name = executableNames.first(where: { installedNames.contains($0) }) else { return nil }
        return URL(filePath: "/usr/local/bin/\(name)")
    }
}

/// Codex `exec --json` runner：发出 thread.started + agent_message。服务路径
/// 全部在 MainActor 上，runner 也标注 @MainActor，避免在 async 中使用 NSLock。
@MainActor
private final class CodexRunner: CodexCommandRunning {
    private var storage: [String] = []
    private let reply: String

    init(reply: String = "嗨，欢迎回来。") { self.reply = reply }

    var prompts: [String] { storage }

    func run(arguments: [String], standardInput: String?) async throws -> CodexCommandResult {
        storage.append(standardInput ?? "")
        return CodexCommandResult(exitCode: 0, output: "{\"type\":\"thread.started\",\"thread_id\":\"thread-session-1\"}\n{\"type\":\"agent_message\",\"message\":\"\(reply)\"}")
    }
}

/// DSH headless runner：记录最后一帧 prompt，返回固定回复。
@MainActor
private final class DSHRunner: CodexCommandRunning {
    private var storage: [String] = []

    var prompts: [String] { storage }

    func run(arguments: [String], standardInput: String?) async throws -> CodexCommandResult {
        storage.append(arguments.last ?? "")
        return CodexCommandResult(exitCode: 0, output: "好的")
    }
}

/// 挂起直到测试显式 resume 的 runner（取消路径用）。
@MainActor
private final class SuspendableRunner: CodexCommandRunning {
    private var pending: CheckedContinuation<CodexCommandResult, Error>?
    private(set) var started = false

    func run(arguments: [String], standardInput: String?) async throws -> CodexCommandResult {
        started = true
        return try await withCheckedThrowingContinuation { continuation in
            if Task.isCancelled {
                continuation.resume(throwing: CancellationError())
                return
            }
            pending = continuation
        }
    }

    func resume(_ result: CodexCommandResult) {
        pending?.resume(returning: result)
        pending = nil
    }
}

// MARK: - 行为场景

@MainActor func run() async throws {
    // 1. 全新 codex 原生会话：每轮用真实用户文字召回(freshSession=true)，
    //    模型返回绝不 ingest；App 显式交付确认后才 ingest 一次（source 透传）。
    do {
        let transport = MemoryTransportStub()
        let memory = ResidentConversationMemory(transport: transport)
        let runner = CodexRunner()
        let service = AgentConversationService(
            locator: StubLocator(installedNames: ["codex"]),
            defaults: makeDefaults(),
            runnerFactory: { _ in runner }
        )
        service.attachConversationMemory(memory)
        let world = makeWorld()
        let reply = try await service.send("你好", worldContext: world)
        check(reply == "嗨，欢迎回来。", "fresh codex turn still replies normally")

        let recalls = transport.calls("memory_recall")
        check(recalls.count == 1, "exactly one recall per real-text resident turn")
        check(recalls.first.flatMap { $0["query"]?.stringValue } == "你好",
              "recall query is the real user text, not the host prompt")
        check(recalls.first.flatMap { $0["freshSession"]?.boolValue } == true,
              "no native thread yet -> freshSession=true")
        check(runner.prompts.count == 1 && runner.prompts[0].contains(transport.recallContext),
              "memory context is injected ahead of the fresh-session prompt")
        check(runner.prompts[0].contains("居民对话记录") == false,
              "no legacy durable transcript wording is injected")

        check(transport.calls("memory_ingest").isEmpty,
              "model return alone never ingests (no memory_ingest yet)")
        guard let requestID = service.lastTurnDeliveryRequestID else {
            check(false, "successful real-text turn registers a pending delivery requestID")
            return
        }
        let delivery = service.confirmDeliveredTurn(
            requestID: requestID, userText: "你好", reply: reply, source: .voice
        )
        check(delivery == .accepted, "explicit delivery confirmation after run/world checks is accepted")
        await eventually { !transport.calls("memory_ingest").isEmpty }
        let ingests = transport.calls("memory_ingest")
        check(ingests.count == 1, "confirmed delivery enqueues exactly one ingest")
        if let params = ingests.first {
            check(params["userText"]?.stringValue == "你好", "ingest carries the real user text")
            check(params["agentReply"]?.stringValue == "嗨，欢迎回来。", "ingest carries the delivered reply")
            check(params["source"]?.stringValue == "voice", "source=voice is forwarded")
            check(params["requestID"]?.stringValue == requestID.uuidString,
                  "ingest uses the confirmed requestID")
            if case let .object(scopeObject)? = params["scope"] {
                check(scopeObject["worldID"]?.stringValue == "cabin", "ingest scoped to the resident world")
            } else {
                check(false, "ingest carries an embedded scope object")
            }
        }
        let second = service.confirmDeliveredTurn(
            requestID: requestID, userText: "你好", reply: reply
        )
        check(second == .notCurrent, "a second confirmation for an already-accepted requestID is not current")
        check(transport.calls("memory_ingest").count == 1, "no duplicate ingest after repeated confirm")
    }

    // 2. 原生续聊（已存 session id）：recall 用真实用户文字但 freshSession=false。
    do {
        let transport = MemoryTransportStub()
        let memory = ResidentConversationMemory(transport: transport)
        let runner = CodexRunner(reply: "收到。")
        let defaults = makeDefaults()
        defaults.set("existing-thread", forKey: "agentConversation.session.codex.\(makeWorld().sessionScope)")
        let service = AgentConversationService(
            locator: StubLocator(installedNames: ["codex"]),
            defaults: defaults,
            runnerFactory: { _ in runner }
        )
        service.attachConversationMemory(memory)
        let world = makeWorld()
        _ = try await service.send("继续", worldContext: world)
        let recalls = transport.calls("memory_recall")
        check(recalls.count == 1, "resumed native turn still recalls per turn")
        check(recalls.first.flatMap { $0["query"]?.stringValue } == "继续",
              "resumed recall query is the real user text")
        check(recalls.first.flatMap { $0["freshSession"]?.boolValue } == false,
              "existing native thread -> freshSession=false")
        check(transport.calls("memory_ingest").isEmpty, "resumed turn still waits for explicit confirmation")
    }

    // 3. DSH：无进程内历史 = 新会话（freshSession=true）；续聊轮次 false；prompt 带记忆背景。
    do {
        let transport = MemoryTransportStub()
        let memory = ResidentConversationMemory(transport: transport)
        let runner = DSHRunner()
        let service = AgentConversationService(
            locator: StubLocator(installedNames: ["dsh"]),
            defaults: makeDefaults(),
            runnerFactory: { _ in runner }
        )
        service.selectBackend(.dsh)
        service.attachConversationMemory(memory)
        let world = makeWorld()
        _ = try await service.send("第一句", worldContext: world)
        var recalls = transport.calls("memory_recall")
        check(recalls.count == 1 && recalls[0]["freshSession"]?.boolValue == true,
              "DSH fresh process history -> freshSession=true")
        check(recalls[0]["query"]?.stringValue == "第一句", "DSH recall uses real user text")
        check(runner.prompts.count == 1 && runner.prompts[0].contains(transport.recallContext),
              "DSH fresh prompt carries the memory background context")

        _ = try await service.send("第二句", worldContext: world)
        recalls = transport.calls("memory_recall")
        check(recalls.count == 2, "each real-text DSH turn recalls")
        check(recalls[1]["freshSession"]?.boolValue == false,
              "DSH continuation (in-process history) -> freshSession=false")
        check(recalls[1]["query"]?.stringValue == "第二句", "DSH continuation recall uses real user text")
        check(runner.prompts.count == 2 && runner.prompts[1].contains("用户：第一句"),
              "DSH in-memory history is still carried across turns")
        check(transport.calls("memory_ingest").isEmpty, "DSH turns never ingest at model return")

        guard let rid = service.lastTurnDeliveryRequestID else {
            check(false, "DSH turn registers a delivery requestID")
            return
        }
        check(service.confirmDeliveredTurn(requestID: rid, userText: "第二句", reply: "好的") == .accepted,
              "DSH explicit delivery confirmation is accepted")
        await eventually { !transport.calls("memory_ingest").isEmpty }
        check(transport.calls("memory_ingest").count == 1, "DSH confirmed turn ingests exactly once")
    }

    // 4. 取消：已取消/迟到成功不能 stage，显式确认一律 notCurrent，绝不 ingest。
    do {
        let transport = MemoryTransportStub()
        let memory = ResidentConversationMemory(transport: transport)
        let suspended = SuspendableRunner()
        let service = AgentConversationService(
            locator: StubLocator(installedNames: ["codex"]),
            defaults: makeDefaults(),
            runnerFactory: { _ in suspended }
        )
        service.attachConversationMemory(memory)
        let world = makeWorld()
        let task = Task { @MainActor in
            try? await service.send("你好", worldContext: world)
        }
        await eventually { suspended.started }
        service.cancel()
        check(service.lastTurnDeliveryRequestID == nil, "cancelled turn stages no delivery credential")
        suspended.resume(CodexCommandResult(exitCode: 0, output: "{\"type\":\"thread.started\",\"thread_id\":\"late-thread\"}\n{\"type\":\"agent_message\",\"message\":\"迟到回复\"}"))
        _ = await task.value
        check(transport.calls("memory_ingest").isEmpty, "late success after cancel never ingests")
        let stale = service.confirmDeliveredTurn(
            requestID: UUID(), userText: "你好", reply: "迟到回复"
        )
        check(stale == .notCurrent, "confirming an unknown/cancelled requestID writes nothing")
    }

    // 5. scope 切换 + reset：旧 scope 凭据即使 requestID 匹配也不能写。
    do {
        let transport = MemoryTransportStub()
        let memory = ResidentConversationMemory(transport: transport)
        let scopeRunner = CodexRunner(reply: "先答。")
        let service = AgentConversationService(
            locator: StubLocator(installedNames: ["codex"]),
            defaults: makeDefaults(),
            runnerFactory: { _ in scopeRunner }
        )
        service.attachConversationMemory(memory)
        let cabin = makeWorld(id: "cabin")
        _ = try await service.send("世界甲", worldContext: cabin)
        guard let cabinRequestID = service.lastTurnDeliveryRequestID else {
            check(false, "first world registers a delivery credential")
            return
        }
        let room = makeWorld(id: "room")
        _ = try await service.send("世界乙", worldContext: room)
        check(transport.calls("memory_recall").count == 2, "each world turn recalls under its own scope")
        let staleResult = service.confirmDeliveredTurn(
            requestID: cabinRequestID, userText: "世界甲", reply: "先答。"
        )
        check(staleResult == .notCurrent,
              "confirmation from a superseded world/scope is rejected (scope switch)")
        check(transport.calls("memory_ingest").isEmpty, "scope-switched stale confirmation writes nothing")

        guard let ridB = service.lastTurnDeliveryRequestID else {
            check(false, "second world registers a delivery credential")
            return
        }
        memory.reset()
        let afterReset = service.confirmDeliveredTurn(
            requestID: ridB, userText: "世界乙", reply: "先答。"
        )
        check(afterReset == .notCurrent, "confirmation after memory reset is rejected by scope/generation gate")
        check(transport.calls("memory_ingest").isEmpty, "post-reset confirmation writes nothing")
    }

    // 6. 未接线记忆 / 召回失败 / 无 world scope：聊天照常；没有交付凭据。
    do {
        let world = makeWorld()
        // 6a：未接线记忆。
        let noMemoryRunner = CodexRunner(reply: "无记忆回复。")
        let service = AgentConversationService(
            locator: StubLocator(installedNames: ["codex"]),
            defaults: makeDefaults(),
            runnerFactory: { _ in noMemoryRunner }
        )
        let reply = try await service.send("你好", worldContext: world)
        check(reply == "无记忆回复。", "resident chat without memory wiring still works")
        check(service.confirmDeliveredTurn(requestID: UUID(), userText: "你好", reply: reply) == .unavailable,
              "no memory attached -> confirmation reports unavailable")
        check(service.lastTurnDeliveryRequestID == nil, "no delivery credential without memory")

        // 6b：召回失败 → 聊天照常、错误可见。
        let failureTransport = MemoryTransportStub()
        failureTransport.failNextCalls = 1
        let failureMemory = ResidentConversationMemory(transport: failureTransport)
        var recallErrorReported = false
        let failingRunner = CodexRunner(reply: "故障后仍可聊。")
        let failing = AgentConversationService(
            locator: StubLocator(installedNames: ["codex"]),
            defaults: makeDefaults(),
            runnerFactory: { _ in failingRunner }
        )
        failing.attachConversationMemory(failureMemory) { message in
            if message.contains("记忆召回失败") { recallErrorReported = true }
        }
        let failedReply = try await failing.send("召回失败仍可聊", worldContext: world)
        check(failedReply == "故障后仍可聊。", "recall failure never breaks chat")
        check(recallErrorReported, "recall failure is visible through the memory error handler")
        check(failureTransport.calls("memory_recall").count == 1, "failed recall still performed a single attempt")

        // 6c：无 worldContext 的普通聊天（无 scope）不召回、无凭据。
        let plainMemoryTransport = MemoryTransportStub()
        let plainMemory = ResidentConversationMemory(transport: plainMemoryTransport)
        let plainRunner = CodexRunner(reply: "普通聊天。")
        let plain = AgentConversationService(
            locator: StubLocator(installedNames: ["codex"]),
            defaults: makeDefaults(),
            runnerFactory: { _ in plainRunner }
        )
        plain.attachConversationMemory(plainMemory)
        _ = try await plain.send("你好")
        check(plainMemory.activeScope == nil, "plain chat without a world scope never binds memory")
        check(plain.lastTurnDeliveryRequestID == nil, "plain chat registers no delivery credential")
    }

    // 7. 工具会话：真实用户文字来自显式 userMessage；缺省（后台/自驱轮）不召回、
    //    不登记假 user turn。
    do {
        let world = makeWorld(id: "room")
        let tools = ResidentConversationTools(
            worldID: "room",
            schemasJSON: Data("[]".utf8),
            call: { _, _, _ in ResidentCodexToolReply(resultJSON: Data("{}".utf8), isError: false) },
            cancel: {}
        )
        let transport = MemoryTransportStub()
        let memory = ResidentConversationMemory(transport: transport)
        let service = AgentConversationService(
            locator: StubLocator(installedNames: ["codex"]),
            defaults: makeDefaults(),
            residentSender: { _, _, _, _ in
                AgentConversationOutcome(reply: "已开始播放。", sessionID: "tools-thread")
            }
        )
        service.attachConversationMemory(memory)
        _ = try await service.send(
            "请放一首爵士乐", worldContext: world, worldTools: tools,
            userMessage: "请放首歌"
        )
        let recalls = transport.calls("memory_recall")
        check(recalls.count == 1, "tool turn with explicit userMessage recalls once")
        check(recalls[0]["query"]?.stringValue == "请放首歌",
              "tool turn recall query is the explicit real user message, not the assembled prompt")

        let bgTransport = MemoryTransportStub()
        let bgMemory = ResidentConversationMemory(transport: bgTransport)
        let background = AgentConversationService(
            locator: StubLocator(installedNames: ["codex"]),
            defaults: makeDefaults(),
            residentSender: { _, _, _, _ in
                AgentConversationOutcome(reply: "自驱完成。", sessionID: "bg-thread")
            }
        )
        background.attachConversationMemory(bgMemory)
        _ = try await background.send(
            "自主检查一下空间", worldContext: world, worldTools: tools
        )
        check(bgTransport.calls("memory_recall").isEmpty,
              "background turn without real user input never recalls/fabricates a query")
        check(background.lastTurnDeliveryRequestID == nil,
              "background turn registers no fake user delivery credential")
    }

    // 8. 合同文本校验：空/超长/控制字符的确认被合理拒绝，不写、聊天已成功不受影响。
    do {
        let transport = MemoryTransportStub()
        let memory = ResidentConversationMemory(transport: transport)
        let contractRunner = CodexRunner(reply: "已收到。")
        let service = AgentConversationService(
            locator: StubLocator(installedNames: ["codex"]),
            defaults: makeDefaults(),
            runnerFactory: { _ in contractRunner }
        )
        service.attachConversationMemory(memory)
        let world = makeWorld()
        let reply = try await service.send("重要的事", worldContext: world)
        guard let rid = service.lastTurnDeliveryRequestID else {
            check(false, "staged delivery credential exists for rejection cases")
            return
        }
        let newlineInReply = service.confirmDeliveredTurn(
            requestID: rid, userText: "重要的事", reply: "第一段\n第二段"
        )
        check(newlineInReply == .rejectedText, "control-character reply is rejected without persisting")
        let longReply = String(repeating: "长", count: 2001)
        let tooLong = service.confirmDeliveredTurn(requestID: rid, userText: "重要的事", reply: longReply)
        check(tooLong == .rejectedText, "over-long reply is rejected without persisting")
        let emptyReply = service.confirmDeliveredTurn(requestID: rid, userText: "重要的事", reply: "  ")
        check(emptyReply == .rejectedText, "blank reply is rejected without persisting")
        check(transport.calls("memory_ingest").isEmpty,
              "rejected confirmations never reach memory_ingest and never persist raw text")
        let retry = service.confirmDeliveredTurn(requestID: rid, userText: "重要的事", reply: reply)
        check(retry == .accepted, "a corrected confirmation with the same requestID can still be accepted")
        await eventually { !transport.calls("memory_ingest").isEmpty }
        check(transport.calls("memory_ingest").count == 1, "accepted corrected confirmation ingests once")

        // 真实用户文字本身含控制字符的回合：登记后确认被合理拒绝。
        let controlTransport = MemoryTransportStub()
        let controlMemory = ResidentConversationMemory(transport: controlTransport)
        let controlRunner = CodexRunner(reply: "收到控制字符输入。")
        let controlService = AgentConversationService(
            locator: StubLocator(installedNames: ["codex"]),
            defaults: makeDefaults(),
            runnerFactory: { _ in controlRunner }
        )
        controlService.attachConversationMemory(controlMemory)
        let controlText = "重要\u{0001}的事"
        _ = try await controlService.send(controlText, worldContext: world)
        guard let controlRequestID = controlService.lastTurnDeliveryRequestID else {
            check(false, "control-character user turn still stages a credential")
            return
        }
        let controlUser = controlService.confirmDeliveredTurn(
            requestID: controlRequestID, userText: controlText, reply: "收到控制字符输入。"
        )
        check(controlUser == .rejectedText, "control-character user text is rejected without persisting")
        check(controlTransport.calls("memory_ingest").isEmpty,
              "control-character user turn never reaches memory_ingest")
    }

    // 9. DSH 请求级记忆背景没有写进进程内历史，但每轮真实历史与请求级上下文并存。
    do {
        let transport = MemoryTransportStub()
        let memory = ResidentConversationMemory(transport: transport)
        let runner = DSHRunner()
        let service = AgentConversationService(
            locator: StubLocator(installedNames: ["dsh"]),
            defaults: makeDefaults(),
            runnerFactory: { _ in runner }
        )
        service.selectBackend(.dsh)
        service.attachConversationMemory(memory)
        let world = makeWorld()
        _ = try await service.send("第一句", worldContext: world)
        _ = try await service.send("第二句", worldContext: world)
        let recallCount = transport.calls("memory_recall").count
        _ = try await service.send("第三句", worldContext: world)
        check(transport.calls("memory_recall").count == recallCount + 1, "third DSH turn recalls once")
        check(runner.prompts[2].contains("用户：第一句"), "third-turn prompt still carries real history")
        check(runner.prompts[2].contains(transport.recallContext), "third-turn prompt carries request-level memory context")
    }

    // 10. DSH 原生 ACP 会话：新会话 freshSession=true（整段恢复只一次）；已有原生
    //     会话的续聊每轮仍真实召回 freshSession=false，上下文进入该次 submit 的
    //     增量 prompt，绝不重复整段恢复历史。
    do {
        let transport = MemoryTransportStub()
        transport.freshRecallContext = "【整段恢复段】这位居民此前相处的完整经历摘要。"
        transport.resumeRecallContext = "【本轮相关】这位居民喜欢在雨天听爵士乐。"
        let memory = ResidentConversationMemory(transport: transport)
        let connector = NativeSessionConnector()
        let service = AgentConversationService(
            locator: StubLocator(installedNames: ["dsh"]),
            defaults: makeDefaults(),
            runnerFactory: { _ in DSHRunner() },
            residentDSHImageConnector: connector
        )
        service.selectBackend(.dsh)
        service.attachConversationMemory(memory)
        let world = makeWorld()
        _ = try await service.send("第一句", worldContext: world)
        var recalls = transport.calls("memory_recall")
        check(recalls.count == 1, "native first turn recalls once")
        check(recalls[0]["query"]?.stringValue == "第一句", "native fresh recall uses real user text")
        check(recalls[0]["freshSession"]?.boolValue == true,
              "native first ACP session -> freshSession=true")
        check(connector.textBlocks.first?.contains("【整段恢复段】") == true,
              "fresh native submit carries the bounded restore segment")
        check(connector.textBlocks.first?.contains("【本轮相关】") == false,
              "fresh native submit does not fabricate a continuation segment")

        _ = try await service.send("第二句", worldContext: world)
        recalls = transport.calls("memory_recall")
        check(recalls.count == 2, "open native ACP session still recalls per turn (no skip)")
        check(recalls[1]["query"]?.stringValue == "第二句", "native continuation recall uses the real query")
        check(recalls[1]["freshSession"]?.boolValue == false,
              "open native ACP session -> freshSession=false")
        let secondBlock = connector.textBlocks.last ?? ""
        check(secondBlock.contains("【本轮相关】"),
              "continuation memory context enters this submit's incremental prompt")
        check(!secondBlock.contains("【整段恢复段】"),
              "continuation does not repeat the full-history restore segment")
        check(connector.textBlocks.count == 2, "exactly two native submits for two turns")
        check(transport.calls("memory_ingest").isEmpty, "native turns never ingest at model return")

        guard let rid = service.lastTurnDeliveryRequestID else {
            check(false, "native continuation registers a delivery requestID")
            return
        }
        let delivery = service.confirmDeliveredTurn(
            requestID: rid, userText: "第二句", reply: "原生回复2", source: .voice
        )
        check(delivery == .accepted, "native delivery confirmation after guards is accepted")
        await eventually { !transport.calls("memory_ingest").isEmpty }
        check(transport.calls("memory_ingest").count == 1, "native confirmed turn ingests exactly once")
    }

    // 11. 缺配置（daemon 无 provider）：recall 返回 unconfigured + 空上下文，
    //     聊天照常返回；显示/语音完成后的显式确认仍可入队（accepted 只代表进入
    //     易失缓冲，不冒充长期保存）。
    do {
        let transport = MemoryTransportStub()
        transport.recallContext = ""
        transport.recallStatus = "unconfigured"
        let memory = ResidentConversationMemory(transport: transport)
        let runner = CodexRunner(reply: "缺配置也能聊。")
        let service = AgentConversationService(
            locator: StubLocator(installedNames: ["codex"]),
            defaults: makeDefaults(),
            runnerFactory: { _ in runner }
        )
        service.attachConversationMemory(memory)
        let world = makeWorld()
        let reply = try await service.send("在吗", worldContext: world)
        check(reply == "缺配置也能聊。", "unconfigured memory recall still lets chat continue")
        check(transport.calls("memory_recall").count == 1, "unconfigured turn still recalls once")
        guard let rid = service.lastTurnDeliveryRequestID else {
            check(false, "unconfigured memory still registers a delivery credential")
            return
        }
        check(service.confirmDeliveredTurn(requestID: rid, userText: "在吗", reply: reply) == .accepted,
              "unconfigured memory accepts a confirmed delivery into the volatile buffer")
        await eventually { !transport.calls("memory_ingest").isEmpty }
        check(transport.calls("memory_ingest").count == 1,
              "unconfigured memory ingests the confirmed delivered turn once")
    }

    print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) agent-conversation memory service checks, \(failures) failures")
    exit(failures == 0 ? 0 : 1)
}

@main struct Tests {
    @MainActor static func main() async {
        do {
            try await run()
        } catch {
            failures += 1; checks += 1
            print("FAIL: unexpected error: \(error)")
            print("FAIL: \(checks) agent-conversation memory service checks, \(failures) failures")
            exit(1)
        }
    }
}
"""#

let main = work.appendingPathComponent("Main.swift")
try harness.write(to: main, atomically: true, encoding: .utf8)
let binary = work.appendingPathComponent("test")
let compile = Process()
compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compile.arguments = ["-swift-version", "6", "-j1", "-parse-as-library"] + [
    "CodexCLI", "AgentConversationService", "ResidentCodexTransport",
    "ResidentCodexPolicy", "ResidentCodexAgent", "ResidentSteeringDelivery",
    "ResidentDSHTransport", "ResidentDSHConfiguration", "ResidentStateClient",
    "ResidentMemoryClient", "ResidentConversationMemory",
    "ResidentDSHAgentToolBridge", "ResidentDSHHostToolsBridge",
    "ResidentClaudeToolBridge", "ResidentClaudeProcessRunner",
].map {
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/\($0).swift").path
} + [
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/ResidentVisionCapture.swift").path,
    main.path, "-o", binary.path,
]
try compile.run()
compile.waitUntilExit()
guard compile.terminationStatus == 0 else { exit(compile.terminationStatus) }
let test = Process()
test.executableURL = binary
try test.run()
test.waitUntilExit()
exit(test.terminationStatus)

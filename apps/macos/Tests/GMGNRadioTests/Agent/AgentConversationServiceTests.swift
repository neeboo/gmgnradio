import Foundation
import Testing
@testable import GMGNRadio

@MainActor
@Test
func worldTurnsRequireRealRustBindingsEvenWhenLegacyModeIsRequested() async throws {
    let recorded = RecordedCalls()
    for backend in AgentConversationBackendID.allCases {
        let executable = AgentConversationBackends.backend(for: backend).executableNames.first!
        let service = fixtureConversationService(locator: StubLocator(installedNames: [executable]),
            defaults: makeDefaults(), residentSender: { _, _, _, _ in
                recorded.append("legacy-resident-sender")
                return .init(reply: "must not execute", sessionID: nil)
            })
        service.selectBackend(backend)
        service.setRustResidentMode(false)
        let tools = ResidentConversationTools(worldID: "room", schemasJSON: Data("[]".utf8),
            call: { _, _, _ in recorded.append("unclaimed-tool"); return .init(resultJSON: Data("{}".utf8), isError: false) }, cancel: {})
        do {
            _ = try await service.send("hello", worldContext: makeResidentWorld(id: "room"), worldTools: tools)
            Issue.record("Unclaimed world turn was admitted: \(backend.rawValue)")
        } catch AgentConversationError.worldToolsUnavailable { }
    }
    #expect(recorded.names.isEmpty)
}


 // MARK: - Private Rust consumer fixtures (no default endpoint or CLI execution)
private final class ConversationRustRPC: @unchecked Sendable {
    private let lock = NSLock()
    var reply = "好的"; var session = "fixture-session"
    var failing = false; var blocked = false
    private var cancelled = false
    private var turns: [[String: Any]] = []
    private var histories: [String: Int] = [:]
    private var sessions: [String: String] = [:]
    func call(_ method: String, _ data: Data) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let p = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        guard p["worldID"] == nil, p["runID"] == nil, p["hostSessionID"] is String else { throw RustChatClient.ClientError.invalidProtocol }
        let key = (p["backend"] as! String) + "|" + (p["scopeID"] as! String)
        switch method {
        case "agent_chat_import":
            if let old = p["sessionID"] as? String, sessions[key] == nil { sessions[key] = old }
            return Data("{\"imported\":true}".utf8)
        case "agent_chat_reset": histories[key] = 0; sessions[key] = nil; return Data("{\"reset\":true}".utf8)
        case "agent_chat_start":
            turns.append(p); cancelled = false
            return try JSONSerialization.data(withJSONObject: ["state":"running","requestID":p["requestID"]!])
        case "agent_chat_cancel": cancelled = true; return Data("{}".utf8)
        case "agent_chat_read":
            let count = histories[key] ?? 0
            if p["requestID"] == nil {
                return try JSONSerialization.data(withJSONObject: ["freshSession": count == 0 && sessions[key] == nil,"historyCount":count,"sessionID":sessions[key] as Any? ?? NSNull()])
            }
            if failing { return Data("{\"state\":\"failed\",\"reply\":\"\"}".utf8) }
            if !blocked && !cancelled { histories[key] = min(6,count+2); sessions[key] = session }
            return try JSONSerialization.data(withJSONObject: ["state":cancelled ? "cancelled":blocked ? "running":"completed","reply": cancelled || blocked ? "" : reply,"sessionID":sessions[key] as Any? ?? NSNull()])
        default: throw RustChatClient.ClientError.invalidProtocol
        }
    }
    func setBlocked(_ value: Bool) { lock.lock(); blocked = value; lock.unlock() }
    func starts() -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return turns }
    func continuity(_ backend: String, _ scope: String) -> (String?,Int) { lock.lock(); defer { lock.unlock() }; let key=backend+"|"+scope;return(sessions[key],histories[key] ?? 0) }
}
private final class ConversationSettingsRPC: @unchecked Sendable {
    private let lock = NSLock(); private var revision = 1
    private var values: [String: Any] = [
        "locale":"zh-CN","residentPersona":"fixture","backgroundTurnsPerHour":6,
        "autoSpeak":false,"autonomyEnabled":true,"agentBackend":"",
        "selectedWorldID":NSNull(),"defaultSpace":"living-pod","djHostPrompt":"","djTakeover":true,"djPlanningModel":NSNull(),
        "ttsProvider":"bailian","ttsModel":"fixture","ttsVoice":"Cherry","asrProvider":"bailian","asrModel":"fixture","microphoneDeviceID":NSNull(),
        "orbRed":0.16,"orbGreen":0.62,"orbBlue":1.0,"orbFlowIntensity":0.82,
        "remoteMotionCatalogURL":"https://fixture.invalid/catalog.json","shortcutAssignments":[],
        "globalShortcutsEnabled":true,"mediaKeysEnabled":true,"musicConnectedProviders":[String](),
        "avatarPositions":[String:[Double]](),"stagePointCloudChoice":"automatic","stageParticleSizeMultiplier":1.0,"stageLegacyImported":false,
        "stageLyricsMode":"automatic","stageLyricsResolvedMode":"luminous","stageLyricsTrackID":NSNull(),"stageLyricsLegacyImported":false
    ]
    func call(_ method: String,_ data: Data) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let p=try JSONSerialization.jsonObject(with:data) as! [String:Any]
        switch method {
        case "product_settings_import","product_settings_read": break
        case "product_settings_apply":
            guard let changes=p["changes"] as? [String:Any] else {throw RustProductSettingsClient.SettingsError.invalidProtocol}
            values.merge(changes){_,new in new};revision += 1
        default: throw RustProductSettingsClient.SettingsError.invalidProtocol
        }
        return try JSONSerialization.data(withJSONObject:["revision":revision,"imported":true,"values":values])
    }
}
@MainActor private var conversationRPCs: [ObjectIdentifier: ConversationRustRPC] = [:]
@MainActor private var conversationSettings: [ObjectIdentifier: RustProductSettingsClient] = [:]
@MainActor private var conversationDefaults: [ObjectIdentifier: UserDefaults] = [:]
@MainActor private func fixtureConversationService(
    locator: any AgentExecutableLocating = StubLocator(installedNames: ["codex"]),
    defaults: UserDefaults = makeDefaults(),
    runnerFactory: (@Sendable (URL) -> any CodexCommandRunning)? = nil,
    residentSender: AgentConversationService.ResidentSender? = nil,
    claudeRunnerFactory: AgentConversationService.ClaudeRunnerFactory? = nil,
    claudeEnvironmentProvider: @escaping AgentConversationService.ClaudeEnvironmentProvider = { _ in nil },
    rpc: ConversationRustRPC = ConversationRustRPC()
) -> AgentConversationService {
    let key=ObjectIdentifier(defaults)
    conversationDefaults[key] = defaults // Keep suite identity alive; never alias a later test by recycled object address.
    let settings: RustProductSettingsClient
    if let existing=conversationSettings[key] {settings=existing}
    else {let transport=ConversationSettingsRPC();settings=RustProductSettingsClient(call:transport.call);conversationSettings[key]=settings}
    let service=AgentConversationService(locator:locator,defaults:defaults,runnerFactory:runnerFactory,
        residentSender:residentSender,claudeRunnerFactory:claudeRunnerFactory,
        claudeEnvironmentProvider:claudeEnvironmentProvider,rustChatClient:RustChatClient(call:rpc.call),
        productSettings:settings,rustChatRoot:URL(fileURLWithPath:"/private/tmp/gmgn-unit-chat-never-staged"),
        plainChatEnvironment:{["GMGN_DSH_ACP_ENTRY":"/dev/null"]})
    conversationRPCs[ObjectIdentifier(service)]=rpc;return service
}
@MainActor private func conversationRPC(_ service: AgentConversationService) -> ConversationRustRPC {
    conversationRPCs[ObjectIdentifier(service)]!
}
@MainActor private func selectConfirmed(_ backend: AgentConversationBackendID, _ service: AgentConversationService) async throws {
    try await service.preferenceStore.settings.ensureLoaded()
    _ = try await service.preferenceStore.settings.apply(["agentBackend":backend.rawValue])
    service.selectBackend(backend)
}

// MARK: - Test doubles

private struct StubLocator: AgentExecutableLocating {
    let installedNames: Set<String>

    func locate(executableNames: [String]) -> URL? {
        if executableNames == ["node"] { return URL(fileURLWithPath: "/usr/bin/true") }
        guard
            let name = executableNames.first(
                where: { installedNames.contains($0) }
            )
        else {
            return nil
        }
        return URL(filePath: "/usr/local/bin/\(name)")
    }
}

private final class RecordedCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var names: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ name: String) {
        lock.lock()
        storage.append(name)
        lock.unlock()
    }
}

/// 按可执行文件名分发固定输出并记录调用的测试 runner，
/// 验证 runnerFactory 注入对所有后端生效。
private final class DispatchedRunner: CodexCommandRunning,
    @unchecked Sendable
{
    private let executableName: String
    private let outputs: [String: String]
    private let recorded: RecordedCalls

    init(
        executableName: String,
        outputs: [String: String],
        recorded: RecordedCalls
    ) {
        self.executableName = executableName
        self.outputs = outputs
        self.recorded = recorded
    }

    func run(
        arguments: [String],
        standardInput: String?
    ) async throws -> CodexCommandResult {
        recorded.append(executableName)
        return CodexCommandResult(
            exitCode: 0,
            output: outputs[executableName] ?? ""
        )
    }
}

/// 记录最后一次 prompt（DSH 场景）的测试 runner。
private final class PromptCaptureRunner: CodexCommandRunning,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storage: [String] = []

    var prompts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    private func record(_ prompt: String) {
        lock.lock()
        storage.append(prompt)
        lock.unlock()
    }

    func run(
        arguments: [String],
        standardInput: String?
    ) async throws -> CodexCommandResult {
        record(arguments.last ?? "")
        return CodexCommandResult(exitCode: 0, output: "好的")
    }
}

private func makeDefaults() -> UserDefaults {
    let name = "AgentConversationServiceTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private func jsonResultOutput(
    result: String,
    sessionID: String?
) -> String {
    var object: [String: Any] = ["result": result]
    if let sessionID {
        object["session_id"] = sessionID
    }
    let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    return String(decoding: data, as: UTF8.self)
}

private func isUUID(_ value: String) -> Bool {
    UUID(uuidString: value) != nil
}

// MARK: - Registry & installation

@Test
func conversationBackendRegistryCoversAllSixBackends() {
    let ids = AgentConversationBackends.all.map(\.kind)
    #expect(ids.count == 6)
    #expect(Set(ids) == Set(AgentConversationBackendID.allCases))
    #expect(
        AgentConversationBackends.all.allSatisfy { !$0.displayName.isEmpty }
    )
    #expect(
        AgentConversationBackends.all.allSatisfy { !$0.executableNames.isEmpty }
    )
    // 唯一性
    #expect(Set(ids).count == ids.count)
    // DSH 与 Claude Code 无原生续聊（各自由服务维护有界历史）；其余支持原生续聊。
    for backend in AgentConversationBackends.all {
        #expect(
            backend.supportsNativeContinuation
                == (backend.kind != .dsh && backend.kind != .claudeCode)
        )
    }
}

@Test
func preferredOrderPutsCodexFirst() {
    #expect(AgentConversationBackends.preferredOrder.first == .codex)
}

@Test
func workbuddyProbesCodebuddyFirst() {
    let backend = AgentConversationBackends.backend(for: .workbuddy)
    #expect(backend.executableNames.first == "codebuddy")
    #expect(backend.executableNames.contains("workbuddy"))
}

@MainActor
@Test
func installedBackendsReflectLocatorResults() {
    let service = fixtureConversationService(
        locator: StubLocator(installedNames: ["codex", "qoder"]),
        defaults: makeDefaults()
    )
    let installed = service.installedBackends().map(\.kind)
    #expect(installed.contains(.codex))
    #expect(installed.contains(.qoder))
    #expect(!installed.contains(.claudeCode))
    #expect(!installed.contains(.dsh))
    #expect(!installed.contains(.workbuddy))
    #expect(!installed.contains(.pi))
}

// MARK: - Selection persistence

@MainActor
@Test
func defaultBackendPrefersFirstInstalledBackend() {
    let service = fixtureConversationService(
        locator: StubLocator(installedNames: ["dsh", "qoder"]),
        defaults: makeDefaults()
    )
    #expect(service.defaultBackendID() == .dsh)
    #expect(service.effectiveBackendID == .dsh)
}

@MainActor
@Test
func selectedBackendPersistsAcrossServiceInstances() async throws {
    let defaults = makeDefaults()
    let first = fixtureConversationService(
        locator: StubLocator(installedNames: ["codex", "claude"]),
        defaults: defaults
    )
    try await selectConfirmed(.claudeCode, first)

    let second = fixtureConversationService(
        locator: StubLocator(installedNames: ["codex", "claude"]),
        defaults: defaults
    )
    #expect(second.effectiveBackendID == .claudeCode)
}

@MainActor
@Test
func defaultBackendFallsBackToCodexWhenNothingInstalled() {
    let service = fixtureConversationService(
        locator: StubLocator(installedNames: []),
        defaults: makeDefaults()
    )
    #expect(service.defaultBackendID() == .codex)
}

// MARK: - Routing without realtime voice

@MainActor
@Test
func sendRoutesTextWithoutRealtimeVoiceConnection() async throws {
    RealtimeVoiceStatusStore.shared.state = .disconnected
    defer { RealtimeVoiceStatusStore.shared.state = .disconnected }
    let rpc=ConversationRustRPC();rpc.reply="晚上好，欢迎回来。"
    let service=fixtureConversationService(rpc:rpc)
    #expect(try await service.send("你好") == rpc.reply)
    #expect(rpc.starts().count == 1)
    #expect(rpc.starts()[0]["backend"] as? String == "codex")
    #expect(rpc.starts()[0]["worldID"] == nil, "ordinary chat never fabricates a world claim")
}

// MARK: - runnerFactory injection for all six backends

@MainActor
@Test
func runnerFactoryIsUsedForEveryBackend() async throws {
    let recorded=RecordedCalls(),rpc=ConversationRustRPC()
    let service=fixtureConversationService(locator:StubLocator(installedNames:["codex","dsh","claude","codebuddy","qoder","pi"]),
        runnerFactory:{ url in recorded.append(url.lastPathComponent);return DispatchedRunner(executableName:url.lastPathComponent,outputs:[:],recorded:recorded) },
        claudeRunnerFactory:{ url,_,_,_ in recorded.append(url.lastPathComponent);return DispatchedRunner(executableName:url.lastPathComponent,outputs:[:],recorded:recorded) },rpc:rpc)
    for backend in AgentConversationBackendID.allCases {
        try await selectConfirmed(backend,service);rpc.reply=backend.rawValue+" 回复"
        #expect(try await service.send("你好") == rpc.reply)
        #expect(rpc.starts().last?["backend"] as? String == backend.rawValue)
        #expect(service.lastSpeechSource["kind"] as? String == "chat")
        for field in ["backend","scopeID","hostSessionID","requestID"] {
            #expect(service.lastSpeechSource[field] as? String == rpc.starts().last?[field] as? String)
        }
    }
    #expect(rpc.starts().count == 6)
    #expect(recorded.names.isEmpty, "retired Swift runners never execute; all six use actual Rust typed consumer")
}

// MARK: - JSON-result CLI arguments (WorkBuddy / Qoder / Claude Code)

@Test
func workbuddyArgumentsUseResumeContinuation() {
    let first = AgentConversationService.jsonResultCLIArguments(
        kind: .workbuddy,
        text: "第一轮",
        sessionID: nil,
        isResume: false
    )
    #expect(first == ["-p", "第一轮", "--output-format", "json"])

    let resume = AgentConversationService.jsonResultCLIArguments(
        kind: .workbuddy,
        text: "第二轮",
        sessionID: "wb-session-1",
        isResume: true
    )
    #expect(
        resume
            == [
                "-p", "--resume", "wb-session-1", "第二轮",
                "--output-format", "json",
            ]
    )
}

@Test
func qoderArgumentsUseGeneratedSessionIDThenResume() {
    let first = AgentConversationService.jsonResultCLIArguments(
        kind: .qoder,
        text: "你好",
        sessionID: nil,
        isResume: false
    )
    #expect(first.count == 6)
    #expect(first.dropFirst(4).first == "--session-id")
    #expect(isUUID(first.last ?? ""))

    let resume = AgentConversationService.jsonResultCLIArguments(
        kind: .qoder,
        text: "继续",
        sessionID: "qoder-9",
        isResume: true
    )
    #expect(
        resume
            == ["-p", "继续", "--output-format", "json", "--resume", "qoder-9"]
    )
}

/// Claude Code 已从通用 JSON CLI 协议迁出：通用协议不再返回任何 Claude 参数，
/// 专用分支由 `claudeArguments` 生成固定安全前缀（无 WebSearch/WebFetch，无
/// resume/session-id，无内建工具）。
@Test
func claudeCodeIsRemovedFromGenericJSONCLIProtocol() {
    #expect(
        AgentConversationService.jsonResultCLIArguments(
            kind: .claudeCode,
            text: "你好",
            sessionID: nil,
            isResume: false
        ).isEmpty
    )
    #expect(
        AgentConversationService.jsonResultCLIArguments(
            kind: .claudeCode,
            text: "继续",
            sessionID: "claude-7",
            isResume: true
        ).isEmpty
    )
}

@Test
func claudeCodeArgumentsUseOnlyTheRestrictedMCPPrefix() {
    let path = "/private/tmp/gmgn-claude-test/config.json"
    let chat = AgentConversationService.claudeArguments(
        mcpConfigPath: path,
        allowedToolNames: []
    )
    #expect(chat.first == "--bare")
    #expect(chat.contains("--print"))
    #expect(Array(chat[chat.firstIndex(of: "--output-format")!...].prefix(2)) == ["--output-format", "json"])
    #expect(chat.contains("--no-session-persistence"))
    #expect(chat[chat.firstIndex(of: "--tools")! + 1] == "")
    #expect(chat.contains("--strict-mcp-config"))
    #expect(chat.contains("--disable-slash-commands"))
    #expect(chat[chat.firstIndex(of: "--setting-sources")! + 1] == "")
    #expect(chat[chat.firstIndex(of: "--settings")! + 1] == "{\"disableAllHooks\":true}")
    #expect(chat[chat.firstIndex(of: "--permission-mode")! + 1] == "dontAsk")
    #expect(chat[chat.firstIndex(of: "--mcp-config")! + 1] == path)
    #expect(!chat.contains("--allowedTools"))
    #expect(!chat.contains("--resume"))
    #expect(!chat.contains("--session-id"))
    #expect(!chat.contains(where: { $0.contains("WebSearch") || $0.contains("WebFetch") }))

    let tools = AgentConversationService.claudeArguments(
        mcpConfigPath: path,
        allowedToolNames: ["mcp__gmgn-resident-tools__gmgn_read_wish_generation"]
    )
    let allowedIndex = tools.firstIndex(of: "--allowedTools")!
    #expect(Array(tools[(allowedIndex + 1)...]) == ["mcp__gmgn-resident-tools__gmgn_read_wish_generation"])
    #expect(!tools.contains("mcp__gmgn-resident-tools"))
    #expect(!tools.contains(where: { $0.contains("WebSearch") || $0.contains("WebFetch") }))
    #expect(!tools.contains("--dangerously-skip-permissions"))
}

@MainActor
@Test
func claudeCodeUsesDedicatedRunnerSeamAndNeverResumes() async throws {
    let rpc=ConversationRustRPC();rpc.reply="claude 回复"
    let recorded=RecordedCalls()
    let service=fixtureConversationService(locator:StubLocator(installedNames:["claude"]),
        claudeRunnerFactory:{ _,_,_,_ in recorded.append("retired");return DispatchedRunner(executableName:"claude",outputs:[:],recorded:recorded) },rpc:rpc)
    try await selectConfirmed(.claudeCode,service)
    #expect(service.supportsWorldTools)
    #expect(try await service.send("你好") == "claude 回复")
    #expect(try await service.send("继续") == "claude 回复")
    #expect(recorded.names.isEmpty)
    #expect(service.preferenceStore.sessionID(for:.claudeCode,scope:nil) == nil, "host preferences never become session authority")
    #expect(rpc.starts().count == 2)
}

@MainActor
@Test
func claudeCodeMissingCredentialFailsBeforeSpawn() async {
    let recorded=RecordedCalls(),rpc=ConversationRustRPC();rpc.failing=true
    let service=fixtureConversationService(locator:StubLocator(installedNames:["claude"]),
        claudeRunnerFactory:{ _,_,_,_ in recorded.append("retired");return DispatchedRunner(executableName:"claude",outputs:[:],recorded:recorded) },rpc:rpc)
    do {try await selectConfirmed(.claudeCode,service);_=try await service.send("你好");Issue.record("Rust failed terminal was promoted")}
    catch { }
    #expect(recorded.names.isEmpty)
    #expect(rpc.continuity("claudeCode","chat").0 == nil, "failed native turn commits no session")
}

@MainActor
@Test
func workbuddySessionResumesAcrossTurns() async throws {
    let rpc=ConversationRustRPC();rpc.reply="第一答";rpc.session="wb-session-1"
    let service=fixtureConversationService(locator:StubLocator(installedNames:["codex","codebuddy","qoder","pi"]),rpc:rpc)
    try await selectConfirmed(.workbuddy,service)
    #expect(try await service.send("第一轮") == "第一答")
    #expect(try await service.send("继续") == "第一答")
    #expect(rpc.continuity("workbuddy","chat").0 == "wb-session-1")
    #expect(rpc.continuity("workbuddy","chat").1 == 4)
    #expect(service.preferenceStore.sessionID(for:.workbuddy) == nil, "Rust continuity does not create a second defaults writer")
}

@MainActor
@Test
func qoderStoresReportedSessionID() async throws {
    let rpc=ConversationRustRPC();rpc.reply="qoder 答";rpc.session="qoder-77"
    let service=fixtureConversationService(locator:StubLocator(installedNames:["codex","codebuddy","qoder","pi"]),rpc:rpc)
    try await selectConfirmed(.qoder,service)
    #expect(try await service.send("第一轮") == "qoder 答")
    #expect(try await service.send("继续") == "qoder 答")
    #expect(rpc.continuity("qoder","chat").0 == "qoder-77")
    #expect(rpc.continuity("qoder","chat").1 == 4)
    #expect(service.preferenceStore.sessionID(for:.qoder) == nil, "Rust continuity does not create a second defaults writer")
}

// MARK: - Pi protocol

@Test
func piArgumentsUseModeJSONAndSessionResume() {
    let first = AgentConversationService.piCLIArguments(
        text: "你好",
        sessionID: nil
    )
    #expect(first == ["--mode", "json", "-p", "你好"])

    let resume = AgentConversationService.piCLIArguments(
        text: "继续",
        sessionID: "pi-3"
    )
    #expect(resume == ["--mode", "json", "-p", "继续", "--session", "pi-3"])
}

@Test
func parsePiEventsReadsSessionIDAndFinalStringContent() {
    let output = """
        {"type":"session","id":"pi-42"}
        {"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"你"}}
        {"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"好"}}
        {"type":"message_end","message":{"content":"最终答案"}}
        """
    let parsed = AgentConversationService.parsePiEvents(output)
    #expect(parsed.sessionID == "pi-42")
    #expect(parsed.reply == "最终答案")
}

@Test
func parsePiEventsHandlesArrayContentAndDeltasOnly() {
    let arrayOutput = """
        {"type":"session","id":"pi-1"}
        {"type":"turn_end","message":{"content":[{"type":"text","text":"第一段"},{"text":"第二段"}]}}
        """
    let arrayParsed = AgentConversationService.parsePiEvents(arrayOutput)
    #expect(arrayParsed.sessionID == "pi-1")
    #expect(arrayParsed.reply == "第一段第二段")

    let deltaOnly = """
        {"type":"session","id":"pi-2"}
        {"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"增量"}}
        """
    let deltaParsed = AgentConversationService.parsePiEvents(deltaOnly)
    #expect(deltaParsed.reply == "增量")

    // 兼容旧顶层 text_delta 字段。
    let legacyDelta = """
        {"type":"session","id":"pi-3"}
        {"type":"message_update","text_delta":"旧增量"}
        """
    let legacyParsed = AgentConversationService.parsePiEvents(legacyDelta)
    #expect(legacyParsed.reply == "旧增量")
}

@MainActor
@Test
func piSessionIDIsStoredForResume() async throws {
    let rpc=ConversationRustRPC();rpc.reply="pi 答";rpc.session="pi-42"
    let service=fixtureConversationService(locator:StubLocator(installedNames:["codex","codebuddy","qoder","pi"]),rpc:rpc)
    try await selectConfirmed(.pi,service)
    #expect(try await service.send("第一轮") == "pi 答")
    #expect(try await service.send("继续") == "pi 答")
    #expect(rpc.continuity("pi","chat").0 == "pi-42")
    #expect(rpc.continuity("pi","chat").1 == 4)
    #expect(service.preferenceStore.sessionID(for:.pi) == nil, "Rust continuity does not create a second defaults writer")
}

// MARK: - DSH history

@Test
func dshPromptEmbedsLimitedHistory() {
    let history = [
        AgentConversationMessage(role: .user, text: "第一轮"),
        AgentConversationMessage(role: .agent, text: "第一答"),
        AgentConversationMessage(role: .user, text: "第二轮"),
        AgentConversationMessage(role: .agent, text: "第二答"),
    ]
    let prompt = AgentConversationService.dshPrompt(
        text: "第三轮",
        history: history
    )
    #expect(prompt.contains("用户：第一轮"))
    #expect(prompt.contains("助手：第二答"))
    #expect(prompt.hasSuffix("用户：第三轮"))
}

@MainActor
@Test
func dshAccumulatesHistoryAcrossTurnsAndClearsOnBackendSwitch()
async throws {
    let rpc=ConversationRustRPC(),service=fixtureConversationService(locator:StubLocator(installedNames:["dsh","codex"]),rpc:rpc)
    try await selectConfirmed(.dsh,service)
    _=try await service.send("第一轮");_=try await service.send("第二轮")
    #expect(rpc.starts().count == 2)
    #expect(rpc.continuity("dsh","chat").1 == 4, "confirmed Rust history continues within backend/scope")
    #expect(rpc.starts().allSatisfy{$0["dshEntryPoint"] as? String == "/dev/null"})
    try await selectConfirmed(.dsh,service)
    _=try await service.send("第三轮")
    #expect(rpc.continuity("dsh","chat").1 == 6, "same backend does not cancel/reset active continuity")
    try await selectConfirmed(.codex,service);_=try await service.send("独立后端")
    #expect(rpc.continuity("codex","chat").1 == 2)
    #expect(rpc.continuity("dsh","chat").1 == 6, "backend identities retain isolated Rust sessions")
}

// MARK: - Codex parsing

@Test
func parseCodexEventsExtractsThreadIDAndFinalAgentMessage() {
    let output = """
        {"type":"thread.started","thread_id":"thread-abc"}
        {"type":"agent_message","message":"第一段"}
        {"type":"item.completed","item":{"type":"agent_message","text":"最终回复"}}
        """
    let parsed = AgentConversationService.parseCodexEvents(output)
    #expect(parsed.threadID == "thread-abc")
    #expect(parsed.reply == "最终回复")
}

@Test
func parseJSONResultOutputExtractsReplyAndSessionID() {
    let output = jsonResultOutput(result: "你好", sessionID: "sid-1")
    let parsed = AgentConversationService.parseJSONResultOutput(output)
    #expect(parsed.reply == "你好")
    #expect(parsed.sessionID == "sid-1")
}

// MARK: - Errors

@MainActor
@Test
func sendFailsClearlyWhenBackendNotInstalled() async {
    let service = fixtureConversationService(
        locator: StubLocator(installedNames: []),
        defaults: makeDefaults()
    )
    await #expect(throws: AgentConversationError.self) {
        _ = try await service.send("你好")
    }
    let error = AgentConversationError.backendNotInstalled(.codex)
    #expect(error.errorDescription?.contains("还没安装") == true, "missing backend carries the current visible installation diagnostic")
}

// MARK: - 居民记忆服务测试支撑（VoiceMem 编排 fixture）

/// 记录每次 codex 调用携带的 prompt 并回放固定会话输出的测试 runner。
private final class RecordingCodexRunner: CodexCommandRunning,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storage: [String] = []
    let replyText: String

    init(replyText: String = "房间回复") { self.replyText = replyText }

    var prompts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    private func record(_ prompt: String) {
        lock.lock()
        storage.append(prompt)
        lock.unlock()
    }

    func run(
        arguments: [String],
        standardInput: String?
    ) async throws -> CodexCommandResult {
        record(arguments.last ?? "")
        return CodexCommandResult(exitCode: 0, output: """
            {"type":"thread.started","thread_id":"thread-session-1"}
            {"type":"agent_message","message":"\(replyText)"}
            """)
    }
}

/// 挂起直到测试显式 resume 的 runner（取消路径用）。
private final class SuspendableRunner: CodexCommandRunning,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var pending: CheckedContinuation<CodexCommandResult, Error>?
    private var started = false

    var didStart: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    func run(
        arguments: [String],
        standardInput: String?
    ) async throws -> CodexCommandResult {
        markStarted()
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if Task.isCancelled {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            pending = continuation
            lock.unlock()
        }
    }

    private func markStarted() {
        lock.lock()
        started = true
        lock.unlock()
    }

    func resume(_ result: CodexCommandResult) {
        lock.lock()
        pending?.resume(returning: result)
        pending = nil
        lock.unlock()
    }
}


/// 记录 resident sender 收到的 prompt/session 的测试容器。
@MainActor
private final class ResidentSenderRecorder {
    var prompts: [String] = []
    var sessions: [String?] = []
}

private func makeResidentWorld(id: String = "cabin") -> ResidentWorldContext {
    ResidentWorldContext(
        selectedWorldID: id, worldID: id, displayName: nil, revision: 1,
        residentPosition: nil, activeActivity: nil, activityPhase: nil,
        objects: [], availableActivities: []
    )
}

@MainActor
private func eventually(_ condition: @MainActor () async -> Bool) async {
    let deadline = Date().addingTimeInterval(8)
    while !(await condition()) {
        if Date() >= deadline { break }
        try? await Task.sleep(for: .milliseconds(5))
    }
}


// MARK: - VoiceMem 记忆接线（ResidentConversationMemory fixture）

/// 只读记忆 IPC fixture：记录实际 memory_recall，禁止退役原文写入。
/// 只做内存模拟，不启动 daemon、不落库（替代旧的 conversation 域 store stub）。
@MainActor
private final class ConversationMemoryStubTransport: ResidentStateTransport {
    private(set) var recorded: [(method: String, params: [String: ResidentStateJSON])] = []
    var recallContext = "这位居民喜欢在雨天听爵士乐。"
    /// 注入连续 N 次调用失败（daemon 故障）。
    var failNextCalls = 0
    var blockNext = false
    var pending: CheckedContinuation<Void, Never>?

    func call(
        method: String,
        params: [String: ResidentStateJSON]
    ) async throws -> [String: ResidentStateJSON] {
        recorded.append((method, params))
        if blockNext {
            blockNext = false
            await withCheckedContinuation { pending = $0 }
        }
        if failNextCalls > 0 {
            failNextCalls -= 1
            throw ResidentStateError.daemon("memory_storage_failed")
        }
        switch method {
        case "memory_recall":
            return [
                "status": .string("ok"), "revision": .number(0),
                "vectorGeneration": .number(0), "facts": .array([]),
                "notes": .array([]), "context": .string(recallContext),
                "pendingTurns": .number(0),
            ]
        default:
            throw ResidentStateError.daemon("unsupported_method")
        }
    }

    func calls(_ method: String) -> [[String: ResidentStateJSON]] {
        recorded.filter { $0.method == method }.map(\.params)
    }
}

/// 记录 codex 调用真实 standardInput 的 runner（codex 文字走 standardInput；
/// 旧的 RecordingCodexRunner 记的是 arguments.last，不适合核对 prompt 内容）。
@MainActor
private final class ConversationMemoryCodexRunner: CodexCommandRunning {
    private var storage: [String] = []
    let replyText: String

    init(replyText: String = "房间回复") { self.replyText = replyText }

    var prompts: [String] { storage }

    func run(
        arguments: [String],
        standardInput: String?
    ) async throws -> CodexCommandResult {
        storage.append(standardInput ?? "")
        return CodexCommandResult(exitCode: 0, output: """
            {"type":"thread.started","thread_id":"thread-session-1"}
            {"type":"agent_message","message":"\(replyText)"}
            """)
    }
}

@MainActor
@Test
func freshCodexResidentTurnRecallsRealUserTextAndIngestsOnlyAfterDeliveryConfirmation()
async throws {
    let transport=ConversationMemoryStubTransport(),rpc=ConversationRustRPC();rpc.reply="嗨，欢迎回来。"
    let service=fixtureConversationService(rpc:rpc);service.attachConversationMemory(ResidentConversationMemory(transport:transport))
    let world=makeResidentWorld()
    let reply=try await service.send("你好",worldContext:world)
    #expect(reply == "嗨，欢迎回来。")
    let recalls=transport.calls("memory_recall")
    #expect(recalls.count == 1 && recalls[0]["query"]?.stringValue == "你好")
    #expect(recalls[0]["freshSession"]?.boolValue == true)
    #expect((rpc.starts()[0]["input"] as? String)?.contains(transport.recallContext) == true)
    #expect((rpc.starts()[0]["input"] as? String)?.contains("居民对话记录") == false)
    #expect(transport.recorded.allSatisfy{$0.method == "memory_recall"}, "delivery/completion never writes the retired raw-memory layer")
    #expect(rpc.continuity("codex",world.sessionScope).0 != nil, "only confirmed Rust turn owns continuity")
    #expect(service.preferenceStore.sessionID(for:.codex,scope:world.sessionScope) == nil)
}

@MainActor
@Test
func nativeResumeAndFreshSessionDriveMemoryFreshFlag() async throws {
    let transport=ConversationMemoryStubTransport(),rpc=ConversationRustRPC()
    let service=fixtureConversationService(rpc:rpc);service.attachConversationMemory(ResidentConversationMemory(transport:transport))
    let world=makeResidentWorld()
    _=try await service.send("今天做什么",worldContext:world)
    _=try await service.send("继续",worldContext:world)
    let recalls=transport.calls("memory_recall")
    #expect(recalls.count == 2)
    #expect(recalls[0]["query"]?.stringValue == "今天做什么" && recalls[0]["freshSession"]?.boolValue == true)
    #expect(recalls[1]["query"]?.stringValue == "继续" && recalls[1]["freshSession"]?.boolValue == false)
    #expect(rpc.continuity("codex",world.sessionScope).1 == 4)
    service.resetSession()
    _=try await service.send("重置后",worldContext:world)
    #expect(transport.calls("memory_recall").last?["freshSession"]?.boolValue == true, "reset re-reads confirmed Rust continuity")
    let legacyDefaults = makeDefaults()
    legacyDefaults.set("existing-thread", forKey: "agentConversation.session.codex.\(world.sessionScope)")
    let legacyTransport = ConversationMemoryStubTransport(), legacyRPC = ConversationRustRPC()
    let legacyService = fixtureConversationService(defaults: legacyDefaults, rpc: legacyRPC)
    legacyService.attachConversationMemory(ResidentConversationMemory(transport: legacyTransport))
    _ = try await legacyService.send("旧会话继续", worldContext: world)
    #expect(legacyTransport.calls("memory_recall").first?["freshSession"]?.boolValue == false,
            "explicit one-time legacy native session import informs Rust fresh-session metadata")
    #expect(legacyDefaults.string(forKey: "agentConversation.session.codex.\(world.sessionScope)") == "existing-thread",
            "host legacy source remains read-only after Rust completion")
}

@MainActor
@Test
func dshFreshProcessRecallsFreshAndContinuationTurnsRecallNonFresh() async throws {
    let transport=ConversationMemoryStubTransport(),rpc=ConversationRustRPC()
    let service=fixtureConversationService(locator:StubLocator(installedNames:["dsh"]),rpc:rpc)
    try await selectConfirmed(.dsh,service)
    service.attachConversationMemory(ResidentConversationMemory(transport:transport))
    let world=makeResidentWorld()
    _=try await service.send("第一句",worldContext:world);_=try await service.send("第二句",worldContext:world)
    let recalls=transport.calls("memory_recall")
    #expect(recalls.count == 2)
    #expect(recalls[0]["freshSession"]?.boolValue == true && recalls[0]["query"]?.stringValue == "第一句")
    #expect(recalls[1]["freshSession"]?.boolValue == false && recalls[1]["query"]?.stringValue == "第二句")
    #expect(rpc.continuity("dsh",world.sessionScope).1 == 4)
    #expect(transport.recorded.allSatisfy{$0.method == "memory_recall"}, "confirmed native DSH turn does not ingest raw transcripts")
}

@MainActor
@Test
func failedOrCancelledTurnNeverStagesNorIngests() async throws {
    let world=makeResidentWorld(),transport=ConversationMemoryStubTransport(),rpc=ConversationRustRPC()
    rpc.failing=true
    let failing=fixtureConversationService(rpc:rpc);failing.attachConversationMemory(ResidentConversationMemory(transport:transport))
    await #expect(throws:(any Error).self) {_ = try await failing.send("你好",worldContext:world)}
    #expect(rpc.continuity("codex",world.sessionScope).1 == 0)
    #expect(transport.recorded.allSatisfy{$0.method == "memory_recall"})
    let delayed=ConversationRustRPC();delayed.setBlocked(true)
    let cancelledTransport=ConversationMemoryStubTransport(),service=fixtureConversationService(rpc:delayed)
    service.attachConversationMemory(ResidentConversationMemory(transport:cancelledTransport))
    let task=Task {try await service.send("你好",worldContext:world)}
    await eventually{!delayed.starts().isEmpty};service.cancel()
    do {_=try await task.value;Issue.record("cancelled turn completed")}catch {}
    delayed.setBlocked(false)
    #expect(delayed.continuity("codex",world.sessionScope).1 == 0, "cancelled reply never commits Rust history")
    #expect(cancelledTransport.recorded.allSatisfy{$0.method == "memory_recall"}, "cancel/late result never writes raw memory")
}

@MainActor
@Test
func scopeSwitchAndMemoryResetRejectLateConfirmation() async throws {
    let transport=ConversationMemoryStubTransport(),rpc=ConversationRustRPC()
    let service=fixtureConversationService(rpc:rpc);let memory=ResidentConversationMemory(transport:transport);service.attachConversationMemory(memory)
    let cabin=makeResidentWorld(id:"cabin"),room=makeResidentWorld(id:"room")
    _=try await service.send("世界甲",worldContext:cabin);_=try await service.send("世界乙",worldContext:room)
    let recalls=transport.calls("memory_recall")
    #expect(recalls.count == 2)
    #expect(recalls[0]["scope"]?.objectValue?["worldID"]?.stringValue == "cabin")
    #expect(recalls[1]["scope"]?.objectValue?["worldID"]?.stringValue == "room")
    #expect(recalls[1]["freshSession"]?.boolValue == true)
    #expect(rpc.continuity("codex",cabin.sessionScope).1 == 2 && rpc.continuity("codex",room.sessionScope).1 == 2)
    memory.reset();service.resetSession()
    _=try await service.send("重置后",worldContext:room)
    #expect(transport.calls("memory_recall").last?["freshSession"]?.boolValue == true)
    transport.blockNext = true
    let before = rpc.starts().count
    let oldRecall = Task { try await service.send("旧空间延迟召回", worldContext: room) }
    await eventually { transport.pending != nil }
    _ = try await service.send("新空间输入", worldContext: cabin)
    transport.pending?.resume(); transport.pending = nil
    do { _ = try await oldRecall.value; Issue.record("old scope recall dispatched after scope switch") }
    catch is CancellationError { }
    #expect(rpc.starts().count == before + 1, "only current scope may dispatch after delayed recall")
    #expect(transport.recorded.allSatisfy{$0.method == "memory_recall"}, "scope/reset never accepts an obsolete delivery write")
}

@MainActor
@Test
func chatWithoutMemoryWiringOrWorldScopeStillWorks() async throws {
    let world=makeResidentWorld(),rpc=ConversationRustRPC();rpc.reply="无记忆回复。"
    let plain=fixtureConversationService(rpc:rpc)
    #expect(try await plain.send("你好",worldContext:world) == rpc.reply)
    let failureTransport=ConversationMemoryStubTransport();failureTransport.failNextCalls=1
    let failed=fixtureConversationService();var reported:String?
    failed.attachConversationMemory(ResidentConversationMemory(transport:failureTransport)){reported=$0}
    #expect(try await failed.send("召回失败仍可聊",worldContext:world) == "好的")
    #expect(reported?.contains("记忆召回失败") == true)
    let chatTransport=ConversationMemoryStubTransport(),memory=ResidentConversationMemory(transport:chatTransport)
    let chat=fixtureConversationService();chat.attachConversationMemory(memory)
    #expect(try await chat.send("你好") == "好的")
    #expect(memory.activeScope == nil)
    #expect(chatTransport.recorded.isEmpty, "unscoped ordinary chat never fabricates recall identity")
}

@MainActor
@Test
func toolTurnUsesExplicitUserMessageAndBackgroundTurnDoesNotFabricateInput() async throws {
    let world = makeResidentWorld(id: "room")
    let rpcCalls = RecordedCalls()
    func binding(runID: String, reply: String) -> RustResidentToolBinding {
        let identity = RustCodexSessionClient.Identity(worldID: "room", residentScope: world.sessionScope,
            hostSessionID: "fixture-host", runID: runID, eventID: "fixture-event-" + runID)
        return .init(identity: identity, transport: { method, data in
            let params = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            guard params["worldID"] as? String == identity.worldID,
                  params["residentScope"] as? String == identity.residentScope,
                  params["hostSessionID"] as? String == identity.hostSessionID,
                  params["runID"] as? String == identity.runID,
                  params["eventID"] as? String == identity.eventID else { throw RustCodexSessionClient.ClientError.identityMismatch }
            rpcCalls.append(method)
            switch method {
            case "agent_cli_start": return Data("{}".utf8)
            case "agent_cli_read":
                if params["continuity"] as? Bool == true { return Data("{\"threadID\":null,\"freshSession\":true}".utf8) }
                return try JSONSerialization.data(withJSONObject: ["state":"completed", "text":reply, "threadID":"fixture-native-thread-"+runID, "turnID":"fixture-native-turn-"+runID, "pendingTools":[[String:Any]]()])
            default: throw RustCodexSessionClient.ClientError.invalidProtocol
            }
        }, environment: [:], effects: ["read_world_state":"read"], authorize: { _ in "fixture-operation" })
    }
    let tools = ResidentConversationTools(
        worldID: "room",
        schemasJSON: Data(#"[{"name":"read_world_state","description":"read fixture","inputSchema":{"type":"object","properties":{},"additionalProperties":false}}]"#.utf8),
        call: { _, _, _ in
            ResidentCodexToolReply(resultJSON: Data("{}".utf8), isError: false)
        },
        cancel: {}, rustBinding: binding(runID: "human", reply: "已开始播放。")
    )
    // 工具会话 + 显式 userMessage：召回 query 是真实用户文字，不是宿主拼装 prompt。
    let transport = ConversationMemoryStubTransport()
    let memory = ResidentConversationMemory(transport: transport)
    let service = fixtureConversationService(
        locator: StubLocator(installedNames: ["codex"]),
        defaults: makeDefaults()
    )
    service.attachConversationMemory(memory)
    let humanReply = try await service.send(
        "请放一首爵士乐", worldContext: world, worldTools: tools,
        userMessage: "请放首歌"
    )
    #expect(humanReply == "已开始播放。")
    #expect(service.lastSpeechSource["kind"] as? String == "world")
    for field in ["worldID","residentScope","hostSessionID","runID","eventID"] {
        let identity = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tools.rustBinding!.identity)) as! [String: Any]
        #expect(service.lastSpeechSource[field] as? String == identity[field] as? String)
    }
    let recalls = transport.calls("memory_recall")
    #expect(recalls.count == 1, "tool turn with explicit userMessage recalls once")
    #expect(recalls[0]["query"]?.stringValue == "请放首歌",
            "tool turn recall query is the real user message, not the assembled prompt")

    // 后台/自驱轮（无 userMessage）：不虚构输入、不召回、不登记假 user turn。
    let backgroundTransport = ConversationMemoryStubTransport()
    let backgroundMemory = ResidentConversationMemory(transport: backgroundTransport)
    let background = fixtureConversationService(
        locator: StubLocator(installedNames: ["codex"]),
        defaults: makeDefaults()
    )
    background.attachConversationMemory(backgroundMemory)
    var backgroundTools = tools
    backgroundTools.rustBinding = binding(runID: "background", reply: "自驱完成。")
    let backgroundReply = try await background.send(
        "自主检查一下空间", worldContext: world, worldTools: backgroundTools
    )
    #expect(backgroundReply == "自驱完成。")
    #expect(rpcCalls.names.filter { $0 == "agent_cli_start" }.count == 2)
    #expect(rpcCalls.names.filter { $0 == "agent_cli_read" }.count == 4)
    #expect(backgroundTransport.calls("memory_recall").isEmpty,
            "background turn without real user input never recalls/fabricates a query")
    #expect(backgroundTransport.recorded.isEmpty,
            "background turn registers no fabricated user memory operation")
}

@MainActor
@Test
func contractViolatingConfirmationIsRejectedAndChatStaysUsable() async throws {
    let transport=ConversationMemoryStubTransport(),rpc=ConversationRustRPC()
    let service=fixtureConversationService(rpc:rpc);service.attachConversationMemory(ResidentConversationMemory(transport:transport))
    let world=makeResidentWorld()
    // Transcript text is no longer a persistence command. Arbitrary model reply
    // cannot gain host memory-write authority by returning successfully.
    for reply in ["第一段\n第二段",String(repeating:"长",count:2001),"  ","已收到。"] {
        rpc.reply=reply
        #expect(try await service.send("重要的事",worldContext:world) == reply)
        #expect(transport.recorded.allSatisfy{$0.method == "memory_recall"}, "model text never obtains raw-memory write authority")
    }
    rpc.reply="收到控制字符输入。"
    #expect(try await service.send("重要\u{0001}的事",worldContext:world) == rpc.reply)
    #expect(transport.calls("memory_ingest").isEmpty, "untrusted control text cannot issue removed memory writes")
}

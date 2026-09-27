// 居民 DSH「真实 AgentConversationService 原生 ACP 层」装配验证（service 层收口）。
//
// 复用 tools/test-agent-conversation-memory-service.swift 的**完整生产编译文件列表**
// （已补齐两个 bridge + 记忆依赖）及其 worldContext 构造；复用 tools/test-resident-dsh-acp-
// native-assembly.swift/.sh 与 resident-dsh-acp-mock.mjs 的真实 runtime 启动、假凭据 /
// 本地 BASE_URL / 控制文件逻辑，不重造架构。差异只在收口层：
//
//   调用方 = 真实 AgentConversationService.send（backend .dsh、独立 UserDefaults suite、
//   worldContext 带 worldID、每轮新 ResidentConversationTools 实例、visionCapable=true
//   强制原生 ACP 路径），绝不注入 residentDSHImageConnector（注入入口走旧 JSON 文本信封
//   回送，不能证明真实 Service 原生通道）。
//
// 环境说明（与 acp-native-assembly 直接驱动 connector 不同，Service 的
// acquireDSHImageRuntime 创建 ResidentDSHConnector 时不传 environmentOverrides ——
// 生产 connector 的 allowlist 子进程环境不含 DEEPSEEK_BASE_URL/DEEPSEEK_API_KEY/DSH_HOME；
// 见 ResidentDSHTransport.residentEnvironment 与 acquireDSHImageRuntime 调用点）。因此
// 启动脚本通过既有发现 seam GMGN_DSH_ACP_ENTRY 指向一个**测试专用 env shim 入口**
// （tools/test-resident-dsh-service-native-assembly.sh 在临时锚点目录生成），它只设置
// loopback mock 的 DEEPSEEK_BASE_URL=mock/v1、DEEPSEEK_API_KEY=mock-key 与全新私有
// DSH_HOME，然后委托给**真实** acp-demo bin.js；node 仍是 command -v 的真实路径、
// ACP runtime/composition/插件/宿主通道全部是生产代码。本 harness 在进程内断言
// allowlist 裁剪仍然成立（证明环境只能经 shim 入口注入），并在结果中如实打印该机制。
//
// 覆盖（真实 Service + 真实 ACP 持久会话 + 真实 gmgn-host-tools 插件 + mock provider）：
//   S1 首轮（armed，tools 实例 A）：宿主执行 A 恰好一次 → 普通 final；
//   S2 同 scope 第二轮（新 tools 实例 B）：执行 B 恰好一次，A 不再执行（跨轮重绑定）；
//   S3 纯文字轮（tools C + 模型只回 final 文本）：零宿主执行，纯文字/文字里的 JSON
//      片段绝不被当作动作执行；
//   S4 取消轮：mock 确定 stall → service.cancel() → 该轮以 cancelled 结束、零宿主执行；
//      取消 settle 后新轮（实例 E）可用、无旧工具副作用（A/B/C/D 计数不变）；
//   S5 同 ACP 会话证据：mock 捕获的 R2 请求消息历史含 R1 用户文字与 R1 工具结果
//      （同一持久会话的服务端累积），且每轮工具结果以 role=tool 回到同一轮请求。
//   附：allowlist 裁剪断言 + shim 委托事实打印。同会话证据只来自本测试 mock 的
//   REQUESTS_FILE（Service bootstrap 只是把历史拼进文本，不会伪造 role=tool）；
//   不扫描任何本测试之外的临时目录/持久文件（FileManager.temporaryDirectory 是系统
//   /var/folders，即使按 creationDate 过滤也无法保证只读本测试资源）。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let work = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-dsh-service-native-assembly-\(UUID().uuidString.prefix(8))", isDirectory: true)
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

let harness = #"""
import Foundation

// ────────────────────────── 轮次 / 断言工具 ──────────────────────────

let environment = ProcessInfo.processInfo.environment
@MainActor var checks = 0
@MainActor var failures = 0
@MainActor func check(_ value: Bool, _ message: String) {
    checks += 1
    if !value { failures += 1; print("FAIL: \(message)") }
}

/// 单轮 send 上界：真实 ACP runtime 的本轮请求必须在界内结束。
@MainActor
private func boundedTurn(
    seconds: Double = 90,
    _ operation: @escaping @MainActor () async throws -> String
) async throws -> String {
    // 先启动标注 @MainActor 的任务（与记忆 harness 同款受支持形态），再在普通任务组里
    // 竞速它的 .value —— 避免把 actor 隔离闭包直接塞进 @Sendable 组任务。
    let workTask = Task { @MainActor in try await operation() }
    return try await withThrowingTaskGroup(of: String.self) { group in
        group.addTask { try await workTask.value }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw CancellationError()
        }
        guard let first = try await group.next() else { throw CancellationError() }
        group.cancelAll()
        return first
    }
}

/// mock 控制文件（tools/test-resident-dsh-acp-mock.mjs：tool | final | stall）。
func writeControl(_ value: String) {
    guard let controlFile = environment["CONTROL_FILE"], !controlFile.isEmpty else { return }
    try? Data((value + "\n").utf8).write(to: URL(fileURLWithPath: controlFile), options: [.atomic])
}

/// mock 捕获的 REQUESTS_FILE：等待某行出现（轮次间/取消前同步用）。
/// async + Task.sleep：不能阻塞 MainActor（send 任务本身在 MainActor 上跑）。
@MainActor
func waitForRequestsLine(containing needle: String, within seconds: TimeInterval = 40) async -> Bool {
    let url = URL(fileURLWithPath: environment["REQUESTS_FILE"] ?? "/nonexistent")
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if let text = try? String(contentsOf: url, encoding: .utf8), text.contains(needle) {
            return true
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return false
}

/// 实例执行日志（锁保护，跨 @MainActor 闭包捕获安全）。
final class ToolLog: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [(instance: String, kind: String, at: Date)] = []
    func record(_ instance: String, _ kind: String) {
        lock.lock(); defer { lock.unlock() }
        records.append((instance, kind, Date()))
    }
    var snapshot: [(instance: String, kind: String)] {
        lock.lock(); defer { lock.unlock() }
        return records.map { ($0.instance, $0.kind) }
    }
    var execSequence: [String] {
        lock.lock(); defer { lock.unlock() }
        return records.filter { $0.kind == "exec" }.map { $0.instance }
    }
    func count(instance: String, kind: String = "exec") -> Int {
        snapshot.filter { $0.instance == instance && $0.kind == kind }.count
    }
    var execCount: Int { snapshot.filter { $0.kind == "exec" }.count }
}

// ────────────────────────── fixture ──────────────────────────

/// 与 conversation-memory-service 一致的 worldContext。
@MainActor
private func makeWorld(id: String = "cabin") -> ResidentWorldContext {
    ResidentWorldContext(
        selectedWorldID: id, worldID: id, displayName: "生活舱", revision: 1,
        residentPosition: [0, 0, 0], activeActivity: nil, activityPhase: nil,
        objects: [], availableActivities: []
    )
}

/// 真实 node + 真实 dsh 入口的 locator（isInstalled(.dsh) 与原生 transport 发现都过）。
struct ServiceLocator: AgentExecutableLocating {
    let node: URL
    let dsh: URL
    func locate(executableNames: [String]) -> URL? {
        if executableNames.contains("node") { return node }
        if executableNames.contains("dsh") { return dsh }
        return nil
    }
}

/// 与 ResidentDSHHostSupportSchema.read 同形的 canonical schema（唯一正式工具；
/// 每轮以新 tools 实例 + 每轮绑定验证重绑定语义）。
func readWishSchemaJSON() -> Data {
    let read: [String: Any] = [
        "name": "read_wish_generation",
        "description": "查询许愿机当前任务状态",
        "inputSchema": [
            "type": "object",
            "properties": ["wish_id": ["type": "string", "description": "许愿任务编号"]],
            "required": [],
            "additionalProperties": false,
        ],
    ]
    return try! JSONSerialization.data(withJSONObject: [read], options: [.sortedKeys])
}

/// 每轮新的 ResidentConversationTools 实例：handler 只计数并回规范假 JSON，
/// 绝不触碰真实空间。
@MainActor
private func makeTools(label: String, log: ToolLog, worldID: String = "cabin") -> ResidentConversationTools {
    let payload = try! JSONSerialization.data(withJSONObject: [
        "ok": true, "running": false, "wish_id": NSNull(),
        "scope": "world.\(worldID)", "instance": label,
    ], options: [.sortedKeys])
    return ResidentConversationTools(
        visionCapable: true,
        worldID: worldID,
        schemasJSON: readWishSchemaJSON(),
        call: { _, _, _ in
            log.record(label, "exec")
            return ResidentCodexToolReply(resultJSON: payload, isError: false)
        },
        cancel: { log.record(label, "cancel") }
    )
}

// ────────────────────────── 请求体分析（mock 捕获）──────────────────────────

private struct RequestLine {
    let control: String
    let body: [String: Any]
}

private func readRequests() -> [RequestLine] {
    let file = environment["REQUESTS_FILE"] ?? ""
    guard !file.isEmpty, let content = try? String(contentsOfFile: file, encoding: .utf8) else { return [] }
    var out: [RequestLine] = []
    for line in content.split(separator: "\n") {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let body = object["body"] as? [String: Any] else { continue }
        out.append(RequestLine(control: object["control"] as? String ?? "", body: body))
    }
    return out
}

private func lastUserIndex(_ messages: [[String: Any]]) -> Int {
    var index = -1
    for (i, message) in messages.enumerated() where (message["role"] as? String) == "user" {
        index = i
    }
    return index
}

private func messageText(_ message: [String: Any]) -> String {
    if let text = message["content"] as? String { return text }
    if let blocks = message["content"] as? [[String: Any]] {
        return blocks.compactMap { $0["text"] as? String }.joined()
    }
    return ""
}

private func toolNames(_ body: [String: Any]) -> [String] {
    guard let tools = body["tools"] as? [[String: Any]] else { return [] }
    return tools.compactMap { tool -> String? in
        if let fn = tool["function"] as? [String: Any], let name = fn["name"] as? String { return name }
        return nil
    }
}

private func toolRoleMessages(_ body: [String: Any]) -> [String] {
    guard let messages = body["messages"] as? [[String: Any]] else { return [] }
    return messages.filter { ($0["role"] as? String) == "tool" }.map(messageText)
}

private func joinMessages(_ body: [String: Any]) -> String {
    guard let messages = body["messages"] as? [[String: Any]] else { return "" }
    return messages.map(messageText).joined(separator: "\n")
}

// ────────────────────────── 主流程 ──────────────────────────

@main struct ServiceNativeAssembly {
    @MainActor static func main() async throws {
        // 总看门狗：整套组装必须远低于此上界退出（先收尾 runtime / 本测试 suite 再退，
        // 不留子进程与偏好域）。
        let watchdog = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 250_000_000_000) }
            catch { return }
            print("FAIL: service native-assembly watchdog timeout (250s)")
            cleanupService()
            exit(1)
        }
        defer { watchdog.cancel() }

        print("== test-resident-dsh-service-native-assembly ==")

        // ── 0) 环境前提与 allowlist 事实 ──
        guard let mockBase = environment["MOCK_BASE_URL"], !mockBase.isEmpty else {
            check(false, "缺少 MOCK_BASE_URL"); printResult(); return
        }
        guard let nodePath = environment["NODE_BIN"], !nodePath.isEmpty,
              FileManager.default.isExecutableFile(atPath: nodePath) else {
            check(false, "缺少可执行的 NODE_BIN（应为 command -v node 的真实路径）")
            printResult(); return
        }
        guard let dshPath = environment["DSH_BIN"], !dshPath.isEmpty,
              FileManager.default.isExecutableFile(atPath: dshPath) else {
            check(false, "缺少可执行的 DSH_BIN")
            printResult(); return
        }
        let shimEntry = environment["GMGN_DSH_ACP_ENTRY"] ?? ""
        let realEntry = environment["REAL_ACP_ENTRY"] ?? ""
        let requestsFile = environment["REQUESTS_FILE"] ?? ""
        check(FileManager.default.isReadableFile(atPath: shimEntry), "GMGN_DSH_ACP_ENTRY shim 可读")
        check(FileManager.default.isReadableFile(atPath: realEntry), "真实 acp-demo bin.js 可读")
        if let shim = try? String(contentsOfFile: shimEntry, encoding: .utf8) {
            check(shim.contains(realEntry), "shim 委托给真实 acp-demo bin.js")
            check(shim.contains("DEEPSEEK_API_KEY") && shim.contains("/v1"),
                  "shim 只注入 mock 端点与假 key（本地 loopback）")
            check(!shim.contains("sk-"), "shim 不含任何真实凭据形态")
        } else {
            check(false, "无法读取 shim 内容")
        }
        // allowlist 事实：Service 的 connector 不给子进程传 DEEPSEEK_*/DSH_HOME（生产
        // 安全设计，见 ResidentDSHTransport.residentEnvironment）。env shim 入口是
        // 本 harness 唯一把这些值送进 ACP 子进程的通道 —— 只送 loopback mock 值。
        let scrubbed = ResidentDSHTransport.residentEnvironment(base: [
            "HOME": "/tmp/home", "TMPDIR": "/tmp",
            "DEEPSEEK_API_KEY": "mock-key", "DEEPSEEK_BASE_URL": mockBase + "/v1",
            "DSH_HOME": "/tmp/dshhome", "DSH_SNAPSHOT": "replay",
            "LANG": "en_US.UTF-8", "USER": "test",
        ])
        check(scrubbed["DEEPSEEK_API_KEY"] == nil && scrubbed["DEEPSEEK_BASE_URL"] == nil,
              "allowlist 事实：DEEPSEEK_API_KEY/BASE_URL 不进 Service 原生 ACP 子进程环境")
        check(scrubbed["DSH_HOME"] == nil && scrubbed["DSH_SNAPSHOT"] == nil,
              "allowlist 事实：DSH_HOME/DSH_SNAPSHOT 不进子进程环境（故走 shim 入口注入）")
        check(scrubbed["HOME"] == "/tmp/home", "allowlist 保留 HOME")
        print("env: node=\(nodePath) dsh=\(dshPath)")
        print("entry: shim=\(shimEntry)")
        print("entry: real acp-demo=\(realEntry)")
        print("mock: \(mockBase)")

        // ── 1) 真实 locator / transport 发现 / Service ──
        let locator = ServiceLocator(node: URL(fileURLWithPath: nodePath), dsh: URL(fileURLWithPath: dshPath))
        let transport = ResidentDSHComposition.locateNativeTransport(using: locator)
        check(transport != nil, "locateNativeTransport 经 locator 找到真实 transport")
        check(transport?.node.path == nodePath, "transport.node 是真实 node 路径")
        check(transport?.entry.path == shimEntry, "transport.entry 采用 GMGN_DSH_ACP_ENTRY（shim）")
        check(ResidentDSHComposition.declaresImageInput(
            ResidentDSHComposition.residentYAML(
                attachmentHome: URL(fileURLWithPath: "/tmp/x/home"),
                persistenceRoot: URL(fileURLWithPath: "/tmp/x/sessions"),
                persona: "p"
            )
        ), "生成 composition 声明图片输入模型（原生通道保留）")

        let suite = "gmgn-service-native-assembly-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        // 记录本测试自建的 suite 域，供成功/失败/看门狗退出路径在 exit() 前显式清理
        // （exit() 不执行 defer，见 cleanupService）。
        Self.ownedDefaultsSuite = suite
        let service = AgentConversationService(locator: locator, defaults: defaults)
        service.selectBackend(.dsh)
        Self.serviceRef = service
        check(service.effectiveBackendID == .dsh, "backend 选择 .dsh")
        check(service.isInstalled(.dsh), "isInstalled(.dsh) 经 locator 通过")
        check(service.supportsWorldTools, "DSH 声明世界工具能力")
        check(service.preferenceStore.sessionID(for: .dsh, scope: nil) == nil, "suite 无残留会话")
        defer { defaults.removePersistentDomain(forName: suite) }

        let world = makeWorld(id: "cabin")
        let log = ToolLog()
        let successText = environment["SUCCESS_TEXT"] ?? "GMGN_SERVICE_NATIVE_ASSEMBLY_FINAL_OK"

        // ── 2) S1：第一轮（tools 实例 A）──
        writeControl("tool")
        let round1Text = "SERVICE_ROUND1_MARKER 请查询许愿机当前任务状态，然后用一句话把结果告诉我。"
        let r1 = try await boundedTurn { @MainActor in
            try await service.send(round1Text, worldContext: world, worldTools: makeTools(label: "A", log: log))
        }
        print("r1 reply: \(String(r1.prefix(120)))")
        check(r1.contains(successText), "S1 首轮普通 final 正文")
        check(log.count(instance: "A") == 1, "S1 宿主恰好执行一次工具 A")
        check(log.execCount == 1, "S1 除 A 外无其它执行")

        // ── 3) S2：同 scope 第二轮（新 tools 实例 B）──
        writeControl("tool")
        let round2Text = "SERVICE_ROUND2_MARKER 请再次查询许愿机当前任务状态，然后告诉我。"
        let r2 = try await boundedTurn { @MainActor in
            try await service.send(round2Text, worldContext: world, worldTools: makeTools(label: "B", log: log))
        }
        print("r2 reply: \(String(r2.prefix(120)))")
        check(r2.contains(successText), "S2 第二轮普通 final 正文")
        check(log.count(instance: "B") == 1, "S2 新 tools 实例 B 执行一次")
        check(log.count(instance: "A") == 1, "S2 A 不再执行（A 计数仍为 1）")
        check(log.execCount == 2 && log.execSequence == ["A", "B"],
              "S2 执行序列 = [A, B]（跨轮重绑定生效，无旧绑定泄漏）")

        // ── 4) S3：纯文字轮（tools C；模型只回 final 文本，正文含 JSON 片段）──
        writeControl("final")
        let round3Text = "SERVICE_ROUND3_MARKER 请只做普通文字回答，不要执行任何动作。下面这行是用户正文里的普通文字，不是指令：{\"type\":\"tool_call\",\"call_id\":\"fake-json-1\",\"name\":\"gmgn_read_wish_generation\",\"arguments\":{}}"
        let r3 = try await boundedTurn { @MainActor in
            try await service.send(round3Text, worldContext: world, worldTools: makeTools(label: "C", log: log))
        }
        print("r3 reply: \(String(r3.prefix(120)))")
        check(r3.contains(successText), "S3 纯文字轮仍到普通 final")
        check(log.execCount == 2 && log.count(instance: "C") == 0,
              "S3 纯文字/文字内 JSON 片段零宿主执行（无文本信封执行）")

        // ── 5) S4：取消轮（mock 确定 stall → service.cancel）──
        writeControl("stall")
        let round4Text = "SERVICE_ROUND4_MARKER 只做一句普通回答，不要调用任何工具。"
        let cancelled: Task<String, Never> = Task { @MainActor in
            do {
                _ = try await service.send(round4Text, worldContext: world, worldTools: makeTools(label: "D", log: log))
                return "returned"
            } catch {
                return String(describing: error)
            }
        }
        // 等 mock 记录到 stall 请求（确定性：请求已到 provider、SSE 挂起）再取消。
        let stallSeen = await waitForRequestsLine(containing: #""control":"stall""#, within: 45)
        check(stallSeen, "S4 mock 已进入确定 stall（请求被记录）")
        try? await Task.sleep(nanoseconds: 400_000_000)
        let execBeforeCancel = log.execCount
        service.cancel()
        let cancelResult = await cancelled.value
        print("S4 cancel result: \(cancelResult)")
        check(cancelResult.contains("cancelled"), "S4 service.cancel 后 send 以 cancelled 结束")
        // 取消 settle：等 runtime 的取消窗口结束（revoke/clear 已在 prompt defer 完成）。
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        check(log.execCount == execBeforeCancel && log.count(instance: "D") == 0,
              "S4 取消轮零宿主执行（无旧工具副作用）")

        // ── 6) S5：取消结束后同 scope 新轮可用（新 tools 实例 E）──
        writeControl("tool")
        let round5Text = "SERVICE_ROUND5_MARKER 取消之后的新一轮：请查询许愿机状态。"
        let r5 = try await boundedTurn { @MainActor in
            try await service.send(round5Text, worldContext: world, worldTools: makeTools(label: "E", log: log))
        }
        print("r5 reply: \(String(r5.prefix(120)))")
        check(r5.contains(successText), "S5 取消后新轮正常到普通 final")
        check(log.count(instance: "E") == 1, "S5 新实例 E 执行一次")
        check(log.count(instance: "A") == 1 && log.count(instance: "B") == 1
              && log.count(instance: "C") == 0 && log.count(instance: "D") == 0,
              "S5 取消无旧工具副作用（A=1,B=1,C=0,D=0）")
        check(log.execSequence == ["A", "B", "E"],
              "S5 总执行序列 [A,B,E]（取消轮与纯文字轮零执行）")

        // ── 7) mock 捕获的请求体断言：工具结果回同一轮 + 同一持久会话 ──
        try? await Task.sleep(nanoseconds: 500_000_000)
        if !requestsFile.isEmpty {
            let requests = readRequests()
            check(!requests.isEmpty, "mock 捕获到请求")
            // 7a. 同一轮：存在 role=tool 消息位于「该轮最后 user 之后」（工具结果回灌同一轮）。
            var sawToolResultInSameRound = 0
            var toolResultText = ""
            for request in requests {
                guard let messages = request.body["messages"] as? [[String: Any]] else { continue }
                let lastUser = lastUserIndex(messages)
                for message in messages.enumerated() where (message.element["role"] as? String) == "tool" {
                    if message.offset > lastUser {
                        sawToolResultInSameRound += 1
                        toolResultText += messageText(message.element)
                    }
                }
            }
            check(sawToolResultInSameRound >= 2, "工具结果以 role=tool 回灌进同一轮（次数 \(sawToolResultInSameRound)）")
            check(toolResultText.contains("\"instance\":\"A\"") && toolResultText.contains("\"instance\":\"B\""),
                  "同一轮工具结果内容含 A/B 实例的宿主规范值")
            // 7b. 同一 ACP 会话：R2 的请求消息历史含 R1 用户文字与 R1 工具结果
            //     （服务端在同一 agent session 累积 —— 新会话不会有 R1 历史）。
            var r1InR2History = false
            var r1ToolInR2History = false
            for request in requests {
                guard let messages = request.body["messages"] as? [[String: Any]] else { continue }
                let joined = joinMessages(request.body)
                guard joined.contains("SERVICE_ROUND2_MARKER") else { continue }
                let lastUser = lastUserIndex(messages)
                let before = Array(messages.prefix(max(lastUser, 0)))
                if before.map(messageText).joined().contains("SERVICE_ROUND1_MARKER") { r1InR2History = true }
                if before.contains(where: { ($0["role"] as? String) == "tool" && messageText($0).contains("\"instance\":\"A\"") }) {
                    r1ToolInR2History = true
                }
            }
            check(r1InR2History, "R2 请求历史含 R1 用户文字（同一持久会话的服务端累积）")
            check(r1ToolInR2History, "R2 请求历史含 R1 工具结果（R1/R2 同一 ACP 会话）")
        } else {
            check(true, "未配置 REQUESTS_FILE，跳过请求体断言")
        }

        // ── 8) 收尾：关 runtime（connector close / 通道 stop / sandbox 删除）并清理
        //      本测试自建的 UserDefaults suite 域（printResult 的 exit() 不走 defer）──
        cleanupService()
        printResult()
    }

    // 收尾（幂等，成功 / 失败 / 看门狗任一退出前都调用）：先关闭 Service 的原生 runtime、
    // 回收它启动的 ACP 子进程（service.resetSession）；再显式移除本测试新建的独立
    // UserDefaults suite 域。exit() 不会执行 defer，因此不能依赖 main 里的 defer 清理
    // 偏好域；这里只动本测试自建的 suite，绝不触碰未知域。
    @MainActor private static var serviceRef: AgentConversationService?
    @MainActor private static var ownedDefaultsSuite: String?

    @MainActor static func cleanupService() {
        serviceRef?.resetSession()
        serviceRef = nil
        if let suite = ownedDefaultsSuite {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            ownedDefaultsSuite = nil
        }
    }

    @MainActor static func printResult() {
        let passed = failures == 0
        print("\(passed ? "PASS" : "FAIL"): \(checks) resident DSH service native-assembly checks, \(failures) failures")
        exit(passed ? 0 : 1)
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
compile.currentDirectoryURL = work
try compile.run()
let compileDeadline = Date().addingTimeInterval(240)
while compile.isRunning && Date() < compileDeadline {
    try await Task.sleep(nanoseconds: 100_000_000)
}
if compile.isRunning {
    compile.terminate()
    print("FAIL: service native-assembly compile exceeded 240s")
    exit(124)
}
compile.waitUntilExit()
guard compile.terminationStatus == 0 else {
    try? FileManager.default.removeItem(at: work)
    print("COMPILE FAILED (exit \(compile.terminationStatus))")
    exit(compile.terminationStatus)
}
let test = Process()
test.executableURL = binary
try test.run()
let runDeadline = Date().addingTimeInterval(300)
while test.isRunning && Date() < runDeadline {
    try await Task.sleep(nanoseconds: 100_000_000)
}
if test.isRunning {
    test.terminate()
    try? FileManager.default.removeItem(at: work)
    print("FAIL: service native-assembly execution exceeded 300s")
    exit(124)
}
test.waitUntilExit()
try? FileManager.default.removeItem(at: work)
print("service-native assembly exit=\(test.terminationStatus)")
exit(test.terminationStatus)

//
//  test-resident-claude-tool-bridge-support.swift
//  GMGNRadio（仅测试；不进 App）
//
//  ResidentClaudeToolBridge 的离线回归夹具与驱动（无真实 Claude 模型 / 无网络）：
//   · ResidentClaudeMCPChecks：断言计数；
//   · ResidentClaudeMCPFixture：生产同形 schemas（3 工具）与 33 工具合成集；
//   · ResidentClaudeMCPCallLog / residentClaudeMCPHandler：确定性宿主执行者；
//   · residentClaudeMCPHTTPFrameAsync：直连私有 HTTP 通道（绕过 adapter 验证宿主侧过期）；
//   · ResidentClaudeMCPStdioClient：以真实 node 子进程驱动 stdio MCP。
//
import Foundation

// MARK: - Checks

struct ResidentClaudeMCPChecks {
    private(set) var passed = 0
    private(set) var failures: [String] = []

    mutating func check(_ condition: Bool, _ description: String) {
        if condition {
            passed += 1
        } else {
            failures.append(description)
            print("FAIL: \(description)")
        }
    }

    mutating func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ description: String) {
        check(lhs == rhs, "\(description)（期望 \(rhs)，实际 \(lhs)）")
    }

    mutating func expectContains(_ haystack: String, _ needle: String, _ description: String) {
        check(haystack.contains(needle), "\(description)（未找到「\(needle)」）")
    }

    var result: Bool { failures.isEmpty }
}

// MARK: - Fixture schemas / payloads

enum ResidentClaudeMCPFixture {
    static func data(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static let expectedDeclaredNames = [
        "gmgn_capture_view", "gmgn_read_wish_generation", "gmgn_submit_wish_generation",
    ]

    /// 与 ResidentWorldToolSession.toolSchemasJSON 同形状：[{name, description, inputSchema}]。
    static let schemas: Data = {
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
        let submit: [String: Any] = [
            "name": "submit_wish_generation",
            "description": "提交许愿机生成",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "attachment_id": ["type": "string"],
                    "name": ["type": "string"],
                    "height_meters": ["type": "number"],
                ],
                "required": ["attachment_id", "name", "height_meters"],
                "additionalProperties": false,
            ],
        ]
        let capture: [String: Any] = [
            "name": "capture_view",
            "description": "抓取一张居民视角图片",
            "inputSchema": [
                "type": "object",
                "properties": ["label": ["type": "string"]],
                "required": [],
                "additionalProperties": false,
            ],
        ]
        return data([read, submit, capture])
    }()

    /// 33 个合成正式工具：验证 tools/list 逐条来自正式 schema、无任何额外内建。
    static let thirtyThreeSchemas: Data = {
        var entries: [[String: Any]] = []
        for index in 0..<33 {
            entries.append([
                "name": "world_tool_\(index)",
                "description": "合成正式工具 \(index)",
                "inputSchema": [
                    "type": "object",
                    "properties": ["value": ["type": "string"]],
                    "required": [],
                    "additionalProperties": false,
                ],
            ])
        }
        return data(entries)
    }()

    static let imagePNG = Data(
        [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + [UInt8](repeating: 0x2A, count: 24)
    )

    /// 单次工具结果超过 adapter 文本上界，用于验证响应有界与截断。
    static let bigText = String(repeating: "x", count: 1_100_000)
}

// MARK: - Host call log + deterministic handler

final class ResidentClaudeMCPCallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String] = []

    func append(_ canonical: String, callID: String, argumentsJSON: Data) {
        lock.lock()
        defer { lock.unlock() }
        records.append("\(callID)|\(canonical)|\(String(decoding: argumentsJSON, as: UTF8.self))")
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return records.count
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    /// 宿主实际看到的 callId 序列（记录格式 `callId|canonical|args`）。
    var callIDs: [String] {
        all.compactMap { record in
            guard let separator = record.firstIndex(of: "|") else { return nil }
            return String(record[record.startIndex..<separator])
        }
    }

    func contains(canonical: String) -> Bool {
        all.contains { $0.contains("|\(canonical)|") }
    }
}

func residentClaudeMCPHandler(
    log: ResidentClaudeMCPCallLog
) -> @MainActor @Sendable (ResidentDSHHostToolRequest) async -> ResidentDSHHostToolReply {
    { request in
        log.append(request.canonicalName, callID: request.callID, argumentsJSON: request.argumentsJSON)
        switch request.canonicalName {
        case "read_wish_generation":
            let payload = ResidentClaudeMCPFixture.data([
                "ok": true, "running": false, "wish_id": NSNull(), "scope": "world.cabin",
            ])
            return ResidentDSHHostToolReply(resultJSON: payload, isError: false)
        case "submit_wish_generation":
            let arguments = ResidentClaudeMCPFixture.object(request.argumentsJSON) ?? [:]
            let name = arguments["name"] as? String ?? "x"
            if name == "fail" {
                let payload = ResidentClaudeMCPFixture.data([
                    "ok": false, "error": ["code": "wish_denied", "message": "测试拒绝"],
                ])
                return ResidentDSHHostToolReply(resultJSON: payload, isError: true)
            }
            if name == "big" {
                let payload = ResidentClaudeMCPFixture.data([
                    "ok": true, "blob": ResidentClaudeMCPFixture.bigText,
                ])
                return ResidentDSHHostToolReply(resultJSON: payload, isError: false)
            }
            let payload = ResidentClaudeMCPFixture.data(["ok": true, "wish_id": "w-" + name])
            return ResidentDSHHostToolReply(resultJSON: payload, isError: false)
        case "capture_view":
            let payload = ResidentClaudeMCPFixture.data(["ok": true, "captured": true])
            return ResidentDSHHostToolReply(
                resultJSON: payload, isError: false,
                imagePNGData: ResidentClaudeMCPFixture.imagePNG
            )
        default:
            let payload = ResidentClaudeMCPFixture.data([
                "ok": false, "error": ["code": "tool_not_allowed", "message": "未开放"],
            ])
            return ResidentDSHHostToolReply(resultJSON: payload, isError: true)
        }
    }
}

// MARK: - Direct HTTP client (bypasses the adapter; mirrors the host wire)

func residentClaudeMCPHTTPFrameAsync(
    rpcURL: String,
    secret: String,
    name: String,
    arguments: [String: Any],
    callID: String = "direct"
) async -> Data? {
    guard let url = URL(string: rpcURL),
          url.scheme == "http", url.host == "127.0.0.1", url.path == "/rpc",
          url.query == nil, url.fragment == nil,
          let port = url.port, (1...65535).contains(port) else { return nil }
    let body: [String: Any] = [
        "v": 1, "callId": callID, "name": name, "arguments": arguments,
    ]
    guard let encoded = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else {
        return nil
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = encoded
    request.timeoutInterval = 10
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = [:]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    guard let (data, response) = try? await session.data(for: request),
          let http = response as? HTTPURLResponse,
          http.statusCode == 200 || http.statusCode == 403,
          data.count <= ResidentClaudeMCPAdapter.maximumHostReplyBytes else { return nil }
    return data
}

// MARK: - MCP stdio client (real node child process)

final class ResidentClaudeMCPStdioClient: @unchecked Sendable {
    private let process: Process
    private let stdinHandle: FileHandle
    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle
    private let lock = NSLock()
    private var stdoutBuffer = Data()
    private var rawLines: [String] = []
    private var history: [String] = []
    private var stderrBuffer = Data()

    init(executableURL: URL, arguments: [String], cwd: URL) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        self.process = process
        self.stdinHandle = inPipe.fileHandleForWriting
        self.stdoutHandle = outPipe.fileHandleForReading
        self.stderrHandle = errPipe.fileHandleForReading
        stdoutHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.ingestStdout(data)
        }
        stderrHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            self.lock.lock()
            self.stderrBuffer.append(data)
            self.lock.unlock()
        }
    }

    private func ingestStdout(_ data: Data) {
        var newLines: [String] = []
        lock.lock()
        stdoutBuffer.append(data)
        while let index = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer[stdoutBuffer.startIndex..<index]
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...index)
            newLines.append(String(decoding: lineData, as: UTF8.self))
        }
        rawLines.append(contentsOf: newLines)
        history.append(contentsOf: newLines)
        lock.unlock()
    }

    func send(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        try sendRaw(data + Data([0x0A]))
    }

    func sendRaw(_ data: Data) throws {
        try stdinHandle.write(contentsOf: data)
    }

    /// 取走匹配 id 的原始响应行；超时返回 nil。async 等待：让出 MainActor，
    /// 宿主通道的工具执行者（@MainActor）才有机会运行。
    func takeRaw(id: Int, timeout: TimeInterval = 15) async -> String? {
        await takeRaw(timeout: timeout) { object in
            (object["id"] as? NSNumber)?.intValue == id
        }
    }

    /// 取走无 id（JSON-RPC 错误或通知）的原始响应行。
    func takeRawUnsolicited(timeout: TimeInterval = 3) async -> String? {
        await takeRaw(timeout: timeout) { object in
            object["id"] == nil || object["id"] is NSNull
        }
    }

    /// 取走下一条响应行（无论 id 形状）——用于非法 id 无法按 id 关联的用例。
    func takeAnyRaw(timeout: TimeInterval = 3) async -> String? {
        await takeRaw(timeout: timeout) { _ in true }
    }

    /// 取走字符串 id 的响应行。
    func takeRaw(stringID: String, timeout: TimeInterval = 5) async -> String? {
        await takeRaw(timeout: timeout) { object in
            (object["id"] as? String) == stringID
        }
    }

    private func takeBufferedRaw(matching: ([String: Any]) -> Bool) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = rawLines.firstIndex(where: { raw in
            guard let data = raw.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return false
            }
            return matching(object)
        }) else { return nil }
        return rawLines.remove(at: index)
    }

    private func takeRaw(timeout: TimeInterval, matching: ([String: Any]) -> Bool) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let raw = takeBufferedRaw(matching: matching) { return raw }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }

    func object(from raw: String?) -> [String: Any]? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    var receivedLines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return history
    }

    var stderrText: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: stderrBuffer, as: UTF8.self)
    }

    func terminate() {
        try? stdinHandle.close()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            let killDeadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}

// MARK: - Node executable resolution (ordinary toolchain lookup; no env scraping)

func residentClaudeMCPResolveNode() -> URL? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["node", "-e", "process.stdout.write(process.execPath)"]
    let outPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = Pipe()
    do { try process.run() } catch { return nil }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return path.isEmpty ? nil : URL(fileURLWithPath: path)
}

// MARK: - One-shot thread-safe flag (for delayed-handler cancellation tests)

final class ResidentClaudeMCPFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

// MARK: - Standalone adapter fixture (crafted grant files; no session)

/// 在临时目录里生成 adapter + 手写 grant 文件并以真实 node 子进程驱动，用于
/// 覆盖 grant 重读/过期/大小上界等 adapter 侧行为。
func residentClaudeMCPStandaloneAdapter(
    in directory: URL,
    nodeExecutable: URL,
    registrations: [ResidentDSHHostToolRegistration],
    grantJSON: String
) throws -> (client: ResidentClaudeMCPStdioClient, grantURL: URL) {
    let source = try ResidentClaudeMCPAdapter.source(registrations: registrations)
    let adapterURL = directory.appendingPathComponent(ResidentClaudeMCPAdapter.filename)
    try Data(source.utf8).write(to: adapterURL, options: [.atomic])
    let grantURL = directory.appendingPathComponent(ResidentClaudeMCPAdapter.grantFilename)
    try Data(grantJSON.utf8).write(to: grantURL, options: [.atomic])
    let client = try ResidentClaudeMCPStdioClient(
        executableURL: nodeExecutable, arguments: [adapterURL.path], cwd: directory
    )
    return (client, grantURL)
}

/// 手工拼 grant JSON（原始文本，便于注入 1e999 / null / 字符串 expiresAt 与非有限数）。
func residentClaudeMCPCraftedGrant(
    secret: String,
    round: String,
    rpcURL: String,
    declaredName: String,
    expiresAtLiteral: String?,
    paddingBytes: Int = 0
) -> String {
    let expires = expiresAtLiteral.map { "\"expiresAt\":\($0)," } ?? ""
    let padding = paddingBytes > 0
        ? "\"pad\":\"" + String(repeating: "a", count: paddingBytes) + "\","
        : ""
    return "{\"protocol\":1,\"state\":\"armed\",\(expires)\(padding)"
        + "\"secret\":\"\(secret)\",\"round\":\"\(round)\",\"endpoint\":{\"version\":2,\"url\":\"\(rpcURL)\",\"token\":\"\(secret)\"},"
        + "\"tools\":[{\"name\":\"\(declaredName)\",\"canonical\":\"read_wish_generation\"}]}"
}

// MARK: - Test program

@main
struct ResidentClaudeMCPBridgeTests {
    static func main() async throws {
        var checks = ResidentClaudeMCPChecks()
        guard let nodeExecutable = residentClaudeMCPResolveNode() else {
            print("FAIL: 无法解析 node 可执行文件（需要本机 node）")
            exit(1)
        }

        // 0) 正式 schema 解析（3 工具）与禁止名单 fail-closed。
        let registrations = try ResidentDSHHostToolSet.parse(schemasJSON: ResidentClaudeMCPFixture.schemas)
        checks.expectEqual(registrations.count, 3, "R0 解析三个正式工具")
        for forbidden in ["shell", "read", "write"] {
            let schema = ResidentClaudeMCPFixture.data([
                ["name": forbidden, "description": "x", "inputSchema": ["type": "object", "properties": [:]]],
            ])
            let parsed = try ResidentDSHHostToolSet.parse(schemasJSON: schema)
            do {
                _ = try ResidentClaudeMCPAdapter.source(registrations: parsed)
                checks.check(false, "R0 禁止工具 \(forbidden) 必须 fail-closed")
            } catch {
                checks.check(true, "R0 禁止工具 \(forbidden) 被拒绝")
            }
        }

        // 0b) callId 生成必须来自 node:crypto randomUUID（仅 Date.now 会在同毫秒撞 id）。
        let adapterSource = try ResidentClaudeMCPAdapter.source(registrations: registrations)
        checks.expectContains(adapterSource, "node:crypto", "R0b adapter 引入 node:crypto")
        checks.expectContains(adapterSource, "randomUUID", "R0b adapter 用 randomUUID 生成 callId")
        checks.expectContains(adapterSource, "node:http", "R0c adapter 使用 HTTP")
        checks.check(!adapterSource.contains("node:net") && !adapterSource.contains("net.connect"), "R0c 无裸 TCP adapter")
        checks.expectContains(adapterSource, "'Authorization': 'Bearer '", "R0c HTTP Bearer 鉴权")

        // 1) 会话启动：私有文件、权限、MCP 配置形状。
        let log = ResidentClaudeMCPCallLog()
        let deadline = Date().addingTimeInterval(600)
        let session = try ResidentClaudeMCPHostSession.start(
            configuration: ResidentClaudeMCPHostSession.Configuration(
                scope: "world.cabin", worldID: "cabin-1",
                registrations: registrations,
                handler: residentClaudeMCPHandler(log: log),
                nodeExecutable: nodeExecutable
            ),
            deadline: deadline
        )
        defer { session.stop() }
        // 首次 arm 的 secret：用于 R16 泄露语料覆盖（后续 arm 会轮换）。
        let initialGrant = ResidentClaudeMCPFixture.object(try Data(contentsOf: session.grantFileURL))
        let initialSecret = initialGrant?["secret"] as? String ?? ""
        let initialEndpoint = initialGrant?["endpoint"] as? [String: Any]
        checks.expectEqual(initialEndpoint?["version"] as? Int, 2, "R1 HTTP endpoint version=2")
        checks.expectEqual(initialEndpoint?["url"] as? String, session.rpcURL, "R1 HTTP RPC URL 一致")
        checks.check(initialEndpoint?["address"] == nil, "R1 不保留旧裸 TCP address")

        checks.check(FileManager.default.fileExists(atPath: session.adapterFileURL.path), "R1 adapter 文件已写")
        checks.check(FileManager.default.fileExists(atPath: session.grantFileURL.path), "R1 grant 文件已写")
        checks.check(FileManager.default.fileExists(atPath: session.configFileURL.path), "R1 mcp config 已写")
        for url in [session.adapterFileURL, session.grantFileURL, session.configFileURL] {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            checks.expectEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600, "R1 \(url.lastPathComponent) 0600")
        }
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: session.directoryURL.path)
        checks.expectEqual((dirAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700, "R1 会话目录 0700")
        checks.check(session.directoryURL.path.count < 100, "R1 私有目录短路径")
        checks.check(!session.isExpired, "R1 未过期")

        let configRaw = try session.mcpConfigJSON()
        let configObject = ResidentClaudeMCPFixture.object(configRaw)
        let server = (configObject?["mcpServers"] as? [String: Any])?[ResidentClaudeMCPAdapter.serverName] as? [String: Any]
        checks.expectEqual(server?["type"] as? String, "stdio", "R1 mcp config type=stdio")
        checks.expectEqual(server?["command"] as? String, nodeExecutable.path, "R1 mcp config command")
        checks.expectEqual(server?["args"] as? [String], [session.adapterFileURL.path], "R1 mcp config args")
        checks.expectEqual(session.mcpConfigArguments, ["--mcp-config", session.configFileURL.path], "R1 接线参数")
        // 放行清单必须逐项精确：mcp__<server>__<declared tool>，不得有宽泛 server 片段。
        let expectedAllowedNames = [
            "mcp__gmgn-resident-tools__gmgn_read_wish_generation",
            "mcp__gmgn-resident-tools__gmgn_submit_wish_generation",
            "mcp__gmgn-resident-tools__gmgn_capture_view",
        ]
        checks.expectEqual(
            ResidentClaudeMCPAdapter.allowedToolNames(registrations: registrations),
            expectedAllowedNames,
            "R1 allowedToolNames 逐项精确完整列表"
        )
        checks.expectEqual(session.allowedToolNames, expectedAllowedNames, "R1 会话放行清单一致")
        checks.check(
            !session.allowedToolNames.contains("mcp__\(ResidentClaudeMCPAdapter.serverName)"),
            "R1 无宽泛 server 片段"
        )
        checks.check(
            session.allowedToolNames.allSatisfy { name in
                name.hasPrefix("mcp__\(ResidentClaudeMCPAdapter.serverName)__") && !name.hasSuffix("__")
            },
            "R1 放行清单全部为 mcp__server__tool 形状"
        )
        // bridge 源码绝不建议内建 WebSearch/WebFetch，也绝不建议任何全局 bypass。
        let bridgeSource = try String(
            contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/ResidentClaudeToolBridge.swift"),
            encoding: .utf8
        )
        for forbiddenSuggestion in ["WebSearch", "WebFetch", "bypassPermissions", "dangerously-skip-permissions"] {
            checks.check(
                !bridgeSource.contains(forbiddenSuggestion),
                "R1 bridge 不建议 \(forbiddenSuggestion)"
            )
        }

        // 2) 真实 node stdio MCP 全链路。
        let client = try ResidentClaudeMCPStdioClient(
            executableURL: nodeExecutable,
            arguments: [session.adapterFileURL.path],
            cwd: session.directoryURL
        )
        defer { client.terminate() }

        try client.send([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": [
                "protocolVersion": ResidentClaudeMCPAdapter.protocolVersion,
                "capabilities": [:], "clientInfo": ["name": "gmgn-test", "version": "1"],
            ],
        ])
        let initRaw = await client.takeRaw(id: 1)
        let initObject = client.object(from: initRaw)
        let initResult = initObject?["result"] as? [String: Any]
        checks.expectEqual(initResult?["protocolVersion"] as? String, ResidentClaudeMCPAdapter.protocolVersion, "R2 initialize 协议版本")
        let serverInfo = initResult?["serverInfo"] as? [String: Any]
        checks.expectEqual(serverInfo?["name"] as? String, ResidentClaudeMCPAdapter.serverName, "R2 initialize serverInfo")
        checks.check(initResult?["capabilities"] != nil, "R2 initialize capabilities")

        try client.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        let initializedNoise = await client.takeRawUnsolicited(timeout: 0.4)
        checks.check(initializedNoise == nil, "R2 initialized 通知不产生响应")

        try client.send(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let listRaw = await client.takeRaw(id: 2)
        let listObject = client.object(from: listRaw)
        let tools = (listObject?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        checks.expectEqual(tools.count, 3, "R2 tools/list 恰好三个正式工具")
        checks.expectEqual(tools.compactMap { $0["name"] as? String }.sorted(), ResidentClaudeMCPFixture.expectedDeclaredNames, "R2 tools/list 名字来自正式 schema")
        checks.check(tools.allSatisfy { ($0["inputSchema"] as? [String: Any])?["type"] as? String == "object" }, "R2 tools/list 带正式 inputSchema")
        let allText = tools.compactMap { $0["name"] as? String }.joined(separator: ",")
        for forbidden in ["shell", "bash", "read", "write", "edit", "exec"] {
            checks.check(!allText.split(separator: ",").contains(Substring(forbidden)), "R2 未注册 \(forbidden)")
        }

        func callTool(id: Int, name: String, arguments: Any) async -> [String: Any]? {
            try? client.send([
                "jsonrpc": "2.0", "id": id, "method": "tools/call",
                "params": ["name": name, "arguments": arguments],
            ])
            let raw = await client.takeRaw(id: id)
            return client.object(from: raw)
        }
        func textContent(_ response: [String: Any]?) -> String {
            let content = (response?["result"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            return content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        func isError(_ response: [String: Any]?) -> Bool? {
            (response?["result"] as? [String: Any])?["isError"] as? Bool
        }
        func errorCode(_ response: [String: Any]?) -> Int? {
            (response?["error"] as? [String: Any]).flatMap { ($0["code"] as? NSNumber)?.intValue }
        }

        // 3) 正常调用：工具结果 JSON → MCP text content。
        let readResponse = await callTool(id: 10, name: "gmgn_read_wish_generation", arguments: [:])
        checks.expectEqual(isError(readResponse), false, "R3 正常调用 isError=false")
        checks.expectContains(textContent(readResponse), "wish_id", "R3 结果 JSON 成为 text content")
        checks.expectContains(textContent(readResponse), "world.cabin", "R3 结果字段透传")
        checks.expectEqual(log.count, 1, "R3 宿主执行一次")

        // 4) 工具自身错误：isError=true 且保留工具错误载荷。
        let failResponse = await callTool(
            id: 11, name: "gmgn_submit_wish_generation",
            arguments: ["attachment_id": "a", "name": "fail", "height_meters": 1.5]
        )
        checks.expectEqual(isError(failResponse), true, "R4 工具错误 isError=true")
        checks.expectContains(textContent(failResponse), "wish_denied", "R4 工具错误载荷透传")
        checks.expectEqual(log.count, 2, "R4 宿主执行到工具")

        // 5) 参数不合法（缺必需属性）：拒绝且宿主零执行。
        let invalidResponse = await callTool(id: 12, name: "gmgn_submit_wish_generation", arguments: ["name": "x"])
        checks.expectEqual(isError(invalidResponse), true, "R5 非法参数 isError=true")
        checks.expectContains(textContent(invalidResponse), "invalid tool arguments", "R5 通用拒绝文本")
        checks.expectEqual(log.count, 2, "R5 非法参数零宿主执行")

        // 6) 未知工具（含内建 shell/read/write）：拒绝且宿主零执行。
        for (offset, name) in ["shell", "gmgn_shell", "read", "write", "gmgn_unknown_tool"].enumerated() {
            let response = await callTool(id: 20 + offset, name: name, arguments: [:])
            checks.expectEqual(isError(response), true, "R6 未知工具 \(name) isError=true")
            checks.expectContains(textContent(response), "unknown tool", "R6 未知工具 \(name) 通用文本")
        }
        checks.expectEqual(log.count, 2, "R6 未知工具零宿主执行")

        // 7) 参数不是对象：协议级 invalid params。
        try client.send([
            "jsonrpc": "2.0", "id": 30, "method": "tools/call",
            "params": ["name": "gmgn_read_wish_generation", "arguments": "not-an-object"],
        ])
        let wrongShapeRaw = await client.takeRaw(id: 30)
        let wrongShape = client.object(from: wrongShapeRaw)
        let wrongShapeError = wrongShape?["error"] as? [String: Any]
        checks.expectEqual((wrongShapeError?["code"] as? NSNumber)?.intValue, -32602, "R7 参数非对象 code=-32602")

        // 7a) JSON-RPC id 只允许字符串或有限整数：object/array/bool/null/非整数一律 -32600。
        let invalidIDs: [Any] = [[String: Any](), [1, 2], true, NSNull(), 1.5]
        for (offset, badID) in invalidIDs.enumerated() {
            try? client.sendRaw(ResidentClaudeMCPFixture.data([
                "jsonrpc": "2.0", "id": badID, "method": "ping",
            ]) + Data([0x0A]))
            let raw = await client.takeAnyRaw(timeout: 3)
            let object = client.object(from: raw)
            checks.expectEqual(errorCode(object), -32600, "R7a 非法 id 形态 #\(offset) code=-32600")
            checks.check(object?["result"] == nil, "R7a 非法 id 形态 #\(offset) 无 result")
        }

        // 7b) params 必须是对象（数组/字符串/null 拒绝）。
        let invalidParams: [Any] = [[], "not-an-object", NSNull()]
        for (offset, badParams) in invalidParams.enumerated() {
            let id = 100 + offset
            try? client.send([
                "jsonrpc": "2.0", "id": id, "method": "tools/call", "params": badParams,
            ])
            let object = client.object(from: await client.takeRaw(id: id))
            checks.expectEqual(errorCode(object), -32602, "R7b 非法 params 形态 #\(offset) code=-32602")
        }

        // 7c) arguments=null 必须拒绝（协议级 invalid params）且零宿主执行。
        let countBeforeNullArguments = log.count
        try? client.send([
            "jsonrpc": "2.0", "id": 110, "method": "tools/call",
            "params": ["name": "gmgn_read_wish_generation", "arguments": NSNull()],
        ])
        let nullArguments = client.object(from: await client.takeRaw(id: 110))
        checks.expectEqual(errorCode(nullArguments), -32602, "R7c arguments null code=-32602")
        checks.expectEqual(log.count, countBeforeNullArguments, "R7c arguments null 零宿主执行")

        // 7d) 合法 id（字符串 / 整数）继续服务。
        try? client.send(["jsonrpc": "2.0", "id": "string-id", "method": "ping"])
        checks.check(
            client.object(from: await client.takeRaw(stringID: "string-id"))?["result"] != nil,
            "R7d 字符串 id 合法"
        )
        try? client.send(["jsonrpc": "2.0", "id": 42, "method": "ping"])
        checks.check(client.object(from: await client.takeRaw(id: 42))?["result"] != nil, "R7d 整数 id 合法")

        // 8) 未知方法。
        try client.send(["jsonrpc": "2.0", "id": 31, "method": "resources/list"])
        let unknownMethodRaw = await client.takeRaw(id: 31)
        let unknownMethod = client.object(from: unknownMethodRaw)
        checks.expectEqual(((unknownMethod?["error"] as? [String: Any])?["code"] as? NSNumber)?.intValue, -32601, "R8 未知方法 code=-32601")

        // 9) 畸形 JSON：parse error 且 adapter 继续服务。
        try client.sendRaw(Data("{not-json".utf8) + Data([0x0A]))
        let malformedRaw = await client.takeRawUnsolicited()
        let malformed = client.object(from: malformedRaw)
        checks.expectEqual(((malformed?["error"] as? [String: Any])?["code"] as? NSNumber)?.intValue, -32700, "R9 畸形 JSON code=-32700")
        try client.send(["jsonrpc": "2.0", "id": 32, "method": "ping"])
        let malformedRecovery = await client.takeRaw(id: 32)
        checks.check(client.object(from: malformedRecovery)?["result"] != nil, "R9 畸形 JSON 后仍可服务")

        // 10) 超长输入：有界拒绝，进程不崩，随后恢复服务。
        let oversized = Data(repeating: 0x61, count: ResidentClaudeMCPAdapter.maximumRequestBytes + 4096)
        try client.sendRaw(oversized)
        try client.sendRaw(Data([0x0A]))
        let tooLargeRaw = await client.takeRawUnsolicited(timeout: 5)
        let tooLarge = client.object(from: tooLargeRaw)
        checks.expectEqual(((tooLarge?["error"] as? [String: Any])?["code"] as? NSNumber)?.intValue, -32700, "R10 超长输入被有界拒绝")
        try client.send(["jsonrpc": "2.0", "id": 33, "method": "ping"])
        let oversizedRecovery = await client.takeRaw(id: 33)
        checks.check(client.object(from: oversizedRecovery)?["result"] != nil, "R10 超长输入后仍可服务")

        // 11) 图片结果：imagePNGData → MCP image content。
        let imageResponse = await callTool(id: 40, name: "gmgn_capture_view", arguments: [:])
        checks.expectEqual(isError(imageResponse), false, "R11 图片调用 isError=false")
        let imageContent = (imageResponse?["result"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        let imageItem = imageContent.first { $0["type"] as? String == "image" }
        checks.expectEqual(imageItem?["mimeType"] as? String, "image/png", "R11 图片 mimeType")
        checks.expectEqual(imageItem?["data"] as? String, ResidentClaudeMCPFixture.imagePNG.base64EncodedString(), "R11 图片 base64")

        // 12) 超大工具结果：响应有界并按文本截断。
        let bigResponse = await callTool(
            id: 41, name: "gmgn_submit_wish_generation",
            arguments: ["attachment_id": "a", "name": "big", "height_meters": 1.0]
        )
        checks.expectEqual(isError(bigResponse), false, "R12 大结果 isError=false")
        checks.expectContains(textContent(bigResponse), "[truncated]", "R12 大结果被截断")
        if let raw = bigResponse.flatMap({ try? JSONSerialization.data(withJSONObject: $0) }) {
            checks.check(raw.count <= ResidentClaudeMCPAdapter.maximumResponseBytes, "R12 响应有界")
        } else {
            checks.check(false, "R12 响应无法测量")
        }

        // 13) 取消 grant：adapter 每次重读 grant → 拒绝；宿主零执行。
        let countBeforeCancel = log.count
        session.revoke()
        checks.check(!FileManager.default.fileExists(atPath: session.grantFileURL.path), "R13 revoke 删除 grant")
        let cancelledResponse = await callTool(id: 50, name: "gmgn_read_wish_generation", arguments: [:])
        checks.expectEqual(isError(cancelledResponse), true, "R13 取消后 isError=true")
        checks.expectContains(textContent(cancelledResponse), "not authorized", "R13 取消后通用拒绝文本")
        checks.expectEqual(log.count, countBeforeCancel, "R13 取消后零宿主执行")

        // 14) 重新 arm：已在运行的旧 adapter 进程钉住的是初始 grant 身份（secret/round），
        //     绝不重读新 secret 复活；只有重新 spawn 的 adapter 进程获得新授权。
        try session.arm(worldRevision: 2, deadline: Date().addingTimeInterval(600))
        let staleResponse = await callTool(id: 51, name: "gmgn_read_wish_generation", arguments: [:])
        checks.expectEqual(isError(staleResponse), true, "R14 旧 adapter re-arm 后 isError=true")
        checks.expectContains(textContent(staleResponse), "not authorized", "R14 旧 adapter 不借新授权复活")
        checks.expectEqual(log.count, countBeforeCancel, "R14 旧 adapter re-arm 后零宿主执行")

        let rearmedClient = try ResidentClaudeMCPStdioClient(
            executableURL: nodeExecutable,
            arguments: [session.adapterFileURL.path],
            cwd: session.directoryURL
        )
        defer { rearmedClient.terminate() }
        try rearmedClient.send([
            "jsonrpc": "2.0", "id": 52, "method": "tools/call",
            "params": ["name": "gmgn_read_wish_generation", "arguments": [:]],
        ])
        let rearmedRaw = await rearmedClient.takeRaw(id: 52)
        let rearmedResponse = rearmedClient.object(from: rearmedRaw)
        checks.expectEqual(isError(rearmedResponse), false, "R14 新 spawn adapter 可调用")
        checks.expectContains(textContent(rearmedResponse), "wish_id", "R14 新 spawn adapter 结果透传")
        checks.expectEqual(log.count, countBeforeCancel + 1, "R14 新 spawn adapter 宿主执行一次")

        // 14b) 同毫秒批量并发调用：callId 必须两两唯一（randomUUID，不用 Date.now）。
        let batchIDs = [70, 71, 72, 73]
        for id in batchIDs {
            try? rearmedClient.send([
                "jsonrpc": "2.0", "id": id, "method": "tools/call",
                "params": ["name": "gmgn_read_wish_generation", "arguments": [:]],
            ])
        }
        var batchOK = 0
        for id in batchIDs {
            let raw = await rearmedClient.takeRaw(id: id)
            if isError(rearmedClient.object(from: raw)) == false { batchOK += 1 }
        }
        checks.expectEqual(batchOK, 4, "R14b 同毫秒批量调用全部成功")
        let batchCallIDs = Array(log.callIDs.suffix(4))
        checks.expectEqual(batchCallIDs.count, 4, "R14b 宿主收到四个 callId")
        checks.expectEqual(Set(batchCallIDs).count, 4, "R14b 同毫秒批量 callId 两两唯一")

        // 15) 过期：重新 spawn 的 adapter 钉住已过期 grant → adapter 侧拒绝；
        //     宿主侧（绕过 adapter 直连）同样拒绝。
        try session.arm(worldRevision: 3, deadline: Date().addingTimeInterval(-5))
        checks.check(session.isExpired, "R15 会话已过期")
        let countBeforeExpiry = log.count
        let expiredClient = try ResidentClaudeMCPStdioClient(
            executableURL: nodeExecutable,
            arguments: [session.adapterFileURL.path],
            cwd: session.directoryURL
        )
        defer { expiredClient.terminate() }
        try expiredClient.send([
            "jsonrpc": "2.0", "id": 60, "method": "tools/call",
            "params": ["name": "gmgn_read_wish_generation", "arguments": [:]],
        ])
        let expiredRaw = await expiredClient.takeRaw(id: 60)
        let expiredResponse = expiredClient.object(from: expiredRaw)
        checks.expectEqual(isError(expiredResponse), true, "R15 adapter 侧过期拒绝")
        checks.expectContains(textContent(expiredResponse), "expired", "R15 过期通用文本")
        let grantObject = ResidentClaudeMCPFixture.object(try Data(contentsOf: session.grantFileURL))
        let secret = grantObject?["secret"] as? String ?? ""
        let rpcURL = (grantObject?["endpoint"] as? [String: Any])?["url"] as? String ?? ""
        let directFrame = await residentClaudeMCPHTTPFrameAsync(
            rpcURL: rpcURL, secret: secret,
            name: "gmgn_read_wish_generation", arguments: [:]
        )
        let direct = directFrame.flatMap {
            (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
        }
        checks.expectEqual(direct?["ok"] as? Bool, false, "R15 宿主侧绕过 adapter 亦拒绝过期")
        checks.expectEqual(
            (direct?["error"] as? [String: Any])?["code"] as? String,
            "tool_error",
            "R15 宿主侧过期经通道包装为工具错误"
        )
        checks.expectEqual(
            ((direct?["data"] as? [String: Any])?["error"] as? [String: Any])?["code"] as? String,
            "tool_session_expired",
            "R15 宿主侧过期错误码"
        )
        checks.expectEqual(log.count, countBeforeExpiry, "R15 过期后零宿主执行")

        // 16) 错误/响应不泄露路径、secret、异常（覆盖全部 adapter 进程）。
        let corpus = client.receivedLines + rearmedClient.receivedLines + expiredClient.receivedLines
        let grantText = (try? String(contentsOf: session.grantFileURL, encoding: .utf8)) ?? ""
        let secrets = [
            initialSecret, secret,
            session.rpcURL, session.directoryURL.path,
            session.grantFileURL.path, session.adapterFileURL.path,
        ]
        for candidate in secrets where !candidate.isEmpty {
            checks.check(!corpus.contains { $0.contains(candidate) }, "R16 响应不包含 \(candidate.prefix(24))…")
        }
        checks.check(!corpus.contains { $0.contains("/Users/") }, "R16 响应不含本机路径")
        checks.check(!corpus.contains { $0.lowercased().contains("enoent") || $0.contains("Error:") }, "R16 响应不含异常细节")
        checks.check(grantText.isEmpty || !corpus.contains { $0.contains(grantText) }, "R16 响应不含 grant 全文")
        let allStderr = client.stderrText + rearmedClient.stderrText + expiredClient.stderrText
        checks.check(!allStderr.contains(secret) || secret.isEmpty, "R16 stderr 不含 secret")

        // 17) 33 个正式工具：tools/list 逐条来自正式 schema，无任何内建/额外工具。
        do {
            let wideWork = FileManager.default.temporaryDirectory
                .appendingPathComponent("gmgn-claude-mcp-wide-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: wideWork, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: wideWork) }
            let wideRegistrations = try ResidentDSHHostToolSet.parse(
                schemasJSON: ResidentClaudeMCPFixture.thirtyThreeSchemas
            )
            checks.expectEqual(wideRegistrations.count, 33, "R17 正式 schema 解析出 33 个工具")
            let wideSource = try ResidentClaudeMCPAdapter.source(registrations: wideRegistrations)
            let wideAdapter = wideWork.appendingPathComponent(ResidentClaudeMCPAdapter.filename)
            try Data(wideSource.utf8).write(to: wideAdapter, options: [.atomic])
            let wideClient = try ResidentClaudeMCPStdioClient(
                executableURL: nodeExecutable, arguments: [wideAdapter.path], cwd: wideWork
            )
            defer { wideClient.terminate() }
            try wideClient.send(["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
            let wideRaw = await wideClient.takeRaw(id: 1)
            let wideObject = wideClient.object(from: wideRaw)
            let wideTools = (wideObject?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
            checks.expectEqual(wideTools.count, 33, "R17 tools/list 恰好 33 个正式工具")
            let wideNames = Set(wideTools.compactMap { $0["name"] as? String })
            let expectedNames = Set((0..<33).map { "gmgn_world_tool_\($0)" })
            checks.expectEqual(wideNames, expectedNames, "R17 名字精确来自正式 schema")
            for forbidden in ["shell", "bash", "read", "write", "edit", "exec"] {
                checks.check(
                    !wideNames.contains(forbidden) && !wideNames.contains("gmgn_" + forbidden),
                    "R17 未注册受限工具 \(forbidden)"
                )
            }
            // 33 个工具的放行清单也必须逐项精确，绝不退化成 server 级宽泛放行。
            let wideAllowedNames = ResidentClaudeMCPAdapter.allowedToolNames(
                registrations: wideRegistrations
            )
            checks.expectEqual(wideAllowedNames.count, 33, "R17 allowedToolNames 33 项")
            checks.expectEqual(
                Set(wideAllowedNames),
                Set((0..<33).map { "mcp__\(ResidentClaudeMCPAdapter.serverName)__gmgn_world_tool_\($0)" }),
                "R17 allowedToolNames 逐项精确"
            )
            checks.check(
                !wideAllowedNames.contains("mcp__\(ResidentClaudeMCPAdapter.serverName)"),
                "R17 无宽泛 server 放行"
            )
        }

        // 18) grant 重读必须大小有界；expiresAt 必须存在且为有限数 —— 全部 fail-closed。
        do {
            let probeLog = ResidentClaudeMCPCallLog()
            let probeSession = try ResidentClaudeMCPHostSession.start(
                configuration: ResidentClaudeMCPHostSession.Configuration(
                    scope: "world.cabin", worldID: "cabin-probe",
                    registrations: registrations,
                    handler: residentClaudeMCPHandler(log: probeLog),
                    nodeExecutable: nodeExecutable
                ),
                deadline: Date().addingTimeInterval(600)
            )
            defer { probeSession.stop() }
            let probeGrant = ResidentClaudeMCPFixture.object(try Data(contentsOf: probeSession.grantFileURL))
            let probeSecret = probeGrant?["secret"] as? String ?? ""
            let probeRound = probeGrant?["round"] as? String ?? ""
            let probeRPCURL = (probeGrant?["endpoint"] as? [String: Any])?["url"] as? String ?? ""
            checks.check(!probeSecret.isEmpty && !probeRound.isEmpty && !probeRPCURL.isEmpty, "R18 probe grant 完整")

            let futureExpiry = "\(Int64((Date().addingTimeInterval(120).timeIntervalSince1970 * 1000).rounded()))"

            func probeCall(
                label: String,
                grantJSON: String,
                expectError: Bool,
                expectedText: String
            ) async throws {
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("gmgn-claude-mcp-probe-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let (probeClient, _) = try residentClaudeMCPStandaloneAdapter(
                    in: directory, nodeExecutable: nodeExecutable,
                    registrations: registrations, grantJSON: grantJSON
                )
                defer { probeClient.terminate() }
                let before = probeLog.count
                try? probeClient.send([
                    "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                    "params": ["name": "gmgn_read_wish_generation", "arguments": [:]],
                ])
                let response = probeClient.object(from: await probeClient.takeRaw(id: 1))
                checks.expectEqual(isError(response), expectError, "\(label) isError")
                checks.expectContains(textContent(response), expectedText, "\(label) 固定文本")
                checks.expectEqual(probeLog.count - before, expectError ? 0 : 1, "\(label) 宿主执行次数")
            }

            try await probeCall(
                label: "R18 合法 future expiresAt",
                grantJSON: residentClaudeMCPCraftedGrant(
                    secret: probeSecret, round: probeRound, rpcURL: probeRPCURL,
                    declaredName: "gmgn_read_wish_generation", expiresAtLiteral: futureExpiry
                ),
                expectError: false, expectedText: "wish_id"
            )
            let validEndpointGrant = residentClaudeMCPCraftedGrant(
                secret: probeSecret, round: probeRound, rpcURL: probeRPCURL,
                declaredName: "gmgn_read_wish_generation", expiresAtLiteral: futureExpiry
            )
            for (label, invalidGrant) in [
                ("非 loopback", validEndpointGrant.replacingOccurrences(of: "127.0.0.1:", with: "192.0.2.1:")),
                ("旧传输协议版本", validEndpointGrant.replacingOccurrences(of: "\"version\":2", with: "\"version\":1")),
                ("HTTPS", validEndpointGrant.replacingOccurrences(of: "http://", with: "https://")),
                ("凭据 URL", validEndpointGrant.replacingOccurrences(of: "http://", with: "http://user:password@")),
                ("其他路由", validEndpointGrant.replacingOccurrences(of: "/rpc", with: "/other")),
                ("查询参数", validEndpointGrant.replacingOccurrences(of: "/rpc", with: "/rpc?token=invalid")),
                ("鉴权不匹配", validEndpointGrant.replacingOccurrences(of: "\"token\":\"\(probeSecret)\"", with: "\"token\":\"\(UUID().uuidString.lowercased())\"")),
            ] {
                try await probeCall(label: "R18 endpoint \(label)", grantJSON: invalidGrant,
                                    expectError: true, expectedText: "tool bridge unavailable")
            }
            for (offset, literal) in [nil, "\"soon\"", "1e999", "null", "true"].enumerated() {
                try await probeCall(
                    label: "R18 非法 expiresAt #\(offset)",
                    grantJSON: residentClaudeMCPCraftedGrant(
                        secret: probeSecret, round: probeRound, rpcURL: probeRPCURL,
                        declaredName: "gmgn_read_wish_generation", expiresAtLiteral: literal
                    ),
                    expectError: true, expectedText: "not authorized"
                )
            }

            // 大小有界：先以合法 grant 启动（钉住身份），再重读一个超上界的合法 grant。
            let sizeDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("gmgn-claude-mcp-size-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: sizeDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: sizeDirectory) }
            let (sizeClient, sizeGrantURL) = try residentClaudeMCPStandaloneAdapter(
                in: sizeDirectory, nodeExecutable: nodeExecutable, registrations: registrations,
                grantJSON: residentClaudeMCPCraftedGrant(
                    secret: probeSecret, round: probeRound, rpcURL: probeRPCURL,
                    declaredName: "gmgn_read_wish_generation", expiresAtLiteral: futureExpiry
                )
            )
            defer { sizeClient.terminate() }
            try? sizeClient.send([
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": "gmgn_read_wish_generation", "arguments": [:]],
            ])
            checks.expectEqual(
                isError(sizeClient.object(from: await sizeClient.takeRaw(id: 1))), false,
                "R18 大小上界对照调用成功"
            )
            let afterControl = probeLog.count
            let oversizedGrant = residentClaudeMCPCraftedGrant(
                secret: probeSecret, round: probeRound, rpcURL: probeRPCURL,
                declaredName: "gmgn_read_wish_generation", expiresAtLiteral: futureExpiry,
                paddingBytes: ResidentClaudeMCPAdapter.maximumGrantBytes * 2
            )
            try Data(oversizedGrant.utf8).write(to: sizeGrantURL, options: [.atomic])
            try? sizeClient.send([
                "jsonrpc": "2.0", "id": 2, "method": "tools/call",
                "params": ["name": "gmgn_read_wish_generation", "arguments": [:]],
            ])
            let oversizedResponse = sizeClient.object(from: await sizeClient.takeRaw(id: 2))
            checks.expectEqual(isError(oversizedResponse), true, "R18 超上界 grant 拒绝")
            checks.expectContains(textContent(oversizedResponse), "not authorized", "R18 超上界 grant 固定文本")
            checks.expectEqual(probeLog.count, afterControl, "R18 超上界 grant 零宿主执行")
        }

        // 19) stdio tools/call 并发有界（上限 4）：超量请求得到固定 busy 错误，
        //     不建立无界 Promise/连接；宿主最多执行 4 次。
        do {
            let slowLog = ResidentClaudeMCPCallLog()
            let slowSession = try ResidentClaudeMCPHostSession.start(
                configuration: ResidentClaudeMCPHostSession.Configuration(
                    scope: "world.cabin", worldID: "cabin-slow",
                    registrations: registrations,
                    handler: { request in
                        slowLog.append(
                            request.canonicalName, callID: request.callID,
                            argumentsJSON: request.argumentsJSON
                        )
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        return ResidentDSHHostToolReply(
                            resultJSON: ResidentClaudeMCPFixture.data(["ok": true, "marker": "slow"]),
                            isError: false
                        )
                    },
                    nodeExecutable: nodeExecutable
                ),
                deadline: Date().addingTimeInterval(600)
            )
            defer { slowSession.stop() }
            let slowClient = try ResidentClaudeMCPStdioClient(
                executableURL: nodeExecutable,
                arguments: [slowSession.adapterFileURL.path],
                cwd: slowSession.directoryURL
            )
            defer { slowClient.terminate() }
            let concurrencyIDs = Array(300..<306)
            for id in concurrencyIDs {
                try? slowClient.send([
                    "jsonrpc": "2.0", "id": id, "method": "tools/call",
                    "params": ["name": "gmgn_read_wish_generation", "arguments": [:]],
                ])
            }
            var successes = 0
            var busy = 0
            for id in concurrencyIDs {
                let response = slowClient.object(from: await slowClient.takeRaw(id: id))
                if isError(response) == false, textContent(response).contains("slow") { successes += 1 }
                if isError(response) == true, textContent(response).contains("tool bridge busy") { busy += 1 }
            }
            checks.expectEqual(successes, 4, "R19 并发上限内 4 次成功")
            checks.expectEqual(busy, 2, "R19 超量 2 次固定 busy 错误")
            checks.expectEqual(slowLog.count, 4, "R19 宿主最多执行 4 次")
        }

        // 20) 回包前复核：工具回包后若授权被撤销/轮换/过期，迟到的结果绝不回给模型。
        do {
            let lateLog = ResidentClaudeMCPCallLog()
            let lateStarted = ResidentClaudeMCPFlag()
            let lateMarker = "late-payload-must-not-arrive"
            let lateSession = try ResidentClaudeMCPHostSession.start(
                configuration: ResidentClaudeMCPHostSession.Configuration(
                    scope: "world.cabin", worldID: "cabin-late",
                    registrations: registrations,
                    handler: { request in
                        lateLog.append(
                            request.canonicalName, callID: request.callID,
                            argumentsJSON: request.argumentsJSON
                        )
                        lateStarted.set()
                        try? await Task.sleep(nanoseconds: 700_000_000)
                        return ResidentDSHHostToolReply(
                            resultJSON: ResidentClaudeMCPFixture.data([
                                "ok": true, "marker": lateMarker,
                            ]),
                            isError: false
                        )
                    },
                    nodeExecutable: nodeExecutable
                ),
                deadline: Date().addingTimeInterval(600)
            )
            defer { lateSession.stop() }
            let lateClient = try ResidentClaudeMCPStdioClient(
                executableURL: nodeExecutable,
                arguments: [lateSession.adapterFileURL.path],
                cwd: lateSession.directoryURL
            )
            defer { lateClient.terminate() }
            try? lateClient.send([
                "jsonrpc": "2.0", "id": 400, "method": "tools/call",
                "params": ["name": "gmgn_read_wish_generation", "arguments": [:]],
            ])
            // 等 handler 真正开始后再撤销：确保覆盖的是「回包前」撤权，而非执行前拒绝。
            var waited = 0
            while !lateStarted.isSet && waited < 250 {
                try? await Task.sleep(nanoseconds: 20_000_000)
                waited += 1
            }
            checks.check(lateStarted.isSet, "R20 延迟 handler 已开始")
            lateSession.revoke()
            let lateResponse = lateClient.object(from: await lateClient.takeRaw(id: 400))
            checks.expectEqual(isError(lateResponse), true, "R20 撤权后迟到结果不回给模型")
            checks.expectContains(textContent(lateResponse), "not authorized", "R20 迟到结果固定拒绝文本")
            checks.check(
                !textContent(lateResponse).contains(lateMarker),
                "R20 迟到结果载荷不泄露给模型"
            )
            checks.expectEqual(lateLog.count, 1, "R20 副作用已发生一次，仅回包被拦")
        }

        print("\(checks.result ? "PASS" : "FAIL"): \(checks.passed) resident-claude MCP bridge checks, \(checks.failures.count) failures")
        exit(checks.result ? 0 : 1)
    }
}

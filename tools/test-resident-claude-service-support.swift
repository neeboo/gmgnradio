//
//  test-resident-claude-service-support.swift
//  GMGNRadio（仅测试；不进 App）
//
//  AgentConversationService `.claudeCode` 安全分支 + ResidentClaudeProcessRunner 的
//  离线端到端夹具（纯 CPU；无真实 Claude 模型、无网络、无 Keychain、无 AppleScript、
//  无 UI、无宿主启动、无 xcodebuild）。真实执行链：
//
//    假 claude 可执行脚本（读 argv/env/cwd/stdin，解析 --mcp-config）
//      → 真 node adapter（生产 ResidentClaudeMCPAdapter 源码）
//      → 真 UDS（生产 ResidentDSHHostToolsChannel）
//      → Swift worldTools.call handler
//      → MCP result 回假 CLI
//      → 假 CLI 生成 JSON result 回 Service
//
//  fixture 使用与 ResidentWorldToolSession.toolSchemasJSON **同形**的 33 工具
//  schema（[{name,description,inputSchema}]）。它不重新编译 WorldRuntime /
//  WorldAgentToolContract，因此这里验证的是生产同形 fixture 的 33 条原样透传，
//  不是 WorldAgentToolContract 的 33 全验收。
//
import Foundation
import Darwin

// MARK: - Checks

struct ResidentClaudeServiceChecks {
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

// MARK: - Fixture

enum ResidentClaudeServiceFixture {
    static let apiKey = "sk-ant-test-KEY-DO-NOT-LEAK-0123456789"
    static let injectedNodeOptions = "--require /tmp/gmgn-injected.js"
    static let injectedNodePath = "/tmp/gmgn-injected-node-path"
    static let injectedClaudeCodeEntrypoint = "gmgn-injected-entrypoint"
    static let injectedClaudeConfigDir = "/tmp/gmgn-injected-claude-config"

    static func data(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data("null".utf8)
    }

    static func canonicalJSON(_ value: Any) -> Data? {
        guard JSONSerialization.isValidJSONObject(value) else { return nil }
        return try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    /// 与 ResidentWorldToolSession.toolSchemasJSON 同形的 33 工具（生产同形 fixture）。
    static let schemas: Data = {
        var entries: [[String: Any]] = []
        for index in 0..<33 {
            entries.append([
                "name": "world_tool_\(index)",
                "description": "居民世界工具 \(index)",
                "inputSchema": [
                    "type": "object",
                    "properties": ["value": ["type": "string", "description": "参数 \(index)"]],
                    "required": [],
                    "additionalProperties": false,
                ],
            ])
        }
        return data(entries)
    }()

    /// 33 条生产同形 schema 对应的 MCP tools 数组（declaredName = gmgn_ + canonical）。
    static var expectedMCPTools: [[String: Any]] {
        guard let entries = (try? JSONSerialization.jsonObject(with: schemas)) as? [[String: Any]] else {
            return []
        }
        return entries.map { entry in
            [
                "name": "gmgn_" + (entry["name"] as? String ?? ""),
                "description": entry["description"] as? String ?? "",
                "inputSchema": entry["inputSchema"] as? [String: Any] ?? [:],
            ]
        }
    }

    static var expectedAllowedToolNames: [String] {
        ((try? JSONSerialization.jsonObject(with: schemas)) as? [[String: Any]] ?? [])
            .compactMap { $0["name"] as? String }
            .map { "mcp__gmgn-resident-tools__gmgn_" + $0 }
    }

    // MARK: Fake claude executable

    struct FakeClaude {
        let executableURL: URL
        let scriptURL: URL
        let recordPath: String
        var livePath: String { recordPath + ".live" }
    }

    enum Mode: String {
        case chat
        case tool
        case empty
        case fail
        case sleep
    }

    /// 专用 runner 行为夹具模式（真实 node 进程）：
    /// stdout/stderr 有界或持续超量、忽略 SIGTERM、静默成功。
    enum RunnerMode: String {
        case stdoutBounded
        case stdoutSustained
        case stderrBounded
        /// 小体量正常 stderr（低于上界）+ 正常 stdout，必须成功。
        case stderrNormal
        /// 有界 stderr 超量但由继承 stderr 的脱离孙进程在直接子进程被 reap **之后**
        /// 才写出：复现 stdout 已 settle 而 stderr overflow 回调晚到的竞态。
        case stderrAfterExit
        case stderrSustained
        case ignoreTERM
        /// 派生一个**脱离且忽略 SIGTERM**的后代进程，让它继承并持续持有 stdout/stderr
        /// 写端；直接子进程自身也忽略 SIGTERM 长驻。用于复现“直接子进程被 reap 后
        /// 管道仍无 EOF”的场景：停止（cancel/timeout）必须仍有界返回并回收直接子进程。
        case descendantHold
        case quiet
    }

    struct FakeRunnerProcess {
        let executableURL: URL
        let scriptURL: URL
        let pidPath: String

        /// `descendantHold` 后代自行写入的 PID 文件（仅 fixture 自己创建的后代）。
        var descendantPIDPath: String { pidPath + ".descendant" }
        /// 测试专属排空哨兵：出现后后代才开始读 stdin 到 EOF 并写报告。
        var stdinDrainSentinelPath: String { pidPath + ".drain" }
        /// 后代 stdin 排空报告（`{bytes, eof}`）；生产无任何测试钩子。
        var stdinDrainReportPath: String { pidPath + ".drain.json" }
    }

    /// 生成一个**真实可执行**的假 claude：shell launcher + node 逻辑脚本。
    /// 记录 argv/env/cwd/stdin 与 MCP 交互结果到 recordPath，供测试断言。
    @discardableResult
    static func writeFakeClaude(
        in directory: URL,
        name: String,
        nodePath: String,
        recordDirectory: URL,
        mode: Mode,
        reply: String = "聊天回复",
        sessionID: String = "fake-session-must-not-be-saved",
        toolName: String = "",
        toolArguments: [String: Any] = [:],
        delayMilliseconds: Int = 0,
        exitCode: Int32 = 0,
        stderrText: String = "",
        rawOutput: String? = nil
    ) throws -> FakeClaude {
        let fileManager = FileManager.default
        let recordURL = recordDirectory.appendingPathComponent("record-\(name).json")
        let scriptURL = directory.appendingPathComponent("fake-claude-\(name).mjs")
        let launcherURL = directory.appendingPathComponent("claude-\(name)")

        var source = scriptTemplate
        let tokens: [(String, String)] = [
            ("__RECORD_PATH__", jsLiteral(recordURL.path)),
            ("__MODE__", jsLiteral(mode.rawValue)),
            ("__REPLY__", jsLiteral(reply)),
            ("__SESSION_ID__", jsLiteral(sessionID)),
            ("__TOOL_NAME__", jsLiteral(toolName)),
            ("__TOOL_ARGS__", jsLiteral(toolArguments)),
            ("__DELAY_MS__", String(delayMilliseconds)),
            ("__EXIT_CODE__", String(exitCode)),
            ("__STDERR_TEXT__", jsLiteral(stderrText)),
            ("__RAW_OUTPUT__", rawOutput.map(jsLiteral) ?? "null"),
        ]
        for (token, value) in tokens {
            source = source.replacingOccurrences(of: token, with: value)
        }
        try Data(source.utf8).write(to: scriptURL, options: [.atomic])
        let launcher = """
        #!/bin/sh
        exec \(shellQuote(nodePath)) \(shellQuote(scriptURL.path)) "$@"
        """
        try Data((launcher + "\n").utf8).write(to: launcherURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcherURL.path)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: scriptURL.path)
        return FakeClaude(executableURL: launcherURL, scriptURL: scriptURL, recordPath: recordURL.path)
    }

    static func readRecord(_ path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return object as? [String: Any]
    }

    /// 进程运行中持续更新的 live 记录（pid / adapterPid / mcpConfigPath）。
    /// 记录文件在进程结束时才写，取消/替代场景读不到；live 文件保证在途可观测。
    static func readLive(_ recordPath: String) -> [String: Any]? {
        readRecord(recordPath + ".live")
    }

    static func readPIDFile(_ path: String) -> pid_t? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return value
    }

    // MARK: JS literal helpers

    static func jsLiteral(_ value: Any) -> String {
        guard let data = canonicalJSON([value]),
              var text = String(data: data, encoding: .utf8) else { return "null" }
        text.removeFirst()
        text.removeLast()
        return text
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Node resolution

    static func resolveNodePath() -> String? {
        let fileManager = FileManager.default
        for candidate in ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }
        let environment = ProcessInfo.processInfo.environment
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = String(directory) + "/node"
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    // MARK: Fake claude node script

    static let scriptTemplate = #"""
    import fs from 'node:fs'
    import { spawn } from 'node:child_process'

    const RECORD_PATH = __RECORD_PATH__
    const LIVE_PATH = RECORD_PATH + '.live'
    const MODE = __MODE__
    const REPLY = __REPLY__
    const SESSION_ID = __SESSION_ID__
    const TOOL_NAME = __TOOL_NAME__
    const TOOL_ARGS = __TOOL_ARGS__
    const DELAY_MS = __DELAY_MS__
    const EXIT_CODE = __EXIT_CODE__
    const STDERR_TEXT = __STDERR_TEXT__
    const RAW_OUTPUT = __RAW_OUTPUT__

    function writeLive(extra) {
      try {
        fs.writeFileSync(LIVE_PATH, JSON.stringify(Object.assign({ pid: process.pid }, extra || {})))
      } catch (_) {}
    }
    writeLive()

    function readStdin() {
      return new Promise((resolve) => {
        let data = ''
        process.stdin.setEncoding('utf8')
        process.stdin.on('data', (chunk) => { data += chunk })
        process.stdin.on('end', () => resolve(data))
        process.stdin.on('error', () => resolve(data))
      })
    }

    function mcpRequest(child, id, method, params) {
      return new Promise((resolve) => {
        let buffer = ''
        const onData = (chunk) => {
          buffer += chunk
          let index
          while ((index = buffer.indexOf('\n')) >= 0) {
            const line = buffer.slice(0, index)
            buffer = buffer.slice(index + 1)
            let message = null
            try { message = JSON.parse(line) } catch (_) { continue }
            if (message && message.id === id) {
              child.stdout.off('data', onData)
              resolve(message)
              return
            }
          }
        }
        child.stdout.on('data', onData)
        child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: id, method: method, params: params }) + '\n')
      })
    }

    function sleep(ms) { return new Promise((resolve) => setTimeout(resolve, ms)) }

    async function main() {
      const argv = process.argv.slice(2)
      const stdin = await readStdin()
      const record = {
        argv: argv,
        stdin: stdin,
        cwd: process.cwd(),
        env: Object.assign({}, process.env),
        cwdMode: null,
        toolsListed: null,
        toolCallResult: null,
        mcpConfigText: null,
        adapterExited: null,
        toolError: null,
        startedAt: Date.now()
      }
      try { record.cwdMode = fs.statSync(process.cwd()).mode & 0o777 } catch (_) {}
      if (DELAY_MS > 0) { await sleep(DELAY_MS) }
      let reply = REPLY
      try {
        const index = argv.indexOf('--mcp-config')
        const configPath = index >= 0 ? argv[index + 1] : null
        if (configPath) {
          writeLive({ mcpConfigPath: configPath })
          record.mcpConfigText = fs.readFileSync(configPath, 'utf8')
          const config = JSON.parse(record.mcpConfigText)
          const servers = config && config.mcpServers ? config.mcpServers : {}
          const names = Object.keys(servers)
          if (MODE === 'tool' && names.length > 0) {
            const server = servers[names[0]]
            const child = spawn(server.command, server.args, { stdio: ['pipe', 'pipe', 'pipe'] })
            writeLive({ mcpConfigPath: configPath, adapterPid: child.pid })
            let exited = false
            child.on('exit', () => { exited = true })
            await mcpRequest(child, 1, 'initialize', {
              protocolVersion: '2024-11-05', capabilities: {},
              clientInfo: { name: 'fake-claude', version: '1.0.0' }
            })
            record.toolsListed = await mcpRequest(child, 2, 'tools/list', {})
            record.toolCallResult = await mcpRequest(child, 3, 'tools/call', {
              name: TOOL_NAME, arguments: TOOL_ARGS
            })
            child.stdin.end()
            await sleep(250)
            record.adapterExited = exited
            if (!exited) { try { child.kill('SIGKILL') } catch (_) {} }
          }
        }
      } catch (error) {
        record.toolError = String(error)
      }
      if (MODE === 'tool' && record.toolCallResult) {
        reply = REPLY + JSON.stringify(record.toolCallResult)
      }
      try { fs.writeFileSync(RECORD_PATH, JSON.stringify(record)) } catch (_) {}
      if (STDERR_TEXT.length > 0) { process.stderr.write(STDERR_TEXT + '\n') }
      if (EXIT_CODE !== 0) { process.exit(EXIT_CODE) }
      if (RAW_OUTPUT !== null) {
        process.stdout.write(RAW_OUTPUT)
      } else {
        process.stdout.write(JSON.stringify({ result: reply, session_id: SESSION_ID }) + '\n')
      }
    }

    main()
    """#

    // MARK: Fake runner process (stdout/stderr bounds + SIGTERM behavior)

    /// 生成一个真实可执行的 node runner 夹具：启动即同步写 pid 文件，随后按模式
    /// 产出有界/持续 stdout 或 stderr，或忽略 SIGTERM 长驻。永远真实可被 reap。
    @discardableResult
    static func writeFakeRunnerProcess(
        in directory: URL,
        name: String,
        nodePath: String,
        mode: RunnerMode,
        bytes: Int,
        ignoreSIGTERM: Bool = false
    ) throws -> FakeRunnerProcess {
        let fileManager = FileManager.default
        let pidURL = directory.appendingPathComponent("runner-\(name).pid")
        let scriptURL = directory.appendingPathComponent("fake-runner-\(name).mjs")
        let launcherURL = directory.appendingPathComponent("runner-\(name)")

        var source = runnerScriptTemplate
        let tokens: [(String, String)] = [
            ("__PID_PATH__", jsLiteral(pidURL.path)),
            ("__MODE__", jsLiteral(mode.rawValue)),
            ("__BYTES__", String(max(0, bytes))),
            ("__IGNORE_SIGTERM__", ignoreSIGTERM ? "true" : "false"),
        ]
        for (token, value) in tokens {
            source = source.replacingOccurrences(of: token, with: value)
        }
        try Data(source.utf8).write(to: scriptURL, options: [.atomic])
        let launcher = """
        #!/bin/sh
        exec \(shellQuote(nodePath)) \(shellQuote(scriptURL.path)) "$@"
        """
        try Data((launcher + "\n").utf8).write(to: launcherURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcherURL.path)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: scriptURL.path)
        return FakeRunnerProcess(executableURL: launcherURL, scriptURL: scriptURL, pidPath: pidURL.path)
    }

    static let runnerScriptTemplate = #"""
    import fs from 'node:fs'
    import { spawn } from 'node:child_process'

    const PID_PATH = __PID_PATH__
    const MODE = __MODE__
    const BYTES = __BYTES__
    const IGNORE_SIGTERM = __IGNORE_SIGTERM__

    process.stdout.on('error', () => {})
    process.stderr.on('error', () => {})
    try { fs.writeFileSync(PID_PATH, String(process.pid)) } catch (_) {}
    if (IGNORE_SIGTERM) { process.on('SIGTERM', () => {}) }

    const CHUNK = 'x'.repeat(65536)
    function emit(stream, total) {
      let written = 0
      while (written < total) {
        const size = Math.min(CHUNK.length, total - written)
        try { stream.write(CHUNK.slice(0, size)) } catch (_) { break }
        written += size
      }
    }

    if (MODE === 'stdoutBounded') {
      emit(process.stdout, BYTES)
      process.stdout.write(JSON.stringify({ result: 'ok' }) + '\n')
    } else if (MODE === 'stderrBounded') {
      emit(process.stderr, BYTES)
      process.stdout.write(JSON.stringify({ result: 'ok' }) + '\n')
    } else if (MODE === 'stderrNormal') {
      emit(process.stderr, BYTES)
      process.stdout.write(JSON.stringify({ result: 'ok' }) + '\n')
    } else if (MODE === 'stderrAfterExit') {
      const grandchildSource = "const n=Number(process.env.GMGN_GRANDCHILD_BYTES||0);" +
        "const c='x'.repeat(65536);let w=0;" +
        "while(w<n){try{process.stderr.write(c.slice(0,Math.min(c.length,n-w)))}catch(_){break}w+=c.length}"
      const grandchild = spawn(process.execPath, ['-e', grandchildSource], {
        detached: true,
        stdio: ['ignore', 'ignore', 2],
        env: Object.assign({}, process.env, { GMGN_GRANDCHILD_BYTES: String(BYTES) })
      })
      grandchild.unref()
      process.stdout.write(JSON.stringify({ result: 'ok' }) + '\n')
    } else if (MODE === 'stdoutSustained') {
      setInterval(() => { try { process.stdout.write(CHUNK) } catch (_) {} }, 1)
    } else if (MODE === 'stderrSustained') {
      setInterval(() => { try { process.stderr.write(CHUNK) } catch (_) {} }, 1)
    } else if (MODE === 'descendantHold') {
      const descendantSource = [
        "const fs = require('node:fs')",
        "const pidPath = process.env.GMGN_DESCENDANT_PID_PATH",
        "const sentinelPath = process.env.GMGN_DESCENDANT_SENTINEL_PATH",
        "const reportPath = process.env.GMGN_DESCENDANT_REPORT_PATH",
        "try { fs.writeFileSync(pidPath, String(process.pid)) } catch (_) {}",
        "process.on('SIGTERM', () => {})",
        "function drain() {",
        "  let bytes = 0",
        "  process.stdin.on('data', (chunk) => { bytes += chunk.length })",
        "  process.stdin.on('end', () => { try { fs.writeFileSync(reportPath, JSON.stringify({ bytes: bytes, eof: true })) } catch (_) {} })",
        "  process.stdin.on('error', () => { try { fs.writeFileSync(reportPath, JSON.stringify({ bytes: bytes, eof: false })) } catch (_) {} })",
        "}",
        "const timer = setInterval(() => {",
        "  if (fs.existsSync(sentinelPath)) { clearInterval(timer); drain() }",
        "}, 10)",
        "setInterval(() => {}, 1000)"
      ].join(';')
      const descendant = spawn(process.execPath, ['-e', descendantSource], {
        detached: true,
        stdio: [0, 1, 2],
        env: Object.assign({}, process.env, {
          GMGN_DESCENDANT_PID_PATH: PID_PATH + '.descendant',
          GMGN_DESCENDANT_SENTINEL_PATH: PID_PATH + '.drain',
          GMGN_DESCENDANT_REPORT_PATH: PID_PATH + '.drain.json'
        })
      })
      descendant.unref()
      setInterval(() => {}, 1000)
    } else if (MODE === 'ignoreTERM') {
      setInterval(() => {}, 1000)
    } else {
      process.stdout.write(JSON.stringify({ result: 'ok' }) + '\n')
    }
    """#
}

// MARK: - Test doubles

struct ResidentClaudeServiceLocator: AgentExecutableLocating {
    let claude: URL?
    let node: URL?

    func locate(executableNames: [String]) -> URL? {
        for name in executableNames {
            switch name {
            case "claude": if let claude { return claude }
            case "node": if let node { return node }
            default: continue
            }
        }
        return nil
    }
}

final class ResidentClaudeSpawnCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class ResidentClaudeRunCapture: @unchecked Sendable {
    struct Entry {
        let environment: [String: String]
        let workingDirectory: URL
        let timeout: TimeInterval
    }

    private let lock = NSLock()
    private var storage: [Entry] = []

    func record(environment: [String: String], workingDirectory: URL, timeout: TimeInterval) {
        lock.lock()
        storage.append(Entry(environment: environment, workingDirectory: workingDirectory, timeout: timeout))
        lock.unlock()
    }

    var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var last: Entry? { entries.last }
}

final class ResidentClaudeToolCallLog: @unchecked Sendable {
    struct Entry {
        let callID: String
        let canonicalName: String
        let argumentsJSON: Data
    }

    private let lock = NSLock()
    private var storage: [Entry] = []

    func append(callID: String, canonicalName: String, argumentsJSON: Data) {
        lock.lock()
        storage.append(Entry(callID: callID, canonicalName: canonicalName, argumentsJSON: argumentsJSON))
        lock.unlock()
    }

    var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var count: Int { entries.count }
}

// MARK: - Memory fixture

/// 记忆 IPC fixture：立即回放 memory_recall/memory_ingest 并记录每笔请求。
/// 只做内存模拟，不启动 daemon、不落库。
@MainActor
final class ResidentClaudeMemoryTransport: ResidentStateTransport {
    private(set) var recorded: [(method: String, params: [String: ResidentStateJSON])] = []
    var recallContext = "这位居民喜欢在雨天听爵士乐。"

    func call(
        method: String,
        params: [String: ResidentStateJSON]
    ) async throws -> [String: ResidentStateJSON] {
        recorded.append((method, params))
        switch method {
        case "memory_recall":
            return [
                "status": .string("ok"), "revision": .number(0),
                "vectorGeneration": .number(0), "facts": .array([]),
                "notes": .array([]), "context": .string(recallContext),
                "pendingTurns": .number(0),
            ]
        case "memory_ingest":
            return [
                "accepted": .bool(true), "replayed": .bool(false),
                "pendingTurns": .number(0), "consolidation": .string("pending"),
            ]
        default:
            throw ResidentStateError.daemon("unsupported_method")
        }
    }

    func calls(_ method: String) -> [[String: ResidentStateJSON]] {
        recorded.filter { $0.method == method }.map(\.params)
    }
}

// MARK: - Shared helpers

func residentClaudeMakeDefaults(_ name: String) -> UserDefaults {
    let suite = "ResidentClaudeServiceTests-\(name)-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

func residentClaudeMakeWorld(_ id: String) -> ResidentWorldContext {
    ResidentWorldContext(
        selectedWorldID: id, worldID: id, displayName: "房间 \(id)", revision: 1,
        residentPosition: [0, 0, 0], activeActivity: nil, activityPhase: nil,
        objects: [], availableActivities: []
    )
}

func residentClaudeCheckCommonArguments(
    _ argv: [String],
    _ checks: inout ResidentClaudeServiceChecks,
    _ label: String
) {
    func value(after flag: String) -> String? {
        guard let index = argv.firstIndex(of: flag), index + 1 < argv.count else { return nil }
        return argv[index + 1]
    }
    checks.check(argv.first == "--bare", "\(label) 首参 --bare")
    checks.check(argv.contains("--print"), "\(label) --print")
    checks.expectEqual(value(after: "--output-format"), "json", "\(label) --output-format json")
    checks.check(argv.contains("--no-session-persistence"), "\(label) --no-session-persistence")
    checks.expectEqual(value(after: "--tools"), "", "\(label) --tools 空内置")
    checks.check(argv.contains("--strict-mcp-config"), "\(label) --strict-mcp-config")
    checks.check(argv.contains("--disable-slash-commands"), "\(label) --disable-slash-commands")
    checks.expectEqual(value(after: "--setting-sources"), "", "\(label) --setting-sources 空")
    checks.expectEqual(
        value(after: "--settings"), "{\"disableAllHooks\":true}", "\(label) --settings 禁 hooks"
    )
    checks.expectEqual(value(after: "--permission-mode"), "dontAsk", "\(label) --permission-mode dontAsk")
    checks.check(value(after: "--mcp-config")?.isEmpty == false, "\(label) 私有 --mcp-config")
    for forbidden in [
        "--resume", "--session-id", "--continue", "--fork-session",
        "--dangerously-skip-permissions", "--dangerously-bypass-approvals-and-sandbox",
        "bypassPermissions", "WebSearch", "WebFetch",
    ] {
        checks.check(!argv.contains(forbidden), "\(label) 无 \(forbidden)")
    }
    checks.check(!argv.contains(where: { $0.contains("mcp__gmgn-resident-tools") == false && $0.hasPrefix("mcp__") }) == true
        || argv.contains(where: { $0.hasPrefix("mcp__gmgn-resident-tools__") }),
        "\(label) mcp 放行名带受限前缀")
}

func residentClaudeWaitForRemoval(_ path: String, timeout: TimeInterval = 4) async -> Bool {
    guard !path.isEmpty else { return false }
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if !FileManager.default.fileExists(atPath: path) { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return !FileManager.default.fileExists(atPath: path)
}

/// 等待真实 pid 消失（已退出且被 reap，`kill(pid, 0)` 失败）。
func residentClaudeWaitForPIDExit(_ pid: pid_t, timeout: TimeInterval = 4) async -> Bool {
    guard pid > 0 else { return false }
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if kill(pid, 0) != 0 { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return kill(pid, 0) != 0
}

/// runner 任务的有界等待结果。watchdog 触发表示 runner 在缺陷实现下永不返回
/// （例如阻塞 read 等不到后代释放管道），测试因此有界失败而不是无限挂起。
struct ResidentClaudeBoundedRunOutcome {
    let result: CodexCommandResult?
    let error: Error?
    let timedOut: Bool
    let elapsed: TimeInterval
}

final class ResidentClaudeRunOutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Result<CodexCommandResult, Error>?

    func store(_ value: Result<CodexCommandResult, Error>) {
        lock.lock()
        storage = value
        lock.unlock()
    }

    var value: Result<CodexCommandResult, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// 有界等待一个 runner Task；watchdog 到点仍未 settle 则返回 `timedOut=true`，
/// 绝不无限挂起测试进程。RED 阶段据此把“永不返回”暴露为失败检查。
func residentClaudeAwaitBounded(
    _ task: Task<CodexCommandResult, Error>,
    watchdog: TimeInterval
) async -> ResidentClaudeBoundedRunOutcome {
    let box = ResidentClaudeRunOutcomeBox()
    let relay = Task {
        do { box.store(.success(try await task.value)) }
        catch { box.store(.failure(error)) }
    }
    let start = Date()
    var resolved: Result<CodexCommandResult, Error>?
    while Date().timeIntervalSince(start) < watchdog {
        if let value = box.value { resolved = value; break }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    relay.cancel()
    let elapsed = Date().timeIntervalSince(start)
    switch resolved {
    case .success(let value):
        return ResidentClaudeBoundedRunOutcome(result: value, error: nil, timedOut: false, elapsed: elapsed)
    case .failure(let error):
        return ResidentClaudeBoundedRunOutcome(result: nil, error: error, timedOut: false, elapsed: elapsed)
    case nil:
        return ResidentClaudeBoundedRunOutcome(result: nil, error: nil, timedOut: true, elapsed: elapsed)
    }
}

/// 在途工具 handler 的异步闸门：`wait()` 挂在 MainActor 上但不阻塞线程，
/// 测试可在 handler 真正在途时执行取消/替代，再 `open()` 释放。
actor ResidentClaudeGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation in
            if opened {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
        }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

// MARK: - End-to-end acceptance

@main
struct ResidentClaudeServiceAcceptance {
    @MainActor
    static func main() async throws {
        var checks = ResidentClaudeServiceChecks()
        let fixture = ResidentClaudeServiceFixture.self
        let fileManager = FileManager.default
        let work = fileManager.temporaryDirectory.appendingPathComponent(
            "gmgn-claude-service-\(UUID().uuidString)", isDirectory: true
        )
        let recordDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "gmgn-claude-records-\(UUID().uuidString)", isDirectory: true
        )
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.createDirectory(at: recordDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer {
            try? fileManager.removeItem(at: work)
            try? fileManager.removeItem(at: recordDirectory)
        }
        guard let nodePath = fixture.resolveNodePath() else {
            print("FAIL: 本机缺少 node，无法运行 Claude service 端到端验收")
            exit(1)
        }
        let nodeURL = URL(fileURLWithPath: nodePath)

        var baseEnvironment = ProcessInfo.processInfo.environment
        baseEnvironment["ANTHROPIC_API_KEY"] = fixture.apiKey
        baseEnvironment["NODE_OPTIONS"] = fixture.injectedNodeOptions
        baseEnvironment["NODE_PATH"] = fixture.injectedNodePath
        baseEnvironment["CLAUDE_CODE_ENTRYPOINT"] = fixture.injectedClaudeCodeEntrypoint
        baseEnvironment["CLAUDE_CONFIG_DIR"] = fixture.injectedClaudeConfigDir

        func makeService(
            claude: URL,
            defaults: UserDefaults,
            capture: ResidentClaudeRunCapture,
            spawns: ResidentClaudeSpawnCounter,
            environment: [String: String],
            turnTimeout: TimeInterval = 300
        ) -> AgentConversationService {
            AgentConversationService(
                locator: ResidentClaudeServiceLocator(claude: claude, node: nodeURL),
                defaults: defaults,
                claudeRunnerFactory: { executable, environment, workingDirectory, timeout in
                    capture.record(environment: environment, workingDirectory: workingDirectory, timeout: timeout)
                    spawns.increment()
                    return ResidentClaudeProcessRunner(
                        executableURL: executable, environment: environment,
                        workingDirectoryURL: workingDirectory, timeout: timeout
                    )
                },
                claudeEnvironmentProvider: { configDirectory in
                    ResidentClaudeEnvironment.make(base: environment, configDirectory: configDirectory)
                },
                claudeTurnTimeout: turnTimeout
            )
        }

        // 1) 纯聊天安全参数 / env 白名单 / 私有 cwd / key 不进 argv+config。
        let chatFake = try fixture.writeFakeClaude(
            in: work, name: "chat", nodePath: nodePath, recordDirectory: recordDirectory,
            mode: .chat, reply: "你好呀"
        )
        let chatCapture = ResidentClaudeRunCapture()
        let chatSpawns = ResidentClaudeSpawnCounter()
        let chatService = makeService(
            claude: chatFake.executableURL, defaults: residentClaudeMakeDefaults("chat"),
            capture: chatCapture, spawns: chatSpawns, environment: baseEnvironment
        )
        chatService.selectBackend(.claudeCode)
        checks.check(chatService.supportsWorldTools, "Claude Code supportsWorldTools = true")
        let chatWorld = residentClaudeMakeWorld("chat-room")
        let chatReply = try await chatService.send("早上好", worldContext: chatWorld)
        checks.expectEqual(chatReply, "你好呀", "纯聊天回复来自 JSON result")
        checks.expectEqual(chatSpawns.count, 1, "纯聊天 spawn 一次")
        checks.expectEqual(chatCapture.last?.timeout, 300, "runner 收到显式 timeout")
        let chatRecord = fixture.readRecord(chatFake.recordPath) ?? [:]
        let chatArgv = chatRecord["argv"] as? [String] ?? []
        residentClaudeCheckCommonArguments(chatArgv, &checks, "纯聊天")
        checks.check(!chatArgv.contains("--allowedTools"), "纯聊天不传 --allowedTools")
        checks.check(!chatArgv.contains(where: { $0.contains(fixture.apiKey) }), "key 不进 argv")
        checks.check(!chatArgv.contains(where: { $0.contains("早上好") }), "用户文字不进 argv")
        let chatStdin = chatRecord["stdin"] as? String ?? ""
        checks.check(chatStdin.contains("早上好"), "用户文字经 stdin 文本传入")
        checks.check(chatStdin.contains("用户消息"), "stdin 是组装后的居民轮次 prompt")
        checks.check(chatStdin.contains(ResidentPreferences.defaultPersona.components(separatedBy: "\n")[0]), "stdin 含当前人格")
        let chatEnvironment = chatRecord["env"] as? [String: String] ?? [:]
        checks.expectEqual(chatEnvironment["ANTHROPIC_API_KEY"], fixture.apiKey, "env 携带显式 API key")
        checks.expectEqual(chatEnvironment["HOME"], baseEnvironment["HOME"], "HOME 原值不变")
        checks.expectEqual(chatEnvironment["TMPDIR"], baseEnvironment["TMPDIR"], "TMPDIR 原值不变")
        checks.expectEqual(chatEnvironment["PATH"], baseEnvironment["PATH"], "PATH 原值不变")
        checks.check(chatEnvironment["NODE_OPTIONS"] == nil, "NODE_OPTIONS 被剔除")
        checks.check(chatEnvironment["NODE_PATH"] == nil, "NODE_PATH 被剔除")
        checks.check(chatEnvironment["CLAUDE_CODE_ENTRYPOINT"] == nil, "其他 CLAUDE_CODE_* 被剔除")
        checks.check(
            chatEnvironment["CLAUDE_CONFIG_DIR"] != fixture.injectedClaudeConfigDir
                && (chatEnvironment["CLAUDE_CONFIG_DIR"]?.isEmpty == false),
            "使用自建私有 CLAUDE_CONFIG_DIR"
        )
        checks.expectEqual((chatRecord["cwdMode"] as? NSNumber)?.intValue, 0o700, "私有 cwd 权限 0700")
        let chatConfig = chatRecord["mcpConfigText"] as? String ?? ""
        checks.check(chatConfig.contains("\"mcpServers\":{}"), "纯聊天空 mcpServers config")
        checks.check(!chatConfig.contains(fixture.apiKey), "mcp config 不含 key")
        checks.check(chatService.preferenceStore.sessionID(for: .claudeCode, scope: chatWorld.sessionScope) == nil,
                     "不保存 CLI 返回的假 sessionID")
        if let chatCwd = chatCapture.last?.workingDirectory {
            checks.check(await residentClaudeWaitForRemoval(chatCwd.deletingLastPathComponent().path),
                         "纯聊天私有目录已清理")
        }

        // 2) 每轮 fresh：无 resume/session-id；进程内历史有界（最近 6 条，每条 8k）。
        let historyFake = try fixture.writeFakeClaude(
            in: work, name: "history", nodePath: nodePath, recordDirectory: recordDirectory,
            mode: .chat, reply: "收到"
        )
        let historyService = makeService(
            claude: historyFake.executableURL, defaults: residentClaudeMakeDefaults("history"),
            capture: ResidentClaudeRunCapture(), spawns: ResidentClaudeSpawnCounter(),
            environment: baseEnvironment
        )
        historyService.selectBackend(.claudeCode)
        _ = try await historyService.send("第一句")
        _ = try await historyService.send("第二句")
        let secondRecord = fixture.readRecord(historyFake.recordPath) ?? [:]
        let secondStdin = secondRecord["stdin"] as? String ?? ""
        checks.check(secondStdin.contains("第一句"), "第二轮 stdin 携带上一轮用户文字")
        checks.check(secondStdin.contains("收到"), "第二轮 stdin 携带上一轮模型回复")
        let secondArgv = secondRecord["argv"] as? [String] ?? []
        checks.check(!secondArgv.contains("--resume"), "第二轮无 --resume")
        checks.check(!secondArgv.contains("--session-id"), "第二轮无 --session-id")
        _ = try await historyService.send("第三句")
        _ = try await historyService.send("第四句")
        _ = try await historyService.send("第五句")
        let fifthStdin = (fixture.readRecord(historyFake.recordPath) ?? ["stdin": ""])["stdin"] as? String ?? ""
        checks.check(!fifthStdin.contains("第一句"), "历史按最近 6 条淘汰最旧轮次")
        checks.check(fifthStdin.contains("第四句"), "历史保留最近轮次")
        checks.check(!fifthStdin.contains("--resume"), "历史轮次从不 resume")

        let longFake = try fixture.writeFakeClaude(
            in: work, name: "longmessage", nodePath: nodePath, recordDirectory: recordDirectory,
            mode: .chat, reply: "ok"
        )
        let longService = makeService(
            claude: longFake.executableURL, defaults: residentClaudeMakeDefaults("long"),
            capture: ResidentClaudeRunCapture(), spawns: ResidentClaudeSpawnCounter(),
            environment: baseEnvironment
        )
        longService.selectBackend(.claudeCode)
        _ = try await longService.send(String(repeating: "x", count: 9_000))
        _ = try await longService.send("下一轮")
        let longStdin = (fixture.readRecord(longFake.recordPath) ?? ["stdin": ""])["stdin"] as? String ?? ""
        checks.check(longStdin.contains(String(repeating: "x", count: 8_000)), "历史单条保留 8000 字符上界")
        checks.check(!longStdin.contains(String(repeating: "x", count: 8_001)), "历史单条不超过 8000 字符")

        // 3) scope 不混、reset 清历史。
        let scopeFake = try fixture.writeFakeClaude(
            in: work, name: "scope", nodePath: nodePath, recordDirectory: recordDirectory,
            mode: .chat, reply: "收到"
        )
        let scopeService = makeService(
            claude: scopeFake.executableURL, defaults: residentClaudeMakeDefaults("scope"),
            capture: ResidentClaudeRunCapture(), spawns: ResidentClaudeSpawnCounter(),
            environment: baseEnvironment
        )
        scopeService.selectBackend(.claudeCode)
        let worldA = residentClaudeMakeWorld("scope-a")
        let worldB = residentClaudeMakeWorld("scope-b")
        _ = try await scopeService.send("甲房第一句", worldContext: worldA)
        _ = try await scopeService.send("乙房第一句", worldContext: worldB)
        let bStdin = (fixture.readRecord(scopeFake.recordPath) ?? ["stdin": ""])["stdin"] as? String ?? ""
        checks.check(!bStdin.contains("甲房第一句"), "切 scope 不混入其他 scope 历史")
        _ = try await scopeService.send("甲房第二句", worldContext: worldA)
        let aStdin = (fixture.readRecord(scopeFake.recordPath) ?? ["stdin": ""])["stdin"] as? String ?? ""
        checks.check(aStdin.contains("甲房第一句"), "回到原 scope 保留其历史")
        checks.check(!aStdin.contains("乙房第一句"), "原 scope 不含其他 scope 历史")
        scopeService.resetSession()
        _ = try await scopeService.send("甲房重置后", worldContext: worldA)
        let resetStdin = (fixture.readRecord(scopeFake.recordPath) ?? ["stdin": ""])["stdin"] as? String ?? ""
        checks.check(!resetStdin.contains("甲房第一句"), "reset 清空该 scope 历史")

        // 4) 世界工具：真 schema → 真 MCP → 真 UDS → Swift handler → 结果回 CLI。
        let toolLog = ResidentClaudeToolCallLog()
        let toolMarker = "world-result-\(UUID().uuidString)"
        let toolFake = try fixture.writeFakeClaude(
            in: work, name: "tool", nodePath: nodePath, recordDirectory: recordDirectory,
            mode: .tool, reply: "已执行：", toolName: "gmgn_world_tool_7",
            toolArguments: ["value": "hello-world"]
        )
        let toolCapture = ResidentClaudeRunCapture()
        let toolSpawns = ResidentClaudeSpawnCounter()
        let toolService = makeService(
            claude: toolFake.executableURL, defaults: residentClaudeMakeDefaults("tool"),
            capture: toolCapture, spawns: toolSpawns, environment: baseEnvironment
        )
        toolService.selectBackend(.claudeCode)
        let toolWorld = residentClaudeMakeWorld("tool-room")
        let tools = ResidentConversationTools(
            worldID: "tool-room",
            schemasJSON: fixture.schemas,
            call: { callID, canonicalName, argumentsJSON in
                toolLog.append(callID: callID, canonicalName: canonicalName, argumentsJSON: argumentsJSON)
                return ResidentCodexToolReply(
                    resultJSON: fixture.data(["ok": true, "marker": toolMarker]), isError: false
                )
            },
            cancel: {}
        )
        let toolReply = try await toolService.send(
            "去拿东西", worldContext: toolWorld, worldTools: tools, userMessage: "去拿东西"
        )
        checks.expectEqual(toolLog.count, 1, "真实工具被调用一次")
        checks.expectEqual(toolLog.entries.first?.canonicalName, "world_tool_7", "canonical 名经 UDS 到达 handler")
        checks.check(
            (toolLog.entries.first?.argumentsJSON).flatMap { String(data: $0, encoding: .utf8) }?
                .contains("hello-world") == true,
            "工具参数原样到达 handler"
        )
        checks.check(toolReply.contains(toolMarker), "MCP 工具结果回到同一 CLI 运行并继续")
        let toolRecord = fixture.readRecord(toolFake.recordPath) ?? [:]
        let toolArgv = toolRecord["argv"] as? [String] ?? []
        residentClaudeCheckCommonArguments(toolArgv, &checks, "世界工具")
        checks.check(!toolArgv.contains(where: { $0.contains(fixture.apiKey) }), "世界工具 key 不进 argv")
        let toolConfig = toolRecord["mcpConfigText"] as? String ?? ""
        checks.check(toolConfig.contains(ResidentClaudeMCPAdapter.serverName), "mcp config 挂载受限 adapter")
        // JSONSerialization 会把 `/` 转义为 `\/`，因此解析后再比对路径。
        let toolConfigObject = (try? JSONSerialization.jsonObject(with: Data(toolConfig.utf8))) as? [String: Any]
        let toolServers = toolConfigObject?["mcpServers"] as? [String: Any]
        let toolServer = toolServers?[ResidentClaudeMCPAdapter.serverName] as? [String: Any]
        checks.expectEqual(toolServer?["command"] as? String, nodePath, "mcp config 使用真实 node")
        checks.check(
            ((toolServer?["args"] as? [String])?.first ?? "").hasSuffix(ResidentClaudeMCPAdapter.filename),
            "mcp config 指向受限 adapter"
        )
        checks.check(!toolConfig.contains(fixture.apiKey), "世界工具 mcp config 不含 key")
        let allowedIndex = toolArgv.firstIndex(of: "--allowedTools")
        let allowedNames = allowedIndex.map { Array(toolArgv[($0 + 1)...]) } ?? []
        checks.expectEqual(allowedNames, fixture.expectedAllowedToolNames, "只逐项放行本轮 MCP 工具")
        checks.check(!allowedNames.contains("mcp__gmgn-resident-tools"), "无 server 级宽泛放行")
        checks.check(!toolArgv.contains(where: { $0.contains("WebSearch") || $0.contains("WebFetch") }),
                     "绝不放行 WebSearch/WebFetch")
        let listedTools = ((toolRecord["toolsListed"] as? [String: Any])?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        checks.expectEqual(listedTools.count, 33, "MCP tools/list 返回 33 条")
        checks.check(
            fixture.canonicalJSON(listedTools) == fixture.canonicalJSON(fixture.expectedMCPTools),
            "生产 schema 原样透传到 MCP"
        )
        checks.expectEqual(toolRecord["adapterExited"] as? Bool, true, "CLI 结束时 adapter stdin EOF 退出")
        let toolLive = fixture.readLive(toolFake.recordPath) ?? [:]
        let toolAdapterPID = (toolLive["adapterPid"] as? NSNumber)?.int32Value
        checks.check((toolAdapterPID ?? 0) > 0, "MCP adapter 记录真实 pid")
        if let pid = toolAdapterPID {
            checks.check(await residentClaudeWaitForPIDExit(pid), "CLI 结束后 MCP adapter 有界退出并回收")
        }
        if let toolCwd = toolCapture.last?.workingDirectory {
            checks.check(await residentClaudeWaitForRemoval(toolCwd.deletingLastPathComponent().path),
                         "世界工具私有目录已清理")
        }

        // 4b) 工具失败经 MCP isError=true 回传（工具自身错误载荷保留）。
        let errorMarker = "tool-error-\(UUID().uuidString)"
        let errorFake = try fixture.writeFakeClaude(
            in: work, name: "toolerror", nodePath: nodePath, recordDirectory: recordDirectory,
            mode: .tool, reply: "失败：", toolName: "gmgn_world_tool_9",
            toolArguments: ["value": "boom"]
        )
        let errorService = makeService(
            claude: errorFake.executableURL, defaults: residentClaudeMakeDefaults("toolerror"),
            capture: ResidentClaudeRunCapture(), spawns: ResidentClaudeSpawnCounter(),
            environment: baseEnvironment
        )
        errorService.selectBackend(.claudeCode)
        let errorTools = ResidentConversationTools(
            worldID: "tool-room", schemasJSON: fixture.schemas,
            call: { _, _, _ in
                ResidentCodexToolReply(
                    resultJSON: fixture.data(["ok": false, "marker": errorMarker]), isError: true
                )
            },
            cancel: {}
        )
        let errorReply = try await errorService.send(
            "失败调用", worldContext: toolWorld, worldTools: errorTools, userMessage: "失败调用"
        )
        let errorRecord = fixture.readRecord(errorFake.recordPath) ?? [:]
        let errorResult = (errorRecord["toolCallResult"] as? [String: Any])?["result"] as? [String: Any]
        checks.expectEqual(errorResult?["isError"] as? Bool, true, "工具失败经 MCP isError=true 回传")
        checks.check(errorReply.contains(errorMarker), "失败载荷回到同一 CLI 运行")

        // 4c) 工具图片经 MCP image content 回传（imagePNGData → image/png）。
        let imageFake = try fixture.writeFakeClaude(
            in: work, name: "toolimage", nodePath: nodePath, recordDirectory: recordDirectory,
            mode: .tool, reply: "图片：", toolName: "gmgn_world_tool_11", toolArguments: [:]
        )
        let imageService = makeService(
            claude: imageFake.executableURL, defaults: residentClaudeMakeDefaults("toolimage"),
            capture: ResidentClaudeRunCapture(), spawns: ResidentClaudeSpawnCounter(),
            environment: baseEnvironment
        )
        imageService.selectBackend(.claudeCode)
        let pngData = Data(
            [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + [UInt8](repeating: 0x2A, count: 24)
        )
        let camera = ResidentVisionCameraStamp(
            label: "fixture", kind: .fullStageObserver, position: [0, 0, 0],
            yaw: 0, pitch: 0, fieldOfViewDegrees: 66, coordinateSpace: "world"
        )
        let stamp = ResidentVisionRenderedStamp(
            surfaceProfile: "full_stage_drawable", frameIndex: 1,
            capturedAt: Date(timeIntervalSince1970: 100), worldID: "tool-room",
            residentAvatarID: nil, residentAvatarFrameRevision: nil,
            residentPosition: nil, camera: camera
        )
        let frame = ResidentVisionRenderedFrame(
            pixelsBGRA: Data(repeating: 0x7F, count: 16), width: 4, height: 1,
            bytesPerRow: 16, stamp: stamp
        )
        let visionImage = ResidentVisionImage(
            pngData: pngData,
            metadata: ResidentVisionMetadata.make(
                renderedFrame: frame, perspective: .currentObservation, expectedWorldRevision: nil
            ),
            fileURL: nil
        )
        let imageTools = ResidentConversationTools(
            worldID: "tool-room", schemasJSON: fixture.schemas,
            call: { _, _, _ in
                ResidentCodexToolReply(
                    resultJSON: fixture.data(["ok": true, "marker": "image"]),
                    isError: false, image: visionImage
                )
            },
            cancel: {}
        )
        _ = try await imageService.send(
            "拍一张", worldContext: toolWorld, worldTools: imageTools, userMessage: "拍一张"
        )
        let imageRecord = fixture.readRecord(imageFake.recordPath) ?? [:]
        let imageContent = (
            ((imageRecord["toolCallResult"] as? [String: Any])?["result"] as? [String: Any])?["content"]
                as? [[String: Any]]
        ) ?? []
        let imageEntry = imageContent.first { ($0["type"] as? String) == "image" }
        checks.expectEqual(imageEntry?["mimeType"] as? String, "image/png", "工具图片经 MCP image content 回传")
        checks.expectEqual(
            imageEntry?["data"] as? String, pngData.base64EncodedString(),
            "MCP image base64 与工具 PNG 一致"
        )

        var imageRejected = false
        let spawnsBeforeImage = toolSpawns.count
        do {
            _ = try await toolService.send(
                "看图", imageURLs: [work.appendingPathComponent("x.png")],
                worldContext: toolWorld, worldTools: tools, userMessage: "看图"
            )
        } catch { imageRejected = true }
        checks.check(imageRejected, "Claude 仍不支持图片输入（imagesUnsupported）")
        checks.expectEqual(toolSpawns.count, spawnsBeforeImage, "图片被拒时零 spawn")

        // 5) 缺凭证：spawn 前固定中文错误，零 spawn，目录零残留。
        var missingEnvironment = baseEnvironment
        missingEnvironment.removeValue(forKey: "ANTHROPIC_API_KEY")
        let missingFake = try fixture.writeFakeClaude(
            in: work, name: "missing", nodePath: nodePath, recordDirectory: recordDirectory,
            mode: .chat, reply: "不应出现"
        )
        let missingSpawns = ResidentClaudeSpawnCounter()
        let missingService = makeService(
            claude: missingFake.executableURL, defaults: residentClaudeMakeDefaults("missing"),
            capture: ResidentClaudeRunCapture(), spawns: missingSpawns, environment: missingEnvironment
        )
        missingService.selectBackend(.claudeCode)
        var missingError: Error?
        do { _ = try await missingService.send("你好") } catch { missingError = error }
        checks.check(missingError != nil, "缺 API key 时固定错误")
        checks.check(
            (missingError?.localizedDescription ?? "").contains("ANTHROPIC_API_KEY")
                || (missingError?.localizedDescription ?? "").contains("凭证"),
            "缺凭证错误为可见中文缺配置提示"
        )
        checks.expectEqual(missingSpawns.count, 0, "缺凭证零 spawn")
        checks.check(fixture.readRecord(missingFake.recordPath) == nil, "缺凭证不执行假 CLI")

        // 6) 退出失败：固定安全诊断，不回显 stderr/key。
        let failFake = try fixture.writeFakeClaude(
            in: work, name: "fail", nodePath: nodePath, recordDirectory: recordDirectory,
            mode: .fail, reply: "不应出现", exitCode: 3,
            stderrText: "LEAK-\(fixture.apiKey)-LEAK"
        )
        let failService = makeService(
            claude: failFake.executableURL, defaults: residentClaudeMakeDefaults("fail"),
            capture: ResidentClaudeRunCapture(), spawns: ResidentClaudeSpawnCounter(),
            environment: baseEnvironment
        )
        failService.selectBackend(.claudeCode)
        var failError: Error?
        do { _ = try await failService.send("你好") } catch { failError = error }
        checks.check(failError != nil, "退出码非零时报错")
        let failDescription = failError?.localizedDescription ?? ""
        checks.check(!failDescription.contains(fixture.apiKey), "失败诊断不回显 key")
        checks.check(!failDescription.contains("LEAK-"), "失败诊断不回显原 stderr")

        // 7) 超时：终止并回收自有进程，目录清理。
        let sleepFake = try fixture.writeFakeClaude(
            in: work, name: "sleep", nodePath: nodePath, recordDirectory: recordDirectory,
            mode: .sleep, reply: "不应出现", delayMilliseconds: 60_000
        )
        let sleepCapture = ResidentClaudeRunCapture()
        let sleepService = makeService(
            claude: sleepFake.executableURL, defaults: residentClaudeMakeDefaults("sleep"),
            capture: sleepCapture, spawns: ResidentClaudeSpawnCounter(),
            environment: baseEnvironment, turnTimeout: 0.8
        )
        sleepService.selectBackend(.claudeCode)
        let timeoutStart = Date()
        var timeoutError: Error?
        do { _ = try await sleepService.send("超时") } catch { timeoutError = error }
        let timeoutElapsed = Date().timeIntervalSince(timeoutStart)
        checks.check(timeoutError != nil, "超时抛出错误")
        checks.check(timeoutElapsed < 20, "超时在有界时间内返回（\(String(format: "%.1f", timeoutElapsed))s）")
        checks.check(
            (timeoutError?.localizedDescription ?? "").contains("超时")
                || (timeoutError is ResidentClaudeProcessError),
            "超时为固定安全超时诊断"
        )
        if let sleepCwd = sleepCapture.last?.workingDirectory {
            checks.check(await residentClaudeWaitForRemoval(sleepCwd.deletingLastPathComponent().path),
                         "超时后私有目录已清理")
        }

        // 8) 取消：先 revoke、finally stop；迟到零副作用、返回屏蔽、目录清理。
        let cancelLog = ResidentClaudeToolCallLog()
        let cancelFake = try fixture.writeFakeClaude(
            in: work, name: "cancel", nodePath: nodePath, recordDirectory: recordDirectory,
            mode: .tool, reply: "不应出现", toolName: "gmgn_world_tool_1",
            toolArguments: [:], delayMilliseconds: 60_000
        )
        let cancelCapture = ResidentClaudeRunCapture()
        let cancelSpawns = ResidentClaudeSpawnCounter()
        let cancelService = makeService(
            claude: cancelFake.executableURL, defaults: residentClaudeMakeDefaults("cancel"),
            capture: cancelCapture, spawns: cancelSpawns, environment: baseEnvironment
        )
        cancelService.selectBackend(.claudeCode)
        let cancelWorld = residentClaudeMakeWorld("cancel-room")
        let cancelTools = ResidentConversationTools(
            worldID: "cancel-room", schemasJSON: fixture.schemas,
            call: { callID, canonicalName, argumentsJSON in
                cancelLog.append(callID: callID, canonicalName: canonicalName, argumentsJSON: argumentsJSON)
                return ResidentCodexToolReply(resultJSON: fixture.data(["ok": true]), isError: false)
            },
            cancel: {}
        )
        let cancelTask = Task { @MainActor in
            do {
                _ = try await cancelService.send(
                    "取消我", worldContext: cancelWorld, worldTools: cancelTools, userMessage: "取消我"
                )
                return "returned"
            } catch {
                return error is CancellationError || (error as? AgentConversationError) != nil ? "cancelled" : "other"
            }
        }
        var waited = 0
        while cancelSpawns.count == 0 && waited < 2_000 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            waited += 1
        }
        checks.expectEqual(cancelSpawns.count, 1, "取消场景已 spawn")
        try? await Task.sleep(nanoseconds: 200_000_000)
        cancelService.cancel()
        let cancelOutcome = await cancelTask.value
        checks.expectEqual(cancelOutcome, "cancelled", "取消后返回被屏蔽为取消")
        checks.expectEqual(cancelLog.count, 0, "取消后零工具副作用")
        if let cancelCwd = cancelCapture.last?.workingDirectory {
            checks.check(await residentClaudeWaitForRemoval(cancelCwd.deletingLastPathComponent().path),
                         "取消后私有目录已清理")
        }

        // 9) 空结果边界：后台静默完成允许空；普通用户空 reply 仍错误。
        let emptyFake = try fixture.writeFakeClaude(
            in: work, name: "empty", nodePath: nodePath, recordDirectory: recordDirectory,
            mode: .empty, reply: ""
        )
        let silentService = makeService(
            claude: emptyFake.executableURL, defaults: residentClaudeMakeDefaults("silent"),
            capture: ResidentClaudeRunCapture(), spawns: ResidentClaudeSpawnCounter(),
            environment: baseEnvironment
        )
        silentService.selectBackend(.claudeCode)
        let silentWorld = residentClaudeMakeWorld("silent-room")
        let silentTools = ResidentConversationTools(
            worldID: "silent-room", schemasJSON: fixture.schemas,
            call: { _, _, _ in ResidentCodexToolReply(resultJSON: fixture.data(["ok": true]), isError: false) },
            cancel: {}, allowsSilentCompletion: { true }
        )
        let silentReply = try await silentService.send(
            "后台", worldContext: silentWorld, worldTools: silentTools
        )
        checks.expectEqual(silentReply, "", "后台静默完成允许空结果")
        let loudTools = ResidentConversationTools(
            worldID: "silent-room", schemasJSON: fixture.schemas,
            call: silentTools.call, cancel: {}, allowsSilentCompletion: { false }
        )
        var loudFailed = false
        do { _ = try await silentService.send("前台", worldContext: silentWorld, worldTools: loudTools) }
        catch { loudFailed = true }
        checks.check(loudFailed, "非静默空 reply 仍报错")
        var chatEmptyFailed = false
        let emptyChatService = makeService(
            claude: emptyFake.executableURL, defaults: residentClaudeMakeDefaults("emptychat"),
            capture: ResidentClaudeRunCapture(), spawns: ResidentClaudeSpawnCounter(),
            environment: baseEnvironment
        )
        emptyChatService.selectBackend(.claudeCode)
        do { _ = try await emptyChatService.send("普通空回复") } catch { chatEmptyFailed = true }
        checks.check(chatEmptyFailed, "普通用户空 reply 仍报错")

        // 10) 记忆边界：每轮 freshSession=true、query 为真实 userText、组装 prompt 不入记忆。
        let memoryTransport = ResidentClaudeMemoryTransport()
        let memory = ResidentConversationMemory(transport: memoryTransport)
        let memoryFake = try fixture.writeFakeClaude(
            in: work, name: "memory", nodePath: nodePath, recordDirectory: recordDirectory,
            mode: .chat, reply: "记忆回复"
        )
        let memoryService = makeService(
            claude: memoryFake.executableURL, defaults: residentClaudeMakeDefaults("memory"),
            capture: ResidentClaudeRunCapture(), spawns: ResidentClaudeSpawnCounter(),
            environment: baseEnvironment
        )
        memoryService.selectBackend(.claudeCode)
        memoryService.attachConversationMemory(memory)
        let memoryWorld = residentClaudeMakeWorld("memory-room")
        _ = try await memoryService.send("记住我喜欢爵士", worldContext: memoryWorld)
        _ = try await memoryService.send("再聊一次", worldContext: memoryWorld)
        let recalls = memoryTransport.calls("memory_recall")
        checks.expectEqual(recalls.count, 2, "每轮都召回记忆")
        checks.check(recalls.allSatisfy { $0["freshSession"]?.boolValue == true },
                     "Claude 无原生 resume：每轮 freshSession=true")
        checks.expectEqual(recalls.first?["query"]?.stringValue, "记住我喜欢爵士", "召回 query 用真实用户文字")
        checks.expectEqual(recalls.last?["query"]?.stringValue, "再聊一次", "第二轮 query 仍是真实用户文字")
        let memoryStdin = (fixture.readRecord(memoryFake.recordPath) ?? ["stdin": ""])["stdin"] as? String ?? ""
        checks.check(
            recalls.allSatisfy { $0["query"]?.stringValue != memoryStdin },
            "组装 prompt 不作为记忆 query"
        )
        checks.expectEqual(memoryTransport.calls("memory_ingest").count, 0, "模型返回不自动 ingest")
        checks.check(memoryService.lastTurnDeliveryRequestID != nil, "成功轮次登记待交付凭据")
        if let requestID = memoryService.lastTurnDeliveryRequestID {
            let delivered = memoryService.confirmDeliveredTurn(
                requestID: requestID, userText: "再聊一次", reply: "记忆回复"
            )
            checks.expectEqual(delivered, .accepted, "显式交付确认入队")
        }
        let ingests = memoryTransport.calls("memory_ingest")
        var ingestWaited = 0
        while memoryTransport.calls("memory_ingest").isEmpty && ingestWaited < 300 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            ingestWaited += 1
        }
        checks.expectEqual(memoryTransport.calls("memory_ingest").count, 1, "交付确认后 ingest 一次")
        checks.expectEqual(
            memoryTransport.calls("memory_ingest").first?["userText"]?.stringValue, "再聊一次",
            "ingest 用真实用户文字"
        )
        _ = ingests
        // 后台无真实用户输入：不虚构 query、不登记交付。
        let backgroundRecallCount = memoryTransport.calls("memory_recall").count
        let backgroundTools = ResidentConversationTools(
            worldID: "memory-room", schemasJSON: fixture.schemas,
            call: { _, _, _ in ResidentCodexToolReply(resultJSON: fixture.data(["ok": true]), isError: false) },
            cancel: {}, allowsSilentCompletion: { true }
        )
        _ = try await memoryService.send("后台轮次", worldContext: memoryWorld, worldTools: backgroundTools)
        checks.expectEqual(memoryTransport.calls("memory_recall").count, backgroundRecallCount,
                           "无真实用户输入的后台轮次不召回记忆")
        checks.check(memoryService.lastTurnDeliveryRequestID == nil, "后台轮次不伪造待交付凭据")

        // 11) 人格每轮重新读取。
        let personaDefaults = residentClaudeMakeDefaults("persona")
        let personaFake = try fixture.writeFakeClaude(
            in: work, name: "persona", nodePath: nodePath, recordDirectory: recordDirectory,
            mode: .chat, reply: "好的"
        )
        let personaService = makeService(
            claude: personaFake.executableURL, defaults: personaDefaults,
            capture: ResidentClaudeRunCapture(), spawns: ResidentClaudeSpawnCounter(),
            environment: baseEnvironment
        )
        personaService.selectBackend(.claudeCode)
        let personaWorld = residentClaudeMakeWorld("persona-room")
        _ = try await personaService.send("第一轮", worldContext: personaWorld)
        ResidentPreferences(defaults: personaDefaults).savePersona("新的居民人格标记-ZQ7")
        _ = try await personaService.send("第二轮", worldContext: personaWorld)
        let personaStdin = (fixture.readRecord(personaFake.recordPath) ?? ["stdin": ""])["stdin"] as? String ?? ""
        checks.check(personaStdin.contains("新的居民人格标记-ZQ7"), "人格保存后下一轮生效")

        // 12) P2-1 runner 输出上界：stdout/stderr 超量必须立即终止自有进程并抛固定
        //     outputTooLarge，绝不静默截断、绝不等待总超时；内存有界、零原始回显。
        let boundLimit = 4_096
        let runnerEnvironment = ["PATH": baseEnvironment["PATH"] ?? "/usr/bin:/bin"]
        func makeRunner(
            _ fake: ResidentClaudeServiceFixture.FakeRunnerProcess,
            limit: Int,
            timeout: TimeInterval
        ) -> ResidentClaudeProcessRunner {
            ResidentClaudeProcessRunner(
                executableURL: fake.executableURL,
                environment: runnerEnvironment,
                workingDirectoryURL: work,
                timeout: timeout,
                maximumOutputBytes: limit
            )
        }

        let quietFake = try fixture.writeFakeRunnerProcess(
            in: work, name: "quiet", nodePath: nodePath, mode: .quiet, bytes: 0
        )
        let quietResult = try await makeRunner(quietFake, limit: boundLimit, timeout: 3)
            .run(arguments: [], standardInput: nil)
        checks.expectEqual(quietResult.exitCode, 0, "上界内 stdout 正常成功")
        checks.check(quietResult.output.contains("ok"), "上界内 stdout 原样返回")

        let boundedStdoutFake = try fixture.writeFakeRunnerProcess(
            in: work, name: "bounded-stdout", nodePath: nodePath,
            mode: .stdoutBounded, bytes: boundLimit * 4
        )
        let boundedStdoutStart = Date()
        var boundedStdoutError: Error?
        do {
            _ = try await makeRunner(boundedStdoutFake, limit: boundLimit, timeout: 3)
                .run(arguments: [], standardInput: nil)
        } catch { boundedStdoutError = error }
        let boundedStdoutElapsed = Date().timeIntervalSince(boundedStdoutStart)
        checks.expectEqual(
            boundedStdoutError as? ResidentClaudeProcessError, .outputTooLarge,
            "有限超量 stdout 抛固定 outputTooLarge"
        )
        checks.check(boundedStdoutElapsed < 3,
                     "有限超量 stdout 有界且不等 timeout（\(String(format: "%.1f", boundedStdoutElapsed))s）")
        checks.check(!(boundedStdoutError?.localizedDescription ?? "").contains("xxx"),
                     "超量错误不回显任何原始 stdout")
        if let pid = fixture.readPIDFile(boundedStdoutFake.pidPath) {
            checks.check(kill(pid, 0) != 0, "有限超量返回时自有进程已退出并回收")
        } else {
            checks.check(false, "有限超量未记录真实 pid")
        }

        let sustainedStdoutFake = try fixture.writeFakeRunnerProcess(
            in: work, name: "sustained-stdout", nodePath: nodePath,
            mode: .stdoutSustained, bytes: 0, ignoreSIGTERM: true
        )
        let sustainedStdoutStart = Date()
        var sustainedStdoutError: Error?
        do {
            _ = try await makeRunner(sustainedStdoutFake, limit: boundLimit, timeout: 3)
                .run(arguments: [], standardInput: nil)
        } catch { sustainedStdoutError = error }
        let sustainedStdoutElapsed = Date().timeIntervalSince(sustainedStdoutStart)
        checks.expectEqual(sustainedStdoutError as? ResidentClaudeProcessError, .outputTooLarge,
                           "持续超量 stdout 抛固定 outputTooLarge")
        checks.check(sustainedStdoutElapsed < 3,
                     "持续超量 stdout（忽略 SIGTERM）有界且不等 timeout（\(String(format: "%.1f", sustainedStdoutElapsed))s）")
        if let pid = fixture.readPIDFile(sustainedStdoutFake.pidPath) {
            checks.check(kill(pid, 0) != 0, "持续超量返回时自有进程已被 KILL 并回收")
        } else {
            checks.check(false, "持续超量未记录真实 pid")
        }

        let boundedStderrFake = try fixture.writeFakeRunnerProcess(
            in: work, name: "bounded-stderr", nodePath: nodePath,
            mode: .stderrBounded, bytes: boundLimit * 4
        )
        let boundedStderrStart = Date()
        var boundedStderrError: Error?
        do {
            _ = try await makeRunner(boundedStderrFake, limit: boundLimit, timeout: 3)
                .run(arguments: [], standardInput: nil)
        } catch { boundedStderrError = error }
        let boundedStderrElapsed = Date().timeIntervalSince(boundedStderrStart)
        checks.expectEqual(boundedStderrError as? ResidentClaudeProcessError, .outputTooLarge,
                           "超量 stderr 抛固定 outputTooLarge")
        checks.check(boundedStderrElapsed < 3,
                     "超量 stderr 有界且不等 timeout（\(String(format: "%.1f", boundedStderrElapsed))s）")
        checks.check(!(boundedStderrError?.localizedDescription ?? "").contains("xxx"),
                     "超量 stderr 错误不回显任何原始 stderr")
        if let pid = fixture.readPIDFile(boundedStderrFake.pidPath) {
            checks.check(kill(pid, 0) != 0, "超量 stderr 返回时自有进程已退出并回收")
        } else {
            checks.check(false, "超量 stderr 未记录真实 pid")
        }

        // 12b) 正常小体量 stderr + stdout：stderr 排空完成才结算，仍必须成功。
        let normalStderrFake = try fixture.writeFakeRunnerProcess(
            in: work, name: "normal-stderr", nodePath: nodePath,
            mode: .stderrNormal, bytes: boundLimit / 4
        )
        var normalStderrError: Error?
        var normalStderrResult: CodexCommandResult?
        do {
            normalStderrResult = try await makeRunner(normalStderrFake, limit: boundLimit, timeout: 3)
                .run(arguments: [], standardInput: nil)
        } catch { normalStderrError = error }
        checks.check(normalStderrError == nil, "正常 stderr+stdout 不报错（\(String(describing: normalStderrError))）")
        checks.expectEqual(normalStderrResult?.exitCode, 0, "正常 stderr+stdout 退出码 0")
        checks.check(normalStderrResult?.output.contains("ok") == true, "正常 stderr+stdout 仍返回 stdout")

        // 12c) 竞态：直接子进程先被 reap，继承 stderr 的孙进程稍后才写出小体量超量
        //      stderr。结算必须等待 stderr 排空完成并以其 overflow 结果为准，固定
        //      outputTooLarge，绝不能凭 stdout 已 reap 就成功。
        let afterExitFake = try fixture.writeFakeRunnerProcess(
            in: work, name: "stderr-after-exit", nodePath: nodePath,
            mode: .stderrAfterExit, bytes: boundLimit * 4
        )
        let afterExitStart = Date()
        var afterExitError: Error?
        var afterExitResult: CodexCommandResult?
        do {
            afterExitResult = try await makeRunner(afterExitFake, limit: boundLimit, timeout: 3)
                .run(arguments: [], standardInput: nil)
        } catch { afterExitError = error }
        let afterExitElapsed = Date().timeIntervalSince(afterExitStart)
        checks.expectEqual(afterExitError as? ResidentClaudeProcessError, .outputTooLarge,
                           "stdout 已 reap 后的 stderr 超量仍固定 outputTooLarge")
        checks.check(afterExitResult == nil, "stdout 已 reap 后的 stderr 超量绝不静默成功")
        checks.check(afterExitElapsed < 3,
                     "晚到 stderr 超量有界且不等 timeout（\(String(format: "%.1f", afterExitElapsed))s）")
        checks.check(!(afterExitError?.localizedDescription ?? "").contains("xxx"),
                     "晚到 stderr 超量不回显任何原始 stderr")
        if let pid = fixture.readPIDFile(afterExitFake.pidPath) {
            checks.check(kill(pid, 0) != 0, "晚到 stderr 超量返回时自有进程已回收")
        } else {
            checks.check(false, "晚到 stderr 超量未记录真实 pid")
        }

        // 13) P2-2 runner 回收：取消/超时在返回前必须已 TERM→(250ms)KILL 并 reap
        //     自有 Process（kill(pid,0) 失败），忽略 SIGTERM 的 node fixture 亦然。
        let cancelRunnerFake = try fixture.writeFakeRunnerProcess(
            in: work, name: "runner-cancel", nodePath: nodePath, mode: .ignoreTERM, bytes: 0
        )
        let cancelRunner = makeRunner(cancelRunnerFake, limit: boundLimit, timeout: 3)
        let cancelRunnerTask = Task { try await cancelRunner.run(arguments: [], standardInput: nil) }
        var cancelPid: pid_t?
        var cancelPidWaited = 0
        while cancelPid == nil && cancelPidWaited < 400 {
            cancelPid = fixture.readPIDFile(cancelRunnerFake.pidPath)
            if cancelPid == nil { try? await Task.sleep(nanoseconds: 5_000_000) }
            cancelPidWaited += 1
        }
        checks.check(cancelPid != nil, "取消场景记录到真实 pid")
        cancelRunnerTask.cancel()
        let cancelReturnStart = Date()
        var cancelRunnerError: Error?
        do { _ = try await cancelRunnerTask.value } catch { cancelRunnerError = error }
        let cancelReturnElapsed = Date().timeIntervalSince(cancelReturnStart)
        checks.check(cancelRunnerError is CancellationError, "直接取消 runner 抛 CancellationError")
        checks.check(cancelReturnElapsed < 5,
                     "取消在有界时间内返回（\(String(format: "%.1f", cancelReturnElapsed))s）")
        if let pid = cancelPid {
            checks.check(kill(pid, 0) != 0, "取消返回时忽略 SIGTERM 的自有进程已退出并回收")
        }

        let timeoutRunnerFake = try fixture.writeFakeRunnerProcess(
            in: work, name: "runner-timeout", nodePath: nodePath, mode: .ignoreTERM, bytes: 0
        )
        let timeoutReturnStart = Date()
        var timeoutRunnerError: Error?
        do {
            _ = try await makeRunner(timeoutRunnerFake, limit: boundLimit, timeout: 2.0)
                .run(arguments: [], standardInput: nil)
        } catch { timeoutRunnerError = error }
        let timeoutReturnElapsed = Date().timeIntervalSince(timeoutReturnStart)
        checks.expectEqual(timeoutRunnerError as? ResidentClaudeProcessError, .timedOut,
                           "runner 超时抛固定 timedOut")
        checks.check(timeoutReturnElapsed < 5,
                     "超时在有界时间内返回（\(String(format: "%.1f", timeoutReturnElapsed))s）")
        if let pid = fixture.readPIDFile(timeoutRunnerFake.pidPath) {
            checks.check(kill(pid, 0) != 0, "超时返回时忽略 SIGTERM 的自有进程已退出并回收")
        } else {
            checks.check(false, "超时场景未记录真实 pid")
        }

        // 13b) 后代持有管道：直接子进程派生一个脱离且忽略 SIGTERM 的后代，由后代持续
        //      持有 stdout/stderr 写端；直接子进程自身也忽略 SIGTERM 长驻。此时即使
        //      直接子进程被 reap，管道也永远等不到 EOF——旧实现的阻塞 read-to-EOF 会让
        //      cancel/timeout 永不返回。两者都必须在有界时间内返回、直接子进程已回收；
        //      后代由 fixture 自行清理它明确创建的 PID，生产不得管理未知子孙。
        func descendantPIDPath(_ fake: ResidentClaudeServiceFixture.FakeRunnerProcess) -> String {
            fake.pidPath + ".descendant"
        }

        func awaitDescendantPIDs(
            _ fake: ResidentClaudeServiceFixture.FakeRunnerProcess
        ) async -> (direct: pid_t?, descendant: pid_t?) {
            var waited = 0
            while waited < 600 {
                let direct = fixture.readPIDFile(fake.pidPath)
                let descendant = fixture.readPIDFile(descendantPIDPath(fake))
                if direct != nil, descendant != nil { return (direct, descendant) }
                try? await Task.sleep(nanoseconds: 5_000_000)
                waited += 1
            }
            return (fixture.readPIDFile(fake.pidPath), fixture.readPIDFile(descendantPIDPath(fake)))
        }

        func cleanupDescendant(_ fake: ResidentClaudeServiceFixture.FakeRunnerProcess) async {
            guard let pid = fixture.readPIDFile(descendantPIDPath(fake)) else { return }
            kill(pid, SIGKILL)
            _ = await residentClaudeWaitForPIDExit(pid)
        }

        /// 后代 stdin 排空报告的有界等待：超出等待仍返回当前观测（可能为 nil）。
        func awaitStdinDrainReport(
            _ fake: ResidentClaudeServiceFixture.FakeRunnerProcess
        ) async -> [String: Any]? {
            var waited = 0
            while waited < 600 {
                if let report = fixture.readRecord(fake.stdinDrainReportPath) { return report }
                try? await Task.sleep(nanoseconds: 5_000_000)
                waited += 1
            }
            return fixture.readRecord(fake.stdinDrainReportPath)
        }

        // 13b-1) 取消：后代持管道时有界返回并回收直接子进程。
        let descendantCancelFake = try fixture.writeFakeRunnerProcess(
            in: work, name: "descendant-cancel", nodePath: nodePath,
            mode: .descendantHold, bytes: 0, ignoreSIGTERM: true
        )
        let descendantCancelRunner = makeRunner(descendantCancelFake, limit: boundLimit, timeout: 30)
        let descendantCancelTask = Task {
            try await descendantCancelRunner.run(arguments: [], standardInput: nil)
        }
        let descendantCancelPIDs = await awaitDescendantPIDs(descendantCancelFake)
        checks.check(descendantCancelPIDs.direct != nil, "后代持管道取消场景记录直接子进程 pid")
        checks.check(descendantCancelPIDs.descendant != nil, "后代持管道取消场景记录后代 pid")
        descendantCancelTask.cancel()
        let descendantCancelOutcome = await residentClaudeAwaitBounded(
            descendantCancelTask, watchdog: 6
        )
        checks.check(!descendantCancelOutcome.timedOut,
                     "后代持管道时取消有界返回（\(String(format: "%.1f", descendantCancelOutcome.elapsed))s）")
        checks.check(descendantCancelOutcome.error is CancellationError,
                     "后代持管道时取消抛 CancellationError")
        checks.check(descendantCancelOutcome.elapsed < 5,
                     "后代持管道时取消不等后代释放管道（\(String(format: "%.1f", descendantCancelOutcome.elapsed))s）")
        if let pid = descendantCancelPIDs.direct {
            checks.check(await residentClaudeWaitForPIDExit(pid),
                         "后代持管道时取消返回时直接子进程已退出并回收")
        }
        await cleanupDescendant(descendantCancelFake)

        // 13b-2) 超时：后代持管道时同样有界返回并回收直接子进程。
        let descendantTimeoutFake = try fixture.writeFakeRunnerProcess(
            in: work, name: "descendant-timeout", nodePath: nodePath,
            mode: .descendantHold, bytes: 0, ignoreSIGTERM: true
        )
        let descendantTimeoutRunner = makeRunner(descendantTimeoutFake, limit: boundLimit, timeout: 2.0)
        let descendantTimeoutTask = Task {
            try await descendantTimeoutRunner.run(arguments: [], standardInput: nil)
        }
        let descendantTimeoutPIDs = await awaitDescendantPIDs(descendantTimeoutFake)
        checks.check(descendantTimeoutPIDs.direct != nil, "后代持管道超时场景记录直接子进程 pid")
        checks.check(descendantTimeoutPIDs.descendant != nil, "后代持管道超时场景记录后代 pid")
        let descendantTimeoutOutcome = await residentClaudeAwaitBounded(
            descendantTimeoutTask, watchdog: 8
        )
        checks.check(!descendantTimeoutOutcome.timedOut,
                     "后代持管道时超时有界返回（\(String(format: "%.1f", descendantTimeoutOutcome.elapsed))s）")
        checks.expectEqual(
            descendantTimeoutOutcome.error as? ResidentClaudeProcessError, .timedOut,
            "后代持管道时超时抛固定 timedOut"
        )
        checks.check(descendantTimeoutOutcome.elapsed < 5,
                     "后代持管道时超时不等后代释放管道（\(String(format: "%.1f", descendantTimeoutOutcome.elapsed))s）")
        if let pid = descendantTimeoutPIDs.direct {
            checks.check(await residentClaudeWaitForPIDExit(pid),
                         "后代持管道时超时返回时直接子进程已退出并回收")
        }
        await cleanupDescendant(descendantTimeoutFake)

        // 13b-3) 后代继承 stdin 读端且不读 + 大于管道容量的 1 MiB prompt：整段阻塞
        //        write 会永久遗留 writer 线程与自有写端。取消必须在有界时间内返回、
        //        回收直接子进程，并由 writer 自己关闭自有写端：取消返回后让后代读
        //        stdin 到 EOF，应只读到取消时管道内已缓冲的部分即 EOF，而不是被遗留
        //        writer 补完整段 prompt。观察只用测试专属哨兵 + 后代报告，无生产钩子。
        let stdinPromptBytes = 1 << 20
        let stdinPrompt = String(repeating: "s", count: stdinPromptBytes)

        let descendantStdinCancelFake = try fixture.writeFakeRunnerProcess(
            in: work, name: "descendant-stdin-cancel", nodePath: nodePath,
            mode: .descendantHold, bytes: 0, ignoreSIGTERM: true
        )
        let descendantStdinCancelRunner = makeRunner(descendantStdinCancelFake, limit: boundLimit, timeout: 30)
        let descendantStdinCancelTask = Task {
            try await descendantStdinCancelRunner.run(arguments: [], standardInput: stdinPrompt)
        }
        let descendantStdinCancelPIDs = await awaitDescendantPIDs(descendantStdinCancelFake)
        checks.check(descendantStdinCancelPIDs.direct != nil, "stdin 持读端取消场景记录直接子进程 pid")
        checks.check(descendantStdinCancelPIDs.descendant != nil, "stdin 持读端取消场景记录后代 pid")
        descendantStdinCancelTask.cancel()
        let descendantStdinCancelOutcome = await residentClaudeAwaitBounded(
            descendantStdinCancelTask, watchdog: 6
        )
        checks.check(!descendantStdinCancelOutcome.timedOut,
                     "stdin 持读端时取消有界返回（\(String(format: "%.1f", descendantStdinCancelOutcome.elapsed))s）")
        checks.check(descendantStdinCancelOutcome.error is CancellationError,
                     "stdin 持读端时取消抛 CancellationError")
        checks.check(descendantStdinCancelOutcome.elapsed < 5,
                     "stdin 持读端时取消不等 writer/后代释放（\(String(format: "%.1f", descendantStdinCancelOutcome.elapsed))s）")
        if let pid = descendantStdinCancelPIDs.direct {
            checks.check(await residentClaudeWaitForPIDExit(pid),
                         "stdin 持读端时取消返回时直接子进程已退出并回收")
        }
        try? Data().write(to: URL(fileURLWithPath: descendantStdinCancelFake.stdinDrainSentinelPath))
        let descendantStdinCancelReport = await awaitStdinDrainReport(descendantStdinCancelFake)
        checks.check(descendantStdinCancelReport?["eof"] as? Bool == true,
                     "取消后自有 stdin 写端已释放（后代读到 EOF）")
        let descendantStdinCancelBytes = (descendantStdinCancelReport?["bytes"] as? NSNumber)?.intValue ?? -1
        checks.check(descendantStdinCancelBytes >= 0 && descendantStdinCancelBytes < stdinPromptBytes,
                     "取消后 writer 有界退出只送出部分 prompt（\(descendantStdinCancelBytes)/\(stdinPromptBytes)）")
        await cleanupDescendant(descendantStdinCancelFake)

        // 13b-4) 同一 1 MiB + 后代持 stdin 读端场景的超时路径：同样有界返回、回收
        //        直接子进程，并由 writer 自己关闭自有写端（后代随后读到 EOF 且未收全）。
        let descendantStdinTimeoutFake = try fixture.writeFakeRunnerProcess(
            in: work, name: "descendant-stdin-timeout", nodePath: nodePath,
            mode: .descendantHold, bytes: 0, ignoreSIGTERM: true
        )
        let descendantStdinTimeoutRunner = makeRunner(descendantStdinTimeoutFake, limit: boundLimit, timeout: 2.0)
        let descendantStdinTimeoutTask = Task {
            try await descendantStdinTimeoutRunner.run(arguments: [], standardInput: stdinPrompt)
        }
        let descendantStdinTimeoutPIDs = await awaitDescendantPIDs(descendantStdinTimeoutFake)
        checks.check(descendantStdinTimeoutPIDs.direct != nil, "stdin 持读端超时场景记录直接子进程 pid")
        checks.check(descendantStdinTimeoutPIDs.descendant != nil, "stdin 持读端超时场景记录后代 pid")
        let descendantStdinTimeoutOutcome = await residentClaudeAwaitBounded(
            descendantStdinTimeoutTask, watchdog: 8
        )
        checks.check(!descendantStdinTimeoutOutcome.timedOut,
                     "stdin 持读端时超时有界返回（\(String(format: "%.1f", descendantStdinTimeoutOutcome.elapsed))s）")
        checks.expectEqual(
            descendantStdinTimeoutOutcome.error as? ResidentClaudeProcessError, .timedOut,
            "stdin 持读端时超时抛固定 timedOut"
        )
        checks.check(descendantStdinTimeoutOutcome.elapsed < 5,
                     "stdin 持读端时超时不等 writer/后代释放（\(String(format: "%.1f", descendantStdinTimeoutOutcome.elapsed))s）")
        if let pid = descendantStdinTimeoutPIDs.direct {
            checks.check(await residentClaudeWaitForPIDExit(pid),
                         "stdin 持读端时超时返回时直接子进程已退出并回收")
        }
        try? Data().write(to: URL(fileURLWithPath: descendantStdinTimeoutFake.stdinDrainSentinelPath))
        let descendantStdinTimeoutReport = await awaitStdinDrainReport(descendantStdinTimeoutFake)
        checks.check(descendantStdinTimeoutReport?["eof"] as? Bool == true,
                     "超时后自有 stdin 写端已释放（后代读到 EOF）")
        let descendantStdinTimeoutBytes = (descendantStdinTimeoutReport?["bytes"] as? NSNumber)?.intValue ?? -1
        checks.check(descendantStdinTimeoutBytes >= 0 && descendantStdinTimeoutBytes < stdinPromptBytes,
                     "超时后 writer 有界退出只送出部分 prompt（\(descendantStdinTimeoutBytes)/\(stdinPromptBytes)）")
        await cleanupDescendant(descendantStdinTimeoutFake)

        // 14) P2-3 Claude 专用严格结果校验：malformed / missing-result / result 非
        //     String / 错误 type/subtype / is_error=true 即便 allowsSilentCompletion
        //     也必须固定失败；合法空 result + 静默仍成功。
        func rawTools(_ worldID: String) -> ResidentConversationTools {
            ResidentConversationTools(
                worldID: worldID, schemasJSON: fixture.schemas,
                call: { _, _, _ in ResidentCodexToolReply(resultJSON: fixture.data(["ok": true]), isError: false) },
                cancel: {}, allowsSilentCompletion: { true }
            )
        }
        struct RawResultCase {
            let name: String
            let raw: String
            let shouldFail: Bool
            let expectedReply: String?
        }
        let rawWorld = residentClaudeMakeWorld("raw-room")
        let rawCases: [RawResultCase] = [
            RawResultCase(name: "invalid-json", raw: "this-is-not-json", shouldFail: true, expectedReply: nil),
            RawResultCase(name: "missing-result",
                          raw: #"{"type":"result","subtype":"success","session_id":"s"}"#,
                          shouldFail: true, expectedReply: nil),
            RawResultCase(name: "result-not-string", raw: #"{"result":{"text":"nested"}}"#,
                          shouldFail: true, expectedReply: nil),
            RawResultCase(name: "is-error-true", raw: #"{"result":"partial-LEAK","is_error":true}"#,
                          shouldFail: true, expectedReply: nil),
            RawResultCase(name: "error-type", raw: #"{"type":"system","subtype":"error","result":"boom-LEAK"}"#,
                          shouldFail: true, expectedReply: nil),
            RawResultCase(name: "error-subtype",
                          raw: #"{"type":"result","subtype":"error_max_turns","result":"boom-LEAK"}"#,
                          shouldFail: true, expectedReply: nil),
            RawResultCase(name: "empty-result-allowed",
                          raw: #"{"type":"result","subtype":"success","result":""}"#,
                          shouldFail: false, expectedReply: ""),
            RawResultCase(name: "valid-result",
                          raw: #"{"type":"result","subtype":"success","result":"正常回复"}"#,
                          shouldFail: false, expectedReply: "正常回复"),
        ]
        for rawCase in rawCases {
            let rawFake = try fixture.writeFakeClaude(
                in: work, name: "raw-\(rawCase.name)", nodePath: nodePath,
                recordDirectory: recordDirectory, mode: .chat, reply: "ignored",
                rawOutput: rawCase.raw
            )
            let rawService = makeService(
                claude: rawFake.executableURL, defaults: residentClaudeMakeDefaults("raw-\(rawCase.name)"),
                capture: ResidentClaudeRunCapture(), spawns: ResidentClaudeSpawnCounter(),
                environment: baseEnvironment
            )
            rawService.selectBackend(.claudeCode)
            if rawCase.shouldFail {
                var rawError: Error?
                var rawReply: String?
                do {
                    rawReply = try await rawService.send(
                        rawCase.name, worldContext: rawWorld, worldTools: rawTools("raw-room"),
                        userMessage: rawCase.name
                    )
                } catch { rawError = error }
                checks.check(rawError != nil, "严格校验 \(rawCase.name) 固定失败")
                checks.check(rawReply == nil, "严格校验 \(rawCase.name) 不返回成功回复")
                checks.check(!(rawError?.localizedDescription ?? "").contains("LEAK"),
                             "严格校验 \(rawCase.name) 不回显原始输出")
                checks.check(String(describing: rawError ?? CancellationError()).contains("claudeInvalidResult"),
                             "严格校验 \(rawCase.name) 为固定 Claude 结果错误")
            } else {
                let rawReply = try await rawService.send(
                    rawCase.name, worldContext: rawWorld, worldTools: rawTools("raw-room"),
                    userMessage: rawCase.name
                )
                checks.expectEqual(rawReply, rawCase.expectedReply ?? "", "严格校验 \(rawCase.name) 成功")
            }
        }

        // 14b) parser 直接行为断言：字段**存在即严格验型**，类型错误一律 nil，
        //      绝不用 `as?` 静默跳过；is_error 只接受真 JSON Bool（0/1 数值拒绝）。
        let parserCases: [(name: String, raw: String, expected: String?)] = [
            ("minimal", #"{"result":"最小"}"#, "最小"),
            ("terminal-valid", #"{"type":"result","subtype":"success","is_error":false,"result":"终端"}"#, "终端"),
            ("terminal-empty-string", #"{"type":"result","subtype":"success","result":""}"#, ""),
            ("is-error-true", #"{"is_error":true,"result":"x"}"#, nil),
            ("is-error-false-bool", #"{"is_error":false,"result":"x"}"#, "x"),
            ("is-error-zero-number", #"{"is_error":0,"result":"x"}"#, nil),
            ("is-error-one-number", #"{"is_error":1,"result":"x"}"#, nil),
            ("is-error-string", #"{"is_error":"false","result":"x"}"#, nil),
            ("is-error-null", #"{"is_error":null,"result":"x"}"#, nil),
            ("is-error-object", #"{"is_error":{"v":false},"result":"x"}"#, nil),
            ("type-number", #"{"type":1,"result":"x"}"#, nil),
            ("type-bool", #"{"type":true,"result":"x"}"#, nil),
            ("type-null", #"{"type":null,"result":"x"}"#, nil),
            ("type-object", #"{"type":{"v":"result"},"result":"x"}"#, nil),
            ("type-wrong", #"{"type":"system","result":"x"}"#, nil),
            ("subtype-number", #"{"type":"result","subtype":1,"result":"x"}"#, nil),
            ("subtype-null", #"{"type":"result","subtype":null,"result":"x"}"#, nil),
            ("subtype-wrong", #"{"type":"result","subtype":"error_max_turns","result":"x"}"#, nil),
            ("result-number", #"{"result":1}"#, nil),
            ("result-bool", #"{"result":true}"#, nil),
            ("result-null", #"{"result":null}"#, nil),
            ("result-missing", #"{"type":"result","subtype":"success"}"#, nil),
            ("top-level-array", #"["result"]"#, nil),
        ]
        for parserCase in parserCases {
            let parsed = AgentConversationService.parseClaudeResultOutput(parserCase.raw)
            checks.expectEqual(parsed, parserCase.expected, "parser \(parserCase.name) 严格验型")
        }

        // 15) P2-4 在途 MCP 取消/下一轮替代：spawn 前 checkCancellation；真实 MCP
        //     handler 在途时旧结果绝不进入新轮，授权文件与会话目录清理，adapter 有界退出。
        func sessionDirectory(from live: [String: Any]) -> String? {
            guard let configPath = live["mcpConfigPath"] as? String else { return nil }
            return URL(fileURLWithPath: configPath).deletingLastPathComponent().path
        }

        let inflightGate = ResidentClaudeGate()
        let inflightLog = ResidentClaudeToolCallLog()
        let inflightFake = try fixture.writeFakeClaude(
            in: work, name: "inflight-cancel", nodePath: nodePath, recordDirectory: recordDirectory,
            mode: .tool, reply: "在途：", toolName: "gmgn_world_tool_5", toolArguments: [:]
        )
        let inflightService = makeService(
            claude: inflightFake.executableURL, defaults: residentClaudeMakeDefaults("inflight-cancel"),
            capture: ResidentClaudeRunCapture(), spawns: ResidentClaudeSpawnCounter(),
            environment: baseEnvironment
        )
        inflightService.selectBackend(.claudeCode)
        let inflightWorld = residentClaudeMakeWorld("inflight-room")
        let inflightTools = ResidentConversationTools(
            worldID: "inflight-room", schemasJSON: fixture.schemas,
            call: { callID, canonicalName, argumentsJSON in
                inflightLog.append(callID: callID, canonicalName: canonicalName, argumentsJSON: argumentsJSON)
                await inflightGate.wait()
                return ResidentCodexToolReply(
                    resultJSON: fixture.data(["marker": "old-inflight-LEAK"]), isError: false
                )
            },
            cancel: {}
        )
        let inflightTask = Task { @MainActor in
            do {
                _ = try await inflightService.send(
                    "在途", worldContext: inflightWorld, worldTools: inflightTools, userMessage: "在途"
                )
                return "returned"
            } catch {
                return "cancelled"
            }
        }
        var inflightWaited = 0
        while inflightLog.count == 0 && inflightWaited < 600 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            inflightWaited += 1
        }
        checks.expectEqual(inflightLog.count, 1, "真实 MCP handler 在途")
        var inflightLive: [String: Any] = [:]
        var inflightLiveWaited = 0
        while (inflightLive["adapterPid"] == nil || inflightLive["mcpConfigPath"] == nil)
            && inflightLiveWaited < 400 {
            inflightLive = fixture.readLive(inflightFake.recordPath) ?? [:]
            if inflightLive["adapterPid"] == nil { try? await Task.sleep(nanoseconds: 5_000_000) }
            inflightLiveWaited += 1
        }
        let inflightDir = sessionDirectory(from: inflightLive)
        let inflightAdapterPID = (inflightLive["adapterPid"] as? NSNumber)?.int32Value
        checks.check(inflightDir != nil, "在途 MCP 会话目录已记录")
        checks.check(inflightAdapterPID != nil, "在途 MCP adapter 记录真实 pid")
        if let dir = inflightDir {
            checks.check(
                FileManager.default.fileExists(atPath: dir + "/" + ResidentClaudeMCPAdapter.grantFilename),
                "在途时 MCP 授权文件真实存在"
            )
        }
        inflightTask.cancel()
        let inflightOutcome = await inflightTask.value
        checks.expectEqual(inflightOutcome, "cancelled", "直接 Task 取消在途轮次返回取消")
        if let dir = inflightDir {
            checks.check(await residentClaudeWaitForRemoval(dir), "取消后 MCP 会话目录已清理")
            checks.check(
                !FileManager.default.fileExists(atPath: dir + "/" + ResidentClaudeMCPAdapter.grantFilename),
                "取消后 MCP 授权文件已删除"
            )
        }
        if let pid = inflightAdapterPID {
            checks.check(await residentClaudeWaitForPIDExit(pid), "取消后 MCP adapter 有界退出并回收")
        }
        await inflightGate.open()

        let replaceGate = ResidentClaudeGate()
        let replaceLog = ResidentClaudeToolCallLog()
        let replaceOldFake = try fixture.writeFakeClaude(
            in: work, name: "replace-old", nodePath: nodePath, recordDirectory: recordDirectory,
            mode: .tool, reply: "旧轮：", toolName: "gmgn_world_tool_2", toolArguments: [:]
        )
        let replaceService = makeService(
            claude: replaceOldFake.executableURL, defaults: residentClaudeMakeDefaults("replace"),
            capture: ResidentClaudeRunCapture(), spawns: ResidentClaudeSpawnCounter(),
            environment: baseEnvironment
        )
        replaceService.selectBackend(.claudeCode)
        let replaceWorld = residentClaudeMakeWorld("replace-room")
        let replaceOldTools = ResidentConversationTools(
            worldID: "replace-room", schemasJSON: fixture.schemas,
            call: { callID, canonicalName, argumentsJSON in
                replaceLog.append(callID: callID, canonicalName: canonicalName, argumentsJSON: argumentsJSON)
                await replaceGate.wait()
                return ResidentCodexToolReply(
                    resultJSON: fixture.data(["marker": "old-inflight-LEAK"]), isError: false
                )
            },
            cancel: {}
        )
        let replaceOldTask = Task { @MainActor in
            do {
                _ = try await replaceService.send(
                    "第一轮", worldContext: replaceWorld, worldTools: replaceOldTools, userMessage: "第一轮"
                )
                return "old-returned"
            } catch {
                return "old-cancelled"
            }
        }
        var replaceWaited = 0
        while replaceLog.count == 0 && replaceWaited < 600 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            replaceWaited += 1
        }
        checks.expectEqual(replaceLog.count, 1, "替代场景旧 MCP handler 在途")
        var replaceLive: [String: Any] = [:]
        var replaceLiveWaited = 0
        while (replaceLive["adapterPid"] == nil || replaceLive["mcpConfigPath"] == nil)
            && replaceLiveWaited < 400 {
            replaceLive = fixture.readLive(replaceOldFake.recordPath) ?? [:]
            if replaceLive["adapterPid"] == nil { try? await Task.sleep(nanoseconds: 5_000_000) }
            replaceLiveWaited += 1
        }
        let replaceOldDir = sessionDirectory(from: replaceLive)
        let replaceOldAdapterPID = (replaceLive["adapterPid"] as? NSNumber)?.int32Value
        let replaceNewTools = ResidentConversationTools(
            worldID: "replace-room", schemasJSON: fixture.schemas,
            call: { _, _, _ in
                ResidentCodexToolReply(
                    resultJSON: fixture.data(["marker": "new-round-marker"]), isError: false
                )
            },
            cancel: {}
        )
        let replaceNewReply = try await replaceService.send(
            "第二轮", worldContext: replaceWorld, worldTools: replaceNewTools, userMessage: "第二轮"
        )
        let replaceOldOutcome = await replaceOldTask.value
        checks.expectEqual(replaceOldOutcome, "old-cancelled", "旧轮被下一轮替代后返回取消")
        checks.check(!replaceNewReply.contains("old-inflight-LEAK"), "旧在途结果不会进入新轮")
        checks.check(replaceNewReply.contains("new-round-marker"), "新轮在替代后仍正常完成")
        if let dir = replaceOldDir {
            checks.check(await residentClaudeWaitForRemoval(dir), "替代后旧 MCP 会话目录已清理")
        }
        if let pid = replaceOldAdapterPID {
            checks.check(await residentClaudeWaitForPIDExit(pid), "替代后旧 MCP adapter 有界退出并回收")
        }
        await replaceGate.open()

        // 16) 环境白名单对抗真实 preload：受控 --require 文件若被执行会写 marker；
        //     把 NODE_OPTIONS/NODE_PATH 污染交给生产 ResidentClaudeEnvironment.make。
        let preloadMarker = work.appendingPathComponent("preload-marker-\(UUID().uuidString)")
        let preloadScript = work.appendingPathComponent("preload-\(UUID().uuidString).cjs")
        let preloadSource = "require('node:fs').writeFileSync(\(fixture.jsLiteral(preloadMarker.path)), 'executed')\n"
        try Data(preloadSource.utf8).write(to: preloadScript, options: [.atomic])
        var preloadEnvironment = ProcessInfo.processInfo.environment
        preloadEnvironment["ANTHROPIC_API_KEY"] = fixture.apiKey
        preloadEnvironment["NODE_OPTIONS"] = "--require \(preloadScript.path)"
        preloadEnvironment["NODE_PATH"] = fixture.injectedNodePath
        let preloadConfigDirectory = work.appendingPathComponent("preload-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: preloadConfigDirectory, withIntermediateDirectories: true)
        let madeEnvironment = ResidentClaudeEnvironment.make(
            base: preloadEnvironment, configDirectory: preloadConfigDirectory
        )
        checks.check(madeEnvironment?["NODE_OPTIONS"] == nil, "生产白名单剔除 NODE_OPTIONS 注入")
        checks.check(madeEnvironment?["NODE_PATH"] == nil, "生产白名单剔除 NODE_PATH 注入")
        checks.check(madeEnvironment?["ANTHROPIC_API_KEY"] == fixture.apiKey, "生产白名单保留显式 apiKey")
        let preloadLog = ResidentClaudeToolCallLog()
        let preloadTools = ResidentConversationTools(
            worldID: "preload-room", schemasJSON: fixture.schemas,
            call: { callID, canonicalName, argumentsJSON in
                preloadLog.append(callID: callID, canonicalName: canonicalName, argumentsJSON: argumentsJSON)
                return ResidentCodexToolReply(
                    resultJSON: fixture.data(["marker": "preload-ok"]), isError: false
                )
            },
            cancel: {}
        )
        let preloadFake = try fixture.writeFakeClaude(
            in: work, name: "preload", nodePath: nodePath, recordDirectory: recordDirectory,
            mode: .tool, reply: "预载：", toolName: "gmgn_world_tool_8", toolArguments: [:]
        )
        let preloadService = makeService(
            claude: preloadFake.executableURL, defaults: residentClaudeMakeDefaults("preload"),
            capture: ResidentClaudeRunCapture(), spawns: ResidentClaudeSpawnCounter(),
            environment: preloadEnvironment
        )
        preloadService.selectBackend(.claudeCode)
        let preloadWorld = residentClaudeMakeWorld("preload-room")
        let preloadReply = try await preloadService.send(
            "预载测试", worldContext: preloadWorld, worldTools: preloadTools, userMessage: "预载测试"
        )
        checks.expectEqual(preloadLog.count, 1, "受污染环境下真实工具回路仍完成")
        checks.check(preloadReply.contains("preload-ok"), "受污染环境下工具结果回到 CLI")
        checks.check(!FileManager.default.fileExists(atPath: preloadMarker.path),
                     "受控 preload 从未被执行（marker 不存在）")
        let preloadCliEnvironment = (fixture.readRecord(preloadFake.recordPath) ?? ["env": [:]])["env"]
            as? [String: String] ?? [:]
        checks.check(preloadCliEnvironment["NODE_OPTIONS"] == nil, "假 CLI 环境无 NODE_OPTIONS 注入")
        checks.check(preloadCliEnvironment["NODE_PATH"] == nil, "假 CLI 环境无 NODE_PATH 注入")

        print("\(checks.result ? "PASS" : "FAIL"): \(checks.passed) resident-claude service checks, \(checks.failures.count) failures")
        exit(checks.result ? 0 : 1)
    }
}

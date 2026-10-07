// 居民 DSH「真实原生工具注册 + 宿主调用链」离线组装验证。
//
// 编译并运行生产文件
//   apps/macos/Sources/GMGNRadio/Agent/ResidentDSHAgentToolBridge.swift
//   apps/macos/Sources/GMGNRadio/Agent/ResidentDSHHostToolsBridge.swift
// 与 tools/resident-dsh-host-tools-support.swift；以**真实安装的 DSH runtime**
// （`dsh --profile headless --patch`）+ 本地 mock DeepSeek provider（无真实模型、
// 无网络外联、无 App）跑完整链路：
//
//   宿主按本轮正式 schemas 生成 grant + 真实 JS 插件 → dsh 单进程启动（受限
//   overlay，与生产同款禁用集）→ 插件 ctx.tools.register 原生注册 gmgn_* →
//   模型原生 function call → DSH 派发插件 execute → 私有 HTTP /rpc 回宿主 →
//   宿主 secret/名称边界/原 schema 复核/授权闸后执行测试宿主工具 → 规范 JSON 回
//   插件 → DSH agent loop 在同一运行内把工具结果回灌模型 → 真实 final 正文。
//
// 环境变量：
//   DSH_BIN         dsh 可执行路径（默认 ~/.local/bin/dsh）
//   MOCK_BASE_URL   mock provider base（无 /v1 后缀）
//   REQUESTS_FILE   可选：mock 捕获的请求 JSONL（组装后断言用）
import Foundation

// MARK: - 进程辅助

struct AssemblyProcessResult: Sendable {
    let exitCode: Int32
    let output: String
    let errorOutput: String
}

func runAssemblyProcess(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    cwd: URL,
    timeout: TimeInterval
) async -> AssemblyProcessResult {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    var merged = ProcessInfo.processInfo.environment
    for (key, value) in environment { merged[key] = value }
    process.environment = merged
    process.currentDirectoryURL = cwd
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    let stdin = Pipe()
    process.standardInput = stdin.fileHandleForReading
    let outputTask = Task.detached(priority: .utility) {
        (try? outPipe.fileHandleForReading.readToEnd()).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
    let errorTask = Task.detached(priority: .utility) {
        (try? errPipe.fileHandleForReading.readToEnd()).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        process.terminationHandler = { _ in continuation.resume() }
        do {
            try process.run()
        } catch {
            continuation.resume()
        }
    }
    let watchdog = Task {
        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        if process.isRunning {
            process.terminate()
            try? await Task.sleep(nanoseconds: 500_000_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
    // terminationHandler 已确保结束；等输出读尽并取消看门狗。
    _ = await (outputTask.result, errorTask.result)
    watchdog.cancel()
    return AssemblyProcessResult(
        exitCode: process.terminationStatus,
        output: await outputTask.value,
        errorOutput: await errorTask.value
    )
}

func loadRequestLines(_ path: String) -> [[String: Any]] {
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    return content.split(separator: "\n").compactMap { line in
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return object
    }
}

// MARK: - 主入口

@main
struct ResidentDSHNativeAssembly {
    static func main() async throws {
        var checks = ResidentDSHHostChecks()
        let environment = ProcessInfo.processInfo.environment
        let dshBin = environment["DSH_BIN"] ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/dsh").path
        guard let mockBase = environment["MOCK_BASE_URL"], !mockBase.isEmpty else {
            checks.check(false, "缺少 MOCK_BASE_URL")
            printResult(checks)
            return
        }
        let requestsFile = environment["REQUESTS_FILE"] ?? ""

        let work = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gmgn-dsh-native-assembly-\(UUID().uuidString.prefix(8))", isDirectory: true
        )
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let home = work.appendingPathComponent("home", isDirectory: true)
        let cwd = work.appendingPathComponent("cwd", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        // 1) 宿主通道：本轮正式工具（生产同形 schemas）armed。
        let log = ResidentDSHHostCallLog()
        let registrations = try ResidentDSHHostToolSet.parse(schemasJSON: ResidentDSHHostSupportSchema.schemas)
        let channel = try ResidentDSHHostToolsChannel.start(
            configuration: ResidentDSHHostToolsChannel.Configuration(
                scope: "world.cabin", worldID: "cabin-1",
                registrations: registrations,
                handler: residentDSHHostToolsTestHandler(log: log, scope: "world.cabin")
            )
        )
        defer { channel.stop() }
        checks.check(FileManager.default.fileExists(atPath: channel.pluginFileURL.path), "A1 插件文件已生成")
        checks.check(FileManager.default.fileExists(atPath: channel.grantFileURL.path), "A1 grant 文件已生成")

        // 2) 受限 overlay：与生产 dshRestrictedPatchYAML 相同方向的禁用集 +
        //    tools mode native + host-tools 插件行。ASSEMBLY_PHASE=direct 时插件以
        //    「普通 composition 行」挂载（ACP 持久 composition 的形态），否则用
        //    `insert:` 包装（headless --patch overlay 的形态）。
        var rows: [String] = []
        rows.append("""
        - id: tools
          config:
            mode: native
        """)
        for id in [
            "code-runtime", "tool-bash", "tool-pwsh", "tool-jobs", "tool-fs",
            "tool-fs-search", "tool-str-replace-editor", "agent-instructions",
            "skill-filesystem", "tool-skill", "plan-mode",
            "tool-subagent-control", "tool-subagent-list-agents", "tool-subagent",
            "tool-subagent-fork", "tool-subagent-report", "workflow-worker-thread",
            "tool-workflow", "tool-result-pruner", "tool-todo", "tool-goal", "tool-ralph",
        ] {
            rows.append("- id: \(id)\n  disabled: true")
        }
        rows.append(ResidentDSHHostToolsOverlay.hostToolsRows(pluginFileURL: channel.pluginFileURL))
        let overlay = rows.joined(separator: "\n") + "\n"
        let overlayURL = work.appendingPathComponent("restricted-native.patch.yml")
        try overlay.write(to: overlayURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: overlayURL.path)
        checks.expectContains(overlay, "gmgn-host-tools", "A2 overlay 含插件行")

        // 3) 跑真实 DSH（mock provider 只回环）。
        let prompt = "请用许愿机正式工具查询当前许愿任务状态，然后把查询结果汇报给我。"
        let result = await runAssemblyProcess(
            executableURL: URL(fileURLWithPath: dshBin),
            arguments: ["--profile", "headless", "--patch", overlayURL.path, prompt],
            environment: [
                "DSH_HOME": home.path,
                "DEEPSEEK_BASE_URL": mockBase + "/v1",
                "DEEPSEEK_API_KEY": "mock-key",
            ],
            cwd: cwd,
            timeout: 170
        )
        checks.expectEqual(result.exitCode, 0, "A3 dsh 退出码 0（实际 \(result.exitCode)）")
        if result.exitCode != 0 {
            print("  dsh stderr tail: \(String(result.errorOutput.suffix(2000)))")
        }
        checks.expectContains(result.output, "GMGN_NATIVE_ASSEMBLY_FINAL_OK", "A3 真实 final 正文回到 stdout")
        if !result.output.contains("GMGN_NATIVE_ASSEMBLY_FINAL_OK") {
            print("  dsh stdout: \(result.output)")
        }

        // 4) 宿主确实执行了一次正式工具（同一次 agent 运行内）。
        checks.expectEqual(log.count, 1, "A4 宿主执行恰好一次")
        checks.check(log.contains(canonical: "read_wish_generation"), "A4 执行的是 read_wish_generation")

        // mock 增量落盘线程可能稍后于 dsh 退出；短暂等待后读取。
        try await Task.sleep(nanoseconds: 700_000_000)

        // 5) mock 捕获的请求体：模型真正看到了原生 gmgn 工具、没有文本信封；
        //    且受限 overlay 生效（无 bash/fs 等工具）。
        if !requestsFile.isEmpty {
            let requests = loadRequestLines(requestsFile)
            var sawGmgn = false
            var sawWebSearch = false
            var toolNames: [String] = []
            var sawToolMessage = false
            var toolMessageText = ""
            for request in requests {
                let body = request["body"] as? [String: Any] ?? [:]
                if let tools = body["tools"] as? [[String: Any]] {
                    for tool in tools {
                        let function = tool["function"] as? [String: Any]
                        if let name = function?["name"] as? String {
                            toolNames.append(name)
                            if name == "gmgn_read_wish_generation" { sawGmgn = true }
                            if name == "web_search" { sawWebSearch = true }
                        }
                    }
                }
                if let messages = body["messages"] as? [[String: Any]] {
                    for message in messages where (message["role"] as? String) == "tool" {
                        sawToolMessage = true
                        if let content = message["content"] as? String { toolMessageText += content }
                    }
                }
            }
            let unique = Array(Set(toolNames)).sorted()
            print("  [evidence] 模型请求里的工具列表: \(unique.joined(separator: ", "))")
            checks.check(sawGmgn, "A5 模型请求包含原生 gmgn_read_wish_generation（真实注册）")
            checks.check(sawWebSearch, "A5 原生 web seam 保留（web_search 可见）")
            for forbidden in ["bash", "write", "edit", "read", "read_image", "grep", "glob", "run_code"] {
                if unique.contains(forbidden) {
                    checks.check(false, "A5 受限 overlay 应禁用 \(forbidden)")
                }
            }
            checks.expectEqual(unique.filter { $0.hasPrefix("gmgn_") }.count, 2, "A5 恰好两个 gmgn_ 工具")
            checks.check(sawToolMessage, "A6 同一次运行出现 tool role 消息（结果回灌同会话）")
            checks.expectContains(toolMessageText, "running", "A6 工具结果文本回到模型（render 的规范值）")
        } else {
            checks.check(true, "A5 未配置 REQUESTS_FILE，跳过请求体断言")
        }

        printResult(checks)
    }

    static func printResult(_ checks: ResidentDSHHostChecks) {
        let passed = checks.failures.isEmpty
        print("\(passed ? "PASS" : "FAIL"): \(checks.passed) resident DSH native-assembly checks, \(checks.failures.count) failures")
        exit(passed ? 0 : 1)
    }
}

// 居民 DSH「真实 ACP 原生宿主工具链」离线组装验证。
//
// 编译并运行生产文件
//   apps/macos/Sources/GMGNRadio/Agent/ResidentDSHAgentToolBridge.swift
//   apps/macos/Sources/GMGNRadio/Agent/ResidentDSHHostToolsBridge.swift
//   apps/macos/Sources/GMGNRadio/Agent/ResidentDSHConfiguration.swift
//   apps/macos/Sources/GMGNRadio/Agent/ResidentDSHTransport.swift
// 与 tools/resident-dsh-host-tools-support.swift；用**真实安装的 DSH ACP runtime**
// （@deepseek-ai/dsh-acp-demo 的 ACP 入口 `--config`）+ 本地内容驱动 mock provider
// 跑完整链路 —— 不是 headless 形态、不是单元 fake：
//
//   宿主按本轮正式 schemas 生成 grant + 真实 JS 插件 → ACP composition（普通行，
//   含 gmgn-host-tools 私有插件行，经 ResidentDSHComposition 生产发射与读回校验）
//   → 真实 dsh-acp-demo 进程启动 → 插件 ctx.tools.register 原生注册 gmgn_* →
//   ACP 同会话两轮 prompt：模型原生 function call → 插件 execute → 私有 UDS IPC 回
//   宿主（名称边界/原 schema 复核/执行前授权复核）→ 宿主工具执行 → 规范 JSON 回插件
//   → DSH agent 在同一 ACP 会话把工具结果回灌模型并继续到普通 final。
//
// 轮次语义（真实 runtime 上验证每轮授权不可跨轮复用）：
//   R1 armed：原生工具调用执行一次，结果回到同会话、继续到普通 final；
//   R2 revoked：模型仍会发起原生调用，但插件/grant 已撤销 → 宿主零执行，会话仍正常
//     结束（普通 final）—— 撤销后旧调用不借新授权执行；
//   cancel 轮：mock 对携带 gmgn 工具的首个请求只开流不回写（stall），宿主取消 ACP
//     prompt → 该轮不产生任何宿主执行；取消 settle 后同会话仍可用；
//   R3 重新 arm：新代/新 secret，原生工具调用再次执行（宿主 +1）、普通 final，
//     与 R1 同一 ACP sessionID。
//
// 环境变量：
//   NODE_BIN        node 可执行路径（默认 /opt/homebrew/bin/node）
//   GMGN_DSH_ACP_ENTRY  acp-demo 入口（默认 locateNativeTransport 的既有路径）
//   MOCK_BASE_URL   mock provider base（无 /v1 后缀）
//   CONTROL_FILE    mock 策略文件路径（tool/final/stall，本 harness 轮次间改写）
//   REQUESTS_FILE   可选：mock 捕获的请求 JSONL（组装后断言用）
//   KEEP_ACPSANDBOX 非空时保留 sandbox/诊断（stderr 落盘等）
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let work = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-dsh-acp-native-assembly-\(UUID().uuidString.prefix(8))", isDirectory: true)
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

let harness = #"""
import Foundation

// ── 离线 ACP 组装测试的最小共享类型占位 ──
// 只含 ResidentDSHConfiguration.swift / ResidentDSHTransport.swift 实际引用的成员；
// 与真实 AgentConversationService.swift 同签名、绝不与其同模块编译。
enum AgentConversationError: Error {
    case dshSecurityPatchUnavailable
    case dshNativeTurnFailed(DSHExecutionFailureReason)
}
struct DSHExecutionFailureReason: Sendable {
    let diagnostic: String
    init(diagnostic: String) { self.diagnostic = diagnostic }
}
protocol AgentExecutableLocating: Sendable {
    func locate(executableNames: [String]) -> URL?
}
struct HarnessLocator: AgentExecutableLocating {
    let node: URL?
    func locate(executableNames: [String]) -> URL? {
        if executableNames.contains("node") { return node }
        return nil
    }
}

@main
struct ResidentDSHACPNativeAssembly {
    @MainActor static func main() async throws {
        var checks = ResidentDSHHostChecks()
        let environment = ProcessInfo.processInfo.environment
        guard let mockBase = environment["MOCK_BASE_URL"], !mockBase.isEmpty else {
            checks.check(false, "缺少 MOCK_BASE_URL")
            printResult(checks)
            return
        }
        let requestsFile = environment["REQUESTS_FILE"] ?? ""
        let controlFile = environment["CONTROL_FILE"] ?? ""
        let keepSandbox = environment["KEEP_ACPSANDBOX"] != nil
        let nodePath = environment["NODE_BIN"] ?? "/opt/homebrew/bin/node"
        guard FileManager.default.isExecutableFile(atPath: nodePath) else {
            checks.check(false, "node 不可执行：\(nodePath)")
            printResult(checks)
            return
        }
        // 总看门狗：整套组装必须远低于此上界退出。
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 200_000_000_000)
            print("FAIL: ACP assembly watchdog timeout (200s)")
            exit(1)
        }
        defer { watchdog.cancel() }

        // 私有 DSH_HOME / 诊断目录（绝不触碰真实凭据）。
        let diagRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gmgn-acp-diag-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: diagRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { if !keepSandbox { try? FileManager.default.removeItem(at: diagRoot) } }
        let privateDSHHome = diagRoot.appendingPathComponent("dshhome", isDirectory: true)
        try FileManager.default.createDirectory(at: privateDSHHome, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        func writeControl(_ value: String) {
            if !controlFile.isEmpty {
                try? Data((value + "\n").utf8).write(to: URL(fileURLWithPath: controlFile), options: [.atomic])
            }
        }

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
        checks.check(FileManager.default.fileExists(atPath: channel.pluginFileURL.path), "B1 宿主插件文件已生成")
        checks.check(FileManager.default.fileExists(atPath: channel.grantFileURL.path), "B1 grant 文件已生成（armed）")

        // 2) 真实 ACP composition：生产发射 + 生产读回校验（含私有插件行）。
        var acpEnvironment = environment
        acpEnvironment["HOME"] = diagRoot.path
        guard let transport = ResidentDSHComposition.locateNativeTransport(
            using: HarnessLocator(node: URL(fileURLWithPath: nodePath)),
            environment: acpEnvironment
        ) else {
            checks.check(false, "未找到真实 DSH ACP 入口（GMGN_DSH_ACP_ENTRY / HOME 下 acp-demo bin.js）")
            printResult(checks)
            return
        }
        // Match Unity's production lifecycle: tools are unarmed during the
        // handshake, then armed only for the admitted foreground prompt.
        channel.revoke()
        let bootstrapURL = channel.pluginFileURL.deletingLastPathComponent().appendingPathComponent("gmgn-host-tools.bootstrap.json")
        let bootstrap = try JSONSerialization.jsonObject(with: Data(contentsOf: bootstrapURL)) as? [String: Any]
        checks.check(Set(bootstrap?.keys.map { $0 } ?? []) == ["tools"], "B2 bootstrap 只含定义，不含密钥/端点/授权")
        checks.check(!FileManager.default.fileExists(atPath: channel.grantFileURL.path), "B2 握手前授权已撤销，定义仍可读")
        let sandbox = try ResidentDSHComposition.makeResidentSandbox(
            resolvingFrom: transport.entry,
            hostToolsPluginPath: channel.pluginFileURL.path
        )
        defer { if !keepSandbox { sandbox.removeAll() } }
        checks.expectContains(sandbox.compositionText, "gmgn-host-tools", "B2 composition 含私有插件行")
        checks.expectContains(sandbox.compositionText, channel.pluginFileURL.path, "B2 插件行指向真实插件路径")
        checks.check(ResidentDSHComposition.validateComposedConfig(
            sandbox.compositionText, hostToolsPluginPath: channel.pluginFileURL.path
        ), "B2 composition 通过生产读回校验")

        // 3) 真实 ACP runtime（acp-demo 入口）经生产 ResidentDSHConnector 驱动。
        let stderrURL = diagRoot.appendingPathComponent("acp.stderr.log")
        let connector = ResidentDSHConnector(
            nodeExecutable: URL(fileURLWithPath: nodePath),
            entryPoint: transport.entry,
            compositionFileURL: sandbox.compositionFileURL,
            requestTimeout: 150,
            cancellationGrace: 4,
            environmentOverrides: [
                "DSH_HOME": privateDSHHome.path,
                "DEEPSEEK_BASE_URL": mockBase + "/v1",
                "DEEPSEEK_API_KEY": "mock-key",
            ],
            stderrFileURL: stderrURL
        )
        let handle: ResidentDSHSessionHandle
        do {
            handle = try await connector.openSession(cwd: sandbox.workspace)
        } catch {
            checks.check(false, "B3 ACP 会话建立失败：\(error)")
            if let text = try? String(contentsOf: stderrURL, encoding: .utf8) {
                print("  acp stderr tail: \(String(text.suffix(3000)))")
            }
            connector.close()
            printResult(checks)
            return
        }
        checks.check(!handle.sessionID.isEmpty, "B3 ACP sessionID 非空")
        checks.expectEqual(handle.imagePromptCapability, true, "B3 服务端声明 image prompt 能力（原生图片通道保留）")

        // 4) R1（armed）：原生工具调用执行、结果回同会话、普通 final。
        writeControl("tool")
        let round1Prompt = "请用许愿机正式工具查询当前许愿任务状态，然后用一句话把结果告诉我。"
        let round1Reply: String
        do {
            try channel.arm(worldRevision: 7)
            round1Reply = try await connector.prompt(sessionID: handle.sessionID, blocks: [ResidentDSHPromptBlock.text(round1Prompt)])
        } catch {
            checks.check(false, "B4 R1 prompt 失败：\(error)")
            if let text = try? String(contentsOf: stderrURL, encoding: .utf8) {
                print("  acp stderr tail: \(String(text.suffix(3000)))")
            }
            connector.close()
            printResult(checks)
            return
        }
        checks.expectEqual(log.count, 1, "B4 R1 宿主执行恰好一次")
        checks.check(log.contains(canonical: "read_wish_generation"), "B4 R1 执行 read_wish_generation")
        checks.expectContains(round1Reply, "GMGN_ACP_NATIVE_ASSEMBLY_FINAL_OK", "B4 R1 普通 final 正文")

        // 5) R2（revoked）：模型仍发起原生调用但宿主零执行、会话仍正常结束。
        channel.revoke()
        checks.check(!FileManager.default.fileExists(atPath: channel.grantFileURL.path), "B5 revoke 删除 grant")
        let round2Prompt = "请再查一次许愿机状态并告诉我。"
        var round2Reply = ""
        do {
            round2Reply = try await connector.prompt(sessionID: handle.sessionID, blocks: [ResidentDSHPromptBlock.text(round2Prompt)])
        } catch {
            checks.check(false, "B5 R2 prompt 失败：\(error)")
            if let text = try? String(contentsOf: stderrURL, encoding: .utf8) {
                print("  acp stderr tail: \(String(text.suffix(3000)))")
            }
        }
        checks.expectEqual(log.count, 1, "B5 revoke 后旧授权调用零执行")
        checks.expectContains(round2Reply, "GMGN_ACP_NATIVE_ASSEMBLY_FINAL_OK", "B5 R2 会话仍正常到普通 final")

        // 6) cancel 轮（mock stall + 宿主取消）：该轮零宿主执行、取消 settle 后同会话可用。
        writeControl("stall")
        let cancelPrompt = "只做一句普通回答，不要调用任何工具。"
        let cancelled = Task { () -> String in
            try await connector.prompt(sessionID: handle.sessionID, blocks: [ResidentDSHPromptBlock.text(cancelPrompt)])
        }
        try await Task.sleep(nanoseconds: 900_000_000)
        connector.cancelActivePrompt()
        var cancelThrew = false
        do {
            let returned = try await cancelled.value
            checks.check(false, "B6 被取消的 prompt 必须抛错（不能返回正文）")
        } catch is CancellationError {
            cancelThrew = true
            checks.check(true, "B6 取消的 ACP prompt 以 CancellationError 结束")
        } catch {
            checks.check(false, "B6 取消的 ACP prompt 抛错类型不符：\(error)")
        }
        await connector.awaitCancellationSettled()
        try await Task.sleep(nanoseconds: 200_000_000)
        checks.check(cancelThrew, "B6 取消轮被中止")
        checks.expectEqual(log.count, 1, "B6 取消轮零宿主执行")
        checks.check(connector.isUsable, "B6 优雅取消后同会话连接仍可用")

        // 7) R3（重新 arm，新代/新 secret）：同会话原生工具再次执行、普通 final。
        writeControl("tool")
        try channel.arm(worldRevision: 7)
        let round3Reply = try await connector.prompt(sessionID: handle.sessionID, blocks: [ResidentDSHPromptBlock.text("请再次用许愿机工具查询状态并把结果告诉我。")])
        checks.expectEqual(log.count, 2, "B7 R3 重新 arm 后宿主再次执行一次")
        checks.expectContains(round3Reply, "GMGN_ACP_NATIVE_ASSEMBLY_FINAL_OK", "B7 R3 普通 final 正文")

        connector.close()
        channel.stop()

        // 8) mock 捕获的请求体断言：gmgn 工具原生可见、工具结果回到同会话、
        //    受限 overlay 生效（无 bash/fs 等本地工具）。
        try await Task.sleep(nanoseconds: 500_000_000)
        if !requestsFile.isEmpty {
            let content = (try? String(contentsOfFile: requestsFile, encoding: .utf8)) ?? ""
            var sawGmgn = false
            var sawWebSearch = false
            var sawToolResult = false
            var toolResultText = ""
            var forbiddenSeen: [String] = []
            for line in content.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let body = object["body"] as? [String: Any] else { continue }
                if let tools = body["tools"] as? [[String: Any]] {
                    for tool in tools {
                        let function = tool["function"] as? [String: Any]
                        guard let name = function?["name"] as? String else { continue }
                        if name == "gmgn_read_wish_generation" { sawGmgn = true }
                        if name == "web_search" { sawWebSearch = true }
                        if ["bash", "write", "edit", "read", "read_image", "grep", "glob", "run_code"].contains(name) {
                            forbiddenSeen.append(name)
                        }
                    }
                }
                if let messages = body["messages"] as? [[String: Any]] {
                    for message in messages where (message["role"] as? String) == "tool" {
                        sawToolResult = true
                        if let content = message["content"] as? String { toolResultText += content }
                    }
                }
            }
            checks.check(sawGmgn, "B8 模型请求含原生 gmgn_read_wish_generation（真实注册）")
            checks.check(sawWebSearch, "B8 原生 web seam 保留（web_search 可见）")
            checks.check(forbiddenSeen.isEmpty, "B8 受限 overlay 生效（禁用的本地工具未出现：\(forbiddenSeen)）")
            checks.check(sawToolResult, "B9 role=tool 消息回到同一 ACP 会话（结果回灌同运行）")
            checks.expectContains(toolResultText, "running", "B9 工具结果文本回到模型（宿主规范值）")
        } else {
            checks.check(true, "B8 未配置 REQUESTS_FILE，跳过请求体断言")
        }

        printResult(checks)
    }

    static func printResult(_ checks: ResidentDSHHostChecks) {
        let passed = checks.failures.isEmpty
        print("\(passed ? "PASS" : "FAIL"): \(checks.passed) resident DSH ACP native-assembly checks, \(checks.failures.count) failures")
        exit(passed ? 0 : 1)
    }
}
"""#

let main = work.appendingPathComponent("Main.swift")
try harness.write(to: main, atomically: true, encoding: .utf8)
let binary = work.appendingPathComponent("test")
let compile = Process()
compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
let agentBridge = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/ResidentDSHAgentToolBridge.swift").path
let hostBridge = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/ResidentDSHHostToolsBridge.swift").path
let configuration = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/ResidentDSHConfiguration.swift").path
let transport = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/ResidentDSHTransport.swift").path
let support = root.appendingPathComponent("tools/resident-dsh-host-tools-support.swift").path
let retry = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/RetryBackoff.swift").path
// 编译门与主代理验收一致：`-swift-version 6 -parse-as-library` 真实编译并运行。
compile.arguments = ["-swift-version", "6", "-parse-as-library", "-j1",
                     agentBridge, hostBridge, configuration, transport, support, retry,
                     main.path, "-o", binary.path]
compile.currentDirectoryURL = work
try compile.run()
let compileDeadline = Date().addingTimeInterval(180)
while compile.isRunning && Date() < compileDeadline {
    try await Task.sleep(nanoseconds: 100_000_000)
}
if compile.isRunning {
    compile.terminate()
    print("FAIL: ACP assembly compile exceeded 180s")
    exit(124)
}
compile.waitUntilExit()
guard compile.terminationStatus == 0 else {
    print("COMPILE FAILED (exit \(compile.terminationStatus))")
    exit(compile.terminationStatus)
}
let test = Process()
test.executableURL = binary
try test.run()
let runDeadline = Date().addingTimeInterval(220)
while test.isRunning && Date() < runDeadline {
    try await Task.sleep(nanoseconds: 100_000_000)
}
if test.isRunning {
    test.terminate()
    print("FAIL: ACP assembly execution exceeded 220s")
    exit(124)
}
test.waitUntilExit()
print("acp-native assembly exit=\(test.terminationStatus)")
exit(test.terminationStatus)

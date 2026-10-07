// 居民图片输入的两道判据诊断（离线，零模型额度）。
//
// 为什么需要它：真机上「图片没送达」只表现为一句 UI 文案，而图片链上没有日志，
// 无法区分是**哪一道判据**断的，也无法区分「判据本身不成立」与「判据成立但图片
// 没走到 send()」。本诊断不启动 app、不调用模型、不读真实凭据，只做两件事：
//
//   1. 用**生产同一段代码**（`ResidentDSHComposition.makeResidentSandbox` +
//      `ResidentDSHHostToolsChannel.start` + `declaresImageInput`）在
//      「带世界工具私有插件行」这一真实形状下重算判据 B；
//   2. 用生产 `ResidentDSHConnector` 走一次官方 ACP `initialize` + `session/new`
//      （这两步不发 prompt、不消耗额度），读出判据 A 的真实取值。
//
// 注意：`initialize`/`session/new` 不产生任何模型请求；本工具绝不发送 prompt。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let work = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-dsh-image-gates-\(UUID().uuidString.prefix(8))", isDirectory: true)
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

let harness = #"""
import Foundation

@main struct Gates {
    @MainActor static func main() async {
        var failures = 0
        func report(_ name: String, _ value: Bool, _ detail: String) {
            print("\(value ? "PASS" : "FAIL") \(name): \(detail)")
            if !value { failures += 1 }
        }

        let locator = AgentExecutableLocator()
        guard let transport = ResidentDSHComposition.locateNativeTransport(using: locator) else {
            print("FAIL transport: node + official acp-demo entry not found (judgement A cannot be read)")
            exit(2)
        }
        print("transport node=\(transport.node.path)")
        print("transport entry=\(transport.entry.path)")

        // ── 形状 1：不带世界工具的 composition（探针形状）。 ──
        var bare: ResidentDSHSandbox?
        do {
            let box = try ResidentDSHComposition.makeResidentSandbox(resolvingFrom: transport.entry)
            bare = box
            let declared = ResidentDSHComposition.declaresImageInput(box.compositionText)
            report("B-bare", declared,
                   "composition WITHOUT the host-tools private row: declaresImageInput=\(declared)")
        } catch {
            report("B-bare", false, "makeResidentSandbox threw \(type(of: error)): \(error)")
        }

        // ── 形状 2：真实居民轮次形状 —— 带 gmgn-host-tools 私有插件行。 ──
        let schemas: [[String: Any]] = [[
            "name": "inspect_world",
            "description": "diagnostic-only read-only schema",
            "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false],
        ]]
        guard let schemasJSON = try? JSONSerialization.data(withJSONObject: schemas, options: [.sortedKeys]) else {
            print("FAIL schema: diagnostic schema not serializable")
            exit(2)
        }
        var channel: ResidentDSHHostToolsChannel?
        let binding = ResidentDSHHostToolsBinding()
        var production: ResidentDSHSandbox?
        do {
            let registrations = try ResidentDSHHostToolSet.parse(schemasJSON: schemasJSON)
            let started = try ResidentDSHHostToolsChannel.start(
                configuration: ResidentDSHHostToolsChannel.Configuration(
                    scope: "diagnose-image-gates", worldID: "diagnose-world",
                    registrations: registrations, handler: binding.channelHandler()
                )
            )
            channel = started
            let pluginPath = started.pluginFileURL.path
            print("host-tools plugin row name=\(pluginPath)")
            let box = try ResidentDSHComposition.makeResidentSandbox(
                resolvingFrom: transport.entry, hostToolsPluginPath: pluginPath
            )
            production = box
            let declared = ResidentDSHComposition.declaresImageInput(box.compositionText)
            let carriesRow = box.compositionText.contains("- id: \(ResidentDSHComposition.hostToolsRowID)")
            report("B-production", declared && carriesRow,
                   "composition WITH the host-tools private row: declaresImageInput=\(declared) carriesRow=\(carriesRow)")
        } catch {
            report("B-production", false,
                   "production-shaped sandbox/threw \(type(of: error)): \(error)")
        }

        // ── 判据 A：生产 connector 的真实握手（零 prompt）。 ──
        if let box = production {
            let connector = ResidentDSHConnector(
                nodeExecutable: transport.node, entryPoint: transport.entry,
                compositionFileURL: box.compositionFileURL,
                requestTimeout: 90, cancellationGrace: 8
            )
            do {
                let handle = try await connector.openSession(cwd: box.workspace)
                report("A-handshake", handle.imagePromptCapability,
                       "agentCapabilities.promptCapabilities.image=\(handle.imagePromptCapability) session=\(handle.sessionID) (zero prompts sent)")
            } catch {
                report("A-handshake", false, "openSession threw \(type(of: error)): \(error)")
            }
            connector.close()
        } else {
            report("A-handshake", false, "skipped: production composition was not built")
        }

        channel?.stop()
        binding.clear()
        production?.removeAll()
        bare?.removeAll()

        if failures == 0 {
            print("RESULT: both image judgements hold in the production composition shape")
        } else {
            print("RESULT: \(failures) image judgement(s) FAILED (first failing gate above is the true cause)")
        }
        exit(failures == 0 ? 0 : 1)
    }
}
"""#

let main = work.appendingPathComponent("Main.swift")
try harness.write(to: main, atomically: true, encoding: .utf8)
let binary = work.appendingPathComponent("gates")
let compile = Process()
compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
var compileArguments = ["-swift-version", "6", "-parse-as-library", "-j1"]
for agentName in [
    "CodexCLI", "AgentConversationService", "ResidentCodexTransport", "ResidentCodexPolicy",
    "ResidentCodexAgent", "ResidentSteeringDelivery", "ResidentDSHTransport",
    "ResidentDSHConfiguration", "ResidentStateClient", "ResidentMemoryClient",
    "ResidentConversationMemory", "ResidentDSHAgentToolBridge", "ResidentDSHHostToolsBridge",
    "ResidentClaudeToolBridge", "ResidentClaudeProcessRunner",
] {
    compileArguments.append(root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/\(agentName).swift").path)
}
compileArguments.append(contentsOf: [
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/RetryBackoff.swift").path,
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/ResidentVisionCapture.swift").path,
    main.path, "-o", binary.path,
])
compile.arguments = compileArguments
try compile.run()
let compileDeadline = Date().addingTimeInterval(240)
while compile.isRunning && Date() < compileDeadline {
    try await Task.sleep(nanoseconds: 100_000_000)
}
if compile.isRunning {
    compile.terminate()
    print("FAIL: gate diagnosis compile exceeded 240s")
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
let runDeadline = Date().addingTimeInterval(180)
while test.isRunning && Date() < runDeadline {
    try await Task.sleep(nanoseconds: 100_000_000)
}
if test.isRunning {
    test.terminate()
    print("FAIL: gate diagnosis execution exceeded 180s")
    exit(124)
}
test.waitUntilExit()
exit(test.terminationStatus)

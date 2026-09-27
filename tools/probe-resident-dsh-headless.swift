// Opt-in real headless gate, using the production service in a desktop-like
// environment and cwd=/, with only an isolated inspect_world host tool.
// Run from the repo root: swift tools/probe-resident-dsh-headless.swift --live
// This contacts the configured DSH model/search services, but never launches
// the app, touches Keychain, or exposes the real resident world.
import Foundation

guard CommandLine.arguments.contains("--live") else {
    print("Use --live to run the real text/search/fetch gate. No request sent.")
    exit(0)
}
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let work = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-dsh-headless-gate-\(UUID())")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: work) }
let harness = #"""
import Foundation
@main struct Probe {
    @MainActor static func main() async {
        let defaults = UserDefaults(suiteName: "gmgn-dsh-headless-gate-\(UUID())")!
        defaults.set("dsh", forKey: AgentConversationPreferenceKeys.selectedBackend)
        let service = AgentConversationService(defaults: defaults, dshRequestTimeout: 120)
        let world = ResidentWorldContext(selectedWorldID: "probe", worldID: "probe",
            displayName: "隔离测试房间", revision: 1, residentPosition: [0, 0, 0],
            activeActivity: nil, activityPhase: nil, objects: [], availableActivities: [])
        var inspections = 0
        let tools = ResidentConversationTools(worldID: "probe", schemasJSON: Data(#"[{"name":"inspect_world","description":"Read this isolated test room","inputSchema":{"type":"object","properties":{},"additionalProperties":false}}]"#.utf8), call: { _, name, _ in
            guard name == "inspect_world" else {
                return ResidentCodexToolReply(resultJSON: Data(#"{"error":"unknown tool"}"#.utf8), isError: true)
            }
            inspections += 1
            return ResidentCodexToolReply(resultJSON: Data(#"{"ok":true,"worldID":"probe","objects":[]}"#.utf8), isError: false)
        }, cancel: {})
        do {
            let greeting = try await service.send(
                "先调用本轮提供的 gmgn_inspect_world 查看这个隔离测试房间，再用一句中文打招呼。只能调用提供的检查工具。",
                worldContext: world, worldTools: tools)
            guard inspections > 0, !greeting.isEmpty else {
                print("FAIL: text/host-tool gate; isolated inspections=\(inspections)")
                exit(1)
            }
            print("PASS: text/host-tool gate; isolated inspections=\(inspections)")
            let reply = try await service.send(
                "现在测试网页能力。实际使用原生 web_search 搜索 DeepSeek 官方 API 文档，"
                + "再实际使用原生 web_fetch 打开 https://example.com 。最后报告搜索来源 URL、读取到的页面标题。"
                + "禁止凭记忆代替工具调用，不调用其他工具。",
                worldContext: world, worldTools: tools)
            guard reply.contains("https://"),
                  reply.localizedCaseInsensitiveContains("Example Domain") else {
                print("FAIL: web reply missing source URL or page title")
                exit(1)
            }
            print("PASS: headless service completed; isolated inspections=\(inspections)")
            print("Reply checks: source URL present; page title present.")
            print("Verify native web_search/web_fetch tool-result records separately; reply text alone is not proof.")
        } catch {
            print("FAIL: \(error.localizedDescription)")
            exit(1)
        }
    }
}
"""#
let main = work.appendingPathComponent("Main.swift")
try harness.write(to: main, atomically: true, encoding: .utf8)
let binary = work.appendingPathComponent("probe")
let compiler = Process()
compiler.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compiler.arguments = ["-parse-as-library", "-j1"] + [
    "CodexCLI", "AgentConversationService", "ResidentCodexTransport", "ResidentCodexPolicy",
    "ResidentCodexAgent", "ResidentSteeringDelivery", "ResidentDSHTransport", "ResidentDSHConfiguration",
].map { root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/\($0).swift").path }
    + [main.path, "-o", binary.path]
try compiler.run(); compiler.waitUntilExit()
guard compiler.terminationStatus == 0 else { exit(compiler.terminationStatus) }
let child = Process()
child.executableURL = binary
child.currentDirectoryURL = URL(fileURLWithPath: "/")
let base = ProcessInfo.processInfo.environment
child.environment = base.filter { ["HOME", "USER", "LOGNAME", "TMPDIR"].contains($0.key) }
child.environment?["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
try child.run(); child.waitUntilExit(); exit(child.terminationStatus)

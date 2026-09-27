//
//  test-resident-claude-service.swift
//  GMGNRadio
//
//  居民 Claude Code 全链（ResidentClaudeProcessRunner + AgentConversationService
//  `.claudeCode` 安全分支 + ResidentClaudeToolBridge 世界工具 MCP）的离线端到端
//  回归入口（纯 CPU；无真实 Claude 模型、无网络、无 Keychain、无 AppleScript、
//  无 UI、无宿主启动、无 xcodebuild test）。
//
//  真实执行链：假 claude 可执行脚本 → 解析 --mcp-config → 真 node adapter
//  （生产源码）→ 真 UDS → Swift worldTools.call → MCP result → 假 CLI JSON result。
//
//  编译门：`-swift-version 6 -parse-as-library` 真实编译并运行。
//  运行：`swift tools/test-resident-claude-service.swift`（仓库根目录）。
//
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let work = FileManager.default.temporaryDirectory.appendingPathComponent(
    "gmgn-claude-service-\(UUID().uuidString)", isDirectory: true
)
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

let agentSources = [
    "CodexCLI",
    "AgentConversationService",
    "ResidentCodexTransport",
    "ResidentCodexPolicy",
    "ResidentCodexAgent",
    "ResidentSteeringDelivery",
    "ResidentDSHTransport",
    "ResidentDSHConfiguration",
    "ResidentStateClient",
    "ResidentMemoryClient",
    "ResidentConversationMemory",
    "ResidentDSHAgentToolBridge",
    "ResidentDSHHostToolsBridge",
    "ResidentClaudeToolBridge",
    "ResidentClaudeProcessRunner",
]
var compileArguments = ["-swift-version", "6", "-parse-as-library", "-j1"]
for name in agentSources {
    compileArguments.append(
        root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/\(name).swift").path
    )
}
compileArguments.append(contentsOf: [
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/ResidentVisionCapture.swift").path,
    root.appendingPathComponent("tools/test-resident-claude-service-support.swift").path,
    "-o",
])
let binary = work.appendingPathComponent("test")
compileArguments.append(binary.path)

for relative in [
    "apps/macos/Sources/GMGNRadio/Agent/ResidentClaudeProcessRunner.swift",
    "tools/test-resident-claude-service-support.swift",
] where !FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path) {
    print("MISSING SOURCE: \(relative)")
}

let compile = Process()
compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compile.arguments = compileArguments
compile.currentDirectoryURL = work
try compile.run()
compile.waitUntilExit()
guard compile.terminationStatus == 0 else {
    print("COMPILE FAILED (exit \(compile.terminationStatus))")
    exit(1)
}

let test = Process()
test.executableURL = binary
try test.run()
test.waitUntilExit()
let testExit = test.terminationStatus
print("swift6 (-swift-version 6) compile+run exit=\(testExit)")
exit(testExit == 0 ? 0 : 1)

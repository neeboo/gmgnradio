//
//  test-resident-claude-tool-bridge.swift
//  GMGNRadio
//
//  居民 Claude Code 世界工具 MCP bridge 的离线回归入口（纯 CPU；无真实 Claude 模型、
//  无网络、无 Keychain、无 AppleScript、无 UI、无宿主启动、无 xcodebuild）。
//  编译门：`-swift-version 6 -parse-as-library` 真实编译并运行。
//  运行：`swift tools/test-resident-claude-tool-bridge.swift`（仓库根目录）。
//
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let work = FileManager.default.temporaryDirectory.appendingPathComponent(
    "gmgn-claude-mcp-\(UUID().uuidString)", isDirectory: true
)
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

let relativeSources = [
    "apps/macos/Sources/GMGNRadio/Presence/RetryBackoff.swift",
    "apps/macos/Sources/GMGNRadio/Agent/ResidentDSHAgentToolBridge.swift",
    "apps/macos/Sources/GMGNRadio/Agent/ResidentDSHHostToolsBridge.swift",
    "apps/macos/Sources/GMGNRadio/Agent/ResidentClaudeToolBridge.swift",
    "tools/test-resident-claude-tool-bridge-support.swift",
]
let sources = relativeSources.map { root.appendingPathComponent($0).path }
for source in sources where !FileManager.default.fileExists(atPath: source) {
    print("MISSING SOURCE: \(source)")
}

let binary = work.appendingPathComponent("test")
let compile = Process()
compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compile.arguments = ["-swift-version", "6", "-parse-as-library", "-j1"] + sources + ["-o", binary.path]
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

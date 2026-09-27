// 宿主工具桥接错误的用户文案 / 脱敏诊断边界（纯 CPU，无网络、无 DSH、无 Claude）。
//
// 回归点（2026-09-22 P1-2）：
//   `ResidentDSHHostToolsError` / `ResidentClaudeMCPBridgeError` 曾把内部原因
//   （私有目录路径、socket 路径、errno、原始诊断）直接插值进 `errorDescription`，
//   最终上屏给普通用户。现在用户文案是固定分类，原因只留在 `diagnostic` 且已脱敏。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let work = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-bridge-errors-\(UUID())")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

let sourceNames = [
    "ResidentDSHAgentToolBridge",
    "ResidentDSHHostToolsBridge",
    "ResidentClaudeToolBridge",
]
let sources = sourceNames.map {
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/\($0).swift")
}
for url in sources where !FileManager.default.fileExists(atPath: url.path) {
    print("MISSING SOURCE: \(url.path)")
    exit(1)
}

let secretPath = "/Users/private-user/Library/Application Support/gmgn/secret.sock"
let mainURL = work.appendingPathComponent("Main.swift")
let main = """
import Foundation

@main
struct BridgeErrorChecks {
    static func main() {
        var checks = 0, failures = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if !value { failures += 1; print("FAIL: " + label) }
        }

        let rawReason = "无法创建私有目录：\(secretPath) errno=13 secret=sk-live-123"
        let rawTool = "read_file:/etc/passwd"

        let dshErrors: [ResidentDSHHostToolsError] = [
            .malformedToolSet(rawReason),
            .invalidConfiguration(rawReason),
            .startupFailed(rawReason),
            .notStarted,
        ]
        let claudeErrors: [ResidentClaudeMCPBridgeError] = [
            .invalidRegistrations(rawReason),
            .forbiddenToolName(rawTool),
            .adapterUnavailable,
            .grantWriteFailed,
            .sessionStopped,
        ]

        func checkUserFacing(_ message: String?, _ label: String) {
            guard let message, !message.isEmpty else {
                check(false, label + " has user text")
                return
            }
            check(!message.contains("/"), label + " user text carries no path")
            check(!message.contains("errno"), label + " user text carries no errno")
            check(!message.contains("sk-live"), label + " user text carries no credential")
            check(!message.contains("无法创建私有目录"), label + " user text does not echo the raw reason")
            check(message.contains("请"), label + " user text is actionable")
        }

        for error in dshErrors { checkUserFacing(error.errorDescription, "dsh \\(error)") }
        for error in claudeErrors { checkUserFacing(error.errorDescription, "claude \\(error)") }

        func distinct(_ values: [String]) -> Bool { Set(values).count == values.count }
        check(distinct(dshErrors.map { $0.errorDescription! }),
              "each DSH bridge failure has its own fixed category text")
        check(distinct(claudeErrors.map { $0.errorDescription! }),
              "each Claude bridge failure has its own fixed category text")

        // diagnostic 保留分类码与脱敏后的原因，供日志使用。
        let startup = ResidentDSHHostToolsError.startupFailed(rawReason)
        check(startup.diagnostic.hasPrefix("dsh_host_tools/startup_failed:"),
              "DSH diagnostic carries a stable category code")
        check(startup.diagnostic.contains("<path>"), "DSH diagnostic redacts absolute paths")
        check(!startup.diagnostic.contains("/Users/private-user"), "DSH diagnostic never keeps the raw home path")
        let forbidden = ResidentClaudeMCPBridgeError.forbiddenToolName(rawTool)
        check(forbidden.diagnostic.hasPrefix("claude_mcp/forbidden_tool_name:"),
              "Claude diagnostic carries a stable category code")
        check(forbidden.diagnostic.contains("<path>"), "Claude diagnostic redacts path-like tool names")
        check(ResidentDSHHostToolsError.notStarted.diagnostic == "dsh_host_tools/not_started",
              "codeless cases keep a stable diagnostic code")

        // 脱敏边界本身：路径、控制字符、超长。
        let redacted = ResidentToolDiagnosticRedaction.redact("a\\nb\\u{0007}c \(secretPath) done")
        check(!redacted.contains("\\n") && !redacted.contains("\\u{0007}"),
              "redaction flattens control characters")
        check(redacted.contains("<path>") && !redacted.contains("\(secretPath)"),
              "redaction replaces the whole path token")
        check(ResidentToolDiagnosticRedaction.redact(String(repeating: "x", count: 400)).hasSuffix("…"),
              "redaction caps diagnostic length")

        // 用户文案与诊断是两个不同边界。
        for error in dshErrors {
            check(error.errorDescription != error.diagnostic, "DSH user text is not the diagnostic: \\(error)")
        }
        for error in claudeErrors {
            check(error.errorDescription != error.diagnostic, "Claude user text is not the diagnostic: \\(error)")
        }

        let status = failures == 0 ? "PASS" : "FAIL"
        print("\\(status): \\(checks) tool bridge error checks, \\(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
"""
try main.write(to: mainURL, atomically: true, encoding: .utf8)

let binary = work.appendingPathComponent("test")
let compile = Process()
compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compile.arguments = ["-swift-version", "6", "-parse-as-library", "-j1"]
    + sources.map(\.path) + [mainURL.path, "-o", binary.path]
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
exit(test.terminationStatus)

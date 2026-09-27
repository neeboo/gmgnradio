//
//  test-resident-claude-prepare-failure.swift
//  GMGNRadio（仅测试；不进 App）
//
//  ResidentClaudeMCPHostSession.start 的 prepare 失败清理回归。
//
//  背景：start 的 catch 只调用 channel.stop()，而配置启动的 channel
//  （removesDirectoryOnStop == false）不会删除整目录，于是本次新建的 private
//  directory 在 prepare/arm 失败路径上泄漏。生产调用方的 defer 只在 start 成功
//  返回 session 时才会整目录回收，抛错路径没有 session 可用。
//
//  隔离策略（**不向生产加任何测试 seam**）：
//    1) 把真实生产源 ResidentClaudeToolBridge.swift 复制到临时目录；
//    2) 只把其中**精确的** prepare 调用点 `try session.prepare(source: source)`
//       替换为「在会话目录写 marker 后抛错」，模拟 prepare IO 失败；
//    3) 与真实依赖（ResidentDSHAgentToolBridge.swift / ResidentDSHHostToolsBridge.swift）
//       以及生成的断言 @main 一起用 swiftc 编译；
//    4) 运行子进程并断言：start 抛出后，本次创建的 private directory 必须已不存在。
//
//  纯 CPU / 仅本地 UDS；无网络、无 Keychain、无 AppleScript、无 UI、无宿主启动、
//  无真实 Claude、无 GPU、无 xcodebuild test、不修改 HOME、不读取凭据。
//
//  运行：`swift tools/test-resident-claude-prepare-failure.swift`（仓库根目录）。
//
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let work = FileManager.default.temporaryDirectory.appendingPathComponent(
    "gmgn-claude-prepare-failure-\(UUID().uuidString)", isDirectory: true
)
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

/// 结束驱动进程前先回收临时工作目录（`exit()` 不会触发 defer）。
func finish(_ code: Int32) -> Never {
    try? FileManager.default.removeItem(at: work)
    exit(code)
}

let productionBridge = root.appendingPathComponent(
    "apps/macos/Sources/GMGNRadio/Agent/ResidentClaudeToolBridge.swift"
)
let dependencySources = [
    "apps/macos/Sources/GMGNRadio/Agent/ResidentDSHAgentToolBridge.swift",
    "apps/macos/Sources/GMGNRadio/Agent/ResidentDSHHostToolsBridge.swift",
].map { root.appendingPathComponent($0) }

for url in [productionBridge] + dependencySources where !FileManager.default.fileExists(atPath: url.path) {
    print("MISSING SOURCE: \(url.path)")
    finish(1)
}

// 精确替换：回归必须落在「prepare 抛错」这一条真实路径上（catch 清理点）。
let needle = "try session.prepare(source: source)"
let original = try String(contentsOf: productionBridge, encoding: .utf8)
guard original.components(separatedBy: needle).count == 2 else {
    print("FAIL: 生产源中未找到唯一精确 prepare 调用点：\(needle)")
    finish(1)
}

let injection = """
try Data(session.directoryURL.path.utf8).write(
                to: URL(fileURLWithPath: ProcessInfo.processInfo.environment["GMGN_CLAUDE_PREPARE_FAILURE_PROBE"] ?? "/dev/null"))
            try Data("gmgn-prepare-failure-marker".utf8).write(
                to: session.directoryURL.appendingPathComponent("gmgn-prepare-failure-marker"))
            throw ResidentClaudeMCPBridgeError.adapterUnavailable
"""
let patched = original.replacingOccurrences(of: needle, with: injection)
guard patched != original else {
    print("FAIL: prepare 注入替换未生效")
    finish(1)
}
let patchedURL = work.appendingPathComponent("PatchedResidentClaudeToolBridge.swift")
try patched.write(to: patchedURL, atomically: true, encoding: .utf8)

let probeURL = work.appendingPathComponent("prepare-failure-probe.txt")
let mainURL = work.appendingPathComponent("GeneratedMain.swift")

// 生成断言 main：只驱动真实 start 路径，并检查失败后的目录清理。
let generatedMain = """
import Foundation
import Darwin

@main
struct ResidentClaudePrepareFailureCleanupTests {
    static func main() throws {
        guard let probePath = ProcessInfo.processInfo.environment["GMGN_CLAUDE_PREPARE_FAILURE_PROBE"],
              !probePath.isEmpty else {
            print("FAIL: 缺少 GMGN_CLAUDE_PREPARE_FAILURE_PROBE")
            exit(2)
        }
        let probeURL = URL(fileURLWithPath: probePath)
        try? FileManager.default.removeItem(at: probeURL)

        let registration = ResidentDSHHostToolRegistration(
            canonicalName: "read_wish_generation",
            declaredName: "gmgn_read_wish_generation",
            description: "查询许愿机当前任务状态",
            originalSchemaJSON: Data(#"{"type":"object","properties":{}}"#.utf8)
        )
        var caught: Error?
        do {
            _ = try ResidentClaudeMCPHostSession.start(
                configuration: ResidentClaudeMCPHostSession.Configuration(
                    scope: "world.cabin",
                    worldID: "cabin-1",
                    registrations: [registration],
                    handler: { _ in
                        ResidentDSHHostToolReply(resultJSON: Data("{}".utf8), isError: false)
                    },
                    nodeExecutable: URL(fileURLWithPath: "/usr/bin/true")
                ),
                deadline: Date().addingTimeInterval(600)
            )
        } catch {
            caught = error
        }

        guard let error = caught else {
            print("FAIL: prepare 注入失败后 start 未抛错")
            exit(1)
        }
        guard (error as? ResidentClaudeMCPBridgeError) == .adapterUnavailable else {
            print("FAIL: start 抛出的错误不是注入的 adapterUnavailable：\\(error)")
            exit(1)
        }

        // 注入点记录的会话目录 —— 这是本例真实创建的 private directory。
        guard let recorded = try? String(contentsOf: probeURL, encoding: .utf8),
              !recorded.isEmpty else {
            print("FAIL: prepare 注入点未记录会话目录")
            exit(1)
        }
        let directoryURL = URL(fileURLWithPath: recorded, isDirectory: true)
        let markerURL = directoryURL.appendingPathComponent("gmgn-prepare-failure-marker")
        print("prepare 注入错误: \\(error)")
        print("本次会话 private directory: \\(directoryURL.path)")

        guard !FileManager.default.fileExists(atPath: directoryURL.path) else {
            print("FAIL: prepare 失败后 private directory 仍存在（泄漏）：\\(directoryURL.path)")
            // 测试自身兜底清理，避免 RED 运行污染宿主临时目录。
            try? FileManager.default.removeItem(at: directoryURL)
            exit(1)
        }
        guard !FileManager.default.fileExists(atPath: markerURL.path) else {
            print("FAIL: prepare 失败后目录 marker 仍存在")
            exit(1)
        }
        print("PASS: prepare 失败后本次 private directory 与 marker 均已回收")
        exit(0)
    }
}
"""
try generatedMain.write(to: mainURL, atomically: true, encoding: .utf8)

let binary = work.appendingPathComponent("test")
let compile = Process()
compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compile.arguments = ["-swift-version", "6", "-parse-as-library", "-j1", patchedURL.path]
    + dependencySources.map(\.path) + [mainURL.path, "-o", binary.path]
compile.currentDirectoryURL = work
try compile.run()
compile.waitUntilExit()
guard compile.terminationStatus == 0 else {
    print("COMPILE FAILED (exit \(compile.terminationStatus))")
    finish(1)
}

let test = Process()
test.executableURL = binary
var environment = ProcessInfo.processInfo.environment
environment["GMGN_CLAUDE_PREPARE_FAILURE_PROBE"] = probeURL.path
test.environment = environment
try test.run()
test.waitUntilExit()
let testExit = test.terminationStatus
print("swift6 (-swift-version 6) compile+run exit=\(testExit)")
finish(testExit == 0 ? 0 : 1)

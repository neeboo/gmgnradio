// E2E 隔离的机械判据：测试根的 UserDefaults suite 必须**每个根稳定独立**，
// 生产默认零副作用，显式访问器在未启用时回落到真实目录。
//
// 它把生产 `E2ERuntime.swift` **原文**编起来跑（不启动 App、不碰磁盘、不碰网络）：
//   * 同一个根的 suite 名必须逐字节稳定（重启同根保留）；
//   * 不同根的 suite 名必须不同（重复验收不串）；
//   * 没设 `GMGN_E2E_DATA_ROOT` 时 `applicationSupportBase` 为 nil、`defaults` 是 `.standard`；
//   * 来源扫描：任务关键 file 持久化点必须走显式注入（`applicationSupportBase` /
//     `directory:` / `E2ERuntime.applicationSupportDirectory`），不许再裸用真实目录。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let runtimeURL = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/App/E2ERuntime.swift")
guard let runtimeSource = try? String(contentsOf: runtimeURL, encoding: .utf8) else {
    print("FAIL: 找不到 E2ERuntime.swift")
    exit(1)
}
let program = runtimeSource + "\n" + #"""
import Foundation

var checks = 0
var failures = 0
let check: (Bool, String) -> Void = { value, message in
    checks += 1
    if !value { failures += 1; print("FAIL: \(message)") }
}

let rootA = URL(fileURLWithPath: "/tmp/gmgn-e2e-root-a", isDirectory: true)
let rootB = URL(fileURLWithPath: "/tmp/gmgn-e2e-root-b", isDirectory: true)
let suiteA1 = E2ERuntime.suiteName(forRoot: rootA)
let suiteA2 = E2ERuntime.suiteName(forRoot: rootA)
let suiteB = E2ERuntime.suiteName(forRoot: rootB)
check(suiteA1 == suiteA2, "same test root derives a stable suite name across restarts")
check(suiteA1 != suiteB, "different test roots derive independent suite names")
check(suiteA1.hasPrefix("ai.gmgn.radio.e2e."), "suite name is namespaced under the e2e bundle id")

// 生产默认（未设环境变量）：零副作用。
check(E2ERuntime.dataRoot == nil, "production (no env) has no test data root")
check(E2ERuntime.isolationRequested == false, "production does not request isolation")
check(E2ERuntime.applicationSupportBase == nil, "production has no injected support base")
check(E2ERuntime.defaults === UserDefaults.standard, "production defaults are the standard suite")
let productionSupport = E2ERuntime.applicationSupportDirectory()
check(productionSupport.path.contains("Application Support"),
      "production support accessor falls back to the real Application Support")

print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) e2e isolation checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
"""#

let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-e2e-isolation-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let sourceURL = temporary.appendingPathComponent("main.swift")
try program.write(to: sourceURL, atomically: true, encoding: .utf8)
let executable = temporary.appendingPathComponent("isolation")

let compile = Process()
compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
compile.arguments = ["swiftc", "-swift-version", "6", sourceURL.path, "-o", executable.path]
try compile.run()
compile.waitUntilExit()
guard compile.terminationStatus == 0 else {
    print("FAIL: e2e isolation harness did not compile")
    exit(compile.terminationStatus)
}
let run = Process()
run.executableURL = executable
try run.run()
run.waitUntilExit()

// 来源扫描：E2E 关键 file 持久化点必须显式注入根，不许裸用真实用户目录。
let sourcesRoot = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
var allSources = ""
if let enumerator = FileManager.default.enumerator(
    at: sourcesRoot, includingPropertiesForKeys: [.isRegularFileKey]
) {
    for case let url as URL in enumerator where url.pathExtension == "swift" {
        allSources += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        allSources += "\n"
    }
}
let injectionMarkers = [
    "PropTaskDaemonClient(root: injectedTaskDaemonRoot)",
    "applicationSupportBase: E2ERuntime.applicationSupportBase",
    "directory: E2ERuntime.applicationSupportBase?",
    "fileURL: injectedPropGenerationConfigURL",
    "E2ERuntime.applicationSupportDirectory()",
    "screenPersistence",
]
for marker in injectionMarkers where !allSources.contains(marker) {
    print("FAIL: composition is missing explicit root injection: \(marker)")
    exit(1)
}
print("PASS: E2E-critical persistence sites inject the test root explicitly")
exit(run.terminationStatus)

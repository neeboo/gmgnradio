// 单一 taskd 根的门禁（2026-10-03 E2E 拒收项）：
//
//   同一个测试根里曾经出现**两个** taskd：
//     · 世界权威 `WorldAuthorityEndpoint` 落在 `<base>/TaskService/taskd.sock`；
//     · 生成服务 `PropTaskDaemonClient(root:)` 落在
//       `<base>/gmgn radio/TaskService/taskd.sock`。
//   于是"世界加载"和"生成任务"各连各的 taskd，生成/入库永远对不上。
//
// 本 harness 把生产 `AuthorityWorldStatePersistence.swift` 里最后那段自包含的
// `WorldAuthorityEndpoint` **原文**切出来，用真 `swiftc` 编起来跑：显式 base 必须得到
// `<base>/gmgn radio/TaskService/taskd.sock`，且 `taskServiceRoot` 与 `socketPath` 同源。
// 再做一条注入负对照：把 `gmgn radio` 那一层抽掉后同一判据必须红。
//
// 另外做来源扫描：App 的 E2E 注入必须走 `WorldAuthorityEndpoint.taskServiceRoot`，
// `PropTaskDaemonClient` 的默认根必须是 `gmgn radio/TaskService`，`LivingWorldBootstrap`
// 必须把 `applicationSupportBase` 交给端点。任一处漂移即红。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let persistenceURL = root.appendingPathComponent(
    "apps/macos/Sources/GMGNRadio/Presence/AuthorityWorldStatePersistence.swift"
)
let appURL = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift")
let clientURL = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/PropTaskDaemonClient.swift")
let bootstrapURL = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/App/LivingWorldBootstrap.swift")

func read(_ url: URL) -> String? {
    try? String(contentsOf: url, encoding: .utf8)
}

var failures = 0
var checks = 0
let check: (Bool, String) -> Void = { value, message in
    checks += 1
    if !value { failures += 1; print("FAIL: \(message)") }
}

guard let persistence = read(persistenceURL),
      let app = read(appURL),
      let client = read(clientURL),
      let bootstrap = read(bootstrapURL)
else {
    print("FAIL: 找不到 root/unification 生产源码")
    exit(1)
}

// MARK: - 切出自包含的 WorldAuthorityEndpoint

let marker = "struct WorldAuthorityEndpoint {"
guard let range = persistence.range(of: marker) else {
    print("FAIL: AuthorityWorldStatePersistence.swift 里找不到 \(marker)")
    exit(1)
}
let endpointSource = String(persistence[range.lowerBound...])

let checkBody = #"""
var checks = 0
var failures = 0
let check: (Bool, String) -> Void = { value, message in
    checks += 1
    if !value { failures += 1; print("FAIL: \(message)") }
}

let base = URL(fileURLWithPath: "/tmp/gmgn-e2e-root", isDirectory: true)
let endpoint = WorldAuthorityEndpoint(applicationSupportBase: base, bundle: Bundle.main)
let expectedRoot = base.appendingPathComponent("gmgn radio", isDirectory: true)
    .appendingPathComponent("TaskService", isDirectory: true)
check(WorldAuthorityEndpoint.taskServiceRoot(applicationSupportBase: base).path == expectedRoot.path,
      "explicit base keeps the gmgn radio/TaskService level")
check(endpoint.socketPath == expectedRoot.appendingPathComponent("taskd.sock").path,
      "socket path is rooted at gmgn radio/TaskService")
check(!endpoint.socketPath.contains("/TaskService/taskd.sock") ||
      endpoint.socketPath.contains("/gmgn radio/TaskService/taskd.sock"),
      "there is exactly one gmgn radio level before TaskService")
check(endpoint.helperPath.hasSuffix("Contents/Helpers/gmgn-taskd"),
      "helper stays inside the app bundle")

print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) socket-root checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
"""#

func runHarness(_ endpointText: String, label: String, expectSuccess: Bool) -> Bool {
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent("gmgn-root-unification-\(UUID())")
    try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let sourceURL = temporary.appendingPathComponent("main.swift")
    let program = "import Foundation\n\n" + endpointText + "\n" + checkBody
    try? program.write(to: sourceURL, atomically: true, encoding: .utf8)
    let executable = temporary.appendingPathComponent("check")
    let compile = Process()
    compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    compile.arguments = ["swiftc", "-swift-version", "6", sourceURL.path, "-o", executable.path]
    try? compile.run()
    compile.waitUntilExit()
    guard compile.terminationStatus == 0 else {
        print("FAIL: \(label) harness did not compile")
        return false
    }
    let run = Process()
    run.executableURL = executable
    let output = Pipe()
    run.standardOutput = output
    run.standardError = output
    try? run.run()
    run.waitUntilExit()
    let succeeded = run.terminationStatus == 0
    if expectSuccess || succeeded != expectSuccess {
        let captured = output.fileHandleForReading.readDataToEndOfFile()
        if !expectSuccess { print("--- \(label) harness output ---") }
        print(String(decoding: captured, as: UTF8.self), terminator: "")
    }
    return succeeded == expectSuccess
}

// 原件：必须通过。
if !runHarness(endpointSource, label: "original", expectSuccess: true) {
    print("FAIL: production WorldAuthorityEndpoint no longer roots at gmgn radio/TaskService")
    failures += 1
}
checks += 1

// 注入负对照：把 `gmgn radio` 那一层抽掉（回到上一轮的错误实现），同一判据必须红。
let tampered = endpointSource.replacingOccurrences(
    of: ".appendingPathComponent(\"gmgn radio\", isDirectory: true)",
    with: ""
)
guard tampered != endpointSource else {
    print("FAIL: 无法构造注入负对照（taskServiceRoot 结构变了）；门禁失效")
    exit(1)
}
if !runHarness(tampered, label: "tampered", expectSuccess: false) {
    print("FAIL: 抽掉 gmgn radio 那一层的注入负对照没有变红；门禁失效")
    failures += 1
}
checks += 1

// MARK: - 来源扫描：三处必须同一口径

let appMarkers = [
    "WorldAuthorityEndpoint.taskServiceRoot(applicationSupportBase:",
]
for marker in appMarkers where !app.contains(marker) {
    print("FAIL: App 的 E2E taskd 注入没有走共享根：\(marker)")
    failures += 1
}
checks += appMarkers.count

let clientMarkers = [".appendingPathComponent(\"gmgn radio\", isDirectory: true)",
                     ".appendingPathComponent(\"TaskService\", isDirectory: true)"]
for marker in clientMarkers where !client.contains(marker) {
    print("FAIL: PropTaskDaemonClient 默认根不再是 gmgn radio/TaskService：\(marker)")
    failures += 1
}
checks += clientMarkers.count

if !bootstrap.contains("WorldAuthorityEndpoint(applicationSupportBase: applicationSupportBase)") {
    print("FAIL: LivingWorldBootstrap 没有把 applicationSupportBase 交给世界权威端点")
    failures += 1
}
checks += 1

print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) taskd-root-unification checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)

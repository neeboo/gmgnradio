// 首次使用引导回归（纯逻辑，无 AppKit/窗口/GPU/权限）。
//
// 覆盖：
//   1. 「显示 Live Cam」在没有角色时给出可见、可执行的设置路径，绝不无响应；
//   2. 没有后端时给出明确配置路径，不等到输入后才失败；
//   3. 技术配置/环境变量名不上屏（只进日志）。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sources = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")

func read(_ path: String) throws -> String {
    try String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8)
}

func declaration(_ signature: String, in text: String) -> String {
    guard let start = text.range(of: signature)?.lowerBound,
          let opening = text[start...].firstIndex(of: "{") else {
        print("FAIL: missing production behavior \(signature)")
        exit(1)
    }
    var depth = 0
    for index in text[opening...].indices {
        if text[index] == "{" { depth += 1 }
        if text[index] == "}" { depth -= 1 }
        if depth == 0 { return String(text[start...index]) }
    }
    fatalError("unterminated declaration")
}

let cameraSource = try read("VisualEngine/StageCameraCoordinator.swift")
let conversationSource = try read("Agent/AgentConversationService.swift")
let appSource = try read("App/GMGNRadioApp.swift")

let pureDeclarations = [
    declaration("enum LiveCamPresentationRequest:", in: cameraSource),
    declaration("enum ResidentBackendReadiness", in: conversationSource),
].joined(separator: "\n")

let wiringChecks: [(Bool, String)] = [
    (appSource.contains("LiveCamPresentationRequest.resolve(hasAvatar:"),
     "App routes Live Cam presentation through the avatar-readiness policy"),
    (appSource.contains("alert.messageText = \"还没有可显示的角色\"")
        && appSource.contains("alert.informativeText = guidance"),
     "App answers a no-avatar Live Cam request with visible guidance"),
    (appSource.contains("refreshResidentBackendGuidance()"),
     "App surfaces the missing-backend guidance"),
    (appSource.contains("ResidentBackendReadiness.guidance(hasUsableBackend:"),
     "App derives the guidance from real backend usability"),
    (conversationSource.contains("请打开\\(ResidentBackendReadiness.settingsPath)"),
     "backend-not-installed errors point at the settings path"),
    // 外部记忆 provider 接线已整体移除：应用源码里不该再出现任何 GMGN_MEMORY_*。
    (!appSource.contains("GMGN_MEMORY"),
     "external memory provider variables are gone from the app entirely"),
]

let harness = #"""
import Foundation

\#(pureDeclarations)

@main struct Main {
    static func main() {
        var checks = 0
        var failures = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if !value { failures += 1; print("FAIL: \(label)") }
        }

        let liveCam = LiveCamPresentationRequest.resolve(hasAvatar: false)
        check(liveCam == .needsAvatar(guidance: LiveCamPresentationRequest.missingAvatarGuidance),
              "no avatar yields visible guidance instead of a silent no-op")
        if case let .needsAvatar(guidance) = liveCam {
            check(guidance.contains("设置 → 角色"), "avatar guidance names the settings path")
            check(guidance.contains("角色"), "avatar guidance talks about the missing character")
            check(!guidance.contains("GMGN_") && !guidance.contains("/Users/") && !guidance.contains("环境变量"),
                  "avatar guidance exposes no internal environment detail")
        }
        check(LiveCamPresentationRequest.resolve(hasAvatar: true) == .present,
              "an installed avatar still presents the Live Cam")

        let missing = ResidentBackendReadiness.guidance(hasUsableBackend: false)
        check(missing != nil, "no usable backend yields guidance before the user types")
        if let missing {
            check(missing.contains("设置 → DJ → 聊天模型"),
                  "backend guidance names the real settings path")
            check(!missing.contains("GMGN_") && !missing.contains("/Users/") && !missing.contains("环境变量"),
                  "backend guidance exposes no environment variables or paths")
        }
        check(ResidentBackendReadiness.guidance(hasUsableBackend: true) == nil,
              "a usable backend yields no missing-backend guidance")

        let status = failures == 0 ? "PASS" : "FAIL"
        print("\(status): \(checks) first-use guidance checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#

let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-first-use-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let main = temporary.appendingPathComponent("FirstUse.swift")
try harness.write(to: main, atomically: true, encoding: .utf8)
let binary = temporary.appendingPathComponent("first-use-test")
let compile = Process()
compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compile.arguments = ["-j1", "-swift-version", "6", "-parse-as-library", main.path, "-o", binary.path]
try compile.run()
compile.waitUntilExit()
guard compile.terminationStatus == 0 else { exit(compile.terminationStatus) }
let test = Process()
test.executableURL = binary
try test.run()
test.waitUntilExit()
let testExit = test.terminationStatus

var wiringFailures = 0
for (ok, label) in wiringChecks where !ok {
    wiringFailures += 1
    print("FAIL: \(label)")
}
if wiringFailures > 0 { print("FAIL: \(wiringFailures) first-use wiring checks failed") }
exit(testExit == 0 && wiringFailures == 0 ? 0 : 1)

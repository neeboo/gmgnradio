// 居民人格与后台思考预算的纯 CPU 回归。
//
// 从 AgentConversationService.swift 提取真实的 ResidentPreferences（@MainActor）与
// ResidentWorldContext 两个类型后编译运行；不启动 App/宿主、不访问 GPU、Keychain、
// 真实 DB 或模型。所有 UserDefaults 都使用隔离 suite 并在结束时清理，绝不读写真实用户值。
import Foundation

let servicePath = "apps/macos/Sources/GMGNRadio/Agent/AgentConversationService.swift"

func fail(_ message: String) -> Never {
    print("FAIL: \(message)")
    exit(1)
}

guard let serviceSource = try? String(contentsOfFile: servicePath, encoding: .utf8) else {
    fail("missing AgentConversationService.swift")
}

func declaration(_ signature: String, in source: String) -> String {
    guard let start = source.range(of: signature)?.lowerBound,
          let open = source[start...].firstIndex(of: "{") else {
        fail("missing \(signature)")
    }
    var depth = 0
    for index in source[open...].indices {
        if source[index] == "{" { depth += 1 }
        if source[index] == "}" { depth -= 1 }
        if depth == 0 { return String(source[start...index]) }
    }
    fail("unbalanced \(signature)")
}

// 只看服务端代码，不看解释性注释。
let serviceCode = serviceSource
    .split(separator: "\n", omittingEmptySubsequences: false)
    .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    .joined(separator: "\n")

// MARK: - 独立字段：绝不复用 DJ hostPrompt

let preferencesCode = declaration("struct ResidentPreferences", in: serviceCode)
guard serviceCode.contains("@MainActor\nstruct ResidentPreferences") else {
    fail("ResidentPreferences must stay MainActor-isolated in AgentConversationService.swift")
}
guard preferencesCode.contains("resident.persona.v1") else {
    fail("resident persona must use its own UserDefaults key")
}
guard !preferencesCode.contains("hostPromptKey"),
      !preferencesCode.contains("dj.agent.host-prompt") else {
    fail("resident persona must not reuse the DJ hostPrompt key or defaults")
}
guard preferencesCode.contains("background-turns-per-hour") else {
    fail("resident background thinking budget needs its own UserDefaults key")
}
guard preferencesCode.contains("var backgroundTurnsPerHour: Int") else {
    fail("ResidentPreferences needs a readable/writable backgroundTurnsPerHour")
}

// MARK: - prompt 统一注入（Codex/DSH 共用同一处）

let context = declaration("struct ResidentWorldContext", in: serviceCode)
guard context.contains("persona: String?") else {
    fail("resident prompt builder must accept the resident persona")
}
guard context.contains("ResidentPreferences.personaInjection") else {
    fail("resident prompt builder must inject the resident persona")
}
guard serviceCode.contains("residentPreferences.persona") else {
    fail("send must re-read the latest persona every round")
}
guard serviceCode.contains("persona: residentPersona") else {
    fail("send must pass the freshly read persona into the shared prompt builder")
}
guard !serviceCode.contains("initialPrompt") else {
    fail("persona must never be cached as an initialPrompt")
}
guard serviceCode.components(separatedBy: "worldContext?.prompt(").count - 1 == 1 else {
    fail("Codex and DSH must share one resident prompt injection point")
}

// MARK: - 行为回归：提取的 @MainActor ResidentPreferences + ResidentWorldContext

let harness = #"""
import Foundation

struct ResidentStateScope: Equatable, Sendable {
    let worldID: String
    let residentScope: String
}

@MainActor
\#(preferencesCode)

\#(context)

@main
struct Tests {
    @MainActor
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            if !value {
                print("FAIL: \(message)")
                exit(1)
            }
            checks += 1
        }
        let suite = "gmgn-resident-preferences-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            print("FAIL: isolated suite unavailable")
            exit(1)
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.removePersistentDomain(forName: suite)

        var prefs = ResidentPreferences(defaults: defaults)
        check(ResidentPreferences.defaultBackgroundTurnsPerHour == 6,
              "documented default background thinking budget is 6")
        check(prefs.backgroundTurnsPerHour == 6, "budget defaults to 6")
        check(ResidentPreferences.minimumBackgroundTurnsPerHour == 0, "budget lower bound is 0")
        check(ResidentPreferences.maximumBackgroundTurnsPerHour == 6, "budget upper bound is 6")
        check(prefs.saveBackgroundTurnsPerHour(-7) == 0, "budget clamps below 0")
        check(prefs.backgroundTurnsPerHour == 0, "clamped low value persists")
        check(prefs.saveBackgroundTurnsPerHour(42) == 6, "budget clamps above 6")
        check(prefs.saveBackgroundTurnsPerHour(4) == 4, "budget keeps in-range 0...6 values")
        check(ResidentPreferences(defaults: defaults).backgroundTurnsPerHour == 4,
              "budget is readable by a fresh main-agent reader")
        defaults.removeObject(forKey: ResidentPreferences.backgroundTurnsPerHourKey)
        check(prefs.backgroundTurnsPerHour == 6, "removing the budget key restores the default")

        prefs.backgroundTurnsPerHour = 3
        check(prefs.backgroundTurnsPerHour == 3, "setter persists an in-range budget")
        check(ResidentPreferences(defaults: defaults).backgroundTurnsPerHour == 3,
              "setter value is visible to a fresh main-agent reader")
        prefs.backgroundTurnsPerHour = 42
        check(prefs.backgroundTurnsPerHour == 6, "setter clamps above the maximum")
        prefs.backgroundTurnsPerHour = -5
        check(prefs.backgroundTurnsPerHour == 0, "setter clamps below the minimum")

        check(prefs.persona == ResidentPreferences.defaultPersona, "persona has a default")
        prefs.savePersona("  说话慢一点，像深夜电台。  ")
        check(prefs.persona == "说话慢一点，像深夜电台。", "persona is trimmed and persisted")
        check(defaults.string(forKey: ResidentPreferences.personaKey) == "说话慢一点，像深夜电台。",
              "persona lives under the resident-only key")
        check(defaults.string(forKey: "dj.agent.host-prompt") == nil,
              "saving the resident persona never writes the DJ host prompt")
        check(ResidentPreferences.personaKey != "dj.agent.host-prompt",
              "resident persona key is independent from the DJ hostPrompt")
        prefs.savePersona("   ")
        check(prefs.persona == ResidentPreferences.defaultPersona, "blank persona falls back to default")

        let injection = ResidentPreferences.personaInjection("只讲你自己的判断。")
        check(injection?.contains("只讲你自己的判断。") == true, "injection carries the persona text")
        check(injection?.contains("不是工具授权") == true, "injection denies any tool permission change")
        check(injection?.contains("正式工具清单") == true, "injection defers to the formal tool manifest")
        check(ResidentPreferences.personaInjection("   ") == nil, "blank persona injects nothing")
        check(ResidentPreferences.personaInjection(nil) == nil, "missing persona injects nothing")

        func world(_ id: String) -> ResidentWorldContext {
            ResidentWorldContext(selectedWorldID: id, worldID: id, displayName: nil, revision: 1,
                residentPosition: nil, activeActivity: nil, activityPhase: nil,
                objects: [], availableActivities: [])
        }
        let cabin = world("cabin")
        let roundOne = try cabin.prompt(for: "第一轮", toolsAvailable: true, persona: prefs.persona)
        check(roundOne.contains(ResidentPreferences.defaultPersona),
              "resident prompt injects the current persona")
        check(roundOne.contains("不是工具授权"), "resident prompt keeps the no-extra-permission guard")
        check(roundOne.contains("第一轮"), "resident prompt keeps the user message")

        prefs.savePersona("新人格：多说一句今天的天气。")
        let roundTwo = try cabin.prompt(for: "第二轮", toolsAvailable: true, persona: prefs.persona)
        check(roundTwo.contains("新人格：多说一句今天的天气。") && roundTwo.contains("不是工具授权"),
              "saving takes effect on the next round with the full no-extra-permission guard")
        check(!roundTwo.contains(ResidentPreferences.defaultPersona),
              "the next round never replays the stale persona")

        let room = world("room")
        let switched = try room.prompt(for: "换空间", toolsAvailable: true, persona: prefs.persona)
        check(switched.contains("新人格：多说一句今天的天气。") && switched.contains("room"),
              "persona survives switching worlds because it is not world-scoped")

        let readOnly = try cabin.prompt(for: "只聊天", toolsAvailable: false, persona: prefs.persona)
        check(readOnly.contains("新人格：多说一句今天的天气。"),
              "read-only resident chat still gets the persona")
        check(readOnly.contains("没有空间动作工具"), "read-only turn still states there are no action tools")

        let withoutPersona = try cabin.prompt(for: "x", toolsAvailable: true, persona: nil)
        check(!withoutPersona.contains("不是工具授权"), "no persona leaves the prompt without an injection block")

        print("PASS: \(checks) resident persona and background-budget checks; isolated suite, no host")
    }
}
"""#

let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-resident-preferences-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let program = directory.appendingPathComponent("Main.swift")
let binary = directory.appendingPathComponent("test")
try harness.write(to: program, atomically: true, encoding: .utf8)

func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

let compile = try run("/usr/bin/swiftc", [
    "-j1", "-parse-as-library",
    program.path, "-o", binary.path,
])
guard compile == 0 else { exit(compile) }
exit(try run(binary.path, []))

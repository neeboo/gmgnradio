// Hostless boundary checks: production headless installs native host tools;
// model text never executes. Explicitly injected legacy connector behavior
// is checked separately and does not stand in for real ACP integration.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let work = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-dsh-tool-channel-\(UUID())")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

let harness = #"""
import Foundation

enum StageVisualMood: String, CaseIterable { case afterglow, liquid, pulse }
enum StageLyricsVisualMode: String { case auto; static let agentValues = ["auto"]; init?(agentValue: String) { self.init(rawValue: agentValue) } }
enum SpatialScenePreset: String, CaseIterable { case cabin }
enum SpatialWeather: String, CaseIterable { case clear }
enum SpatialCameraCommandDirection: String, CaseIterable { case reset }

let safeDSHConfigDump = """
- id: llm
  name: '@deepseek-ai/dsh-llm'
- id: agent
  name: '@deepseek-ai/dsh-agent'
- id: tools
  name: '@deepseek-ai/dsh-tools'
  config:
    mode: native
- id: system-prompt
  name: '@deepseek-ai/dsh-system-prompt'
- id: agent-loop
  name: '@deepseek-ai/dsh-agent-loop'
- id: llm-deepseek
  name: '@deepseek-ai/dsh-llm-deepseek'
- id: headless-startup
  name: '@deepseek-ai/dsh-headless/startup'
- id: headless-runner
  name: '@deepseek-ai/dsh-headless'
- id: web
  name: '@deepseek-ai/dsh-web'
- id: web-search-deepseek
  name: '@deepseek-ai/dsh-web-search-deepseek'
- id: web-fetch-http
  name: '@deepseek-ai/dsh-web-fetch-http'
- id: tool-web
  name: '@deepseek-ai/dsh-tool-web'
- id: code-runtime
  name: '@deepseek-ai/dsh-code-runtime-worker-thread'
  disabled: true
- id: tool-bash
  name: '@deepseek-ai/dsh-tool-bash'
  disabled: true
- id: tool-pwsh
  name: '@deepseek-ai/dsh-tool-pwsh'
  disabled: true
- id: tool-jobs
  name: '@deepseek-ai/dsh-tool-jobs'
  disabled: true
- id: tool-fs
  name: '@deepseek-ai/dsh-tool-fs'
  disabled: true
- id: tool-fs-search
  name: '@deepseek-ai/dsh-tool-fs-search'
  disabled: true
- id: tool-str-replace-editor
  name: '@deepseek-ai/dsh-tool-str-replace-editor'
  disabled: true
- id: agent-instructions
  name: '@deepseek-ai/dsh-agent-instructions'
  disabled: true
- id: skill-filesystem
  name: '@deepseek-ai/dsh-skill-filesystem'
  disabled: true
- id: tool-skill
  name: '@deepseek-ai/dsh-tool-skill'
  disabled: true
- id: plan-mode
  name: '@deepseek-ai/dsh-plan-mode'
  disabled: true
- id: tool-subagent-control
  name: '@deepseek-ai/dsh-tool-subagent-control'
  disabled: true
- id: tool-subagent-list-agents
  name: '@deepseek-ai/dsh-tool-subagent-control/list-agents'
  disabled: true
- id: tool-subagent
  name: '@deepseek-ai/dsh-tool-subagent'
  disabled: true
- id: tool-subagent-fork
  name: '@deepseek-ai/dsh-tool-subagent'
  disabled: true
- id: tool-subagent-report
  name: '@deepseek-ai/dsh-tool-subagent-report'
  disabled: true
- id: workflow-worker-thread
  name: '@deepseek-ai/dsh-workflow-worker-thread'
  disabled: true
- id: tool-workflow
  name: '@deepseek-ai/dsh-tool-workflow'
  disabled: true
- id: tool-result-pruner
  name: '@deepseek-ai/dsh-compaction-tool-result-pruner'
  disabled: true
- id: tool-todo
  name: '@deepseek-ai/dsh-tool-todo'
  disabled: true
- id: tool-goal
  name: '@deepseek-ai/dsh-tool-goal'
  disabled: true
- id: tool-ralph
  name: '@deepseek-ai/dsh-tool-ralph'
  disabled: true
"""

actor Script {
    private var outputs: [String]
    private let modelExitCode: Int32
    private let preflightExitCode: Int32
    private let preflightOutput: String
    private let privateArtifactTamper: String?
    private(set) var prompts: [String] = []
    private(set) var modelArguments: [[String]] = []
    private(set) var securityPatchTexts: [String] = []
    private(set) var securityPluginTexts: [String] = []
    private(set) var securityPluginURLs: [URL] = []
    private(set) var registeredNames: [String] = []

    init(_ outputs: [String]) {
        self.modelExitCode = 0
        self.preflightExitCode = 0
        self.preflightOutput = safeDSHConfigDump
        self.privateArtifactTamper = nil
        self.outputs = outputs
    }

    func run(arguments: [String]) -> CodexCommandResult {
        if arguments.contains("--dump-config") {
            var privateRow = ""
            if let patchIndex = arguments.firstIndex(of: "--patch"),
               arguments.indices.contains(patchIndex + 1),
               let patch = try? String(contentsOfFile: arguments[patchIndex + 1], encoding: .utf8) {
                securityPatchTexts.append(patch)
                let pluginURL = URL(fileURLWithPath: arguments[patchIndex + 1])
                    .deletingLastPathComponent().appendingPathComponent("resident-interactive-budget.mjs")
                if let plugin = try? String(contentsOf: pluginURL, encoding: .utf8) {
                    securityPluginTexts.append(plugin)
                    securityPluginURLs.append(pluginURL)
                    privateRow = "\n- id: gmgn-interactive-budget\n  name: '\(pluginURL.path)'\n"
                    switch privateArtifactTamper {
                    case "module-content": try? "export function apply() {}".write(to: pluginURL, atomically: true, encoding: .utf8)
                    case "module-permissions": try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: pluginURL.path)
                    case "directory-permissions": try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pluginURL.deletingLastPathComponent().path)
                    case "patch-content": try? patch.replacingOccurrences(of: pluginURL.path, with: pluginURL.path + ".unexpected")
                        .write(toFile: arguments[patchIndex + 1], atomically: true, encoding: .utf8)
                    default: break
                    }
                }
            }
            if let i = arguments.firstIndex(of: "--patch"), arguments.indices.contains(i + 1),
               let patch = try? String(contentsOfFile: arguments[i + 1], encoding: .utf8) {
                let lines = patch.components(separatedBy: "\n")
                if let row = lines.firstIndex(where: { $0.contains("- id: gmgn-host-tools") }),
                   lines.indices.contains(row + 1) {
                    privateRow += "\n- id: gmgn-host-tools\n  " + lines[row + 1].trimmingCharacters(in: .whitespaces) + "\n"
                    let nameRow = lines[row + 1].trimmingCharacters(in: .whitespaces)
                    let path = String(nameRow.dropFirst("name: '".count).dropLast())
                    let grantURL = URL(fileURLWithPath: path).deletingLastPathComponent()
                        .appendingPathComponent("gmgn-host-tools.grant.json")
                    if let data = try? Data(contentsOf: grantURL),
                       let grant = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let rows = grant["tools"] as? [[String: Any]] {
                        registeredNames = rows.compactMap { $0["name"] as? String }
                    }
                }
            }
            return CodexCommandResult(exitCode: preflightExitCode, output: preflightOutput + privateRow)
        }
        prompts.append(arguments.last ?? "")
        guard !outputs.isEmpty else { return CodexCommandResult(exitCode: 1, output: "") }
        return CodexCommandResult(exitCode: 0, output: outputs.removeFirst())
    }

    func recordedPrompts() -> [String] { prompts }
}

struct QueueRunner: CodexCommandRunning {
    let script: Script
    func run(arguments: [String], standardInput: String?) async throws -> CodexCommandResult {
        await script.run(arguments: arguments)
    }
}

struct ChannelLocator: AgentExecutableLocating {
    func locate(executableNames: [String]) -> URL? { URL(fileURLWithPath: "/fixture/dsh") }
}

/// Captures the prompt blocks the model actually receives on the native
/// connector path, then replays the real model outputs.
@MainActor final class ChannelConnector: ResidentDSHImageConnecting, @unchecked Sendable {
    private(set) var capturedPrompts: [String] = []
    private var step = 0
    var isUsable = true

    func openSession(cwd: URL) async throws -> ResidentDSHSessionHandle {
        ResidentDSHSessionHandle(sessionID: "channel", imagePromptCapability: true)
    }

    func prompt(sessionID: String, blocks: [ResidentDSHPromptBlock]) async throws -> String {
        let text = blocks.compactMap { block -> String? in
            if case let .text(value) = block { return value }
            return nil
        }.joined(separator: "\n")
        capturedPrompts.append(text)
        step += 1
        if step == 1 {
            return #"{"type":"tool_call","call_id":"ch-1","name":"gmgn_list_music_playlists","arguments":{}}"#
        }
        return #"{"type":"final","text":"已尝试歌单入口"}"#
    }

    func cancelActivePrompt() {}
    func close() { isUsable = false }
}

@MainActor final class Calls {
    struct Entry: Equatable { let id: String; let name: String }
    private(set) var entries: [Entry] = []

    func handle(_ id: String, _ name: String, _ arguments: Data) -> ResidentCodexToolReply {
        entries.append(Entry(id: id, name: name))
        let object: [String: Any] = name == "list_music_playlists"
            ? ["ok": true, "playlists": [["id": "night", "name": "Night Radio"]]]
            : ["ok": true, "message": "完成 \(name)"]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return ResidentCodexToolReply(resultJSON: data, isError: false)
    }
}

@main struct Tests {
    @MainActor static func main() async throws {
        var checks = 0, failures = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if !value { failures += 1; print("FAIL: \(label)") }
        }
        func defaults(_ suffix: String) -> UserDefaults {
            let suite = "gmgn-dsh-channel-\(suffix)-\(UUID())"
            let value = UserDefaults(suiteName: suite)!
            value.removePersistentDomain(forName: suite)
            value.set(AgentConversationBackendID.dsh.rawValue, forKey: AgentConversationPreferenceKeys.selectedBackend)
            return value
        }
        let world = ResidentWorldContext(selectedWorldID: "cabin", worldID: "cabin", displayName: "生活舱",
            revision: 1, residentPosition: [0, 0, 0], activeActivity: nil, activityPhase: nil, objects: [], availableActivities: [])
        let schemaNames = ["inspect_world", "list_places", "list_available_activities", "plan_route", "move_to",
            "start_activity", "stop_activity", "look_at", "list_music_playlists", "read_music_playlist",
            "prepare_music_track", "read_radio_state", "read_current_track", "submit_wish_generation",
            "read_owned_props"]
        let schemas: [[String: Any]] = schemaNames.map { name in
            ["name": name, "description": "fixture \(name)",
             "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false]]
        }
        let schemasJSON = try JSONSerialization.data(withJSONObject: schemas, options: [.sortedKeys])

        func fixtureTools(_ data: Data) -> ResidentConversationTools {
            ResidentConversationTools(
                worldID: "cabin",
                schemasJSON: data,
                call: { _, _, _ in
                    ResidentCodexToolReply(resultJSON: Data("{}".utf8), isError: false)
                },
                cancel: {}
            )
        }

        // The boundary is strict in both directions: every valid category is
        // prefixed, while malformed, duplicate, or already-prefixed trusted
        // schemas fail closed instead of being silently dropped.
        let boundary = try AgentConversationService.DSHToolBoundary(
            worldTools: fixtureTools(schemasJSON)
        )
        let declaredSchemas = try JSONSerialization.jsonObject(
            with: boundary.schemasJSON
        ) as? [[String: Any]] ?? []
        let declaredNames = Set(declaredSchemas.compactMap { $0["name"] as? String })
        check(declaredNames == Set(schemaNames.map { "gmgn_" + $0 }),
            "all declared world, loop, music, wish, and prop names receive exactly one gmgn_ prefix")

        func rejects(_ data: Data) -> Bool {
            do {
                _ = try AgentConversationService.DSHToolBoundary(worldTools: fixtureTools(data))
                return false
            } catch AgentConversationError.invalidDSHToolProtocol {
                return true
            } catch {
                return false
            }
        }
        check(rejects(Data("{}".utf8)), "non-array schemas fail closed")
        let prefixedSchema = try JSONSerialization.data(
            withJSONObject: [["name": "gmgn_inspect_world"]]
        )
        check(rejects(prefixedSchema), "already-prefixed canonical schemas fail closed")
        let duplicateSchemas = try JSONSerialization.data(
            withJSONObject: [["name": "inspect_world"], ["name": "inspect_world"]]
        )
        check(rejects(duplicateSchemas), "duplicate declared names fail closed")

        func channelClause(_ prompt: String) -> Bool {
            prompt.contains("UNKNOWN_TOOL")
                && prompt.contains("gmgn_")
                && prompt.contains("原生")
                && prompt.contains("tool_call")
        }

        // A. Production headless path accepts prose; text envelopes never execute.
        for output in ["已查看歌单", #"{"type":"tool_call","call_id":"c1","name":"gmgn_list_music_playlists","arguments":{}}"#] {
            let calls = Calls()
            let script = Script([output])
            let service = AgentConversationService(locator: ChannelLocator(), defaults: defaults("headless"),
                runnerFactory: { _ in QueueRunner(script: script) })
            let tools = ResidentConversationTools(worldID: "cabin", schemasJSON: schemasJSON,
                call: { id, name, arguments in calls.handle(id, name, arguments) }, cancel: {})
            let reply = try await service.send("去点唱机放首歌", worldContext: world, worldTools: tools)
            let prompts = await script.recordedPrompts()
            check(reply == output && calls.entries.isEmpty, "model text remains text and never dispatches formal tools")
            check(prompts.count == 1, "headless native tool turn uses one process without envelope continuation")
            let patches = await script.securityPatchTexts
            check(patches.count == 1 && patches[0].contains("- id: gmgn-host-tools"),
                  "headless path installs the private native host-tools plugin")
            let registered = await script.registeredNames
            check(registered.sorted() == schemaNames.map { "gmgn_" + $0 }.sorted(),
                  "private native grant exposes exactly this turn's declared host tool names")
        }

        // B. Explicitly injected legacy connector compatibility; not real ACP coverage.
        do {
            let calls = Calls()
            let connector = ChannelConnector()
            let service = AgentConversationService(locator: ChannelLocator(), defaults: defaults("native"),
                residentDSHImageConnector: connector)
            let tools = ResidentConversationTools(worldID: "cabin", schemasJSON: schemasJSON,
                call: { id, name, arguments in calls.handle(id, name, arguments) }, cancel: {})
            _ = try await service.send("去点唱机放首歌", worldContext: world, worldTools: tools)
            check(calls.entries.contains { $0.name == "list_music_playlists" },
                "the native connector path still maps declared gmgn_ names to canonical dispatch")
            check(connector.capturedPrompts.isEmpty == false, "native connector prompts were captured")
            if let first = connector.capturedPrompts.first {
                check(channelClause(first), "the native connector prompt carries the channel boundary")
            }
        }

        print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) resident DSH tool channel checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#

let main = work.appendingPathComponent("Main.swift")
try harness.write(to: main, atomically: true, encoding: .utf8)
let binary = work.appendingPathComponent("test")
let compile = Process()
compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
var compileArguments = ["-parse-as-library", "-j1"]
for agentName in ["CodexCLI", "AgentConversationService", "ResidentCodexTransport", "ResidentCodexPolicy", "ResidentCodexAgent", "ResidentSteeringDelivery", "ResidentDSHTransport", "ResidentDSHConfiguration", "ResidentStateClient", "ResidentMemoryClient", "ResidentConversationMemory", "ResidentDSHAgentToolBridge", "ResidentDSHHostToolsBridge", "ResidentClaudeToolBridge", "ResidentClaudeProcessRunner"] {
    compileArguments.append(root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/\(agentName).swift").path)
}
compileArguments.append(contentsOf: [
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/ResidentVisionCapture.swift").path,
    main.path, "-o", binary.path,
])
compile.arguments = compileArguments
try compile.run()
compile.waitUntilExit()
guard compile.terminationStatus == 0 else { exit(compile.terminationStatus) }
let test = Process()
test.executableURL = binary
try test.run()
test.waitUntilExit()
exit(test.terminationStatus)

// Read-only metadata preflight. Never prints or writes configuration values/auth data.
import Foundation
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let work = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-codex-preflight-\(UUID())")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }
let harness = #"""
import Foundation
@main struct Probe {
    @MainActor static func main() async {
        let cwd = URL(fileURLWithPath: CommandLine.arguments[1])
        var active: ResidentCodexTransport?
        defer { active?.close() }
        do {
            let environment = ResidentCodexPolicy.environment(from: ProcessInfo.processInfo.environment)
            let executable = URL(fileURLWithPath: "/usr/local/bin/codex")
            let params = try JSONSerialization.data(withJSONObject: ["includeLayers": false, "cwd": cwd.path])
            let discovery = ResidentCodexTransport(executableURL: executable, arguments: try ResidentCodexPolicy.arguments(disabling: []), currentDirectoryURL: cwd, environment: environment, requestTimeout: 30)
            active = discovery
            try await discovery.start()
            let names = try ResidentCodexPolicy.serverNames(in: try await discovery.request(method: "config/read", params: params))
            discovery.close()
            let resident = ResidentCodexTransport(executableURL: executable, arguments: try ResidentCodexPolicy.arguments(disabling: names), currentDirectoryURL: cwd, environment: environment, requestTimeout: 30)
            active = resident
            try await resident.start()
            let response = try await resident.request(method: "config/read", params: params)
            do { try ResidentCodexPolicy.verify(response) }
            catch {
                // Diagnostic projection is intentionally limited to public policy flags.
                let envelope = try JSONSerialization.jsonObject(with: response) as? [String: Any]
                let config = envelope?["config"] as? [String: Any] ?? [:]
                let features = config["features"] as? [String: Any] ?? [:]
                print("Policy flags: " + ["plugins", "apps", "hooks", "multi_agent", "multi_agent_v2", "image_generation", "shell_tool"].map { "\($0)=\(features[$0] as? Bool == false ? "off" : "unconfirmed")" }.joined(separator: ","))
                print("fileAuth=\(config["cli_auth_credentials_store"] as? String == "file"), fileMCPAuth=\(config["mcp_oauth_credentials_store"] as? String == "file"), notifyEmpty=\((config["notify"] as? [Any])?.isEmpty == true), agentsOff=\((config["agents"] as? [String:Any])?["enabled"] as? Bool == false), webSearchOn=\(config["web_search"] as? String != "disabled")")
                throw error
            }
            print("PASS: configuration preflight; \(names.count) external MCP definitions disabled; no thread or model started")
            resident.close()
        } catch {
            let safe = error as? ResidentCodexTransportError
            print("FAIL: configuration preflight (\(type(of: error))); private response suppressed")
            if let transport = active, let category = transport.failureCategory { print("diagnostic category: \(category)") }
            if let detail = active?.failureDetail { print("diagnostic detail: \(detail)") }
            active?.close()
            exit(1)
        }
    }
}
"""#
let main = work.appendingPathComponent("Probe.swift")
try harness.write(to: main, atomically: true, encoding: .utf8)
let binary = work.appendingPathComponent("probe")
let compile = Process(); compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compile.arguments = ["-parse-as-library", "-j1", root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/ResidentCodexPolicy.swift").path, root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/ResidentCodexTransport.swift").path, main.path, "-o", binary.path]
try compile.run(); compile.waitUntilExit()
guard compile.terminationStatus == 0 else { exit(compile.terminationStatus) }
let run = Process(); run.executableURL = binary; run.arguments = [work.path]
try run.run(); run.waitUntilExit(); exit(run.terminationStatus)

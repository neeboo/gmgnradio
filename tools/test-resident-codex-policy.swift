// No accounts or configuration files: compile and test the actual policy using fixtures.
import Foundation
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let work = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-policy-test-\(UUID())")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }
let program = #"""
import Foundation
var checks = 0
var failures = 0
func check(_ result: Bool, _ label: String) {
    checks += 1
    if !result { failures += 1; print("FAIL: \(label)") }
}
func data(_ config: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["config": config])
}
let switches = ["plugins", "apps", "hooks", "multi_agent", "multi_agent_v2", "image_generation", "shell_tool"]
var safe: [String: Any] = [
    "features": Dictionary(uniqueKeysWithValues: switches.map { ($0, false) }),
    "agents": ["enabled": false], "notify": [String](),
    "web_search": "disabled", "cli_auth_credentials_store": "file", "mcp_oauth_credentials_store": "file",
    "mcp_servers": ["fixture.server": ["enabled": false, "env": ["TOKEN": "fixture-private"]]]
]
let names = try ResidentCodexPolicy.serverNames(in: data(safe))
check(names == ["fixture.server"], "extract names only")
let args = try ResidentCodexPolicy.arguments(disabling: ["fixture.server", "quoted\"name"])
check(args.first == "app-server", "app server command")
check(args.contains("cli_auth_credentials_store=\"file\""), "file-only auth at process startup")
check(args.contains("features.plugins=false") && args.contains("features.hooks=false"), "disable startup extensions")
check(args.contains("notify=[]"), "disable legacy notify")
let mcp = args.first { $0.hasPrefix("mcp_servers=") } ?? ""
check(mcp.contains("\"fixture.server\"={enabled=false}"), "literal dotted server name")
check(mcp.contains("\"quoted\\\"name\"={enabled=false}"), "escaped server name")
check(!args.joined().contains("fixture-private"), "no configuration values in arguments")
try ResidentCodexPolicy.verify(data(safe))
for key in switches {
    var altered = safe
    var features = safe["features"] as! [String: Bool]
    features[key] = true
    altered["features"] = features
    var rejected = false
    do { try ResidentCodexPolicy.verify(data(altered)) } catch { rejected = true }
    check(rejected, "reject enabled \(key)")
}
for (key, value) in [("mcp_servers", ["unknown": [:]] as Any), ("notify", ["command"] as Any), ("cli_auth_credentials_store", "keyring" as Any), ("mcp_oauth_credentials_store", "auto" as Any), ("web_search", "live" as Any), ("agents", ["enabled": true] as Any)] {
    var altered = safe; altered[key] = value
    var rejected = false
    do { try ResidentCodexPolicy.verify(data(altered)) } catch { rejected = true }
    check(rejected, "reject unsafe \(key)")
}
var rejected = false
do { _ = try ResidentCodexPolicy.serverNames(in: Data("{}".utf8)) } catch { rejected = true }
check(rejected, "malformed config fails closed")
let env = ResidentCodexPolicy.environment(from: ["HOME": "/fixture", "CODEX_HOME": "/fixture/codex", "PATH": "/bin", "CODEX_THREAD_ID": "parent", "CODEX_EXEC_SERVER_NOISE_SECRET": "secret", "OPENAI_API_KEY": "fixture-key", "HTTPS_PROXY": "proxy"])
check(env["HOME"] == "/fixture" && env["CODEX_HOME"] == "/fixture/codex", "preserve original auth locations")
check(env["CODEX_THREAD_ID"] == nil && env["CODEX_EXEC_SERVER_NOISE_SECRET"] == nil, "drop inherited control channels")
check(env["OPENAI_API_KEY"] == nil, "do not silently switch logged-in account to inherited API key")
check(env["CODEX_EXEC_SERVER_URL"] == "none", "disable local execution environment")
check(env["HTTPS_PROXY"] == "proxy", "preserve connection proxy")
let directories = (ResidentCodexPolicy.environment(from: ["PATH": "/fixture/bin:/usr/local/bin:/bin"]) ["PATH"] ?? "").split(separator: ":").map(String.init)
check(Array(directories.prefix(6)) == ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"], "GUI launches include standard runtime directories")
check(directories.last == "/fixture/bin" && Set(directories).count == directories.count, "preserve additional paths without duplicates")
let noPath = ResidentCodexPolicy.environment(from: [:])
check(noPath["PATH"]?.contains("/usr/local/bin") == true && noPath["HOME"] == nil, "missing PATH gains runtime locations without inventing HOME")
print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) resident policy checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
"""#
let main = work.appendingPathComponent("main.swift")
try program.write(to: main, atomically: true, encoding: .utf8)
let binary = work.appendingPathComponent("test")
let compiler = Process()
compiler.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compiler.arguments = [root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/ResidentCodexPolicy.swift").path, main.path, "-o", binary.path]
try compiler.run(); compiler.waitUntilExit()
guard compiler.terminationStatus == 0 else { exit(compiler.terminationStatus) }
let test = Process(); test.executableURL = binary
try test.run(); test.waitUntilExit(); exit(test.terminationStatus)

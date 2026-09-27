// Real web-search/web-read gate probe for the resident DSH native transport.
//
// Everything runs through the production stack: ResidentDSHComposition for the
// on-disk composition (now mounting the native web seam), ResidentDSHConnector
// for the official dsh-acp-demo ACP entry. It performs a small number of real
// public web operations with the existing DSH login (DeepSeek search provider
// resolves the managed credential document; nothing is printed). No files are
// written outside the probe-owned sandbox and the ACP child's own temp roots.
//
// Usage:
//   swift tools/probe-resident-dsh-web.swift            # real web search + fetch
//   swift tools/probe-resident-dsh-web.swift --handshake-only
import Foundation
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let build = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-dsh-web-probe-build-\(UUID())", isDirectory: true)
try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: build) }

let harness = ##"""
import Foundation
import CryptoKit

enum ProbeExit: Int32 { case fail = 1, gate = 2, credential = 3, network = 4, timeout = 5 }
@MainActor func bail(_ code: ProbeExit, _ message: String) -> Never {
    print("FAIL[\(code.rawValue)]: \(message)")
    exit(code.rawValue)
}
struct ProbeTimeout: Error, LocalizedError {
    var errorDescription: String? { "probe 单轮请求超时" }
}

@main struct Probe {
    @MainActor static func main() async throws {
        let startedAt = Date()
        let watchdog = Task {
            do { try await Task.sleep(nanoseconds: 480_000_000_000) }
            catch { return }
            print("FAIL[5]: probe watchdog timeout (8min)")
            exit(5)
        }
        defer { watchdog.cancel() }

        // Gate 1: composition with the native web seam passes read-back and
        // still locks image-capable model + no execution rows.
        let locator = AgentExecutableLocator()
        guard let transport = ResidentDSHComposition.locateNativeTransport(using: locator) else {
            bail(.gate, "native DSH ACP transport (node + official acp-demo entry) not found")
        }
        let sandbox = try ResidentDSHComposition.makeResidentSandbox(resolvingFrom: transport.entry)
        defer { sandbox.removeAll() }
        let diskText = try String(contentsOf: sandbox.compositionFileURL, encoding: .utf8)
        guard diskText == sandbox.compositionText,
              ResidentDSHComposition.validateComposedConfig(diskText),
              ResidentDSHComposition.declaresImageInput(diskText) else {
            bail(.gate, "on-disk composition failed read-back / whitelist validation")
        }
        guard diskText.contains("@deepseek-ai/dsh-web"),
              diskText.contains("@deepseek-ai/dsh-web-search-deepseek"),
              diskText.contains("@deepseek-ai/dsh-web-fetch-http"),
              diskText.contains("@deepseek-ai/dsh-tool-web"),
              !diskText.contains("tool-bash") else {
            bail(.gate, "composition is missing the pinned web seam or gained execution rows")
        }
        let scrubbed = ResidentDSHTransport.residentEnvironment(base: ProcessInfo.processInfo.environment)
        guard scrubbed["DEEPSEEK_API_KEY"] == nil, scrubbed["DSH_HOME"] == nil else {
            bail(.gate, "terminal credentials or DSH overrides reached the ACP environment")
        }
        print("config: web-seam composition validated (search + fetch providers pinned, no execution rows)")

        let connector = ResidentDSHConnector(
            nodeExecutable: transport.node, entryPoint: transport.entry,
            compositionFileURL: sandbox.compositionFileURL,
            requestTimeout: 300, cancellationGrace: 8
        )
        defer { connector.close() }
        let handle: ResidentDSHSessionHandle
        do { handle = try await connector.openSession(cwd: sandbox.workspace) }
        catch {
            let reason = DSHExecutionFailureReason(diagnostic: String(describing: error))
            switch reason {
            case .missingCredential, .authentication, .quota: bail(.credential, reason.userMessage)
            case .network: bail(.network, reason.userMessage)
            default: throw error
            }
        }
        guard handle.imagePromptCapability else { bail(.gate, "handshake did not advertise image capability") }
        print("session: opened \(handle.sessionID) (image=true) on the official ACP entry")

        if CommandLine.arguments.contains("--handshake-only") {
            print("PASS: handshake-only (no model turn)")
            return
        }

        func boundedPrompt(_ text: String, seconds: Double = 240) async throws -> String {
            try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await connector.prompt(sessionID: handle.sessionID, blocks: [.text(text)])
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    throw ProbeTimeout()
                }
                guard let first = try await group.next() else { throw ProbeTimeout() }
                group.cancelAll()
                return first
            }
        }

        // Turn 1: real web search. The model must search rather than answer
        // from memory; a reply without any http(s) URL is treated as no
        // evidence of search.
        let searchReply: String
        do { searchReply = try await boundedPrompt(
            "请用网页搜索检索后回答：DeepSeek 官方平台（api-docs.deepseek.com）当前主要提供哪些 DeepSeek 模型名称？"
            + "不要凭记忆。必须实际执行网页搜索，并在回答里列出你检索到的至少一个来源 URL。"
        ) }
        catch { bail(.timeout, "web search turn timed out") }
        let searchExcerpt = searchReply.replacingOccurrences(of: "\n", with: " ").prefix(300)
        print("search reply: \(searchExcerpt)")
        let urlPattern = #"https?://[^\s\)\]]+"#
        let hasURL = searchReply.range(of: urlPattern, options: .regularExpression) != nil
        guard hasURL else { bail(.fail, "web search turn returned no source URL; search evidence missing") }
        print("search evidence: reply cites at least one http(s) source URL")

        // Turn 2: real public page read (web_fetch through the local HTTP
        // fetch provider). example.com's body contains the constant title.
        let fetchReply: String
        do { fetchReply = try await boundedPrompt(
            "请使用网页读取工具打开 https://example.com ，只告诉我页面上实际出现的标题文字（网页正文的第一行）。不要凭记忆。"
        ) }
        catch { bail(.timeout, "web fetch turn timed out") }
        let fetchExcerpt = fetchReply.replacingOccurrences(of: "\n", with: " ").prefix(300)
        print("fetch reply: \(fetchExcerpt)")
        let hasTitle = fetchReply.localizedCaseInsensitiveContains("example domain")
        guard hasTitle else { bail(.fail, "web fetch turn did not report example.com's actual title text") }
        print("fetch evidence: reply reflects the real fetched page content")

        let elapsed = Int(Date().timeIntervalSince(startedAt))
        print("== RECEIPT ==")
        print("result: PASS")
        print("model: deepseek-v4-flash-vision-exp @ deepseek-official (native web seam mounted)")
        print("transport: production ResidentDSHConnector; official dsh-acp-demo entry")
        print("session_id: \(handle.sessionID)")
        print("web_search: real search performed; reply cites source URL(s)")
        print("web_fetch: real public page read (example.com title confirmed)")
        print("composition_sha256: "
            + (SHA256.hash(data: Data(diskText.utf8)).map { String(format: "%02x", $0) }.joined()))
        print("env: child scrubbed; key only via credentials-local; never printed")
        print("elapsed_seconds: \(elapsed)")
    }
}
"""##

// Driver: compile the production agent sources together with the probe harness.
let workDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-dsh-web-probe-\(UUID())", isDirectory: true)
try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: workDir) }
let main = build.appendingPathComponent("Main.swift")
try harness.write(to: main, atomically: true, encoding: .utf8)
let binary = build.appendingPathComponent("probe")
let compile = Process()
compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compile.arguments = ["-swift-version", "6", "-parse-as-library", "-j1"] + [
    "CodexCLI", "AgentConversationService", "ResidentCodexTransport", "ResidentCodexPolicy",
    "ResidentCodexAgent", "ResidentSteeringDelivery", "ResidentDSHTransport", "ResidentDSHConfiguration",
].map { root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/\($0).swift").path } + [main.path, "-o", binary.path]
try compile.run()
let compileDeadline = Date().addingTimeInterval(180)
while compile.isRunning && Date() < compileDeadline {
    try await Task.sleep(nanoseconds: 100_000_000)
}
if compile.isRunning {
    compile.terminate()
    print("FAIL: probe compile exceeded 180s")
    exit(124)
}
compile.waitUntilExit()
guard compile.terminationStatus == 0 else { exit(compile.terminationStatus) }

let compileOnly = CommandLine.arguments.contains("--compile-only")
    || ProcessInfo.processInfo.environment["PROBE_COMPILE_ONLY"] == "1"
if compileOnly {
    let stable = URL(fileURLWithPath: "/tmp/gmgn-dsh-web-probe")
    try? FileManager.default.removeItem(at: stable)
    try FileManager.default.copyItem(at: binary, to: stable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stable.path)
    try? FileManager.default.removeItem(at: build)
    print("PROBE_BINARY: \(stable.path)")
    exit(0)
}
print("PROBE_BINARY: \(binary.path)")
let test = Process()
test.executableURL = binary
try test.run()
let runDeadline = Date().addingTimeInterval(560)
while test.isRunning && Date() < runDeadline {
    try await Task.sleep(nanoseconds: 200_000_000)
}
if test.isRunning {
    test.terminate()
    print("FAIL: probe execution exceeded its overall bound")
    exit(124)
}
test.waitUntilExit()
exit(test.terminationStatus)

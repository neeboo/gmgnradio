// The MCP mounting judgement for the resident DSH composition.
//
// What this pins, and why each line is a judgement rather than a description:
//
//   * **Default is off.** With no `mcpServer` argument, the emitted bytes and
//     the linked package set are exactly what they were before the MCP face
//     existed. An MCP client restart must not be able to change this round's
//     tool face, so mounting it is an explicit act.
//   * **The fields are DSH's real ones.** The row uses
//     `@deepseek-ai/dsh-mcp-client`'s own config surface
//     (`serverName` / `transport` / `command` / `args`), so the client
//     registers the tools as `mcp__gmgn__<tool>`. A row that invented its own
//     field names would be a composition the loader ignores.
//   * **The paths are the ones the host wrote.** `command` and `args` must be
//     the exact absolute facts the caller passed. Swapping either one — pointing
//     the face at another binary, another socket, or another authorization file
//     — fails closed, because read-back validation compares against the
//     caller's own facts rather than trusting the text.
//   * **An unrequested row is fatal, not ignored.** A `gmgn-mcp` row that
//     nobody asked for means the composition was not written by this code.
//
// Local mocks only: no DSH process, no model, no credentials, no network.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let work = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-dsh-mcp-\(UUID())")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

// The real path shape on this machine: the socket lives inside the daemon's
// private root, which contains a space. A mounting scheme that cannot carry a
// space is not a scheme that works here.
let realSocket = "/Users/fixture/Library/Application Support/gmgn radio/TaskService/taskd.sock"
let realGrant = "/Users/fixture/Library/Application Support/gmgn radio/TaskService/gmgn-host-tools.grant.json"
let binary = "/Applications/GMGN Radio.app/Contents/Helpers/gmgn-mcpd"

let harness = #"""
import Foundation

// The two production types `ResidentDSHConfiguration.swift` refers to. Only the
// cases this file touches are needed, so the harness compiles that one real
// source file and nothing else.
protocol AgentExecutableLocating {
    func locate(executableNames: [String]) -> URL?
}
enum AgentConversationError: Error { case dshSecurityPatchUnavailable }

var count = 0
var failures: [String] = []
@MainActor func check(_ condition: Bool, _ label: String) {
    if condition {
        count += 1
        print("PASS: \(label)")
    } else {
        print("FAIL: \(label)")
        failures.append(label)
    }
}

let work = URL(fileURLWithPath: CommandLine.arguments[1])
let binary = CommandLine.arguments[2]
let realSocket = CommandLine.arguments[3]
let realGrant = CommandLine.arguments[4]

let attachmentHome = work.appendingPathComponent("home")
let persistenceRoot = work.appendingPathComponent("sessions")
let persona = "你是生活空间的居民。"

let server = ResidentDSHComposition.ResidentDSHMCPServer(
    command: binary, socketPath: realSocket, grantPath: realGrant)

// ── 1. Default off: no row, no new package, same bytes. ──────────────────
let plain = ResidentDSHComposition.residentYAML(
    attachmentHome: attachmentHome, persistenceRoot: persistenceRoot, persona: persona)
check(ResidentDSHComposition.validateComposedConfig(plain), "baseline composition still validates")
check(!plain.contains("- id: \(ResidentDSHComposition.mcpRowID)"),
      "no MCP row is emitted unless one was asked for")
check(!plain.contains(ResidentDSHComposition.mcpClientPackage),
      "the baseline composition does not depend on the DSH MCP client package")
check(ResidentDSHComposition.declaresImageInput(plain),
      "the baseline composition still declares image input")
check(ResidentDSHComposition.privateMCPServer(in: plain) == nil,
      "no MCP row can be recovered from a composition that carries none")

// ── 2. Mounted: the row is the real DSH shape, verbatim. ─────────────────
let mounted = ResidentDSHComposition.residentYAML(
    attachmentHome: attachmentHome, persistenceRoot: persistenceRoot, persona: persona,
    mcpServer: server)
let expectedRow = """
- id: gmgn-mcp
  name: '@deepseek-ai/dsh-mcp-client'
  config:
    serverName: gmgn
    transport: stdio
    command: '\(binary)'
    args: [--socket, \(realSocket), --grant, \(realGrant)]
"""
check(mounted.contains(expectedRow), "the MCP row is emitted in the official field vocabulary")
check(ResidentDSHComposition.validateComposedConfig(mounted, mcpServer: server),
      "the mounted composition validates when validated with what was asked for")
check(ResidentDSHComposition.declaresImageInput(mounted),
      "the MCP row does not hide the image model declaration (production send-time read)")
check(!ResidentDSHComposition.validateComposedConfig(mounted),
      "an MCP row nobody asked for is rejected, never silently ignored")
check(ResidentDSHComposition.privateMCPServer(in: mounted) == server,
      "the emitted row round-trips back to the facts it was built from")

// A socket path with a space has to survive both the emitter and the reading
// validator; otherwise the real private root could never be mounted.
check(server.argumentsText.contains("Application Support/gmgn radio"),
      "a space-containing private root survives the argument list text")
check(server.isWellFormed, "the real private-root paths are accepted as well formed")

// ── 3. Tampering fails closed. ───────────────────────────────────────────
let tampered: [(String, String)] = [
    ("pointed at another binary",
     mounted.replacingOccurrences(of: "command: '\(binary)'",
                                  with: "command: '/tmp/other-mcpd'")),
    ("pointed at another socket",
     mounted.replacingOccurrences(of: "--socket, \(realSocket)",
                                  with: "--socket, /tmp/other.sock")),
    ("pointed at another grant file",
     mounted.replacingOccurrences(of: "--grant, \(realGrant)",
                                  with: "--grant, /tmp/other.grant.json")),
    ("grant argument dropped",
     mounted.replacingOccurrences(of: ", --grant, \(realGrant)", with: "")),
    ("grant argument added",
     mounted.replacingOccurrences(of: "\(realGrant)]", with: "\(realGrant), --grant, /tmp/x.json]")),
    ("server namespace renamed",
     mounted.replacingOccurrences(of: "    serverName: gmgn", with: "    serverName: other")),
    ("transport swapped",
     mounted.replacingOccurrences(of: "    transport: stdio", with: "    transport: streamable-http")),
    ("command left unquoted",
     mounted.replacingOccurrences(of: "command: '\(binary)'", with: "command: \(binary)")),
    ("an extra config key",
     mounted.replacingOccurrences(of: "    transport: stdio",
                                  with: "    transport: stdio\n    cwd: /tmp")),
    ("the tool timeout widened from outside",
     mounted.replacingOccurrences(of: "    transport: stdio",
                                  with: "    transport: stdio\n    toolCallTimeoutMs: 600000")),
    ("name pointed at another package",
     mounted.replacingOccurrences(of: "name: '@deepseek-ai/dsh-mcp-client'",
                                  with: "name: '@deepseek-ai/dsh-tool-web'")),
    ("config block removed",
     mounted.replacingOccurrences(of: expectedRow, with: "- id: gmgn-mcp\n  name: '@deepseek-ai/dsh-mcp-client'\n")),
    ("a second MCP row appended",
     mounted + "\n- id: gmgn-mcp\n  name: '@deepseek-ai/dsh-mcp-client'\n"),
]
for (label, text) in tampered {
    check(!ResidentDSHComposition.validateComposedConfig(text, mcpServer: server),
          "tampered composition fails closed: \(label)")
}

// The recovery path must not hand back facts this code would never have
// written, or the send-time image read would be unlocked by a foreign row.
check(ResidentDSHComposition.privateMCPServer(
    in: mounted.replacingOccurrences(of: binary, with: "/tmp/other-mcpd")) == nil,
      "a foreign binary cannot be recovered as our MCP row")
check(ResidentDSHComposition.privateMCPServer(
    in: mounted.replacingOccurrences(of: "\(realGrant)]", with: "\(realGrant), --grant, /tmp/x.json]")) == nil,
      "a widened argument list cannot be recovered as our MCP row")
check(!ResidentDSHComposition.declaresImageInput(
    mounted.replacingOccurrences(of: "    serverName: gmgn", with: "    serverName: other")),
      "the image-declaration read still fails closed on a foreign MCP row")

// A malformed request is not a request: it must not emit a half-valid row.
let relativeBinary = ResidentDSHComposition.ResidentDSHMCPServer(
    command: "gmgn-mcpd", socketPath: realSocket, grantPath: nil)
check(!relativeBinary.isWellFormed, "a relative command path is not well formed")
let commaSocket = ResidentDSHComposition.ResidentDSHMCPServer(
    command: binary, socketPath: "/tmp/a,b.sock", grantPath: nil)
check(!commaSocket.isWellFormed, "a socket path containing a comma is not well formed")
let quotedSocket = ResidentDSHComposition.ResidentDSHMCPServer(
    command: binary, socketPath: "/tmp/o'brien.sock", grantPath: nil)
check(!quotedSocket.isWellFormed, "a socket path containing a quote is not well formed")
let refusedEmit = ResidentDSHComposition.residentYAML(
    attachmentHome: attachmentHome, persistenceRoot: persistenceRoot, persona: persona,
    mcpServer: relativeBinary)
check(!refusedEmit.contains("- id: \(ResidentDSHComposition.mcpRowID)"),
      "a malformed mount request emits no row at all")

// ── 4. Package linking. ──────────────────────────────────────────────────
func buildFakeInstall(in base: URL, includingMCPServer: Bool, omitting omitted: String? = nil) -> URL {
    var names = ["dsh-llm-deepseek", "dsh-credentials-local", "dsh-attachment-local", "dsh-acp-demo",
                 "dsh-web", "dsh-web-fetch-http", "dsh-web-search-deepseek", "dsh-tool-web"]
    if includingMCPServer { names.append("dsh-mcp-client") }
    for name in names where name != omitted {
        let packageDirectory = base.appendingPathComponent("node_modules/@deepseek-ai/\(name)", isDirectory: true)
        try? FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        try? Data("{\"name\":\"@deepseek-ai/\(name)\"}".utf8)
            .write(to: packageDirectory.appendingPathComponent("package.json"))
    }
    let entry = base.appendingPathComponent("packages/examples/acp-demo/lib/bin.js")
    try? FileManager.default.createDirectory(at: entry.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data("#!/usr/bin/env node\n".utf8).write(to: entry)
    return entry
}

// Without the MCP row, the sandbox must not require the MCP client package:
// an existing installation that lacks it keeps working untouched.
let legacyBase = work.appendingPathComponent("install-legacy", isDirectory: true)
let legacyEntry = buildFakeInstall(in: legacyBase, includingMCPServer: false)
do {
    let sandbox = try ResidentDSHComposition.makeResidentSandbox(resolvingFrom: legacyEntry)
    defer { sandbox.removeAll() }
    check(true, "an installation without the MCP client package still builds the baseline sandbox")
    let link = sandbox.root.appendingPathComponent("node_modules/@deepseek-ai/dsh-mcp-client")
    check(!FileManager.default.fileExists(atPath: link.path),
          "the unused MCP client package is not linked into a baseline sandbox")
} catch {
    check(false, "an installation without the MCP client package still builds the baseline sandbox")
}

// With the row, the package is linked; without it, the mount fails closed
// rather than emitting a composition the loader cannot resolve.
let mcpBase = work.appendingPathComponent("install-mcp", isDirectory: true)
let mcpEntry = buildFakeInstall(in: mcpBase, includingMCPServer: true)
do {
    let sandbox = try ResidentDSHComposition.makeResidentSandbox(resolvingFrom: mcpEntry, mcpServer: server)
    defer { sandbox.removeAll() }
    let link = sandbox.root.appendingPathComponent("node_modules/@deepseek-ai/dsh-mcp-client")
    check(FileManager.default.fileExists(atPath: link.resolvingSymlinksInPath()
            .appendingPathComponent("package.json").path),
          "the sandbox resolves the official MCP client package when the row is mounted")
    check(ResidentDSHComposition.declaresImageInput(sandbox.compositionText),
          "the production read-back still declares image input with the MCP row mounted")
} catch {
    check(false, "the sandbox resolves the official MCP client package when the row is mounted")
}

let brokenBase = work.appendingPathComponent("install-broken", isDirectory: true)
let brokenEntry = buildFakeInstall(in: brokenBase, includingMCPServer: false)
do {
    let sandbox = try ResidentDSHComposition.makeResidentSandbox(resolvingFrom: brokenEntry, mcpServer: server)
    sandbox.removeAll()
    check(false, "an installation missing the MCP client package fails closed when the row is asked for")
} catch {
    check(true, "an installation missing the MCP client package fails closed when the row is asked for")
}

// The optional package is resolvable only through the optional whitelist.
check(ResidentDSHComposition.locateInstalledPackage(
    "@deepseek-ai/dsh-mcp-client", from: mcpEntry) != nil,
      "the MCP client package is a known mountable package")
check(ResidentDSHComposition.locateInstalledPackage(
    "@deepseek-ai/dsh-mystery", from: mcpEntry) == nil,
      "an unknown package is still not mountable")

if !failures.isEmpty {
    print("FAIL: \(failures.count) of \(count + failures.count) DSH MCP mount checks")
    for failure in failures { print("FAIL: \(failure)") }
    exit(1)
}
print("PASS: \(count) DSH MCP mount checks")
"""#

// Top-level code lives in `main.swift` on purpose: the checks below are a
// straight-line script, and a lowercase `main.swift` is the one file Swift lets
// carry top-level statements.
let main = work.appendingPathComponent("main.swift")
try harness.write(to: main, atomically: true, encoding: .utf8)
let binaryURL = work.appendingPathComponent("test")
let compile = Process(); compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
var arguments = ["-swift-version", "6", "-j1"]
arguments.append(root.appendingPathComponent(
    "apps/macos/Sources/GMGNRadio/Agent/ResidentDSHConfiguration.swift").path)
arguments.append(contentsOf: [main.path, "-o", binaryURL.path])
compile.arguments = arguments
try compile.run(); compile.waitUntilExit()
guard compile.terminationStatus == 0 else { exit(compile.terminationStatus) }
let test = Process(); test.executableURL = binaryURL
test.arguments = [work.path, binary, realSocket, realGrant]
try test.run(); test.waitUntilExit(); exit(test.terminationStatus)

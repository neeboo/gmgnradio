import Foundation

// Real-vision gate probe for the resident DSH native image transport.
// Everything runs through the production stack: ResidentDSHComposition for the
// on-disk restricted composition, ResidentDSHConnector for the official
// dsh-acp-demo ACP entry, AgentConversationService for the actual image+text
// turns. No HTTP shortcuts, no second resident, no prop generation, no key
// printing. The world is this probe's own fixture space and never claims to be
// a real host run.

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let build = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-dsh-vision-probe-build-\(UUID())", isDirectory: true)
try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: build) }

let harness = ##"""
import Foundation
import CryptoKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Probe-owned fixture space; explicitly NOT a real host run.
let fixtureWorldID = "probe-fixture-cabin"
// Read-only tool whitelist for the space-tool turn.
let readOnlyToolNames: Set<String> = ["inspect_world", "list_places"]

struct TurnTimeout: Error, LocalizedError {
    var errorDescription: String? { "probe 单轮请求超时" }
}
enum ProbeExit: Int32 {
    case fail = 1, gate = 2, credential = 3, network = 4, timeout = 5
}
/// Every exit path — bail and the watchdog alike — runs this first, so a real
/// ACP child can never be orphaned by an early failure.
@MainActor final class ProbeCleanup {
    static let shared = ProbeCleanup()
    private var handler: (() -> Void)?
    func install(_ handler: @escaping () -> Void) { self.handler = handler }
    func run() {
        handler?()
        handler = nil
    }
}
@MainActor func bail(_ code: ProbeExit, _ message: String) -> Never {
    print("FAIL[\(code.rawValue)]: \(message)")
    ProbeCleanup.shared.run()
    exit(code.rawValue)
}

// ── Test images via the system CoreGraphics + ImageIO encoder. ──
func writePNG(width: Int, height: Int, to url: URL, pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) throws {
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw AgentConversationError.imageFormatUnsupported
    }
    for y in 0..<height {
        for x in 0..<width {
            let (r, g, b) = pixel(x, y)
            context.setFillColor(CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1))
            context.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
    }
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
          ) else {
        throw AgentConversationError.imageFormatUnsupported
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw AgentConversationError.imageFormatUnsupported
    }
}

/// Transparent forwarding wrapper around the real connector: records the
/// actual handshake result and every wire prompt so the receipt can prove one
/// real session id, image=true, and per-turn image counts. The service's
/// injected branch hands openSession a temp cwd URL it never created, so this
/// wrapper always forwards the probe's own pre-created sandbox workspace.
@MainActor final class RecordingRealConnector: ResidentDSHImageConnecting {
    let base: ResidentDSHConnector
    let workspace: URL
    private(set) var openedSessionID: String?
    private(set) var openedImageCapability: Bool?
    private(set) var promptRecords: [(sessionID: String, imageCount: Int)] = []

    init(base: ResidentDSHConnector, workspace: URL) {
        self.base = base
        self.workspace = workspace
    }

    var isUsable: Bool { base.isUsable }

    func openSession(cwd: URL) async throws -> ResidentDSHSessionHandle {
        let handle = try await base.openSession(cwd: workspace)
        openedSessionID = handle.sessionID
        openedImageCapability = handle.imagePromptCapability
        return handle
    }

    func prompt(sessionID: String, blocks: [ResidentDSHPromptBlock]) async throws -> String {
        let imageCount = blocks.reduce(0) { count, block in
            if case .image = block { return count + 1 }
            return count
        }
        promptRecords.append((sessionID, imageCount))
        return try await base.prompt(sessionID: sessionID, blocks: blocks)
    }

    func cancelActivePrompt() { base.cancelActivePrompt() }
    func close() { base.close() }
}

@main struct Probe {
    @MainActor static func main() async throws {
        let startedAt = Date()
        let watchdog = Task {
            // The sleep must propagate its own cancellation: a successful run
            // cancels this watchdog and the catch exits instead of falling
            // through to exit(5) over a PASS.
            do { try await Task.sleep(nanoseconds: 1_200_000_000_000) }
            catch { return }
            print("FAIL[5]: probe overall watchdog timeout (20min)")
            ProbeCleanup.shared.run()
            exit(5)
        }
        defer { watchdog.cancel() }
        var checks = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if !value { bail(.fail, label) }
        }

        print("== probe-resident-dsh-vision ==")
        print("fixture: probe 自有 fixture 空间（\(fixtureWorldID)），不代表真实宿主运行")

        // ── Gate 1: final on-disk composition read-back + whitelist + model lock. ──
        let locator = AgentExecutableLocator()
        guard let transport = ResidentDSHComposition.locateNativeTransport(using: locator) else {
            bail(.gate, "native DSH ACP transport (node + official acp-demo entry) not found")
        }
        let sandbox = try ResidentDSHComposition.makeResidentSandbox(resolvingFrom: transport.entry)
        defer { sandbox.removeAll() }
        let diskText = try String(contentsOf: sandbox.compositionFileURL, encoding: .utf8)
        check(diskText == sandbox.compositionText, "composition read-back equals the validated text")
        check(ResidentDSHComposition.validateComposedConfig(diskText), "on-disk composition passes the whitelist validator")
        check(ResidentDSHComposition.declaresImageInput(diskText), "on-disk composition selects a model declaring image input")
        check(diskText.contains("provider: deepseek-official"), "composition locks the official provider route")
        check(diskText.contains("model: deepseek-flash"), "composition locks the current multimodal model deepseek-flash")
        check(diskText.contains("@deepseek-ai/dsh-credentials-local"), "managed credential source is the only key path")
        check(diskText.contains("@deepseek-ai/dsh-attachment-local"), "attachment store is mounted for native image admission")
        // The official schema check happens at boot: the acp-demo loader
        // validates this exact file when the server starts below.
        print("config: read-back/whitelist/model-lock PASS (official loader validation follows at boot)")

        // ── Gate 2: terminal credentials are never inherited. ──
        let scrubbed = ResidentDSHTransport.residentEnvironment(base: ProcessInfo.processInfo.environment)
        check(scrubbed["DEEPSEEK_API_KEY"] == nil, "DEEPSEEK_API_KEY never reaches the ACP child environment")
        check(scrubbed["DSH_HOME"] == nil && scrubbed["DSH_SNAPSHOT"] == nil, "DSH overrides never reach the ACP child environment")
        check(scrubbed["HOME"] != nil, "HOME is preserved for the managed credential document")
        print("env: child environment is allowlist-scrubbed; the key is only read by credentials-local")

        // ── Gate 3: production transport discovery + one single connector. ──
        let baseConnector = ResidentDSHConnector(
            nodeExecutable: transport.node, entryPoint: transport.entry,
            compositionFileURL: sandbox.compositionFileURL,
            requestTimeout: 300, cancellationGrace: 8
        )
        check(FileManager.default.fileExists(atPath: sandbox.workspace.path),
              "the sandbox workspace exists before openSession")
        let connector = RecordingRealConnector(base: baseConnector, workspace: sandbox.workspace)
        // Every exit path — including bail and the watchdog — must first close
        // the real ACP child and remove the probe's own directories.
        ProbeCleanup.shared.install {
            baseConnector.close()
            sandbox.removeAll()
            try? FileManager.default.removeItem(at: work_dir)
        }
        defer { ProbeCleanup.shared.run() }
        if CommandLine.arguments.contains("--handshake-only") {
            let session = try await connector.openSession(cwd: sandbox.workspace)
            check(session.imagePromptCapability, "official handshake advertises native image input")
            print("PASS: official initialize image=true; session/new=\(session.sessionID); zero prompts")
            return
        }
        try FileManager.default.createDirectory(at: work_dir, withIntermediateDirectories: true)

        // ── Test images: neutral file names; prompts below never carry the
        // shape counts or colors. ──
        let imageA = work_dir.appendingPathComponent("probe-img-a.png")
        let imageB = work_dir.appendingPathComponent("probe-img-b.png")
        do {
            // Image A: exactly ONE red square on white.
            try writePNG(width: 64, height: 64, to: imageA) { x, y in
                let inSquare = (20...43).contains(x) && (20...43).contains(y)
                return inSquare ? (220, 30, 30) : (255, 255, 255)
            }
            // Image B: exactly THREE blue circles on white.
            try writePNG(width: 64, height: 64, to: imageB) { x, y in
                let centers = [(14, 32), (32, 32), (50, 32)]
                let inCircle = centers.contains { center in
                    let dx = Double(x - center.0), dy = Double(y - center.1)
                    return (dx * dx + dy * dy).squareRoot() <= 7.5
                }
                return inCircle ? (30, 60, 220) : (255, 255, 255)
            }
        } catch {
            bail(.fail, "failed to encode the probe test PNGs: \(error)")
        }
        // Hash the actual on-disk files the transport will read.
        let shaA = SHA256.hash(data: try Data(contentsOf: imageA)).map { String(format: "%02x", $0) }.joined()
        let shaB = SHA256.hash(data: try Data(contentsOf: imageB)).map { String(format: "%02x", $0) }.joined()
        check(shaA != shaB, "the two test images have distinct hashes")
        print("image A sha256 \(shaA.prefix(16))… (expect 1 red square)")
        print("image B sha256 \(shaB.prefix(16))… (expect 3 blue circles)")

        // ── Production conversation service, DSH backend, single scope. ──
        let suite = "gmgn-probe-dsh-vision-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let service = AgentConversationService(
            locator: locator, defaults: defaults, residentDSHImageConnector: connector
        )
        service.selectBackend(.dsh)
        check(service.supportsWorldTools, "DSH advertises host world tools in the probe")
        defer { defaults.removePersistentDomain(forName: suite) }

        let world = ResidentWorldContext(
            selectedWorldID: fixtureWorldID, worldID: fixtureWorldID,
            displayName: "probe fixture 空间（非真实宿主）", revision: 1,
            residentPosition: [0, 0, 0], activeActivity: nil, activityPhase: nil,
            objects: [], availableActivities: []
        )
        var invokedToolNames: [String] = []
        let schemas: [[String: Any]] = [
            ["name": "inspect_world", "description": "只读查看当前空间公开资料",
             "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false]],
            ["name": "list_places", "description": "只读列出当前空间的可前往地点",
             "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false]],
        ]
        let schemasJSON = try JSONSerialization.data(withJSONObject: schemas, options: [.sortedKeys])
        // The tool callback cannot throw: serialize the fixture payloads here,
        // outside the closure.
        let listPlacesJSON = try JSONSerialization.data(
            withJSONObject: ["ok": true, "places": [["id": "wp.window", "name": "窗边"], ["id": "wp.shelf", "name": "展示架"]]],
            options: [.sortedKeys]
        )
        let inspectWorldJSON = try JSONSerialization.data(
            withJSONObject: ["ok": true, "world": fixtureWorldID],
            options: [.sortedKeys]
        )
        let tools = ResidentConversationTools(
            worldID: fixtureWorldID, schemasJSON: schemasJSON,
            call: { _, name, _ in
                invokedToolNames.append(name)
                return ResidentCodexToolReply(
                    resultJSON: name == "list_places" ? listPlacesJSON : inspectWorldJSON,
                    isError: false
                )
            },
            cancel: {}
        )

        func classify(_ error: Error) -> Never {
            if let conversationError = error as? AgentConversationError {
                switch conversationError {
                case .dshImageCapabilityUnavailable:
                    bail(.gate, "handshake did not advertise image capability (image gate refused)")
                case let .dshNativeTurnFailed(reason):
                    if reason == .missingCredential || reason == .authentication || reason == .quota {
                        bail(.credential, reason.userMessage)
                    }
                    if reason == .network { bail(.network, reason.userMessage) }
                    bail(.fail, reason.userMessage)
                default:
                    bail(.fail, String(describing: error))
                }
            }
            if error is TurnTimeout { bail(.timeout, "a vision turn exceeded its per-turn bound") }
            if error is CancellationError { bail(.timeout, "a vision turn was cancelled") }
            bail(.fail, String(describing: error))
        }
        func turn(_ text: String, images: [URL], seconds: Double = 240) async throws -> String {
            try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await service.send(text, imageURLs: images, worldContext: world, worldTools: tools)
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    throw TurnTimeout()
                }
                guard let first = try await group.next() else {
                    throw TurnTimeout()
                }
                group.cancelAll()
                return first
            }
        }
        func mentions(_ reply: String, _ terms: [String]) -> Bool {
            terms.contains { reply.localizedCaseInsensitiveContains($0) }
        }
        func excerpt(_ reply: String) -> String {
            let clean = reply.replacingOccurrences(of: "\n", with: " ")
            return String(clean.prefix(200))
        }

        // Wire-level turn markers: a human turn may issue several ACP prompts
        // when it runs the tool loop (the tool-result round rides an extra
        // zero-image request inside the same session).
        var humanTurnBounds: [Int] = []

        // ── Turn 1: image 1 + text through the production gate. ──
        humanTurnBounds.append(connector.promptRecords.count)
        let reply1: String
        do { reply1 = try await turn("请看这张图片：里面有什么颜色和形状？各有几个？", images: [imageA]) }
        catch { classify(error) }
        print("turn1 reply: \(excerpt(reply1))")
        check(mentions(reply1, ["红", "red"]) && mentions(reply1, ["1", "一"]),
              "turn 1 identifies the one red square from real image content")
        check(mentions(reply1, ["方形", "方块", "square"]),
              "turn 1 also names the square shape")

        // ── Turn 2: no new image — the session must still hold image 1. ──
        humanTurnBounds.append(connector.promptRecords.count)
        let reply2: String
        do { reply2 = try await turn("不要看新图片：刚才第一张图里是什么颜色、什么形状、有几个？", images: []) }
        catch { classify(error) }
        print("turn2 reply: \(excerpt(reply2))")
        check(mentions(reply2, ["红", "red"]) && mentions(reply2, ["1", "一"]),
              "turn 2 recalls image 1 without a new upload (session continuity)")

        // ── Turn 3: image 2 through the same session. ──
        humanTurnBounds.append(connector.promptRecords.count)
        let reply3: String
        do { reply3 = try await turn("再看这张新的图片：里面有几个什么颜色的什么形状？", images: [imageB]) }
        catch { classify(error) }
        print("turn3 reply: \(excerpt(reply3))")
        check(mentions(reply3, ["蓝", "blue"]) && mentions(reply3, ["3", "三"]),
              "turn 3 identifies the three blue circles from real image content")
        check(mentions(reply3, ["圆形", "圆", "circle"]),
              "turn 3 also names the circle shape")

        // ── Turn 4: one read-only official space tool inside the same session. ──
        humanTurnBounds.append(connector.promptRecords.count)
        let reply4: String
        do { reply4 = try await turn("请用只读工具列出当前空间有哪些地点，然后简要告诉我。", images: []) }
        catch { classify(error) }
        print("turn4 reply: \(excerpt(reply4))")
        check(!invokedToolNames.isEmpty, "turn 4 actually invoked a space tool")
        check(Set(invokedToolNames).isSubset(of: readOnlyToolNames),
              "only read-only tools were invoked (got \(invokedToolNames))")
        check(mentions(reply4, ["窗边", "展示架", "地点", "空间"]),
              "turn 4 answer reflects the trusted tool result")

        // ── Real wire session assertions from the forwarding connector. ──
        guard let realSessionID = connector.openedSessionID else {
            bail(.gate, "the real connector never opened a session")
        }
        check(connector.openedImageCapability == true, "handshake advertised image=true on the real wire")
        humanTurnBounds.append(connector.promptRecords.count)
        let turnRequestCounts = zip(humanTurnBounds, humanTurnBounds.dropFirst()).map { $1 - $0 }
        check(turnRequestCounts.count == 4 && turnRequestCounts.allSatisfy { $0 >= 1 },
              "each of the four human turns produced ACP requests (per-turn: \(turnRequestCounts)); tool-result rounds ride extra zero-image requests")
        check(connector.promptRecords.allSatisfy { $0.sessionID == realSessionID },
              "every ACP request used the one real session id \(realSessionID)")
        let imageCounts = connector.promptRecords.map(\.imageCount)
        check(imageCounts.filter { $0 > 0 } == [1, 1],
              "only image 1 and image 2 ride the wire, one image each (got \(imageCounts))")
        check(connector.promptRecords.first?.imageCount == 1,
              "the first wire prompt carries image 1")
        check(shaA != shaB, "the two test images have distinct hashes")

        // ── Safe receipt. ──
        let compositionSHA = SHA256.hash(data: Data(diskText.utf8)).map { String(format: "%02x", $0) }.joined()
        let elapsed = Int(Date().timeIntervalSince(startedAt))
        print("== RECEIPT ==")
        print("result: PASS")
        print("model: deepseek-flash @ deepseek-official")
        print("handshake: image=true (advertised at initialize, enforced by the production image gate)")
        print("transport: production ResidentDSHConnector through a transparent recording wrapper; probe-dedicated sandbox (the service default connector-factory path is not exercised by this probe)")
        print("session_id: \(realSessionID)")
        print("wire_requests: \(connector.promptRecords.count), human_turns: 4, image_counts: \(imageCounts), all on session_id above")
        print("config_sha256: \(compositionSHA)")
        print("image_a_sha256: \(shaA)")
        print("image_b_sha256: \(shaB)")
        print("session_continuity: no-image recall passed and the space tool turn ran in the same real session")
        print("tool_calls: \(invokedToolNames)")
        print("fixture: probe-owned space \(fixtureWorldID); not a real host run")
        print("env: child scrubbed of terminal credentials; key only via credentials-local; never printed")
        print("elapsed_seconds: \(elapsed)")
        ProbeCleanup.shared.run()
    }
}

// The harness embeds the probe work directory path computed at driver time.
"""##

// Driver: compile the production agent sources together with the probe
// harness, then run it under a hard overall bound.
let workDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-dsh-vision-probe-\(UUID())", isDirectory: true)
try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: workDir) }
var emitted = harness.replacingOccurrences(
    of: "let work_dir = placeholder", with: "let work_dir = URL(fileURLWithPath: \"\(workDir.path)\")"
)
if emitted == harness {
    // Insert the work directory binding right after the imports.
    emitted = harness.replacingOccurrences(
        of: "import CryptoKit\n",
        with: "import CryptoKit\n\nlet work_dir = URL(fileURLWithPath: \"\(workDir.path)\")\n"
    )
}
let main = build.appendingPathComponent("Main.swift")
try emitted.write(to: main, atomically: true, encoding: .utf8)
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
    print("FAIL[5]: probe compile exceeded 180s")
    exit(124)
}
compile.waitUntilExit()
guard compile.terminationStatus == 0 else { exit(compile.terminationStatus) }

// Compile-only mode: persist the binary outside the cleaned build directory,
// print its absolute path, and hand the lane back without any runtime (no ACP
// process, no model request).
let compileOnly = CommandLine.arguments.contains("--compile-only")
    || ProcessInfo.processInfo.environment["PROBE_COMPILE_ONLY"] == "1"
if compileOnly {
    let stable = URL(fileURLWithPath: "/tmp/gmgn-dsh-vision-probe")
    try? FileManager.default.removeItem(at: stable)
    try FileManager.default.copyItem(at: binary, to: stable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stable.path)
    try? FileManager.default.removeItem(at: build)
    print("PROBE_BINARY: \(stable.path)")
    print("compile-only: runtime disabled; run the binary above when the real-model lane opens")
    exit(0)
}
print("PROBE_BINARY: \(binary.path)")

let test = Process()
test.executableURL = binary
try test.run()
let runDeadline = Date().addingTimeInterval(1_300)
while test.isRunning && Date() < runDeadline {
    try await Task.sleep(nanoseconds: 200_000_000)
}
if test.isRunning {
    test.terminate()
    print("FAIL[5]: probe execution exceeded its overall bound")
    exit(124)
}
test.waitUntilExit()
exit(test.terminationStatus)

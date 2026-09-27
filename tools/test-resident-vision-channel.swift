// Hostless checks for the resident vision native-image channel.
// Compiles and RUNS the shipping production sources: the real
// ResidentWorldToolSession lease (cancel/expiry/call ledger), the real
// ResidentVisionToolbox + ResidentVisionCaptureService behind a fake frame
// surface, the real per-run ResidentVisionImageBox, and the real DSH native
// tool loop in AgentConversationService. Asserts that a successful capture
// ships a real PNG as a native image block in the same turn, that failed
// captures and cancelled/expired leases never ship image bytes, and that an
// image-incapable native session fails loudly instead of sending bytes.
//
// Run:  swift tools/test-resident-vision-channel.swift

import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sources = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
let runtimePackage = root.appendingPathComponent("apps/macos/Packages/WorldRuntime")
let runtimeBuild = runtimePackage.appendingPathComponent(".build/arm64-apple-macosx/debug")

func run(_ binary: String, _ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = arguments
    if binary.hasSuffix("swift") {
        process.standardOutput = Pipe()
        process.standardError = Pipe()
    }
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

// Keep the linked WorldRuntime objects fresh; a stale or missing module fails
// the run with its real status instead of being papered over.
let buildStatus = try run("/usr/bin/swift", ["build", "--disable-sandbox", "--package-path", runtimePackage.path])
guard buildStatus == 0 else {
    print("FAIL: WorldRuntime package build failed with \(buildStatus)")
    exit(buildStatus)
}
let objectFiles = try FileManager.default.contentsOfDirectory(
    at: runtimeBuild.appendingPathComponent("WorldRuntime.build"),
    includingPropertiesForKeys: nil
).filter { $0.pathExtension == "o" }.map(\.path)
guard !objectFiles.isEmpty else {
    print("FAIL: WorldRuntime object files missing")
    exit(1)
}

let work = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-vision-channel-\(UUID())")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

let harness = #"""
import Foundation
import WorldRuntime

// Same value shape the app module declares in VoiceSession/RealtimeDJSession.swift.
struct RealtimeDJToolCall: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let argumentsJSON: Data
}
struct RealtimeDJToolResult: Codable, Equatable, Sendable {
    let callID: String
    let resultJSON: Data
    let isError: Bool
}

@MainActor var checks = 0
@MainActor var failures = 0
@MainActor func check(_ value: Bool, _ label: String) {
    checks += 1
    if !value { failures += 1; print("FAIL: \(label)") }
}
func payload(_ result: RealtimeDJToolResult) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: result.resultJSON)) as? [String: Any] ?? [:]
}
func code(_ result: RealtimeDJToolResult) -> String? { payload(result)["code"] as? String }
func replyPayload(_ reply: ResidentCodexToolReply) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: reply.resultJSON)) as? [String: Any] ?? [:]
}
func replyCode(_ reply: ResidentCodexToolReply) -> String? { replyPayload(reply)["code"] as? String }

struct DSHLocator: AgentExecutableLocating {
    func locate(executableNames: [String]) -> URL? { URL(fileURLWithPath: "/fixture/dsh") }
}

/// Scripted native ACP session: records every prompt's blocks so image blocks
/// can be asserted against what the production loop actually submitted.
@MainActor final class RecordingConnector: ResidentDSHImageConnecting {
    var isUsable = true
    var imagePromptCapability: Bool
    private var outputs: [String]
    private(set) var prompts: [[ResidentDSHPromptBlock]] = []

    init(imagePromptCapability: Bool = true, outputs: [String]) {
        self.imagePromptCapability = imagePromptCapability
        self.outputs = outputs
    }

    func openSession(cwd: URL) async throws -> ResidentDSHSessionHandle {
        ResidentDSHSessionHandle(sessionID: "vision-session", imagePromptCapability: imagePromptCapability)
    }

    func prompt(sessionID: String, blocks: [ResidentDSHPromptBlock]) async throws -> String {
        prompts.append(blocks)
        guard !outputs.isEmpty else {
            throw ResidentDSHTransportError.connectionClosed
        }
        return outputs.removeFirst()
    }

    func cancelActivePrompt() {}
    func awaitCancellationSettled() async {}
    func close() { isUsable = false }
}

/// Fake frame source: stamps a fresh frame so the production freshness gate accepts it.
@MainActor final class FakeVisionSurface: ResidentVisionSurface {
    enum Behavior {
        case valid
        case explicit(ResidentVisionSurfaceFrameResult)
    }
    var behavior: Behavior
    init(_ behavior: Behavior = .valid) { self.behavior = behavior }

    func captureCurrentObservation(
        request: ResidentVisionCaptureRequest,
        requestedAt: Date
    ) async -> ResidentVisionSurfaceFrameResult {
        if case let .explicit(result) = behavior { return result }
        let stamp = ResidentVisionRenderedStamp(
            surfaceProfile: "full_stage_drawable", frameIndex: 7,
            capturedAt: requestedAt.addingTimeInterval(0.01),
            worldID: request.worldID,
            residentAvatarID: "resident.fixture",
            residentAvatarFrameRevision: 3,
            residentPosition: [0, 0, 0],
            camera: ResidentVisionCameraStamp(
                label: "full-stage observer", kind: .fullStageObserver,
                position: [0, 1.4, 2.1], yaw: 0, pitch: 0,
                fieldOfViewDegrees: 66, coordinateSpace: "stage"))
        return .frame(ResidentVisionRenderedFrame(
            pixelsBGRA: Data(repeating: 0x80, count: 16 * 16 * 4),
            width: 16, height: 16, bytesPerRow: 16 * 4, stamp: stamp))
    }
}

/// Mirrors the app's per-run wiring (GMGNRadioApp.makeResidentWorldTools):
/// the AdditionalTool handle stores the typed PNG in the per-run box, and the
/// outer closure always awaits session.call and only attaches a successful
/// boxed image. The production session/toolbox/capture/box types are real.
@MainActor final class RunWiring {
    let session: ResidentWorldToolSession
    let box: ResidentVisionImageBox
    let toolbox: ResidentVisionToolbox
    private(set) var capturedCalls: [String] = []

    init(messageID: UUID, manifest: WorldManifest, surface: (any ResidentVisionSurface)?,
         isCurrent: @escaping @MainActor () -> Bool, deadline: Date,
         now: @escaping @MainActor () -> Date) {
        let worldID = manifest.worldID
        let imageBox = ResidentVisionImageBox()
        box = imageBox
        let toolbox = ResidentVisionToolbox(surface: surface, fileRoot: nil,
            currentSession: { isCurrent() ? ResidentVisionToolbox.Session(
                runID: messageID, worldID: worldID, worldRevision: 3) : nil },
            now: now)
        self.toolbox = toolbox
        let visionTools = ResidentVisionToolContract.additionalToolSchemas().compactMap { schema -> ResidentWorldToolSession.AdditionalTool? in
            guard let name = schema["name"] as? String,
                  let description = schema["description"] as? String,
                  let inputSchema = schema["inputSchema"] as? [String: Any] else { return nil }
            return ResidentWorldToolSession.AdditionalTool(name: name, description: description,
                inputSchema: inputSchema, validate: { _ in true },
                handle: { [imageBox] id, arguments in
                    let reply = await toolbox.handleImage(name: name, argumentsJSON: arguments)
                    if !reply.isError, let image = reply.image {
                        imageBox.store(callID: id, image: image)
                    }
                    return RealtimeDJToolResult(callID: id, resultJSON: reply.payloadJSON, isError: reply.isError)
                })
        }
        session = ResidentWorldToolSession(scopeID: messageID, worldID: worldID,
            dispatcher: WorldAgentToolDispatcher(takeoverEnabled: { true },
                context: try! WorldAgentContext(manifest: manifest),
                availableActivity: { _ in true }),
            deadline: deadline, now: now, isCurrent: isCurrent,
            onCancel: { [imageBox] in imageBox.removeAll() },
            additionalTools: visionTools, maximumCalls: nil)
    }

    func conversationTools() -> ResidentConversationTools {
        ResidentConversationTools(visionCapable: true, worldID: session.worldID,
            schemasJSON: session.toolSchemasJSON,
            call: { [self] requestID, name, arguments in
                capturedCalls.append(name)
                let result = await session.call(requestID: requestID, name: name, argumentsJSON: arguments)
                let image = box.take(callID: requestID, succeeded: !result.isError)
                return ResidentCodexToolReply(resultJSON: result.resultJSON, isError: result.isError, image: image)
            },
            cancel: { [self] in session.cancel() })
    }
}

func defaults(_ suffix: String) -> UserDefaults {
    let suite = "vision-channel-\(suffix)-\(UUID())"
    let value = UserDefaults(suiteName: suite)!
    value.removePersistentDomain(forName: suite)
    value.set(AgentConversationBackendID.dsh.rawValue, forKey: AgentConversationPreferenceKeys.selectedBackend)
    return value
}

func fixturePNG() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-\(UUID()).png")
    try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00]).write(to: url)
    return url
}

@MainActor func firstImage(_ blocks: [ResidentDSHPromptBlock]) -> ResidentDSHImageBlock? {
    blocks.compactMap { block in
        if case let .image(image) = block { return image }
        return nil
    }.first
}

@MainActor func textBlocks(_ blocks: [ResidentDSHPromptBlock]) -> [String] {
    blocks.compactMap { block in
        if case let .text(text) = block { return text }
        return nil
    }
}

@MainActor func makeWorldContext(worldID: String) -> ResidentWorldContext {
    ResidentWorldContext(selectedWorldID: worldID, worldID: worldID, displayName: "生活舱",
        revision: 1, residentPosition: [0, 0, 0], activeActivity: nil, activityPhase: nil,
        objects: [], availableActivities: [])
}

@MainActor @main struct Tests {
    static func main() async throws {
        let manifest = try JSONDecoder().decode(WorldManifest.self, from: Data(contentsOf:
            URL(fileURLWithPath: "apps/macos/Resources/Worlds/marble-living-cabin/world.json")))
        let worldID = manifest.worldID
        let world = makeWorldContext(worldID: worldID)

        // 1. Successful capture: the native loop ships a real PNG block in the
        //    same turn as the typed result; the text never carries base64.
        do {
            let connector = RecordingConnector(outputs: [
                #"{"type":"tool_call","call_id":"vision-1","name":"gmgn_capture_space_photo","arguments":{}}"#,
                #"{"type":"final","text":"我看到当前画面了"}"#,
            ])
            let wiring = RunWiring(messageID: UUID(), manifest: manifest, surface: FakeVisionSurface(),
                isCurrent: { true }, deadline: Date().addingTimeInterval(300), now: { Date() })
            let service = AgentConversationService(locator: DSHLocator(), defaults: defaults("typed"),
                residentDSHImageConnector: connector)
            let reply = try await service.send("拍一张看看", worldContext: world, worldTools: wiring.conversationTools())
            check(reply == "我看到当前画面了", "the vision turn completes with the model reply")
            check(connector.prompts.count == 2, "two native prompts (tool call + result)")
            let prompts = connector.prompts
            guard prompts.count == 2 else { exit(failures == 0 ? 0 : 1) }
            let image = firstImage(prompts[1])
            check(image?.mimeType == "image/png", "the result turn carries an image/png native block")
            check(image.map { ResidentVisionPNG.looksPlausible($0.data) } == true,
                "the native block holds real PNG bytes")
            check(image.map { $0.data.count > 64 } == true, "the PNG bytes are a real encoded frame, not a stub")
            let texts = textBlocks(prompts[1])
            check(texts.count == 1 && !texts[0].contains("iVBOR") && !texts[0].contains("base64"),
                "the visible text carries metadata only, never image bytes")
            check(wiring.capturedCalls == ["capture_space_photo"],
                "the formal vision tool reached the session ledger by its canonical name")
            check(wiring.session.records.count == 1 && wiring.session.records[0].ok,
                "the session ledger records the successful vision call")
            check(wiring.session.records[0].callID == "vision-1",
                "the ledger keeps the transport call identity")
            let fileless = await wiring.toolbox.handleImage(name: "capture_space_photo", argumentsJSON: Data("{}".utf8))
            check(fileless.image != nil && fileless.image?.fileURL == nil,
                "the native capture produces PNG bytes without creating a file")
        }

        // 2. Failed capture: honest failure, no image block, ledger records failure.
        do {
            let connector = RecordingConnector(outputs: [
                #"{"type":"tool_call","call_id":"vision-2","name":"gmgn_capture_space_photo","arguments":{}}"#,
                #"{"type":"final","text":"画面暂不可用"}"#,
            ])
            let wiring = RunWiring(messageID: UUID(), manifest: manifest,
                surface: FakeVisionSurface(.explicit(.failure(code: .noPicture, message: "暂无画面"))),
                isCurrent: { true }, deadline: Date().addingTimeInterval(300), now: { Date() })
            let service = AgentConversationService(locator: DSHLocator(), defaults: defaults("noimage"),
                residentDSHImageConnector: connector)
            let reply = try await service.send("拍一张", worldContext: world, worldTools: wiring.conversationTools())
            check(reply == "画面暂不可用", "a failed capture is reported honestly to the model")
            let prompts = connector.prompts
            check(prompts.count == 2 && firstImage(prompts[1]) == nil,
                "a failed capture never ships an image block")
            check(wiring.session.records.count == 1 && !wiring.session.records[0].ok,
                "the ledger records the failed capture")
        }

        // 3. Image-incapable native session with EMPTY initial imageURLs: the
        //    PNG only ever arrives through the capture tool's typed reply, so
        //    the runDSHNativeToolLoop append gate (imagePromptCapability AND
        //    modelImageDeclared) must fail the turn loudly before any image
        //    bytes leave the host — the initial-images gate cannot cover this.
        do {
            let connector = RecordingConnector(imagePromptCapability: false, outputs: [
                #"{"type":"tool_call","call_id":"vision-3","name":"gmgn_capture_space_photo","arguments":{}}"#,
                #"{"type":"final","text":"不应到达"}"#,
            ])
            let wiring = RunWiring(messageID: UUID(), manifest: manifest, surface: FakeVisionSurface(),
                isCurrent: { true }, deadline: Date().addingTimeInterval(300), now: { Date() })
            let service = AgentConversationService(locator: DSHLocator(), defaults: defaults("nocap"),
                residentDSHImageConnector: connector)
            var capabilityRejected = false
            do { _ = try await service.send("拍一张", worldContext: world, worldTools: wiring.conversationTools()) }
            catch AgentConversationError.dshImageCapabilityUnavailable { capabilityRejected = true }
            catch {}
            check(capabilityRejected, "an image-incapable session rejects the capture-only image reply")
            check(connector.prompts.count == 1 && firstImage(connector.prompts[0]) == nil,
                "the turn stops before any capture PNG is appended to a native prompt")
        }

        // 4. Input images on an image-incapable session are rejected before any prompt.
        do {
            let connector = RecordingConnector(imagePromptCapability: false, outputs: [])
            let wiring = RunWiring(messageID: UUID(), manifest: manifest, surface: FakeVisionSurface(),
                isCurrent: { true }, deadline: Date().addingTimeInterval(300), now: { Date() })
            let service = AgentConversationService(locator: DSHLocator(), defaults: defaults("nocap-input"),
                residentDSHImageConnector: connector)
            var inputRejected = false
            do { _ = try await service.send("看这张", imageURLs: [try fixturePNG()],
                worldContext: world, worldTools: wiring.conversationTools()) }
            catch AgentConversationError.dshImageCapabilityUnavailable { inputRejected = true }
            catch {}
            check(inputRejected && connector.prompts.isEmpty,
                "user attachments on an incapable session fail before any model request")
        }

        // 5. Session lease: a cancelled session fails the vision call, clears the
        //    boxed image, and the ledger keeps the closed-call record.
        do {
            let connector = RecordingConnector(outputs: [])
            let wiring = RunWiring(messageID: UUID(), manifest: manifest, surface: FakeVisionSurface(),
                isCurrent: { true }, deadline: Date().addingTimeInterval(300), now: { Date() })
            let tools = wiring.conversationTools()
            wiring.session.cancel()
            let cancelled = await tools.call("vision-4", "capture_space_photo", Data("{}".utf8))
            check(replyCode(cancelled) == "tool_session_cancelled", "a cancelled lease fails the vision call")
            check(wiring.session.records.last?.ok == false, "the cancelled call lands in the ledger as failure")
            let reply = await tools.call("vision-4", "capture_space_photo", Data("{}".utf8))
            check(replyCode(reply) == "tool_session_cancelled", "the same call id stays cancelled after the lease closed")
        }

        // 6. Session lease: an expired deadline fails the vision call without an image.
        do {
            let clock = Date().addingTimeInterval(-600)
            let wiring = RunWiring(messageID: UUID(), manifest: manifest, surface: FakeVisionSurface(),
                isCurrent: { true }, deadline: clock.addingTimeInterval(-1), now: { clock })
            let tools = wiring.conversationTools()
            let expired = await tools.call("vision-5", "capture_space_photo", Data("{}".utf8))
            check(replyCode(expired) == "tool_session_expired", "an expired lease fails the vision call")
            check(wiring.box.take(callID: "vision-5", succeeded: true) == nil,
                "the per-run box holds no image for a call that never captured")
        }

        // 7. Stale world/session gating: currentSession nil (loop moved on) fails
        //    honestly with session_mismatch instead of capturing.
        do {
            let wiring = RunWiring(messageID: UUID(), manifest: manifest, surface: FakeVisionSurface(),
                isCurrent: { false }, deadline: Date().addingTimeInterval(300), now: { Date() })
            let tools = wiring.conversationTools()
            let stale = await tools.call("vision-6", "capture_space_photo", Data("{}".utf8))
            check(replyCode(stale) == "stale_world_session", "a stale world session refuses the vision call")
        }

        // 8. Box semantics: single-use success handoff, failure drops, clear-all.
        do {
            let box = ResidentVisionImageBox()
            let camera = ResidentVisionCameraStamp(label: "fixture", kind: .fullStageObserver,
                position: [0, 0, 0], yaw: 0, pitch: 0, fieldOfViewDegrees: 66, coordinateSpace: "world")
            let stamp = ResidentVisionRenderedStamp(surfaceProfile: "full_stage_drawable", frameIndex: 1,
                capturedAt: Date(timeIntervalSince1970: 100), worldID: worldID,
                residentAvatarID: nil, residentAvatarFrameRevision: nil, residentPosition: nil, camera: camera)
            let frame = ResidentVisionRenderedFrame(pixelsBGRA: Data(repeating: 0x7F, count: 16), width: 4,
                height: 1, bytesPerRow: 16, stamp: stamp)
            let image = ResidentVisionImage(pngData: Data([0x89, 0x50, 0x4E, 0x47, 0x01]),
                metadata: ResidentVisionMetadata.make(renderedFrame: frame,
                    perspective: .currentObservation, expectedWorldRevision: nil), fileURL: nil)
            box.store(callID: "a", image: image)
            check(box.take(callID: "a", succeeded: false) == nil, "a failed call never releases the boxed image")
            check(box.take(callID: "b", succeeded: true) == nil, "an unknown call id yields nothing")
            box.store(callID: "a", image: image)
            check(box.take(callID: "a", succeeded: true) == image, "a successful call takes exactly the boxed image")
            check(box.take(callID: "a", succeeded: true) == nil, "the handoff is single-use")
            box.store(callID: "c", image: image)
            box.removeAll()
            check(box.take(callID: "c", succeeded: true) == nil, "session cancel clears every boxed image")
        }

        print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) resident vision channel checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#

let main = work.appendingPathComponent("Main.swift")
try harness.write(to: main, atomically: true, encoding: .utf8)
let binary = work.appendingPathComponent("test")
let agentSources = ["CodexCLI", "AgentConversationService", "ResidentCodexTransport", "ResidentCodexPolicy",
    "ResidentCodexAgent", "ResidentSteeringDelivery", "ResidentDSHTransport", "ResidentDSHConfiguration",
    "ResidentStateClient", "ResidentMemoryClient", "ResidentConversationMemory",
    "ResidentDSHAgentToolBridge", "ResidentDSHHostToolsBridge",
    "ResidentClaudeToolBridge", "ResidentClaudeProcessRunner"]
    .map { sources.appendingPathComponent("Agent/\($0).swift").path }
let sessionSources = ["Agent/WorldAgentContext.swift", "Agent/WorldAgentToolContract.swift",
    "Agent/WorldAgentToolDispatcher.swift", "Agent/ResidentWorldToolSession.swift",
    "Agent/ResidentVisionTools.swift", "Agent/ResidentVisionImageBox.swift",
    "Presence/ResidentVisionCapture.swift"].map { sources.appendingPathComponent($0).path }
var arguments = ["-parse-as-library", "-j1",
    "-I", runtimeBuild.appendingPathComponent("Modules").path]
arguments += agentSources + sessionSources + objectFiles + [main.path, "-o", binary.path]
let compileStatus = try run("/usr/bin/swiftc", arguments)
guard compileStatus == 0 else { exit(compileStatus) }
exit(try run(binary.path, []))

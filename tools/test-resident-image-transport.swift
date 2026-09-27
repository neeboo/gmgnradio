// Local mocks only: no Codex model, host app or credentials are opened.
import Foundation
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let work = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-resident-images-\(UUID())")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }
let harness = #"""
import Foundation
struct Locator: AgentExecutableLocating {
    func locate(executableNames: [String]) -> URL? { URL(fileURLWithPath: "/fixture/codex") }
}
@MainActor final class RecordingDSHConnector: ResidentDSHImageConnecting {
    struct PromptRecord {
        let sessionID: String
        let blocks: [ResidentDSHPromptBlock]
    }
    private(set) var prompts: [PromptRecord] = []
    private(set) var cancellations = 0
    private(set) var closed = false
    private let handshakeImage: Bool
    private let gate: Bool
    private var replies: [Result<String, Error>]
    private var pending: CheckedContinuation<String, Error>?
    private var sessionCounter = 0
    /// Cancellation observed before a gated prompt registers must still take
    /// effect; otherwise the prompt would suspend with nobody to resume it.
    private var cancelledWhileIdle = false

    init(handshakeImage: Bool = true, replies: [Result<String, Error>], gate: Bool = false) {
        self.handshakeImage = handshakeImage
        self.replies = replies
        self.gate = gate
    }

    func appendReply(_ reply: Result<String, Error>) { replies.append(reply) }

    var isUsable: Bool { !closed }

    func openSession(cwd: URL) async throws -> ResidentDSHSessionHandle {
        sessionCounter += 1
        return ResidentDSHSessionHandle(sessionID: "dsh-native-\(sessionCounter)", imagePromptCapability: handshakeImage)
    }

    func prompt(sessionID: String, blocks: [ResidentDSHPromptBlock]) async throws -> String {
        prompts.append(PromptRecord(sessionID: sessionID, blocks: blocks))
        // Only the first prompt gates: later turns exercise session reuse.
        if gate && prompts.count == 1 {
            if cancelledWhileIdle {
                cancelledWhileIdle = false
                throw CancellationError()
            }
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        guard !replies.isEmpty else { throw AgentConversationError.emptyReply }
        return try replies.removeFirst().get()
    }

    func cancelActivePrompt() {
        cancellations += 1
        if let pending {
            pending.resume(throwing: CancellationError())
            self.pending = nil
        } else {
            cancelledWhileIdle = true
        }
    }

    func close() { closed = true }
}

@MainActor final class DelayedBootConnector: ResidentDSHImageConnecting {
    private(set) var opens = 0
    private(set) var prompts: [String] = []
    private(set) var closes = 0
    private var boot: CheckedContinuation<ResidentDSHSessionHandle, Never>?
    var isUsable: Bool { true }
    func openSession(cwd: URL) async throws -> ResidentDSHSessionHandle {
        opens += 1
        if opens == 1 { return await withCheckedContinuation { boot = $0 } }
        return ResidentDSHSessionHandle(sessionID: "boot-\(opens)", imagePromptCapability: true)
    }
    func releaseBoot() {
        boot?.resume(returning: ResidentDSHSessionHandle(sessionID: "boot-1", imagePromptCapability: true))
        boot = nil
    }
    func prompt(sessionID: String, blocks: [ResidentDSHPromptBlock]) async throws -> String {
        prompts.append(sessionID)
        return "fresh reply"
    }
    func cancelActivePrompt() {}
    func close() { closes += 1 }
}
actor Recorder: CodexCommandRunning {
    var calls: [[String]] = []
    func run(arguments: [String], standardInput: String?) async throws -> CodexCommandResult {
        calls.append(arguments)
        return CodexCommandResult(exitCode: 0, output: "{\"type\":\"thread.started\",\"thread_id\":\"ordinary\"}\n{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"看到了\"}}")
    }
}
@main struct Tests {
    @MainActor static func main() async throws {
        // Overall watchdog: this suite must never hang past five minutes.
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 300_000_000_000)
            print("FAIL: overall test watchdog timeout (5min)")
            exit(1)
        }
        defer { watchdog.cancel() }
        var count = 0
        func check(_ value: Bool, _ label: String) { count += 1; if !value { fatalError("FAIL: " + label) } }
        func waitFor(_ condition: @MainActor () -> Bool, seconds: Double, _ label: String) async {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() && Date() < deadline { await Task.yield() }
            check(condition(), label + " (bounded wait \(seconds)s)")
        }
        let suite = "gmgn-image-test-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let runner = Recorder()
        let service = AgentConversationService(locator: Locator(), defaults: defaults, runnerFactory: { _ in runner })
        service.selectBackend(.codex)
        let images = [URL(fileURLWithPath: "/fixture/prepared one.png"), URL(fileURLWithPath: "/fixture/prepared two.png")]
        check(try await service.send("", imageURLs: images) == "看到了", "pure image CLI request is supported")
        var calls = await runner.calls
        check(calls[0] == ["exec", "--image", images[0].path, "--image", images[1].path, "--json", "-"], "CLI receives images as arguments, never prompt paths")
        _ = try await service.send("看看细节", imageURLs: [images[1]])
        calls = await runner.calls
        check(calls[1] == ["exec", "resume", "ordinary", "--image", images[1].path, "--json", "-"], "resumed CLI receives image")
        _ = try await service.send("纯文字")
        calls = await runner.calls
        check(!calls[2].contains("--image"), "text-only arguments unchanged")
        for backend in AgentConversationBackendID.allCases where backend != .codex {
            service.selectBackend(backend)
            do { try service.validateImageSupport(imageURLs: images); check(false, "draft validation should reject unsupported image provider") }
            catch AgentConversationError.imagesUnsupported(let rejected) { check(rejected == backend, "draft rejection identifies provider") }
            try service.validateImageSupport(imageURLs: [])
            do { _ = try await service.send("图片", imageURLs: images); check(false, "unsupported backend should reject images") }
            catch AgentConversationError.imagesUnsupported(let rejected) { check(rejected == backend, "unsupported backend named clearly") }
        }
        check(await runner.calls.count == 3, "unsupported image does not invoke text-only backend")
        let world = ResidentWorldContext(selectedWorldID: "fixture", worldID: "fixture", displayName: nil, revision: 1, residentPosition: nil, activeActivity: nil, activityPhase: nil, objects: [], availableActivities: [])
        let tools = ResidentConversationTools(worldID: "fixture", schemasJSON: Data("[]".utf8), call: { _, _, _ in ResidentCodexToolReply(resultJSON: Data("{}".utf8), isError: false) }, cancel: {})
        var receivedImages: [URL] = []
        var nativeSessions: [String?] = []
        let native = AgentConversationService(locator: Locator(), defaults: defaults, residentImageSender: { _, prompt, urls, session, _ in
            receivedImages = urls
            nativeSessions.append(session)
            return AgentConversationOutcome(reply: "收到图片", sessionID: "native-image")
        })
        native.selectBackend(.codex)
        check(native.supportsWorldTools, "image-aware injected sender supports world tools")
        check(try await native.send("", imageURLs: images, worldContext: world, worldTools: tools) == "收到图片", "image-aware sender receives pure-image request")
        check(receivedImages == images, "native sender does not silently drop attachments")
        _ = try await native.send("下一张", imageURLs: [images[1]], worldContext: world, worldTools: tools)
        check(nativeSessions.count == 2 && nativeSessions[0] == nil && nativeSessions[1] == "native-image",
              "new image turns keep the same resident session after the registry migration")
        let legacy = AgentConversationService(locator: Locator(), defaults: defaults, residentSender: { _, _, _, _ in
            fatalError("text-only injected sender cannot receive images")
        })
        do { _ = try await legacy.send("图", imageURLs: images, worldContext: world, worldTools: tools); check(false, "legacy sender must reject images") }
        catch AgentConversationError.imageTransportUnavailable { check(true, "legacy injected sender gives explicit image limitation") }
        var pending: CheckedContinuation<AgentConversationOutcome, Error>?
        let delayed = AgentConversationService(locator: Locator(), defaults: defaults, residentImageSender: { _, _, _, _, _ in
            try await withCheckedThrowingContinuation { pending = $0 }
        })
        let task = Task { try await delayed.send("", imageURLs: images, worldContext: world, worldTools: tools) }
        await waitFor({ pending != nil }, seconds: 5, "image sender starts")
        delayed.selectBackend(.dsh)
        pending?.resume(returning: AgentConversationOutcome(reply: "迟到", sessionID: "late-image"))
        do { _ = try await task.value; check(false, "old image response must be discarded") }
        catch AgentConversationError.cancelled { check(true, "image cancellation preserves session boundary") }
        check(delayed.preferenceStore.sessionID(for: .codex, scope: world.sessionScope + ".tools.v8") == "native-image", "cancelled image cannot replace saved session")

        // ── DSH 原生图片传输（官方 ACP 入口 + 受限组合） ──
        let dshWork = FileManager.default.temporaryDirectory
            .appendingPathComponent("gmgn-resident-images-dsh-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dshWork, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dshWork) }
        let pngBytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        let pngA = dshWork.appendingPathComponent("resident-a.png")
        let pngB = dshWork.appendingPathComponent("resident-b.png")
        try pngBytes.write(to: pngA)
        try pngBytes.write(to: pngB)
        let persona = "你是生活空间的居民。"

        let sandbox = dshWork.appendingPathComponent("dsh-home", isDirectory: true)
        let composed = ResidentDSHComposition.residentYAML(
            attachmentHome: sandbox.appendingPathComponent("home"),
            persistenceRoot: sandbox.appendingPathComponent("sessions"),
            persona: persona)
        check(ResidentDSHComposition.validateComposedConfig(composed), "resident composition passes its own whitelist read-back")
        check(ResidentDSHComposition.declaresImageInput(composed), "resident composition selects a model that declares image input")
        check(composed.contains("    reasoningEffort: low\n    maxTokens: 8192\n"),
              "App native composition bounds interactive reasoning and reply tokens")

        let attachmentRow = "- id: attachment-local\n  name: '@deepseek-ai/dsh-attachment-local'\n  config:\n    dshHome: '\(sandbox.appendingPathComponent("home").path)'\n"
        check(composed.contains(attachmentRow), "the sandboxed attachment row is emitted verbatim")
        let visionCatalogRow = "      - id: deepseek-v4-flash-vision-exp\n        inputModalities: [text, image]\n"
        check(composed.contains(visionCatalogRow), "the vision model declares image input in the mounted catalog")
        let skillsRow = "    skills:\n      enabled: false\n"
        check(composed.contains(skillsRow), "skills are explicitly disabled because the spine enables them by default")
        // The composition mounts the native web seam: the web service pinned to
        // the DeepSeek search provider and the local HTTP fetch provider, plus
        // the model-facing web_search/web_fetch tools.
        let webRow = "- id: web\n  name: '@deepseek-ai/dsh-web'\n  config:\n    searchProvider: deepseek-official\n"
        check(composed.contains(webRow), "the native web seam is mounted verbatim with the search provider pinned")
        check(composed.contains("- id: web-fetch-http\n  name: '@deepseek-ai/dsh-web-fetch-http'\n"),
              "the public HTTP fetch provider is mounted for page reading")
        check(composed.contains("- id: web-search-deepseek\n  name: '@deepseek-ai/dsh-web-search-deepseek'\n"),
              "the DeepSeek-backed search provider is mounted")
        check(composed.contains("- id: tool-web\n  name: '@deepseek-ai/dsh-tool-web'"),
              "the model-facing web tools row is mounted (search + fetch defaults)")
        let toolWebRow = "- id: tool-web\n  name: '@deepseek-ai/dsh-tool-web'"
        let tampered: [(String, String)] = [
            ("missing reply budget", composed.replacingOccurrences(of: "    maxTokens: 8192\n", with: "")),
            ("expanded reply budget", composed.replacingOccurrences(of: "    maxTokens: 8192", with: "    maxTokens: 256000")),
            ("expanded reasoning default", composed.replacingOccurrences(of: "    reasoningEffort: low", with: "    reasoningEffort: high")),
            ("extra model config", composed.replacingOccurrences(of: "    models:", with: "    thinking: enabled\n    models:")),
            ("bash row", composed + "\n- id: tool-bash\n  name: '@deepseek-ai/dsh-tool-bash'\n"),
            ("fs row", composed + "\n- id: tool-fs\n  name: '@deepseek-ai/dsh-tool-fs'\n"),
            ("subagent row", composed + "\n- id: tool-subagent\n  name: '@deepseek-ai/dsh-tool-subagent'\n"),
            ("unknown row", composed + "\n- id: mystery-tool\n  name: '@deepseek-ai/dsh-mystery'\n"),
            ("missing attachment store", composed.replacingOccurrences(of: attachmentRow, with: "")),
            ("text-only selection", composed.replacingOccurrences(of: "    model: deepseek-v4-flash-vision-exp", with: "    model: deepseek-v4-flash")),
            ("text-only catalog", composed.replacingOccurrences(of: visionCatalogRow, with: "      - id: deepseek-v4-flash-vision-exp\n        inputModalities: [text]\n")),
            ("bash re-enabled", composed.replacingOccurrences(of: "    toolBash: false", with: "    toolBash: true")),
            ("missing workspaceContext", composed.replacingOccurrences(of: "    workspaceContext: false\n", with: "")),
            ("unknown provider", composed.replacingOccurrences(of: "    provider: deepseek-official", with: "    provider: deepseek-other")),
            ("skills re-enabled", composed.replacingOccurrences(of: "      enabled: false", with: "      enabled: true")),
            ("skills default-on", composed.replacingOccurrences(of: skillsRow, with: "")),
            ("jobs re-enabled", composed.replacingOccurrences(of: "    toolJobs: false", with: "    toolJobs: {}")),
            ("web search provider swapped", composed.replacingOccurrences(of: "searchProvider: deepseek-official", with: "searchProvider: deepseek-other")),
            ("web config widened", composed.replacingOccurrences(of: "searchProvider: deepseek-official", with: "searchProvider: deepseek-official\n    allowedDomains: [example.com]")),
            ("web-fetch provider removed", composed.replacingOccurrences(of: "- id: web-fetch-http\n  name: '@deepseek-ai/dsh-web-fetch-http'\n", with: "")),
            ("search provider removed", composed.replacingOccurrences(of: "- id: web-search-deepseek\n  name: '@deepseek-ai/dsh-web-search-deepseek'\n", with: "")),
            ("tool-web row removed", composed.replacingOccurrences(of: toolWebRow, with: "")),
            ("tool-web given config", composed.replacingOccurrences(of: toolWebRow, with: "- id: tool-web\n  name: '@deepseek-ai/dsh-tool-web'\n  config:\n    fetch: false\n")),
            ("acp-agent extra config key", composed.replacingOccurrences(of: "    workspaceContext: false", with: "    workspaceContext: false\n    fetch: true")),
        ]
        for (label, text) in tampered {
            check(!ResidentDSHComposition.validateComposedConfig(text), "tampered composition fails closed: \(label)")
        }
        check(!ResidentDSHComposition.declaresImageInput(
            composed.replacingOccurrences(of: visionCatalogRow, with: "      - id: deepseek-v4-flash-vision-exp\n        inputModalities: [text]\n")),
              "a text-only catalog cannot claim image input")

        // ── Plugin dependency resolution: the official loader anchors bare
        // specifiers at the composition file's directory, so the sandbox must
        // link the four mounted packages to the selected ACP installation. ──
        func buildFakeInstall(in base: URL, omitting omitted: String? = nil) -> URL {
            let names = ["dsh-llm-deepseek", "dsh-credentials-local", "dsh-attachment-local", "dsh-acp-demo",
                         "dsh-web", "dsh-web-fetch-http", "dsh-web-search-deepseek", "dsh-tool-web"]
            for name in names where name != omitted {
                let packageDirectory = base.appendingPathComponent("node_modules/@deepseek-ai/\(name)", isDirectory: true)
                try? FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
                try? Data("{\"name\":\"@deepseek-ai/\(name)\"}".utf8).write(to: packageDirectory.appendingPathComponent("package.json"))
            }
            let entry = base.appendingPathComponent("packages/examples/acp-demo/lib/bin.js")
            try? FileManager.default.createDirectory(at: entry.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data("#!/usr/bin/env node\n".utf8).write(to: entry)
            return entry
        }
        let installBase = dshWork.appendingPathComponent("fake-install-\(UUID())", isDirectory: true)
        let fakeEntry = buildFakeInstall(in: installBase)
        let linkedSandbox = try ResidentDSHComposition.makeResidentSandbox(resolvingFrom: fakeEntry)
        defer { linkedSandbox.removeAll() }
        for name in ["dsh-llm-deepseek", "dsh-credentials-local", "dsh-attachment-local", "dsh-acp-demo",
                     "dsh-web", "dsh-web-fetch-http", "dsh-web-search-deepseek", "dsh-tool-web"] {
            let link = linkedSandbox.root.appendingPathComponent("node_modules/@deepseek-ai/\(name)")
            check(FileManager.default.fileExists(atPath: link.resolvingSymlinksInPath().appendingPathComponent("package.json").path),
                  "sandbox resolves @deepseek-ai/\(name) to the existing installation")
        }
        check(FileManager.default.fileExists(atPath: installBase.appendingPathComponent("node_modules/@deepseek-ai/dsh-acp-demo/package.json").path),
              "the anchor installation is read through links, never modified")

        let incompleteInstall = dshWork.appendingPathComponent("fake-install-partial-\(UUID())", isDirectory: true)
        let incompleteEntry = buildFakeInstall(in: incompleteInstall, omitting: "dsh-credentials-local")
        do {
            let broken = try ResidentDSHComposition.makeResidentSandbox(resolvingFrom: incompleteEntry)
            broken.removeAll()
            check(false, "an installation missing a mounted plugin fails closed")
        } catch {
            check(true, "an installation missing a mounted plugin fails closed")
        }
        check(ResidentDSHComposition.locateInstalledPackage(
            "@deepseek-ai/dsh-credentials-local", from: URL(fileURLWithPath: "/bin.js")) == nil,
              "root-directory missing package search terminates")

        let scrubbed = ResidentDSHTransport.residentEnvironment(base: [
            "DEEPSEEK_API_KEY": "sk-secret", "DSH_SNAPSHOT": "replay", "DSH_HOME": "/elsewhere",
            "HOME": "/Users/fixture", "PATH": "/custom/bin", "LANG": "en_US.UTF-8",
        ])
        check(scrubbed["DEEPSEEK_API_KEY"] == nil && scrubbed["DSH_SNAPSHOT"] == nil && scrubbed["DSH_HOME"] == nil,
              "credentials and snapshot overrides never reach the ACP entry environment")
        check(scrubbed["HOME"] == "/Users/fixture", "HOME is preserved so the managed credential document resolves")
        check(scrubbed["PATH"]?.contains("/usr/bin") == true, "PATH carries the standard directories")
        check(!ResidentDSHComposition.isNativeImageTransportAvailable(using: Locator(), environment: [:]),
              "a fixture environment has no native DSH image transport")

        func dshDefaults() -> UserDefaults {
            let suite = "gmgn-image-dsh-\(UUID())"
            let value = UserDefaults(suiteName: suite)!
            value.removePersistentDomain(forName: suite)
            value.set(AgentConversationBackendID.dsh.rawValue, forKey: AgentConversationPreferenceKeys.selectedBackend)
            return value
        }

        let imageConnector = RecordingDSHConnector(replies: [.success("看到了红色杯子"), .success("无关回复"), .success("新空间")])
        let dshService = AgentConversationService(locator: Locator(), defaults: dshDefaults(), residentDSHImageConnector: imageConnector)
        dshService.selectBackend(.dsh)
        var dshDraftAccepted = false
        do { try dshService.validateImageSupport(imageURLs: [pngA]); dshDraftAccepted = true } catch {}
        check(dshDraftAccepted, "DSH with an injected native connector accepts image drafts")
        dshService.selectBackend(.claudeCode)
        do { try dshService.validateImageSupport(imageURLs: [pngA]); check(false, "other backends stay rejected with a connector present") }
        catch AgentConversationError.imagesUnsupported(let rejected) { check(rejected == .claudeCode, "other backends still name the provider") }
        dshService.selectBackend(.dsh)
        check(try await dshService.send("", imageURLs: [pngA, pngB]) == "看到了红色杯子", "DSH native transport answers a pure-image request")
        let imageRecords = imageConnector.prompts
        check(imageRecords.count == 1, "one native prompt carries the whole image turn")
        check(imageRecords[0].blocks == [
            .image(.init(data: pngBytes, mimeType: "image/png")),
            .image(.init(data: pngBytes, mimeType: "image/png")),
        ], "images travel as real native content blocks with their original bytes and MIME")
        check(imageRecords[0].sessionID == "dsh-native-1", "the native turn runs inside an opened ACP session")
        check(!imageConnector.closed, "the connector stays open so later turns keep the same session")

        let textOnlyConnector = RecordingDSHConnector(handshakeImage: false, replies: [.success("好的")])
        let dshTextOnly = AgentConversationService(locator: Locator(), defaults: dshDefaults(), residentDSHImageConnector: textOnlyConnector)
        dshTextOnly.selectBackend(.dsh)
        var textOnlyDraftAccepted = false
        do { try dshTextOnly.validateImageSupport(imageURLs: [pngA]); textOnlyDraftAccepted = true } catch {}
        check(textOnlyDraftAccepted, "draft validation only requires an available native transport; the handshake gate stays at send time")
        do { _ = try await dshTextOnly.send("看这张图", imageURLs: [pngA]); check(false, "a missing handshake image capability must fail loudly") }
        catch AgentConversationError.dshImageCapabilityUnavailable { check(true, "missing handshake image capability is reported, not silently dropped") }
        check(textOnlyConnector.prompts.isEmpty, "a connection without image capability never serializes image bytes")
        check(!textOnlyConnector.closed, "the text-capable session stays open after an image refusal")
        check(try await dshTextOnly.send("纯文字聊天") == "好的", "the same connection still carries plain text after an image refusal")
        let textOnlyRecords = textOnlyConnector.prompts
        check(textOnlyRecords.count == 1 && textOnlyRecords[0].sessionID == "dsh-native-1", "plain text reuses the already opened session")

        let tiff = dshWork.appendingPathComponent("resident-x.tiff")
        try pngBytes.write(to: tiff)
        do { _ = try await dshService.send("", imageURLs: [tiff]); check(false, "unsupported raster formats must be refused") }
        catch AgentConversationError.imageFormatUnsupported { check(true, "unsupported raster format is refused, never re-encoded or silently dropped") }

        check(try await dshService.send("图里还有什么？") == "无关回复", "a text-only follow-up returns to the same native image session")
        let followRecords = imageConnector.prompts
        check(followRecords.count == 2 && followRecords[1].sessionID == followRecords[0].sessionID,
              "a turn without new images keeps the same image session")
        check(!followRecords[1].blocks.contains(where: { if case .image = $0 { return true }; return false }),
              "the follow-up sends text only and no new image bytes")
        if case let .text(followText)? = followRecords[1].blocks.last {
            check(!followText.contains("看到了红色杯子") && followText.contains("图里还有什么？"),
                  "a reused native session receives only the new user message, not its retained history")
        } else { check(false, "the follow-up prompt carries text") }
        check(!imageConnector.closed, "the image session stays open across turns")

        let worldB = ResidentWorldContext(selectedWorldID: "studio", worldID: "studio", displayName: nil, revision: 1,
            residentPosition: nil, activeActivity: nil, activityPhase: nil, objects: [], availableActivities: [])
        check(try await dshService.send("去那边看看", worldContext: worldB, worldTools: nil) == "新空间",
              "a different world opens its own session lineage")
        check(imageConnector.closed, "the previous world's image session was closed when the world changed")
        let worldRecords = imageConnector.prompts
        check(worldRecords.count == 3 && worldRecords[2].sessionID == "dsh-native-2",
              "the new world starts a fresh native session")

        var loopHandled: [String] = []
        // Declare the canonical names that each native fixture actually calls.
        func nativeSchemas(_ names: [String]) -> Data {
            let schemas: [[String: Any]] = names.map { name in
                let properties: [String: Any] = name == "update_resident_intent"
                    ? ["status": ["type": "string"]] : [:]
                return ["name": name, "description": "fixture \(name)",
                        "inputSchema": ["type": "object", "properties": properties,
                                        "additionalProperties": false]]
            }
            return try! JSONSerialization.data(withJSONObject: schemas, options: [.sortedKeys])
        }
        let loopSchemas = nativeSchemas(["list_places", "inspect_world"])
        let loopTools = ResidentConversationTools(worldID: "fixture", schemasJSON: loopSchemas, call: { id, name, _ in
            loopHandled.append(name)
            let object: [String: Any] = ["ok": true, "message": "完成 \(name)"]
            return ResidentCodexToolReply(resultJSON: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), isError: false)
        }, cancel: {})
        let loopConnector = RecordingDSHConnector(replies: [
            .success(#"{"type":"tool_call","call_id":"p1","name":"gmgn_list_places","arguments":{}}"#),
            .success(#"{"type":"final","text":"我看清图片里的摆件了，展示台就在旁边。"}"#),
            .success(#"{"type":"final","text":"还是同一个会话，图片我仍然记得。"}"#),
        ])
        let loopService = AgentConversationService(locator: Locator(), defaults: dshDefaults(), residentDSHImageConnector: loopConnector)
        loopService.selectBackend(.dsh)
        check(try await loopService.send("按图找位置", imageURLs: [pngA], worldContext: world, worldTools: loopTools).contains("看清图片"),
              "the native DSH loop completes an image request through host tools")
        check(loopHandled == ["list_places"], "the host tool executes exactly once inside the native loop")
        let loopRecords = loopConnector.prompts
        check(loopRecords.count == 2 && loopRecords[0].sessionID == loopRecords[1].sessionID,
              "tool and image turns stay inside one native session so the image context persists")
        check(loopRecords[0].blocks.contains { block in
            if case let .text(text) = block { return text.contains("空间动作必须使用下方正式工具") }
            return false
        } && loopRecords[0].blocks.contains(where: { if case .image = $0 { return true }; return false }),
              "the first native prompt carries the image together with the bounded host protocol")
        check(loopRecords[1].blocks.contains { block in
            if case let .text(text) = block { return text.contains("p1") && text.contains("完成 list_places") }
            return false
        }, "the trusted tool result is carried into the follow-up native prompt")
        if case let .text(toolDelta)? = loopRecords[1].blocks.last {
            check(!toolDelta.contains("current_request") && !toolDelta.contains("按图找位置")
                && !toolDelta.contains("\"tool_call\"") && !toolDelta.contains("\"tools\""),
                "native tool continuation does not replay user request, assistant call, or schema")
        } else { check(false, "native tool continuation carries a text delta") }
        check(!loopRecords[1].blocks.contains(where: { if case .image = $0 { return true }; return false }),
              "the follow-up prompt does not re-send image bytes; the session history holds them")
        check(try await loopService.send("图片还在吗", worldContext: world, worldTools: loopTools).contains("还是同一个会话"),
              "a no-new-image world turn continues the image session")
        let followLoopRecords = loopConnector.prompts
        check(followLoopRecords.count == 3 && followLoopRecords.allSatisfy { $0.sessionID == followLoopRecords[0].sessionID },
              "successive world turns keep one native session identity")
        if case let .text(thirdPrompt)? = followLoopRecords[2].blocks.last {
            check(!thirdPrompt.contains("我看清图片里的摆件了") && thirdPrompt.contains("空间动作必须使用下方正式工具"),
                  "the next human turn refreshes tool authority without replaying native history")
        } else { check(false, "the third native prompt carries text") }

        let gateConnector = RecordingDSHConnector(replies: [.success("取消后仍在同一会话")], gate: true)
        let gateService = AgentConversationService(locator: Locator(), defaults: dshDefaults(), residentDSHImageConnector: gateConnector)
        gateService.selectBackend(.dsh)
        let gateTask = Task { try await gateService.send("图", imageURLs: [pngA]) }
        await waitFor({ gateConnector.prompts.count == 1 }, seconds: 5, "gated native prompt starts")
        gateService.cancel()
        do { _ = try await gateTask.value; check(false, "a late image reply must be discarded") }
        catch AgentConversationError.cancelled { check(true, "cancelled native image turn reports cancellation") }
        check(gateConnector.cancellations == 1, "cancellation reaches the native ACP session")
        check(gateConnector.prompts.count == 1, "a cancelled turn never sends a second prompt or a late image")
        check(!gateConnector.closed, "cancellation keeps the session alive for the next turn")
        check(try await gateService.send("还在吗") == "取消后仍在同一会话", "the next turn returns to the same cancelled image session")
        let gateRecords = gateConnector.prompts
        check(gateRecords.count == 2 && gateRecords[1].sessionID == gateRecords[0].sessionID,
              "the follow-up reuses the cancelled session identity")

        let bootstrapConnector = RecordingDSHConnector(replies: [.success("bootstrap reply"), .success("delta reply")])
        let bootstrapService = AgentConversationService(locator: Locator(), defaults: dshDefaults(), residentDSHImageConnector: bootstrapConnector)
        let migratedHistory = [AgentConversationMessage(role: .user, text: "before-native-question"),
                               AgentConversationMessage(role: .agent, text: "before-native-answer")]
        _ = try await bootstrapService.send("", imageURLs: [pngA], history: migratedHistory)
        _ = try await bootstrapService.send("new-native-question", history: migratedHistory)
        let bootstrapText = bootstrapConnector.prompts[0].blocks.compactMap { block -> String? in
            if case let .text(text) = block { return text }; return nil
        }.joined()
        let deltaText = bootstrapConnector.prompts[1].blocks.compactMap { block -> String? in
            if case let .text(text) = block { return text }; return nil
        }.joined()
        check(bootstrapText.contains("before-native-answer"), "first image-only native prompt bootstraps pre-native conversation history")
        check(!deltaText.contains("before-native") && deltaText.contains("new-native-question"),
              "native bootstrap history is not replayed when a caller supplies it again")

        let correctionConnector = RecordingDSHConnector(replies: [
            .success(#"{"type":"tool_call","call_id":"delta-1","name":"gmgn_inspect_world","arguments":{}}"#),
            .success(#"{"type":"tool_call","call_id":"delta-2","name":"gmgn_list_places","arguments":{}}"#),
            .success("bad format"),
            .success(#"{"type":"tool_call","call_id":"delta-3","name":"gmgn_inspect_world","arguments":{}}"#),
            .success(#"{"type":"final","text":"工具链完成"}"#),
        ])
        let correctionService = AgentConversationService(locator: Locator(), defaults: dshDefaults(), residentDSHImageConnector: correctionConnector)
        check(try await correctionService.send("unique-native-request", imageURLs: [pngA], worldContext: world, worldTools: loopTools) == "工具链完成",
              "several native tool deltas and one correction retain a final answer")
        let deltaPrompts = correctionConnector.prompts.map { record in
            record.blocks.compactMap { block -> String? in if case let .text(text) = block { return text }; return nil }.joined()
        }
        check(deltaPrompts.dropFirst().allSatisfy { !$0.contains("unique-native-request") }, "native multi-tool turn sends its user request once")
        check(deltaPrompts[2].contains("delta-2") && !deltaPrompts[2].contains("delta-1"), "each native result delta excludes older tools")
        check(deltaPrompts[3].contains("上一次输出格式无效") && !deltaPrompts[3].contains("delta-2"), "format correction does not replay an already admitted tool result")
        check(deltaPrompts[4].contains("delta-3") && !deltaPrompts[4].contains("delta-1") && !deltaPrompts[4].contains("delta-2"),
              "tool delta after correction includes only the newly executed result")
        check(correctionConnector.prompts.flatMap(\.blocks).filter { if case .image = $0 { return true }; return false }.count == 1,
              "image data stays in the session and is never replayed during native tool corrections")

        let delayedBoot = DelayedBootConnector()
        let delayedBootService = AgentConversationService(locator: Locator(), defaults: dshDefaults(), residentDSHImageConnector: delayedBoot)
        let abandonedBoot = Task { try await delayedBootService.send("must-not-send") }
        await waitFor({ delayedBoot.opens == 1 }, seconds: 5, "cancel test reached delayed native handshake")
        delayedBootService.cancel()
        delayedBoot.releaseBoot()
        do { _ = try await abandonedBoot.value; check(false, "cancelled handshake must not yield a reply") }
        catch AgentConversationError.cancelled {}
        // Let the deliberately noncooperative boot return to the real service.
        await waitFor({ delayedBoot.closes == 1 }, seconds: 5, "cancelled late handshake is retired")
        check(delayedBoot.prompts.isEmpty && delayedBoot.closes == 1, "a cancelled late handshake closes without ever sending the abandoned prompt")
        check(try await delayedBootService.send("fresh request") == "fresh reply" && delayedBoot.opens == 2,
              "a late cancelled handshake cannot populate the cache used by the next request")

        let emptyNative = RecordingDSHConnector(replies: [.success(" \n\t")])
        let emptyNativeService = AgentConversationService(locator: Locator(), defaults: dshDefaults(), residentDSHImageConnector: emptyNative)
        var emptyRejected = false
        do { _ = try await emptyNativeService.send("need a reply") }
        catch AgentConversationError.emptyReply { emptyRejected = true }
        check(emptyRejected, "native plain chat rejects an empty final reply consistently with headless")

        for permitSilence in [true, false] {
            for finalText in ["", " \n\t"] {
                var silentAllowed = false
                var intentUpdates = 0
                let silentTools = ResidentConversationTools(worldID: "fixture", schemasJSON: nativeSchemas(["update_resident_intent"]),
                    call: { _, name, _ in
                        if name == "update_resident_intent" {
                            intentUpdates += 1
                            silentAllowed = permitSilence
                        }
                        return ResidentCodexToolReply(resultJSON: Data(#"{"ok":true,"status":"waiting_event"}"#.utf8), isError: false)
                    }, cancel: {}, allowsSilentCompletion: { silentAllowed })
                let finalData = try JSONSerialization.data(withJSONObject: ["type": "final", "text": finalText])
                let silentConnector = RecordingDSHConnector(replies: [
                    .success(#"{"type":"tool_call","call_id":"intent-1","name":"gmgn_update_resident_intent","arguments":{"status":"waiting_event"}}"#),
                    .success(String(decoding: finalData, as: UTF8.self)),
                    .success(#"{"type":"final","text":"unexpected acknowledgement"}"#),
                ])
                let silentService = AgentConversationService(locator: Locator(), defaults: dshDefaults(),
                    residentDSHImageConnector: silentConnector)
                var reply: String?
                var emptyRejected = false
                do { reply = try await silentService.send("记录等待事件", worldContext: world, worldTools: silentTools) }
                catch AgentConversationError.emptyReply { emptyRejected = true }
                catch {}
                check(intentUpdates == 1, "native silent permission is established by the intent tool during this turn")
                check(permitSilence ? reply == "" : (reply == nil && emptyRejected),
                    "native empty final obeys live silent permission=\(permitSilence), whitespace=\(!finalText.isEmpty)")
                check(silentConnector.prompts.count == 2, "native empty final does not trigger correction or synthetic acknowledgement")
            }
        }
        for invalidFinal in [#"{"type":"final"}"#, #"{"type":"final","text":null}"#, #"{"type":"final","text":0}"#] {
            let invalidConnector = RecordingDSHConnector(replies: [.success(invalidFinal), .success(invalidFinal)])
            let invalidService = AgentConversationService(locator: Locator(), defaults: dshDefaults(), residentDSHImageConnector: invalidConnector)
            let invalidTools = ResidentConversationTools(worldID: "fixture", schemasJSON: Data("[]".utf8),
                call: loopTools.call, cancel: {}, allowsSilentCompletion: { true })
            var rejected = false
            do { _ = try await invalidService.send("等待", worldContext: world, worldTools: invalidTools) }
            catch AgentConversationError.invalidDSHToolProtocol { rejected = true }
            check(rejected && invalidConnector.prompts.count == 2, "native silent permission does not accept missing or non-string final text")
        }

        let recoverableConnector = RecordingDSHConnector(replies: [
            .failure(AgentConversationError.dshNativeTurnFailed(.network)), .success("new response"),
        ])
        let recoverableService = AgentConversationService(locator: Locator(), defaults: dshDefaults(), residentDSHImageConnector: recoverableConnector)
        do { _ = try await recoverableService.send("possibly-admitted-request", history: migratedHistory); check(false, "provider failure is reported") }
        catch AgentConversationError.dshNativeTurnFailed {}
        check(try await recoverableService.send("new request after failure", history: migratedHistory) == "new response",
              "a recoverable native provider failure allows a new user turn")
        let recoveryText = recoverableConnector.prompts[1].blocks.compactMap { block -> String? in
            if case let .text(text) = block { return text }; return nil
        }.joined()
        check(!recoveryText.contains("before-native") && !recoveryText.contains("possibly-admitted-request"),
              "an uncertain admission never triggers replay of bootstrap or the failed request")

        let retiredConnector = RecordingDSHConnector(replies: [
            .success("first answer"), .failure(ResidentDSHTransportError.connectionClosed), .success("new session answer"),
        ])
        let retiredService = AgentConversationService(locator: Locator(), defaults: dshDefaults(), residentDSHImageConnector: retiredConnector)
        _ = try await retiredService.send("first request", history: migratedHistory)
        do { _ = try await retiredService.send("connection will close"); check(false, "terminal native failure is reported") }
        catch ResidentDSHTransportError.connectionClosed {}
        check(try await retiredService.send("new request after reconnect", history: migratedHistory) == "new session answer",
              "terminal native failure rebuilds the session")
        let rebuiltText = retiredConnector.prompts[2].blocks.compactMap { block -> String? in
            if case let .text(text) = block { return text }; return nil
        }.joined()
        check(retiredConnector.prompts[2].sessionID != retiredConnector.prompts[0].sessionID
              && rebuiltText.contains("before-native-answer") && !rebuiltText.contains("connection will close"),
              "only a fresh native session receives a new history bootstrap, without retrying failed input")

        let malformedNative = RecordingDSHConnector(replies: [.success("bad-one"), .success("bad-two")])
        let malformedNativeService = AgentConversationService(locator: Locator(), defaults: dshDefaults(), residentDSHImageConnector: malformedNative)
        var twiceMalformedRejected = false
        do { _ = try await malformedNativeService.send("one correction only", worldContext: world, worldTools: loopTools) }
        catch AgentConversationError.invalidDSHToolProtocol { twiceMalformedRejected = true }
        check(twiceMalformedRejected && malformedNative.prompts.count == 2, "native incremental protocol still permits exactly one format correction")

        // ── Reasoning-only DSH turns carry no visible text (content 空). An
        // empty turn is not a broken envelope: recovering it must never spend
        // the round's single format correction, replay an executed tool, or
        // fabricate success. RED under the one-correction-only loop, GREEN
        // under the bounded empty-turn recovery. ──
        var reasoningCalls: [String] = []
        let reasoningTools = ResidentConversationTools(worldID: "fixture", schemasJSON: nativeSchemas(["update_resident_intent", "list_places", "inspect_world"]), call: { id, name, _ in
            reasoningCalls.append(name)
            let object: [String: Any] = ["ok": true, "message": "完成 \(name)"]
            return ResidentCodexToolReply(resultJSON: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), isError: false)
        }, cancel: {})
        func joinedNativeText(_ records: [RecordingDSHConnector.PromptRecord]) -> [String] {
            records.map { record in
                record.blocks.compactMap { block -> String? in if case let .text(text) = block { return text }; return nil }.joined()
            }
        }
        func nativeImageCount(_ records: [RecordingDSHConnector.PromptRecord]) -> Int {
            records.flatMap(\.blocks).filter { if case .image = $0 { return true }; return false }.count
        }

        // 1) The real production round: legal tool → 空 → legal tool → 空 →
        //    recovery → legal final. Each tool executes exactly once, no tool
        //    result or image is replayed, and no format correction is spent.
        let productionRoundConnector = RecordingDSHConnector(replies: [
            .success(#"{"type":"tool_call","call_id":"intent-9","name":"gmgn_update_resident_intent","arguments":{"status":"continue"}}"#),
            .success(""),
            .success(#"{"type":"tool_call","call_id":"places-9","name":"gmgn_list_places","arguments":{}}"#),
            .success(" \n\t"),
            .success(#"{"type":"final","text":"意图与地点都已就绪。"}"#),
        ])
        let productionRoundService = AgentConversationService(locator: Locator(), defaults: dshDefaults(), residentDSHImageConnector: productionRoundConnector)
        productionRoundService.selectBackend(.dsh)
        var productionReply: String?
        var productionError = ""
        do { productionReply = try await productionRoundService.send("继续空间流程", imageURLs: [pngA], worldContext: world, worldTools: reasoningTools) }
        catch { productionError = String(describing: error) }
        check(productionReply == "意图与地点都已就绪。",
              "a reasoning-only DSH turn inside a world round recovers to the legal final (error=\(productionError))")
        check(reasoningCalls == ["update_resident_intent", "list_places"],
              "tools execute exactly once across empty turns and the recovery (calls=\(reasoningCalls))")
        let productionPrompts = joinedNativeText(productionRoundConnector.prompts)
        check(productionRoundConnector.prompts.count == 5,
              "two reasoning-only turns add two bounded nudges and no extra tool round (prompts=\(productionRoundConnector.prompts.count))")
        check(productionPrompts[2].contains("没有可见回复") && productionPrompts[4].contains("没有可见回复"),
              "an empty DSH turn is recovered by an explicit continuation nudge")
        check(productionPrompts.allSatisfy { !$0.contains("上一次输出格式无效") },
              "a reasoning-only turn never spends the round's single format correction")
        check(!productionPrompts[2].contains("intent-9") && !productionPrompts[2].contains("完成 update_resident_intent")
              && !productionPrompts[4].contains("places-9") && !productionPrompts[4].contains("完成 list_places"),
              "empty-turn nudges replay no admitted tool result and fabricate no success")
        check(!productionPrompts[1].contains("places-9") && productionPrompts[3].contains("places-9") && !productionPrompts[3].contains("intent-9"),
              "each tool result delta after an empty turn still carries only the newest tool")
        check(nativeImageCount(productionRoundConnector.prompts) == 1,
              "image bytes stay in the first native prompt and are never replayed during empty recovery")
        check(!productionPrompts[2].contains("继续空间流程") && !productionPrompts[4].contains("继续空间流程"),
              "empty-turn recovery never retries the whole user request")

        // 2) Consecutive reasoning-only turns stop after the finite budget.
        let reasoningCallsAtStart = reasoningCalls.count
        let consecutiveVoidConnector = RecordingDSHConnector(replies: [.success(""), .success("  "), .success("")])
        let consecutiveVoidService = AgentConversationService(locator: Locator(), defaults: dshDefaults(), residentDSHImageConnector: consecutiveVoidConnector)
        consecutiveVoidService.selectBackend(.dsh)
        var consecutiveVoidRejected = false
        do { _ = try await consecutiveVoidService.send("只思考不回复", worldContext: world, worldTools: reasoningTools) }
        catch AgentConversationError.invalidDSHToolProtocol { consecutiveVoidRejected = true }
        check(consecutiveVoidRejected && consecutiveVoidConnector.prompts.count == 3,
              "consecutive empty DSH turns terminate after the bounded recovery budget (prompts=\(consecutiveVoidConnector.prompts.count))")
        check(reasoningCalls.count == reasoningCallsAtStart, "bounded empty-turn termination executes no tool")

        // 3) Persistent tool → empty alternation is still capped for the whole
        //    round, not reset per streak, and every executed tool runs once.
        let alternationConnector = RecordingDSHConnector(replies: [
            .success(#"{"type":"tool_call","call_id":"a-1","name":"gmgn_inspect_world","arguments":{}}"#), .success(""),
            .success(#"{"type":"tool_call","call_id":"a-2","name":"gmgn_list_places","arguments":{}}"#), .success(""),
            .success(#"{"type":"tool_call","call_id":"a-3","name":"gmgn_list_places","arguments":{}}"#), .success(""),
        ])
        let alternationService = AgentConversationService(locator: Locator(), defaults: dshDefaults(), residentDSHImageConnector: alternationConnector)
        alternationService.selectBackend(.dsh)
        var alternationRejected = false
        do { _ = try await alternationService.send("持续交替", worldContext: world, worldTools: reasoningTools) }
        catch AgentConversationError.invalidDSHToolProtocol { alternationRejected = true }
        check(alternationRejected && alternationConnector.prompts.count == 6,
              "tool/empty alternation is capped for the whole round, not per streak (prompts=\(alternationConnector.prompts.count))")
        check(reasoningCalls == ["update_resident_intent", "list_places", "inspect_world", "list_places", "list_places"],
              "alternation tools each execute exactly once before the whole-round cap (calls=\(reasoningCalls))")

        // 4) A void turn must not consume the single format correction, and the
        //    strict tool_call schema still fails closed afterwards.
        let strictAfterVoidConnector = RecordingDSHConnector(replies: [
            .success(""),
            .success(#"{"type":"tool_call","call_id":"bad-9","name":" ","arguments":{}}"#),
            .success(#"{"type":"tool_call","call_id":"bad-9","name":" ","arguments":{}}"#),
        ])
        let strictAfterVoidService = AgentConversationService(locator: Locator(), defaults: dshDefaults(), residentDSHImageConnector: strictAfterVoidConnector)
        strictAfterVoidService.selectBackend(.dsh)
        let reasoningCallsBeforeStrict = reasoningCalls.count
        var strictAfterVoidRejected = false
        do { _ = try await strictAfterVoidService.send("格式必须严格", worldContext: world, worldTools: reasoningTools) }
        catch AgentConversationError.invalidDSHToolProtocol { strictAfterVoidRejected = true }
        let strictAfterVoidTexts = joinedNativeText(strictAfterVoidConnector.prompts)
        check(strictAfterVoidRejected && strictAfterVoidConnector.prompts.count == 3 && strictAfterVoidTexts[1].contains("没有可见回复")
              && strictAfterVoidTexts[2].contains("上一次输出格式无效"),
              "an empty turn never spends the format correction, so a later invalid tool JSON still gets exactly one correction")
        check(reasoningCalls.count == reasoningCallsBeforeStrict, "invalid tool JSON after an empty turn is never executed or loosened")

        // Redacted reproduction of the real image turn: a plain description,
        // followed by final JSON whose text contains literal (unescaped) LF.
        let imageDescription = "图片已收到。\n参考物品放在桌面上。\n可见轮廓与材质细节。"
        let literalLineBreakFinal = "{\"type\":\"final\",\"text\":\"\(imageDescription)\"}"
        let multilineConnector = RecordingDSHConnector(replies: [
            .success(imageDescription), .success(literalLineBreakFinal),
        ])
        let multilineService = AgentConversationService(locator: Locator(), defaults: dshDefaults(), residentDSHImageConnector: multilineConnector)
        let handledBeforeMultiline = loopHandled.count
        var multilineReply: String?
        do { multilineReply = try await multilineService.send("只描述参考图片，不执行操作", imageURLs: [pngA], worldContext: world, worldTools: loopTools) }
        catch {}
        check(multilineReply == imageDescription, "a final-only literal-LF image description survives the existing format correction")
        check(multilineConnector.prompts.count == 2 && loopHandled.count == handledBeforeMultiline,
              "literal-LF final recovery adds no retry or tool execution")
        if case let .text(correction)? = multilineConnector.prompts[1].blocks.last {
            check(correction.contains("\\n") && correction.contains("\\r"), "native correction explicitly requires escaped line breaks")
        } else { check(false, "native correction text exists") }
        for (index, description) in ["图片已收到。\r第二行。", "图片已收到。\r\n第二行。", "图片已收到。\n有\"引号\"与\\路径。"].enumerated() {
            let encoded = try JSONSerialization.data(withJSONObject: ["type": "final", "text": description], options: [.sortedKeys])
            let raw = String(decoding: encoded, as: UTF8.self)
                .replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\r", with: "\r")
            let connector = RecordingDSHConnector(replies: [.success(raw)])
            let service = AgentConversationService(locator: Locator(), defaults: dshDefaults(), residentDSHImageConnector: connector)
            var actual: String?
            do { actual = try await service.send("describe", imageURLs: [pngA], worldContext: world, worldTools: loopTools) }
            catch {}
            check(actual == description,
                  "final-only normalization preserves CR, CRLF, quotes and backslashes with text before type, case \(index)")
            check(connector.prompts.count == 1, "valid normalized final needs no correction round")
        }
        let unsupportedLineBreakEnvelopes: [(String, String)] = [
            ("tool call", "{\"type\":\"tool_call\",\"call_id\":\"x\",\"name\":\"inspect_world\",\"arguments\":{\"note\":\"a\nb\"}}"),
            ("unknown key", "{\"type\":\"final\",\"text\":\"a\nb\",\"extra\":true}"),
            ("nested text", "{\"type\":\"final\",\"text\":{\"value\":\"a\nb\"}}"),
            ("duplicate type", "{\"type\":\"final\",\"type\":\"final\",\"text\":\"a\nb\"}"),
            ("duplicate text", "{\"type\":\"final\",\"text\":\"first\",\"text\":\"a\nb\"}"),
            ("tab control", "{\"type\":\"final\",\"text\":\"a\nb\tc\"}"),
            ("null control", "{\"type\":\"final\",\"text\":\"a\nb\u{0000}c\"}"),
            ("truncated", "{\"type\":\"final\",\"text\":\"a\nb"),
            ("invalid escape", "{\"type\":\"final\",\"text\":\"a\nb\\q\"}"),
            ("backslash then LF", "{\"type\":\"final\",\"text\":\"a\\\nb\"}"),
            ("numeric text", "{\"type\":\"final\",\"text\":1\n2}"),
        ]
        let handledBeforeInvalidFinals = loopHandled.count
        for (label, output) in unsupportedLineBreakEnvelopes {
            let connector = RecordingDSHConnector(replies: [.success(output), .success(output)])
            let service = AgentConversationService(locator: Locator(), defaults: dshDefaults(), residentDSHImageConnector: connector)
            var rejected = false
            do { _ = try await service.send("invalid final fixture", imageURLs: [pngA], worldContext: world, worldTools: loopTools) }
            catch AgentConversationError.invalidDSHToolProtocol { rejected = true }
            catch {}
            check(rejected && connector.prompts.count == 2, "literal-line-break fallback rejects \(label)")
        }
        check(loopHandled.count == handledBeforeInvalidFinals, "malformed tool calls are never repaired or executed")

        print("PASS: \(count) resident image routing checks")
    }
}
"""#
let main = work.appendingPathComponent("Main.swift")
try harness.write(to: main, atomically: true, encoding: .utf8)
let binary = work.appendingPathComponent("test")
let compile = Process(); compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
var compileArguments = ["-swift-version", "6", "-parse-as-library", "-j1"]
for agentName in ["CodexCLI", "AgentConversationService", "ResidentCodexTransport", "ResidentCodexPolicy", "ResidentCodexAgent", "ResidentSteeringDelivery", "ResidentDSHTransport", "ResidentDSHConfiguration", "ResidentStateClient", "ResidentMemoryClient", "ResidentConversationMemory", "ResidentDSHAgentToolBridge", "ResidentDSHHostToolsBridge", "ResidentClaudeToolBridge", "ResidentClaudeProcessRunner"] {
    compileArguments.append(root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Agent/\(agentName).swift").path)
}
compileArguments.append(contentsOf: [
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/ResidentVisionCapture.swift").path,
    main.path, "-o", binary.path,
])
compile.arguments = compileArguments
try compile.run(); compile.waitUntilExit()
guard compile.terminationStatus == 0 else { exit(compile.terminationStatus) }
let test = Process(); test.executableURL = binary
try test.run(); test.waitUntilExit(); exit(test.terminationStatus)

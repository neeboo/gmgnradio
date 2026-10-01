// Behavioral checks for the resident web-reference tools through the real
// ResidentWorldToolSession lease and the real WishMachineCoordinator journal,
// against a fake public API response and a fake local-acceptance daemon only.
import Foundation

// WorldRuntime 的模块搜索路径与目标文件**只有一处定义**：tools/world-runtime-harness-flags.sh。
// harness 一律调用它，绝不自己拼 `.build/...`（27 份各自拼写正是 SwiftPM 模块与 xcodebuild
// `Products/Debug` 旧模块两份并存的根因，后者报 `WorldQuaternion` 没有 `identity`）。
func worldRuntimeHarnessFlags() -> [String] {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [FileManager.default.currentDirectoryPath + "/tools/world-runtime-harness-flags.sh"]
    process.standardOutput = pipe
    try? process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(separator: "\n").map(String.init)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sources = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
let referenceSource = sources.appendingPathComponent("Agent/ResidentWishReferenceTools.swift")
let sessionSource = sources.appendingPathComponent("Agent/ResidentWorldToolSession.swift")
let coordinatorSource = sources.appendingPathComponent("Presence/WishMachineCoordinator.swift")
guard FileManager.default.fileExists(atPath: referenceSource.path) else {
    print("FAIL: resident wish reference tools are not implemented")
    exit(1)
}
guard try String(contentsOf: sessionSource, encoding: .utf8).contains("struct AdditionalTool") else {
    print("FAIL: real resident world tool session is missing"); exit(1)
}
guard try String(contentsOf: coordinatorSource, encoding: .utf8).contains("func registerWebReference(") else {
    print("FAIL: coordinator has no host-only web-reference registration"); exit(1)
}
guard try String(contentsOf: coordinatorSource, encoding: .utf8).contains("webReferences") else {
    print("FAIL: coordinator does not persist web-reference provenance"); exit(1)
}

let harness = #"""
import Foundation

// ── Minimal WorldAgent surface required to compile the real tool session. ──
struct RealtimeDJToolResult: Sendable { let callID: String; let resultJSON: Data; let isError: Bool }
struct RealtimeDJToolCall: Sendable { let id: String; let name: String; let argumentsJSON: Data }

enum WorldAgentToolContract {
    struct Parameter { let type: String }
    struct Capability { let name: String; let parameters: [String: Parameter]; let requiredParameters: [String] }
    static let capabilities: [Capability] = []
}

struct WorldAgentContext: Sendable {
    struct Snapshot: Sendable { let worldID: String }
    struct Activity: Sendable { let id: String }
    struct Manifest: Sendable { let activities: [Activity] }
    let snapshot: Snapshot
    let manifest: Manifest
}

@MainActor
final class WorldAgentToolDispatcher {
    let providerTools: [[String: Any]] = []
    let context: WorldAgentContext
    init(context: WorldAgentContext) { self.context = context }
    func handle(_ call: RealtimeDJToolCall) async -> RealtimeDJToolResult {
        RealtimeDJToolResult(callID: call.id, resultJSON: Data("{\"ok\":false,\"code\":\"unused\"}".utf8), isError: true)
    }
}

// The downloader lives in a parallel change; this offline stub matches its fixed
// public API so the tool's default wiring type-checks without network.
struct ResidentWebImageResponse: Sendable {
    let data: Data
    let mimeType: String
    let finalURL: URL
}
struct ResidentWebImageDownloader: Sendable {
    func download(_ url: URL) async throws -> Data { throw URLError(.unsupportedURL) }
    func fetchPublicData(_ url: URL, maximumBytes: Int) async throws -> ResidentWebImageResponse {
        throw URLError(.unsupportedURL)
    }
}

struct ResidentImageAttachment: Identifiable, Codable, Sendable, Equatable {
    let id: UUID; let url: URL; let displayName: String
}

// Fake local daemon: every provider call is answered by the caller's URLProtocol.
final class HTTP: URLProtocol {
    nonisolated(unsafe) static var state = "queued"
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let value: [String: Any] = ["id": String(repeating: "a", count: 32), "state": Self.state,
            "name": "reference", "source": ["author": "web", "license": "unverified"], "height_meters": 0.5,
            "compute_may_continue": false, "created_at": 1, "updated_at": 2]
        let body = try! JSONSerialization.data(withJSONObject: value)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor var failures = 0
@MainActor var checks = 0
@MainActor func check(_ value: Bool, _ message: String) {
    checks += 1
    if !value { failures += 1; print("FAIL: \(message)") }
}

// Main-actor recorder shared with @Sendable transport closures.
@MainActor final class Recorder {
    var leaseCurrent = true
    var searchRequests: [URL] = []
    var downloadRequests: [URL] = []
    var concurrentDownloads = 0
    func recordSearch(_ url: URL) { searchRequests.append(url) }
    func recordDownload(_ url: URL) { downloadRequests.append(url) }
    func disableLease() { leaseCurrent = false }
    func noteConcurrentDownload() { concurrentDownloads += 1 }
}

// Counts download attempts across @Sendable closures; the first attempt is cancelled.
@MainActor final class AttemptCounter {
    private(set) var count = 0
    func increment() -> Int { count += 1; return count }
}

// A FileManager that fails exactly at the post-write chmod so the tool's cleanup
// path is exercised without touching the real filesystem permissions.
final class FailingChmodFileManager: FileManager, @unchecked Sendable {
    override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        if path.hasSuffix(".png") { throw CocoaError(.fileWriteNoPermission) }
        try super.setAttributes(attributes, ofItemAtPath: path)
    }
}

@main struct WishReferenceChecks {
    @MainActor static func main() async throws {
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wish-ref-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let referenceDirectory = dir.appendingPathComponent("references")
        try FileManager.default.createDirectory(at: referenceDirectory, withIntermediateDirectories: true)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTP.self]
        let session = URLSession(configuration: config)
        let store = fixtureWishStore(directory: dir.appendingPathComponent("core"), session: session)
        try store.configure(endpoint: URL(string: "http://127.0.0.1:8191")!, token: "fixture")
        let world = "wish-world", resident = "resident.scope"
        let coordinator = WishMachineCoordinator(store: store,
            directory: dir.appendingPathComponent("wishes"), canClaim: { _ in nil })

        let runID = UUID()
        let leaseCurrent = true
        let recorder = Recorder()

        let searchJSON: [String: Any] = ["batchcomplete": "", "query": ["pages": [
            "7": ["pageid": 7, "ns": 6, "title": "File:Red wooden chair.jpg",
                  "imageinfo": [["url": "https://upload.invalid/original/red-chair.png",
                                 "thumburl": "https://upload.invalid/thumb/red-chair.png",
                                 "descriptionurl": "https://commons.invalid/wiki/File:Red_wooden_chair.jpg"]]],
            "8": ["pageid": 8, "ns": 6, "title": "File:Broken metadata.jpg", "imageinfo": [["descriptionurl": "https://commons.invalid/wiki/File:Broken.jpg"]]],
        ]]]
        let searchData = try JSONSerialization.data(withJSONObject: searchJSON)
        let emptySearch = Data("{\"batchcomplete\":\"\"}".utf8)

        func makeTools(fetcher: ResidentWishReferenceTools.Fetcher) -> [ResidentWorldToolSession.AdditionalTool] {
            let reference = ResidentWishReferenceTools(coordinator: coordinator, authorizationID: runID,
                worldID: world, residentScope: resident, isCurrent: { leaseCurrent }, fetcher: fetcher,
                directory: referenceDirectory)
            let wish = ResidentWishMachineTools(coordinator: coordinator, worldID: world, residentScope: resident,
                authorizationID: runID, isCurrent: { leaseCurrent })
            return reference.tools + wish.tools
        }
        func liveFetcher(respondSearch: Data, mimeType: String = "application/json",
                         download: @escaping @Sendable (URL) async throws -> Data) -> ResidentWishReferenceTools.Fetcher {
            ResidentWishReferenceTools.Fetcher(
                fetchPublicData: { url, _ in
                    await recorder.recordSearch(url)
                    return .init(data: respondSearch, mimeType: mimeType)
                }, download: { url in
                    await recorder.recordDownload(url)
                    return try await download(url)
                })
        }
        let dispatcher = WorldAgentToolDispatcher(context: .init(snapshot: .init(worldID: world),
            manifest: .init(activities: [])))
        func makeSession(_ tools: [ResidentWorldToolSession.AdditionalTool], scope: UUID = UUID()) -> ResidentWorldToolSession {
            ResidentWorldToolSession(scopeID: scope, worldID: world, dispatcher: dispatcher,
                deadline: Date().addingTimeInterval(60), isCurrent: { leaseCurrent }, additionalTools: tools)
        }
        func parse(_ result: RealtimeDJToolResult) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: result.resultJSON)) as? [String: Any] ?? [:]
        }
        func call(_ session: ResidentWorldToolSession, _ id: String, _ name: String, _ args: [String: Any]) async -> RealtimeDJToolResult {
            await session.call(requestID: id, name: name,
                argumentsJSON: try! JSONSerialization.data(withJSONObject: args))
        }

        // ── Real session exposes the two new schemas with canonical names. ──
        let session0 = makeSession(makeTools(fetcher: liveFetcher(respondSearch: searchData, download: { _ in png })))
        let schemas = (try? JSONSerialization.jsonObject(with: session0.toolSchemasJSON)) as? [[String: Any]] ?? []
        let byName = Dictionary(uniqueKeysWithValues: schemas.compactMap { schema -> (String, [String: Any])? in
            (schema["name"] as? String).map { ($0, schema) } })
        check(byName["search_wish_reference_images"] != nil && byName["register_wish_reference_image"] != nil,
              "real session publishes the new reference tools")
        let searchSchema = byName["search_wish_reference_images"]?["inputSchema"] as? [String: Any] ?? [:]
        let registerSchema = byName["register_wish_reference_image"]?["inputSchema"] as? [String: Any] ?? [:]
        check(Set((searchSchema["properties"] as? [String: Any] ?? [:]).keys) == ["query"]
              && (searchSchema["required"] as? [String]) == ["query"], "search exposes only query")
        check(Set((registerSchema["properties"] as? [String: Any] ?? [:]).keys) == ["image_url", "display_name"],
              "register exposes only the public image URL and name")
        let registerDescription = byName["register_wish_reference_image"]?["description"] as? String ?? ""
        check(registerDescription.contains("generation_authorized=false") && registerDescription.contains("先调用本工具登记"),
              "register description tells the agent to establish image authorization by registering first")
        // The model can never choose authorization/world/path.
        let injected = await call(session0, "bad-args", "register_wish_reference_image",
            ["image_url": "https://upload.invalid/a.png", "display_name": "a", "authorization_id": runID.uuidString,
             "world_id": world, "path": "/tmp/x.png"])
        check(injected.isError && (parse(injected)["code"] as? String) == "invalid_arguments",
              "model-supplied authorization/world/path are rejected")

        // ── Search: real URL construction, structured results, honest empty result. ──
        let searched = await call(session0, "search-1", "search_wish_reference_images", ["query": "red wooden chair"])
        let searchPayload = parse(searched)
        check(!searched.isError && searchPayload["ok"] as? Bool == true, "search succeeds on a fake public response")
        let results = searchPayload["results"] as? [[String: Any]] ?? []
        check(results.count == 1, "only imageinfo-backed results are returned, never fabricated: \(results.count)")
        check(results.first?["image_url"] as? String == "https://upload.invalid/thumb/red-chair.png"
              && results.first?["source_page_url"] as? String == "https://commons.invalid/wiki/File:Red_wooden_chair.jpg"
              && results.first?["title"] as? String == "File:Red wooden chair.jpg",
              "search returns image_url, source_page_url and title")
        check(searchPayload["license_verified"] as? Bool == false || results.first?["license_verified"] as? Bool == false,
              "search states that licensing is not verified")
        let requestedURL = recorder.searchRequests.last!
        let components = URLComponents(url: requestedURL, resolvingAgainstBaseURL: false)!
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        check(components.host == "commons.wikimedia.org" && components.path == "/w/api.php"
              && query["action"] == "query" && query["generator"] == "search" && query["gsrnamespace"] == "6"
              && query["gsrlimit"] == "5" && query["prop"] == "imageinfo"
              && query["iiprop"] == "url|extmetadata" && query["iiurlwidth"] == "1024"
              && query["format"] == "json" && query["gsrsearch"] == "red wooden chair",
              "search uses the fixed Wikimedia Commons URLComponents query")

        // ── Register: real PNG, private 0700/0600 file, persisted provenance. ──
        let registerArgs: [String: Any] = ["image_url": "https://upload.invalid/thumb/red-chair.png",
            "display_name": "Red wooden chair"]
        let registered = await call(session0, "register-1", "register_wish_reference_image", registerArgs)
        let registerPayload = parse(registered)
        check(!registered.isError && (registerPayload["attachment_id"] as? String).flatMap(UUID.init(uuidString:)) != nil,
              "register downloads and returns an attachment id")
        let attachmentID = UUID(uuidString: registerPayload["attachment_id"] as! String)!
        check(registerPayload["source_image_url"] as? String == "https://upload.invalid/thumb/red-chair.png"
              && registerPayload["source_kind"] as? String == "public_web_reference"
              && registerPayload["license_verified"] as? Bool == false,
              "register displays web provenance and does not claim verified licensing")
        check(recorder.downloadRequests == [URL(string: "https://upload.invalid/thumb/red-chair.png")!],
              "register downloads the chosen public direct link once")
        let file = referenceDirectory.appendingPathComponent(attachmentID.uuidString + ".png")
        check(FileManager.default.fileExists(atPath: file.path) && (try? Data(contentsOf: file)) == png,
              "registered file is retained for the asynchronous wish")
        let directoryMode = (try! FileManager.default.attributesOfItem(atPath: referenceDirectory.path)[.posixPermissions] as! NSNumber).intValue
        let fileMode = (try! FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber).intValue
        check(directoryMode == 0o700 && fileMode == 0o600, "reference cache is private 0700 with 0600 files")
        check(store.jobs.isEmpty, "registration never submits a generation")
        // Registration is durable and survives restart, still scoped.
        let reloaded = WishMachineCoordinator(store: store, directory: dir.appendingPathComponent("wishes"), canClaim: { _ in nil })
        check(reloaded.attachmentChoices(authorizationID: runID, worldID: world, residentScope: resident).map(\.id) == [attachmentID],
              "registration survives restart in the original scope")
        check(reloaded.attachmentChoices(authorizationID: runID, worldID: world, residentScope: "other").isEmpty,
              "registration is invisible outside the original resident scope")

        // ── Same call id is idempotent; different args conflict; same URL dedups. ──
        let replay = await call(session0, "register-1", "register_wish_reference_image", registerArgs)
        check(parse(replay)["attachment_id"] as? String == attachmentID.uuidString
              && recorder.downloadRequests.count == 1, "same call id returns the same attachment without re-downloading")
        let conflict = await call(session0, "register-1", "register_wish_reference_image",
            ["image_url": "https://upload.invalid/other.png", "display_name": "other"])
        check(conflict.isError && (parse(conflict)["code"] as? String) == "call_id_conflict",
              "same call id with different arguments conflicts")
        let sameURL = await call(session0, "register-2", "register_wish_reference_image", registerArgs)
        check(parse(sameURL)["attachment_id"] as? String == attachmentID.uuidString
              && recorder.downloadRequests.count == 1, "same public URL dedups across call ids")

        // ── Read discovery finds the registered image and marks its source. ──
        let discovered = await call(session0, "read-1", "read_wish_generation", [:])
        let discovery = parse(discovered)
        let attachments = discovery["attachments"] as? [[String: Any]] ?? []
        check(discovery["generation_authorized"] as? Bool == true && attachments.count == 1
              && attachments.first?["attachment_id"] as? String == attachmentID.uuidString,
              "read_wish_generation discovers the registered reference image")
        check(attachments.first?["source_kind"] as? String == "public_web_reference"
              && (attachments.first?["source_image_url"] as? String)?.contains("red-chair.png") == true,
              "discovery keeps the web source beside the image, never as a user upload")

        // ── Submit uses the registered attachment through the real coordinator/daemon. ──
        let submitted = await call(session0, "submit-1", "submit_wish_generation",
            ["attachment_id": attachmentID.uuidString, "name": "red chair", "height_meters": 0.8])
        let submitPayload = parse(submitted)
        check(!submitted.isError && (submitPayload["wish_id"] as? String).flatMap(UUID.init(uuidString:)) != nil
              && submitPayload["accepted"] as? Bool == true,
              "submit_wish_generation accepts the registered reference through the real chain: \(submitPayload)")
        check(store.jobs.count == 1 && store.jobs.first?.source.author.contains("网页参考图") == true,
              "the daemon receives the web-reference provenance, not a user upload")

        // ── Consumed grant cannot grow; a second wish in the same run is refused. ──
        let otherPNG = liveFetcher(respondSearch: searchData, download: { _ in png })
        let session1 = makeSession(makeTools(fetcher: otherPNG))
        let expanded = await call(session1, "register-after-submit", "register_wish_reference_image",
            ["image_url": "https://upload.invalid/second.png", "display_name": "second"])
        check(expanded.isError && (parse(expanded)["code"] as? String) == "reference_authorization_consumed",
              "a consumed run grant cannot be extended by registering another image")

        // ── A fresh human run on a text-only turn can register then submit. ──
        let run2 = UUID()
        let secondCoordinatorDir = dir.appendingPathComponent("wishes-second")
        let secondCoordinator = WishMachineCoordinator(store: store, directory: secondCoordinatorDir, canClaim: { _ in nil })
        let reference2 = ResidentWishReferenceTools(coordinator: secondCoordinator, authorizationID: run2,
            worldID: world, residentScope: resident, isCurrent: { leaseCurrent },
            fetcher: liveFetcher(respondSearch: searchData, download: { _ in png }),
            directory: dir.appendingPathComponent("references-second"))
        let wish2 = ResidentWishMachineTools(coordinator: secondCoordinator, worldID: world, residentScope: resident,
            authorizationID: run2, isCurrent: { leaseCurrent })
        let session2 = makeSession(reference2.tools + wish2.tools, scope: run2)
        let before = await call(session2, "empty-read", "read_wish_generation", [:])
        check(parse(before)["generation_authorized"] as? Bool == false, "text-only turn starts without a generation grant")
        let registered2 = await call(session2, "register-text", "register_wish_reference_image",
            ["image_url": "https://upload.invalid/thumb/red-chair.png", "display_name": "chair"])
        check(!registered2.isError, "a text-only human turn may register a reference image")
        let read2 = await call(session2, "read-text", "read_wish_generation", [:])
        check(parse(read2)["generation_authorized"] as? Bool == true,
              "the run grant appears only after a reference image is registered")

        // ── Four images maximum; registration is not generation. ──
        let limitDir = dir.appendingPathComponent("references-limit")
        let limitRun = UUID()
        let limitCoordinator = WishMachineCoordinator(store: store, directory: dir.appendingPathComponent("wishes-limit"), canClaim: { _ in nil })
        let limitTools = ResidentWishReferenceTools(coordinator: limitCoordinator, authorizationID: limitRun,
            worldID: world, residentScope: resident, isCurrent: { leaseCurrent },
            fetcher: liveFetcher(respondSearch: searchData, download: { _ in png }), directory: limitDir)
        let limitSession = makeSession(limitTools.tools, scope: limitRun)
        var limitFailures = 0
        for index in 0..<5 {
            let result = await call(limitSession, "limit-\(index)", "register_wish_reference_image",
                ["image_url": "https://upload.invalid/limit-\(index).png", "display_name": "limit \(index)"])
            if index < 4 { check(!result.isError, "reference \(index) registers within the four-image budget") }
            else { if result.isError { limitFailures += 1 } }
        }
        check(limitFailures == 1 && limitCoordinator.attachmentChoices(authorizationID: limitRun, worldID: world,
              residentScope: resident).count == 4, "a fifth reference image is refused at the four-image limit")

        // ── Same attachment id with different bytes must validate before any mutation. ──
        let validateCoordinator = WishMachineCoordinator(store: store,
            directory: dir.appendingPathComponent("wishes-validate"), canClaim: { _ in nil })
        let validateRun = UUID()
        let originalAttachment = ResidentImageAttachment(id: UUID(), url: URL(fileURLWithPath: "/tmp/original.png"),
            displayName: "original")
        try validateCoordinator.authorize(attachments: [originalAttachment], worldID: world, residentScope: resident,
            authorizationID: validateRun, source: .init(author: "user", license: "unverified"))
        let changedAttachment = ResidentImageAttachment(id: originalAttachment.id,
            url: URL(fileURLWithPath: "/tmp/changed.png"), displayName: "changed")
        var validateConflicted = false
        do {
            _ = try validateCoordinator.registerWebReference(changedAttachment,
                imageURL: URL(string: "https://upload.invalid/changed.png")!, authorizationID: validateRun,
                worldID: world, residentScope: resident, source: ResidentWishReferenceTools.webSource)
        } catch WishMachineError.conflictingCall { validateConflicted = true } catch {}
        check(validateConflicted, "the same attachment id with different bytes is refused")
        check(validateCoordinator.attachmentChoices(authorizationID: validateRun, worldID: world,
              residentScope: resident).first?.displayName == "original",
              "a conflicting attachment id never replaces the registered attachment")
        check(validateCoordinator.webReference(attachmentID: originalAttachment.id) == nil,
              "a conflicting attachment id never records a web reference")

        // ── Same attachment id with a different source is a conflict and never overwrites. ──
        let sourceRun = UUID()
        let sourceAttachment = ResidentImageAttachment(id: UUID(), url: URL(fileURLWithPath: "/tmp/source.png"),
            displayName: "source")
        let firstReference = try validateCoordinator.registerWebReference(sourceAttachment,
            imageURL: URL(string: "https://upload.invalid/source.png")!, authorizationID: sourceRun,
            worldID: world, residentScope: resident, source: ResidentWishReferenceTools.webSource)
        var sourceConflicted = false
        do {
            _ = try validateCoordinator.registerWebReference(sourceAttachment,
                imageURL: URL(string: "https://upload.invalid/source.png")!, authorizationID: sourceRun,
                worldID: world, residentScope: resident,
                source: PropGenerationSource(author: "different", license: "different"))
        } catch WishMachineError.conflictingCall { sourceConflicted = true } catch {}
        check(sourceConflicted, "the same attachment id with a different source is refused")
        check(validateCoordinator.webReference(attachmentID: sourceAttachment.id) == firstReference
              && validateCoordinator.attachmentChoices(authorizationID: sourceRun, worldID: world,
                  residentScope: resident).count == 1,
              "a conflicting source never overwrites the recorded web reference")

        // ── A failed durable write rolls back the in-memory grant and keeps disk intact. ──
        let rollbackDir = dir.appendingPathComponent("wishes-rollback")
        let rollbackBackup = dir.appendingPathComponent("wishes-rollback-backup")
        let rollbackCoordinator = WishMachineCoordinator(store: store, directory: rollbackDir, canClaim: { _ in nil })
        let rollbackRun = UUID()
        let rollbackAttachment = ResidentImageAttachment(id: UUID(), url: URL(fileURLWithPath: "/tmp/rollback.png"),
            displayName: "rollback")
        _ = try rollbackCoordinator.registerWebReference(rollbackAttachment,
            imageURL: URL(string: "https://upload.invalid/rollback.png")!, authorizationID: rollbackRun,
            worldID: world, residentScope: resident, source: ResidentWishReferenceTools.webSource)
        let newAttachment = ResidentImageAttachment(id: UUID(), url: URL(fileURLWithPath: "/tmp/new.png"),
            displayName: "new")
        // Replace the archive directory with a plain file so the next persistence preparation fails.
        try FileManager.default.moveItem(at: rollbackDir, to: rollbackBackup)
        try Data("blocker".utf8).write(to: rollbackDir)
        var rollbackFailed = false
        do {
            _ = try rollbackCoordinator.registerWebReference(newAttachment,
                imageURL: URL(string: "https://upload.invalid/new.png")!, authorizationID: rollbackRun,
                worldID: world, residentScope: resident, source: ResidentWishReferenceTools.webSource)
        } catch WishMachineError.unavailable { rollbackFailed = true } catch {}
        check(rollbackFailed, "a failed durable write surfaces as an unavailable error")
        check(rollbackCoordinator.webReference(attachmentID: newAttachment.id) == nil,
              "a failed durable write never exposes the new web reference in memory")
        check(!rollbackCoordinator.attachmentChoices(authorizationID: rollbackRun, worldID: world,
              residentScope: resident).contains { $0.id == newAttachment.id },
              "a failed durable write never exposes the new attachment in memory")
        let rollbackReload = WishMachineCoordinator(store: store, directory: rollbackBackup, canClaim: { _ in nil })
        check(rollbackReload.attachmentChoices(authorizationID: rollbackRun, worldID: world,
              residentScope: resident).map(\.id) == [rollbackAttachment.id],
              "the original durable grant is untouched by a failed new registration")

        // ── Failed download / non-PNG / cancellation keep no file and no registration. ──
        let failDir = dir.appendingPathComponent("references-fail")
        try FileManager.default.createDirectory(at: failDir, withIntermediateDirectories: true)
        let failCoordinator = WishMachineCoordinator(store: store, directory: dir.appendingPathComponent("wishes-fail"), canClaim: { _ in nil })
        let failRun = UUID()
        let failTools = ResidentWishReferenceTools(coordinator: failCoordinator, authorizationID: failRun,
            worldID: world, residentScope: resident, isCurrent: { leaseCurrent },
            fetcher: liveFetcher(respondSearch: searchData, download: { _ in throw URLError(.timedOut) }), directory: failDir)
        let failSession = makeSession(failTools.tools, scope: failRun)
        let failed = await call(failSession, "fail-download", "register_wish_reference_image",
            ["image_url": "https://upload.invalid/fail.png", "display_name": "fail"])
        check(failed.isError && (try! FileManager.default.contentsOfDirectory(atPath: failDir.path)).isEmpty
              && failCoordinator.attachmentChoices(authorizationID: failRun, worldID: world, residentScope: resident).isEmpty,
              "a failed download registers nothing and leaves no temporary file")
        let badCoordinator = WishMachineCoordinator(store: store, directory: dir.appendingPathComponent("wishes-bad"), canClaim: { _ in nil })
        let badRun = UUID()
        let badTools = ResidentWishReferenceTools(coordinator: badCoordinator, authorizationID: badRun,
            worldID: world, residentScope: resident, isCurrent: { leaseCurrent },
            fetcher: liveFetcher(respondSearch: searchData, download: { _ in Data("not a png".utf8) }), directory: failDir)
        let badSession = makeSession(badTools.tools, scope: badRun)
        let bad = await call(badSession, "bad-png", "register_wish_reference_image",
            ["image_url": "https://upload.invalid/bad.png", "display_name": "bad"])
        check(bad.isError && (try! FileManager.default.contentsOfDirectory(atPath: failDir.path)).isEmpty,
              "non-PNG bytes register nothing and leave no temporary file")

        // ── A chmod failure after the bytes exist must still remove this call's own file. ──
        let chmodDir = dir.appendingPathComponent("references-chmod")
        try FileManager.default.createDirectory(at: chmodDir, withIntermediateDirectories: true)
        let chmodCoordinator = WishMachineCoordinator(store: store, directory: dir.appendingPathComponent("wishes-chmod"), canClaim: { _ in nil })
        let chmodRun = UUID()
        let chmodTools = ResidentWishReferenceTools(coordinator: chmodCoordinator, authorizationID: chmodRun,
            worldID: world, residentScope: resident, isCurrent: { true },
            fetcher: liveFetcher(respondSearch: searchData, download: { _ in png }),
            directory: chmodDir, fileManager: FailingChmodFileManager())
        let chmodSession = makeSession(chmodTools.tools, scope: chmodRun)
        let chmodResult = await call(chmodSession, "chmod-fail", "register_wish_reference_image",
            ["image_url": "https://upload.invalid/chmod.png", "display_name": "chmod"])
        check(chmodResult.isError && (try! FileManager.default.contentsOfDirectory(atPath: chmodDir.path)).isEmpty
              && chmodCoordinator.attachmentChoices(authorizationID: chmodRun, worldID: world, residentScope: resident).isEmpty,
              "a chmod failure after writing still removes this call's own file and registers nothing")

        // ── Scope switch during download must not register. ──
        let staleRecorder = Recorder()
        let staleDir = dir.appendingPathComponent("references-stale")
        try FileManager.default.createDirectory(at: staleDir, withIntermediateDirectories: true)
        let staleCoordinator = WishMachineCoordinator(store: store, directory: dir.appendingPathComponent("wishes-stale"), canClaim: { _ in nil })
        let staleRun = UUID()
        let staleTools = ResidentWishReferenceTools(coordinator: staleCoordinator, authorizationID: staleRun,
            worldID: world, residentScope: resident, isCurrent: { staleRecorder.leaseCurrent },
            fetcher: ResidentWishReferenceTools.Fetcher(
                fetchPublicData: { _, _ in .init(data: searchData, mimeType: "application/json") },
                download: { _ in await staleRecorder.disableLease(); return png }), directory: staleDir)
        let staleSession = makeSession(staleTools.tools, scope: staleRun)
        let staleResult = await call(staleSession, "stale-register", "register_wish_reference_image",
            ["image_url": "https://upload.invalid/stale.png", "display_name": "stale"])
        check(staleResult.isError && staleCoordinator.attachmentChoices(authorizationID: staleRun, worldID: world,
              residentScope: resident).isEmpty
              && (try! FileManager.default.contentsOfDirectory(atPath: staleDir.path)).isEmpty,
              "a scope switch during download registers nothing and cleans its own file")

        // ── Cancelling the caller must cancel the in-flight download: no registration,
        // no file, and a fresh call can retry the same URL. ──
        let cancelDir = dir.appendingPathComponent("references-cancel")
        try FileManager.default.createDirectory(at: cancelDir, withIntermediateDirectories: true)
        let cancelCoordinator = WishMachineCoordinator(store: store, directory: dir.appendingPathComponent("wishes-cancel"), canClaim: { _ in nil })
        let cancelRun = UUID()
        let cancelCounter = AttemptCounter()
        let cancelFetcher = ResidentWishReferenceTools.Fetcher(
            fetchPublicData: { _, _ in .init(data: searchData, mimeType: "application/json") },
            download: { _ in
                let attempt = await cancelCounter.increment()
                if attempt == 1 { try await Task.sleep(nanoseconds: 40_000_000) }
                return png
            })
        let cancelTools = ResidentWishReferenceTools(coordinator: cancelCoordinator, authorizationID: cancelRun,
            worldID: world, residentScope: resident, isCurrent: { true }, fetcher: cancelFetcher, directory: cancelDir)
        let cancelTool = cancelTools.tools.first { $0.name == "register_wish_reference_image" }!
        let cancelArgs = try JSONSerialization.data(withJSONObject: ["image_url": "https://upload.invalid/cancel.png",
            "display_name": "cancel"])
        let running = Task { await cancelTool.handle("cancel-a", cancelArgs) }
        for _ in 0..<100_000 { if cancelCounter.count >= 1 { break }; await Task.yield() }
        running.cancel()
        let cancelledResult = await running.value
        check(cancelledResult.isError, "cancelling the caller fails the in-flight registration")
        check((try! FileManager.default.contentsOfDirectory(atPath: cancelDir.path)).isEmpty,
              "a cancelled download leaves no reference file")
        check(cancelCoordinator.attachmentChoices(authorizationID: cancelRun, worldID: world, residentScope: resident).isEmpty,
              "a cancelled download registers nothing")
        let cancelledRetry = await cancelTool.handle("cancel-b", cancelArgs)
        check(!cancelledRetry.isError, "a new registration call can retry the same URL after cancellation")

        // ── No results is an honest empty list, not a fabricated image. ──
        let emptyFetcher = ResidentWishReferenceTools.Fetcher(
            fetchPublicData: { _, _ in .init(data: emptySearch, mimeType: "application/json") }, download: { _ in png })
        let emptyTools = ResidentWishReferenceTools(coordinator: coordinator, authorizationID: UUID(),
            worldID: world, residentScope: resident, isCurrent: { true }, fetcher: emptyFetcher,
            directory: dir.appendingPathComponent("references-empty"))
        let emptySession = makeSession(emptyTools.tools)
        let empty = await call(emptySession, "search-empty", "search_wish_reference_images", ["query": "nonexistent thing"])
        let emptyPayload = parse(empty)
        check(!empty.isError && (emptyPayload["results"] as? [[String: Any]])?.isEmpty == true,
              "no search result is reported as an empty list")
        // A search transport failure is an explicit error, never fabricated links.
        let brokenFetcher = ResidentWishReferenceTools.Fetcher(
            fetchPublicData: { _, _ in throw URLError(.cannotConnectToHost) }, download: { _ in png })
        let brokenTools = ResidentWishReferenceTools(coordinator: coordinator, authorizationID: UUID(),
            worldID: world, residentScope: resident, isCurrent: { true }, fetcher: brokenFetcher,
            directory: dir.appendingPathComponent("references-broken"))
        let brokenSession = makeSession(brokenTools.tools)
        let broken = await call(brokenSession, "search-broken", "search_wish_reference_images", ["query": "chair"])
        check(broken.isError && (parse(broken)["code"] as? String) == "reference_search_failed",
              "a failed search returns an explicit error")
        // A structured API error object must never masquerade as an empty result set.
        let apiErrorSearch = try JSONSerialization.data(withJSONObject: ["error": ["code": "badvalue", "info": "invalid search"]])
        let apiErrorFetcher = ResidentWishReferenceTools.Fetcher(
            fetchPublicData: { _, _ in .init(data: apiErrorSearch, mimeType: "application/json") }, download: { _ in png })
        let apiErrorTools = ResidentWishReferenceTools(coordinator: coordinator, authorizationID: UUID(),
            worldID: world, residentScope: resident, isCurrent: { true }, fetcher: apiErrorFetcher,
            directory: dir.appendingPathComponent("references-api-error"))
        let apiErrorSession = makeSession(apiErrorTools.tools)
        let apiError = await call(apiErrorSession, "search-error", "search_wish_reference_images", ["query": "chair"])
        check(apiError.isError && (parse(apiError)["code"] as? String) == "reference_search_failed",
              "a Wikimedia error object is an explicit search failure, never an empty result")
        // A non-JSON response (even with valid-looking bytes) must be refused on MIME.
        let htmlFetcher = ResidentWishReferenceTools.Fetcher(
            fetchPublicData: { _, _ in .init(data: searchData, mimeType: "text/html; charset=utf-8") }, download: { _ in png })
        let htmlTools = ResidentWishReferenceTools(coordinator: coordinator, authorizationID: UUID(),
            worldID: world, residentScope: resident, isCurrent: { true }, fetcher: htmlFetcher,
            directory: dir.appendingPathComponent("references-html"))
        let htmlSession = makeSession(htmlTools.tools)
        let htmlSearch = await call(htmlSession, "search-html", "search_wish_reference_images", ["query": "chair"])
        check(htmlSearch.isError && (parse(htmlSearch)["code"] as? String) == "reference_search_failed",
              "a non-JSON search MIME type is an explicit failure, never an empty result")
        check(ResidentWishReferenceTools.isJSONMIMEType("Application/JSON; charset=utf-8")
              && ResidentWishReferenceTools.isJSONMIMEType("application/problem+json")
              && !ResidentWishReferenceTools.isJSONMIMEType("text/html"),
              "JSON MIME validation ignores parameters, accepts +json and rejects HTML")

        // ── Every wishworld turn (including background) registers the same two schemas.
        // A nil human grant only refuses registration inside the handler; it never removes
        // the tools, because the provider registers once per thread and caches the manifest. ──
        let backgroundDir = dir.appendingPathComponent("references-background")
        try FileManager.default.createDirectory(at: backgroundDir, withIntermediateDirectories: true)
        let backgroundFetcher = liveFetcher(respondSearch: searchData, download: { _ in png })
        let humanTools = ResidentWishReferenceTools.sessionTools(coordinator: coordinator, authorizationID: runID,
            worldID: world, residentScope: resident, isCurrent: { true }, fetcher: backgroundFetcher, directory: backgroundDir)
        let backgroundTools = ResidentWishReferenceTools.sessionTools(coordinator: coordinator, authorizationID: nil,
            worldID: world, residentScope: resident, isCurrent: { true }, fetcher: backgroundFetcher, directory: backgroundDir)
        let humanNames = Set(humanTools.map(\.name))
        let backgroundNames = Set(backgroundTools.map(\.name))
        check(humanNames == backgroundNames
              && humanNames == ["search_wish_reference_images", "register_wish_reference_image"],
              "background and human wishworld turns register the identical reference schemas: \(backgroundNames)")
        let backgroundSession = makeSession(backgroundTools)
        let backgroundSearch = await call(backgroundSession, "background-search", "search_wish_reference_images",
            ["query": "red wooden chair"])
        check(!backgroundSearch.isError && (parse(backgroundSearch)["results"] as? [[String: Any]])?.count == 1,
              "a background turn can still search public references read-only")
        let background = await call(backgroundSession, "background-register", "register_wish_reference_image",
            ["image_url": "https://upload.invalid/thumb/red-chair.png", "display_name": "chair"])
        check(background.isError && (parse(background)["code"] as? String) == "reference_registration_unauthorized",
              "a background run without a host grant cannot register")
        check((try! FileManager.default.contentsOfDirectory(atPath: backgroundDir.path)).isEmpty
              && coordinator.attachmentChoices(authorizationID: runID, worldID: world, residentScope: resident).count == 1,
              "a rejected background registration downloads nothing and adds no attachment")

        // ── Concurrent same-URL registration downloads once and returns one id. ──
        let concurrentRecorder = Recorder()
        let concurrentDir = dir.appendingPathComponent("references-concurrent")
        let concurrentCoordinator = WishMachineCoordinator(store: store, directory: dir.appendingPathComponent("wishes-concurrent"), canClaim: { _ in nil })
        let concurrentRun = UUID()
        let concurrentTools = ResidentWishReferenceTools(coordinator: concurrentCoordinator, authorizationID: concurrentRun,
            worldID: world, residentScope: resident, isCurrent: { true },
            fetcher: ResidentWishReferenceTools.Fetcher(
                fetchPublicData: { _, _ in .init(data: searchData, mimeType: "application/json") }, download: { _ in
                await concurrentRecorder.noteConcurrentDownload()
                try await Task.sleep(nanoseconds: 20_000_000)
                return png
            }), directory: concurrentDir)
        let concurrentSession = makeSession(concurrentTools.tools, scope: concurrentRun)
        let concurrentArgs = ["image_url": "https://upload.invalid/concurrent.png", "display_name": "concurrent"]
        async let first = call(concurrentSession, "concurrent-a", "register_wish_reference_image", concurrentArgs)
        async let second = call(concurrentSession, "concurrent-b", "register_wish_reference_image", concurrentArgs)
        let (firstResult, secondResult) = await (first, second)
        check(parse(firstResult)["attachment_id"] as? String == parse(secondResult)["attachment_id"] as? String
              && concurrentRecorder.concurrentDownloads == 1,
              "concurrent same-URL registration dedups to one download and one attachment")

        print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) resident wish reference tool checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
"""#

let work = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-wish-ref-" + UUID().uuidString)
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }
let main = work.appendingPathComponent("Checks.swift")
try harness.write(to: main, atomically: true, encoding: .utf8)
let binary = work.appendingPathComponent("checks")
let compile = Process()
compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
compile.arguments = ["-swift-version", "6", "-j1", "-parse-as-library"]
    + worldRuntimeHarnessFlags() + [
    sources.appendingPathComponent("Presence/PropGenerationClient.swift").path,
    sources.appendingPathComponent("Presence/PropGenerationStore.swift").path,
    sources.appendingPathComponent("Presence/PropImagePreparation.swift").path,
    sources.appendingPathComponent("Presence/WishMachineOutputDescriptor.swift").path,
    // 连通性词汇只有**一份**：coordinator 的 `isNetworkClassSubmissionError` 现在委托给
    // `ResidentConnectivityFact`，所以那份生产文件必须一起编进来（编同一份，不是抄一份）。
    sources.appendingPathComponent("Presence/WishMachineTaskPresentation.swift").path,
    sources.appendingPathComponent("Presence/WishMachineCoordinator.swift").path,
    sources.appendingPathComponent("Presence/PropTaskDaemonClient.swift").path,
    sources.appendingPathComponent("Agent/WishMachineContract.swift").path,
    sources.appendingPathComponent("Agent/ResidentWishMachineTools.swift").path,
    sessionSource.path,
    referenceSource.path,
    root.appendingPathComponent("tools/fixtures/WishMachineDaemonFixture.swift").path,
    main.path, "-o", binary.path]
try compile.run()
compile.waitUntilExit()
guard compile.terminationStatus == 0 else { exit(compile.terminationStatus) }
let test = Process()
test.executableURL = binary
try test.run()
test.waitUntilExit()
exit(test.terminationStatus)

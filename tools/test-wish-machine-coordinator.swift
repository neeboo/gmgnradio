import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sources = ["Presence/PropGenerationClient", "Presence/PropGenerationStore", "Presence/PropImagePreparation",
               "Presence/WishMachineOutputDescriptor", "Presence/WishMachineCoordinator", "Agent/ResidentWishMachineTools"]
    .map { root.appendingPathComponent("apps/macos/Sources/GMGNRadio/\($0).swift") }
    + [root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/PropTaskDaemonClient.swift"),
       root.appendingPathComponent("tools/fixtures/WishMachineDaemonFixture.swift"),
       // 连通性词汇只有**一份**：coordinator 的 `isNetworkClassSubmissionError` 现在
       // 委托给 `ResidentConnectivityFact`，所以那份生产文件必须一起编进来 ——
       // 是编同一份，不是在这里抄一份词汇表。
       root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/WishMachineTaskPresentation.swift")]
guard sources.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
    print("FAIL: wish machine coordinator and tool primitives are missing"); exit(1)
}
let coordinatorSource = try String(contentsOf: sources[4], encoding: .utf8)
guard !coordinatorSource.contains("submissionTasks"), coordinatorSource.contains("store.onChange"),
      coordinatorSource.contains("case stateChanged") else {
    print("FAIL: wish coordinator still owns execution instead of observing daemon snapshots")
    exit(1)
}
guard coordinatorSource.contains("func unpublishedEvents("), coordinatorSource.contains("func markEventPublished(") else {
    print("FAIL: wish facts cannot be durably handed to the Rust message inbox")
    exit(1)
}
// 暂停的重新校验**不依赖后端健康**：它纯本地、幂等，唯一判据是"有没有用户意图证据"。
// 后端没配好时，遗留的非用户暂停同样必须自愈，而不是继续要求人工解除。只有网络类
// 未知提交的自动确认才需要等后端可达（它要复用幂等身份重发/确认）。
guard let refreshStart = coordinatorSource.range(of: "func refreshPending("),
      let localLift = coordinatorSource.range(of: "discardPausesWithoutUserIntent()", range: refreshStart.upperBound..<coordinatorSource.endIndex),
      let healthGate = coordinatorSource.range(of: "guard healthy else", range: refreshStart.upperBound..<coordinatorSource.endIndex),
      localLift.lowerBound < healthGate.lowerBound else {
    print("FAIL: lifting a pause nobody asked for must run before (and independently of) the backend health gate")
    exit(1)
}
let program = #"""
import Foundation
import ImageIO
import UniformTypeIdentifiers
struct ResidentImageAttachment: Identifiable, Codable, Sendable, Equatable { let id: UUID; let url: URL; let displayName: String }
struct RealtimeDJToolResult { let callID: String; let resultJSON: Data; let isError: Bool }
final class ArchivePermissionFailure: FileManager, @unchecked Sendable {
    var failPermissions = false
    var preparedArchiveObserved = false
    override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        if failPermissions {
            preparedArchiveObserved = fileExists(atPath: path)
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.setAttributes(attributes, ofItemAtPath: path)
    }
}
@MainActor final class ResidentWorldToolSession {
    struct AdditionalTool {
        let name: String; let description: String; let inputSchema: [String: Any]
        let validate: @MainActor ([String: Any]) -> Bool
        let handle: @MainActor (String, Data) async -> RealtimeDJToolResult
    }
}
final class HTTP: URLProtocol {
    static var requests: [URLRequest] = []
    static var state = "queued"
    static var generationCount = 0
    static var submissionKeys: Set<String> = []
    static var loseSubmitResponse = false
    static var observeSubmit: (() -> Void)?
    static var holdSubmit = false
    static var heldSubmit: HTTP?
    static let glb = Data([0x67,0x6c,0x54,0x46,2,0,0,0,20,0,0,0,0,0,0,0,0x4a,0x53,0x4f,0x4e])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        if request.url!.path == "/v1/jobs", request.httpMethod == "POST" {
            let key = request.value(forHTTPHeaderField: "Idempotency-Key") ?? "missing"
            if Self.submissionKeys.insert(key).inserted { Self.generationCount += 1 }
            Self.observeSubmit?()
            if Self.holdSubmit { Self.heldSubmit = self; return }
            if Self.loseSubmitResponse {
                client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return
            }
        }
        if request.url!.path.hasSuffix("/cancel") { Self.state = "cancel_requested" }
        let body: Data
        if request.url!.path.hasSuffix("model.glb") { body = Self.glb }
        else {
            var value: [String: Any] = ["id": String(repeating: "a", count: 32), "state": Self.state,
                "name": "sword", "source": ["author": "user", "license": "internal"], "height_meters": 1.2,
                "compute_may_continue": Self.state == "cancel_requested", "created_at": 1, "updated_at": 2]
            if Self.state == "completed" {
                value["result"] = ["model_url": "/v1/jobs/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/model.glb", "suggested_height_meters": 1.2,
                    "scale_requires_confirmation": true, "interaction_status": "unbound", "workflow_profile": "fixture",
                    "source": ["author": "user", "license": "internal"], "affordance_candidates": ["inspect", "place"], "interaction_bindings": [],
                    "inspection": ["sha256": "fixture", "bytes": 20, "triangles": 1, "primitives": 1, "materials": 1, "accessors": 1,
                        "accessor_bounds": [:], "bounds": ["min": [0,0,0], "max": [1,1,1], "dimensions": [1,1,1], "units": "model_units", "space": "mesh_local"],
                        "scale_calibrated": false, "meters_per_model_unit": NSNull(), "scene_transform_count": 0]]
            }
            body = try! JSONSerialization.data(withJSONObject: value)
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
extension WishMachineCoordinator {
    // Fixture-only waiting, never used by the application or resident tool.
    func settle(_ job: WishMachineJob) async throws -> WishMachineJob {
        for _ in 0..<100000 {
            let current = try await refresh(id: job.id, worldID: job.worldID, residentScope: job.residentScope)
            if current.stage != .submitting && (current.stage != .generated || current.lastError != nil) { return current }
            await Task.yield()
        }
        let current = try read(id: job.id, worldID: job.worldID, residentScope: job.residentScope)
        fatalError("fixture submission did not settle: \(job.requestID) stage=\(current.stage.rawValue) error=\(current.lastError ?? "none")")
    }
    func submitSettled(requestID: String, authorizationID: UUID, attachmentID: UUID, name: String,
        heightMeters: Double, worldID: String, residentScope: String, destination: WishPlacementDestination? = nil) async throws -> WishMachineJob {
        let job = try await submit(requestID: requestID, authorizationID: authorizationID, attachmentID: attachmentID,
            name: name, heightMeters: heightMeters, worldID: worldID, residentScope: residentScope, destination: destination)
        return try await settle(job)
    }
}
@main struct Checks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ title: String) { guard value else { fatalError("FAIL: " + title) }; count += 1 }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wish-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let imageURL = dir.appendingPathComponent("image.png")
        let image = CGImage(width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: CGDataProvider(data: Data(repeating: 200, count: 64) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let output = CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(output, image, nil); check(CGImageDestinationFinalize(output), "PNG fixture")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [HTTP.self]
        let store = fixtureWishStore(directory: dir.appendingPathComponent("props"), session: URLSession(configuration: config))
        try store.configure(endpoint: URL(string: "http://127.0.0.1:8191")!, token: "fixture")
        var evidence = WishMachineClaimEvidence(worldID: "world", activityID: nil, phase: nil, distanceMeters: 5, outputAvailable: false)
        var claimChecks = 0
        let coordinator = WishMachineCoordinator(store: store, directory: dir.appendingPathComponent("wishes"), canClaim: { _ in claimChecks += 1; return evidence })
        let authorization = UUID(), attachment = ResidentImageAttachment(id: UUID(), url: imageURL, displayName: "image.png")
        let asyncCore = dir.appendingPathComponent("async-core")
        let asyncDaemon = WishMachineDaemonFixture(directory: asyncCore, session: URLSession(configuration: config))
        let asyncStore = PropGenerationStore(directory: asyncCore, daemonClient: asyncDaemon)
        try asyncStore.configure(endpoint: URL(string: "http://127.0.0.1:8191")!, token: "fixture")
        let asyncDirectory = dir.appendingPathComponent("async-wishes")
        let asyncCoordinator = WishMachineCoordinator(store: asyncStore, directory: asyncDirectory, canClaim: { _ in nil })
        let asyncGrant = UUID()
        try asyncCoordinator.authorize(attachments: [attachment], worldID: "async-world", residentScope: "async-resident", authorizationID: asyncGrant, source: .init(author: "user", license: "test"))
        var durableChanges = 0
        asyncCoordinator.onChange = {
            check(FileManager.default.fileExists(atPath: asyncDirectory.appendingPathComponent("wishes.json").path), "notification follows durable journal")
            durableChanges += 1
        }
        HTTP.holdSubmit = true
        let accepted = try await asyncCoordinator.submit(requestID: "async-accepted", authorizationID: asyncGrant, attachmentID: attachment.id,
            name: "async", heightMeters: 0.4, worldID: "async-world", residentScope: "async-resident")
        check(accepted.stage == .submitting && durableChanges > 0, "local task ID returns before provider response")
        check(accepted.daemonAccepted == true && asyncDaemon.contexts[accepted.id] == PropTaskContext(worldID: "async-world", residentScope: "async-resident"), "durable task acceptance carries the exact original world and resident")
        let acceptedEvents = asyncCoordinator.pendingEvents(worldID: "async-world", residentScope: "async-resident")
        check(acceptedEvents.count == 1 && acceptedEvents[0].kind == .stateChanged && acceptedEvents[0].wishID == accepted.id, "accepted state has durable same-task event")
        check(asyncCoordinator.unpublishedEvents(worldID: "async-world", residentScope: "async-resident").map(\.id) == acceptedEvents.map(\.id), "facts remain pending until a durable Rust publish acknowledgement")
        try asyncCoordinator.markEventPublished(id: acceptedEvents[0].id)
        let changesAfterPublish = durableChanges
        try asyncCoordinator.markEventPublished(id: acceptedEvents[0].id)
        check(durableChanges == changesAfterPublish, "duplicate durable transfer acknowledgement does not write again")
        check(asyncCoordinator.unpublishedEvents(worldID: "async-world", residentScope: "async-resident").isEmpty
              && asyncCoordinator.pendingEvents(worldID: "async-world", residentScope: "async-resident").count == 1,
              "Rust transfer is separate from the legacy agent-consumed flag")
        for _ in 0..<100000 { if HTTP.heldSubmit != nil { break }; await Task.yield() }
        check(HTTP.heldSubmit != nil, "background task independently reaches held provider")
        let cancelledPending = try await asyncCoordinator.cancel(id: accepted.id, worldID: "async-world", residentScope: "async-resident")
        check(cancelledPending.cancelRequested == true && cancelledPending.stage == .submitting, "cancel while submit busy is retained without claiming completion")
        HTTP.holdSubmit = false
        HTTP.heldSubmit?.startLoading(); HTTP.heldSubmit = nil
        _ = try await asyncCoordinator.settle(accepted)
        for _ in 0..<100000 {
            if try asyncCoordinator.read(id: accepted.id, worldID: "async-world", residentScope: "async-resident").remoteState == .cancelRequested { break }
            await Task.yield()
        }
        let cancelReadback = try asyncCoordinator.read(id: accepted.id, worldID: "async-world", residentScope: "async-resident")
        check(cancelReadback.remoteState == .cancelRequested && cancelReadback.stage != .cancelled && cancelReadback.computeMayContinue, "remote cancel request remains nonterminal")
        HTTP.state = "cancelled"
        await asyncCoordinator.refreshPending(limit: 1)
        let cancelEvents = asyncCoordinator.pendingEvents(worldID: "async-world", residentScope: "async-resident")
        check(cancelEvents.contains { $0.kind == .cancelled && $0.wishID == accepted.id }, "confirmed cancellation reaches durable event")
        await asyncCoordinator.refreshPending(limit: 1)
        check(asyncCoordinator.pendingEvents(worldID: "async-world", residentScope: "async-resident").count == cancelEvents.count, "identical terminal state does not duplicate notification")
        let asyncRestored = WishMachineCoordinator(store: asyncStore, directory: asyncDirectory, canClaim: { _ in nil })
        check(asyncRestored.pendingEvents(worldID: "async-world", residentScope: "async-resident").map(\.id) == cancelEvents.map(\.id), "restart preserves notification IDs")
        check(!asyncRestored.unpublishedEvents(worldID: "async-world", residentScope: "async-resident").contains { $0.id == acceptedEvents[0].id }, "restart does not republish a durably transferred event")
        let untransferred = asyncRestored.unpublishedEvents(worldID: "async-world", residentScope: "async-resident").last!
        let savedAsyncDirectory = dir.appendingPathComponent("async-wishes-saved")
        try FileManager.default.moveItem(at: asyncDirectory, to: savedAsyncDirectory)
        try Data("fixture storage blocker".utf8).write(to: asyncDirectory)
        do { try asyncRestored.markEventPublished(id: untransferred.id); fatalError("FAIL: transfer marker storage failure hidden") }
        catch { count += 1 }
        try FileManager.default.removeItem(at: asyncDirectory)
        try FileManager.default.moveItem(at: savedAsyncDirectory, to: asyncDirectory)
        let failedTransferRestart = WishMachineCoordinator(store: asyncStore, directory: asyncDirectory, canClaim: { _ in nil })
        check(failedTransferRestart.unpublishedEvents(worldID: "async-world", residentScope: "async-resident").contains { $0.id == untransferred.id }, "failed local transfer-marker save retains the same event for idempotent republish after restart")
        HTTP.state = "queued"
        HTTP.requests = []; HTTP.generationCount = 0; HTTP.submissionKeys = []
        try coordinator.authorize(attachments: [attachment], worldID: "world", residentScope: "resident", authorizationID: authorization,
                                  source: .init(author: "user", license: "internal"))
        do {
            _ = try await coordinator.submit(requestID: "call", authorizationID: UUID(), attachmentID: attachment.id,
                name: "sword", heightMeters: 1.2, worldID: "world", residentScope: "resident")
            fatalError("FAIL: unauthorized generation")
        } catch { count += 1 }
        check(HTTP.requests.isEmpty, "unauthorized request never reaches service")
        do {
            _ = try await coordinator.submit(requestID: "call", authorizationID: authorization, attachmentID: UUID(),
                name: "sword", heightMeters: 1.2, worldID: "world", residentScope: "resident")
            fatalError("FAIL: unknown image accepted")
        } catch { count += 1 }
        let job = try await coordinator.submitSettled(requestID: "call", authorizationID: authorization, attachmentID: attachment.id,
            name: "sword", heightMeters: 1.2, worldID: "world", residentScope: "resident")
        check(job.jobID != nil && job.stage == .generating, "submitted job retains world resident attachment association")
        check(job.jobID == job.id && store.jobs.first?.id == job.id, "core identity is allocated before coordinator submission")
        let countAfterSubmit = HTTP.requests.count
        let replay = try await coordinator.submit(requestID: "call", authorizationID: authorization, attachmentID: attachment.id,
            name: "sword", heightMeters: 1.2, worldID: "world", residentScope: "resident")
        check(replay.id == job.id && HTTP.requests.count == countAfterSubmit, "same tool call does not generate twice")
        do {
            _ = try await coordinator.submit(requestID: "new-call", authorizationID: authorization, attachmentID: attachment.id,
                name: "another", heightMeters: 1.2, worldID: "world", residentScope: "resident")
            fatalError("FAIL: authorization reused for second generation")
        } catch { count += 1 }
        do { _ = try coordinator.read(id: job.id, worldID: "other", residentScope: "resident"); fatalError("FAIL: crossed world") }
        catch { count += 1 }
        check(coordinator.readyOutputs(worldID: "world").isEmpty, "queued result never appears on tray")
        check(coordinator.residentJobs(worldID: "world", residentScope: "resident").count == 1 && coordinator.residentJobs(worldID: "world", residentScope: "other").isEmpty,
              "resident context only lists own jobs")
        HTTP.state = "completed"
        await coordinator.refreshPending(limit: 1)
        let ready = try coordinator.read(id: job.id, worldID: "world", residentScope: "resident")
        check(ready.stage == .ready && ready.modelPath != nil, "completion downloads GLB before tray ready")
        check(coordinator.readyOutputs(worldID: "world").first?.id == job.objectID, "descriptor uses stable object identity")
        let events = coordinator.pendingEvents(worldID: "world", residentScope: "resident")
        check(Set(events.map(\.kind)) == [.stateChanged, .generationCompleted, .outputReady], "generated and available events remain distinct from task progress")
        check(coordinator.pendingEvents(worldID: "other", residentScope: "resident").isEmpty, "event routed only to original world")
        await coordinator.refreshPending(limit: 1)
        check(coordinator.pendingEvents(worldID: "world", residentScope: "resident").count == events.count, "no duplicate terminal events")
        let beforeRenderFailure = try coordinator.read(id: job.id, worldID: "world", residentScope: "resident")
        do { try coordinator.recordOutputRenderFailure(id: job.id, worldID: "other", residentScope: "resident", message: "bad asset"); fatalError("FAIL: wrong-scope renderer failure accepted") }
        catch WishMachineError.wrongScope { count += 1 }
        var rendererNotifications = 0
        coordinator.onChange = { rendererNotifications += 1 }
        try coordinator.recordOutputRenderFailure(id: job.id, worldID: "world", residentScope: "resident", message: "bad asset")
        let renderEvent = coordinator.unpublishedEvents(worldID: "world", residentScope: "resident").first { $0.failureSource == "renderer" }!
        check(coordinator.outputRenderFailure(id: job.id, worldID: "world", residentScope: "resident")?.id == renderEvent.id, "read-only renderer failure query returns the persisted fact")
        check(coordinator.outputRenderFailure(id: job.id, worldID: "other", residentScope: "resident") == nil
            && coordinator.outputRenderFailure(id: job.id, worldID: "world", residentScope: "other") == nil
            && coordinator.outputRenderFailure(id: UUID(), worldID: "world", residentScope: "resident") == nil, "renderer failure query isolates world resident and task")
        check(renderEvent.kind == .failed && renderEvent.stage == .ready && renderEvent.message?.hasPrefix("成品场景加载失败") == true, "renderer failure is a distinct local fact, never remote generation failure")
        check(try coordinator.read(id: job.id, worldID: "world", residentScope: "resident") == beforeRenderFailure, "renderer failure preserves downloaded backend state and model identity")
        try coordinator.recordOutputRenderFailure(id: job.id, worldID: "world", residentScope: "resident", message: "different per-frame detail")
        check(rendererNotifications == 1 && coordinator.unpublishedEvents(worldID: "world", residentScope: "resident").filter { $0.failureSource == "renderer" }.map(\.id) == [renderEvent.id], "repeated renderer callbacks retain one event and do not persist every frame")
        coordinator.onChange = nil
        // A recovered download may retain an earlier failure fact; a scene failure is separate.
        var renderArchive = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("wishes/wishes.json"))) as! [String: Any]
        var oldDownloadFailure = try JSONSerialization.jsonObject(with: JSONEncoder().encode(renderEvent)) as! [String: Any]
        let oldDownloadID = UUID()
        oldDownloadFailure["id"] = oldDownloadID.uuidString
        oldDownloadFailure.removeValue(forKey: "failureSource")
        oldDownloadFailure["message"] = "prior download failure"
        renderArchive["events"] = [oldDownloadFailure]
        let renderArchiveData = try JSONSerialization.data(withJSONObject: renderArchive)
        let renderHistoryDirectory = dir.appendingPathComponent("renderer-history")
        try FileManager.default.createDirectory(at: renderHistoryDirectory, withIntermediateDirectories: true)
        try renderArchiveData.write(to: renderHistoryDirectory.appendingPathComponent("wishes.json"))
        let renderHistory = WishMachineCoordinator(store: store, directory: renderHistoryDirectory, canClaim: { _ in nil })
        try renderHistory.recordOutputRenderFailure(id: job.id, worldID: "world", residentScope: "resident", message: "scene failed")
        let separateFailures = renderHistory.unpublishedEvents(worldID: "world", residentScope: "resident").filter { $0.kind == .failed }
        check(separateFailures.count == 2 && separateFailures.contains { $0.id == oldDownloadID && $0.failureSource == nil }, "scene failure does not replace or suppress a prior download failure fact")
        let blockedRenderDirectory = dir.appendingPathComponent("renderer-write-failure")
        try FileManager.default.createDirectory(at: blockedRenderDirectory, withIntermediateDirectories: true)
        try renderArchiveData.write(to: blockedRenderDirectory.appendingPathComponent("wishes.json"))
        let blockedRenderer = WishMachineCoordinator(store: store, directory: blockedRenderDirectory, canClaim: { _ in nil })
        var failedRenderNotifications = 0
        blockedRenderer.onChange = { failedRenderNotifications += 1 }
        let backupRenderDirectory = dir.appendingPathComponent("renderer-write-backup")
        try FileManager.default.moveItem(at: blockedRenderDirectory, to: backupRenderDirectory)
        try Data("fixture blocker".utf8).write(to: blockedRenderDirectory)
        do { try blockedRenderer.recordOutputRenderFailure(id: job.id, worldID: "world", residentScope: "resident", message: "scene failed"); fatalError("FAIL: renderer event write failure hidden") }
        catch WishMachineError.unavailable { count += 1 }
        check(failedRenderNotifications == 0, "failed renderer fact persistence does not notify publication")
        check(blockedRenderer.outputRenderFailure(id: job.id, worldID: "world", residentScope: "resident") == nil, "unpersisted in-memory renderer failure is never returned as durable evidence")
        let rendererWriteRestart = WishMachineCoordinator(store: store, directory: backupRenderDirectory, canClaim: { _ in nil })
        check(!rendererWriteRestart.unpublishedEvents(worldID: "world", residentScope: "resident").contains { $0.failureSource == "renderer" }, "failed renderer fact persistence does not appear after restart")
        do { _ = try coordinator.claim(id: job.id, worldID: "world", residentScope: "resident"); fatalError("FAIL: remote claim") }
        catch { count += 1 }
        evidence = .init(worldID: "world", activityID: "wish_machine.collect", phase: "approaching", distanceMeters: 2, outputAvailable: false)
        claimChecks = 0
        var leaseCurrent = true, claimFinished = false
        let waitingTools = ResidentWishMachineTools(coordinator: coordinator, worldID: "world", residentScope: "resident", authorizationID: nil, isCurrent: { leaseCurrent }).tools
        let claimTool = waitingTools.first { $0.name == "claim_wish_output" }!
        let waitingClaim = Task {
            let result = await claimTool.handle("wait-claim", try! JSONSerialization.data(withJSONObject: ["wish_id": job.id.uuidString]))
            claimFinished = true
            return result
        }
        for _ in 0..<10000 { if claimChecks > 0 { break }; await Task.yield() }
        check(claimChecks > 0 && !claimFinished, "claim waits only for already started collect activity")
        leaseCurrent = false
        let stoppedClaim = await waitingClaim.value
        let afterStoppedClaim = try coordinator.read(id: job.id, worldID: "world", residentScope: "resident")
        check(stoppedClaim.isError && afterStoppedClaim.stage == .ready,
              "stop during arrival wait leaves output unclaimed")
        // ── 领取判据：站在注册锚点上 ⇒ 通过；越容差 / 托盘没东西 / 没有真的在跑 ⇒ 仍然拒绝 ──
        // 位置判据只有注册锚点一个来源（宿主用 `propAnchorRegistry.entry(activityID:)` 供口径），
        // 这里逐条把边界钉住：既不许"站在锚点上还不通过"，也不许把门禁拆掉。
        // 先跑拒绝组：领取一旦成功，后面的 `claim` 会按幂等直接返回，拒绝就测不出来了。
        evidence = .init(worldID: "world", activityID: "wish_machine.collect", phase: "loop",
                         distanceMeters: 0.25 + 0.000001, outputAvailable: true)
        var beyondToleranceRejected = false
        do { _ = try coordinator.claim(id: job.id, worldID: "world", residentScope: "resident") }
        catch WishMachineError.notAtMachine { beyondToleranceRejected = true }
        check(beyondToleranceRejected, "distance beyond the registered anchor tolerance must still refuse the pickup")
        evidence = .init(worldID: "world", activityID: "wish_machine.collect", phase: "loop",
                         distanceMeters: 0, outputAvailable: false)
        var unrenderedTrayRejected = false
        do { _ = try coordinator.claim(id: job.id, worldID: "world", residentScope: "resident") }
        catch WishMachineError.notAtMachine { unrenderedTrayRejected = true }
        check(unrenderedTrayRejected, "an unrendered tray must still refuse the pickup while standing on the anchor")
        // 执行器空转时 `ActivityExecutor.status` 会把相位回落成安全待机的 loop：没有 id 的
        // 一边必须仍然拒绝，不能靠这个回落相位冒充"真的在跑领取活动"。
        evidence = .init(worldID: "world", activityID: nil, phase: "loop",
                         distanceMeters: 0, outputAvailable: true)
        var idleExecuterRejected = false
        do { _ = try coordinator.claim(id: job.id, worldID: "world", residentScope: "resident") }
        catch WishMachineError.notAtMachine { idleExecuterRejected = true }
        check(idleExecuterRejected, "a safe-idle loop phase without a running collect activity must still refuse the pickup")
        evidence = .init(worldID: "world", activityID: "wish_machine.collect", phase: "approach",
                         distanceMeters: 0, outputAvailable: true)
        var approachingRejected = false
        do { _ = try coordinator.claim(id: job.id, worldID: "world", residentScope: "resident") }
        catch WishMachineError.notAtMachine { approachingRejected = true }
        check(approachingRejected, "an unfinished approach must still refuse the pickup")
        check(try coordinator.read(id: job.id, worldID: "world", residentScope: "resident").stage == .ready,
              "every rejected evidence attempt leaves the output unclaimed")
        // 站在注册锚点上、托盘也渲染好了 ⇒ 必须通过（位置判据只认注册锚点这一个来源）。
        evidence = .init(worldID: "world", activityID: "wish_machine.collect", phase: "loop",
                         distanceMeters: 0, outputAvailable: true)
        check(try coordinator.claim(id: job.id, worldID: "world", residentScope: "resident").stage == .claimed,
              "standing exactly on the registered pickup anchor with a rendered tray must claim")
        evidence = .init(worldID: "world", activityID: "wish_machine.collect", phase: "loop", distanceMeters: 0.25, outputAvailable: true)
        let claimed = try coordinator.claim(id: job.id, worldID: "world", residentScope: "resident")
        let claimedAgain = try coordinator.claim(id: job.id, worldID: "world", residentScope: "resident")
        check(claimed.stage == .claimed && claimedAgain.objectID == job.objectID, "arrival claim is stable and idempotent")
        check(coordinator.readyOutputs(worldID: "world").isEmpty, "claimed item removed from unclaimed tray outputs")
        let restored = WishMachineCoordinator(store: store, directory: dir.appendingPathComponent("wishes"), canClaim: { _ in evidence })
        check(try restored.read(id: job.id, worldID: "world", residentScope: "resident").stage == .claimed, "claim persists across restart")
        check(restored.unpublishedEvents(worldID: "world", residentScope: "resident").contains { $0.id == renderEvent.id && $0.failureSource == "renderer" }, "renderer failure ID survives restart")
        check(restored.outputRenderFailure(id: job.id, worldID: "world", residentScope: "resident")?.id == renderEvent.id, "renderer failure query reads the same fact after restart")
        do { try restored.recordOutputRenderFailure(id: job.id, worldID: "world", residentScope: "resident", message: "stale renderer"); fatalError("FAIL: claimed task renderer failure accepted") }
        catch WishMachineError.notReady { count += 1 }
        try restored.acknowledgeEvent(id: events[0].id)
        check(!restored.pendingEvents(worldID: "world", residentScope: "resident").contains { $0.id == events[0].id }, "host acknowledges event explicitly")
        check(!restored.unpublishedEvents(worldID: "world", residentScope: "resident").contains { $0.id == events[0].id }, "legacy consumed events are not broadcast anew during migration")
        check(restored.unpublishedEvents(worldID: "world", residentScope: "resident").contains { $0.kind == .claimed && $0.wishID == job.id }, "real claim emits a stable same-task fact for Rust delivery")
        let tools = ResidentWishMachineTools(coordinator: coordinator, worldID: "world", residentScope: "resident", authorizationID: nil, isCurrent: { true }).tools
        check(tools.count == 6 && tools.contains { $0.name == "submit_wish_generation" }, "stable schema always registers all wish primitives")
        let allowedTools = ResidentWishMachineTools(coordinator: coordinator, worldID: "world", residentScope: "resident", authorizationID: authorization, isCurrent: { true }).tools
        let submit = allowedTools.first { $0.name == "submit_wish_generation" }!
        let props = submit.inputSchema["properties"] as! [String: Any]
        let attachmentParameter = props["attachment_id"] as! [String: Any]
        check(attachmentParameter["enum"] == nil, "submit schema stays independent of current image IDs")
        let schemaWithoutGrant = try JSONSerialization.data(withJSONObject: tools.map { ["name": $0.name, "description": $0.description, "schema": $0.inputSchema] }, options: .sortedKeys)
        let schemaWithGrant = try JSONSerialization.data(withJSONObject: allowedTools.map { ["name": $0.name, "description": $0.description, "schema": $0.inputSchema] }, options: .sortedKeys)
        check(schemaWithoutGrant == schemaWithGrant, "same resumed resident retains identical tool schemas")
        let autonomousSubmit = tools.first { $0.name == "submit_wish_generation" }!
        let validSubmitArguments = try JSONSerialization.data(withJSONObject: ["attachment_id": attachment.id.uuidString, "name": "sword", "height_meters": 1.2])
        let beforeAutonomousSubmit = HTTP.requests.count
        let refused = await autonomousSubmit.handle("autonomous-spend", validSubmitArguments)
        check(refused.isError && HTTP.requests.count == beforeAutonomousSubmit, "schema registration does not grant autonomous spending")
        let discoveryTool = allowedTools.first { $0.name == "read_wish_generation" }!
        check(discoveryTool.validate([:]), "read tool accepts discovery without wish ID")
        let discovered = await discoveryTool.handle("discover", Data("{}".utf8))
        let discoveryJSON = try JSONSerialization.jsonObject(with: discovered.resultJSON) as! [String: Any]
        let discoveredAttachments = discoveryJSON["attachments"] as? [[String: Any]]
        check(discoveredAttachments?.first?["attachment_id"] as? String == attachment.id.uuidString
              && discoveredAttachments?.first?["url"] == nil && discoveryJSON["generation_authorized"] as? Bool == false,
              "read discovers registered images and reports consumed grant without paths")
        check(!submit.validate(["attachment_id": attachment.id.uuidString, "name": "sword", "height_meters": 1.2, "path": "/etc/passwd"]), "no arbitrary file path tool argument")
        let stoppedTools = ResidentWishMachineTools(coordinator: coordinator, worldID: "world", residentScope: "resident", authorizationID: nil, isCurrent: { false }).tools
        let stopped = await stoppedTools[0].handle("stopped", try JSONSerialization.data(withJSONObject: ["wish_id": job.id.uuidString]))
        check(stopped.isError, "stopped resident cannot use tool")
        let brokenDirectory = dir.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: brokenDirectory, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: brokenDirectory.appendingPathComponent("wishes.json"))
        let broken = WishMachineCoordinator(store: store, directory: brokenDirectory, canClaim: { _ in evidence })
        do {
            try broken.authorize(attachments: [attachment], worldID: "world", residentScope: "resident", authorizationID: UUID(), source: .init(author: "user", license: "internal"))
            fatalError("FAIL: damaged wish history overwritten")
        } catch { count += 1 }
        let brokenReadback = try String(contentsOf: brokenDirectory.appendingPathComponent("wishes.json"), encoding: .utf8)
        check(brokenReadback == "broken", "damaged history preserved")
        let recoveryProps = dir.appendingPathComponent("recovery-props"), recoveryWishes = dir.appendingPathComponent("recovery-wishes")
        let recoveryStore = fixtureWishStore(directory: recoveryProps, session: URLSession(configuration: config))
        try recoveryStore.configure(endpoint: URL(string: "http://127.0.0.1:8191")!, token: "fixture")
        let recoveryCoordinator = WishMachineCoordinator(store: recoveryStore, directory: recoveryWishes, canClaim: { _ in nil })
        let recoveryAuthorization = UUID()
        try recoveryCoordinator.authorize(attachments: [attachment], worldID: "original-world", residentScope: "original-resident", authorizationID: recoveryAuthorization,
                                          source: .init(author: "user", license: "internal"))
        var associationAtSend = false
        var archiveAtSend = Data()
        HTTP.observeSubmit = {
            archiveAtSend = try! Data(contentsOf: recoveryWishes.appendingPathComponent("wishes.json"))
            let archive = try! JSONSerialization.jsonObject(with: archiveAtSend) as! [String: Any]
            let wish = (archive["jobs"] as! [[String: Any]])[0]
            associationAtSend = wish["jobID"] as? String == wish["id"] as? String
                && wish["worldID"] as? String == "original-world" && wish["residentScope"] as? String == "original-resident"
        }
        HTTP.state = "queued"; HTTP.loseSubmitResponse = true
        let uncertain = try await recoveryCoordinator.submitSettled(requestID: "lost-response", authorizationID: recoveryAuthorization, attachmentID: attachment.id,
            name: "sword", heightMeters: 1.2, worldID: "original-world", residentScope: "original-resident")
        check(associationAtSend && uncertain.jobID != nil && uncertain.stage == .submissionUncertain, "owner association exists on disk before remote response")
        let generationCountBeforeRetry = HTTP.generationCount
        HTTP.observeSubmit = nil; HTTP.loseSubmitResponse = false
        // Restore the checkpoint that existed while the HTTP submission was in flight.
        try archiveAtSend.write(to: recoveryWishes.appendingPathComponent("wishes.json"), options: .atomic)
        let restartedStore = fixtureWishStore(directory: recoveryProps, session: URLSession(configuration: config))
        try restartedStore.configure(endpoint: URL(string: "http://127.0.0.1:8191")!, token: "fixture")
        let restarted = WishMachineCoordinator(store: restartedStore, directory: recoveryWishes, canClaim: { _ in nil })
        let restoredOwner = try restarted.read(id: uncertain.id, worldID: "original-world", residentScope: "original-resident")
        check(restoredOwner.jobID == uncertain.id && restoredOwner.stage == .submissionUncertain, "restart retains original world resident and deterministic core identity")
        let recoveryTools = ResidentWishMachineTools(coordinator: restarted, worldID: "original-world", residentScope: "original-resident", authorizationID: nil, isCurrent: { true }).tools
        let retryTool = recoveryTools.first { $0.name == "retry_wish_generation" }
        check(retryTool != nil, "uncertain task has explicit identity preserving recovery tool")
        let retryArguments = try JSONSerialization.data(withJSONObject: ["wish_id": uncertain.id.uuidString])
        let retryResult = await retryTool!.handle("retry-one", retryArguments)
        let recovered = try await restarted.settle(restarted.read(id: uncertain.id, worldID: "original-world", residentScope: "original-resident"))
        check(HTTP.generationCount == generationCountBeforeRetry, "explicit recovery never schedules another GPU generation")
        check(recovered.stage == .generating && recovered.jobID == uncertain.id,
              "explicit recovery confirms original task identity")
        check(!retryResult.isError, "recovery tool reports confirmation")
        let requestsBeforeKnownRetry = HTTP.requests.filter { $0.httpMethod == "POST" && $0.url?.path == "/v1/jobs" }.count
        _ = await retryTool!.handle("retry-two", retryArguments)
        check(HTTP.requests.filter { $0.httpMethod == "POST" && $0.url?.path == "/v1/jobs" }.count == requestsBeforeKnownRetry, "confirmed receipt cannot be resubmitted by retry tool")
        let pauseProps = dir.appendingPathComponent("pause-props"), pauseWishes = dir.appendingPathComponent("pause-wishes")
        let pauseStore = fixtureWishStore(directory: pauseProps, session: URLSession(configuration: config))
        try pauseStore.configure(endpoint: URL(string: "http://127.0.0.1:8191")!, token: "fixture")
        let pausable = WishMachineCoordinator(store: pauseStore, directory: pauseWishes, canClaim: { _ in evidence })
        let pauseGrant = UUID()
        try pausable.authorize(attachments: [attachment], worldID: "world", residentScope: "resident", authorizationID: pauseGrant,
                               source: .init(author: "user", license: "internal"))
        HTTP.state = "completed"
        let pauseJob = try await pausable.submitSettled(requestID: "pause-job", authorizationID: pauseGrant, attachmentID: attachment.id,
            name: "sword", heightMeters: 1.2, worldID: "world", residentScope: "resident")
        await pausable.refreshPending(limit: 1)
        let eventsBeforePause = pausable.pendingEvents(worldID: "world", residentScope: "resident")
        let requestsBeforePause = HTTP.requests.count
        try pausable.pauseContinuations(worldID: "world", residentScope: "resident")
        check(HTTP.requests.count == requestsBeforePause, "pausing continuation does not cancel issued service work")
        check(pausable.automaticContinuationEvents(worldID: "world", residentScope: "resident").isEmpty
              && pausable.pendingEvents(worldID: "world", residentScope: "resident").count == eventsBeforePause.count,
              "automatic pause preserves unacknowledged facts")
        let pauseRestart = WishMachineCoordinator(store: pauseStore, directory: pauseWishes, canClaim: { _ in evidence })
        let restoredPausedJob = try pauseRestart.read(id: pauseJob.id, worldID: "world", residentScope: "resident")
        check(restoredPausedJob.autoContinuationPaused == true && pauseRestart.automaticContinuationEvents(worldID: "world", residentScope: "resident").isEmpty,
              "restart cannot resume a stopped collection commission")
        let pauseReadTools = ResidentWishMachineTools(coordinator: pauseRestart, worldID: "world", residentScope: "resident", authorizationID: nil, isCurrent: { true }).tools
        check(pauseReadTools.contains { $0.name == "resume_wish_continuation" }, "paused existing wishes expose an explicit formal resume tool")
        let pausedRead = await pauseReadTools.first { $0.name == "read_wish_generation" }!.handle("paused-read", try JSONSerialization.data(withJSONObject: ["wish_id": pauseJob.id.uuidString]))
        let pausedReadJSON = try JSONSerialization.jsonObject(with: pausedRead.resultJSON) as! [String: Any]
        check(pausedReadJSON["auto_continuation_paused"] as? Bool == true, "resident readback identifies paused automatic collection")
        let pauseClaimArguments = try JSONSerialization.data(withJSONObject: ["wish_id": pauseJob.id.uuidString])
        let backgroundClaim = await pauseReadTools.first { $0.name == "claim_wish_output" }!.handle("ambient-claim", pauseClaimArguments)
        let afterBackgroundClaim = try pauseRestart.read(id: pauseJob.id, worldID: "world", residentScope: "resident")
        check(backgroundClaim.isError && afterBackgroundClaim.stage == .ready, "ambient read and claim cannot bypass persisted commission pause")
        let humanTools = ResidentWishMachineTools(coordinator: pauseRestart, worldID: "world", residentScope: "resident", authorizationID: nil, isCurrent: { true }, humanOrderedClaim: { true }).tools
        let humanClaim = await humanTools.first { $0.name == "claim_wish_output" }!.handle("new-human-claim", pauseClaimArguments)
        let manualClaim = try pauseRestart.read(id: pauseJob.id, worldID: "world", residentScope: "resident")
        check(!humanClaim.isError && manualClaim.autoContinuationPaused == true, "fresh human claim does not silently reenable automatic commission")
        check(manualClaim.stage == .claimed && manualClaim.objectID == pauseJob.objectID, "fresh human instruction can still claim paused output")
        // 领取授权是"本轮是否载有人类明确指令"，按每次调用求值：后台 run 被人类
        // 引导接手后（同一 run 的 humanOrderedClaim 由 false 变 true）必须能领取。
        // 建租约时的快照口径会让这一轮白跑，这正是真机上"明确下令也拿不到"的一类。
        let steeringPaused = WishMachineCoordinator(store: pauseStore, directory: pauseWishes, canClaim: { _ in evidence })
        HTTP.state = "completed"
        let steeringGrant = UUID()
        try steeringPaused.authorize(attachments: [attachment], worldID: "world", residentScope: "resident", authorizationID: steeringGrant,
                                     source: .init(author: "user", license: "internal"))
        let steeringJob = try await steeringPaused.submitSettled(requestID: "steering-paused-job", authorizationID: steeringGrant,
            attachmentID: attachment.id, name: "steered sword", heightMeters: 1.2, worldID: "world", residentScope: "resident")
        try steeringPaused.pauseContinuations(worldID: "world", residentScope: "resident")
        var steeredRunHasHumanInput = false
        let steeringTools = ResidentWishMachineTools(coordinator: steeringPaused, worldID: "world", residentScope: "resident",
            authorizationID: nil, isCurrent: { true }, humanOrderedClaim: { steeredRunHasHumanInput }).tools
        let steeringClaimArguments = try JSONSerialization.data(withJSONObject: ["wish_id": steeringJob.id.uuidString])
        let snapshotDenied = await steeringTools.first { $0.name == "claim_wish_output" }!
            .handle("snapshotless-claim", steeringClaimArguments)
        check(snapshotDenied.isError, "a run with no human input cannot claim a paused artifact")
        steeredRunHasHumanInput = true
        let steeredClaim = await steeringTools.first { $0.name == "claim_wish_output" }!
            .handle("steered-human-claim", steeringClaimArguments)
        let steeredReadback = try steeringPaused.read(id: steeringJob.id, worldID: "world", residentScope: "resident")
        check(!steeredClaim.isError && steeredReadback.stage == .claimed && steeredReadback.autoContinuationPaused == true,
              "human steering into a live run authorizes that run's explicit claim without resuming automatic commission")
        let newGrant = UUID()
        try pauseRestart.authorize(attachments: [attachment], worldID: "world", residentScope: "resident", authorizationID: newGrant,
                                   source: .init(author: "user", license: "internal"))
        let newJob = try await pauseRestart.submitSettled(requestID: "new-user-request", authorizationID: newGrant, attachmentID: attachment.id,
            name: "new sword", heightMeters: 1.2, worldID: "world", residentScope: "resident")
        await pauseRestart.refreshPending(limit: 1)
        check(newJob.autoContinuationPaused != true && pauseRestart.automaticContinuationEvents(worldID: "world", residentScope: "resident").contains { $0.wishID == newJob.id },
              "newly authorized wish does not inherit old commission pause")
        // A write failure must leave the in-memory stop active and expose that it was not saved.
        let pauseFile = pauseWishes.appendingPathComponent("wishes.json")
        try FileManager.default.moveItem(at: pauseFile, to: pauseWishes.appendingPathComponent("wishes-backup.json"))
        try FileManager.default.createDirectory(at: pauseFile, withIntermediateDirectories: false)
        do { try pauseRestart.pauseContinuations(worldID: "world", residentScope: "resident"); fatalError("FAIL: pause persistence failure hidden") }
        catch { count += 1 }
        check(pauseRestart.jobs.first { $0.id == newJob.id }?.autoContinuationPaused == true
              && pauseRestart.errorMessage?.contains("保存失败") == true, "failed persistence keeps memory paused and reports unsaved state")
        // ---- 任务 2: scoped image registration and cross-turn reuse ----
        let scopedStore = fixtureWishStore(directory: dir.appendingPathComponent("scoped-props"), session: URLSession(configuration: config))
        try scopedStore.configure(endpoint: URL(string: "http://127.0.0.1:8191")!, token: "fixture")
        let scoped = WishMachineCoordinator(store: scopedStore, directory: dir.appendingPathComponent("scoped-wishes"), canClaim: { _ in nil })
        try scoped.registerImages([attachment], worldID: "world", residentScope: "resident", conversationID: "conv-a")
        check(scoped.registeredImages(worldID: "world", residentScope: "resident", conversationID: "conv-a").map(\.id) == [attachment.id], "registered image reusable in original conversation scope")
        check(scoped.registeredImages(worldID: "world", residentScope: "resident", conversationID: "conv-b").isEmpty, "image invisible outside original conversation")
        check(scoped.registeredImages(worldID: "world", residentScope: "other", conversationID: "conv-a").isEmpty, "image invisible outside original resident")
        check(scoped.registeredImages(worldID: "other", residentScope: "resident", conversationID: "conv-a").isEmpty, "image invisible outside original world")
        do { try scoped.registerImages([attachment], worldID: "world", residentScope: "other", conversationID: "conv-a"); fatalError("FAIL: cross-scope registration accepted") } catch { count += 1 }
        let laterGrant = UUID()
        try scoped.authorize(registeredImageIDs: [attachment.id], worldID: "world", residentScope: "resident", conversationID: "conv-a", authorizationID: laterGrant, source: .init(author: "user", license: "internal"))
        check(scoped.attachmentChoices(authorizationID: laterGrant, worldID: "world", residentScope: "resident").count == 1, "later current instruction reuses earlier registered attachment")
        do { try scoped.authorize(registeredImageIDs: [attachment.id], worldID: "world", residentScope: "resident", conversationID: "conv-b", authorizationID: UUID(), source: .init(author: "user", license: "internal")); fatalError("FAIL: other conversation authorized") } catch { count += 1 }
        let scopedReload = WishMachineCoordinator(store: scopedStore, directory: dir.appendingPathComponent("scoped-wishes"), canClaim: { _ in nil })
        let laterGrantAfterReload = UUID()
        try scopedReload.authorize(registeredImageIDs: [attachment.id], worldID: "world", residentScope: "resident", conversationID: "conv-a", authorizationID: laterGrantAfterReload, source: .init(author: "user", license: "internal"))
        check(scopedReload.attachmentChoices(authorizationID: laterGrantAfterReload, worldID: "world", residentScope: "resident").count == 1, "registration and later reuse survive restart")
        // ---- 任务 5: persisted object-limited placement delegation ----
        HTTP.state = "completed"
        let placementStore = fixtureWishStore(directory: dir.appendingPathComponent("placement-props"), session: URLSession(configuration: config))
        try placementStore.configure(endpoint: URL(string: "http://127.0.0.1:8191")!, token: "fixture")
        let claimEvidence = WishMachineClaimEvidence(worldID: "world", activityID: "wish_machine.collect", phase: "loop", distanceMeters: 0.1, outputAvailable: true)
        let placementCoordinator = WishMachineCoordinator(store: placementStore, directory: dir.appendingPathComponent("placement-wishes"), canClaim: { _ in claimEvidence })
        let placeGrant = UUID()
        try placementCoordinator.authorize(attachments: [attachment], worldID: "world", residentScope: "resident", authorizationID: placeGrant, source: .init(author: "user", license: "internal"))
        let explicitTarget = WishPlacementTarget(surfaceID: "resident.display_table", position: .init(x: 9, y: 0.52, z: -5), yaw: 0.5)
        _ = try placementCoordinator.authorizePlacement(authorizationID: placeGrant, worldID: "world", residentScope: "resident",
            allowedSurfaceIDs: ["resident.display_table"], explicitTarget: explicitTarget)
        do { _ = try placementCoordinator.authorizePlacement(authorizationID: UUID(), worldID: "world", residentScope: "resident", allowedSurfaceIDs: ["resident.display_table"]); fatalError("FAIL: placement grant without generation authorization") } catch { count += 1 }
        do { _ = try placementCoordinator.authorizePlacement(authorizationID: placeGrant, worldID: "world", residentScope: "resident", allowedSurfaceIDs: ["elsewhere"]); fatalError("FAIL: conflicting destination grant accepted") } catch { count += 1 }
        let placeJob = try await placementCoordinator.submitSettled(requestID: "place-call", authorizationID: placeGrant, attachmentID: attachment.id,
            name: "teapot", heightMeters: 0.42, worldID: "world", residentScope: "resident")
        let bound = placementCoordinator.placementDelegations(worldID: "world", residentScope: "resident")
        check(bound.count == 1 && bound[0].objectID == placeJob.objectID && bound[0].state == .pending, "accepted submission binds delegation to stable object identity")
        check(bound[0].requestID.hasPrefix("placement."), "delegation carries stable persisted request id")
        do { _ = try placementCoordinator.validatePlacementCommand(worldID: "world", residentScope: "resident", objectID: placeJob.objectID, surfaceID: "resident.display_table", target: explicitTarget); fatalError("FAIL: unclaimed placement validated") } catch { count += 1 }
        _ = try await placementCoordinator.refresh(id: placeJob.id, worldID: "world", residentScope: "resident")
        _ = try placementCoordinator.claim(id: placeJob.id, worldID: "world", residentScope: "resident")
        _ = try placementCoordinator.validatePlacementCommand(worldID: "world", residentScope: "resident", objectID: placeJob.objectID, surfaceID: "resident.display_table", target: explicitTarget)
        do { _ = try placementCoordinator.validatePlacementCommand(worldID: "world", residentScope: "resident", objectID: placeJob.objectID, surfaceID: "resident.display_table", target: .init(surfaceID: "resident.display_table", position: .init(x: 9, y: 0.52, z: -5), yaw: 0.7)); fatalError("FAIL: rotated target accepted") } catch { count += 1 }
        do { _ = try placementCoordinator.validatePlacementCommand(worldID: "world", residentScope: "resident", objectID: placeJob.objectID, surfaceID: "resident.floor", target: explicitTarget); fatalError("FAIL: other surface accepted") } catch { count += 1 }
        do { _ = try placementCoordinator.validatePlacementCommand(worldID: "world", residentScope: "resident", objectID: "other-object", surfaceID: "resident.display_table", target: explicitTarget); fatalError("FAIL: other object accepted") } catch { count += 1 }
        do { _ = try placementCoordinator.validatePlacementCommand(worldID: "other", residentScope: "resident", objectID: placeJob.objectID, surfaceID: "resident.display_table", target: explicitTarget); fatalError("FAIL: cross-world validation accepted") } catch { count += 1 }
        let completedGrant = try placementCoordinator.recordPlacementCompletion(worldID: "world", residentScope: "resident", objectID: placeJob.objectID,
            requestID: bound[0].requestID, surfaceID: "resident.display_table", target: explicitTarget)
        check(completedGrant.state == .placed && completedGrant.lastError == nil, "durable placement completion recorded")
        let repeatedGrant = try placementCoordinator.recordPlacementCompletion(worldID: "world", residentScope: "resident", objectID: placeJob.objectID,
            requestID: bound[0].requestID, surfaceID: "resident.display_table", target: explicitTarget)
        check(repeatedGrant.state == .placed, "stable request id makes repeated completion idempotent")
        check(placementCoordinator.unpublishedEvents(worldID: "world", residentScope: "resident").filter { $0.kind == .placed && $0.wishID == placeJob.id }.count == 1, "confirmed placement emits exactly one same-task fact for Rust delivery")
        do { _ = try placementCoordinator.recordPlacementCompletion(worldID: "world", residentScope: "resident", objectID: placeJob.objectID, requestID: "placement.other", surfaceID: "resident.display_table", target: explicitTarget); fatalError("FAIL: foreign request id recorded") } catch { count += 1 }
        let placedReload = WishMachineCoordinator(store: placementStore, directory: dir.appendingPathComponent("placement-wishes"), canClaim: { _ in nil })
        check(placedReload.placementDelegations(worldID: "world", residentScope: "resident").first?.state == .placed, "placement completion survives restart")
        // Crash between durable placement and completion record: replay cannot duplicate or corrupt.
        let crashFile = dir.appendingPathComponent("placement-wishes").appendingPathComponent("wishes.json")
        var crashArchive = try JSONSerialization.jsonObject(with: Data(contentsOf: crashFile)) as! [String: Any]
        var crashDelegations = crashArchive["delegations"] as! [[String: Any]]
        crashDelegations[0]["state"] = "pending"
        crashArchive["delegations"] = crashDelegations
        try JSONSerialization.data(withJSONObject: crashArchive).write(to: crashFile, options: .atomic)
        let crashReload = WishMachineCoordinator(store: placementStore, directory: dir.appendingPathComponent("placement-wishes"), canClaim: { _ in nil })
        check(crashReload.placementDelegations(worldID: "world", residentScope: "resident").first?.state == .pending, "crash left coordinator archive pending")
        let replayGrant = try crashReload.recordPlacementCompletion(worldID: "world", residentScope: "resident", objectID: placeJob.objectID,
            requestID: bound[0].requestID, surfaceID: "resident.display_table", target: explicitTarget)
        check(replayGrant.state == .placed, "post-crash completion replay marks placed without duplication")
        // Dynamic bridge resolve: surface-only grants bind the model-chosen absolute target before effect.
        let resolveProps = dir.appendingPathComponent("resolve-props"), resolveWishes = dir.appendingPathComponent("resolve-wishes")
        let resolveStore = fixtureWishStore(directory: resolveProps, session: URLSession(configuration: config))
        try resolveStore.configure(endpoint: URL(string: "http://127.0.0.1:8191")!, token: "fixture")
        let resolveCoordinator = WishMachineCoordinator(store: resolveStore, directory: resolveWishes, canClaim: { _ in claimEvidence })
        let resolveGrant = UUID()
        try resolveCoordinator.authorize(attachments: [attachment], worldID: "world", residentScope: "resident", authorizationID: resolveGrant, source: .init(author: "user", license: "internal"))
        _ = try resolveCoordinator.authorizePlacement(authorizationID: resolveGrant, worldID: "world", residentScope: "resident", allowedSurfaceIDs: ["resident.display_table"])
        let resolveJob = try await resolveCoordinator.submitSettled(requestID: "resolve-call", authorizationID: resolveGrant, attachmentID: attachment.id,
            name: "plate", heightMeters: 0.2, worldID: "world", residentScope: "resident")
        let targetA = WishPlacementTarget(surfaceID: "resident.display_table", position: .init(x: 0.1, y: 0.52, z: -2.3), yaw: 0.7)
        do { _ = try resolveCoordinator.resolvePlacementGrant(worldID: "world", residentScope: "resident", objectID: resolveJob.objectID, surfaceID: "resident.display_table", target: targetA); fatalError("FAIL: unclaimed resolve granted") } catch { count += 1 }
        _ = try await resolveCoordinator.refresh(id: resolveJob.id, worldID: "world", residentScope: "resident")
        _ = try resolveCoordinator.claim(id: resolveJob.id, worldID: "world", residentScope: "resident")
        let resolvedA = try resolveCoordinator.resolvePlacementGrant(worldID: "world", residentScope: "resident", objectID: resolveJob.objectID, surfaceID: "resident.display_table", target: targetA)
        check(resolvedA.state == .pending && resolvedA.boundTarget == targetA, "surface-only resolve binds selected absolute target")
        let resolveReload = WishMachineCoordinator(store: resolveStore, directory: resolveWishes, canClaim: { _ in claimEvidence })
        check(resolveReload.placementDelegations(worldID: "world", residentScope: "resident").first?.boundTarget == targetA, "bound target persists before effect for crash replay")
        let targetB = WishPlacementTarget(surfaceID: "resident.display_table", position: .init(x: 1, y: 0.52, z: -4), yaw: 0)
        _ = try resolveReload.resolvePlacementGrant(worldID: "world", residentScope: "resident", objectID: resolveJob.objectID, surfaceID: "resident.display_table", target: targetB)
        check(resolveReload.placementDelegations(worldID: "world", residentScope: "resident").first?.boundTarget == targetB, "invalid candidate never locks out a later legal spot")
        let resolveRequestID = resolveReload.placementDelegations(worldID: "world", residentScope: "resident").first!.requestID
        do { _ = try resolveReload.recordPlacementCompletion(worldID: "world", residentScope: "resident", objectID: resolveJob.objectID, requestID: resolveRequestID, surfaceID: "resident.display_table", target: targetA); fatalError("FAIL: stale target completed") } catch { count += 1 }
        check(try resolveReload.recordPlacementCompletion(worldID: "world", residentScope: "resident", objectID: resolveJob.objectID, requestID: resolveRequestID, surfaceID: "resident.display_table", target: targetB).state == .placed, "surface-only completion records the selected transform")
        // Canonical float comparison accepts decimal targets round-tripped through Float.
        let decimalGrant = UUID()
        try resolveCoordinator.authorize(attachments: [attachment], worldID: "world", residentScope: "resident", authorizationID: decimalGrant, source: .init(author: "user", license: "internal"))
        let decimalTarget = WishPlacementTarget(surfaceID: "resident.display_table", position: .init(x: 0.1, y: 0.52, z: -2.3), yaw: 0.7)
        _ = try resolveCoordinator.authorizePlacement(authorizationID: decimalGrant, worldID: "world", residentScope: "resident", allowedSurfaceIDs: ["resident.display_table"], explicitTarget: decimalTarget)
        let decimalJob = try await resolveCoordinator.submitSettled(requestID: "decimal-call", authorizationID: decimalGrant, attachmentID: attachment.id,
            name: "saucer", heightMeters: 0.1, worldID: "world", residentScope: "resident")
        _ = try await resolveCoordinator.refresh(id: decimalJob.id, worldID: "world", residentScope: "resident")
        _ = try resolveCoordinator.claim(id: decimalJob.id, worldID: "world", residentScope: "resident")
        let floatRoundTrip = WishPlacementTarget(surfaceID: "resident.display_table",
            position: .init(x: Double(Float(0.1)), y: Double(Float(0.52)), z: Double(Float(-2.3))), yaw: Double(Float(0.7)))
        _ = try resolveCoordinator.validatePlacementCommand(worldID: "world", residentScope: "resident", objectID: decimalJob.objectID, surfaceID: "resident.display_table", target: floatRoundTrip)
        _ = try resolveCoordinator.recordPlacementCompletion(worldID: "world", residentScope: "resident", objectID: decimalJob.objectID,
            requestID: resolveCoordinator.placementDelegations(worldID: "world", residentScope: "resident").first { $0.authorizationID == decimalGrant }!.requestID,
            surfaceID: "resident.display_table", target: floatRoundTrip)
        // No legal spot: host records failure; item stays in inventory; only fresh human instruction retries.
        let failedGrant = UUID()
        try placementCoordinator.authorize(attachments: [attachment], worldID: "world", residentScope: "resident", authorizationID: failedGrant, source: .init(author: "user", license: "internal"))
        _ = try placementCoordinator.authorizePlacement(authorizationID: failedGrant, worldID: "world", residentScope: "resident", allowedSurfaceIDs: ["nowhere"])
        let failedJob = try await placementCoordinator.submitSettled(requestID: "failed-call", authorizationID: failedGrant, attachmentID: attachment.id,
            name: "lamp", heightMeters: 0.3, worldID: "world", residentScope: "resident")
        try placementCoordinator.markPlacementFailed(worldID: "world", residentScope: "resident", objectID: failedJob.objectID, reason: "没有找到合法落点，物件保留在库存，等待新的摆放委托。")
        let failedDelegation = placementCoordinator.placementDelegations(worldID: "world", residentScope: "resident").first { $0.authorizationID == failedGrant }!
        check(failedDelegation.state == .failed && (failedDelegation.lastError ?? "").contains("保留在库存"), "no legal spot fails delegation and keeps inventory")
        do { _ = try placementCoordinator.validatePlacementCommand(worldID: "world", residentScope: "resident", objectID: failedJob.objectID, surfaceID: "nowhere", target: nil); fatalError("FAIL: failed delegation validated") } catch { count += 1 }
        // Stop revokes incomplete delegation persistently; restart and world switch never revive it.
        let stopGrant = UUID()
        try placementCoordinator.authorize(attachments: [attachment], worldID: "world", residentScope: "resident", authorizationID: stopGrant, source: .init(author: "user", license: "internal"))
        _ = try placementCoordinator.authorizePlacement(authorizationID: stopGrant, worldID: "world", residentScope: "resident", allowedSurfaceIDs: ["resident.display_table"])
        let stopJob = try await placementCoordinator.submitSettled(requestID: "stop-call", authorizationID: stopGrant, attachmentID: attachment.id,
            name: "vase", heightMeters: 0.3, worldID: "world", residentScope: "resident")
        check(placementCoordinator.placementDelegations(worldID: "world", residentScope: "resident").first { $0.authorizationID == stopGrant }?.state == .pending, "delegation pending before stop")
        try placementCoordinator.pauseContinuations(worldID: "world", residentScope: "resident")
        let stopDelegation = placementCoordinator.placementDelegations(worldID: "world", residentScope: "resident").first { $0.authorizationID == stopGrant }!
        check(stopDelegation.state == .revoked && stopDelegation.objectID == stopJob.objectID, "stop revokes incomplete delegation")
        do { _ = try placementCoordinator.validatePlacementCommand(worldID: "world", residentScope: "resident", objectID: stopJob.objectID, surfaceID: "resident.display_table", target: nil); fatalError("FAIL: revoked delegation validated") } catch WishMachineError.placementRevoked { count += 1 }
        do { _ = try placementCoordinator.recordPlacementCompletion(worldID: "world", residentScope: "resident", objectID: stopJob.objectID, requestID: stopDelegation.requestID, surfaceID: "resident.display_table", target: nil); fatalError("FAIL: revoked delegation completed") } catch WishMachineError.placementRevoked { count += 1 }
        let stopReload = WishMachineCoordinator(store: placementStore, directory: dir.appendingPathComponent("placement-wishes"), canClaim: { _ in nil })
        check(stopReload.placementDelegations(worldID: "world", residentScope: "resident").first { $0.authorizationID == stopGrant }?.state == .revoked, "revocation persists across restart")
        do { _ = try stopReload.validatePlacementCommand(worldID: "other", residentScope: "resident", objectID: stopJob.objectID, surfaceID: "resident.display_table", target: nil); fatalError("FAIL: cross-world revoked validation") } catch { count += 1 }
        // Binding only after accepted submission.
        let uncertainProps = dir.appendingPathComponent("uncertain-props"), uncertainWishes = dir.appendingPathComponent("uncertain-wishes")
        let uncertainStore = fixtureWishStore(directory: uncertainProps, session: URLSession(configuration: config))
        try uncertainStore.configure(endpoint: URL(string: "http://127.0.0.1:8191")!, token: "fixture")
        let uncertainCoordinator = WishMachineCoordinator(store: uncertainStore, directory: uncertainWishes, canClaim: { _ in nil })
        let uncertainGrant = UUID()
        try uncertainCoordinator.authorize(attachments: [attachment], worldID: "world", residentScope: "resident", authorizationID: uncertainGrant, source: .init(author: "user", license: "internal"))
        _ = try uncertainCoordinator.authorizePlacement(authorizationID: uncertainGrant, worldID: "world", residentScope: "resident", allowedSurfaceIDs: ["resident.display_table"])
        HTTP.state = "completed"; HTTP.loseSubmitResponse = true
        let uncertainJob = try await uncertainCoordinator.submitSettled(requestID: "uncertain-call", authorizationID: uncertainGrant, attachmentID: attachment.id,
            name: "cup", heightMeters: 0.2, worldID: "world", residentScope: "resident")
        check(uncertainJob.stage == .submissionUncertain, "submission result unknown")
        var uncertainDelegation = uncertainCoordinator.placementDelegations(worldID: "world", residentScope: "resident").first!
        check(uncertainDelegation.objectID == nil && uncertainDelegation.state == .awaitingSubmission, "object identity bound only after accepted submission")
        HTTP.loseSubmitResponse = false
        _ = try await uncertainCoordinator.retry(id: uncertainJob.id, worldID: "world", residentScope: "resident")
        _ = try await uncertainCoordinator.settle(uncertainCoordinator.read(id: uncertainJob.id, worldID: "world", residentScope: "resident"))
        uncertainDelegation = uncertainCoordinator.placementDelegations(worldID: "world", residentScope: "resident").first!
        check(uncertainDelegation.objectID == uncertainJob.objectID && uncertainDelegation.state == .pending, "accepted confirmation binds delegation object identity")
        // Tool-carried structured destination.
        let toolProps = dir.appendingPathComponent("tool-props"), toolWishes = dir.appendingPathComponent("tool-wishes")
        let toolStore = fixtureWishStore(directory: toolProps, session: URLSession(configuration: config))
        try toolStore.configure(endpoint: URL(string: "http://127.0.0.1:8191")!, token: "fixture")
        let toolCoordinator = WishMachineCoordinator(store: toolStore, directory: toolWishes, canClaim: { _ in nil })
        try toolCoordinator.registerImages([attachment], worldID: "world", residentScope: "resident", conversationID: "conv")
        let toolGrant = UUID()
        try toolCoordinator.authorize(registeredImageIDs: [attachment.id], worldID: "world", residentScope: "resident", conversationID: "conv", authorizationID: toolGrant, source: .init(author: "user", license: "internal"))
        let toolBridge = ResidentWishMachineTools(coordinator: toolCoordinator, worldID: "world", residentScope: "resident", authorizationID: toolGrant, isCurrent: { true }).tools
        let submitTool = toolBridge.first { $0.name == "submit_wish_generation" }!
        check(!(submitTool.inputSchema["required"] as! [String]).contains("destination"), "generation schema does not require placement authorization")
        let generationOnly: [String: Any] = ["attachment_id": attachment.id.uuidString, "name": "statue", "height_meters": 0.42]
        check(submitTool.validate(generationOnly), "generation without placement remains valid")
        for invalid in ["table" as Any, ["surface_ids": ["resident.display_table"], "position": "table"],
                        ["surface_ids": ["resident.display_table"], "unexpected": true]] {
            var arguments = generationOnly; arguments["destination"] = invalid
            check(!submitTool.validate(arguments), "malformed destination cannot silently discard user placement")
        }
        let destinationArguments = try JSONSerialization.data(withJSONObject: ["attachment_id": attachment.id.uuidString, "name": "statue", "height_meters": 0.42,
            "destination": ["surface_ids": ["resident.display_table"], "position": ["surface_id": "resident.display_table", "x": -2.7, "y": 0.52, "z": -5, "yaw": 0.25]]])
        check(submitTool.validate(try JSONSerialization.jsonObject(with: destinationArguments) as! [String: Any]), "destination arguments validate")
        check(!submitTool.validate(["attachment_id": attachment.id.uuidString, "name": "statue", "height_meters": 0.42, "destination": ["surface_ids": ["resident.display_table"], "position": ["surface_id": "elsewhere", "x": 0, "y": 0, "z": 0, "yaw": 0]]]), "explicit target must use allowed surface")
        let submitResult = await submitTool.handle("dest-submit", destinationArguments)
        check(!submitResult.isError, "destination submission accepted")
        let acceptedPayload = try JSONSerialization.jsonObject(with: submitResult.resultJSON) as! [String: Any]
        check(acceptedPayload["accepted"] as? Bool == true && acceptedPayload["notification"] as? String == "async_task_events", "tool promises task events instead of provider polling")
        _ = try await toolCoordinator.settle(toolCoordinator.residentJobs(worldID: "world", residentScope: "resident")[0])
        let destinationDelegation = toolCoordinator.placementDelegations(worldID: "world", residentScope: "resident").first!
        check(destinationDelegation.allowedSurfaceIDs == ["resident.display_table"] && destinationDelegation.explicitTarget?.surfaceID == "resident.display_table"
              && destinationDelegation.explicitTarget?.yaw == 0.25 && destinationDelegation.objectID != nil && destinationDelegation.state == .pending, "tool carries structured destination into bound delegation")
        let conflictingResult = await submitTool.handle("dest-conflict", try JSONSerialization.data(withJSONObject: ["attachment_id": attachment.id.uuidString, "name": "statue", "height_meters": 0.42, "destination": ["surface_ids": ["resident.floor"]]]))
        check(conflictingResult.isError && toolCoordinator.placementDelegations(worldID: "world", residentScope: "resident").first?.allowedSurfaceIDs == ["resident.display_table"], "replay with different destination rejected without changing grant")
        let backgroundTools = ResidentWishMachineTools(coordinator: toolCoordinator, worldID: "world", residentScope: "resident", authorizationID: nil, isCurrent: { true }).tools
        let backgroundResult = await backgroundTools.first { $0.name == "submit_wish_generation" }!.handle("bg-dest", destinationArguments)
        check(backgroundResult.isError && toolCoordinator.placementDelegations(worldID: "world", residentScope: "resident").count == 1, "background cannot create destination grants")
        let rejectedDirectory = dir.appendingPathComponent("rejected-daemon")
        let rejectedDaemon = WishMachineDaemonFixture(directory: rejectedDirectory, session: URLSession(configuration: config))
        rejectedDaemon.rejectSubmit = true
        let rejectedStore = PropGenerationStore(directory: rejectedDirectory, daemonClient: rejectedDaemon)
        try rejectedStore.configure(endpoint: URL(string: "http://127.0.0.1:8191")!, token: "fixture")
        let rejectedCoordinator = WishMachineCoordinator(store: rejectedStore, directory: dir.appendingPathComponent("rejected-wishes"), canClaim: { _ in nil })
        let rejectedGrant = UUID()
        try rejectedCoordinator.authorize(attachments: [attachment], worldID: "world", residentScope: "resident", authorizationID: rejectedGrant, source: .init(author: "user", license: "test"))
        let rejectedTool = ResidentWishMachineTools(coordinator: rejectedCoordinator, worldID: "world", residentScope: "resident", authorizationID: rejectedGrant, isCurrent: { true }).tools.first { $0.name == "submit_wish_generation" }!
        let rejectedResult = await rejectedTool.handle("missing-local-ack", try JSONSerialization.data(withJSONObject: generationOnly))
        let rejectedPayload = try JSONSerialization.jsonObject(with: rejectedResult.resultJSON) as! [String: Any]
        check(rejectedPayload["accepted"] as? Bool == false && rejectedPayload["stage"] as? String == "submissionUncertain", "missing daemon ACK never claims durable queue acceptance")
        check(rejectedPayload["wish_id"] != nil && rejectedCoordinator.residentJobs(worldID: "world", residentScope: "resident").count == 1, "unconfirmed local handoff retains one retryable task identity")
        // Explicit foreground authorization revives only this existing wish's follow-through.
        let resumeJob = toolCoordinator.residentJobs(worldID: "world", residentScope: "resident")[0]
        let resumeArguments: [String: Any] = ["wish_id": resumeJob.id.uuidString, "confirm_resume": true]
        let resumeData = try JSONSerialization.data(withJSONObject: resumeArguments)
        try toolCoordinator.pauseContinuations(worldID: "world", residentScope: "resident")
        let stoppedDestination = toolCoordinator.placementDelegation(worldID: "world", residentScope: "resident", objectID: resumeJob.objectID)!
        let requestCountBeforeResume = HTTP.requests.count
        func resumeTool(_ coordinator: WishMachineCoordinator, grant: UUID?, world: String = "world", resident: String = "resident", current: Bool = true,
                        placed: Bool? = nil) -> ResidentWorldToolSession.AdditionalTool {
            ResidentWishMachineTools(coordinator: coordinator, worldID: world, residentScope: resident, authorizationID: nil,
                isCurrent: { current }, continuationResumeAuthorizationID: grant, resumePlacementStatus: { _ in placed }).tools.first { $0.name == "resume_wish_continuation" }!
        }
        check((await resumeTool(toolCoordinator, grant: nil).handle("background-resume", resumeData)).isError, "background cannot manufacture a human resume grant")
        let resumeGrant = UUID(), approvedResume = resumeTool(toolCoordinator, grant: resumeGrant)
        for malformed in [["wish_id": resumeJob.id.uuidString] as [String: Any],
                          ["wish_id": resumeJob.id.uuidString, "confirm_resume": false],
                          ["wish_id": resumeJob.id.uuidString, "confirm_resume": 1],
                          ["wish_id": resumeJob.id.uuidString, "confirm_resume": true, "surface_id": "elsewhere"]] {
            check(!approvedResume.validate(malformed), "resume requires explicit boolean confirmation and cannot change destination")
        }
        check((await resumeTool(toolCoordinator, grant: UUID(), world: "other").handle("wrong-world", resumeData)).isError,
              "resume cannot cross world scope")
        check((await resumeTool(toolCoordinator, grant: UUID(), resident: "other").handle("wrong-resident", resumeData)).isError,
              "resume cannot cross resident scope")
        check((await resumeTool(toolCoordinator, grant: UUID(), current: false).handle("stale-resume", resumeData)).isError,
              "stopped tool lease cannot resume its old wish")
        var resumeChanges = 0
        toolCoordinator.onChange = { resumeChanges += 1 }
        let resumeResult = await approvedResume.handle("resume-existing", resumeData)
        let resumePayload = try JSONSerialization.jsonObject(with: resumeResult.resultJSON) as! [String: Any]
        let resumedJob = try toolCoordinator.read(id: resumeJob.id, worldID: "world", residentScope: "resident")
        let resumedDestination = toolCoordinator.placementDelegation(worldID: "world", residentScope: "resident", objectID: resumeJob.objectID)!
        check(!resumeResult.isError && resumePayload["continuation_resumed"] as? Bool == true
            && resumePayload["auto_continuation_paused"] as? Bool == false, "formal resume returns persisted wish permission, not a model intention")
        check(resumedJob.id == resumeJob.id && resumedJob.jobID == resumeJob.jobID && resumedJob.objectID == resumeJob.objectID
            && resumedJob.stage == resumeJob.stage && resumedJob.modelPath == resumeJob.modelPath, "resume preserves task asset and backend identity")
        check(resumedDestination.state == .pending && resumedDestination.requestID == stoppedDestination.requestID
            && resumedDestination.authorizationID == stoppedDestination.authorizationID && resumedDestination.allowedSurfaceIDs == stoppedDestination.allowedSurfaceIDs
            && resumedDestination.explicitTarget == stoppedDestination.explicitTarget, "resume restores only the original destination delegation")
        let resumeEvents = toolCoordinator.automaticContinuationEvents(worldID: "world", residentScope: "resident").filter { $0.continuationResumeAuthorizationID == resumeGrant }
        check(resumeEvents.count == 1 && resumeEvents[0].autoContinuationPaused == false, "one durable resume fact grants one trusted continuation")
        check(!(await approvedResume.handle("resume-replay", resumeData)).isError && resumeChanges == 1,
              "repeated authorized resume returns the same state without another write or event")
        check(HTTP.requests.count == requestCountBeforeResume, "resume never contacts generation service or downloads again")
        toolCoordinator.onChange = nil
        let resumedReload = WishMachineCoordinator(store: toolStore, directory: toolWishes, canClaim: { _ in nil })
        check(try resumedReload.read(id: resumeJob.id, worldID: "world", residentScope: "resident").autoContinuationPaused == false
            && resumedReload.unpublishedEvents(worldID: "world", residentScope: "resident").contains { $0.id == resumeEvents[0].id }, "resume permission and event identity survive restart")
        try resumedReload.pauseContinuations(worldID: "world", residentScope: "resident")
        check((await resumeTool(resumedReload, grant: resumeGrant).handle("stale-authorization", resumeData)).isError,
              "a new stop cannot be undone by replaying an already consumed resume authorization")
        let secondResumeGrant = UUID()
        check(!(await resumeTool(resumedReload, grant: secondResumeGrant).handle("new-user-resume", resumeData)).isError,
              "new explicit human authorization can resume after a real stop")
        check(resumedReload.automaticContinuationEvents(worldID: "world", residentScope: "resident").compactMap(\.continuationResumeAuthorizationID) == [secondResumeGrant],
              "renewing authorization cannot reactivate an older unconsumed resume event")
        try resumedReload.pauseContinuations(worldID: "world", residentScope: "resident")
        check((await resumeTool(resumedReload, grant: resumeGrant).handle("older-authorization", resumeData)).isError,
              "older resume authorization cannot be reused after an intervening authorization")
        let resumeBlockedDirectory = dir.appendingPathComponent("resume-blocked")
        try FileManager.default.createDirectory(at: resumeBlockedDirectory, withIntermediateDirectories: true)
        try Data(contentsOf: toolWishes.appendingPathComponent("wishes.json")).write(to: resumeBlockedDirectory.appendingPathComponent("wishes.json"))
        let blockedResume = WishMachineCoordinator(store: toolStore, directory: resumeBlockedDirectory, canClaim: { _ in nil })
        let resumeBackupDirectory = dir.appendingPathComponent("resume-backup")
        try FileManager.default.moveItem(at: resumeBlockedDirectory, to: resumeBackupDirectory)
        try Data("fixture blocker".utf8).write(to: resumeBlockedDirectory)
        var blockedResumeChanges = 0
        blockedResume.onChange = { blockedResumeChanges += 1 }
        check((await resumeTool(blockedResume, grant: UUID()).handle("cannot-persist", resumeData)).isError
            && blockedResumeChanges == 0 && blockedResume.jobs.first?.autoContinuationPaused == true, "failed persistence never authorizes continuation in memory or reports success")
        let blockedResumeReload = WishMachineCoordinator(store: toolStore, directory: resumeBackupDirectory, canClaim: { _ in nil })
        check(try blockedResumeReload.read(id: resumeJob.id, worldID: "world", residentScope: "resident").autoContinuationPaused == true,
              "failed resume leaves durable permission paused after restart")
        let preparedFailureDirectory = dir.appendingPathComponent("resume-prepared-failure")
        try FileManager.default.createDirectory(at: preparedFailureDirectory, withIntermediateDirectories: true)
        let preparedArchiveURL = preparedFailureDirectory.appendingPathComponent("wishes.json")
        try Data(contentsOf: resumeBackupDirectory.appendingPathComponent("wishes.json")).write(to: preparedArchiveURL)
        let archiveManager = ArchivePermissionFailure()
        let preparedFailure = WishMachineCoordinator(store: toolStore, directory: preparedFailureDirectory,
            archiveFileManager: archiveManager, canClaim: { _ in nil })
        let durableBeforePermissionFailure = try Data(contentsOf: preparedArchiveURL)
        archiveManager.failPermissions = true
        check((await resumeTool(preparedFailure, grant: UUID()).handle("prepared-permission-failure", resumeData)).isError,
              "archive permission preparation failure is reported")
        let durableAfterPermissionFailure = try Data(contentsOf: preparedArchiveURL)
        check(archiveManager.preparedArchiveObserved && durableAfterPermissionFailure == durableBeforePermissionFailure,
              "a prepared archive permission failure cannot change the previously committed pause grant")
        check(try FileManager.default.contentsOfDirectory(atPath: preparedFailureDirectory.path) == ["wishes.json"],
              "failed pre-commit archive preparation removes only its temporary file")
        let preparedFailureReload = WishMachineCoordinator(store: toolStore, directory: preparedFailureDirectory, canClaim: { _ in nil })
        check(try preparedFailureReload.read(id: resumeJob.id, worldID: "world", residentScope: "resident").autoContinuationPaused == true,
              "restart after permission preparation failure keeps the old pause")
        HTTP.state = "completed"
        let claimedResume = WishMachineCoordinator(store: toolStore, directory: toolWishes, canClaim: { _ in
            .init(worldID: "world", activityID: "wish_machine.collect", phase: "loop", distanceMeters: 0.1, outputAvailable: true)
        })
        await claimedResume.refreshPending(limit: 1)
        _ = try claimedResume.claim(id: resumeJob.id, worldID: "world", residentScope: "resident")
        check((await resumeTool(claimedResume, grant: UUID(), placed: nil).handle("unverified-owned", resumeData)).isError,
              "claimed output cannot resume placement without a real host ownership readback")
        check((await resumeTool(claimedResume, grant: UUID(), placed: true).handle("already-placed", resumeData)).isError,
              "already manually placed output never restores automatic duplicate placement")
        check(!(await resumeTool(claimedResume, grant: UUID(), placed: false).handle("verified-unplaced", resumeData)).isError,
              "verified owned and unplaced item may resume its original revoked destination")
        try claimedResume.markPlacementFailed(worldID: "world", residentScope: "resident", objectID: resumeJob.objectID, reason: "fixture no legal spot")
        try claimedResume.pauseContinuations(worldID: "world", residentScope: "resident")
        check((await resumeTool(claimedResume, grant: UUID(), placed: false).handle("failed-placement", resumeData)).isError,
              "resume cannot turn a failed placement into an automatic retry")
        let resumeTerminalArchive = try JSONSerialization.jsonObject(with: Data(contentsOf: resumeBackupDirectory.appendingPathComponent("wishes.json"))) as! [String: Any]
        for (stage, remote, cancellationRequested) in [("failed", "failed", false), ("cancelled", "cancelled", false),
                                                     ("interrupted", "interrupted", false), ("generating", "running", true),
                                                     ("generating", "cancel_requested", false)] {
            var archive = resumeTerminalArchive
            var archiveJobs = archive["jobs"] as! [[String: Any]]
            archiveJobs[0]["stage"] = stage
            archiveJobs[0]["remoteState"] = remote
            archiveJobs[0]["cancelRequested"] = cancellationRequested
            archive["jobs"] = archiveJobs
            let terminalDirectory = dir.appendingPathComponent("resume-terminal-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: terminalDirectory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: archive).write(to: terminalDirectory.appendingPathComponent("wishes.json"))
            // Keep the persisted terminal snapshot isolated from another fixture's ready task.
            let terminalStore = fixtureWishStore(directory: terminalDirectory.appendingPathComponent("core"), session: URLSession(configuration: config))
            let terminalResume = WishMachineCoordinator(store: terminalStore, directory: terminalDirectory, canClaim: { _ in nil })
            check((await resumeTool(terminalResume, grant: UUID()).handle("terminal-" + remote, resumeData)).isError
              && terminalResume.jobs.first?.autoContinuationPaused == true, "resume cannot reopen terminal or cancelling work: " + remote)
        }
        HTTP.state = "queued"; HTTP.holdSubmit = true; HTTP.heldSubmit = nil
        let lateReceiptStore = fixtureWishStore(directory: dir.appendingPathComponent("late-receipt-core"), session: URLSession(configuration: config))
        try lateReceiptStore.configure(endpoint: URL(string: "http://127.0.0.1:8191")!, token: "fixture")
        let lateReceiptCoordinator = WishMachineCoordinator(store: lateReceiptStore, directory: dir.appendingPathComponent("late-receipt-wishes"), canClaim: { _ in nil })
        let lateReceiptGrant = UUID()
        try lateReceiptCoordinator.authorize(attachments: [attachment], worldID: "world", residentScope: "resident", authorizationID: lateReceiptGrant,
            source: .init(author: "user", license: "test"))
        let lateReceiptJob = try await lateReceiptCoordinator.submit(requestID: "pause-before-remote-receipt", authorizationID: lateReceiptGrant,
            attachmentID: attachment.id, name: "late receipt", heightMeters: 0.42, worldID: "world", residentScope: "resident",
            destination: .init(surfaceIDs: ["resident.display_table"], explicitTarget: nil))
        for _ in 0..<100000 { if HTTP.heldSubmit != nil { break }; await Task.yield() }
        check(HTTP.heldSubmit != nil, "late-receipt fixture holds remote acknowledgement")
        try lateReceiptCoordinator.pauseContinuations(worldID: "world", residentScope: "resident")
        HTTP.holdSubmit = false
        HTTP.heldSubmit?.startLoading(); HTTP.heldSubmit = nil
        _ = try await lateReceiptCoordinator.settle(lateReceiptJob)
        let lateBound = lateReceiptCoordinator.placementDelegation(worldID: "world", residentScope: "resident", objectID: lateReceiptJob.objectID)
        check(lateBound?.state == .revoked && lateReceiptCoordinator.jobs.first?.autoContinuationPaused == true,
              "a late backend acknowledgement cannot revive a placement stopped before receipt")
        let lateResumeData = try JSONSerialization.data(withJSONObject: ["wish_id": lateReceiptJob.id.uuidString, "confirm_resume": true])
        check(!(await resumeTool(lateReceiptCoordinator, grant: UUID()).handle("explicit-late-resume", lateResumeData)).isError
            && lateReceiptCoordinator.placementDelegation(worldID: "world", residentScope: "resident", objectID: lateReceiptJob.objectID)?.state == .pending,
              "only new explicit authorization restores a late-bound revoked placement")
        // ── 定因回归：只有"用户按过停止"才是用户意图 ─────────────────────────
        // 真机 2026-10-01：许愿任务行出现「[自主行动已停止] (恢复自动领取)」+ `network_unavailable`，
        // 而用户从没按过停止。旧接线把这条**持久、只能人工解除**的暂停挂在了循环的
        // 通用取消通道上（换空间/退出/自主可用性回收/网络抖动都会走），于是"网络失败"
        // 变成了"永久暂停 + 要求人工恢复"。这里注入那条旧路径会留下的档案：有暂停、
        // 没有任何用户意图证据，并且守护进程侧就是网络类未知提交。把它退回去就会 FAIL。
        let legacyProps = dir.appendingPathComponent("legacy-pause-props")
        let legacyWishes = dir.appendingPathComponent("legacy-pause-wishes")
        let legacyStore = fixtureWishStore(directory: legacyProps, session: URLSession(configuration: config))
        try legacyStore.configure(endpoint: URL(string: "http://127.0.0.1:8191")!, token: "fixture")
        let legacySource = WishMachineCoordinator(store: legacyStore, directory: legacyWishes, canClaim: { _ in nil })
        let legacyGrant = UUID()
        try legacySource.authorize(attachments: [attachment], worldID: "world", residentScope: "resident",
            authorizationID: legacyGrant, source: .init(author: "user", license: "internal"))
        HTTP.state = "queued"; HTTP.loseSubmitResponse = true
        let unknown = try await legacySource.submitSettled(requestID: "legacy-network-unknown", authorizationID: legacyGrant,
            attachmentID: attachment.id, name: "lamp", heightMeters: 1.5, worldID: "world", residentScope: "resident")
        check(unknown.stage == .submissionUncertain && unknown.lastError == "network_unavailable",
              "the fixture reproduces the real daemon's network-class unknown submission")
        HTTP.loseSubmitResponse = false
        // 注入旧行为：持久暂停（无用户意图证据）。旧代码就是这么留下的。
        let legacyArchiveURL = legacyWishes.appendingPathComponent("wishes.json")
        var legacyArchive = try JSONSerialization.jsonObject(with: Data(contentsOf: legacyArchiveURL)) as! [String: Any]
        var legacyJobs = legacyArchive["jobs"] as! [[String: Any]]
        legacyJobs[0]["autoContinuationPaused"] = true
        legacyJobs[0].removeValue(forKey: "autoContinuationStoppedByUser")
        legacyArchive["jobs"] = legacyJobs
        try JSONSerialization.data(withJSONObject: legacyArchive).write(to: legacyArchiveURL, options: .atomic)
        let selfHealedStore = fixtureWishStore(directory: legacyProps, session: URLSession(configuration: config))
        try selfHealedStore.configure(endpoint: URL(string: "http://127.0.0.1:8191")!, token: "fixture")
        let selfHealed = WishMachineCoordinator(store: selfHealedStore, directory: legacyWishes, canClaim: { _ in nil })
        check(selfHealed.jobs.first?.autoContinuationPaused == true, "the injected legacy pause is really on disk")
        await selfHealed.refreshPending()
        check(selfHealed.jobs.first?.autoContinuationPaused != true,
              "a network-class unknown submission must never keep a pause only a human can clear")
        check(selfHealed.jobs.first?.autoContinuationStoppedByUser != true,
              "no user-intent provenance is invented while self-healing")
        check(selfHealed.jobs.contains { $0.autoContinuationPaused == false }
              && selfHealed.pendingEvents(worldID: "world", residentScope: "resident")
                  .contains { $0.autoContinuationPaused == false && $0.message?.contains("不需要手动解除") == true },
              "the automatic release is a durable, visible fact rather than a silent flag flip")
        for _ in 0..<200 { if selfHealed.jobs.first?.lastError != "network_unavailable" { break }; await Task.yield() }
        check(selfHealed.jobs.first?.lastError != "network_unavailable",
              "network_unavailable disappears once the backend is healthy again")
        // 非网络类的真实结果绝不自动重发：认证失败是**结论**，不是"未知"。
        var blockedArchive = try JSONSerialization.jsonObject(with: Data(contentsOf: legacyArchiveURL)) as! [String: Any]
        var blockedJobs = blockedArchive["jobs"] as! [[String: Any]]
        blockedJobs[0]["lastError"] = "authentication_required"
        blockedJobs[0]["stage"] = "submissionUncertain"
        blockedArchive["jobs"] = blockedJobs
        try JSONSerialization.data(withJSONObject: blockedArchive).write(to: legacyArchiveURL, options: .atomic)
        let blockedStore = fixtureWishStore(directory: legacyProps, session: URLSession(configuration: config))
        try blockedStore.configure(endpoint: URL(string: "http://127.0.0.1:8191")!, token: "fixture")
        let blocked = WishMachineCoordinator(store: blockedStore, directory: legacyWishes, canClaim: { _ in nil })
        let blockedSubmissions = HTTP.requests.filter { $0.url?.path == "/v1/jobs" && $0.httpMethod == "POST" }.count
        await blocked.confirmNetworkUncertainSubmissions()
        check(HTTP.requests.filter { $0.url?.path == "/v1/jobs" && $0.httpMethod == "POST" }.count == blockedSubmissions,
              "a rejected or unauthenticated submission is never silently reissued")
        // 用户**显式**停止仍然是用户意图：自愈不得替用户解除它。
        try selfHealed.pauseContinuations(worldID: "world", residentScope: "resident")
        check(selfHealed.discardPausesWithoutUserIntent() == 0
              && selfHealed.jobs.first?.autoContinuationPaused == true,
              "an explicit user stop survives automatic re-validation")
        let stopReloaded = WishMachineCoordinator(store: selfHealedStore, directory: legacyWishes, canClaim: { _ in nil })
        check(stopReloaded.jobs.first?.autoContinuationPaused == true
              && stopReloaded.jobs.first?.autoContinuationStoppedByUser == true,
              "user-intent provenance is durable across restart")
        await stopReloaded.refreshPending()
        check(stopReloaded.jobs.first?.autoContinuationPaused == true
              && stopReloaded.automaticContinuationEvents(worldID: "world", residentScope: "resident").isEmpty,
              "a real user stop still needs its own explicit release and grants no continuation")

        print("PASS: \(count) wish machine coordinator checks")
    }
}
"""#
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("wish-machine-test-" + UUID().uuidString)
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let checks = tmp.appendingPathComponent("checks.swift"), binary = tmp.appendingPathComponent("checks")
try program.write(to: checks, atomically: true, encoding: .utf8)
let compiler = Process(); compiler.executableURL = URL(fileURLWithPath: "/usr/bin/nice")
compiler.arguments = ["-n", "15", "swiftc", "-j1", "-parse-as-library"] + sources.map(\.path) + [checks.path, "-o", binary.path]
try compiler.run(); compiler.waitUntilExit(); guard compiler.terminationStatus == 0 else { exit(compiler.terminationStatus) }
let run = Process(); run.executableURL = binary; try run.run(); run.waitUntilExit(); exit(run.terminationStatus)

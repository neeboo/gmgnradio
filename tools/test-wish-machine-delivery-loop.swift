// One isolated job: real GLB + real collider + real Metal + production tools.
// The daemon and HTTP are recorded fixtures; this is not a Rust process-lifetime or model test.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sources = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
let products = root.appendingPathComponent("apps/macos/Build/Build/Products/Debug")
let worldBuild = root.appendingPathComponent("apps/macos/Packages/WorldRuntime/.build/arm64-apple-macosx/debug")
let bootstrap = try String(contentsOf: sources.appendingPathComponent("App/LivingWorldBootstrap.swift"), encoding: .utf8)
let collisionStart = bootstrap.range(of: "struct MarbleLivingCabinCollisionWorld:")!.lowerBound
let collisionEnd = bootstrap.range(of: "/// An effect is keyed", range: collisionStart..<bootstrap.endIndex)!.lowerBound
let appSource = try String(contentsOf: sources.appendingPathComponent("App/GMGNRadioApp.swift"), encoding: .utf8)
func declaration(_ signature: String) -> String {
    let start = appSource.range(of: signature)!.lowerBound, open = appSource[start...].firstIndex(of: "{")!
    var depth = 0
    for index in appSource[open...].indices {
        if appSource[index] == "{" { depth += 1 }; if appSource[index] == "}" { depth -= 1 }
        if depth == 0 { return String(appSource[start...index]) }
    }
    fatalError("unterminated production recovery method")
}
let recovery = ["private func reconcileResidentWishPlacements(", "private func residentWishPlacementGrant(",
    "private func recordResidentWishPlacement("].map(declaration).joined(separator: "\n")
let program = #"""
import Foundation
import CryptoKit
import Metal
import WorldRuntime
import simd
import ImageIO
import UniformTypeIdentifiers
struct ResidentImageAttachment: Identifiable, Codable, Sendable, Equatable { let id: UUID; let url: URL; let displayName: String }
struct RealtimeDJToolCall { let id: String; let name: String; let argumentsJSON: Data }
struct RealtimeDJToolResult { let callID: String; let resultJSON: Data; let isError: Bool }
@MainActor final class ResidentWorldToolSession {
    struct AdditionalTool {
        let name: String; let description: String; let inputSchema: [String: Any]
        let validate: @MainActor ([String: Any]) -> Bool
        let handle: @MainActor (String, Data) async -> RealtimeDJToolResult
    }
}
\#(bootstrap[collisionStart..<collisionEnd])
struct Config: Decodable { struct Framing: Decodable { let origin: [Float]; let scale: Float }; let framing: Framing }
struct ResidentWorldContext { let worldID: String?; let sessionScope: String }
@MainActor final class RecoveryHost {
    let livingWorldContext: WorldAgentContext?
    let wishMachineCoordinator: WishMachineCoordinator
    var residentOwnedPropAssets: [String: Bool] = [:]
    var selectedScope: ResidentWorldContext
    init(_ context: WorldAgentContext, _ coordinator: WishMachineCoordinator, resident: String) {
        livingWorldContext = context; wishMachineCoordinator = coordinator
        selectedScope = .init(worldID: context.manifest.worldID, sessionScope: resident)
    }
    func currentResidentWorldContext() -> ResidentWorldContext { selectedScope }
    \#(recovery)
    func grant(_ objectID: String, _ placement: WorldPropPlacement, worldID: String, resident: String) throws -> ResidentPropDelegatedGrant {
        try residentWishPlacementGrant(objectID: objectID, placement: placement, worldID: worldID, residentScope: resident)
    }
    func record(_ grant: ResidentPropDelegatedGrant, _ placement: WorldPropPlacement, worldID: String, resident: String) throws {
        try recordResidentWishPlacement(grant, placement: placement, worldID: worldID, residentScope: resident)
    }
    func recover(worldID: String, resident: String) throws {
        try reconcileResidentWishPlacements(.init(worldID: worldID, sessionScope: resident))
    }
}
final class RecordedService: URLProtocol {
    static var receipt: [String: Any] = [:]
    static var model = Data()
    static var complete = false
    static var submissions = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.httpMethod == "POST" { Self.submissions += 1 }
        var value = Self.receipt
        if !Self.complete { value["state"] = "queued"; value.removeValue(forKey: "result") }
        let data = request.url!.path.hasSuffix("model.glb") ? Self.model : try! JSONSerialization.data(withJSONObject: value)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct Delivery {
    @MainActor static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--live" { try await runLive(Array(arguments.dropFirst())) }
        else { try await runRecorded(arguments) }
    }

    @MainActor static func prepareWorld(directory: URL) throws -> (WorldAgentContext, [WorldTriangle], WorldManifest, AtomicJSONWorldStatePersistence) {
        let worldRoot = URL(fileURLWithPath: "apps/macos/Resources/Worlds/marble-living-cabin")
        let manifest = try JSONDecoder().decode(WorldManifest.self, from: Data(contentsOf: worldRoot.appendingPathComponent("world.json")))
        let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: worldRoot.appendingPathComponent("marble.json")))
        let origin = config.framing.origin
        let triangles = try GLBColliderDecoder().decode(data: Data(contentsOf: worldRoot.appendingPathComponent("collider.glb")),
            transform: WorldMeshTransform(axisConversion: .flipYAndZ, origin: SIMD3(origin[0],origin[1],origin[2]), uniformScale: config.framing.scale))
        let physics = MarbleLivingCabinCollisionWorld(environment: TriangleMeshCollisionWorld(triangles: triangles),
            props: CollisionVolumeWorld(volumes: ResidentPropPlacementConfiguration.independentCollisionVolumes(manifest)))
        let persistence = AtomicJSONWorldStatePersistence(fileURL: directory.appendingPathComponent("world.json"))
        let context = try WorldAgentContext(manifest: manifest, persistence: persistence)
        _ = try context.installCollisionWorldAndReconcilePlacement(physics)
        return (context, triangles, manifest, persistence)
    }

    enum ResumeState: Equatable { case fresh, resumable, wishMissingCore, malformed }
    @MainActor static func resumeState(store: PropGenerationStore, coordinator: WishMachineCoordinator,
                                       worldID: String, resident: String) -> ResumeState {
        let wishCount = coordinator.residentJobs(worldID: worldID, residentScope: resident).count
        if store.jobs.isEmpty && wishCount == 0 { return .fresh }
        if store.jobs.count == 1 && wishCount == 1 { return .resumable }
        if store.jobs.isEmpty && wishCount == 1 { return .wishMissingCore }
        return .malformed
    }

    @MainActor static func runRecorded(_ recordedArguments: [String]) async throws {
        func check(_ ok: Bool, _ label: String) { precondition(ok, label) }
        let proof = URL(fileURLWithPath: "tmp/wish-machine-service-proof-20260906/core")
        let record = try JSONDecoder().decode([PropGenerationRecord].self, from: Data(contentsOf: proof.appendingPathComponent("tasks.json")))[0]
        let receipt = record.receipt!
        RecordedService.receipt = try JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as! [String: Any]
        RecordedService.model = try Data(contentsOf: URL(fileURLWithPath: record.localModelPath!))
        let sha = SHA256.hash(data: RecordedService.model).map { String(format: "%02x", $0) }.joined()
        check(sha == receipt.result!.inspection.sha256, "recorded real output matches its service checksum")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-delivery-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (context, triangles, manifest, persistence) = try prepareWorld(directory: directory)
        let sessionConfig = URLSessionConfiguration.ephemeral; sessionConfig.protocolClasses = [RecordedService.self]
        let fixtureSession = URLSession(configuration: sessionConfig)
        let daemon = WishMachineDaemonFixture(directory: directory.appendingPathComponent("core"), session: fixtureSession)
        let store = PropGenerationStore(directory: directory.appendingPathComponent("core"), session: fixtureSession, daemonClient: daemon)
        try store.configure(endpoint: URL(string: "http://127.0.0.1:8191")!, token: "fixture-only")
        let evidenceDirectory = recordedArguments.first.map { URL(fileURLWithPath: $0) }
        if let evidenceDirectory { try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true) }
        let capturer = FrameCapturer(evidenceDirectory: evidenceDirectory)
        let worldID = manifest.worldID, resident = "isolated-delivery-resident"
        let coordinator = WishMachineCoordinator(store: store, directory: directory.appendingPathComponent("wishes"), canClaim: { job in
            let p = context.snapshot.agentTransform.position, target = WishMachineScene.pickupPosition
            let distance = simd_length(SIMD3(p.x,p.y,p.z) - target)
            return .init(worldID: worldID, activityID: context.snapshot.activeActivity?.id,
                phase: context.snapshot.activeActivity?.phase.rawValue, distanceMeters: Double(distance),
                outputAvailable: capturer.status == .ready(id: job.objectID))
        })
        let service = ResidentPropPlacementService(context: context, surfaces: ResidentPropPlacementConfiguration.surfaces,
            validateEnvironment: { box, y in
                guard WorldPropMeshClearance.canPlace(box, supportHeight: y, triangles: triangles) else { throw ResidentPropPlacementError.collision("mesh") }
            })
        let host = RecoveryHost(context, coordinator, resident: resident)
        var preCompletionJournal: Data?
        let journalURL = directory.appendingPathComponent("wishes/wishes.json")
        // Construct once, before submission and pickup. Its dynamic callbacks
        // must admit only the same claimed and host-registered item later on.
        let delegated = ResidentPropToolBridge(service: service, allowsMutation: false, isCurrent: { true },
            resolveDelegatedGrant: { objectID, placement in
                try host.grant(objectID, placement, worldID: worldID, resident: resident)
            }, recordDelegatedPlacement: { grant, placement in
                preCompletionJournal = try Data(contentsOf: journalURL)
                try host.record(grant, placement, worldID: worldID, resident: resident)
            })
        let attachment = ResidentImageAttachment(id: UUID(), url: URL(fileURLWithPath: record.imagePath), displayName: "coffee.png")
        let authorization = UUID()
        check(Self.resumeState(store: store, coordinator: coordinator, worldID: worldID, resident: resident) == .fresh,
            "submission contract requires a fresh journal before creating a task")
        let intentMarker = directory.appendingPathComponent("submission-intent.json")
        try JSONSerialization.data(withJSONObject: ["authorization_id": authorization.uuidString, "input": "recorded-fixture",
            "created_at": Date().timeIntervalSince1970], options: .sortedKeys).write(to: intentMarker, options: .withoutOverwriting)
        do { try Data("rival".utf8).write(to: intentMarker, options: .withoutOverwriting); check(false, "submission intent marker creation is exclusive") } catch {}
        try coordinator.authorize(attachments: [attachment], worldID: worldID, residentScope: resident,
            authorizationID: authorization, source: record.source)
        let tools = ResidentWishMachineTools(coordinator: coordinator, worldID: worldID, residentScope: resident,
            authorizationID: authorization, isCurrent: { true }).tools
        func invoke(_ name: String, _ id: String, _ arguments: [String: Any]) async throws -> RealtimeDJToolResult {
            let tool = tools.first { $0.name == name }!
            check(tool.validate(arguments), "production schema accepts check command")
            return await tool.handle(id, try JSONSerialization.data(withJSONObject: arguments))
        }
        let submitted = try await invoke("submit_wish_generation", "one-generation", ["attachment_id": attachment.id.uuidString, "name": record.name, "height_meters": 0.42,
            "destination": ["surface_ids": ["resident.display_table"]]])
        check(!submitted.isError, "formal generation tool receives durable queue acceptance")
        for _ in 0..<100000 {
            if RecordedService.submissions == 1 && store.jobs.first?.receipt != nil { break }
            await Task.yield()
        }
        check(RecordedService.submissions == 1, "fake daemon submits exactly one isolated job after queue acceptance")
        check(FileManager.default.fileExists(atPath: intentMarker.path), "submission intent remains durable after acceptance")
        check(Self.resumeState(store: store, coordinator: coordinator, worldID: worldID, resident: resident) == .resumable,
            "exactly one resumable task in coordinator and core journals after submission")
        let job = coordinator.residentJobs(worldID: worldID, residentScope: resident).first!
        RecordedService.complete = true
        await daemon.pushBackendChanges()
        let downloaded = try coordinator.read(id: job.id, worldID: worldID, residentScope: resident)
        check(downloaded.stage == .ready, "daemon push makes the same downloaded job visible without coordinator polling")
        let pushed = coordinator.unpublishedEvents(worldID: worldID, residentScope: resident)
        check(pushed.contains { $0.kind == .outputReady && $0.wishID == job.id }, "download event is a same-task fact awaiting Rust message publication")
        let denied = try await invoke("claim_wish_output", "before-render", ["wish_id": job.id.uuidString])
        check(denied.isError, "download alone never authorizes remote pickup")
        let output = coordinator.readyOutputs(worldID: worldID).first!
        capturer.renderer.update(output, worldID: worldID, isVisible: true)
        var lit = 0
        for _ in 0..<500 {
            lit = await capturer.frame(); await Task.yield()
            if capturer.status == .ready(id: output.id) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        check(lit > 100 && capturer.status == .ready(id: job.objectID), "same GLB is actually drawn before pickup")
        try capturer.saveFrame("01-tray-output-offscreen")
        let dispatcher = WorldAgentToolDispatcher(takeoverEnabled: { true }, context: context)
        let start = await dispatcher.handle(.init(id: "walk-to-tray", name: "start_activity",
            argumentsJSON: try JSONSerialization.data(withJSONObject: ["activity_id": "wish_machine.collect"])))
        check(!start.isError, "production activity tool starts navigation")
        let initialPosition = context.snapshot.agentTransform.position
        for _ in 0..<900 {
            try context.tick(deltaTime: 1.0/30)
            if context.snapshot.activeActivity?.phase == .loop { break }
        }
        check(context.snapshot.agentTransform.position != initialPosition && context.snapshot.activeActivity?.phase == .loop,
            "resident actually advances through collider, without assigning arrival coordinates")
        _ = await capturer.frame()
        try capturer.saveFrame("02-output-at-arrival-offscreen")
        let claim = try await invoke("claim_wish_output", "claim-same-output", ["wish_id": job.id.uuidString])
        check(!claim.isError, "formal claim succeeds only after real arrival and GPU frame")
        let duplicate = try await invoke("claim_wish_output", "claim-replayed", ["wish_id": job.id.uuidString])
        check(!duplicate.isError && coordinator.readyOutputs(worldID: worldID).isEmpty, "duplicate pickup keeps same item out of tray")
        capturer.renderer.update(nil, worldID: worldID, isVisible: true)
        check(await capturer.frame() == 0, "claimed GLB no longer renders on tray")
        try capturer.saveFrame("03-tray-empty-after-claim-offscreen")
        let loaded = try await WishMachineOutputRenderer.Loaded.make(output: output, device: capturer.device, color: .rgba8Unorm, depth: .depth32Float)
        let bounds = loaded.asset.worldBounds, height = bounds.max.y - bounds.min.y
        let size = (bounds.max-bounds.min)*(0.42/height)
        let prop = WorldGeneratedProp(objectID: job.objectID, sourceWishID: job.id.uuidString, assetID: sha,
            displayName: record.name, size: .init(x:size.x,y:size.y,z:size.z), sourceHeight: height)
        try service.commit(.register(prop), expectedLayoutRevision: context.state.layoutRevision, requestID: "register-claimed")
        let surface = service.surfaces.first { $0.id == "resident.display_table" }!
        let placement = WorldPropPlacement(surfaceID: surface.id, position: surface.center, yaw: 0)
        do { _ = try host.grant(job.objectID, placement, worldID: worldID, resident: resident); check(false, "asset absent from host registry accepted") }
        catch WishMachineError.unauthorized {}
        host.residentOwnedPropAssets[job.objectID] = true
        host.selectedScope = .init(worldID: worldID, sessionScope: "another-resident")
        do { _ = try host.grant(job.objectID, placement, worldID: worldID, resident: resident); check(false, "changed resident accepted") }
        catch WishMachineError.unauthorized {}
        host.selectedScope = .init(worldID: worldID, sessionScope: resident)
        let before = context.state
        _ = try service.preview(objectID: job.objectID, placement: placement)
        check(context.state == before, "preview of same claimed object does not persist")
        let apply = delegated.tools.first { $0.name == "apply_prop_placement" }!
        func arguments(_ placement: WorldPropPlacement) throws -> Data {
            try JSONSerialization.data(withJSONObject:["object_id":job.objectID,"surface_id":placement.surfaceID,
                "x":placement.position.x,"y":placement.position.y,"z":placement.position.z,"yaw":placement.yaw,
                "layout_revision":context.state.layoutRevision])
        }
        let placed = await apply.handle("background-placement", try arguments(placement))
        check(!placed.isError, "background resident uses persisted original destination through production placement tool")
        check(coordinator.placementDelegation(worldID:worldID,residentScope:resident,objectID:job.objectID)?.state == .placed,
            "successful world commit records delegation completion")
        let secondBackground = await apply.handle("repeat-background-placement", try arguments(placement))
        check(secondBackground.isError, "completed delegation cannot keep modifying the object")
        // Restore only this test journal's pre-marker checkpoint: this models a
        // crash after the atomic world commit, before the separate wish marker.
        // The production world remains untouched and contains its real receipt.
        try preCompletionJournal!.write(to: journalURL, options: .atomic)
        let recoveryCoordinator = WishMachineCoordinator(store: store, directory: directory.appendingPathComponent("wishes"), canClaim: { _ in nil })
        let recoveredWorld = try WorldAgentContext(manifest: manifest, persistence: persistence)
        check(recoveredWorld.state.layoutReceipts == context.state.layoutReceipts, "world command receipts were loaded from disk")
        check(recoveredWorld.state.objectStates[job.objectID] == context.state.objectStates[job.objectID]
            && recoveredWorld.state.layoutRevision == context.state.layoutRevision, "persisted placement matches before recovery")
        let recoveryHost = RecoveryHost(recoveredWorld, recoveryCoordinator, resident: resident)
        let committedState = recoveredWorld.state
        try recoveryHost.recover(worldID: worldID, resident: resident)
        check(recoveredWorld.state == committedState && recoveryCoordinator.placementDelegation(worldID:worldID,residentScope:resident,objectID:job.objectID)?.state == .placed,
            "production host reconciles the committed receipt after a missed completion marker without moving again")
        try recoveryHost.recover(worldID: worldID, resident: resident)
        check(recoveredWorld.state == committedState, "recovery is idempotent")
        let rotated = WorldPropPlacement(surfaceID: surface.id, position: surface.center, yaw: .pi/4)
        try service.commit(.place(objectID: job.objectID, placement: rotated), expectedLayoutRevision: context.state.layoutRevision, requestID: "rotate-claimed")
        let restored = try WorldAgentContext(manifest: manifest, persistence: persistence)
        check(restored.state.objectStates[job.objectID] == context.state.objectStates[job.objectID], "same object position and rotation survive real JSON reload")
        check(restored.state.objectStates.values.filter { $0.generatedProp != nil }.count == 1 && RecordedService.submissions == 1,
            "generation pickup rotation and reload leave exactly one object")
        if let evidenceDirectory {
            let report: [String:Any] = ["mode":"recorded_service_real_gpu_and_navigation", "liveGeneration":false, "liveModel":false,
                "hostWindow":false, "avatarRendered":false, "wishID":job.id.uuidString, "objectID":job.objectID,
                "recordedRemoteJobID":receipt.id, "sha256":sha, "layoutRevision":context.state.layoutRevision,
                "trayPixels":lit, "storedPropCount":1, "arrivalPhase":context.snapshot.activeActivity?.phase.rawValue ?? "none"]
            try JSONSerialization.data(withJSONObject:report, options:[.prettyPrinted,.sortedKeys]).write(to:evidenceDirectory.appendingPathComponent("receipt.json"), options:.atomic)
            try JSONEncoder().encode(restored.state).write(to:evidenceDirectory.appendingPathComponent("world-readback.json"), options:.atomic)
        }
        print("PASS: recorded single job → real GLB GPU → formal walk over Marble collider → claim → placement → rotation → JSON reload")
        print("EVIDENCE: object=\(job.objectID) sha256=\(sha) layoutRevision=\(context.state.layoutRevision) trayPixels=\(lit); no live model, generation, host or avatar frames")
    }

    @MainActor final class FrameCapturer {
        let device: MTLDevice
        let renderer: WishMachineOutputRenderer
        var status: WishMachineOutputStatus = .empty
        var latestPixels = Data()
        var evidenceDirectory: URL?
        private let queue: MTLCommandQueue
        private let color: MTLTexture
        private let depth: MTLTexture
        private let viewProjection: simd_float4x4
        private let cameraPosition: SIMD3<Float>
        init(evidenceDirectory: URL?) {
            self.evidenceDirectory = evidenceDirectory
            device = MTLCreateSystemDefaultDevice()!
            queue = device.makeCommandQueue()!
            renderer = WishMachineOutputRenderer(device: device, colorFormat: .rgba8Unorm, depthFormat: .depth32Float)
            let colorDescription = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 128, height: 128, mipmapped: false)
            colorDescription.usage = [.renderTarget]; colorDescription.storageMode = .shared
            let depthDescription = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: 128, height: 128, mipmapped: false)
            depthDescription.usage = [.renderTarget]; depthDescription.storageMode = .private
            color = device.makeTexture(descriptor: colorDescription)!
            depth = device.makeTexture(descriptor: depthDescription)!
            let eye = SIMD3<Float>(0.8,0.942,-1.1), f: Float = 1/tan(50 * Float.pi/360), near: Float = 0.05, far: Float = 20
            var projection = simd_float4x4()
            projection.columns = (SIMD4(f,0,0,0),SIMD4(0,f,0,0),SIMD4(0,0,far/(near-far),-1),SIMD4(0,0,far*near/(near-far),0))
            var view = matrix_identity_float4x4; view.columns.3 = SIMD4(-eye,1)
            viewProjection = projection*view
            cameraPosition = eye
            renderer.onStatusChanged = { [weak self] in self?.status = $0 }
        }
        func frame() async -> Int {
            let command = queue.makeCommandBuffer()!, pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = color; pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,1)
            pass.depthAttachment.texture = depth; pass.depthAttachment.loadAction = .clear; pass.depthAttachment.storeAction = .store; pass.depthAttachment.clearDepth = 1
            command.makeRenderCommandEncoder(descriptor: pass)!.endEncoding()
            _ = renderer.render(commandBuffer: command, colorTexture: color, depthTexture: depth, viewProjection: viewProjection,
                cameraPosition: cameraPosition, reversedDepth: false, preservesDepth: true)
            await withCheckedContinuation { (c: CheckedContinuation<Void,Never>) in command.addCompletedHandler { _ in c.resume() }; command.commit() }
            precondition(command.status == .completed, "Metal frame completed")
            var pixels = [UInt8](repeating: 0, count: 128*128*4)
            pixels.withUnsafeMutableBytes { color.getBytes($0.baseAddress!, bytesPerRow: 128*4, from: MTLRegionMake2D(0,0,128,128), mipmapLevel: 0) }
            latestPixels = Data(pixels)
            return stride(from:0,to:pixels.count,by:4).filter { pixels[$0]>3 || pixels[$0+1]>3 || pixels[$0+2]>3 }.count
        }
        func saveFrame(_ name: String) throws {
            guard let evidenceDirectory else { return }
            let image = CGImage(width:128, height:128, bitsPerComponent:8, bitsPerPixel:32, bytesPerRow:128*4,
                space:CGColorSpaceCreateDeviceRGB(), bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.noneSkipLast.rawValue),
                provider:CGDataProvider(data:latestPixels as CFData)!, decode:nil, shouldInterpolate:false, intent:.defaultIntent)!
            let destination = CGImageDestinationCreateWithURL(evidenceDirectory.appendingPathComponent(name + ".png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil)
            precondition(CGImageDestinationFinalize(destination), "offscreen evidence frame saved")
        }
    }

    @MainActor static func runLive(_ arguments: [String]) async throws {
        func check(_ ok: Bool, _ label: String) { precondition(ok, label) }
        var stateDirectoryPath: String?, imagePath: String?, evidencePath: String?
        var pollSeconds = 5.0, deadlineSeconds = 1200.0
        var iterator = arguments.makeIterator()
        while let token = iterator.next() {
            switch token {
            case "--evidence": evidencePath = iterator.next()
            case "--poll-seconds":
                guard let raw = iterator.next(), let value = Double(raw), value.isFinite, value > 0 else {
                    preconditionFailure("--poll-seconds requires a positive finite number")
                }
                pollSeconds = value
            case "--deadline-seconds":
                guard let raw = iterator.next(), let value = Double(raw), value.isFinite, value > 0 else {
                    preconditionFailure("--deadline-seconds requires a positive finite number")
                }
                deadlineSeconds = value
            default:
                if token.hasPrefix("--") { preconditionFailure("unknown flag: \(token)") }
                if stateDirectoryPath == nil { stateDirectoryPath = token }
                else if imagePath == nil { imagePath = token }
                else { preconditionFailure("unexpected argument: \(token)") }
            }
        }
        guard let stateDirectoryPath, let imagePath else { preconditionFailure("usage: --live <stateDir> <imagePath> [--evidence <dir>] [--poll-seconds N] [--deadline-seconds N]") }
        let stateDirectory = URL(fileURLWithPath: stateDirectoryPath)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let evidenceDirectory = evidencePath.map { URL(fileURLWithPath: $0) } ?? stateDirectory.appendingPathComponent("evidence")
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        func liveStatus(_ code: String, _ detail: String, exitCode: Int32) -> Never {
            print("LIVE-STATUS[\(code)]: \(detail)")
            print("RESUME: swift tools/test-wish-machine-delivery-loop.swift --live \(stateDirectoryPath) \(imagePath)")
            exit(exitCode)
        }
        // Credentials load only here, at live execution; the token never leaves memory or prints.
        guard let configuration = try PropGenerationConfigurationStore().load() else {
            preconditionFailure("live mode requires a saved local prop-generation configuration")
        }
        guard let endpointHost = configuration.endpoint.host?.lowercased(),
              ["localhost", "127.0.0.1", "::1"].contains(endpointHost) else {
            preconditionFailure("live mode refuses a non-local saved endpoint")
        }
        let endpointDescription = configuration.endpoint.port.map { "\(endpointHost):\($0)" } ?? endpointHost
        let (context, triangles, manifest, persistence) = try prepareWorld(directory: stateDirectory)
        let store = PropGenerationStore(directory: stateDirectory.appendingPathComponent("core"))
        try store.configure(endpoint: configuration.endpoint, token: configuration.token)
        let capturer = FrameCapturer(evidenceDirectory: evidenceDirectory)
        let worldID = manifest.worldID, resident = "isolated-delivery-resident"
        let coordinator = WishMachineCoordinator(store: store, directory: stateDirectory.appendingPathComponent("wishes"), canClaim: { job in
            let p = context.snapshot.agentTransform.position, target = WishMachineScene.pickupPosition
            let distance = simd_length(SIMD3(p.x,p.y,p.z) - target)
            return .init(worldID: worldID, activityID: context.snapshot.activeActivity?.id,
                phase: context.snapshot.activeActivity?.phase.rawValue, distanceMeters: Double(distance),
                outputAvailable: capturer.status == .ready(id: job.objectID))
        })
        let service = ResidentPropPlacementService(context: context, surfaces: ResidentPropPlacementConfiguration.surfaces,
            validateEnvironment: { box, y in
                guard WorldPropMeshClearance.canPlace(box, supportHeight: y, triangles: triangles) else { throw ResidentPropPlacementError.collision("mesh") }
            })
        let host = RecoveryHost(context, coordinator, resident: resident)
        let delegated = ResidentPropToolBridge(service: service, allowsMutation: false, isCurrent: { true },
            resolveDelegatedGrant: { objectID, placement in
                try host.grant(objectID, placement, worldID: worldID, resident: resident)
            }, recordDelegatedPlacement: { grant, placement in
                try host.record(grant, placement, worldID: worldID, resident: resident)
            })
        // Resume first: a committed-but-unmarked placement completes without moving again.
        try host.recover(worldID: worldID, resident: resident)
        let intentMarker = stateDirectory.appendingPathComponent("submission-intent.json")
        var job: WishMachineJob
        // The facade starts empty: inspect Rust's durable snapshot before deciding
        // whether this isolated run has a resumable task or may create its first one.
        await coordinator.refreshPending(limit: 1)
        if store.errorMessage != nil {
            liveStatus("task-daemon-unavailable", "cannot verify the local task snapshot; refusing a new submission", exitCode: 2)
        }
        switch Self.resumeState(store: store, coordinator: coordinator, worldID: worldID, resident: resident) {
        case .fresh:
            guard !FileManager.default.fileExists(atPath: stateDirectory.appendingPathComponent("core/tasks.json").path),
                  !FileManager.default.fileExists(atPath: stateDirectory.appendingPathComponent("wishes/wishes.json").path) else {
                liveStatus("existing-journal", "a prior submission journal exists without one resumable task; refusing a new submission", exitCode: 2)
            }
            guard FileManager.default.fileExists(atPath: imagePath) else { preconditionFailure("image not found: \(imagePath)") }
            let attachment = ResidentImageAttachment(id: UUID(), url: URL(fileURLWithPath: imagePath), displayName: (imagePath as NSString).lastPathComponent)
            let authorization = UUID()
            // Exclusive submission-intent marker BEFORE any grant or network call. Two simultaneous
            // invocations cannot both create it; it records input identity and never credentials.
            let intent: [String: Any] = ["authorization_id": authorization.uuidString, "image_path": imagePath,
                "name": "live prop", "height_meters": 0.42, "destination_surfaces": ["resident.display_table", "resident.floor"],
                "created_at": Date().timeIntervalSince1970]
            do { try JSONSerialization.data(withJSONObject: intent, options: .sortedKeys).write(to: intentMarker, options: .withoutOverwriting) }
            catch { liveStatus("intent-marker-exists", "an exclusive submission-intent marker exists without a resumable task; refusing a second submission", exitCode: 2) }
            do {
                // Durable grant and job identity precede any network submission.
                try coordinator.authorize(attachments: [attachment], worldID: worldID, residentScope: resident,
                    authorizationID: authorization, source: .init(author: "用户提供", license: "未核验，仅限个人测试"))
                let tools = ResidentWishMachineTools(coordinator: coordinator, worldID: worldID, residentScope: resident,
                    authorizationID: authorization, isCurrent: { true }).tools
                let submitTool = tools.first { $0.name == "submit_wish_generation" }!
                let liveArguments: [String: Any] = ["attachment_id": attachment.id.uuidString, "name": "live prop", "height_meters": 0.42,
                    "destination": ["surface_ids": ["resident.display_table", "resident.floor"]]]
                check(submitTool.validate(liveArguments), "live submit arguments match production schema")
                let submitted = await submitTool.handle("one-live-generation", try JSONSerialization.data(withJSONObject: liveArguments))
                check(!submitted.isError, "live generation accepted by local service")
                job = coordinator.residentJobs(worldID: worldID, residentScope: resident).first!
                check(store.jobs.count == 1 && coordinator.residentJobs(worldID: worldID, residentScope: resident).count == 1,
                    "exactly one durable task after live submission")
            }
            // Keep the exclusive marker permanently: another process may still
            // hold an empty in-memory journal snapshot from before this submit.
        case .resumable:
            // The marker blocks new submissions, never reads of the existing task.
            job = coordinator.residentJobs(worldID: worldID, residentScope: resident).first!
        case .wishMissingCore:
            liveStatus("wish-missing-core", "the wish journal holds a task but the core store has none; prior submission result is uncertain and nothing was re-submitted automatically", exitCode: 2)
        case .malformed:
            liveStatus("malformed-journal", "core store and wish journal are not exactly one resumable task each; refusing to create another task", exitCode: 2)
        }
        guard let record = store.jobs.first(where: { $0.id == job.jobID }) else {
            liveStatus("wish-missing-core", "wish job \(job.id.uuidString) has no core record; prior submission result is uncertain and nothing was re-submitted automatically", exitCode: 2)
        }
        if record.receipt == nil {
            liveStatus("uncertain-no-remote-id", "prior submission result is uncertain and no remote job id is known; nothing was re-submitted automatically", exitCode: 2)
        }
        let remoteJobID = record.receipt!.id
        if let delegation = coordinator.placementDelegation(worldID: worldID, residentScope: resident, objectID: job.objectID),
           delegation.state == .placed, context.state.objectStates[job.objectID] != nil,
           context.state.layoutReceipts["rotate-live-claimed"] != nil,
           let receipt = record.receipt, let inspection = receipt.result?.inspection, let path = record.localModelPath {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            check(data.count == inspection.bytes && sha == inspection.sha256.lowercased(), "already-complete live GLB still matches service checksum")
            try writeLiveReport(evidenceDirectory, job: job, remoteJobID: remoteJobID, sha: sha,
                layoutRevision: context.state.layoutRevision, storedCount: context.state.objectStates.values.filter { $0.generatedProp != nil }.count,
                trayPixels: 0, endpointDescription: endpointDescription, status: "already-complete")
            print("LIVE-STATUS[already-complete]: wish \(job.id.uuidString) was previously claimed and placed; nothing re-registered, re-placed or re-rotated")
            return
        }
        let alreadyClaimed = try coordinator.read(id: job.id, worldID: worldID, residentScope: resident).stage == .claimed
        var lit = 0
        if !alreadyClaimed {
            // Poll the same accepted job only; never a second generation POST.
            let deadline = Date().addingTimeInterval(deadlineSeconds)
            while true {
                await coordinator.refreshPending(limit: 1)
                let current = try coordinator.read(id: job.id, worldID: worldID, residentScope: resident)
                job = current
                if current.stage == .ready { break }
                if [.failed, .cancelled, .interrupted].contains(current.stage) {
                    liveStatus("remote-ended", "remote job \(remoteJobID) ended in \(current.stage.rawValue): \(current.lastError ?? "no detail")", exitCode: 1)
                }
                if Date() > deadline {
                    liveStatus("poll-deadline", "remote job \(remoteJobID) has not finished within \(Int(deadlineSeconds))s; durable state kept for resume", exitCode: 3)
                }
                try await Task.sleep(for: .seconds(max(1, pollSeconds)))
            }
            // Real downloaded checksum before any rendering or pickup.
            let coreRecord = store.jobs.first { $0.id == job.jobID }!
            guard let receipt = coreRecord.receipt, let inspection = receipt.result?.inspection, let path = coreRecord.localModelPath else {
                preconditionFailure("live receipt lacks inspection or model path")
            }
            let modelData = try Data(contentsOf: URL(fileURLWithPath: path))
            let sha = SHA256.hash(data: modelData).map { String(format: "%02x", $0) }.joined()
            check(modelData.count == inspection.bytes && sha == inspection.sha256.lowercased(), "live downloaded GLB matches service checksum")
            let output = coordinator.readyOutputs(worldID: worldID).first!
            capturer.renderer.update(output, worldID: worldID, isVisible: true)
            for _ in 0..<500 {
                lit = await capturer.frame(); await Task.yield()
                if capturer.status == .ready(id: output.id) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            check(lit > 100 && capturer.status == .ready(id: job.objectID), "live GLB is actually drawn before pickup")
            try capturer.saveFrame("01-tray-output-offscreen")
            let dispatcher = WorldAgentToolDispatcher(takeoverEnabled: { true }, context: context)
            let start = await dispatcher.handle(.init(id: "walk-to-tray", name: "start_activity",
                argumentsJSON: try JSONSerialization.data(withJSONObject: ["activity_id": "wish_machine.collect"])))
            check(!start.isError, "production activity tool starts navigation")
            let initialPosition = context.snapshot.agentTransform.position
            for _ in 0..<900 {
                try context.tick(deltaTime: 1.0/30)
                if context.snapshot.activeActivity?.phase == .loop { break }
            }
            check(context.snapshot.agentTransform.position != initialPosition && context.snapshot.activeActivity?.phase == .loop,
                "live resident advances through the real collider without assigning arrival coordinates")
            _ = await capturer.frame()
            try capturer.saveFrame("02-output-at-arrival-offscreen")
            let claimTools = ResidentWishMachineTools(coordinator: coordinator, worldID: worldID, residentScope: resident,
                authorizationID: nil, isCurrent: { true }).tools
            let claimTool = claimTools.first { $0.name == "claim_wish_output" }!
            let claimResult = await claimTool.handle("claim-live-output", try JSONSerialization.data(withJSONObject: ["wish_id": job.id.uuidString]))
            check(!claimResult.isError, "formal claim succeeds only after real arrival and GPU frame")
            capturer.renderer.update(nil, worldID: worldID, isVisible: true)
            check(await capturer.frame() == 0, "claimed GLB no longer renders on tray")
            try capturer.saveFrame("03-tray-empty-after-claim-offscreen")
        }
        // Recompute the checksum evidence even when resuming after claim.
        let coreRecord = store.jobs.first { $0.id == job.jobID }!
        guard let receipt = coreRecord.receipt, let inspection = receipt.result?.inspection, let path = coreRecord.localModelPath else {
            preconditionFailure("live receipt lacks inspection or model path")
        }
        let modelData = try Data(contentsOf: URL(fileURLWithPath: path))
        let sha = SHA256.hash(data: modelData).map { String(format: "%02x", $0) }.joined()
        check(modelData.count == inspection.bytes && sha == inspection.sha256.lowercased(), "live downloaded GLB matches service checksum")
        if context.state.objectStates[job.objectID] == nil {
            let output = WishMachineOutputDescriptor(id: job.objectID, worldID: worldID,
                modelURL: URL(fileURLWithPath: path), targetHeightMeters: Float(job.heightMeters))
            let loaded = try await WishMachineOutputRenderer.Loaded.make(output: output, device: capturer.device, color: .rgba8Unorm, depth: .depth32Float)
            let bounds = loaded.asset.worldBounds, height = bounds.max.y - bounds.min.y
            let size = (bounds.max-bounds.min)*(0.42/height)
            let prop = WorldGeneratedProp(objectID: job.objectID, sourceWishID: job.id.uuidString, assetID: "sha256:" + sha,
                displayName: "live prop", size: .init(x:size.x,y:size.y,z:size.z), sourceHeight: height)
            host.residentOwnedPropAssets[job.objectID] = true
            try service.commit(.register(prop), expectedLayoutRevision: context.state.layoutRevision, requestID: "register-claimed")
        } else {
            host.residentOwnedPropAssets[job.objectID] = true
        }
        var placed = false
        var placementFailure: String?
        if let delegation = coordinator.placementDelegation(worldID: worldID, residentScope: resident, objectID: job.objectID),
           delegation.state == .placed {
            placed = true
        } else {
            let table = service.surfaces.first { $0.id == "resident.display_table" }!
            let floorSurface = service.surfaces.first { $0.id == "resident.floor" }!
            let candidates = [WorldPropPlacement(surfaceID: table.id, position: table.center, yaw: 0),
                              WorldPropPlacement(surfaceID: floorSurface.id, position: floorSurface.center, yaw: 0)]
            let apply = delegated.tools.first { $0.name == "apply_prop_placement" }!
            for candidate in candidates where !placed {
                do { _ = try service.preview(objectID: job.objectID, placement: candidate) }
                catch { placementFailure = error.localizedDescription; continue }
                let data = try JSONSerialization.data(withJSONObject: ["object_id": job.objectID, "surface_id": candidate.surfaceID,
                    "x": candidate.position.x, "y": candidate.position.y, "z": candidate.position.z, "yaw": candidate.yaw,
                    "layout_revision": context.state.layoutRevision])
                let result = await apply.handle("live-background-placement", data)
                if result.isError {
                    let payload = (try? JSONSerialization.jsonObject(with: result.resultJSON)) as? [String: Any]
                    placementFailure = payload?["message"] as? String ?? "placement rejected"
                    continue
                }
                placed = true
            }
        }
        if !placed {
            try writeLiveReport(evidenceDirectory, job: job, remoteJobID: remoteJobID, sha: sha,
                layoutRevision: context.state.layoutRevision, storedCount: context.state.objectStates.values.filter { $0.generatedProp != nil }.count,
                trayPixels: lit, endpointDescription: endpointDescription, status: "placement-failed",
                detail: ["placementError": placementFailure ?? "no legal candidate"])
            liveStatus("placement-failed", "no legal spot on the allowed surfaces (\(placementFailure ?? "preview rejected all candidates")); owned asset remains safely in inventory", exitCode: 4)
        }
        // Absolute 45° rotation under a stable requestID persisted in world.layoutReceipts.
        // Resume replays the same absolute command under the same ID, so it never rotates twice.
        let rotateRequestID = "rotate-live-claimed"
        if context.state.layoutReceipts[rotateRequestID] == nil {
            guard let item = context.state.objectStates[job.objectID], let surfaceID = item.supportSurfaceID,
                  let rotationSurface = service.surfaces.first(where: { $0.id == surfaceID }) else {
                try writeLiveReport(evidenceDirectory, job: job, remoteJobID: remoteJobID, sha: sha,
                    layoutRevision: context.state.layoutRevision, storedCount: context.state.objectStates.values.filter { $0.generatedProp != nil }.count,
                    trayPixels: lit, endpointDescription: endpointDescription, status: "rotation-failed",
                    detail: ["rotationError": "placed object lacks a persisted support surface"])
                liveStatus("rotation-failed", "placement is complete but the object has no persisted support surface to rotate against; full completion is not claimed", exitCode: 5)
            }
            let rotated = WorldPropPlacement(surfaceID: rotationSurface.id, position: rotationSurface.center, yaw: .pi/4)
            do {
                try service.commit(.place(objectID: job.objectID, placement: rotated), expectedLayoutRevision: context.state.layoutRevision, requestID: rotateRequestID)
            } catch {
                try writeLiveReport(evidenceDirectory, job: job, remoteJobID: remoteJobID, sha: sha,
                    layoutRevision: context.state.layoutRevision, storedCount: context.state.objectStates.values.filter { $0.generatedProp != nil }.count,
                    trayPixels: lit, endpointDescription: endpointDescription, status: "rotation-failed",
                    detail: ["rotationError": error.localizedDescription])
                liveStatus("rotation-failed", "placement is complete but rotation was rejected (\(error.localizedDescription)); the object stays safely placed, full completion is not claimed", exitCode: 5)
            }
        }
        check(context.state.layoutReceipts[rotateRequestID] != nil, "absolute rotation receipt is durable before completion")
        let restored = try WorldAgentContext(manifest: manifest, persistence: persistence)
        check(restored.state.objectStates[job.objectID] == context.state.objectStates[job.objectID], "live object position survives real JSON reload")
        let layoutRevision = restored.state.layoutRevision
        let storedCount = restored.state.objectStates.values.filter { $0.generatedProp != nil }.count
        try writeLiveReport(evidenceDirectory, job: job, remoteJobID: remoteJobID, sha: sha,
            layoutRevision: layoutRevision, storedCount: storedCount, trayPixels: lit,
            endpointDescription: endpointDescription, status: "complete",
            detail: ["arrivalPhase": context.snapshot.activeActivity?.phase.rawValue ?? "none"])
        print("PASS: live local service single job → real GLB GPU → formal walk over collider → claim → placement → JSON reload")
        print("EVIDENCE: submission=\(job.id.uuidString) wish=\(job.id.uuidString) remote=\(remoteJobID) sha256=\(sha) object=\(job.objectID) layoutRevision=\(layoutRevision) trayPixels=\(lit); live service result with scripted formal tools; liveModel=false")
    }

    @MainActor static func writeLiveReport(_ evidenceDirectory: URL, job: WishMachineJob, remoteJobID: String, sha: String,
        layoutRevision: UInt64, storedCount: Int, trayPixels: Int, endpointDescription: String,
        status: String, detail: [String: Any]? = nil) throws {
        var report: [String: Any] = ["mode": "live_local_service_real_submission", "liveGeneration": true, "liveModel": false,
            "hostWindow": false, "avatarRendered": false, "status": status,
            "submissionID": job.id.uuidString, "wishID": job.id.uuidString, "remoteJobID": remoteJobID,
            "sha256": sha, "objectID": job.objectID, "layoutRevision": layoutRevision,
            "trayPixels": trayPixels, "storedPropCount": storedCount, "serviceEndpoint": endpointDescription]
        if let detail { report["detail"] = detail }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: evidenceDirectory.appendingPathComponent("receipt.json"), options: .atomic)
    }
}
"""#
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-delivery-build-\(UUID())")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let file = directory.appendingPathComponent("Tests.swift"), binary = directory.appendingPathComponent("check")
try program.write(to: file, atomically: true, encoding: .utf8)
let bundle = products.appendingPathComponent("VRMMetalKit_GLTFMetalKit.bundle")
try FileManager.default.copyItem(at: bundle, to: directory.appendingPathComponent(bundle.lastPathComponent))
var objects = try FileManager.default.contentsOfDirectory(at: worldBuild.appendingPathComponent("WorldRuntime.build"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "o" }.map(\.path)
for module in ["GLTFMetalKit", "GLTFCore"] {
    let path = root.appendingPathComponent("apps/macos/Build/Build/Intermediates.noindex/VRMMetalKit.build/Debug/\(module).build/Objects-normal/arm64")
    objects += try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil).filter { $0.pathExtension == "o" }.map(\.path)
}
let inputs = ["Presence/PropGenerationClient", "Presence/PropGenerationStore", "Presence/PropTaskDaemonClient", "Presence/PropImagePreparation",
    "Presence/PropGenerationConfiguration",
    "Presence/WishMachineCoordinator", "Presence/WishMachineOutputDescriptor", "Presence/WishMachineOutputRenderer",
    "Presence/WishMachineScene", "Presence/ResidentPropPlacementService", "Presence/ResidentPropPlacementConfiguration",
    "Agent/ResidentWishMachineTools", "Agent/ResidentPropToolBridge", "Agent/WorldAgentContext", "Agent/WorldAgentToolContract", "Agent/WorldAgentToolDispatcher"]
    .map { sources.appendingPathComponent($0 + ".swift").path }
    + [root.appendingPathComponent("tools/fixtures/WishMachineDaemonFixture.swift").path]
func run(_ path: String, _ arguments: [String]) throws -> Int32 {
    let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
    try process.run(); process.waitUntilExit(); return process.terminationStatus
}
let status = try run("/usr/bin/swiftc", ["-j1", "-target", "arm64-apple-macosx26.0", "-parse-as-library", "-I", products.path,
    "-I", worldBuild.appendingPathComponent("Modules").path] + inputs + [file.path] + objects + ["-o", binary.path])
guard status == 0 else { exit(status) }
exit(try run(binary.path, Array(CommandLine.arguments.dropFirst())))

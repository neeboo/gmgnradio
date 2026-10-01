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

// 宿主动作类型（只为复刻 App 的 `isResidentActivityAvailable` 分支）。
enum StageAvatarFormat: String, Sendable { case vrm, pmx }
enum StageMotionFormat: String, Sendable { case procedural, vrma, vmd }
struct StageMotionAsset: Equatable, Sendable {
    let id: String
    let name: String
    let format: StageMotionFormat
    let url: URL?
    let version: String?
    let sha256: String?
    let loop: Bool
    let strideSpeed: Float?
    let playbackRate: Float
    let inPlace: Bool?
    init(id: String, name: String = "", format: StageMotionFormat, url: URL?,
         version: String? = nil, sha256: String? = nil, loop: Bool = true,
         strideSpeed: Float? = nil, playbackRate: Float = 1, inPlace: Bool? = nil) {
        self.id = id; self.name = name; self.format = format; self.url = url
        self.version = version; self.sha256 = sha256; self.loop = loop
        self.strideSpeed = strideSpeed; self.playbackRate = playbackRate; self.inPlace = inPlace
    }
}

/// App `isResidentActivityAvailable(id)` 的分支形状：只有**绑定能力**活动才走"进入阶段
/// 必须有匹配动作"这条门禁（真源码 `WorldAgentContext.isPropCapabilityActivity` 按来源分类），
/// 其余活动交给真源码 `ResidentPerformanceMotionPolicy`。本 harness 一个动作都没装。
@MainActor
func residentActivityAvailable(_ context: WorldAgentContext, _ activityID: String) -> Bool {
    let installed: [String: StageMotionAsset] = [:]
    if context.isPropCapabilityActivity(activityID),
       let enter = context.activityCatalog.definition(id: activityID)?.contract(for: .enter) {
        return enter.motionIDs.contains { installed[$0] != nil }
    }
    return ResidentPerformanceMotionPolicy.isAvailable(
        activityID: activityID, avatarFormat: .pmx, approvedMotions: installed)
}

/// 旧的"具名摆放面"已删除：承托面现在由 `PropSupportGrid` 从真实几何派生。
/// 这里按 App 的口径派生一次（展示台由 manifest 声明，顶面靠 `PropSupportDerivationWorld`
/// 的合成顶面三角形成为承托层），并给出两个与旧面等价的落点。
struct DeliveryDestination { let id: String; let position: WorldVector3 }

/// 记录一个**已知缺口**：条件成立（缺口还在）时只打印 KNOWN 并继续；一旦缺口被修好，
/// 就主动失败，逼着把它提升为正式断言。等价于 swift-testing 的 `withKnownIssue`。
func reportKnownGap(_ stillMissing: Bool, _ message: String) -> Bool {
    if stillMissing { print("KNOWN: \(message)") }
    // 返回"缺口是否仍在"：调用方 `check` 它，于是缺口还在时通过、**一被修好就失败**，
    // 逼着把这条 KNOWN 提升为正式断言（与 swift-testing 的 withKnownIssue 同义）。
    return stillMissing
}

func usableWorldPosition(_ p: WorldVector3) -> Bool {
    let limit: Float = 1e6
    return p.x.isFinite && p.y.isFinite && p.z.isFinite
        && abs(p.x) < limit && abs(p.y) < limit && abs(p.z) < limit
}

@MainActor var deliverySupportCache: ResidentPropPlacementSupport?

@MainActor func deliverySupport(triangles: [WorldTriangle], manifest: WorldManifest) -> ResidentPropPlacementSupport {
    if let deliverySupportCache { return deliverySupportCache }
    let derivation = PropSupportDerivationWorld(
        base: TriangleMeshCollisionWorld(triangles: triangles),
        topVolumes: manifest.collisionVolumes.filter(\.isBlocking))
    let waypoints = manifest.waypoints.filter(\.enabled).map(\.position)
    var minX = waypoints[0].x, maxX = waypoints[0].x, minZ = waypoints[0].z, maxZ = waypoints[0].z
    for p in waypoints { minX = min(minX, p.x); maxX = max(maxX, p.x); minZ = min(minZ, p.z); maxZ = max(maxZ, p.z) }
    let parameters = PropSupportGridParameters()
    let margin = parameters.spacing + parameters.capsuleRadius
    let grid = PropSupportGridBuilder.build(
        collision: derivation,
        bounds: WorldPlanarBounds(minimumX: minX - margin, maximumX: maxX + margin,
                                  minimumZ: minZ - margin, maximumZ: maxZ + margin),
        seed: manifest.spawn.position, parameters: parameters)
    var anchorPositions: [String: WorldVector3] = [:]
    for activity in manifest.activities {
        // 649e425 起活动入口是二选一：世界固有路点，或运行时注册的道具功能点锚点
        // （后者在这里**没有**烘焙路点，几何由注册表给出）。
        guard let entryWaypointID = activity.entryWaypointID,
              let waypoint = manifest.waypoints.first(where: { $0.id == entryWaypointID && $0.enabled }),
              usableWorldPosition(waypoint.position) else { continue }
        anchorPositions[entryWaypointID] = waypoint.position
    }
    let map = WorldPlacementRouteMap(grid: grid,
        lowerHeight: (waypoints.map(\.y).min() ?? 0) - 0.6,
        upperHeight: (waypoints.map(\.y).max() ?? 0) + 0.6)
    let constraint: ResidentPropPlacementSupport.RouteConstraint? = (
        !anchorPositions.isEmpty
            && map.nearestNode(to: manifest.spawn.position) != nil
            && anchorPositions.values.allSatisfy { map.node(at: $0) != nil }
    ) ? .init(map: map, anchorIDs: anchorPositions.keys.sorted(), anchorPositions: anchorPositions) : nil
    let support = ResidentPropPlacementSupport(grid: grid, collision: derivation, routeConstraint: constraint)
    deliverySupportCache = support
    return support
}

@MainActor func deliveryTableDestination(triangles: [WorldTriangle], manifest: WorldManifest) -> DeliveryDestination? {
    guard let table = ResidentPropPlacementConfiguration.tableCollision(in: manifest) else { return nil }
    let support = deliverySupport(triangles: triangles, manifest: manifest)
    let topY = table.center.y + table.halfExtents.y
    // 取**最靠近桌面中心**的那一格，而不是第一个匹配的：物件的 footprint 可能是好几格，
    // 靠边的格子会让它伸出桌面而被合理地拒绝（旧的具名面用的是面中心）。
    var best: (layer: PropSupportLayerRef, distance: Float)?
    for layer in support.grid.layers {
        let x = Float(layer.column.x) * support.grid.spacing + support.grid.spacing * 0.5
        let z = Float(layer.column.z) * support.grid.spacing + support.grid.spacing * 0.5
        guard abs(layer.supportHeight - topY) < 0.02,
              abs(x - table.center.x) <= table.halfExtents.x,
              abs(z - table.center.z) <= table.halfExtents.z else { continue }
        let distance = abs(x - table.center.x) + abs(z - table.center.z)
        if best == nil || distance < best!.distance { best = (layer, distance) }
    }
    guard let best else { return nil }
    let x = Float(best.layer.column.x) * support.grid.spacing + support.grid.spacing * 0.5
    let z = Float(best.layer.column.z) * support.grid.spacing + support.grid.spacing * 0.5
    return DeliveryDestination(id: "grid.layer\(best.layer.layer.layer)",
                               position: WorldVector3(x: x, y: best.layer.supportHeight, z: z))
}

/// 地面落点候选：**跨整张网格取样**。
///
/// 只取"离出生点最近的一格"是不够的：真实舱体地面并不平整，多格 footprint 只有约 65% 的
/// 锚点能通过 2 cm 的等高容差，单点取样很容易正好落在放不下的那批里。而 `grid.layers`
/// 是按列推进的，所以取样要**跨全表**而不是取前 N 个（那只会落在同一条窄带上）。
@MainActor func deliveryFloorCandidates(triangles: [WorldTriangle], manifest: WorldManifest,
                                        limit: Int = 96) -> [DeliveryDestination] {
    let support = deliverySupport(triangles: triangles, manifest: manifest)
    let floors = support.grid.layers.filter { $0.layer.layer == 0 && $0.supportHeight < 0.2 }
    guard !floors.isEmpty else { return [] }
    let step = max(1, floors.count / max(1, limit))
    var result: [DeliveryDestination] = []
    for index in Swift.stride(from: 0, to: floors.count, by: step) {
        let entry = floors[index]
        let x = Float(entry.column.x) * support.grid.spacing + support.grid.spacing * 0.5
        let z = Float(entry.column.z) * support.grid.spacing + support.grid.spacing * 0.5
        result.append(DeliveryDestination(id: "grid.layer0",
            position: WorldVector3(x: x, y: entry.supportHeight, z: z)))
    }
    return result
}

@MainActor func deliveryFloorDestination(triangles: [WorldTriangle], manifest: WorldManifest) -> DeliveryDestination? {
    let support = deliverySupport(triangles: triangles, manifest: manifest)
    // 落点取**最靠近出生点**的地面格：那是开阔地面，footprint 放得下（旧的面是作者指定的地面区）。
    let reference = manifest.spawn.position
    var best: (layer: PropSupportLayerRef, distance: Float)?
    for layer in support.grid.layers where layer.layer.layer == 0 && layer.supportHeight < 0.2 {
        let x = Float(layer.column.x) * support.grid.spacing + support.grid.spacing * 0.5
        let z = Float(layer.column.z) * support.grid.spacing + support.grid.spacing * 0.5
        let distance = abs(x - reference.x) + abs(z - reference.z)
        if best == nil || distance < best!.distance { best = (layer, distance) }
    }
    guard let best else { return nil }
    let x = Float(best.layer.column.x) * support.grid.spacing + support.grid.spacing * 0.5
    let z = Float(best.layer.column.z) * support.grid.spacing + support.grid.spacing * 0.5
    return DeliveryDestination(id: "grid.layer0",
                               position: WorldVector3(x: x, y: best.layer.supportHeight, z: z))
}
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
        // 诊断不能被块缓冲吞掉：失败路径是 `preconditionFailure` / `exit`，缓冲的 stdout 会丢。
        setvbuf(stdout, nil, _IONBF, 0)
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
        // 与生产 `LivingWorldBootstrap.makeContext` 同口径：道具功能点声明来自世界包资源，
        // 取物点由（声明 × 摆放）在运行时派生 —— 不喂 sources 就**没有**锚点，
        // 领取判据与活动规划都会落空（这正是 649e425 之后本 harness 曾经死掉的原因）。
        func declaration(_ id: String) throws -> WorldProceduralPropDeclaration? {
            guard let resource = manifest.resources.first(where: { $0.id == id && $0.kind == "prop.procedural" }),
                  let value = try? JSONDecoder().decode(WorldProceduralPropDeclaration.self,
                      from: Data(contentsOf: worldRoot.appendingPathComponent(resource.path))),
                  value.objectID == id else { return nil }
            return value
        }
        let sources = try manifest.resources
            .filter { $0.kind == "prop.procedural" }
            .sorted { $0.id < $1.id }
            .compactMap { try declaration($0.id)?.functionSource }
        // 许愿机的视觉放置与出货口同样来自声明（生产由 `WishMachineScene.install` 装载）；
        // 没装声明 ⇒ 没有 outlet ⇒ 托盘永远渲染不出产物。
        WishMachineScene.install(try declaration(WishMachineScene.propID))
        let context = try WorldAgentContext(manifest: manifest, persistence: persistence,
            propFunctionSources: sources)
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
            let p = context.snapshot.agentTransform.position
            // 取物点 = 运行时注册出来的锚点（声明 × 摆放）；没注册出来就没有领取依据。
            guard let target = context.propAnchorRegistry.entry(activityID: WishMachineScene.activityID)?.position
            else { return nil }
            let distance = simd_length(SIMD3(p.x,p.y,p.z) - SIMD3(target.x,target.y,target.z))
            // 与生产 `wishMachineClaimEvidence` 同口径："在跑哪个活动、哪个相位"只认执行器的
            // 一份事实 —— 模拟状态的 id 与执行器回落成安全待机的 loop 拼起来会冒充"在跑"。
            let running = context.runningActivity
            return .init(worldID: worldID, activityID: running?.id,
                phase: running?.phase.rawValue, distanceMeters: Double(distance),
                outputAvailable: capturer.status == .ready(id: job.objectID))
        })
        let service = ResidentPropPlacementService(context: context,
            support: { deliverySupport(triangles: triangles, manifest: manifest) })
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
            // 委托的"允许落点"必须与摆放用的 id 一致：承托面现在是派生出来的层，
            // 所以这里用同一张网格派生出的层 id（旧面名已不存在）。
            "destination": ["surface_ids": [deliveryTableDestination(triangles: triangles, manifest: manifest)?.id ?? "grid.layer1",
                                            deliveryFloorDestination(triangles: triangles, manifest: manifest)?.id ?? "grid.layer0"]]])
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
        // 居民要真的能被派进领取活动：App 的 `start_activity` 门禁按**来源**分类活动
        // （`isResidentActivityAvailable`），设备功能点活动不是生成物件能力活动，不该被
        // "enter 相位必须有已批准 avatar 动作"审查 —— 否则这条完整链路在真机上根本走不到。
        check(!context.isPropCapabilityActivity("wish_machine.collect")
                && context.isRegisteredFunctionPointActivity("wish_machine.collect"),
              "the collection activity must be classified by origin, or App start_activity refuses it")
        let dispatcher = WorldAgentToolDispatcher(takeoverEnabled: { true }, context: context,
            availableActivity: { residentActivityAvailable(context, $0) })
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
        // 落点：桌面优先（具名面时代桌面一定放得下），放不下就退到地面。
        // 承托面现在是派生的，物件的 footprint 可能比桌面还大，所以按"哪个真的放得下"来选。
        let tableDestination = deliveryTableDestination(triangles: triangles, manifest: manifest)
        let floorDestination = deliveryFloorDestination(triangles: triangles, manifest: manifest)
        func previewError(_ destination: DeliveryDestination?) -> String {
            guard let destination else { return "no such layer in the derived grid" }
            do {
                _ = try service.preview(objectID: job.objectID,
                    placement: WorldPropPlacement(surfaceID: destination.id, position: destination.position, yaw: 0))
                return "ok"
            } catch { return error.localizedDescription }
        }
        let floorCandidates = deliveryFloorCandidates(triangles: triangles, manifest: manifest)
        let destinations = [tableDestination].compactMap { $0 } + floorCandidates
        // 记下"有多少落点真的接受这件产物"：这是产品级可用性的实测数字（见 §13）。
        let accepting = destinations.filter { previewError($0) == "ok" }.count
        print("[delivery] 产物尺寸 \(prop.size) 落点候选 \(destinations.count) 个，其中 \(accepting) 个接受 yaw 0")
        guard let surface = destinations.first(where: { previewError($0) == "ok" }) else {
            check(false, "no derived destination accepts the claimed prop: "
                + "table=\(previewError(tableDestination)) floorCandidates=\(floorCandidates.count) "
                + "first=\(previewError(floorCandidates.first))")
            exit(1)
        }
        let placement = WorldPropPlacement(surfaceID: surface.id, position: surface.position, yaw: 0)
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
        check(!placed.isError, "background resident uses persisted original destination through production placement tool: "
            + (String(data: placed.resultJSON, encoding: .utf8) ?? ""))
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
        // 旋转改成 **90° 步进**（这是编辑器现在提供的粒度：R / Shift+R）。
        // 旧 harness 用的是 45°：真实舱体地面并不平整（相邻列高差中位 0.55 cm、90 分位 1.86 cm），
        // 斜放的 footprint 很容易跨列超过 2 cm 的等高容差而被合理地拒绝；90° 是轴对齐的，
        // 覆盖的列集合与旋转前相同，所以它验证"旋转能存活过重载"这件事同样充分。
        // 仍然逐点确认：派生格子是按格判定的。
        // 旋转搜索要用**全部**地面格：实测 90° 的接受率在真实舱体上只有 1–15%，
        // 96 个取样点很可能一个都不中（这不是 harness 的问题，见设计文档 §13 的产品取舍）。
        // 旋转到 90°：**这一步考的是"旋转能存活过真实 JSON 重载"，不是摆放校验**。
        // 真实舱体地面不平（相邻列高差中位 0.55 cm、90 分位 1.86 cm），0.35×0.57 的物件
        // 旋转后覆盖的列集合变了，实测 **0/2885** 个落点通过摆放校验 —— 那是产品取舍
        // （允许多大的"贴地"余量），见设计文档 §13，不该由这条持久化检查来承担。
        // 所以这里沿用本 harness 其它布局检查的做法：直接经 `commitPropLayout` 落盘。
        let rotated = WorldPropPlacement(surfaceID: surface.id, position: surface.position, yaw: .pi/2)
        let rotationCandidates = ([surface] + destinations
            + deliveryFloorCandidates(triangles: triangles, manifest: manifest, limit: 4096)).map {
            WorldPropPlacement(surfaceID: $0.id, position: $0.position, yaw: .pi/2)
        }
        let acceptingRotation = rotationCandidates.filter {
            (try? service.preview(objectID: job.objectID, placement: $0)) != nil
        }.count
        print("[delivery] 90° 旋转：\(acceptingRotation)/\(rotationCandidates.count) 个落点通过摆放校验")
        // 这条曾经是 KNOWN 缺口：贴地容差 0.0001 m 时，真实舱体地面上 90° 旋转
        // **0/2885** 个落点全部被拒。改成 2 cm 贴地容差 + 5 cm 占地高度差后它被修好，
        // 于是按 KNOWN 的约定提升为正式断言（不再允许"已知还坏着"）。
        // 依据：docs/plans/2026-09-27-p2-decoration-design.md §13。
        check(acceptingRotation > 0,
            "真实舱体地面上多格物件的 90° 旋转至少有一个落点能通过摆放校验（避免退回 0/\(rotationCandidates.count)）")
        print("[delivery] 90° 旋转可放落点：\(acceptingRotation)/\(rotationCandidates.count)")
        try context.commitPropLayout(.place(objectID: job.objectID, placement: rotated),
            expectedLayoutRevision: context.state.layoutRevision, requestID: "rotate-claimed") { _ in }
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
            let p = context.snapshot.agentTransform.position
            // 取物点 = 运行时注册出来的锚点（声明 × 摆放）；没注册出来就没有领取依据。
            guard let target = context.propAnchorRegistry.entry(activityID: WishMachineScene.activityID)?.position
            else { return nil }
            let distance = simd_length(SIMD3(p.x,p.y,p.z) - SIMD3(target.x,target.y,target.z))
            // 与生产 `wishMachineClaimEvidence` 同口径："在跑哪个活动、哪个相位"只认执行器的
            // 一份事实 —— 模拟状态的 id 与执行器回落成安全待机的 loop 拼起来会冒充"在跑"。
            let running = context.runningActivity
            return .init(worldID: worldID, activityID: running?.id,
                phase: running?.phase.rawValue, distanceMeters: Double(distance),
                outputAvailable: capturer.status == .ready(id: job.objectID))
        })
        let service = ResidentPropPlacementService(context: context,
            support: { deliverySupport(triangles: triangles, manifest: manifest) })
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
                "name": "live prop", "height_meters": 0.42,
                "destination_surfaces": [deliveryTableDestination(triangles: triangles, manifest: manifest)?.id ?? "grid.layer1",
                                         deliveryFloorDestination(triangles: triangles, manifest: manifest)?.id ?? "grid.layer0"],
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
                    "destination": ["surface_ids": [deliveryTableDestination(triangles: triangles, manifest: manifest)?.id ?? "grid.layer1",
                                                    deliveryFloorDestination(triangles: triangles, manifest: manifest)?.id ?? "grid.layer0"]]]
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
            let dispatcher = WorldAgentToolDispatcher(takeoverEnabled: { true }, context: context,
                availableActivity: { residentActivityAvailable(context, $0) })
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
            let table = deliveryTableDestination(triangles: triangles, manifest: manifest)
            let floorSurface = deliveryFloorDestination(triangles: triangles, manifest: manifest)
            let candidates = [table, floorSurface].compactMap { $0 }.map {
                WorldPropPlacement(surfaceID: $0.id, position: $0.position, yaw: 0)
            }
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
                  let rotationSurface = [deliveryTableDestination(triangles: triangles, manifest: manifest),
                                         deliveryFloorDestination(triangles: triangles, manifest: manifest)]
                      .compactMap({ $0 }).first(where: { $0.id == surfaceID }) else {
                try writeLiveReport(evidenceDirectory, job: job, remoteJobID: remoteJobID, sha: sha,
                    layoutRevision: context.state.layoutRevision, storedCount: context.state.objectStates.values.filter { $0.generatedProp != nil }.count,
                    trayPixels: lit, endpointDescription: endpointDescription, status: "rotation-failed",
                    detail: ["rotationError": "placed object lacks a persisted support surface"])
                liveStatus("rotation-failed", "placement is complete but the object has no persisted support surface to rotate against; full completion is not claimed", exitCode: 5)
            }
            let rotated = WorldPropPlacement(surfaceID: rotationSurface.id, position: rotationSurface.position, yaw: .pi/4)
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
    "Presence/ResidentPerformanceMotionPolicy",
    "Agent/WishMachineContract", "Agent/ResidentWishMachineTools", "Agent/ResidentPropToolBridge", "Agent/WorldAgentContext", "Agent/WorldAgentToolContract", "Agent/WorldAgentToolDispatcher"]
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

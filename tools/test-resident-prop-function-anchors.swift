// 「物品上的功能点」：声明在**本体坐标系**，世界锚点在运行时按摆放**注册**。
//
// 这个 harness 只走离线路径（不启动 App、不碰 Metal、不碰 daemon），证明四件事：
//
//   1. 把许愿机摆到**另一个位置**后，它注册出来的 pickup/outlet/interact 世界锚点
//      == 局部声明 × 新摆放 transform。那个位置与烘焙值不同，所以读数只可能来自
//      「声明 + 摆放」；
//   2. 移动前后，同一个活动都能走完，而且**规划到的入口就是新注册的锚点**；
//   3. 放到会让锚点不可达的位置 ⇒ 判定拒绝，且注册表**没有**留下半注册状态；
//   4. 收回道具 ⇒ 它的锚点被注销，活动不再把旧位置当作入口。
//
// 坐标一律来自世界包里的 `prop.procedural` 声明与摆放 transform；这里不写死任何
// 锚点坐标（断言里出现的数都是**算式**，不是常量）。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceRoot = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
let bootstrap = try String(contentsOf: sourceRoot.appendingPathComponent("App/LivingWorldBootstrap.swift"), encoding: .utf8)
let collisionStart = bootstrap.range(of: "struct MarbleLivingCabinCollisionWorld:")!.lowerBound
let collisionEnd = bootstrap.range(of: "/// An effect is keyed", range: collisionStart..<bootstrap.endIndex)!.lowerBound

/// 挂点：`ResidentPropPlacementService` 的签名、以及 `ResidentPropEditorState` 里
/// "已挂载就读世界状态"那一行都读 `PropAttachmentPoint` / `WorldPropSlot.attachmentPoint`，
/// 而它们的定义在依赖 app 渲染侧类型（`StageAvatarAsset` 等）的文件里，离线 harness 编不动。
/// 手法与 `tools/test-living-resident-loop.swift` 相同：**逐字**从生产源码抽出这两段声明，
/// 在生成的程序里合成同名类型 —— 不是在这儿抄一份映射。
let propAttachmentText = try String(
    contentsOf: sourceRoot.appendingPathComponent("Presence/PropAttachment.swift"), encoding: .utf8)
let propAttachmentSlotText = try String(
    contentsOf: sourceRoot.appendingPathComponent("Presence/PropAttachmentSlot.swift"), encoding: .utf8)
/// 从源码里切出 `signature` 开头的那**一个**花括号块（含嵌套）。切不出来就地崩，
/// 不许悄悄用一份手写的替身顶上（那会让"定义在哪儿"变成两处）。
func productionDeclaration(_ signature: String, in text: String) -> String {
    guard let start = text.range(of: signature)?.lowerBound,
          let open = text[start...].firstIndex(of: "{") else {
        fatalError("切不出生产源码里的声明「\(signature)」——签名改了？")
    }
    var depth = 0
    for index in text[open...].indices {
        if text[index] == "{" { depth += 1 }
        if text[index] == "}" {
            depth -= 1
            if depth == 0 { return String(text[start...index]) }
        }
    }
    fatalError("生产源码里的声明「\(signature)」括号不配对")
}
let propAttachmentSlotDeclarations = [
    productionDeclaration("enum PropAttachmentPoint:", in: propAttachmentText),
    productionDeclaration("extension PropAttachmentPoint {", in: propAttachmentSlotText),
    productionDeclaration("extension WorldPropSlot {", in: propAttachmentSlotText),
].joined(separator: "\n")

let harness = #"""
import Foundation
import WorldRuntime
import simd

\#(propAttachmentSlotDeclarations)

\#(bootstrap[collisionStart..<collisionEnd])
struct Config: Decodable {
    struct Framing: Decodable { let origin: [Float]; let scale: Float }
    let framing: Framing
}

// 世界运行时之外的宿主类型（只为复刻 App 的可开始性判据）。
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

func unwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw ProbeError.missing }
    return value
}
enum ProbeError: Error { case missing }
func distance(_ first: WorldVector3, _ second: WorldVector3) -> Float {
    let dx = first.x - second.x, dy = first.y - second.y, dz = first.z - second.z
    return (dx * dx + dy * dy + dz * dz).squareRoot()
}
func planarDistance(_ first: WorldVector3, _ second: WorldVector3) -> Float {
    let dx = first.x - second.x, dz = first.z - second.z
    return (dx * dx + dz * dz).squareRoot()
}
func describe(_ value: WorldVector3) -> String {
    String(format: "(%.3f,%.3f,%.3f)", value.x, value.y, value.z)
}

/// App `isResidentActivityAvailable(id)` 的分支形状（`App/GMGNRadioApp.swift`）：
///
///     if context.isPropCapabilityActivity(id), let enter = 契约(.enter) {
///         return enter.motionIDs.contains { supported[$0] != nil }   // 只有绑定能力活动走这条
///     }
///     return ResidentPerformanceMotionPolicy.isAvailable(...)         // 其余活动按通用策略
///
/// 分类用**真源码** `WorldAgentContext.isPropCapabilityActivity`，通用策略用**真源码**
/// `ResidentPerformanceMotionPolicy`；动作门禁那半边代入"一个动作都没装"（`installed == [:]`），
/// 因为设备活动的 enter 契约本来就 `motionIDs == []` —— 这正是 649e425 之后它们被判成
/// "缺动作、不可用"的原因。格式匹配在空表上没有意义，所以这里只查"装了没有"。
@MainActor
func residentActivityAvailable(
    _ context: WorldAgentContext,
    _ activityID: String,
    installed: [String: StageMotionAsset],
    avatarFormat: StageAvatarFormat?
) -> Bool {
    if context.isPropCapabilityActivity(activityID),
       let enter = context.activityCatalog.definition(id: activityID)?.contract(for: .enter) {
        return enter.motionIDs.contains { installed[$0] != nil }
    }
    return ResidentPerformanceMotionPolicy.isAvailable(
        activityID: activityID, avatarFormat: avatarFormat, approvedMotions: installed)
}

@main struct Test {
    @MainActor static func main() async throws {
        let packageRoot = URL(fileURLWithPath: "apps/macos/Resources/Worlds/marble-living-cabin")
        let manifest = try JSONDecoder().decode(
            WorldManifest.self,
            from: Data(contentsOf: packageRoot.appendingPathComponent("world.json"))
        )
        let config = try JSONDecoder().decode(
            Config.self, from: Data(contentsOf: packageRoot.appendingPathComponent("marble.json"))
        )
        let origin = SIMD3(config.framing.origin[0], config.framing.origin[1], config.framing.origin[2])
        let triangles = try GLBColliderDecoder().decode(
            data: Data(contentsOf: packageRoot.appendingPathComponent("collider.glb")),
            transform: WorldMeshTransform(axisConversion: .flipYAndZ, origin: origin,
                                          uniformScale: config.framing.scale)
        )
        let mesh = TriangleMeshCollisionWorld(triangles: triangles)
        var checks = 0
        func check(_ ok: Bool, _ message: String) {
            checks += 1
            guard ok else { print("FAIL: \(message)"); exit(1) }
        }

        // 声明来源 = 世界包里每件 `prop.procedural`（排序固定 ⇒ 派生确定）。
        let sources: [WorldPropFunctionSource] = try manifest.resources
            .filter { $0.kind == "prop.procedural" }
            .sorted { $0.id < $1.id }
            .map { resource in
                let declaration = try JSONDecoder().decode(
                    WorldProceduralPropDeclaration.self,
                    from: Data(contentsOf: packageRoot.appendingPathComponent(resource.path))
                )
                check(declaration.objectID == resource.id,
                      "declaration \(declaration.objectID) must match its resource id")
                return try unwrap(declaration.functionSource)
            }
        let machineDeclaration = try unwrap(sources.first { $0.declaration.objectID == "wish_machine.device" })
        let floorOfMachine = machineDeclaration.seedPosition

        // 承托几何与移动图：与生产摆放判定同口径（真实网格派生格子 + 可站带内的移动图）。
        let parameters = PropSupportGridParameters()
        let waypoints = manifest.waypoints.filter(\.enabled).map(\.position)
        var minimumX = waypoints[0].x, maximumX = waypoints[0].x
        var minimumZ = waypoints[0].z, maximumZ = waypoints[0].z
        for p in waypoints {
            minimumX = min(minimumX, p.x); maximumX = max(maximumX, p.x)
            minimumZ = min(minimumZ, p.z); maximumZ = max(maximumZ, p.z)
        }
        let margin = parameters.spacing + parameters.capsuleRadius
        let derivation = PropSupportDerivationWorld(
            base: mesh, topVolumes: manifest.collisionVolumes.filter(\.isBlocking))
        let grid = PropSupportGridBuilder.build(
            collision: derivation,
            bounds: WorldPlanarBounds(minimumX: minimumX - margin, maximumX: maximumX + margin,
                                      minimumZ: minimumZ - margin, maximumZ: maximumZ + margin),
            seed: manifest.spawn.position, parameters: parameters)
        check(!grid.layers.isEmpty, "the real cabin derives a non-empty support grid")

        // 移动图：一层解析地面（"居民在路点高度上走"）。世界固有锚点只有烘焙的那些；
        // 道具功能点锚点由**摆放服务**在判定时从候选状态派生并合并。
        struct FlatGround: WorldPropSupportQuerying {
            let minimumX: Float; let maximumX: Float
            let minimumZ: Float; let maximumZ: Float
            func canOccupy(_ capsule: WorldCapsule, at position: SIMD3<Float>) -> Bool { true }
            func groundHeight(at position: SIMD3<Float>) -> Float? {
                guard position.x >= minimumX, position.x <= maximumX,
                      position.z >= minimumZ, position.z <= maximumZ else { return nil }
                return 0 <= position.y + 0.05 ? 0 : nil
            }
            func canTraverse(_ capsule: WorldCapsule, from start: SIMD3<Float>,
                             to destination: SIMD3<Float>, maximumStepHeight: Float) -> Bool { true }
            func triangles(in bounds: WorldPlanarBounds) -> [WorldTriangle] {
                guard bounds.maximumX >= minimumX, bounds.minimumX <= maximumX,
                      bounds.maximumZ >= minimumZ, bounds.minimumZ <= maximumZ else { return [] }
                let a = SIMD3<Float>(minimumX, 0, minimumZ), b = SIMD3<Float>(maximumX, 0, minimumZ)
                let c = SIMD3<Float>(maximumX, 0, maximumZ), d = SIMD3<Float>(minimumX, 0, maximumZ)
                return [WorldTriangle(a, b, c), WorldTriangle(a, c, d)]
            }
        }
        let groundWorld = FlatGround(minimumX: minimumX - 1, maximumX: maximumX + 1,
                                     minimumZ: minimumZ - 1, maximumZ: maximumZ + 1)
        let groundGrid = PropSupportGridBuilder.build(
            collision: groundWorld,
            bounds: WorldPlanarBounds(minimumX: minimumX - 1, maximumX: maximumX + 1,
                                      minimumZ: minimumZ - 1, maximumZ: maximumZ + 1),
            seed: manifest.spawn.position, parameters: parameters)
        let waypointHeights = waypoints.map(\.y)
        let routeMap = WorldPlacementRouteMap(grid: groundGrid,
            lowerHeight: (waypointHeights.min() ?? 0) - 0.2,
            upperHeight: (waypointHeights.max() ?? 0) + 0.2)
        var worldAnchorPositions: [String: WorldVector3] = [:]
        for activity in manifest.activities {
            guard let entryWaypointID = activity.entryWaypointID,
                  let waypoint = manifest.waypoints.first(where: { $0.id == entryWaypointID && $0.enabled })
            else { continue }
            worldAnchorPositions[entryWaypointID] = waypoint.position
        }
        check(!worldAnchorPositions.isEmpty, "the world keeps its own baked anchors")
        let routeConstraint = ResidentPropPlacementSupport.RouteConstraint(
            map: routeMap,
            anchorIDs: worldAnchorPositions.keys.sorted(),
            anchorPositions: worldAnchorPositions
        )
        let support = ResidentPropPlacementSupport(
            grid: grid, collision: derivation, routeConstraint: routeConstraint)

        let context = try WorldAgentContext(manifest: manifest, propFunctionSources: sources)
        let independent = ResidentPropPlacementConfiguration.independentCollisionVolumes(manifest)
        let combined = MarbleLivingCabinCollisionWorld(
            environment: mesh, props: CollisionVolumeWorld(volumes: independent))
        _ = try context.installCollisionWorldAndReconcilePlacement(combined)
        let service = ResidentPropPlacementService(context: context, support: { support })

        /// 独立实现的"局部点 → 世界点"：用与 `.place` 写进存档时同源的四元数
        /// `(0, sin(yaw/2), 0, cos(yaw/2))` 旋转，而不是抄一遍包里的旋转矩阵。
        func rotate(_ local: WorldVector3, _ position: WorldVector3, yaw: Float) -> WorldVector3 {
            let half = yaw / 2
            let u = SIMD3<Float>(0, sin(half), 0)
            let w = cos(half)
            let v = SIMD3<Float>(local.x, local.y, local.z)
            let t = 2 * simd_cross(u, simd_cross(u, v) + w * v)
            return WorldVector3(x: position.x + v.x + t.x,
                                y: position.y + v.y + t.y,
                                z: position.z + v.z + t.z)
        }

        // ── 断言 0：种子摆放（存档里没有这件道具）== 旧的烘焙几何 ──────────────
        let seedAnchor = try unwrap(context.propAnchorRegistry.entry(activityID: "wish_machine.collect"))
        let bakedPickup = try unwrap(manifest.waypoints.first { $0.id == "wish_machine.pickup" }?.position)
        check(distance(seedAnchor.position, bakedPickup) < 0.001,
              "the seed placement must reproduce the previously baked pickup anchor exactly")
        let seedOutlet = try unwrap(context.propAnchorRegistry.anchor(objectID: "wish_machine.device", role: "outlet"))
        let expectedSeedOutlet = rotate(
            try unwrap(machineDeclaration.declaration.point(role: "outlet")).position,
            machineDeclaration.seedPosition, yaw: machineDeclaration.seedYaw)
        check(distance(seedOutlet.position, expectedSeedOutlet) < 0.0001,
              "the seed outlet anchor must be declaration × seed transform")
        check(context.snapshot.activities.contains { $0.id == "wish_machine.collect" },
              "the machine's activity is discoverable while its anchors are registered")
        check(context.snapshot.activities.first { $0.id == "wish_machine.collect" }?.entryPlaceID == "wish_machine.pickup",
              "at the seed placement the planned entry is the baked pickup waypoint")

        // ── 把许愿机变成**可摆放**的物件，然后换一个位置 ─────────────────────
        // 摆放体积取小一点：被测的是**功能点几何**（一律来自声明）；footprint 只要在真实
        // 地面上放得下就行 —— 用真实 0.9×0.8 反而会把"找不到格子"混进来。
        let machine = WorldGeneratedProp(
            objectID: "wish_machine.device", sourceWishID: "test.wish", assetID: "test.wish",
            displayName: "许愿机", size: WorldVector3(x: 0.35, y: 0.35, z: 0.35), sourceHeight: 0.5)
        _ = try service.commit(.register(machine), expectedLayoutRevision: context.state.layoutRevision,
                              requestID: "register-machine")
        check(context.propAnchorRegistry.anchors(objectID: "wish_machine.device").isEmpty,
              "a prop that is registered but not placed puts no anchor in the world")

        let blocker = WorldGeneratedProp(
            objectID: "test.blocker", sourceWishID: "test.blocker", assetID: "test.blocker",
            displayName: "挡路箱", size: WorldVector3(x: 0.3, y: 0.3, z: 0.3), sourceHeight: 0.3)
        _ = try service.commit(.register(blocker), expectedLayoutRevision: context.state.layoutRevision,
                              requestID: "register-blocker")
        check(context.propAnchorRegistry.registeredActivityIDs == ["music.listen"],
              "with the machine unplaced only the jukebox keeps an activity entry, got \(context.propAnchorRegistry.registeredActivityIDs)")

        let floorHeight = try unwrap(grid.layers.map(\.supportHeight).min())
        let floorCells = grid.layers
            .filter { abs($0.supportHeight - floorHeight) < 0.05 }
            .map { layer in
                WorldVector3(x: Float(layer.column.x) * grid.spacing + grid.spacing * 0.5,
                             y: layer.supportHeight,
                             z: Float(layer.column.z) * grid.spacing + grid.spacing * 0.5)
            }
            .sorted { first, second in
                let firstDistance = distance(first, floorOfMachine)
                let secondDistance = distance(second, floorOfMachine)
                if firstDistance == secondDistance {
                    if first.x != second.x { return first.x < second.x }
                    return first.z < second.z
                }
                return firstDistance < secondDistance
            }
        check(!floorCells.isEmpty, "the real cabin derives floor cells")

        // 候选新位置：与烘焙位置**不同**（≥ 1.2 m）、放得下，而且把挡路箱放进它的
        // pickup 锚点那一格时，判定**恰好**因为那个注册锚点被占而拒绝。
        //
        // 每次尝试都真的走一遍 commit/withdraw：于是"这条判据真的会触发"是被实测出来的，
        // 而不是被假设的；找不到就 FAIL（绝不静默通过）。
        var target: WorldVector3?
        var blockerSpot: WorldVector3?
        var attempts = 0
        for cell in floorCells where distance(cell, floorOfMachine) >= 1.2 {
            guard (try? service.preview(objectID: machine.objectID,
                placement: .init(surfaceID: "grid", position: cell, yaw: 0))) != nil else { continue }
            let candidate = try? WorldPropAnchorRegistry(placements: [WorldPropFunctionPlacement(
                objectID: "wish_machine.device", position: cell, yaw: 0,
                declaration: machineDeclaration.declaration)])
            guard let pickup = candidate?.entry(activityID: "wish_machine.collect"),
                  routeMap.node(at: pickup.position) != nil else { continue }
            let column = PropSupportColumn(x: Int(floor(pickup.position.x / grid.spacing)),
                                           z: Int(floor(pickup.position.z / grid.spacing)))
            guard let layer = grid.layers.first(where: { $0.column == column }),
                  abs(layer.supportHeight - pickup.position.y) < 0.35 else { continue }
            let cellOfPickup = WorldVector3(
                x: Float(layer.column.x) * grid.spacing + grid.spacing * 0.5,
                y: layer.supportHeight,
                z: Float(layer.column.z) * grid.spacing + grid.spacing * 0.5)
            attempts += 1
            guard (try? service.commit(.place(objectID: machine.objectID,
                placement: .init(surfaceID: "grid", position: cell, yaw: 0)),
                expectedLayoutRevision: context.state.layoutRevision,
                requestID: "try-machine-\(attempts)")) != nil else { continue }
            // 只挑"几何上放得下这一格"的候选：判定**恰好点名注册锚点**、或者
            // **被接受**（= 判据漏了，交给断言 3 报 FAIL）。其它拒绝理由是几何问题，
            // 与本条断言无关，换一格。
            let verdict = blockerVerdict(service: service, blocker: blocker, at: cellOfPickup)
            if verdict != .other {
                target = cell
                blockerSpot = cellOfPickup
                break
            }
            _ = try? service.commit(.withdraw(objectID: machine.objectID),
                expectedLayoutRevision: context.state.layoutRevision,
                requestID: "try-withdraw-\(attempts)")
        }
        check(target != nil,
              "some floor cell must let the registered pickup anchor be the thing that blocks a placement (\(attempts) candidates tried)")
        let moved = try unwrap(target)
        let blockerCell = try unwrap(blockerSpot)

        // ── 断言 1：局部声明 × 新 transform == 注册出来的世界锚点 ─────────────
        let declaration = machineDeclaration.declaration
        for role in ["pickup", "outlet", "interact"] {
            let local = try unwrap(declaration.point(role: role))
            let registered = try unwrap(context.propAnchorRegistry.anchor(objectID: "wish_machine.device", role: role))
            let expected = rotate(local.position, moved, yaw: 0)
            check(distance(registered.position, expected) < 0.0001,
                  "\(role) anchor \(describe(registered.position)) must equal declaration × placement \(describe(expected))")
            check(distance(registered.position, local.position) > 0.05,
                  "\(role) anchor must have moved away from its local coordinates")
        }
        let movedPickup = try unwrap(context.propAnchorRegistry.entry(activityID: "wish_machine.collect"))
        check(distance(movedPickup.position, bakedPickup) > 1.0,
              "the moved pickup anchor must not be the baked value (\(describe(movedPickup.position)) vs \(describe(bakedPickup)))")
        check(context.propAnchorRegistry.registeredActivityIDs == ["music.listen", "wish_machine.collect"],
              "both the machine and the jukebox register their declared entries, got \(context.propAnchorRegistry.registeredActivityIDs)")
        check(abs(abs(movedPickup.yaw) - Float.pi) < 0.0001,
              "the pickup facing must follow the declaration (got \(movedPickup.yaw))")

        // ── 断言 3：放到会让锚点不可达的位置 ⇒ 拒绝，且没有半注册状态 ──────────
        let registryBefore = context.propAnchorRegistry
        let revisionBefore = context.state.layoutRevision
        let objectsBefore = context.state.objectStates
        var previewRejection: String?
        do {
            _ = try service.preview(objectID: blocker.objectID,
                placement: .init(surfaceID: "grid", position: blockerCell, yaw: 0))
        } catch {
            previewRejection = error.localizedDescription
        }
        check(previewRejection != nil, "putting a blocking prop on the registered pickup anchor must be rejected")
        check(previewRejection?.contains("wish_machine.device#pickup") == true,
              "the rejection must name the **registered** anchor, got: \(previewRejection ?? "nil")")
        do {
            _ = try service.commit(.place(objectID: blocker.objectID,
                placement: .init(surfaceID: "grid", position: blockerCell, yaw: 0)),
                expectedLayoutRevision: context.state.layoutRevision, requestID: "place-blocker")
            check(false, "the rejected placement must not commit")
        } catch {
            check(error.localizedDescription.contains("wish_machine.device#pickup"),
                  "the commit rejection must name the registered anchor, got: \(error.localizedDescription)")
        }
        check(context.state.layoutRevision == revisionBefore && context.state.objectStates == objectsBefore,
              "a rejected placement must not mutate the world (revision \(context.state.layoutRevision) vs \(revisionBefore))")
        check(context.propAnchorRegistry.anchors == registryBefore.anchors
                && context.propAnchorRegistry.routeAnchorPositions == registryBefore.routeAnchorPositions,
              "a rejected placement must leave the registry complete and unchanged (no half-registered state)")
        check(context.propAnchorRegistry.entry(activityID: "wish_machine.collect")?.position == movedPickup.position,
              "the activity entry must still be the last committed anchor")

        // ── 断言 2：移动后同一个活动走完，入口就是新锚点 ───────────────────────
        // （放在断言 3 之后：断言 3 要求居民还在出生点附近，否则"压住注册锚点"会被
        //  更早的"别把居民夹在墙里"判据遮住。）
        let entryPlaceAfterMove = try unwrap(
            context.snapshot.activities.first { $0.id == "wish_machine.collect" }?.entryPlaceID)
        check(entryPlaceAfterMove != "wish_machine.pickup",
              "planning must stop using the baked pickup waypoint once the machine moved")
        check(entryPlaceAfterMove != "wp.spawn" && entryPlaceAfterMove != "wp.center",
              "planning must resolve a real approach waypoint, got \(entryPlaceAfterMove)")

        try context.startActivity(id: "wish_machine.collect")
        for _ in 0..<1800 {
            try context.tick(deltaTime: 1.0 / 30)
            if context.snapshot.activeActivity?.phase == .loop { break }
        }
        let phase = context.snapshot.activeActivity?.phase
        check(phase == .loop, "the resident must complete the run on the moved anchor (phase=\(String(describing: phase)))")
        let reached = context.state.agentTransform.position
        let planarToAnchor = planarDistance(reached, movedPickup.position)
        check(planarToAnchor < 0.25,
              "the resident must finish on the registered anchor (distance=\(planarToAnchor), at \(describe(reached)))")
        let planarToBaked = planarDistance(reached, bakedPickup)
        check(planarToBaked > 1.0,
              "the resident must not have walked to the old baked pickup (\(planarToBaked))")
        try context.stopActivity()

        // ── 断言 4：收回 ⇒ 注销，活动不再把旧位置当入口 ────────────────────────
        _ = try service.commit(.withdraw(objectID: machine.objectID),
            expectedLayoutRevision: context.state.layoutRevision, requestID: "withdraw-machine")
        check(context.propAnchorRegistry.anchors(objectID: "wish_machine.device").isEmpty,
              "withdrawing the machine must unregister every one of its anchors")
        check(context.propAnchorRegistry.entry(activityID: "wish_machine.collect") == nil,
              "the withdrawn machine must not keep an activity entry")
        check(!context.snapshot.activities.contains { $0.id == "wish_machine.collect" },
              "the activity must disappear from discovery once its anchors are unregistered")
        var startRejected = false
        do { try context.startActivity(id: "wish_machine.collect") } catch { startRejected = true }
        check(startRejected, "the withdrawn machine's activity must not start")
        // 音箱仍然在：注册表是**按件**的生命周期，收回一件不影响另一件。
        let jukeboxEntry = try unwrap(context.propAnchorRegistry.entry(activityID: "music.listen"))
        check(distance(jukeboxEntry.position, try unwrap(
            manifest.waypoints.first { $0.id == "wp.jukebox" }?.position)) < 0.001,
              "the jukebox keeps its registered entry (derived from its own declaration) while the machine is withdrawn")

        // ── 断言 5：活动的**来源**必须显式区分，可开始性不能拿生成物件的规则审设备活动 ──
        // 居民能不能真的走到领取位置，取决于 App 允不允许 `start_activity
        // wish_machine.collect`。649e425 把功能点锚点活动也塞进 `propActivities`，
        // 而 `isPropCapabilityActivity` 当时是"在这个字典里就算生成物件能力活动"，
        // 于是设备活动被要求"enter 相位必须有已批准的 avatar 动作" —— 而它的 enter
        // 契约本来就是 `motionIDs == []`，判据恒为 false，居民**永远**进不了领取活动。
        //
        // 用**种子摆放**的新上下文做这一组断言（上面的上下文已经把机器收回了，
        // 收回后活动本就不该存在）。
        let seedContext = try WorldAgentContext(manifest: manifest, propFunctionSources: sources)
        _ = try seedContext.installCollisionWorldAndReconcilePlacement(combined)
        check(seedContext.isRegisteredFunctionPointActivity("wish_machine.collect"),
              "the machine's activity must be classified as a registered function-point activity")
        check(!seedContext.isPropCapabilityActivity("wish_machine.collect"),
              "the machine's activity must not be classified as a generated-prop capability activity")
        check(seedContext.isRegisteredFunctionPointActivity("music.listen"),
              "the jukebox's activity must be classified as a registered function-point activity")
        check(!seedContext.isPropCapabilityActivity("music.listen"),
              "the jukebox's activity must not be classified as a generated-prop capability activity")
        check(seedContext.activityCatalog.definition(id: "wish_machine.collect")?
                .contract(for: .enter)?.motionIDs.isEmpty == true,
              "the machine's enter phase declares no motion, so no motion can be missing")
        let installed: [String: StageMotionAsset] = [:] // 一个动作都没装：最少假设
        for avatarFormat in [StageAvatarFormat.pmx, StageAvatarFormat.vrm] {
            check(residentActivityAvailable(seedContext, "wish_machine.collect",
                    installed: installed, avatarFormat: avatarFormat),
                  "a resident on \(avatarFormat.rawValue) must be able to start the machine's collection activity")
            check(residentActivityAvailable(seedContext, "music.listen",
                    installed: installed, avatarFormat: avatarFormat),
                  "a resident on \(avatarFormat.rawValue) must be able to start the jukebox's activity")
        }
        // 门禁没有被拆掉：真实需要动作的表演活动，在没装动作时仍然不可开始。
        check(!residentActivityAvailable(seedContext, "performance.backflip",
                installed: installed, avatarFormat: .pmx),
              "a performance activity without its installed motion must stay unavailable")

        // ── 断言 6：领取判据里的"真的在跑"只能来自执行器一份事实 ────────────────
        // `snapshot.activeActivity` 把模拟状态的 id 与执行器的相位拼在一起：执行器没有 run 时
        // `ActivityExecutor.status` 走安全待机回退（activityID: nil, phase: .loop），于是
        // "相位是 loop"在什么都没跑时也成立。恢复一份"模拟状态记着领取活动、执行器还没接管"
        // 的存档就能造出这个不一致，它必须**不能**冒充"真的在跑"。
        struct StaleRestore: WorldStatePersisting {
            let state: WorldState
            func save(_ state: WorldState) throws {}
            func load() throws -> WorldState? { state }
        }
        var stale = seedContext.state
        stale.activeActivity = WorldActivityState(
            activityID: "wish_machine.collect", status: .running, startedAt: Date(timeIntervalSince1970: 0))
        let staleContext = try WorldAgentContext(
            manifest: manifest, persistence: StaleRestore(state: stale), propFunctionSources: sources)
        check(staleContext.snapshot.activeActivity?.id == "wish_machine.collect",
              "the restored simulation still records the collection activity")
        check(staleContext.snapshot.activeActivity?.phase == .loop,
              "an idle executor's safe-idle fallback reports phase loop, which is why the snapshot's phase cannot prove a run")
        check(staleContext.runningActivity == nil,
              "the executor's own fact must be nil when no run is executing, got \(String(describing: staleContext.runningActivity))")

        print("PASS: \(checks) prop function-point anchor checks; machine moved to \(describe(moved)); "
            + "blocker rejected at \(describe(blockerCell)); jukebox entry \(describe(jukeboxEntry.position))")
    }
}

enum BlockVerdict { case namedRegisteredAnchor, accepted, other }

/// 挡路箱放在这一格时，判定给了什么。`accepted` 是要**留给断言 3 去失败**的那一种：
/// 判据漏了注册锚点，这里绝不替它兜底。
@MainActor func blockerVerdict(service: ResidentPropPlacementService,
                              blocker: WorldGeneratedProp,
                              at position: WorldVector3) -> BlockVerdict {
    do {
        _ = try service.preview(objectID: blocker.objectID,
            placement: .init(surfaceID: "grid", position: position, yaw: 0))
        return .accepted
    } catch let error as ResidentPropPlacementError {
        if case let .blockedRoute(name) = error {
            return name == "wish_machine.device#pickup" ? .namedRegisteredAnchor : .other
        }
        return .other
    } catch {
        return .other
    }
}
"""#
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-prop-function-anchors-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let program = temporary.appendingPathComponent("Test.swift")
try harness.write(to: program, atomically: true, encoding: .utf8)
let executable = temporary.appendingPathComponent("test")
func run(_ binary: String, _ args: [String]) throws -> Int32 {
    let p = Process(); p.executableURL = URL(fileURLWithPath: binary); p.arguments = args
    try p.run(); p.waitUntilExit(); return p.terminationStatus
}
// WorldRuntime 的模块搜索路径 + 目标文件**只有一处定义**：tools/world-runtime-harness-flags.sh。
// 不要在这里拼 `.build/...`：27 份各自拼写正是 SwiftPM 与 xcodebuild 两份模块并存的根因。
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
let worldRuntimeFlags = worldRuntimeHarnessFlags()
let worldRuntimeModules = worldRuntimeFlags[1]
let objects = Array(worldRuntimeFlags.dropFirst(2))
let compiled = try run("/usr/bin/swiftc", ["-j1", "-parse-as-library", "-I", worldRuntimeModules,
    sourceRoot.appendingPathComponent("Agent/WorldAgentContext.swift").path,
    sourceRoot.appendingPathComponent("Presence/ResidentPerformanceMotionPolicy.swift").path,
    sourceRoot.appendingPathComponent("Presence/ResidentPropPlacementService.swift").path,
    sourceRoot.appendingPathComponent("Presence/ResidentPropPlacementConfiguration.swift").path,
    sourceRoot.appendingPathComponent("Presence/ResidentPropEditorState.swift").path,
    // 摆放试算上限的唯一策略定义（`RetryBackoffSite.propPlacement`）。
    sourceRoot.appendingPathComponent("Presence/RetryBackoff.swift").path,
    // 「我的物件」的唯一投影：面板状态现在从它现算行，编它就得一起编这一份。
    sourceRoot.appendingPathComponent("Presence/ResidentOwnershipProjection.swift").path,
    // 手持上限的替身（见文件头注释）：`ResidentPropPlacementService` 读那一份定义。
    root.appendingPathComponent("tools/fixtures/ResidentPropHoldLimitShim.swift").path,
    program.path, "-o", executable.path] + objects)
guard compiled == 0 else { exit(compiled) }
exit(try run(executable.path, Array(CommandLine.arguments.dropFirst())))

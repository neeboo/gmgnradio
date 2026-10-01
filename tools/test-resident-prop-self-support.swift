// 已摆物件的体积**不得**参与承托网格的派生：真机 2026-10-01「什么都摆不了」。
//
// 现象（真机实测，另一条线定位）：舱室里**任何一次** `place` 都被拒，理由
// 「这里不是可以摆放的承托面。」（`ResidentPropPlacementError.unknownSurface`）。
// 被拒的**不是**你要摆的那一件：`ResidentPropPlacementService.validate(_:)` 会复算
// 房间里**每一件**已摆物件的位置；斧头（`-2.625, -0.058583736, -2.375`）那一列
// `(-11,-10)` 整列没有承托层 —— 因为派生承托网格的碰撞世界里混进了**已摆物件的体积**，
// 而 `PropLayoutCollisionWorld.canTraverse`（`Agent/WorldAgentContext.swift:1406-1416`）
// 会沿途采样这些体积 ⇒ **斧头自己的盒子把它自己脚下那一列挤出网格**。
//
// 这个 harness 用**真实舱体几何 + 真权威快照**（`state.json`，斧头与咖啡机都已摆出）
// 钉住四件事（每一条在旧行为下都会红）：
//
//   1. **自己的体积不得抹掉自己脚下的承托列**：生产入口（`WorldAgentContext
//      .propSupportQuerying`）派生出的网格里，斧头那一列必须有层、且正好托着斧头；
//      同一份几何下把已摆物件体积塞进派生世界（旧行为），那一列必须整列消失
//      —— 机制被反向钉住，不是只断言"现在好了"。
//   2. **别人仍然挡它**：把另一件物件摆进斧头脚下 ⇒ 必须因为**互斥**被拒
//      （`blockedByPlacedProp(斧头)`），而不是因为"这一列不存在"。
//   3. **判据未放宽**：真实舱体地面格上「格子说可放 ⇔ 服务接受」仍然 100% 一致
//      （与 `test-resident-prop-one-judge.swift` 同一个判据，但这次房间里**真的摆着**
//      斧头与咖啡机）。
//   4. **真机能摆了**：修复后同一份快照上真的能 `commit(.place(...))` 落地一件，
//      而且修复前（旧行为）同一批格子**一格都提交不了**；`layoutRevision` 只在
//      那一次提交上 +1，复算不涨版本号；斧头与咖啡机仍在库、仍 `isEnabled`。
//
// 几何与快照路径：
// * 几何：`apps/macos/Resources/Worlds/marble-living-cabin`（与其余 harness 同一份）；
// * 快照：`$GMGN_STATE_JSON` > 本机真权威存档 > 仓里那份逐字备份
//   （`backups/world-state-migration/20261001T061021Z/state/marble-living-cabin/1.2.0/state.json`）。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceRoot = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
let bootstrap = try String(contentsOf: sourceRoot.appendingPathComponent("App/LivingWorldBootstrap.swift"), encoding: .utf8)
let start = bootstrap.range(of: "struct MarbleLivingCabinCollisionWorld:")!.lowerBound
let end = bootstrap.range(of: "/// An effect is keyed", range: start..<bootstrap.endIndex)!.lowerBound
let harness = #"""
import Foundation
import WorldRuntime
import simd
\#(bootstrap[start..<end])

/// 真权威快照：`state.json` 就是 `WorldState` 的 JSON（`.millisecondsSince1970`）。
/// 用它当 persistence 的 `load()`，上下文一构造出来就与真机冷启动时**同一份状态**
/// （斧头 + 咖啡机都已摆出）。
struct SnapshotPersistence: WorldStatePersisting {
    let snapshot: WorldState
    func save(_ state: WorldState) throws {}
    func load() throws -> WorldState? { snapshot }
}

@main struct SelfSupport {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ ok: Bool, _ message: String) {
            checks += 1
            guard ok else { print("FAIL: \(message)"); exit(1) }
        }

        // ---- 真实舱体几何 ----
        let worldRoot = URL(fileURLWithPath: "apps/macos/Resources/Worlds/marble-living-cabin")
        let manifest = try JSONDecoder().decode(WorldManifest.self,
            from: Data(contentsOf: worldRoot.appendingPathComponent("world.json")))
        struct Config: Decodable { struct Framing: Decodable { let origin: [Float]; let scale: Float }; let framing: Framing }
        let config = try JSONDecoder().decode(Config.self,
            from: Data(contentsOf: worldRoot.appendingPathComponent("marble.json")))
        let origin = SIMD3(config.framing.origin[0], config.framing.origin[1], config.framing.origin[2])
        let triangles = try GLBColliderDecoder().decode(
            data: Data(contentsOf: worldRoot.appendingPathComponent("collider.glb")),
            transform: WorldMeshTransform(axisConversion: .flipYAndZ, origin: origin,
                                          uniformScale: config.framing.scale))
        let mesh = TriangleMeshCollisionWorld(triangles: triangles)

        // ---- 真权威快照 ----
        let stateURL: URL = {
            if let override = ProcessInfo.processInfo.environment["GMGN_STATE_JSON"], !override.isEmpty {
                return URL(fileURLWithPath: override)
            }
            let live = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
                "Library/Application Support/ai.gmgn.radio/LivingWorld/marble-living-cabin/1.2.0/state.json")
            if FileManager.default.fileExists(atPath: live.path) { return live }
            return URL(fileURLWithPath:
                "backups/world-state-migration/20261001T061021Z/state/marble-living-cabin/1.2.0/state.json")
        }()
        let stateDecoder = JSONDecoder()
        stateDecoder.dateDecodingStrategy = .millisecondsSince1970
        let snapshot = try stateDecoder.decode(WorldState.self, from: Data(contentsOf: stateURL))
        check(snapshot.worldID == manifest.worldID,
              "快照与世界的 worldID 必须一致（快照 \(snapshot.worldID) / 世界 \(manifest.worldID)）")

        func displayName(_ item: WorldObjectState) -> String? {
            guard let raw = item.metadata["gmgn.generated-prop.v1"], let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return object["displayName"] as? String
        }
        let enabled = snapshot.objectStates.filter { $0.value.isEnabled }
        let axeID = enabled.first { displayName($0.value)?.contains("斧") == true }?.key
        let coffeeID = enabled.first { displayName($0.value)?.contains("咖啡") == true }?.key
        guard let axeID, let coffeeID else {
            print("FAIL: 真权威快照里必须有已摆出的斧头与咖啡机（实测已摆出 \(enabled.count) 件）")
            exit(1)
        }
        let axePosition = snapshot.objectStates[axeID]!.transform.position
        print("SNAPSHOT: \(stateURL.path) layoutRevision=\(snapshot.layoutRevision) 已摆出=\(enabled.count) 斧头=\(axeID) @(\(axePosition.x),\(axePosition.y),\(axePosition.z)) 咖啡机=\(coffeeID)")

        // ---- 生产同一份装配：环境网格 + manifest 家具体积；碰撞世界装进上下文 ----
        let base = MarbleLivingCabinCollisionWorld(
            environment: mesh,
            props: CollisionVolumeWorld(volumes: manifest.collisionVolumes))
        let context = try WorldAgentContext(manifest: manifest,
            persistence: SnapshotPersistence(snapshot: snapshot))
        _ = try context.installCollisionWorldAndReconcilePlacement(base)
        check(context.state.layoutRevision == snapshot.layoutRevision,
              "装上碰撞世界不得改 layoutRevision（快照 \(snapshot.layoutRevision) → 现在 \(context.state.layoutRevision)）")
        check(context.state.objectStates[axeID]?.isEnabled == true, "快照里那把斧头必须仍然是已摆出")
        check(context.state.objectStates[coffeeID]?.isEnabled == true, "快照里那台咖啡机必须仍然是已摆出")

        // ---- 派生网格：与宿主 `activateResidentPropGrid` 逐字同一条路 ----
        let parameters = PropSupportGridParameters()
        let waypointPositions = manifest.waypoints.filter(\.enabled).map(\.position)
        var minimumX = waypointPositions[0].x, maximumX = waypointPositions[0].x
        var minimumZ = waypointPositions[0].z, maximumZ = waypointPositions[0].z
        for position in waypointPositions {
            minimumX = min(minimumX, position.x); maximumX = max(maximumX, position.x)
            minimumZ = min(minimumZ, position.z); maximumZ = max(maximumZ, position.z)
        }
        let margin = parameters.spacing + parameters.capsuleRadius
        let bounds = WorldPlanarBounds(minimumX: minimumX - margin, maximumX: maximumX + margin,
                                       minimumZ: minimumZ - margin, maximumZ: maximumZ + margin)
        func derive(_ support: any WorldPropSupportQuerying) -> PropSupportGrid {
            PropSupportGridBuilder.build(
                collision: PropSupportDerivationWorld(
                    base: support, topVolumes: manifest.collisionVolumes.filter(\.isBlocking)),
                bounds: bounds, seed: manifest.spawn.position, parameters: parameters)
        }

        // 生产入口（修复点）：建造模式派生用的几何。旧行为下它就是"含已摆物件体积"的那一份。
        guard let productionSupport = context.propSupportQuerying else {
            print("FAIL: 建造模式拿不到承托几何（fail-closed，但不该发生在这个世界上）")
            exit(1)
        }
        // 旧行为：把**已摆物件体积**也算进派生世界（这正是修复前 `propSupportQuerying` 交出去的东西）。
        guard let layoutSupport = context.layoutCollisionWorld(for: context.state) as? any WorldPropSupportQuerying else {
            print("FAIL: 旧行为那一份（含已摆物件体积的包装世界）必须能给出三角形")
            exit(1)
        }
        let fixedGrid = derive(productionSupport)
        let erodedGrid = derive(layoutSupport)
        check(!fixedGrid.layers.isEmpty, "真实舱体派生出的承托网格不能为空")

        let spacing = fixedGrid.spacing
        func column(of position: WorldVector3) -> PropSupportColumn {
            PropSupportColumn(
                x: Int(((position.x - spacing * 0.5) / spacing).rounded()),
                z: Int(((position.z - spacing * 0.5) / spacing).rounded()))
        }
        func placement(_ layer: PropSupportLayerRef, yaw: Float = 0) -> WorldPropPlacement {
            .init(surfaceID: "grid.layer\(layer.layer)",
                  position: .init(x: Float(layer.column.x) * spacing + spacing * 0.5,
                                  y: layer.supportHeight,
                                  z: Float(layer.column.z) * spacing + spacing * 0.5),
                  yaw: yaw)
        }
        let axeColumn = column(of: axePosition)
        let fixedLayers = fixedGrid.layers(at: axeColumn)
        let erodedLayers = erodedGrid.layers(at: axeColumn)
        print("AXE COLUMN (\(axeColumn.x),\(axeColumn.z)): 修复后=\(fixedLayers.map { $0.supportHeight }) 旧行为=\(erodedLayers.map { $0.supportHeight })")
        // ① 自己的体积不得抹掉自己脚下的承托列
        check(!fixedLayers.isEmpty,
              "自己的体积不得抹掉自己脚下的承托列：列 (\(axeColumn.x),\(axeColumn.z)) 在生产网格里必须有层（实测 \(fixedLayers.count) 层）")
        check(fixedLayers.contains { abs($0.supportHeight - axePosition.y) < 0.005 },
              "那一列必须正好托着斧头（斧头 y=\(axePosition.y)，实测层 \(fixedLayers.map { $0.supportHeight })）")
        // 机制钉住：旧行为下整列消失（防止"修复"其实是把断言写松了）
        check(erodedLayers.isEmpty,
              "机制钉住：把已摆物件的体积混进派生世界，斧头自己那一列必须整列消失（实测 \(erodedLayers.count) 层）")

        // ---- 服务：与宿主同一个出口（格子 + 派生世界 + 移动图） ----
        let waypointHeights = manifest.waypoints.filter(\.enabled).map(\.position.y)
        let anchorIDs = Set(manifest.activities.compactMap(\.entryWaypointID)).sorted()
        var anchorPositions: [String: WorldVector3] = [:]
        for id in anchorIDs {
            if let waypoint = manifest.waypoints.first(where: { $0.id == id }) { anchorPositions[id] = waypoint.position }
        }
        func routeConstraint(for grid: PropSupportGrid) -> ResidentPropPlacementSupport.RouteConstraint {
            let map = WorldPlacementRouteMap(grid: grid,
                lowerHeight: waypointHeights.min()! - 0.2, upperHeight: waypointHeights.max()! + 0.2)
            return .init(map: map, anchorIDs: anchorIDs, anchorPositions: anchorPositions)
        }
        let derivation = PropSupportDerivationWorld(
            base: productionSupport, topVolumes: manifest.collisionVolumes.filter(\.isBlocking))
        let support = ResidentPropPlacementSupport(
            grid: fixedGrid, collision: derivation, routeConstraint: routeConstraint(for: fixedGrid))
        let service = ResidentPropPlacementService(context: context, support: { support })

        // 真机那把剑（另一条线给出的权威尺寸）。
        let sword = WorldGeneratedProp(objectID: "test.self-support-sword",
            sourceWishID: "self-support.sword", assetID: "self-support.sword.asset",
            displayName: "2B 白色长剑（外形摆件）",
            size: WorldVector3(x: 0.1462, y: 1.1, z: 0.0624), sourceHeight: 1.1)
        _ = try service.commit(.register(sword),
            expectedLayoutRevision: context.state.layoutRevision, requestID: "self-support.register-sword")
        check(context.state.objectStates[sword.objectID]?.isEnabled == false, "入库登记不得把剑放进空间")

        let floorHeight = fixedGrid.layers.map(\.supportHeight).min()!
        let cells = fixedGrid.layers.filter { $0.supportHeight < floorHeight + 0.3 }
        check(cells.count > 1000, "真机舱体的地面层必须有上千格（实测 \(cells.count)）")

        // ③ 判据未放宽：同一批真实落点「格子说可放 ⇔ 服务接受」必须 100% 一致。
        let model = ResidentPropGridEditorModel()
        model.installDerivedGrid(fixedGrid, collision: derivation, key: manifest.worldID)
        model.setRouteBand(fromWaypoints: manifest.waypoints)
        model.verdictForPlacement = { objectID, footprint, height, position, yaw in
            do {
                _ = try service.previewState(objectID: objectID,
                    placement: .init(surfaceID: "grid", position: position, yaw: yaw))
                return nil
            } catch {
                if case ResidentPropPlacementError.blockedRoute(let id) = error { return .blockedRoute(id) }
                if case ResidentPropPlacementError.blockedBySupport(let reason) = error { return reason }
                if case ResidentPropPlacementError.collision = error { return .blockedByMesh }
                return .noSupport
            }
        }
        model.invalidateVerdicts()
        var serviceAccepted = 0, serviceRejected = 0, agree = 0
        var rejectionExample: String?
        let revisionBeforeScan = context.state.layoutRevision
        for cell in cells {
            let requested = placement(cell)
            var allowed = true
            var rejectionReason: String?
            do { _ = try service.preview(objectID: sword.objectID, placement: requested) }
            catch { allowed = false; rejectionReason = error.localizedDescription }
            if allowed { serviceAccepted += 1 } else {
                serviceRejected += 1
                if rejectionExample == nil {
                    rejectionExample = "cell=(\(cell.column.x),\(cell.column.z)) \(rejectionReason ?? "?")"
                }
            }
            let footprint = WorldPlanarFootprint(size: SIMD2(sword.size.x, sword.size.z), yaw: 0)
            let reason = model.verdict(footprint: footprint, height: sword.size.y,
                                       layerRef: cell, objectID: sword.objectID)
            if (reason == nil) != allowed {
                print("FAIL: 格子与服务不一致 cell=(\(cell.column.x),\(cell.column.z)) 格子说可放=\(reason == nil) 服务接受=\(allowed) 原因=\(String(describing: reason))")
                exit(1)
            }
            agree += 1
        }
        check(agree == cells.count && serviceRejected > 0,
              "真实落点必须每一格都被两条路问过，且必须存在被拒的落点（问了 \(agree)/\(cells.count)，拒绝 \(serviceRejected)）")
        print("PASS[1]: \(agree)/\(agree) 格「格子说可放 ⇔ 服务接受」100% 一致（房间里真的摆着斧头 + 咖啡机；接受 \(serviceAccepted) 拒绝 \(serviceRejected)）")
        check(context.state.layoutRevision == revisionBeforeScan,
              "复算（\(cells.count) 格逐格判定）不得让 layoutRevision 乱涨（\(revisionBeforeScan) → \(context.state.layoutRevision)）")

        // ④ 真机能摆了：从这批格子里挑一格真的提交下去。
        var target: PropSupportLayerRef?
        for cell in cells where (try? service.preview(objectID: sword.objectID, placement: placement(cell))) != nil {
            target = cell; break
        }
        guard let target else {
            print("FAIL: 修复后真实舱体地面上一格都提交不了（实测 \(cells.count) 格全部被拒，例：\(rejectionExample ?? "-")）")
            exit(1)
        }
        let revisionBeforeCommit = context.state.layoutRevision
        let axeBefore = context.state.objectStates[axeID]
        let coffeeBefore = context.state.objectStates[coffeeID]
        _ = try service.commit(.place(objectID: sword.objectID, placement: placement(target)),
            expectedLayoutRevision: revisionBeforeCommit, requestID: "self-support.place-sword")
        check(context.state.objectStates[sword.objectID]?.isEnabled == true,
              "剑必须真的落地（列 (\(target.column.x),\(target.column.z)) y=\(target.supportHeight)）")
        check(context.state.layoutRevision == revisionBeforeCommit + 1,
              "一次提交只涨一个 layoutRevision（\(revisionBeforeCommit) → \(context.state.layoutRevision)）")
        print("PASS[2]: 真权威快照上一次真实提交落地 —— 剑 @列(\(target.column.x),\(target.column.z)) y=\(target.supportHeight)，layoutRevision \(revisionBeforeCommit) → \(context.state.layoutRevision)")
        // 面板 / `state.json` 的可复核变化：这一件在权威状态里写成了什么（与存档同形，
        // `.sortedKeys` 就是 `AtomicJSONWorldStatePersistence.save` 的编码姿势），
        // 以及斧头/咖啡机那两条**逐字节没变**。
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func encoded(_ item: WorldObjectState?) -> String {
            guard let item, let data = try? encoder.encode(item) else { return "nil" }
            return String(decoding: data, as: UTF8.self)
        }
        print("STATE.JSON objectStates[\(sword.objectID)] = \(encoded(context.state.objectStates[sword.objectID]))")
        check(encoded(context.state.objectStates[axeID]) == encoded(axeBefore),
              "斧头在权威状态里的那一条必须逐字节不变")
        check(encoded(context.state.objectStates[coffeeID]) == encoded(coffeeBefore),
              "咖啡机在权威状态里的那一条必须逐字节不变")

        // ② 别人仍然挡它：把另一件摆进斧头脚下 ⇒ 必须因为**互斥**被拒。
        let blocker = WorldGeneratedProp(objectID: "test.self-support-blocker",
            sourceWishID: "self-support.blocker", assetID: "self-support.blocker.asset",
            displayName: "挡路箱", size: WorldVector3(x: 0.5, y: 0.5, z: 0.5), sourceHeight: 0.5)
        _ = try service.commit(.register(blocker),
            expectedLayoutRevision: context.state.layoutRevision, requestID: "self-support.register-blocker")
        guard let axeLayer = fixedLayers.first(where: { abs($0.supportHeight - axePosition.y) < 0.005 }) else {
            print("FAIL: 斧头那一层必须在生产网格里（实测 \(fixedLayers.map { $0.supportHeight })）")
            exit(1)
        }
        let axePlacement = placement(PropSupportLayerRef(column: axeColumn, layer: axeLayer))
        do {
            _ = try service.preview(objectID: blocker.objectID, placement: axePlacement)
            check(false, "把另一件物件摆进斧头脚下必须被拒（别人仍然挡它）—— 实测被接受")
        } catch let error as ResidentPropPlacementError {
            guard case .blockedBySupport(.blockedByPlacedProp(let other)) = error else {
                check(false, "必须因为互斥被拒（blockedByPlacedProp），实测 \(error)")
                exit(1)
            }
            check(other == axeID || other == blocker.objectID,
                  "互斥拒绝必须点名房间里那件挡路的物件（实测 \(other)）")
            print("PASS[3]: 别人仍然挡它 —— 把挡路箱摆进斧头脚下被拒：\(error.errorDescription ?? "")（挡路的=\(other)）")
        } catch {
            check(false, "把另一件物件摆进斧头脚下必须被拒，且必须是摆放判据给出的拒绝（实测 \(error)）")
        }

        // 不回归：斧头与咖啡机仍在库、仍已摆出。
        check(context.state.objectStates[axeID]?.isEnabled == true, "斧头不得因为这次修复被改动")
        check(context.state.objectStates[coffeeID]?.isEnabled == true, "咖啡机不得因为这次修复被改动")
        check(context.state.objectStates[axeID]?.generatedProp != nil, "斧头必须仍在库（有 generatedProp）")
        check(context.state.objectStates[coffeeID]?.generatedProp != nil, "咖啡机必须仍在库（有 generatedProp）")

        // ---- 修复前 vs 修复后：同一份快照、同一批格子，能不能提交 ----
        let erodedContext = try WorldAgentContext(manifest: manifest,
            persistence: SnapshotPersistence(snapshot: snapshot))
        _ = try erodedContext.installCollisionWorldAndReconcilePlacement(base)
        let erodedDerivation = PropSupportDerivationWorld(
            base: layoutSupport, topVolumes: manifest.collisionVolumes.filter(\.isBlocking))
        let erodedSupport = ResidentPropPlacementSupport(
            grid: erodedGrid, collision: erodedDerivation, routeConstraint: routeConstraint(for: erodedGrid))
        let erodedService = ResidentPropPlacementService(context: erodedContext, support: { erodedSupport })
        let erodedSword = WorldGeneratedProp(objectID: "test.eroded-sword",
            sourceWishID: "self-support.eroded-sword", assetID: "self-support.eroded-sword.asset",
            displayName: "2B 白色长剑（外形摆件）",
            size: WorldVector3(x: 0.1462, y: 1.1, z: 0.0624), sourceHeight: 1.1)
        _ = try erodedService.commit(.register(erodedSword),
            expectedLayoutRevision: erodedContext.state.layoutRevision, requestID: "self-support.register-eroded")
        var erodedAccepted = 0
        for cell in cells {
            if (try? erodedService.preview(objectID: erodedSword.objectID, placement: placement(cell))) != nil {
                erodedAccepted += 1
            }
        }
        var erodedCommitError: String?
        do {
            _ = try erodedService.commit(.place(objectID: erodedSword.objectID, placement: placement(cells[0])),
                expectedLayoutRevision: erodedContext.state.layoutRevision, requestID: "self-support.place-eroded")
        } catch { erodedCommitError = error.localizedDescription }
        print("PASS[4]: 同一房间能摆放的格数 修复前 \(erodedAccepted)/\(cells.count) → 修复后 \(serviceAccepted)/\(cells.count)；修复前提交=\(erodedCommitError ?? "被接受")")
        check(serviceAccepted > erodedAccepted,
              "修复后能摆放的格数必须严格多于修复前（\(serviceAccepted) vs \(erodedAccepted)）")
        check(erodedAccepted == 0, "修复前同一份快照上一格都放不下（实测 \(erodedAccepted)/\(cells.count)）")
        check(erodedCommitError != nil, "修复前那次提交必须被拒（实测被接受）")

        print("PASS: \(checks) 项断言全部通过（真实舱体层=\(fixedGrid.layers.count) 地面格=\(cells.count) 斧头列=\(fixedLayers.map(\.supportHeight))）")
    }
}
"""#
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-selfsupport-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let program = temporary.appendingPathComponent("SelfSupport.swift")
try harness.write(to: program, atomically: true, encoding: .utf8)
// 宿主侧类型的最小替身：`ResidentPropGridEditorModel` 是 App 目标里的文件，离线编译它
// 需要 `ProductIdentity`（只是个常量）与 `log.showPrivacy`（让 `privacy:` 插值可解析）。
let prelude = temporary.appendingPathComponent("HostPrelude.swift")
try """
import Foundation
import os
enum ProductIdentity { static let displayName = "gmgn radio"; static let bundleIdentifier = "ai.gmgn.radio" }
extension Logger { var showPrivacy: Bool { get { false } set {} } }
""".write(to: prelude, atomically: true, encoding: .utf8)
// WorldRuntime 的模块搜索路径 + 目标文件**只有一处定义**：tools/world-runtime-harness-flags.sh。
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
let executable = temporary.appendingPathComponent("selfsupport")
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
p.arguments = ["-j1", "-parse-as-library", "-O", "-I", worldRuntimeModules,
    sourceRoot.appendingPathComponent("Agent/WorldAgentContext.swift").path,
    sourceRoot.appendingPathComponent("Presence/ResidentPropPlacementService.swift").path,
    sourceRoot.appendingPathComponent("Presence/ResidentPropPlacementConfiguration.swift").path,
    sourceRoot.appendingPathComponent("Presence/ResidentPropGridEditorModel.swift").path,
    sourceRoot.appendingPathComponent("Presence/PropSupportGridMapping.swift").path,
    sourceRoot.appendingPathComponent("Presence/PropSupportGridPresentation.swift").path,
    sourceRoot.appendingPathComponent("Presence/PropSupportGridPicker.swift").path,
    prelude.path,
    // 手持上限 + 挂点（slot）的替身：`ResidentPropPlacementService` 的签名读那两份定义。
    // 与 `tools/test-resident-prop-grid-placement.swift` 同一批替身（唯一一处定义，不抄）。
    root.appendingPathComponent("tools/fixtures/ResidentPropHoldLimitShim.swift").path,
    root.appendingPathComponent("tools/fixtures/PropAttachmentPointShim.swift").path,
    root.appendingPathComponent("tools/fixtures/PropAttachmentSlotShim.swift").path,
    program.path, "-o", executable.path] + objects
try p.run(); p.waitUntilExit()
guard p.terminationStatus == 0 else { print("compile failed"); exit(1) }
let r = Process(); r.executableURL = executable; r.arguments = []
try r.run(); r.waitUntilExit(); exit(r.terminationStatus)

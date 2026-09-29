// 服务层的摆放校验：在**真实舱体几何**上走完整的「格子 + footprint」路径。
//
// 这个脚本取代了原来的 `test-resident-prop-surfaces.swift`：主题从"具名摆放面"变成了
// "从几何派生出来的承托格子"。它验证的不是评估器本身（那有 WorldRuntime 的单测），
// 而是 `ResidentPropPlacementService` 把格子接进校验之后的整条链路：
// 格心上可放、不在格心上被拒、与已放物件重叠被拒、整块越界被拒、拿不到承托几何时 fail-closed。
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
struct Config: Decodable {
    struct Framing: Decodable { let origin: [Float]; let scale: Float }
    let framing: Framing
}
@main struct Test {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath:"apps/macos/Resources/Worlds/marble-living-cabin")
        let manifest = try JSONDecoder().decode(WorldManifest.self, from: Data(contentsOf:root.appendingPathComponent("world.json")))
        let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf:root.appendingPathComponent("marble.json")))
        let origin = SIMD3(config.framing.origin[0],config.framing.origin[1],config.framing.origin[2])
        let triangles = try GLBColliderDecoder().decode(data:Data(contentsOf:root.appendingPathComponent("collider.glb")),transform:WorldMeshTransform(axisConversion:.flipYAndZ,origin:origin,uniformScale:config.framing.scale))
        let mesh = TriangleMeshCollisionWorld(triangles:triangles)
        let physics = MarbleLivingCabinCollisionWorld(environment:mesh,props:CollisionVolumeWorld(volumes:manifest.collisionVolumes))
        var count = 0
        func check(_ ok:Bool,_ message:String) { count += 1; guard ok else { print("FAIL: \(message)");exit(1) } }

        // 用真实记录下来的咖啡机尺寸（与 test-resident-prop-render-gpu.swift 同一份）。
        let size=WorldVector3(x:0.35069498,y:0.41999996,z:0.56627256)
        let prop=WorldGeneratedProp(objectID:"test.coffee",sourceWishID:"test",assetID:"test",displayName:"咖啡机",size:size,sourceHeight:0.745393)

        // 承托范围与 App 一致：导航 waypoint 包络外扩一格 + 胶囊半径。
        var parameters = PropSupportGridParameters()
        let positions = manifest.waypoints.filter(\.enabled).map(\.position)
        var minimumX = positions[0].x, maximumX = positions[0].x
        var minimumZ = positions[0].z, maximumZ = positions[0].z
        for p in positions {
            minimumX=min(minimumX,p.x); maximumX=max(maximumX,p.x)
            minimumZ=min(minimumZ,p.z); maximumZ=max(maximumZ,p.z)
        }
        let margin = parameters.spacing + parameters.capsuleRadius
        // 与 App 相同：派生世界把家具体积的**顶面**也当作承托面（合成顶面三角形 +
        // y 受限的 groundHeight），否则真实展示台的桌面不会是承托层（§12 回归 2）。
        let derivation = PropSupportDerivationWorld(
            base: mesh, topVolumes: manifest.collisionVolumes.filter(\.isBlocking))
        let grid = PropSupportGridBuilder.build(
            collision: derivation,
            bounds: WorldPlanarBounds(minimumX:minimumX-margin,maximumX:maximumX+margin,
                                      minimumZ:minimumZ-margin,maximumZ:maximumZ+margin),
            seed: manifest.spawn.position,
            parameters: parameters)
        check(grid.report.seeded,"grid derivation is seeded from the spawn point")
        check(!grid.layers.isEmpty,"real cabin derives a non-empty support grid")
        check(!grid.layers.contains { $0.supportHeight >= 3 },"no layer sits on the roof")

        // 收窄后的路点判据（"居民还走不走得到活动锚点"）。
        //
        // 判据要的三样输入（可站带、锚点、居民当前位置）都来自**真实世界坐标**：路点高度与
        // 活动入口都在 y≈0、居民出生点在 (-1,-5)。本 harness 的**摆放几何**是真实舱体
        // 派生网格（`grid`/`derivation`），但那张网格不含"居民走的地面"这一层语义，
        // 所以移动图用一层解析地面表达"居民在这些路点高度上走"。真实舱体上的
        // 收窄前后对比在 `test-resident-prop-one-judge.swift`。
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
        let routeAnchorsByID: [String: WorldVector3] = { () -> [String: WorldVector3] in
            var result: [String: WorldVector3] = [:]
            for activity in manifest.activities {
                guard let waypoint = manifest.waypoints.first(where: {
                    $0.id == activity.entryWaypointID && $0.enabled
                }) else { continue }
                result[activity.entryWaypointID] = waypoint.position
            }
            return result
        }()
        let waypointHeights = manifest.waypoints.filter(\.enabled).map(\.position.y)
        let routeMap = WorldPlacementRouteMap(grid: groundGrid,
            lowerHeight: (waypointHeights.min() ?? 0) - 0.2,
            upperHeight: (waypointHeights.max() ?? 0) + 0.2)
        let routeConstraint: ResidentPropPlacementSupport.RouteConstraint? = (
            !routeAnchorsByID.isEmpty
                && routeMap.nearestNode(to: manifest.spawn.position) != nil
                && routeAnchorsByID.values.allSatisfy { routeMap.node(at: $0) != nil }
        ) ? .init(map: routeMap,
                  anchorIDs: routeAnchorsByID.keys.sorted(),
                  anchorPositions: routeAnchorsByID) : nil
        let support=ResidentPropPlacementSupport(grid:grid,collision:derivation,routeConstraint:routeConstraint)
        let context=try WorldAgentContext(manifest:manifest)
        let independent=ResidentPropPlacementConfiguration.independentCollisionVolumes(manifest)
        let combined=MarbleLivingCabinCollisionWorld(environment:mesh,props:CollisionVolumeWorld(volumes:independent))
        _=try context.installCollisionWorldAndReconcilePlacement(combined)
        let service=ResidentPropPlacementService(context:context,support:{ support })
        _=try service.commit(.register(prop),expectedLayoutRevision:0,requestID:"register")

        // 8. 回归 2 的终验收：**真实展示台的桌面**必须是承托层，而且真的能在上面摆放。
        guard let table=ResidentPropPlacementConfiguration.tableCollision(in:manifest) else {
            print("FAIL: the manifest declares the display table"); exit(1)
        }
        let tableTopY=table.center.y+table.halfExtents.y
        let tableLayers=grid.layers.filter { layer in
            abs(layer.supportHeight-tableTopY)<0.02
                && abs(Float(layer.column.x)*grid.spacing+grid.spacing*0.5-table.center.x)
                    <= table.halfExtents.x
                && abs(Float(layer.column.z)*grid.spacing+grid.spacing*0.5-table.center.z)
                    <= table.halfExtents.z
        }
        check(!tableLayers.isEmpty,"the real display table top is a support layer")
        // 把家具顶面当承托面**不能**把屋顶/天花板平面放回来。
        check(!grid.layers.contains { $0.supportHeight >= 3 },"furniture tops do not readmit the roof")
        guard let tableLayer=tableLayers.first else { exit(1) }
        func placement(_ layer:PropSupportLayerRef,_ yaw:Float=0) -> WorldPropPlacement {
            .init(surfaceID:"grid.layer\(layer.layer)",position:.init(
                x:Float(layer.column.x)*grid.spacing+grid.spacing*0.5,
                y:layer.supportHeight,
                z:Float(layer.column.z)*grid.spacing+grid.spacing*0.5),yaw:yaw)
        }

        // 1. 真实咖啡机在真实派生网格上**至少能放进某一格**（footprint 整块判定）。
        // 跨**整个网格**取样，而不是取连续一段：`grid.layers` 是按列推进的，取前若干层
        // 只会落在同一条窄带上（那里可能正好摆不下），得到"哪里都放不下"的假结论。
        var anchor:PropSupportLayerRef?
        var firstError:String?
        var sampled = 0
        for index in stride(from:0,to:grid.layers.count,by:3) {
            let layer = grid.layers[index]
            sampled += 1
            do { _=try service.preview(objectID:prop.objectID,placement:placement(layer)); anchor=layer; break }
            catch { if firstError == nil { firstError="\(error) / \(error.localizedDescription)" } }
        }
        guard let anchor else {
            print("FAIL: the real coffee never fits anywhere in the derived grid (\(sampled) anchors sampled); first error: \(firstError ?? "none")")
            exit(1)
        }
        // 用**真实展示台**做一件小物件（0.2×0.2）的摆放预检：桌面这一层必须能落地。
        let mug=WorldGeneratedProp(objectID:"test.mug",sourceWishID:"test.mug",assetID:"test.mug",
            displayName:"杯子",size:WorldVector3(x:0.2,y:0.2,z:0.2),sourceHeight:1)
        _=try service.commit(.register(mug),expectedLayoutRevision:context.state.layoutRevision,requestID:"register-mug")
        do {
            _=try service.preview(objectID:mug.objectID,placement:placement(tableLayer))
            check(true,"a mug previews on the real display table top (regression 2 acceptance)")
        } catch {
            check(false,"a mug on the real display table top (\(error.localizedDescription))")
        }
        check(true,"real coffee fits the derived grid at column (\(anchor.column.x),\(anchor.column.z)) y=\(anchor.supportHeight)")

        // 2. 吸附：离格心不到半格的偏移会被吸附到**同一列**，仍然可放。
        //    （校验是按吸附后的列做的，所以 0.4 格的偏移不会变成"另一个格子"。）
        do {
            let nudged=WorldVector3(x:Float(anchor.column.x)*grid.spacing+grid.spacing*0.9,
                                    y:anchor.supportHeight,
                                    z:Float(anchor.column.z)*grid.spacing+grid.spacing*0.5)
            _=try service.preview(objectID:prop.objectID,placement:.init(surfaceID:"grid",position:nudged,yaw:0))
            check(true,"a sub-half-cell offset snaps to the same column and stays placeable")
        } catch { check(false,"a sub-half-cell offset snaps to the same column (got \(error.localizedDescription))") }

        // 3. 网格之外 → 不是承托面。
        do {
            _=try service.preview(objectID:prop.objectID,placement:.init(
                surfaceID:"grid",position:.init(x:500,y:anchor.supportHeight,z:500),yaw:0))
            check(false,"a position far outside the grid is not a support surface")
        } catch ResidentPropPlacementError.unknownSurface { check(true,"a position far outside the grid is not a support surface") }

        // 4. 高度对不上任何一层 → 不是承托面（防止"把物件浮在半空"）。
        do {
            let floating=WorldVector3(x:Float(anchor.column.x)*grid.spacing+grid.spacing*0.5,
                                      y:anchor.supportHeight+50,
                                      z:Float(anchor.column.z)*grid.spacing+grid.spacing*0.5)
            _=try service.preview(objectID:prop.objectID,placement:.init(surfaceID:"grid",position:floating,yaw:0))
            check(false,"a height that matches no layer is not a support surface")
        } catch ResidentPropPlacementError.unknownSurface { check(true,"a height that matches no layer is not a support surface") }

        // 4. 真的摆下去，然后第二件放在同一格 → 与已放物件重叠被拒。
        _=try service.commit(.place(objectID:prop.objectID,placement:placement(anchor)),
                             expectedLayoutRevision:context.state.layoutRevision,requestID:"place")
        check(context.state.objectStates[prop.objectID]?.isEnabled == true,"the accepted placement lands")
        // `sourceWishID` 必须唯一：WorldSimulation 会拒绝同一愿望产出的第二件（invalidObject）。
let second=WorldGeneratedProp(objectID:"test.second",sourceWishID:"test.second",assetID:"test.second",displayName:"第二台",size:size,sourceHeight:0.745393)
        _=try service.commit(.register(second),expectedLayoutRevision:context.state.layoutRevision,requestID:"register2")
        do {
            _=try service.preview(objectID:second.objectID,placement:placement(anchor))
            check(false,"a second prop on the same cells is rejected")
        } catch ResidentPropPlacementError.blockedBySupport(let reason) {
            if case .blockedByPlacedProp = reason { check(true,"a second prop on the same cells is rejected") }
            else { check(false,"a second prop is rejected for the right reason (got \(reason))") }
        }

        // 5. 整块占地越出网格 → 越界拒绝。
        //
        // 尺寸要卡在两条线之间：**大于**网格 x 跨度（约 13.6 m）才会越界；**不大于**
        // `WorldPlanarFootprint.maximumColumnCount`（4096 列 = 每轴 16 m），否则
        // `columns` 返回空数组、报的是 insufficientClearance 而不是 outsideBounds。
        //
        // **必须用独立上下文**：如果和上一件放在同一格，`validate` 遍历的是**已放的那件**，
        // 它会因为被这件压住而报 blockedByPlacedProp —— 那是对的错误、错的期望。
        let huge=WorldGeneratedProp(objectID:"test.huge",sourceWishID:"test.huge",assetID:"test.huge",displayName:"大件",size:WorldVector3(x:15,y:0.4,z:15),sourceHeight:1)
        let hugeContext=try WorldAgentContext(manifest:manifest)
        _=try hugeContext.installCollisionWorldAndReconcilePlacement(combined)
        let hugeService=ResidentPropPlacementService(context:hugeContext,support:{ support })
        _=try hugeService.commit(.register(huge),expectedLayoutRevision:0,requestID:"register-huge")
        do {
            _=try hugeService.preview(objectID:huge.objectID,placement:placement(anchor))
            check(false,"a footprint wider than the grid is out of bounds (15 m beats the ~13.6 m grid x-range and stays under the 4096-column cap)")
        } catch ResidentPropPlacementError.blockedBySupport(let reason) {
            // 具体是越界还是"没有同一层的承托面"，取决于这个 footprint 相对网格**列范围**的位置：
            // 整体落在范围内就是 noSupport，超出范围才是 outsideBounds。两者都是几何拒绝，
            // 这条服务层断言要的是"被几何原因拒绝"，精确的 outsideBounds 由 WorldRuntime 单测覆盖。
            switch reason {
            case .outsideBounds, .noSupport, .insufficientClearance:
                check(true,"an oversized footprint is refused for a geometric reason (\(reason))")
            default:
                check(false,"an oversized footprint is refused geometrically, not by collision (got \(reason))")
            }
        }

        // 6. 拿不到承托几何 → fail-closed（而不是"随便放"）。
        let bare=try WorldAgentContext(manifest:manifest)
        let bareService=ResidentPropPlacementService(context:bare)
        _=try bareService.commit(.register(prop),expectedLayoutRevision:0,requestID:"register")
        do {
            _=try bareService.preview(objectID:prop.objectID,placement:.init(surfaceID:"grid",position:.init(x:0,y:0,z:0),yaw:0))
            check(false,"no support geometry refuses placement")
        } catch ResidentPropPlacementError.environmentNotReady { check(true,"no support geometry refuses placement") }

        // 7. 展示台的真实碰撞盒在网格里是空的。
        //
        // 这里**不再**断言"展示台不挡任何已授权路线"：那条静态不变量在接入运行时惰性重规划
        // （`ActivityExecutor` → `route(from:to:canTraverse:)`）之后已不是必需条件，导航问题
        // 也不该由摆放 harness 承担。
        //
        // 但真实数据实测**有 6 个 waypoint 因此运行时不可达**（不含展示台 649/649；含展示台
        // 643/649，全部是 `wp.auto.x-5/-6.z-9/-10/-11.h0`）。这是 `ba8ff40` 重烘焙引入的
        // 回归——删掉 `cabinSupportReservationIntersects` 时它同时移除了"把展示台 footprint
        // 排除出导航图"这件事。证据与修法见 `docs/plans/2026-09-27-p2-decoration-design.md` §12。
        // 展示台现在由 manifest 声明（不再硬编码在 App 里），所以这里也从 manifest 取。
        guard let stand=ResidentPropPlacementConfiguration.tableCollision(in:manifest) else {
            print("FAIL: the manifest declares the display table"); exit(1)
        }
        check(WorldPropMeshClearance.canPlace(stand,supportHeight:stand.center.y-stand.halfExtents.y,triangles:triangles),"table real box clear in mesh")
        // 8. 失败的预览不改库存状态。
        check(context.state.objectStates[second.objectID]?.isEnabled == false,"rejected previews preserve disabled inventory")

        // 9. 「点物件那一行必须进入携带态」——2026-09-28 真机缺陷，在**真实舱体几何**上验收。
        //
        // 症状：面板打开、地面铺满绿色可放格、行显示「已摆出」，但点它没有勾、没有高亮、
        // 下方也不出现任何控件。原因是面板的 `surfaces` 是宿主**推送**来的字段，而格子派生
        // 是异步的：就绪那一刻推送还没到，面板手里还是"派生中"的那一份（`surfaces` 为空），
        // `select()` 的承托守卫于是静默 return。
        //
        // 因此这里钉两条**行为**（不是"某行代码存在"）：
        //   - 承托面的**归并逻辑本身在真实房间里是好的**（就绪后非空、派生中为空）——
        //     即根因不是 `listedSupportLayers()` 的过滤条件；
        //   - 格子就绪后的那一份快照真的能让点一行进携带态。
        let derivingsService=ResidentPropPlacementService(context:context,support:{ nil })
        check(derivingsService.listedSupportLayers().isEmpty,
              "before the grid is derived the panel has no support surface at all (the stale snapshot of the defect)")
        let listed=service.listedSupportLayers()
        check(!listed.isEmpty,"the real cabin lists support layers once the grid is ready (\(listed.count) layers)")
        let editable=ResidentPropEditorState()
        editable.update(.init(worldID:manifest.worldID,revision:context.state.layoutRevision,
            objects:context.state.objectStates.values.filter { $0.generatedProp != nil }
                .sorted { $0.generatedProp!.objectID < $1.generatedProp!.objectID },
            surfaces:listed.enumerated().map { index,layer in
                ResidentPropEditorSurface(id:layer.id,
                    name:index == 0 ? "地面" : String(format:"台面 %.2f m",layer.supportHeight),
                    position:layer.center) },
            canUndo:false,heldProp:context.state.heldProp))
        editable.open()
        editable.preview = { id,placement in try service.preview(objectID:id,placement:placement) }
        await editable.select(objectID:prop.objectID)
        check(editable.selectedID == prop.objectID && editable.placement != nil && editable.isCarrying,
              "on the real cabin a row click enters the carrying state once the grid is ready (selectedID=\(editable.selectedID ?? "nil"), notice=\(editable.notice))")
        check(editable.candidate != nil,
              "the carrying state previews the prop at its own placement (preview=\(editable.candidate == nil ? "nil" : "set"), notice=\(editable.notice))")
        // 10.（任务 2）**还没摆出来**的物件的初始落点必须是"真的能放"的那一格。
        //
        // 旧行为：初始落点固定退到 `listedSupportLayers().first.center` —— 最低层里列序最小的格。
        //
        // 2026-09-29 收窄路点判据**之前**，真实生活舱实测那一格被"全部 643 个路点都要空着"
        // 那条判据挡住（footprint 是红的），于是自动初始落点必须另找。收窄之后那一格**可以放**
        // 了（这正是本次要修的缺陷：地板本来就不该被那条判据禁掉），所以这里的断言反过来：
        // 旧的默认点现在可放，而自动初始落点照样是一个真实格心、照样可放。
        let rookie=WorldGeneratedProp(objectID:"test.rookie",sourceWishID:"test.rookie",assetID:"test.rookie",
            displayName:"新物件",size:WorldVector3(x:0.2,y:0.2,z:0.2),sourceHeight:1)
        _=try service.commit(.register(rookie),expectedLayoutRevision:context.state.layoutRevision,requestID:"register-rookie")
        do {
            _=try service.preview(objectID:rookie.objectID,
                placement:.init(surfaceID:listed[0].id,position:listed[0].center,yaw:0))
            check(true,"after narrowing the route rule the old default landing spot is placeable again (this is the fix)")
        } catch {
            check(false,"the old default landing spot must be placeable once the route rule is narrowed (\(error.localizedDescription))")
        }
        let autoSurfaces=ResidentPropInitialPlacement.fillingAnchors(
            listed.enumerated().map { index,layer in
                ResidentPropEditorSurface(id:layer.id,
                    name:index == 0 ? "地面" : String(format:"台面 %.2f m",layer.supportHeight),
                    position:layer.center,cellCount:layer.cellCount) },
            grid:grid,spawn:manifest.spawn.position)
        let automatic=ResidentPropEditorState()
        automatic.update(.init(worldID:manifest.worldID,revision:context.state.layoutRevision,
            objects:context.state.objectStates.values.filter { $0.generatedProp != nil },
            surfaces:autoSurfaces,canUndo:false,heldProp:context.state.heldProp))
        automatic.open()
        automatic.preview = { id,placement in try service.preview(objectID:id,placement:placement) }
        await automatic.select(objectID:rookie.objectID)
        check(automatic.candidate != nil && automatic.isCarrying,
            "selecting a prop that is not placed yet must start on a placeable spot (candidate=\(automatic.candidate == nil ? "nil" : "set"), notice=\(automatic.notice))")
        // 而且那个落点必须是**真实存在的格心**（列号 × 间距 + 半格、层高一致），
        // 不是"断言某个具体坐标"：换世界、换尺寸它都得成立。
        check(automatic.placement.map { placement in grid.layers.contains { layer in
            abs(layer.supportHeight - placement.position.y) < 0.005
                && Float(layer.column.x) * grid.spacing + grid.spacing * 0.5 == placement.position.x
                && Float(layer.column.z) * grid.spacing + grid.spacing * 0.5 == placement.position.z
        } } ?? false,"the automatic landing spot is a real derived grid cell centre")

        print("PASS: \(count) real cabin grid placement checks; layers=\(grid.layers.count), coffee anchor y=\(anchor.supportHeight)")
    }
}
"""#
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-prop-grid-placement-\(UUID())")
try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:true)
defer { try? FileManager.default.removeItem(at:temporary) }
let program = temporary.appendingPathComponent("Test.swift")
try harness.write(to:program,atomically:true,encoding:.utf8)
let executable = temporary.appendingPathComponent("test")
func run(_ binary:String,_ args:[String]) throws -> Int32 {
    let p = Process(); p.executableURL=URL(fileURLWithPath:binary);p.arguments=args
    try p.run();p.waitUntilExit();return p.terminationStatus
}
let build = root.appendingPathComponent("apps/macos/Packages/WorldRuntime/.build/arm64-apple-macosx/debug")
let objects = try FileManager.default.contentsOfDirectory(at:build.appendingPathComponent("WorldRuntime.build"),includingPropertiesForKeys:nil).filter{$0.pathExtension == "o"}.map(\.path)
let compiled = try run("/usr/bin/swiftc",["-j1","-parse-as-library","-I",build.appendingPathComponent("Modules").path,
    sourceRoot.appendingPathComponent("Agent/WorldAgentContext.swift").path,
    sourceRoot.appendingPathComponent("Presence/ResidentPropPlacementService.swift").path,
    sourceRoot.appendingPathComponent("Presence/ResidentPropEditorState.swift").path,
    sourceRoot.appendingPathComponent("Presence/ResidentPropPlacementConfiguration.swift").path,
    program.path,"-o",executable.path]+objects)
guard compiled == 0 else { exit(compiled) }
exit(try run(executable.path,Array(CommandLine.arguments.dropFirst())))

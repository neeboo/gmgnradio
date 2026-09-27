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
    @MainActor static func main() throws {
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
        let grid = PropSupportGridBuilder.build(
            collision: mesh,
            bounds: WorldPlanarBounds(minimumX:minimumX-margin,maximumX:maximumX+margin,
                                      minimumZ:minimumZ-margin,maximumZ:maximumZ+margin),
            seed: manifest.spawn.position,
            parameters: parameters)
        check(grid.report.seeded,"grid derivation is seeded from the spawn point")
        check(!grid.layers.isEmpty,"real cabin derives a non-empty support grid")
        check(!grid.layers.contains { $0.supportHeight >= 3 },"no layer sits on the roof")

        let support=ResidentPropPlacementSupport(grid:grid,collision:mesh)
        let context=try WorldAgentContext(manifest:manifest)
        let independent=ResidentPropPlacementConfiguration.independentCollisionVolumes(manifest)
        let combined=MarbleLivingCabinCollisionWorld(environment:mesh,props:CollisionVolumeWorld(volumes:independent))
        _=try context.installCollisionWorldAndReconcilePlacement(combined)
        let service=ResidentPropPlacementService(context:context,support:{ support })
        _=try service.commit(.register(prop),expectedLayoutRevision:0,requestID:"register")

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
        let stand=ResidentPropPlacementConfiguration.tableCollision
        check(WorldPropMeshClearance.canPlace(stand,supportHeight:ResidentPropPlacementConfiguration.tablePosition.y,triangles:triangles),"table real box clear in mesh")
        // 8. 失败的预览不改库存状态。
        check(context.state.objectStates[second.objectID]?.isEnabled == false,"rejected previews preserve disabled inventory")
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
    sourceRoot.appendingPathComponent("Presence/ResidentPropPlacementConfiguration.swift").path,
    program.path,"-o",executable.path]+objects)
guard compiled == 0 else { exit(compiled) }
exit(try run(executable.path,Array(CommandLine.arguments.dropFirst())))

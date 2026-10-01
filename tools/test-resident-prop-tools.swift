// 摆件工具桥的委托/授权/幂等行为检查（无宿主、无网络）。
//
// 主题已经迁移到「格子 + footprint」：具名摆放面（`ResidentPropSupportSurface`）已从生产
// 代码删除，摆放校验改为「位置落在某一层格子的格心上 + `PropPlacementEvaluator` 整块
// footprint 判定」。下面用一张解析平面派生出真实的 `PropSupportGrid` 作为承托几何
// （等价于原来那张具名面 `test`；`surface_id` 现在只是状态里的层标签）。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sources = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
let bridge = sources.appendingPathComponent("Agent/ResidentPropToolBridge.swift")
guard FileManager.default.fileExists(atPath: bridge.path) else { print("FAIL: resident placement tools missing"); exit(1) }
let harness = #"""
import Foundation
import WorldRuntime
struct RealtimeDJToolResult { let callID:String;let resultJSON:Data;let isError:Bool }
enum ResidentWorldToolSession {
    struct AdditionalTool {
        let name:String;let description:String;let inputSchema:[String:Any]
        let validate:([String:Any])->Bool
        let handle:@MainActor (String,Data) async -> RealtimeDJToolResult
    }
}
@MainActor final class Current { var value = true }
/// 合成承托几何：一张水平承托层（旧具名摆放面 `test` 的等价物）。
///
/// 摆放校验现在要的是「格子 + 承托几何」，所以承托面必须由几何派生：这张解析平面给出
/// 承托高度与覆盖范围，`groundHeight` 遵守 y 受限契约（只报不高于查询点的承托面），
/// 列扫描才能收敛成"一列一层"。
struct FlatSupport: WorldPropSupportQuerying {
    let minimumX:Float; let maximumX:Float; let minimumZ:Float; let maximumZ:Float; let height:Float
    func canOccupy(_ capsule:WorldCapsule,at position:SIMD3<Float>)->Bool { true }
    func groundHeight(at position:SIMD3<Float>)->Float? {
        guard position.x >= minimumX, position.x <= maximumX,
              position.z >= minimumZ, position.z <= maximumZ else { return nil }
        return height <= position.y + 0.05 ? height : nil
    }
    func canTraverse(_ capsule:WorldCapsule,from start:SIMD3<Float>,to destination:SIMD3<Float>,maximumStepHeight:Float)->Bool { true }
    func triangles(in bounds:WorldPlanarBounds)->[WorldTriangle] {
        guard bounds.maximumX >= minimumX, bounds.minimumX <= maximumX,
              bounds.maximumZ >= minimumZ, bounds.minimumZ <= maximumZ else { return [] }
        let a=SIMD3<Float>(minimumX,height,minimumZ),b=SIMD3<Float>(maximumX,height,minimumZ)
        let c=SIMD3<Float>(maximumX,height,maximumZ),d=SIMD3<Float>(minimumX,height,maximumZ)
        return [WorldTriangle(a,b,c),WorldTriangle(a,c,d)]
    }
}
/// 与旧面 `test` 同范围同高度：中心 (-2.7, 0.52, -5)、半长 (1, 0, 1)。
let flatWorld=FlatSupport(minimumX:-3.7,maximumX:-1.7,minimumZ:-6,maximumZ:-4,height:0.52)

/// 收窄后的路点约束：与生产**同一条**推导。
///
/// 判据要的三样东西必须取自**同一个世界**：可站带（路点高度）、锚点位置、居民当前位置。
/// 合成平面上的验证要用合成世界的路点/居民 —— 拿真实舱体的路点给合成平面算，居民与锚点
/// 根本不在同一片坐标里，判据只会 fail-closed 拒绝一切（那正是它该做的）。
///
/// 拿不到可用节点时返回 nil ⇒ 服务拒绝摆放（fail-closed）。
@MainActor func routeConstraint(_ grid:PropSupportGrid,
                                anchorCandidates:[WorldVector3],
                                resident:WorldVector3)->ResidentPropPlacementSupport.RouteConstraint? {
 func usable(_ p:WorldVector3)->Bool {
   let limit:Float=1e6
   return p.x.isFinite && p.y.isFinite && p.z.isFinite
     && abs(p.x)<limit && abs(p.y)<limit && abs(p.z)<limit
 }
 let heights=[resident.y]+anchorCandidates.map(\.y)
 guard let lowest=heights.min(), let highest=heights.max(),
       anchorCandidates.allSatisfy(usable), usable(resident) else { return nil }
 let map=WorldPlacementRouteMap(grid:grid,lowerHeight:lowest-0.6,upperHeight:highest+0.6)
 guard map.nearestNode(to:resident) != nil else { return nil }
 var positions:[String:WorldVector3]=[:]
 for candidate in anchorCandidates where map.node(at:candidate) != nil {
   positions["anchor.\(positions.count)"]=candidate
 }
 guard !positions.isEmpty else { return nil }
 return .init(map:map,anchorIDs:positions.keys.sorted(),anchorPositions:positions)
}

/// 站立地面 + 台面的合成世界：`flatWorld` 只覆盖那一小块台面，而"居民还走不走得到
/// 活动入口"这条判据要的是**居民与锚点所站的整片地面**。所以台面之外再给一层 y=0 的地面。
struct FlatRoomAndTable: WorldPropSupportQuerying {
    let minimumX:Float; let maximumX:Float; let minimumZ:Float; let maximumZ:Float
    let table:FlatSupport
    func canOccupy(_ capsule:WorldCapsule,at position:SIMD3<Float>)->Bool { true }
    func groundHeight(at position:SIMD3<Float>)->Float? {
        var candidates:[Float]=[]
        if position.x >= minimumX, position.x <= maximumX,
           position.z >= minimumZ, position.z <= maximumZ,
           0 <= position.y + 0.05 { candidates.append(0) }
        if let tableHeight=table.groundHeight(at:position) { candidates.append(tableHeight) }
        return candidates.max()
    }
    func canTraverse(_ capsule:WorldCapsule,from start:SIMD3<Float>,to destination:SIMD3<Float>,
                     maximumStepHeight:Float)->Bool { true }
    /// 三角形顺序决定层号：地面在前（layer 0）、台面在后（layer 1）。
    func triangles(in bounds:WorldPlanarBounds)->[WorldTriangle] {
        var result:[WorldTriangle]=[]
        if bounds.maximumX >= minimumX, bounds.minimumX <= maximumX,
           bounds.maximumZ >= minimumZ, bounds.minimumZ <= maximumZ {
            let a=SIMD3<Float>(minimumX,0,minimumZ),b=SIMD3<Float>(maximumX,0,minimumZ)
            let c=SIMD3<Float>(maximumX,0,maximumZ),d=SIMD3<Float>(minimumX,0,maximumZ)
            result.append(WorldTriangle(a,b,c)); result.append(WorldTriangle(a,c,d))
        }
        result.append(contentsOf:table.triangles(in:bounds))
        return result
    }
}
@MainActor func flatSupport()->ResidentPropPlacementSupport {
    let room=FlatRoomAndTable(minimumX:-8,maximumX:8,minimumZ:-10,maximumZ:2,table:flatWorld)
    let bounds=WorldPlanarBounds(minimumX:-8,maximumX:8,minimumZ:-10,maximumZ:2)
    let grid=PropSupportGridBuilder.build(collision:room,bounds:bounds,
                                          seed:WorldVector3(x:0,y:0,z:0),parameters:PropSupportGridParameters())
    // 活动入口与居民都在**地面**上（世界路点 y=0）；台面（y=0.52）只用来摆物件。
    let anchors:[WorldVector3]=[
        WorldVector3(x:-2.0,y:0,z:-5.0),
        WorldVector3(x:-1.0,y:0,z:-3.0),
    ]
    return ResidentPropPlacementSupport(grid:grid,collision:room,
        routeConstraint:routeConstraint(grid,anchorCandidates:anchors,
                                        resident:WorldVector3(x:0,y:0,z:0)))
}
@main struct Tests {
    @MainActor static func main() async throws {
        let data=try Data(contentsOf:URL(fileURLWithPath:"apps/macos/Resources/Worlds/marble-living-cabin/world.json"))
        let manifest=try JSONDecoder().decode(WorldManifest.self,from:data)
        let context=try WorldAgentContext(manifest:manifest)
        // 承托层由几何派生：范围与旧的具名面 `test` 相同（展示台桌面高度 0.52 m）。
        let flat=flatSupport()
        let current=Current()
        let service=ResidentPropPlacementService(context:context,support:{flat},isCurrent:{current.value},
            currentAvatarAssetID:{"pmx.2b-miss-0414-standard"},makeGripCalibration:{ prop, avatarID, point in
                // 挂点跟着调用方给的那一个走（`point.worldSlot`）：换挂点时标定里的挂点必须跟着变，
                // 否则世界那条 `.adjustGrip` 会以"标定说的挂点不是它"为由拒绝。
                WorldPropGripCalibration(avatarAssetID:avatarID,hand:point.worldSlot,
                    normalizedGrip:.init(x:0.5,y:0.5,z:0.5),localOffset:.init(x:0,y:0,z:0),
                    localRotation:.init(x:0,y:0,z:0,w:1))
            })
        let prop=WorldGeneratedProp(objectID:"owned",sourceWishID:"wish",assetID:"sha256:fixture",displayName:"摆件",size:.init(x:0.2,y:0.3,z:0.2),sourceHeight:1)
        _=try service.commit(.register(prop),expectedLayoutRevision:0,requestID:"register")
        let readonly=ResidentPropToolBridge(service:service,allowsMutation:false,isCurrent:{current.value})
        let human=ResidentPropToolBridge(service:service,allowsMutation:true,isCurrent:{current.value})
        var checks=0
        func check(_ value:Bool,_ message:String){checks += 1;if !value {print("FAIL: \(message)");exit(1)}}
        func invoke(_ bridge:ResidentPropToolBridge,_ name:String,_ arguments:[String:Any],_ id:String="call") async throws -> RealtimeDJToolResult {
            let tool=bridge.tools.first{$0.name == name}!
            return await tool.handle(id,try JSONSerialization.data(withJSONObject:arguments))
        }
        func payload(_ result:RealtimeDJToolResult)->[String:Any]{(try! JSONSerialization.jsonObject(with:result.resultJSON)) as! [String:Any]}
        // `delete_prop`（永久删除一件生成资产）是第十一个原语工具：它和别的原语一样
        // 走同一条 grant/白名单与同一份契约，所以这里钉住"工具面就是这十一件、不多不少"。
        check(Set(human.tools.map(\.name)) == ["read_owned_props","list_placement_surfaces","preview_prop_placement","apply_prop_placement","withdraw_prop","undo_prop_placement","hold_prop","adjust_held_prop_grip","return_held_prop","enable_prop_capability","delete_prop"],"eleven primitive tools")
        let schemas=try JSONSerialization.data(withJSONObject:human.tools.map{$0.inputSchema},options:.sortedKeys)
        check(schemas == (try JSONSerialization.data(withJSONObject:readonly.tools.map{$0.inputSchema},options:.sortedKeys)),"human/background schema stable")
        let read=try await invoke(readonly,"read_owned_props",[:])
        check(!read.isError && (payload(read)["layout_revision"] as? Int) == 1,"read persisted inventory revision")
        check(String(decoding:read.resultJSON,as:UTF8.self).contains("摆件") && !String(decoding:read.resultJSON,as:UTF8.self).contains("/Users/"),"read inventory without paths")
        var place:[String:Any]=["object_id":"owned","surface_id":"test","x":-2.7,"y":0.52,"z":-5,"yaw":0]
        let before=context.state
        let preview=try await invoke(readonly,"preview_prop_placement",place)
        check(!preview.isError && context.state == before,"background preview has no mutation")
        place["layout_revision"]=1
        check(try await invoke(readonly,"apply_prop_placement",place).isError && context.state == before,"background placement denied")
        check(!(try await invoke(human,"apply_prop_placement",place,"place")).isError && context.state.objectStates["owned"]?.isEnabled == true,"human same service placement")
        check(try await invoke(human,"apply_prop_placement",place,"stale").isError,"stale layout rejected")
        let applied=context.state
        check(!(try await invoke(human,"apply_prop_placement",place,"place")).isError && context.state == applied,"duplicate idempotent mutation")
        check(try await invoke(readonly,"withdraw_prop",["object_id":"owned","layout_revision":2]).isError,"background withdrawal denied")
        check(!(try await invoke(human,"withdraw_prop",["object_id":"owned","layout_revision":2],"withdraw")).isError,"human withdraw")
        check(context.state.objectStates["owned"]?.isEnabled == false,"withdraw keeps inventory")
        check(!(try await invoke(human,"undo_prop_placement",["layout_revision":3],"undo")).isError && context.state.objectStates["owned"]?.isEnabled == true,"one undo restores")
        check(try await invoke(human,"undo_prop_placement",["layout_revision":4],"undo2").isError,"second undo rejected")
        let placedBeforeHold=context.state.objectStates["owned"]!
        check(try await invoke(readonly,"hold_prop",["object_id":"owned","layout_revision":4],"background-hold").isError,"background hold denied")
        check(!(try await invoke(human,"hold_prop",["object_id":"owned","layout_revision":4],"hold")).isError,"human hold accepted")
        check(context.state.heldProp?.objectID == "owned" && context.state.objectStates["owned"]?.isEnabled == false,"hold reuses one object identity")
        let heldRead=try await invoke(readonly,"read_owned_props",[:],"read-held")
        check(String(decoding:heldRead.resultJSON,as:UTF8.self).contains("\"is_held\":true"),"read reports held fact")
        let grip:[String:Any]=["object_id":"owned","layout_revision":5,"offset_x":0.02,"offset_y":0.01,"offset_z":-0.03,"rotation_yaw":0.2]
        check(!(try await invoke(human,"adjust_held_prop_grip",grip,"grip")).isError,"human grip adjustment accepted")
        check(context.state.objectStates["owned"]?.gripCalibration?.localOffset.x == 0.02,"grip saved on same object")
        check(!(try await invoke(human,"return_held_prop",["object_id":"owned","layout_revision":6],"return")).isError,"human return accepted")
        check(context.state.heldProp == nil && context.state.objectStates["owned"]?.transform == placedBeforeHold.transform,"return restores exact placement")
        let stable=context.state
        current.value=false
        check(try await invoke(human,"withdraw_prop",["object_id":"owned","layout_revision":7],"stopped").isError && context.state == stable,"stop revokes lease")
        current.value=true
        place["layout_revision"]=true
        check(try await invoke(human,"apply_prop_placement",place).isError,"boolean revision rejected")
        place["layout_revision"]=7;place["model_path"]="/tmp/fake.glb"
        check(try await invoke(human,"apply_prop_placement",place).isError,"caller cannot inject asset paths")
        let surfaces=try await invoke(human,"list_placement_surfaces",[:])
        check(!surfaces.isError && String(decoding:surfaces.resultJSON,as:UTF8.self).contains("half_extents"),"surfaces include usable geometry")
        // ---- delegated background placement grant ----
        let otherProp=WorldGeneratedProp(objectID:"other",sourceWishID:"wish2",assetID:"sha256:fixture2",displayName:"花瓶",size:.init(x:0.2,y:0.3,z:0.2),sourceHeight:1)
        check(!(try await invoke(human,"withdraw_prop",["object_id":"owned","layout_revision":7],"withdraw2")).isError,"human withdraw resets inventory for delegation test")
        _=try service.commit(.register(otherProp),expectedLayoutRevision:context.state.layoutRevision,requestID:"register2")
        let grant=ResidentPropDelegatedGrant(objectID:"owned",allowedSurfaceIDs:["test"],target:.init(surfaceID:"test",position:.init(x:-2.7,y:0.52,z:-5),yaw:0),requestID:"placement.stable")
        let delegated=ResidentPropToolBridge(service:service,allowsMutation:false,isCurrent:{current.value},delegatedGrant:grant)
        check(!(try await invoke(delegated,"apply_prop_placement",["object_id":"owned","surface_id":"test","x":-2.7,"y":0.52,"z":-5,"yaw":0,"layout_revision":context.state.layoutRevision],"delegated-place")).isError,"background delegated apply at exact target allowed")
        check(context.state.objectStates["owned"]?.isEnabled == true,"delegated apply places only object")
        let afterGrant=context.state
        check(!(try await invoke(delegated,"apply_prop_placement",["object_id":"owned","surface_id":"test","x":-2.7,"y":0.52,"z":-5,"yaw":0,"layout_revision":afterGrant.layoutRevision],"delegated-place")).isError && context.state == afterGrant,"stable request id makes delegated retry idempotent")
        check(try await invoke(delegated,"apply_prop_placement",["object_id":"owned","surface_id":"test","x":-2.7,"y":0.52,"z":-5,"yaw":0.5,"layout_revision":context.state.layoutRevision],"rotated").isError,"delegated background cannot rotate incrementally")
        check(try await invoke(delegated,"apply_prop_placement",["object_id":"other","surface_id":"test","x":-2.7,"y":0.52,"z":-5,"yaw":0,"layout_revision":context.state.layoutRevision],"other-place").isError,"delegated background cannot place another object")
        check(try await invoke(delegated,"withdraw_prop",["object_id":"owned","layout_revision":context.state.layoutRevision]).isError,"delegated background cannot withdraw")
        check(try await invoke(delegated,"undo_prop_placement",["layout_revision":context.state.layoutRevision]).isError,"delegated background cannot undo")
        check(try await invoke(delegated,"hold_prop",["object_id":"owned","layout_revision":context.state.layoutRevision]).isError,"delegated background cannot hold")
        check(!(try await invoke(delegated,"preview_prop_placement",["object_id":"owned","surface_id":"test","x":-2.7,"y":0.52,"z":-5,"yaw":0])).isError,"delegated background may preview own object")
        check(try await invoke(delegated,"preview_prop_placement",["object_id":"other","surface_id":"test","x":-2.7,"y":0.52,"z":-5,"yaw":0]).isError,"delegated background preview limited to delegated object")
        check(context.state == afterGrant,"denied delegated mutations leave state untouched")
        check(!(try await invoke(human,"apply_prop_placement",["object_id":"owned","surface_id":"test","x":-2.7,"y":0.52,"z":-5,"yaw":0,"layout_revision":context.state.layoutRevision],"human-place")).isError,"ordinary current-human mutation unaffected by delegation")
        // ---- dynamic delegation resolve/record callbacks ----
        final class DynamicBox { var state = "pending"; var records = 0; var boundTarget: WorldPropPlacement? }
        let box = DynamicBox()
        let dynamicBridge = ResidentPropToolBridge(service: service, allowsMutation: false, isCurrent: { current.value },
            resolveDelegatedGrant: { objectID, placement in
                guard objectID == "owned", box.state == "pending", placement.surfaceID == "test" else { throw ResidentPropDelegationError.inactiveDelegation }
                box.boundTarget = placement
                return ResidentPropDelegatedGrant(objectID: "owned", allowedSurfaceIDs: ["test"], target: placement, requestID: "placement.dynamic")
            },
            recordDelegatedPlacement: { grant, placement in
                guard grant.requestID == "placement.dynamic", placement == box.boundTarget else { throw ResidentPropDelegationError.requestChanged }
                box.records += 1; box.state = "placed"
            })
        check(!(try await invoke(human, "withdraw_prop", ["object_id": "owned", "layout_revision": context.state.layoutRevision], "dynamic-reset")).isError, "human withdraw resets for dynamic grant test")
        let chosen: [String: Any] = ["object_id": "owned", "surface_id": "test", "x": -2.7, "y": 0.52, "z": -5, "yaw": 0.1, "layout_revision": context.state.layoutRevision]
        check(!(try await invoke(dynamicBridge, "apply_prop_placement", chosen, "dynamic-place")).isError && context.state.objectStates["owned"]?.isEnabled == true, "surface-only dynamic grant places model-chosen legal target")
        check(box.records == 1 && box.boundTarget?.yaw == Float(0.1), "completion recorded once after durable commit")
        let afterDynamic = context.state
        check(try await invoke(dynamicBridge, "apply_prop_placement", chosen, "dynamic-retry").isError && context.state == afterDynamic, "placed delegation rejects retry without duplicate effect")
        box.state = "pending"
        check(try await invoke(dynamicBridge, "apply_prop_placement", ["object_id": "owned", "surface_id": "elsewhere", "x": -2.7, "y": 0.52, "z": -5, "yaw": 0, "layout_revision": context.state.layoutRevision], "dynamic-wrong-surface").isError, "wrong surface candidate rejected")
        check(!(try await invoke(dynamicBridge, "apply_prop_placement", chosen, "dynamic-again")).isError, "later legal candidate still accepted after invalid one")
        // Stop during await revokes the dynamic grant without touching isCurrent.
        final class RevokeBox { var state = "pending"; var records = 0 }
        let revokeBox = RevokeBox()
        let revokeBridge = ResidentPropToolBridge(service: service, allowsMutation: false, isCurrent: { current.value },
            prepareMutation: { _ in revokeBox.state = "revoked" },
            delegatedGrant: ResidentPropDelegatedGrant(objectID: "owned", allowedSurfaceIDs: ["test"], target: nil, requestID: "placement.revoke-snapshot"),
            resolveDelegatedGrant: { objectID, placement in
                guard objectID == "owned", revokeBox.state == "pending", placement.surfaceID == "test" else { throw ResidentPropDelegationError.inactiveDelegation }
                return ResidentPropDelegatedGrant(objectID: "owned", allowedSurfaceIDs: ["test"], target: placement, requestID: "placement.revoke")
            },
            recordDelegatedPlacement: { _, _ in revokeBox.records += 1 })
        let beforeRevoke = context.state
        check(try await invoke(revokeBridge, "apply_prop_placement", ["object_id": "owned", "surface_id": "test", "x": -2.7, "y": 0.52, "z": -5, "yaw": 0, "layout_revision": context.state.layoutRevision], "revoke-during-await").isError && context.state == beforeRevoke, "stop during await revokes dynamic grant and rejects commit")
        check(revokeBox.records == 0, "revoked grant never records completion")
        // Canonical float coordinates: JSON decimals must match persisted Float targets.
        let decimalGrant = ResidentPropDelegatedGrant(objectID: "owned", allowedSurfaceIDs: ["test"], target: .init(surfaceID: "test", position: .init(x: -2.7, y: 0.52, z: -5), yaw: Float(0.7)), requestID: "placement.decimal")
        let decimalBridge = ResidentPropToolBridge(service: service, allowsMutation: false, isCurrent: { current.value }, delegatedGrant: decimalGrant)
        check(!(try await invoke(decimalBridge, "apply_prop_placement", ["object_id": "owned", "surface_id": "test", "x": -2.7, "y": 0.52, "z": -5, "yaw": 0.7, "layout_revision": context.state.layoutRevision], "decimal-place")).isError, "canonical float comparison accepts decimal target from JSON")
        check(try await invoke(decimalBridge, "apply_prop_placement", ["object_id": "owned", "surface_id": "test", "x": -2.7, "y": 0.52, "z": -5, "yaw": 0.8, "layout_revision": context.state.layoutRevision], "decimal-mismatch").isError, "nearby decimal does not pass for a different target")
        // ---- 挂点（slot）：hold_prop 的 slot 参数 + 回执/错误文案里的挂点名 ----
        // 放在最后：这里用**当前** revision，不去改动前面那些显式数字的算术。
        let holdTool = human.tools.first { $0.name == "hold_prop" }!
        let holdProperties = (holdTool.inputSchema["properties"] as? [String: Any]) ?? [:]
        let slotSchema = holdProperties["slot"] as? [String: Any]
        check(slotSchema?["enum"] as? [String] == ["rightHand", "back", "waist"],
              "hold_prop 必须给出挂点参数（三个字面量与 WorldPropSlot.rawValue 同一份）")
        check((holdTool.inputSchema["required"] as? [String])?.contains("slot") == false,
              "slot 可省（省缺 = rightHand，既有调用点与旧提示词一个字都不用改）")
        // 旧存档 / 旧调用点：不带 slot 仍然是右手。
        check(!(try await invoke(human, "hold_prop", ["object_id": "owned", "layout_revision": context.state.layoutRevision], "hold-default-slot")).isError,
              "不带 slot 的 hold_prop 必须照旧成功（省缺 = 右手）")
        check(context.state.heldProp?.hand == .rightHand, "省缺挂点还是 rightHand（旧行为逐字节不变）")
        // 说"挂背后" ⇒ 就地换挂点，回执里必须有挂点名。
        let switched = try await invoke(human, "hold_prop",
            ["object_id": "owned", "layout_revision": context.state.layoutRevision, "slot": "背后"], "hold-back")
        check(!switched.isError, "「挂背后」必须被接受（用户嘴里那几种说法也认）")
        check((payload(switched)["held_slot"] as? String) == "back"
              && (payload(switched)["held_slot_name"] as? String) == "背后",
              "回执必须说清它现在挂在哪个挂点（held_slot/hold_slot_name = back/背后）")
        check(context.state.heldProp?.hand == .back, "换挂点必须落进**持久状态**（WorldHeldProp.hand == back）")
        check(context.state.objectStates["owned"]?.gripCalibration?.hand == .back,
              "标定里的挂点必须跟着换（渲染侧读的就是它）")
        // 认不出来的挂点名：拒绝，且不许改动现状。
        let bogus = try await invoke(human, "hold_prop",
            ["object_id": "owned", "layout_revision": context.state.layoutRevision, "slot": "头顶"], "hold-bogus")
        check(bogus.isError, "认不出来的挂点名必须拒绝（不许猜一个挂点）")
        check(["invalid_arguments", "placement_rejected"].contains(payload(bogus)["code"] as? String ?? ""),
              "拒绝回执必须走既有的错误通道（实测 \(payload(bogus)["code"] as? String ?? "nil")）")
        check(context.state.heldProp?.hand == .back, "被拒的挂点不许改动现状")
        // 微调只动偏移/朝向，不许把挂点挪回右手。
        check(!(try await invoke(human, "adjust_held_prop_grip",
            ["object_id": "owned", "layout_revision": context.state.layoutRevision,
             "offset_x": 0.01, "offset_y": 0, "offset_z": 0.02, "rotation_yaw": 0], "grip-back")).isError,
              "在背后微调握点必须成功")
        check(context.state.heldProp?.hand == .back
              && context.state.objectStates["owned"]?.gripCalibration?.hand == .back,
              "微调不许悄悄把挂点改回右手")
        print("PASS: \(checks) resident prop tool checks")
    }
}
"""#
let temporary=FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-prop-tools-\(UUID())")
try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:true)
defer{try? FileManager.default.removeItem(at:temporary)}
let file=temporary.appendingPathComponent("Test.swift")
try harness.write(to:file,atomically:true,encoding:.utf8)
let exe=temporary.appendingPathComponent("test")
func run(_ binary:String,_ args:[String]) throws->Int32{let p=Process();p.executableURL=URL(fileURLWithPath:binary);p.arguments=args;try p.run();p.waitUntilExit();return p.terminationStatus}
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
let objects=Array(worldRuntimeFlags.dropFirst(2))
let code=try run("/usr/bin/swiftc",["-j1","-parse-as-library","-I",worldRuntimeFlags[1],sources.appendingPathComponent("Agent/WorldAgentContext.swift").path,sources.appendingPathComponent("Presence/ResidentPropPlacementService.swift").path,root.appendingPathComponent("tools/fixtures/PropAttachmentPointShim.swift").path,sources.appendingPathComponent("Presence/PropGripInference.swift").path,sources.appendingPathComponent("Presence/PropAttachmentSlot.swift").path,bridge.path,root.appendingPathComponent("tools/fixtures/ResidentPropHoldLimitShim.swift").path,file.path,"-o",exe.path]+objects)
guard code == 0 else{exit(code)}
exit(try run(exe.path,[]))

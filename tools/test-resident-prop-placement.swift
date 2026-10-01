// 摆放事务与手持路径的行为检查（无宿主、无网络）。
//
// 主题已经迁移到「格子 + footprint」：具名摆放面（`ResidentPropSupportSurface`）已从生产
// 代码删除，摆放校验改为「位置落在某一层格子的格心上 + `PropPlacementEvaluator` 整块
// footprint 判定」。所以下面的合成承托几何是一张**解析平面**派生出来的真实 `PropSupportGrid`
// （等价于原来那张具名面），拒绝原因也随口径改成 `.blockedBySupport(...)` /
// `.unknownSurface` / `.environmentNotReady`。
import Foundation
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let base = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
let service = base.appendingPathComponent("Presence/ResidentPropPlacementService.swift")
guard FileManager.default.fileExists(atPath: service.path) else { print("FAIL: no prop placement transaction service"); exit(1) }
// 「已领取但入库被拒」的台账与文案住在 App 文件里，但它是**纯逻辑**（不依赖任何错误
// 类型），所以这里逐字抽取生产文本一起编译 —— 断言的不是副本，而是真正跑在 App 里的那份。
let appSource = try String(contentsOf: root.appendingPathComponent("apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift"), encoding: .utf8)
func appDeclaration(_ signature: String) -> String {
    guard let start = appSource.range(of: signature)?.lowerBound,
          let open = appSource[start...].firstIndex(of: "{") else { fatalError("missing declaration: \(signature)") }
    var depth = 0
    for index in appSource[open...].indices {
        if appSource[index] == "{" { depth += 1 }
        if appSource[index] == "}" { depth -= 1 }
        if depth == 0 { return String(appSource[start...index]) }
    }
    fatalError("unbalanced declaration: \(signature)")
}
let inventoryBacklogSource = appDeclaration("struct ResidentPropInventoryBacklog {")

// ---- 生产接线判据（纯文本）------------------------------------------------
// 行为断言在生成程序末尾（同一个 `ResidentPropInventoryBacklog` 生产文本上跑）。
func fail(_ message: String) -> Never { print("FAIL: \(message)"); exit(1) }
let syncSource = appDeclaration("private func synchronizeOwnedResidentProps()")
guard syncSource.contains("residentPropInventoryBacklog.record(") else {
    fail("a refused inventory registration must be remembered in the backlog (otherwise it is silent)")
}
guard syncSource.contains("residentPropInventoryBacklog.resolve(objectID:") else {
    fail("a successful inventory registration must clear its pending entry (otherwise the waiting state stays)")
}
guard syncSource.contains("requestID: \"claimed.\" + job.id.uuidString") else {
    fail("the idempotency key must stay the existing claim receipt (`claimed.<jobID>`)")
}
guard appSource.contains("(error as? ResidentPropPlacementError) == .environmentNotReady") else {
    fail("the backlog must classify the service's own refusal value, not a copy of its text")
}
let finishDerivationSource = appDeclaration("private func finishResidentPropGridDerivation(")
guard finishDerivationSource.contains("drainResidentPropInventoryBacklog(") else {
    fail("the support-geometry-ready callback must drive the inventory retry")
}
let drainSource = appDeclaration("private func drainResidentPropInventoryBacklog(")
guard drainSource.contains("await self?.synchronizeOwnedResidentProps()") else {
    fail("the inventory retry must re-enter the existing synchronizeOwnedResidentProps path")
}
guard !drainSource.contains("Timer") && !drainSource.contains("Task.sleep") else {
    fail("the inventory retry must not add polling or a timer")
}
guard !finishDerivationSource.contains("Timer") else {
    fail("the inventory retry must not add a timer to the derivation-finish path")
}
// 「我的物件」列表与状态文字必须读**同一份**事实（库存记录）：列表不许以"资产是否就绪"
// 过滤 —— 否则"状态说已入库、列表里却没有"会再次出现（真机 2026-10-01 的截图）。
let editorStateSource = try String(contentsOf: base.appendingPathComponent("Presence/ResidentPropEditorState.swift"), encoding: .utf8)
guard editorStateSource.contains("item.generatedProp != nil && (!showsPlacedOnly || item.isEnabled || snapshot.heldProp?.objectID == item.generatedProp?.objectID)") else {
    fail("the \u{300C}\u{6211}\u{7684}\u{7269}\u{4EF6}\u{300D} list must filter on the inventory record only (the same fact as the status text)")
}
guard !editorStateSource.contains("residentOwnedPropAssets") else {
    fail("the \u{300C}\u{6211}\u{7684}\u{7269}\u{4EF6}\u{300D} list must not read the model-asset table (that is how a stored object disappears)")
}
// fail-closed 判定**一个字都没放宽**：删掉任何一条承托守卫就死在这里。
// （纯文本判据，所以放在外层：生成程序里 `service` 是那个摆放服务实例，不是 URL。）
let serviceText = try String(contentsOf: service, encoding: .utf8)
let failClosedGuards = serviceText.components(separatedBy: "throw ResidentPropPlacementError.environmentNotReady").count - 1
guard failClosedGuards >= 4 else {
    print("FAIL: the fail-closed environment guards were weakened (found \(failClosedGuards), expected 4)")
    exit(1)
}
// 台账分类必须读**服务抛出来的那个错误值**，不许抄它的文案。
guard appSource.contains("(error as? ResidentPropPlacementError) == .environmentNotReady") else {
    print("FAIL: the backlog must classify the service's own refusal value, not a copy of its text")
    exit(1)
}
let code = #"""
import Foundation
import WorldRuntime
struct Floor: WorldCollisionQuerying {
 func canOccupy(_ c: WorldCapsule,at p: SIMD3<Float>)->Bool { p.x < 9 }
 func groundHeight(at p: SIMD3<Float>)->Float? { 0 }
}
final class Disk: WorldStatePersisting, @unchecked Sendable {
 var fail = false; var saved: WorldState?
 func save(_ state:WorldState)throws { if fail { throw NSError(domain:"disk",code:1) }; saved=state }
 func load()throws->WorldState? { saved }
}
/// 合成承托几何：一张水平承托层（旧具名摆放面的等价物）。
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
/// 覆盖 (5,0,5) 一带（旧的具名面 `floor`），但**不**覆盖 (5.9,0,5) 与 (10,0,5)：
/// 那两处必须仍然被判成"不是承托面"。
let flatWorld=FlatSupport(minimumX:-1,maximumX:5.5,minimumZ:-1,maximumZ:10,height:0)
/// 收窄后的路点约束：与生产**同一条**推导（世界路点定可站带、活动锚点定目标）。
/// 生产里这段在 `ResidentPropGridEditorModel`（宿主侧）；这里逐字重算一遍，
/// 因为它只是"把世界的两个数组喂进 `WorldPlacementRouteMap`"，没有别的逻辑。
///
/// **锚点必须取自同一个世界**（`bandManifest` 同时给出可站带与锚点）：合成平面上的
/// 验证要用合成世界的路点，真实舱体上的验证要用真实舱体的路点。
@MainActor func routeConstraint(_ grid:PropSupportGrid,_ manifest:WorldManifest)->ResidentPropPlacementSupport.RouteConstraint? {
 /// 病态世界坐标（非有限 / 离谱）一律当作"拿不到判据"。生产里这条在
 /// `ResidentPropGridEditorModel.isUsableWorldPosition`（列号换算会溢出，而溢出不是判据）。
 func usable(_ p:WorldVector3)->Bool {
   let limit:Float=1e6
   return p.x.isFinite && p.y.isFinite && p.z.isFinite
     && abs(p.x)<limit && abs(p.y)<limit && abs(p.z)<limit
 }
 let heights=manifest.waypoints.filter(\.enabled).map(\.position.y)
 guard let lowest=heights.min(), let highest=heights.max() else { return nil }
 let map=WorldPlacementRouteMap(grid:grid,lowerHeight:lowest-0.2,upperHeight:highest+0.2)
 var positions:[String:WorldVector3]=[:]
 for activity in manifest.activities {
   // 道具功能点锚点不受这里的烘焙几何支配（服务会从候选状态派生并合并），
   // 缺 `entryWaypointID` 时跳过不是放宽：它本来就没有烘焙入口。
   guard let entryWaypointID=activity.entryWaypointID else { continue }
   guard let waypoint=manifest.waypoints.first(where:{ $0.id==entryWaypointID && $0.enabled }),
         usable(waypoint.position) else { return nil }
   positions[entryWaypointID]=waypoint.position
 }
 guard !positions.isEmpty else { return nil }
 return .init(map:map,anchorIDs:positions.keys.sorted(),anchorPositions:positions)
}
/// 合成平面的支撑几何。
///
/// `bandSource` 是**可站带的来源**（世界路点高度）：生产里就是当前世界的路点。
/// 这里之所以要分开传，是因为下面有几段在**合成世界**上验证，而"居民当前位置能不能
/// 走到锚点"是按**世界里真的路点**算的 —— 拿另一个世界的路点来算，居民与锚点根本不在
/// 同一片坐标里，判据只会 fail-closed 拒绝一切（那正是它该做的）。
@MainActor func flatSupport(_ manifest:WorldManifest)->ResidentPropPlacementSupport {
 let bounds=WorldPlanarBounds(minimumX:flatWorld.minimumX,maximumX:flatWorld.maximumX,
                              minimumZ:flatWorld.minimumZ,maximumZ:flatWorld.maximumZ)
 let grid=PropSupportGridBuilder.build(collision:flatWorld,bounds:bounds,
                                       seed:WorldVector3(x:5,y:0,z:5),parameters:PropSupportGridParameters())
 return ResidentPropPlacementSupport(grid:grid,collision:flatWorld,
   routeConstraint:routeConstraint(grid,manifest))
}
@MainActor func require(_ b:Bool,_ s:String) { if !b { print("FAIL: \(s)"); exit(1) } }
// 生产里的那份台账/文案（逐字，见文件头 `appDeclaration`）。
\#(inventoryBacklogSource)
@main struct Test {
 @MainActor static func main() throws {
  let manifest = try JSONDecoder().decode(WorldManifest.self,from:Data(contentsOf:URL(fileURLWithPath:"apps/macos/Resources/Worlds/marble-living-cabin/world.json")))
  let identity=WorldQuaternion(x:0,y:0,z:0,w:1)
  let unit=WorldVector3(x:1,y:1,z:1)
  let fixture=WorldManifest(schemaVersion:manifest.schemaVersion,packageID:"test",packageVersion:"1",worldID:"test",displayName:"test",calibration:manifest.calibration,
   spawn:.init(position:.init(x:0,y:0,z:0),rotation:identity,scale:unit),
   collisionVolumes:[.init(id:"fixed",center:.init(x:4,y:0.5,z:0),halfExtents:.init(x:0.5,y:0.5,z:0.5),rotation:identity,isBlocking:true)],
   waypoints:[.init(id:"a",position:.init(x:1,y:0,z:2),arrivalRadius:0.2,enabled:true),.init(id:"b",position:.init(x:3,y:0,z:2),arrivalRadius:0.2,enabled:true)],
   routes:[.init(id:"route",waypointIDs:["a","b"],bidirectional:true,enabled:true)],
   // 收窄后的判据要的是**活动锚点**：这条 sit 让 `routeConstraint` 有目标，"挡住入口"
   // 才有一条真的判据可验（没有活动 ⇒ 拿不到判据 ⇒ fail-closed 拒绝一切）。
   activities:[.init(id:"sit",action:"sit",entryWaypointID:"a",
     transform:.init(position:.init(x:1,y:0,z:2),rotation:identity,scale:unit),
     motionID:nil,propIDs:[],interruptible:true)],
   cameras:[],capabilities:[],resources:[])
  // **合成世界**（`fixture`）：可站带与活动锚点都取自它，所以"格子 + footprint"与
  // "居民还走得到锚点"这两条判据在同一片坐标里。用真实舱体的路点给合成平面算，
  // 居民与锚点根本不在同一处，判据只会 fail-closed 拒绝一切。
  let fixtureDisk=Disk()
  let context=try WorldAgentContext(manifest:fixture,persistence:fixtureDisk)
  context.installCollisionWorld(Floor())
  let flat=flatSupport(fixture)
  var authorized=true
  let service=ResidentPropPlacementService(context:context,support:{flat},isCurrent:{authorized})
  let prop=WorldGeneratedProp(objectID:"prop1",sourceWishID:"wish1",assetID:"asset1",displayName:"Coffee",size:.init(x:0.4,y:0.42,z:0.4),sourceHeight:2)
  _ = try service.commit(.register(prop),expectedLayoutRevision:0,requestID:"register")
  let before=context.state
  let placement=WorldPropPlacement(surfaceID:"floor",position:.init(x:5,y:0,z:5),yaw:0)
  _ = try service.preview(objectID:"prop1",placement:placement)
  require(context.state==before,"preview mutated state")
  fixtureDisk.fail=true
  do { _ = try service.commit(.place(objectID:"prop1",placement:placement),expectedLayoutRevision:1,requestID:"place"); fatalError("save failure accepted") } catch {}
  require(context.state==before && context.collisionWorld.canOccupy(.init(radius:0.1,height:1),at:SIMD3(5,0,5)),"failed save changed state/collision")
  fixtureDisk.fail=false
  _ = try service.commit(.place(objectID:"prop1",placement:placement),expectedLayoutRevision:1,requestID:"place")
  require(!context.collisionWorld.canOccupy(.init(radius:0.1,height:1),at:SIMD3(5,0,5)),"new object not blocking")
  require(context.collisionWorld.groundHeight(at:SIMD3(5,0,5))==0,"object top became ground")
  context.installCollisionWorld(Floor())
  require(!context.collisionWorld.canOccupy(.init(radius:0.1,height:1),at:SIMD3(5,0,5)),"base replacement lost object")
  require(!context.collisionWorld.canOccupy(.init(radius:0.1,height:1),at:SIMD3(10,0,5)),"base replacement lost environment")
  let restored=try WorldAgentContext(manifest:fixture,persistence:fixtureDisk)
  restored.installCollisionWorld(Floor())
  require(!restored.collisionWorld.canOccupy(.init(radius:0.1,height:1),at:SIMD3(5,0,5)),"restore lost object collision")
  do { _ = try service.preview(objectID:"prop1",placement:.init(surfaceID:"floor",position:.init(x:5.9,y:0,z:5),yaw:.pi/4)); fatalError("edge crossing accepted") }
  catch let error as ResidentPropPlacementError { require(error == .unknownSurface,"wrong edge-crossing rejection: \(error)") }
  let placed=context.state
  var savedAvatarID = "pmx.2b-miss-0414-standard"
  let failingHold=ResidentPropPlacementService(context:context,support:{flat},
    currentAvatarAssetID:{savedAvatarID},makeGripCalibration:{ prop,avatarID in
      .init(avatarAssetID:avatarID,hand:.rightHand,normalizedGrip:.init(x:0.5,y:0.2,z:0.5),
        localOffset:.init(x:0,y:0,z:0),localRotation:.init(x:0,y:0,z:0,w:1))
    })
  let delayedHold=try failingHold.holdCommand(objectID:"prop1")
  savedAvatarID = "avatar.changed"
  do { _ = try failingHold.commit(delayedHold,expectedLayoutRevision:2,requestID:"changed-avatar");fatalError("changed avatar accepted") }
  catch let error as ResidentPropPlacementError { require(error == .avatarChanged,"wrong changed-avatar rejection") }
  require(context.state == placed,"changed avatar committed a hold")
  savedAvatarID = "pmx.2b-miss-0414-standard";fixtureDisk.fail=true
  do { _ = try failingHold.commit(delayedHold,expectedLayoutRevision:2,requestID:"failed-hold-save");fatalError("failed hold save accepted") } catch {}
  require(context.state == placed && context.state.heldProp == nil,"failed hold persistence changed state")
  fixtureDisk.fail=false
  _ = try failingHold.commit(delayedHold,expectedLayoutRevision:2,requestID:"saved-hold")
  let heldBeforeFailedReturn = context.state
  let delayedReturn = try failingHold.returnHeldCommand(objectID:"prop1")
  fixtureDisk.fail=true
  do { _ = try failingHold.commit(delayedReturn,expectedLayoutRevision:3,requestID:"failed-return-save");fatalError("failed return save accepted") } catch {}
  require(context.state == heldBeforeFailedReturn && context.state.heldProp?.objectID == "prop1","failed return persistence claimed the hand was clear")
  fixtureDisk.fail=false
  _ = try failingHold.commit(delayedReturn,expectedLayoutRevision:3,requestID:"saved-return")
  let readyAfterReturn = context.state
  authorized=false
  do { _ = try service.commit(.withdraw(objectID:"prop1"),expectedLayoutRevision:4,requestID:"stop"); fatalError("stale context accepted") } catch {}
  require(context.state==readyAfterReturn,"stopped context changed state")
  authorized=true
  _ = try service.commit(.withdraw(objectID:"prop1"),expectedLayoutRevision:4,requestID:"remove")
  require(context.collisionWorld.canOccupy(.init(radius:0.1,height:1),at:SIMD3(5,0,5)),"withdraw left collision")
  _ = try service.commit(.undo,expectedLayoutRevision:5,requestID:"undo")
  require(context.state.objectStates["prop1"]==readyAfterReturn.objectStates["prop1"],"undo did not restore")
  // 旧的"墙"具名面在格子口径下就是网格之外：可以拿到承托几何，但这里没有承托层，
  // 因此必须是 `.unknownSurface` 的几何拒绝，而不是被静默接受。
  let wallService=ResidentPropPlacementService(context:context,support:{flat})
  do { _ = try wallService.preview(objectID:"prop1",placement:.init(surfaceID:"wall",position:.init(x:10,y:0,z:5),yaw:0)); fatalError("out-of-grid placement accepted") }
  catch let error as ResidentPropPlacementError { require(error == .unknownSurface,"wrong out-of-grid rejection: \(error)") }
  var reentered=false
  let reentrant=ResidentPropPlacementService(context:context,support:{flat},prepare:{ _ in
   if !reentered { reentered=true; _ = try service.commit(.withdraw(objectID:"prop1"),expectedLayoutRevision:context.state.layoutRevision,requestID:"newer") }
  })
  do { _ = try reentrant.commit(.place(objectID:"prop1",placement:placement),expectedLayoutRevision:context.state.layoutRevision,requestID:"outer"); fatalError("preparation overwrote newer state") } catch {}
  let routeContext=try WorldAgentContext(manifest:fixture)
  routeContext.installCollisionWorld(Floor())
  let routeFlat=flatSupport(fixture)
  let routing=ResidentPropPlacementService(context:routeContext,support:{routeFlat})
  _ = try routing.commit(.register(prop),expectedLayoutRevision:0,requestID:"import")
  func rejection(_ x:Float,_ z:Float,_ expected:ResidentPropPlacementError) throws {
   do { _ = try routing.preview(objectID:"prop1",placement:.init(surfaceID:"floor",position:.init(x:x,y:0,z:z),yaw:0)); fatalError("unsafe placement accepted") }
   catch let error as ResidentPropPlacementError { require(error==expected,"wrong placement rejection: \(error)") }
  }
  try rejection(0,0,.collision("居民"))
  // 阻挡体积/已放物件的互斥现在由 `PropPlacementEvaluator` 判定，所以原因走
  // `.blockedBySupport(...)`（旧的 `.collision(id)` 通道已经不存在）。
  try rejection(4,0,.blockedBySupport(.blockedByBlockingVolume("fixed")))
  // 收窄后：挡住**活动入口**（锚点自己那一格）必须被拒。fixture 的 sit 活动锚在 a。
  try rejection(1,2,.blockedRoute("a"))
  // 中间路点被压住**不再**否决摆放（这正是本次收窄）。fixture 两个路点都是锚点，
  // 所以这条由 `tools/test-resident-prop-one-judge.swift` 在真实舱体上钉住。
  require(context.state.objectStates["prop1"]?.isEnabled == false,"reentrant newer layout lost")
  // 拿不到承托几何 → fail-closed（`support` 默认 `{ nil }`），而不是"随便放"。
  let unready=ResidentPropPlacementService(context:context)
  do { _ = try unready.preview(objectID:"prop1",placement:placement); fatalError("missing environment accepted") }
  catch let error as ResidentPropPlacementError { require(error == .environmentNotReady,"wrong missing-environment rejection: \(error)") }
  _ = try routing.commit(.place(objectID:"prop1",placement:.init(surfaceID:"floor",position:.init(x:5,y:0,z:5),yaw:0)),expectedLayoutRevision:1,requestID:"first-place")
  let second=WorldGeneratedProp(objectID:"prop2",sourceWishID:"wish2",assetID:"asset2",displayName:"Second",size:prop.size,sourceHeight:2)
  _ = try routing.commit(.register(second),expectedLayoutRevision:2,requestID:"second-import")
  do { _ = try routing.preview(objectID:"prop2",placement:.init(surfaceID:"floor",position:.init(x:5,y:0,z:5),yaw:0)); fatalError("overlapping props accepted") }
  catch let error as ResidentPropPlacementError { require(error == .blockedBySupport(.blockedByPlacedProp("prop1")) || error == .blockedBySupport(.blockedByPlacedProp("prop2")),"wrong overlap rejection: \(error)") }
  let holding=ResidentPropPlacementService(context:routeContext,support:{routeFlat},
    currentAvatarAssetID:{"pmx.2b-miss-0414-standard"},makeGripCalibration:{ prop,avatarID in
      .init(avatarAssetID:avatarID,hand:.rightHand,normalizedGrip:.init(x:0.5,y:0.2,z:0.5),
        localOffset:.init(x:0,y:0,z:0),localRotation:identity)
    })
  _ = try holding.commit(holding.holdCommand(objectID:"prop1"),expectedLayoutRevision:3,requestID:"hold-footprint")
  do { _ = try holding.preview(objectID:"prop2",placement:.init(surfaceID:"floor",position:.init(x:5,y:0,z:5),yaw:0));fatalError("held return footprint was reused") }
  catch let error as ResidentPropPlacementError { require(error == .blockedBySupport(.blockedByPlacedProp("prop1")) || error == .blockedBySupport(.blockedByPlacedProp("prop2")),"wrong held-footprint rejection: \(error)") }
  _ = try holding.commit(holding.returnHeldCommand(objectID:"prop1"),expectedLayoutRevision:4,requestID:"return-footprint")
  let coffeeMachine=WorldGeneratedProp(objectID:"coffee-machine",sourceWishID:"wish-coffee",assetID:"coffee-asset",displayName:"咖啡机",
    size:.init(x:0.35,y:0.42,z:0.566),sourceHeight:1)
  _ = try routing.commit(.register(coffeeMachine),expectedLayoutRevision:5,requestID:"coffee-import")
  do { _ = try holding.holdCommand(objectID:"coffee-machine"); fatalError("oversized coffee machine accepted for holding") }
  catch let error as ResidentPropPlacementError { require(error == .propTooLarge("咖啡机"),"wrong oversized holding rejection") }
  let huge=WorldManifest(schemaVersion:fixture.schemaVersion,packageID:"huge",packageVersion:"1",worldID:"huge",displayName:"huge",calibration:fixture.calibration,spawn:fixture.spawn,collisionVolumes:[],
   waypoints:[.init(id:"a",position:.init(x:-1e38,y:0,z:0),arrivalRadius:0.2,enabled:true),.init(id:"b",position:.init(x:1e38,y:0,z:0),arrivalRadius:0.2,enabled:true)],
   routes:[.init(id:"huge-route",waypointIDs:["a","b"],bidirectional:true,enabled:true)],activities:[],cameras:[],capabilities:[],resources:[])
  // 病态的路线输入（±1e38）现在是**锚点位置的可用性**判据：拿不到可用锚点 ⇒ 拿不到约束
  // ⇒ 服务 fail-closed 拒绝摆放。列号换算绝不接受这种输入（会溢出，而溢出不是判据）。
  let hugeContext=try WorldAgentContext(manifest:huge)
  let hugeService=ResidentPropPlacementService(context:hugeContext,support:{flatSupport(huge)})
  _ = try hugeService.commit(.register(prop),expectedLayoutRevision:0,requestID:"huge-import")
  // 真的摆一件：判据要的是"摆放之后还走不走得到锚点"，而锚点位置不可用 ⇒ 拿不到约束
  // ⇒ fail-closed 拒绝（而不是拿一个会溢出的坐标去算列号）。
  do {
    _ = try hugeService.commit(.place(objectID:"prop1",
        placement:.init(surfaceID:"floor",position:.init(x:5,y:0,z:5),yaw:0)),
        expectedLayoutRevision:hugeContext.state.layoutRevision,requestID:"huge-place")
    fatalError("oversized route accepted")
  }
  catch let error as ResidentPropPlacementError { require(error == .environmentNotReady,"wrong oversized route rejection: \(error)") }
  // ---------------------------------------------------------------------------
  // 「已领取但入库被拒」：确证卡在哪一步 + 补做台账（真机 2026-10-01 `2B 白色长剑`）
  //
  // 真机存档的形状：世界 `objectStates` 里**已经有**已摆出（`isEnabled`）的物件
  // （存档 `marble-living-cabin/1.2.0/state.json`：斧头 + 咖啡机），此刻领取一件新物件、
  // 而承托几何拿不到（装修会话没开 ⇒ `support()` 返回 nil，见 `activateResidentPropGrid`
  // 是**唯一**的激活点）。判定 fail-closed 拒绝 —— 这是**对的**，本测试钉住它不许放宽。
  // 要修的是"被拒之后没人补做"：由下面的台账断言覆盖。
  let claimedSword = WorldGeneratedProp(objectID:"prop-sword", sourceWishID:"wish-sword",
    assetID:"asset-sword", displayName:"2B 白色长剑（外形摆件）", size:prop.size, sourceHeight:2)
  let swordRequestID = "claimed.4210DB95-9253-4CAF-83A3-3C45F090B099"
  let stuckContext = try WorldAgentContext(manifest:fixture)
  stuckContext.installCollisionWorld(Floor())
  let alreadyPlaced = WorldGeneratedProp(objectID:"prop-axe", sourceWishID:"wish-axe",
    assetID:"asset-axe", displayName:"斧头", size:prop.size, sourceHeight:2)
  let stuckRouting = ResidentPropPlacementService(context:stuckContext, support:{routeFlat})
  _ = try stuckRouting.commit(.register(alreadyPlaced), expectedLayoutRevision:0, requestID:"claimed.axe")
  _ = try stuckRouting.commit(.place(objectID:"prop-axe", placement:.init(surfaceID:"floor",
      position:.init(x:5,y:0,z:5),yaw:0)), expectedLayoutRevision:1, requestID:"place.axe")
  let geometryless = ResidentPropPlacementService(context:stuckContext, support:{nil})
  var refusedWithoutGeometry = false
  do {
    _ = try geometryless.commit(.register(claimedSword),
        expectedLayoutRevision:stuckContext.state.layoutRevision, requestID:swordRequestID)
  } catch let error as ResidentPropPlacementError {
    refusedWithoutGeometry = (error == .environmentNotReady)
    require(error.localizedDescription == "空间碰撞数据尚未准备好，请稍后再摆放。",
            "the user-visible reason must stay the service's own text")
  }
  // 注入"未就绪也放行"（例如删掉 `validate` 里的承托守卫）就死在这一行。
  require(refusedWithoutGeometry,
          "registration without support geometry was accepted (fail-closed judgement was widened)")
  require(stuckContext.state.objectStates["prop-sword"] == nil,
          "a refused registration must leave no inventory record — this is the stuck state")
  require(stuckContext.state.layoutReceipts[swordRequestID] == nil,
          "a refused registration must leave no receipt (real device: no `claimed.4210DB95…` receipt)")
  // 几何一到，同一条提交立刻成立：变量是"几何在不在"，不是服务、资产或物件本身。
  _ = try stuckRouting.commit(.register(claimedSword),
      expectedLayoutRevision:stuckContext.state.layoutRevision, requestID:swordRequestID)
  require(stuckContext.state.objectStates["prop-sword"]?.generatedProp != nil,
          "with support geometry the same registration must land in inventory")
  // 幂等（既有幂等键 `claimed.<jobID>`）：同一回执再放一次**不写第二遍**。
  let afterSwordRegister = stuckContext.state
  _ = try stuckRouting.commit(.register(claimedSword),
      expectedLayoutRevision:afterSwordRegister.layoutRevision, requestID:swordRequestID)
  require(stuckContext.state == afterSwordRegister,
          "a replayed `claimed.<jobID>` receipt must not write a second inventory record")

  // 台账：被拒之后**记住**，几何就绪那一刻补做，且同一件只报一次。
  var backlog = ResidentPropInventoryBacklog()
  var inventory: [String: Bool] = ["prop-sword": false, "prop-axe": true]
  func isInInventory(_ id: String) -> Bool { inventory[id] == true }
  let swordPending = ResidentPropInventoryBacklog.Pending(objectID:"prop-sword",
    name:"2B 白色长剑（外形摆件）", reason:"空间碰撞数据尚未准备好，请稍后再摆放。",
    waitsForSupportGeometry:true)
  backlog.record(swordPending)
  backlog.record(swordPending)
  require(backlog.count == 1, "recording the same object twice must keep exactly one pending entry")
  require(backlog["prop-sword"] == swordPending, "the pending entry must keep the readable reason")
  require(backlog.drain(isSupportGeometryReady:false, isInInventory:isInInventory).isEmpty,
          "without support geometry nothing may be re-attempted")
  require(backlog.count == 1,
          "the pending entry must survive while geometry is missing (visible, never silent)")
  require(backlog.drain(isSupportGeometryReady:true, isInInventory:isInInventory) == ["prop-sword"],
          "geometry becoming ready must re-attempt the pending registration exactly once")
  require(backlog.drain(isSupportGeometryReady:true, isInInventory:isInInventory) == ["prop-sword"],
          "an entry that is still not in inventory must stay retryable (no lost write)")
  inventory["prop-sword"] = true
  require(backlog.drain(isSupportGeometryReady:true, isInInventory:isInInventory).isEmpty,
          "an object already in inventory must never be written a second time")
  require(backlog.isEmpty, "an object already in inventory must be pruned from the ledger")

  // 可见状态：入库没完成 ⇒ 说得出来；入库完成 ⇒ 立刻转正；资产坏了 ⇒ 原因可读。
  require(ResidentPropInventoryBacklog.status(isInInventory:false, hasAssetFailure:false, isWaitingForInventory:true)
            == "已领取，等待入库",
          "an unregistered claim must read as waiting for inventory, never as stored")
  require(ResidentPropInventoryBacklog.status(isInInventory:false, hasAssetFailure:false, isWaitingForInventory:false)
            == "领取后入库中",
          "the first sync pass must read as in-progress, not as stored")
  require(ResidentPropInventoryBacklog.isTerminal(isInInventory:false) == false,
          "an unregistered claim must not be terminal (a terminal row expires off the panel)")
  require(ResidentPropInventoryBacklog.status(isInInventory:true, hasAssetFailure:false, isWaitingForInventory:false)
            == "已领取并入库",
          "only a real inventory record may read as stored")
  require(ResidentPropInventoryBacklog.isTerminal(isInInventory:true) == true,
          "a real inventory record is terminal")
  require(ResidentPropInventoryBacklog.status(isInInventory:true, hasAssetFailure:true, isWaitingForInventory:false)
            == "已入库，资产未就绪",
          "a stored object whose asset failed must say so instead of claiming it is ready")
  require(ResidentPropInventoryBacklog.assetNotice("本地文件缺失或校验失败").hasPrefix("资产未就绪："),
          "an asset failure must stay readable in the panel")
  let notice = ResidentPropInventoryBacklog.pendingNotice(swordPending)
  require(notice.hasPrefix("2B 白色长剑（外形摆件） 已领取，入库尚未保存：") && notice.contains("空间就绪后会自动补做"),
          "the refusal must be visible and must say it self-heals: \(notice)")
  require(ResidentPropInventoryBacklog.pendingDetail(swordPending).contains("空间就绪后会自动补做"),
          "the task row detail must carry the same promise and the same reason")

  print("PASS: layout preview, atomic save including hold, reserved footprint, collision recovery, bounds and stop checks")
  print("PASS: claimed-prop inventory backlog (refused register keeps a visible pending entry, re-attempts once, idempotent, fail-closed intact)")
 }
}
"""#
let tmp=FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-placement-\(UUID())")
try FileManager.default.createDirectory(at:tmp,withIntermediateDirectories:true)
defer { try? FileManager.default.removeItem(at:tmp) }
let source=tmp.appendingPathComponent("Test.swift"); try code.write(to:source,atomically:true,encoding:.utf8)
func run(_ binary:String,_ args:[String])throws->Int32 { let p=Process();p.executableURL=URL(fileURLWithPath:binary);p.arguments=args;try p.run();p.waitUntilExit();return p.terminationStatus }
let build=root.appendingPathComponent("apps/macos/Packages/WorldRuntime/.build/arm64-apple-macosx/debug")
let objects=try FileManager.default.contentsOfDirectory(at:build.appendingPathComponent("WorldRuntime.build"),includingPropertiesForKeys:nil).filter{$0.pathExtension=="o"}.map(\.path)
let binary=tmp.appendingPathComponent("test")
let result=try run("/usr/bin/swiftc",["-j1","-parse-as-library","-I",build.appendingPathComponent("Modules").path,base.appendingPathComponent("Agent/WorldAgentContext.swift").path,service.path,source.path,"-o",binary.path]+objects)
guard result==0 else { exit(result) }
let status=try run(binary.path,[])
print("PASS: claimed-prop inventory wiring (refusal remembered, geometry-ready callback drains, existing receipt key, no timer, 「我的物件」 list reads the inventory record only)")
exit(status)

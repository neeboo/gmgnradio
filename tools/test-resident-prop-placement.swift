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
// ---- 历史存档自愈的**接线**判据（真机 2026-10-01 那把「2B 白色长剑」）--------------
// 行为判据在下面 (E) 那一节（真数字、真判据、真世界状态、真摆放）；这里钉的是
// "App 真的走了那条自愈 + 到底有没有把改动**说出来**"。
guard syncSource.contains("WorldPropArchiveRebase.decide(") else {
    fail("入库那一处必须走唯一那份自愈判据（WorldPropArchiveRebase），不许自己拼一套规则")
}
guard syncSource.contains("orientationNotices[job.objectID] = record.summary") else {
    fail("自愈必须留下**可见记录**（谁被修了、改了哪几个字段）：静默改写用户数据是红线")
}
guard syncSource.contains("throw ResidentPropHostError.archiveNotRepairable(detail)") else {
    fail("不能安全对齐的存档必须**可见地拒绝**并说出具体差异，不许静默跳过")
}
guard syncSource.contains("requestID: record.requestID") else {
    fail("自愈写回必须用内容寻址的幂等键（同一份修复重放不写第二条）")
}
guard syncSource.contains(".rebase(healed)") else {
    fail("自愈必须走 `.rebase` 那条只换派生字段的命令，不许拿 `.resize`/`.register` 冒充")
}
// 顺序：**先说出来，再写**。反过来的话，一次写失败就会留下"说改过、其实没改"。
if let noticeIndex = syncSource.range(of: "orientationNotices[job.objectID] = record.summary"),
   let commitIndex = syncSource.range(of: ".rebase(healed)") {
    guard noticeIndex.lowerBound < commitIndex.lowerBound else {
        fail("可见记录必须写在提交之前（否则写失败时会说一句做不到的话）")
    }
} else {
    fail("自愈写回必须同时有可见记录与 .rebase 提交")
}
guard appSource.contains("物件存档与领取记录不一致，而且这份存档不能安全对齐") else {
    fail("不能对齐时的拒绝文案必须把'为什么'带给用户，而不是只说一句'不一致'")
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
// 判据分层必须落在**类型**上，而且"全部空间判据"只能出现在空间那一支里 ——
// 这正是本次要修的形状：登记进库存**不得**被按摆放来判。
guard serviceText.contains("enum ResidentPropLayoutIntent") else {
    print("FAIL: the judgement layering must be a type (`ResidentPropLayoutIntent`), not a scattered flag")
    exit(1)
}
guard let inventoryBranch = serviceText.range(of: "case let .inventoryRegistration(objectID):"),
      let spatialBranch = serviceText.range(of: "case .spatialChange:") else {
    print("FAIL: `commit` must dispatch on the typed intent (inventory vs spatial)")
    exit(1)
}
let inventoryBody = String(serviceText[inventoryBranch.upperBound..<spatialBranch.lowerBound])
guard !inventoryBody.contains("validate(state)") else {
    print("FAIL: the inventory-registration layer must not run the spatial judgement (`validate(state)`)")
    exit(1)
}
guard inventoryBody.contains("validateInventoryRegistration(") else {
    print("FAIL: the inventory layer must run its own judgement (`validateInventoryRegistration`)")
    exit(1)
}
guard serviceText[spatialBranch.upperBound...].contains("try validate(state)") else {
    print("FAIL: the spatial layer must still run the full spatial judgement (`validate(state)`)")
    exit(1)
}
// ---- 手持尺寸上限：只有一处定义，判据与文案都读它 -------------------------------
// 上限与它的"人话"文案**逐字**从生产源码 `PropAttachment.swift` 抽出来（不是在这儿抄一份
// 数字）：生产里改了，这个 harness 立刻跟着变。这一条同时是"全仓没有第二个写死的 45/0.45"
// 的门禁部分 —— 判据、拒绝文案、系统提示词三处都必须指向同一份定义。
let attachmentText = try String(contentsOf: base.appendingPathComponent("Presence/PropAttachment.swift"),
                                encoding: .utf8)
func attachmentLine(_ prefix: String, _ what: String) -> String {
    guard let line = attachmentText.split(separator: "\n")
        .map({ $0.trimmingCharacters(in: .whitespaces) })
        .first(where: { $0.hasPrefix(prefix) }) else {
        print("FAIL: PropAttachment.swift 里找不到\(what)（以 \"\(prefix)\" 开头的声明）")
        exit(1)
    }
    return line
}
let holdableMetersLine = attachmentLine("static let holdableLongestEdgeMeters", "手持上限")
let holdableTextLine = attachmentLine("static var holdableLongestEdgeText", "手持上限文案")
/// 从生产源码里**逐字**抽出一个完整声明（含花括号内全部内容）：同一个文件里的其它类型
/// （`PropAttachmentPoint`）也被 `ResidentPropPlacementService` 读到，同样不许在这儿抄一份。
/// 花括号配对取，所以它将来多几个 case 也照样跟着过来。
func attachmentType(_ signature: String) -> String {
    guard let start = attachmentText.range(of: signature)?.lowerBound,
          let open = attachmentText[start...].firstIndex(of: "{") else {
        print("FAIL: PropAttachment.swift 里找不到 \(signature)")
        exit(1)
    }
    var depth = 0
    for index in attachmentText[open...].indices {
        if attachmentText[index] == "{" { depth += 1 }
        if attachmentText[index] == "}" { depth -= 1 }
        if depth == 0 { return String(attachmentText[start...index]) }
    }
    print("FAIL: \(signature) 的花括号不平衡")
    exit(1)
}
guard serviceText.contains("<= ResidentPropAttachmentEligibility.holdableLongestEdgeMeters") else {
    print("FAIL: 手持判据必须读唯一那份上限（`holdableLongestEdgeMeters`），不许写死数字")
    exit(1)
}
guard serviceText.contains("\\(ResidentPropAttachmentEligibility.holdableLongestEdgeText)") else {
    print("FAIL: 拒绝文案必须与上限同源（插值 `holdableLongestEdgeText`），不许写死数字")
    exit(1)
}
guard appSource.contains("不超过 \\(ResidentPropAttachmentEligibility.holdableLongestEdgeText)") else {
    print("FAIL: 系统提示词必须与判据同源（插值 `holdableLongestEdgeText`），不许写死数字")
    exit(1)
}
for (name, text) in [("ResidentPropPlacementService.swift", serviceText), ("GMGNRadioApp.swift", appSource)] {
    guard !text.contains("45 厘米") else {
        print("FAIL: \(name) 里还有第二处写死的 45 厘米（上限必须只有一处定义）")
        exit(1)
    }
}
// 工具描述是 agent 真正读到的"能拿多大"（`hold_prop` 的 description），
// 所以它也必须在同一份定义上：写死一个数就是第二种真相。
// 注意坑：这里的旧文案是**没有空格**的「45厘米」，只按「45 厘米」搜是搜不到的。
let toolBridgeText = try String(contentsOf: base.appendingPathComponent("Agent/ResidentPropToolBridge.swift"),
                                encoding: .utf8)
guard toolBridgeText.contains("\\(ResidentPropAttachmentEligibility.holdableLongestEdgeText)") else {
    print("FAIL: 工具描述（hold_prop）必须与上限同源（插值 `holdableLongestEdgeText`），不许写死数字")
    exit(1)
}
guard !toolBridgeText.contains("45厘米") && !toolBridgeText.contains("45 厘米") else {
    print("FAIL: 工具描述里还有写死的 45 厘米")
    exit(1)
}
let code = #"""
import Foundation
import WorldRuntime
/// 手持上限：**逐字**取自生产源码 `PropAttachment.swift` 的那两行（见本文件上面的抽取器）。
/// 这里刻意不写数字 —— 断言里也没有第二个上限，改生产那一行这里立刻跟着变。
enum ResidentPropAttachmentEligibility {
 \#(holdableMetersLine)
 \#(holdableTextLine)
}
/// 挂点类型同样是 `PropAttachment.swift` 里的生产声明，服务读它 —— 逐字抽出来，不抄一份。
\#(attachmentType("enum PropAttachmentPoint:"))
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
    currentAvatarAssetID:{savedAvatarID},makeGripCalibration:{ prop,avatarID,_ in
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
    currentAvatarAssetID:{"pmx.2b-miss-0414-standard"},makeGripCalibration:{ prop,avatarID,_ in
      .init(avatarAssetID:avatarID,hand:.rightHand,normalizedGrip:.init(x:0.5,y:0.2,z:0.5),
        localOffset:.init(x:0,y:0,z:0),localRotation:identity)
    })
  _ = try holding.commit(holding.holdCommand(objectID:"prop1"),expectedLayoutRevision:3,requestID:"hold-footprint")
  do { _ = try holding.preview(objectID:"prop2",placement:.init(surfaceID:"floor",position:.init(x:5,y:0,z:5),yaw:0));fatalError("held return footprint was reused") }
  catch let error as ResidentPropPlacementError { require(error == .blockedBySupport(.blockedByPlacedProp("prop1")) || error == .blockedBySupport(.blockedByPlacedProp("prop2")),"wrong held-footprint rejection: \(error)") }
  _ = try holding.commit(holding.returnHeldCommand(objectID:"prop1"),expectedLayoutRevision:4,requestID:"return-footprint")
  // ---- 手持尺寸闸门：判据、拒绝文案、系统提示词读的是**同一份**上限 --------------
  // 真机那把「2B 白色长剑」：摆正后的世界尺寸 = 0.1462 × 1.1 × 0.0624，最长边 1.1 m。
  // 它**必须**拿得起来 —— 改造前 0.45 m 的闸门把它拒在门外，那正是"白色长剑怎么才能
  // 用手拿着"今天答不出来的唯一原因。
  let holdSword=WorldGeneratedProp(objectID:"hold-sword",sourceWishID:"wish-hold-sword",
    assetID:"hold-sword-asset",displayName:"2B 白色长剑",size:.init(x:0.1462,y:1.1,z:0.0624),sourceHeight:1.1)
  _ = try routing.commit(.register(holdSword),expectedLayoutRevision:routeContext.state.layoutRevision,requestID:"hold-sword-import")
  // `holdCommand` 对**已登记**物件就判尺寸（不要求已摆出），所以正向用例不需要建完整摆放链。
  do { _ = try holding.holdCommand(objectID:"hold-sword") }
  catch { fatalError("1.1 m 的剑必须能手持（上限 \(ResidentPropAttachmentEligibility.holdableLongestEdgeText)）：\(error)") }
  // 界限**之下**的另一件（真机咖啡机 0.566 m）同样必须拿得起来 ——
  // "上限抬高之后咖啡机也能拿"是这次改动的必然结果，不是意外。
  let coffeeMachine=WorldGeneratedProp(objectID:"coffee-machine",sourceWishID:"wish-coffee",assetID:"coffee-asset",displayName:"咖啡机",
    size:.init(x:0.35,y:0.42,z:0.566),sourceHeight:1)
  _ = try routing.commit(.register(coffeeMachine),expectedLayoutRevision:routeContext.state.layoutRevision,requestID:"coffee-import")
  do { _ = try holding.holdCommand(objectID:"coffee-machine") }
  catch { fatalError("上限之下的咖啡机必须能手持：\(error)") }
  // 界限**之上**的（上限 + 0.05 m）必须被拒，而且拒绝文案必须与上限**同源**
  // （含 `holdableLongestEdgeText`）—— 把文案写死成别的数，这一条就红。
  let tooLong=WorldGeneratedProp(objectID:"hold-toolong",sourceWishID:"wish-hold-toolong",
    assetID:"hold-toolong-asset",displayName:"超大件",
    size:.init(x:ResidentPropAttachmentEligibility.holdableLongestEdgeMeters+0.05,y:0.2,z:0.2),sourceHeight:1)
  _ = try routing.commit(.register(tooLong),expectedLayoutRevision:routeContext.state.layoutRevision,requestID:"hold-toolong-import")
  do {
    _ = try holding.holdCommand(objectID:"hold-toolong")
    fatalError("超过上限（\(ResidentPropAttachmentEligibility.holdableLongestEdgeText)）的物件被接受去手持了")
  } catch let error as ResidentPropPlacementError {
    require(error == .propTooLarge("超大件"),"wrong oversized holding rejection: \(error)")
    require(error.errorDescription?.contains(ResidentPropAttachmentEligibility.holdableLongestEdgeText) == true,
      "拒绝文案必须与上限同源（必须含 \(ResidentPropAttachmentEligibility.holdableLongestEdgeText)），实测 \(error.errorDescription ?? "nil")")
  }
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
  // 「已领取但入库被拒」：判据分层（真机 2026-10-01 `2B 白色长剑`）
  //
  // 真机存档的形状：权威 `world_records` 的 `objects` 域里**已经有**已摆出（`isEnabled`）
  // 的物件（斧头 + 咖啡机），此刻领取一件新物件，而它在权威里**连一条 `objectStates`
  // 都没有** —— 没有落点，也没有承托面可言。
  //
  // 分层（本次修复，落在类型 `ResidentPropLayoutIntent` 上）：
  //   * **入库登记**（`.register` / 未摆出物件的 `.resize`）= 归属与资产：
  //     物件身份、尺寸合法、资产存在且哈希自洽、请求幂等；
  //   * **摆放**（`.place` / `.withdraw` / `.hold` / `.returnHeld` / `.enableCapability` /
  //     `.undo` / 已摆出/在手物件的 `.resize`）= **今天全部**空间判据
  //     （承托面、footprint 互斥、越界、居民不被压住、唯一通路），一个字不放宽。
  // ---------------------------------------------------------------------------
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
  // (A) **承托几何拿不到**时登记照样成立：库存里的东西不在空间里，没有承托面可判。
  // 把空间判据接回登记（例如让 `commit` 无条件跑 `validate`）⇒ 这里会以
  // `.environmentNotReady` 变红。
  let geometryless = ResidentPropPlacementService(context:stuckContext, support:{nil})
  do {
    _ = try geometryless.commit(.register(claimedSword),
        expectedLayoutRevision:stuckContext.state.layoutRevision, requestID:swordRequestID)
  } catch {
    require(false, "入库登记不得要求承托几何（库存里的东西不在空间里）：\(error)")
  }
  require(stuckContext.state.objectStates["prop-sword"]?.generatedProp != nil,
          "with no support geometry the registration must still land in inventory")
  require(stuckContext.state.objectStates["prop-sword"]?.isEnabled == false,
          "an inventory registration must not put the object into space")
  require(stuckContext.state.objectStates["prop-sword"]?.supportSurfaceID == nil,
          "the real sword has no landing point at all (no support surface recorded)")
  require(stuckContext.state.layoutReceipts[swordRequestID] != nil,
          "a successful registration must leave the existing `claimed.<jobID>` receipt")
  // 既有那件不回归：仍在库存、仍已摆出。
  require(stuckContext.state.objectStates["prop-axe"]?.isEnabled == true,
          "the already-placed axe must stay placed")
  // (B) 幂等：同一 `claimed.<jobID>` 重放**不写第二条**、也不涨 `layoutRevision`。
  let afterSwordRegister = stuckContext.state
  _ = try geometryless.commit(.register(claimedSword),
      expectedLayoutRevision:afterSwordRegister.layoutRevision, requestID:swordRequestID)
  require(stuckContext.state == afterSwordRegister,
          "a replayed `claimed.<jobID>` receipt must not write a second inventory record")
  require(stuckContext.state.layoutRevision == afterSwordRegister.layoutRevision,
          "a replayed `claimed.<jobID>` receipt must not grow the layout revision")
  // (C) 真机形状：房间里已摆出的东西**不在当前网格的承托层上**。真机那把斧头就是这样
  //     （y=-0.058583736，而冷派生出的网格里它那一列整列没有层：它自己的阻挡体积把
  //     那一列从 BFS 里挤掉了）。**摆放**会因此被拒（下面钉住），但**登记不许多看它一眼**。
  let offGridContext = try WorldAgentContext(manifest:fixture)
  offGridContext.installCollisionWorld(Floor())
  let offGridService = ResidentPropPlacementService(context:offGridContext, support:{flatSupport(fixture)})
  let offGridProp = WorldGeneratedProp(objectID:"prop-offgrid", sourceWishID:"wish-offgrid",
    assetID:"asset-offgrid", displayName:"斧头", size:prop.size, sourceHeight:2)
  _ = try offGridService.commit(.register(offGridProp), expectedLayoutRevision:0, requestID:"offgrid-register")
  // 用世界自己的提交入口摆到合成平面之外（这一条刻意绕开服务：它要造的是"已摆出但不在
  // 任何承托层上"这个**现状**，正是真机冷派生之后斧头的样子）。
  _ = try offGridContext.commitPropLayout(.place(objectID:"prop-offgrid",
      placement:.init(surfaceID:"off", position:.init(x:40,y:0,z:40), yaw:0)),
      expectedLayoutRevision:offGridContext.state.layoutRevision, requestID:"offgrid-place") { _ in }
  require(offGridContext.state.objectStates["prop-offgrid"]?.isEnabled == true,
          "the fixture must really contain an object that is placed and off the support grid")
  let secondSword = WorldGeneratedProp(objectID:"prop-sword2", sourceWishID:"wish-sword2",
    assetID:"asset-sword2", displayName:"2B 白色长剑（外形摆件）", size:prop.size, sourceHeight:2)
  do {
    _ = try offGridService.commit(.register(secondSword),
        expectedLayoutRevision:offGridContext.state.layoutRevision, requestID:"claimed.second-sword")
  } catch {
    require(false, "入库登记被**别的**已摆物件的位置判据拒了（判据用错层）：\(error)")
  }
  require(offGridContext.state.objectStates["prop-sword2"]?.generatedProp != nil,
          "the second sword must be in inventory even though the room holds an off-grid placed prop")
  // 同一条路、同一份几何：**摆放**仍然按今天全部判据拒绝（空间判据一个字没放宽）。
  do {
    _ = try offGridService.commit(.place(objectID:"prop-sword2",
        placement:.init(surfaceID:"floor", position:.init(x:5,y:0,z:5), yaw:0)),
        expectedLayoutRevision:offGridContext.state.layoutRevision, requestID:"offgrid-place-sword")
    require(false, "a placement must still be judged against every placed prop (off-grid one included)")
  } catch let error as ResidentPropPlacementError {
    require(error == .unknownSurface, "the placement refusal must still be the support-surface judgement: \(error)")
  }
  // (D) 入库那一层**不是空判据**：资产/归属判据（宿主注入的 `prepare`）拒绝时登记必须跟着拒绝。
  let assetRejecting = ResidentPropPlacementService(context:offGridContext,
    support:{flatSupport(fixture)}, prepare:{ _ in throw NSError(domain:"asset", code:1) })
  let thirdSword = WorldGeneratedProp(objectID:"prop-sword3", sourceWishID:"wish-sword3",
    assetID:"asset-sword3", displayName:"2B 白色长剑（外形摆件）", size:prop.size, sourceHeight:2)
  var assetRefusal = false
  do {
    _ = try assetRejecting.commit(.register(thirdSword),
        expectedLayoutRevision:offGridContext.state.layoutRevision, requestID:"claimed.third-sword")
  } catch { assetRefusal = true }
  require(assetRefusal, "the inventory layer must still refuse when the ownership/asset judgement refuses")
  require(offGridContext.state.objectStates["prop-sword3"] == nil,
          "a refused registration must leave no inventory record")
  require(offGridContext.state.layoutReceipts["claimed.third-sword"] == nil,
          "a refused registration must leave no receipt")

  // (E) **历史存档自愈**：真机那把「2B 白色长剑（外形摆件）」的**真实数字**。
  //
  // 权威里那条存档是**朝向归一落地之前**登记的：`size` = 1.100 × 0.146 × 0.062 米
  // （躺着的网格按最长边归一），`sourceHeight` = 原始 Y 跨度 0.133 米，**没有** `orientation`
  // 键；而今天同一份网格（`assetID` = 模型字节的 sha256，1,722,692 字节，字节一个都没变）
  // 从原始 GLB + 领取记录推出来的是**立着**的 0.146 × 1.100 × 0.062 米。
  // 两边的三个数字只是**换了一次位置** —— 所以旧判据（`size` 逐位相等）为假，那把剑
  // 永久进不了 `residentOwnedPropAssets`，用户"摆不了"。
  let swordObjectID = "wish-prop-4210db95-9253-4caf-83a3-3c45f090b099"
  let swordWishID = "4210DB95-9253-4CAF-83A3-3C45F090B099"
  let swordAssetID = "sha256:e9dda009e47ca4c1ace5e8a6e4ccf18645a109556b4f4772e410815c2be05529"
  let swordName = "2B 白色长剑（外形摆件）"
  // 渲染器量出来的**原始** AABB（与回执 `inspection.bounds.dimensions`、GLB 字节级重算一致）。
  let swordRawExtent = WorldVector3(x:1.005432426929474, y:0.1334928721189499, z:0.05656638368964195)
  let swordRequestedHeight: Float = 1.1
  let swordOrientation = WorldPropOrientationPolicy.resolve(sourceExtent: swordRawExtent)
  let swordOrientedExtent = WorldPropOrientationPolicy.orientedExtent(of: swordRawExtent, by: swordOrientation)
  let swordDerived = WorldGeneratedProp(objectID: swordObjectID, sourceWishID: swordWishID,
    assetID: swordAssetID, displayName: swordName,
    size: WorldPropSizePolicy.automatic(sourceExtent: swordOrientedExtent,
                                        requestedHeight: swordRequestedHeight)!.size,
    sourceHeight: swordOrientedExtent.y,
    orientation: swordOrientation.shouldArchive ? swordOrientation : nil)
  let swordArchived = WorldGeneratedProp(objectID: swordObjectID, sourceWishID: swordWishID,
    assetID: swordAssetID, displayName: swordName,
    size: WorldPropSizePolicy.automatic(sourceExtent: swordRawExtent,
                                        requestedHeight: swordRequestedHeight)!.size,
    sourceHeight: swordRawExtent.y)
  // 这一组数字必须真的是旧判据会拒的那一组（否则这个 harness 就不再盯着那个缺陷了）。
  require(!swordArchived.matchesIdentity(of: swordDerived),
          "真机那把剑的两份尺寸必须真的逐位不等（旧判据才会拒）")
  require(swordArchived.objectID == swordDerived.objectID && swordArchived.assetID == swordDerived.assetID,
          "它必须是同一件物件、同一份网格 —— 否则'自愈'就变成'把另一件东西认成它'")
  require(abs(swordArchived.size.x - 1.1) < 0.0001 && abs(swordArchived.size.y - 0.14604877) < 0.0001
          && abs(swordDerived.size.y - 1.1) < 0.0001 && abs(swordDerived.size.x - 0.14604877) < 0.0001,
          "真机数字：存档 (1.100, 0.146, 0.062) / 今天 (0.146, 1.100, 0.062)")
  let swordDecision = WorldPropArchiveRebase.decide(stored: swordArchived, derived: swordDerived,
    meshExtent: swordRawExtent, orientedExtent: swordOrientedExtent,
    requestedHeight: swordRequestedHeight, requestIDPrefix: "rebase." + swordWishID)
  guard case let .rebase(swordHealed, swordRecord) = swordDecision else {
    require(false, "同一件物件 + 同一份网格 + 只是量法换了 ⇒ 必须判成可安全自愈（实测 \(swordDecision)）"); exit(1)
  }
  // 三个**派生**字段整体换成今天那一份（拆开取会让画面与碰撞盒分叉）。
  require(swordHealed.size == swordDerived.size && swordHealed.sourceHeight == swordDerived.sourceHeight
          && swordHealed.orientation == swordDerived.orientation,
          "派生字段（尺寸/高度基准/朝向）必须整体对齐到今天，不许只换一半")
  // 用户自己的字段一个都不许动。
  require(swordHealed.sizeLocked == swordArchived.sizeLocked
          && swordHealed.sizeIntent == swordArchived.sizeIntent
          && swordHealed.collision == swordArchived.collision
          && swordHealed.authoritativeSize == swordArchived.authoritativeSize,
          "用户自己的字段（尺寸锁/尺寸意图/碰撞代理/权威尺寸）一个都不许动")
  // **可见记录**：改了哪几个字段、从多少到多少、凭什么。
  require(swordRecord.changes.count == 3, "三个派生字段都要出现在记录里（实测 \(swordRecord.changes.count) 条）")
  require(swordRecord.summary.contains(swordName) && swordRecord.summary.contains("→")
          && swordRecord.summary.contains("claimed."),
          "记录必须说清楚'谁被修了、改了什么、原值在哪'（可回滚），实测：\(swordRecord.summary)")
  require(swordRecord.requestID.hasPrefix("rebase." + swordWishID),
          "幂等键必须可读且内容寻址：\(swordRecord.requestID)")
  // 幂等：修完之后再判一次 ⇒ 什么都不做（下一次 5 秒周期就落在这里）。
  require(WorldPropArchiveRebase.decide(stored: swordHealed, derived: swordDerived,
            meshExtent: swordRawExtent, orientedExtent: swordOrientedExtent,
            requestedHeight: swordRequestedHeight, requestIDPrefix: "rebase." + swordWishID) == .unchanged,
          "修完之后必须幂等（再判一次是 .unchanged，不写第二条）")
  // 自愈之后**身份判据真的放行** —— 这正是那件资产能进 `residentOwnedPropAssets` 的条件。
  require(swordHealed.matchesIdentity(of: swordDerived),
          "修完之后身份判据必须放行，否则那把剑还是摆不了")
  // **不能安全对齐**时必须可见地拒绝（同一件物件，但存档那份尺寸不是这份网格的等比缩放）。
  let foreignArchive = WorldGeneratedProp(objectID: swordObjectID, sourceWishID: swordWishID,
    assetID: swordAssetID, displayName: swordName,
    size: WorldVector3(x: 0.7, y: 0.9, z: 0.31), sourceHeight: 0.31)
  guard case let .refuse(refusal) = WorldPropArchiveRebase.decide(stored: foreignArchive,
      derived: swordDerived, meshExtent: swordRawExtent, orientedExtent: swordOrientedExtent,
      requestedHeight: swordRequestedHeight, requestIDPrefix: "rebase." + swordWishID) else {
    require(false, "不是这份网格的等比缩放的存档不许被'对齐'（那会静默改写一个来路不明的数字）"); exit(1)
  }
  require(refusal.contains("0.70") && refusal.contains("等比缩放"),
          "拒绝必须把**具体差异**说出来（两份数字都在），实测：\(refusal)")
  // 身份不同（另一份资产）也必须拒绝，而不是把这次推导按到它头上。
  let otherAsset = WorldGeneratedProp(objectID: swordObjectID, sourceWishID: swordWishID,
    assetID: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
    displayName: swordName, size: swordArchived.size, sourceHeight: swordArchived.sourceHeight)
  guard case .refuse = WorldPropArchiveRebase.decide(stored: otherAsset, derived: swordDerived,
      meshExtent: swordRawExtent, orientedExtent: swordOrientedExtent,
      requestedHeight: swordRequestedHeight, requestIDPrefix: "rebase." + swordWishID) else {
    require(false, "另一份资产（assetID 不同）不许被当成同一件物件修"); exit(1)
  }
  // ---- 世界状态那一层：`.rebase` 只换派生字段，放置不动，`layoutRevision` 只 +1，重放不写第二条 ----
  let healContext = try WorldAgentContext(manifest: fixture)
  healContext.installCollisionWorld(Floor())
  let healFlat = flatSupport(fixture)
  let healService = ResidentPropPlacementService(context: healContext, support: { healFlat })
  _ = try healService.commit(.register(swordArchived), expectedLayoutRevision: 0,
                             requestID: "claimed." + swordWishID)
  let healed = try healService.commit(.rebase(swordHealed),
      expectedLayoutRevision: healContext.state.layoutRevision, requestID: swordRecord.requestID)
  require(healed.layoutRevision == 2,
          "一次自愈只许 +1（登记 0 → 1、自愈 1 → 2），实测 \(healed.layoutRevision)")
  let healedItem = healed.objectStates[swordObjectID]!
  require(healedItem.generatedProp == swordHealed, "存档里那一份必须变成今天推出来的那一份")
  require(healedItem.isEnabled == false, "自愈不许把库存里的东西推进空间（isEnabled 一个字节都不改）")
  require(abs(healedItem.transform.scale.x - swordHealed.effectiveSize.y / swordHealed.sourceHeight) < 1e-6,
          "渲染色调必须跟着 effectiveSize 那唯一一份出口重算")
  // 幂等重放：同一条回执**不写第二条**、不涨 revision、状态逐位不变。
  let afterHeal = healContext.state
  _ = try healService.commit(.rebase(swordHealed),
      expectedLayoutRevision: afterHeal.layoutRevision, requestID: swordRecord.requestID)
  require(healContext.state == afterHeal, "同一份修复重放不许写第二条")
  require(healContext.state.layoutRevision == afterHeal.layoutRevision, "重放不许涨 layoutRevision")
  // **真的能摆进空间**：自愈之后走今天**全部**空间判据（一个字没放宽）把它放到格子中心。
  let swordPlacement = WorldPropPlacement(surfaceID:"floor", position:.init(x:5,y:0,z:5), yaw:0)
  _ = try healService.preview(objectID: swordObjectID, placement: swordPlacement)
  _ = try healService.commit(.place(objectID: swordObjectID, placement: swordPlacement),
      expectedLayoutRevision: healContext.state.layoutRevision, requestID: "place." + swordWishID)
  require(healContext.state.objectStates[swordObjectID]?.isEnabled == true,
          "自愈之后那把剑必须真的能摆进空间（真机缺陷的终点）")
  require(healContext.state.objectStates[swordObjectID]?.generatedProp == swordHealed,
          "摆进去的仍然是自愈之后那一份（没有再被改写）")
  // 只有派生字段能换：改身份 / 改用户字段一律 fail-closed 拒绝（`.rebase` 不是后门）。
  let lockedTarget = WorldGeneratedProp(objectID: swordObjectID, sourceWishID: swordWishID,
    assetID: swordAssetID, displayName: swordName, size: swordHealed.size,
    sourceHeight: swordHealed.sourceHeight, sizeLocked: true, orientation: swordHealed.orientation)
  do {
    _ = try healService.commit(.rebase(lockedTarget),
        expectedLayoutRevision: healContext.state.layoutRevision, requestID: "rebase.tampered-lock")
    require(false, "`.rebase` 不许改动用户自己的字段（尺寸锁）")
  } catch let error as WorldPropLayoutError {
    require(error == .invalidObject, "改用户字段必须判 invalidObject，实测 \(error)")
  }
  let otherAssetTarget = WorldGeneratedProp(objectID: swordObjectID, sourceWishID: swordWishID,
    assetID: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
    displayName: swordName, size: swordHealed.size, sourceHeight: swordHealed.sourceHeight,
    orientation: swordHealed.orientation)
  do {
    _ = try healService.commit(.rebase(otherAssetTarget),
        expectedLayoutRevision: healContext.state.layoutRevision, requestID: "rebase.tampered-asset")
    require(false, "`.rebase` 不许把一件物件换成另一份资产")
  } catch let error as WorldPropLayoutError {
    require(error == .invalidObject, "换资产必须判 invalidObject，实测 \(error)")
  }
  // 回归：斧头与咖啡机（同样已登记、立着的资产）不受影响 —— 它们的存档与今天的推导逐位一致，
  // 判据是 `.unchanged`，一次写都不会发生。
  let axe = WorldGeneratedProp(objectID:"wish-prop-02bfee6e-82ad-4680-8525-db2d86791bf1",
    sourceWishID:"02BFEE6E-82AD-4680-8525-DB2D86791BF1",
    assetID:"sha256:9d50e3d75f88f9c3aeca8fc6624045d6c31951e44ac5e24da19104b7267caeeb",
    displayName:"斧头", size:WorldVector3(x:0.88547075, y:0.7, z:0.08647913), sourceHeight:0.79552174)
  let axeExtent = WorldVector3(x:1.0062, y:0.79552174, z:0.0983)
  require(WorldPropArchiveRebase.decide(stored: axe, derived: axe, meshExtent: axeExtent,
            orientedExtent: axeExtent, requestedHeight: 0.7,
            requestIDPrefix: "rebase.axe") == .unchanged,
          "已登记且一致的物件（斧头）必须是 .unchanged：一次写都不许发生")
  let coffee = WorldGeneratedProp(objectID:"wish-prop-ebfc07be-6af3-4e25-af6c-9e795c6e28c6",
    sourceWishID:"EBFC07BE-6AF3-4E25-AF6C-9E795C6E28C6",
    assetID:"sha256:d656c46b21ee0c6601f754d44643285538c7d7ed32271c9095eadb875cc689f8",
    displayName:"E2E-0907 咖啡机", size:WorldVector3(x:0.29150167, y:0.35, z:0.4719286), sourceHeight:0.7465656)
  require(WorldPropArchiveRebase.decide(stored: coffee, derived: coffee,
            meshExtent: WorldVector3(x:0.622, y:0.7465656, z:1.007),
            orientedExtent: WorldVector3(x:0.622, y:0.7465656, z:1.007),
            requestedHeight: 0.35, requestIDPrefix: "rebase.coffee") == .unchanged,
          "已登记且一致的物件（咖啡机）必须是 .unchanged")
  // 这一节覆盖了什么（每个 harness 都把结论打出来，否则没人知道它跑过）。
  print("PASS: 历史存档自愈（真机那把「2B 白色长剑」：同一件物件 + 同一份网格、只是量法换了 ⇒ "
        + "只换派生字段 size/sourceHeight/orientation、可见记录、幂等、可回滚；来路不明的尺寸与另一份资产"
        + "一律**可见拒绝**；世界状态那一层 layoutRevision 只 +1、重放不写第二条；修完之后真的能摆进空间；"
        + "斧头/咖啡机 .unchanged）")

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
  print("PASS: claimed-prop inventory layering (registration judges ownership/assets only — no support geometry, no other placed prop's position; placement still judged by every spatial rule; idempotent `claimed.<jobID>`; asset refusal still refuses)")
 }
}
"""#
let tmp=FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-placement-\(UUID())")
try FileManager.default.createDirectory(at:tmp,withIntermediateDirectories:true)
defer { try? FileManager.default.removeItem(at:tmp) }
let source=tmp.appendingPathComponent("Test.swift"); try code.write(to:source,atomically:true,encoding:.utf8)
func run(_ binary:String,_ args:[String])throws->Int32 { let p=Process();p.executableURL=URL(fileURLWithPath:binary);p.arguments=args;try p.run();p.waitUntilExit();return p.terminationStatus }
// WorldRuntime 的模块搜索路径 + 目标文件**只有一处定义**：tools/world-runtime-harness-flags.sh。
// 不要在这里拼 `.build/...`：27 份各自拼写正是 SwiftPM 与 xcodebuild 两份模块并存的根因。
// `build` 由那唯一一份定义**推出来**（= Modules 的上一级），本文件不持有路径字面量。
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
let build = URL(fileURLWithPath: worldRuntimeFlags[1]).deletingLastPathComponent()
let objects=try FileManager.default.contentsOfDirectory(at:build.appendingPathComponent("WorldRuntime.build"),includingPropertiesForKeys:nil).filter{$0.pathExtension=="o"}.map(\.path)
let binary=tmp.appendingPathComponent("test")
let result=try run("/usr/bin/swiftc",["-j1","-parse-as-library","-I",build.appendingPathComponent("Modules").path,base.appendingPathComponent("Agent/WorldAgentContext.swift").path,service.path,source.path,"-o",binary.path]+objects)
guard result==0 else { exit(result) }
let status=try run(binary.path,[])
print("PASS: claimed-prop inventory wiring (judgement layering is a type, inventory layer never runs `validate`, spatial layer still runs it; geometry-ready callback drains; existing receipt key; no timer; 「我的物件」 list reads the inventory record only)")
exit(status)

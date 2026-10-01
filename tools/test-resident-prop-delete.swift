// 删除一件生成资产的判据（无宿主、无网络、无模型）。
//
// 用户原话：**「生成的资产可以删除，让 agent 能调用工具」**。设计一页见
// `docs/plans/2026-10-02-prop-deletion-semantics.md`。这里钉的是它的每一条结论：
//
//   1. 删除是**墓碑 + 事实**，不是硬删行（`deletedProps` 墓碑 + `propDeleted` 事件）；
//   2. 还在被别人引用的**共享内容必须留着**（引用计数从活物件**派生**，带数字）；
//   3. 引用计数为 0 才谈得上回收字节；
//   4. 正被摆放 / 正拿在手里 / 挂在身上的：**同一次提交里原子收场**，绝不静默抹掉；
//   5. 「删干净」三层（记录 + 引用 + 文件）各有结论；
//   6. 失败具名（找不到 / 已经删过），而且**坏资产必须删得掉**；
//   7. 判据分层：删除走 `.removal` 那一层，**不跑空间判据**（单调性论证），
//      所以承托几何拿不到时**仍然删得掉**，而摆放照旧 fail-closed 拒绝；
//   8. 没被删的物件（另一件斧头/咖啡机）**一个字节都不变**。
//
// 编译方式与 `tools/test-resident-prop-placement.swift` 同源：真的
// `WorldAgentContext.swift` + 真的 `ResidentPropPlacementService.swift` + 真的
// `WorldRuntime` 模块产物。判据在**生产代码**上跑，不重写一份等价实现。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
func readSource(_ relative: String) throws -> String {
    try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
}
func check(_ condition: Bool, _ message: String) {
    guard condition else { print("FAIL:", message); exit(1) }
}
/// 从源码里切出 `signature` 开头的那**一个**花括号块（含嵌套）。
func declaration(_ source: String, _ signature: String) -> String? {
    guard let start = source.range(of: signature)?.lowerBound,
          let open = source[start...].firstIndex(of: "{") else { return nil }
    var depth = 0
    for index in source[open...].indices {
        if source[index] == "{" { depth += 1 }
        if source[index] == "}" {
            depth -= 1
            if depth == 0 { return String(source[start...index]) }
        }
    }
    return nil
}

let bridge = try readSource("apps/macos/Sources/GMGNRadio/Agent/ResidentPropToolBridge.swift")
let serviceSource = try readSource("apps/macos/Sources/GMGNRadio/Presence/ResidentPropPlacementService.swift")
let editorState = try readSource("apps/macos/Sources/GMGNRadio/Presence/ResidentPropEditorState.swift")
let editorView = try readSource("apps/macos/Sources/GMGNRadio/VisualEngine/ResidentPropEditorView.swift")
let appSource = try readSource("apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift")
let observation = try readSource("apps/macos/Sources/GMGNRadio/Agent/ResidentWorldObservation.swift")

// ---------------------------------------------------------------------------
// 接线判据（纯文本）：工具、面板、宿主三条路必须接上**同一份**判据
// ---------------------------------------------------------------------------

// 「唯一一份删除命令」：工具与面板都提交 `WorldPropLayoutCommand.delete`，
// 没有任何一条路自己拼一套删除。
// 注意：必须查**工具清单那一段**（`var tools` 的声明），不能只查全文里有没有
// `"delete_prop"` 这个串 —— 描述字典里也有它，那种查法在"工具被摘掉、描述还在"时
// 会假通过（注入 I6 就是照着这个形状设计的）。
let toolListSource = declaration(bridge, "var tools: [ResidentWorldToolSession.AdditionalTool]")
/// 工具清单 = `var tools` 里 **`.map` 之前**那一段数组字面量（描述字典在 `.map` 之后）。
/// 只查全文的话，"工具被摘掉、描述还在"会假通过。
let toolNames = toolListSource.flatMap { block -> String? in
    guard let end = block.range(of: ".map { name in")?.lowerBound else { return nil }
    return String(block[block.startIndex..<end])
}
check(toolNames?.contains("\"delete_prop\"") == true,
      "agent 工具面必须真的把 delete_prop 列进工具清单（不只是描述里有这个名字）")
check(bridge.contains("try service.deleteCommand(objectID: objectID, reason: values[\"reason\"] as? String)"),
      "delete_prop 必须走服务里那唯一一处命令构造（归属 + 命名）")
check(bridge.contains("service.commit(command, expectedLayoutRevision:"),
      "delete_prop 必须走与摆放/收回**同一条**提交路径（不新开通道）")
check(bridge.contains("payload[\"deletion\"] = deletion.payload"),
      "删除成功的回执必须带三层证明（record/reference/file）")
check(bridge.contains("payload[\"deleted\"] = tombstones.map"),
      "只读入口（read_owned_props）必须能查到已经删掉的那些（否则'少了'与'丢了'分不开）")
check(bridge.contains("case WorldPropLayoutError.objectNotFound: code = \"object_not_found\"")
      && bridge.contains("case WorldPropLayoutError.objectAlreadyDeleted: code = \"object_already_deleted\""),
      "失败必须具名：找不到 / 已经删过各给一个机器读的 code")
check(bridge.contains("永久删除") && bridge.contains("不可恢复"),
      "工具描述必须把'永久、不可恢复'写给 agent 看")

// 面板：同一个入口（`save(.delete(...))`），并且**必须先确认**。
check(editorState.contains("func deleteSelected(reason: String? = nil) async"),
      "面板必须有删除动作")
check(editorState.contains("await save(.delete(objectID: id, reason: reason))"),
      "面板删除必须走既有那一条 save（同一个 commit 出口，不另造逻辑）")
check(editorState.contains("static func deletedNotice(_ name: String) -> String")
      && editorState.contains("已删除（永久）"),
      "成功必须可见，而且说的是'永久删除'而不是'已保存'")
check(editorView.contains("confirmationDialog") && editorView.contains("永久删除"),
      "面板上必须有一次确认（不可恢复的动作不能不问就做）")

// 判据分层：`.delete` → `.removal`，而且那一层**不跑**空间判据。
let resolveSource = declaration(serviceSource, "static func resolve(_ command: WorldPropLayoutCommand, in state: WorldState) -> Self")
check(resolveSource?.contains("case let .delete(objectID, _):") == true
      && resolveSource?.contains("return .removal(objectID: objectID)") == true,
      "`.delete` 必须走 `.removal` 那一层（分层由唯一一处穷尽 switch 回答）")
let commitSource = declaration(serviceSource, "func commit(_ command: WorldPropLayoutCommand, expectedLayoutRevision: UInt64, requestID: String) throws -> WorldState")
check(commitSource?.contains("case let .removal(objectID):") == true
      && commitSource?.contains("validateDeletion(objectID: objectID, in: state, baseline: baseline)") == true,
      "删除那一层必须跑它自己的判据（validateDeletion）")
check(commitSource?.contains("case .spatialChange:") == true
      && commitSource?.contains("try validate(state)") == true,
      "空间那一层必须原样保留（一个字不放宽）")
let deletionSource = declaration(serviceSource, "private func validateDeletion(objectID: String, in state: WorldState, baseline: WorldState) throws")
check(deletionSource?.contains("try validate(") == false,
      "删除那一层**不得**跑空间判据（删除只会移走障碍，单调性保证它破坏不了任何空间判据）")
check(deletionSource?.contains("try prepare(") == false,
      "删除**不得**以'资产可用'为前提（坏掉的资产必须删得掉）")

// 宿主：删除不预置任何渲染资源（它把物件移出空间，不引入资源）。
check(appSource.contains("case .register, .withdraw, .enableCapability, .resize, .rebase, .delete: break"),
      "宿主 prepareResidentPropMutation 必须把 .delete 归到'不需要备资产'那一列")
check(observation.contains("case let .propDeleted("),
      "居民观察流必须认得删除事实（否则它会把删掉的东西读成丢了）")

print("PASS: 删除接线（工具 / 面板 / 宿主 / 观察四处接的是同一份删除命令；分层是 .removal；确认与永久文案都在）")

// ---------------------------------------------------------------------------
// 行为判据：在真生产代码上跑
// ---------------------------------------------------------------------------

// 手持上限与挂点类型：**逐字**从生产源码 `PropAttachment.swift` 里抽出来编译，
// 不在这里抄一份数字/一份枚举（抄一份的话，判据测的是我抄的那份 —— 那正是这个仓库
// 反复踩过的"门禁从不 FAIL"）。服务真的会读它们，所以必须同源。
let attachmentText = try readSource("apps/macos/Sources/GMGNRadio/Presence/PropAttachment.swift")
func attachmentLine(_ prefix: String, _ what: String) -> String {
    guard let line = attachmentText.split(separator: "\n")
        .map({ $0.trimmingCharacters(in: .whitespaces) })
        .first(where: { $0.hasPrefix(prefix) }) else {
        print("FAIL: PropAttachment.swift 里找不到\(what)（以 \"\(prefix)\" 开头的声明）")
        exit(1)
    }
    return line
}
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
let holdableMetersLine = attachmentLine("static let holdableLongestEdgeMeters", "手持上限")
let holdableTextLine = attachmentLine("static var holdableLongestEdgeText", "手持上限文案")

let harness = #"""
import Foundation
import CryptoKit
import WorldRuntime
/// 手持上限：**逐字**取自 `PropAttachment.swift`（服务真的读它）。
enum ResidentPropAttachmentEligibility {
 \#(holdableMetersLine)
 \#(holdableTextLine)
}
/// 挂点类型同样是生产声明，逐字抽出来。
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
let flatWorld=FlatSupport(minimumX:-1,maximumX:5.5,minimumZ:-1,maximumZ:10,height:0)
@MainActor func routeConstraint(_ grid:PropSupportGrid,_ manifest:WorldManifest)->ResidentPropPlacementSupport.RouteConstraint? {
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
  guard let entryWaypointID=activity.entryWaypointID else { continue }
  guard let waypoint=manifest.waypoints.first(where:{ $0.id==entryWaypointID && $0.enabled }),
        usable(waypoint.position) else { return nil }
  positions[entryWaypointID]=waypoint.position
 }
 guard !positions.isEmpty else { return nil }
 return .init(map:map,anchorIDs:positions.keys.sorted(),anchorPositions:positions)
}
@MainActor func flatSupport(_ manifest:WorldManifest)->ResidentPropPlacementSupport {
 let bounds=WorldPlanarBounds(minimumX:flatWorld.minimumX,maximumX:flatWorld.maximumX,
                              minimumZ:flatWorld.minimumZ,maximumZ:flatWorld.maximumZ)
 let grid=PropSupportGridBuilder.build(collision:flatWorld,bounds:bounds,
                                       seed:WorldVector3(x:5,y:0,z:5),parameters:PropSupportGridParameters())
 return ResidentPropPlacementSupport(grid:grid,collision:flatWorld,
   routeConstraint:routeConstraint(grid,manifest))
}
@MainActor func require(_ b:Bool,_ s:String) { if !b { print("FAIL: \(s)"); exit(1) } }

/// 两份**内容寻址**的字节：不同内容 ⇒ 不同 sha256；两件物件可以引用同一份。
/// 哈希用真的 SHA-256 —— `assetID` 就是模型字节的 sha256，判据必须按同一口径认它。
let sharedBytes = Data("the-same-glb-bytes".utf8)
let otherBytes = Data("a-different-glb".utf8)
func sha(_ data:Data)->String { SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined() }

/// **文件层的真执行器**（harness 自己拥有一个临时目录）。
///
/// 它只接受"引用计数为 0"的集合 —— 按 objectID 删文件这条路在这里根本不存在
/// （生产里也不存在：字节的拥有者是 taskd，不是本进程）。所以"共享文件不误删"
/// 在这一层是**结构性**的，而不只是判据里的一句话。
final class AssetFiles {
 let directory: URL
 init() {
  directory = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-delete-\(UUID().uuidString)")
  try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
 }
 func put(_ data:Data) { try? data.write(to: directory.appendingPathComponent(sha(data))) }
 func has(_ digest:String)->Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent(digest).path) }
 /// 回收：**只看计数**，不看是哪件物件。返回真的删掉的那些。
 @discardableResult func reclaim(_ reclamation:WorldPropReclamation)->[String] {
  var removed:[String]=[]
  for digest in reclamation.unreferenced where has(digest) {
   try? FileManager.default.removeItem(at: directory.appendingPathComponent(digest))
   removed.append(digest)
  }
  return removed
 }
}

/// 「静默删除」的样子：物件没了，**手里的东西还指着它**（悬空）。
/// 这条函数就是"注入静默删除 ⇒ FAIL"要抓的那个形状 —— 判据读它。
func leavesDanglingHold(_ state:WorldState,_ objectID:String)->Bool {
 state.heldProp?.objectID == objectID && state.objectStates[objectID] == nil
}

@main struct Test {
 /// 意外抛出 = 判据红，而且必须**打印出来**：门禁不能靠一个崩溃栈退出码说话
 /// （`swift tools/...` 的失败要看得见是哪一条判据没抓住）。
 @MainActor static func main() {
  do { try run() } catch { print("FAIL: 删除提交被意外拒绝／抛出（判据在这一次提交上没走到断言）：\(error)"); exit(1) }
 }
 @MainActor static func run() throws {
  let manifest = try JSONDecoder().decode(WorldManifest.self,from:Data(contentsOf:URL(fileURLWithPath:"apps/macos/Resources/Worlds/marble-living-cabin/world.json")))
  let identity=WorldQuaternion(x:0,y:0,z:0,w:1)
  let unit=WorldVector3(x:1,y:1,z:1)
  let fixture=WorldManifest(schemaVersion:manifest.schemaVersion,packageID:"test",packageVersion:"1",worldID:"test",displayName:"test",calibration:manifest.calibration,
   spawn:.init(position:.init(x:0,y:0,z:0),rotation:identity,scale:unit),
   collisionVolumes:[.init(id:"fixed",center:.init(x:4,y:0.5,z:0),halfExtents:.init(x:0.5,y:0.5,z:0.5),rotation:identity,isBlocking:true)],
   waypoints:[.init(id:"a",position:.init(x:1,y:0,z:2),arrivalRadius:0.2,enabled:true),.init(id:"b",position:.init(x:3,y:0,z:2),arrivalRadius:0.2,enabled:true)],
   routes:[.init(id:"route",waypointIDs:["a","b"],bidirectional:true,enabled:true)],
   activities:[.init(id:"sit",action:"sit",entryWaypointID:"a",
     transform:.init(position:.init(x:1,y:0,z:2),rotation:identity,scale:unit),
     motionID:nil,propIDs:[],interruptible:true)],
   cameras:[],capabilities:[],resources:[])
  let disk=Disk()
  let context=try WorldAgentContext(manifest:fixture,persistence:disk)
  context.installCollisionWorld(Floor())
  let flat=flatSupport(fixture)
  var authorized=true
  var prepareFails=false
  let service=ResidentPropPlacementService(context:context,support:{flat},
    prepare:{ _ in if prepareFails { throw ResidentPropPlacementError.environmentNotReady } },
    isCurrent:{authorized})

  // 两件物件引用**同一份**内容（同一个 sha256）：真机上同一张输入图存 5 份就是这个形状，
  // 所以"删一件不能删掉别人还在用的那份字节"必须能在这一层验证。
  let shared = sha(sharedBytes)
  let other = sha(otherBytes)
  let sharedProp=WorldGeneratedProp(objectID:"shared-a",sourceWishID:"wish-a",assetID:"sha256:"+shared,displayName:"共享内容 A",size:.init(x:0.3,y:0.3,z:0.3),sourceHeight:1)
  let twinProp=WorldGeneratedProp(objectID:"shared-b",sourceWishID:"wish-b",assetID:"sha256:"+shared,displayName:"共享内容 B",size:.init(x:0.3,y:0.3,z:0.3),sourceHeight:1)
  let otherProp=WorldGeneratedProp(objectID:"other-c",sourceWishID:"wish-c",assetID:"sha256:"+other,displayName:"别的物件 C",size:.init(x:0.3,y:0.3,z:0.3),sourceHeight:1)
  _ = try service.commit(.register(sharedProp),expectedLayoutRevision:0,requestID:"register-a")
  _ = try service.commit(.register(twinProp),expectedLayoutRevision:1,requestID:"register-b")
  _ = try service.commit(.register(otherProp),expectedLayoutRevision:2,requestID:"register-c")

  let files=AssetFiles()
  files.put(sharedBytes); files.put(otherBytes)

  // ---- 引用计数是**派生**的：两件都引用 shared，计数 = 2（带编号） ----
  let counts=WorldPropAssetReferences.referenceCounts(in:context.state)
  require(counts[shared]?.sorted()==["shared-a","shared-b"],"引用计数必须从活物件派生，并说得出是谁")

  // ---- (1) 正在摆放的那一件：同一次提交里收场（.withdrawn） ----
  let placed=WorldPropPlacement(surfaceID:"layer.0",position:.init(x:5,y:0,z:5),yaw:0)
  _ = try service.commit(.place(objectID:"shared-a",placement:placed),expectedLayoutRevision:3,requestID:"place-a")
  require(context.state.objectStates["shared-a"]?.isEnabled==true,"前置：shared-a 必须真的摆在房间里")
  require(context.collisionWorld.canOccupy(.init(radius:0.1,height:1),at:SIMD3(5,0,5))==false,"前置：摆好的物件必须挡人")

  let layoutBefore=context.state.layoutRevision
  let simulationBefore = context.simulation.events.count
  _ = try service.commit(.delete(objectID:"shared-a",reason:"用户说不要了"),expectedLayoutRevision:layoutBefore,requestID:"delete-a")
  let state=context.state

  // (1a) **墓碑 + 事实**：不是硬删行。
  require(state.objectStates["shared-a"]==nil,"删除后这一条必须离开 objectStates（权威据此置墓碑）")
  guard let tombstone=state.propTombstones?["shared-a"] else { print("FAIL: 删除必须留下墓碑"); exit(1) }
  require(tombstone.isValid,"墓碑必须自洽")
  require(tombstone.displayName=="共享内容 A","墓碑必须冻住被删的那一件的身份")
  require(tombstone.previous.assetID=="sha256:"+shared,"墓碑必须冻住它的资产引用")
  require(tombstone.reason=="用户说不要了","理由必须进审计")
  require(tombstone.releasedBlobRefs==[shared],"释放的内容引用必须逐字记下来")
  require(tombstone.settlement==WorldPropDeletionSettlement.withdrawn(
            surfaceID:"layer.0",position:WorldVector3(x:5,y:0,z:5)),
          "正在摆放的那一件必须记成'随删除一并结束'，并说得出原来在哪")
  require(tombstone.settlement.name=="withdrawn_then_deleted","结算名必须机器可读")
  // 事件日志里**查得到**：一次提交恰好一条事件，而且是**具名**的删除事实。
  let events=context.simulation.events
  require(events.count==simulationBefore+1,"一次删除恰好记一条事件")
  guard case let .propDeleted(id,name,rev,settled,released)=events.last!.kind else {
   print("FAIL: 事件日志里必须有 propDeleted 这条具名事实（不是笼统的 propLayoutChanged）"); exit(1) }
  require(id=="shared-a" && name=="共享内容 A" && rev==state.layoutRevision && settled=="withdrawn_then_deleted"
          && released==[shared],"删除事件必须带够信息：谁、什么、哪个布局版本、怎么收场、释放了什么")
  // 「一次提交一条事实」：新记的这一条**就是**删除事实本身（不是再补一条笼统的布局变化）。
  // 上面 count+1 与 last 已经把这件事钉住了 —— 这里再确认删除那一件没有第二条附加事件。
  require(events.dropLast().last.map { if case .propDeleted = $0.kind { return false }; return true } ?? true,
          "删除不得在末尾之前再补记一条同样针对它的具名事实")
  require(state.layoutRevision==layoutBefore+1,"删除只推进一个布局版本")
  // 摆好的那一件走了 ⇒ 那里不再挡人（这正是"删除只会移走障碍"的单调性）。
  require(context.collisionWorld.canOccupy(.init(radius:0.1,height:1),at:SIMD3(5,0,5)),"删掉之后那里不该再挡人")

  // ---- (2)(3) 共享内容：还被别人引用 ⇒ 必须留着；计数为 0 才可回收 ----
  let receipt = service.deletionReceipt(objectID:"shared-a")
  guard let receipt else { print("FAIL: 删除后必须读得到回执"); exit(1) }
  require(receipt.reclamation.released==[shared],"回执必须报出释放了哪些内容")
  require(receipt.reclamation.retainedCounts[shared]==1,
          "shared 还被 shared-b 引用 ⇒ 计数必须是 1（要能给出**数字**）")
  require(receipt.reclamation.retained[shared]==["shared-b"],"必须说得出还在引用它的是哪一件")
  require(receipt.reclamation.unreferenced.isEmpty,"还有引用者时**不许**把内容判成可回收")
  let reclaimed=files.reclaim(receipt.reclamation)
  require(reclaimed.isEmpty,"还被引用的内容一份都不许回收")
  require(files.has(shared),"共享内容必须还在磁盘上（按 objectID 删文件正是要抓的缺陷）")
  let payload=receipt.payload
  // 三层证明要**看得见数字**，不只是断言通过：把回执原样打出来（这就是报告里贴的那份）。
  print("deletion receipt: " + String(decoding: (try? JSONSerialization.data(
    withJSONObject: payload, options: [.sortedKeys])) ?? Data(), as: UTF8.self))
  guard let fileLayer=payload["file_layer"] as? [String:Any],
        let kept=fileLayer["kept"] as? [[String:Any]] else { print("FAIL: 回执必须带文件层"); exit(1) }
  require(kept.contains { ($0["sha256"] as? String)==shared && ($0["referenced_by"] as? [String])==["shared-b"] },
          "文件层必须逐份给出'保留'与引用者（这就是共享文件不误删的证据）")

  // ---- (7) 承托几何拿不到：**仍然删得掉**，而摆放照旧 fail-closed 拒绝 ----
  let blind=ResidentPropPlacementService(context:context,support:{nil},isCurrent:{true})
  do { _ = try blind.commit(.place(objectID:"shared-b",placement:placed),expectedLayoutRevision:state.layoutRevision,requestID:"blind-place")
       print("FAIL: 承托几何拿不到时摆放必须被拒绝（fail-closed）"); exit(1) } catch {}
  _ = try blind.commit(.delete(objectID:"shared-b",reason:nil),expectedLayoutRevision:context.state.layoutRevision,requestID:"delete-b")
  require(context.state.propTombstones?["shared-b"] != nil,"承托几何拿不到也必须删得掉（删除只会移走障碍，不需要空间判据）")
  // 第二件走了 ⇒ shared 的引用计数归零 ⇒ 才谈得上回收。
  let second=service.deletionReceipt(objectID:"shared-b")!
  require(second.reclamation.unreferenced==[shared],"两件都删掉之后，计数归零才可回收")
  require(second.reclamation.retained.isEmpty,"归零之后不该还有引用者")
  require(files.reclaim(second.reclamation)==[shared],"计数归零 ⇒ 文件层可以回收它")
  require(!files.has(shared),"回收之后字节才不在")
  require(files.has(other),"**别的**物件引用的内容一份都不许动")

  // ---- (6) 失败具名 ----
  do { _ = try service.commit(.delete(objectID:"shared-b",reason:nil),expectedLayoutRevision:context.state.layoutRevision,requestID:"delete-b-again")
       print("FAIL: 再删一次必须具名失败，不许静默成功"); exit(1) }
  catch let error as WorldPropLayoutError {
   require(error==WorldPropLayoutError.objectAlreadyDeleted(objectID:"shared-b"),"已经删过的必须报 objectAlreadyDeleted")
   require(error.errorDescription?.contains("已经删除过了")==true,"失败文案必须可读")
  }
  do { _ = try service.commit(.delete(objectID:"never-existed",reason:nil),expectedLayoutRevision:context.state.layoutRevision,requestID:"delete-ghost")
       print("FAIL: 删一件不存在的必须具名失败"); exit(1) }
  catch let error as WorldPropLayoutError {
   require(error==WorldPropLayoutError.objectNotFound(objectID:"never-existed"),"找不到必须报 objectNotFound")
  }

  // ---- (4) 正拿在手里 / 挂在身上：原子收场（放回再删），**绝不悬空** ----
  let backCalibration=WorldPropGripCalibration(avatarAssetID:"avatar",hand:.back,
    normalizedGrip:.init(x:0.5,y:0.5,z:0.5),localOffset:.init(x:0,y:0,z:0),localRotation:.init(x:0,y:0,z:0,w:1))
  let heldService=ResidentPropPlacementService(context:context,support:{flat},
    currentAvatarAssetID:{"avatar"}, makeGripCalibration:{_,_,_ in backCalibration})
  let heldProp=WorldGeneratedProp(objectID:"held-d",sourceWishID:"wish-d",assetID:"sha256:"+other,displayName:"手上的东西 D",size:.init(x:0.2,y:0.2,z:0.2),sourceHeight:1)
  _ = try heldService.commit(.register(heldProp),expectedLayoutRevision:context.state.layoutRevision,requestID:"register-d")
  let heldCommand=try heldService.holdCommand(objectID:"held-d",point:.back)
  _ = try heldService.commit(heldCommand,expectedLayoutRevision:context.state.layoutRevision,requestID:"hold-d")
  require(context.state.heldProp?.objectID=="held-d","前置：D 必须真的在背后")
  let heldRevision=context.state.layoutRevision
  _ = try heldService.commit(.delete(objectID:"held-d",reason:"挂了也不要了"),expectedLayoutRevision:heldRevision,requestID:"delete-d")
  require(context.state.heldProp==nil,"删除挂在手上的东西必须先放回：删除后 heldProp 必须为空")
  require(leavesDanglingHold(context.state,"held-d")==false,"删除后绝不能留下指向不存在物件的 heldProp")
  guard let heldTomb=context.state.propTombstones?["held-d"] else { print("FAIL: 手持物删除也要留墓碑"); exit(1) }
  require(heldTomb.settlement==WorldPropDeletionSettlement.returnedFromSlot(
            slot:.back,position:WorldVector3(x:0,y:0,z:0)),
          "手持物必须记成'先放回原位再删除'，并说得出放回哪一处")
  require(heldTomb.settlement.name=="returned_then_deleted","结算名必须机器可读")
  // 负对照：**静默删除**（物件没了、手里的还指着它）必须被同一条判据抓出来。
  var dangling=context.state
  dangling.objectStates.removeValue(forKey:"held-d")
  dangling.heldProp=WorldHeldProp(objectID:"held-d",avatarAssetID:"avatar",hand:.back,
    returnState:WorldObjectState(isEnabled:true,transform:.init(position:.init(x:0,y:0,z:0),rotation:identity,scale:unit),metadata:[:]))
  require(leavesDanglingHold(dangling,"held-d")==true,
          "静默删除必须被判据抓出来（注入静默删除 ⇒ 这条断言红）")

  // ---- (5) 坏资产必须删得掉 ----
  // 先**登记好**（登记那一层照旧要求资产可用），再让资产坏掉，然后删 —— 删除这一层
  // 不得以"资产可用"为前提，否则坏资产会变成一件永远删不掉的东西。
  let brokenProp=WorldGeneratedProp(objectID:"broken-e",sourceWishID:"wish-e",assetID:"sha256:"+other,displayName:"坏资产 E",size:.init(x:0.2,y:0.2,z:0.2),sourceHeight:1)
  _ = try service.commit(.register(brokenProp),expectedLayoutRevision:context.state.layoutRevision,requestID:"register-e")
  prepareFails=true
  _ = try service.commit(.delete(objectID:"broken-e",reason:"资产坏了，清掉"),expectedLayoutRevision:context.state.layoutRevision,requestID:"delete-e")
  require(context.state.propTombstones?["broken-e"] != nil,
          "资产坏掉的物件必须删得掉（把'资产可用'当删除前提会造出删不掉的坏物件）")
  prepareFails=false

  // ---- (8) 没被点名的那一件：一个字节都不变 ----
  let untouchedBefore=context.state.objectStates["other-c"]
  require(untouchedBefore != nil,"前置：other-c 还在库存里")
  _ = try service.commit(.place(objectID:"other-c",placement:placed),expectedLayoutRevision:context.state.layoutRevision,requestID:"place-c")
  guard let placedC=context.state.objectStates["other-c"] else { print("FAIL: other-c 必须摆好了"); exit(1) }
  let beforeAll=context.state
  let spare=WorldGeneratedProp(objectID:"spare-f",sourceWishID:"wish-f",assetID:"sha256:"+other,displayName:"待删的杂物 F",size:.init(x:0.2,y:0.2,z:0.2),sourceHeight:1)
  _ = try service.commit(.register(spare),expectedLayoutRevision:context.state.layoutRevision,requestID:"register-f")
  _ = try service.commit(.delete(objectID:"spare-f",reason:"只删这一件"),expectedLayoutRevision:context.state.layoutRevision,requestID:"delete-f")
  require(context.state.objectStates["other-c"]==placedC,"删别人的时候，没被点名的物件必须逐位不变（斧头/咖啡机一个字不动）")
  require(context.state.objectStates["other-c"]?.transform==placedC.transform,"它的落点也必须逐位不变")
  require(context.state.objectStates["other-c"]?.metadata==placedC.metadata,"它的元数据也必须逐位不变")
  require(beforeAll.objectStates["other-c"]?.isEnabled==true,"前置：它本来就在房间里")
  // 三件删掉之后，墓碑一条不少（历史留下来，不是硬删）。
  require(Set((context.state.propTombstones ?? [:]).keys)==["shared-a","shared-b","held-d","broken-e","spare-f"],
          "墓碑必须一件不少地留下来（删除是软删：记录不删、只标记）")
  require(context.state.objectStates.count==1,"房间里只剩没被点名的那一件")
  print("PASS: 删除语义（墓碑 + 具名事实；共享内容按派生引用计数保留；摆放/手持原子收场且不悬空；坏资产删得掉；承托几何拿不到仍删得掉；未点名物件逐位不变）")
  print("PASS: 删干净三层（记录=墓碑+propDeleted；引用=释放/保留带数字；文件=计数>0 必须留、归零才回收）")
 }
}
"""#

let tmp=FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-prop-delete-\(UUID())")
try FileManager.default.createDirectory(at:tmp,withIntermediateDirectories:true)
defer { try? FileManager.default.removeItem(at:tmp) }
let source=tmp.appendingPathComponent("Test.swift")
try harness.write(to:source,atomically:true,encoding:.utf8)
func run(_ binary:String,_ args:[String])throws->Int32 { let p=Process();p.executableURL=URL(fileURLWithPath:binary);p.arguments=args;try p.run();p.waitUntilExit();return p.terminationStatus }
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
let base = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
let result=try run("/usr/bin/swiftc",["-j1","-parse-as-library","-I",build.appendingPathComponent("Modules").path,
    base.appendingPathComponent("Agent/WorldAgentContext.swift").path,
    base.appendingPathComponent("Presence/ResidentPropPlacementService.swift").path,
    source.path,"-o",binary.path]+objects)
guard result==0 else { exit(result) }
exit(try run(binary.path,[]))

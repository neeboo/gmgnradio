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
@MainActor func flatSupport()->ResidentPropPlacementSupport {
 let bounds=WorldPlanarBounds(minimumX:flatWorld.minimumX,maximumX:flatWorld.maximumX,
                              minimumZ:flatWorld.minimumZ,maximumZ:flatWorld.maximumZ)
 let grid=PropSupportGridBuilder.build(collision:flatWorld,bounds:bounds,
                                       seed:WorldVector3(x:5,y:0,z:5),parameters:PropSupportGridParameters())
 return ResidentPropPlacementSupport(grid:grid,collision:flatWorld)
}
@MainActor func require(_ b:Bool,_ s:String) { if !b { print("FAIL: \(s)"); exit(1) } }
@main struct Test {
 @MainActor static func main() throws {
  let manifest = try JSONDecoder().decode(WorldManifest.self,from:Data(contentsOf:URL(fileURLWithPath:"apps/macos/Resources/Worlds/marble-living-cabin/world.json")))
  let disk=Disk(); let context=try WorldAgentContext(manifest:manifest,persistence:disk)
  context.installCollisionWorld(Floor())
  let flat=flatSupport()
  var authorized=true
  let service=ResidentPropPlacementService(context:context,support:{flat},isCurrent:{authorized})
  let prop=WorldGeneratedProp(objectID:"prop1",sourceWishID:"wish1",assetID:"asset1",displayName:"Coffee",size:.init(x:0.4,y:0.42,z:0.4),sourceHeight:2)
  _ = try service.commit(.register(prop),expectedLayoutRevision:0,requestID:"register")
  let before=context.state
  let placement=WorldPropPlacement(surfaceID:"floor",position:.init(x:5,y:0,z:5),yaw:0)
  _ = try service.preview(objectID:"prop1",placement:placement)
  require(context.state==before,"preview mutated state")
  disk.fail=true
  do { _ = try service.commit(.place(objectID:"prop1",placement:placement),expectedLayoutRevision:1,requestID:"place"); fatalError("save failure accepted") } catch {}
  require(context.state==before && context.collisionWorld.canOccupy(.init(radius:0.1,height:1),at:SIMD3(5,0,5)),"failed save changed state/collision")
  disk.fail=false
  _ = try service.commit(.place(objectID:"prop1",placement:placement),expectedLayoutRevision:1,requestID:"place")
  require(!context.collisionWorld.canOccupy(.init(radius:0.1,height:1),at:SIMD3(5,0,5)),"new object not blocking")
  require(context.collisionWorld.groundHeight(at:SIMD3(5,0,5))==0,"object top became ground")
  context.installCollisionWorld(Floor())
  require(!context.collisionWorld.canOccupy(.init(radius:0.1,height:1),at:SIMD3(5,0,5)),"base replacement lost object")
  require(!context.collisionWorld.canOccupy(.init(radius:0.1,height:1),at:SIMD3(10,0,5)),"base replacement lost environment")
  let restored=try WorldAgentContext(manifest:manifest,persistence:disk)
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
  savedAvatarID = "pmx.2b-miss-0414-standard";disk.fail=true
  do { _ = try failingHold.commit(delayedHold,expectedLayoutRevision:2,requestID:"failed-hold-save");fatalError("failed hold save accepted") } catch {}
  require(context.state == placed && context.state.heldProp == nil,"failed hold persistence changed state")
  disk.fail=false
  _ = try failingHold.commit(delayedHold,expectedLayoutRevision:2,requestID:"saved-hold")
  let heldBeforeFailedReturn = context.state
  let delayedReturn = try failingHold.returnHeldCommand(objectID:"prop1")
  disk.fail=true
  do { _ = try failingHold.commit(delayedReturn,expectedLayoutRevision:3,requestID:"failed-return-save");fatalError("failed return save accepted") } catch {}
  require(context.state == heldBeforeFailedReturn && context.state.heldProp?.objectID == "prop1","failed return persistence claimed the hand was clear")
  disk.fail=false
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
  require(context.state.objectStates["prop1"]?.isEnabled == false,"reentrant newer layout lost")
  // 拿不到承托几何 → fail-closed（`support` 默认 `{ nil }`），而不是"随便放"。
  let unready=ResidentPropPlacementService(context:context)
  do { _ = try unready.preview(objectID:"prop1",placement:placement); fatalError("missing environment accepted") }
  catch let error as ResidentPropPlacementError { require(error == .environmentNotReady,"wrong missing-environment rejection: \(error)") }
  let identity=WorldQuaternion(x:0,y:0,z:0,w:1)
  let unit=WorldVector3(x:1,y:1,z:1)
  let fixture=WorldManifest(schemaVersion:manifest.schemaVersion,packageID:"test",packageVersion:"1",worldID:"test",displayName:"test",calibration:manifest.calibration,
   spawn:.init(position:.init(x:0,y:0,z:0),rotation:identity,scale:unit),
   collisionVolumes:[.init(id:"fixed",center:.init(x:4,y:0.5,z:0),halfExtents:.init(x:0.5,y:0.5,z:0.5),rotation:identity,isBlocking:true)],
   waypoints:[.init(id:"a",position:.init(x:1,y:0,z:2),arrivalRadius:0.2,enabled:true),.init(id:"b",position:.init(x:3,y:0,z:2),arrivalRadius:0.2,enabled:true)],
   routes:[.init(id:"route",waypointIDs:["a","b"],bidirectional:true,enabled:true)],activities:[],cameras:[],capabilities:[],resources:[])
  let routeContext=try WorldAgentContext(manifest:fixture)
  routeContext.installCollisionWorld(Floor())
  let routing=ResidentPropPlacementService(context:routeContext,support:{flat})
  _ = try routing.commit(.register(prop),expectedLayoutRevision:0,requestID:"import")
  func rejection(_ x:Float,_ z:Float,_ expected:ResidentPropPlacementError) throws {
   do { _ = try routing.preview(objectID:"prop1",placement:.init(surfaceID:"floor",position:.init(x:x,y:0,z:z),yaw:0)); fatalError("unsafe placement accepted") }
   catch let error as ResidentPropPlacementError { require(error==expected,"wrong placement rejection: \(error)") }
  }
  try rejection(0,0,.collision("居民"))
  // 阻挡体积/已放物件的互斥现在由 `PropPlacementEvaluator` 判定，所以原因走
  // `.blockedBySupport(...)`（旧的 `.collision(id)` 通道已经不存在）。
  try rejection(4,0,.blockedBySupport(.blockedByBlockingVolume("fixed")))
  try rejection(1,2,.blockedRoute("a"))
  try rejection(2,2,.blockedRoute("route"))
  _ = try routing.commit(.place(objectID:"prop1",placement:.init(surfaceID:"floor",position:.init(x:5,y:0,z:5),yaw:0)),expectedLayoutRevision:1,requestID:"first-place")
  let second=WorldGeneratedProp(objectID:"prop2",sourceWishID:"wish2",assetID:"asset2",displayName:"Second",size:prop.size,sourceHeight:2)
  _ = try routing.commit(.register(second),expectedLayoutRevision:2,requestID:"second-import")
  do { _ = try routing.preview(objectID:"prop2",placement:.init(surfaceID:"floor",position:.init(x:5,y:0,z:5),yaw:0)); fatalError("overlapping props accepted") }
  catch let error as ResidentPropPlacementError { require(error == .blockedBySupport(.blockedByPlacedProp("prop1")) || error == .blockedBySupport(.blockedByPlacedProp("prop2")),"wrong overlap rejection: \(error)") }
  let holding=ResidentPropPlacementService(context:routeContext,support:{flat},
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
  let hugeContext=try WorldAgentContext(manifest:huge)
  let hugeService=ResidentPropPlacementService(context:hugeContext)
  do { _ = try hugeService.commit(.register(prop),expectedLayoutRevision:0,requestID:"huge"); fatalError("oversized route accepted") }
  catch let error as ResidentPropPlacementError { require(error == .blockedRoute("huge-route"),"wrong oversized route rejection") }
  print("PASS: layout preview, atomic save including hold, reserved footprint, collision recovery, bounds and stop checks")
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
guard result==0 else { exit(result) };exit(try run(binary.path,[]))

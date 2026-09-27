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
@MainActor func require(_ b:Bool,_ s:String) { if !b { print("FAIL: \(s)"); exit(1) } }
@main struct Test {
 @MainActor static func main() throws {
  let manifest = try JSONDecoder().decode(WorldManifest.self,from:Data(contentsOf:URL(fileURLWithPath:"apps/macos/Resources/Worlds/marble-living-cabin/world.json")))
  let disk=Disk(); let context=try WorldAgentContext(manifest:manifest,persistence:disk)
  context.installCollisionWorld(Floor())
  let surface=ResidentPropSupportSurface(id:"floor",center:.init(x:5,y:0,z:5),halfExtents:.init(x:1,y:0,z:1),yaw:0,excludedCollisionID:nil)
  var authorized=true
  let service=ResidentPropPlacementService(context:context,surfaces:[surface],isCurrent:{authorized},validateEnvironment:{ _,_ in })
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
  do { _ = try service.preview(objectID:"prop1",placement:.init(surfaceID:"floor",position:.init(x:5.9,y:0,z:5),yaw:.pi/4)); fatalError("edge crossing accepted") } catch {}
  let placed=context.state
  var savedAvatarID = "pmx.2b-miss-0414-standard"
  let failingHold=ResidentPropPlacementService(context:context,surfaces:[surface],validateEnvironment:{_,_ in},
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
  let wallSurface=ResidentPropSupportSurface(id:"wall",center:.init(x:10,y:0,z:5),halfExtents:.init(x:1,y:0,z:1),yaw:0,excludedCollisionID:nil)
  let wallService=ResidentPropPlacementService(context:context,surfaces:[surface,wallSurface],validateEnvironment:{ _,_ in })
  do { _ = try wallService.preview(objectID:"prop1",placement:.init(surfaceID:"wall",position:.init(x:10,y:0,z:5),yaw:0)); fatalError("real environment wall accepted") } catch {}
  var reentered=false
  let reentrant=ResidentPropPlacementService(context:context,surfaces:[surface],prepare:{ _ in
   if !reentered { reentered=true; _ = try service.commit(.withdraw(objectID:"prop1"),expectedLayoutRevision:context.state.layoutRevision,requestID:"newer") }
  },validateEnvironment:{ _,_ in })
  do { _ = try reentrant.commit(.place(objectID:"prop1",placement:placement),expectedLayoutRevision:context.state.layoutRevision,requestID:"outer"); fatalError("preparation overwrote newer state") } catch {}
  require(context.state.objectStates["prop1"]?.isEnabled == false,"reentrant newer layout lost")
  let unready=ResidentPropPlacementService(context:context,surfaces:[surface])
  do { _ = try unready.preview(objectID:"prop1",placement:placement); fatalError("missing environment accepted") } catch {}
  let identity=WorldQuaternion(x:0,y:0,z:0,w:1)
  let unit=WorldVector3(x:1,y:1,z:1)
  let fixture=WorldManifest(schemaVersion:manifest.schemaVersion,packageID:"test",packageVersion:"1",worldID:"test",displayName:"test",calibration:manifest.calibration,
   spawn:.init(position:.init(x:0,y:0,z:0),rotation:identity,scale:unit),
   collisionVolumes:[.init(id:"fixed",center:.init(x:4,y:0.5,z:0),halfExtents:.init(x:0.5,y:0.5,z:0.5),rotation:identity,isBlocking:true)],
   waypoints:[.init(id:"a",position:.init(x:1,y:0,z:2),arrivalRadius:0.2,enabled:true),.init(id:"b",position:.init(x:3,y:0,z:2),arrivalRadius:0.2,enabled:true)],
   routes:[.init(id:"route",waypointIDs:["a","b"],bidirectional:true,enabled:true)],activities:[],cameras:[],capabilities:[],resources:[])
  let routeContext=try WorldAgentContext(manifest:fixture)
  routeContext.installCollisionWorld(Floor())
  let broad=ResidentPropSupportSurface(id:"floor",center:.init(x:0,y:0,z:0),halfExtents:.init(x:8,y:0,z:8),yaw:0,excludedCollisionID:nil)
  let routing=ResidentPropPlacementService(context:routeContext,surfaces:[broad],validateEnvironment:{_,_ in})
  _ = try routing.commit(.register(prop),expectedLayoutRevision:0,requestID:"import")
  func rejection(_ x:Float,_ z:Float,_ expected:ResidentPropPlacementError) throws {
   do { _ = try routing.preview(objectID:"prop1",placement:.init(surfaceID:"floor",position:.init(x:x,y:0,z:z),yaw:0)); fatalError("unsafe placement accepted") }
   catch let error as ResidentPropPlacementError { require(error==expected,"wrong placement rejection: \(error)") }
  }
  try rejection(0,0,.collision("居民"))
  try rejection(4,0,.collision("fixed"))
  try rejection(1,2,.blockedRoute("a"))
  try rejection(2,2,.blockedRoute("route"))
  _ = try routing.commit(.place(objectID:"prop1",placement:.init(surfaceID:"floor",position:.init(x:5,y:0,z:5),yaw:0)),expectedLayoutRevision:1,requestID:"first-place")
  let second=WorldGeneratedProp(objectID:"prop2",sourceWishID:"wish2",assetID:"asset2",displayName:"Second",size:prop.size,sourceHeight:2)
  _ = try routing.commit(.register(second),expectedLayoutRevision:2,requestID:"second-import")
  do { _ = try routing.preview(objectID:"prop2",placement:.init(surfaceID:"floor",position:.init(x:5,y:0,z:5),yaw:0)); fatalError("overlapping props accepted") }
  catch let error as ResidentPropPlacementError { require(error == .collision("prop1") || error == .collision("prop2"),"wrong overlap rejection") }
  let holding=ResidentPropPlacementService(context:routeContext,surfaces:[broad],validateEnvironment:{_,_ in},
    currentAvatarAssetID:{"pmx.2b-miss-0414-standard"},makeGripCalibration:{ prop,avatarID in
      .init(avatarAssetID:avatarID,hand:.rightHand,normalizedGrip:.init(x:0.5,y:0.2,z:0.5),
        localOffset:.init(x:0,y:0,z:0),localRotation:identity)
    })
  _ = try holding.commit(holding.holdCommand(objectID:"prop1"),expectedLayoutRevision:3,requestID:"hold-footprint")
  do { _ = try holding.preview(objectID:"prop2",placement:.init(surfaceID:"floor",position:.init(x:5,y:0,z:5),yaw:0));fatalError("held return footprint was reused") }
  catch let error as ResidentPropPlacementError { require(error == .collision("prop1") || error == .collision("prop2"),"wrong held-footprint rejection") }
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
  let hugeService=ResidentPropPlacementService(context:hugeContext,surfaces:[broad],validateEnvironment:{_,_ in})
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

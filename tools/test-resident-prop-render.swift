import Foundation
let descriptor = "apps/macos/Sources/GMGNRadio/Presence/WishMachineOutputDescriptor.swift"
let source = try String(contentsOfFile: descriptor, encoding: .utf8)
guard source.contains("struct ResidentPropRenderDescriptor") else { print("FAIL: resident prop placement contract missing"); exit(1) }
let harness = #"""
import Foundation
import simd
func check(_ value: Bool, _ message: String) { if !value { print("FAIL:",message);exit(1) } }
@main struct Checks {
 @MainActor static func main() throws {
  let ownership=ResidentPropRenderOwnership(),space=ResidentPropRenderOwner(),cam=ResidentPropRenderOwner()
  let lease=ownership.claim(owner:space,worldID:"w",drawsWorld:true,isVisible:true)!
  check(ownership.claim(owner:cam,worldID:"w",drawsWorld:false,isVisible:true)==nil,"LiveCam cannot replace space owner")
  check(!ownership.release(owner:cam),"LiveCam cannot clear space hooks")
  check(ownership.accepts(owner:space,worldID:"w",revision:lease),"space hook remains live")
  ownership.invalidate()
  check(!ownership.accepts(owner:space,worldID:"w",revision:lease),"exit invalidates old callbacks")
  let next=ownership.claim(owner:space,worldID:"next",drawsWorld:true,isVisible:true)!
  check(next != lease && !ownership.accepts(owner:space,worldID:"w",revision:lease),"new world rejects old async completion")
  check(ownership.release(owner:space),"only owner can release hooks")
  check(ownership.claim(owner:cam,worldID:"w",drawsWorld:true,isVisible:false)==nil,"hidden view cannot claim")
  do { let temporary=ResidentPropRenderOwner();check(ownership.claim(owner:temporary,worldID:"w",drawsWorld:true,isVisible:true) != nil,"temporary view owns hook") }
  check(ownership.claim(owner:space,worldID:"w",drawsWorld:true,isVisible:true) != nil,"destroyed view does not retain ownership")
  let min=SIMD3<Float>(-2,-1,-3),max=SIMD3<Float>(4,3,1),p=SIMD3<Float>(6,0.7,-2)
  let t=try ResidentPropPlacementMatrix.transform(minimum:min,maximum:max,targetHeight:0.8,position:p,yaw:.pi/2)
  let bottom=t*SIMD4<Float>(1,-1,-1,1), top=t*SIMD4<Float>(1,3,-1,1)
  check(simd_length(SIMD3(bottom.x,bottom.y,bottom.z)-p)<0.00001,"bottom center uses one scale before yaw")
  check(abs(top.y-bottom.y-0.8)<0.00001,"height exactly target")
  let side=t*SIMD4<Float>(4,-1,-1,1)
  check(abs(side.x-p.x)<0.00001 && abs(side.z-(p.z-0.6))<0.00001,"yaw rotates physical width to Z")
  let url=URL(fileURLWithPath:"/tmp/fixture.glb")
  let a=ResidentPropRenderDescriptor(objectID:"a",worldID:"w",assetID:"shared",modelURL:url,targetHeightMeters:0.8,position:p,yaw:0)
  var preview=a;preview.position.x += 1
  let b=ResidentPropRenderDescriptor(objectID:"b",worldID:"w",assetID:"shared",modelURL:url,targetHeightMeters:0.8,position:p,yaw:0)
  check(a.assetKey==preview.assetKey && a.assetKey==b.assetKey,"transforms and instance IDs do not reload asset")
  check(ResidentPropRenderSelection.resolve([a,b],preview:preview,worldID:"w")==[preview,b],"preview replaces original exactly once")
  check(ResidentPropRenderSelection.resolve([a,b],preview:nil,worldID:"w")==[a,b],"cancel restores formal transforms")
  check(ResidentPropRenderSelection.resolve([a,b],preview:preview,worldID:"other").isEmpty,"world isolation")
  let identity=matrix_identity_float4x4
  check(ResidentPropProjection.point(normalized:SIMD2(0.5,0.5),surfaceY:0,inverseViewProjection:identity)==nil,"parallel ray rejected")
  var camera=identity;camera.columns.2=SIMD4(0,-1,0,0);camera.columns.1=SIMD4(0,0,1,0);camera.columns.3=SIMD4(0,2,0,1)
  let hit=ResidentPropProjection.point(normalized:SIMD2(0.5,0.5),surfaceY:0.7,inverseViewProjection:camera)
  check(hit != nil && abs(hit!.y-0.7)<0.00001,"viewport ray hits exact support plane")
  print("PASS: prop scale/yaw, unique preview/cancel, shared identity, world isolation and support ray")
 }
}
"""#
let temp=FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-prop-render-\(UUID())")
try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
defer {try? FileManager.default.removeItem(at:temp)}
let file=temp.appendingPathComponent("main.swift"),exe=temp.appendingPathComponent("check")
try harness.write(to:file,atomically:true,encoding:.utf8)
func run(_ path:String,_ args:[String]) throws->Int32 {let p=Process();p.executableURL=URL(fileURLWithPath:path);p.arguments=args;try p.run();p.waitUntilExit();return p.terminationStatus}
let result=try run("/usr/bin/nice",["-n","15","/usr/bin/swiftc","-j1","-parse-as-library",descriptor,file.path,"-o",exe.path])
guard result==0 else {exit(result)}
exit(try run(exe.path,[]))

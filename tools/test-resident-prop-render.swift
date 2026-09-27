import Foundation
let descriptor = "apps/macos/Sources/GMGNRadio/Presence/WishMachineOutputDescriptor.swift"
let picker = "apps/macos/Sources/GMGNRadio/Presence/PropSupportGridPicker.swift"
let source = try String(contentsOfFile: descriptor, encoding: .utf8)
guard source.contains("struct ResidentPropRenderDescriptor") else { print("FAIL: resident prop placement contract missing"); exit(1) }
// 拾取器刻意只依赖 Foundation + simd，所以这里能单独编译它做离线验证。
let pickerSource = try String(contentsOfFile: picker, encoding: .utf8)
guard pickerSource.contains("enum PropSupportGridPicker") else { print("FAIL: build-mode grid picker missing"); exit(1) }
// 按行精确判断 import，避免把注释里提到的字样当成真的 import。
let pickerImports = pickerSource.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
guard !pickerImports.contains("import WorldRuntime") else { print("FAIL: grid picker must stay independent of WorldRuntime for offline verification"); exit(1) }
guard pickerImports.allSatisfy({ $0 == "" || !$0.hasPrefix("import ") || $0 == "import Foundation" || $0 == "import simd" }) else {
    print("FAIL: grid picker must only import Foundation and simd"); exit(1) }
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
  // ── 建造模式格子拾取（工作项 8）──────────────────────────────────────────
  func cell(_ x:Int,_ z:Int,_ layer:Int,_ height:Float) -> PropSupportGridPicker.Candidate {
      PropSupportGridPicker.Candidate(columnX:x,columnZ:z,layer:layer,supportHeight:height) }
  // 同一台合成相机：位于 (0,2,0)，沿 -Y 看下去，故 NDC 中心命中 (0, y, 0)。
  let pickerRay=PropSupportGridPicker.ray(normalized:SIMD2(0.5,0.5),inverseViewProjection:camera)
  check(pickerRay != nil && abs(pickerRay!.origin.y-2)<0.00001,"picker ray originates at the near plane")
  check(pickerRay != nil && abs(pickerRay!.direction.y + 1)<0.00001,"picker ray points down the view axis")
  check(PropSupportGridPicker.pick(normalized:SIMD2(0.5,0.5),inverseViewProjection:identity,
        candidates:[cell(0,0,0,0.7)],spacing:0.25,maximumDistance:30)==nil,
        "parallel ray picks nothing")
  check(PropSupportGridPicker.pick(normalized:SIMD2(1.5,0.5),inverseViewProjection:camera,
        candidates:[cell(0,0,0,0.7)],spacing:0.25,maximumDistance:30)==nil,
        "cursor outside the viewport picks nothing")
  check(PropSupportGridPicker.pick(normalized:SIMD2(0.5,0.5),inverseViewProjection:camera,
        candidates:[cell(0,0,0,0.7)],spacing:0,maximumDistance:30)==nil,
        "invalid spacing picks nothing")

  // 命中 (0,0.7,0) 恰好落在列 (0,0) 的最小角上。
  let floor=cell(0,0,0,0.7)
  let picked=PropSupportGridPicker.pick(normalized:SIMD2(0.5,0.5),inverseViewProjection:camera,
        candidates:[floor],spacing:0.25,maximumDistance:30)
  check(picked==floor,"picked cell is the one whose own cell contains the hit")

  // 关键：命中点必须落在【该层自己的格子】里，不能四舍五入到最近的格子。
  let neighbour=cell(-1,0,0,0.7)
  check(PropSupportGridPicker.pick(normalized:SIMD2(0.5,0.5),inverseViewProjection:camera,
        candidates:[neighbour],spacing:0.25,maximumDistance:30)==nil,
        "a neighbouring cell does not claim a hit that lands outside it")

  // 多层：桌面 (0.7) 在相机与地面 (0.2) 之间，必须选桌面 —— 不靠 GPU readback 也能选对层。
  let table=cell(0,0,1,0.7)
  let ground=cell(0,0,0,0.2)
  let nearest=PropSupportGridPicker.pick(normalized:SIMD2(0.5,0.5),inverseViewProjection:camera,
        candidates:[ground,table],spacing:0.25,maximumDistance:30)
  check(nearest==table,"nearest layer wins when two layers stack on one column")
  check(PropSupportGridPicker.pick(normalized:SIMD2(0.5,0.5),inverseViewProjection:camera,
        candidates:[table,ground],spacing:0.25,maximumDistance:30)==table,
        "pick result does not depend on candidate order")

  // 近层在别的列上时，应回落到后面的地面层。
  let tableElsewhere=cell(5,5,1,0.7)
  check(PropSupportGridPicker.pick(normalized:SIMD2(0.5,0.5),inverseViewProjection:camera,
        candidates:[tableElsewhere,ground],spacing:0.25,maximumDistance:30)==ground,
        "a nearer layer in another cell does not shadow this one")

  // 距离上限：命中距离为 1.3（t=1.3，方向为单位向量）。
  check(PropSupportGridPicker.pick(normalized:SIMD2(0.5,0.5),inverseViewProjection:camera,
        candidates:[floor],spacing:0.25,maximumDistance:1.0)==nil,
        "hit beyond maximumDistance is rejected")
  check(PropSupportGridPicker.pick(normalized:SIMD2(0.5,0.5),inverseViewProjection:camera,
        candidates:[floor],spacing:0.25,maximumDistance:1.5) != nil,
        "hit within maximumDistance is accepted")
  // 相机背后的层不算命中：地面在 y=3（相机上方）。
  let above=cell(0,0,0,3)
  check(PropSupportGridPicker.pick(normalized:SIMD2(0.5,0.5),inverseViewProjection:camera,
        candidates:[above],spacing:0.25,maximumDistance:30)==nil,
        "layer behind the camera is not picked")
  print("PASS: prop scale/yaw, unique preview/cancel, shared identity, world isolation, support ray and multi-layer grid picking")
 }
}
"""#
let temp=FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-prop-render-\(UUID())")
try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
defer {try? FileManager.default.removeItem(at:temp)}
let file=temp.appendingPathComponent("main.swift"),exe=temp.appendingPathComponent("check")
try harness.write(to:file,atomically:true,encoding:.utf8)
func run(_ path:String,_ args:[String]) throws->Int32 {let p=Process();p.executableURL=URL(fileURLWithPath:path);p.arguments=args;try p.run();p.waitUntilExit();return p.terminationStatus}
let result=try run("/usr/bin/nice",["-n","15","/usr/bin/swiftc","-j1","-parse-as-library",descriptor,picker,file.path,"-o",exe.path])
guard result==0 else {exit(result)}
exit(try run(exe.path,[]))

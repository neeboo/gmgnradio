import Foundation
let descriptor = "apps/macos/Sources/GMGNRadio/Presence/WishMachineOutputDescriptor.swift"
let picker = "apps/macos/Sources/GMGNRadio/Presence/PropSupportGridPicker.swift"
let presentation = "apps/macos/Sources/GMGNRadio/Presence/PropSupportGridPresentation.swift"
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
let presentationSource = try String(contentsOfFile: presentation, encoding: .utf8)
guard presentationSource.contains("enum PropSupportGridPresentation") else { print("FAIL: grid presentation missing"); exit(1) }
let presentationImports = presentationSource.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
guard presentationImports.allSatisfy({ $0 == "" || !$0.hasPrefix("import ") || $0 == "import Foundation" || $0 == "import simd" }) else {
    print("FAIL: grid presentation must only import Foundation and simd"); exit(1) }
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
  // 不再截断件数。这里曾经硬编码 4：第 5 件起会被静默丢弃，用户摆的家具凭空消失。
  let many=(0..<6).map { i in ResidentPropRenderDescriptor(objectID:"m\(i)",worldID:"w",assetID:"shared",modelURL:url,targetHeightMeters:0.8,position:p,yaw:0) }
  check(ResidentPropRenderSelection.resolve(many,preview:nil,worldID:"w").count==6,
        "every placed prop is selected, not just the first four")
  check(ResidentPropRenderSelection.resolve(many,preview:many[5],worldID:"w").count==6,
        "previewing an existing prop does not change the count")
  let extra=ResidentPropRenderDescriptor(objectID:"extra",worldID:"w",assetID:"shared",modelURL:url,targetHeightMeters:0.8,position:p,yaw:0)
  let withExtra=ResidentPropRenderSelection.resolve(many,preview:extra,worldID:"w")
  check(withExtra.count==7 && withExtra.last?.objectID=="extra",
        "a preview for a new prop is appended rather than dropped at the old cap")
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
  // ── 建造模式格子呈现（工作项 7 中可离线验证的部分）──────────────────────
  func gridCell(_ x:Int,_ z:Int,_ layer:Int,_ height:Float) -> PropSupportGridPresentation.Cell {
      PropSupportGridPresentation.Cell(columnX:x,columnZ:z,layer:layer,
          columnXWorld:Float(x)*0.25,columnZWorld:Float(z)*0.25,supportHeight:height) }
  var grid=PropSupportGridPresentation.Options.default
  grid.lift=0.001; grid.gap=0.08; grid.fadeStart=2; grid.fadeEnd=6
  grid.maximumDistance=10; grid.maximumInstances=20000
  let origin=SIMD3<Float>(0,0,0)
  check(PropSupportGridPresentation.instances(cells:[],states:[:],cameraPosition:origin,spacing:0.25,options:grid).isEmpty,
        "no cells means no instances")
  check(PropSupportGridPresentation.instances(cells:[gridCell(0,0,0,0)],states:[:],cameraPosition:origin,spacing:0,options:grid).isEmpty,
        "invalid spacing draws nothing")
  var badGrid=grid; badGrid.fadeEnd=badGrid.fadeStart
  check(PropSupportGridPresentation.instances(cells:[gridCell(0,0,0,0)],states:[:],cameraPosition:origin,spacing:0.25,options:badGrid).isEmpty,
        "invalid options draw nothing")

  let near=PropSupportGridPresentation.instances(cells:[gridCell(0,0,0,0.5)],states:[:],cameraPosition:origin,spacing:0.25,options:grid)
  check(near.count==1,"near cell is drawn")
  check(abs(near[0].center.x-0.125)<0.00001 && abs(near[0].center.z-0.125)<0.00001,
        "quad is centred inside its cell, not on the column corner")
  check(abs(near[0].center.y-0.501)<0.00001,"quad is lifted off the support plane")
  check(abs(near[0].size-0.23)<0.00001,"quad leaves a gap so cells read as a grid")
  check(abs(near[0].alpha-1)<0.00001,"inside fadeStart the grid is opaque")
  check(near[0].state == .placeable,"cells without a verdict default to placeable")

  // 相机在原点：列 16 的世界 X=4.0，列 24 的世界 X=6.0，列 40 的世界 X=10.0。
  let fading=PropSupportGridPresentation.instances(cells:[gridCell(16,0,0,0)],states:[:],cameraPosition:origin,spacing:0.25,options:grid)
  let fadingDistance=simd_length(SIMD3<Float>(4.125,0.001,0.125))
  check(fading.count==1 && abs(fading[0].alpha-(1-(fadingDistance-2)/4))<0.0001,
        "alpha falls off linearly between fadeStart and fadeEnd")
  let nearer=PropSupportGridPresentation.instances(cells:[gridCell(8,0,0,0)],states:[:],cameraPosition:origin,spacing:0.25,options:grid)
  check(nearer.count==1 && fading.count==1 && nearer[0].alpha > fading[0].alpha,
        "a nearer cell is never more transparent than a farther one")
  check(PropSupportGridPresentation.instances(cells:[gridCell(24,0,0,0)],states:[:],cameraPosition:origin,spacing:0.25,options:grid).isEmpty,
        "a cell exactly at fadeEnd is not drawn")
  check(PropSupportGridPresentation.instances(cells:[gridCell(40,0,0,0)],states:[:],cameraPosition:origin,spacing:0.25,options:grid).isEmpty,
        "a cell beyond maximumDistance is not drawn")

  // 状态着色：每种状态颜色不同，且能被显式覆盖。
  let allStates:[PropSupportGridPresentation.CellState] = [.placeable,.blocked,.occupied,.validFootprint,.invalidFootprint]
  var tints=Set<[Float]>()
  for state in allStates { tints.insert([state.tint.x,state.tint.y,state.tint.z,state.tint.w]) }
  check(tints.count==allStates.count,"every cell state has its own colour")
  let blockedCell=gridCell(0,0,0,0)
  let withState=PropSupportGridPresentation.instances(cells:[blockedCell],states:[blockedCell:.blocked],cameraPosition:origin,spacing:0.25,options:grid)
  check(withState.count==1 && withState[0].state == .blocked,"an explicit verdict overrides the default")

  // 预算：超出上限时丢【最远】的，保留最近的，并维持原始顺序。
  var budget=grid; budget.maximumInstances=3
  let five=[gridCell(0,0,0,0),gridCell(4,0,0,0),gridCell(8,0,0,0),gridCell(12,0,0,0),gridCell(16,0,0,0)]
  let kept=PropSupportGridPresentation.instances(cells:five,states:[:],cameraPosition:origin,spacing:0.25,options:budget)
  check(kept.count==3,"budget caps the instance count")
  check(abs(kept[0].center.x-0.125)<0.00001 && abs(kept[1].center.x-1.125)<0.00001 && abs(kept[2].center.x-2.125)<0.00001,
        "budget drops the farthest cells and keeps the order stable")
  check(PropSupportGridPresentation.instances(cells:five,states:[:],cameraPosition:origin,spacing:0.25,options:grid).count==5,
        "all five cells fit when the budget allows")
  check(PropSupportGridPresentation.instances(cells:five,states:[:],cameraPosition:origin,spacing:0.25,options:budget)
        == PropSupportGridPresentation.instances(cells:five,states:[:],cameraPosition:origin,spacing:0.25,options:budget),
        "instance generation is deterministic")
  print("PASS: prop scale/yaw, unique preview/cancel, shared identity, world isolation, support ray, multi-layer grid picking and grid presentation")
 }
}
"""#
let temp=FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-prop-render-\(UUID())")
try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
defer {try? FileManager.default.removeItem(at:temp)}
let file=temp.appendingPathComponent("main.swift"),exe=temp.appendingPathComponent("check")
try harness.write(to:file,atomically:true,encoding:.utf8)
func run(_ path:String,_ args:[String]) throws->Int32 {let p=Process();p.executableURL=URL(fileURLWithPath:path);p.arguments=args;try p.run();p.waitUntilExit();return p.terminationStatus}
let result=try run("/usr/bin/nice",["-n","15","/usr/bin/swiftc","-j1","-parse-as-library",descriptor,picker,presentation,file.path,"-o",exe.path])
guard result==0 else {exit(result)}
exit(try run(exe.path,[]))

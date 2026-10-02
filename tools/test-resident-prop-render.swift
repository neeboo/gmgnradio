import Foundation
let descriptor = "apps/macos/Sources/GMGNRadio/Presence/WishMachineOutputDescriptor.swift"
let picker = "apps/macos/Sources/GMGNRadio/Presence/PropSupportGridPicker.swift"
let presentation = "apps/macos/Sources/GMGNRadio/Presence/PropSupportGridPresentation.swift"
let hitTest = "apps/macos/Sources/GMGNRadio/Presence/ResidentPropHitTest.swift"
let source = try String(contentsOfFile: descriptor, encoding: .utf8)
guard source.contains("struct ResidentPropRenderDescriptor") else { print("FAIL: resident prop placement contract missing"); exit(1) }
// 描述符带着**尺寸意图**（`size_intent`）。这一轮只编描述符、不整份编
// `PropGenerationClient.swift`（那份依赖 WorldRuntime），所以按括号配平把
// `PropSizeIntent` 这一段声明**从生产源码里原样抽出来**当成一份源码文件一起编 ——
// 编的是同一份源码，不是在这儿抄一份类型定义。抽不到就 FAIL。
func declaration(in text: String, _ signature: String) -> String? {
    guard let start = text.range(of: signature)?.lowerBound,
          let open = text[start...].firstIndex(of: "{") else { return nil }
    var depth = 0
    for index in text[open...].indices {
        if text[index] == "{" { depth += 1 }
        if text[index] == "}" { depth -= 1 }
        if depth == 0 { return String(text[start...index]) }
    }
    return nil
}
let propGenerationClient = "apps/macos/Sources/GMGNRadio/Presence/PropGenerationClient.swift"
let propGenerationClientSource = try String(contentsOfFile: propGenerationClient, encoding: .utf8)
guard let sizeIntentDeclaration = declaration(in: propGenerationClientSource, "struct PropSizeIntent: Codable") else {
    print("FAIL: 生产源码里找不到 PropSizeIntent 的声明（尺寸意图契约不能只存在于别处）"); exit(1)
}
let temporaryDirectoryForSizeIntentShim = FileManager.default.temporaryDirectory
    .appendingPathComponent("gmgn-prop-render-contract-" + UUID().uuidString)
try FileManager.default.createDirectory(at: temporaryDirectoryForSizeIntentShim, withIntermediateDirectories: true)
let sizeIntentShim = temporaryDirectoryForSizeIntentShim.appendingPathComponent("PropSizeIntentContract.swift")
try ("import Foundation\n\n" + sizeIntentDeclaration + "\n").write(to: sizeIntentShim, atomically: true, encoding: .utf8)
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
// 场景内「点已摆物件」的命中：同样只依赖 Foundation + simd（它复用拾取器的射线）。
let hitTestSource = try String(contentsOfFile: hitTest, encoding: .utf8)
guard hitTestSource.contains("enum ResidentPropHitTest") else { print("FAIL: resident prop hit test missing"); exit(1) }
let hitTestImports = hitTestSource.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
guard hitTestImports.allSatisfy({ $0 == "" || !$0.hasPrefix("import ") || $0 == "import Foundation" || $0 == "import simd" }) else {
    print("FAIL: resident prop hit test must only import Foundation and simd"); exit(1) }
// 光标旁那枚「这里为什么不能放」的纯逻辑：几何只用 CoreGraphics，**不许**碰 AppKit /
// Metal / WorldRuntime —— 否则它就不能被离线编译与断言。
let blockLabel = "apps/macos/Sources/GMGNRadio/Presence/ResidentPropBlockReasonLabel.swift"
let blockLabelSource = try String(contentsOfFile: blockLabel, encoding: .utf8)
guard blockLabelSource.contains("enum ResidentPropBlockReasonLabel") else {
    print("FAIL: the block-reason label next to the cursor is missing"); exit(1) }
let blockLabelImports = blockLabelSource.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
guard blockLabelImports.allSatisfy({
    $0 == "" || !$0.hasPrefix("import ")
        || $0 == "import Foundation" || $0 == "import CoreGraphics" }) else {
    print("FAIL: the block-reason label must only import Foundation and CoreGraphics (it is drawn in the interaction view, not in Metal)"); exit(1) }
// 面板里的图例：它必须从格子配色的**同一处**取色，而不是各写一份 RGB。
let editorView = "apps/macos/Sources/GMGNRadio/VisualEngine/ResidentPropEditorView.swift"
let editorViewSource = try String(contentsOfFile: editorView, encoding: .utf8)
guard editorViewSource.contains("PropSupportGridPresentation.Legend.entries"),
      editorViewSource.contains("entry.srgbTint") else {
    print("FAIL: the placement panel has no legend for the grid colours (users keep asking what red means)"); exit(1) }
// 一份源码里所有「带小数点的数字字面量」，按出现顺序、归一成两位小数（`1.0` 与 `1.00` 同形）。
func decimalLiterals(_ source: String) -> [String] {
    let regex = try! NSRegularExpression(pattern: #"[0-9]+\.[0-9]+"#)
    let text = source as NSString
    return regex.matches(in: source, range: NSRange(location: 0, length: text.length)).map {
        String(format: "%.2f", Double(text.substring(with: $0.range)) ?? -1)
    }
}
// App 侧全部源码 → 各自的数字字面量。图例「与格子渲染同源」这条断言要能**真的抓住**
// "各写一份 RGB"，所以它扫的是全仓：同一个三元组只允许出现在定义 tint 的那一个文件里。
func mentionsState(_ source: String, _ name: String) -> Bool {
    let regex = try! NSRegularExpression(pattern: "\\.\(name)\\b")
    return regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) != nil
}
var appSourceNumbers: [(file: String, numbers: [String])] = []
var blockedOrOccupiedOutsideThePalette: [String] = []
if let walker = FileManager.default.enumerator(atPath: "apps/macos/Sources/GMGNRadio") {
    for case let path as String in walker where path.hasSuffix(".swift") {
        let text = try String(contentsOfFile: "apps/macos/Sources/GMGNRadio/" + path, encoding: .utf8)
        appSourceNumbers.append((path, decimalLiterals(text)))
        // `.blocked` / `.occupied` 这两个 `CellState` 在当前链路里没有任何赋值点（只有配色表
        // 提到它们，见 `case .blocked:`）。图例因此不列它们；哪天真的被赋给格子，这条会亮，
        // 图例必须跟着补上。
        //
        // 判据是"这个文件在谈 `CellState`"：`.blocked` / `.occupied` 是全仓的常用词
        // （`ActivityExecutionFailure.blocked`、`.blockedRoute` …），只按字面量扫会误报。
        if path != "Presence/PropSupportGridPresentation.swift",
           text.contains("CellState"),
           mentionsState(text, "blocked") || mentionsState(text, "occupied") {
            blockedOrOccupiedOutsideThePalette.append(path)
        }
    }
}
guard blockedOrOccupiedOutsideThePalette.isEmpty else {
    print("FAIL: .blocked/.occupied now have a live assignment in \(blockedOrOccupiedOutsideThePalette) — the legend must list them"); exit(1) }
guard blockedOrOccupiedOutsideThePalette.isEmpty else {
    print("FAIL: .blocked/.occupied now have a live assignment in \(blockedOrOccupiedOutsideThePalette) — the legend must list them"); exit(1) }
let sourceNumbersLiteral = "[" + appSourceNumbers
    .map { entry in
        "(\"\(entry.file)\", [" + entry.numbers.map { "\"\($0)\"" }.joined(separator: ",") + "])"
    }
    .joined(separator: ",") + "]"
let harness = #"""
import Foundation
import simd
import CoreGraphics
func check(_ value: Bool, _ message: String) { if !value { print("FAIL:",message);exit(1) } }
@main struct Checks {
 @MainActor static func main() throws {
  /// App 侧每份源码的数字字面量（由 harness 的驱动脚本扫出来注入）：图例"与格子同源"这条
  /// 断言扫的是**全仓**，所以"各写一份 RGB"不可能蒙混过关。
  let appSourceNumbers:[(file:String,numbers:[String])] = \#(sourceNumbersLiteral)
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
  let allStates:[PropSupportGridPresentation.CellState] = [.placeable,.blocked,.occupied,.validFootprint,.invalidFootprint,.hoverTarget]
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
  // ── 建造模式格子的焦点裁剪（The Sims：只画脚下一小块，不铺满地面）────────
  // 20 m × 20 m 的一块地板：0.25 m 格距 = 80×80 = 6400 列，比真实房间的一整块地板还大。
  var lawn:[PropSupportGridPresentation.Cell]=[]
  for x in -40..<40 { for z in -40..<40 { lawn.append(gridCell(x,z,0,0)) } }
  // 锚点 = 1×1 的 footprint（**空手**悬停时编辑器给的就是"一格"），着色表里只有它。
  let anchorCell=gridCell(0,0,0,0)
  let anchored=PropSupportGridPresentation.focusedInstances(
      cells:lawn,states:[anchorCell:.validFootprint],cameraPosition:origin,spacing:0.25,options:grid)
  let ring=Float(PropSupportGridPresentation.Focus.ringCount)
  check(anchored.count==25,
        "the focused patch is the footprint plus two rings, not the whole floor")
  check(anchored.allSatisfy { abs($0.center.x-0.125) <= ring*0.25+0.0001
        && abs($0.center.z-0.125) <= ring*0.25+0.0001 },
        "no instance is generated for a column farther than the ring radius")
  check(anchored.filter { $0.state == .validFootprint }.count==1
        && anchored.filter { $0.state == .validFootprint }.allSatisfy { abs($0.alpha-1) < 0.00001 },
        "the anchored footprint stays high contrast inside the patch")
  check(anchored.filter { $0.state != .validFootprint }.allSatisfy {
        abs($0.alpha-PropSupportGridPresentation.Focus.ringAlpha) < 0.00001 },
        "the ring is drawn at the ring alpha, not at the footprint's contrast")
  check(PropSupportGridPresentation.Focus.ringAlpha > 0
        && PropSupportGridPresentation.Focus.ringAlpha < 0.5,
        "the ring is a faint hint rather than a solid carpet")
  // 改动前的那种"整片"由一个入口生成，这里量出它到底有多少格：量级对比是结构性的。
  let unfocused=PropSupportGridPresentation.instances(
      cells:lawn,states:[anchorCell:.validFootprint],cameraPosition:origin,spacing:0.25,options:grid).count
  check(unfocused > anchored.count*20,
        "focusing removes the floor-wide carpet (before/after differ by more than 20x)")
  // 没有锚点（光标没落在任何承托层上，或还没进场景）→ 一个格子都不画，而不是恢复整片。
  check(PropSupportGridPresentation.focusedInstances(
        cells:lawn,states:[:],cameraPosition:origin,spacing:0.25,options:grid).isEmpty,
        "with no anchor the grid draws nothing instead of flooding the floor")
  // 焦点不跨层：锚点在地面时，旁边桌上的格子不该跟着浮出来。
  var stacked=lawn
  for y in 1...4 { stacked.append(gridCell(y,0,1,0.7)) }
  check(PropSupportGridPresentation.focusedInstances(
        cells:stacked,states:[anchorCell:.validFootprint],cameraPosition:origin,spacing:0.25,options:grid)
        .allSatisfy { $0.center.y < 0.5 },
        "a neighbouring layer's grid does not float into the focus patch")
  // ── 已摆物件的悬停发光：进场的是 `.hoverTarget`，而且**不越过** focus 裁剪 ────────
  // 4 格 footprint（2×2 列）的悬停发光的着色表：它就是编辑器模型在光标移到已摆物件上时
  // 写进 `states` 的东西（模型那一侧的断言在 test-resident-prop-editor.swift）。
  var glow:[PropSupportGridPresentation.Cell:PropSupportGridPresentation.CellState]=[:]
  for x in 0...1 { for z in 0...1 { glow[gridCell(x,z,0,0)] = .hoverTarget } }
  let lit=PropSupportGridPresentation.focusedInstances(
      cells:lawn,states:glow,cameraPosition:origin,spacing:0.25,options:grid)
  check(lit.count==36,"the glowing prop's patch is its 2x2 footprint plus two rings (36 cells), not the floor")
  // 「不越过裁剪」逐格量出来：画出来的列**恰好**是 footprint 的列范围各外扩 ringCount 圈，
  // 再远一列都没有实例（不是靠"总数看起来差不多"）。
  let litColumns=Set(lit.map { Int((($0.center.x-0.125)/0.25).rounded()) })
  let litRows=Set(lit.map { Int((($0.center.z-0.125)/0.25).rounded()) })
  let expectedColumns=Set(-PropSupportGridPresentation.Focus.ringCount...1+PropSupportGridPresentation.Focus.ringCount)
  check(litColumns==expectedColumns && litRows==expectedColumns,
        "the glow patch is exactly the footprint columns expanded by the ring count, no column farther")
  check(lit.filter { $0.state == .hoverTarget }.count==4
        && lit.filter { $0.state == .hoverTarget }.allSatisfy { abs($0.alpha-1) < 0.00001 },
        "every hovered footprint cell is drawn at full contrast inside the patch")
  check(lit.filter { $0.state != .hoverTarget }.allSatisfy {
        abs($0.alpha-PropSupportGridPresentation.Focus.ringAlpha) < 0.00001 },
        "the ring around a glowing prop stays faint")
  check(PropSupportGridPresentation.focusedInstances(
        cells:lawn,states:glow,cameraPosition:origin,spacing:0.25,options:grid).count
        < PropSupportGridPresentation.instances(cells:lawn,states:glow,cameraPosition:origin,spacing:0.25,options:grid).count,
        "the glow goes through the focus clip instead of flooding the floor")
  // ── 靠墙提示（**全局**表）不许把焦点窗口拉成整片地面 ──────────────────────────
  // 真机 2026-10-01「满地都是格子」的成因：`refreshWallPlaceability` 给**每一面**墙的第一个
  // 可放候选着色（真机日志原文：`格子派生：命中缓存 key=… 层=3160 墙面=194` +
  // `建造模式：格子派生结束，网格层=3160 可绘制列=3160`，房间 14.4 × 23.9 米），
  // 这批格子散落在整个房间里；而焦点锚点当时取的是 `states` 的**全部**键 ⇒ 外包框 = 整个房间
  // ⇒ 3160 列全画出来。所以这里量的是"锚点里有没有靠墙那一种状态"。
  var wallHints:[PropSupportGridPresentation.Cell:PropSupportGridPresentation.CellState]=[:]
  wallHints[anchorCell] = .validFootprint
  // 一面就在 footprint 旁边的墙脚（必须照画），两面在房间另一头（必须不画）。
  wallHints[gridCell(0,2,0,0)] = .wallPlaceable
  wallHints[gridCell(-38,-38,0,0)] = .wallPlaceable
  wallHints[gridCell(38,38,0,0)] = .wallPlaceable
  let wallHinted=PropSupportGridPresentation.focusedInstances(
      cells:lawn,states:wallHints,cameraPosition:origin,spacing:0.25,options:grid)
  check(wallHinted.count==25,
        "靠墙提示是全局表（真机 194 面墙、3160 列），它绝不能把焦点窗口拉成整片地面（实测画了 \(wallHinted.count) 格）")
  check(wallHinted.allSatisfy { abs($0.center.x-0.125) <= ring*0.25+0.0001
        && abs($0.center.z-0.125) <= ring*0.25+0.0001 },
        "靠墙提示不能生成焦点窗口之外的实例")
  let nearWall=wallHinted.filter { $0.state == .wallPlaceable }
  check(nearWall.count==1,"落在窗口内的靠墙提示必须照画（实测 \(nearWall.count) 个）")
  check(nearWall.allSatisfy { abs($0.alpha-1) < 0.00001 },
        "靠墙提示要一眼可辨（全对比），不许被压成外圈那层淡色")
  // 颜色语义：黄（当前落点·可放）/ 红（当前落点·放不下）/ 蓝（能靠墙）三色不许合并，
  // 而且**当前落点**那两色在这个窗口里仍然全对比 —— 一眼可辨是这条判据的全部意义。
  let footprintRed=PropSupportGridPresentation.focusedInstances(
      cells:lawn,states:[anchorCell:.invalidFootprint,gridCell(0,2,0,0):.wallPlaceable],
      cameraPosition:origin,spacing:0.25,options:grid)
  check(footprintRed.contains { $0.state == .invalidFootprint && abs($0.alpha-1) < 0.00001 },
        "当前落点·放不下必须仍然一眼可辨（红、全对比）")
  let legendTints=[PropSupportGridPresentation.CellState.placeable.tint,
             PropSupportGridPresentation.CellState.validFootprint.tint,
             PropSupportGridPresentation.CellState.invalidFootprint.tint,
             PropSupportGridPresentation.CellState.wallPlaceable.tint,
             PropSupportGridPresentation.CellState.hoverTarget.tint]
  check(Set(legendTints.map { [$0.x,$0.y,$0.z,$0.w] }).count==legendTints.count,
        "黄（当前落点·可放）/ 红（放不下）/ 蓝（能靠墙）/ 绿（能放）/ 青白（能点起来）五色的语义不许被合并")
  // 面板图例列的那几种颜色也必须两两不同：图例列了两种同色 = 用户分不清"能放"和"能靠墙放"。
  let legendEntries=PropSupportGridPresentation.Legend.entries.map { [$0.tint.x,$0.tint.y,$0.tint.z,$0.tint.w] }
  check(Set(legendEntries).count==legendEntries.count,"图例里的每一种颜色必须两两不同")
  // 只有靠墙提示、**没有**当前落点时：一个格子都不画（它不构成锚点）。
  check(PropSupportGridPresentation.focusedInstances(
        cells:lawn,states:[gridCell(0,2,0,0):.wallPlaceable],cameraPosition:origin,spacing:0.25,options:grid).isEmpty,
        "没有当前落点时不许拿靠墙提示当锚点把整片地面画回来")
  check(!wallHinted.isEmpty && wallHinted.count < PropSupportGridPresentation.instances(
        cells:lawn,states:wallHints,cameraPosition:origin,spacing:0.25,options:grid).count,
        "靠墙提示必须走焦点裁剪，而不是绕过它铺满地面")
  // ── 场景内点已摆物件：射线 × yaw 包围盒（摆放校验用的同一个盒子）────────────────
  func target(_ id:String,_ x:Float,_ y:Float,_ z:Float,_ hx:Float,_ hy:Float,_ hz:Float,_ yaw:Float=0)
      -> ResidentPropHitTest.Target {
      .init(objectID:id,center:SIMD3(x,y,z),halfExtents:SIMD3(hx,hy,hz),yaw:yaw) }
  // 合成相机：位于 (0,2,0) 沿 -Y 看下去（与上面格子拾取同一个相机）。
  let down=camera
  let lamp=target("lamp",0,0.5,0,0.2,0.5,0.2)
  check(ResidentPropHitTest.hit(normalized:SIMD2(0.5,0.5),inverseViewProjection:down,targets:[lamp])=="lamp",
        "a ray through a placed prop hits it")
  check(ResidentPropHitTest.hit(normalized:SIMD2(1.4,0.5),inverseViewProjection:down,targets:[lamp])==nil,
        "a ray outside the prop's box does not hit it")
  check(ResidentPropHitTest.hit(normalized:SIMD2(1.5,0.5),inverseViewProjection:down,targets:[lamp])==nil,
        "a cursor outside the viewport hits nothing")
  check(ResidentPropHitTest.hit(normalized:SIMD2(0.5,0.5),inverseViewProjection:down,targets:[])==nil,
        "no placed props means no hit")
  check(ResidentPropHitTest.hit(normalized:SIMD2(0.5,0.5),inverseViewProjection:down,targets:[lamp],maximumDistance:0.5)==nil,
        "a hit beyond maximumDistance is rejected")
  // 前后重叠时取**最近**的那一件（否则点前面那件会拿起身后那件）。
  let closer=target("closer",0,1.2,0,0.2,0.2,0.2), farther=target("farther",0,0.4,0,0.2,0.2,0.2)
  check(ResidentPropHitTest.hit(normalized:SIMD2(0.5,0.5),inverseViewProjection:down,targets:[farther,closer])=="closer",
        "the nearest prop wins, independent of order")
  check(ResidentPropHitTest.hit(normalized:SIMD2(0.5,0.5),inverseViewProjection:down,targets:[closer,farther])=="closer",
        "the nearest prop wins, independent of order")
  // yaw **必须**参与判定：同一支射线在转 90° 之后才落进这块薄板里。
  let thin=target("thin",0,0,0,0.5,0.5,0.2,.pi/2)
  let unrotated=target("thin",0,0,0,0.5,0.5,0.2,0)
  // 命中点 (0.15, ·, 0.5)：转 90° 后在板内（局部 x = −0.5 ≤ 0.5、局部 z = 0.15 ≤ 0.2），
  // 不转则在板外（世界 z = 0.5 > 0.2）。
  let spot=SIMD3<Float>(0.15,0,0.5)
  check(ResidentPropHitTest.distance(rayOrigin:spot+SIMD3(0,2,0),rayDirection:SIMD3(0,-1,0),target:thin) != nil,
        "yaw rotates the hit box (a ray into the rotated sliver is a hit)")
  check(ResidentPropHitTest.distance(rayOrigin:spot+SIMD3(0,2,0),rayDirection:SIMD3(0,-1,0),target:unrotated) == nil,
        "the same ray misses the unrotated box (yaw is really applied)")
  // 射线起点在盒内 → 距离 0（不是"背面的 tExit"）。
  check(ResidentPropHitTest.distance(rayOrigin:SIMD3(0,0,0),rayDirection:SIMD3(0,-1,0),target:unrotated)==0,
        "a ray starting inside the box reports zero distance")
  // 反方向、退化输入都不算命中（fail-closed，不猜）。
  check(ResidentPropHitTest.distance(rayOrigin:SIMD3(0,3,0),rayDirection:SIMD3(0,1,0),target:unrotated)==nil,
        "a prop behind the camera is not hit")
  check(ResidentPropHitTest.distance(rayOrigin:SIMD3(0,3,0),rayDirection:SIMD3(0,-1,0),
        target:target("degenerate",0,0,0,0,0.5,0.2))==nil,"a degenerate box is never hit")
  check(ResidentPropHitTest.distance(rayOrigin:SIMD3(0,3,0),rayDirection:SIMD3(0,-1,0),
        target:target("badYaw",0,0,0,0.5,0.5,0.2,.nan))==nil,"a non-finite yaw is never hit")
  check(ResidentPropHitTest.hit(normalized:SIMD2(0.5,1.5),inverseViewProjection:down,targets:[lamp])==nil,
        "a cursor below the viewport hits nothing")
  // ── 图例（面板里那一行小方块）：只有链路真的会赋给格子的颜色 ──────────────────
  //
  // 2026-10-02 加入第四种：`.wallPlaceable`（蓝）—— 靠墙可放。它**有赋值点**
  // （`ResidentPropGridEditorModel.refreshWallPlaceability` 只在派生出竖直面时才会写），
  // 与 `.blocked`/`.occupied` 那种"链路里根本没有赋值点"的 case 不同。
  // 面板那一行只在**真的派生出竖直面**时才显示它（见 `ResidentPropEditorView`），
  // 所以平房间里不会多出一个看不懂的蓝色小方块。
  let legend=PropSupportGridPresentation.Legend.entries
  check(legend.map(\.state)==[.placeable,.wallPlaceable,.validFootprint,.invalidFootprint],
        "the legend lists exactly the states the live link paints: green (other cells), blue (wall-placeable), yellow (this drop spot, placeable), red (this drop spot, blocked)")
  check(!legend.contains { $0.state == .blocked || $0.state == .occupied },
        "the legend must not advertise colours the live link never assigns to a cell")
  check(legend.allSatisfy { !$0.label.isEmpty && $0.label.count <= 8 },
        "legend labels stay short — a legend is not a manual")
  /// 某个三元组是否**连续**出现在这份源码的数字字面量里。逐字复制一份 RGB 一定会命中。
  func paints(_ numbers:[String],_ rgb:[String])->Bool {
      guard numbers.count>=rgb.count else { return false }
      for start in 0...(numbers.count-rgb.count) where Array(numbers[start..<(start+rgb.count)])==rgb { return true }
      return false
  }
  for entry in legend {
      // 图例的颜色必须**就是**格子实例上那个状态的 tint（逐分量相等），
      // 并且那份 tint 只允许在定义它的那一个文件里以字面量出现 —— 各写一份 RGB 会在这里裂开。
      let cell=gridCell(0,0,0,0)
      let drawn=PropSupportGridPresentation.instances(cells:[cell],states:[cell:entry.state],
          cameraPosition:origin,spacing:0.25,options:grid)
      check(drawn.count==1 && drawn[0].state==entry.state,"precondition: the state is drawn")
      check(entry.tint==drawn[0].state.tint,
            "the legend colour must be the very same tint the cell is drawn with (\(entry.label))")
      let linear=[entry.tint.x,entry.tint.y,entry.tint.z].map { String(format:"%.2f",$0) }
      let paintedIn=appSourceNumbers.filter { paints($0.numbers,linear) }.map(\.file)
      check(paintedIn==["Presence/PropSupportGridPresentation.swift"],
            "the grid tint \(linear) must live in exactly one place, not be copied into the legend (found in \(paintedIn))")
      // 手抄一份"算好的 sRGB"同样不行：面板只能走 tint 的派生值。
      let srgb=[entry.srgbTint.x,entry.srgbTint.y,entry.srgbTint.z].map { String(format:"%.2f",$0) }
      check(!appSourceNumbers.contains { paints($0.numbers,srgb) },
            "the legend swatch must be derived from the grid tint, not hand-written as sRGB \(srgb)")
      check(entry.srgbTint != SIMD3(entry.tint.x,entry.tint.y,entry.tint.z),
            "the panel swatch is the sRGB rendering of the very same tint, not the raw linear value (the grid is drawn into a .bgra8Unorm_srgb attachment)")
  }
  // ── 光标旁那枚「这里为什么不能放」：什么时候画、画在哪 ─────────────────────────
  check(ResidentPropBlockReasonLabel.content(isCarrying:true,reason:nil)==nil,
        "a placeable spot has no reason, so no label is drawn at all")
  check(ResidentPropBlockReasonLabel.content(isCarrying:false,reason:"这里会插进墙或家具。")==nil,
        "with nothing in hand there is no label, reason or not")
  check(ResidentPropBlockReasonLabel.content(isCarrying:true,reason:"  \n ")==nil,
        "a blank reason draws nothing instead of an empty bubble")
  let reasonSample="这里会和已经放好的 落地灯 重叠。"
  check(ResidentPropBlockReasonLabel.content(isCarrying:true,reason:reasonSample)==reasonSample,
        "the label text is the reason exactly as the existing projection gives it — not re-worded, not truncated")
  // 位置：锚点（圆环圆心）正上方、不压圆环、不出视图。
  let anchor=CGPoint(x:400,y:300)
  let viewSize=CGSize(width:900,height:600)
  let textSize=CGSize(width:150,height:14)
  let box=ResidentPropBlockReasonLabel.frame(anchor:anchor,ringRadius:26,textSize:textSize,viewSize:viewSize)
  check(abs(box.midX-anchor.x)<0.001,"the label is centred on the handle anchor")
  check(box.minY>=anchor.y+26,
        "the label sits above the ring (anchor + radius), so neither the ring nor the drop spot is covered")
  check(box.width==textSize.width+16 && box.height==textSize.height+8,
        "the capsule is the text plus its padding")
  check(box.minX>=0 && box.minY>=0 && box.maxX<=viewSize.width && box.maxY<=viewSize.height,
        "the label stays inside the view")
  let leftEdge=ResidentPropBlockReasonLabel.frame(anchor:CGPoint(x:4,y:300),ringRadius:26,textSize:textSize,viewSize:viewSize)
  let rightEdge=ResidentPropBlockReasonLabel.frame(anchor:CGPoint(x:896,y:300),ringRadius:26,textSize:textSize,viewSize:viewSize)
  let topEdge=ResidentPropBlockReasonLabel.frame(anchor:CGPoint(x:400,y:595),ringRadius:26,textSize:textSize,viewSize:viewSize)
  check(leftEdge.minX>=0 && rightEdge.maxX<=viewSize.width,"a label near a side edge is clamped into the view")
  check(topEdge.maxY<=viewSize.height,"a label near the top edge is clamped into the view")
  check(ResidentPropBlockReasonLabel.frame(anchor:anchor,ringRadius:40,textSize:textSize,viewSize:viewSize).minY
        > ResidentPropBlockReasonLabel.frame(anchor:anchor,ringRadius:26,textSize:textSize,viewSize:viewSize).minY,
        "the label gives way to the ring: a bigger radius pushes it further up")
  print("PASS: prop scale/yaw, unique preview/cancel, shared identity, world isolation, support ray, multi-layer grid picking, grid presentation, the focus patch that replaces the floor-wide carpet, the wall-hint table that must NOT become a focus anchor (real machine: 194 patches / 3160 columns — restoring the old anchor draws 1804 cells instead of 25), the hover glow patch, the placed-prop hit test, the multi-colour legend that takes its colours from the grid tint itself, and the cursor-side block-reason label (drawn only when carrying with a reason, anchored above the ring)")
 }
}
"""#
let temp=FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-prop-render-\(UUID())")
try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
defer {try? FileManager.default.removeItem(at:temp)}
let file=temp.appendingPathComponent("main.swift"),exe=temp.appendingPathComponent("check")
try harness.write(to:file,atomically:true,encoding:.utf8)
func run(_ path:String,_ args:[String]) throws->Int32 {let p=Process();p.executableURL=URL(fileURLWithPath:path);p.arguments=args;try p.run();p.waitUntilExit();return p.terminationStatus}
// 生产描述符现在 `import WorldRuntime`（摆放矩阵要读资产级摆正旋转 `WorldPropOrientation`），
// 所以这一档编译也要带上模块搜索路径与对象文件 —— 与下面第二档同一条口径。
// WorldRuntime 的模块搜索路径 + 目标文件**只有一处定义**：tools/world-runtime-harness-flags.sh。
// 不要在这里拼 `.build/...`：27 份各自拼写正是 SwiftPM 与 xcodebuild 两份模块并存的根因。
// `worldBuild` 由那唯一一份定义**推出来**（= Modules 的上一级），本文件不持有路径字面量。
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
let worldBuild = URL(fileURLWithPath: worldRuntimeFlags[1]).deletingLastPathComponent().path
let worldObjects = (try? FileManager.default.contentsOfDirectory(atPath: worldBuild + "/WorldRuntime.build"))?
    .filter { $0.hasSuffix(".swift.o") }.sorted().map { worldBuild + "/WorldRuntime.build/" + $0 } ?? []
guard !worldObjects.isEmpty else {
    print("FAIL: WorldRuntime 还没编译过（先 `swift build --package-path apps/macos/Packages/WorldRuntime`）")
    exit(1)
}
let result=try run("/usr/bin/nice",["-n","15","/usr/bin/swiftc","-j1","-parse-as-library","-I",worldBuild + "/Modules",descriptor,sizeIntentShim.path,picker,presentation,hitTest,blockLabel,file.path,"-o",exe.path] + worldObjects)
guard result==0 else {exit(result)}
let checks=try run(exe.path,[])
guard checks==0 else {exit(checks)}

// ── 在手预览（2026-09-29 真机缺陷的行为断言）────────────────────────────────────
//
// 「带着一件**已摆出的**物件移动光标时，渲染端拿到的选择必须是**同一件物件、在光标那一格**，
// 而不是它原来站着的位置；而且同一个 objectID 只出现一次（不能画两份）。」
//
// 为什么这一步要单独再编一次：这条链的**上游**是编辑器状态机（`ResidentPropEditorState`），
// 它依赖 `WorldRuntime`（`WorldObjectState` / `WorldPropPlacement`），而上面那段 harness
// 刻意只编 Foundation + simd 的纯文件。所以这里把编辑器与**真实的** `resolve` 一起编进来，
// 走完整条真机链路：
//   摆放服务拒绝这次落点（真机是 `blockedRoute`，实测该次会话 273/273 个"格子说可放"的
//   落点全被拒）→ `ResidentPropEditorState.validate` → `onPreviewChanged` →
//   `GMGNRadioApp.residentPropDescriptor` 那条**唯一**的换算 → `ResidentPropRenderSelection.resolve`。
//
// 缺陷版本下 `onPreviewChanged` 只收到 nil（编辑器把预览整个丢掉了），于是 resolve 继续给出
// **原地那一件** —— 用户看到的就是"物件站在原地不动、只有落点格子跟着鼠标跑"。
// 挂点：`ResidentPropEditorState`（与摆放服务的签名）读 `PropAttachmentPoint` /
// `PropAttachmentSlots`，它们的定义在 `PropAttachment.swift` / `PropAttachmentSlot.swift` 里，
// 而这两份都依赖 app 目标的渲染侧类型（`StageAvatarAsset` 等），离线 harness 编不动。
// 于是**逐字**抽出需要的那几段声明（不是在这儿抄一份映射；生产改了这里跟着变）。
let propAttachmentSource = try String(contentsOfFile: "apps/macos/Sources/GMGNRadio/Presence/PropAttachment.swift", encoding: .utf8)
let propAttachmentSlotSource = try String(contentsOfFile: "apps/macos/Sources/GMGNRadio/Presence/PropAttachmentSlot.swift", encoding: .utf8)
func attachmentDeclaration(_ signature: String, in source: String) -> String {
    guard let start = source.range(of: signature)?.lowerBound,
          let open = source[start...].firstIndex(of: "{") else {
        print("FAIL: 生产源码里找不到 \(signature)"); exit(1)
    }
    var depth = 0
    for index in source[open...].indices {
        if source[index] == "{" { depth += 1 }
        if source[index] == "}" { depth -= 1 }
        if depth == 0 { return String(source[start...index]) }
    }
    print("FAIL: \(signature) 的花括号不平衡"); exit(1)
}
let propAttachmentShim = """
\(attachmentDeclaration("enum PropAttachmentPoint:", in: propAttachmentSource))
\(attachmentDeclaration("extension PropAttachmentPoint {", in: propAttachmentSlotSource))
\(attachmentDeclaration("extension WorldPropSlot {", in: propAttachmentSlotSource))
\(attachmentDeclaration("enum PropAttachmentSlots {", in: propAttachmentSlotSource))
"""
let editorState = "apps/macos/Sources/GMGNRadio/Presence/ResidentPropEditorState.swift"
guard !worldObjects.isEmpty else {
    print("FAIL: the in-hand preview probe needs the WorldRuntime build artefacts (run `swift build --package-path apps/macos/Packages/WorldRuntime` first)")
    exit(1)
}
let onHandHarness = #"""
import Foundation
import WorldRuntime
import simd
\#(propAttachmentShim)
func check(_ value: Bool, _ message: String) { if !value { print("FAIL:", message); exit(1) } }
/// 摆放服务在真机上给出的那一条拒绝（`ResidentPropPlacementError.blockedRoute`）的等价物：
/// 这条断言只关心"服务拒绝了这次落点"，所以这里自己抛一个同形状的错误，不引入服务文件。
struct PreviewRejected: LocalizedError {
    var errorDescription: String? { "这里会挡住活动入口或通道：wp.auto.x0.z-2.h0" }
}
@main struct OnHandPreview {
 @MainActor static func main() async throws {
  let modelURL = URL(fileURLWithPath: "/tmp/fixture.glb")
  // 存档里的那一件：完好、已摆出、在台面上（真机 2026-09-29 咖啡机）。
  let prop = WorldGeneratedProp(objectID: "wish-prop-coffee", sourceWishID: "wish",
      assetID: "sha256:coffee", displayName: "咖啡机",
      size: .init(x: 0.29150167, y: 0.35, z: 0.4719286), sourceHeight: 0.7465656)
  let metadata = ["gmgn.generated-prop.v1": String(data: try JSONEncoder().encode(prop), encoding: .utf8)!]
  let scale = prop.size.y / prop.sourceHeight
  let placed = WorldObjectState(isEnabled: true,
      transform: .init(position: .init(x: -2.875, y: 0.52, z: -4.875),
                       rotation: .init(x: 0, y: 0, z: 0, w: 1),
                       scale: .init(x: scale, y: scale, z: scale)),
      metadata: metadata)
  let snapshot = ResidentPropEditorSnapshot(worldID: "w", revision: 9, objects: [placed],
      surfaces: [ResidentPropEditorSurface(id: "layer.0", name: "地面",
                                           position: .init(x: 0, y: -0.041, z: 0))], canUndo: false)
  let editor = ResidentPropEditorState()
  var previews: [WorldObjectState?] = []
  editor.onPreviewChanged = { previews.append($0) }
  // 真机上那一条：落点被判不能放（挡住居民路点/通道），服务抛错。
  editor.preview = { _, _ in throw PreviewRejected() }
  editor.update(snapshot)
  editor.open()
  await editor.select(objectID: prop.objectID)
  check(editor.isCarrying, "picking up an already placed prop must enter the carrying state")
  let cell = WorldVector3(x: -1.375, y: -0.041, z: -6.625)
  await editor.moveGridPointer(to: cell, layerName: "layer.0", yaw: 0.5)
  // 编辑器推给宿主的那一份：**显示**事实（手上拿着什么、现在在哪），不是落点判定。
  guard let last = previews.last, let onHand = last else {
      check(false, "cursor moved while carrying an already placed prop, but the editor pushed nil — the in-hand preview is thrown away and the renderer keeps drawing the prop parked at its placed position")
      return
  }
  check(onHand.generatedProp == placed.generatedProp,
      "the in-hand preview must carry the placed prop's own generatedProp identity, or the host's asset-ownership guard rejects it and nothing is drawn")
  // 与 `GMGNRadioApp.residentPropDescriptor` 一模一样的换算（这里编译的就是那一份）。
  func descriptor(_ state: WorldObjectState) -> ResidentPropRenderDescriptor {
      let p = state.transform.position, q = state.transform.rotation
      return .residentProp(objectID: prop.objectID, worldID: "w", assetID: prop.assetID, modelURL: modelURL,
                           targetHeightMeters: prop.size.y, position: SIMD3(p.x, p.y, p.z),
                           rotation: SIMD4(q.x, q.y, q.z, q.w))
  }
  let placedDescriptor = descriptor(placed)
  let onHandDescriptor = descriptor(onHand)
  check(placedDescriptor.position.x == -2.875 && placedDescriptor.position.z == -4.875,
        "the placed copy still sits where it was placed")
  let selection = ResidentPropRenderSelection.resolve([placedDescriptor], preview: onHandDescriptor, worldID: "w")
  check(selection.count == 1, "the in-hand preview must replace the placed copy, never draw two props with one id")
  check(selection.allSatisfy { $0.objectID == prop.objectID }, "only the carried prop id may be selected")
  check(abs(selection[0].position.x - cell.x) < 0.0001 && abs(selection[0].position.y - cell.y) < 0.0001
        && abs(selection[0].position.z - cell.z) < 0.0001,
        "the render selection must be the carried prop at the cursor cell, not the copy parked at its placed position")
  check(abs(selection[0].yaw - 0.5) < 0.0001, "the render selection must carry the preview yaw")
  check(abs(selection[0].position.x - placedDescriptor.position.x) > 1,
        "the stale placed transform must be gone from the selection")
  print("PASS: the in-hand preview of an already placed prop follows the cursor cell (one id, one copy) even when the placement service rejects the drop point")
 }
}
"""#
let onHandFile=temp.appendingPathComponent("onhand.swift"),onHandExe=temp.appendingPathComponent("onhand")
try onHandHarness.write(to:onHandFile,atomically:true,encoding:.utf8)
let onHandCompile=try run("/usr/bin/nice",["-n","15","/usr/bin/swiftc","-j1","-parse-as-library","-swift-version","6",
    // 握点推断只依赖 WorldRuntime + simd，能独立编 ⇒ 编**同一份**生产文件（抽取只用于
    // 编不动的那两份：`PropAttachment*.swift`）。
    "-I",worldBuild + "/Modules",descriptor,sizeIntentShim.path,
    "apps/macos/Sources/GMGNRadio/Presence/PropGripInference.swift",editorState,onHandFile.path,
    // 「我的物件」的唯一投影：`ResidentPropEditorState` 现在从它现算行（`ownershipFacts` →
    // `ResidentOwnershipProjection.row`），所以编面板状态就必须一起编它（编同一份，不抄）。
    "apps/macos/Sources/GMGNRadio/Presence/ResidentOwnershipProjection.swift",
    // 摆放试算上限的唯一策略定义（`RetryBackoffSite.propPlacement`）。
    "apps/macos/Sources/GMGNRadio/Presence/RetryBackoff.swift",
    "-o",onHandExe.path] + worldObjects)
guard onHandCompile==0 else {exit(onHandCompile)}
exit(try run(onHandExe.path,[]))

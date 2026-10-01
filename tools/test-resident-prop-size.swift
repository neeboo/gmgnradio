// 「生成物件的尺寸标定」真机验收（无宿主、无窗口、无 GPU）。
//
// 真机 2026-10-01 用户报两件事，它们其实是**同一个根因**的两面：
//   1. 「另外生成的物件太大了，控不了尺寸吗」——同一件「2B 白色长剑（外形摆件）」
//      横跨整个舱室；
//   2. 「大剑还是消失了啊」——它**没有进房间**（唯一的 state.json 里没有它）。
//
// 真机证据（本 harness 直接读真机文件，不抄结论）：
//   - `…/gmgn radio/TaskService/4210DB95-9253-4CAF-83A3-3C45F090B099.glb`
//     实测网格 1.005432 × 0.133493 × 0.056566 m（长 × 高 × 厚）；
//   - 同一件在 `…/TaskService/tasks.sqlite3` 的回执里 `inspection.bounds.dimensions`
//     逐位一致（`space=mesh_local`、`units=model_units`、`scale_requires_confirmation=true`）；
//   - `…/WishMachine/wishes.json` 里这次生成请求的高度是 1.1 m；
//   - 旧的"只按高度轴归一" ⇒ scale = 1.1 / 0.133493 = 8.2401 ⇒ 场景里 **8.2848 m 长**，
//     而舱室只有 7 × 8 × 3.2 m。
//
// 本 harness 钉死下面几条（每条都能在"退回旧行为"时抓住缺陷）：
//   A1 回执的 bounds 与 GLB 实际一致（不是"bounds 校验被放过"）；
//   A2 旧标定下这把剑在**真实承托网格**上可放格数 = 0（所以"消失"= 没进房间）；
//   A3 新策略下它自动缩到最长边 = 请求高度（横纵比不失真），且**渲染矩阵**给出的实际尺寸
//      逐位等于登记的 `size`（画面 = 碰撞盒 = 存档同一份）；
//   A4 既有物件（真机存档里的斧头 / 咖啡机）尺寸**一个数字都不变**（不回归）；
//   A5 手动覆盖优先：改尺寸后 `size` / 碰撞盒 / 红绿格 footprint / 存档四处一致；
//   A6 夹取生效：过小、过大、非等比都被**拒绝**并给读得出原因；
//   A7 新尺寸下同一件物件在真实网格上**可放格数 > 0**（能真的摆进屋）；
//   A8 「已入库但没摆出来」在列表里写着「尚未摆放」（不许看起来像"消失"）。
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceRoot = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
let bootstrap = try String(contentsOf: sourceRoot.appendingPathComponent("App/LivingWorldBootstrap.swift"), encoding: .utf8)
let collisionStart = bootstrap.range(of: "struct MarbleLivingCabinCollisionWorld:")!.lowerBound
let collisionEnd = bootstrap.range(of: "/// An effect is keyed", range: collisionStart..<bootstrap.endIndex)!.lowerBound
let outputDescriptorSource = try String(contentsOf: sourceRoot.appendingPathComponent("Presence/WishMachineOutputDescriptor.swift"), encoding: .utf8)
guard outputDescriptorSource.contains("enum WishMachineOutputPlacement") else {
    print("FAIL: the one placement-matrix conversion is missing"); exit(1)
}
// 描述符带着**尺寸意图**（`size_intent`）：这份 harness 只 inline 描述符，不整份编
// `PropGenerationClient.swift`（那份依赖 WorldRuntime，会把碰撞代理一起拖进来），
// 所以按括号配平把 `PropSizeIntent` 这一段声明**从生产源码里原样抽出来**前置 ——
// 编的是同一份源码，不是在这儿抄一份类型定义。抽不到就 FAIL，不允许静默跳过。
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
let propGenerationClientSource = try String(contentsOf: sourceRoot.appendingPathComponent("Presence/PropGenerationClient.swift"), encoding: .utf8)
guard let sizeIntentDeclaration = declaration(in: propGenerationClientSource, "struct PropSizeIntent: Codable") else {
    print("FAIL: 生产源码里找不到 PropSizeIntent 的声明（尺寸意图契约不能只存在于别处）"); exit(1)
}
let editorStateSource = try String(contentsOf: sourceRoot.appendingPathComponent("Presence/ResidentPropEditorState.swift"), encoding: .utf8)
guard editorStateSource.contains("static func rowStatus(isHeld: Bool, isPlaced: Bool)") else {
    print("FAIL: the prop list has no single source for \"尚未摆放\" / \"已摆出\" / \"手持中\""); exit(1)
}
// ── 接线：策略必须真的挂在"请求高度"进系统的两处，而不是只存在于库里 ──────────
// 1) 生成入库（`heightMeters` 是请求高度）；2) 许愿机托盘那一件（还没登记）。
// 文件不在工作区（例如另一条线正在拆分/搬迁）时只**跳过并说出来**，不当成通过；
// 文件在、接线被拆掉时必须 FAIL。
func wiring(_ relative: String, _ required: [String], _ message: String) throws -> Bool {
    let url = sourceRoot.appendingPathComponent(relative)
    guard let source = try? String(contentsOf: url, encoding: .utf8) else {
        print("SKIP: \(relative) 不在工作区（app 目标无法构建），跳过这条接线断言")
        return false
    }
    guard required.allSatisfy(source.contains) else { print("FAIL: \(message)"); exit(1) }
    return true
}
_ = try wiring("App/GMGNRadioApp.swift",
    ["WorldPropSizePolicy.automatic(", "size: autoSize.size,"],
    "生成入库那一步没有把「请求高度」落成世界尺寸（那把剑会照旧被算成 8.2848 m）")
_ = try wiring("Presence/WishMachineCoordinator.swift",
    ["heightIsGenerationRequest: true"],
    "许愿机托盘上的产物没有被标成「请求高度」（托盘会照旧按高度轴归一成 8.2848 m）")
_ = try wiring("Presence/WishMachineOutputRenderer.swift",
    ["WorldPropSizePolicy.automatic("],
    "托盘渲染没有过尺寸策略")
let editorViewSource = try String(contentsOf: sourceRoot.appendingPathComponent("VisualEngine/ResidentPropEditorView.swift"), encoding: .utf8)
guard editorViewSource.contains("state.resize(toLongestEdge:"),
      editorViewSource.contains("ResidentPropEditorState.rowStatus(") else {
    print("FAIL: the decoration panel must offer a size control (slider / fine steps) and read the row status from that single source")
    exit(1)
}
// 挂点（slot）：编辑器状态里那两行（"面板选中的挂点" / "已挂载就读世界状态"）读
// `PropAttachmentPoint` 与 `WorldPropSlot.attachmentPoint`。它们的真定义在依赖渲染侧类型的
// `PropAttachment.swift` / `PropAttachmentSlot.swift` 里 ⇒ 按本 harness 一贯的手法**逐字**
// 切出来注入程序（不是在这儿抄一份映射）。
let propAttachmentSource = try String(
    contentsOf: sourceRoot.appendingPathComponent("Presence/PropAttachment.swift"), encoding: .utf8)
let propAttachmentSlotSource = try String(
    contentsOf: sourceRoot.appendingPathComponent("Presence/PropAttachmentSlot.swift"), encoding: .utf8)
guard let propAttachmentPointDeclaration = declaration(in: propAttachmentSource, "enum PropAttachmentPoint:"),
      let propAttachmentWorldSlotExtension = declaration(in: propAttachmentSlotSource, "extension PropAttachmentPoint {"),
      let worldSlotAttachmentPointExtension = declaration(in: propAttachmentSlotSource, "extension WorldPropSlot {") else {
    print("FAIL: 切不出挂点的类型声明（`enum PropAttachmentPoint:` / 两条映射的签名改了？）"); exit(1)
}
let propAttachmentShim = [propAttachmentPointDeclaration, propAttachmentWorldSlotExtension, worldSlotAttachmentPointExtension]
    .joined(separator: "\n")

let harness = #"""
import Foundation
import WorldRuntime
import simd

\#(bootstrap[collisionStart..<collisionEnd])

\#(sizeIntentDeclaration)

\#(outputDescriptorSource)

\#(editorStateSource)

\#(propAttachmentShim)

/// 真机那把剑的 GLB（尺寸标定的现场）。
let swordModelPath = NSHomeDirectory() + "/Library/Application Support/gmgn radio/TaskService/4210DB95-9253-4CAF-83A3-3C45F090B099.glb"
/// 真机 `tasks.sqlite3` 里这次生成回执的 `inspection.bounds.dimensions`
///（`space=mesh_local`、`units=model_units`、`suggested_height_meters=1.1`、
/// `scale_requires_confirmation=true`）。
let recordedSwordDimensions: [Float] = [1.005432426929474, 0.1334928721189499, 0.05656638368964195]

func measure(_ url: URL) -> (minimum: SIMD3<Float>, maximum: SIMD3<Float>)? {
    guard let data = try? Data(contentsOf: url),
          let triangles = try? GLBColliderDecoder().decode(
            data: data, transform: WorldMeshTransform(axisConversion: .identity)) else { return nil }
    guard !triangles.isEmpty else { return nil }
    var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
    var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
    for triangle in triangles {
        for vertex in [triangle.first, triangle.second, triangle.third] {
            minimum = SIMD3(min(minimum.x, vertex.x), min(minimum.y, vertex.y), min(minimum.z, vertex.z))
            maximum = SIMD3(max(maximum.x, vertex.x), max(maximum.y, vertex.y), max(maximum.z, vertex.z))
        }
    }
    return (minimum, maximum)
}

@main struct PropSize {
 @MainActor static func main() async throws {
  var checks = 0
  func check(_ ok: Bool, _ message: String) {
    checks += 1
    guard ok else { print("FAIL: \(message)"); exit(1) }
  }
  func f(_ value: Float) -> String { String(format: "%.4f", value) }
  func v(_ size: WorldVector3) -> String { "(\(f(size.x)), \(f(size.y)), \(f(size.z)))" }

  // ---- 真机数据：存档 + 三件物件的真实网格 + 那次生成请求的高度 ----
  let saveURL = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent("Library/Application Support/ai.gmgn.radio/LivingWorld/marble-living-cabin/1.2.0/state.json")
  let saved = try JSONDecoder().decode(WorldState.self, from: Data(contentsOf: saveURL))
  let taskService = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/gmgn radio/TaskService")
  let swordURL = URL(fileURLWithPath: swordModelPath)
  guard let sword = measure(swordURL) else {
      print("FAIL: 真机那把剑的 GLB 读不出来（\(swordModelPath)）"); exit(1)
  }
  let swordExtent = sword.maximum - sword.minimum
  // 请求高度取自真机 `wishes.json`（不抄结论）。
  let wishesURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/gmgn radio/WishMachine/wishes.json")
  let wishes = try JSONSerialization.jsonObject(with: Data(contentsOf: wishesURL)) as? [String: Any] ?? [:]
  let jobs = wishes["jobs"] as? [[String: Any]] ?? []
  guard let swordJob = jobs.first(where: { ($0["id"] as? String) == "4210DB95-9253-4CAF-83A3-3C45F090B099" }),
        let requestedHeight = (swordJob["heightMeters"] as? NSNumber)?.floatValue else {
      print("FAIL: 真机 wishes.json 里找不到那把剑的生成请求"); exit(1)
  }
  print("真机数据：长剑网格实测 \(v(WorldVector3(x: swordExtent.x, y: swordExtent.y, z: swordExtent.z))) m，生成请求高度 \(f(requestedHeight)) m")

  // ---- A1：回执的 bounds 与 GLB 实际逐位一致 ----
  for (index, axis) in [swordExtent.x, swordExtent.y, swordExtent.z].enumerated() {
    check(abs(axis - recordedSwordDimensions[index]) <= 1e-6,
          "回执 inspection.bounds 与实际网格不符（第 \(index) 轴 实测 \(f(axis)) vs 回执 \(f(recordedSwordDimensions[index]))）")
  }
  print("PASS[1]: 回执 bounds 与 GLB 实际一致（\(f(swordExtent.x)) / \(f(swordExtent.y)) / \(f(swordExtent.z))，容差 1e-6）—— 根因不是 bounds 校验被放过")

  // ---- A2：旧标定（只按高度轴归一）下这把剑有多长 ----
  let legacyScale = requestedHeight / swordExtent.y
  let legacySize = WorldVector3(x: swordExtent.x * legacyScale, y: requestedHeight, z: swordExtent.z * legacyScale)
  let legacyLongest = WorldPropSizePolicy.longestEdge(of: legacySize)
  check(abs(legacyScale - 8.2401) < 0.001, "旧标定的 scale 必须是 8.2401（实测 \(f(legacyScale))）")
  check(abs(legacyLongest - 8.2848) < 0.001, "旧标定必须复现真机上那把 8.2848 m 长的剑（实测 \(f(legacyLongest))）")
  check(legacyLongest > 8, "旧标定的剑比舱室进深 8 m 还长（实测 \(f(legacyLongest)) m）")
  print("PASS[2]: 旧标定的真实数字 —— scale=\(f(legacyScale))，场景里 \(v(legacySize)) m（最长边 \(f(legacyLongest)) m > 房间 8 m）")

  // ---- A3：新策略：细长物件按最长边归一，画面 = 碰撞盒 = 存档同一份 ----
  guard let auto = WorldPropSizePolicy.automatic(
    sourceExtent: WorldVector3(x: swordExtent.x, y: swordExtent.y, z: swordExtent.z),
    requestedHeight: requestedHeight) else { print("FAIL: 新策略给不出这把剑的尺寸"); exit(1) }
  check(auto.basis == .longestEdge, "细长物件（最长边/高度 = \(f(auto.aspectRatio))）必须按最长边归一（实测 \(auto.basis)）")
  check(abs(auto.longestEdge - requestedHeight) <= 1e-5,
        "新标定后最长边必须等于请求高度 \(f(requestedHeight))（实测 \(f(auto.longestEdge))）")
  check(abs(auto.size.y / auto.size.x - swordExtent.y / swordExtent.x) <= 1e-5,
        "横纵比必须**不失真**（原始 \(f(swordExtent.y / swordExtent.x)) vs 现在 \(f(auto.size.y / auto.size.x))）")
  // 渲染矩阵（真机那一份唯一的换算）给出的实际尺寸必须逐位等于登记的 size。
  let outlet = SIMD3<Float>(0, 0, 0)
  let matrix = try WishMachineOutputPlacement.transform(minimum: sword.minimum, maximum: sword.maximum,
    targetHeight: auto.size.y, outlet: outlet)
  var renderedMinimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
  var renderedMaximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
  for xi in 0...1 { for yi in 0...1 { for zi in 0...1 {
    let corner = SIMD4<Float>(xi == 0 ? sword.minimum.x : sword.maximum.x,
                              yi == 0 ? sword.minimum.y : sword.maximum.y,
                              zi == 0 ? sword.minimum.z : sword.maximum.z, 1)
    let world = matrix * corner
    renderedMinimum = SIMD3(min(renderedMinimum.x, world.x), min(renderedMinimum.y, world.y), min(renderedMinimum.z, world.z))
    renderedMaximum = SIMD3(max(renderedMaximum.x, world.x), max(renderedMaximum.y, world.y), max(renderedMaximum.z, world.z))
  }}}
  let rendered = renderedMaximum - renderedMinimum
  for (name, pair) in [("x", (rendered.x, auto.size.x)), ("y", (rendered.y, auto.size.y)), ("z", (rendered.z, auto.size.z))] {
    check(abs(pair.0 - pair.1) <= 1e-4,
          "画面里的 \(name) 必须等于登记的 size（渲染 \(f(pair.0)) vs 登记 \(f(pair.1))）")
  }
  print("PASS[3]: 新标定 —— 场景里实际 \(v(auto.size)) m（最长边 \(f(auto.longestEdge)) m = 请求高度），渲染矩阵实测 \(f(rendered.x)) × \(f(rendered.y)) × \(f(rendered.z))，与 size 逐位一致")

  // ---- A4：既有物件不回归（真机存档里两件的登记尺寸一个数字都不能变）----
  let existing: [(String, String)] = [
      ("斧头", "02BFEE6E-82AD-4680-8525-DB2D86791BF1"),
      ("E2E-0907 咖啡机", "EBFC07BE-6AF3-4E25-AF6C-9E795C6E28C6"),
  ]
  for (name, wishID) in existing {
    guard let stored = saved.objectStates.values.compactMap(\.generatedProp).first(where: { $0.sourceWishID == wishID }) else {
        print("FAIL: 真机存档里找不到 \(name)"); exit(1)
    }
    guard let mesh = measure(taskService.appendingPathComponent("\(wishID).glb")) else {
        print("FAIL: \(name) 的 GLB 读不出来"); exit(1)
    }
    let extent = mesh.maximum - mesh.minimum
    guard let resolution = WorldPropSizePolicy.automatic(
        sourceExtent: WorldVector3(x: extent.x, y: extent.y, z: extent.z),
        requestedHeight: stored.size.y) else { print("FAIL: \(name) 的新策略给不出尺寸"); exit(1) }
    check(resolution.basis == .height, "\(name) 的最长边/高度 = \(f(resolution.aspectRatio)) 不该改判（实测 \(resolution.basis)）")
    check(abs(resolution.size.x - stored.size.x) <= 1e-5
          && abs(resolution.size.y - stored.size.y) <= 1e-5
          && abs(resolution.size.z - stored.size.z) <= 1e-5,
          "\(name) 的尺寸必须与真机存档逐位相同（存档 \(v(stored.size)) vs 新策略 \(v(resolution.size))）")
    print("        不回归：\(name) 最长边/高度 = \(f(resolution.aspectRatio)) ⇒ \(v(resolution.size))，与真机存档一致")
  }
  print("PASS[4]: 既有物件量级不变（斧头 1.2649、咖啡机 1.3484 都走旧的按高度归一）")

  // ---- A5：手动覆盖优先，四处一致（尺寸 / 碰撞盒 / 红绿格 footprint / 存档）----
  var world = WorldState(revision: saved.revision, worldID: saved.worldID, worldTime: saved.worldTime,
                         lastObservedWallTime: saved.lastObservedWallTime, weather: saved.weather,
                         agentTransform: saved.agentTransform)
  let swordProp = WorldGeneratedProp(objectID: "wish-prop-4210db95-9253-4caf-83a3-3c45f090b099",
      sourceWishID: "4210DB95-9253-4CAF-83A3-3C45F090B099", assetID: "sha256:sword",
      displayName: "2B 白色长剑（外形摆件）", size: auto.size, sourceHeight: swordExtent.y)
  var simulation = WorldSimulation(restoring: world)
  try simulation.applyPropLayout(.register(swordProp), expectedLayoutRevision: 0, requestID: "test.register.sword")
  try simulation.applyPropLayout(.place(objectID: swordProp.objectID,
      placement: .init(surfaceID: "layer.0", position: .init(x: 0, y: 0, z: 0), yaw: 0.4)),
      expectedLayoutRevision: simulation.state.layoutRevision, requestID: "test.place.sword")
  world = simulation.state
  guard let placedBefore = world.objectStates[swordProp.objectID]?.generatedProp else { print("FAIL: 剑没有登记"); exit(1) }
  check(!placedBefore.isSizeLocked, "自动标定出来的物件不该被标成\"用户手动定过\"")

  // 用户把它调到最长边 1.60 m（等比）。
  let manualTarget: Float = 1.60
  let manualSize = try WorldPropSizePolicy.manualSize(current: placedBefore.size, targetLongestEdge: manualTarget)
  try simulation.applyPropLayout(.resize(objectID: swordProp.objectID, size: manualSize),
      expectedLayoutRevision: simulation.state.layoutRevision, requestID: "test.resize.sword")
  guard let resized = simulation.state.objectStates[swordProp.objectID] else { print("FAIL: 改尺寸后物件不见了"); exit(1) }
  guard let resizedProp = resized.generatedProp else { print("FAIL: 改尺寸后元数据解不出来"); exit(1) }
  check(abs(resizedProp.longestEdge - manualTarget) <= 1e-5, "手动值必须优先：最长边 \(f(manualTarget))（实测 \(f(resizedProp.longestEdge))）")
  check(resizedProp.isSizeLocked, "手动定过的尺寸必须记下来（否则自动基线会覆盖它）")
  // 碰撞盒：同一份 size。
  guard let volume = resized.generatedCollisionVolume else { print("FAIL: 改尺寸后碰撞盒解不出来"); exit(1) }
  check(abs(volume.halfExtents.x * 2 - resizedProp.effectiveSize.x) <= 1e-5
        && abs(volume.halfExtents.y * 2 - resizedProp.effectiveSize.y) <= 1e-5
        && abs(volume.halfExtents.z * 2 - resizedProp.effectiveSize.z) <= 1e-5,
        "碰撞盒必须是同一份 size（碰撞盒 \(f(volume.halfExtents.x * 2)) / \(f(volume.halfExtents.y * 2)) / \(f(volume.halfExtents.z * 2)) vs size \(v(resizedProp.size))）")
  check(abs(volume.center.y - (resized.transform.position.y + resizedProp.size.y / 2)) <= 1e-6,
        "碰撞盒底面必须仍然贴住落点（底面 \(f(volume.center.y - volume.halfExtents.y)) vs 落点 \(f(resized.transform.position.y))）")
  // 红/绿格：`ResidentPropPlacementService.validate` 用的 footprint 必须与碰撞盒同源。
  check(resizedProp.effectiveSize == resizedProp.size && resizedProp.sizeSource == .appMeasured,
        "没有工作流权威尺寸时，`effectiveSize` 必须与 `size` 逐位相同（实测 \(v(resizedProp.effectiveSize)) vs \(v(resizedProp.size))）")
  let judgeFootprint = WorldPlanarFootprint(size: SIMD2(resizedProp.effectiveSize.x, resizedProp.effectiveSize.z), yaw: 0.4)
  let boxFootprint = WorldPlanarFootprint(size: SIMD2(volume.halfExtents.x * 2, volume.halfExtents.z * 2), yaw: 0.4)
  check(judgeFootprint.size == boxFootprint.size, "红绿格的 footprint 必须与碰撞盒同源（判据 \(judgeFootprint.size) vs 碰撞盒 \(boxFootprint.size)）")
  // transform.scale 也必须由同一份 size 推出来。
  check(abs(resized.transform.scale.y - resizedProp.size.y / resizedProp.sourceHeight) <= 1e-6,
        "transform.scale 必须由同一份 size 推出（\(f(resized.transform.scale.y)) vs \(f(resizedProp.size.y / resizedProp.sourceHeight))）")
  // 存档：编码 → 解码 → 尺寸与"手动定过"都还在，而且自动基线不再覆盖它。
  let encoded = try JSONEncoder().encode(simulation.state)
  let restored = try JSONDecoder().decode(WorldState.self, from: encoded)
  guard let restoredProp = restored.objectStates[swordProp.objectID]?.generatedProp else { print("FAIL: 存档里丢了那条物件"); exit(1) }
  check(restoredProp.size == resizedProp.size && restoredProp.isSizeLocked,
        "存档必须保住这份尺寸与\"手动定过\"（\(v(restoredProp.size))，locked=\(restoredProp.isSizeLocked)）")
  guard let rebaseline = WorldPropSizePolicy.automatic(
      sourceExtent: WorldVector3(x: swordExtent.x, y: swordExtent.y, z: swordExtent.z),
      requestedHeight: requestedHeight) else { print("FAIL: 自动基线算不出来"); exit(1) }
  let autoProp = WorldGeneratedProp(objectID: swordProp.objectID, sourceWishID: swordProp.sourceWishID,
      assetID: swordProp.assetID, displayName: swordProp.displayName, size: rebaseline.size,
      sourceHeight: swordProp.sourceHeight)
  check(restoredProp.size != autoProp.size,
        "这条断言必须打在\"尺寸真的被改过\"的前提上（自动基线 \(v(autoProp.size)) vs 存档 \(v(restoredProp.size))）")
  check(restoredProp.matchesIdentity(of: autoProp),
        "手动定过尺寸的物件必须仍然被判成\"同一件\"（否则下一次资产准备会把它判成归属不一致 ⇒ 从舞台消失）")
  let untouchedAuto = WorldGeneratedProp(objectID: "other", sourceWishID: "other", assetID: "other",
      displayName: "other", size: autoProp.size, sourceHeight: autoProp.sourceHeight)
  let untouchedStored = WorldGeneratedProp(objectID: "other", sourceWishID: "other", assetID: "other",
      displayName: "other", size: WorldVector3(x: autoProp.size.x * 2, y: autoProp.size.y * 2, z: autoProp.size.z * 2),
      sourceHeight: autoProp.sourceHeight)
  check(!untouchedStored.matchesIdentity(of: untouchedAuto),
        "**没有**手动定过尺寸的物件，尺寸不同必须仍然判成不一致（fail-closed 一个字都没放宽）")
  print("PASS[5]: 手动覆盖优先且四处一致 —— size \(v(resizedProp.size))、碰撞盒 \(f(volume.halfExtents.x * 2))×\(f(volume.halfExtents.y * 2))×\(f(volume.halfExtents.z * 2))、footprint \(judgeFootprint.size)、存档 \(v(restoredProp.size)) locked=\(restoredProp.isSizeLocked)")

  // ---- A6：夹取生效（拒绝 + 可读原因）----
  func reason(_ body: () throws -> Void) -> String? {
      do { try body(); return nil } catch { return error.localizedDescription }
  }
  let tooSmall = reason { _ = try WorldPropSizePolicy.manualSize(current: resizedProp.size, targetLongestEdge: 0.005) }
  check(tooSmall?.contains("太小") == true && tooSmall?.contains("0.02") == true,
        "过小必须被拒绝并给可读原因（实测「\(tooSmall ?? "没有拒绝")」）")
  let tooBig = reason { _ = try WorldPropSizePolicy.manualSize(current: resizedProp.size, targetLongestEdge: 4) }
  check(tooBig?.contains("太大") == true && tooBig?.contains("3.00") == true,
        "过大必须被拒绝并给可读原因（实测「\(tooBig ?? "没有拒绝")」）")
  // 非等比，但**在上限之内**：这样断言打的就是"等比"这一条，而不是被上限先拦下。
  let distorted = WorldVector3(x: resizedProp.size.x * 1.2, y: resizedProp.size.y, z: resizedProp.size.z)
  let distortedReason = reason {
      var probe = WorldSimulation(restoring: simulation.state)
      try probe.applyPropLayout(.resize(objectID: swordProp.objectID, size: distorted),
          expectedLayoutRevision: probe.state.layoutRevision, requestID: "test.resize.distorted")
  }
  check(distortedReason?.contains("等比") == true,
        "非等比尺寸必须被拒绝并给可读原因（实测「\(distortedReason ?? "没有拒绝")」）")
  let tinyRequest = WorldPropSizePolicy.automatic(sourceExtent: WorldVector3(x: 40, y: 0.1, z: 0.1), requestedHeight: 0.001)
  check(tinyRequest?.basis == .clampedMinimum && tinyRequest?.reason?.contains("太小") == true,
        "自动标定的下限夹取必须给可读原因（实测 \(tinyRequest?.basis ?? .height) / 「\(tinyRequest?.reason ?? "没有原因")」）")
  let hugeRequest = WorldPropSizePolicy.automatic(sourceExtent: WorldVector3(x: 40, y: 0.1, z: 0.1), requestedHeight: 9)
  check(hugeRequest?.basis == .clampedMaximum && hugeRequest?.reason?.contains("太长") == true,
        "自动标定的上限夹取必须给可读原因（实测 \(hugeRequest?.basis ?? .height) / 「\(hugeRequest?.reason ?? "没有原因")」）")
  check(abs((hugeRequest?.size.x ?? 0) - 3) <= 1e-5, "上限夹取后最长边必须正好是 3 m（实测 \(f(hugeRequest?.size.x ?? 0))）")
  print("PASS[6]: 夹取与拒绝都有可读原因 —— 「\(tooSmall ?? "")」「\(tooBig ?? "")」「\(distortedReason ?? "")」")

  // ---- A7：真实舱体几何上的摆放判定（同一件判据：格子 + footprint）----
  let wr = URL(fileURLWithPath: "apps/macos/Resources/Worlds/marble-living-cabin")
  let manifest = try JSONDecoder().decode(WorldManifest.self, from: Data(contentsOf: wr.appendingPathComponent("world.json")))
  struct C: Decodable { struct F: Decodable { let origin: [Float]; let scale: Float }; let framing: F }
  let cfg = try JSONDecoder().decode(C.self, from: Data(contentsOf: wr.appendingPathComponent("marble.json")))
  let origin = SIMD3(cfg.framing.origin[0], cfg.framing.origin[1], cfg.framing.origin[2])
  let environment = try GLBColliderDecoder().decode(
    data: Data(contentsOf: wr.appendingPathComponent("collider.glb")),
    transform: WorldMeshTransform(axisConversion: .flipYAndZ, origin: origin, uniformScale: cfg.framing.scale))
  let mesh = TriangleMeshCollisionWorld(triangles: environment)
  check(environment.count > 100000, "真机舱体碰撞网格必须是十万级三角形（实测 \(environment.count)）")
  let parameters = PropSupportGridParameters()
  let waypoints = manifest.waypoints.filter(\.enabled).map(\.position)
  var minimumX = waypoints[0].x, maximumX = waypoints[0].x
  var minimumZ = waypoints[0].z, maximumZ = waypoints[0].z
  for p in waypoints {
      minimumX = min(minimumX, p.x); maximumX = max(maximumX, p.x)
      minimumZ = min(minimumZ, p.z); maximumZ = max(maximumZ, p.z)
  }
  let margin = parameters.spacing + parameters.capsuleRadius
  // 与 App **同一份**派生世界（家具体积的顶面也算承托面），它同时就是摆放判定的 collision。
  let derivation = PropSupportDerivationWorld(base: mesh, topVolumes: manifest.collisionVolumes.filter(\.isBlocking))
  let grid = PropSupportGridBuilder.build(collision: derivation,
    bounds: WorldPlanarBounds(minimumX: minimumX - margin, maximumX: maximumX + margin,
                              minimumZ: minimumZ - margin, maximumZ: maximumZ + margin),
    seed: manifest.spawn.position, parameters: parameters)
  check(grid.layers.count > 1000, "真机舱体必须派生出上千个承托层（实测 \(grid.layers.count)）")
  let floorHeight = grid.layers.map(\.supportHeight).min()!
  let floors = grid.layers.filter { $0.supportHeight < floorHeight + 0.3 }
  let blocking = manifest.collisionVolumes.filter(\.isBlocking)
  let placedProps = WorldLayoutObstacles.resolve(saved).volumes
  check(placedProps.count == 2, "真机存档必须有两件已摆出的物件当障碍（实测 \(placedProps.count)）")
  func placeable(_ size: WorldVector3, yaw: Float) -> (count: Int, first: String?, reason: String?) {
      var count = 0
      var first: String? = nil
      var reason: String? = nil
      for layer in floors {
          let footprint = WorldPlanarFootprint(size: SIMD2(size.x, size.z), yaw: yaw)
          let blocked = PropPlacementEvaluator.evaluate(footprint: footprint, height: size.y, at: layer,
              grid: grid, collision: derivation, blockingVolumes: blocking, placedProps: placedProps)
          if let blocked {
              if reason == nil { reason = blocked.errorDescription }
              continue
          }
          count += 1
          if first == nil { first = "cell=(\(layer.column.x),\(layer.column.z))" }
      }
      return (count, first, reason)
  }
  let legacyOnFloor = placeable(legacySize, yaw: 0.4)
  let fixedOnFloor = placeable(auto.size, yaw: 0.4)
  check(legacyOnFloor.count == 0,
        "旧尺寸（\(f(legacyLongest)) m 长）在真实地面格上必须**一格都放不下**（实测 \(legacyOnFloor.count) 格可放）")
  check(fixedOnFloor.count > 0,
        "新尺寸（最长边 \(f(auto.longestEdge)) m）必须能真的摆进屋（实测 \(fixedOnFloor.count) 格可放）")
  // 放不下必须是**可读的拒绝**，不是静默失败：判据给的原因就是面板 notice 上那一句
  //（`ResidentPropPlacementError.blockedBySupport(reason).errorDescription == reason.errorDescription`）。
  check((legacyOnFloor.reason?.isEmpty == false),
        "放不下时必须给得出可读原因，而不是静默拒绝（实测「\(legacyOnFloor.reason ?? "空")」）")
  check(fixedOnFloor.reason == nil || fixedOnFloor.count > 0,
        "新尺寸下必须真的有可放格（否则「能摆进屋」这句话不成立）")
  print("PASS[7]: 真实承托网格 \(grid.layers.count) 层 / 地面 \(floors.count) 格 —— 旧尺寸可放 \(legacyOnFloor.count) 格（原因「\(legacyOnFloor.reason ?? "-")」），新尺寸可放 \(fixedOnFloor.count) 格（例：\(fixedOnFloor.first ?? "-")）")

  // ---- A9：工作流权威尺寸存在时，手动调整**不被吞掉**（尺寸只有一个出口 `effectiveSize`）----
  let authoritative = WorldPropAuthoritativeSize(
      dimensions: WorldVector3(x: auto.size.x * 2, y: auto.size.y * 2, z: auto.size.z * 2),
      units: "m", upAxis: "+Y", forwardAxis: "-Z")
  let withAuthoritative = WorldGeneratedProp(objectID: swordProp.objectID, sourceWishID: swordProp.sourceWishID,
      assetID: swordProp.assetID, displayName: swordProp.displayName, size: auto.size,
      sourceHeight: swordProp.sourceHeight, authoritativeSize: authoritative)
  check(withAuthoritative.effectiveSize == authoritative.dimensions
        && withAuthoritative.effectiveSize != withAuthoritative.size,
        "有权威尺寸时必须以它为准（否则这条断言是空的）")
  var authoritativeSimulation = WorldSimulation(restoring: WorldState(
      revision: saved.revision, worldID: saved.worldID, worldTime: saved.worldTime,
      lastObservedWallTime: saved.lastObservedWallTime, weather: saved.weather,
      agentTransform: saved.agentTransform))
  try authoritativeSimulation.applyPropLayout(.register(withAuthoritative),
      expectedLayoutRevision: 0, requestID: "test.register.authoritative")
  try authoritativeSimulation.applyPropLayout(.place(objectID: swordProp.objectID,
      placement: .init(surfaceID: "layer.0", position: .init(x: 0, y: 0, z: 0), yaw: 0.2)),
      expectedLayoutRevision: authoritativeSimulation.state.layoutRevision, requestID: "test.place.authoritative")
  guard let authoritativeBefore = authoritativeSimulation.state.objectStates[swordProp.objectID]?.generatedProp else {
      print("FAIL: 带权威尺寸的物件没有登记"); exit(1)
  }
  check(authoritativeBefore.effectiveSize == authoritative.dimensions,
        "登记后判据看到的必须仍是权威尺寸（实测 \(v(authoritativeBefore.effectiveSize))）")
  let authoritativeTarget: Float = 1.30
  let manualFromAuthoritative = try WorldPropSizePolicy.manualSize(
      current: authoritativeBefore.effectiveSize, targetLongestEdge: authoritativeTarget)
  try authoritativeSimulation.applyPropLayout(.resize(objectID: swordProp.objectID, size: manualFromAuthoritative),
      expectedLayoutRevision: authoritativeSimulation.state.layoutRevision, requestID: "test.resize.authoritative")
  guard let authoritativeAfter = authoritativeSimulation.state.objectStates[swordProp.objectID],
        let authoritativeProp = authoritativeAfter.generatedProp else {
      print("FAIL: 带权威尺寸的物件改尺寸后不见了"); exit(1)
  }
  check(abs(WorldPropSizePolicy.longestEdge(of: authoritativeProp.effectiveSize) - authoritativeTarget) <= 1e-5,
        "有权威尺寸时手动调整必须生效，而不是被权威值吞掉（实测最长边 \(f(WorldPropSizePolicy.longestEdge(of: authoritativeProp.effectiveSize)))，目标 \(f(authoritativeTarget))）")
  check(authoritativeProp.effectiveSize == authoritativeProp.size,
        "手动定过之后必须只剩一份尺寸（size \(v(authoritativeProp.size)) vs effectiveSize \(v(authoritativeProp.effectiveSize))）")
  check(authoritativeProp.isSizeLocked && authoritativeProp.collision == withAuthoritative.collision,
        "手动尺寸必须留住\"用户定的\"标记与碰撞代理")
  guard let authoritativeVolume = authoritativeAfter.generatedCollisionVolume else {
      print("FAIL: 带权威尺寸的物件改尺寸后碰撞盒解不出来"); exit(1)
  }
  check(abs(authoritativeVolume.halfExtents.x * 2 - authoritativeProp.effectiveSize.x) <= 1e-5,
        "碰撞盒必须跟着手动尺寸走（碰撞盒 \(f(authoritativeVolume.halfExtents.x * 2)) vs 尺寸 \(f(authoritativeProp.effectiveSize.x))）")
  print("PASS[9]: 权威尺寸与手动覆盖只有一份出口 —— 权威 \(v(authoritative.dimensions)) ⇒ 手动 \(v(authoritativeProp.effectiveSize))，碰撞盒同步")

  // ---- A8：已入库但没摆出来，列表里必须写着「尚未摆放」----
  check(ResidentPropEditorState.rowStatus(isHeld: false, isPlaced: false) == "尚未摆放",
        "未摆放的已入库物件必须写着「尚未摆放」（实测「\(ResidentPropEditorState.rowStatus(isHeld: false, isPlaced: false))」）")
  check(ResidentPropEditorState.rowStatus(isHeld: false, isPlaced: true) == "已摆出",
        "已摆出的物件必须写着「已摆出」")
  check(ResidentPropEditorState.rowStatus(isHeld: true, isPlaced: false) == "手持中",
        "手持中的物件必须写着「手持中」")
  let editor = ResidentPropEditorState()
  let unplaced = WorldObjectState(isEnabled: false,
      transform: .init(position: .init(x: 0, y: 0, z: 0), rotation: .init(x: 0, y: 0, z: 0, w: 1), scale: .init(x: 1, y: 1, z: 1)),
      metadata: ["gmgn.generated-prop.v1": String(decoding: try JSONEncoder().encode(resizedProp), as: UTF8.self)])
  editor.update(.init(worldID: saved.worldID, revision: 1, objects: [unplaced], surfaces: [], canUndo: false))
  check(editor.objects.contains { $0.generatedProp?.objectID == resizedProp.objectID },
        "「我的物件」列表（默认筛选）必须能看见已入库但没摆出来的物件")
  print("PASS[8]: 未摆放的已入库物件在列表里可见且写着「\(ResidentPropEditorState.rowStatus(isHeld: false, isPlaced: editor.objects.first?.isEnabled ?? true))」")

  print("PASS: \(checks) 项断言全部通过（真机那把剑 \(v(auto.size)) m、真实舱体 \(environment.count) 三角形 / \(grid.layers.count) 承托层）")
 }
}
"""#
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-propsize-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let program = temporary.appendingPathComponent("PropSize.swift")
try harness.write(to: program, atomically: true, encoding: .utf8)
let prelude = temporary.appendingPathComponent("HostPrelude.swift")
try """
import Foundation
import os
enum ProductIdentity { static let displayName = "gmgn radio"; static let bundleIdentifier = "ai.gmgn.radio" }
extension Logger { var showPrivacy: Bool { get { false } set {} } }
""".write(to: prelude, atomically: true, encoding: .utf8)
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
// 先把 WorldRuntime 的目标文件**拷一份**再链接：别的 agent 可能正在同时重新构建
// （SwiftPM 直接改写 `.o`），原地链接会报 "input file was modified during the build"，
// 把一次真实的失败伪装成"编译失败"。
let objects = try FileManager.default.contentsOfDirectory(at: build.appendingPathComponent("WorldRuntime.build"), includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "o" }
    .map { url -> String in
        let copy = temporary.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: copy)
        try? FileManager.default.copyItem(at: url, to: copy)
        return FileManager.default.fileExists(atPath: copy.path) ? copy.path : url.path
    }
let executable = temporary.appendingPathComponent("propsize")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
process.arguments = ["-j1", "-parse-as-library", "-O", "-I", build.appendingPathComponent("Modules").path,
    prelude.path, program.path, "-o", executable.path] + objects
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { print("compile failed"); exit(1) }
// 面板那一段也必须能编译（滑块/微调按钮就是用户真正碰得到的那一块）。
let viewCheck = Process()
viewCheck.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
viewCheck.arguments = ["-j1", "-typecheck", "-swift-version", "6", "-I", build.appendingPathComponent("Modules").path,
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/ResidentPropEditorState.swift").path,
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/PropSupportGridPresentation.swift").path,
    // 挂点（slot）：面板那一行读 `PropAttachmentSlots.displayName` / `PropAttachmentPoint.allCases`，
    // 编辑器状态读 `held.hand.attachmentPoint`。挂点表的**真定义**在 PropAttachmentSlot.swift
    // （它要 PropGripInference），而 `PropAttachmentPoint` 的真定义在依赖渲染侧类型的
    // PropAttachment.swift 里 ⇒ 类型用只含三个 case 的替身（数值/骨名一条都不在它里面，
    // 那些由 tools/test-resident-prop-hold.swift 切真源码钉住）。
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/PropGripInference.swift").path,
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/PropAttachmentSlot.swift").path,
    root.appendingPathComponent("tools/fixtures/PropAttachmentPointShim.swift").path,
    root.appendingPathComponent("apps/macos/Sources/GMGNRadio/VisualEngine/ResidentPropEditorView.swift").path]
try viewCheck.run(); viewCheck.waitUntilExit()
guard viewCheck.terminationStatus == 0 else { print("FAIL: 摆放面板（尺寸控件那一段）编译不过"); exit(1) }
let run = Process()
run.executableURL = executable
try run.run()
run.waitUntilExit()
exit(run.terminationStatus)

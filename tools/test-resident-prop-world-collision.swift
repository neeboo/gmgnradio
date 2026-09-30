// 「已摆放的生成物件在世界里是不是障碍」——真机数据的同源验收（无宿主、无窗口、无 GPU）。
//
// 真机 2026-09-30 用户报「斧头怎么没有做碰撞啊」。这条链上有两个消费者，它们的输入必须
// 是**同一份**、几何也必须是**同一份**：
//
//   1. 运行时移动/站立：`WorldAgentContext` 的 `PropLayoutCollisionWorld`（底座是
//      `MarbleLivingCabinCollisionWorld` + `CollisionVolumeWorld`）→ 居民胶囊；
//   2. 摆放判定：`ResidentPropPlacementService.validate` 的"还走不走得到活动锚点"预检
//      → `WorldPlacementRouteMap.blockedNodes`（格子红/黄与落地是否被拒都由它决定）。
//
// 本 harness 用真机存档（`斧头` + `咖啡机`）、真实 161,600 三角形碰撞网格与真实承托网格，
// 把下面五条钉死：
//
//   A1 已摆放的生成物件在**世界通行/站立判定**里是障碍（行为断言：站位 + 187 条真实行走）；
//   A2 解不出碰撞体积的已摆物件**可见地报告**，而不是静默变成"这里没有东西"（fail-closed）；
//   A3 判定只有一条：摆放预检的被占节点与运行时站立判定**逐节点一致**
//      （旧实现实测：斧头漏挡 9 / 假挡 5，咖啡机漏挡 9）；
//   A4 代价有界：每次 `blockedNodes` 只扫物件自身包围盒外扩胶囊的那几列；
//   A5 这条差异是**用户看得见**的：同一批真实地面格里有 13 格从"可放"变成"会被拒绝"。
import Foundation
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceRoot = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
let bootstrap = try String(contentsOf: sourceRoot.appendingPathComponent("App/LivingWorldBootstrap.swift"), encoding: .utf8)
let collisionStart = bootstrap.range(of: "struct MarbleLivingCabinCollisionWorld:")!.lowerBound
let collisionEnd = bootstrap.range(of: "/// An effect is keyed", range: collisionStart..<bootstrap.endIndex)!.lowerBound
let harness = #"""
import Foundation
import WorldRuntime
import simd

\#(bootstrap[collisionStart..<collisionEnd])

struct RealSave: WorldStatePersisting {
    let state: WorldState
    func load() throws -> WorldState? { state }
    func save(_ state: WorldState) throws {}
}

func q(_ values: [Double], _ p: Double) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
}

/// 旧实现（2026-09-30 之前）逐字复刻：**未旋转**的半尺寸去扩世界轴 AABB。
/// 只用于"证明这条断言能抓住缺陷"的对照，不再是生产代码。
func legacyBlockedNodes(_ map: WorldPlacementRouteMap, spacing: Float,
                        volume: WorldCollisionVolume, capsuleRadius: Float) -> Set<Int> {
    let halfX = Float(volume.halfExtents.x), halfZ = Float(volume.halfExtents.z)
    let blockHalfX = halfX + capsuleRadius, blockHalfZ = halfZ + capsuleRadius
    let top = volume.center.y + volume.halfExtents.y
    let bottom = volume.center.y - volume.halfExtents.y
    var result: Set<Int> = []
    let xRange = Int(floor((volume.center.x - blockHalfX) / spacing))...Int(floor((volume.center.x + blockHalfX) / spacing))
    let zRange = Int(floor((volume.center.z - blockHalfZ) / spacing))...Int(floor((volume.center.z + blockHalfZ) / spacing))
    for x in xRange {
        for z in zRange {
            let column = PropSupportColumn(x: x, z: z)
            guard let layerHeight = map.supportHeight(at: column) else { continue }
            guard layerHeight <= top + 0.0001, layerHeight >= bottom - 0.0001 else { continue }
            let cx = (Float(x) + 0.5) * spacing, cz = (Float(z) + 0.5) * spacing
            guard abs(cx - volume.center.x) <= blockHalfX, abs(cz - volume.center.z) <= blockHalfZ else { continue }
            guard let node = map.node(at: WorldVector3(x: cx, y: layerHeight, z: cz)) else { continue }
            result.insert(node)
        }
    }
    return result
}

@main struct WorldCollision {
 @MainActor static func main() async throws {
  var checks = 0
  func check(_ ok: Bool, _ message: String) {
    checks += 1
    guard ok else { print("FAIL: \(message)"); exit(1) }
  }

  // ---- 真机数据 ----
  let saveURL = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent("Library/Application Support/ai.gmgn.radio/LivingWorld/marble-living-cabin/1.2.0/state.json")
  let saved = try JSONDecoder().decode(WorldState.self, from: Data(contentsOf: saveURL))
  let wr = URL(fileURLWithPath: "apps/macos/Resources/Worlds/marble-living-cabin")
  let manifest = try JSONDecoder().decode(WorldManifest.self, from: Data(contentsOf: wr.appendingPathComponent("world.json")))
  struct C: Decodable { struct F: Decodable { let origin: [Float]; let scale: Float }; let framing: F }
  let cfg = try JSONDecoder().decode(C.self, from: Data(contentsOf: wr.appendingPathComponent("marble.json")))
  let origin = SIMD3(cfg.framing.origin[0], cfg.framing.origin[1], cfg.framing.origin[2])
  let triangles = try GLBColliderDecoder().decode(
    data: Data(contentsOf: wr.appendingPathComponent("collider.glb")),
    transform: WorldMeshTransform(axisConversion: .flipYAndZ, origin: origin, uniformScale: cfg.framing.scale))
  let mesh = TriangleMeshCollisionWorld(triangles: triangles)
  check(triangles.count > 100000, "真机舱体碰撞网格必须是十万级三角形（实测 \(triangles.count)）")

  let context = try WorldAgentContext(manifest: manifest, persistence: RealSave(state: saved))
  let installed = MarbleLivingCabinCollisionWorld(environment: mesh,
    props: CollisionVolumeWorld(volumes: ResidentPropPlacementConfiguration.independentCollisionVolumes(manifest)))
  _ = try context.installCollisionWorldAndReconcilePlacement(installed)

  let placeable = saved.objectStates.values.filter { $0.isEnabled && $0.generatedProp != nil }
  check(placeable.count == 2, "真机存档必须有两件已摆出的生成物件（实测 \(placeable.count)）")
  guard let axe = placeable.first(where: { $0.generatedProp?.displayName == "斧头" }),
        let coffee = placeable.first(where: { $0.generatedProp?.displayName == "E2E-0907 咖啡机" }),
        let axeVolume = axe.generatedCollisionVolume,
        let coffeeVolume = coffee.generatedCollisionVolume,
        let axeProp = axe.generatedProp, let coffeeProp = coffee.generatedProp
  else { print("FAIL: 真机存档里必须有斧头与咖啡机两件已摆出的生成物件"); exit(1) }
  print("真机数据：斧头 yaw=\(atan2(2*(axeVolume.rotation.w*axeVolume.rotation.y), 1-2*axeVolume.rotation.y*axeVolume.rotation.y)) size=(\(axeProp.size.x), \(axeProp.size.z))")
  print("          咖啡机 yaw=\(atan2(2*(coffeeVolume.rotation.w*coffeeVolume.rotation.y), 1-2*coffeeVolume.rotation.y*coffeeVolume.rotation.y)) size=(\(coffeeProp.size.x), \(coffeeProp.size.z))")

  let capsule = WorldCapsule(radius: 0.2, height: 1.8)
  let axeOnly = CollisionVolumeWorld(volumes: [axeVolume])

  // ---- A1：已摆放的生成物件在世界通行/站立判定里是障碍 ----
  for (name, item, volume) in [("斧头", axe, axeVolume), ("咖啡机", coffee, coffeeVolume)] {
    let p = item.transform.position
    let ground = context.collisionWorld.groundHeight(at: SIMD3(p.x, p.y, p.z)) ?? p.y
    check(!context.collisionWorld.canOccupy(capsule, at: SIMD3(p.x, ground, p.z)),
          "\(name) 的正中心必须站不住（运行时站立判定必须把它当障碍）")
    // 同一个查询也必须在"运行时的碰撞世界"上成立（不是只有裸体积会挡）。
    check(!CollisionVolumeWorld(volumes: [volume]).canOccupy(capsule, at: SIMD3(p.x, volume.center.y, p.z)),
          "\(name) 的体积必须挡住胶囊（同一个 WorldCapsuleClearance）")
  }
  // 行为断言：从真机存档里居民站的地方出发，走遍附近所有真实路点，
  // **没有一帧**居民的胶囊落在斧头体积里。
  var tried = 0, penetrations = 0, firstPenetration: String? = nil
  for waypoint in manifest.waypoints.filter(\.enabled) {
    let from = context.state.agentTransform.position
    let distance = hypot(waypoint.position.x - from.x, waypoint.position.z - from.z)
    guard distance > 0.6, distance < 8 else { continue }
    do { _ = try context.move(to: waypoint.id) } catch { continue }
    tried += 1
    var frames = 0
    while frames < 1200 {
      try context.tick(deltaTime: 1.0 / 30.0)
      frames += 1
      let p = context.state.agentTransform.position
      if !axeOnly.canOccupy(capsule, at: SIMD3(p.x, p.y, p.z)) {
        penetrations += 1
        if firstPenetration == nil { firstPenetration = "走向 \(waypoint.id) 时 (\(p.x), \(p.y), \(p.z))" }
      }
      if context.currentMovementRequestID == nil { break }
    }
  }
  check(tried >= 100, "必须真的走了一批真实目的地（实测 \(tried)）")
  check(penetrations == 0,
        "居民任何一帧都不能落在已摆放的斧头里（实测 \(penetrations) 帧，首次 \(firstPenetration ?? "-")）")
  print("PASS[1]: 已摆放的生成物件在世界通行/站立判定里是障碍（站立判定=挡住；\(tried) 条真实行走、\(penetrations) 帧穿模）")

  // ---- A2：解不出碰撞体积的已摆物件必须**可见地报告**（fail-closed）----
  var corrupt = saved
  corrupt.objectStates[coffeeProp.objectID]?.metadata["gmgn.generated-prop.v1"] = "broken"
  let resolved = WorldLayoutObstacles.resolve(corrupt)
  check(resolved.unmodelledObjectIDs == [coffeeProp.objectID],
        "损坏的已摆物件必须出现在 unmodelledObjectIDs（实测 \(resolved.unmodelledObjectIDs)）")
  check(resolved.volumes.count == 1,
        "解析结果只能包含那件好物件（实测 \(resolved.volumes.map(\.id))）")
  // 旧写法（`compactMap(\.generatedCollisionVolume)`）会把损坏的那件静默丢掉：这正是
  // "让一件家具对所有判据都无敌"的来源。
  let legacy = corrupt.objectStates.values.compactMap(\.generatedCollisionVolume)
  check(legacy.count == 1 && resolved.volumes.count == legacy.count,
        "旧写法与解析器在体积集合上必须一致，差别只在'说不说得出来'")
  // 真路：摆放服务必须**拒绝**并给出可读原因，而不是若无其事地继续。
  let corruptContext = try WorldAgentContext(manifest: manifest, persistence: RealSave(state: corrupt))
  let service = ResidentPropPlacementService(context: corruptContext)
  let replay = WorldPropPlacement(surfaceID: axe.supportSurfaceID ?? "grid",
    position: axe.transform.position, yaw: 0)
  do {
    _ = try service.previewState(objectID: axeProp.objectID, placement: replay)
    print("FAIL: 房间里有一件解不出碰撞体积的已摆物件时，摆放判定必须拒绝，而不是静默放行")
    exit(1)
  } catch {
    let reason: PropSupportBlockReason
    if case let ResidentPropPlacementError.blockedBySupport(inner) = error { reason = inner }
    else { print("FAIL: 拒绝原因必须是可读的阻挡原因，实测 \(error)"); exit(1) }
    let text = reason.errorDescription ?? ""
    check(text.contains(coffeeProp.objectID),
          "拒绝原因必须点名那一件解不出体积的物件（实测「\(text)」）")
    check(!text.isEmpty, "拒绝原因必须有可读文案（光标旁那枚标签要显示它）")
    print("PASS[2]: 解不出碰撞体积的已摆物件可见地报告并 fail-closed：\(text)")
  }

  // ---- 真实承托网格 + 移动图（摆放预检用的那一套）----
  let parameters = PropSupportGridParameters()
  let positions = manifest.waypoints.filter(\.enabled).map(\.position)
  var minimumX = positions[0].x, maximumX = positions[0].x
  var minimumZ = positions[0].z, maximumZ = positions[0].z
  for p in positions {
    minimumX = min(minimumX, p.x); maximumX = max(maximumX, p.x)
    minimumZ = min(minimumZ, p.z); maximumZ = max(maximumZ, p.z)
  }
  let margin = parameters.spacing + parameters.capsuleRadius
  let derivation = PropSupportDerivationWorld(base: mesh, topVolumes: manifest.collisionVolumes.filter(\.isBlocking))
  let grid = PropSupportGridBuilder.build(collision: derivation,
    bounds: WorldPlanarBounds(minimumX: minimumX - margin, maximumX: maximumX + margin,
                              minimumZ: minimumZ - margin, maximumZ: maximumZ + margin),
    seed: manifest.spawn.position, parameters: parameters)
  check(grid.layers.count > 1000, "真机舱体必须派生出上千个承托层（实测 \(grid.layers.count)）")
  let heights = positions.map(\.y)
  let map = WorldPlacementRouteMap(grid: grid, lowerHeight: heights.min()! - 0.2,
                                   upperHeight: heights.max()! + 0.2)
  check(map.standableNodeCount > 1000, "移动图必须有上千个可站节点（实测 \(map.standableNodeCount)）")

  // ---- A3：判定只有一条 ----
  var legacyDisagreements = 0
  for (name, volume) in [("斧头", axeVolume), ("咖啡机", coffeeVolume)] {
    let runtime = CollisionVolumeWorld(volumes: [volume])
    var truth: Set<Int> = []
    for layer in grid.layers {
      let cx = (Float(layer.column.x) + 0.5) * grid.spacing
      let cz = (Float(layer.column.z) + 0.5) * grid.spacing
      guard let node = map.node(at: WorldVector3(x: cx, y: layer.supportHeight, z: cz)) else { continue }
      guard hypot(cx - volume.center.x, cz - volume.center.z) <= 3 else { continue }
      guard !runtime.canOccupy(map.capsule, at: SIMD3(cx, layer.supportHeight, cz)) else { continue }
      truth.insert(node)
    }
    let model = map.blockedNodes(volume: volume)
    let legacy = legacyBlockedNodes(map, spacing: grid.spacing, volume: volume, capsuleRadius: map.capsuleRadius)
    let legacyMissed = truth.subtracting(legacy).count, legacyExtra = legacy.subtracting(truth).count
    legacyDisagreements += legacyMissed + legacyExtra
    let missed = truth.subtracting(model), extra = model.subtracting(truth)
    print("        \(name)：运行时真值 \(truth.count) 节点；旧实现 \(legacy.count)（漏 \(legacyMissed) / 假 \(legacyExtra)）；现在 \(model.count)（漏 \(missed.count) / 假 \(extra.count)）")
    check(legacyMissed + legacyExtra > 0, "\(name) 必须真的能暴露出旧实现的轴向缺陷（否则这条断言是空的）")
    check(missed.isEmpty && extra.isEmpty,
          "\(name) 的被占节点必须与运行时站立判定逐节点一致（漏 \(missed.sorted().prefix(4)) / 假 \(extra.sorted().prefix(4))）")
  }
  print("PASS[3]: 判定只有一条 —— 摆放预检的被占节点与运行时站立判定逐节点一致（旧实现与运行时分歧 \(legacyDisagreements) 个节点）")

  // ---- A4：代价有界 ----
  var samples: [Double] = []
  for _ in 0 ..< 200 {
    let start = DispatchTime.now().uptimeNanoseconds
    _ = map.blockedNodes(volume: axeVolume)
    samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1000)
  }
  let median = q(samples, 0.5), p95 = q(samples, 0.95)
  check(median < 2000, "单件物件的被占节点计算必须便宜（实测中位 \(median) µs）")
  print(String(format: "PASS[4]: 代价有界 —— 单件物件 blockedNodes 中位 %.1f µs p95 %.1f µs（只扫物件自身包围盒外扩胶囊的几列，不碰三角形网格）",
    median, p95))

  // ---- A5：这条差异是用户看得见的（真实地面格上的判定翻转）----
  let anchorIDs = Set(manifest.activities.compactMap(\.entryWaypointID)).sorted()
  var anchorPositions: [String: WorldVector3] = [:]
  for id in anchorIDs { if let w = manifest.waypoints.first(where: { $0.id == id }) { anchorPositions[id] = w.position } }
  check(!anchorIDs.isEmpty, "真机世界必须有活动锚点（否则这条判据没有目标）")
  let floorHeight = grid.layers.map(\.supportHeight).min()!
  let floors = grid.layers.filter { $0.supportHeight < floorHeight + 0.3 }
  let candidateSize = SIMD2<Float>(0.29150167, 0.4719286)
  var legacyOccupied: Set<Int> = []
  var currentOccupied: Set<Int> = []
  for volume in [axeVolume, coffeeVolume] {
    legacyOccupied.formUnion(legacyBlockedNodes(map, spacing: grid.spacing, volume: volume, capsuleRadius: map.capsuleRadius))
    currentOccupied.formUnion(map.blockedNodes(volume: volume))
  }
  var flips = 0, allowed = 0
  var flipExample: String? = nil
  for layer in floors {
    let volume = PropPlacementEvaluator.placementVolume(
      footprint: WorldPlanarFootprint(size: candidateSize, yaw: 0),
      height: 0.35, at: layer, spacing: grid.spacing)
    let legacyDecision = map.decision(
      blockedNodes: legacyOccupied.union(legacyBlockedNodes(map, spacing: grid.spacing, volume: volume, capsuleRadius: map.capsuleRadius)),
      anchorIDs: anchorIDs, anchorPositions: anchorPositions,
      residentPosition: context.state.agentTransform.position)
    let currentDecision = map.decision(
      blockedNodes: currentOccupied.union(map.blockedNodes(volume: volume)),
      anchorIDs: anchorIDs, anchorPositions: anchorPositions,
      residentPosition: context.state.agentTransform.position)
    if legacyDecision == .allowed { allowed += 1 }
    if legacyDecision != currentDecision {
      flips += 1
      if flipExample == nil {
        flipExample = "cell=(\(layer.column.x),\(layer.column.z)) 旧=\(legacyDecision) → 现在=\(currentDecision)"
      }
    }
  }
  check(flips > 0,
        "真机地面格上必须真的出现「旧实现放行、统一判据拒绝」的翻转（否则这条断言是空的）")
  check(allowed > floors.count / 2,
        "翻转必须是**收紧**而不是大范围拒绝（旧实现放行 \(allowed)/\(floors.count)）")
  print("PASS[5]: 差异用户看得见 —— \(floors.count) 个真实地面格里 \(flips) 个从「可放」变成「会被拒绝」（例：\(flipExample ?? "-")）")

  print("PASS: \(checks) 项断言全部通过（真机两件物件、161,600 三角形网格、\(grid.layers.count) 承托层、\(map.standableNodeCount) 可站节点）")
 }
}
"""#
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-worldcollision-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let program = temporary.appendingPathComponent("WorldCollision.swift")
try harness.write(to: program, atomically: true, encoding: .utf8)
// 宿主侧类型的最小替身（与 test-resident-prop-one-judge.swift 同一套）。
let prelude = temporary.appendingPathComponent("HostPrelude.swift")
try """
import Foundation
import os
enum ProductIdentity { static let displayName = "gmgn radio"; static let bundleIdentifier = "ai.gmgn.radio" }
extension Logger { var showPrivacy: Bool { get { false } set {} } }
""".write(to: prelude, atomically: true, encoding: .utf8)
let build = root.appendingPathComponent("apps/macos/Packages/WorldRuntime/.build/arm64-apple-macosx/debug")
let objects = try FileManager.default.contentsOfDirectory(at: build.appendingPathComponent("WorldRuntime.build"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "o" }.map(\.path)
let executable = temporary.appendingPathComponent("worldcollision")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
process.arguments = ["-j1", "-parse-as-library", "-O", "-I", build.appendingPathComponent("Modules").path,
    sourceRoot.appendingPathComponent("Agent/WorldAgentContext.swift").path,
    sourceRoot.appendingPathComponent("Presence/ResidentPropPlacementService.swift").path,
    sourceRoot.appendingPathComponent("Presence/ResidentPropPlacementConfiguration.swift").path,
    prelude.path,
    program.path, "-o", executable.path] + objects
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { print("compile failed"); exit(1) }
let run = Process()
run.executableURL = executable
run.arguments = []
try run.run()
run.waitUntilExit()
exit(run.terminationStatus)

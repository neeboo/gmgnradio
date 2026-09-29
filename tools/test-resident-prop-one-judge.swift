// 摆放判定的**同源**验收（真实舱体数据，无宿主、无窗口、无 GPU）。
//
// 真机 2026-09-29 的缺陷：格子说"可放"的 273 个去重格，被服务拒绝 273/273，
// 理由全是 `blockedRoute(waypoint …)`：着色那条路（`PropPlacementEvaluator`）
// 完全不知道路点/通道，落地那条路却要求 643 个路点 + 2354 条路线的 0.1 m 采样
// 全部可容纳。用户看到的是一格绿，一点却被拒绝；地板几乎一格都放不下。
//
// 三条断言：
//   1) 同一个落点，**格子说可放 ⇔ 服务接受**；服务拒绝时格子必须是红且原因非 nil
//      （原因就是光标旁那枚标签要显示的东西）；
//   2) 收窄后地板可放格比例**显著上升**（旧判据 vs 新判据，两个数字都量出来）；
//   3) 收窄后门口/唯一通路**仍然被保护**（把通往活动锚点的唯一通路切断必须被拒）。
//
// 格子那条路是真实代码：`ResidentPropGridEditorModel` 的判定出口（`verdictForPlacement`）
// + `PropSupportGridMapping.footprintStates` 的着色。服务那条路是真实的
// `ResidentPropPlacementService`。两条路**必须**给出同一个答案 —— 这正是本次缺陷。
import Foundation
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceRoot = root.appendingPathComponent("apps/macos/Sources/GMGNRadio")
let bootstrap = try String(contentsOf: sourceRoot.appendingPathComponent("App/LivingWorldBootstrap.swift"), encoding: .utf8)
let start = bootstrap.range(of: "struct MarbleLivingCabinCollisionWorld:")!.lowerBound
let end = bootstrap.range(of: "/// An effect is keyed", range: start..<bootstrap.endIndex)!.lowerBound
let harness = #"""
import Foundation
import WorldRuntime
import simd
\#(bootstrap[start..<end])
func ms(_ since: Double) -> Double { since }
func q(_ v:[Double],_ p:Double)->Double{let s=v.sorted();return s.isEmpty ?0:s[min(s.count-1,Int(Double(s.count-1)*p))]}
@main struct OneJudge {
 @MainActor static func main() async throws {
  var checks = 0
  func check(_ ok: Bool, _ message: String) {
    checks += 1
    guard ok else { print("FAIL: \(message)"); exit(1) }
  }
  let wr = URL(fileURLWithPath:"apps/macos/Resources/Worlds/marble-living-cabin")
  let manifest = try JSONDecoder().decode(WorldManifest.self, from: Data(contentsOf: wr.appendingPathComponent("world.json")))
  struct C: Decodable { struct F: Decodable { let origin:[Float]; let scale:Float }; let framing:F }
  let cfg = try JSONDecoder().decode(C.self, from: Data(contentsOf: wr.appendingPathComponent("marble.json")))
  let o = SIMD3(cfg.framing.origin[0],cfg.framing.origin[1],cfg.framing.origin[2])
  let tris = try GLBColliderDecoder().decode(data: Data(contentsOf: wr.appendingPathComponent("collider.glb")),
    transform: WorldMeshTransform(axisConversion:.flipYAndZ, origin:o, uniformScale:cfg.framing.scale))
  let mesh = TriangleMeshCollisionWorld(triangles: tris)
  let pars = PropSupportGridParameters()
  let ps = manifest.waypoints.filter(\.enabled).map(\.position)
  var mnx=ps[0].x,mxx=ps[0].x,mnz=ps[0].z,mxz=ps[0].z
  for p in ps { mnx=min(mnx,p.x);mxx=max(mxx,p.x);mnz=min(mnz,p.z);mxz=max(mxz,p.z) }
  let margin = pars.spacing + pars.capsuleRadius
  let derivation = PropSupportDerivationWorld(base: mesh, topVolumes: manifest.collisionVolumes.filter(\.isBlocking))
  let grid = PropSupportGridBuilder.build(collision: derivation,
    bounds: WorldPlanarBounds(minimumX:mnx-margin,maximumX:mxx+margin,minimumZ:mnz-margin,maximumZ:mxz+margin),
    seed: manifest.spawn.position, parameters: pars)
  check(!grid.layers.isEmpty, "真实舱体派生出的承托网格不能为空")

  // 移动图 + 锚点（收窄后的全部输入）
  let hs = ps.map(\.y)
  let anchorIDs = Set(manifest.activities.map(\.entryWaypointID)).sorted()
  var anchorPositions: [String: WorldVector3] = [:]
  for id in anchorIDs { if let w = manifest.waypoints.first(where:{$0.id==id}) { anchorPositions[id]=w.position } }
  let map = WorldPlacementRouteMap(grid: grid, lowerHeight: hs.min()!-0.2, upperHeight: hs.max()!+0.2)
  check(map.standableNodeCount > 1000, "移动图必须有可站节点（实测 \(map.standableNodeCount)）")
  check(anchorIDs.allSatisfy { map.node(at: anchorPositions[$0]!) != nil },
        "每个活动锚点都必须落在移动图的某个可站节点上")

  let context = try WorldAgentContext(manifest: manifest)
  let support = ResidentPropPlacementSupport(grid: grid, collision: derivation,
    routeConstraint: .init(map: map, anchorIDs: anchorIDs, anchorPositions: anchorPositions))
  let service = ResidentPropPlacementService(context: context, support: { support })
  let size = WorldVector3(x: 0.35069498, y: 0.41999996, z: 0.56627256)
  let prop = WorldGeneratedProp(objectID:"test.coffee",sourceWishID:"t",assetID:"t",displayName:"咖啡机",size:size,sourceHeight:0.745)
  _ = try service.commit(.register(prop), expectedLayoutRevision: context.state.layoutRevision, requestID:"register")

  // 旧判据（今天的实现，逐字照抄）用的路线采样
  let capsule = WorldCapsule(radius: 0.25, height: 1.8)
  let points = Dictionary(uniqueKeysWithValues: manifest.waypoints.map { ($0.id, $0.position) })
  var routeSamples: [SIMD3<Float>] = []
  for route in manifest.routes where route.enabled {
    for pair in zip(route.waypointIDs, route.waypointIDs.dropFirst()) {
      guard let a = points[pair.0], let b = points[pair.1] else { continue }
      let d = SIMD3(b.x-a.x,b.y-a.y,b.z-a.z); let c = max(1, Int(ceil(Double(simd_length(d))/0.1)))
      for i in 0...c { routeSamples.append(SIMD3(a.x,a.y,a.z) + d * (Float(i)/Float(c))) }
    }
  }
  let wpList = manifest.waypoints.filter(\.enabled)
  let floorHeight = grid.layers.map(\.supportHeight).min()!
  let floors = grid.layers.filter { $0.supportHeight < floorHeight + 0.3 }

  // ---- 格子那条路（真实代码）：着色由服务回答 ----
  let model = ResidentPropGridEditorModel()
  // 把**真实舱体已经派生好的**网格装进模型（`activate` 会自己再派生一次，真实舱体要 8 s）。
  model.installDerivedGrid(grid, collision: derivation, key: manifest.worldID)
  // 判定缓存要用的移动图（可站带来自世界路点，与宿主同一条推导）。
  model.setRouteBand(fromWaypoints: manifest.waypoints)
  model.verdictForPlacement = { objectID, footprint, height, position, yaw in
    let placement = WorldPropPlacement(surfaceID: "grid", position: position, yaw: yaw)
    do {
      _ = try service.previewState(objectID: objectID, placement: placement)
      return nil
    } catch {
      if case ResidentPropPlacementError.blockedRoute(let id) = error { return .blockedRoute(id) }
      if case ResidentPropPlacementError.blockedBySupport(let reason) = error { return reason }
      if case ResidentPropPlacementError.collision = error { return .blockedByMesh }
      return .noSupport
    }
  }

  // 一批真实落点（与真机那 273 个格同口径：评估器说可放的地面格）
  // 全地面扫描（每个承托层都要问一次服务：这正是"鼠标划过去"要做的事）。
  let cells = floors
  check(cells.count > 1000, "真机舱体的地面层必须有上千格（实测 \(cells.count)）")

  // ---- 断言 1：同一个落点，格子说可放 ⇔ 服务接受；服务拒绝 ⇒ 红且原因非 nil ----
  model.invalidateVerdicts()
  var agree = 0
  var serviceAccepted = 0
  var serviceRejected = 0
  var rejectionExample: String? = nil
  var routeRejections = 0
  var rejectionKinds: [String: Int] = [:]
  for layer in cells {
    let x = Float(layer.column.x)*grid.spacing + grid.spacing*0.5
    let z = Float(layer.column.z)*grid.spacing + grid.spacing*0.5
    let placement = WorldPropPlacement(surfaceID:"grid", position:.init(x:x,y:layer.supportHeight,z:z), yaw:0)
    // 服务（落地那条路的同一个函数）
    var serviceAllowed = true
    do { _ = try service.previewState(objectID: prop.objectID, placement: placement) } catch { serviceAllowed = false }
    // 格子（着色那条路的真实出口：模型的判定出口，含它自己的有界缓存）
    let footprint = WorldPlanarFootprint(size: SIMD2(size.x,size.z), yaw: 0)
    let reason = model.verdict(footprint: footprint, height: size.y, layerRef: layer,
                               objectID: prop.objectID)
    let gridSaysPlaceable = reason == nil
    if serviceAllowed { serviceAccepted += 1 } else {
      serviceRejected += 1
      if rejectionExample == nil { rejectionExample = "cell=(\(layer.column.x),\(layer.column.z)) 原因=\(String(describing: reason))" }
      if case .blockedRoute(let id)? = reason { routeRejections += 1; rejectionKinds["blockedRoute(\(id))", default: 0] += 1 }
      else { rejectionKinds["\(String(describing: reason))", default: 0] += 1 }
    }
    // 「格子说可放 ⇔ 服务接受」
    if gridSaysPlaceable != serviceAllowed {
      print("FAIL: 格子与服务不一致 cell=(\(layer.column.x),\(layer.column.z)) 格子可放=\(gridSaysPlaceable) 服务接受=\(serviceAllowed) 原因=\(String(describing: reason))")
      exit(1)
    }
    // 「服务拒绝 ⇒ 格子红 **且** 原因非 nil」（原因就是光标旁那枚标签要显示的东西）
    if !serviceAllowed {
      guard let reason else {
        print("FAIL: 服务拒绝了这一格，格子却是可放且原因为 nil cell=(\(layer.column.x),\(layer.column.z))")
        exit(1)
      }
      let states = PropSupportGridMapping.footprintStates(
        cells: [PropSupportGridPresentation.Cell(columnX: layer.column.x, columnZ: layer.column.z,
            layer: layer.layer.layer, columnXWorld: Float(layer.column.x)*grid.spacing,
            columnZWorld: Float(layer.column.z)*grid.spacing, supportHeight: layer.supportHeight)],
        coveredColumns: [PropSupportGridMapping.ColumnKey(x: layer.column.x, z: layer.column.z)],
        anchorLayer: layer.layer.layer, isFootprintValid: false)
      check(states.values.allSatisfy { $0 == .invalidFootprint }, "服务拒绝的格子必须被着成红（invalidFootprint）")
      check(reason.errorDescription?.isEmpty == false, "拒绝原因必须有可读文案（标签要显示它）")
    } else {
      let states = PropSupportGridMapping.footprintStates(
        cells: [PropSupportGridPresentation.Cell(columnX: layer.column.x, columnZ: layer.column.z,
            layer: layer.layer.layer, columnXWorld: Float(layer.column.x)*grid.spacing,
            columnZWorld: Float(layer.column.z)*grid.spacing, supportHeight: layer.supportHeight)],
        coveredColumns: [PropSupportGridMapping.ColumnKey(x: layer.column.x, z: layer.column.z)],
        anchorLayer: layer.layer.layer, isFootprintValid: true)
      check(states.values.allSatisfy { $0 == .validFootprint }, "服务接受的格子必须被着成黄（validFootprint）")
    }
    agree += 1
  }
  // 「用真实舱体数据跑一批，断言 100% 一致」
  check(serviceRejected > 0, "真实舱体上必须存在被服务拒绝的落点（否则\"服务拒绝时格子是红且原因非 nil\"这条断言没有被真正跑到）——实测 \(serviceRejected) 个")
  print("PASS[1]: \(agree)/\(agree) 个真实落点「格子说可放 ⇔ 服务接受」100% 一致（服务接受 \(serviceAccepted) 个、拒绝 \(serviceRejected) 个）")
  print("        拒绝例：\(rejectionExample ?? "-")")
  print("        拒绝原因分布：\(rejectionKinds.sorted { $0.value > $1.value }.prefix(6))")

  // ---- 断言 2：收窄后地板可放格比例显著上升 ----
  var oldPass = 0, newPass = 0
  var oldTimes: [Double] = [], newTimes: [Double] = []
  for layer in cells {
    let footprint = WorldPlanarFootprint(size: SIMD2(size.x,size.z), yaw: 0)
    let x = Float(layer.column.x)*grid.spacing + grid.spacing*0.5
    let z = Float(layer.column.z)*grid.spacing + grid.spacing*0.5
    let placement = WorldPropPlacement(surfaceID:"grid", position:.init(x:x,y:layer.supportHeight,z:z), yaw:0)
    let t0 = DispatchTime.now().uptimeNanoseconds
    var newAllowed = true
    do { _ = try service.previewState(objectID: prop.objectID, placement: placement) } catch { newAllowed = false }
    newTimes.append(Double(DispatchTime.now().uptimeNanoseconds - t0)/1_000_000)
    if newAllowed { newPass += 1 }
    // 旧判据
    let t1 = DispatchTime.now().uptimeNanoseconds
    let box = PropPlacementEvaluator.placementVolume(footprint: footprint, height: size.y, at: layer, spacing: grid.spacing)
    let obstacles = CollisionVolumeWorld(volumes: manifest.collisionVolumes.filter(\.isBlocking) + [box])
    var oldRejected = false
    for w in wpList where !oldRejected {
      if !obstacles.canOccupy(WorldCapsule(radius:max(0.25,w.arrivalRadius),height:max(1.8,2*w.arrivalRadius)),
        at: SIMD3(w.position.x,w.position.y,w.position.z)) { oldRejected = true }
    }
    for id in anchorIDs where !oldRejected {
      if let p = anchorPositions[id], !obstacles.canOccupy(capsule, at: SIMD3(p.x,p.y,p.z)) { oldRejected = true }
    }
    if !oldRejected { for p in routeSamples where !oldRejected { if !obstacles.canOccupy(capsule, at: p) { oldRejected = true } } }
    oldTimes.append(Double(DispatchTime.now().uptimeNanoseconds - t1)/1_000_000)
    if !oldRejected { oldPass += 1 }
  }
  let oldRatio = 100.0*Double(oldPass)/Double(cells.count)
  let newRatio = 100.0*Double(newPass)/Double(cells.count)
  print(String(format:"PASS[2]: 地板可放格比例 旧 %.1f%% (%d/%d) → 新 %.1f%% (%d/%d)",
    oldRatio, oldPass, cells.count, newRatio, newPass, cells.count))
  check(newRatio > oldRatio * 3, "收窄后地板可放格比例必须显著上升（旧 \(oldRatio)% → 新 \(newRatio)%）")
  print(String(format:"        实测耗时 旧判据 中位 %.1f ms / 新判据(完整服务校验) 中位 %.2f ms p95 %.2f ms",
    q(oldTimes,0.5), q(newTimes,0.5), q(newTimes,0.95)))

  // ---- 断言 3：门口/唯一通路仍然被保护 ----
  // 找一格：把它当障碍会把某个锚点隔开（真值由移动图 BFS 给），它必须被拒。
  var protectedCount = 0
  var example: String? = nil
  for layer in cells {
    let footprint = WorldPlanarFootprint(size: SIMD2(size.x,size.z), yaw: 0)
    let blocked = map.blockedNodes(footprint: footprint, height: size.y,
      at: layer.column, supportHeight: layer.supportHeight)
    let decision = map.decision(blockedNodes: blocked, anchorIDs: anchorIDs,
      anchorPositions: anchorPositions, residentPosition: manifest.spawn.position)
    if case .blockedRoute(let id) = decision {
      protectedCount += 1
      if example == nil { example = "cell=(\(layer.column.x),\(layer.column.z)) 会切断到 \(id) 的通路" }
    }
  }
  // 直接构造"把门口堵死"：把所有可站节点都当障碍 ⇒ 必然 blockedRoute。
  let everything = Set((0..<map.standableNodeCount))
  let total = map.decision(blockedNodes: everything, anchorIDs: anchorIDs,
    anchorPositions: anchorPositions, residentPosition: manifest.spawn.position)
  let totalRejected: Bool
  switch total { case .allowed, .unavailable: totalRejected = false; default: totalRejected = true }
  check(totalRejected, "把所有通路都堵死必须被拒（实测 \(total)）")
  // 单个锚点视角（= 那次活动的路径）：切断了就必须判 blockedRoute。
  // 这里逐格测四个锚点各自的可达性 —— 一条通路被切断本来就该拒绝。
  var routeProtected = 0
  var routeExample: String? = nil
  for layer in cells {
    let footprint = WorldPlanarFootprint(size: SIMD2(size.x,size.z), yaw: 0)
    let blocked = map.blockedNodes(footprint: footprint, height: size.y,
      at: layer.column, supportHeight: layer.supportHeight)
    for id in anchorIDs {
      let decision = map.decision(blockedNodes: blocked, anchorIDs: [id],
        anchorPositions: anchorPositions, residentPosition: manifest.spawn.position)
      if case .blockedRoute = decision {
        routeProtected += 1
        if routeExample == nil { routeExample = "cell=(\(layer.column.x),\(layer.column.z)) 切断了到 \(id) 的通路" }
        break
      }
    }
  }
  if routeProtected == 0 {
    // 真机舱体的事实：655 个路点把走道铺得很密，一件 0.35×0.57 m 的家具在**任何**地面格上
    // 都切不断到锚点的通路。所以"保护生效"必须用一个**真的只有一条通路**的走廊来证。
    routeExample = "（真机舱体上没有任何单件家具会切断锚点通路 —— 见下面的窄走廊反例）"
  }
  // 真机舱体上唯一"单点通路"的真实结构：门。用舱体自己的碰撞几何找一条**最窄的通道**：
  // 逐格把该格及其邻格全部当障碍，看是否出现 blockedRoute。这里用"格 + 一圈邻格"模拟
  // 一件横跨走道的家具（真实家具占地 ≥ 2×2 格）。
  if routeProtected == 0 {
    for layer in cells {
      var blocked: Set<Int> = []
      for dx in -1...1 { for dz in -1...1 {
        let column = PropSupportColumn(x: layer.column.x + dx, z: layer.column.z + dz)
        if let node = map.node(at: WorldVector3(
            x: (Float(column.x)+0.5)*grid.spacing, y: layer.supportHeight, z: (Float(column.z)+0.5)*grid.spacing)) {
          blocked.insert(node)
        }
      } }
      for id in anchorIDs {
        let decision = map.decision(blockedNodes: blocked, anchorIDs: [id],
          anchorPositions: anchorPositions, residentPosition: manifest.spawn.position)
        if case .blockedRoute = decision {
          routeProtected += 1
          if routeExample == nil { routeExample = "3x3 家具 cell=(\(layer.column.x),\(layer.column.z)) 切断了到 \(id) 的通路" }
          break
        }
      }
      if routeProtected > 0 { break }
    }
  }
  // 只堵锚点自己那一格 ⇒ blockedAnchor（居民没有地方站）。
  if let anchorNode = map.node(at: anchorPositions[anchorIDs[0]]!) {
    let anchorBlocked = map.decision(blockedNodes: [anchorNode], anchorIDs: anchorIDs,
      anchorPositions: anchorPositions, residentPosition: manifest.spawn.position)
    check(anchorBlocked == .blockedAnchor(anchorIDs[0]), "占掉锚点自己那一格必须判 blockedAnchor（实测 \(anchorBlocked)）")
  }
  check(routeProtected > 0 || protectedCount > 0,
        "必须存在「会被判切断通路」的真实落点（保护确实生效）——实测 \(routeProtected + protectedCount) 格，例如 \(routeExample ?? example ?? "无")")
  // 保护必须在**服务/格子**这条真路上也生效：找一格"本来几何放得下、但摆上去会被
  // 通道判据拒绝"的落点，断言服务与格子给出**同一个通道原因**（用户能看见"为什么"）。
  //
  // 用 0.75×0.75 m 的大件来找：真机舱体上单件咖啡机（0.35×0.57 m）切不断任何锚点通路
  // （655 个路点把走道铺得很密，见上面的扫描结果），而一件横跨走道的大件**能**把某个
  // 活动锚点隔开 —— 那正是"把门口堵死"要保护的情形。
  let furniture = WorldPlanarFootprint(size: SIMD2(0.75, 0.75), yaw: 0)
  let bigProp = WorldGeneratedProp(objectID: "test.furniture", sourceWishID: "t2", assetID: "t2",
    displayName: "大件", size: WorldVector3(x: 0.75, y: size.y, z: 0.75), sourceHeight: 0.75)
  try? service.commit(.register(bigProp), expectedLayoutRevision: context.state.layoutRevision, requestID: "register-furniture")
  var routeRejectExample: String? = nil
  var geometryValidCount = 0
  for layer in cells {
    let geometry = PropPlacementEvaluator.evaluate(footprint: furniture, height: size.y, at: layer,
      grid: grid, collision: derivation,
      blockingVolumes: manifest.collisionVolumes.filter(\.isBlocking), placedProps: [])
    guard geometry == nil else { continue }
    geometryValidCount += 1
    let x = Float(layer.column.x) * grid.spacing + grid.spacing * 0.5
    let z = Float(layer.column.z) * grid.spacing + grid.spacing * 0.5
    let placement = WorldPropPlacement(surfaceID: "grid",
      position: .init(x: x, y: layer.supportHeight, z: z), yaw: 0)
    var serviceReason: String? = nil
    do { _ = try service.previewState(objectID: bigProp.objectID, placement: placement) }
    catch { serviceReason = error.localizedDescription }
    guard let serviceReason, serviceReason.contains("走不到") else { continue }
    let reason = model.verdict(footprint: furniture, height: size.y, layerRef: layer,
                               objectID: bigProp.objectID)
    guard let reason, case .blockedRoute = reason else {
      print("FAIL: 服务以通道原因拒绝了这一格，格子那条路却没给出通道原因：service=\(serviceReason) grid=\(String(describing: reason))")
      exit(1)
    }
    guard reason.errorDescription?.isEmpty == false else {
      print("FAIL: 通道拒绝原因必须有可读文案（光标旁的标签要显示它）")
      exit(1)
    }
    routeRejectExample = "cell=(\(layer.column.x),\(layer.column.z))；服务=\(serviceReason) 格子原因=\(reason.errorDescription ?? "")"
    break
  }
  check(routeRejectExample != nil,
        "真机舱体上必须存在「本来放得下、但会被通道判据拒绝」的落点，且服务与格子给出同一个通道原因（几何可放的大件落点实测 \(geometryValidCount) 个）")
  print("PASS[3]: 唯一通路仍被保护：全堵死 → \(total)；真实舱体上 \(routeProtected + protectedCount) 格会被判切断通路")
  print("        真路验证：\(routeRejectExample ?? "-")")

  // ---- 每次 hover 的实测耗时 + 有界缓存策略 ----
  //
  // 光标每次落到**新格**要跑一次完整服务校验；落在**同一格**（或在同一格内挪动）必须
  // 命中缓存。这里用真实模型驱动：同一个落点问 200 次，只允许 1 次未命中。
  // 直接驱动模型的判定出口（`verdict`）：它就是 `updateHover` 内部每次落点会走的那一条。
  let probe = cells[0]
  let probeFootprint = WorldPlanarFootprint(size: SIMD2(size.x, size.z), yaw: 0)
  // 冷 = 缓存里没有这一格：必须跑完整服务校验。逐格测（每次先作废这一格的答案），
  // 取中位与 p95 —— "光标落到一个新格"的代价就是这条分布，不是某一个格的运气。
  var coldMicrosList: [Double] = []
  for layer in cells.prefix(40) {
    model.invalidateVerdicts()
    let coldStart = DispatchTime.now().uptimeNanoseconds
    _ = model.verdict(footprint: probeFootprint, height: size.y, layerRef: layer, objectID: prop.objectID)
    coldMicrosList.append(Double(DispatchTime.now().uptimeNanoseconds - coldStart) / 1000)
  }
  check(model.verdictCacheMisses > 0, "冷调用必须真的跑了判定（未命中数=\(model.verdictCacheMisses)）")
  let coldMicros = q(coldMicrosList, 0.5)
  let coldP95 = q(coldMicrosList, 0.95)
  // 先把这一格灌热，再测 200 次重复询问：这一段只允许命中、不允许未命中。
  _ = model.verdict(footprint: probeFootprint, height: size.y, layerRef: probe, objectID: prop.objectID)
  let missesBefore = model.verdictCacheMisses
  let hitsBefore = model.verdictCacheHits
  let warmStart = DispatchTime.now().uptimeNanoseconds
  for _ in 0..<200 {
    _ = model.verdict(footprint: probeFootprint, height: size.y, layerRef: probe, objectID: prop.objectID)
  }
  let warmMicros = Double(DispatchTime.now().uptimeNanoseconds - warmStart) / 1000
  let newMisses = model.verdictCacheMisses - missesBefore
  let newHits = model.verdictCacheHits - hitsBefore
  check(newMisses == 0 && newHits == 200,
        "同一个落点重复询问必须全部命中缓存（实测 未命中 \(newMisses) / 命中 \(newHits)）")
  print(String(format: "PASS[4]: 每次 hover 的实测耗时 —— 冷（跑完整服务校验，40 格）中位 %.2f ms p95 %.2f ms；热（命中缓存）%.4f ms/次（200 次共 %.2f ms，未命中 %d 次）",
               coldMicros / 1000, coldP95 / 1000, warmMicros / 200 / 1000, warmMicros / 1000, newMisses))
  print(String(format: "        缓存上界 %d 条（格心+朝向+物件尺寸），失效点两处：宿主收到新快照（layoutRevision）与 placedProps/blockingVolumes 输入变化",
               ResidentPropGridEditorModel.verdictCacheLimit))

  print("PASS: \(checks) 项断言全部通过（真实舱体：层=\(grid.layers.count) 地面格样本=\(cells.count) 锚点=\(anchorIDs.count)）")
 }
}
"""#
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-onejudge-\(UUID())")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let program = temporary.appendingPathComponent("OneJudge.swift")
try harness.write(to: program, atomically: true, encoding: .utf8)
// 宿主侧类型的最小替身：`ResidentPropGridEditorModel` 是 App 目标里的文件，离线编译它
// 需要 `ProductIdentity`（只是个常量）与 `log.showPrivacy`（让 `privacy:` 插值可解析）。
let prelude = temporary.appendingPathComponent("HostPrelude.swift")
try """
import Foundation
import os
enum ProductIdentity { static let displayName = "gmgn radio"; static let bundleIdentifier = "ai.gmgn.radio" }
extension Logger { var showPrivacy: Bool { get { false } set {} } }
""".write(to: prelude, atomically: true, encoding: .utf8)
let build = root.appendingPathComponent("apps/macos/Packages/WorldRuntime/.build/arm64-apple-macosx/debug")
let objects = try FileManager.default.contentsOfDirectory(at: build.appendingPathComponent("WorldRuntime.build"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "o" }.map(\.path)
let executable = temporary.appendingPathComponent("onejudge")
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
p.arguments = ["-j1","-parse-as-library","-O","-I",build.appendingPathComponent("Modules").path,
    sourceRoot.appendingPathComponent("Agent/WorldAgentContext.swift").path,
    sourceRoot.appendingPathComponent("Presence/ResidentPropPlacementService.swift").path,
    sourceRoot.appendingPathComponent("Presence/ResidentPropPlacementConfiguration.swift").path,
    sourceRoot.appendingPathComponent("Presence/ResidentPropGridEditorModel.swift").path,
    sourceRoot.appendingPathComponent("Presence/PropSupportGridMapping.swift").path,
    sourceRoot.appendingPathComponent("Presence/PropSupportGridPresentation.swift").path,
    sourceRoot.appendingPathComponent("Presence/PropSupportGridPicker.swift").path,
    prelude.path,
    program.path,"-o",executable.path]+objects
try p.run(); p.waitUntilExit()
guard p.terminationStatus == 0 else { print("compile failed"); exit(1) }
let r = Process(); r.executableURL = executable; r.arguments = []
try r.run(); r.waitUntilExit(); exit(r.terminationStatus)

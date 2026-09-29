import Foundation
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let modelURL = root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/ResidentPropEditorState.swift")
guard FileManager.default.fileExists(atPath: modelURL.path) else {
    print("FAIL: prop editor has no cancel-safe state machine"); exit(1)
}
var model = try String(contentsOf: modelURL, encoding: .utf8)
if CommandLine.arguments.contains("--red-double-submit") {
 model = model.replacingOccurrences(of:"isOpen && !isSaving && candidate",with:"isOpen && candidate")
   .replacingOccurrences(of:"guard isOpen, !isSaving, let commit",with:"guard isOpen, let commit")
}
// 格子管线：发光那条断言要真的驱动 `ResidentPropGridEditorModel`（它在渲染层与焦点裁剪之间），
// 所以把映射/拾取/呈现/格子模型四个文件一起编进 harness（它们都只依赖 WorldRuntime 的公共类型）。
let gridMapping = try String(contentsOf:root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/PropSupportGridMapping.swift"),encoding:.utf8)
let gridPicker = try String(contentsOf:root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/PropSupportGridPicker.swift"),encoding:.utf8)
let gridPresentation = try String(contentsOf:root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/PropSupportGridPresentation.swift"),encoding:.utf8)
let gridModelSource = try String(contentsOf:root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/ResidentPropGridEditorModel.swift"),encoding:.utf8)
let controller = try String(contentsOf:root.appendingPathComponent("apps/macos/Sources/GMGNRadio/VisualEngine/StageWindowController.swift"),encoding:.utf8)
let editorView = try String(contentsOf:root.appendingPathComponent("apps/macos/Sources/GMGNRadio/VisualEngine/ResidentPropEditorView.swift"),encoding:.utf8)
guard controller.contains("StageControlPanelLayout.transportWidth + StageControlPanelLayout.controlSize"),
      controller.contains("window.minSize = CGSize(width: 760, height: 520)"),
      controller.contains("propEditorPanel.widthAnchor.constraint(equalToConstant: 340)"),
      controller.contains("Float(1 - point.y / bounds.height)") else {
 print("FAIL: native editor size or bottom-left pointer mapping is missing");exit(1)
}
guard ["拿着看", "放回", "向前", "向后", "向上", "向下", "左转 15°", "右转 15°"].allSatisfy(editorView.contains),
      editorView.contains("state.isSelectedHeld") else {
 print("FAIL: limited right-hand controls are missing from the shared placement panel");exit(1)
}
let appSource = try String(contentsOf:root.appendingPathComponent("apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift"),encoding:.utf8)
func method(_ signature:String, in source:String = controller) -> String {
 let start = source.range(of:signature)!.lowerBound
 let open = source[start...].firstIndex(of:"{")!
 var depth = 0
 for i in source[open...].indices {
  if source[i] == "{" { depth += 1 };if source[i] == "}" { depth -= 1 }
  if depth == 0 { return String(source[start...i]) }
 }
 fatalError("unbalanced method")
}
// ── 结构性断言（真源码）：窗口失焦**不是**放弃编辑的意图 ────────────────────────
// 装修的"在手"状态只是一份本地草稿（`placement`/`candidate`，`preview` 从不改世界）。
// 真机 2026-09-28：用户打开装修 → 点了一下物件那一行 → 切到别的窗口说话，装修在 4.4 s 后
// 自己退出了，而 Debug 下一次派生要 4.8 s ⇒ 派生每次被掐死、结果被丢弃。所以
// `windowDidResignKey` 里不许出现任何关闭/停用装修会话的动作（读 `isOpen` 这种只读引用无妨）。
let resignKeyHandler = method("func windowDidResignKey(")
for forbidden in ["close()","deactivate","escape(","cancelPreview"] where resignKeyHandler.contains(forbidden) {
 print("FAIL: windowDidResignKey must not close or deactivate the decoration editor on focus loss (found \"\(forbidden)\")");exit(1)
}
if controller.contains("func windowDidBecomeKey") {
 let becomeKeyHandler = method("func windowDidBecomeKey(")
 guard !becomeKeyHandler.contains("close()"), !becomeKeyHandler.contains("deactivate") else {
  print("FAIL: regaining window focus must not compensate for focus loss by closing the decoration editor");exit(1)
 }
}
let harness = #"""
import Foundation
import Combine
import simd
import os
import WorldRuntime
func precondition(_ condition:@autoclosure()->Bool,_ message:String="assertion failed") {
 if !condition() { print("FAIL: \(message)"); exit(1) }
}
/// 被一起编进来的生产代码（格子模型、被抽取的 App 方法）要用的最小环境：
/// 日志与 bundle 标识。harness 不装 subsystem，只要求这些引用能解析。
enum ProductIdentity { static let bundleIdentifier = "test.gmgn.fixture" }
let livingWorldLogger = Logger(subsystem: ProductIdentity.bundleIdentifier, category: "LivingWorld")
/// 「还会不会好」与「会话要不要重接」这两条判据是**纯类型**：从 App 里逐字抽出来放在
/// 文件作用域，测试直接调它们（而不是各写一份替身，那样就测不到生产代码了）。
\#(method("enum ResidentPropSupportReadiness",in:appSource))
\#(method("enum ResidentPropDecorationSessionRearm",in:appSource))
\#(model.replacingOccurrences(of: "import WorldRuntime", with: ""))
\#(gridMapping)
\#(gridPicker)
\#(gridPresentation)
\#(gridModelSource)
/// 一块 3 m × 3 m 的平地板（y = 0）：派生出来的承托网格每列只有一层、而且同高。
///
/// 真实舱体的地面是起伏网格（每个高度常常只有一格），反而量不出"整块 footprint 发光"这件事；
/// 平地板把这一点单独隔出来。判定/派生仍然走 WorldRuntime 的真实现（不 stub 几何）。
struct FlatFloorCollision: WorldPropSupportQuerying {
 let half: Float
 private var plane: [WorldTriangle] {
  [WorldTriangle(SIMD3(-half,0,-half),SIMD3(half,0,-half),SIMD3(half,0,half)),
   WorldTriangle(SIMD3(-half,0,-half),SIMD3(half,0,half),SIMD3(-half,0,half))]
 }
 func triangles(in bounds: WorldPlanarBounds) -> [WorldTriangle] {
  guard bounds.minimumX <= half, bounds.maximumX >= -half,
        bounds.minimumZ <= half, bounds.maximumZ >= -half else { return [] }
  return plane
 }
 // 站立判据：只在这块板子**之上**成立（胶囊进不到板子下面）。
 func canOccupy(_ capsule: WorldCapsule, at position: SIMD3<Float>) -> Bool { position.y >= -0.001 }
 // `groundHeight` 的语义是"不高于 position.y + 0.05 的最高承托面"：必须真的**随高度**回答，
 // 否则列扫描会一层层往下把同一个高度取 256 次（那是假几何造出来的病态网格，不是被测行为）。
 func groundHeight(at position: SIMD3<Float>) -> Float? {
  guard position.x >= -half, position.x <= half,
        position.z >= -half, position.z <= half,
        position.y + 0.05 >= 0 else { return nil }
  return 0
 }
 func canTraverse(_ capsule: WorldCapsule, from start: SIMD3<Float>, to destination: SIMD3<Float>, maximumStepHeight: Float) -> Bool { true }
}
/// 计数版平地板：`triangles(in:)` 的调用次数就是"派生**真的问过几何**没有"的唯一证据。
///
/// 按世界缓存这条行为断言不能只看"模型里有个字典"：第二次进入同一世界必须**一次都不问**
/// 几何，那才叫复用而不是重算。
///
/// `sleepSeconds` 只作用在**第一次**查询上（多睡 50 ms），用来把"派生正在进行中"这一段
/// 拉长到主线程能观察到 —— 于是"切窗口/关面板会不会打断进行中的派生"可以被真的测出来，
/// 而不是靠时序碰运气。
final class CountingFloorCollision: WorldPropSupportQuerying, @unchecked Sendable {
 let half: Float
 private let sleepSeconds: Double
 private let lock = NSLock()
 private var queries = 0
 init(half: Float, sleepSeconds: Double = 0) { self.half = half; self.sleepSeconds = sleepSeconds }
 var queryCount: Int { lock.lock(); defer { lock.unlock() }; return queries }
 private var plane: [WorldTriangle] {
  [WorldTriangle(SIMD3(-half,0,-half),SIMD3(half,0,-half),SIMD3(half,0,half)),
   WorldTriangle(SIMD3(-half,0,-half),SIMD3(half,0,half),SIMD3(-half,0,half))]
 }
 func triangles(in bounds: WorldPlanarBounds) -> [WorldTriangle] {
  lock.lock()
  queries += 1
  let isFirstQuery = queries == 1
  lock.unlock()
  if isFirstQuery, sleepSeconds > 0 { Thread.sleep(forTimeInterval: sleepSeconds) }
  guard bounds.minimumX <= half, bounds.maximumX >= -half,
        bounds.minimumZ <= half, bounds.maximumZ >= -half else { return [] }
  return plane
 }
 func canOccupy(_ capsule: WorldCapsule, at position: SIMD3<Float>) -> Bool { position.y >= -0.001 }
 func groundHeight(at position: SIMD3<Float>) -> Float? {
  guard position.x >= -half, position.x <= half,
        position.z >= -half, position.z <= half,
        position.y + 0.05 >= 0 else { return nil }
  return 0
 }
 func canTraverse(_ capsule: WorldCapsule, from start: SIMD3<Float>, to destination: SIMD3<Float>, maximumStepHeight: Float) -> Bool { true }
}
/// 窗口失焦这条路的**真源码**：`windowDidResignKey` 从 `StageWindowController` 里原样抽出来
/// 编译（不是替身），所以"失焦会不会关掉装修、会不会打断派生"测的是生产代码。
///
/// 接线刻意照抄真机：会话关闭（`onEditingChanged(false)`）⇒ App 的 `setResidentPropEditing(false)`
/// ⇒ 停用格子并收回派生令牌。
@MainActor final class DecorationFocusHarness {
 static let log = Logger(subsystem: ProductIdentity.bundleIdentifier, category: "StageWindowController")
 let residentPropEditor = ResidentPropEditorState()
 let residentPropGridEditor = ResidentPropGridEditorModel()
 /// **正在进行的那一次**派生的令牌（与 App 里的 `residentPropGridDerivation` 同名同义）。
 var residentPropGridDerivation: UUID?
 init() {
  residentPropEditor.onEditingChanged = { [unowned self] open in
   guard !open else { return }
   residentPropGridDerivation = nil
   residentPropGridEditor.deactivate()
  }
 }
 /// 打开装修：进会话 + 派生格子（真机 `open()` → `activateResidentPropGrid()`）。
 func beginDecoration(worldID: String, collision: any WorldPropSupportQuerying = FlatFloorCollision(half: 1.5)) async {
  residentPropEditor.update(.init(worldID: worldID, revision: 1, objects: [], surfaces: [], canUndo: false))
  residentPropEditor.open()
  residentPropGridDerivation = UUID()
  await residentPropGridEditor.activate(collision: collision, seed: .init(x: 0, y: 0, z: 0),
   bounds: .init(minimumX: -1.5, maximumX: 1.5, minimumZ: -1.5, maximumZ: 1.5), key: worldID)
  residentPropGridDerivation = nil
 }
 \#(method("func windowDidResignKey("))
}
@MainActor final class ControllerHarness {
 let residentPropEditor = ResidentPropEditorState()
 \#(method("func configureResidentPropEditor("))
 \#(method("func updateResidentPropEditor("))
 /// 格子点击落地那条路径的入口。本 harness 不驱动它（`snappedPlacement` 恒为 nil），
 /// 只要求被抽取的 `publishResidentPropGrid` 能编过。
 func moveResidentPropGridPointer(to position:WorldVector3,layerName:String,yaw:Float) async {}
}
/// 建造模式格子模型的替身：只保留 `publishResidentPropGrid` / 就绪判据读的那几个事实，
/// 但**"就绪是异步的"这个时序**照旧（`isReady` 不会在请求的那一刻就为真）。
///
/// 另外照抄真机的**第三种状态**：`grid != nil` 但**一层承托面都没有**
/// （`PropSupportGridBuilder.build` 的 fail-closed 失败就是返回这样一个空网格，
/// 见 `PropSupportGrid.empty`）。真机 2026-09-28 的"永远说格子还在生成"正活在这一格：
/// `isReady` 为真 ⇒ 面板永远说"还在生成"，而 `surfaces` 恒为空 ⇒ 那一行永远点不动。
@MainActor final class GridStub {
 var isBuildModeActive = false
 var spacing:Float = 0.25
 /// 与真机 `ResidentPropGridEditorModel.grid` 对应：nil = 还没派生出来；
 /// 非 nil 但 `layers` 为空 = 派生结束了，却什么承托面也没有。
 var grid:(layers:[Int],spacing:Float)?
 var isReady:Bool { grid != nil }
 var renderCells:[Int] { (grid?.layers ?? []).indices.map { $0 } }
 var cellStates:[Int:Int] = [:]
 var snappedPlacement:(position:SIMD3<Float>,yaw:Float)?
 var hoveredLayerName:String?
 /// 派生完成：这一刻起渲染层才有格子可画（与真机 `residentPropGridEditor` 同一时序）。
 func becomeReady(cells:Int = 4) {
  isBuildModeActive = true
  grid = (Array(0..<cells), 0.25)
 }
 /// 派生"成功"但一无所获：`isReady` 为真，一个格子都没有（真机的空网格）。
 func becomeReadyEmpty() { becomeReady(cells: 0) }
 func deactivate() { isBuildModeActive = false; grid = nil }
}
typealias StageWindowController = ControllerHarness
enum ResidentPropPlacementError: Error { case inactiveContext }
@MainActor final class LayoutContext {
 struct Manifest { let worldID:String }
 let manifest:Manifest
 var state:WorldState
 init(_ state:WorldState) { self.state = state;manifest = .init(worldID:state.worldID) }
}
typealias WorldAgentContext = LayoutContext
@MainActor final class PlacementFixture {
 let context:LayoutContext
 let isCurrent:()->Bool
 init(_ context:LayoutContext, isCurrent:@escaping()->Bool) { self.context = context;self.isCurrent = isCurrent }
 func preview(objectID:String,placement:WorldPropPlacement) throws -> WorldObjectState {
  guard isCurrent() else { throw ResidentPropPlacementError.inactiveContext }
  return context.state.objectStates[objectID]!
 }
 func holdCommand(objectID:String) throws -> WorldPropLayoutCommand {
  guard isCurrent() else { throw ResidentPropPlacementError.inactiveContext }
  return .hold(objectID:objectID,avatarAssetID:"pmx.2b-miss-0414-standard",
   calibration:.init(avatarAssetID:"pmx.2b-miss-0414-standard",hand:.rightHand,
    normalizedGrip:.init(x:0.5,y:0.2,z:0.5),localOffset:.init(x:0,y:0,z:0),
    localRotation:.init(x:0,y:0,z:0,w:1)))
 }
 func adjustGripCommand(objectID:String,localOffset:WorldVector3,localRotation:WorldQuaternion) throws -> WorldPropLayoutCommand {
  guard isCurrent() else { throw ResidentPropPlacementError.inactiveContext }
  return .adjustGrip(objectID:objectID,avatarAssetID:"pmx.2b-miss-0414-standard",
   calibration:.init(avatarAssetID:"pmx.2b-miss-0414-standard",hand:.rightHand,
    normalizedGrip:.init(x:0.5,y:0.2,z:0.5),localOffset:localOffset,localRotation:localRotation))
 }
 func returnHeldCommand(objectID:String) throws -> WorldPropLayoutCommand {
  guard isCurrent() else { throw ResidentPropPlacementError.inactiveContext }
  return .returnHeld(objectID:objectID,avatarAssetID:"pmx.2b-miss-0414-standard")
 }
 func commit(_ command:WorldPropLayoutCommand,expectedLayoutRevision:UInt64,requestID:String) throws {
  guard isCurrent() else { throw ResidentPropPlacementError.inactiveContext }
  var simulation = WorldSimulation(restoring:context.state)
  try simulation.applyPropLayout(command,expectedLayoutRevision:expectedLayoutRevision,requestID:requestID)
  context.state = simulation.state
 }
}
@MainActor final class AppGuardHarness {
 final class Spatial {
  var selectedWorldID:String? = "a";var residentPropPreview:WorldObjectState?
  var isResidentPropBuildModeActive = false
  var residentPropGridCells:[Int] = []
  var residentPropGridStates:[Int:Int] = [:]
  var residentPropGridSpacing:Float = 0
 }
 var livingWorldContext:LayoutContext?
 let spatialStage = Spatial()
 /// 建造模式的格子模型（替身）。**就绪是异步的**：请求派生的那一刻 `isReady` 还是 false。
 let residentPropGridEditor = GridStub()
 /// **正在进行的那一次**派生的令牌（nil = 没有派生在跑）。与真机同名同义。
 var residentPropGridDerivation:UUID?
 /// 最近一次推给面板的承托几何状态。只在变化时重推快照。
 private var publishedResidentPropSupportPhase:ResidentPropSupportPhase?
 /// 最近一次已经写进日志的相位（真机用它压制重复日志）。
 private var loggedResidentPropSupportPhase:ResidentPropSupportPhase?
 private var residentPropGridPushedHover:ResidentPropGridHoverKey?
 var stageWindowController:ControllerHarness?
 var residentPropEditingID:UUID?
 var residentPropEditingWorldID:String?
 var isPreparing = false
 var delayPreparation = false
 /// 格子派生好之后，面板该看到的承托面（真机来自 `listedSupportLayers()`）。
 var surfaces:[ResidentPropEditorSurface] = []
 func prepareResidentPropMutation(_ command:WorldPropLayoutCommand,context:LayoutContext) async throws {
  if delayPreparation { isPreparing = true;try await Task.sleep(for:.milliseconds(25));isPreparing = false }
 }
 func residentPropPlacementService(context:LayoutContext,isCurrent:@escaping()->Bool) -> PlacementFixture { .init(context,isCurrent:isCurrent) }
 func residentPropDescriptor(_ state:WorldObjectState) -> WorldObjectState? { state }
 /// 真机：唯一一处把快照推给面板（`updateResidentPropEditor`）。返回**是否真的推成功**。
 @discardableResult
 func synchronizeResidentPropPresentation() -> Bool {
  guard let context = livingWorldContext, spatialStage.selectedWorldID == context.manifest.worldID else { return false }
  guard let stageWindowController else { return false }
  stageWindowController.updateResidentPropEditor(residentPropEditorSnapshot(context:context))
  return true
 }
 /// 真机：`surfaces` 来自格子（没有网格 / 空网格都是空），"还会不会好"来自派生令牌，
 /// 而 `supportGeometryUnavailable` 是这两件事的唯一投影（`ResidentPropSupportReadiness`）。
 func residentPropEditorSnapshot(context:LayoutContext) -> ResidentPropEditorSnapshot {
  let visibleSurfaces = residentPropGridEditor.renderCells.isEmpty ? [] : surfaces
  let readiness = ResidentPropSupportReadiness.resolve(
   hasSurfaces:!visibleSurfaces.isEmpty,
   isDeriving:residentPropGridDerivation != nil)
  return .init(worldID:context.manifest.worldID,revision:context.state.layoutRevision,
   objects:Array(context.state.objectStates.values),
   surfaces:visibleSurfaces,
   canUndo:false,heldProp:context.state.heldProp,
   supportGeometryUnavailable:readiness.supportGeometryUnavailable)
 }
 /// 真机 `finishResidentPropGridDerivation`：任务一结束令牌就失效，并按现状重推快照。
 func finishResidentPropGridDerivation(_ token:UUID) {
  guard residentPropGridDerivation == token else { return }
  residentPropGridDerivation = nil
  publishResidentPropGrid()
 }
 \#(method("private struct ResidentPropSupportPhase",in:appSource))
 \#(method("private var residentPropSupportPhase",in:appSource))
 \#(method("private struct ResidentPropGridHoverKey",in:appSource))
 \#(method("private func publishResidentPropGrid(",in:appSource).replacingOccurrences(of:"private func",with:"func"))
 func setResidentPropEditing(_ editing:Bool) {
  residentPropEditingID = editing ? UUID() : nil
  residentPropEditingWorldID = editing ? livingWorldContext?.manifest.worldID : nil
 }
 \#(method("private func configureResidentPropEditor(",in:appSource).replacingOccurrences(of:"private func",with:"func"))
 \#(method("private func isResidentPropEditorCurrent(",in:appSource).replacingOccurrences(of:"private func",with:"func"))
}
@main struct Test {
 @MainActor static func main() async throws {
  let s = ResidentPropEditorState()
  let zero = WorldVector3(x:0,y:0,z:0)
  let identity = WorldTransform(position:zero,rotation:.init(x:0,y:0,z:0,w:1),scale:.init(x:1,y:1,z:1))
  let surface = ResidentPropEditorSurface(id:"floor",name:"地面",position:zero)
  let prop = WorldGeneratedProp(objectID:"cup",sourceWishID:"wish",assetID:"cup-asset",displayName:"杯子",size:.init(x:0.1,y:0.2,z:0.1),sourceHeight:1)
  let metadata = ["gmgn.generated-prop.v1":String(data:try JSONEncoder().encode(prop),encoding:.utf8)!]
  let object = WorldObjectState(transform:identity, metadata:metadata)
  let snapshot = ResidentPropEditorSnapshot(worldID:"a",revision:3,objects:[object],surfaces:[surface],canUndo:true)
  var commits = 0
  var previews:[WorldObjectState?] = []
  s.onPreviewChanged = { previews.append($0) }
  s.preview = { _, p in WorldObjectState(transform:.init(position:p.position,rotation:identity.rotation,scale:identity.scale),metadata:metadata) }
  s.commit = { _, rev, _ in
   commits += 1
   precondition(rev == 3)
   try await Task.sleep(for:.milliseconds(25))
   throw NSError(domain:"test",code:1,userInfo:[NSLocalizedDescriptionKey:"这个位置有物件"])
  }
  s.update(snapshot); s.open(); await s.select(objectID:"cup")
  precondition(s.candidate != nil)
  s.cancelPreview(); precondition(commits == 0 && s.candidate == nil)
  await s.select(objectID:"cup")
  let task = Task { await s.confirm() }
  await Task.yield(); await s.confirm(); await task.value
  precondition(commits == 1 && s.candidate != nil && s.notice == "这个位置有物件","duplicate confirmation submitted twice or failure lost draft")
  await s.movePointer(to:.init(x:2,y:0,z:1))
  precondition(s.placement?.position.x == 2)
  s.update(.init(worldID:"a",revision:4,objects:[object],surfaces:[surface],canUndo:true))
  precondition(!s.canConfirm && s.notice.contains("变化"),"old revision cannot commit")
  s.close(); precondition(s.candidate == nil && !s.isOpen)
  s.update(snapshot);s.open();await s.select(objectID:"cup")
  let late = Task { await s.confirm() };await Task.yield()
  s.update(.init(worldID:"b",revision:0,objects:[],surfaces:[],canUndo:false))
  await late.value
  precondition(s.snapshot.worldID == "b" && s.candidate == nil && s.notice.isEmpty)
  precondition(!s.isOpen)
  precondition(!ResidentPropEditorState.consumesScenePointer(isOpen:true,moving:true,inputOwnsFocus:true))
  precondition(ResidentPropEditorState.consumesScenePointer(isOpen:true,moving:true,inputOwnsFocus:false))
  precondition(!ResidentPropEditorState.consumesScenePointer(isOpen:true,moving:false,inputOwnsFocus:false))
  let host = ControllerHarness()
  var editEvents:[Bool] = []
  host.configureResidentPropEditor(preview:{ _, _ in object },commit:{ _, _, _ in snapshot },onPreviewChanged:{ _ in },onEditingChanged:{ editEvents.append($0) })
  host.updateResidentPropEditor(snapshot)
  host.residentPropEditor.open();await host.residentPropEditor.select(objectID:"cup")
  precondition(host.residentPropEditor.candidate == object)
  host.residentPropEditor.escape()
  precondition(host.residentPropEditor.isOpen && host.residentPropEditor.candidate == nil)
  host.residentPropEditor.escape()
  precondition(editEvents == [true,false])
  let handEditor = ResidentPropEditorState()
  var handWorld = WorldState(revision:0,worldID:"a",worldTime:Date(),lastObservedWallTime:Date(),weather:.clear,
   agentTransform:identity,objectStates:["cup":object])
  handWorld.layoutRevision = 3
  func handSnapshot() -> ResidentPropEditorSnapshot {
   .init(worldID:"a",revision:handWorld.layoutRevision,objects:Array(handWorld.objectStates.values),surfaces:[surface],
    canUndo:handWorld.layoutUndo != nil,heldProp:handWorld.heldProp)
  }
  let handCalibration = WorldPropGripCalibration(avatarAssetID:"pmx.2b-miss-0414-standard",hand:.rightHand,
   normalizedGrip:.init(x:0.5,y:0.2,z:0.5),localOffset:.init(x:0,y:0,z:0),
   localRotation:.init(x:0,y:0,z:0,w:1))
  handEditor.preview = { _, _ in object }
  handEditor.hold = { id, revision, requestID in
   var simulation = WorldSimulation(restoring:handWorld)
   try simulation.applyPropLayout(.hold(objectID:id,avatarAssetID:"pmx.2b-miss-0414-standard",calibration:handCalibration),
    expectedLayoutRevision:revision,requestID:requestID)
   handWorld = simulation.state
   return handSnapshot()
  }
  handEditor.adjustHeldGrip = { id, offset, rotation, revision, requestID in
   var simulation = WorldSimulation(restoring:handWorld)
   let calibration = WorldPropGripCalibration(avatarAssetID:"pmx.2b-miss-0414-standard",hand:.rightHand,
    normalizedGrip:handCalibration.normalizedGrip,localOffset:offset,localRotation:rotation)
   try simulation.applyPropLayout(.adjustGrip(objectID:id,avatarAssetID:"pmx.2b-miss-0414-standard",calibration:calibration),
    expectedLayoutRevision:revision,requestID:requestID)
   handWorld = simulation.state
   return handSnapshot()
  }
  handEditor.returnHeld = { id, revision, requestID in
   var simulation = WorldSimulation(restoring:handWorld)
   try simulation.applyPropLayout(.returnHeld(objectID:id,avatarAssetID:"pmx.2b-miss-0414-standard"),
    expectedLayoutRevision:revision,requestID:requestID)
   handWorld = simulation.state
   return handSnapshot()
  }
  handEditor.update(handSnapshot());handEditor.open();await handEditor.select(objectID:"cup");await handEditor.holdSelected()
  precondition(handEditor.isSelectedHeld && handWorld.objectStates["cup"]?.isEnabled == false,"editor hold must preserve one held identity")
  await handEditor.nudgeHeld(y:0.02)
  precondition(handWorld.objectStates["cup"]?.gripCalibration?.localOffset.y == 0.02,"editor grip adjustment must persist")
  await handEditor.returnSelected()
  precondition(handWorld.heldProp == nil && handWorld.objectStates["cup"]?.isEnabled == true,"editor return must restore original placement")
  let escaping = ResidentPropEditorState(); escaping.update(snapshot);escaping.open()
  var editorLease:UUID? = UUID(), savedFacts = 0
  escaping.onEditingChanged = { open in if !open { editorLease = nil } }
  escaping.preview = { _, _ in object }
  escaping.commit = { _, _, _ in
    let captured = editorLease
    try await Task.sleep(for:.milliseconds(25))
    guard captured != nil && editorLease == captured else { throw CancellationError() }
    savedFacts += 1
    return snapshot
  }
  await escaping.select(objectID:"cup")
  let waitingCommit = Task { await escaping.confirm() }
  while !escaping.isSaving { await Task.yield() }
  escaping.escape();await waitingCommit.value
  let actualHost = AppGuardHarness(), actualController = ControllerHarness()
  let world = WorldState(revision:0,worldID:"a",worldTime:Date(),lastObservedWallTime:Date(),weather:.clear,agentTransform:identity,objectStates:["cup":object])
  let context = LayoutContext(world);actualHost.livingWorldContext = context
  // 格子派生完成之后面板才看得到承托面（真机：`surfaces` 来自 `listedSupportLayers()`）。
  actualHost.surfaces = [surface];actualHost.residentPropGridDerivation = UUID()
  actualHost.residentPropGridEditor.becomeReady()
  actualHost.configureResidentPropEditor(actualController)
  actualController.updateResidentPropEditor(actualHost.residentPropEditorSnapshot(context:context))
  let actualEditor = actualController.residentPropEditor
  actualEditor.open();await actualEditor.select(objectID:"cup")
  actualHost.delayPreparation = true
  let preparedCommit = Task { await actualEditor.confirm() }
  while !actualHost.isPreparing { await Task.yield() }
  actualEditor.escape();await preparedCommit.value
  precondition(actualHost.residentPropEditingID == nil && context.state == world,"real App callback lease must reject save after Escape during prepare")
  precondition(editorLease == nil && savedFacts == 0 && !escaping.isOpen,"Escape while saving must revoke host lease and prevent mutation")
  let race = ResidentPropEditorState();race.update(snapshot);race.open()
  race.preview = { _, _ in try await Task.sleep(for:.milliseconds(20));return object }
  let pending = Task { await race.select(objectID:"cup") }
  await Task.yield();race.cancelPreview();await pending.value
  precondition(race.candidate == nil && race.selectedID == nil,"late preview must not revive cancelled item")
  let stalePreview = Task { await race.select(objectID:"cup") }
  await Task.yield();race.update(.init(worldID:"a",revision:4,objects:[object],surfaces:[surface],canUndo:false))
  await stalePreview.value
  precondition(race.candidate == nil && !race.canConfirm,"old revision preview must not be adopted")

  // ─────────────────────────────────────────────────────────────────────────────
  // 2026-09-28 缺陷：**格子已经画出来了，点物件那一行却没有任何反应**。
  //
  // 真机症状（截图）：面板打开、地面铺满绿色可放格、行显示「E2E-0907 咖啡机 / 已摆出」，
  // 但没有勾、没有高亮、下方也不出现任何控件 ⇒ `selectedID == nil` ⇒ `select()` 提前 return。
  // 四个条件里唯一失败的是**承托面**：`snapshot.surfaces` 是宿主**推送**来的字段，而格子
  // 派生是异步的（真实舱体 -O 0.5 s / -Onone 6.6 s），就绪那一刻的推送还没到，面板手里
  // 还是"派生中"的那一份（`surfaces` 为空）。
  //
  // 下面五条把"点一行"的**行为**钉死（而不是钉某一行代码存在）：
  //   1. 拿不到承托几何 → 进不了携带态（fail-closed 保留），但**必须说出来**；
  //   2. 宿主能答出现状（格子已就绪）→ 点一行**必须**进携带态；
  //   3. 永远拿不到几何 → 不能说"请稍候"（那不是"还没好"，是"好不了"）；
  //   4. 格子就绪那一刻，宿主**自己**必须重新投影一次面板快照；
  //   5. **宿主答不出来**与"宿主答出现状为空"必须是**不同**的结果 —— 前者是"没有人会来救
  //      这次点击"，后者是"宿主说现在确实没有承托面"。2026-09-28 真机缺陷正糊在这里：
  //      宿主答不出来时沿用手里那份陈旧快照，于是"格子还在生成"变成一句永远不会兑现的谎话。
  let driftingRow = ResidentPropEditorSnapshot(
    worldID:"a",revision:3,objects:[object],surfaces:[],canUndo:false,heldProp:nil,
    holdUnavailableReasons:[:],supportGeometryUnavailable:false)
  let stranded = ResidentPropEditorState()
  stranded.update(driftingRow);stranded.open()
  stranded.preview = { _, p in WorldObjectState(transform:.init(position:p.position,rotation:identity.rotation,scale:identity.scale),metadata:metadata) }
  // 宿主答不出更好的现状（没在装修 / 世界换了）：仍然不许静默，而且**不许说"还在生成"**
  // —— 它答不出来就意味着没有人会在下一次推送里把承托面送过来。
  await stranded.select(objectID:"cup")
  precondition(stranded.selectedID == nil && stranded.placement == nil,
    "no support geometry must not enter the carrying state")
  precondition(stranded.notice == ResidentPropEditorState.supportSessionUnavailableText,
    "a click the host cannot answer must say so honestly, never \"still generating\" (got \"\(stranded.notice)\")")
  precondition(stranded.notice != ResidentPropEditorSnapshot.supportDerivingText,
    "a click the host cannot answer must not be reported as \"still deriving\"")

  // 同一个"陈旧快照"，但宿主**答得出来**：现状是"有一次派生真的在跑、承托面还没出来" ——
  // 这时候说"格子还在生成，请稍候"才是诚实的（与上一条互斥，必须是两个不同的结果）。
  let honestlyDeriving = ResidentPropEditorState()
  honestlyDeriving.update(driftingRow);honestlyDeriving.open()
  honestlyDeriving.preview = { _, p in WorldObjectState(transform:.init(position:p.position,rotation:identity.rotation,scale:identity.scale),metadata:metadata) }
  honestlyDeriving.refreshSnapshot = { ResidentPropEditorSnapshot(worldID:"a",revision:3,objects:[object],surfaces:[],canUndo:false,heldProp:nil,
    holdUnavailableReasons:[:],supportGeometryUnavailable:false) }
  await honestlyDeriving.select(objectID:"cup")
  precondition(honestlyDeriving.notice == ResidentPropEditorSnapshot.supportDerivingText,
    "with a derivation genuinely in flight the panel must say \"still generating\" (got \"\(honestlyDeriving.notice)\")")

  // 宿主答得出来的另一种现状：格子**派生结束但一无所获**（空网格 = 真机 fail-closed 的
  // `PropSupportGrid.empty`）—— 不会好了，就必须说"拿不到"，一个字都不许说"请稍候"。
  let derivedNothing = ResidentPropEditorState()
  derivedNothing.update(.init(worldID:"a",revision:3,objects:[object],surfaces:[],canUndo:false,heldProp:nil,
    holdUnavailableReasons:[:],supportGeometryUnavailable:true))
  derivedNothing.open()
  derivedNothing.refreshSnapshot = { ResidentPropEditorSnapshot(worldID:"a",revision:3,objects:[object],surfaces:[],canUndo:false,heldProp:nil,
    holdUnavailableReasons:[:],supportGeometryUnavailable:true) }
  await derivedNothing.select(objectID:"cup")
  precondition(derivedNothing.notice == ResidentPropEditorSnapshot.supportUnavailableText,
    "a derivation that finished with nothing must never be reported as \"still generating\" (got \"\(derivedNothing.notice)\")")

  // 「提示必须与事实一致」也包括**事实变了、提示得跟着变**：承托面到了以后，面板上不许
  // 还挂着"格子还在生成"（真机截图里那句就是挂在已经就绪的格子上）。
  let noticeFollowsFact = ResidentPropEditorState()
  noticeFollowsFact.update(driftingRow);noticeFollowsFact.open()
  noticeFollowsFact.refreshSnapshot = { ResidentPropEditorSnapshot(worldID:"a",revision:3,objects:[object],surfaces:[],canUndo:false,heldProp:nil,
    holdUnavailableReasons:[:],supportGeometryUnavailable:false) }
  await noticeFollowsFact.select(objectID:"cup")
  precondition(noticeFollowsFact.notice == ResidentPropEditorSnapshot.supportDerivingText,
    "precondition: the panel first reports a derivation in flight")
  noticeFollowsFact.update(.init(worldID:"a",revision:3,objects:[object],surfaces:[surface],canUndo:false,heldProp:nil,
    holdUnavailableReasons:[:],supportGeometryUnavailable:false))
  precondition(noticeFollowsFact.notice == ResidentPropEditorState.supportReadyText,
    "once the surfaces arrive the stale \"not ready\" notice must be replaced (got \"\(noticeFollowsFact.notice)\")")

  // 同一个"陈旧快照"，但宿主能答出**现状**：格子已经就绪 → 点一行必须进携带态。
  let catchingUp = ResidentPropEditorState()
  catchingUp.update(driftingRow);catchingUp.open()
  catchingUp.preview = { _, p in WorldObjectState(transform:.init(position:p.position,rotation:identity.rotation,scale:identity.scale),metadata:metadata) }
  catchingUp.refreshSnapshot = { ResidentPropEditorSnapshot(worldID:"a",revision:3,objects:[object],surfaces:[surface],canUndo:false,heldProp:nil,
    holdUnavailableReasons:[:],supportGeometryUnavailable:false) }
  await catchingUp.select(objectID:"cup")
  precondition(catchingUp.selectedID == "cup" && catchingUp.placement?.surfaceID == "floor",
    "a click must enter the carrying state once the grid is ready, without waiting for the next push")
  precondition(catchingUp.candidate != nil && !catchingUp.snapshot.surfaces.isEmpty,
    "the carrying state must be backed by the fresh support surfaces")

  // 一份"永远拿不到几何"的陈旧快照 + **宿主完全答不出来**（没有接线）：不许说"还在生成"，
  // 也不许把手里那份陈旧快照的说法当成现状 —— 这次点击确实没拿到当前状态，如实说这一句。
  let hopeless = ResidentPropEditorState()
  hopeless.update(.init(worldID:"a",revision:3,objects:[object],surfaces:[],canUndo:false,heldProp:nil,
    holdUnavailableReasons:[:],supportGeometryUnavailable:true))
  hopeless.open()
  await hopeless.select(objectID:"cup")
  precondition(hopeless.notice == ResidentPropEditorState.supportSessionUnavailableText,
    "a click the host cannot answer must not be reported as a stale fact (got \"\(hopeless.notice)\")")
  precondition(hopeless.notice != ResidentPropEditorSnapshot.supportDerivingText,
    "geometry that will never arrive must not tell the resident to wait (got \"\(hopeless.notice)\")")
  // 同样一份陈旧快照，但**宿主答得出来**且答的就是"拿不到"：照实转述宿主那句话。
  let hopelessButAnswered = ResidentPropEditorState()
  hopelessButAnswered.update(.init(worldID:"a",revision:3,objects:[object],surfaces:[],canUndo:false,heldProp:nil,
    holdUnavailableReasons:[:],supportGeometryUnavailable:true))
  hopelessButAnswered.open()
  hopelessButAnswered.refreshSnapshot = { ResidentPropEditorSnapshot(worldID:"a",revision:3,objects:[object],surfaces:[],
    canUndo:false,heldProp:nil,holdUnavailableReasons:[:],supportGeometryUnavailable:true) }
  await hopelessButAnswered.select(objectID:"cup")
  precondition(hopelessButAnswered.notice == ResidentPropEditorSnapshot.supportUnavailableText,
    "when the host answers \"never\" the panel must repeat that, not the session message (got \"\(hopelessButAnswered.notice)\")")

  // 根因的前提必须由**真实现**证明：`PropSupportGridBuilder.build` 的 fail-closed 失败
  // **不是 nil 网格**，而是一个"层为空的网格"。真机那句"永远还在生成"就活在这一格上：
  // 模型会把它当成 `isReady`，而面板一个承托面都拿不到。
  let emptyRegionBounds = WorldPlanarBounds(minimumX:500, maximumX:501, minimumZ:500, maximumZ:501)
  let builderEmptyGrid = PropSupportGridBuilder.build(
    collision: FlatFloorCollision(half:1.5),
    bounds: emptyRegionBounds,
    seed: WorldVector3(x:500.5, y:0, z:500.5))
  precondition(builderEmptyGrid.layers.isEmpty,
    "a region with no usable geometry must derive a grid with no layers")
  precondition(!builderEmptyGrid.report.seeded,
    "that grid must report that it never found a seed layer")
  precondition(ResidentPropSupportReadiness.resolve(hasSurfaces:!builderEmptyGrid.layers.isEmpty,
      isDeriving:false).supportGeometryUnavailable,
    "the real builder's empty grid must be reported as unavailable, not as still deriving")

  // 「还会不会好」的唯一判据：**有承托面** 或 **确实有一次派生在跑**。空网格（`grid != nil`
  // 但一层都没有）是最会骗人的一格：旧代码只看 `grid != nil`，于是它被当成"就绪"，
  // 面板永远说"还在生成"、那一行永远点不动。下面把三态逐项钉死（真代码，不 stub 判据）。
  precondition(ResidentPropSupportReadiness.resolve(hasSurfaces:true, isDeriving:false) == .ready,
    "surfaces mean ready, even while a derivation happens to be running")
  precondition(ResidentPropSupportReadiness.resolve(hasSurfaces:false, isDeriving:true) == .deriving,
    "no surfaces with a live derivation is the only \"still deriving\" case")
  precondition(ResidentPropSupportReadiness.resolve(hasSurfaces:false, isDeriving:false) == .unavailable,
    "no surfaces and no live derivation means the geometry is not coming: say so")
  precondition(!ResidentPropSupportReadiness.resolve(hasSurfaces:true, isDeriving:true).supportGeometryUnavailable,
    "a ready grid must never be reported as unavailable")
  precondition(ResidentPropSupportReadiness.resolve(hasSurfaces:false, isDeriving:false).supportGeometryUnavailable,
    "an empty finished grid must be reported as unavailable, not as deriving")

  // 会话自救的判据：面板开着、世界也对，但宿主的装修会话不在（或属于别的世界）时，
  // 这次点击必须先重接会话 —— 否则"格子已就绪却点不动"会永远粘住。
  precondition(ResidentPropDecorationSessionRearm.shouldRearm(hasSession:false, sessionWorldID:nil, worldID:"a"),
    "a missing decoration session must be re-armed before answering a click")
  precondition(ResidentPropDecorationSessionRearm.shouldRearm(hasSession:true, sessionWorldID:"b", worldID:"a"),
    "a decoration session for another world must be re-armed")
  precondition(!ResidentPropDecorationSessionRearm.shouldRearm(hasSession:true, sessionWorldID:"a", worldID:"a"),
    "a live session for the same world must be left alone")

  // 根因：**格子就绪**必须触发一次面板快照的重新投影。这一段驱动的是 App 里被抽取出来的
  // `publishResidentPropGrid`（真代码），只有"格子模型怎么变"和"快照怎么算"是替身。
  let wiringHost = AppGuardHarness(), wiringController = ControllerHarness()
  wiringHost.livingWorldContext = context
  wiringHost.surfaces = [surface]
  wiringHost.stageWindowController = wiringController
  wiringHost.configureResidentPropEditor(wiringController)
  wiringHost.residentPropGridDerivation = UUID()   // 有一次派生真的在跑，格子还没出来
  wiringHost.publishResidentPropGrid()
  wiringController.residentPropEditor.open()
  precondition(wiringController.residentPropEditor.snapshot.surfaces.isEmpty,
    "the panel sees no support surface while the grid is still deriving")
  wiringHost.residentPropGridEditor.becomeReady()          // 派生完成：渲染层这一刻才有格子
  wiringHost.publishResidentPropGrid()
  precondition(!wiringController.residentPropEditor.snapshot.surfaces.isEmpty,
    "grid readiness must re-project the panel snapshot (otherwise every row click is swallowed silently)")
  await wiringController.residentPropEditor.select(objectID:"cup")
  precondition(wiringController.residentPropEditor.selectedID == "cup",
    "after the grid is ready a row click must enter the carrying state")

  // 派生**结束**必须让令牌失效（无论它有没有产出）。这一条钉住"请求过 ≠ 还在生成"：
  // 真机上"没有任何派生在跑"却一直说"还在生成"，就是令牌没随任务收回。
  let tokenHost = AppGuardHarness(), tokenController = ControllerHarness()
  tokenHost.livingWorldContext = context
  tokenHost.surfaces = [surface]
  tokenHost.stageWindowController = tokenController
  tokenHost.configureResidentPropEditor(tokenController)
  let derivationToken = UUID()
  tokenHost.residentPropGridDerivation = derivationToken
  tokenHost.publishResidentPropGrid()
  tokenController.residentPropEditor.open()
  precondition(tokenHost.residentPropEditorSnapshot(context:context).supportGeometryUnavailable == false,
    "precondition: while a derivation is in flight the snapshot must not claim to be stuck")
  tokenHost.finishResidentPropGridDerivation(derivationToken)   // 派生结束：什么都没产出
  precondition(tokenHost.residentPropGridDerivation == nil,
    "a finished derivation must revoke its token, otherwise the panel says \"still generating\" forever")
  precondition(tokenHost.residentPropEditorSnapshot(context:context).supportGeometryUnavailable,
    "a finished derivation with no support surfaces must be reported as unavailable")
  await tokenController.residentPropEditor.select(objectID:"cup")
  precondition(tokenController.residentPropEditor.notice == ResidentPropEditorSnapshot.supportUnavailableText,
    "a row click after a fruitless derivation must say \"cannot get the geometry\", never \"please wait\" (got \"\(tokenController.residentPropEditor.notice)\")")

  // 空网格（真机 `PropSupportGrid.empty`：`isReady` 为真、一层承托面都没有）不许被当成"就绪"。
  let emptyGridHost = AppGuardHarness(), emptyGridController = ControllerHarness()
  emptyGridHost.livingWorldContext = context
  emptyGridHost.surfaces = [surface]
  emptyGridHost.stageWindowController = emptyGridController
  emptyGridHost.configureResidentPropEditor(emptyGridController)
  emptyGridHost.residentPropGridEditor.becomeReadyEmpty()
  emptyGridHost.publishResidentPropGrid()
  emptyGridController.residentPropEditor.open()
  precondition(emptyGridController.residentPropEditor.snapshot.surfaces.isEmpty,
    "an empty grid yields no support surfaces")
  precondition(emptyGridHost.residentPropEditorSnapshot(context:context).supportGeometryUnavailable,
    "an empty (finished) grid is not a ready grid: it must say the geometry is unavailable")
  await emptyGridController.residentPropEditor.select(objectID:"cup")
  precondition(emptyGridController.residentPropEditor.notice != ResidentPropEditorSnapshot.supportDerivingText,
    "an empty grid must never leave the panel saying \"still generating\" (got \"\(emptyGridController.residentPropEditor.notice)\")")

  // **推失败不能把相位记成"已推"**：世界切换的那一刻推不出去，如果照样记下来，
  // 相位之后不再变化，面板就永远收不到那一份 —— 格子早好了，面板还停在"派生中"。
  let retryHost = AppGuardHarness(), retryController = ControllerHarness()
  retryHost.livingWorldContext = context
  retryHost.surfaces = [surface]
  retryHost.stageWindowController = retryController
  retryHost.configureResidentPropEditor(retryController)
  retryHost.residentPropGridEditor.becomeReady()
  retryHost.spatialStage.selectedWorldID = "other"     // 世界还没切回来：这一次推不出去
  retryHost.publishResidentPropGrid()
  precondition(retryController.residentPropEditor.snapshot.surfaces.isEmpty,
    "a push while the world is not current must not reach the panel")
  retryHost.spatialStage.selectedWorldID = "a"         // 世界切回来了
  retryHost.publishResidentPropGrid()
  precondition(!retryController.residentPropEditor.snapshot.surfaces.isEmpty,
    "a skipped push must stay unpublished so the next publish retries and the panel catches up")
  retryController.residentPropEditor.open()
  await retryController.residentPropEditor.select(objectID:"cup")
  precondition(retryController.residentPropEditor.selectedID == "cup",
    "after the retry the row click must enter the carrying state")

  // ─────────────────────────────────────────────────────────────────────────────
  // 任务 1：在场景里直接拿起已摆出的物件。
  //
  // (a) 分流规则只有一份（`ResidentPropSceneClick`）。下面这几条钉住"谁赢"：
  //     空手单击已摆物件 → 拾取；手上有物件 → 放下（绝不是重新拾取）；
  //     编辑器没打开（或格子没激活）→ 什么也不做；双击 → 不拾取。
  precondition(ResidentPropSceneClick.resolve(isEditorOpen:true,isBuildModeActive:true,isCarrying:false,
      clickCount:1,hitObjectID:"cup") == .pickUp("cup"),
    "an empty-handed click on a placed prop must pick that prop up")
  precondition(ResidentPropSceneClick.resolve(isEditorOpen:true,isBuildModeActive:true,isCarrying:true,
      clickCount:1,hitObjectID:"other") == .dropAtGrid,
    "a click while carrying must drop, never re-pick another prop")
  precondition(ResidentPropSceneClick.resolve(isEditorOpen:false,isBuildModeActive:true,isCarrying:false,
      clickCount:1,hitObjectID:"cup") == .none,
    "with the editor closed a scene click has no effect at all")
  precondition(ResidentPropSceneClick.resolve(isEditorOpen:true,isBuildModeActive:false,isCarrying:false,
      clickCount:1,hitObjectID:"cup") == .none,
    "without the build grid a scene click has no effect at all")
  precondition(ResidentPropSceneClick.resolve(isEditorOpen:true,isBuildModeActive:true,isCarrying:false,
      clickCount:1,hitObjectID:nil) == .none,
    "an empty-handed click on empty ground has no effect")
  precondition(ResidentPropSceneClick.resolve(isEditorOpen:true,isBuildModeActive:true,isCarrying:false,
      clickCount:2,hitObjectID:"cup") == .none,
    "a double click never picks a prop up (that gesture stays the camera reset)")
  // 双击的第二下：把刚在场景里拾起的那一下**撤回原位** + 复位相机（净效果 = 不拾取）。
  // 面板点行拾起的那件不受影响（`carryingStartedAtScenePointer == false`）。
  precondition(ResidentPropSceneClick.resolvePress(isEditorOpen:true,isBuildModeActive:true,
      carryingStartedAtScenePointer:true,clickCount:2) == .reclaimPickUpAndResetCamera,
    "the second click of a scene double click must put back what the first click picked up")
  precondition(ResidentPropSceneClick.resolvePress(isEditorOpen:true,isBuildModeActive:true,
      carryingStartedAtScenePointer:false,clickCount:2) == .none,
    "a panel row pick is not reclaimed by a scene double click")
  precondition(ResidentPropSceneClick.resolvePress(isEditorOpen:true,isBuildModeActive:true,
      carryingStartedAtScenePointer:true,clickCount:1) == .none,
    "a single press never reclaims a pick-up")
  precondition(ResidentPropSceneClick.resolvePress(isEditorOpen:false,isBuildModeActive:true,
      carryingStartedAtScenePointer:true,clickCount:2) == .none,
    "a double click with the editor closed does nothing")

  // (b) "点已摆物件 → 进携带态，而且 placement 取自**该物件自己的 transform**"。
  //     物件的落点刻意**不等于**任何承托面的中心：旧实现若退回 `support.position`，
  //     下面前两条立刻失败。
  let placedAt = WorldVector3(x:2,y:0.5,z:1)
  var placedMetadata = metadata
  placedMetadata["gmgn.support-surface.v1"] = "table"
  let placedObject = WorldObjectState(
    transform:.init(position:placedAt,rotation:identity.rotation,scale:identity.scale),
    metadata:placedMetadata)
  let placedSnapshot = ResidentPropEditorSnapshot(worldID:"a",revision:3,objects:[placedObject],
    surfaces:[.init(id:"floor",name:"地面",position:zero,cellCount:1),
              .init(id:"table",name:"台面 0.50 m",position:.init(x:-3,y:0.5,z:-3),cellCount:8)],
    canUndo:false)
  let scenePick = ResidentPropEditorState()
  scenePick.update(placedSnapshot);scenePick.open()
  var scenePickPreviews = 0
  scenePick.preview = { _, _ in scenePickPreviews += 1; return placedObject }
  await scenePick.select(objectID:"cup")
  precondition(scenePick.isCarrying,"clicking a placed prop enters the carrying state")
  precondition(scenePick.placement?.surfaceID == "table",
    "a placed prop keeps its own support surface (got \(scenePick.placement?.surfaceID ?? "nil"))")
  precondition(scenePick.placement?.position.x == placedAt.x && scenePick.placement?.position.z == placedAt.z,
    "a placed prop's carrying placement comes from its own transform, not from the support surface's centre")
  precondition(scenePick.candidate != nil && scenePickPreviews == 1,
    "the carrying state previews the prop at its own transform (previews=\(scenePickPreviews))")

  // (c) 悬停发光：光标移到已摆物件上 → **它的 footprint 格子**进入 `.hoverTarget`，
  //     并且这批格子自动成为焦点裁剪的锚点（patch 恰好是 footprint + 两圈，没有更远的列）。
  let gridModel = ResidentPropGridEditorModel()
  let flatFloor = FlatFloorCollision(half:1.5)
  await gridModel.activate(collision:flatFloor,seed:.init(x:0,y:0,z:0),
    bounds:.init(minimumX:-1.5,maximumX:1.5,minimumZ:-1.5,maximumZ:1.5),key:"harness")
  precondition(gridModel.isBuildModeActive && gridModel.isReady,"the flat floor derives a support grid")
  precondition(!gridModel.renderCells.isEmpty,"the flat floor derives cells")
  gridModel.setHoveredProp(objectID:"lamp",volume:.init(id:"lamp",
    center:.init(x:0.125,y:0.2,z:0.125),halfExtents:.init(x:0.2,y:0.2,z:0.2),
    rotation:.init(x:0,y:0,z:0,w:1),isBlocking:true))
  precondition(gridModel.hoveredPropID == "lamp","hovering a placed prop records which prop it is")
  let glowing = gridModel.cellStates.filter { $0.value == .hoverTarget }.keys
  let glowingColumns = Set(glowing.map { "\($0.columnX),\($0.columnZ)" })
  precondition(glowingColumns == Set(["0,0","1,0","0,1","1,1"]),
    "hovering a placed prop lights exactly its 2x2 footprint cells (got \(glowingColumns.sorted()))")
  precondition(glowing.allSatisfy { abs($0.supportHeight) < 0.0001 },
    "the glow stays on the prop's own support height")
  let glowPatch = PropSupportGridPresentation.focusedInstances(
    cells:gridModel.renderCells,states:gridModel.cellStates,
    cameraPosition:SIMD3(0,5,0),spacing:gridModel.spacing)
  precondition(glowPatch.filter { $0.state == .hoverTarget }.count == 4,
    "all four hovered footprint cells are inside the drawn patch")
  precondition(glowPatch.filter { $0.state == .hoverTarget }.allSatisfy { abs($0.alpha - 1) < 0.00001 },
    "the hovered footprint is the high-contrast part of the patch, not part of the faint ring")
  let glowPatchColumns = Set(glowPatch.map { Int(((($0.center.x - 0.125) / gridModel.spacing)).rounded()) })
  precondition(glowPatchColumns == Set(-2...3),
    "the glow goes through the focus clip: exactly the footprint columns expanded by the ring count (got \(glowPatchColumns.sorted()))")
  precondition(glowPatch.count < gridModel.renderCells.count,
    "the glow must not flood the floor (drew \(glowPatch.count) of \(gridModel.renderCells.count) cells)")
  gridModel.clearHoveredProp()
  precondition(gridModel.hoveredPropID == nil && !gridModel.cellStates.values.contains(.hoverTarget),
    "moving the cursor off the prop turns the glow off")

  // ─────────────────────────────────────────────────────────────────────────────
  // 任务 2：**还没摆出来**的物件的初始落点必须是"真的能放"的那一格。
  //
  // 旧行为：固定退到 `snapshot.surfaces.first.position`（最低层里列序最小的格）。真实生活舱实测
  // 那一格被活动通道挡住（"这里会挡住活动入口或通道：wp.auto.x-4.z-6.h0"），于是勾和控件都出现了、
  // footprint 却是红的，直到鼠标动一下才对。真实舱体那一侧的验收在
  // `tools/test-resident-prop-grid-placement.swift`；这里钉住状态机本身的行为。
  let blockedAnchor = WorldVector3(x:0,y:0,z:0)
  let freeAnchor = WorldVector3(x:2,y:0.5,z:0)
  let rookie = WorldGeneratedProp(objectID:"rookie",sourceWishID:"rookie",assetID:"rookie-asset",
    displayName:"新物件",size:.init(x:0.2,y:0.2,z:0.2),sourceHeight:1)
  let rookieMetadata = ["gmgn.generated-prop.v1":String(data:try JSONEncoder().encode(rookie),encoding:.utf8)!]
  let rookieObject = WorldObjectState(isEnabled:false,transform:identity,metadata:rookieMetadata)
  let rookieSnapshot = ResidentPropEditorSnapshot(worldID:"a",revision:3,objects:[rookieObject],
    surfaces:[.init(id:"floor",name:"地面",position:blockedAnchor,cellCount:1,candidateAnchors:[blockedAnchor]),
              .init(id:"table",name:"台面 0.50 m",position:freeAnchor,cellCount:8,candidateAnchors:[freeAnchor])],
    canUndo:false)
  let picking = ResidentPropEditorState()
  picking.update(rookieSnapshot);picking.open()
  var pickOrder:[Float] = []
  picking.preview = { _, p in
    pickOrder.append(p.position.x)
    guard p.position.x == freeAnchor.x else {
      throw NSError(domain:"test",code:2,
        userInfo:[NSLocalizedDescriptionKey:"这里会挡住活动入口或通道：wp.auto.x-4.z-6.h0。"])
    }
    return rookieObject
  }
  await picking.select(objectID:"rookie")
  precondition(picking.candidate != nil && picking.placement?.surfaceID == "table",
    "a prop that is not placed yet must start on the first *placeable* candidate, not on the lowest layer's minimum-column cell (surface=\(picking.placement?.surfaceID ?? "nil"), notice=\(picking.notice))")
  precondition(picking.isCarrying,"the initial landing spot still enters the carrying state")
  // 顺序：**最平整的承托面**（格子多的那张台面）先试，而且它的第一个候选就可放 ——
  // 全程没有碰过被挡的最低层那一格。第二个 preview 是 `validate` 给赢家取的正式预览。
  precondition(pickOrder == [freeAnchor.x,freeAnchor.x],
    "the widest flat support surface is tried first and the first placeable candidate wins (order=\(pickOrder))")

  // 试遍候选都不可放：**保持现状**（退回这一层的默认落点）并且**明说**，不假装成功。
  let hopelessRookie = ResidentPropEditorState()
  hopelessRookie.update(rookieSnapshot);hopelessRookie.open()
  hopelessRookie.preview = { _, _ in
    throw NSError(domain:"test",code:3,userInfo:[NSLocalizedDescriptionKey:"这里会挡住活动入口或通道：wp.center。"])
  }
  await hopelessRookie.select(objectID:"rookie")
  precondition(hopelessRookie.placement?.surfaceID == "floor"
      && hopelessRookie.placement?.position.x == blockedAnchor.x,
    "when no candidate can be placed we keep the old default landing spot")
  precondition(hopelessRookie.candidate == nil
      && hopelessRookie.notice.hasPrefix("这里没有找到能放下它的位置："),
    "when no candidate can be placed we must say so, not pretend it worked (got \"\(hopelessRookie.notice)\")")

  // 主线程预算：候选再多也只试有上限的几次（真实舱体一次 preview 5–13 ms）。
  let manySurfaces = (0..<40).map { index in
    ResidentPropEditorSurface(id:"s\(index)",name:"层 \(index)",position:.init(x:Float(index),y:0,z:0),
      cellCount:40 - index,candidateAnchors:(0..<8).map { .init(x:Float(index),y:0,z:Float($0)) })
  }
  let capped = ResidentPropEditorState()
  capped.update(.init(worldID:"a",revision:3,objects:[rookieObject],surfaces:manySurfaces,canUndo:false))
  capped.open()
  var cappedAttempts = 0
  capped.preview = { _, _ in
    cappedAttempts += 1
    throw NSError(domain:"test",code:4,userInfo:[NSLocalizedDescriptionKey:"放不下"])
  }
  await capped.select(objectID:"rookie")
  precondition(cappedAttempts <= ResidentPropEditorState.initialPlacementAttemptLimit + 1,
    "the initial-placement search is bounded (tried \(cappedAttempts))")
  precondition(capped.placement?.surfaceID == "s0","the fallback keeps the object's own support surface")

  // 已摆出的物件必须继续用自身 transform —— 上面 (b) 已经钉住；这里再钉住"没承托面时仍然
  // 进不了携带态"的 fail-closed 行为没有被初始落点这条路绕过去。
  precondition(ResidentPropInitialPlacement.fillingAnchors(rookieSnapshot.surfaces,grid:nil,
      spawn:zero).allSatisfy { $0.candidateAnchors.count <= 8 },
    "without a grid the surface candidates stay empty instead of being invented")

  // ─────────────────────────────────────────────────────────────────────────────
  // 2026-09-28 阻塞缺陷（真机确诊）：**窗口失焦把装修会话杀掉了**。
  //
  // 用户只是「打开装修 → 点了一下物件那一行 → 切到别的窗口跟我说话」，装修在打开 4.4 s 后
  // 自己退出了，而 Debug 构建下一次派生要 4.8 s ⇒ 派生每次都被掐死、结果被丢弃，于是面板
  // 永远说"格子还在生成"、那一行永远点不动。下面把"失焦不关装修、不打断派生"钉在**真源码**上：
  // `windowDidResignKey` 是从 `StageWindowController` 里原样抽出来编译的（不是替身），
  // 接线也照抄真机（会话关闭 ⇒ 停用格子 + 收回派生令牌）。
  let focusHarness = DecorationFocusHarness()
  await focusHarness.beginDecoration(worldID:"focus-world")
  precondition(focusHarness.residentPropEditor.isOpen,
    "precondition: opening decoration opens the editor")
  precondition(focusHarness.residentPropGridEditor.isBuildModeActive && focusHarness.residentPropGridEditor.isReady,
    "precondition: opening decoration derives the grid")
  // 切到别的窗口去说话 —— 真机就是这一步把装修杀掉的。
  focusHarness.windowDidResignKey(Notification(name:Notification.Name("NSWindowDidResignKeyNotification")))
  precondition(focusHarness.residentPropEditor.isOpen,
    "losing window focus must not close the decoration editor")
  precondition(focusHarness.residentPropGridEditor.isBuildModeActive,
    "losing window focus must not end the decoration session")
  precondition(focusHarness.residentPropGridEditor.isReady && !focusHarness.residentPropGridEditor.renderCells.isEmpty,
    "losing window focus must not discard the derived grid")
  precondition(focusHarness.residentPropGridDerivation == nil,
    "losing window focus must not touch the derivation token")
  // 切回来：控制器里没有 `windowDidBecomeKey` 的补偿逻辑（结构性断言见
  // `test-stage-resident-chat.swift`），所以这一趟往返对会话什么也没做。
  precondition(focusHarness.residentPropEditor.isOpen && focusHarness.residentPropGridEditor.isReady,
    "the editor and its derived grid must survive a window focus round trip")

  // 派生**正在进行中**失焦：不许被掐死，也不许结果被丢弃（真机上 4.8 s 就是这么被掐掉的）。
  let inflightCollision = CountingFloorCollision(half:1.5,sleepSeconds:0.05)
  let inflightHarness = DecorationFocusHarness()
  let inflightTask = Task { await inflightHarness.beginDecoration(worldID:"focus-inflight",collision:inflightCollision) }
  for _ in 0..<100_000 { if inflightCollision.queryCount > 0 { break };await Task.yield() }
  precondition(inflightCollision.queryCount > 0,
    "precondition: the in-flight derivation really started asking the geometry")
  precondition(inflightHarness.residentPropGridEditor.isBuildModeActive && !inflightHarness.residentPropGridEditor.isReady,
    "precondition: the derivation is still in flight")
  inflightHarness.windowDidResignKey(Notification(name:Notification.Name("NSWindowDidResignKeyNotification")))
  await inflightTask.value
  precondition(inflightHarness.residentPropEditor.isOpen && inflightHarness.residentPropGridEditor.isBuildModeActive
      && inflightHarness.residentPropGridEditor.isReady,
    "losing window focus mid-derivation must neither kill the session nor drop the finished grid")

  // ─────────────────────────────────────────────────────────────────────────────
  // 按世界缓存：**同一世界第二次进入装修复用缓存网格，不重新派生**（行为断言）。
  //
  // 判据是"几何还被问过没有"：第二次进入必须**一次都不问** —— 只断言"模型里有个字典"不够。
  let flatBounds = WorldPlanarBounds(minimumX:-1.5,maximumX:1.5,minimumZ:-1.5,maximumZ:1.5)
  let cacheCollision = CountingFloorCollision(half:1.5)
  let cachedModel = ResidentPropGridEditorModel()
  await cachedModel.activate(collision:cacheCollision,seed:.init(x:0,y:0,z:0),bounds:flatBounds,key:"cache-world")
  precondition(cachedModel.isReady && !cachedModel.renderCells.isEmpty,
    "precondition: the first entry derives a grid")
  let queriesAfterFirstEntry = cacheCollision.queryCount
  precondition(queriesAfterFirstEntry > 0,
    "precondition: the first derivation really asked the geometry (queries=\(queriesAfterFirstEntry))")
  cachedModel.deactivate()
  precondition(!cachedModel.isBuildModeActive && !cachedModel.isReady && cachedModel.renderCells.isEmpty
      && cachedModel.cellStates.isEmpty && cachedModel.supportCollision == nil,
    "deactivate must clear the active state (build mode, grid, cells, colouring, collision)")
  await cachedModel.activate(collision:cacheCollision,seed:.init(x:0,y:0,z:0),bounds:flatBounds,key:"cache-world")
  precondition(cachedModel.isReady,"re-entering the same world must be ready immediately")
  precondition(cacheCollision.queryCount == queriesAfterFirstEntry,
    "re-entering the same world must reuse the cached grid instead of deriving it again (queries \(queriesAfterFirstEntry) → \(cacheCollision.queryCount))")
  precondition(!cachedModel.renderCells.isEmpty,
    "the cached grid must be re-projected into cells on re-entry")

  // 派生**进行中**用户明确关掉面板（X / Esc）：结果一样不许丢，下次进来直接复用。
  let interruptedCollision = CountingFloorCollision(half:1.5,sleepSeconds:0.05)
  let interruptedModel = ResidentPropGridEditorModel()
  let interruptedTask = Task { await interruptedModel.activate(collision:interruptedCollision,
    seed:.init(x:0,y:0,z:0),bounds:flatBounds,key:"interrupted-world") }
  for _ in 0..<100_000 { if interruptedCollision.queryCount > 0 { break };await Task.yield() }
  precondition(interruptedCollision.queryCount > 0,"precondition: the interrupted derivation really started")
  interruptedModel.deactivate()
  await interruptedTask.value
  precondition(!interruptedModel.isBuildModeActive,"an explicit close must leave the build mode off")
  let queriesAfterInterrupted = interruptedCollision.queryCount
  await interruptedModel.activate(collision:interruptedCollision,seed:.init(x:0,y:0,z:0),bounds:flatBounds,
    key:"interrupted-world")
  precondition(interruptedModel.isReady,
    "a derivation that finished while the panel was closed must still be reused on the next entry")
  precondition(interruptedCollision.queryCount == queriesAfterInterrupted,
    "closing the panel must not throw away a derivation that already finished (queries \(queriesAfterInterrupted) → \(interruptedCollision.queryCount))")

  // 缓存必须有**上界**：换世界不会让网格无限增长；被淘汰的世界重进要重新派生，仍在缓存里的则复用。
  let boundedCollision = CountingFloorCollision(half:1.5)
  let boundedModel = ResidentPropGridEditorModel()
  for key in ["bound-a","bound-b","bound-c"] {
    await boundedModel.activate(collision:boundedCollision,seed:.init(x:0,y:0,z:0),bounds:flatBounds,key:key)
    boundedModel.deactivate()
  }
  precondition(boundedModel.retainedGridCount == ResidentPropGridEditorModel.retainedGridLimit,
    "the grid cache must stay bounded (\(boundedModel.retainedGridCount) retained, limit \(ResidentPropGridEditorModel.retainedGridLimit))")
  let queriesAfterThreeWorlds = boundedCollision.queryCount
  await boundedModel.activate(collision:boundedCollision,seed:.init(x:0,y:0,z:0),bounds:flatBounds,key:"bound-c")
  precondition(boundedCollision.queryCount == queriesAfterThreeWorlds,
    "the most recently used world must still be cached")
  await boundedModel.activate(collision:boundedCollision,seed:.init(x:0,y:0,z:0),bounds:flatBounds,key:"bound-a")
  precondition(boundedCollision.queryCount > queriesAfterThreeWorlds,
    "the evicted world must derive again (the cache is bounded, not a leak)")

  print("PASS: editor cancel, failure preservation, hand controls, duplicate submit, stale revision, late world, input routing, ready-grid row click, host-cannot-answer vs host-says-empty, empty-grid and dead-derivation honesty, stale notice refresh, skipped-push retry, scene pick-up routing, placed-prop transform, hover glow inside the focus clip, the placeable initial landing spot, window focus loss preserving the decoration session and its derivation, and same-world grid reuse from a bounded cache")
 }
}
"""#
let temp = FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-prop-editor-\(UUID().uuidString)")
try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
let source = temp.appendingPathComponent("test.swift"), binary = temp.appendingPathComponent("test")
try harness.write(to:source,atomically:true,encoding:.utf8)
let products = root.appendingPathComponent("apps/macos/Packages/WorldRuntime/.build/arm64-apple-macosx/debug")
let objects = try FileManager.default.contentsOfDirectory(at:products.appendingPathComponent("WorldRuntime.build"),includingPropertiesForKeys:nil).filter { $0.path.hasSuffix(".swift.o") }.map(\.path)
let compile = Process(); compile.executableURL = URL(fileURLWithPath:"/usr/bin/xcrun")
compile.arguments = ["swiftc","-j1","-parse-as-library","-swift-version","6","-I",products.appendingPathComponent("Modules").path,source.path,"-o",binary.path] + objects
try compile.run();compile.waitUntilExit();guard compile.terminationStatus == 0 else { exit(compile.terminationStatus) }
if !CommandLine.arguments.contains("--red-double-submit") {
 let viewCheck = Process();viewCheck.executableURL = URL(fileURLWithPath:"/usr/bin/xcrun")
 viewCheck.arguments = ["swiftc","-j1","-typecheck","-swift-version","6","-I",products.appendingPathComponent("Modules").path,modelURL.path,root.appendingPathComponent("apps/macos/Sources/GMGNRadio/VisualEngine/ResidentPropEditorView.swift").path]
 try viewCheck.run();viewCheck.waitUntilExit();guard viewCheck.terminationStatus == 0 else { exit(viewCheck.terminationStatus) }
}
let run = Process();run.executableURL = binary;try run.run();run.waitUntilExit();exit(run.terminationStatus)

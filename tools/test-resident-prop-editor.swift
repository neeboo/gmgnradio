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
let harness = #"""
import Foundation
import Combine
import simd
import WorldRuntime
func precondition(_ condition:@autoclosure()->Bool,_ message:String="assertion failed") {
 if !condition() { print("FAIL: \(message)"); exit(1) }
}
\#(model.replacingOccurrences(of: "import WorldRuntime", with: ""))
@MainActor final class ControllerHarness {
 let residentPropEditor = ResidentPropEditorState()
 \#(method("func configureResidentPropEditor("))
 \#(method("func updateResidentPropEditor("))
 /// 格子点击落地那条路径的入口。本 harness 不驱动它（`snappedPlacement` 恒为 nil），
 /// 只要求被抽取的 `publishResidentPropGrid` 能编过。
 func moveResidentPropGridPointer(to position:WorldVector3,layerName:String,yaw:Float) async {}
}
/// 建造模式格子模型的替身：只保留 `publishResidentPropGrid` 读的那几个事实，
/// 但**"就绪是异步的"这个时序**照旧（`isReady` 不会在请求的那一刻就为真）。
@MainActor final class GridStub {
 var isBuildModeActive = false
 var isReady = false
 var spacing:Float = 0.25
 var renderCells:[Int] = []
 var cellStates:[Int:Int] = [:]
 var snappedPlacement:(position:SIMD3<Float>,yaw:Float)?
 var hoveredLayerName:String?
 /// 派生完成：这一刻起渲染层才有格子可画（与真机 `residentPropGridEditor` 同一时序）。
 func becomeReady(cells:Int = 4) {
  isBuildModeActive = true
  isReady = true
  renderCells = Array(0..<cells)
 }
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
 /// 本次装修有没有真的去派生格子（区分"派生中"与"永远拿不到几何"）。
 var residentPropGridDerivationRequested = false
 /// 最近一次推给面板的承托几何状态。只在变化时重推快照。
 private var publishedResidentPropSupportPhase:ResidentPropSupportPhase?
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
 /// 真机：唯一一处把快照推给面板（`updateResidentPropEditor`）。
 func synchronizeResidentPropPresentation() {
  guard let context = livingWorldContext, spatialStage.selectedWorldID == context.manifest.worldID else { return }
  stageWindowController?.updateResidentPropEditor(residentPropEditorSnapshot(context:context))
 }
 /// 真机：`surfaces` 来自格子（没派生好就是空），`supportGeometryUnavailable` 来自同一个判据。
 func residentPropEditorSnapshot(context:LayoutContext) -> ResidentPropEditorSnapshot {
  .init(worldID:context.manifest.worldID,revision:context.state.layoutRevision,
   objects:Array(context.state.objectStates.values),
   surfaces:residentPropSupportPhase.isGridReady ? surfaces : [],
   canUndo:false,heldProp:context.state.heldProp,
   supportGeometryUnavailable:residentPropSupportPhase.supportGeometryUnavailable)
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
  actualHost.surfaces = [surface];actualHost.residentPropGridDerivationRequested = true
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
  // 下面四条把"点一行"的**行为**钉死（而不是钉某一行代码存在）：
  //   1. 拿不到承托几何 → 进不了携带态（fail-closed 保留），但**必须说出来**；
  //   2. 宿主能答出现状（格子已就绪）→ 点一行**必须**进携带态；
  //   3. 永远拿不到几何 → 不能说"请稍候"（那不是"还没好"，是"好不了"）；
  //   4. 格子就绪那一刻，宿主**自己**必须重新投影一次面板快照。
  let driftingRow = ResidentPropEditorSnapshot(
    worldID:"a",revision:3,objects:[object],surfaces:[],canUndo:false,heldProp:nil,
    holdUnavailableReasons:[:],supportGeometryUnavailable:false)
  let stranded = ResidentPropEditorState()
  stranded.update(driftingRow);stranded.open()
  stranded.preview = { _, p in WorldObjectState(transform:.init(position:p.position,rotation:identity.rotation,scale:identity.scale),metadata:metadata) }
  // 宿主答不出更好的现状（没在装修 / 世界换了）：仍然不许静默。
  await stranded.select(objectID:"cup")
  precondition(stranded.selectedID == nil && stranded.placement == nil,
    "no support geometry must not enter the carrying state")
  precondition(stranded.notice == "格子还在生成，请稍候",
    "a click without support geometry must say so, not return silently (got \"\(stranded.notice)\")")

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

  let hopeless = ResidentPropEditorState()
  hopeless.update(.init(worldID:"a",revision:3,objects:[object],surfaces:[],canUndo:false,heldProp:nil,
    holdUnavailableReasons:[:],supportGeometryUnavailable:true))
  hopeless.open()
  await hopeless.select(objectID:"cup")
  precondition(hopeless.selectedID == nil && hopeless.notice == "当前空间拿不到摆放几何，暂时不能摆放",
    "geometry that will never arrive must not tell the resident to wait (got \"\(hopeless.notice)\")")

  // 根因：**格子就绪**必须触发一次面板快照的重新投影。这一段驱动的是 App 里被抽取出来的
  // `publishResidentPropGrid`（真代码），只有"格子模型怎么变"和"快照怎么算"是替身。
  let wiringHost = AppGuardHarness(), wiringController = ControllerHarness()
  wiringHost.livingWorldContext = context
  wiringHost.surfaces = [surface]
  wiringHost.stageWindowController = wiringController
  wiringHost.configureResidentPropEditor(wiringController)
  wiringHost.residentPropGridDerivationRequested = true   // 已请求派生，格子还没出来
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
  print("PASS: editor cancel, failure preservation, hand controls, duplicate submit, stale revision, late world, input routing, ready-grid row click")
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

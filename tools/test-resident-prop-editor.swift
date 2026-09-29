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
// 光标旁那枚「这里为什么不能放」的纯逻辑（同时是 `ResidentPropEditorView` 图例的取色来源）。
let blockLabelSource = try String(contentsOf:root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/ResidentPropBlockReasonLabel.swift"),encoding:.utf8)
guard blockLabelSource.contains("enum ResidentPropBlockReasonLabel") else {
    print("FAIL: the cursor-side block-reason label is missing");exit(1)
}
let controller = try String(contentsOf:root.appendingPathComponent("apps/macos/Sources/GMGNRadio/VisualEngine/StageWindowController.swift"),encoding:.utf8)
let editorView = try String(contentsOf:root.appendingPathComponent("apps/macos/Sources/GMGNRadio/VisualEngine/ResidentPropEditorView.swift"),encoding:.utf8)
// ── 光标旁那枚标签的**绘制条件**只能来自那个纯判据 ────────────────────────────
// 真机：红格的原因只写在面板右下角，用户看不见。现在它跟着光标走 —— 但"什么时候画"
// 必须仍然由 `ResidentPropBlockReasonLabel.content` 回答（携带 + 真的有原因），
// 视图里自己判断（例如"总是画"）会让可放时也冒出一枚噪音标签。
let blockLabelDraw = method("private func drawBlockReasonLabel(", in: controller)
guard blockLabelDraw.contains("guard let text = ResidentPropBlockReasonLabel.content("),
      blockLabelDraw.contains("isCarrying: propEditor.isCarrying"),
      blockLabelDraw.contains("reason: spatialStage.residentPropBlockReason?.errorDescription") else {
 print("FAIL: the cursor-side label must be drawn only through ResidentPropBlockReasonLabel.content(isCarrying:reason:...) and take its copy from the existing block-reason projection");exit(1)
}
// 实时性：这一拍里 `onGridCursor` 才会算出新的原因，所以标脏必须在它**之后** ——
// 否则标签永远慢一次 hover。
let pointerUpdate = method("private func updatePropPointer(", in: controller)
guard let cursorCall = pointerUpdate.range(of:"onGridCursor?(normalized)"),
      pointerUpdate.range(of:"needsDisplay = true",range:cursorCall.upperBound..<pointerUpdate.endIndex) != nil else {
 print("FAIL: the hover redraw must be marked after onGridCursor returns (otherwise the label lags one hover behind)");exit(1)
}
guard controller.contains("StageControlPanelLayout.transportWidth + StageControlPanelLayout.controlSize"),
      controller.contains("window.minSize = CGSize(width: 760, height: 520)"),
      controller.contains("propEditorPanel.widthAnchor.constraint(equalToConstant: 340)"),
      controller.contains("Float(1 - point.y / bounds.height)") else {
 print("FAIL: native editor size or bottom-left pointer mapping is missing");exit(1)
}
// ── 场景输入门禁的判据来源：**真正的输入框**，不是任意 `NSTextView` ──────────────
// 真机 2026-09-29：用户在右侧「摆放」面板点了一行 → 进了携带态 → 鼠标不跟手、圆环点不动、
// `R`/`,`/`.` 全没反应。两条同源怀疑里，**能成立的那条**是判据太宽：门禁读的是
// `window?.firstResponder is NSTextView`，而"用户在打字"的本意只有"first responder 是
// `residentComposer`（聊天输入框）自己或它的后代"。判据本体必须只有一份，且必须由真正的
// 输入框宿主决定；门禁的两处读取（`consumesPropPointer` / `keyDown`）都不许再出现裸的
// `is NSTextView`（那会让面板里的文本视图把场景整个挡掉）。
let inputFocusPredicate = method("@MainActor\nfunc stageTextInputOwnsFocus(", in: controller)
guard controller.contains("var isTextInputFocused: (() -> Bool)?"),
      controller.contains("isTextInputFocused?() ?? (window?.firstResponder is NSTextView)") else {
 print("FAIL: the scene gate must take its \"is the input field typing\" answer from its host, and keep the old answer as the fail-closed fallback");exit(1)
}
let consumesPropPointer = method("private var consumesPropPointer", in: controller)
guard consumesPropPointer.contains("inputOwnsFocus: inputOwnsFocus"),
      !consumesPropPointer.contains("is NSTextView") else {
 print("FAIL: consumesPropPointer must not decide \"typing\" from any NSTextView");exit(1)
}
let inputOwnsFocus = method("private var inputOwnsFocus", in: controller)
guard inputOwnsFocus.contains("isTextInputFocused?()") else {
 print("FAIL: the scene gate has no single source for \"the input field owns focus\"");exit(1)
}
// 门禁判据与"焦点交回场景"必须接在**同一处**（`wireSceneInputOwnership`），且交回走既有的
// `makeFirstResponder(worldInteractionView)`：真机上点完面板动作之后，键盘/指针必须回到场景。
let wireOwnership = method("private func wireSceneInputOwnership(", in: controller)
guard wireOwnership.contains("residentPropEditor.onSceneFocusRequested ="),
      wireOwnership.contains("worldInteractionView.isTextInputFocused ="),
      wireOwnership.contains("residentComposerOwnsFirstResponder()") else {
 print("FAIL: the scene gate's predicate and the panel-to-scene focus hand-back must be wired together from the real composer");exit(1)
}
let returnSceneFocus = method("private func returnSceneFocus(", in: controller)
guard returnSceneFocus.contains("window.makeFirstResponder(worldInteractionView)") else {
 print("FAIL: handing focus back to the scene must use the existing makeFirstResponder(worldInteractionView) path");exit(1)
}
let selectBody = method("func select(objectID: String) async", in: model)
guard selectBody.contains("handFocusBackToScene(") else {
 print("FAIL: clicking a panel row must hand the keyboard focus back to the scene");exit(1)
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
import AppKit
import WorldRuntime
func precondition(_ condition:@autoclosure()->Bool,_ message:String="assertion failed") {
 if !condition() { print("FAIL: \(message)"); exit(1) }
}
/// 场景键盘/指针门禁的**判据本体**（生产实现，逐字抽取）。
\#(inputFocusPredicate)
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
\#(blockLabelSource)
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
 /// 被抽取的生产代码里的日志引用（`StageWindowController.log` 在这里解析到这个类型）。
 static let log = Logger(subsystem: ProductIdentity.bundleIdentifier, category: "ControllerHarness")
 let residentPropEditor = ResidentPropEditorState()
 \#(method("func configureResidentPropEditor("))
 \#(method("func updateResidentPropEditor("))
 /// 格子点击落地那条路径的入口。本 harness 不驱动它（`snappedPlacement` 恒为 nil），
 /// 只要求被抽取的 `publishResidentPropGrid` 能编过。
 func moveResidentPropGridPointer(to position:WorldVector3,layerName:String,yaw:Float) async {}
}
/// 窗口替身：只需要"谁是 first responder"这一件事 —— 焦点交回是不是真的换人，全靠它记。
@MainActor final class FocusWindow {
 var firstResponder: AnyObject?
 func makeFirstResponder(_ responder: AnyObject) { firstResponder = responder }
}
/// 场景交互视图的替身：只做两件事 —— 被 `makeFirstResponder` 指到的那个对象，以及
/// `isTextInputFocused` 这个**注入位**（生产里它是 `StageWorldInteractionView` 的存储属性，
/// 抽取出来的 `inputOwnsFocus` 读它；结构断言已经把生产那一行的类型钉死）。
@MainActor final class SceneInteractionStandIn {
 var isTextInputFocused: (() -> Bool)?
}
/// `StageContentView` 里 responder 相关的两处接线 + 门禁判据（生产实现，逐字抽取）：
/// `wireSceneInputOwnership()` 是**唯一**的接线处，`returnSceneFocus` 是焦点交回的唯一出口，
/// `residentComposerOwnsFirstResponder()` 是"正在打字"的唯一判据。
///
/// 这里用**真 AppKit 视图树**（`residentComposer` 里挂一个 `NSTextView`）来回答门禁：
/// "面板里的 `NSTextView`"与"聊天输入框里的 field editor"是两个不同的东西，只有后者算打字。
@MainActor final class SceneOwnershipHarness {
 let residentPropEditor = ResidentPropEditorState()
 let residentComposer = NSView()
 let worldInteractionView = SceneInteractionStandIn()
 var window: FocusWindow? = FocusWindow()
 var lastLoggedSceneInputFocusOwner: String?
 \#(method("private func wireSceneInputOwnership(").replacingOccurrences(of:"private func",with:"func"))
 \#(method("private func residentComposerOwnsFirstResponder(").replacingOccurrences(of:"private func",with:"func"))
 \#(method("private func noteSceneInputGateBlocked(").replacingOccurrences(of:"private func",with:"func"))
 \#(method("private func returnSceneFocus(").replacingOccurrences(of:"private func",with:"func"))
}
/// 场景交互视图的**门禁部分**（`inputOwnsFocus` / `consumesPropPointer` 原样抽取）。
/// 判定本体 `ResidentPropEditorState.consumesScenePointer` 与编辑器状态都是生产实现；
/// 只有"注入位"（`isTextInputFocused`）与窗口替身是 harness 的。
@MainActor final class SceneGateProbe {
 let propEditor: ResidentPropEditorState
 var window: FocusWindow?
 var isTextInputFocused: (() -> Bool)?
 init(_ propEditor: ResidentPropEditorState) { self.propEditor = propEditor }
 \#(method("private var inputOwnsFocus").replacingOccurrences(of:"private var",with:"var"))
 \#(method("private var consumesPropPointer").replacingOccurrences(of:"private var",with:"var"))
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
 /// 与真机 `ResidentPropGridEditorModel.hoveredBlockReason` 对应：nil = 这个落点能放。
 /// 光标旁那枚标签读的就是它（经 `publishResidentPropGrid` 原样转发）。
 var hoveredBlockReason:PropSupportBlockReason?
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
  /// 真机 `SpatialStageStore.residentPropBlockReason`：给渲染层读的「这里为什么不能放」。
  var residentPropBlockReason:PropSupportBlockReason?
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
/// 宿主此刻**答得出来的现状**。做成一个引用盒子是因为：闭包得先装配好，之后再改它 ——
/// 待办补做正好发生在宿主推来新快照（`update`）之后，测试必须能改"现在"。
@MainActor final class HostSnapshotBox {
 var value:ResidentPropEditorSnapshot
 init(_ value:ResidentPropEditorSnapshot) { self.value = value }
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

  // ── 门禁的判据来源：**真正的输入框**，不是任意 `NSTextView` ─────────────────────
  // 真机 2026-09-29：用户在右侧「摆放」面板里点了物件那一行 → 确实进了携带态（青色圆环画出来了）
  // → 但鼠标不跟手、点圆环没反应、`R`/`,`/`.` 全没反应。两条同源怀疑里，**判据太宽**那条成立：
  // 门禁读的是 `window?.firstResponder is NSTextView`，于是"窗口里任何一个文本视图拿到焦点"
  // 都被当成"用户在打字"。这里用**真 AppKit 视图树**把这条钉死：装修面板里的 `NSTextView`
  // 不是打字（场景照常收指针）；只有 `residentComposer`（聊天输入框）里的 field editor 才算。
  let ownership = SceneOwnershipHarness()
  ownership.wireSceneInputOwnership()
  let composerField = NSTextView()
  ownership.residentComposer.addSubview(composerField)
  // 窗口里**除了输入框之外**的文本视图（真机上可能是设置里的文本区、别的面板里的控件；
  // 判据不该问它在哪个面板，只该问它是不是那个输入框）。
  let otherEditor = NSTextView()
  let otherHost = NSView()
  otherHost.addSubview(otherEditor)
  precondition(ownership.worldInteractionView.isTextInputFocused != nil,
    "the scene interaction view must receive the gate predicate from its host")
  ownership.window?.firstResponder = otherEditor
  precondition(!ownership.worldInteractionView.isTextInputFocused!(),
    "a text view that is not the real input field is not \"the user is typing\"")
  ownership.window?.firstResponder = composerField
  precondition(ownership.worldInteractionView.isTextInputFocused!(),
    "typing in the resident composer is \"the user is typing\" and must still gate the scene")
  ownership.window?.firstResponder = otherHost
  precondition(!ownership.worldInteractionView.isTextInputFocused!(),
    "a plain view is not \"the user is typing\"")

  // ── 面板动作 → 焦点交回场景交互视图 ─────────────────────────────────────────
  // 「点面板行之后，场景交互视图重新成为 first responder」。走的是**真状态机**（`select`）+
  // **真接线**（`wireSceneInputOwnership`）+ **真交回路径**（`returnSceneFocus` →
  // `makeFirstResponder(worldInteractionView)`）。先把 first responder 摆成"面板里的文本视图"
  // —— 真机上点完一行就是这个状态，而它正是"场景收不到键盘/指针"的来源。
  ownership.residentPropEditor.preview = { _, p in
   WorldObjectState(transform:.init(position:p.position,rotation:identity.rotation,scale:identity.scale),metadata:metadata)
  }
  ownership.residentPropEditor.commit = { _, _, _ in snapshot }
  ownership.residentPropEditor.update(snapshot)
  ownership.residentPropEditor.open()
  ownership.window?.firstResponder = otherEditor
  await ownership.residentPropEditor.select(objectID:"cup")
  precondition(ownership.window?.firstResponder === ownership.worldInteractionView,
    "clicking a row in the decoration panel must hand the keyboard focus back to the scene interaction view")
  precondition(ownership.residentPropEditor.isCarrying,
    "precondition: the row click really entered the carrying state")
  // 携带态 + 面板的 `NSTextView` 拿焦点 ⇒ 场景**仍然**收指针（旧判据在这里会误判成打字）。
  let gate = SceneGateProbe(ownership.residentPropEditor)
  gate.window = ownership.window
  gate.isTextInputFocused = ownership.worldInteractionView.isTextInputFocused
  ownership.window?.firstResponder = otherEditor
  precondition(gate.consumesPropPointer,
    "with a text view that is not the input field focused, a carried prop must still follow the scene pointer")
  ownership.window?.firstResponder = composerField
  precondition(!gate.consumesPropPointer,
    "typing in the resident composer must still keep the scene from stealing the pointer")
  // 收回 / 撤销同样是面板动作：做完也要把焦点交回场景（用户接着还在房间里操作）。
  ownership.window?.firstResponder = otherEditor
  await ownership.residentPropEditor.withdraw()
  precondition(ownership.window?.firstResponder === ownership.worldInteractionView,
    "withdrawing from the panel must hand the keyboard focus back to the scene interaction view")
  ownership.window?.firstResponder = otherEditor
  await ownership.residentPropEditor.undo()
  precondition(ownership.window?.firstResponder === ownership.worldInteractionView,
    "undoing from the panel must hand the keyboard focus back to the scene interaction view")

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

  // ─────────────────────────────────────────────────────────────────────────────
  // 2026-09-28 真机缺陷（第二次确诊）：**打开装修就点物件那一行，那一次点击被浪费掉**。
  //
  // 真机日志：19.105 进入装修 → 19.130 开始派生 → 19.832 派生完成（0.69 s）。用户在那 0.7 s
  // 窗口里点了那一行：当时 `surfaces` 还是空的，面板回了一句"格子还在生成，请稍候"
  // 就把这次点击**扔掉了**。格子好了以后提示确实换成了"可以摆放了"，但**那次点击不会被补做**
  // —— 用户以为点过了，实际"没有携带态"。
  //
  // 下面把"待办"钉成**行为**（不是钉某个变量）：
  //   1. 未就绪时点行 ⇒ 记住意图 + 可读提示；承托面到（宿主的就绪重推）⇒ **自动进入携带态**，
  //      不需要第二次点击，而且 placement 必须来自**被点的那一件**（用它自己的 transform）；
  //   2. "用户不要这件事了"的每一条路（改选另一件 / 关面板 / Esc / 退出装修 / 换世界 / 保存中）
  //      ⇒ 待办被作废：之后**重新打开面板**再收到承托面，也绝不会自己拿起东西；
  //   3. 待办**只允许一件**：后点覆盖前点，绝不排队（先点的那件永远不许事后被补做）。
  let deferredAnchor = WorldVector3(x:2,y:0.5,z:1)
  var deferredMetadata = metadata
  deferredMetadata["gmgn.support-surface.v1"] = "table"
  let deferredObject = WorldObjectState(
    transform:.init(position:deferredAnchor,rotation:identity.rotation,scale:identity.scale),
    metadata:deferredMetadata)
  let deferredSurfaces:[ResidentPropEditorSurface] = [
    .init(id:"floor",name:"地面",position:zero,cellCount:1),
    .init(id:"table",name:"台面 0.50 m",position:.init(x:-3,y:0.5,z:-3),cellCount:8)]
  /// 宿主**答得出来**的"格子还在生成"：承托面为空，但确实有一次派生在跑
  /// （`supportGeometryUnavailable == false`）—— 与"永远拿不到"互斥。
  let deferredDeriving = ResidentPropEditorSnapshot(worldID:"a",revision:3,objects:[deferredObject],
    surfaces:[],canUndo:true,heldProp:nil,holdUnavailableReasons:[:],supportGeometryUnavailable:false)
  let deferredReady = ResidentPropEditorSnapshot(worldID:"a",revision:3,objects:[deferredObject],
    surfaces:deferredSurfaces,canUndo:true)
  let otherWorldReady = ResidentPropEditorSnapshot(worldID:"b",revision:3,objects:[deferredObject],
    surfaces:deferredSurfaces,canUndo:true)

  // (1) 未就绪时点行 ⇒ 记住意图 + 可读提示；承托面到 ⇒ **自动进入携带态**（不需要第二次点击）。
  //     这是"真机那 0.7 s 窗口"的逐字复现：`update(deferredReady)` 就是 19.832 那次重推。
  let deferred = ResidentPropEditorState()
  deferred.update(deferredDeriving);deferred.open()
  let deferredHost = HostSnapshotBox(deferredDeriving)
  deferred.refreshSnapshot = { deferredHost.value }
  var deferredPreviews:[String] = []
  deferred.preview = { id, _ in deferredPreviews.append(id);return deferredObject }
  await deferred.select(objectID:"cup")
  precondition(deferred.selectedID == nil && !deferred.isCarrying,
    "precondition: without support geometry a row click must not enter the carrying state")
  precondition(deferred.notice == ResidentPropEditorSnapshot.supportDerivingText,
    "a row click before the grid is ready must still say \"\(ResidentPropEditorSnapshot.supportDerivingText)\" (got \"\(deferred.notice)\")")
  deferredHost.value = deferredReady
  deferred.update(deferredReady)          // 宿主在格子就绪那一刻重推快照
  for _ in 0..<1_000 { if deferred.isCarrying { break };await Task.yield() }
  precondition(deferred.isCarrying,
    "once the grid is ready the row click that was swallowed must be completed automatically, without a second click (carrying=\(deferred.isCarrying) selected=\(deferred.selectedID ?? "nil") notice=\(deferred.notice))")
  precondition(deferred.selectedID == "cup",
    "the completed click must carry the very row that was clicked (got \(deferred.selectedID ?? "nil"))")
  precondition(deferred.placement?.surfaceID == "table"
      && deferred.placement?.position.x == deferredAnchor.x
      && deferred.placement?.position.z == deferredAnchor.z,
    "the completed carrying state must come from the clicked prop's own transform (surface=\(deferred.placement?.surfaceID ?? "nil") position=\(String(describing:deferred.placement?.position)))")
  precondition(deferred.candidate != nil && deferredPreviews == ["cup"],
    "the completed click must preview exactly that prop (previews=\(deferredPreviews) candidate=\(deferred.candidate != nil))")
  precondition(deferred.notice != ResidentPropEditorSnapshot.supportDerivingText,
    "a completed click must not leave the stale \"still generating\" notice behind (got \"\(deferred.notice)\")")

  // (2) "用户不要这件事了"的每一条路都必须**作废**待办。判据刻意放在"之后**重新打开面板**
  //     再收到承托面"上：关掉面板本身会让携带态不可见，只有重新打开才暴露"待办还活着"。
  func pendingThenInvalidated(_ label:String, laterSnapshot:ResidentPropEditorSnapshot,
                              _ invalidate:(ResidentPropEditorState) async -> Void) async {
    let editor = ResidentPropEditorState()
    editor.update(deferredDeriving);editor.open()
    let hostSnapshot = HostSnapshotBox(deferredDeriving)
    editor.refreshSnapshot = { hostSnapshot.value }
    editor.commit = { _, _, _ in deferredReady }
    var previewed:[String] = []
    editor.preview = { id, _ in previewed.append(id);return deferredObject }
    await editor.select(objectID:"cup")
    precondition(editor.notice == ResidentPropEditorSnapshot.supportDerivingText,
      "precondition (\(label)): the row click must be remembered while the grid is deriving (notice=\(editor.notice))")
    await invalidate(editor)
    hostSnapshot.value = laterSnapshot
    editor.update(laterSnapshot)
    editor.open()                          // 用户重新打开面板
    for _ in 0..<1_000 { await Task.yield() }
    precondition(!editor.isCarrying && editor.selectedID == nil && previewed.isEmpty,
      "\(label) must invalidate the pending row click: reopening the panel and getting the surfaces must NOT pick anything up (carrying=\(editor.isCarrying) selected=\(editor.selectedID ?? "nil") previewed=\(previewed))")
  }
  await pendingThenInvalidated("closing the panel", laterSnapshot:deferredReady) { $0.close() }
  // Esc 在"手上有待办"时的分支是 close()（没有选中任何东西），所以这里钉的就是那条。
  await pendingThenInvalidated("pressing Escape", laterSnapshot:deferredReady) { $0.escape() }
  // 换世界：宿主推来**别的世界**的现状。待办属于旧世界，必须随之作废。
  await pendingThenInvalidated("switching worlds", laterSnapshot:otherWorldReady) {
    $0.update(.init(worldID:"b",revision:0,objects:[],surfaces:[],canUndo:false))
  }
  // 保存中：真的起一次保存（`undo` 走 `save`）。世界随时可能换一份回来，待办一律作废。
  // 这次保存刻意**失败**（commit 抛错）：失败分支走不到 `cancelPreview()`，所以这一条钉的是
  // `save` 自己那次作废，而不是被别的清理路径捎带着清掉的。
  await pendingThenInvalidated("a save in flight", laterSnapshot:deferredReady) { editor in
    editor.commit = { _, _, _ in
      throw NSError(domain:"test",code:9,userInfo:[NSLocalizedDescriptionKey:"保存失败"])
    }
    await editor.undo()
  }

  // 退出装修：走**真机那条链**（菜单「结束装修」/ 窗口关闭都落到控制器的 `close()`），
  // 而不是直接戳状态机 —— 这条链上任何一步漏了作废，待办都会活到下一次重推。
  let exitHost = AppGuardHarness(), exitController = ControllerHarness()
  exitHost.livingWorldContext = context
  exitHost.surfaces = [surface]
  exitHost.stageWindowController = exitController
  exitHost.configureResidentPropEditor(exitController)
  let exitToken = UUID()
  exitHost.residentPropGridDerivation = exitToken
  exitHost.publishResidentPropGrid()       // 派生在跑：面板看到的承托面为空
  exitController.residentPropEditor.open()
  await exitController.residentPropEditor.select(objectID:"cup")   // 这次点击落在空档里
  precondition(exitController.residentPropEditor.selectedID == nil
      && exitController.residentPropEditor.notice == ResidentPropEditorSnapshot.supportDerivingText,
    "precondition: a row click during the derivation is remembered, not carried (notice=\(exitController.residentPropEditor.notice))")
  exitController.residentPropEditor.close()      // ← 结束装修 / 关面板走的就是这一条
  exitHost.residentPropGridEditor.becomeReady()  // 格子随后才派生完
  exitHost.finishResidentPropGridDerivation(exitToken)
  precondition(!exitController.residentPropEditor.snapshot.surfaces.isEmpty,
    "precondition: the ready grid re-projects the panel snapshot")
  exitController.residentPropEditor.open()       // 用户重新打开装修
  for _ in 0..<1_000 { await Task.yield() }
  precondition(!exitController.residentPropEditor.isCarrying && exitController.residentPropEditor.selectedID == nil,
    "ending the decoration session must invalidate the pending row click: reopening it must NOT pick anything up (carrying=\(exitController.residentPropEditor.isCarrying) selected=\(exitController.residentPropEditor.selectedID ?? "nil"))")

  // (3) 待办**只允许一件**（后点覆盖前点，绝不排队）。
  let kettleProp = WorldGeneratedProp(objectID:"kettle",sourceWishID:"wish",assetID:"kettle-asset",
    displayName:"水壶",size:.init(x:0.1,y:0.2,z:0.1),sourceHeight:1)
  var kettleMetadata = ["gmgn.generated-prop.v1":String(data:try JSONEncoder().encode(kettleProp),encoding:.utf8)!]
  kettleMetadata["gmgn.support-surface.v1"] = "floor"
  let kettleAnchor = WorldVector3(x:-1,y:0,z:-1)
  let kettleObject = WorldObjectState(
    transform:.init(position:kettleAnchor,rotation:identity.rotation,scale:identity.scale),
    metadata:kettleMetadata)
  let twoObjects = [deferredObject,kettleObject]
  func pairSnapshot(surfaces:[ResidentPropEditorSurface]) -> ResidentPropEditorSnapshot {
    .init(worldID:"a",revision:3,objects:twoObjects,surfaces:surfaces,canUndo:true,heldProp:nil,
      holdUnavailableReasons:[:],supportGeometryUnavailable:false)
  }
  let bothDeriving = pairSnapshot(surfaces:[]), bothReady = pairSnapshot(surfaces:deferredSurfaces)
  // (3a) 未就绪时连点两行：只有**后点**的那一件会被补做，先点的那一件永远不许事后被拿起。
  let queue = ResidentPropEditorState()
  queue.update(bothDeriving);queue.open()
  let queueHost = HostSnapshotBox(bothDeriving)
  queue.refreshSnapshot = { queueHost.value }
  var queuedPreviews:[String] = []
  queue.preview = { id, _ in queuedPreviews.append(id);return twoObjects.first { $0.generatedProp?.objectID == id }! }
  await queue.select(objectID:"cup")
  await queue.select(objectID:"kettle")
  precondition(queue.notice == ResidentPropEditorSnapshot.supportDerivingText,
    "precondition: both row clicks landed while the grid was still deriving (notice=\(queue.notice))")
  queueHost.value = bothReady
  queue.update(bothReady)
  for _ in 0..<1_000 { if queue.isCarrying { break };await Task.yield() }
  precondition(queue.isCarrying && queue.selectedID == "kettle",
    "only the most recent row click may be remembered and completed (carrying=\(queue.isCarrying) selected=\(queue.selectedID ?? "nil") previewed=\(queuedPreviews))")
  precondition(queuedPreviews == ["kettle"],
    "the superseded row click must never be completed later (previewed=\(queuedPreviews))")
  precondition(queue.placement?.position.x == kettleAnchor.x,
    "the completed click must carry the most recently clicked prop (position=\(String(describing:queue.placement?.position)))")

  // (3b) 未就绪时点了 cup，随后承托面到了、用户改点 kettle 并且**这次成功了**：
  //      旧的那次待办必须**已经不存在** —— 否则宿主下一次重推快照会把它补做，
  //      于是"用户明明拿起了 kettle，过一会儿手里变成了 cup"。
  let supersede = ResidentPropEditorState()
  supersede.update(bothDeriving);supersede.open()
  let supersedeHost = HostSnapshotBox(bothDeriving)
  supersede.refreshSnapshot = { supersedeHost.value }
  var supersedePreviews:[String] = []
  supersede.preview = { id, _ in supersedePreviews.append(id);return twoObjects.first { $0.generatedProp?.objectID == id }! }
  await supersede.select(objectID:"cup")
  precondition(supersede.selectedID == nil && supersede.notice == ResidentPropEditorSnapshot.supportDerivingText,
    "precondition: the first row click is remembered while the grid is deriving")
  supersedeHost.value = bothReady
  await supersede.select(objectID:"kettle")
  precondition(supersede.isCarrying && supersede.selectedID == "kettle",
    "the row click that finally can be honoured must enter the carrying state (selected=\(supersede.selectedID ?? "nil"))")
  supersede.update(bothReady)             // 宿主下一次重推（鼠标一动就会推）
  for _ in 0..<1_000 { await Task.yield() }
  precondition(supersede.selectedID == "kettle" && supersedePreviews == ["kettle"],
    "a newer row click must supersede the older pending one for good, never the other way round (selected=\(supersede.selectedID ?? "nil") previewed=\(supersedePreviews))")

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
  // 光标旁那枚「这里为什么不能放」：文案必须来自**既有的阻挡原因投影**，不是新造的字符串。
  //
  // 真机：用户看到台面上一片绿格、其中两格是红的，问"这两个红色的是什么意思"。红 = 不能放 ✓，
  // 原因也算出来了，但只写在面板右下角那行 `notice` 里。下面用**真的格子模型**算出原因
  // （`PropSupportGridEditorModel.hoveredBlockReason`），再断言标签拿到的就是同一份文案。
  let reasonModel = ResidentPropGridEditorModel()
  let reasonFloor = FlatFloorCollision(half:1.5)
  await reasonModel.activate(collision:reasonFloor,seed:.init(x:0,y:0,z:0),
    bounds:.init(minimumX:-1.5,maximumX:1.5,minimumZ:-1.5,maximumZ:1.5),key:"reason-harness")
  precondition(reasonModel.isReady,"precondition: the flat floor derives a support grid for the reason test")
  // 合成相机：位于 (0,2,0) 沿 -Y 看下去（与 `test-resident-prop-render.swift` 同一个相机），
  // 光标打在视口正中 ⇒ 命中地面柱 (0,0) 那一层。
  var reasonCamera = matrix_identity_float4x4
  reasonCamera.columns.2 = SIMD4(0,-1,0,0)
  reasonCamera.columns.1 = SIMD4(0,0,1,0)
  reasonCamera.columns.3 = SIMD4(0,2,0,1)
  let reasonCursor = SIMD2<Float>(0.5,0.5)
  let reasonSize = SIMD2<Float>(repeating:reasonModel.spacing)
  func hoverReason(with placed:[WorldCollisionVolume]) {
    reasonModel.updateHover(normalizedCursor:reasonCursor,inverseViewProjection:reasonCamera,
      footprintSize:reasonSize,height:reasonSize.x,blockingVolumes:[],placedProps:placed)
  }
  hoverReason(with:[])
  precondition(reasonModel.canPlaceAtHover,
    "precondition: the empty drop spot is placeable (reason=\(String(describing:reasonModel.hoveredBlockReason)))")
  precondition(reasonModel.cellStates.values.contains(.validFootprint),
    "precondition: a placeable drop spot is painted yellow (.validFootprint) — the legend's second colour")
  precondition(ResidentPropBlockReasonLabel.content(isCarrying:true,
      reason:reasonModel.hoveredBlockReason?.errorDescription) == nil,
    "a placeable drop spot must draw no label at all (pure predicate: no reason → nothing to draw)")
  precondition(ResidentPropBlockReasonLabel.content(isCarrying:false,
      reason:PropSupportBlockReason.blockedByPlacedProp("落地灯").errorDescription) == nil,
    "with nothing in hand no label is drawn, reason or not")
  // 同一格上摆一件物件 ⇒ 模型给出 `.blockedByPlacedProp`，格子转红，标签出现 ——
  // 三者（红格 / 原因 / 标签）出自**同一个**判定。
  let blocker = WorldCollisionVolume(id:"落地灯",center:.init(x:0.125,y:0.1,z:0.125),
    halfExtents:.init(x:0.2,y:0.2,z:0.2),rotation:.init(x:0,y:0,z:0,w:1),isBlocking:true)
  hoverReason(with:[blocker])
  let blockedReason = reasonModel.hoveredBlockReason
  precondition(blockedReason == .blockedByPlacedProp("落地灯"),
    "precondition: a placed prop on the drop spot blocks it (got \(String(describing:blockedReason)))")
  precondition(reasonModel.cellStates.values.contains(.invalidFootprint)
      && !reasonModel.cellStates.values.contains(.validFootprint),
    "precondition: the blocked drop spot is painted red (.invalidFootprint) — the legend's third colour")
  let labelText = ResidentPropBlockReasonLabel.content(isCarrying:true,reason:blockedReason?.errorDescription)
  precondition(labelText == blockedReason?.errorDescription && labelText != nil,
    "the label next to the cursor must show the existing block reason verbatim, not a newly written string")
  // 既有六种原因的投影就是标签的全部文案：新造一句（例如"这里不能放"）会在这里裂开。
  let existingReasons:[String?] = [
    PropSupportBlockReason.outsideBounds.errorDescription,
    PropSupportBlockReason.noSupport.errorDescription,
    PropSupportBlockReason.blockedByMesh.errorDescription,
    PropSupportBlockReason.blockedByBlockingVolume("点唱机").errorDescription,
    PropSupportBlockReason.blockedByPlacedProp("落地灯").errorDescription,
    PropSupportBlockReason.insufficientClearance.errorDescription,
  ]
  precondition(existingReasons.allSatisfy { $0 != nil && !$0!.isEmpty },
    "every existing block reason still projects to a non-empty Chinese sentence")
  precondition(existingReasons.contains(labelText),
    "the label text must be one of the existing projections, not a second set of copy (got \"\(labelText ?? "nil")\")")
  precondition(labelText == "这里会和已经放好的 落地灯 重叠。",
    "the label shows exactly what the panel notice shows (got \"\(labelText ?? "nil")\")")
  // 转发：`publishResidentPropGrid`（真代码）把原因原样写进渲染层 —— 标签才有得可读。
  let reasonHost = AppGuardHarness(), reasonController = ControllerHarness()
  reasonHost.livingWorldContext = context
  reasonHost.stageWindowController = reasonController
  reasonHost.spatialStage.residentPropBlockReason = nil
  reasonHost.residentPropGridEditor.hoveredBlockReason = blockedReason
  reasonHost.publishResidentPropGrid()
  precondition(reasonHost.spatialStage.residentPropBlockReason == blockedReason,
    "the block reason must be forwarded to the render layer untouched — that value is what the cursor-side label reads")
  reasonHost.residentPropGridEditor.hoveredBlockReason = nil
  reasonHost.publishResidentPropGrid()
  precondition(reasonHost.spatialStage.residentPropBlockReason == nil,
    "a placeable hover clears the forwarded reason, so the label cannot stay stale on screen")

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
  // 令牌 = "还有一次派生在跑"的唯一凭据：失焦不许碰它（真机上它就是在这里被收回的，
  // 于是面板显示"还在生成"，其实已经没人在算了）。
  let focusDerivationToken = UUID()
  focusHarness.residentPropGridDerivation = focusDerivationToken
  // 切到别的窗口去说话 —— 真机就是这一步把装修杀掉的。
  focusHarness.windowDidResignKey(Notification(name:Notification.Name("NSWindowDidResignKeyNotification")))
  precondition(focusHarness.residentPropEditor.isOpen,
    "losing window focus must not close the decoration editor")
  precondition(focusHarness.residentPropGridEditor.isBuildModeActive,
    "losing window focus must not end the decoration session")
  precondition(focusHarness.residentPropGridEditor.isReady && !focusHarness.residentPropGridEditor.renderCells.isEmpty,
    "losing window focus must not discard the derived grid")
  precondition(focusHarness.residentPropGridDerivation == focusDerivationToken,
    "losing window focus must not revoke the derivation token (the panel would keep saying \"still generating\")")
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

  print("PASS: editor cancel, failure preservation, hand controls, duplicate submit, stale revision, late world, input routing, ready-grid row click, host-cannot-answer vs host-says-empty, empty-grid and dead-derivation honesty, stale notice refresh, skipped-push retry, the row click that arrives before the grid is ready (remembered, completed on readiness from the clicked prop's own transform, invalidated by every \"I do not want this\" signal, never queued), scene pick-up routing, placed-prop transform, hover glow inside the focus clip, the placeable initial landing spot, the cursor-side \"why can't I put it here\" label taking its copy from the existing block-reason projection (and drawing nothing when placeable), window focus loss preserving the decoration session and its derivation, and same-world grid reuse from a bounded cache, the typing gate resolving to the real input field only, and the panel-to-scene hands-back of keyboard focus")
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
 viewCheck.arguments = ["swiftc","-j1","-typecheck","-swift-version","6","-I",products.appendingPathComponent("Modules").path,modelURL.path,root.appendingPathComponent("apps/macos/Sources/GMGNRadio/Presence/PropSupportGridPresentation.swift").path,root.appendingPathComponent("apps/macos/Sources/GMGNRadio/VisualEngine/ResidentPropEditorView.swift").path]
 try viewCheck.run();viewCheck.waitUntilExit();guard viewCheck.terminationStatus == 0 else { exit(viewCheck.terminationStatus) }
}
let run = Process();run.executableURL = binary;try run.run();run.waitUntilExit();exit(run.terminationStatus)

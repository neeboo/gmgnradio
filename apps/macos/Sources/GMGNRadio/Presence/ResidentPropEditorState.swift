import Foundation
import Combine
import WorldRuntime

struct ResidentPropEditorSurface: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let position: WorldVector3
}

struct ResidentPropEditorSnapshot: Equatable, Sendable {
    let worldID: String
    let revision: UInt64
    let objects: [WorldObjectState]
    let surfaces: [ResidentPropEditorSurface]
    let canUndo: Bool
    let heldProp: WorldHeldProp?
    let holdUnavailableReasons: [String: String]
    /// 承托几何**永远**不会来（派生的前置条件不成立：拿不到碰撞三角形或导航范围）。
    ///
    /// `false`（缺省）表示"格子还在派生"。这个字段只回答"还会不会好"，**不回答就绪与否** ——
    /// 就绪与否只看 `surfaces` 是不是空，所以两者不可能自相矛盾。
    let supportGeometryUnavailable: Bool
    init(worldID: String, revision: UInt64, objects: [WorldObjectState], surfaces: [ResidentPropEditorSurface],
         canUndo: Bool, heldProp: WorldHeldProp? = nil, holdUnavailableReasons: [String: String] = [:],
         supportGeometryUnavailable: Bool = false) {
        self.worldID = worldID; self.revision = revision; self.objects = objects; self.surfaces = surfaces
        self.canUndo = canUndo; self.heldProp = heldProp; self.holdUnavailableReasons = holdUnavailableReasons
        self.supportGeometryUnavailable = supportGeometryUnavailable
    }
    static let empty = Self(worldID: "", revision: 0, objects: [], surfaces: [], canUndo: false,
                            heldProp: nil, holdUnavailableReasons: [:], supportGeometryUnavailable: false)

    /// 拿不到承托几何时，面板要**说出来**的原因（有承托面时不会被读到）。
    ///
    /// 「派生中」的措辞与点击落地那条（`GMGNRadioApp.residentPropGridCommit`）**逐字一致**：
    /// 同一个用户处境（格子还没出来）在两处说同一句话，工具测试钉住这一点。
    var supportUnavailableNotice: String {
        supportGeometryUnavailable ? "当前空间拿不到摆放几何，暂时不能摆放" : "格子还在生成，请稍候"
    }
}

/// Drafts never change the world. Both validation and saving go through the host's placement service.
@MainActor final class ResidentPropEditorState: ObservableObject {
    @Published private(set) var snapshot = ResidentPropEditorSnapshot.empty
    @Published private(set) var isOpen = false
    @Published private(set) var selectedID: String?
    @Published private(set) var placement: WorldPropPlacement?
    @Published private(set) var candidate: WorldObjectState?
    @Published private(set) var isMoving = false
    @Published private(set) var isSaving = false
    @Published private(set) var notice = ""
    @Published var showsPlacedOnly = false
    var preview: (@MainActor (String, WorldPropPlacement) async throws -> WorldObjectState)?
    var commit: (@MainActor (WorldPropLayoutCommand, UInt64, String) async throws -> ResidentPropEditorSnapshot)?
    var hold: (@MainActor (String, UInt64, String) async throws -> ResidentPropEditorSnapshot)?
    var adjustHeldGrip: (@MainActor (String, WorldVector3, WorldQuaternion, UInt64, String) async throws -> ResidentPropEditorSnapshot)?
    var returnHeld: (@MainActor (String, UInt64, String) async throws -> ResidentPropEditorSnapshot)?
    /// 按**现状**再要一份快照。宿主没有可答的上下文（没在装修、世界换了）时返回 nil。
    ///
    /// 唯一消费者是 `select(objectID:)`：见那里对"快照是推送来的、格子却异步派生"的说明。
    var refreshSnapshot: (@MainActor () -> ResidentPropEditorSnapshot?)?
    var onPreviewChanged: @MainActor (WorldObjectState?) -> Void = { _ in }
    var onEditingChanged: @MainActor (Bool) -> Void = { _ in }
    private var generation = UUID()
    private var previewGeneration = UUID()
    private var draftRevision: UInt64?
    private var requestID = UUID().uuidString
    private var submittedCommand: WorldPropLayoutCommand?
    private var submittedActionKey: String?

    var objects: [WorldObjectState] {
        snapshot.objects.filter { item in
            item.generatedProp != nil && (!showsPlacedOnly || item.isEnabled || snapshot.heldProp?.objectID == item.generatedProp?.objectID)
        }
    }
    var selectedObject: WorldObjectState? { snapshot.objects.first { $0.generatedProp?.objectID == selectedID } }
    var isSelectedHeld: Bool { selectedID != nil && snapshot.heldProp?.objectID == selectedID }
    /// 「鼠标把物件拿在手上」——**派生**，不新增存储状态。
    ///
    /// 这样 confirm / cancelPreview / save 这些既有清理路径会自动把它清掉，不存在
    /// "忘了复位"的失效 bug。与「居民把物件拿在手里」（`isSelectedHeld` / `holdSelected()`
    /// 的 `WorldPropLayoutCommand.hold`，会持久化、绑居民右手、要求 2B 角色、最长边 >0.45 m
    /// 拒绝）是**两件不同的事**，命名上不要混：「在手」=鼠标携带，「手持/拿着看/放回」=居民携带。
    var isCarrying: Bool { isOpen && placement != nil && !isSelectedHeld }
    /// 当前摆放/建造模式算 footprint 用的物件尺寸：优先"正在拖动/待确认"的那个，否则用选中的。
    /// 没有选中任何物件时返回 nil，调用方退回"一格"。
    ///
    /// **唯一一份推导**：摆放校验（`residentPropGridHover` 的 `footprintSize`/`height`）与
    /// 场景内旋转手柄的外扩距离都读它——两处各抄一遍的话，手柄会偏离真正被判定/着色的 footprint。
    var footprint: (size: SIMD2<Float>, height: Float)? {
        guard let prop = (candidate ?? selectedObject)?.generatedProp else { return nil }
        return (SIMD2(prop.size.x, prop.size.z), prop.size.y)
    }
    var selectedGrip: WorldPropGripCalibration? { isSelectedHeld ? selectedObject?.gripCalibration : nil }
    var selectedHoldUnavailableReason: String? { selectedID.flatMap { snapshot.holdUnavailableReasons[$0] } }
    var surface: ResidentPropEditorSurface? { snapshot.surfaces.first { $0.id == placement?.surfaceID } }
    var canConfirm: Bool { isOpen && !isSaving && candidate != nil && draftRevision == snapshot.revision }

    func update(_ value: ResidentPropEditorSnapshot) {
        if snapshot.worldID != value.worldID { close(); notice = "" }
        else if placement != nil && draftRevision != value.revision {
            previewGeneration = UUID()
            notice = "房间摆放已有变化，请重新选择位置"
            candidate = nil; onPreviewChanged(nil)
        }
        snapshot = value
    }
    func open() { guard !snapshot.worldID.isEmpty, !isOpen else { return }; isOpen = true; onEditingChanged(true) }
    func close() {
        generation = UUID(); isSaving = false; cancelPreview()
        if isOpen { isOpen = false; onEditingChanged(false) }
    }
    func cancelPreview() {
        previewGeneration = UUID(); candidate = nil; placement = nil; selectedID = nil
        draftRevision = nil; isMoving = false; notice = ""; onPreviewChanged(nil)
    }
    func escape() {
        // Saving can await asset preparation. Closing revokes the host's editing lease before it resumes.
        if isSaving { close() }
        else if selectedID != nil { cancelPreview() }
        else { close() }
    }
    /// 点一行 → 进入携带态（`isCarrying`）。
    ///
    /// **不信任手里的快照**：`surfaces` 是宿主**推送**来的字段，而格子派生是异步的
    /// （真实舱体一次 0.5 s，-Onone 6.6 s）。就绪那一刻的推送可能还没到，所以点一行时先按
    /// 现状要一份（`refreshSnapshot`）再判 —— 否则"格子已经画出来了、点一行却毫无反应"。
    func select(objectID: String) async {
        guard isOpen, !isSaving else { return }
        if let refreshed = refreshSnapshot?() { update(refreshed) }
        guard isOpen else { return }
        // 行是从 `objects`（`snapshot.objects` 的过滤结果）画出来的，所以找不到只可能是
        // 快照刚好换了一版（例如世界被换掉）。那不是用户的动作失败，静默即可。
        guard let object = snapshot.objects.first(where: { $0.generatedProp?.objectID == objectID }) else { return }
        // 「必须有承托面」是**前置检查**，不是形式：`support` 同时给出初始落点 ——
        // `surfaceID` 与"未摆出物件的出生位置"（见下面的 `validate`）。拿不到就进不了携带态。
        // 但**绝不静默**：用户点了那一行，必须看得见为什么还没反应。
        guard let support = support(for: object) else {
            notice = snapshot.supportUnavailableNotice
            return
        }
        selectedID = objectID; draftRevision = snapshot.revision; requestID = UUID().uuidString
        if snapshot.heldProp?.objectID == objectID {
            placement = nil; candidate = nil; isMoving = false; notice = "手持展示中"; onPreviewChanged(nil)
            return
        }
        let q = object.transform.rotation
        let yaw = atan2(2 * (q.w * q.y + q.x * q.z), 1 - 2 * (q.y * q.y + q.z * q.z))
        await validate(.init(surfaceID: support.id, position: object.isEnabled ? object.transform.position : support.position, yaw: yaw))
    }

    /// 这一行现在能坐在哪一层承托面上。
    ///
    /// `supportSurfaceID` 是摆放时随状态存下来的**标签**，未摆出的物件没有它 —— 那时退回
    /// 第一层（`listedSupportLayers()` 按高度升序，第一层就是语义上的"地面"）。
    private func support(for object: WorldObjectState) -> ResidentPropEditorSurface? {
        snapshot.surfaces.first { $0.id == object.supportSurfaceID } ?? snapshot.surfaces.first
    }

    func selectSurface(_ id: String) async {
        guard !isSaving, let s = snapshot.surfaces.first(where: { $0.id == id }), selectedID != nil else { return }
        draftRevision = snapshot.revision
        await validate(.init(surfaceID: s.id, position: s.position, yaw: placement?.yaw ?? 0))
    }
    func toggleMoving() { guard !isSaving, placement != nil else { return }; isMoving.toggle() }
    func movePointer(to point: WorldVector3) async {
        guard !isSaving, let p = placement else { return }
        await validate(.init(surfaceID: p.surfaceID, position: point, yaw: p.yaw))
    }
    /// 建造模式：把预览挪到吸附后的格心。
    ///
    /// 与 `movePointer` 的差别有两点，都是建造模式需要的：
    /// - `surfaceID` 换成**层标识**（surfaceID 不再是具名摆放面）；
    /// - `yaw` 由调用方给（来自 `ResidentPropGridEditorModel.footprintYaw`），
    ///   这样 footprint 朝向只有一个真相来源，不会和编辑器里的旧值打架。
    func moveGridPointer(to point: WorldVector3, layerName: String, yaw: Float) async {
        guard !isSaving, placement != nil else { return }
        await validate(.init(surfaceID: layerName, position: point, yaw: yaw))
    }

    /// 建造模式的 90° 步进旋转。**全仓已无任何调用者**（旋转的唯一入口是
    /// `ResidentPropGridEditorModel.rotateFootprint(bySteps:)`，R / ⇧R / `,` / `.` /
    /// 场景内手柄都走它）。这里保留只是为了"先报告、别删"；确认后应整段删除。
    func rotateQuarterTurn(bySteps steps: Int) async {
        guard !isSaving, let p = placement else { return }
        await validate(.init(surfaceID: p.surfaceID, position: p.position, yaw: p.yaw + Float(steps) * .pi / 2))
    }

    func pointerMissed() {
        guard !isSaving else { return }
        previewGeneration = UUID(); candidate = nil; onPreviewChanged(nil)
        notice = "指针没有落在当前支持面上"
    }
    func nudge(x: Float, z: Float) async {
        guard let p = placement else { return }
        await movePointer(to: .init(x: p.position.x + x, y: p.position.y, z: p.position.z + z))
    }
    /// 面板上的 45° 旋转按钮（`ResidentPropEditorView` 的「左转 45° / 右转 45°」）。
    ///
    /// ⚠️ 这条路径只改 `placement.yaw`，**是第二个 yaw 真相来源**（唯一真相是
    /// `ResidentPropGridEditorModel.footprintYaw`），下一次 `publishResidentPropGrid`
    /// 会把预览转回去。建造模式的手柄/按键**绝不**走这里。
    /// 本步（第 2 步）**没有删它**：删了会打断 `ResidentPropEditorView.swift:66-67` 的编译，
    /// 而那个文件属于后续的"面板瘦身"步（D10）。
    func rotate(_ direction: Float) async {
        guard !isSaving, let p = placement else { return }
        await validate(.init(surfaceID: p.surfaceID, position: p.position, yaw: p.yaw + direction * .pi / 4))
    }
    private func validate(_ p: WorldPropPlacement) async {
        guard isOpen, !isSaving, let id = selectedID, let preview else { return }
        let run = UUID(); previewGeneration = run
        draftRevision = snapshot.revision
        let context = generation; placement = p; candidate = nil; onPreviewChanged(nil)
        requestID = UUID().uuidString
        do {
            let result = try await preview(id, p)
            guard generation == context, previewGeneration == run, isOpen else { return }
            candidate = result; notice = "预览中 · 确认后保存"; onPreviewChanged(result)
        } catch {
            guard generation == context, previewGeneration == run, isOpen else { return }
            notice = error.localizedDescription
        }
    }
    func confirm() async {
        guard canConfirm, let id = selectedID, let p = placement else { return }
        await save(.place(objectID: id, placement: p))
    }
    func withdraw() async {
        guard !isSaving, let id = selectedID, selectedObject?.isEnabled == true else { return }
        await save(.withdraw(objectID: id))
    }
    func undo() async { guard snapshot.canUndo, !isSaving else { return }; await save(.undo) }
    func holdSelected() async {
        guard let id = selectedID, snapshot.holdUnavailableReasons[id] == nil, let hold else { return }
        await saveAction(key: "hold:\(id)", keepSelection: id) { revision, requestID in
            try await hold(id, revision, requestID)
        }
    }
    func returnSelected() async {
        guard let id = selectedID, isSelectedHeld, let returnHeld else { return }
        await saveAction(key: "return:\(id)", keepSelection: nil) { revision, requestID in
            try await returnHeld(id, revision, requestID)
        }
    }
    func nudgeHeld(x: Float = 0, y: Float = 0, z: Float = 0) async {
        guard let id = selectedID, let grip = selectedGrip, let adjustHeldGrip else { return }
        let next = WorldVector3(x: grip.localOffset.x + x, y: grip.localOffset.y + y, z: grip.localOffset.z + z)
        await saveAction(key: "grip:\(id):\(next.x):\(next.y):\(next.z)", keepSelection: id) { revision, requestID in
            try await adjustHeldGrip(id, next, grip.localRotation, revision, requestID)
        }
    }
    func rotateHeld(_ direction: Float) async {
        guard let id = selectedID, let grip = selectedGrip, let adjustHeldGrip else { return }
        let q = grip.localRotation
        let currentYaw = atan2(2 * (q.w * q.y + q.x * q.z), 1 - 2 * (q.y * q.y + q.z * q.z))
        let yaw = currentYaw + direction * .pi / 12
        let rotation = WorldQuaternion(x: 0, y: sin(yaw/2), z: 0, w: cos(yaw/2))
        await saveAction(key: "grip-yaw:\(id):\(yaw)", keepSelection: id) { revision, requestID in
            try await adjustHeldGrip(id, grip.localOffset, rotation, revision, requestID)
        }
    }
    private func save(_ command: WorldPropLayoutCommand) async {
        guard isOpen, !isSaving, let commit else { return }
        isSaving = true; isMoving = false
        submittedActionKey = nil
        if submittedCommand != command { requestID = UUID().uuidString; submittedCommand = command }
        let context = generation, revision = snapshot.revision, id = requestID
        do {
            let result = try await commit(command, revision, id)
            guard context == generation, isOpen else { return }
            guard result.worldID == snapshot.worldID else {
                isSaving = false; notice = "房间已切换，请重新打开摆放"; return
            }
            snapshot = result; isSaving = false; cancelPreview(); notice = "已保存"
            requestID = UUID().uuidString
        } catch {
            guard context == generation, isOpen else { return }
            isSaving = false; notice = error.localizedDescription
        }
    }

    private func saveAction(key: String, keepSelection: String?,
                            perform: @escaping @MainActor (UInt64, String) async throws -> ResidentPropEditorSnapshot) async {
        guard isOpen, !isSaving else { return }
        isSaving = true; isMoving = false
        if submittedCommand != nil || submittedActionKey != key { requestID = UUID().uuidString }
        submittedCommand = nil
        submittedActionKey = key
        let context = generation, revision = snapshot.revision, id = requestID
        do {
            let result = try await perform(revision, id)
            guard context == generation, isOpen else { return }
            guard result.worldID == snapshot.worldID else {
                isSaving = false; notice = "房间已切换，请重新打开摆放"; return
            }
            snapshot = result; isSaving = false; candidate = nil; placement = nil; isMoving = false
            selectedID = keepSelection; draftRevision = result.revision; onPreviewChanged(nil)
            notice = keepSelection.map { result.heldProp?.objectID == $0 } == true ? "手持展示中" : "已放回"
            requestID = UUID().uuidString
        } catch {
            guard context == generation, isOpen else { return }
            isSaving = false; notice = error.localizedDescription
        }
    }
    static func consumesScenePointer(isOpen: Bool, moving: Bool, inputOwnsFocus: Bool) -> Bool {
        isOpen && moving && !inputOwnsFocus
    }
}

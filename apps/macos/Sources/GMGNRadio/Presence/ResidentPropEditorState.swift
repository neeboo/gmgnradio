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
    init(worldID: String, revision: UInt64, objects: [WorldObjectState], surfaces: [ResidentPropEditorSurface],
         canUndo: Bool, heldProp: WorldHeldProp? = nil, holdUnavailableReasons: [String: String] = [:]) {
        self.worldID = worldID; self.revision = revision; self.objects = objects; self.surfaces = surfaces
        self.canUndo = canUndo; self.heldProp = heldProp; self.holdUnavailableReasons = holdUnavailableReasons
    }
    static let empty = Self(worldID: "", revision: 0, objects: [], surfaces: [], canUndo: false,
                            heldProp: nil, holdUnavailableReasons: [:])
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
    func select(objectID: String) async {
        guard isOpen, !isSaving,
              let object = snapshot.objects.first(where: { $0.generatedProp?.objectID == objectID }),
              let support = snapshot.surfaces.first(where: { $0.id == object.supportSurfaceID }) ?? snapshot.surfaces.first else { return }
        selectedID = objectID; draftRevision = snapshot.revision; requestID = UUID().uuidString
        if snapshot.heldProp?.objectID == objectID {
            placement = nil; candidate = nil; isMoving = false; notice = "手持展示中"; onPreviewChanged(nil)
            return
        }
        let q = object.transform.rotation
        let yaw = atan2(2 * (q.w * q.y + q.x * q.z), 1 - 2 * (q.y * q.y + q.z * q.z))
        await validate(.init(surfaceID: support.id, position: object.isEnabled ? object.transform.position : support.position, yaw: yaw))
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
    func pointerMissed() {
        guard !isSaving else { return }
        previewGeneration = UUID(); candidate = nil; onPreviewChanged(nil)
        notice = "指针没有落在当前支持面上"
    }
    func nudge(x: Float, z: Float) async {
        guard let p = placement else { return }
        await movePointer(to: .init(x: p.position.x + x, y: p.position.y, z: p.position.z + z))
    }
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

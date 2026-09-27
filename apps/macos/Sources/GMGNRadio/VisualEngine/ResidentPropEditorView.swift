import SwiftUI
import WorldRuntime

/// A temporary, quiet shelf. The actual object remains in the room during previews.
struct ResidentPropEditorView: View {
    @ObservedObject var state: ResidentPropEditorState
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("摆放", systemImage: "square.stack.3d.up").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { state.close() } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).help("收起摆放")
            }
            Picker("物件", selection: $state.showsPlacedOnly) {
                Text("我的物件").tag(false)
                Text("房间里").tag(true)
            }.pickerStyle(.segmented).labelsHidden()
            if state.objects.isEmpty {
                Text(state.showsPlacedOnly ? "房间里还没有摆放物件" : "领取许愿机的物件后，可以在这里摆放")
                    .foregroundStyle(.secondary).font(.system(size: 12)).padding(.vertical, 14)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(state.objects, id: \.generatedProp?.objectID) { object in
                            if let prop = object.generatedProp {
                                Button { Task { await state.select(objectID: prop.objectID) } } label: {
                                    HStack(spacing: 9) {
                                        Image(systemName: "shippingbox")
                                        Text(prop.displayName).lineLimit(1)
                                        Spacer()
                                        if state.snapshot.heldProp?.objectID == prop.objectID {
                                            Text("手持中").font(.system(size: 10)).foregroundStyle(.cyan)
                                        } else if object.isEnabled {
                                            Text("已摆出").font(.system(size: 10)).foregroundStyle(.secondary)
                                        }
                                        if state.selectedID == prop.objectID { Image(systemName: "checkmark").foregroundStyle(.cyan) }
                                    }.padding(9).frame(maxWidth: .infinity)
                                        .background(state.selectedID == prop.objectID ? Color.white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                }.buttonStyle(.plain).disabled(state.isSaving)
                            }
                        }
                    }
                }.frame(maxHeight: 145)
            }
            if state.selectedID != nil {
                Divider().overlay(.white.opacity(0.08))
                if state.isSelectedHeld {
                    Text("右手展示微调").foregroundStyle(.secondary)
                    HStack(spacing: 7) {
                        holdStep("向前", z: -0.02); holdStep("向后", z: 0.02)
                        holdStep("向上", y: 0.02); holdStep("向下", y: -0.02)
                    }.controlSize(.small)
                    HStack(spacing: 8) {
                        Button("左转 15°") { Task { await state.rotateHeld(-1) } }
                        Button("右转 15°") { Task { await state.rotateHeld(1) } }
                        Spacer()
                        Button("放回") { Task { await state.returnSelected() } }
                    }.controlSize(.small)
                } else {
                    Picker("放在", selection: Binding(get: { state.placement?.surfaceID ?? "" }, set: { id in Task { await state.selectSurface(id) } })) {
                        ForEach(state.snapshot.surfaces) { Text($0.name).tag($0.id) }
                    }
                    HStack(spacing: 8) {
                        Button("左转 45°") { Task { await state.rotate(-1) } }
                        Button("右转 45°") { Task { await state.rotate(1) } }
                        Spacer()
                        Button(state.isMoving ? "停止移动" : "移动") { state.toggleMoving() }
                    }.controlSize(.small)
                    HStack(spacing: 7) {
                        Text("微调").foregroundStyle(.secondary)
                        step("arrow.left", x: -0.1, z: 0); step("arrow.up", x: 0, z: -0.1)
                        step("arrow.down", x: 0, z: 0.1); step("arrow.right", x: 0.1, z: 0)
                        Spacer()
                        Button("收回") { Task { await state.withdraw() } }.disabled(state.selectedObject?.isEnabled != true)
                    }.controlSize(.small)
                    HStack {
                        Button("拿着看") { Task { await state.holdSelected() } }
                            .disabled(state.selectedHoldUnavailableReason != nil || state.isSaving)
                        if let reason = state.selectedHoldUnavailableReason {
                            Text(reason).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    if state.isMoving {
                        Text("移动指针选择落点，单击确认；Esc 取消")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            if !state.notice.isEmpty { Text(state.notice).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("撤销上次") { Task { await state.undo() } }.disabled(!state.snapshot.canUndo || state.isSaving)
                Spacer()
                if state.selectedID != nil && !state.isSelectedHeld {
                    Button("取消") { state.cancelPreview() }.disabled(state.isSaving)
                    Button(state.isSaving ? "保存中…" : "确认") { Task { await state.confirm() } }
                        .buttonStyle(.borderedProminent).tint(.cyan.opacity(0.7)).disabled(!state.canConfirm)
                }
            }.controlSize(.small)
        }
        .font(.system(size: 12)).padding(16)
        }
        .frame(maxHeight: 390)
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white.opacity(0.9))
        .background(Color(red: 0.075, green: 0.085, blue: 0.105).opacity(0.98), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 3)
        .onExitCommand { state.escape() }
        .disabled(state.isSaving)
    }
    private func step(_ icon: String, x: Float, z: Float) -> some View {
        Button { Task { await state.nudge(x: x, z: z) } } label: { Image(systemName: icon) }
            .help("移动 10 厘米")
    }
    private func holdStep(_ title: String, y: Float = 0, z: Float = 0) -> some View {
        Button(title) { Task { await state.nudgeHeld(y: y, z: z) } }
            .help("微调 2 厘米")
    }
}

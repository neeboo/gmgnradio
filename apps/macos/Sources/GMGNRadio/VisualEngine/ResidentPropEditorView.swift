import SwiftUI
import WorldRuntime

/// A temporary, quiet shelf. The actual object remains in the room during previews.
///
/// 2026-09-29：这里**不再是配置表单**。落点、朝向、放下都改在 3D 空间里用鼠标做
/// （射线命中哪一层就放哪一层；点地面放下；`R` / `⇧R` / `,` / `.` 或物件旁的圆环转
/// 45°；`Esc` 放回）。面板只留下"选哪一件"和几个不可替代的次要动作：撤销、收回，
/// 以及**居民右手**那一套（拿着看/放回/微调）——那是"居民真的把东西拿在手里"
/// （会持久化、要求 2B 角色、最长边 >0.45 m 直接拒绝），和鼠标携带是两件事。
struct ResidentPropEditorView: View {
    @ObservedObject var state: ResidentPropEditorState
    /// 尺寸滑块的手上草稿：拖动过程**不改世界**，松手才提交一次（提交要走摆放判定，
    /// 每拖动一格提交一次既贵又会让滑块和存档互相打架）。
    @State private var sizeDraft: Double = 0
    @State private var sizeDraftObjectID: String?
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
                                        // 状态文案只有一份推导（`ResidentPropEditorState.rowStatus`）：
                                        // **已入库但没摆出来**必须写着「尚未摆放」，不能只留一个空位 ——
                                        // 真机 2026-10-01 用户就是因此说"大剑还是消失了"。
                                        Text(ResidentPropEditorState.rowStatus(
                                            isHeld: state.snapshot.heldProp?.objectID == prop.objectID,
                                            isPlaced: object.isEnabled))
                                            .font(.system(size: 10))
                                            .foregroundStyle(state.snapshot.heldProp?.objectID == prop.objectID
                                                             ? Color.cyan
                                                             : (object.isEnabled ? Color.secondary : Color.orange.opacity(0.9)))
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
                    // 不做落点配置：层由射线命中决定，朝向与放下都在空间里完成。
                    HStack(spacing: 8) {
                        Button("拿着看") { Task { await state.holdSelected() } }
                            .disabled(state.selectedHoldUnavailableReason != nil || state.isSaving)
                        Button("收回") { Task { await state.withdraw() } }
                            .disabled(state.selectedObject?.isEnabled != true)
                    }.controlSize(.small)
                    if let reason = state.selectedHoldUnavailableReason {
                        Text(reason).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Text("移动指针选择落点，左键放下；右键旋转 45°（R / ⇧R / , / . 同）；Esc 放回")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                sizeControl
            }
            // 图例：用户连着两轮问"这两个红色的是什么意思" —— 缺的不是原因，是**画面没有图例**。
            // 一行、极短；颜色小方块直接取自格子渲染的同一份 `CellState.tint`
            // （`PropSupportGridPresentation.Legend`），这里**不写第二份 RGB**。
            HStack(spacing: 10) {
                ForEach(Array(PropSupportGridPresentation.Legend.entries.enumerated()), id: \.offset) { _, entry in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(
                                red: Double(entry.srgbTint.x),
                                green: Double(entry.srgbTint.y),
                                blue: Double(entry.srgbTint.z)
                            ))
                            .frame(width: 8, height: 8)
                        Text(entry.label).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            if !state.notice.isEmpty { Text(state.notice).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("撤销上次") { Task { await state.undo() } }.disabled(!state.snapshot.canUndo || state.isSaving)
                Spacer()
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
    private func holdStep(_ title: String, y: Float = 0, z: Float = 0) -> some View {
        Button(title) { Task { await state.nudgeHeld(y: y, z: z) } }
            .help("微调 2 厘米")
    }

    /// 尺寸：只改**这一件**物件自己的尺寸（写回它的 `size`，碰撞盒/红绿格/存档同一份）。
    ///
    /// 手动值**优先于**自动标定：`WorldGeneratedProp.isSizeLocked` 记着"这是用户定的"，
    /// 自动基线重新算过之后不会再覆盖它。
    @ViewBuilder private var sizeControl: some View {
        if let prop = state.selectedObject?.generatedProp, !state.isSelectedHeld {
            Divider().overlay(.white.opacity(0.08))
            Text("尺寸").foregroundStyle(.secondary)
            HStack(spacing: 6) {
                sizeStep("−10 cm", -0.10); sizeStep("−1 cm", -0.01)
                sizeStep("+1 cm", 0.01); sizeStep("+10 cm", 0.10)
                Spacer()
                Text(String(format: "最长边 %.2f m", prop.longestEdge))
                    .font(.system(size: 11)).monospacedDigit()
            }.controlSize(.small)
            HStack(spacing: 8) {
                Slider(
                    value: Binding(get: { sizeDraftObjectID == prop.objectID ? sizeDraft : Double(prop.longestEdge) },
                                   set: { sizeDraftObjectID = prop.objectID; sizeDraft = $0 }),
                    in: Double(WorldPropSizePolicy.minimumExtentMeters)...Double(WorldPropSizePolicy.maximumExtentMeters),
                    onEditingChanged: { editing in
                        guard !editing, sizeDraftObjectID == prop.objectID else { return }
                        Task { await state.resize(toLongestEdge: Float(sizeDraft)) }
                    }
                ).tint(.cyan.opacity(0.86)).accessibilityLabel("物件最长边")
                Text(String(format: "%.2f m", sizeDraftObjectID == prop.objectID ? sizeDraft : Double(prop.longestEdge)))
                    .font(.system(size: 11)).monospacedDigit().frame(width: 52, alignment: .trailing)
            }
            Text(String(format: "长 %.2f × 高 %.2f × 深 %.2f m（等比缩放；0.02–3.00 m）",
                        prop.effectiveSize.x, prop.effectiveSize.y, prop.effectiveSize.z))
                .font(.system(size: 10)).foregroundStyle(.secondary)
            // 「这个尺寸是怎么定的」：四态出处（手动 / 尺寸意图 / 权威 / 推断）之一。
            // 越界时上面那条 `notice` 会说原因，这里说**数字的来源**，两者都不静默。
            if let provenance = state.selectedSizeProvenance {
                Text("尺寸来源 · " + provenance)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("resident.prop-editor.size-provenance")
            }
        }
    }

    private func sizeStep(_ title: String, _ delta: Float) -> some View {
        Button(title) {
            Task { await state.resize(toLongestEdge: (state.selectedLongestEdge ?? 0) + delta) }
        }
        .help("在最长边上微调 \(delta) 米；越界会被拒绝并说明原因")
    }
}

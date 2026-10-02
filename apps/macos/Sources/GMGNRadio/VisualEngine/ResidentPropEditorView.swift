import SwiftUI
import WorldRuntime

/// A temporary, quiet shelf. The actual object remains in the room during previews.
///
/// 2026-09-29：这里**不再是配置表单**。落点、朝向、放下都改在 3D 空间里用鼠标做
/// （射线命中哪一层就放哪一层；点地面放下；`R` / `⇧R` / `,` / `.` 或物件旁的圆环转
/// 45°；`Esc` 放回）。面板只留下"选哪一件"和几个不可替代的次要动作：撤销、收回，
/// 以及**居民右手**那一套（拿着看/放回/微调）——那是"居民真的把东西拿在手里"
/// （会持久化、要求 2B 角色、最长边超过
/// `ResidentPropAttachmentEligibility.holdableLongestEdgeText` 直接拒绝），和鼠标携带是两件事。
struct ResidentPropEditorView: View {
    @ObservedObject var state: ResidentPropEditorState
    /// 尺寸滑块的手上草稿：拖动过程**不改世界**，松手才提交一次（提交要走摆放判定，
    /// 每拖动一格提交一次既贵又会让滑块和存档互相打架）。
    @State private var sizeDraft: Double = 0
    @State private var sizeDraftObjectID: String?
    /// 「永久删除」的确认态（面板上那一次点击只把它置真，真正提交在确认之后）。
    @State private var confirmingDelete = false
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
            // 「我的物件」是**你许愿过 / 拥有过的所有东西的目录**（每行一句状态）；
            // 「房间里」仍然是**已摆放**（语义一个字没改，见 `ResidentPropEditorState.ownershipList`）。
            //
            // 分组、对外状态、折叠、动作**全部**来自唯一投影 `ResidentOwnershipProjection`：
            // 视图不判状态、不拼状态文案（第二套投影与第四套文案已退场）。
            ownershipList
            if state.selectedID != nil {
                Divider().overlay(.white.opacity(0.08))
                if state.isSelectedHeld {
                    HStack(spacing: 8) {
                        Text("\(PropAttachmentSlots.displayName(for: state.selectedHoldPoint))展示微调")
                            .foregroundStyle(.secondary)
                        Spacer()
                        slotPicker
                    }
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
                        Spacer()
                        slotPicker
                    }.controlSize(.small)
                    if let reason = state.selectedHoldUnavailableReason {
                        Text(reason).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Text("移动指针选择落点，左键放下；右键旋转 45°（R / ⇧R / , / . 同）；Esc 放回")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                // 「删除」是**永久**的，所以它必须问一次。放在这里（而不是塞进那一排小按钮）
                // 是为了让它读起来就是"不可逆"，而不是"又一个操作"。
                HStack(spacing: 8) {
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        Label("删除", systemImage: "trash")
                    }
                    .disabled(state.isSaving)
                    .help("永久删除这一件生成资产：不可恢复。正在摆放或拿在手里的会先收场再删。")
                    Spacer()
                }.controlSize(.small)
                sizeControl
            }
            // 图例：用户连着两轮问"这两个红色的是什么意思" —— 缺的不是原因，是**画面没有图例**。
            // 一行、极短；颜色小方块直接取自格子渲染的同一份 `CellState.tint`
            // （`PropSupportGridPresentation.Legend`），这里**不写第二份 RGB**。
            HStack(spacing: 10) {
                // 蓝色那一枚只在**真的派生出竖直面**时才出现：平房间里多一个"能靠墙放"
                // 的图例，用户会去找一堵根本不存在的墙。
                ForEach(Array(PropSupportGridPresentation.Legend.entries
                    .filter { $0.state != .wallPlaceable || state.snapshot.wallFaces > 0 }
                    .enumerated()), id: \.offset) { _, entry in
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
            // 「靠墙」：读的是**判据说可以**的格子数，不是"几何上看起来能靠"。一堵墙都没派生
            // 出来时如实说"没有竖直面"，而不是显示一个 0 让人以为"有墙但放不了"。
            Text(state.snapshot.wallFaces == 0
                 ? "靠墙 · 这个空间里没有识别到竖直面"
                 : "靠墙 · \(state.snapshot.wallFaces) 面墙，\(state.snapshot.wallPlaceableCells) 格可背朝墙放置")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .accessibilityIdentifier("resident.prop-editor.wall-placement")
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
        // 永久删除必须**问一次**：文案里说清它是什么、以及"正在摆放/在手里"会怎么收场，
        // 确认按钮自己也写着「永久删除」（不是含糊的"确定"）。
        .confirmationDialog(
            "永久删除「\(state.selectedObject?.generatedProp?.displayName ?? "这一件")」？",
            isPresented: $confirmingDelete, titleVisibility: .visible
        ) {
            Button("永久删除", role: .destructive) { Task { await state.deleteSelected() } }
            Button("取消", role: .cancel) { }
        } message: {
            Text("删除不可恢复。它不会再出现在「我的物件」里；如果它正摆在房间里或拿在居民手里，"
                 + "会在同一次操作里先收回/放回再删掉。还被别的物件引用的共享内容会保留。")
        }
    }
    /// 「我的物件」列表 = 唯一投影算出来的四组，一组一块。
    ///
    /// 视图在这里**不做任何判断**：组的顺序、每组的行、行够不够显示（「还有 N 件」）、
    /// 「已结束」折不折叠，全是 `OwnershipList` / `OwnershipSection` 说的。
    @ViewBuilder
    private var ownershipList: some View {
        let list = state.ownershipList
        if list.rowCount == 0 {
            Text(state.showsPlacedOnly
                 ? "房间里还没有摆放物件"
                 : "还没有许愿。对居民说你想要什么，做好后会出现在这里。")
                .foregroundStyle(.secondary).font(.system(size: 12)).padding(.vertical, 14)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(list.sections, id: \.group) { section in
                        ownershipSection(section)
                    }
                    // 「看不见的列表」正是这次要修的病：放不下时说清楚还有几件，不静默截断。
                    if list.remainingCount > 0 {
                        Text("还有 \(list.remainingCount) 件")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .padding(.horizontal, 9)
                            .accessibilityIdentifier("resident.ownership.remaining")
                    }
                }
            }
            // 190 pt（宽度 340 不动）。放不下时上面那句「还有 N 件」兜住。
            .frame(maxHeight: CGFloat(ResidentOwnershipProjection.panelListHeightPoints))
        }
    }

    /// 一组：组头 + 这一组的行。「已结束」默认折叠（Q1：**折叠可见**，不是隐藏）。
    @ViewBuilder
    private func ownershipSection(_ section: OwnershipSection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if section.isFolded {
                    Button { state.showsEnded = true } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.right")
                            Text(ResidentOwnershipProjection.sectionTitle(section))
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("resident.ownership-section.\(section.group.rawValue)")
                } else {
                    Text(ResidentOwnershipProjection.sectionTitle(section))
                    if section.group == .ended {
                        Button("收起") { state.showsEnded = false }.buttonStyle(.plain)
                    }
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(section.rows) { row in
                ownershipRow(row)
            }
        }
    }

    /// 一行。**状态文案只有一份**：`row.statusText`（唯一投影给的 `OwnershipSentence`）。
    /// 视图里因此没有任何状态字面量 —— 在这里拼一句就是第二份真相。
    ///
    /// 行内动作也由投影派生（`row.actions`），视图不判"能不能领 / 能不能重试"。
    ///
    /// 一行的样子**只有三样**：名字 / 一句人话状态 / 能做的事（按钮）。
    /// 2026-10-02 用户原话：「不要搞为什么然后给展开折叠，普通人看得懂吗，里面一堆
    /// key-value 的东西」—— 所以这里**没有**「为什么」入口、**没有**展开的证据面板、
    /// 也**没有**把内部 join 方式（`sourceWishID` 这类）写在副标题里。字段名、回执键、
    /// UUID、路径是给我们和 agent 看的，留在统一日志（subsystem=ai.gmgn.radio）与
    /// agent 回执里，不上界面。
    @ViewBuilder
    private func ownershipRow(_ row: OwnershipRow) -> some View {
        let isSelected = state.selectedID == row.key.objectID
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Image(systemName: ownershipIcon(row))
                Text(row.name).lineLimit(1)
                Spacer(minLength: 2)
                Text(row.statusText).font(.system(size: 10))
                    .foregroundStyle(ownershipTint(row)).lineLimit(1)
                if isSelected { Image(systemName: "checkmark").foregroundStyle(.cyan) }
            }
            .contentShape(Rectangle())
            // 点行 = 既有的携带态入口（摆放 / 收回都在 3D 里完成），语义一个字没改。
            .onTapGesture {
                guard row.actions.contains(.place) || row.actions.contains(.withdraw) else { return }
                Task { await state.select(objectID: row.key.objectID) }
            }
            // 第二样之外的**唯一**一层：能做的事。不再有第三个按钮来解释它们为什么在那里。
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                ownershipActions(row)
            }.controlSize(.small)
        }
        .padding(9).frame(maxWidth: .infinity)
        .background(isSelected ? Color.white.opacity(0.08) : Color.white.opacity(0.03),
                    in: RoundedRectangle(cornerRadius: 8))
        .disabled(state.isSaving)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("resident.ownership-row.\(row.id)")
    }

    /// 行内动作 → **既有**那几条路。视图只负责把投影给的动作摆出来。
    @ViewBuilder
    private func ownershipActions(_ row: OwnershipRow) -> some View {
        HStack(spacing: 5) {
            if row.actions.contains(.claim), let jobID = row.key.jobID?.uuidString {
                Button("领取") { Task { await state.claimWish(jobID: jobID) } }
                    .accessibilityIdentifier("resident.ownership-row.\(row.id).claim")
            }
            if row.actions.contains(.askResidentToFetch) {
                // Q4：「领取」够不到许愿机 ⇒ 按钮**可见但置灰**，并给「让居民去取」
                // （既有 agent 路径）。为什么够不到**不在界面上解释**：那一句是投影里的
                // 工程原因（可能要带字段与数值），只进统一日志与 agent 回执。
                // `claim()` 判据一个字不改。
                Button("领取") {}.disabled(true)
                // 「让居民去取」走既有的 agent 路径（`claim_when_arrived`）：
                // **不新增人类通道、不放宽 0.25 m / activityID 判据**。
                Button("让居民去取") {
                    Task { await state.askResidentToFetch(jobID: row.key.jobID?.uuidString ?? "") }
                }
                .accessibilityIdentifier("resident.ownership-row.\(row.id).ask-resident")
            }
            if row.actions.contains(.retry), let jobID = row.key.jobID?.uuidString {
                Button("重试") { Task { await state.retryWish(jobID: jobID) } }
                    .accessibilityIdentifier("resident.ownership-row.\(row.id).retry")
            }
            // 「已领取但没入库」的下一步**不是**重新生成（`retryableStages` 不含 `.claimed`，
            // 重发会多出一件）：走既有的入库补做重入。
            if row.actions.contains(.retryInventoryRegistration), let jobID = row.key.jobID?.uuidString {
                Button("重试入库") { Task { await state.retryWishInventory(jobID: jobID) } }
                    .accessibilityIdentifier("resident.ownership-row.\(row.id).retry-inventory")
            }
            if row.actions.contains(.withdraw) {
                Button("收回") { Task { await state.select(objectID: row.key.objectID); await state.withdraw() } }
            }
            if row.actions.contains(.delete) {
                Button("删除") {
                    Task { await state.select(objectID: row.key.objectID); confirmingDelete = true }
                }
            }
        }
    }

    /// 图标只承担**语义分组**（不是文案）：状态词一律读 `row.statusText`。
    private func ownershipIcon(_ row: OwnershipRow) -> String {
        switch row.state {
        case .generating: return "hourglass"
        case .awaitingClaim: return "arrow.down.circle"
        case .inInventory: return "shippingbox"
        case .placed: return "cube.box"
        case .failed: return "exclamationmark.triangle"
        case .ended: return "archivebox"
        }
    }

    private func ownershipTint(_ row: OwnershipRow) -> Color {
        switch row.state {
        case .awaitingClaim: return .cyan
        case .inInventory: return .orange.opacity(0.9)
        case .failed: return .red.opacity(0.9)
        case .generating, .placed, .ended: return .secondary
        }
    }

    /// 挂点：手里 / 背后 / 腰间。
    /// 改一下就是一次**世界命令**（没拿时是「拿起」，已经拿在手上时是就地换挂点），
    /// 不是本地开关：找不到那个挂点的骨骼时世界会拒绝并给出读得懂的理由，选中格自己会弹回
    /// （`selectedHoldPoint` 读的是世界状态那一份，不是这里记的一份）。
    private var slotPicker: some View {
        Picker("挂点", selection: Binding(
            get: { state.selectedHoldPoint },
            set: { point in Task { await state.holdSelected(at: point) } }
        )) {
            ForEach(PropAttachmentPoint.allCases, id: \.self) { point in
                Text(PropAttachmentSlots.displayName(for: point)).tag(point)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 156)
        .controlSize(.small)
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

// 已从产品界面移除（用户要求：左下角那块电视面板不应该出现）；保留代码供将来用别的入口。
import SwiftUI

/// 电视面板：**放 / 停 / 换片 / 调整屏幕范围**，以及"这块屏幕的范围是哪来的"。
///
/// 三条纪律写在这个视图里，不是写在注释里：
/// - 面板上**只有人话**：这台叫什么、屏幕范围是自动认出来的还是你标定的、能做什么。
///   出处原话（法向 / 面积 / 格数 / 毫秒）是**工程口径**，留在
///   `WorldScreenSnapshot.note` / `.occlusionText` 那条线上（日志 `subsystem = ai.gmgn.radio`
///   与 agent 工具），**不进这里** —— 真机 2026-10-02 用户原话：「什么玩意儿」，
///   以及上一轮同一句：「不要搞为什么然后给展开折叠，普通人看得懂吗，里面一堆 key-value 的东西」；
/// - 几何给不出来时显示**人话的下一步**（点「调整屏幕范围」），而不是把具名原因摆出来；
/// - 换片只有一个输入框，接受的三种输入（嵌入链接 / 观看链接 / 裸 id）在
///   placeholder 里说清楚；不在白名单里的输入会被**具体**拒绝。
///
/// 每一个字都来自 `ScreenPanelCopy`（纯函数、可离线逐字断言），这里不另写一句话。
///
/// 宽度由宿主（`StageContentView`）约束成 340，与既有面板同规格 —— 这里不设宽度。
struct ScreenPanelView: View {
    @ObservedObject var store: WorldScreenStore
    /// 关掉面板。宿主（`StageContentView`）负责把这一页收起来 ——
    /// 面板自己不拥有自己的可见性。
    var onClose: (() -> Void)?
    @State private var draftURL: String = ""
    @State private var calibratingObjectID: String?
    @State private var widthDraft: Double = 1.10
    @State private var heightDraft: Double = 0.62
    @State private var centerDraft: Double = 1.05
    @State private var lastNotice: String?
    @State private var isBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ScreenContentField(draftURL: $draftURL)
            if store.snapshots.isEmpty {
                Text("这个空间里还没有电视。生成一件电视（名字里带 TV / 屏幕 / 电视），或者在下面手动指定一件物件。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(store.snapshots, id: \.objectID) { snapshot in
                            row(snapshot)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
            if let lastNotice {
                Text(lastNotice)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(ScreenPanelCopy.capacityLine(maximum: WorldScreenStore.maximumSimultaneousScreens))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("电视", systemImage: "tv").font(.system(size: 14, weight: .semibold))
            Spacer()
            if let onClose {
                Button { onClose() } label: {
                    Image(systemName: "xmark").frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("收起电视面板")
            }
            Button {
                isBusy = true
                Task {
                    // 开关作用于"唯一的那一台"：多台时必须显式选（面板里每行各有自己的按钮）。
                    if store.snapshots.count == 1, let only = store.snapshots.first {
                        if only.isPlaying {
                            lastNotice = store.stopScreen(objectID: only.objectID).message
                        } else if !draftURL.isEmpty {
                            lastNotice = await store.playScreen(
                                objectID: only.objectID, rawContent: draftURL
                            ).message
                        } else {
                            lastNotice = WorldScreenContentIssue.missingInput.errorDescription
                        }
                    } else {
                        lastNotice = "空间里不止一台电视，请在下面那一行上按「放 / 停」。"
                    }
                    isBusy = false
                }
            } label: {
                Image(systemName: "power").frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .help("开/关唯一的那台电视")
        }
    }

    private func row(_ snapshot: WorldScreenSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(snapshot.displayName).font(.system(size: 12, weight: .medium))
                Spacer()
                Button(ScreenPanelCopy.playActionTitle) {
                    Task {
                        isBusy = true
                        lastNotice = await store.playScreen(
                            objectID: snapshot.objectID, rawContent: draftURL
                        ).message
                        isBusy = false
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .disabled(isBusy)
                Button(ScreenPanelCopy.stopActionTitle) {
                    lastNotice = store.stopScreen(objectID: snapshot.objectID).message
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                Button(ScreenPanelCopy.adjustRangeActionTitle) {
                    calibratingObjectID = calibratingObjectID == snapshot.objectID
                        ? nil : snapshot.objectID
                    if snapshot.aspect > 0 {
                        widthDraft = Double(snapshot.aspect) * heightDraft
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
            }
            // 这块屏幕的范围是哪来的 —— **一句人话**。工程口径的 `snapshot.note`
            // （法向 / 面积 / m²）不进面板：它在日志与 agent 回执里。
            Text(ScreenPanelCopy.screenRangeLine(
                source: snapshot.source, hasGeometryIssue: snapshot.geometryIssue != nil
            ))
                .font(.system(size: 10))
                .foregroundStyle(snapshot.source == .calibrated ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
            if let status = ScreenPanelCopy.statusLine(
                for: snapshot.surfaceState, isPlaying: snapshot.isPlaying
            ) {
                Text(status)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // 画面被挡住时**只说一句**、只在真被挡时说，而且说不出格数与毫秒
            // （那种每帧都在变的数才是刷屏的来源）。工程的账在 `snapshot.occlusionText`。
            if let occlusion = ScreenPanelCopy.occlusionLine(isBlocked: snapshot.isBlocked) {
                Text(occlusion)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if calibratingObjectID == snapshot.objectID {
                calibrationFields(snapshot)
            }
        }
        .padding(8)
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
    }

    private func calibrationFields(_ snapshot: WorldScreenSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("宽").font(.system(size: 10))
                TextField("m", value: $widthDraft, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 56)
                Text("高").font(.system(size: 10))
                TextField("m", value: $heightDraft, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 56)
                Text("中心高").font(.system(size: 10))
                TextField("m", value: $centerDraft, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 56)
            }
            HStack(spacing: 6) {
                Button("就按这个大小") {
                    lastNotice = store.calibrateScreen(
                        objectID: snapshot.objectID,
                        widthMeters: Float(widthDraft),
                        heightMeters: Float(heightDraft),
                        centerHeightMeters: Float(centerDraft)
                    ).message
                    calibratingObjectID = nil
                }
                .buttonStyle(.plain).font(.system(size: 11))
                Button("让系统自己认") {
                    lastNotice = store.designateScreen(objectID: snapshot.objectID, size: nil).message
                    calibratingObjectID = nil
                }
                .buttonStyle(.plain).font(.system(size: 11))
            }
        }
        .padding(.top, 2)
    }
}

/// 换片输入框单独抽出来，是为了让"接受哪三种输入"只有一处说法。
struct ScreenContentField: View {
    @Binding var draftURL: String

    var body: some View {
        TextField(ScreenPanelCopy.contentPlaceholder, text: $draftURL)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11))
    }
}

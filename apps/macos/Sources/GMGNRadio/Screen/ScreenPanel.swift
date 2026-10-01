import SwiftUI

/// 电视面板：**开关 / 换片 / 标定**，以及"这块屏幕的几何是哪来的"。
///
/// 三条纪律写在这个视图里，不是写在注释里：
/// - 几何出处是 `缺省` 或 `推断` 时，**必须**把 `note` 原文显示出来 ——
///   "屏幕位置是猜的"这句话要看得见，不能只活在日志里；
/// - 几何给不出来时显示**具名原因**，并且把"标定"三个输入放在同一行，
///   让用户能当场把缺的那一级补上；
/// - 换片只有一个输入框，接受的三种输入（嵌入链接 / 观看链接 / 裸 id）在
///   placeholder 里说清楚；不在白名单里的输入会被**具体**拒绝。
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
                Text("这个空间里还没有电视。生成一件电视（名字里带 TV / 屏幕 / 电视），或在下面标定一件物件。")
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
            Text("同时最多放 \(WorldScreenStore.maximumSimultaneousScreens) 块屏幕；看不见的屏幕会自动暂停（不掉登录态）。")
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
                sourceBadge(snapshot.source)
                Spacer()
                Button("放") {
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
                Button("停") {
                    lastNotice = store.stopScreen(objectID: snapshot.objectID).message
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                Button(snapshot.geometryIssue == nil ? "标定" : "标定…") {
                    calibratingObjectID = calibratingObjectID == snapshot.objectID
                        ? nil : snapshot.objectID
                    if snapshot.aspect > 0 {
                        widthDraft = Double(snapshot.aspect) * heightDraft
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
            }
            // 几何出处原话：**必须显示**。缺省/推断时这就是"我们在猜"的公告。
            Text(snapshot.note.isEmpty ? snapshot.stateText : snapshot.note)
                .font(.system(size: 10))
                .foregroundStyle(snapshot.source == .calibrated ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
            if !snapshot.isPlaying {
                Text(snapshot.stateText)
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
                Button("写进这件物件") {
                    lastNotice = store.calibrateScreen(
                        objectID: snapshot.objectID,
                        widthMeters: Float(widthDraft),
                        heightMeters: Float(heightDraft),
                        centerHeightMeters: Float(centerDraft)
                    ).message
                    calibratingObjectID = nil
                }
                .buttonStyle(.plain).font(.system(size: 11))
                Button("按尺寸自动推断") {
                    lastNotice = store.designateScreen(objectID: snapshot.objectID, size: nil).message
                    calibratingObjectID = nil
                }
                .buttonStyle(.plain).font(.system(size: 11))
            }
        }
        .padding(.top, 2)
    }

    private func sourceBadge(_ source: WorldScreenSource?) -> some View {
        let (text, colour): (String, Color) = switch source {
        case .calibrated: ("标定", .green)
        case .inferred: ("推断", .orange)
        case .default: ("缺省", .red)
        case nil: ("无几何", .red)
        }
        return Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(colour.opacity(0.22), in: Capsule())
            .foregroundStyle(colour)
    }
}

/// 换片输入框单独抽出来，是为了让"接受哪三种输入"只有一处说法。
struct ScreenContentField: View {
    @Binding var draftURL: String

    var body: some View {
        TextField(
            "官方嵌入链接 / 观看链接 / 视频 id（YouTube、哔哩哔哩、Twitch）",
            text: $draftURL
        )
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 11))
    }
}

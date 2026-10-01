import AppKit
import SwiftUI
import UniformTypeIdentifiers
import simd

@MainActor
final class StageResidentChatState: ObservableObject {
    @Published var draft = ""
    @Published private(set) var reply = ""
    @Published private(set) var isThinking = false
    @Published var voiceActive = false
    @Published var deliveryNotice: String?
    @Published var progress: String?
    /// 拖着图片经过对话面板时落点是否亮着。**只由落点自己的命中判据点亮**：非图片
    /// 拖拽（文本、别的文件）不会走到 `draggingEntered` 的接受分支，所以不会亮。
    @Published var isImageDropTargeted = false
    @Published private(set) var statusNotice: String?
    /// 当前状态行的类别，决定它能否被普通提示覆盖（见 ResidentStatusNoticeMerge）。
    private(set) var statusKind: ResidentStatusNoticeKind = .info
    @Published var canStop = false
    /// 最近对话（宿主持有的同一份快照）：用户提交的回合 + 居民回复，按回合可
    /// 回看。展示层只渲染，不做回合判定，与 LiveCam 口径一致。
    @Published private(set) var transcript: [ResidentChatTranscriptLine] = []
    let images = ResidentAttachmentStore()
    private var recovery = ResidentDraftRecovery()

    init() { images.onChange = { [weak self] in self?.objectWillChange.send() } }

    func takeMessage() -> ResidentChatSubmission? {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard images.canSubmit, !message.isEmpty || !images.attachments.isEmpty else { return nil }
        draft = ""
        recovery = ResidentDraftRecovery()
        begin()
        return ResidentChatSubmission(text: message, attachments: images.takeAttachments())
    }

    func restore(_ submission: ResidentChatSubmission, error: Error) {
        restore(submission, notice: error.localizedDescription)
    }

    func restore(_ submission: ResidentChatSubmission, notice: String) {
        let recovered = recovery.restore(submission, text: draft, attachments: images.attachments)
        draft = recovered.text
        images.restore(recovered.attachments)
        setThinking(false)
        // 失败回填是失败提示，不能被下一条普通应用信息盖掉。
        showFailureStatus(notice + "\n文字和图片已保留。")
    }

    func begin() { reply = ""; applyStatus(nil, kind: .info); isThinking = true }
    /// 宿主推送的最近对话快照：只替换展示数据，不影响状态行/回合判定。
    func setTranscript(_ lines: [ResidentChatTranscriptLine]) { transcript = lines }
    func setThinking(_ thinking: Bool) {
        if thinking && !isThinking { applyStatus(nil, kind: .info) }
        isThinking = thinking
        if !thinking { progress = nil }
    }
    func finish(_ text: String) { reply = text; applyStatus(nil, kind: .info); setThinking(false) }
    func showStatus(_ text: String) { applyStatus(text, kind: .info) }
    /// 语音连接/收音的临时提示，连接成功或断麦后可用 dismissVoiceStatus 清除。
    func showVoiceStatus(_ text: String) { applyStatus(text, kind: .voice) }
    /// 需要用户确认或重试的失败；普通提示绝不覆盖它。
    func showFailureStatus(_ text: String) { applyStatus(text, kind: .failure) }
    func dismissStatus() { applyStatus(nil, kind: .info) }
    /// 只清除语音临时提示，绝不抹掉真正的失败提示。
    func dismissVoiceStatus() {
        guard statusKind == .voice else { return }
        applyStatus(nil, kind: .info)
    }
    /// 换世界/换后端等上下文切换：旧提示全部作废（含旧失败），新上下文重新开始。
    func clearTransient() {
        applyStatus(nil, kind: .info)
        progress = nil
    }
    private func applyStatus(_ text: String?, kind: ResidentStatusNoticeKind) {
        let decision = ResidentStatusNoticeMerge.resolve(
            incoming: text,
            kind: kind,
            current: statusNotice,
            currentKind: statusKind
        )
        statusNotice = decision.text
        statusKind = decision.kind
    }
    func cancel() { setThinking(false); showStatus("已停止本次回复。") }
}

/// Separate from the reply so a failed voice request never hides readable text.
@MainActor
struct ResidentSpeechErrorNotice: View {
    private let status = AgentSpeechStatusStore.shared

    var body: some View {
        if let message = status.lastErrorMessage, !message.isEmpty {
            Label(message, systemImage: "speaker.slash")
                .font(.system(size: 11))
                .foregroundStyle(.orange.opacity(0.95))
                .lineLimit(3)
                .help(message)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(white: 0.1).opacity(0.96), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// Async wish jobs remain visible independently of the resident's reply and thinking state.
/// Terminal tasks hide 30 seconds after their stored prompt anchor; the expiry
/// timestamp is persisted in the shared inbox, so refreshes and reopenings
/// never keep a finished task resident. In-progress and pending tasks stay.
@MainActor
struct WishMachineTaskStatusView: View {
    @ObservedObject var state: WishMachineTaskPresentationStore
    var maximumHeight: CGFloat = 132
    var compact = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let visible = state.tasks.filter { task in
                guard let expiry = task.promptExpiresAt else { return true }
                return timeline.date < expiry
            }
            VStack(alignment: .leading, spacing: 6) {
                connectivityBanner
                autonomyBanner
                if !visible.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("许愿任务")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                        ScrollView {
                            VStack(alignment: .leading, spacing: 9) {
                                ForEach(visible) { task in
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                                            Image(systemName: task.isTerminal ? "circle.fill" : "clock")
                                                .font(.system(size: 8))
                                            Text(task.title).lineLimit(1)
                                            Spacer(minLength: 2)
                                            Text(task.status).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                                        }
                                        .font(.system(size: 11, weight: .medium))
                                        // **任务行只表达它自己的三轴状态（生成/归属/摆放）。**
                                        // 授权在全局开关（autonomyBanner）上，连通性在全局横幅
                                        // （connectivityBanner）上；任务行上不存在任何按任务的
                                        // "停止/恢复"控件 —— "能不能自主"不是任务状态。
                                        if !compact, let axes = task.axes {
                                            HStack(spacing: 4) {
                                                axisChip("生成", axes.generation.label)
                                                    .accessibilityIdentifier("resident.wish-task.\(task.id.uuidString).generation")
                                                axisChip("归属", axes.ownership.label)
                                                    .accessibilityIdentifier("resident.wish-task.\(task.id.uuidString).ownership")
                                                axisChip("摆放", axes.placement.label)
                                                    .accessibilityIdentifier("resident.wish-task.\(task.id.uuidString).placement")
                                            }
                                        }
                                        if !compact, let detail = task.detail, !detail.isEmpty {
                                            Text(detail)
                                                .font(.system(size: 10))
                                                .foregroundStyle(.white.opacity(0.6))
                                                .lineLimit(2)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .help([task.title, task.status, task.detail].compactMap { $0 }.joined(separator: "\n"))
                                    .accessibilityElement(children: .combine)
                                    .accessibilityIdentifier("resident.wish-task.\(task.id.uuidString)")
                                }
                            }
                        }
                        .frame(height: min(maximumHeight, CGFloat(visible.count) * (compact ? 20 : 48)))
                    }
                    .foregroundStyle(.white)
                    .padding(compact ? 6 : 10)
                    .background(Color(white: 0.1).opacity(0.96), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityIdentifier("resident.wish-tasks")
                }
            }
        }
    }

    /// 三轴里的一格：只说"哪条轴 = 现在是什么"。任务行不在这里表达授权或连通性。
    @ViewBuilder
    private func axisChip(_ title: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(title).foregroundStyle(.white.opacity(0.45))
            Text(value).foregroundStyle(.white.opacity(0.85))
        }
        .font(.system(size: 9))
        .lineLimit(1)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Color.white.opacity(0.08), in: Capsule())
    }

    /// **连通性是全局事实，不是任务属性。**
    ///
    /// 连不上后台（`network_unavailable` / `remote_unavailable` 这类连通性事实）时，
    /// 舞台/小窗顶部出现这一条横幅：可读原因 + "恢复后会自己继续"。它由任务投影里的
    /// 连通性事实**算出来**（`WishMachineTaskPresentationStore.update`），不另存一份；
    /// 投影不再报连通性事实时它就自动消失，不需要用户关掉它。
    @ViewBuilder
    private var connectivityBanner: some View {
        if let notice = state.connectivityNotice {
            Label(notice, systemImage: "wifi.exclamationmark")
                .font(.system(size: compact ? 9 : 11))
                .foregroundStyle(.orange.opacity(0.95))
                .lineLimit(compact ? 2 : 3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(compact ? 6 : 10)
                .background(Color(white: 0.1).opacity(0.96), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("resident.connectivity-banner")
        }
    }

    /// **一个全局开关**：允许居民自主行动。
    ///
    ///   - 关着 ⇒ 不自己动手，但你仍可下令；开着 ⇒ 它可以自己去领去摆。
    ///   - 「用户显式停止」仍然有效（安全语义保留）：停止后不自主。停止的证据有
    ///     三份（run 级停止 / 任务级持久暂停 / 投影文本里的停止事实），任意一份
    ///     为真这里就亮 —— 但页面上的解除只有**一个**动作。
    ///   - 解除只需这**一个**动作，且**不需要按任务逐个恢复**：一次点击打开开关、
    ///     解除 run 级停止，并把所有被用户停过的任务一次解开。做不成时这里一定有话说。
    ///
    /// 这就是"能不能自主"的入口 —— 任务行上不再有任何按任务的停止/恢复控件。
    /// 开关的值直接读设置里那**一个**键（`state.isAutonomySwitchOn`），不另存一份；
    /// 外层 `TimelineView` 每秒重算，所以设置里改一下这里一秒内跟上。
    @ViewBuilder
    private var autonomyBanner: some View {
        if !state.isAutonomySwitchOn || state.isAutonomyStoppedByUser {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Label(
                        state.isAutonomySwitchOn ? "自主行动已停止" : "居民自主行动已关闭",
                        systemImage: state.isAutonomySwitchOn ? "pause.circle" : "hand.raised"
                    )
                    .font(.system(size: compact ? 9 : 10))
                    .foregroundStyle(.orange.opacity(0.95))
                    .lineLimit(1)
                    Spacer(minLength: 2)
                    Button(state.isAutonomySwitchOn ? "恢复自主行动" : "打开自主行动") {
                        state.resumeAutonomy()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: compact ? 9 : 10, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.16), in: Capsule())
                    .accessibilityIdentifier("resident.autonomy.resume")
                }
                if !compact {
                    Text("不自主不等于不听话：直接下达的指令在任何开关状态下都会执行。")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let failure = state.autonomyResumeFailure {
                    Text(failure)
                        .font(.system(size: 9))
                        .foregroundStyle(.orange.opacity(0.95))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("resident.autonomy.resume-failure")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(.white)
            .padding(compact ? 6 : 10)
            .background(Color(white: 0.1).opacity(0.96), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityIdentifier("resident.autonomy-banner")
        }
    }
}

/// A quiet, native input surface shared with the resident's existing session.
@MainActor
struct StageResidentComposer: View {
    @ObservedObject var state: StageResidentChatState
    private let speechStatus = AgentSpeechStatusStore.shared
    let onSendMessage: @MainActor (ResidentChatSubmission) async throws -> Void
    let onCancelMessage: @MainActor () -> Void
    let onToggleVoice: @MainActor () -> Void
    let onFocusInput: @MainActor () -> Void
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ResidentSpeechErrorNotice()
            if !state.transcript.isEmpty || !state.reply.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            // 最近对话：按回合回看，含未送达/取消的明确标记；只有
                            // 与历史重复的后台回复才不重复显示。
                            ForEach(Array(state.transcript.enumerated()), id: \.offset) { _, line in
                                let label = ResidentChatTranscriptLine.speakerLabel(line.speaker)
                                VStack(alignment: .leading, spacing: 2) {
                                    if !label.isEmpty {
                                        Text(label)
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(.white.opacity(0.45))
                                    }
                                    Text(line.text)
                                        .font(.system(size: 13))
                                        .foregroundStyle(line.speaker == .notice
                                            ? Color.orange.opacity(0.95) : .white.opacity(0.9))
                                        .lineSpacing(4)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            if let standalone = ResidentChatTranscriptLine.standaloneReply(
                                state.reply, in: state.transcript
                            ) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("居民")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.45))
                                    Text(standalone)
                                        .font(.system(size: 13))
                                        .foregroundStyle(.white.opacity(0.9))
                                        .lineSpacing(4)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 132)
                    .accessibilityIdentifier("stage.resident-transcript")
                    if !state.reply.isEmpty {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(state.reply, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 12))
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.55))
                        .help("复制最新回复")
                        .accessibilityLabel("复制最新回复")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(white: 0.1).opacity(0.96), in: RoundedRectangle(cornerRadius: 16))
            }

            VStack(alignment: .leading, spacing: 12) {
                // 落点提示：拖着图片经过时面板边框/底色变化，并明说这一下会做什么。
                if state.isImageDropTargeted {
                    Label("松手把图片加进这条消息", systemImage: "photo.badge.plus")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.cyan.opacity(0.95))
                        .accessibilityIdentifier("stage.resident-image-drop-hint")
                }
                if let notice = state.statusNotice, !notice.isEmpty {
                    Text("应用提示：" + notice)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange.opacity(0.95))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("stage.resident-status-notice")
                }
                if let notice = state.deliveryNotice, !notice.isEmpty {
                    Text(notice)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange.opacity(0.95))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("stage.resident-delivery-notice")
                }
                ResidentAttachmentStrip(store: state.images)
                ResidentAttachmentInput(text: $state.draft, store: state.images, onSubmit: submit, onFocus: {
                    inputFocused = true
                    onFocusInput()
                }, onBlur: { inputFocused = false })
                .frame(minHeight: 24)

                HStack(spacing: 10) {
                    Button { state.images.chooseImages() } label: {
                        Image(systemName: "plus").font(.system(size: 15)).frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help("添加图片，也可以直接粘贴图片")
                    .accessibilityLabel("添加图片附件")
                    .disabled(state.images.isPreparing || state.images.attachments.count >= 4)
                    // 状态行：符号与头顶气泡**同一个来源**（`ResidentStatusBadge`）。四种
                    // 状态的文案与改动前逐字一致，新增的只有前缀（说话分支是新增的：
                    // 语音正在输出时这里原本显示空闲文案，看不出"它在说话"）。
                    Text(ResidentStatusBadge.statusLine(
                        isThinking: state.isThinking,
                        isSpeaking: speechStatus.isSpeaking,
                        isListening: state.voiceActive,
                        progress: state.progress ?? "等待居民回应…"
                    ))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.43))
                        .accessibilityIdentifier("stage.resident-progress")
                    Spacer(minLength: 8)
                    Button(action: onToggleVoice) {
                        Image(systemName: state.voiceActive ? "mic.fill" : "mic")
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(state.voiceActive ? Color.cyan : .white.opacity(0.72))
                    .help(state.voiceActive ? "结束语音输入" : "语音输入")
                    .accessibilityLabel(state.voiceActive ? "结束语音输入" : "语音输入")
                    if canStopReply && hasDraft {
                        Button(action: stopReply) {
                            if speechStatus.isSpeaking {
                                Text("停止说话").font(.system(size: 12, weight: .medium))
                            } else {
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                    .frame(width: 30, height: 30)
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.72))
                        .help(stopActionLabel)
                        .accessibilityLabel(stopActionLabel)
                        .accessibilityIdentifier("stage.resident-stop")
                    }
                    Button(action: performPrimaryAction) {
                        if primaryStops && speechStatus.isSpeaking {
                            Text("停止说话")
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 9).frame(height: 30)
                                .background(.white.opacity(0.12), in: Capsule())
                        } else {
                            Image(systemName: primaryStops ? "stop.fill" : "arrow.up")
                                .font(.system(size: primaryStops ? 11 : 15, weight: .semibold))
                                .foregroundStyle(Color(white: 0.14))
                                .frame(width: 30, height: 30)
                                .background(.white.opacity(canSubmit ? 0.92 : 0.25), in: Circle())
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSubmit)
                    .help(primaryActionLabel)
                    .accessibilityLabel(primaryActionLabel)
                }
            }
            .padding(15)
            .background(
                (state.isImageDropTargeted ? Color(red: 0.10, green: 0.28, blue: 0.34) : Color(white: 0.15)).opacity(0.98),
                in: RoundedRectangle(cornerRadius: 20)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .stroke(
                        .white.opacity(state.isImageDropTargeted ? 0.55 : (inputFocused ? 0.22 : 0.1)),
                        lineWidth: state.isImageDropTargeted ? 2 : 1
                    )
            }
        }
        .frame(maxWidth: .infinity)
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        // 拖拽落点：整个对话面板（含输入框）。非拖拽时刻这个视图的 `hitTest` 恒为 nil，
        // 所以按钮/输入框/场景交互都与加它之前逐事件一致。
        .overlay {
            ResidentImageDropTarget(
                isTargeted: $state.isImageDropTargeted,
                onFileURLs: acceptDroppedImageFiles,
                onBitmap: acceptDroppedImageData
            )
        }
    }

    /// 拖进来的图片文件：**与「＋ 选择文件」同一条** `ResidentAttachmentStore.add(urls:)`。
    ///
    /// 这里刻意**不先筛一遍**：混合拖拽（图片 + 别的文件）里那个非图片文件也交给 store，
    /// 由 store 逐个校验并逐个给出可见原因 —— 不允许静默丢弃。超过 4 张、上一批还在准备、
    /// 不是图片，这三种拒绝的文案与判据都在 store 那一份逻辑里，这里不重复任何一条。
    private func acceptDroppedImageFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task { await state.images.add(urls: urls) }
    }

    /// 直接拖进来的位图内容：**与「⌘V」同一条** `add(imageData:)`。
    private func acceptDroppedImageData(_ data: Data) {
        Task { await state.images.add(imageData: data) }
    }

    private var canSubmit: Bool {
        primaryStops || (hasDraft && state.images.canSubmit)
    }

    private var hasDraft: Bool {
        !state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !state.images.attachments.isEmpty
    }

    private var primaryStops: Bool { canStopReply && !hasDraft }

    private var canStopReply: Bool {
        state.isThinking || speechStatus.isSpeaking || state.canStop
    }

    private var primaryActionLabel: String {
        primaryStops ? stopActionLabel : "发送消息"
    }

    private var stopActionLabel: String { speechStatus.isSpeaking ? "停止说话" : "停止当前任务" }

    private func performPrimaryAction() {
        if primaryStops {
            stopReply()
        } else {
            submit()
        }
    }

    private func stopReply() {
        if speechStatus.isSpeaking {
            speechStatus.stopSpeaking()
            return
        }
        if state.isThinking { state.cancel() }
        onCancelMessage()
    }

    private func submit() {
        guard let message = state.takeMessage() else { return }
        Task {
            do { try await onSendMessage(message) }
            catch { state.restore(message, error: error) }
        }
    }
}

/// 居民**头顶**那朵漫画式思考/说话气泡（本需求的主交付）。
///
/// 三件事各自只有一个来源，这里不重复任何一份：
///
/// 1. **画什么** —— `ResidentStatusBadge.symbol(isThinking:isSpeaking:)`。和舞台下方
///    状态行、Live Cam 面板状态行是**同一个函数**，所以三处不可能显示不同的符号；
/// 2. **画在哪** —— 头顶世界点由**既有的**绑定矩阵 `MarblePMXFraming.modelTransform`
///    给出（与 `MarbleSpatialView` 画角色用的是同一行代码），再喂给**既有的**
///    `SpatialStageStore.residentPropScreenPoint`（与装修旋转手柄的锚点同一个投影）。
///    本视图里没有一句自己写的投影数学；
/// 3. **画成什么样** —— `ResidentStatusBadge` 里那几条纯几何（云瓣、指向圆点、浮动、
///    呼吸）。尺寸是恒定 pt，链路上没有任何随相机距离缩放的量。
///
/// 屏幕空间绘制（SwiftUI `Canvas`），不碰 Metal / shader，也不进输入链：外面套的是
/// `StageOverlayHostingView`（`hitTest` 返回 nil），这里再显式 `allowsHitTesting(false)`。
@MainActor
struct StageResidentHeadBadgeView: View {
    let spatialStage: SpatialStageStore
    @ObservedObject var residentChat: StageResidentChatState
    /// 语音是否正在输出。与合成器的"停止说话"读的是同一个源。
    private let speechStatus = AgentSpeechStatusStore.shared

    var body: some View {
        let isThinking = residentChat.isThinking
        let isSpeaking = speechStatus.isSpeaking
        let visible = ResidentStatusBadge.isVisible(
            isThinking: isThinking,
            isSpeaking: isSpeaking
        )
        ZStack {
            if visible {
                // 只读 `timeline.date` 来算浮动/呼吸，**不改任何 SwiftUI 布局**：每帧被
                // 重画的只有这一块画布，位置是时间的纯函数，所以不会抖也不会漂。
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    Canvas { context, size in
                        draw(
                            in: &context,
                            viewSize: size,
                            date: timeline.date,
                            isThinking: isThinking,
                            isSpeaking: isSpeaking
                        )
                    }
                }
                .transition(.opacity)
            }
        }
        // 状态切换淡入淡出（0.22 s）；空闲态整朵（云 + 点）一起消失，不留孤立符号。
        .animation(.easeInOut(duration: 0.22), value: visible)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(
        in context: inout GraphicsContext,
        viewSize: CGSize,
        date: Date,
        isThinking: Bool,
        isSpeaking: Bool
    ) {
        guard let symbol = ResidentStatusBadge.symbol(
            isThinking: isThinking,
            isSpeaking: isSpeaking
        ),
        let geometry = headGeometry(viewSize: viewSize),
        let anchor = ResidentStatusBadge.anchor(
            projectedHead: geometry.head,
            characterScreenHeight: geometry.characterScreenHeight,
            viewSize: viewSize
        )
        else { return }

        let seconds = date.timeIntervalSinceReferenceDate
        // 云体随浮动轻轻上下；指向点不跟着浮（`tailDots` 拿的是**名义**锚点），
        // 于是"与头的最小间隙"不会被浮动吃掉。
        let cloud = ResidentStatusBadge.cloudRect(
            anchor: anchor,
            bob: ResidentStatusBadge.bobOffset(seconds: seconds)
        )
        // 顺序：指向点 → 云 → 云里的符号。符号最后画，永远压在云上。
        drawTailDots(in: &context, anchor: anchor)
        drawCloud(in: &context, rect: cloud)
        drawSymbol(
            in: &context,
            symbol: symbol,
            cloud: cloud,
            seconds: seconds,
            isThinking: isThinking
        )
    }

    /// 头顶与脚下的屏幕位置（左上原点、pt）。世界→屏幕这一跳**全部复用既有实现**。
    ///
    /// 两次投影都走 `SpatialStageStore.residentPropScreenPoint`（与装修旋转手柄的锚点同一个
    /// 函数），世界点分别由**既有的**绑定矩阵 `MarblePMXFraming.modelTransform` 从"本地头顶"
    /// 与"本地脚底"得到。本视图里没有一句自己写的投影数学。
    ///
    /// 为什么要投影**两个**点：云与头之间的间隙需要知道角色在屏幕上有多高（近景头大、
    /// 远景头小），否则固定 pt 的间隙在近景会被头本身吃掉 —— 那正是真机"卡在头部"的成因。
    private func headGeometry(viewSize: CGSize) -> (head: CGPoint, characterScreenHeight: CGFloat)? {
        // 角色当前的世界摆放：与 `MarbleSpatialView` 画角色时读的是同一个属性
        // （`spatialStage.avatarPlacement`），所以走动/转场时气泡跟着一起动。
        //
        // 跟随的是**身体根节点**（placement + 归一化身高），不是头骨：点头/转身这类
        // 头部动画不会让气泡甩来甩去，气泡只跟"这个人站在哪"。这条口径与改动前一致，
        // 没有改语义（头骨姿态只存在于渲染器内部，宿主侧拿不到，也不该为此改渲染链）。
        let placement = spatialStage.avatarPlacement
        let modelTransform = MarblePMXFraming.modelTransform(
            bounds: nil,
            placement: placement
        )
        guard let headNormalized = spatialStage.residentPropScreenPoint(
            world: ResidentStatusBadge.headTopWorldPoint(modelTransform: modelTransform)
        ) else { return nil }
        let head = ResidentStatusBadge.viewPoint(
            projectedNormalized: CGPoint(
                x: CGFloat(headNormalized.x),
                y: CGFloat(headNormalized.y)
            ),
            viewSize: viewSize
        )
        // 脚点：绑定矩阵把本地脚底（y = 0）映射到 `placement.position`，正是角色站的地方。
        // 拿不到时给 0，`headGap(characterScreenHeight:)` 会退回最小间隙。
        let characterScreenHeight: CGFloat = spatialStage
            .residentPropScreenPoint(world: placement.position)
            .map { foot in
                abs(CGFloat(foot.y) * viewSize.height - head.y)
            } ?? 0
        return (head, characterScreenHeight)
    }

    /// 由大到小的三个指向圆点，画在云底与头顶之间。每颗都是"先描边色放大一圈、再填充色"。
    ///
    /// 配色取自 `ResidentStatusBadge.tailDotFill/tailDotOutline` —— 与云体同一套，不另写 RGB。
    private func drawTailDots(in context: inout GraphicsContext, anchor: CGPoint) {
        let dots = ResidentStatusBadge.tailDots(anchor: anchor)
        for dot in dots {
            context.fill(
                Path(ellipseIn: dotRect(dot.center, dot.radius + Self.outlineWidth)),
                with: .color(ResidentStatusBadge.tailDotOutline.color)
            )
        }
        for dot in dots {
            context.fill(
                Path(ellipseIn: dotRect(dot.center, dot.radius)),
                with: .color(ResidentStatusBadge.tailDotFill.color)
            )
        }
    }

    private func dotRect(_ center: CGPoint, _ radius: CGFloat) -> CGRect {
        CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
    }

    /// 云朵：先按描边色把每一块放大画一遍（得到干净的外轮廓），再用填充色画本体。
    ///
    /// 这样就不需要布尔并集路径 —— 叠加出来就是一朵单层轮廓的云，没有内部弧线。
    /// 白底 + 深色细描边：暗背景上白底最清楚，亮背景上由描边界定轮廓。
    private func drawCloud(in context: inout GraphicsContext, rect: CGRect) {
        let blobs = ResidentStatusBadge.cloudBlobs(in: rect)
        for blob in blobs {
            context.fill(
                Path(
                    roundedRect: blob.rect.insetBy(
                        dx: -Self.outlineWidth,
                        dy: -Self.outlineWidth
                    ),
                    cornerRadius: blob.cornerRadius + Self.outlineWidth
                ),
                with: .color(ResidentStatusBadge.cloudOutline.color)
            )
        }
        for blob in blobs {
            context.fill(
                Path(roundedRect: blob.rect, cornerRadius: blob.cornerRadius),
                with: .color(ResidentStatusBadge.cloudFill.color)
            )
        }
    }

    /// 云里的符号。思考时轻微呼吸（`breathScale`），说话时不呼吸（边说话边缩放会显得吵）。
    private func drawSymbol(
        in context: inout GraphicsContext,
        symbol: String,
        cloud: CGRect,
        seconds: Double,
        isThinking: Bool
    ) {
        let scale = isThinking ? ResidentStatusBadge.breathScale(seconds: seconds) : 1
        var symbolContext = context
        symbolContext.translateBy(x: cloud.midX, y: cloud.midY)
        symbolContext.scaleBy(x: scale, y: scale)
        symbolContext.draw(
            Text(symbol)
                .font(.system(size: Self.symbolFontSize))
                .foregroundStyle(ResidentStatusBadge.symbolInk.color),
            at: CGPoint.zero
        )
    }

    /// 描边宽度（pt）。云、指向点共用同一条，粗细一致。
    private static let outlineWidth: CGFloat = 1.4
    /// 云里符号的字号。云体 50×36、底面只占半个云高，18 pt 的 emoji 四周仍留得下白边，
    /// 不会顶到云瓣的圆弧上。
    private static let symbolFontSize: CGFloat = 18
}

/// 配色的**唯一一份**分量 → SwiftUI `Color`。RGB 只写在 `ResidentStatusBadgeInk` 里，
/// 这里没有任何字面量颜色。
private extension ResidentStatusBadgeInk {
    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}

struct StageOverlayView: View {
    @ObservedObject var presentation: StagePresentationModel
    @ObservedObject var overlayState: StageOverlayState
    @ObservedObject var lyrics: StageLyricsStore
    @ObservedObject var videos: StageVideoPlaybackStore
    let audioFeatures: VisualAudioFeatureStore
    let playbackPosition: @MainActor () -> TimeInterval
    /// 角色头顶气泡要的**世界**（角色位置 + 既有投影都从它取）。
    ///
    /// 这里放开成普通 `let`（不是 `@Bindable`）：这一层自己不读它的任何属性，读发生在
    /// `StageResidentHeadBadgeView` 的 body 里，Observation 就只订阅到那一层 —— 角色一动
    /// 只重画气泡，不会把歌词/节目单整棵视图树一起重算。
    let spatialStage: SpatialStageStore
    /// 居民的"在想"取自合成器那份**同一个**状态对象（`StageResidentChatState`），
    /// 不新建第二份 thinking 状态。
    @ObservedObject var residentChat: StageResidentChatState

    var body: some View {
        ZStack {
            StageLyricsView(
                lyrics: lyrics,
                overlayState: overlayState,
                audioFeatures: audioFeatures,
                playbackPosition: playbackPosition
            )
            .allowsHitTesting(false)

            // 居民头顶那朵思考/说话气泡（主交付）。放在这一层而不是合成器那一层，
            // 是因为只有这一层是**铺满整个舞台**的覆盖层，而且宿主是
            // `StageOverlayHostingView` —— 那个 hosting view 的 `hitTest` 返回 nil，
            // 所以气泡天然**穿透点击**，场景指针仍旧归 `StageWorldInteractionView`。
            StageResidentHeadBadgeView(
                spatialStage: spatialStage,
                residentChat: residentChat
            )

            VStack(alignment: .leading) {
                if !presentation.programTitle.isEmpty {
                    Text(presentation.programTitle)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(
                            Color(red: 0.42, green: 0.88, blue: 1)
                        )
                        .shadow(
                            color: Color(red: 0.06, green: 0.62, blue: 1)
                                .opacity(0.55),
                            radius: 8
                        )
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, 34)
            .padding(.leading, 36)
            .allowsHitTesting(false)

            VStack {
                Spacer()
                if let cue = presentation.currentCue {
                    Text(cue.text)
                        .font(.system(
                            size: 17 + CGFloat(cue.emphasis) * 4,
                            weight: .semibold,
                            design: .rounded
                        ))
                        .foregroundStyle(
                            Color(red: 0.84, green: 0.96, blue: 1)
                        )
                        .lineLimit(3)
                        .lineSpacing(5)
                        .minimumScaleFactor(0.76)
                        .multilineTextAlignment(.center)
                        .frame(
                            maxWidth: overlayState.isProgramRailVisible
                                ? 640
                                : 860
                        )
                        .fixedSize(horizontal: false, vertical: true)
                        .id(cue.id)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        .shadow(
                            color: Color(red: 0.02, green: 0.42, blue: 1)
                                .opacity(0.72),
                            radius: 12
                        )
                        .shadow(color: .black.opacity(0.92), radius: 4)
                        .padding(.bottom, 38)
                        .offset(x: overlayState.isProgramRailVisible ? -154 : 0)
                        .opacity(overlayState.isProgramRailVisible ? 0.72 : 1)
                }
            }

            if let prompt = videos.pendingBoundVideo {
                VStack {
                    HStack {
                        Spacer()
                        StageBoundVideoPromptView(
                            prompt: prompt,
                            onPlay: videos.playPendingBoundVideo,
                            onClose: {
                                videos.dismissBoundVideoPrompt(id: prompt.id)
                            }
                        )
                    }
                    Spacer()
                }
                .padding(.top, 28)
                .padding(.trailing, 32)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: prompt.id) {
                    try? await Task.sleep(for: .seconds(3))
                    videos.dismissBoundVideoPrompt(id: prompt.id)
                }
            }
        }
        .animation(.easeOut(duration: 0.28), value: presentation.currentCue?.id)
        .animation(
            .easeOut(duration: 0.22),
            value: overlayState.isProgramRailVisible
        )
    }
}

private struct StageBoundVideoPromptView: View {
    let prompt: StageBoundVideoPrompt
    let onPlay: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 12) {
                Image(systemName: "video.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.cyan.opacity(0.9))
                    .frame(width: 34, height: 34)
                    .background(Color.cyan.opacity(0.13), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("这首歌有专属画面")
                        .font(.system(
                            size: 13,
                            weight: .semibold,
                            design: .rounded
                        ))
                    Text(prompt.asset.displayName)
                        .font(.system(
                            size: 11,
                            weight: .medium,
                            design: .rounded
                        ))
                        .foregroundStyle(.white.opacity(0.48))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Button("播放", action: onPlay)
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan.opacity(0.72))
                    .controlSize(.small)
            }
            .padding(.leading, 10)
            .padding(.trailing, 28)
            .frame(width: 330, height: 58)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.46))
            .accessibilityLabel("忽略绑定视频")
            .padding(7)
        }
        .foregroundStyle(.white.opacity(0.9))
        .frame(width: 330, height: 58)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.cyan.opacity(0.24), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.44), radius: 18, y: 8)
    }
}

@MainActor
private struct StageLyricsView: View {
    @ObservedObject var lyrics: StageLyricsStore
    @ObservedObject var overlayState: StageOverlayState
    let audioFeatures: VisualAudioFeatureStore
    let playbackPosition: @MainActor () -> TimeInterval

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval:
                    StageLyricRenderPolicy.minimumFrameInterval
            )
        ) { context in
            let playbackTime = playbackPosition()
            let resolvedMode = StageLyricModeDirector.resolve(
                configuredMode: lyrics.visualMode,
                trackID: lyrics.trackID,
                lines: lyrics.lines,
                playbackTime: playbackTime
            )
            let audioMotion = StageLyricAudioMotion(
                features: audioFeatures.current,
                animationTime: context.date.timeIntervalSinceReferenceDate,
                mode: resolvedMode
            )
            switch resolvedMode {
            case .automatic:
                EmptyView()
            case .flowingLine:
                StageFlowingLyricsFrame(
                    scene: StageLyricFlowSceneModel(
                        lines: lyrics.lines,
                        playbackTime: playbackTime
                    ),
                    isProgramRailVisible: overlayState.isProgramRailVisible,
                    animationTime: context.date.timeIntervalSinceReferenceDate,
                    audio: audioMotion
                )
            case .depthStack:
                StageDepthLyricsFrame(
                    scene: StageLyricSceneModel(
                        lines: lyrics.lines,
                        playbackTime: playbackTime
                    ),
                    isProgramRailVisible: overlayState.isProgramRailVisible,
                    audio: audioMotion
                )
            case .cloudSteps:
                StageCloudStepsLyricsFrame(
                    scene: StageLyricFlowSceneModel(
                        lines: lyrics.lines,
                        playbackTime: playbackTime
                    ),
                    isProgramRailVisible: overlayState.isProgramRailVisible,
                    audio: audioMotion
                )
            case .chorusChat:
                StageChorusChatLyricsFrame(
                    scene: StageLyricFlowSceneModel(
                        lines: lyrics.lines,
                        playbackTime: playbackTime
                    ),
                    isProgramRailVisible: overlayState.isProgramRailVisible,
                    audio: audioMotion
                )
            case .cinematicSplit:
                StageCinematicSplitLyricsFrame(
                    scene: StageLyricFlowSceneModel(
                        lines: lyrics.lines,
                        playbackTime: playbackTime
                    ),
                    playbackTime: playbackTime,
                    isProgramRailVisible: overlayState.isProgramRailVisible,
                    audio: audioMotion
                )
            case .orbitArc:
                StageOrbitLyricsFrame(
                    scene: StageLyricFlowSceneModel(
                        lines: lyrics.lines,
                        playbackTime: playbackTime
                    ),
                    isProgramRailVisible: overlayState.isProgramRailVisible,
                    animationTime:
                        context.date.timeIntervalSinceReferenceDate,
                    audio: audioMotion
                )
            case .posterRail:
                StagePosterRailLyricsFrame(
                    lines: lyrics.lines,
                    scene: StageLyricFlowSceneModel(
                        lines: lyrics.lines,
                        playbackTime: playbackTime
                    ),
                    isProgramRailVisible: overlayState.isProgramRailVisible,
                    audio: audioMotion
                )
            case .editorialField:
                StageEditorialLyricsFrame(
                    lines: lyrics.lines,
                    scene: StageLyricFlowSceneModel(
                        lines: lyrics.lines,
                        playbackTime: playbackTime
                    ),
                    playbackTime: playbackTime,
                    isProgramRailVisible: overlayState.isProgramRailVisible,
                    audio: audioMotion
                )
            case .pendulumWheel:
                StagePendulumLyricsFrame(
                    lines: lyrics.lines,
                    scene: StageLyricFlowSceneModel(
                        lines: lyrics.lines,
                        playbackTime: playbackTime
                    ),
                    isProgramRailVisible: overlayState.isProgramRailVisible,
                    animationTime:
                        context.date.timeIntervalSinceReferenceDate,
                    audio: audioMotion
                )
            case .dioramaStage:
                StageDioramaLyricsFrame(
                    scene: StageLyricFlowSceneModel(
                        lines: lyrics.lines,
                        playbackTime: playbackTime
                    ),
                    isProgramRailVisible: overlayState.isProgramRailVisible,
                    animationTime:
                        context.date.timeIntervalSinceReferenceDate,
                    audio: audioMotion
                )
            case .foldingVerse:
                StageFoldingVerseLyricsFrame(
                    scene: StageLyricFoldSceneModel(
                        lines: lyrics.lines,
                        playbackTime: playbackTime
                    ),
                    isProgramRailVisible: overlayState.isProgramRailVisible
                )
            }
        }
        .animation(
            .easeOut(duration: 0.22),
            value: overlayState.isProgramRailVisible
        )
        .environment(
            \.stageFoliaTheme,
            lyrics.activeTheme ?? .gmgnDefaultDark
        )
        .allowsHitTesting(false)
    }
}

private struct StageFlowingLyricsFrame: View {
    @Environment(\.stageFoliaTheme) private var theme

    let scene: StageLyricFlowSceneModel
    let isProgramRailVisible: Bool
    let animationTime: TimeInterval
    let audio: StageLyricAudioMotion

    var body: some View {
        GeometryReader { proxy in
            if let line = scene.activeLine {
                let fontSize = resolvedFontSize(
                    text: line.text,
                    availableWidth: proxy.size.width
                )
                let railOffset = isProgramRailVisible ? -150.0 : 0
                let breathingY = sin(animationTime * 0.72) * 2.2
                    + audio.beatLift * 0.18

                VStack(spacing: 22) {
                    if let previousLine = scene.previousLine {
                        contextualLine(
                            previousLine.text,
                            fontSize: fontSize,
                            alignment: .leading,
                            isUpcoming: false
                        )
                    }

                    HStack(alignment: .firstTextBaseline, spacing: fontSize * 0.015) {
                        ForEach(scene.glyphs) { glyph in
                            StageFlowingLyricGlyph(
                                glyph: glyph,
                                fontSize: fontSize,
                                isChorus: scene.isChorus
                            )
                        }
                    }
                    .compositingGroup()
                    .shadow(
                        color: scene.isChorus
                            ? theme.secondaryColor.opacity(0.3)
                            : theme.accentColor.opacity(0.22),
                        radius: scene.isChorus ? 22 : 14
                    )
                    .shadow(color: .black.opacity(0.78), radius: 3)
                    .frame(maxWidth: proxy.size.width * 0.82)
                    .offset(y: breathingY)

                    if let translation = scene.translation {
                        Text(translation)
                            .font(.system(
                                size: max(16, fontSize * 0.22),
                                weight: .medium,
                                design: .rounded
                            ))
                            .tracking(0.7)
                            .foregroundStyle(theme.primaryColor.opacity(0.66))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .frame(maxWidth: 720)
                            .shadow(color: .black.opacity(0.9), radius: 5)
                    }

                    if let nextLine = scene.nextLine {
                        contextualLine(
                            nextLine.text,
                            fontSize: fontSize,
                            alignment: .trailing,
                            isUpcoming: true
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .offset(x: railOffset, y: -8)
                .scaleEffect(audio.expansion)
                .id(line.id)
                .transition(
                    .opacity.combined(
                        with: .scale(scale: 0.94, anchor: .center)
                    )
                )
                .animation(
                    .spring(response: 0.44, dampingFraction: 0.84),
                    value: line.id
                )
            }
        }
    }

    private func resolvedFontSize(
        text: String,
        availableWidth: CGFloat
    ) -> CGFloat {
        CGFloat(StageLyricTypography.fontSize(
            text: text,
            availableWidth: Double(availableWidth)
        ))
    }

    private func contextualLine(
        _ text: String,
        fontSize: CGFloat,
        alignment: Alignment,
        isUpcoming: Bool
    ) -> some View {
        Text(text)
            .font(.system(
                size: min(max(fontSize * 0.28, 15), 24),
                weight: .semibold,
                design: .rounded
            ))
            .tracking(0.5)
            .foregroundStyle(
                theme.primaryColor.opacity(isUpcoming ? 0.28 : 0.18)
            )
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .frame(maxWidth: 680, alignment: alignment)
            .blur(radius: isUpcoming ? 0.9 : 1.5)
            .offset(x: isUpcoming ? 42 : -42)
    }
}

private struct StageFoldingVerseLyricsFrame: View {
    @Environment(\.stageFoliaTheme) private var theme

    let scene: StageLyricFoldSceneModel
    let isProgramRailVisible: Bool

    var body: some View {
        GeometryReader { proxy in
            let progress = eased(scene.transitionProgress)
            let direction: CGFloat = scene.foldDirection == .left
                ? -1
                : 1
            let railOffset = isProgramRailVisible ? -138.0 : 0

            ZStack {
                if !scene.previousLines.isEmpty {
                    lyricGroup(
                        lines: scene.previousLines,
                        activeLineID: nil,
                        availableWidth: proxy.size.width * 0.58,
                        historical: true
                    )
                    .rotationEffect(
                        .degrees(direction * 90 * progress),
                        anchor: scene.foldDirection == .left
                            ? .leading
                            : .trailing
                    )
                    .rotation3DEffect(
                        .degrees(direction * 7 * progress),
                        axis: (x: 0, y: 1, z: 0),
                        anchor: scene.foldDirection == .left
                            ? .leading
                            : .trailing,
                        perspective: 0.72
                    )
                    .offset(
                        x: direction * proxy.size.width * 0.29 * progress,
                        y: -proxy.size.height * 0.07 * progress
                    )
                    .scaleEffect(1 - progress * 0.18)
                    .opacity(1 - progress * 0.5)
                }

                lyricGroup(
                    lines: scene.currentLines,
                    activeLineID: scene.activeLineID,
                    availableWidth: proxy.size.width * 0.68,
                    historical: false
                )
                .offset(
                    x: direction * proxy.size.width * 0.035
                        * (1 - progress),
                    y: proxy.size.height * 0.68 * (1 - progress)
                )
                .scaleEffect(
                    0.92 + progress * 0.08,
                    anchor: .bottom
                )
                .opacity(0.16 + progress * 0.84)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .offset(x: railOffset, y: -8)
            .clipped()
        }
    }

    private func lyricGroup(
        lines: [StageLyricLine],
        activeLineID: String?,
        availableWidth: CGFloat,
        historical: Bool
    ) -> some View {
        let activeIndex = activeLineID.flatMap { id in
            lines.firstIndex(where: { $0.id == id })
        }

        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(lines.enumerated()), id: \.element.id) {
                index,
                line in
                let state = lineState(
                    index: index,
                    activeIndex: activeIndex,
                    historical: historical
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(line.text)
                        .font(.system(
                            size: fontSize(
                                for: line.text,
                                availableWidth: availableWidth
                            ),
                            weight: state.isActive ? .black : .bold,
                            design: .rounded
                        ))
                        .tracking(state.isActive ? -1.2 : -0.6)
                        .foregroundStyle(state.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.56)
                        .shadow(
                            color: state.isActive
                                ? theme.accentColor.opacity(0.32)
                                : .black.opacity(0.72),
                            radius: state.isActive ? 18 : 4
                        )

                    if state.isActive,
                        let translation = line.translation,
                        !translation.isEmpty
                    {
                        Text(translation)
                            .font(.system(
                                size: 16,
                                weight: .semibold,
                                design: .rounded
                            ))
                            .foregroundStyle(
                                theme.primaryColor.opacity(0.58)
                            )
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
                .frame(maxWidth: availableWidth, alignment: .leading)
            }
        }
        .frame(maxWidth: availableWidth, alignment: .leading)
        .compositingGroup()
    }

    private func lineState(
        index: Int,
        activeIndex: Int?,
        historical: Bool
    ) -> FoldingVerseLineState {
        if historical {
            return FoldingVerseLineState(
                color: theme.primaryColor.opacity(0.5),
                isActive: false
            )
        }
        guard let activeIndex else {
            return FoldingVerseLineState(
                color: theme.primaryColor.opacity(0.26),
                isActive: false
            )
        }
        if index == activeIndex {
            return FoldingVerseLineState(
                color: theme.accentColor,
                isActive: true
            )
        }
        return FoldingVerseLineState(
            color: theme.primaryColor.opacity(
                index < activeIndex ? 0.82 : 0.22
            ),
            isActive: false
        )
    }

    private func fontSize(
        for text: String,
        availableWidth: CGFloat
    ) -> CGFloat {
        let fitted = CGFloat(StageLyricTypography.fontSize(
            text: text,
            availableWidth: Double(availableWidth)
        ))
        return min(max(fitted * 0.72, 28), 72)
    }

    private func eased(_ progress: Double) -> CGFloat {
        let value = min(max(progress, 0), 1)
        return CGFloat(value * value * (3 - 2 * value))
    }
}

private struct FoldingVerseLineState {
    let color: Color
    let isActive: Bool
}

private struct StageFlowingLyricGlyph: View {
    @Environment(\.stageFoliaTheme) private var theme

    let glyph: StageLyricGlyphFrame
    let fontSize: CGFloat
    var isChorus = false

    var body: some View {
        let style = visualStyle
        ZStack {
            if StageLyricRenderPolicy.shouldRenderDynamicGlow(
                for: glyph.phase
            ) {
                Text(glyph.text)
                    .foregroundStyle(style.glowColor)
                    .blur(radius: style.glowRadius)
                    .opacity(style.glowOpacity)
            }

            Text(glyph.text)
                .foregroundStyle(style.bodyColor)
        }
        .font(.system(
            size: fontSize,
            weight: .bold,
            design: .rounded
        ))
        .tracking(fontSize * -0.018)
        .fixedSize()
        .blur(radius: style.blurRadius)
        .scaleEffect(style.scale * glyph.restingScale)
        .rotationEffect(.degrees(glyph.rotation * style.motionAmount))
        .offset(
            x: glyph.xOffset * style.motionAmount,
            y: glyph.yOffset * style.motionAmount + style.lift
        )
        .opacity(style.opacity)
    }

    private var visualStyle: StageFlowingGlyphStyle {
        switch glyph.phase {
        case .waiting:
            return StageFlowingGlyphStyle(
                bodyColor:
                    theme.primaryColor.opacity(0.26),
                glowColor: Color.clear,
                glowRadius: 0,
                glowOpacity: 0,
                opacity: 0.72,
                scale: 0.98,
                lift: 3,
                motionAmount: 0.08,
                blurRadius: 0.55
            )
        case .active:
            let pulse = 1.04 + sin(glyph.progress * .pi) * 0.035
            return StageFlowingGlyphStyle(
                bodyColor:
                    theme.semanticColor(for: glyph.text)
                        ?? (isChorus
                            ? theme.secondaryColor
                            : theme.primaryColor),
                glowColor:
                    isChorus
                        ? theme.secondaryColor
                        : theme.accentColor,
                glowRadius: 10 + sin(glyph.progress * .pi) * 8,
                glowOpacity: 0.7,
                opacity: 1,
                scale: pulse,
                lift: -2 - sin(glyph.progress * .pi) * 4,
                motionAmount: 0.18,
                blurRadius: 0
            )
        case .passed:
            return StageFlowingGlyphStyle(
                bodyColor:
                    isChorus
                        ? theme.secondaryColor.opacity(0.88)
                        : theme.accentColor.opacity(0.88),
                glowColor: Color.clear,
                glowRadius: 0,
                glowOpacity: 0,
                opacity: 0.96,
                scale: 1,
                lift: 0,
                motionAmount: 0.04,
                blurRadius: 0
            )
        }
    }
}

private struct StageFlowingGlyphStyle {
    let bodyColor: Color
    let glowColor: Color
    let glowRadius: Double
    let glowOpacity: Double
    let opacity: Double
    let scale: Double
    let lift: Double
    let motionAmount: Double
    let blurRadius: Double
}

private struct StageCinematicSplitLyricsFrame: View {
    @Environment(\.stageFoliaTheme) private var theme

    let scene: StageLyricFlowSceneModel
    let playbackTime: TimeInterval
    let isProgramRailVisible: Bool
    let audio: StageLyricAudioMotion

    var body: some View {
        GeometryReader { proxy in
            if let line = scene.activeLine {
                let layout = StageTiltLayoutModel(line: line)
                let fontSize = CGFloat(StageLyricTypography.fontSize(
                    text: line.text,
                    availableWidth: Double(proxy.size.width * 0.76)
                ))
                VStack(alignment: .leading, spacing: fontSize * 0.08) {
                    ForEach(layout.segments) { segment in
                        if playbackTime >= segment.revealAt {
                            Text(segment.text)
                                .font(.system(
                                    size: segment.isTilted
                                        ? fontSize * 1.14
                                        : fontSize,
                                    weight: segment.isTilted
                                        ? .light
                                        : .bold,
                                    design: .rounded
                                ))
                                .italic(segment.isTilted)
                                .foregroundStyle(
                                    segment.isTilted
                                        ? LinearGradient(
                                            colors: [
                                                theme.secondaryColor,
                                                theme.accentColor,
                                                theme.primaryColor,
                                            ],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                        : LinearGradient(
                                            colors: [
                                                theme.primaryColor,
                                                theme.primaryColor.opacity(0.76),
                                            ],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                )
                                .shadow(
                                    color: segment.isTilted
                                        ? theme.accentColor.opacity(0.32)
                                        : .black.opacity(0.72),
                                    radius: segment.isTilted ? 18 : 5
                                )
                                .offset(
                                    x: proxy.size.width * segment.xOffset,
                                    y: audio.beatLift
                                        * (segment.isTilted ? 0.22 : 0.08)
                                )
                                .rotationEffect(
                                    .degrees(segment.isTilted ? -7 : 0),
                                    anchor: .leading
                                )
                                .scaleEffect(
                                    segment.isTilted
                                        ? 1 + audio.mid * 0.045
                                        : 1,
                                    anchor: .leading
                                )
                                .transition(
                                    .opacity.combined(
                                        with: .offset(
                                            x: segment.isTilted ? 34 : -22,
                                            y: 0
                                        )
                                    )
                                )
                                .id(segment.id)
                        }
                    }

                    if let translation = scene.translation {
                        Text(translation)
                            .font(.system(
                                size: max(15, fontSize * 0.2),
                                weight: .medium,
                                design: .rounded
                            ))
                            .foregroundStyle(theme.primaryColor.opacity(0.56))
                            .frame(maxWidth: 620, alignment: .leading)
                            .padding(.top, 8)
                    }
                }
                .animation(
                    .spring(response: 0.55, dampingFraction: 0.82),
                    value: layout.segments.filter {
                        playbackTime >= $0.revealAt
                    }.count
                )
                .frame(
                    maxWidth: proxy.size.width * 0.78,
                    maxHeight: .infinity,
                    alignment: .leading
                )
                .padding(.leading, max(62, proxy.size.width * 0.08))
                .offset(
                    x: isProgramRailVisible ? -104 : 0,
                    y: -14
                )
                .rotation3DEffect(
                    .degrees(-4),
                    axis: (x: 0.02, y: 1, z: 0),
                    anchor: .leading,
                    perspective: 0.76
                )
                .id(line.id)
                .transition(
                    .opacity.combined(
                        with: .move(edge: .leading)
                    )
                )
            }
        }
    }
}

private struct StageOrbitLyricsFrame: View {
    let scene: StageLyricFlowSceneModel
    let isProgramRailVisible: Bool
    let animationTime: TimeInterval
    let audio: StageLyricAudioMotion

    var body: some View {
        GeometryReader { proxy in
            if let line = scene.activeLine {
                let count = max(scene.glyphs.count, 1)
                let fontSize = min(
                    72,
                    max(26, proxy.size.width * 0.7 / CGFloat(count))
                )
                ZStack {
                    ForEach(
                        Array(scene.glyphs.enumerated()),
                        id: \.element.id
                    ) { index, glyph in
                        let unit = count == 1
                            ? 0.5
                            : Double(index) / Double(count - 1)
                        let angle = (unit - 0.5) * 1.58
                        StageFlowingLyricGlyph(
                            glyph: glyph,
                            fontSize: fontSize,
                            isChorus: scene.isChorus
                        )
                        .rotation3DEffect(
                            .degrees((unit - 0.5) * -34),
                            axis: (x: 0.12, y: 1, z: 0),
                            perspective: 0.7
                        )
                        .offset(
                            x: sin(angle)
                                * min(430, proxy.size.width * 0.38)
                                * audio.expansion,
                            y: cos(angle) * -92
                                + sin(animationTime * 0.55 + unit * 4) * 4
                                + audio.beatLift * (0.12 + unit * 0.1)
                        )
                    }

                    if let translation = scene.translation {
                        Text(translation)
                            .font(.system(
                                size: 17,
                                weight: .medium,
                                design: .rounded
                            ))
                            .foregroundStyle(.white.opacity(0.58))
                            .offset(y: 78)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .offset(x: isProgramRailVisible ? -150 : 0, y: -18)
                .id(line.id)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
    }
}

private struct StagePosterRailLyricsFrame: View {
    @Environment(\.stageFoliaTheme) private var theme

    let lines: [StageLyricLine]
    let scene: StageLyricFlowSceneModel
    let isProgramRailVisible: Bool
    let audio: StageLyricAudioMotion

    var body: some View {
        GeometryReader { proxy in
            if let line = scene.activeLine {
                let rail = StageMonetRailModel(
                    lines: lines,
                    activeLineID: line.id
                )
                let fontSize = CGFloat(StageLyricTypography.fontSize(
                    text: line.text,
                    availableWidth: Double(proxy.size.width * 0.58)
                ))

                HStack(spacing: 28) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(
                            LinearGradient(
                                colors: [
                                    theme.accentColor.opacity(0.9),
                                    theme.secondaryColor.opacity(0.4),
                                    .clear,
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(
                            width: 3 + audio.high * 2,
                            height: min(520, proxy.size.height * 0.7)
                                * audio.expansion
                        )

                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(rail.entries) { entry in
                            monetRailEntry(
                                entry,
                                fontSize: fontSize,
                                maxWidth: proxy.size.width * 0.62
                            )
                            .offset(
                                x: CGFloat(abs(entry.offset)) * 18
                                    + (entry.offset > 0 ? 12 : 0)
                            )
                            .blur(
                                radius: entry.status == .active
                                    ? 0
                                    : Double(abs(entry.offset)) * 0.34
                            )
                            .transition(
                                .opacity.combined(
                                    with: .offset(
                                        x: 0,
                                        y: entry.offset > 0 ? 24 : -24
                                    )
                                )
                            )
                        }
                    }
                }
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .leading
                )
                .padding(.leading, max(60, proxy.size.width * 0.075))
                .offset(x: isProgramRailVisible ? -96 : 0)
                .id(line.id)
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private func monetRailEntry(
        _ entry: StageMonetRailEntry,
        fontSize: CGFloat,
        maxWidth: CGFloat
    ) -> some View {
        if entry.status == .active {
            VStack(alignment: .leading, spacing: 10) {
                HStack(
                    alignment: .firstTextBaseline,
                    spacing: fontSize * 0.012
                ) {
                    ForEach(scene.glyphs) { glyph in
                        StageFlowingLyricGlyph(
                            glyph: glyph,
                            fontSize: fontSize,
                            isChorus: scene.isChorus
                        )
                    }
                }
                .fixedSize()
                .scaleEffect(
                    x: audio.expansion,
                    y: 1 + audio.mid * 0.025,
                    anchor: .leading
                )

                if let translation = scene.translation {
                    Text(translation)
                        .font(.system(
                            size: max(15, fontSize * 0.2),
                            weight: .medium,
                            design: .rounded
                        ))
                        .foregroundStyle(theme.primaryColor.opacity(0.54))
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: maxWidth, alignment: .leading)
            .padding(.vertical, 10)
            .shadow(
                color: theme.accentColor.opacity(0.18 + audio.glow * 0.18),
                radius: 22
            )
        } else {
            Text(entry.line.text)
                .font(.system(
                    size: min(max(fontSize * 0.34, 17), 28),
                    weight: entry.status == .passed ? .medium : .semibold,
                    design: .rounded
                ))
                .foregroundStyle(
                    entry.status == .passed
                        ? theme.secondaryColor.opacity(
                            0.16 + 0.05 / Double(abs(entry.offset))
                        )
                        : theme.primaryColor.opacity(
                            0.34 - Double(abs(entry.offset) - 1) * 0.07
                        )
                )
                .lineLimit(2)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: maxWidth * 0.82, alignment: .leading)
        }
    }
}

private struct StageEditorialLyricsFrame: View {
    @Environment(\.stageFoliaTheme) private var theme

    let lines: [StageLyricLine]
    let scene: StageLyricFlowSceneModel
    let playbackTime: TimeInterval
    let isProgramRailVisible: Bool
    let audio: StageLyricAudioMotion

    var body: some View {
        GeometryReader { proxy in
            if let activeLine = scene.activeLine {
                let fontSize = CGFloat(StageLyricTypography.fontSize(
                    text: activeLine.text,
                    availableWidth: Double(proxy.size.width * 0.62)
                ))
                let article = StageFumeArticleModel(
                    lines: lines,
                    activeLineID: activeLine.id
                )

                ZStack {
                    ForEach(article.blocks, id: \.lineID) { block in
                        if block.lineID != activeLine.id {
                            articleContextBlock(
                                block,
                                cameraTarget: article.cameraTarget,
                                canvasSize: proxy.size
                            )
                        }
                    }

                    VStack(spacing: 16) {
                        HStack(
                            alignment: .firstTextBaseline,
                            spacing: fontSize * 0.012
                        ) {
                            ForEach(scene.glyphs) { glyph in
                                StageFlowingLyricGlyph(
                                    glyph: glyph,
                                    fontSize: fontSize,
                                    isChorus: scene.isChorus
                                )
                            }
                        }
                        .fixedSize()
                        .frame(maxWidth: proxy.size.width * 0.64)

                        if let translation = scene.translation {
                            Text(translation)
                                .font(.system(
                                    size: max(15, fontSize * 0.19),
                                    weight: .medium,
                                    design: .rounded
                                ))
                                .foregroundStyle(
                                    theme.primaryColor.opacity(0.58)
                                )
                                .lineLimit(2)
                                .frame(maxWidth: 680)
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 26)
                    .background {
                        RoundedRectangle(cornerRadius: 34)
                            .fill(.black.opacity(0.16))
                            .overlay {
                                RoundedRectangle(cornerRadius: 34)
                                    .stroke(.white.opacity(0.08), lineWidth: 1)
                            }
                    }
                    .shadow(
                        color: scene.isChorus
                            ? theme.secondaryColor.opacity(0.2)
                            : theme.accentColor.opacity(0.18),
                        radius: 32
                    )
                    .position(
                        x: proxy.size.width * 0.5
                            + (isProgramRailVisible ? -140 : 0),
                        y: proxy.size.height * 0.5 + audio.beatLift * 0.2
                    )
                    .scaleEffect(audio.expansion)
                    .id(activeLine.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
        }
    }

    private func articleContextBlock(
        _ block: StageFumeArticleBlock,
        cameraTarget: SIMD2<Double>,
        canvasSize: CGSize
    ) -> some View {
        let distance = abs(block.position.y - cameraTarget.y)
        let isLeading = block.position.x < 0.5
        let fontSize = 17 + max(0, 1 - distance * 4) * 8
        let opacity = max(0.07, 0.34 - distance * 0.72)
        let x = canvasSize.width
            * (0.5 + (block.position.x - cameraTarget.x) * 1.45)
        let y = canvasSize.height
            * (0.5 + (block.position.y - cameraTarget.y) * 2.25)

        return Text(block.text)
            .font(.system(
                size: fontSize,
                weight: .semibold,
                design: .rounded
            ))
            .foregroundStyle(theme.primaryColor.opacity(opacity))
            .lineLimit(3)
            .multilineTextAlignment(isLeading ? .leading : .trailing)
            .frame(
                width: canvasSize.width * min(block.width, 0.42),
                alignment: isLeading ? .leading : .trailing
            )
            .position(x: x, y: y)
            .blur(radius: min(distance * 3.2, 2.2))
    }
}

private struct StageCloudStepsLyricsFrame: View {
    @Environment(\.stageFoliaTheme) private var theme

    let scene: StageLyricFlowSceneModel
    let isProgramRailVisible: Bool
    let audio: StageLyricAudioMotion

    var body: some View {
        GeometryReader { proxy in
            if let line = scene.activeLine {
                let count = max(scene.glyphs.count, 1)
                let layout = StagePartitaLayoutModel(
                    glyphIDs: scene.glyphs.map(\.id),
                    lineID: line.id,
                    isChorus: scene.isChorus
                )
                let fontSize = min(
                    68,
                    max(25, proxy.size.width * 0.7 / CGFloat(count))
                )

                ZStack {
                    ForEach(
                        Array(layout.placements.enumerated()),
                        id: \.element.glyphID
                    ) { index, placement in
                        let glyph = scene.glyphs[index]
                        let x = proxy.size.width * (0.5 + placement.x)
                            + (isProgramRailVisible ? -140 : 0)
                        let y = proxy.size.height * (0.5 + placement.y)

                        StageFlowingLyricGlyph(
                            glyph: glyph,
                            fontSize: fontSize,
                            isChorus: scene.isChorus
                        )
                        .rotation3DEffect(
                            .degrees(placement.rotationDegrees * 0.72),
                            axis: (x: 0.08, y: 1, z: 0),
                            perspective: 0.72
                        )
                        .rotationEffect(
                            .degrees(placement.rotationDegrees * 0.28)
                        )
                        .scaleEffect(
                            placement.scale
                                * (1 + audio.sceneEnergy * 0.025)
                        )
                        .position(x: x, y: y)
                    }

                    if let translation = scene.translation {
                        Text(translation)
                            .font(.system(
                                size: 15,
                                weight: .medium,
                                design: .rounded
                            ))
                            .tracking(0.8)
                            .foregroundStyle(
                                theme.primaryColor.opacity(0.48)
                            )
                            .lineLimit(2)
                            .frame(width: min(520, proxy.size.width * 0.5))
                            .position(
                                x: proxy.size.width * 0.5
                                    + (isProgramRailVisible ? -140 : 0),
                                y: proxy.size.height * 0.84
                            )
                    }
                }
                .scaleEffect(audio.expansion)
                .id(line.id)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }
}

private struct StageChorusChatLyricsFrame: View {
    @Environment(\.stageFoliaTheme) private var theme

    let scene: StageLyricFlowSceneModel
    let isProgramRailVisible: Bool
    let audio: StageLyricAudioMotion

    var body: some View {
        GeometryReader { proxy in
            if let line = scene.activeLine {
                let fontSize = CGFloat(StageLyricTypography.fontSize(
                    text: line.text,
                    availableWidth: Double(proxy.size.width * 0.5)
                ))
                let conversation = StageCappellaConversationModel(
                    previousLineID: scene.previousLine?.id,
                    activeLineID: line.id,
                    nextLineID: scene.nextLine?.id,
                    isChorus: scene.isChorus
                )
                VStack(spacing: 18) {
                    if let previous = scene.previousLine {
                        contextBubble(
                            previous.text,
                            voice: conversation.previousVoice,
                            isTrailing: true
                        )
                    }

                    HStack(spacing: 12) {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        theme.accentColor,
                                        theme.secondaryColor,
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 34, height: 34)
                            .overlay {
                                Image(
                                    systemName:
                                        conversation.activeVoice.symbolName
                                )
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(theme.primaryColor)
                            }
                            .shadow(
                                color: theme.accentColor.opacity(audio.glow),
                                radius: 10 + audio.high * 10
                            )

                        VStack(alignment: .leading, spacing: 10) {
                            HStack(
                                alignment: .firstTextBaseline,
                                spacing: fontSize * 0.012
                            ) {
                                ForEach(scene.glyphs) { glyph in
                                    StageFlowingLyricGlyph(
                                        glyph: glyph,
                                        fontSize: fontSize,
                                        isChorus: scene.isChorus
                                    )
                                }
                            }
                            .fixedSize()

                            if let translation = scene.translation {
                                Text(translation)
                                    .font(.system(
                                        size: max(14, fontSize * 0.19),
                                        weight: .medium,
                                        design: .rounded
                                    ))
                                    .foregroundStyle(
                                        theme.primaryColor.opacity(0.56)
                                    )
                                    .lineLimit(2)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 18)
                        .background {
                            UnevenRoundedRectangle(
                                topLeadingRadius: 8,
                                bottomLeadingRadius: 30,
                                bottomTrailingRadius: 30,
                                topTrailingRadius: 30
                            )
                            .fill(.black.opacity(0.32))
                            .overlay {
                                UnevenRoundedRectangle(
                                    topLeadingRadius: 8,
                                    bottomLeadingRadius: 30,
                                    bottomTrailingRadius: 30,
                                    topTrailingRadius: 30
                                )
                                .stroke(
                                    scene.isChorus
                                        ? theme.secondaryColor.opacity(0.46)
                                        : theme.accentColor.opacity(0.34),
                                    lineWidth: 1
                                )
                            }
                        }
                    }
                    .scaleEffect(audio.expansion, anchor: .leading)
                    .offset(y: audio.beatLift * 0.18)

                    if let next = scene.nextLine {
                        contextBubble(
                            next.text,
                            voice: conversation.nextVoice,
                            isTrailing: false
                        )
                    }
                }
                .frame(maxWidth: min(860, proxy.size.width * 0.72))
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .center
                )
                .offset(x: isProgramRailVisible ? -140 : 0)
                .id(line.id)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
    }

    private func contextBubble(
        _ text: String,
        voice: StageCappellaVoice,
        isTrailing: Bool
    ) -> some View {
        HStack(spacing: 9) {
            if isTrailing {
                Spacer(minLength: 40)
            }
            Circle()
                .fill(theme.secondaryColor.opacity(0.12))
                .frame(width: 27, height: 27)
                .overlay {
                    Image(systemName: voice.symbolName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(
                            theme.secondaryColor.opacity(0.72)
                        )
                }
            Text(text)
                .font(.system(
                    size: 18,
                    weight: .medium,
                    design: .rounded
                ))
                .foregroundStyle(theme.primaryColor.opacity(0.36))
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background {
                    Capsule()
                        .fill(theme.primaryColor.opacity(0.045))
                        .overlay {
                            Capsule()
                                .stroke(
                                    theme.primaryColor.opacity(0.08),
                                    lineWidth: 0.8
                                )
                        }
                }
            if !isTrailing {
                Spacer(minLength: 40)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct StagePendulumLyricsFrame: View {
    @Environment(\.stageFoliaTheme) private var theme

    let lines: [StageLyricLine]
    let scene: StageLyricFlowSceneModel
    let isProgramRailVisible: Bool
    let animationTime: TimeInterval
    let audio: StageLyricAudioMotion

    var body: some View {
        GeometryReader { proxy in
            if let line = scene.activeLine {
                let wheel = StagePendoloWheelModel(
                    lines: lines,
                    activeLineID: line.id
                )
                let radius = min(proxy.size.width, proxy.size.height) * 0.48
                    * audio.expansion
                let center = CGPoint(
                    x: proxy.size.width * 0.04
                        + (isProgramRailVisible ? -140 : 0),
                    y: proxy.size.height * 0.5
                )

                ZStack {
                    Circle()
                        .trim(from: 0, to: 0.5)
                        .stroke(
                            AngularGradient(
                                colors: [
                                    theme.secondaryColor.opacity(0.1),
                                    theme.accentColor.opacity(0.58),
                                    theme.primaryColor.opacity(0.18),
                                    theme.secondaryColor.opacity(0.1),
                                ],
                                center: .center
                            ),
                            style: StrokeStyle(
                                lineWidth: 1.2 + audio.high * 1.4,
                                lineCap: .round
                            )
                        )
                        .frame(width: radius * 2, height: radius * 2)
                        .position(center)
                        .rotationEffect(.degrees(-90))

                    Circle()
                        .trim(from: 0.04, to: 0.46)
                        .stroke(
                            theme.primaryColor.opacity(
                                0.035 + audio.glow * 0.08
                            ),
                            lineWidth: 20 + audio.low * 10
                        )
                        .frame(
                            width: radius * 1.88,
                            height: radius * 1.88
                        )
                        .position(center)
                        .rotationEffect(.degrees(-90))

                    ForEach(wheel.items) { item in
                        let point = CGPoint(
                            x: center.x + item.x * radius,
                            y: center.y + item.y * radius
                        )

                        pendoloLine(
                            item,
                            activeLine: line,
                            maxWidth: proxy.size.width * 0.56
                        )
                        .rotationEffect(
                            .degrees(item.angleDegrees * 0.16),
                            anchor: .leading
                        )
                        .scaleEffect(item.scale, anchor: .leading)
                        .opacity(item.opacity)
                        .position(point)
                    }

                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    theme.primaryColor.opacity(0.8),
                                    theme.accentColor.opacity(0.46),
                                    .clear,
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: 34
                            )
                        )
                        .frame(
                            width: 28 + audio.beat * 14,
                            height: 28 + audio.beat * 14
                        )
                        .position(
                            x: center.x,
                            y: center.y
                        )
                        .shadow(
                            color: theme.accentColor.opacity(audio.glow),
                            radius: 12 + audio.high * 10
                        )
                }
                .id(line.id)
                .transition(.opacity)
                .animation(
                    .spring(response: 0.72, dampingFraction: 0.86),
                    value: line.id
                )
            }
        }
    }

    @ViewBuilder
    private func pendoloLine(
        _ item: StagePendoloWheelItem,
        activeLine: StageLyricLine,
        maxWidth: CGFloat
    ) -> some View {
        if item.isActive {
            let fontSize = CGFloat(StageLyricTypography.fontSize(
                text: activeLine.text,
                availableWidth: Double(maxWidth)
            ))
            HStack(
                alignment: .firstTextBaseline,
                spacing: fontSize * 0.012
            ) {
                ForEach(scene.glyphs) { glyph in
                    StageFlowingLyricGlyph(
                        glyph: glyph,
                        fontSize: fontSize,
                        isChorus: scene.isChorus
                    )
                }
            }
            .fixedSize()
            .shadow(
                color: theme.accentColor.opacity(0.22 + audio.glow * 0.2),
                radius: 18
            )
        } else {
            Text(item.line.text)
                .font(.system(
                    size: 24,
                    weight: .semibold,
                    design: .rounded
                ))
                .foregroundStyle(
                    item.angleDegrees < 0
                        ? theme.secondaryColor.opacity(0.68)
                        : theme.primaryColor.opacity(0.72)
                )
                .lineLimit(1)
                .minimumScaleFactor(0.74)
                .frame(maxWidth: maxWidth * 0.72, alignment: .leading)
        }
    }
}

private struct StageDioramaLyricsFrame: View {
    @Environment(\.stageFoliaTheme) private var theme

    let scene: StageLyricFlowSceneModel
    let isProgramRailVisible: Bool
    let animationTime: TimeInterval
    let audio: StageLyricAudioMotion

    var body: some View {
        GeometryReader { proxy in
            if let line = scene.activeLine {
                let centerX = proxy.size.width * 0.5
                    + (isProgramRailVisible ? -140 : 0)
                ZStack {
                    particleField(size: proxy.size)

                    if let previous = scene.previousLine {
                        dioramaPanel(
                            previous.text,
                            width: min(520, proxy.size.width * 0.46),
                            opacity: 0.2
                        )
                        .rotation3DEffect(
                            .degrees(34),
                            axis: (x: 0.08, y: 1, z: 0),
                            perspective: 0.68
                        )
                        .position(
                            x: centerX - proxy.size.width * 0.27,
                            y: proxy.size.height * 0.3
                        )
                        .scaleEffect(0.76)
                    }

                    if let next = scene.nextLine {
                        dioramaPanel(
                            next.text,
                            width: min(520, proxy.size.width * 0.46),
                            opacity: 0.28
                        )
                        .rotation3DEffect(
                            .degrees(-38),
                            axis: (x: 0.06, y: 1, z: 0),
                            perspective: 0.68
                        )
                        .position(
                            x: centerX + proxy.size.width * 0.28,
                            y: proxy.size.height * 0.7
                        )
                        .scaleEffect(0.82)
                    }

                    activePanel(
                        line: line,
                        availableWidth: proxy.size.width * 0.6
                    )
                    .position(
                        x: centerX,
                        y: proxy.size.height * 0.5 + audio.beatLift * 0.22
                    )
                    .scaleEffect(audio.expansion)
                    .rotation3DEffect(
                        .degrees(sin(animationTime * 0.23) * 2.4),
                        axis: (x: 0.04, y: 1, z: 0),
                        perspective: 0.72
                    )
                }
                .id(line.id)
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
    }

    private func activePanel(
        line: StageLyricLine,
        availableWidth: CGFloat
    ) -> some View {
        let fontSize = CGFloat(StageLyricTypography.fontSize(
            text: line.text,
            availableWidth: Double(availableWidth)
        ))
        return VStack(spacing: 14) {
            HStack(
                alignment: .firstTextBaseline,
                spacing: fontSize * 0.012
            ) {
                ForEach(scene.glyphs) { glyph in
                    StageFlowingLyricGlyph(
                        glyph: glyph,
                        fontSize: fontSize,
                        isChorus: scene.isChorus
                    )
                }
            }
            .fixedSize()

            if let translation = scene.translation {
                Text(translation)
                    .font(.system(
                        size: max(15, fontSize * 0.18),
                        weight: .medium,
                        design: .rounded
                    ))
                    .foregroundStyle(theme.primaryColor.opacity(0.54))
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 28)
        .background {
            RoundedRectangle(cornerRadius: 28)
                .fill(.black.opacity(0.26))
                .overlay {
                    RoundedRectangle(cornerRadius: 28)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    theme.accentColor.opacity(0.5),
                                    theme.secondaryColor.opacity(0.24),
                                    theme.primaryColor.opacity(0.38),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
        }
        .shadow(
            color: theme.accentColor.opacity(audio.glow * 0.7),
            radius: 26 + audio.high * 18
        )
    }

    private func dioramaPanel(
        _ text: String,
        width: CGFloat,
        opacity: Double
    ) -> some View {
        Text(text)
            .font(.system(size: 24, weight: .semibold, design: .rounded))
            .foregroundStyle(theme.primaryColor.opacity(opacity))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .frame(width: width)
            .padding(.vertical, 22)
            .background {
                RoundedRectangle(cornerRadius: 24)
                    .fill(.white.opacity(0.025))
                    .overlay {
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(.white.opacity(0.07), lineWidth: 0.8)
                    }
            }
    }

    private func particleField(size: CGSize) -> some View {
        Canvas { context, canvasSize in
            let energy = max(audio.particleEnergy, 0.08)
            for index in 0 ..< 180 {
                let seed = Double(index) * 12.9898
                let unitX = abs(sin(seed * 0.71)) * canvasSize.width
                let unitY = abs(cos(seed * 1.17)) * canvasSize.height
                let drift = sin(animationTime * (0.16 + audio.mid * 0.2)
                    + seed) * (8 + energy * 24)
                let depth = 0.35 + abs(sin(seed * 0.33)) * 0.65
                let diameter = 0.7 + depth * (1.5 + audio.onset * 2.4)
                let point = CGRect(
                    x: unitX + drift,
                    y: unitY + cos(animationTime * 0.2 + seed) * 7,
                    width: diameter,
                    height: diameter
                )
                let color: Color = switch index % 3 {
                case 0:
                    theme.accentColor
                case 1:
                    theme.secondaryColor
                default:
                    theme.primaryColor
                }
                context.fill(
                    Path(ellipseIn: point),
                    with: .color(color.opacity(0.12 + energy * 0.28))
                )
            }
        }
        .frame(width: size.width, height: size.height)
        .blur(radius: 0.2 + audio.low * 0.7)
    }
}

private struct StageDepthLyricsFrame: View {
    @Environment(\.stageFoliaTheme) private var theme

    let scene: StageLyricSceneModel
    let isProgramRailVisible: Bool
    let audio: StageLyricAudioMotion

    var body: some View {
        ZStack {
            ForEach(scene.lines) { line in
                lyricLine(line)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(
            .easeOut(duration: 0.26),
            value: scene.lines.first(where: { $0.position == 0 })?.id
        )
    }

    private func lyricLine(_ line: StageLyricSceneLine) -> some View {
        let isCurrent = line.position == 0
        let railOffset = isProgramRailVisible ? -150.0 : 0
        let xOffset = railOffset + Double(line.position) * 92
        let yOffset = Double(line.position) * 96
            + (isCurrent ? audio.beatLift * 0.24 : 0)
        let glow = isCurrent
            ? theme.accentColor.opacity(0.5)
            : Color.black.opacity(0.72)

        return Text(line.text)
            .font(.system(
                size: isCurrent ? 38 : 24,
                weight: isCurrent ? .bold : .semibold,
                design: .rounded
            ))
            .tracking(isCurrent ? 0.4 : 0.1)
            .foregroundStyle(lyricGradient(isCurrent: isCurrent))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .frame(maxWidth: isCurrent ? 760 : 620)
            .shadow(color: glow, radius: isCurrent ? 18 : 7)
            .shadow(color: .black.opacity(0.96), radius: 4)
            .opacity(line.opacity)
            .blur(radius: line.blurRadius)
            .scaleEffect(
                line.scale * (isCurrent ? audio.expansion : 1)
            )
            .rotation3DEffect(
                .degrees(Double(line.position) * -12),
                axis: (x: 0.08, y: 1, z: 0),
                perspective: 0.68
            )
            .offset(x: xOffset, y: yOffset)
            .zIndex(isCurrent ? 6 : 2)
    }

    private func lyricGradient(isCurrent: Bool) -> LinearGradient {
        LinearGradient(
            colors: isCurrent
                ? [
                    theme.primaryColor,
                    theme.accentColor,
                ]
                : [
                    theme.primaryColor.opacity(0.76),
                    theme.accentColor.opacity(0.5),
                ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

@MainActor
final class StageOverlayState: ObservableObject {
    @Published private(set) var isProgramRailVisible = false

    func setProgramRailVisible(_ isVisible: Bool) {
        isProgramRailVisible = isVisible
    }
}

enum StageVisualPickerMode: Equatable {
    case space
    case player

    static func resolve(isWorldPresentationRequested: Bool) -> Self {
        isWorldPresentationRequested ? .space : .player
    }
}

enum StageVisualPickerGroup: Equatable {
    case worldSelection
    case avatarPlacement
    case loadingStatus
    case lyricsEffects
    case pointCloud
    case particleSize
    case musicVideo

    static func visibleGroups(
        for mode: StageVisualPickerMode
    ) -> [Self] {
        switch mode {
        case .space:
            [.worldSelection, .avatarPlacement, .loadingStatus]
        case .player:
            [.lyricsEffects, .pointCloud, .particleSize, .musicVideo]
        }
    }
}

enum StageControlPanelTab: String, Hashable, CaseIterable {
    case player, space, motions, activities

    /// P1：默认呈现面是空间。电台插件关闭（默认）时**任何**入口都先落在「空间」；
    /// 插件打开时恢复改动前的行为（空间模式落空间，其余落播放器）。
    /// 四个分区本身始终可选；`mode` 参数保留以免破坏调用点。
    static func initial(
        for mode: StageVisualPickerMode,
        isRadioPluginEnabled: Bool
    ) -> Self {
        guard isRadioPluginEnabled else { return .space }
        return mode == .space ? .space : .player
    }

    var title: String {
        switch self {
        case .player: "播放器"
        case .space: "空间"
        case .motions: "角色"
        case .activities: "活动"
        }
    }
}

enum StageControlPanelLayout {
    static let maximumWidth: CGFloat = 590
    static let maximumHeight: CGFloat = 458
    static let controlSize: CGFloat = 44
    static let sideInset: CGFloat = 4
    static let groupGap: CGFloat = 6
    static let settingsWidth: CGFloat = 68
    static let transportWidth: CGFloat = 8 * controlSize + settingsWidth + 2 * sideInset + 2 * groupGap + 1
}

enum StageActivityAvailability {
    static func unavailableMessage(
        isWorldVisible: Bool,
        isWorldPresentationRequested: Bool
    ) -> String {
        if isWorldVisible { return "这个空间还没有配置生活活动。" }
        return isWorldPresentationRequested
            ? "空间载入完成后可选择活动。" : "进入空间后可选择生活活动。"
    }

    static func canRun(
        isWorldVisible: Bool,
        selectedWorldID: String?,
        activityWorldID: String?
    ) -> Bool {
        isWorldVisible && selectedWorldID != nil && selectedWorldID == activityWorldID
    }
}

@MainActor
struct StageVisualPickerView: View {
    @ObservedObject var lyrics: StageLyricsStore
    @ObservedObject var visualDirections: StageVisualDirectionStore
    @ObservedObject var videos: StageVideoPlaybackStore
    @Bindable var programStore: DJProgramStore
    @Bindable var spatialStage: SpatialStageStore
    @Bindable var marbleLibrary: MarbleWorldLibrary
    @Bindable var avatarRuntime: StageAvatarRuntimeStore = .shared
    @ObservedObject private var activities = LivingWorldActivityMenuStore.shared
    @State private var model = PresenceSettingsModel()
    @State private var tab: StageControlPanelTab = .space
    @State private var didChooseInitialTab = false
    @State private var motionCategory: MotionLibraryCategory?
    var onRunActivity: @MainActor (String) -> Void = { _ in }
    var onStopActivity: @MainActor () -> Void = {}
    var onManageAssets: @MainActor () -> Void = {}

    private let lyricColumns = [GridItem(.adaptive(minimum: 90), spacing: 6)]
    private let pointCloudColumns = [GridItem(.adaptive(minimum: 110), spacing: 6)]
    private let videoColumns = [GridItem(.adaptive(minimum: 108), spacing: 6)]

    private var mode: StageVisualPickerMode {
        .resolve(isWorldPresentationRequested: spatialStage.isWorldPresentationRequested)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("舞台设置")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Text(mode == .space ? "正在空间中" : "正在播放器中")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.64))
            }
            Picker("设置分区", selection: $tab) {
                ForEach(StageControlPanelTab.allCases, id: \.self) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch tab {
                    case .player:
                        if mode == .space {
                            Label("这些效果用于播放器画面，切回播放器后可查看", systemImage: "info.circle")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.72))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        visualGroups(for: .player)
                    case .space: visualGroups(for: .space)
                    case .motions: motionGroup
                    case .activities: activityGroup
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(red: 0.075, green: 0.085, blue: 0.105))
                .overlay {
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                }
        }
        .foregroundStyle(.white.opacity(0.92))
        .environment(\.colorScheme, .dark)
        .shadow(color: .black.opacity(0.32), radius: 16, y: 6)
        .padding(7)
        .onAppear {
            guard !didChooseInitialTab else { return }
            tab = .initial(
                for: mode,
                isRadioPluginEnabled: RadioPluginAvailability.isEnabled()
            )
            didChooseInitialTab = true
        }
        .onChange(of: tab) { _, newTab in
            if newTab == .motions { model.load() }
        }
        .onChange(of: avatarRuntime.snapshot.avatar?.id) { _, _ in
            if tab == .motions { model.load() }
        }
    }

    private func visualGroups(for mode: StageVisualPickerMode) -> some View {
        let groups = StageVisualPickerGroup.visibleGroups(for: mode)
        return VStack(alignment: .leading, spacing: 12) {
            if groups.contains(.worldSelection) { worldSelectionGroup }
            if groups.contains(.avatarPlacement) { avatarPlacementGroup }
            if groups.contains(.loadingStatus) { loadingStatusGroup }
            if groups.contains(.lyricsEffects) { lyricsEffectsGroup }
            if groups.contains(.pointCloud) { pointCloudGroup }
            if groups.contains(.particleSize) { particleSizeGroup }
            if groups.contains(.musicVideo) { musicVideoGroup }
        }
    }

    private var motionGroup: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(avatarRuntime.snapshot.name ?? "尚未选择角色", systemImage: "person.crop.circle")
                Spacer()
                Button("刷新") { model.load() }
            }
            Text("选择已安装动作；自然待机可结束当前表演。")
                .foregroundStyle(.secondary)
            Picker("分类", selection: $motionCategory) {
                Text("全部").tag(MotionLibraryCategory?.none)
                ForEach(MotionLibraryCategory.allCases) { category in
                    Text(category.title).tag(MotionLibraryCategory?.some(category))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            ForEach(model.motions(in: motionCategory), id: \.id) { motion in
                let compatibility = model.motionCompatibility(motion)
                Button {
                    model.activateMotion(motion)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: avatarRuntime.snapshot.motion?.id == motion.id
                            ? "checkmark.circle.fill" : "figure.dance")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(motion.name)
                            if case let .incompatible(reason) = compatibility {
                                Text(reason).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(compatibility != .compatible || model.isWorking)
            }
            if model.motions.isEmpty {
                Text("暂无可用动作，请在资产管理中安装。")
            } else if let notice = model.motionListNotice {
                Text(notice).foregroundStyle(.secondary)
            } else if model.motions(in: motionCategory).isEmpty, motionCategory != nil {
                Text("这个分类下暂无当前角色可用的动作。").foregroundStyle(.secondary)
            }
            if let message = model.message {
                Text(message).foregroundStyle(model.hasError ? Color.orange : Color.secondary)
            }
            Button("管理角色与动作…", action: onManageAssets)
        }
        .font(.system(size: 12))
    }

    private var activityGroup: some View {
        let canRun = StageActivityAvailability.canRun(
            isWorldVisible: spatialStage.isWorldVisible,
            selectedWorldID: spatialStage.selectedWorldID,
            activityWorldID: activities.worldID
        )
        return VStack(alignment: .leading, spacing: 10) {
            Text("活动来自当前空间，角色会走到对应位置再开始。")
                .foregroundStyle(.secondary)
            if canRun {
                ForEach(activities.items) { item in
                    Button { onRunActivity(item.id) } label: {
                        HStack {
                            Image(systemName: activities.activeActivityID == item.id
                                ? "checkmark.circle.fill" : "play.circle")
                            Text(item.name)
                            Spacer()
                        }
                        .padding(10)
                        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
                if activities.items.isEmpty { Text("这个空间还没有配置生活活动。") }
                Button("停止活动", action: onStopActivity)
                    .disabled(activities.activeActivityID == nil)
                if let message = activities.message { Text(message).foregroundStyle(.secondary) }
            } else {
                Text(StageActivityAvailability.unavailableMessage(
                    isWorldVisible: spatialStage.isWorldVisible,
                    isWorldPresentationRequested: spatialStage.isWorldPresentationRequested
                ))
            }
        }
        .font(.system(size: 12))
    }

    private var worldSelectionGroup: some View {
        Menu {
            Section("公开空间") {
                ForEach(marbleLibrary.publicExampleWorlds) { world in
                    Button {
                        enter(worldID: world.id)
                    } label: {
                        if marbleLibrary.selectedWorld?.id == world.id {
                            Label(world.name, systemImage: "checkmark")
                        } else {
                            Text(world.name)
                        }
                    }
                }
            }
            Section("生成场景") {
                ForEach(SpatialScenePreset.allCases) { preset in
                    Button {
                        activate(preset: preset)
                    } label: {
                        Label(preset.displayName, systemImage: preset.symbolName)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "globe.americas.fill")
                Text(
                    marbleLibrary.selectedWorld?.isPublicExample == true
                        ? marbleLibrary.selectedWorld?.name ?? "公开空间"
                        : "公开空间 · 无需生成"
                )
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 12, weight: .bold))
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.68))
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 36)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.045))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.07), lineWidth: 1)
            }
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: .infinity)
    }

    private var avatarPlacementGroup: some View {
        VStack(alignment: .leading, spacing: 12) {
            pickerHeader("人物位置", symbol: "figure.stand")

            VStack(spacing: 5) {
                avatarPositionSlider(
                    axis: .x,
                    range: -2 ... 2,
                    accessibilityLabel: "人物左右位置"
                )
                avatarPositionSlider(
                    axis: .y,
                    range: -2 ... 2,
                    accessibilityLabel: "人物上下位置"
                )
                avatarPositionSlider(
                    axis: .z,
                    range: -3 ... 3,
                    accessibilityLabel: "人物前后位置"
                )
            }

            HStack {
                Text("人物位置会按当前空间保存")
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Button("重置") {
                    spatialStage.resetAvatarPosition()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.cyan.opacity(0.78))
            }
            .font(.system(size: 12, weight: .medium, design: .rounded))

            HStack {
                Text("W/S 沿视线前后移动，A/D 左右移动")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("镜头复位") { spatialStage.resetCamera() }
            }
            .font(.system(size: 12))
        }
    }

    @ViewBuilder
    private var loadingStatusGroup: some View {
        if spatialStage.isWorldPresentationRequested,
            !spatialStage.isWorldVisible
        {
            Label("正在载入空间，完成后自动进入…", systemImage: "cube.transparent")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.cyan.opacity(0.72))
                .lineLimit(1)
        } else if let message = marbleLibrary.generationMessage {
            Label(message, systemImage: "sparkles")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.cyan.opacity(0.72))
                .lineLimit(1)
        } else if let message = marbleLibrary.errorMessage {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.orange.opacity(0.78))
                .lineLimit(1)
        }
    }

    private var lyricsEffectsGroup: some View {
        VStack(alignment: .leading, spacing: 12) {
            pickerHeader("字幕特效", symbol: "captions.bubble")

            LazyVGrid(columns: lyricColumns, spacing: 6) {
                ForEach(StageLyricsVisualMode.allCases, id: \.self) { mode in
                    pickerButton(
                        title: mode.displayName,
                        symbol: mode.symbolName,
                        isSelected: lyrics.visualMode == mode
                    ) {
                        lyrics.setVisualMode(mode)
                    }
                }
            }
        }
    }

    private var pointCloudGroup: some View {
        VStack(alignment: .leading, spacing: 12) {
            pickerHeader("3D 点阵", symbol: "circle.hexagongrid")

            LazyVGrid(columns: pointCloudColumns, spacing: 6) {
                ForEach(StagePointCloudChoice.allCases, id: \.self) {
                    choice in
                    pickerButton(
                        title: choice.title,
                        symbol: choice.symbolName,
                        isSelected:
                            visualDirections.currentPointCloudChoice == choice
                    ) {
                        visualDirections.selectPointCloud(choice)
                    }
                }
            }
        }
    }

    private var particleSizeGroup: some View {
        HStack(spacing: 10) {
            Image(systemName: "circle.grid.2x2.fill")
                .foregroundStyle(.white.opacity(0.68))
            Slider(
                value: Binding(
                    get: {
                        Double(visualDirections.particleSizeMultiplier)
                    },
                    set: {
                        visualDirections.setParticleSizeMultiplier(
                            Float($0)
                        )
                    }
                ),
                in: Double(StageParticleSizing.manualRange.lowerBound)
                    ... Double(StageParticleSizing.manualRange.upperBound)
            )
            .tint(.cyan.opacity(0.86))
            .accessibilityLabel("颗粒大小")
            Text(
                "\(Int(visualDirections.particleSizeMultiplier * 100))%"
            )
            .monospacedDigit()
            .frame(width: 38, alignment: .trailing)
            .foregroundStyle(.white.opacity(0.68))
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .padding(.horizontal, 10)
        .frame(minHeight: 36)
    }

    private var musicVideoGroup: some View {
        VStack(alignment: .leading, spacing: 12) {
            pickerHeader("MV 场景", symbol: "film.stack")

            LazyVGrid(columns: videoColumns, spacing: 6) {
                pickerButton(
                    title: "导入 MP4",
                    symbol: "plus",
                    isSelected: false,
                    action: importMP4
                )
                ForEach(StageVideoPlaybackMode.allCases, id: \.self) {
                    mode in
                    pickerButton(
                        title: mode.displayName,
                        symbol: mode.symbolName,
                        isSelected: videos.isActive && videos.mode == mode
                    ) {
                        videos.setMode(mode)
                    }
                }
                pickerButton(
                    title: "关闭",
                    symbol: "xmark",
                    isSelected: !videos.isActive && !videos.assets.isEmpty
                ) {
                    videos.stop()
                }
            }

            if !videos.assets.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "sun.min")
                        .foregroundStyle(.white.opacity(0.68))
                    Slider(
                        value: Binding(
                            get: { Double(videos.brightness) },
                            set: { videos.setBrightness(Float($0)) }
                        ),
                        in: 0.15 ... 1
                    )
                    .tint(.cyan.opacity(0.86))
                    .accessibilityLabel("视频亮度")
                    Text("\(Int(videos.brightness * 100))%")
                        .monospacedDigit()
                        .frame(width: 38, alignment: .trailing)
                        .foregroundStyle(.white.opacity(0.68))
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .padding(.horizontal, 10)
                .frame(minHeight: 36)

                Menu {
                    ForEach(videos.assets) { asset in
                        Menu(asset.displayName) {
                            Button(
                                videos.isActive
                                    && videos.activeAssetID == asset.id
                                    ? "取消加载"
                                    : "加载"
                            ) {
                                videos.toggle(asset.id)
                            }

                            if let track = programStore.activeSlot?.track {
                                if videos.boundAsset(for: track.id)?.id == asset.id {
                                    Button("解除当前歌曲绑定") {
                                        videos.unbind(trackID: track.id)
                                    }
                                } else {
                                    Button("绑定到当前歌曲") {
                                        videos.bind(asset.id, to: track.id)
                                    }
                                }
                            }

                            Divider()
                            Button("移出素材库", role: .destructive) {
                                videos.remove(asset.id)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(
                            systemName: videos.isActive
                                ? "video.fill"
                                : "video.slash"
                        )
                        Text(videos.activeAsset?.displayName ?? "未加载视频")
                            .lineLimit(1)
                        Spacer()
                        Text(
                            videos.isActive
                                ? "已加载"
                                : "\(videos.assets.count) 段"
                        )
                            .foregroundStyle(.white.opacity(0.68))
                    }
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.68))
                    .padding(.horizontal, 12)
                    .frame(minHeight: 36)
                    .background(Color.white.opacity(0.045), in: Capsule())
                }
                .menuStyle(.borderlessButton)
            }
        }
    }

    private func pickerHeader(
        _ title: String,
        symbol: String
    ) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
    }

    private func avatarPositionSlider(
        axis: SpatialAvatarPositionAxis,
        range: ClosedRange<Double>,
        accessibilityLabel: String
    ) -> some View {
        let value = avatarPositionValue(for: axis)
        return HStack(spacing: 9) {
            Text(axis.rawValue)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.52))
                .frame(width: 12)
            Slider(
                value: Binding(
                    get: { Double(avatarPositionValue(for: axis)) },
                    set: {
                        spatialStage.setAvatarPosition(
                            Float($0),
                            axis: axis
                        )
                    }
                ),
                in: range,
                step: 0.01
            )
            .tint(.cyan.opacity(0.86))
            .accessibilityLabel(accessibilityLabel)
            Text(value.formatted(.number.precision(.fractionLength(2))))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.68))
                .frame(width: 42, alignment: .trailing)
        }
        .frame(minHeight: 36)
    }

    private func avatarPositionValue(
        for axis: SpatialAvatarPositionAxis
    ) -> Float {
        let position = spatialStage.avatarPlacement.position
        switch axis {
        case .x:
            return position.x
        case .y:
            return position.y
        case .z:
            return position.z
        }
    }

    private func pickerButton(
        title: String,
        symbol: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                Text(title)
                    .font(.system(
                        size: 12,
                        weight: .semibold,
                        design: .rounded
                    ))
                    .lineLimit(1)
            }
            .foregroundStyle(
                isSelected
                    ? Color(red: 0.48, green: 0.95, blue: 1)
                    : Color.white.opacity(0.62)
            )
            .frame(maxWidth: .infinity)
            .frame(minHeight: 48)
            .background {
                RoundedRectangle(cornerRadius: 13)
                    .fill(
                        isSelected
                            ? Color.cyan.opacity(0.16)
                            : Color.white.opacity(0.045)
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 13)
                    .stroke(
                        isSelected
                            ? Color.cyan.opacity(0.52)
                            : Color.white.opacity(0.07),
                        lineWidth: isSelected ? 1 : 0.8
                    )
            }
        }
        .buttonStyle(.plain)
    }

    private func activate(preset: SpatialScenePreset) {
        spatialStage.requestWorldPresentation()
        Task {
            await marbleLibrary.activate(preset: preset)
            if marbleLibrary.errorMessage != nil {
                spatialStage.exitWorld()
            }
        }
    }

    private func enter(worldID: String) {
        spatialStage.requestWorldPresentation()
        Task {
            guard await marbleLibrary.select(worldID: worldID) != nil else {
                spatialStage.exitWorld()
                return
            }
        }
    }

    private func importMP4() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "导入"
        panel.message = "选择要与 3D 点阵叠加的 MP4 片段"
        guard panel.runModal() == .OK else {
            return
        }
        videos.add(panel.urls)
    }
}

struct StageProgramRailCard: Equatable, Identifiable {
    let slotIndex: Int
    let trackID: String
    let title: String
    let artist: String
    let energy: Double
    let relativeIndex: Int
    let isCurrent: Bool
    let depth: Int
    let opacity: Double
    let scale: Double

    var id: String {
        trackID
    }
}

enum StageProgramRailCardLayout {
    static func horizontalOffset(
        relativeIndex: Int,
        isFocused: Bool
    ) -> Double {
        if isFocused {
            return -30
        }
        return Double(min(2, abs(relativeIndex))) * 9
    }
}

struct StageProgramRailModel: Equatable {
    let title: String?
    let cards: [StageProgramRailCard]

    init(
        plan: ProgramPlan?,
        activeSlotIndex: Int?
    ) {
        guard let plan, !plan.slots.isEmpty else {
            self.init(
                title: plan?.title,
                tracks: [],
                activeIndex: nil
            )
            return
        }

        let activeIndex: Int?
        if
            let activeSlotIndex,
            plan.slots.indices.contains(activeSlotIndex)
        {
            activeIndex = activeSlotIndex
        } else {
            activeIndex = nil
        }

        self.init(
            title: plan.title,
            tracks: plan.slots.map(\.track),
            activeIndex: activeIndex
        )
    }

    init(
        playlist: MusicPlaylistSnapshot,
        activeTrackID: String?
    ) {
        self.init(
            title: playlist.name,
            tracks: playlist.tracks,
            activeIndex: activeTrackID.flatMap { activeTrackID in
                playlist.tracks.firstIndex { $0.id == activeTrackID }
            }
        )
    }

    private init(
        title: String?,
        tracks: [MusicCandidate],
        activeIndex: Int?
    ) {
        self.title = title
        cards = tracks.enumerated().map { absoluteIndex, track in
            let relativeIndex = activeIndex.map {
                absoluteIndex - $0
            } ?? absoluteIndex
            let isCurrent = absoluteIndex == activeIndex
            let distance = abs(relativeIndex)
            let visualDistance = min(distance, 2)
            return StageProgramRailCard(
                slotIndex: absoluteIndex,
                trackID: track.id,
                title: track.title,
                artist: track.artist,
                energy: track.energy,
                relativeIndex: relativeIndex,
                isCurrent: isCurrent,
                depth: visualDistance * -72,
                opacity: isCurrent
                    ? 1
                    : max(
                        relativeIndex < 0 ? 0.34 : 0.46,
                        1 - Double(visualDistance) * 0.16
                    ),
                scale: isCurrent
                    ? 1
                    : max(
                        0.78,
                        1 - Double(visualDistance) * 0.055
                    )
            )
        }
    }
}

@MainActor
enum StageProgramRailRoute: Equatable {
    case programs
    case tracks(programID: String)
    case playlistTracks(playlistID: String)
}

enum StageProgramRailCatalog {
    static func visiblePrograms(
        _ programs: [SavedDJProgram],
        syncedPlaylists: [MusicPlaylistSnapshot]
    ) -> [SavedDJProgram] {
        let syncedIDs = Set(syncedPlaylists.map(\.id))
        return programs.filter {
            !syncedIDs.contains($0.plan.brief.id)
        }
    }
}

@MainActor
final class StageProgramRailSelection: ObservableObject {
    @Published private(set) var route = StageProgramRailRoute.programs
    @Published private(set) var selectedProgramID: String?
    @Published private(set) var selectedPlaylistID: String?
    @Published private(set) var selectedSlotIndex: Int?
    private let onPlay: @MainActor (String, Int) -> Void
    private let onReplan: @MainActor () -> Void
    private let onPlayPlaylist: @MainActor (String, Int) -> Void
    private let onOpenPlaylist: @MainActor (String) -> Void
    private let onLoadMorePlaylist: @MainActor (String) -> Void

    init(
        onPlay: @escaping @MainActor (String, Int) -> Void = { _, _ in },
        onPlayPlaylist:
            @escaping @MainActor (String, Int) -> Void = { _, _ in },
        onOpenPlaylist:
            @escaping @MainActor (String) -> Void = { _ in },
        onLoadMorePlaylist:
            @escaping @MainActor (String) -> Void = { _ in },
        onReplan: @escaping @MainActor () -> Void = {}
    ) {
        self.onPlay = onPlay
        self.onPlayPlaylist = onPlayPlaylist
        self.onOpenPlaylist = onOpenPlaylist
        self.onLoadMorePlaylist = onLoadMorePlaylist
        self.onReplan = onReplan
    }

    func openProgram(_ programID: String) {
        selectedProgramID = programID
        selectedPlaylistID = nil
        selectedSlotIndex = nil
        route = .tracks(programID: programID)
    }

    func openPlaylist(_ playlistID: String) {
        selectedPlaylistID = playlistID
        selectedProgramID = nil
        selectedSlotIndex = nil
        route = .playlistTracks(playlistID: playlistID)
        onOpenPlaylist(playlistID)
    }

    func showPrograms() {
        selectedSlotIndex = nil
        route = .programs
    }

    func activate(slotIndex: Int) {
        selectedSlotIndex = slotIndex
        switch route {
        case let .tracks(programID):
            onPlay(programID, slotIndex)
        case let .playlistTracks(playlistID):
            onPlayPlaylist(playlistID, slotIndex)
        case .programs:
            break
        }
    }

    func replan() {
        onReplan()
    }

    func loadMoreSelectedPlaylist() {
        guard let selectedPlaylistID else {
            return
        }
        onLoadMorePlaylist(selectedPlaylistID)
    }
}

@MainActor
struct StageProgramRailView: View {
    @Bindable var programStore: DJProgramStore
    @Bindable var libraryStore: SyncedMusicLibraryStore
    @ObservedObject var selection: StageProgramRailSelection
    @ObservedObject var videos: StageVideoPlaybackStore
    let audioFeatures: VisualAudioFeatureStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var programs: [SavedDJProgram] {
        let candidates: [SavedDJProgram]
        if !programStore.recentPrograms.isEmpty {
            candidates = programStore.recentPrograms
        } else if let plan = programStore.plan {
            candidates = [
                SavedDJProgram(
                    plan: plan,
                    activeSlotIndex: programStore.activeSlotIndex,
                    updatedAt: plan.generatedAt
                ),
            ]
        } else {
            candidates = []
        }
        return StageProgramRailCatalog.visiblePrograms(
            candidates,
            syncedPlaylists: libraryStore.playlists
        )
    }

    private var selectedProgram: SavedDJProgram? {
        guard let selectedProgramID = selection.selectedProgramID else {
            return nil
        }
        return programs.first {
            $0.plan.brief.id == selectedProgramID
        }
    }

    private var selectedPlaylist: MusicPlaylistSnapshot? {
        guard let selectedPlaylistID = selection.selectedPlaylistID else {
            return nil
        }
        return libraryStore.playlist(id: selectedPlaylistID)
    }

    private var trackModel: StageProgramRailModel {
        if let selectedPlaylist {
            return StageProgramRailModel(
                playlist: selectedPlaylist,
                activeTrackID: programStore.plan?.brief.id == selectedPlaylist.id
                    ? programStore.activeSlot?.track.id
                    : nil
            )
        }
        let selected = selectedProgram
        let isPlayingSelectedProgram =
            selected?.plan.brief.id == programStore.plan?.brief.id
        return StageProgramRailModel(
            plan: selected?.plan,
            activeSlotIndex: isPlayingSelectedProgram
                ? programStore.activeSlotIndex
                : nil
        )
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            switch selection.route {
            case .programs:
                programList
            case .tracks:
                trackList
            case .playlistTracks:
                trackList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, 42)
        .padding(.trailing, 10)
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.22),
            value: selection.route
        )
    }

    @ViewBuilder
    private var programList: some View {
        if programs.isEmpty && libraryStore.playlists.isEmpty {
            emptyState
                .padding(.top, 96)
        } else {
            railHeader(
                title: "歌单",
                count: programs.count + libraryStore.playlists.count
            )
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .trailing, spacing: 4) {
                    ForEach(programs, id: \.plan.brief.id) { saved in
                        Button {
                            selection.openProgram(saved.plan.brief.id)
                        } label: {
                            HStack(spacing: 13) {
                                Image(systemName: "radio.fill")
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(Color.cyan.opacity(0.88))
                                    .frame(width: 42, height: 42)
                                    .background(
                                        Color.cyan.opacity(0.1),
                                        in: Circle()
                                    )

                                VStack(alignment: .leading, spacing: 5) {
                                    Text(
                                        programTitle(saved.plan)
                                    )
                                    .font(.system(
                                        size: 16,
                                        weight: .semibold,
                                        design: .rounded
                                    ))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .lineLimit(1)

                                    Text(
                                        "\(saved.plan.slots.count) 首"
                                            + programDirection(saved.plan)
                                    )
                                    .font(.system(
                                        size: 13,
                                        weight: .medium,
                                        design: .rounded
                                    ))
                                    .foregroundStyle(.white.opacity(0.46))
                                    .lineLimit(1)
                                }

                                Spacer(minLength: 4)

                                if
                                    saved.plan.brief.id
                                        == programStore.pendingPlan?.brief.id
                                {
                                    Image(systemName: "sparkles")
                                        .font(.system(
                                            size: 13,
                                            weight: .semibold
                                        ))
                                        .foregroundStyle(
                                            Color.cyan.opacity(0.9)
                                        )
                                        .help("后台新编排，等待切换")
                                } else {
                                    Image(systemName: "chevron.right")
                                        .font(.system(
                                            size: 12,
                                            weight: .semibold
                                        ))
                                        .foregroundStyle(
                                            .white.opacity(0.34)
                                        )
                                }
                            }
                            .padding(.horizontal, 14)
                            .frame(width: 306, height: 74)
                            .background(
                                .ultraThinMaterial,
                                in: RoundedRectangle(cornerRadius: 22)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 22)
                                    .stroke(
                                        saved.plan.brief.id
                                            == programStore.plan?.brief.id
                                            ? Color.cyan.opacity(0.44)
                                            : Color.white.opacity(0.11),
                                        lineWidth: 1
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                        .rotation3DEffect(
                            .degrees(-7),
                            axis: (x: 0, y: 1, z: 0),
                            anchor: .trailing,
                            perspective: 0.72
                        )
                        .shadow(color: .black.opacity(0.38), radius: 13, y: 7)
                    }
                    ForEach(libraryStore.playlists) { playlist in
                        syncedPlaylistButton(playlist)
                    }
                }
            }
            .contentMargins(.vertical, 18)
            .mask(railMask)
        }
    }

    @ViewBuilder
    private var trackList: some View {
        if trackModel.cards.isEmpty {
            Group {
                if selectedPlaylist != nil {
                    VStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在加载歌曲…")
                            .font(.system(
                                size: 13,
                                weight: .medium,
                                design: .rounded
                            ))
                    }
                    .foregroundStyle(.white.opacity(0.58))
                } else {
                    emptyState
                }
            }
                .padding(.top, 96)
                .onAppear {
                    selection.loadMoreSelectedPlaylist()
                }
        } else {
            HStack(spacing: 8) {
                Button {
                    selection.showPrograms()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.72))
                .accessibilityLabel("返回节目单")

                Spacer(minLength: 4)
                if let title = trackModel.title, !title.isEmpty {
                    Text(title.uppercased())
                        .lineLimit(1)
                }
                if let selectedPlaylist {
                    Text(
                        "· \(selectedPlaylist.tracks.count)"
                            + " / \(selectedPlaylist.trackCount)"
                    )
                } else {
                    Text("· \(trackModel.cards.count)")
                }
                if selectedPlaylist == nil {
                    replanButton
                }
            }
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .tracking(1.2)
            .foregroundStyle(.white.opacity(0.62))
            .shadow(color: .black.opacity(0.9), radius: 4)
            .padding(.horizontal, 14)

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .trailing, spacing: -7) {
                        ForEach(trackModel.cards) { card in
                            programCard(card)
                                .id(card.slotIndex)
                                .onAppear {
                                    guard
                                        selectedPlaylist != nil,
                                        card.slotIndex
                                            >= trackModel.cards.count - 4
                                    else {
                                        return
                                    }
                                    selection.loadMoreSelectedPlaylist()
                                }
                                .scrollTransition(
                                    .interactive,
                                    axis: .vertical
                                ) { content, phase in
                                    content
                                        .opacity(
                                            phase.isIdentity ? 1 : 0.56
                                        )
                                        .scaleEffect(
                                            phase.isIdentity ? 1 : 0.9,
                                            anchor: .trailing
                                        )
                                        .rotation3DEffect(
                                            .degrees(
                                                Double(phase.value) * -13
                                            ),
                                            axis: (x: 1, y: 0.16, z: 0),
                                            anchor: .trailing,
                                            perspective: 0.72
                                        )
                                }
                        }
                        if let selectedPlaylist,
                           selectedPlaylist.tracks.count
                            < selectedPlaylist.trackCount
                        {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.cyan.opacity(0.8))
                                .frame(width: 306, height: 44)
                                .onAppear {
                                    selection.loadMoreSelectedPlaylist()
                                }
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
                .contentMargins(.vertical, 18)
                .mask(railMask)
                .onAppear {
                    scrollToActive(using: proxy, animated: false)
                }
                .onChange(of: programStore.activeSlotIndex) {
                    scrollToActive(using: proxy, animated: true)
                }
            }
        }
    }

    private func railHeader(title: String, count: Int) -> some View {
        HStack(spacing: 10) {
            replanButton
            Spacer(minLength: 4)
            Text("\(title.uppercased()) · \(count)")
        }
        .font(.system(size: 14, weight: .semibold, design: .rounded))
        .tracking(1.2)
        .foregroundStyle(.white.opacity(0.62))
        .shadow(color: .black.opacity(0.9), radius: 4)
        .padding(.horizontal, 14)
    }

    private func syncedPlaylistButton(
        _ playlist: MusicPlaylistSnapshot
    ) -> some View {
        Button {
            selection.openPlaylist(playlist.id)
        } label: {
            HStack(spacing: 13) {
                AsyncImage(url: playlist.artworkURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Color.red.opacity(0.88))
                }
                .frame(width: 42, height: 42)
                .background(Color.red.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 5) {
                    Text(playlist.name)
                        .font(.system(
                            size: 16,
                            weight: .semibold,
                            design: .rounded
                        ))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                    Text(
                        "\(providerName(playlist.providerID)) · "
                            + "\(playlist.trackCount) 首"
                    )
                    .font(.system(
                        size: 13,
                        weight: .medium,
                        design: .rounded
                    ))
                    .foregroundStyle(.white.opacity(0.46))
                    .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.34))
            }
            .padding(.horizontal, 14)
            .frame(width: 306, height: 74)
            .background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: 22)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 22)
                    .stroke(Color.white.opacity(0.11), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .rotation3DEffect(
            .degrees(-7),
            axis: (x: 0, y: 1, z: 0),
            anchor: .trailing,
            perspective: 0.72
        )
        .shadow(color: .black.opacity(0.38), radius: 13, y: 7)
    }

    private func providerName(_ providerID: MusicProviderID) -> String {
        switch providerID {
        case .netease:
            "网易云"
        case .qqMusic:
            "QQ 音乐"
        case .appleMusic:
            "Apple Music"
        default:
            "音乐库"
        }
    }

    private var replanButton: some View {
        Button {
            selection.replan()
        } label: {
            Image(
                systemName: programStore.status == .planning
                    ? "hourglass"
                    : "arrow.triangle.2.circlepath"
            )
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(
                programStore.status == .planning
                    ? Color.orange.opacity(0.86)
                    : Color.cyan.opacity(0.88)
            )
            .frame(width: 28, height: 28)
            .background(Color.white.opacity(0.06), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(programStore.status == .planning)
        .help(
            programStore.status == .planning
                ? "DJ 正在重新编排"
                : "让 DJ 重新编排后续歌曲"
        )
        .accessibilityLabel("重新编排后续歌曲")
    }

    private var railMask: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.08),
                .init(color: .black, location: 0.92),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func programDirection(_ plan: ProgramPlan) -> String {
        guard let direction = plan.direction, !direction.isEmpty else {
            return ""
        }
        return " · \(direction)"
    }

    private func programTitle(_ plan: ProgramPlan) -> String {
        guard let title = plan.title, !title.isEmpty else {
            return "未命名节目"
        }
        return title
    }

    private var emptyState: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.path")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.cyan.opacity(0.9))

            Text(programStore.status == .planning ? "DJ 正在排歌" : "暂无节目")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.84))
        }
        .padding(.horizontal, 20)
        .frame(height: 64)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .stroke(Color.cyan.opacity(0.24), lineWidth: 1)
        }
        .shadow(color: Color.cyan.opacity(0.14), radius: 24)
    }

    @ViewBuilder
    private func programCard(_ card: StageProgramRailCard) -> some View {
        let isFocused = selection.selectedSlotIndex.map {
            $0 == card.slotIndex
        } ?? card.isCurrent
        let relative = Double(
            max(-2, min(2, card.relativeIndex))
        )
        let distance = Double(min(2, abs(card.relativeIndex)))
        ZStack(alignment: .topTrailing) {
            Button {
                withAnimation(
                    reduceMotion ? nil : .easeOut(duration: 0.2)
                ) {
                    selection.activate(slotIndex: card.slotIndex)
                }
            } label: {
                HStack(spacing: 13) {
                ZStack {
                    Circle()
                        .fill(
                            card.isCurrent
                                ? Color.cyan.opacity(0.22)
                                : Color.white.opacity(0.06)
                        )
                    if card.isCurrent {
                        StageReactiveTrackIcon(
                            audioFeatures: audioFeatures
                        )
                    } else {
                        Image(
                            systemName: isFocused
                                ? "play.fill"
                                : "music.note"
                        )
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(
                            isFocused
                                ? Color(red: 0.48, green: 0.95, blue: 1)
                                : Color.white.opacity(0.52)
                        )
                    }
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 5) {
                    Text(card.title)
                        .font(.system(
                            size: card.isCurrent ? 17 : 16,
                            weight: .semibold,
                            design: .rounded
                        ))
                        .foregroundStyle(.white.opacity(card.isCurrent ? 0.96 : 0.82))
                        .lineLimit(1)

                    HStack(spacing: 12) {
                        Text(card.artist)
                            .font(.system(
                                size: 14,
                                weight: .medium,
                                design: .rounded
                            ))
                            .foregroundStyle(.white.opacity(0.48))
                            .lineLimit(1)

                        Spacer(minLength: 4)

                        energyTrace(card.energy)
                    }
                }
                }
                .padding(.horizontal, 14)
                .frame(width: 294, height: 76)
                .background {
                RoundedRectangle(cornerRadius: 23)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        LinearGradient(
                            colors: [
                                Color(
                                    red: 0.02,
                                    green: 0.55,
                                    blue: 0.88
                                ).opacity(card.isCurrent ? 0.19 : 0.06),
                                Color.black.opacity(0.12),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 23))
                    }
                }
                .overlay {
                RoundedRectangle(cornerRadius: 23)
                    .stroke(
                        card.isCurrent
                            ? Color.cyan.opacity(0.52)
                            : Color.white.opacity(0.12),
                        lineWidth: card.isCurrent ? 1.2 : 0.8
                    )
                }
                .shadow(
                color: card.isCurrent
                    ? Color.cyan.opacity(0.2)
                    : Color.black.opacity(0.42),
                radius: card.isCurrent ? 24 : 13,
                y: 7
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                card.isCurrent
                    ? "正在播放，\(card.title)，\(card.artist)"
                    : "选择，\(card.title)，\(card.artist)"
            )
            .accessibilityHint("立即播放这首歌曲")

            if card.isCurrent, videos.boundAsset(for: card.trackID) != nil {
                Button {
                    videos.playBoundVideo(for: card.trackID)
                } label: {
                    Image(systemName: "video.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(
                            videos.activeAssetID
                                == videos.boundAsset(for: card.trackID)?.id
                                && videos.isActive
                                ? Color.cyan
                                : Color.white.opacity(0.62)
                        )
                        .frame(width: 26, height: 26)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .offset(x: -9, y: 8)
                .help("播放这首歌绑定的视频")
                .accessibilityLabel("播放绑定视频")
            }
        }
        .scaleEffect(
            isFocused ? card.scale + 0.055 : card.scale,
            anchor: .trailing
        )
        .opacity(isFocused ? 1 : card.opacity)
        .blur(radius: isFocused ? 0 : distance * 0.16)
        .rotation3DEffect(
            .degrees(isFocused ? -4 : -10 - relative * 2.5),
            axis: (x: 0, y: 1, z: 0),
            anchor: .trailing,
            perspective: 0.72
        )
        .offset(
            x: StageProgramRailCardLayout.horizontalOffset(
                relativeIndex: card.relativeIndex,
                isFocused: isFocused
            ),
            y: 0
        )
        .zIndex(
            isFocused || card.isCurrent
                ? 20
                : Double(10 - abs(card.relativeIndex))
        )
    }

    private func scrollToActive(
        using proxy: ScrollViewProxy,
        animated: Bool
    ) {
        guard let activeSlotIndex = programStore.activeSlotIndex else {
            return
        }
        let action = {
            proxy.scrollTo(activeSlotIndex, anchor: .center)
        }
        if animated && !reduceMotion {
            withAnimation(.easeOut(duration: 0.24), action)
        } else {
            action()
        }
    }

    private func energyTrace(_ energy: Double) -> some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0 ..< 7, id: \.self) { index in
                let wave = 0.36
                    + abs(sin(Double(index + 1) * 1.7)) * 0.64
                Capsule()
                    .fill(Color.cyan.opacity(0.42))
                    .frame(width: 2, height: 5 + 13 * energy * wave)
            }
        }
        .frame(width: 28, height: 22)
        .accessibilityHidden(true)
    }
}

private struct StageReactiveTrackIcon: View {
    let audioFeatures: VisualAudioFeatureStore

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { _ in
            let audio = audioFeatures.current
            HStack(alignment: .center, spacing: 2) {
                ForEach(0 ..< 5, id: \.self) { index in
                    let sample = abs(audio.waveform[index])
                    let band = switch index {
                    case 0, 1:
                        audio.low
                    case 2:
                        audio.mid
                    default:
                        audio.high
                    }
                    let activity = max(
                        sample,
                        band * 0.72,
                        audio.amplitude * 0.56
                    )
                    Capsule()
                        .fill(Color(red: 0.48, green: 0.95, blue: 1))
                        .frame(
                            width: 2.4,
                            height: 5 + CGFloat(activity) * 18
                        )
                }
            }
            .frame(width: 24, height: 25)
            .animation(
                .linear(duration: 1 / 30),
                value: audio.amplitude
            )
        }
        .accessibilityHidden(true)
    }
}

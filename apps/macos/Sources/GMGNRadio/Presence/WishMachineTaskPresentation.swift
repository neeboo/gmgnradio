import Foundation
import Combine

// MARK: - 状态收敛：三条互不相干的轴 + 一个开关

/// **生成轴**：排队 → 生成中 → 完成 / 失败。
/// 网络只影响这条轴的**进度**，不影响别的轴，也不构成"需要人工解除的暂停"。
enum ResidentGenerationAxis: String, Equatable, Sendable {
    case queued, generating, completed, failed
    // 三轴**没有**自己的 `label`（2026-10-02 收口）：原先那四个字面量
    // （排队中 / 生成中 / 已完成 / 已失败）是与唯一投影并存的第二套状态词。
    // 三轴 → 一句话只有**一个**出口：`ResidentTaskAxisProjection.currentStatus` →
    // `ResidentOwnershipProjection.sentence(...)` → `OwnershipSentence`。
}

/// **归属轴**：未领取 → 已领取 → 已入库。
/// **只前进**：网络、重启、重复刷新都不能把它推回去（见 `advance(_:to:)`）。
enum ResidentOwnershipAxis: String, Equatable, Sendable, Comparable {
    case unclaimed, claimed, inInventory
    // 同上：`label`（未领取 / 已领取 / 已入库）已删 —— 那一句话在唯一投影里。

    private var rank: Int {
        switch self {
        case .unclaimed: 0
        case .claimed: 1
        case .inInventory: 2
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }

    /// 归属是**只前进**的：一次投影最多把它推进到 `next`，绝不后退。
    /// 退回意味着"东西没了"，而那是本次收敛要消灭的观感。
    static func advance(_ current: Self, to next: Self) -> Self { max(current, next) }
}

/// **摆放轴**：未摆放 → 在库存 → 已摆放。由用户或居民摆放它。
///
/// 低档刻意分成两格：`归属` 还没到「已入库」时，摆放这条轴**还没开始**，
/// 那时说「在库存」就是一句假话 —— 这个仓库刚为同一类假话（"已领取并入库"）
/// 付过代价（真机 2026-10-01 `2B 白色长剑`）。用户给的两级阶梯
/// （在库存 → 已摆放）原样保留，只是给它补了一个诚实的起点。
enum ResidentPlacementAxis: String, Equatable, Sendable, Comparable {
    case notYetPlaced, inInventory, placed
    // 同上：`label`（未摆放 / 在库存 / 已摆放）已删 —— 那一句话在唯一投影里。

    private var rank: Int {
        switch self {
        case .notYetPlaced: 0
        case .inInventory: 1
        case .placed: 2
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// 一个任务的**三轴状态**。任务行只表达这三轴：不含授权（见开关），
/// 也不含连通性（见全局横幅）。
struct ResidentTaskAxes: Equatable, Sendable {
    var generation: ResidentGenerationAxis
    var ownership: ResidentOwnershipAxis
    var placement: ResidentPlacementAxis

    /// 生成轴自己的失败/进度补充说明。**连通性事实不属于这里**。
    var generationDetail: String?
}

/// 三轴投影的**唯一**判据。宿主只负责把事实读出来交给它，判断只在这里发生，
/// 所以"任务行说了什么"不可能与"三轴是什么"各存一份。
enum ResidentTaskAxisProjection {
    /// 生成轴事实（由 `WishMachineJob.stage` + `remoteState` 读得）。
    enum GenerationFact: Equatable, Sendable {
        case submitted
        case submissionUncertain
        case remoteQueued
        case remotePreflight
        case remoteWaitingResources
        case remoteRunning
        case downloaded
        case completed
        case failed
        case cancelled
        case interrupted
    }

    /// 归属轴事实。`inInventory` **只能**来自库存读回（`state.objectStates`），
    /// 不能来自"模型已备好"或任何缓存。
    enum OwnershipFact: Equatable, Sendable {
        case notClaimed
        case claimedNotInInventory
        case inInventory
    }

    /// 摆放轴事实（由摆放委托或世界读回得到）。摆放**失败/停止**不是这条轴的取值：
    /// 它只是"还停在低档"，原因由任务自己的 `status`/`detail` 说（可读、可见）。
    enum PlacementFact: Equatable, Sendable {
        case unknown
        case notPlaced
        case placed
        case failed
        case stopped
    }

    static func generation(_ fact: GenerationFact) -> ResidentGenerationAxis {
        switch fact {
        case .submitted, .submissionUncertain, .remoteQueued, .remotePreflight, .remoteWaitingResources:
            .queued
        case .remoteRunning, .downloaded:
            .generating
        case .completed:
            .completed
        case .failed, .cancelled, .interrupted:
            .failed
        }
    }

    static func ownership(_ fact: OwnershipFact) -> ResidentOwnershipAxis {
        switch fact {
        case .notClaimed: .unclaimed
        case .claimedNotInInventory: .claimed
        case .inInventory: .inInventory
        }
    }

    /// 摆放这一档要看**归属**：没有真的进库存就没有"在库存待摆"这回事。
    static func placement(_ fact: PlacementFact, ownership: ResidentOwnershipAxis) -> ResidentPlacementAxis {
        if fact == .placed { return .placed }
        return ownership == .inInventory ? .inInventory : .notYetPlaced
    }

    /// 三轴一起算出来。归属**只前进**由 `previous.ownership` 保证；摆放这一轴
    /// 也按归属的**推进后**取值，所以不会出现「归属=未领取 / 摆放=在库存」这种自相矛盾。
    static func project(_ generation: GenerationFact, ownership ownershipFact: OwnershipFact,
                        placement placementFact: PlacementFact,
                        previousOwnership: ResidentOwnershipAxis = .unclaimed,
                        generationDetail: String? = nil) -> ResidentTaskAxes {
        let ownership = ResidentOwnershipAxis.advance(previousOwnership, to: Self.ownership(ownershipFact))
        return ResidentTaskAxes(
            generation: Self.generation(generation),
            ownership: ownership,
            placement: Self.placement(placementFact, ownership: ownership),
            generationDetail: generationDetail
        )
    }

    // MARK: 三轴 → 一句现状

    /// **三轴 → 一句现状**。全仓只有这一份：视图不按轴各拼一段文案，也不另存状态文案，
    /// 所以"任务行说了什么"仍然只由三轴决定（与 `project` 同一处判据）。
    ///
    /// 取法是「**最靠后的、对用户最有意义的那一步**」，不是"最坏的那个"：
    /// 沿 `生成 → 归属 → 摆放` 这条链**从后往前**看，走到哪一步就说哪一步。
    /// 于是「已摆放」的任务不会因为生成轴上曾经失败而被说成"生成失败"。
    ///
    /// **字面量不再在这里**（2026-10-02 收口）：这一句委托给唯一投影
    /// `ResidentOwnershipProjection.sentence(generation:ownership:placement:)`，
    /// 于是任务行、列表、「房间里」、托盘、agent 回执取的是**同一份** `OwnershipSentence`。
    /// 以前这里自己写着 可领取 / 等待入库 / 未摆放 —— 那是与投影并存的第二套状态词，
    /// 同一件事在任务行与列表里能说成两句不同的话。
    ///
    /// 三轴语义一个字没动（`project` / `advance` / `hasReachedTerminalStep` 照旧）：
    /// 变的只是这三轴**合成哪一句话**，而且那句话只有一个出口。
    ///
    /// 唯一不由这里说的是**失败**：`.failed` 只说明"没做成"，说不出是失败、取消还是
    /// 中断，所以任务行走既有失败通道（见 `WishMachineTaskPresentation.currentStatusLine`），
    /// 原因仍在 `detail` 那一行 —— 不在这里另造一句。
    static func currentStatus(_ axes: ResidentTaskAxes) -> String {
        ResidentOwnershipProjection.sentence(
            generation: axes.generation.rawValue,
            ownership: axes.ownership.rawValue,
            placement: axes.placement.rawValue)
    }

    /// 三轴上「已经走到头」的那一档：**进了库存**或**摆了出来**。
    ///
    /// 宿主把一件事判成终态（`isTerminal`），三轴却还没走到这一档 ⇒ 那一定是**没做成**
    /// （生成失败 / 已取消 / 任务已中断 / 场景加载失败 / 摆放失败…）。此时任务行交回
    /// 既有失败通道：绝不把"还没做成"说成轴上的下一步（例如把加载失败说成「可领取」）。
    static func hasReachedTerminalStep(_ axes: ResidentTaskAxes) -> Bool {
        axes.placement == .placed || axes.ownership == .inInventory
    }
}

// MARK: - 连通性：全局事实，不是任务属性

/// 连通性是**一条全局提示**：连不上后台时舞台/小窗顶部出现一条横幅，说明可读原因，
/// 恢复后自动消失。它绝不作为任务的属性出现在任务行上。
enum ResidentConnectivityFact {
    /// 连通性词汇的**唯一**一份。`WishMachineCoordinator.isNetworkClassSubmissionError`
    /// 表达的是同一件事，收敛时应当委托到这里，而不是各存一套。
    static let vocabulary: Set<String> = ["network_unavailable", "remote_unavailable"]

    /// 一行文本是不是连通性事实。判据只看这一行**本身**是不是那个词，
    /// 不做子串匹配 —— 避免把"已恢复 network_unavailable 之后"这类叙述误判。
    static func isConnectivityLine(_ line: String) -> Bool {
        vocabulary.contains(line.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 连通性事实的人类可读横幅文案。`nil` 表示连通正常（横幅自动消失）。
    static func bannerText(for line: String) -> String {
        let reason = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return "连不上后台（\(reason)）。任务和产物都还在，恢复后会自己继续；这条提示会自动消失。"
    }

    /// 从多行文本里挑出**第一条**连通性事实；`nil` 表示没有连通性问题。
    static func firstConnectivityLine(in text: String?) -> String? {
        guard let text else { return nil }
        return text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: isConnectivityLine)
    }

    /// 把连通性事实从任务自己的文本里摘掉：任务行不许再渲染它。
    static func strippingConnectivityLines(from text: String?) -> String? {
        guard let text else { return nil }
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !isConnectivityLine($0) }
            .filter { !$0.isEmpty }
        return kept.isEmpty ? nil : kept.joined(separator: "\n")
    }
}

// MARK: - 一个开关：允许居民自主行动

/// 「能不能自主」是**一个全局开关**，不是任务状态。
///   - 关着＝不自己动手，但你仍可下令；开着＝它可以自己去领去摆。
///   - 「用户显式停止」仍然有效（安全语义保留）：停止后不自主。
///   - 解除只需**一个动作**，且**不需要按任务逐个恢复**。
///
/// 键名与通知名复用设置里已有的那一份（`resident.autonomous.enabled.v1` /
/// `gmgnResidentAutonomyChanged`），不另造一套开关。
enum ResidentAutonomySwitch {
    static let defaultsKey = "resident.autonomous.enabled.v1"
    static let didChangeNotification = Notification.Name("gmgnResidentAutonomyChanged")
}

/// **授权事实的文本形态**。
///
/// 投影会在 `detail` 里追加一句"自主行动已停止：…直接下达指令仍可当轮执行。"。
/// 那是**授权**（用户显式停止），不是任务自己的说明，因此它属于全局开关横幅，
/// 不属于任务行。判据只有这一份；投影侧最终应当干脆不写它（收敛到只留这里），
/// 在那之前由呈现边界把它摘出来交给全局横幅 —— 与连通性走完全一样的路。
enum ResidentAutonomyFact {
    static let stoppedNoticeMarker = "自主行动已停止"

    static func containsStopNotice(_ text: String?) -> Bool {
        guard let text else { return false }
        return text.split(separator: "\n").contains {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix(stoppedNoticeMarker)
        }
    }

    /// 把授权文本从任务自己的说明里摘掉：任务行不许再渲染它。
    static func strippingStopNotice(from text: String?) -> String? {
        guard let text else { return nil }
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix(stoppedNoticeMarker) }
            .filter { !$0.isEmpty }
        return kept.isEmpty ? nil : kept.joined(separator: "\n")
    }
}

/// A projection of one persisted wish; dialog activity does not own its lifetime.
/// `promptExpiresAt` hides a terminal task's on-site prompt after its 30-second
/// window: the anchor lives in the shared inbox store, so refreshes, window
/// reopenings and restarts never extend it. History and the unread badge are
/// unaffected — expiry only hides the prompt.
///
/// **任务行只表达它自己的三轴状态（生成/归属/摆放），不表达授权，也不表达连通性。**
/// 授权由全局开关 `ResidentAutonomySwitch` 表达，连通性由全局横幅
/// `ResidentConnectivityFact` 表达。
///
/// `autoContinuationPaused` 仍然是宿主持久化的**任务级停止事实**，但它**不是**
/// 一个可以按任务渲染/按任务解除的控件：它只用来算"全局开关是不是被用户显式停过"，
/// 并且只由**一个**全局动作解除（见 `WishMachineTaskPresentationStore.resumeAutonomy`）。
struct WishMachineTaskPresentation: Identifiable, Equatable {
    let id: UUID
    let title: String
    /// 宿主的**既有事实/失败通道**（"场景加载失败""已取消""生成中"…）。
    /// 任务行不再直接渲染它，只经 `currentStatusLine` 使用：
    /// 正常推进时那一句由三轴派生，三轴说不出的失败才回到这一句。
    /// 授权/连通性仍然不在这里（见 `ResidentAutonomyFact` / `ResidentConnectivityFact`）。
    let status: String
    /// 任务**自己的**补充说明（生成进度、摆放原因、入库 backlog）。
    /// 连通性事实不会留在这里 —— 它由 `ResidentConnectivityFact` 摘到全局横幅，
    /// 所以这一项在 `WishMachineTaskPresentationStore.update` 里会被就地摘干净。
    var detail: String?
    let isTerminal: Bool
    /// 三轴状态。宿主投影提供时，任务行按三轴渲染；为 `nil` 时退回 `status` 一行。
    var axes: ResidentTaskAxes? = nil
    /// 宿主那句话**必须**盖过三轴那一档。
    ///
    /// 三轴说得出"走到了哪一步"（排队/生成/完成 → 未领取/已领取/已入库 → 未摆放/已摆放），
    /// 说不出"**这一刻托盘上有没有它**"。而"可领取"这句话是关于托盘的：托盘上没有它时
    /// 三轴照样会说"可领取"，任务行于是与空托盘自相矛盾（真机 2026-10-02「超大荧幕电视」：
    /// 任务行说有下一步、托盘上什么都没有、也领不了）。
    ///
    /// 所以判据仍是**一处**（`currentStatusLine`），只是它现在能听到宿主那句从**现场推导**
    /// （`WishMachineOutputReachability`）得来的话。它不是第二个状态来源：
    /// `status` 本来就存在，这里只是允许它在三轴说得不完整时说话。
    /// 与 `isTerminal` 分开是有意的：`isTerminal` 还会让**站内提示 30 秒后过期**，
    /// 而"还在把产物放上托盘"不是终态，任务行不许因此消失。
    var hostSentenceWins: Bool = false
    /// 内部事实：该任务被**用户显式停止**过（持久化的 `autoContinuationStoppedByUser`
    /// 或同等证据）。**不按任务渲染**，只参与"全局开关是否被停过"的判定。
    var autoContinuationPaused: Bool = false
    var promptExpiresAt: Date? = nil
}

// MARK: - 任务行的唯一一句现状

extension WishMachineTaskPresentation {
    /// 任务行渲染的**唯一一句现状**（面板上每条任务只有这一句状态，不再是三个轴标签）。
    ///
    /// 判断只有一处：正常推进时它由三轴派生（`ResidentTaskAxisProjection.currentStatus`）。
    /// 三轴说不出的失败仍然走**既有失败通道**：三轴还没走到头（没进库存、也没摆出来），
    /// 宿主却已经把它判成终态 —— 那是没做成（生成失败 / 已取消 / 任务已中断 /
    /// 场景加载失败 / 摆放失败…），这一句就用宿主那句话，原因仍在 `detail` 那一行。
    /// 视图里因此**没有任何 if/else**，也没有第二份状态文案。
    ///
    /// `axes == nil` 时退回宿主那句话：这次简化只减去标签，不减去状态。
    ///
    /// `hostSentenceWins` 时也走宿主那句：三轴给不出"托盘这一刻有没有它"，
    /// 而"可领取"说的正是托盘。两者因此不可能一个说"可领取"、另一个空着。
    var currentStatusLine: String {
        guard let axes else { return status }
        if hostSentenceWins { return status }
        if isTerminal, !ResidentTaskAxisProjection.hasReachedTerminalStep(axes) { return status }
        return ResidentTaskAxisProjection.currentStatus(axes)
    }
}

@MainActor
final class WishMachineTaskPresentationStore: ObservableObject {
    @Published private(set) var tasks: [WishMachineTaskPresentation] = []
    /// 全局连通性提示：连不上后台的可读原因。`nil` 表示连通正常（横幅不显示）。
    @Published private(set) var connectivityNotice: String?
    /// 一次"恢复自主行动"没有真的解开时的可读原因。绝不静默变回原样。
    @Published private(set) var autonomyResumeFailure: String?
    /// 宿主的**一个**全局动作：解除该任务的自动续办并获得一次可信授权。
    /// 由宿主接线（不是模型工具），所以解除不依赖任何措辞。
    /// 全局横幅把它按"一次点击 → 所有被停任务"扇出，用户不需要按任务逐个恢复。
    var onResumeAutomaticContinuation: ((UUID) -> Void)?

    /// 宿主推来的**权威**连通性事实（后台健康，`PropGenerationStore.errorMessage`）。
    /// 为 `nil` 时退回从投影文本里推导，所以宿主接线之前这条横幅也真的会亮 ——
    /// 不会留下一个永远不出现的提示。
    private var reportedConnectivity: String?
    private var derivedConnectivity: String?

    /// 宿主推来的**权威**全局自主停止事实（run 级用户停止，`ResidentAgentLoop`）。
    @Published private(set) var hostAutonomyStop = false
    /// 从投影文本里读到的授权事实（"自主行动已停止…"，见 `ResidentAutonomyFact`）。
    @Published private(set) var reportedAutonomyStop = false

    /// **用户显式停止是否仍然有效**（安全语义保留）。这是**全局**判定：任意一份证据
    /// （run 级停止 / 任务级持久暂停 / 投影文本里的停止事实）为真，自主就是停的。
    /// 它不是一个可以按任务渲染、按任务解除的东西。
    var isAutonomyStoppedByUser: Bool {
        hostAutonomyStop || reportedAutonomyStop || tasks.contains { $0.autoContinuationPaused }
    }

    /// 全局开关的当前值。直接读设置里那**一个**键，不另存一份状态；
    /// 呈现侧每秒重算，所以设置里改一下这里一秒内跟上。
    var isAutonomySwitchOn: Bool {
        UserDefaults.standard.bool(forKey: ResidentAutonomySwitch.defaultsKey)
    }

    /// 宿主推来的权威连通性事实（后台连不上时的可读原因）。这是**一条全局提示**。
    func setConnectivityWarning(_ text: String?) {
        guard reportedConnectivity != text else { return }
        reportedConnectivity = text
        connectivityNotice = text ?? derivedConnectivity
    }

    /// 宿主推来的权威全局自主停止事实（run 级用户停止）。
    func setHostAutonomyStop(_ stopped: Bool) {
        guard hostAutonomyStop != stopped else { return }
        hostAutonomyStop = stopped
    }

    func update(_ tasks: [WishMachineTaskPresentation]) {
        // 连通性与授权都是**全局事实**，不是任务属性：先把它们从任务自己的文本里
        // 摘出来，再让任务行去渲染。任务行因此不可能显示它们 —— 而它们各自仍然
        // **可见**，出现在全局横幅上（不允许变成"东西没了"）。
        let connectivityLine = tasks.compactMap { task in
            ResidentConnectivityFact.firstConnectivityLine(in: task.detail)
                ?? (ResidentConnectivityFact.isConnectivityLine(task.status) ? task.status : nil)
        }.first
        let stopped = tasks.contains { ResidentAutonomyFact.containsStopNotice($0.detail) }
        let stripped = tasks.map { task -> WishMachineTaskPresentation in
            var value = task
            value.detail = ResidentConnectivityFact.strippingConnectivityLines(from: task.detail)
            value.detail = ResidentAutonomyFact.strippingStopNotice(from: value.detail)
            return value
        }
        derivedConnectivity = connectivityLine.map(ResidentConnectivityFact.bannerText)
        connectivityNotice = reportedConnectivity ?? derivedConnectivity
        reportedAutonomyStop = stopped
        guard self.tasks != stripped else { return }
        self.tasks = stripped
    }

    /// 全局开关的**一个动作**：打开开关、解除 run 级停止，并把该空间里**所有**
    /// 被用户停过的任务一次解开。用户不需要知道有几个任务、也不需要逐个点。
    ///
    /// 做不成时 `autonomyResumeFailure` 一定有话说 —— 不允许"点了没反应"。
    func resumeAutonomy() {
        UserDefaults.standard.set(true, forKey: ResidentAutonomySwitch.defaultsKey)
        // 复用设置里那条既有通知：宿主据此解除 run 级停止并热更新后台预算。
        NotificationCenter.default.post(name: ResidentAutonomySwitch.didChangeNotification, object: nil)
        let paused = tasks.filter(\.autoContinuationPaused)
        guard !paused.isEmpty else { autonomyResumeFailure = nil; return }
        guard let resume = onResumeAutomaticContinuation else {
            autonomyResumeFailure = "自主开关已打开，但仍有 \(paused.count) 个任务停在原地：宿主还没接上恢复通道。任务和产物都还在。"
            return
        }
        for task in paused { resume(task.id) }
        autonomyResumeFailure = nil
    }
}

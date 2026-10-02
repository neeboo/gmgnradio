import Foundation

// ---------------------------------------------------------------------------
// 许愿任务 = **一条条消息**，不是一个窗口、也不是一块常驻列表。
//
// 用户 2026-10-02 原话：
//   「小窗也是不要有遮挡」
//   「许愿任务变成消息提示，不要单独做窗口了」
//
// 所以：许愿任务自己的窗口/列表**没有了**。它的每一次状态变化只生成**一条人话消息**，
// 走进**既有的**消息通道（与居民对话的地方，见 `publishResidentTranscript`）——
// 不新造面板、不新造窗口。
//
// 三条纪律：
//   1. **状态来源是唯一投影** `ResidentOwnershipProjection.row(_:)`。这里**不判断**
//      "它现在算什么状态"：`state` / `statusText` 都是投影的输出，文案只是把它
//      逐字说出来（连状态词都不自己造一份 —— 造一份就是第二套状态词）。
//   2. **同一状态只发一次**：幂等键 = 行标识 + 投影状态，见 `WishMachineTaskMessageFeed`。
//   3. **失败待办不自动消失**：`keepsUntilHandled` 只由 `OwnershipDisplayState.failed`
//      （唯一投影的判定）给出，不看时钟。取消/中断是 `.ended`，按既有窗口过期。
//
// 本文件**只依赖 Foundation 与唯一投影**（`OwnershipRow` / `OwnershipDisplayState` /
// `OwnershipSentence`），所以能被离线 harness 直接编译并逐条驱动。
// ---------------------------------------------------------------------------

/// 「这一档状态此刻还占不占屏幕」的**唯一**一条规则。
///
/// 用户 2026-10-02 原话：「左上角这个也不应该常驻啊」。收起的规矩一个字没变：
/// 有到期锚点（终态，由共享收件箱按 `updatedAt` 现算）就按它收起；没有（还没了结）
/// 就一直留着。**失败待办不走这条时间窗**（见 `WishMachineTaskMessage.keepsUntilHandled`）。
///
/// 它原来住在 `VisualEngine/StageOverlayView.swift` 里，跟着那块列表一起；列表按产品
/// 决定整个删掉之后，规则搬到消息通道这边（**只有这一处实现** —— 消息通道与离线
/// harness 问的是同一个它）。本文件只依赖 Foundation，所以这条规则可以在没有 app、
/// 没有 UI 的情况下被逐条驱动。
enum WishMachineTaskPrompt {
    static func isShown(promptExpiresAt: Date?, at now: Date) -> Bool {
        guard let expiry = promptExpiresAt else { return true }
        return now < expiry
    }
}

/// 许愿任务的一条消息（给用户看的一句话）。
struct WishMachineTaskMessage: Equatable, Identifiable, Sendable {
    /// 幂等键 = 行标识 + 投影给出的那一档状态。同一状态永远同一个 id。
    let id: String
    /// 这一行是谁（`OwnershipRowKey.identifier`）。**内部标识，不进文案**。
    let taskID: String
    /// 投影给出的对外状态 + 那一句人话（幂等键的组成部分）。
    let stateKey: String
    /// 一句话人话（界面上逐字显示这一句）。
    let text: String
    /// **失败待办**：这条消息不自动消失，留到用户处理完。
    ///
    /// 判据就是唯一投影的 `OwnershipDisplayState.failed`（生成失败 / 已领取但入库没保存
    /// 都落在这一档）；已取消 / 已中断是 `.ended`，不在这里。**没有第二份真相**。
    let keepsUntilHandled: Bool

    /// 展示层的回合标识：**稳定派生**，不是随机 UUID。
    ///
    /// 于是同一条消息每次推到聊天通道都得到同一个 id，重复推送不会让展示层以为
    /// "又来了一条新消息"。它是一个内部标识，**永远不会出现在 `text` 里**。
    var transcriptTurnID: UUID {
        let first = Self.fnv1a(id, seed: 0xcbf2_9ce4_8422_2325)
        let second = Self.fnv1a(id, seed: 0x9e37_79b9_7f4a_7c15)
        var bytes: [UInt8] = []
        for value in [first, second] {
            withUnsafeBytes(of: value.bigEndian) { bytes.append(contentsOf: $0) }
        }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func fnv1a(_ text: String, seed: UInt64) -> UInt64 {
        var hash = seed
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}

/// 唯一投影的一行 → 一条消息。**判据全部来自投影**，这里只有措辞。
enum WishMachineTaskMessageBuilder {
    /// 一件东西的称呼。拿不到人给的名字时**绝不**把内部编号（`wish-prop-<uuid>`）
    /// 当名字说出去 —— 说出去就是界面上出现 UUID。
    static func displayName(_ row: OwnershipRow) -> String {
        let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != row.key.objectID else { return "这件东西" }
        return name
    }

    /// 投影那一档 → 幂等键。`state` 与 `statusText` 都是投影的输出，所以
    /// "同一状态"这件事不可能与投影分叉（例如 `.failed` 里的「生成失败」与
    /// 「已领取，入库尚未保存」是两条不同的消息，因为投影给了两句不同的人话）。
    static func stateKey(_ row: OwnershipRow) -> String {
        "\(row.state.rawValue)|\(row.statusText)"
    }

    static func identifier(_ row: OwnershipRow) -> String {
        "\(row.key.identifier)#\(stateKey(row))"
    }

    /// 一条消息的**逐字文案**：投影那一句人话 + 这件东西的名字。
    ///
    /// 刻意不按状态另写一套词：`OwnershipSentence` 已经是"这件事现在怎么样"的
    /// **唯一**一份人话（任务行、列表、托盘、agent 回执读的都是它）。这里再造一套
    /// 就等于同一件事又能被说成两句不同的话。
    /// 失败那一档多说的半句是**关于这条消息自己**的（它会留着），不是状态词。
    static func message(_ row: OwnershipRow) -> WishMachineTaskMessage? {
        // 没有许愿记录的行（孤儿产物 / 只有墓碑）不是许愿任务的状态，不产生消息。
        guard row.key.jobID != nil else { return nil }
        let sentence = row.statusText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentence.isEmpty else { return nil }
        let keepsUntilHandled = row.state == .failed
        var text = "「\(displayName(row))」\(sentence)。"
        if keepsUntilHandled {
            text += "这条提示会留到你处理完。"
        }
        return WishMachineTaskMessage(
            id: identifier(row),
            taskID: row.key.identifier,
            stateKey: stateKey(row),
            text: text,
            keepsUntilHandled: keepsUntilHandled)
    }
}

/// 消息通道的**去重与保留**规则（全仓唯一一处）。
///
/// - **同一状态只发一次**：幂等键 = 行标识 + 投影状态；已经发过的键**不再追加**，
///   重复喂同一份投影是幂等的（这就是"状态没变不重复"）。
/// - **失败待办不自动消失**：`keepsUntilHandled` 的消息只在唯一投影**不再**把它判成
///   `.failed` 的那一刻收起 —— 也就是"用户处理完了"，与时钟无关。
/// - **其它终态按既有窗口过期**：到期锚点就是**既有的**那一个（共享收件箱按
///   `updatedAt` 现算的 `promptExpiresAt`，终态后 30 秒）。这里不新造时间来源，
///   所以刷新 / 重开窗口 / 重启都不会把这个窗口往后推。
struct WishMachineTaskMessageFeed {
    /// 一次同步喂进来的候选：投影的一行 + 那件任务**既有的**到期锚点。
    struct Candidate: Equatable, Sendable {
        let row: OwnershipRow
        let promptExpiresAt: Date?

        init(row: OwnershipRow, promptExpiresAt: Date?) {
            self.row = row
            self.promptExpiresAt = promptExpiresAt
        }
    }

    private(set) var messages: [WishMachineTaskMessage] = []
    /// 发过的状态（幂等键 → 消息）。**只增不删**是故意的：同一状态换个时刻再来，
    /// 也还是"已经发过"，不会再发一条。
    private var issued: [String: WishMachineTaskMessage] = [:]
    /// 每条消息的到期锚点（`nil` = 投影此刻说它还没了结）。
    private var anchors: [String: Date?] = [:]
    /// 发出顺序（消息按"事情发生的先后"排）。
    private var order: [String] = []

    /// 换世界 / 换居民：旧消息全部作废，新上下文重新开始。
    mutating func reset() {
        messages = []
        issued = [:]
        anchors = [:]
        order = []
    }

    /// 喂一次当前投影；返回**此刻应显示**的消息（已发出的顺序）。
    @discardableResult
    mutating func sync(_ candidates: [Candidate], now: Date) -> [WishMachineTaskMessage] {
        var live = Set<String>()
        var failingTaskIDs = Set<String>()
        for candidate in candidates {
            guard let message = WishMachineTaskMessageBuilder.message(candidate.row) else { continue }
            live.insert(message.id)
            if message.keepsUntilHandled { failingTaskIDs.insert(message.taskID) }
            // 到期锚点每次按**最新现算值**刷新：同一个 id 的锚点是稳定的（收件箱内容变了
            // 就是另一档状态、另一个 id），所以刷新既不会把窗口往后推，又能让"第一次同步时
            // 收件箱还没落库"这种时序不留下一辈子不过期的消息。
            anchors[message.id] = candidate.promptExpiresAt
            guard issued[message.id] == nil else { continue }
            issued[message.id] = message
            order.append(message.id)
        }
        messages = order.compactMap { id -> WishMachineTaskMessage? in
            guard let message = issued[id] else { return nil }
            if message.keepsUntilHandled {
                // 失败待办：它与时钟无关，只在投影不再说它失败时收起。
                return failingTaskIDs.contains(message.taskID) ? message : nil
            }
            // 非失败：只有"这一刻仍然是那一档"才显示（状态推进了就不再占着通道）。
            guard live.contains(id) else { return nil }
            // 到期锚点走**唯一**那一条规则（未了结 ⇒ 没有锚点 ⇒ 一直显示）。
            return WishMachineTaskPrompt.isShown(promptExpiresAt: anchors[id] ?? nil, at: now)
                ? message : nil
        }
        return messages
    }
}

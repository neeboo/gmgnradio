import Foundation

// ---------------------------------------------------------------------------
// 「我的物件」的**唯一**投影：一行 = 一次许愿（`jobID` 为主）∪ 一件世界物件。
//
// 这一份回答一个问题：「我许愿过的东西现在怎么样了」，而且答案是
// **`状态 = f(权威)`** —— 权威是 `wishes.json`（过程）与世界文档（归属），
// 外加几条**会话内**事实（资产失败、入库待补做台账、托盘是否显示它）。
//
// 六条纪律（见 docs/plans/2026-10-02-ownership-list-design.md §3.3）：
// 1. 没有 `OwnershipListStore`：列表是事实的**纯函数结果**，不存第二份状态；
// 2. 类型上写不出"存下来"：`OwnershipRow` / `OwnershipDisplayState` **不实现
//    `Codable`**、没有 `init(rawValue:)`，不进 `wishes.json` / `state.json` /
//    `UserDefaults`；
// 3. 只能"读不到"，不许"沿用上一次"；
// 4. 归属轴复用既有投影（`ResidentOwnershipAxis.advance`），这里不重判"算不算已入库"；
// 5. **禁止反解 `objectID`**：`job ⇄ object` 只做正向比对
//    （① `job.objectID == object.objectID`，② `job.id.uuidString == object.sourceWishID`），
//    历史的短命名（`wish-prop-ebfc07be`）反查不出 job；
// 6. 对外状态**只有五种**（+ 折叠的「已结束」）：生成中 / 未领取 / 在库里（没摆）/
//    已摆放 / 失败。设计稿里那 18 个内部状态只能往这五种上映射；映射不进去的
//    （例如还没提交的 `pendingDrafts`，它既不是 job 也不是物件）**不产生行**。
//
// 本文件**只依赖 Foundation**：这样它可以被离线 harness 直接编译，
// 拿真机 `wishes.json` + `state.json` 逐行复核。
// ---------------------------------------------------------------------------

/// 一行的主键：许愿编号（有 job 时）+ 物件编号（铸造时就是
/// `"wish-prop-" + jobID.lowercased()`，但**绝不**用它反解 job）。
struct OwnershipRowKey: Hashable, Sendable {
    let jobID: UUID?
    let objectID: String

    /// 唯一行标识（同一个 `objectID` 一行、同一个 `jobID` 一行）。
    var identifier: String { "\(jobID?.uuidString ?? "-")/\(objectID)" }
}

/// `wishes.json` 里那条 job 的阶段。**逐字**对应 `WishMachineStage`（不新增取值）。
enum OwnershipJobStage: String, Sendable, CaseIterable {
    case submitting, submissionUncertain, generating, generated, ready, failed, cancelled, interrupted, claimed
}

/// 世界文档里这件东西在哪儿。**判据只有一处**（`WorldState`）：
/// - `placed`  ⟺ `objectStates[id].generatedProp != nil && isEnabled == true`
/// - `held`    ⟺ `heldProp?.objectID == id`（挂上去时 `isEnabled` 被置 false）
/// - `inventory` ⟺ 有 `generatedProp`、`isEnabled == false`、也不在手里
/// - `absent`  ⟺ `objectStates` 里没有它（未入库 / 已删除）
enum OwnershipRoomPresence: String, Sendable, CaseIterable {
    case absent, inventory, placed, held
}

/// **对外状态：只有这五种**（+ `ended`，它只在折叠的「已结束」里）。
///
/// 这里刻意**不是**设计稿 §2.2 那 18 个内部状态：界面上不许出现内部术语。
enum OwnershipDisplayState: String, Sendable, CaseIterable {
    case generating
    case awaitingClaim
    case inInventory
    case placed
    case failed
    /// 折叠组「已结束」：已删除 / 已取消 / 任务已中断。
    case ended

    /// 界面上那一枚状态词（**唯一**一份）。
    var label: String {
        switch self {
        case .generating: return "生成中"
        case .awaitingClaim: return "未领取"
        case .inInventory: return "在库里（没摆）"
        case .placed: return "已摆放"
        case .failed: return "失败"
        case .ended: return "已结束"
        }
    }
}

/// 四组，顺序固定。哪一行进哪一组由 `state` 决定（唯一投影），不由视图决定。
enum OwnershipGroup: String, Sendable, CaseIterable {
    case needsYou
    case inInventory
    case inRoom
    case ended

    var title: String {
        switch self {
        case .needsYou: return "待你处理"
        case .inInventory: return "在库里"
        case .inRoom: return "在房间里"
        case .ended: return "已结束"
        }
    }
}

/// 一件东西的**全部**用户可读句子。全仓只有这一份字面量：
/// 面板那一行、任务行那一句、agent 回执取的都是这里。
enum OwnershipSentence: String, Sendable, CaseIterable {
    case generating = "生成中"
    case submitting = "正在提交后台"
    case submissionUncertain = "提交结果待确认"
    case cancelPending = "取消请求处理中"
    case awaitingClaim = "未领取"
    /// 「还没上托盘」**不是那一档的主文案**（用户 2026-10-02 拍板：`stage=ready` 的主文案
    /// 就是「未领取」）。它是**原因**，只在行内展开 / 原因那一行里出现 ——
    /// 主文案带着它会让同一档在托盘前后说成两句不同的话，而"这一件到底领没领"只有一个答案。
    case notOnTrayReason = "许愿机托盘一次只展示一件；它还没上托盘。"
    case inInventory = "在库里（没摆）"
    case heldByResident = "在居民手里"
    case placed = "已摆放"
    case generationFailed = "生成失败"
    /// 场景加载失败：它是**徽标 + 原因**，不把整行改成"失败"（见 `row(_:)` 的 `.ready` 支）。
    case renderFailed = "场景加载失败"
    /// 与 `ResidentPropInventoryBacklog.pendingNotice` **逐字同源**的那一句。
    case inventoryNotSaved = "已领取，入库尚未保存"
    case deleted = "已删除"
    case cancelled = "已取消"
    case interrupted = "任务已中断"
}

/// 由 `state` 派生（**不由调用点 if/else 决定**）的行内动作。
enum OwnershipRowAction: String, Sendable, CaseIterable {
    /// 就地领取：走既有的 `WishMachineCoordinator.claim`，判据一个字不改。
    case claim
    /// 「领取」够不到许愿机时的那条路：让居民自己去（既有 agent 路径
    /// `claim_when_arrived`）。**不新增人类通道、不放宽 0.25 m / activityID 判据。**
    case askResidentToFetch
    /// 重试：`.failed` 的原提交确认 / `submissionUncertain` 的原提交重放。
    /// **走既有的** `WishMachineCoordinator.retry`（阶段判据见 `retryableStages`）。
    case retry
    /// 「重试入库」：**已领取但没写进库存**那一行的下一步。
    ///
    /// 它**不是** `retry`：`retryableStages` 刻意不含 `.claimed`（已经有产物了，重发会
    /// 多出一件）。这一步走的是**既有**的入库补做路径
    /// （`drainResidentPropInventoryBacklog(reason:)` → `synchronizeOwnedResidentProps`
    /// → 摆放服务的 `register`，回执键仍是 `claimed.<jobID>`），判定一个字不放宽：
    /// 承托几何拿不到时 `register` 照样 fail-closed 拒绝。
    case retryInventoryRegistration
    /// 摆放（既有面板点行进携带态）。
    case place
    /// 收回（既有 `withdraw`）。
    case withdraw
    /// 删除（既有世界命令，永久）。
    case delete

    var label: String {
        switch self {
        case .claim: return "领取"
        case .askResidentToFetch: return "让居民去取"
        case .retry: return "重试"
        case .retryInventoryRegistration: return "重试入库"
        case .place: return "摆放"
        case .withdraw: return "收回"
        case .delete: return "删除"
        }
    }
}

/// 「这句话的出处」：**字段名 + 值**。分叉时用户与我们看到的都是"两个值不一样"，
/// 而不是一个盖住另一个。
struct OwnershipEvidence: Equatable, Sendable {
    let field: String
    let value: String
    init(_ field: String, _ value: String) {
        self.field = field
        self.value = value
    }
}

/// 一行需要的**全部**事实。没有一项是"上一版列表算出来的"。
///
/// 过程权威来自 `wishes.json`，归属权威来自世界文档；`assetFailure` /
/// `inventoryPending*` / `trayShowsThis` / `canClaimNow` / `canRetryNow` 是
/// **会话内**事实（重启即消失），只用来解释"现在为什么不能动"。
struct OwnershipRowFacts: Equatable, Sendable {
    /// 世界物件编号。job 一定有它（铸造时就是 `"wish-prop-" + jobID.lowercased()`）。
    var objectID: String

    // ── 过程权威：`wishes.json` 的一条 job（可以没有：孤儿行） ──
    var jobID: UUID?
    var jobName: String?
    var jobStage: OwnershipJobStage?
    var remoteState: String?
    var lastError: String?
    var cancelRequested: Bool = false
    var renderFailureMessage: String?
    /// job 在 `wishes.json` 里的位置：越大越新（数组是追加写的）。
    ///
    /// **为什么不用时间戳**：`WishMachineJob` 与 `WishMachineEvent` 都没有时间字段，
    /// 所以"组内按最近倒序"只能用这个**确定性**的替代（设计稿 §5 的"确定性优先于
    /// 感觉上的新"）。孤儿行没有这个数，按 `objectID` 字典序排在后面。
    var processOrder: Int?

    // ── 归属权威：世界文档 ──
    var objectPresent: Bool = false
    var objectHasGeneratedProp: Bool = false
    var objectName: String?
    var objectIsEnabled: Bool = false
    /// 挂在身上时的手/挂点（`heldProp.hand`），没挂就是 nil。
    var heldSlot: String?
    /// 墓碑（有意删除）。删除**不回写** `wishes.json`，所以状态必须读它，
    /// 否则删了还会显示成"已摆出"。
    var tombstoneName: String?
    var tombstoneReason: String?
    var tombstoneSettlement: String?

    // ── 世界回执（幂等键）：`layoutReceipts["claimed.<jobID>"]` ──
    var claimReceiptPresent: Bool = false
    /// 「重试入库」这条动作今天真的走得通吗。
    ///
    /// **不是**这里判的：它是 `WorldState.canRedoInventoryRegistration(objectID:)` 的
    /// 返回值（宿主在 `residentPropWishFacts` 里读出来），而那个函数与
    /// `applyPropLayout(.register)` 的回执去重判据**同源**。投影只负责"这个动作摆不摆
    /// 出来"，判据本身一个字都不在这里 —— 于是"按钮亮了却做不到"在结构上不可能。
    var canRedoInventoryRegistration: Bool = false
    /// 世界里的物件是不是**靠 `sourceWishID`** 这条第二线索认到 job 的（① 失配）。
    var matchedBySourceWishID: Bool = false

    // ── 会话内事实（重启/换世界会消失） ──
    var assetFailure: String?
    var inventoryPendingNotice: String?
    var inventoryPendingWaitsForSupportGeometry: Bool = false
    var trayShowsThis: Bool = false
    /// `claim()` 的判据现在成立吗（居民真的在取物点、托盘上显示它）。
    /// **判据本身就是 `WishMachineCoordinator.claim`**，这里只是把答案读出来。
    var canClaimNow: Bool = false
    /// `WishMachineCoordinator.retry` 的 guard 对这个 job 成立吗。
    var canRetryNow: Bool = false

    // ── 尺寸（世界文档那一份，唯一出口） ──
    var sizeText: String?
    var sizeProvenance: String?

    init(objectID: String) { self.objectID = objectID }
}

/// 只读投影。**不实现 `Codable`、没有 `init(rawValue:)`、不落盘**。
struct OwnershipRow: Equatable, Sendable, Identifiable {
    let key: OwnershipRowKey
    let name: String
    /// 对外状态（五种之一，或 `ended`）。
    let state: OwnershipDisplayState
    /// 世界里的位置事实（与 `state` 分开：`held` 属于「在房间里」但**不是**「已摆放」）。
    let room: OwnershipRoomPresence
    let group: OwnershipGroup
    /// 界面上那一句人话（= `OwnershipSentence` 之一）。
    let statusText: String
    /// 具名原因（字段 + 数值），只在失败/受阻时非 nil。列表本体只放一句人话，
    /// 这一份在**行内展开**里显示。
    let reasonText: String?
    let sizeText: String?
    let sizeProvenance: String?
    /// 有物件无 job：照常显示，并在展开里明写「找不到对应的许愿记录」。
    let isOrphan: Bool
    /// 叠加徽标（非互斥）。
    let badges: [String]
    let actions: [OwnershipRowAction]
    let evidence: [OwnershipEvidence]

    var id: String { key.identifier }

    /// 「已结束」是默认折叠的唯一一组。
    var isFoldedByDefault: Bool { state == .ended }
}

/// 分组之后的一段。`rows` 已经按预算截断（放不下时 `remainingCount` 说明还有几件）。
struct OwnershipSection: Equatable, Sendable {
    let group: OwnershipGroup
    let title: String
    let rows: [OwnershipRow]
    let totalCount: Int
    let isFolded: Bool
}

struct OwnershipList: Equatable, Sendable {
    let sections: [OwnershipSection]
    /// 「还有 N 件」。
    let remainingCount: Int

    var allRows: [OwnershipRow] { sections.flatMap(\.rows) }
    var rowCount: Int { sections.reduce(0) { $0 + $1.totalCount } }
}

enum ResidentOwnershipProjection {

    // MARK: - 面板的行预算

    /// 面板列表区能放下的行数（高度 190 pt，一行约 30 pt，还要留组头）。
    ///
    /// 放不下时**不是**把后面的行丢掉，而是显示前两组 + 末尾一句「还有 N 件」
    /// —— "看不见的列表"正是这次要修的病。
    static let visibleRowBudget = 6

    /// 面板列表区的行预算上限（190 pt）。**宽度 340 不动**（红线）。
    static let panelListHeightPoints = 190

    // MARK: - 唯一的推导

    /// **唯一**推导。纯函数：同输入同输出，不读时钟、不读磁盘、**不写任何东西**。
    static func row(_ facts: OwnershipRowFacts) -> OwnershipRow {
        let key = OwnershipRowKey(jobID: facts.jobID, objectID: facts.objectID)
        let room = roomPresence(facts)
        let isOrphan = facts.jobID == nil
        let name = facts.objectName ?? facts.tombstoneName ?? facts.jobName ?? facts.objectID

        var badges: [String] = []
        var actions: [OwnershipRowAction] = []
        var reasonText: String?
        var state: OwnershipDisplayState
        var statusText: String

        // 墓碑优先**只有当物件确实不在**时：删除把物件移出 `objectStates`，
        // 两者并存是存档分叉。那时以**物件**为准（"东西不许消失"是首要纪律），
        // 分叉由下面的 evidence 明写出来。
        if facts.tombstoneName != nil, !facts.objectPresent {
            state = .ended
            statusText = OwnershipSentence.deleted.rawValue
            let settlement = facts.tombstoneSettlement.map { "（\($0)）" } ?? ""
            var deleted = facts.tombstoneReason.map { "删除理由：\($0)" } ?? "删除是永久的，不能恢复\(settlement)"
            // 「已领取」+ 墓碑：许愿那一笔还开着，可东西是用户**有意删掉**的。
            //
            // 这里**不给**「重试入库」——给了就是承诺"删掉的还能回来"，而删除是永久的
            // （`docs/plans/2026-10-02-prop-deletion-semantics.md` §4）。判据与面板按钮
            // 是同一个（`facts.canRedoInventoryRegistration` 在墓碑这一支必为 false，
            // 见 `WorldState.canRedoInventoryRegistration`）。但**必须说出来**：
            // 沉默会让用户以为"还在补做、等一会儿就有了"。这就是那句人话。
            if facts.jobStage == .claimed {
                deleted += " 已领取的那一次不再补做入库：删除是永久的。"
            }
            reasonText = deleted
        } else if facts.objectPresent {
            // ── 有世界记录：归属由世界文档**唯一**决定 ──
            if let slot = facts.heldSlot {
                state = .placed
                statusText = OwnershipSentence.heldByResident.rawValue
                reasonText = "挂在\(heldSlotName(slot))上；先放回才能摆到房间里。"
                actions = [.withdraw, .delete]
            } else if facts.objectIsEnabled {
                state = .placed
                statusText = OwnershipSentence.placed.rawValue
                actions = [.withdraw, .delete]
            } else {
                state = .inInventory
                statusText = OwnershipSentence.inInventory.rawValue
                actions = [.place, .delete]
            }
            if let failure = facts.assetFailure {
                badges.append("资产未就绪")
                reasonText = "资产未就绪：\(failure)"
            }
        } else {
            // ── 只有 job（物件从来没进过世界，或已被删） ──
            switch facts.jobStage {
            case .claimed:
                // 这正是真机那 3 件「已领取但没写进库存」：`job.stage == .claimed`、
                // `layoutReceipts` 里没有 `claimed.<jobID>`、`objectStates` 里也没有它。
                state = .failed
                statusText = OwnershipSentence.inventoryNotSaved.rawValue
                reasonText = inventoryNotSavedReason(facts)
                // 下一步是**既有**的入库补做（不是重新生成）：所以这里给的是
                // `retryInventoryRegistration`，而不是阶段判据会拒绝 `.claimed` 的 `.retry`。
                //
                // 但**只有那条路今天真的走得通时**才摆出来 —— 判据是宿主读出来的
                // `canRedoInventoryRegistration`（= `WorldState.canRedoInventoryRegistration`,
                // 与 `applyPropLayout(.register)` 的回执去重同源）。做不到就不给按钮：
                // 一句做不到的承诺比没有按钮更坏（G4/Q4 同一条纪律）。
                actions = facts.canRedoInventoryRegistration ? [.retryInventoryRegistration] : []
            case .ready:
                // 「产物已就绪、还没领取」**永远是未领取**（用户 2026-10-02 原话：这一档
                // 就写「未领取」）：`claim()` 的判据只看 `stage == .ready` + 模型文件在，
                // **不看**渲染失败那条记录，**也不看**托盘这一刻有没有它 ——
                // 托盘只影响"还差哪一步"，不影响"领没领"。所以主文案只有一个答案，
                // 「还没上托盘」降级成**原因**（下面那一支）。
                //
                // `outputRenderFailure` 是一条**持久化的派生结论**（某次渲染推导失败）。
                // 让它把这一行改成"失败"，就等于"推导逻辑被修好"这件事永远不会被重新推导
                // ——真机那台电视 `stage == .ready`、资产完好、尺寸意图今天能推出合法尺寸，
                // 却因为一条旧结论永久消失（用户已经撞了两次）。所以失败**降级成徽标 + 原因**：
                // 东西照旧在「待你处理」里看得见，为什么上不了托盘也说得出来。
                state = .awaitingClaim
                statusText = OwnershipSentence.awaitingClaim.rawValue
                if let message = facts.renderFailureMessage {
                    badges.append(OwnershipSentence.renderFailed.rawValue)
                    reasonText = message
                } else if !facts.trayShowsThis {
                    reasonText = OwnershipSentence.notOnTrayReason.rawValue
                }
                // Q4：「领取」够不到许愿机时**按钮可见但置灰**，并给出
                // 「让居民去取」（既有 agent 路径）。判据一个字不改。
                //
                // 场景加载失败时**两个都不给**：那种情况下托盘永远显示不出它，
                // 「让居民去取」会变成一句做不到的承诺（原因是具名的，已在上面说出来）。
                actions = facts.renderFailureMessage != nil
                    ? []
                    : (facts.canClaimNow ? [.claim] : [.askResidentToFetch])
            case .failed:
                state = .failed
                statusText = OwnershipSentence.generationFailed.rawValue
                reasonText = facts.lastError
                actions = facts.canRetryNow ? [.retry] : []
            case .cancelled:
                state = .ended
                statusText = OwnershipSentence.cancelled.rawValue
            case .interrupted:
                state = .ended
                statusText = OwnershipSentence.interrupted.rawValue
            case .submitting:
                state = .generating
                statusText = OwnershipSentence.submitting.rawValue
            case .submissionUncertain:
                state = .generating
                statusText = OwnershipSentence.submissionUncertain.rawValue
                reasonText = facts.lastError
                actions = facts.canRetryNow ? [.retry] : []
            case .generating, .generated, .none:
                state = .generating
                statusText = OwnershipSentence.generating.rawValue
            }
            if facts.cancelRequested, [.submitting, .submissionUncertain, .generating, .generated].contains(facts.jobStage) {
                statusText = OwnershipSentence.cancelPending.rawValue
            }
        }

        if isOrphan { badges.append("无许愿记录") }
        // 墓碑与库存并存：过去这**只能是**存档分叉；现在它还有第二种来源 ——
        // "删掉之后又被重新登记回来"（入库那一笔的回执失效之后，重新入库是一次
        // **新的**变更，而墓碑是"删过"这件事的记录，不随它消失）。两种都在这条徽标里
        // 说清，因为用户看到的"删过、又在了"必须有解释，否则它就是一条看不懂的矛盾。
        if facts.tombstoneName != nil, facts.objectPresent {
            badges.append("墓碑与库存并存（分叉）：这一件删过，之后又被重新登记回来")
        }
        if facts.matchedBySourceWishID { badges.append("按 sourceWishID 认到所属许愿") }

        return OwnershipRow(
            key: key,
            name: name,
            state: state,
            room: room,
            group: group(for: state),
            statusText: statusText,
            reasonText: reasonText,
            sizeText: facts.sizeText,
            sizeProvenance: facts.sizeProvenance,
            isOrphan: isOrphan,
            badges: badges,
            actions: actions,
            evidence: evidence(facts, room: room, isOrphan: isOrphan))
    }

    /// 世界里的位置：**一处**判据（与 `world_records` / `state.json` 同一口径）。
    static func roomPresence(_ facts: OwnershipRowFacts) -> OwnershipRoomPresence {
        guard facts.objectPresent, facts.objectHasGeneratedProp else { return .absent }
        if facts.heldSlot != nil { return .held }
        return facts.objectIsEnabled ? .placed : .inventory
    }

    static func group(for state: OwnershipDisplayState) -> OwnershipGroup {
        switch state {
        case .awaitingClaim, .failed: return .needsYou
        case .inInventory: return .inInventory
        case .placed: return .inRoom
        case .generating: return .needsYou
        case .ended: return .ended
        }
    }

    /// 三轴 → 一句现状的**唯一**出口（`ResidentTaskAxisProjection.currentStatus`
    /// 委托到这里，于是不会变成第二套文案）。
    ///
    /// 入参用 `rawValue` 而不是那三个枚举类型：本文件因此不依赖呈现层，
    /// 可以被离线 harness 直接编译。
    static func sentence(generation: String, ownership: String, placement: String,
                         room: OwnershipRoomPresence = .absent) -> String {
        if room == .held { return OwnershipSentence.heldByResident.rawValue }
        if placement == "placed" { return OwnershipSentence.placed.rawValue }
        if ownership == "inInventory" { return OwnershipSentence.inInventory.rawValue }
        if ownership == "claimed" { return OwnershipSentence.inventoryNotSaved.rawValue }
        switch generation {
        case "completed": return OwnershipSentence.awaitingClaim.rawValue
        case "failed": return OwnershipSentence.generationFailed.rawValue
        default: return OwnershipSentence.generating.rawValue
        }
    }

    /// 「已领取，入库尚未保存」的**具名原因**：字段 + 实测值。
    ///
    /// 会话内台账在时用它的**原话**（那是摆放服务给的判定文本）；不在时也必须答得出来
    /// —— 这一个窗口（`claim()` 与入库写入之间）本来就是长的，而"说得出为什么没保存"
    /// 正是真机上缺的那句话。
    static func inventoryNotSavedReason(_ facts: OwnershipRowFacts) -> String {
        if let notice = facts.inventoryPendingNotice { return notice }
        if facts.claimReceiptPresent {
            return "世界回执 claimed.\(facts.jobID?.uuidString ?? "?") 在，但库存里没有这一条；这次入库没有被库存接受。"
        }
        return "世界没有接受这次入库：layoutReceipts 里没有 claimed.\(facts.jobID?.uuidString ?? "?")，objectStates 里也没有它。"
    }

    static func heldSlotName(_ slot: String) -> String {
        switch slot {
        case "rightHand": return "右手"
        case "back": return "背后"
        case "waist": return "腰间"
        default: return slot
        }
    }

    /// 展开里的 evidence：**字段名 + 值**。分叉可见，而不是互相覆盖。
    static func evidence(_ facts: OwnershipRowFacts, room: OwnershipRoomPresence,
                         isOrphan: Bool) -> [OwnershipEvidence] {
        var items: [OwnershipEvidence] = []
        if let jobID = facts.jobID {
            items.append(.init("wishes.json jobID", jobID.uuidString))
            items.append(.init("wishes.json stage", facts.jobStage?.rawValue ?? "没有这一条"))
            items.append(.init("wishes.json remoteState", facts.remoteState ?? "无"))
            items.append(.init("wishes.json lastError", facts.lastError ?? "无"))
        } else {
            items.append(.init("wishes.json", "找不到对应的许愿记录（孤儿行）"))
        }
        items.append(.init("objectID", facts.objectID))
        items.append(.init("state.json objectStates", facts.objectPresent ? "有这一条" : "没有这一条"))
        if facts.objectPresent {
            items.append(.init("state.json generatedProp", facts.objectHasGeneratedProp ? "有" : "没有"))
            items.append(.init("state.json isEnabled", facts.objectIsEnabled ? "true" : "false"))
            items.append(.init("state.json heldProp.objectID", facts.heldSlot ?? "没有挂在身上"))
        }
        items.append(.init("state.json propTombstones", facts.tombstoneName.map { "有（\($0)）" } ?? "没有"))
        if let jobID = facts.jobID {
            items.append(.init("layoutReceipts[claimed.\(jobID.uuidString)]",
                               facts.claimReceiptPresent ? "有" : "没有"))
        }
        items.append(.init("托盘是否显示这一件", facts.trayShowsThis ? "是" : "不是"))
        if let failure = facts.assetFailure {
            items.append(.init("residentPropAssetFailures[objectID]", failure))
        }
        if let notice = facts.inventoryPendingNotice {
            items.append(.init("residentPropInventoryBacklog[objectID]", notice))
        }
        if let size = facts.sizeText { items.append(.init("effectiveSize", size)) }
        if let provenance = facts.sizeProvenance { items.append(.init("sizeProvenance", provenance)) }
        if isOrphan { items.append(.init("归属", "有物件、无许愿记录；名称与状态从世界事实派生")) }
        return items
    }

    // MARK: - 排序与分组

    /// 组内确定性顺序：有 job 的按 `processOrder` 倒序（越新越前），
    /// 孤儿行按 `objectID` 字典序排在后面。**没有时间来源就不假装有**。
    static func ordered(_ rows: [OwnershipRow], order: [String: Int]) -> [OwnershipRow] {
        rows.sorted { lhs, rhs in
            let l = order[lhs.key.identifier], r = order[rhs.key.identifier]
            switch (l, r) {
            case let (l?, r?): return l == r ? lhs.key.objectID < rhs.key.objectID : l > r
            case (nil, _?): return false
            case (_?, nil): return true
            default: return lhs.key.objectID < rhs.key.objectID
            }
        }
    }

    /// 分组 + 预算截断。`rows` 必须已经排好序（见 `ordered`）。
    static func list(_ rows: [OwnershipRow], order: [String: Int] = [:],
                     showsEnded: Bool, rowBudget: Int = visibleRowBudget) -> OwnershipList {
        let sorted = ordered(rows, order: order)
        var sections: [OwnershipSection] = []
        var remaining = 0
        var budget = max(0, rowBudget)
        // ① ② ③ 先分，预算用完之后剩下的进「还有 N 件」；④ 已结束默认折叠。
        for group in [OwnershipGroup.needsYou, .inInventory, .inRoom] {
            let inGroup = sorted.filter { $0.group == group }
            guard !inGroup.isEmpty else { continue }
            let shown = Array(inGroup.prefix(budget))
            guard !shown.isEmpty else {
                // 预算已经用完：不渲染一个没有行的组头，全部计进「还有 N 件」。
                remaining += inGroup.count
                continue
            }
            budget -= shown.count
            remaining += inGroup.count - shown.count
            sections.append(.init(group: group, title: group.title, rows: shown,
                                  totalCount: inGroup.count, isFolded: false))
        }
        let ended = sorted.filter { $0.group == .ended }
        if !ended.isEmpty {
            if showsEnded, budget > 0 {
                let shown = Array(ended.prefix(budget))
                budget -= shown.count
                remaining += ended.count - shown.count
                sections.append(.init(group: .ended, title: OwnershipGroup.ended.title, rows: shown,
                                      totalCount: ended.count, isFolded: false))
            } else {
                // 折叠行本身不占"件数"：它只说「已结束 (N)」。
                sections.append(.init(group: .ended, title: OwnershipGroup.ended.title, rows: [],
                                      totalCount: ended.count, isFolded: true))
            }
        }
        return OwnershipList(sections: sections, remainingCount: remaining)
    }

    /// 组头文案：折叠的「已结束」带计数；空组整组不显示。
    static func sectionTitle(_ section: OwnershipSection) -> String {
        section.totalCount > 0 ? "\(section.title) (\(section.totalCount))" : section.title
    }
}

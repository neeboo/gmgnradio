import Foundation

// ---------------------------------------------------------------------------
// 删除一件生成资产：**墓碑 + 事实**，不是硬删行。
//
// 设计（一页）见 docs/plans/2026-10-02-prop-deletion-semantics.md。这里只重复三条
// 会在代码里被反复读到的纪律：
//
// 1. **行留下来**。删除把物件移出 `objectStates`（这正是权威 `world_records` 派生
//    `tombstone=1` 与 `object.removed` 事实的输入），但它的身份冻结进
//    `WorldState.propTombstones[objectID]`：于是"有意删掉"与"意外丢了"在任何时候
//    都分得开，读回、面板与对账器都能回答"它去哪儿了"。
// 2. **引用计数是派生的**。`world_blobs` 刻意没有 refcount 列（见
//    `services/gmgn-taskd/src/world.rs` 的模块说明）：一份内容今天还被谁引用，
//    只能从**活着的物件**身上数出来。所以这里没有第二份清单，只有每次现算的函数。
// 3. **销毁不可逆**。墓碑是为了可审计，不是为了可回滚；文案必须说"永久删除"。
// ---------------------------------------------------------------------------

/// 一件被删除的物件留下的墓碑。
///
/// 与 Rust `world_records` 的墓碑**同构**：记录不删，只标记；这里额外把"这次删除
/// 释放了哪些内容引用"和"删的那一刻它在哪儿"一并留下 —— 否则删除之后就再也回答不了
/// "哪些共享文件还该留着"（那正是引用计数唯一的输入）。
public struct WorldPropTombstone: Codable, Equatable, Sendable {
    public let objectID: String
    public let displayName: String
    /// 这次删除释放掉的 blob 引用（小写 sha256，字典序、去重）。
    ///
    /// 它是**被删物件自己**引用过的那几份内容（模型字节 + 碰撞代理），不是"可以删的
    /// 文件清单"：能不能删由 `WorldPropAssetReferences.reclamation` 现算的引用计数回答。
    public let releasedBlobRefs: [String]
    /// 删除时这件东西正在哪儿（见 `WorldPropDeletionSettlement`）。
    public let settlement: WorldPropDeletionSettlement
    /// 谁为什么删的（agent 或用户给的理由，可省）。
    public let reason: String?
    /// **世界时间**（与 `WorldState.worldTime` 同一份），不是 wall clock：存档回放要确定。
    public let deletedAt: Date
    /// 被删掉的那一份物件身份（冻结值）。墓碑之所以是"软删"，就是因为它还答得出
    /// "删的到底是哪一件、引用过什么"。
    public let previous: WorldGeneratedProp

    public init(objectID: String, displayName: String, releasedBlobRefs: [String],
                settlement: WorldPropDeletionSettlement, reason: String?,
                deletedAt: Date, previous: WorldGeneratedProp) {
        self.objectID = objectID
        self.displayName = displayName
        self.releasedBlobRefs = releasedBlobRefs.sorted()
        self.settlement = settlement
        self.reason = reason
        self.deletedAt = deletedAt
        self.previous = previous
    }

    /// 合法性：与 `WorldGeneratedProp.isValid` 同口径，外加"墓碑必须与它冻的那一件同号"。
    ///
    /// 坏掉的墓碑**不能**被当成"没有墓碑"（那会让一次删除在存档里消失 —— 也就是硬删行
    /// 从后门回来），所以调用方一律 fail-closed 拒绝。
    public var isValid: Bool {
        !objectID.isEmpty && objectID.count <= 256
            && !displayName.isEmpty && displayName.count <= 256
            && previous.isValid && previous.objectID == objectID
            && releasedBlobRefs.allSatisfy { WorldPropAssetReferences.isCanonicalDigest($0) }
            && (reason?.count ?? 0) <= 200
            && settlement.isValid
    }
}

/// 删除那一刻，这件东西在哪儿 —— 也就是"要不要收场、怎么收场"。
///
/// 三种都是**同一次提交里的原子收场**（见设计 §3）：不存在"先收回、再删一次"这种
/// 两步路，也不存在"静默把正在手里的东西抹掉"。
public enum WorldPropDeletionSettlement: Codable, Equatable, Sendable {
    /// 未摆放、也没在手上：没有需要收场的东西。
    case inventory
    /// 原来摆在房间里：摆放随这次删除一并结束。
    case withdrawn(surfaceID: String, position: WorldVector3)
    /// 原来拿在手里 / 挂在身上：先按 `heldProp.returnState` 放回，同一提交里删掉。
    case returnedFromSlot(slot: WorldPropSlot, position: WorldVector3)

    public var isValid: Bool {
        switch self {
        case .inventory:
            return true
        case let .withdrawn(_, position), let .returnedFromSlot(_, position):
            return [position.x, position.y, position.z].allSatisfy(\.isFinite)
        }
    }

    /// 回执里那一句话（agent 与面板读的是同一份字面量）。
    public var summary: String {
        switch self {
        case .inventory: return "原本就在库存里，没有需要收场的摆放或手持"
        case .withdrawn: return "原本摆放在房间里，摆放随删除一并结束"
        case let .returnedFromSlot(slot, _):
            return "原本挂着（\(slot.rawValue)），已先放回原位再删除"
        }
    }

    /// 机器读的结算名（回执的 `settled` 字段）。
    public var name: String {
        switch self {
        case .inventory: return "inventory_only"
        case .withdrawn: return "withdrawn_then_deleted"
        case .returnedFromSlot: return "returned_then_deleted"
        }
    }
}

/// 一次删除的**回收判定**：引用计数这一层的全部答案（带数字）。
public struct WorldPropReclamation: Equatable, Sendable {
    /// 这次删除释放掉的引用（= 被删物件自己引用的内容），字典序。
    public let released: [String]
    /// 释放之后**仍然**被别的活物件引用的：内容哈希 → 还在引用它的物件编号（字典序）。
    /// 计数 > 0 ⇒ **文件必须留着**。
    public let retained: [String: [String]]
    /// 释放之后引用计数**归零**的：内容哈希（字典序）。这才是"可以回收"的集合。
    public let unreferenced: [String]

    public init(released: [String], retained: [String: [String]], unreferenced: [String]) {
        self.released = released.sorted()
        self.retained = retained
        self.unreferenced = unreferenced.sorted()
    }

    /// 仍然被引用着的每一份内容各被几件物件引用（回执里要能给出**数字**）。
    public var retainedCounts: [String: Int] { retained.mapValues(\.count) }
}

/// 内容寻址引用与**派生引用计数**的唯一一份换算。
///
/// 它回答两个问题，而且只回答这两个：
/// - 一件物件引用了哪些内容（`blobRefs(of:)`）；
/// - 一份内容今天还被谁引用（`referenceCounts(in:)`）。
///
/// 没有第三份"引用表"：`WorldState` 里不存计数，权威 `world_blobs` 里也不存
/// （那正是既定的纪律）。计数每次现算，所以它不可能与"活着的物件"分叉。
public enum WorldPropAssetReferences {
    /// 64 位小写十六进制 = 规范的内容寻址键。别的一律**不认**（绝不猜一个哈希出来）。
    public static func isCanonicalDigest(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// `sha256:<hex>` / `<hex>` → `<hex>`；别的形状返回 nil（不静默当合法）。
    public static func canonicalDigest(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let text = raw.contains(":") ? String(raw.split(separator: ":").last ?? "") : raw
        let lowered = text.lowercased()
        return isCanonicalDigest(lowered) ? lowered : nil
    }

    /// 一件物件引用的**全部**内容寻址 blob：模型字节（`assetID`）+ 碰撞代理
    /// （`collision.sha256`）。解不出来的那一项**不出现**在这份清单里 ——
    /// 它也就不会被"释放"，更不会被回收（宁可留着，不可误删）。
    public static func blobRefs(of prop: WorldGeneratedProp) -> [String] {
        var refs: Set<String> = []
        if let model = canonicalDigest(prop.assetID) { refs.insert(model) }
        if let collision = canonicalDigest(prop.collision?.sha256) { refs.insert(collision) }
        return refs.sorted()
    }

    /// 从一份世界状态**派生**引用计数：内容哈希 → 还引用它的**活物件**编号（字典序）。
    ///
    /// "活着" = 在 `objectStates` 里、且解得出有效的 `generatedProp`。
    /// **墓碑不算引用**（被删掉的东西不再让一份字节保持存活）；手持中的物件仍然算 ——
    /// 它在 `objectStates` 里，它的资产还在被用。
    public static func referenceCounts(in state: WorldState) -> [String: [String]] {
        var counts: [String: [String]] = [:]
        for (objectID, item) in state.objectStates {
            guard let prop = item.generatedProp else { continue }
            for ref in blobRefs(of: prop) { counts[ref, default: []].append(objectID) }
        }
        for key in counts.keys { counts[key]?.sort() }
        return counts
    }

    /// 把 `objectID` 从 `state` 里删掉**之后**的回收判定（候选状态口径）。
    ///
    /// 注意入参是**删除后**的状态：计数问的是"这件东西走了之后，还有谁在引用"。
    /// 被判定的那件物件自己已经不在里面，所以它释放的引用天然不会被自己计数 ——
    /// 这正是"删一件不能看它自己"这条判据成立的原因。
    public static func reclamation(deleting objectID: String,
                                   from state: WorldState) -> WorldPropReclamation {
        let released: [String] = state.propTombstones?[objectID]?.releasedBlobRefs
            ?? state.objectStates[objectID]?.generatedProp.map(blobRefs(of:)) ?? []
        let counts = referenceCounts(in: state)
        var retained: [String: [String]] = [:]
        var unreferenced: [String] = []
        for ref in released {
            let holders = counts[ref] ?? []
            if holders.isEmpty { unreferenced.append(ref) } else { retained[ref] = holders }
        }
        return WorldPropReclamation(released: released, retained: retained, unreferenced: unreferenced)
    }
}

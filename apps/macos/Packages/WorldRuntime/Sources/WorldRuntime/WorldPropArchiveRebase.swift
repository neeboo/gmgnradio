import Foundation

/// 「历史登记的物件存档与今天从**原始 GLB + 领取记录**推出来的那一份对不上」这件事的
/// **唯一**一份判据与修复规则：什么时候可以安全地把存档里的**派生字段**对齐到今天，
/// 什么时候必须**可见地拒绝**。
///
/// ## 为什么需要它（真机 2026-10-01 的「2B 白色长剑（外形摆件）」）
///
/// 那把剑是在**朝向归一**（`WorldPropOrientationPolicy`）落地**之前**登记进权威的：
/// 存档里那一份 `size` 是"躺着生成的网格按最长边归一"的产物
/// （1.100 × 0.146 × 0.062 m，`sourceHeight` = 原始 Y 跨度 0.133 m，没有 `orientation` 键），
/// 而今天同一份网格（`assetID` = sha256，字节没变）从原始 GLB + 领取记录推出来的是
/// **立着**的（0.146 × 1.100 × 0.062 m，`sourceHeight` = 摆正后的 Y 跨度 1.005 m）。
/// `WorldGeneratedProp.matchesIdentity(of:)` 要求两份 `size` 相等（除非有
/// `sizeLocked` / `sizeIntent` 这两条"用户自己定过"的豁免），于是
/// `synchronizeOwnedResidentProps` 在 `GMGNRadioApp.swift` 的
/// `guard let storedProp, storedProp.matchesIdentity(of: prop)` 那一行抛
/// `.ownershipMismatch` —— 这件资产**永远进不了** `residentOwnedPropAssets`，
/// 用户手里那把剑因此**永久摆不了**（面板上它却写着"已摆出 ✓"）。
///
/// ## 为什么不能只是"放宽判据"
///
/// 存档里的 `size` 与今天的 `orientation` **不能同时保留**：渲染端只有一份等比缩放
/// （`effectiveSize.y / sourceHeight`）。留着躺着的 `size`（0.146 m 高）再按今天的摆正
/// 旋转去画，画面里那把剑会缩成 0.146 m 高的小匕首 —— 那正是"静默改写用户数据"的另一种写法。
/// 所以这里做的不是放宽判据，而是**把存档里的派生字段显式地对齐到今天**，并且
/// 每一步都留下可见记录（详见 `Record`）。
///
/// ## 规则（三条，都不许猜）
///
/// 1. **身份必须逐位相同**：`objectID` / `sourceWishID` / `assetID` / `displayName`。
///    不同 ⇒ `refuse`（那是**另一件物件或另一份资产**，`assetID` 就是模型字节的 sha256，
///    它说不同就是不同）。
/// 2. **必须是同一份网格的等比缩放**：存档里那份 `size` 相对**原始网格** AABB 或
///    **摆正后**的 AABB 必须存在一个统一的缩放因子（`WorldPropSizePolicy.uniformFactor`）。
///    这条判据的作用是排除"用户手改过的数字"与"另一个形状"：任何"同一份网格换一根轴 /
///    换一种归一"都保留等比关系（所以旧规则算出来的那一份一定过），而手工拖出来的、
///    与这份网格无关的数字过不了。真正的用户改动另有一条硬闸：它带 `sizeLocked == true`
///    （`withSize` 写的），那种档案**根本走不到这里**（`matchesIdentity` 已经为真）。
/// 3. **用户自己的字段一个都不动**：`sizeLocked` / `sizeIntent` / `collision` /
///    `authoritativeSize` 原样保留（`healed(stored:derived:)`）；只有
///    `size` / `sourceHeight` / `orientation` 这三个**派生**字段被今天的那一份替换。
///
/// 幂等：修完之后存档与推导逐位一致 ⇒ 下一次走到这里是 `.unchanged`，不再写第二遍。
/// 可回滚：原值仍然留在**注册那一条**回执里（`claimed.<jobID>`），加上动手前的
/// 权威备份，任何一次修复都能逐字回退。
public enum WorldPropArchiveRebaseVerdict: Equatable, Sendable {
    /// 存档与今天的推导一致（或本来就带用户自己的尺寸）：**什么都不做**。
    case unchanged
    /// 同一件物件、同一份网格，存档里的派生字段是旧规则算的 ⇒ 对齐到今天这一份。
    case rebase(WorldGeneratedProp, WorldPropArchiveRebase.Record)
    /// 不能安全对齐（不是同一件物件 / 不是同一份网格的等比缩放 / 尺寸本身不合法）。
    /// 附带**读得懂的原因**：调用方必须把它说出来，不许静默丢弃、也不许硬改。
    case refuse(String)
}

public enum WorldPropArchiveRebase {
    /// 参与"对齐"的派生字段（身份字段与用户字段**不在其中**，见文件头）。
    public static let derivedFieldNames = ["size", "sourceHeight", "orientation"]

    /// 一处字段变化（`from` / `to` 都是给人看的短字符串）。
    public struct Change: Equatable, Sendable {
        public let field: String
        public let from: String
        public let to: String

        public init(field: String, from: String, to: String) {
            self.field = field; self.from = from; self.to = to
        }
    }

    /// 一次修复的**可见记录**：谁被修了、改了哪几个字段、凭什么、幂等键是什么。
    ///
    /// 它是"绝不静默"这条纪律的载体：`summary` 走既有的面板/语音状态通道
    /// （与摆正、夹取说明同一条），`requestID` 进权威的世界状态回执
    /// （与 `claimed.<jobID>` 同一个 `layoutReceipts` 表），于是"谁在什么时候把哪几个
    /// 数字从多少改成了多少"在**权威里**查得到，不是只飘在日志里。
    public struct Record: Equatable, Sendable {
        public let objectID: String
        public let displayName: String
        /// 权威回执的幂等键：内容寻址（同一份修复重放用的是同一个键）。
        public let requestID: String
        public let changes: [Change]
        /// 为什么这次修复是**可解释**的（规则名 + 两边的数字）。
        public let explanation: String

        /// 一句话给用户看（面板/状态行）。**必须说清楚"谁被改了、改了什么、凭什么"**，
        /// 否则这次自动修复就是一次静默改写。
        public var summary: String {
            let detail = changes.map { "\($0.field) \($0.from) → \($0.to)" }.joined(separator: "、")
            return "\(displayName)：存档里的派生字段是旧规则算的，已按今天的规则对齐（\(detail)）。"
                + explanation
                + "你手动定过的字段一个都没动；原值仍留在权威的注册回执里（claimed.<jobID>），可逐字回滚。"
        }
    }

    // MARK: - 判据

    /// 存档 + 今天的推导（+ 两份网格 AABB）→ 结论。
    ///
    /// - `stored`：权威里那一份（`objectStates[objectID].generatedProp`）；
    /// - `derived`：**今天**从原始 GLB + 领取记录推出来的那一份（`synchronizeOwnedResidentProps`
    ///   里那个 `prop`，尺寸由 `WorldPropSizePolicy` 在**摆正之后**的 AABB 上算出）；
    /// - `meshExtent` / `orientedExtent`：渲染器量出来的原始 AABB 与摆正后的 AABB
    ///   （判据 2 的输入）；
    /// - `requestIDPrefix`：幂等键的前缀（生产传 `"rebase.<jobID>"`）。
    public static func decide(
        stored: WorldGeneratedProp,
        derived: WorldGeneratedProp,
        meshExtent: WorldVector3,
        orientedExtent: WorldVector3,
        requestedHeight: Float,
        requestIDPrefix: String
    ) -> WorldPropArchiveRebaseVerdict {
        // ① 身份：不同就是**另一件东西**，不许把这次的推导按到它头上。
        guard stored.objectID == derived.objectID, stored.sourceWishID == derived.sourceWishID,
              stored.assetID == derived.assetID, stored.displayName == derived.displayName else {
            return .refuse(
                "存档里那条 \(stored.displayName)（\(stored.objectID)，资产 \(stored.assetID)）"
                + "与这次领取记录（\(derived.objectID)，资产 \(derived.assetID)）不是同一件物件。"
            )
        }
        // ② 已经一致（或带用户自己的尺寸/意图）⇒ 什么都不做。幂等重放落在这一支。
        if stored.matchesIdentity(of: derived) { return .unchanged }
        guard stored.isValid else {
            return .refuse("存档里那一份尺寸不合法（\(describe(stored.size))），不能拿它当基准。")
        }
        guard derived.isValid else {
            return .refuse("今天推导出来的那一份尺寸不合法（\(describe(derived.size))），先不动物件。")
        }
        // ③ 同一份网格的等比缩放：换轴/换归一都保留这个关系，手工改的数字不保留。
        let rawFactor = WorldPropSizePolicy.uniformFactor(from: meshExtent, to: stored.size)
        let orientedFactor = WorldPropSizePolicy.uniformFactor(from: orientedExtent, to: stored.size)
        guard rawFactor != nil || orientedFactor != nil else {
            return .refuse(
                "存档里的尺寸 \(describe(stored.size)) 与这份网格（原始 \(describe(meshExtent))、"
                + "摆正后 \(describe(orientedExtent))）不是等比缩放关系 ⇒ 不能确定它是同一份网格的"
                + "另一种量法，已保留原记录。"
            )
        }
        let healedProp = healed(stored: stored, derived: derived)
        guard healedProp.isValid else {
            return .refuse("对齐之后的那一份尺寸不合法（\(describe(healedProp.size))），已保留原记录。")
        }
        let changes = changes(from: stored, to: healedProp)
        guard !changes.isEmpty else { return .unchanged }
        let rule = reproducedRule(stored.size, meshExtent: meshExtent, orientedExtent: orientedExtent,
                                  requestedHeight: requestedHeight)
        let explanation = explain(rule: rule, rawFactor: rawFactor, orientedFactor: orientedFactor,
                                  meshExtent: meshExtent, orientedExtent: orientedExtent,
                                  requestedHeight: requestedHeight)
        let record = Record(objectID: stored.objectID, displayName: stored.displayName,
                            requestID: requestIDPrefix + "." + fingerprint(of: healedProp),
                            changes: changes, explanation: explanation)
        return .rebase(healedProp, record)
    }

    /// 修复后的那一份：身份与**用户字段**原样保留，三个派生字段换成今天的那一份。
    ///
    /// `orientation` 取 `derived.orientation`（**不是** `stored.orientation ?? derived...`）：
    /// `size` / `sourceHeight` / `orientation` 是**同一次推导**的三个产物
    /// （`orientedExtent` 由 `orientation` 作用在原始 AABB 上得到），拆开取会让它们互相错位
    /// —— 那正是"画面按转正的网格画、碰撞盒按躺着的尺寸算"的另一种写法。
    public static func healed(stored: WorldGeneratedProp, derived: WorldGeneratedProp) -> WorldGeneratedProp {
        WorldGeneratedProp(
            objectID: stored.objectID, sourceWishID: stored.sourceWishID,
            assetID: stored.assetID, displayName: stored.displayName,
            size: derived.size, sourceHeight: derived.sourceHeight,
            sizeLocked: stored.sizeLocked, collision: stored.collision,
            authoritativeSize: stored.authoritativeSize, sizeIntent: stored.sizeIntent,
            orientation: derived.orientation
        )
    }

    /// 「这次提交只换派生字段」——`WorldPropLayoutCommand.rebase` 在**世界状态那一层**的守卫。
    ///
    /// 身份、用户字段必须逐位不变；三个派生字段里至少要有一处真的变了（否则那是一次空提交，
    /// 调用方应该走 `.unchanged` 而不是多写一条回执）。
    public static func isDerivedOnlyRewrite(from existing: WorldGeneratedProp,
                                           to submitted: WorldGeneratedProp) -> Bool {
        existing.objectID == submitted.objectID
            && existing.sourceWishID == submitted.sourceWishID
            && existing.assetID == submitted.assetID
            && existing.displayName == submitted.displayName
            && existing.sizeLocked == submitted.sizeLocked
            && existing.sizeIntent == submitted.sizeIntent
            && existing.collision == submitted.collision
            && existing.authoritativeSize == submitted.authoritativeSize
            && (existing.size != submitted.size
                || existing.sourceHeight != submitted.sourceHeight
                || existing.orientation != submitted.orientation)
    }

    // MARK: - 记录

    /// 今天的哪一条归一规则**正好**复现了存档里那个尺寸（有的话，写进说明当证据）。
    static func reproducedRule(_ size: WorldVector3, meshExtent: WorldVector3,
                               orientedExtent: WorldVector3, requestedHeight: Float) -> String? {
        let h = WorldPropSizePolicy.meters(requestedHeight)
        let candidates: [(String, WorldVector3?)] = [
            ("原始网格按最长边归一（请求高度 \(h) 米）",
             WorldPropSizePolicy.automatic(sourceExtent: meshExtent, requestedHeight: requestedHeight)?.size),
            ("原始网格按高度归一（请求高度 \(h) 米，尺寸策略落地前的行为）",
             WorldPropSizePolicy.intended(sourceExtent: meshExtent, axis: .height, meters: requestedHeight)?.size),
            ("摆正后的网格按高度归一（请求高度 \(h) 米）",
             WorldPropSizePolicy.automatic(sourceExtent: orientedExtent, requestedHeight: requestedHeight)?.size),
            ("摆正后的网格按最长边归一（请求高度 \(h) 米）",
             WorldPropSizePolicy.intended(sourceExtent: orientedExtent, axis: .longest, meters: requestedHeight)?.size),
        ]
        return candidates.first { entry in
            guard let value = entry.1 else { return false }
            return WorldPropSizePolicy.uniformFactor(from: value, to: size) != nil
        }?.0
    }

    private static func explain(rule: String?, rawFactor: Float?, orientedFactor: Float?,
                                meshExtent: WorldVector3, orientedExtent: WorldVector3,
                                requestedHeight: Float) -> String {
        let meters = WorldPropSizePolicy.meters
        let where_ = rule.map { "存档里那份尺寸与「\($0)」逐位相同；" }
            ?? "存档里那份尺寸是这份网格的等比缩放（缩放 "
                + meters(rawFactor ?? orientedFactor ?? 1) + " 倍，换轴/换归一都会得到这个形状）；"
        return where_
            + "同一份网格（assetID = 模型字节的 sha256，字节没变）今天从原始 GLB + 领取记录"
            + "（请求高度 \(meters(requestedHeight)) 米）推出的是摆正后的 "
            + "\(describe(meshExtent)) → \(describe(orientedExtent))。"
    }

    private static func changes(from stored: WorldGeneratedProp,
                                to healed: WorldGeneratedProp) -> [Change] {
        var changes: [Change] = []
        if stored.size != healed.size {
            changes.append(Change(field: "尺寸", from: describe(stored.size), to: describe(healed.size)))
        }
        if stored.sourceHeight != healed.sourceHeight {
            changes.append(Change(field: "高度基准", from: WorldPropSizePolicy.meters(stored.sourceHeight),
                                  to: WorldPropSizePolicy.meters(healed.sourceHeight)))
        }
        if stored.orientation != healed.orientation {
            changes.append(Change(field: "朝向",
                                  from: stored.orientation?.source.label ?? "保留原样（存档里没有这一项）",
                                  to: healed.orientation?.source.label ?? "保留原样"))
        }
        return changes
    }

    /// 内容寻址的幂等后缀：同一份"修好之后的样子"永远得到同一个键。
    ///
    /// FNV-1a（64 位）够用：它只回答"这两次修复是不是同一份"，**不承担安全职责**。
    /// 万一撞了，回执守卫会以 `requestConflict` **可见地**拒绝第二次写入，
    /// 而不是把一次不同的修复当成重放悄悄跳过（失败方向是 fail-closed）。
    static func fingerprint(of prop: WorldGeneratedProp) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in canonical(prop).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    private static func canonical(_ prop: WorldGeneratedProp) -> String {
        let orientation = prop.orientation.map {
            "\($0.source.rawValue):\($0.rotation.x),\($0.rotation.y),\($0.rotation.z),\($0.rotation.w)"
        } ?? "none"
        return [
            prop.objectID, prop.assetID,
            String(format: "%.6f", prop.size.x), String(format: "%.6f", prop.size.y),
            String(format: "%.6f", prop.size.z), String(format: "%.6f", prop.sourceHeight),
            String(prop.isSizeLocked), orientation,
        ].joined(separator: "|")
    }

    private static func describe(_ size: WorldVector3) -> String {
        "\(WorldPropSizePolicy.meters(size.x)) × \(WorldPropSizePolicy.meters(size.y)) × "
            + "\(WorldPropSizePolicy.meters(size.z)) 米"
    }
}

import Foundation

/// Created only by the trusted claim bridge; assetID is an opaque registry key, never a path.
public struct WorldGeneratedProp: Codable, Equatable, Sendable {
    public let objectID: String
    public let sourceWishID: String
    public let assetID: String
    public let displayName: String
    public let size: WorldVector3
    public let sourceHeight: Float
    /// 这份 `size` 是不是**用户手动定过**的（`nil`/`false` = 生成时自动定的基线）。
    ///
    /// 它不是第二份尺寸 —— 尺寸永远只有 `size` 这一份（渲染、碰撞盒、红/绿格、存档全读它）。
    /// 它只回答一个**出处**问题：自动基线重新算过之后，还要不要覆盖世界状态里那一份。
    /// 手动改过 ⇒ 不再要求与自动基线逐位相等，否则下一次资产准备会判成"资产归属不一致"，
    /// 那件物件会**从房间里消失**（正是这次要修的观感缺陷）。
    public let sizeLocked: Bool?
    /// 生成工作流自带的**碰撞代理**描述。可选、纯增量：为 nil 时合成 `Codable` 不会编码这个键
    /// （`encodeIfPresent`），于是没有代理的物件其元数据 JSON 与改造前逐字节一致。
    public let collision: WorldPropCollisionProxy?
    /// 生成工作流给的**权威尺寸**。存在时 `effectiveSize` 用它，app 不再从网格量。
    public let authoritativeSize: WorldPropAuthoritativeSize?
    /// 提交时声明的**尺寸意图**（守护进程 `size_intent`）：这份 `size` 是按它定出来的。
    ///
    /// 可选、纯增量：为 nil 时合成 `Codable` 不编码这个键（`encodeIfPresent`），
    /// 没有意图的产物其元数据与改造前逐字节相同。
    ///
    /// 它**不是**第二份尺寸 —— 尺寸仍只有 `size` 一份。它回答的是"这份尺寸是谁定的"，
    /// 并决定优先级里它排第几：用户手动覆盖 > 尺寸意图 > 工作流权威尺寸 > 自动推断。
    /// （正解是**提交前就说清楚**：真机那把剑的 8.28 m 就是"只按高度归一 + 事后猜"长出来的。）
    public let sizeIntent: WorldPropSizeIntent?
    /// 把**原始网格**转正的旋转（`WorldPropOrientation`）：来自工作流声明的 `up_axis` /
    /// `forward_axis`，或由网格主轴推断，或明确"无法确定、保留原样"。
    ///
    /// 它**不是第二份朝向**：房间里"朝哪边"仍然只有 `WorldObjectState.transform.rotation`
    /// 那一份 yaw。这一份说的是"这件**资产**的网格本身是躺着的"，与放置位置无关；
    /// 两者相乘的次数只有一次（`ResidentPropPlacementMatrix` 与 `WorldPropCollisionProxyMesh.placed`），
    /// 所以渲染、碰撞代理、判据不可能各转各的。
    ///
    /// 可选、纯增量：为 nil 时合成 `Codable` 不编码这个键（`encodeIfPresent`），
    /// 于是**已经立着的**资产（绝大多数）元数据 JSON 与改造前逐字节相同。
    public let orientation: WorldPropOrientation?
    /// **基础几何**拼出来的那件东西的记录（三轴毫米数 + 场景米数 + 那句解释）。
    ///
    /// 它回答的是"用户说的完整长宽高到底照做了没有"：这份 `size` 是**拼出来的几何**，
    /// 逐位等于用户给的三轴（真机那台 `1443 × 862 × 302 mm` 的电视），而不是生成器交回来的
    /// 网格按最长边等比缩放的结果。面板/回执逐位回读的就是 `summary` 那一句。
    ///
    /// 它不是第二份尺寸（尺寸仍只有 `size` 一份），也不是"尺寸意图"（那是提交时说的，
    /// 存在 `sizeIntent` 里）：它说的是"这件的几何是按三轴**拼**出来的，拼的时候这几块料
    /// 是怎么分的"。用户事后手动改过尺寸 ⇒ `withSize` 会把它清掉（见那里）。
    ///
    /// 可选、纯增量：为 nil 时合成 `Codable` 不编码这个键（`encodeIfPresent`），
    /// 于是不是基础几何拼出来的物件（绝大多数）其元数据与改造前逐字节相同。
    public let primitive: WorldPrimitiveTelevisionRecord?
    public init(objectID: String, sourceWishID: String, assetID: String, displayName: String,
                size: WorldVector3, sourceHeight: Float, sizeLocked: Bool? = nil,
                collision: WorldPropCollisionProxy? = nil,
                authoritativeSize: WorldPropAuthoritativeSize? = nil,
                sizeIntent: WorldPropSizeIntent? = nil,
                orientation: WorldPropOrientation? = nil,
                primitive: WorldPrimitiveTelevisionRecord? = nil) {
        self.objectID = objectID; self.sourceWishID = sourceWishID; self.assetID = assetID
        self.displayName = displayName; self.size = size; self.sourceHeight = sourceHeight
        self.sizeLocked = sizeLocked
        self.collision = collision; self.authoritativeSize = authoritativeSize
        self.sizeIntent = sizeIntent
        self.orientation = orientation
        self.primitive = primitive
    }
    /// 摆正旋转的**唯一**出口（没有 orientation 就是单位四元数）。
    ///
    /// 渲染矩阵、碰撞代理、审计面板都读这里，谁都不许自己再算一遍。
    public var orientationRotation: WorldQuaternion { orientation?.rotation ?? .identity }
    /// 网格是躺着的、已经摆正过（要写进存档的那一种）。
    public var isOrientationNormalized: Bool { orientation.map { !$0.isIdentity } ?? false }
    public var isSizeLocked: Bool { sizeLocked == true }
    /// 渲染后最长边（米）。**读 `effectiveSize`**：与判据、碰撞盒、渲染目标高度同一个出口。
    public var longestEdge: Float { WorldPropSizePolicy.longestEdge(of: effectiveSize) }
    /// 尺寸的**唯一**出口：用户手动覆盖 > 尺寸意图 > 权威尺寸 > app 自己量的那一份。
    ///
    /// 所有"这件东西多大"的下游（碰撞体积/footprint/互斥/承托/渲染目标高度）都必须读这里
    /// 而不是直接读 `size`，否则这条优先级只会在一半判据里生效。
    ///
    /// 为什么手动与意图都读 `size`：这两条路都在**入世界之前**就把目标尺寸算成了唯一的
    /// 那一份 `size`（意图在提交入库那一处、手动在 `withSize`），权威尺寸是**别人**给的
    /// 候选值，只有在前两者都没说话时才轮到它。没有意图、没有权威尺寸时 `effectiveSize`
    /// 与 `size` **逐位相同** ⇒ 旧资产行为不变。
    public var effectiveSize: WorldVector3 {
        if isSizeLocked || sizeIntent != nil { return size }
        return authoritativeSize?.dimensions ?? size
    }
    /// 这份尺寸是谁给的（审计）：`app-measured` / `workflow-authoritative` / `submit-intent`。
    ///
    /// 注意它说的是"这个数字**来自哪份数据**"，不是"最后是谁说了算"——后者见
    /// `sizeProvenance`。手动改过的尺寸仍然来自 app 量出来的那一份，所以这里不变。
    public var sizeSource: WorldPropSizeSource {
        switch sizeProvenance {
        case .submitIntent: return .submitIntent
        case .workflowAuthoritative: return .workflowAuthoritative
        case .manual, .appMeasured: return .appMeasured
        }
    }
    /// 「这件东西的尺寸是**怎么定**的」：手动 > 意图 > 权威 > 自动推断。面板/任务行读它。
    public var sizeProvenance: WorldPropSizeProvenance {
        // **基础几何**拼出来的那件东西：这份 `size` 不是 app 从网格量出来的、也不是用户事后
        // 拖出来的，它**就是**用户给的三轴本身（`primitive.millimeters`）⇒ 出处是"按你说的
        // 尺寸"。用户事后拖过尺寸 ⇒ `withSize` 把 `primitive` 清掉，于是这里自然落回 `.manual`。
        if primitive != nil { return .submitIntent }
        if isSizeLocked { return .manual }
        if sizeIntent != nil { return .submitIntent }
        return authoritativeSize == nil ? .appMeasured : .workflowAuthoritative
    }
    /// 一行可读的出处说明（面板用），例如「用户指定的最长边 1.10 米」。
    public var sizeProvenanceSummary: String {
        // 基础几何那一份记录里就是**逐位回读**那一句（用户说的毫米数 + 场景里的米数 +
        // "z 是底座进深、面板厚度是拼出来的"）。它是那句解释的唯一来源，面板不另算。
        if let primitive { return primitive.summary }
        switch sizeProvenance {
        case .manual: return "手动改过尺寸（最长边 \(WorldPropSizePolicy.meters(longestEdge)) 米）"
        case .submitIntent: return sizeIntent?.summary ?? "按提交时的尺寸意图"
        case .workflowAuthoritative: return "生成工作流给的权威尺寸"
        case .appMeasured: return "按生成请求自动推断"
        }
    }
    public var isValid: Bool {
        [objectID, sourceWishID, assetID, displayName].allSatisfy { !$0.isEmpty && $0.count <= 256 }
            && [size.x, size.y, size.z, sourceHeight].allSatisfy { $0.isFinite && $0 > 0 && $0 <= 100 }
            && (size.y/sourceHeight).isFinite && size.y/sourceHeight > 0
            // 可选字段**存在时**必须合法：一份坏的代理描述不能被当成"没有代理"
            // （那会让碰撞形状在用户不知情下从代理退回盒子 —— 那正是 fail-open）。
            && (collision?.isValid ?? true)
            && (authoritativeSize?.isValid ?? true)
            // 尺寸意图同理：非法意图不能被当成"没有意图"（那就退回"让 app 猜"了）。
            && (sizeIntent?.isValid ?? true)
            // 基础几何记录同理：坏记录不能被当成"不是拼出来的"（面板会退回最长边那一行，
            // 而用户明明给过三轴 —— 那就是 fail-open）。
            && (primitive?.isValid ?? true)
            // 摆正旋转同理：坏掉的朝向不能被当成"不用摆正"（画面会躺着，而判据按立着算）。
            && (orientation?.isValid ?? true)
    }
    /// 换一份尺寸并**记下"这是用户定的"**（唯一一份尺寸仍然是 `size`）。
    ///
    /// 碰撞代理与权威尺寸**必须一起带过去**：改尺寸只改"多大"，不改"是哪一件产物、
    /// 用哪一份代理"。漏掉它们会让一次尺寸调整把代理悄悄丢掉 ⇒ 碰撞退回盒子。
    /// 尺寸意图**保留**：它是"这份产物当初是照谁的话做的"这一审计事实，
    /// 用户手动改过尺寸只把它在优先级里压到第二（`isSizeLocked` 先判），不改写历史。
    public func withSize(_ size: WorldVector3) -> WorldGeneratedProp {
        // 用户手动定的这一份**覆盖**工作流的权威尺寸：不丢掉 `authoritativeSize` 的话，
        // `effectiveSize` 会继续返回权威值 —— 于是判据/碰撞盒/画面全都还停在旧尺寸，
        // 而 `size` 变了，那就是"两份尺寸"。形状（碰撞代理）与这次调整无关，原样保留。
        WorldGeneratedProp(objectID: objectID, sourceWishID: sourceWishID, assetID: assetID,
                           displayName: displayName, size: size, sourceHeight: sourceHeight,
                           sizeLocked: true, collision: collision,
                           authoritativeSize: nil, sizeIntent: sizeIntent,
                           // 摆正与"多大"是两件事：改尺寸不该把"这件网格是躺着的"这件事丢掉，
                           // 否则改完尺寸画面又躺回去（存档/渲染会分叉）。
                           orientation: orientation,
                           // 基础几何记录**必须一起丢掉**：它那句 `summary` 说的是
                           // "场景里就是 1.443 × 0.862 × 0.302 米"，而用户刚刚把尺寸改成了
                           // 别的数 —— 留着它就是在面板上写一句当场可证的假话。
                           // 尺寸意图（"当初照谁的话做的"）是审计事实，原样保留。
                           primitive: nil)
    }
    /// 是不是**同一件物件**（身份相同）。尺寸可以不同：用户手动定过尺寸的物件，
    /// 自动基线必然与存档里的那一份不等 —— 那不是"资产归属不一致"，不该被判成错误。
    /// 带尺寸意图的物件同理：意图是提交时说的，自动基线按它算，重新登记时不必逐位相等。
    ///
    /// **`sourceHeight` 与 `orientation` 刻意不参与身份**：
    /// - `assetID` 就是模型字节的 sha256 ⇒ "是不是同一份网格"这一个问题它已经答完了，
    ///   `sourceHeight` 只是同一份网格的一个**量法**；
    /// - 而"怎么量"是会变的：摆正（`WorldPropOrientation`）落地之后，同一份网格的
    ///   "高度"从"原始 Y 跨度"变成"摆正后的 Y 跨度"（真机那把躺着生成的剑：0.133 → 1.005 m）。
    ///   把它算进身份，会让**每一条旧存档**在下一次资产准备时被判成归属不一致 ⇒ 从房间里消失。
    ///   这正是 §`sizeLocked` 注释里记着的那次真机缺陷，绝不能靠改一个字段的语义把它带回来。
    public func matchesIdentity(of other: WorldGeneratedProp) -> Bool {
        objectID == other.objectID && sourceWishID == other.sourceWishID && assetID == other.assetID
            && displayName == other.displayName
            && (size == other.size || isSizeLocked || other.isSizeLocked
                || sizeIntent != nil || other.sizeIntent != nil)
    }
}

public struct WorldPropPlacement: Codable, Equatable, Sendable {
    public let surfaceID: String
    public let position: WorldVector3
    public let yaw: Float
    public init(surfaceID: String, position: WorldVector3, yaw: Float) {
        self.surfaceID = surfaceID; self.position = position; self.yaw = yaw
    }
}

/// 挂点：物件挂在角色的哪根骨头上 —— 手、背后、腰间。
///
/// **旧名字与旧字段名都不动**：`WorldPropGripCalibration.hand` 这个**字段名**保留（它就是
/// 存档里的 JSON 键），`rightHand` 这个**原始值**也保留。于是旧存档里 `"hand":"rightHand"`
/// 解出来逐字节不变，只是这个类型现在回答的问题从"哪只手"变成了"哪个挂点"。
public enum WorldPropSlot: String, Codable, Equatable, Sendable {
    case rightHand
    case back
    case waist
}

/// 旧名保留：既有调用点与 harness 一行都不用改。
public typealias WorldPropHand = WorldPropSlot

/// A resident-specific grip in final, metre-scaled prop space.
public struct WorldPropGripCalibration: Codable, Equatable, Sendable {
    public let avatarAssetID: String
    public let hand: WorldPropHand
    public let normalizedGrip: WorldVector3
    public let localOffset: WorldVector3
    public let localRotation: WorldQuaternion

    public init(
        avatarAssetID: String,
        hand: WorldPropHand,
        normalizedGrip: WorldVector3,
        localOffset: WorldVector3,
        localRotation: WorldQuaternion
    ) {
        self.avatarAssetID = avatarAssetID
        self.hand = hand
        self.normalizedGrip = normalizedGrip
        self.localOffset = localOffset
        self.localRotation = localRotation
    }

    public var isValid: Bool {
        guard !avatarAssetID.isEmpty, avatarAssetID.count <= 256 else { return false }
        let grip = [normalizedGrip.x, normalizedGrip.y, normalizedGrip.z]
        guard grip.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else { return false }
        let offset = [localOffset.x, localOffset.y, localOffset.z]
        guard offset.allSatisfy({ $0.isFinite && abs($0) <= 2 }) else { return false }
        let rotation = [localRotation.x, localRotation.y, localRotation.z, localRotation.w]
        guard rotation.allSatisfy(\.isFinite) else { return false }
        let lengthSquared = rotation.reduce(Float.zero) { $0 + $1 * $1 }
        return lengthSquared.isFinite && abs(lengthSquared - 1) <= 0.01
    }
}

public struct WorldHeldProp: Codable, Equatable, Sendable {
    public let objectID: String
    public let avatarAssetID: String
    /// **挂点**（旧字段名 `hand` 与原始值都不动 ⇒ 旧存档逐字节可解）。
    /// `var` 是因为"换挂点"走既有的 `.adjustGrip`：就地把这件东西从手里挪到背后，
    /// 而不是先放回再拿起。
    public var hand: WorldPropSlot
    public var returnState: WorldObjectState

    public init(
        objectID: String,
        avatarAssetID: String,
        hand: WorldPropHand,
        returnState: WorldObjectState
    ) {
        self.objectID = objectID
        self.avatarAssetID = avatarAssetID
        self.hand = hand
        self.returnState = returnState
    }
}

public enum WorldPropLayoutCommand: Codable, Equatable, Sendable {
    case register(WorldGeneratedProp)
    case place(objectID: String, placement: WorldPropPlacement)
    case withdraw(objectID: String)
    /// 用户改这一件物件自己的尺寸。传进来的 `size` 就是**最终**尺寸：渲染、碰撞盒、
    /// 红/绿格、存档读的都是它（不引入第二份尺寸来源），并且必须是当前尺寸的**等比缩放**
    /// （渲染端只有一份等比缩放，非等比会让碰撞盒与画面对不上 ⇒ 拒绝）。
    case resize(objectID: String, size: WorldVector3)
    /// **把一件已经登记的物件的派生字段对齐到今天**（历史存档自愈：真机 2026-10-01 的
    /// 「2B 白色长剑（外形摆件）」在朝向归一落地**之前**登记，存档里的 `size` 是旧规则
    /// 算的 ⇒ `matchesIdentity` 判成"资产归属不一致" ⇒ 那件资产永远进不了
    /// `residentOwnedPropAssets`，用户**永久摆不了**它）。
    ///
    /// 它不是"另一种 register"，也不是"改尺寸"：
    /// - **身份与用户字段逐位不许变**（`WorldPropArchiveRebase.isDerivedOnlyRewrite`）；
    /// - 只有 `size` / `sourceHeight` / `orientation` 这三个**派生**字段可以被替换，
    ///   而且新值必须由 `WorldPropArchiveRebase` 判为"同一份网格的另一种量法"（可解释）；
    /// - **放置不动**：`isEnabled` / `transform.position` / `transform.rotation` / 手持状态
    ///   一个字节都不改（渲染色调 `scale` 跟着 `effectiveSize` 那一份唯一出口重算，
    ///   与 `.resize` 同一处换算）；
    /// - 幂等由**既有的** `layoutReceipts` 回答：调用方给一个内容寻址的 `requestID`
    ///   （`WorldPropArchiveRebase.Record.requestID`），同一份修复重放不写第二遍、
    ///   也不再涨 `layoutRevision`。
    case rebase(WorldGeneratedProp)
    case hold(objectID: String, avatarAssetID: String, calibration: WorldPropGripCalibration)
    case adjustGrip(objectID: String, avatarAssetID: String, calibration: WorldPropGripCalibration)
    /// Switch only the avatar binding of the same held prop. The previous avatar
    /// is an explicit precondition; source grip, slot and return placement stay fixed.
    case rebindHeldAvatar(objectID: String, previousAvatarAssetID: String, calibration: WorldPropGripCalibration)
    case returnHeld(objectID: String, avatarAssetID: String)
    /// Release to a verified nearby support pose, atomically preserving the prop.
    case dropHeld(objectID: String, avatarAssetID: String, placement: WorldPropPlacement)
    case enableCapability(objectID: String, templateID: String)
    /// **删掉一件生成资产**（永久，不可恢复）。
    ///
    /// 它不是"少了一行的 withdraw"：
    /// - 世界文档里这一条**离开** `objectStates`（权威据此把记录置墓碑并派生
    ///   `object.removed` 事实），但它**不是硬删** —— 身份冻结进
    ///   `WorldState.propTombstones[objectID]`，历史与对账都还答得出"它去哪儿了"；
    /// - 正在摆放 / 正在手持**在同一次提交里原子收场**（`WorldPropDeletionSettlement`）：
    ///   摆放随删除结束，手持先按 `heldProp.returnState` 放回再删 —— 绝不留下悬空的手持记录；
    /// - `reason` 可省（用户的理由），最多 200 字：它是审计事实的一部分。
    ///
    /// 幂等仍由**既有的** `layoutReceipts` 回答（同一个 `requestID` 重放不写第二遍）。
    case delete(objectID: String, reason: String?)
    case undo
}

public enum WorldPropLayoutError: Error, Equatable, Sendable {
    case staleRevision(submitted: UInt64, current: UInt64)
    case requestConflict
    case invalidObject
    /// 删除时找不到那一件：**具名失败**，绝不静默成功（否则 agent 会以为删掉了）。
    case objectNotFound(objectID: String)
    /// 这件物件已经在墓碑里了（再删一次不是幂等成功，而是说清"它已经删了"）。
    case objectAlreadyDeleted(objectID: String)
    /// 删除理由过长（审计字段不接受任意长度的文本）。
    case deletionReasonTooLong
    case invalidPlacement
    /// 尺寸越界 / 非等比。带上**读得懂的原因**（面板与光标旁的标签都显示它）。
    case invalidSize(String)
    case nothingToUndo
    case heldPropAlreadyExists(objectID: String)
    case objectIsHeld(objectID: String)
    case heldPropMismatch
    case activeActivityConflict(activityID: String)
    case invalidGripCalibration
    case unsupportedCapability(templateID: String)
}

public struct WorldPropLayoutUndo: Codable, Equatable, Sendable {
    public let objectID: String
    public let previous: WorldObjectState
    public let previousHeldProp: WorldHeldProp?

    public init(objectID: String, previous: WorldObjectState, previousHeldProp: WorldHeldProp? = nil) {
        self.objectID = objectID
        self.previous = previous
        self.previousHeldProp = previousHeldProp
    }
}

public extension WorldObjectState {
    /// Authored built-in devices use the same durable pose and dimensions as
    /// their render/click proxy. They remain obstacles without pretending to be
    /// inventory-owned generated props.
    var builtinDeviceCollisionVolume: WorldCollisionVolume? {
        guard isEnabled, let raw = metadata["gmgn.builtin-device.v1"],
              let declaration = try? JSONDecoder().decode(WorldProceduralPropDeclaration.self, from: Data(raw.utf8)),
              ["builtin.jukebox", "builtin.wish_machine"].contains(declaration.renderer ?? ""),
              let size = declaration.size,
              [size.x,size.y,size.z].allSatisfy({ $0.isFinite && $0 > 0 }),
              [transform.scale.x,transform.scale.y,transform.scale.z].allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        let dimensions = WorldVector3(x:size.x*transform.scale.x,y:size.y*transform.scale.y,z:size.z*transform.scale.z)
        let p = transform.position
        return WorldCollisionVolume(id:declaration.objectID,
            center:.init(x:p.x,y:p.y+dimensions.y/2,z:p.z),
            halfExtents:.init(x:dimensions.x/2,y:dimensions.y/2,z:dimensions.z/2),
            rotation:transform.rotation,isBlocking:true)
    }
    var generatedProp: WorldGeneratedProp? {
        guard let json = metadata["gmgn.generated-prop.v1"], let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(WorldGeneratedProp.self, from: data), value.isValid else { return nil }
        return value
    }
    var supportSurfaceID: String? { metadata["gmgn.support-surface.v1"] }
    var gripCalibration: WorldPropGripCalibration? {
        guard let json = metadata["gmgn.prop-grip.v1"], let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(WorldPropGripCalibration.self, from: data), value.isValid else { return nil }
        return value
    }
    /// **今天那条路**：yaw 包围盒。尺寸读 `effectiveSize`（有权威尺寸就以它为准）。
    ///
    /// 仍然保留：它是"没有代理"时的回退，也是所有只认盒子的旧消费者的输入。
    var generatedCollisionVolume: WorldCollisionVolume? {
        guard isEnabled, let prop = generatedProp else { return nil }
        let p = transform.position
        let size = prop.effectiveSize
        return WorldCollisionVolume(id: prop.objectID, center: .init(x: p.x,y: p.y + size.y/2,z: p.z),
            halfExtents: .init(x: size.x/2,y: size.y/2,z: size.z/2), rotation: transform.rotation, isBlocking: true)
    }

    /// **权威形状**：有碰撞代理就用代理（摆到世界坐标的三角形），没有就用今天的 yaw 盒子。
    ///
    /// 返回 nil 的两种情形都必须被上层当成"解不出体积"（fail-closed / 可见拒绝）：
    /// - `generatedProp` 解不出来（元数据坏了）；
    /// - 元数据**声明了**代理、但那份代理不在注册表里（没安装 / 安装失败 / 不归一）。
    ///   这里**绝不**退回盒子 —— 那会让碰撞形状在用户不知情下变掉。
    var generatedCollisionObstacle: WorldPropObstacle? {
        guard isEnabled, let prop = generatedProp else { return nil }
        guard let collision = prop.collision else {
            guard let volume = generatedCollisionVolume else { return nil }
            return WorldPropObstacle(volume: volume)
        }
        guard let proxy = WorldPropCollisionProxyStore.shared.mesh(forSHA256: collision.sha256),
              let mesh = proxy.placed(
                  id: prop.objectID,
                  format: collision.format,
                  position: transform.position,
                  yaw: transform.rotation.yawAroundUp,
                  heightMeters: prop.effectiveSize.y,
                  // 代理与模型必须共用**同一份**摆正旋转：只转模型不转代理，碰撞形状就与画面
                  // 错位（"盒子挡空气"的同一族病）。这一份来自物件元数据，不是这里另算的。
                  orientation: prop.orientation
              )
        else { return nil }
        return WorldPropObstacle(id: prop.objectID, isBlocking: true, shape: .proxyMesh(mesh))
    }
}

extension WorldQuaternion {
    /// 只有绕 Y 的旋转对"物件怎么站在地上"有意义（`WorldPropMeshClearance.canPlace` 与
    /// `ResidentPropPlacementMatrix` 都是这个口径）。x/z 分量不为 0 的极端四元数按 yaw 投影处理。
    var yawAroundUp: Float {
        let lengthSquared = x * x + y * y + z * z + w * w
        guard lengthSquared.isFinite, lengthSquared > 0.000001 else { return 0 }
        let inverse = 1 / lengthSquared.squareRoot()
        let ny = y * inverse, nw = w * inverse
        let yaw = 2 * atan2(ny, nw)
        return yaw.isFinite ? yaw : 0
    }
}

/// 世界状态 → **世界障碍体积**的**唯一**一份换算。
///
/// 「已摆放的生成物件在世界里是障碍」这件事有两个消费者，它们的输入必须逐字相同：
///
/// - 运行时移动/站立（`WorldAgentContext` 的 `PropLayoutCollisionWorld` → 居民胶囊）；
/// - 摆放时的"这里会不会挡人 / 挡住活动锚点"预检（`ResidentPropPlacementService`）。
///
/// 两边以前各自写 `state.objectStates.values.compactMap(\.generatedCollisionVolume)`：
/// 同一份 `compactMap`，但**解不出体积的已摆物件被静默丢掉**（`compactMap` 的语义），
/// 于是"元数据坏掉的物件"在两个判据里都变成"这里没有东西"——一件看不见、也挡不住的
/// 家具。那正是这个项目反复踩的坑：**判定只能有一条，而且缺失必须可见**。
///
/// 所以这里把"哪些物件有体积、哪些解不出来"一次性说清楚：
/// - `obstacles`：全部可用的阻挡形状（运行时与摆放预检共用，含生成侧的碰撞代理）；
/// - `volumes`：只认盒子的旧消费者的**保守**投影（见下面的说明）；
/// - `unmodelledObjectIDs`：`isEnabled == true` 却解不出形状的物件编号。调用方**必须**
///   把它当成"判据不完整"来处理（拒绝并报告），不得当作"无障碍"继续。
public enum WorldLayoutObstacles {
    public struct Resolution: Equatable, Sendable {
        /// **权威**的一份：每个障碍带自己的形状（yaw 盒子**或**生成侧的碰撞代理）。
        /// 三条判据（运行时移动、通路预检、互斥预检）都读它。
        public let obstacles: [WorldPropObstacle]
        /// 已摆出（`isEnabled`）却解不出碰撞形状的物件编号，字典序。
        public let unmodelledObjectIDs: [String]

        /// 只认盒子的旧消费者的输入：盒障碍**逐字**给出，代理障碍给出它的世界轴包围盒。
        ///
        /// 这个投影的性质是**只会多挡、不会漏挡**（包围盒包含代理本身），所以旧消费者
        /// 不至于 fail-open。但它会**假拒绝**细长物件，所以新消费者一律用 `obstacles`。
        /// 现存唯一的使用点是 `ResidentPropPlacementService`（它还在把体积交给
        /// `PropPlacementEvaluator` / `WorldPlacementRouteMap` 的盒子入口）。
        ///
        /// 换成 `obstacles` 的清单见
        /// `docs/plans/2026-10-02-workflow-side-collision-proxy-checklist.md`。
        public var volumes: [WorldCollisionVolume] {
            obstacles.map(\.conservativeBoxProjection)
        }

        public init(obstacles: [WorldPropObstacle], unmodelledObjectIDs: [String]) {
            self.obstacles = obstacles
            self.unmodelledObjectIDs = unmodelledObjectIDs
        }

        /// 兼容入口：只有盒子时与旧签名逐字一致（`volumes` 就是传进来的那批）。
        public init(volumes: [WorldCollisionVolume], unmodelledObjectIDs: [String]) {
            self.init(
                obstacles: volumes.map(WorldPropObstacle.init(volume:)),
                unmodelledObjectIDs: unmodelledObjectIDs
            )
        }
    }

    /// 已摆出的物件（含**手持物件的原放回位置**）+ 它们的阻挡体积。
    ///
    /// 手持中的物件在状态里是 `isEnabled == false`（它现在在居民手上），但它**注定要
    /// 放回** `heldProp.returnState` 那个位置 —— 摆放判据必须把那个位置按"已经有东西"
    /// 处理，否则用户可以在居民手里那件物件的放回点上再摆一件，一放回就互相穿模。
    /// 运行时移动判据不需要这一条（那个位置此刻真的什么都没有），但体积来源仍是这一份。
    public static func resolve(_ state: WorldState) -> Resolution {
        var obstacles: [WorldPropObstacle] = []
        var unmodelled: [String] = []
        for (id, item) in state.objectStates {
            guard item.isEnabled else { continue }
            // `generatedCollisionObstacle` 在"元数据坏了"**和**"声明了代理但代理解不出来"
            // 两种情形下都返回 nil。两种都必须可见 —— 后者是本轮新增的 fail-closed 落点。
            if let volume = item.builtinDeviceCollisionVolume, volume.id == id {
                obstacles.append(WorldPropObstacle(volume:volume))
            } else if let obstacle = item.generatedCollisionObstacle {
                obstacles.append(obstacle)
            } else {
                unmodelled.append(id)
            }
        }
        if let held = state.heldProp, held.returnState.isEnabled,
           let obstacle = held.returnState.generatedCollisionObstacle {
            obstacles.append(obstacle)
        }
        return Resolution(
            obstacles: obstacles.sorted { $0.id < $1.id },
            unmodelledObjectIDs: unmodelled.sorted()
        )
    }
}

extension WorldPropLayoutError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .staleRevision(_, current): "物件状态已经变化，请按版本 \(current) 重试。"
        case .requestConflict: "物件请求与已经处理的请求冲突。"
        case .invalidObject: "物件不存在或物件资料无效。"
        case let .objectNotFound(objectID): "没有找到这件物件（\(objectID)），它可能已经被删除了。"
        case let .objectAlreadyDeleted(objectID): "物件 \(objectID) 已经删除过了，墓碑还在，不必再删。"
        case .deletionReasonTooLong: "删除理由太长了（最多 200 字）。"
        case .invalidPlacement: "物件摆放位置无效。"
        case let .invalidSize(reason): reason
        case .nothingToUndo: "没有可撤销的物件操作。"
        case let .heldPropAlreadyExists(objectID): "居民已经手持物件 \(objectID)。"
        case let .objectIsHeld(objectID): "物件 \(objectID) 正在手持中，请先放回。"
        case .heldPropMismatch: "手持物件或居民已经变化，请重新查看后再操作。"
        case let .activeActivityConflict(activityID): "居民正在进行活动 \(activityID)，暂时不能手持物件。"
        case .invalidGripCalibration: "物件握持位置或旋转无效。"
        case let .unsupportedCapability(templateID): "该物件不支持使用能力 \(templateID)，当前仅支持 coffee.brew 冲泡模板。"
        }
    }
}

/// Placement-only triangle/box test. Callers cache the local triangles for authored support regions.
/// This deliberately does not share the character controller's step-over behavior.
public enum WorldPropMeshClearance {
    /// 允许"贴地"判定放宽多少米：低于/等于 `supportHeight + restingTolerance` 的三角形
    /// 视为与承托面接触，不当作插进物件。
    ///
    /// 这个值只对**手工摆平的承托面**无所谓（0.1 毫米足够）；但真实舱体的地面是生成
    /// 出来的起伏网格，footprint 里总有比锚点高几毫米的三角形，于是同一块地面上一件
    /// 0.35×0.57 m 的物件只有 3% 的格子能放（90° 时 1%）。要不要放宽、放宽到多少是
    /// **产品取舍**：放得越宽，物件越可能肉眼可见地陷进地面。所以这里把它做成显式
    /// 参数（默认仍是原来的 0.1 毫米），让"如果放宽到 N 毫米会怎样"可以被实测，
    /// 而不是靠猜。
    public static let restingTolerance: Float = 0.02

    public static func canPlace(_ box: WorldCollisionVolume, supportHeight: Float,
                                triangles: [WorldTriangle],
                                restingTolerance: Float = WorldPropMeshClearance.restingTolerance) -> Bool {
        let q=box.rotation, h=SIMD3(box.halfExtents.x,box.halfExtents.y,box.halfExtents.z)
        let center=SIMD3(box.center.x,box.center.y,box.center.z)
        guard [h.x,h.y,h.z].allSatisfy({ $0.isFinite && $0>0 }),
              [center.x,center.y,center.z,supportHeight,q.x,q.y,q.z,q.w].allSatisfy(\.isFinite),
              abs(q.x)<0.0001,abs(q.z)<0.0001 else { return false }
        let yaw=atan2(2*q.w*q.y,1-2*q.y*q.y),c=cos(yaw),s=sin(yaw)
        let ex=abs(c)*h.x+abs(s)*h.z,ez=abs(s)*h.x+abs(c)*h.z
        func local(_ p:SIMD3<Float>)->SIMD3<Float> {
            let d=p-center
            return SIMD3(c*d.x-s*d.z,d.y,s*d.x+c*d.z)
        }
        func cross(_ a:SIMD3<Float>,_ b:SIMD3<Float>)->SIMD3<Float> {
            SIMD3(a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x)
        }
        func dot(_ a:SIMD3<Float>,_ b:SIMD3<Float>)->Float { a.x*b.x+a.y*b.y+a.z*b.z }
        let basis:[SIMD3<Float>]=[SIMD3(1,0,0),SIMD3(0,1,0),SIMD3(0,0,1)]
        for t in triangles {
            let vertices=[t.first,t.second,t.third]
            guard vertices.allSatisfy({ [$0.x,$0.y,$0.z].allSatisfy(\.isFinite) }) else { return false }
            let minX=min(t.first.x,min(t.second.x,t.third.x)),maxX=max(t.first.x,max(t.second.x,t.third.x))
            let minY=min(t.first.y,min(t.second.y,t.third.y)),maxY=max(t.first.y,max(t.second.y,t.third.y))
            let minZ=min(t.first.z,min(t.second.z,t.third.z)),maxZ=max(t.first.z,max(t.second.z,t.third.z))
            // Permit contact with the authored support, never skip a triangle crossing into the item.
            if maxY <= supportHeight+restingTolerance || minY >= center.y+h.y || maxY <= center.y-h.y
                || maxX < center.x-ex || minX > center.x+ex || maxZ < center.z-ez || minZ > center.z+ez { continue }
            let points=vertices.map(local)
            let edges=[points[1]-points[0],points[2]-points[1],points[0]-points[2]]
            let axes=basis + [cross(edges[0],edges[1])] + edges.flatMap { edge in basis.map { cross(edge,$0) } }
            var separated=false
            for axis in axes {
                let length=sqrt(dot(axis,axis))
                if length < 0.0000001 { continue }
                let unit=axis/length
                let p=points.map { dot($0,unit) }
                let r=h.x*abs(unit.x)+h.y*abs(unit.y)+h.z*abs(unit.z)
                if p.min()! >= r-0.000001 || p.max()! <= -r+0.000001 { separated=true;break }
            }
            if !separated { return false }
        }
        return true
    }
}

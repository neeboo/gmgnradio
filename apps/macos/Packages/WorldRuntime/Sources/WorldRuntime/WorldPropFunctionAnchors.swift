import Foundation

// MARK: - 声明：道具本体坐标系下的功能点

/// 道具**本体坐标系**下的一个功能点。
///
/// 「物品上的功能点」只有这一种声明形态：坐标是**局部的**（原点 = 道具落地点，+Y 向上），
/// 角色是道具自己起的名字。宿主**不得**知道任何具体角色对应的坐标 —— 它只会把声明乘上
/// 摆放 transform，再按角色查回来。任何写死在世界代码里的坐标/锚点 id 都是缺陷。
public struct WorldPropFunctionPoint: Codable, Equatable, Sendable {
    /// 功能点的语义。**只有 `standingSpot` 参与可站立 / 可达判据**：把出货口或按钮
    /// 喂进"居民站得住吗"会产生假拒绝，而假拒绝会让人把判据整条删掉。
    public enum Kind: String, Codable, Equatable, Sendable {
        /// 居民要站上去的点（活动的接近锚点）。
        case standingSpot
        /// 只发射/承接物件的点（出货口、托盘），居民不站上去。
        case emitter
        /// 被操作的点（按钮 / 机身正面）。用来给站姿定向，居民不站上去。
        case interaction
    }

    public let role: String
    public let kind: Kind
    /// 本体坐标系下的位置。
    public let position: WorldVector3
    /// 居民站上去时的朝向（本体坐标系下的 yaw，弧度）。`nil` = 朝向被操作点，再退到原点。
    public let yaw: Float?
    /// 把这里当作**接近锚点**的活动 id。`nil` = 这个功能点不绑定活动。
    public let activityID: String?

    public init(
        role: String,
        kind: Kind = .standingSpot,
        position: WorldVector3,
        yaw: Float? = nil,
        activityID: String? = nil
    ) {
        self.role = role
        self.kind = kind
        self.position = position
        self.yaw = yaw
        self.activityID = activityID
    }

    public var isValid: Bool {
        guard !role.isEmpty, role.count <= 64,
              role.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-" })
        else { return false }
        guard [position.x, position.y, position.z].allSatisfy({ $0.isFinite && abs($0) <= 100 })
        else { return false }
        if let yaw, !yaw.isFinite { return false }
        if let activityID, activityID.isEmpty || activityID.count > 256 { return false }
        return true
    }

    private enum CodingKeys: String, CodingKey {
        case role, kind, position, yaw, activityID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(String.self, forKey: .role)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .standingSpot
        position = try WorldPropPointCoding.decodeVector(container, forKey: .position)
        yaw = try container.decodeIfPresent(Float.self, forKey: .yaw)
        activityID = try container.decodeIfPresent(String.self, forKey: .activityID)
    }
}

/// 一件道具声明的功能点集合。**这是"物品上的功能点"的唯一来源**：
/// 世界包里的 `prop.procedural` 定义，以及生成道具的资产元数据，都用这个结构。
public struct WorldPropFunctionPointDeclaration: Codable, Equatable, Sendable {
    /// 生成道具的资产元数据里声明功能点的键。
    public static let metadataKey = "gmgn.prop-function-points.v1"
    /// 一件道具能声明的功能点数量上限（防御性上限，不是产品上限）。
    public static let maximumFunctionPoints = 16

    public let objectID: String
    public let functionPoints: [WorldPropFunctionPoint]

    public init(objectID: String, functionPoints: [WorldPropFunctionPoint]) {
        self.objectID = objectID
        self.functionPoints = functionPoints
    }

    public var isValid: Bool {
        !objectID.isEmpty && objectID.count <= 256
            && !functionPoints.isEmpty
            && functionPoints.count <= Self.maximumFunctionPoints
            && functionPoints.allSatisfy(\.isValid)
            && Set(functionPoints.map(\.role)).count == functionPoints.count
    }

    public func point(role: String) -> WorldPropFunctionPoint? {
        functionPoints.first { $0.role == role }
    }

    public func points(kind: WorldPropFunctionPoint.Kind) -> [WorldPropFunctionPoint] {
        functionPoints.filter { $0.kind == kind }
    }

    /// 绑定到该活动、且是**接近锚点**的那一个功能点。多于一处的歧义由注册表拒绝，
    /// 这里只负责"声明内"的查询。
    public func entryPoint(activityID: String) -> WorldPropFunctionPoint? {
        functionPoints.first {
            $0.activityID == activityID && $0.kind == .standingSpot
        }
    }

    private enum CodingKeys: String, CodingKey {
        case objectID, functionPoints
    }
}

public extension WorldObjectState {
    /// 生成道具在**资产元数据**里声明的功能点。缺失或非法 = 这件道具没有功能点，
    /// 绝不猜（`nil`，而不是空表）。
    var functionPointDeclaration: WorldPropFunctionPointDeclaration? {
        guard let json = metadata[WorldPropFunctionPointDeclaration.metadataKey],
              let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(
                  WorldPropFunctionPointDeclaration.self, from: data
              ),
              value.isValid
        else { return nil }
        // 生成道具：声明必须自称是这一件（元数据不能张冠李戴到别的物件上）。
        if let generatedObjectID = generatedProp?.objectID {
            return value.objectID == generatedObjectID ? value : nil
        }
        return value
    }
}

/// 世界包里一件 `prop.procedural` 道具的声明。
///
/// `position`/`yaw` 是**种子**摆放：只在存档里根本没有这件道具时使用。存档里有这件道具
/// （`objectStates[objectID]`）时，**存档是唯一事实源** —— 包括"它被收回了"这件事。
public struct WorldProceduralPropDeclaration: Codable, Equatable, Sendable {
    public let objectID: String
    public let renderer: String?
    public let seedPosition: WorldVector3
    public let seedYaw: Float
    public let size: WorldVector3?
    public let activityID: String?
    public let functionPoints: [WorldPropFunctionPoint]

    public init(
        objectID: String,
        renderer: String? = nil,
        seedPosition: WorldVector3,
        seedYaw: Float,
        size: WorldVector3? = nil,
        activityID: String? = nil,
        functionPoints: [WorldPropFunctionPoint] = []
    ) {
        self.objectID = objectID
        self.renderer = renderer
        self.seedPosition = seedPosition
        self.seedYaw = seedYaw
        self.size = size
        self.activityID = activityID
        self.functionPoints = functionPoints
    }

    public var functionPointDeclaration: WorldPropFunctionPointDeclaration? {
        let declaration = WorldPropFunctionPointDeclaration(
            objectID: objectID, functionPoints: functionPoints
        )
        return declaration.isValid ? declaration : nil
    }

    public var functionSource: WorldPropFunctionSource? {
        guard let declaration = functionPointDeclaration else { return nil }
        return WorldPropFunctionSource(
            declaration: declaration,
            seedPosition: seedPosition,
            seedYaw: seedYaw
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, renderer, position, yaw, size, activityID, functionPoints
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        objectID = try container.decode(String.self, forKey: .id)
        renderer = try container.decodeIfPresent(String.self, forKey: .renderer)
        seedPosition = try WorldPropPointCoding.decodeVector(container, forKey: .position)
        seedYaw = try container.decodeIfPresent(Float.self, forKey: .yaw) ?? 0
        size = WorldPropPointCoding.decodeVectorIfPresent(container, forKey: .size)
        activityID = try container.decodeIfPresent(String.self, forKey: .activityID)
        functionPoints = try container.decodeIfPresent(
            [WorldPropFunctionPoint].self, forKey: .functionPoints
        ) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(objectID, forKey: .id)
        try container.encodeIfPresent(renderer, forKey: .renderer)
        try container.encode(
            [seedPosition.x, seedPosition.y, seedPosition.z], forKey: .position
        )
        try container.encode(seedYaw, forKey: .yaw)
        if let size {
            try container.encode([size.x, size.y, size.z], forKey: .size)
        }
        try container.encodeIfPresent(activityID, forKey: .activityID)
        try container.encode(functionPoints, forKey: .functionPoints)
    }
}

/// 一件道具的声明 + 它的**种子**摆放。存档里没有这件道具时才会用到种子。
public struct WorldPropFunctionSource: Equatable, Sendable {
    public let declaration: WorldPropFunctionPointDeclaration
    public let seedPosition: WorldVector3
    public let seedYaw: Float

    public init(
        declaration: WorldPropFunctionPointDeclaration,
        seedPosition: WorldVector3,
        seedYaw: Float
    ) {
        self.declaration = declaration
        self.seedPosition = seedPosition
        self.seedYaw = seedYaw
    }
}

// MARK: - 注册：局部点 × 摆放 transform = 世界锚点

/// 一件道具**当前**的摆放（位置 + 偏向）+ 它的功能点声明。注册表的唯一输入。
public struct WorldPropFunctionPlacement: Equatable, Sendable {
    public let objectID: String
    public let position: WorldVector3
    public let yaw: Float
    public let declaration: WorldPropFunctionPointDeclaration

    public init(
        objectID: String,
        position: WorldVector3,
        yaw: Float,
        declaration: WorldPropFunctionPointDeclaration
    ) {
        self.objectID = objectID
        self.position = position
        self.yaw = yaw
        self.declaration = declaration
    }
}

/// 一件道具注册出来的一个世界锚点。**永不落盘**：它每次都由声明 + 摆放派生。
public struct WorldPropFunctionAnchor: Equatable, Sendable {
    /// `"<objectID>#<role>"`。确定性、可复现、不含摆放信息。
    public let id: String
    public let objectID: String
    public let role: String
    public let kind: WorldPropFunctionPoint.Kind
    /// 世界坐标 = 摆放 transform ∘ 局部点。
    public let position: WorldVector3
    /// 世界朝向 = 摆放 yaw + 局部 yaw（未声明时朝向被操作点，再退到原点）。
    public let yaw: Float
    /// 绑定到哪个活动（只有接近锚点有）。
    public let activityID: String?

    public init(
        id: String,
        objectID: String,
        role: String,
        kind: WorldPropFunctionPoint.Kind,
        position: WorldVector3,
        yaw: Float,
        activityID: String?
    ) {
        self.id = id
        self.objectID = objectID
        self.role = role
        self.kind = kind
        self.position = position
        self.yaw = yaw
        self.activityID = activityID
    }

    public static func id(objectID: String, role: String) -> String {
        "\(objectID)#\(role)"
    }
}

public enum WorldPropAnchorError: Error, Equatable, Sendable {
    case invalidObjectID(String)
    case invalidDeclaration(objectID: String)
    case duplicateObject(objectID: String)
    case nonFinitePlacement(objectID: String)
    case duplicateRole(objectID: String, role: String)
    /// 两件道具都把一个接近锚点绑到同一个活动：**拒绝**，绝不静默取其一。
    case activityEntryConflict(activityID: String, first: String, second: String)
    /// 改摆放到一个不存在的道具上 / 改了不存在的活动绑定。
    case unknownPlacement(objectID: String)
}

/// 「道具功能点」的运行时注册表。
///
/// ## 生命周期
///
/// 注册表是**纯值**：由（声明，摆放）一次性派生，没有增量状态，所以**不可能**存在
/// "半注册"。改摆放 = 用同一套规则重新派生一个新值；新值要么完整成立，要么抛错，
/// 旧值仍然可用 —— 这就是回滚。
///
/// 谁持有：世界运行时（`WorldAgentContext`）持有一份；每次摆放/移动/收回/撤销/加载存档
/// 后重建。**不落盘**：存档里只有 `WorldObjectState.transform`，锚点每次从它派生，
/// 于是"锚点"与"摆放位置"不可能分叉成两份事实。
public struct WorldPropAnchorRegistry: Sendable {
    /// key = `WorldPropFunctionAnchor.id`。
    public let anchorsByID: [String: WorldPropFunctionAnchor]
    /// 活动 id → 它的接近锚点。一个活动**最多**一个；冲突是错误，不是"取最近的一个"。
    public let entriesByActivityID: [String: WorldPropFunctionAnchor]
    /// 派生的输入，按 objectID 排序，确定性。回滚/试算用它重新派生。
    public let placements: [WorldPropFunctionPlacement]

    public static let empty = WorldPropAnchorRegistry(
        anchorsByID: [:], entriesByActivityID: [:], placements: []
    )

    private init(
        anchorsByID: [String: WorldPropFunctionAnchor],
        entriesByActivityID: [String: WorldPropFunctionAnchor],
        placements: [WorldPropFunctionPlacement]
    ) {
        self.anchorsByID = anchorsByID
        self.entriesByActivityID = entriesByActivityID
        self.placements = placements
    }

    /// 从一组摆放派生。**fail-closed**：任何一处非法（角色重复、摆放非有限、
    /// 两件道具抢同一个活动入口）都抛错，不产出注册表。
    public init(placements: [WorldPropFunctionPlacement]) throws {
        var ordered = placements.sorted { $0.objectID < $1.objectID }
        var anchors: [String: WorldPropFunctionAnchor] = [:]
        var entries: [String: WorldPropFunctionAnchor] = [:]
        var seenObjects: Set<String> = []

        for placement in ordered {
            let objectID = placement.objectID
            guard !objectID.isEmpty, objectID.count <= 256 else {
                throw WorldPropAnchorError.invalidObjectID(objectID)
            }
            guard seenObjects.insert(objectID).inserted else {
                throw WorldPropAnchorError.duplicateObject(objectID: objectID)
            }
            guard placement.declaration.objectID == objectID else {
                throw WorldPropAnchorError.invalidDeclaration(objectID: objectID)
            }
            guard placement.declaration.isValid else {
                throw WorldPropAnchorError.invalidDeclaration(objectID: objectID)
            }
            let components = [placement.position.x, placement.position.y, placement.position.z, placement.yaw]
            guard components.allSatisfy(\.isFinite) else {
                throw WorldPropAnchorError.nonFinitePlacement(objectID: objectID)
            }

            for point in placement.declaration.functionPoints {
                let id = WorldPropFunctionAnchor.id(objectID: objectID, role: point.role)
                guard anchors[id] == nil else {
                    throw WorldPropAnchorError.duplicateRole(objectID: objectID, role: point.role)
                }
                let anchor = WorldPropFunctionAnchor(
                    id: id,
                    objectID: objectID,
                    role: point.role,
                    kind: point.kind,
                    position: Self.worldPosition(
                        of: point.position, placedAt: placement.position, yaw: placement.yaw
                    ),
                    yaw: Self.worldYaw(
                        of: point,
                        in: placement.declaration,
                        placedAt: placement.position,
                        yaw: placement.yaw
                    ),
                    activityID: point.activityID
                )
                anchors[id] = anchor
                guard let activityID = point.activityID, point.kind == .standingSpot else { continue }
                if let existing = entries[activityID] {
                    throw WorldPropAnchorError.activityEntryConflict(
                        activityID: activityID, first: existing.id, second: anchor.id
                    )
                }
                entries[activityID] = anchor
            }
        }
        ordered = ordered.sorted { $0.objectID < $1.objectID }
        ordered = ordered.sorted { $0.objectID < $1.objectID }
        self.init(anchorsByID: anchors, entriesByActivityID: entries, placements: ordered)
    }

    // MARK: 查询

    /// 全部锚点，按 id 排序（确定性）。
    public var anchors: [WorldPropFunctionAnchor] {
        anchorsByID.values.sorted { $0.id < $1.id }
    }

    public func anchor(id: String) -> WorldPropFunctionAnchor? { anchorsByID[id] }

    public func anchor(objectID: String, role: String) -> WorldPropFunctionAnchor? {
        anchorsByID[WorldPropFunctionAnchor.id(objectID: objectID, role: role)]
    }

    public func anchors(objectID: String) -> [WorldPropFunctionAnchor] {
        anchors.filter { $0.objectID == objectID }
    }

    public func anchors(role: String) -> [WorldPropFunctionAnchor] {
        anchors.filter { $0.role == role }
    }

    /// 某个活动的接近锚点。没有注册就是 `nil`：**活动规划只认注册出来的锚点**。
    public func entry(activityID: String) -> WorldPropFunctionAnchor? {
        entriesByActivityID[activityID]
    }

    /// 已注册出接近锚点的活动 id，排序。
    public var registeredActivityIDs: [String] {
        entriesByActivityID.keys.sorted()
    }

    // MARK: 判据输入（只有站立点）

    /// 「居民站得住吗 / 走得到吗」这条判据的锚点集合。**只有 `standingSpot`**。
    public var routeAnchors: [WorldPropFunctionAnchor] {
        anchors.filter { $0.kind == .standingSpot }
    }

    public var routeAnchorIDs: [String] { routeAnchors.map(\.id) }

    public var routeAnchorPositions: [String: WorldVector3] {
        Dictionary(uniqueKeysWithValues: routeAnchors.map { ($0.id, $0.position) })
    }

    // MARK: 试算 / 提交

    /// 一件道具的改摆放请求（移动或收回）。**试算**用它派生一份新注册表；
    /// 提交的只是"是否接受"这个决定，注册表本身由调用方在提交后重建。
    public enum PlacementChange: Equatable, Sendable {
        case place(objectID: String, position: WorldVector3, yaw: Float)
        case withdraw(objectID: String)
    }

    /// 派生一份"如果这样摆"的注册表。失败 = 这个摆放不成立，**调用方的当前注册表一个字节都没动**。
    public func applying(_ change: PlacementChange) throws -> WorldPropAnchorRegistry {
        var updated = placements
        switch change {
        case let .place(objectID, position, yaw):
            guard let index = updated.firstIndex(where: { $0.objectID == objectID }) else {
                throw WorldPropAnchorError.unknownPlacement(objectID: objectID)
            }
            let existing = updated[index]
            updated[index] = WorldPropFunctionPlacement(
                objectID: objectID, position: position, yaw: yaw,
                declaration: existing.declaration
            )
        case let .withdraw(objectID):
            guard let index = updated.firstIndex(where: { $0.objectID == objectID }) else {
                throw WorldPropAnchorError.unknownPlacement(objectID: objectID)
            }
            updated.remove(at: index)
        }
        return try WorldPropAnchorRegistry(placements: updated)
    }

    // MARK: 派生规则

    /// 从「声明（世界包的种子摆放）」+「存档里的摆放」派生注册表。
    ///
    /// 规则（每条都是 fail-closed）：
    ///
    /// 1. 存档里有这件道具 ⇒ **存档是唯一事实源**：启用 ⇒ 用它的 transform；
    ///    停用（收回）⇒ **不注册**，且**不回退到种子**（否则收回会"复活"锚点）。
    /// 2. 存档里没有这件道具 ⇒ 用声明里的种子摆放（世界固有道具的初始状态）。
    /// 3. 带功能点元数据的生成道具 ⇒ 只认存档里的摆放，停用即注销。
    /// 4. 同一 objectID 被两处声明 ⇒ 拒绝；同一声明里角色重复 ⇒ 拒绝；
    ///    两件道具抢同一个活动入口 ⇒ 拒绝。
    public static func derive(
        sources: [WorldPropFunctionSource] = [],
        objectStates: [String: WorldObjectState]
    ) throws -> WorldPropAnchorRegistry {
        var placements: [WorldPropFunctionPlacement] = []
        var declared: Set<String> = []
        for source in sources.sorted(by: { $0.declaration.objectID < $1.declaration.objectID }) {
            let objectID = source.declaration.objectID
            guard declared.insert(objectID).inserted else {
                throw WorldPropAnchorError.duplicateObject(objectID: objectID)
            }
            guard source.declaration.isValid else {
                throw WorldPropAnchorError.invalidDeclaration(objectID: objectID)
            }
            if let state = objectStates[objectID] {
                // 存档说话：包括"它被收回了"。
                guard state.isEnabled else { continue }
                placements.append(WorldPropFunctionPlacement(
                    objectID: objectID,
                    position: state.transform.position,
                    yaw: yaw(of: state.transform.rotation),
                    declaration: source.declaration
                ))
                continue
            }
            placements.append(WorldPropFunctionPlacement(
                objectID: objectID,
                position: source.seedPosition,
                yaw: source.seedYaw,
                declaration: source.declaration
            ))
        }
        for (objectID, state) in objectStates.sorted(by: { $0.key < $1.key }) {
            guard let declaration = state.functionPointDeclaration else { continue }
            guard declared.insert(objectID).inserted else {
                throw WorldPropAnchorError.duplicateObject(objectID: objectID)
            }
            guard state.isEnabled else { continue }
            placements.append(WorldPropFunctionPlacement(
                objectID: objectID,
                position: state.transform.position,
                yaw: yaw(of: state.transform.rotation),
                declaration: declaration
            ))
        }
        return try WorldPropAnchorRegistry(placements: placements)
    }

    // MARK: 局部 → 世界

    /// 本体坐标 → 世界坐标（只绕 +Y 旋转，与摆放的 yaw 同口径）。
    public static func worldPosition(
        of local: WorldVector3,
        placedAt position: WorldVector3,
        yaw: Float
    ) -> WorldVector3 {
        let cosine = cos(yaw)
        let sine = sin(yaw)
        return WorldVector3(
            x: position.x + cosine * local.x + sine * local.z,
            y: position.y + local.y,
            z: position.z - sine * local.x + cosine * local.z
        )
    }

    /// 站姿朝向：声明了局部 yaw 就用它；否则**面向**被操作点；再没有就面向原型原点。
    ///
    /// 朝向约定与烘焙的活动锚点一致：角色前方是 **-Z**，所以"面向 (dx,dz)"的 yaw 是
    /// `atan2(-dx, -dz)`。这不是猜的 —— 迁移前的两个烘焙值都由它重现：
    ///
    /// - 音箱：锚点 (1.3,-6)、道具 (2,-6) ⇒ dx=0.7, dz=0 ⇒ -π/2（烘焙 rotation
    ///   `(0,-0.7071,0,0.7071)` 换算出来正是 -π/2）；
    /// - 许愿机：锚点 (0.8,-3.55)、道具 (0.8,-2.6) ⇒ dx=0, dz=0.95 ⇒ π（烘焙
    ///   rotation `(0,1,0,~0)` 换算出来正是 π）。
    public static func worldYaw(
        of point: WorldPropFunctionPoint,
        in declaration: WorldPropFunctionPointDeclaration,
        placedAt position: WorldVector3,
        yaw: Float
    ) -> Float {
        if let declared = point.yaw { return normalizedYaw(yaw + declared) }
        let target = declaration.points(kind: .interaction).first?.position
            ?? WorldVector3(x: 0, y: 0, z: 0)
        let dx = target.x - point.position.x
        let dz = target.z - point.position.z
        guard dx.isFinite, dz.isFinite, (dx * dx + dz * dz) > 1e-8 else {
            return normalizedYaw(yaw)
        }
        return normalizedYaw(yaw + atan2(-dx, -dz))
    }

    /// 四元数 → yaw（与 `WorldAgentContext` /烘焙活动锚点的取法同口径：只有绕 Y 的分量）。
    public static func yaw(of rotation: WorldQuaternion) -> Float {
        let numerator = 2 * (rotation.w * rotation.y + rotation.x * rotation.z)
        let denominator = 1 - 2 * (rotation.y * rotation.y + rotation.z * rotation.z)
        return normalizedYaw(atan2(numerator, denominator))
    }

    private static func normalizedYaw(_ yaw: Float) -> Float {
        guard yaw.isFinite else { return yaw }
        var value = yaw.truncatingRemainder(dividingBy: 2 * .pi)
        if value > .pi { value -= 2 * .pi }
        if value <= -.pi { value += 2 * .pi }
        return value
    }
}

/// 世界包里的道具 JSON 用 `[x,y,z]` 数组写坐标，元数据/新写入的 JSON 也可能用
/// `{x,y,z}`。两种都收，**但只收合法的三维**。
enum WorldPropPointCoding {
    static func decodeVector<Key: CodingKey>(
        _ container: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) throws -> WorldVector3 {
        guard let value = try decodeVectorIfPresent(container, forKey: key) else {
            throw DecodingError.keyNotFound(
                key,
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "缺少三维坐标 \(key.stringValue)"
                )
            )
        }
        return value
    }

    static func decodeVectorIfPresent<Key: CodingKey>(
        _ container: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) -> WorldVector3? {
        if let vector = try? container.decode(WorldVector3.self, forKey: key) {
            return vector
        }
        guard let array = try? container.decode([Float].self, forKey: key),
              array.count == 3, array.allSatisfy(\.isFinite)
        else { return nil }
        return WorldVector3(x: array[0], y: array[1], z: array[2])
    }
}

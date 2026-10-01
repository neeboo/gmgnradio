import Foundation

// ===========================================================================
// 「把这件东西摆正」—— 面积/朝向归一化的**唯一**一份策略
// ===========================================================================
//
// ## 为什么要有这一份
//
// 生成服务交回来的网格**不保证立着**。2026-10-01 真机那把「2B 白色长剑（外形摆件）」
// 实测 AABB 是 1.005 × 0.133 × 0.057 m（长 × 高 × 厚）：网格是**躺着**的，而 app 在
// 归一化那一步（`WishMachineOutputPlacement.transform`）**只按 Y 轴量高度**：
//
//   scale = 请求高度 / (max.y - min.y) = 1.1 / 0.133493 = 8.2401
//
// 于是场景里那把剑有 8.2848 m 长 —— 比整个舱室还长。当时修的是**面积那一面**
// （`WorldPropSizePolicy`：细长物件改按最长边归一），朝向那一面留着：网格仍然是躺着的，
// 编辑器里能转的只有绕竖轴的 yaw（`WorldQuaternion` 只写 y 分量），所以躺着的模型
// **转也转不正**。用户的原话是「现在放置只能放地板，而且打横」。
//
// 这一份修的就是朝向那一面：在**入库那一处**把物件摆正，并把"凭什么这么摆"记进世界状态。
//
// ## 与尺寸策略的分工（两份东西，不是两份尺寸）
//
//   原始网格 AABB ──[本文件：摆正]──► 转正后的 AABB ──[WorldPropSizePolicy]──► `size`
//
// 摆正**先**发生：转正之后，那把剑的 AABB 变成 0.133 × 1.005 × 0.057 ⇒ 最长边/高度 = 1
// ⇒ 尺寸策略回到"高度就是它的大小"这条主路（`basis == .height`），1.1 m 的请求得到一把
// **立着的 1.1 m 剑**，而不是一把 8.28 m 长的横棍。也就是说：这一份**不是**绕过尺寸策略的
// 第二条路，它把输入喂回主路。
//
// ## 结论只有三种，而且都不许"猜"
//
//   ① 工作流声明了 `up_axis` / `forward_axis`（回执 `authoritative_size` 里那两个字段）
//      ⇒ 按声明摆正（`workflowDeclared`）。**这是优先级最高、也最干净的一条**。
//   ② 没有声明，但网格自己说话（最长边明显不在 Y 轴上）⇒ 由主轴推断（`inferredPrincipalAxis`）。
//   ③ 都没有 / 推断不出来 ⇒ **保留原样并留下可见说明**（`unresolved` / `alreadyUpright`）。
//
// 第 ③ 条是**刻意的**：把一台咖啡机"硬掰正"比不掰更坏 —— 用户会看到一台凭空躺下的咖啡机，
// 而画面里没有任何东西告诉他这是 app 干的。所以本文件只做两件有证据的事（声明 / 主轴），
// 拿不到证据就原样保留 + 说清楚。
//
// ## ⚠️ 契约边界（真机核实过的限制）
//
// 守护进程契约（`services/gmgn-taskd/src/model.rs`，见
// `docs/plans/2026-10-02-workflow-side-collision-proxy-checklist.md` §2.1）把
// `up_axis` **白名单死在 `+Y` / `-Y`**、`forward_axis` 死在 `±Z` / `±X`，别的字面量一律
// `invalid_authoritative_size`。也就是说：**契约今天根本表达不了"网格躺着"**（它只能说
// "我的 up 是 +X"这句话本身非法）。所以 ① 永远修不了那把剑，② 是必须存在的那条路 ——
// 而 ③ 的存在保证了 ② 拿不到证据时不会瞎掰。

/// 「这件东西的朝向是**怎么定**的」。与 `WorldPropSizeProvenance` 同一个手法：
/// 面板/回执读它，四态一一对应上面那三条路。
public enum WorldPropOrientationSource: String, Codable, Equatable, Sendable {
    /// ① 生成工作流在 `authoritative_size` 里声明的 `up_axis` / `forward_axis`。
    case workflowDeclared = "workflow-declared"
    /// ② 回执没声明，但原始网格的主轴说得清楚（最长边明显不在 Y 轴上）。
    case inferredPrincipalAxis = "inferred-principal-axis"
    /// ③ 网格本来就是立着的（Y 轴就是最长边），无需任何转动，也没有可说的。
    case alreadyUpright = "already-upright"
    /// ③ 无法确定朝向（尺寸不像"躺着生成"）⇒ **保留原样**，`notice` 里说明。
    case unresolved

    /// 面板/回执用的中文说明。
    public var label: String {
        switch self {
        case .workflowDeclared: return "按工作流声明的朝向"
        case .inferredPrincipalAxis: return "按网格主轴摆正"
        case .alreadyUpright: return "网格本来就是立着的"
        case .unresolved: return "朝向无法确定（保留原样）"
        }
    }
}

/// 「把原始网格转正」的旋转 + **出处** + 可读说明。
///
/// `rotation` 作用在**原始网格坐标系**上：世界摆放 = `T(position) · Ry(yaw) · rotation · 归一化`。
/// 归一化（缩放到目标高度、XZ 居中、底面贴承托面）用的是 **`rotation` 之后的**包围盒，
/// 所以"立正"与"多大"共用同一个中间量，不存在第二份朝向。
///
/// 它是**物件级**（跟 `assetID` 走），不是**放置级**：同一件东西在房间里的哪个位置、朝哪边，
/// 仍然是 `WorldObjectState.transform.rotation` 那份 yaw。两者相乘的次数**只有一次**
/// （`ResidentPropPlacementMatrix`），所以不会出现"渲染转了一次、判据转了两次"。
public struct WorldPropOrientation: Codable, Equatable, Sendable {
    /// 把**原始网格**转正的旋转。`unresolved` / `alreadyUpright` 时是单位四元数。
    public let rotation: WorldQuaternion
    public let source: WorldPropOrientationSource
    /// 给用户看的一句话。`nil` = 这件事本来就无需说明（网格本来就立着）。
    public let notice: String?

    public init(rotation: WorldQuaternion, source: WorldPropOrientationSource, notice: String?) {
        self.rotation = rotation
        self.source = source
        self.notice = notice
    }

    public var isIdentity: Bool {
        WorldPropRotation.isIdentity(rotation)
    }

    /// 要不要写进世界状态。
    ///
    /// - 真的转了 ⇒ 要写（渲染/碰撞代理/存档都读它，缺了就转不回来）；
    /// - `unresolved` ⇒ 也要写：它记的是"我们决定不动它"，那是**审计事实**，不是没有信息；
    /// - `alreadyUpright` / 声明即恒等 ⇒ 不写 ⇒ 老资产、绝大多数物件的元数据**逐字节不变**。
    public var shouldArchive: Bool {
        !isIdentity || source == .unresolved
    }

    public var isValid: Bool {
        let values = [rotation.x, rotation.y, rotation.z, rotation.w]
        guard values.allSatisfy(\.isFinite) else { return false }
        let lengthSquared = values.reduce(0) { $0 + $1 * $1 }
        // 单位四元数容差：只用来挡住"坏掉的存档"，不参与任何几何判断。
        return abs(lengthSquared - 1) <= 0.001
    }
}

/// 「原始网格尺寸 + 声明 → 摆正旋转」的**唯一**一份策略。纯函数、无副作用、可离线逐项断言。
public enum WorldPropOrientationPolicy {
    /// 「最长边 / 高度」超过它就算**躺着生成**。与 `WorldPropSizePolicy.longThinAspectLimit`
    /// 是**同一个数**：两处如果在"多细算细长"上分叉，就会出现"尺寸按细长算、朝向却按立着算"
    /// 的自相矛盾。真实数据：能用的两件是 1.348（咖啡机）与 1.265（斧头），坏掉的剑是 7.532。
    public static let lyingDownAspectLimit: Float = WorldPropSizePolicy.longThinAspectLimit

    /// 契约白名单（与 `WorldPropAuthoritativeSize` 的同一批字面量；这里只是**引用**它们，
    /// 不另立一份）。声明越界一律当作"没有声明"，由主轴推断接手 —— 与
    /// `WorldPropAuthoritativeSize.isValid` 的 fail-closed 方向一致。
    static let acceptedUpAxes: Set<String> = Set(WorldPropAuthoritativeSize.acceptedUpAxes)
    static let acceptedForwardAxes: Set<String> = Set(WorldPropAuthoritativeSize.acceptedForwardAxes)

    /// 摆正用的"正面"方向：物件在转正后的局部坐标系里**正面朝 +Z、背面朝 -Z**。
    ///
    /// 为什么是 +Z（而不是契约示例里的 "-Z"）：靠墙摆放的落点由
    /// `WorldPlanarFootprint.center(anchoredAt:spacing:)` 决定 —— 它把 footprint 的**本地最小角**
    /// 放在格子最小角上，于是盒子从锚定列出发沿**本地 +Z** 方向长出去（`Ry(yaw)·ẑ`）。
    /// 贴墙时锚定列就是墙脚那一列，所以"贴着墙的那一面"必然是本地的 **-Z 面** ⇒ 背面 =-Z、
    /// 正面 =+Z 是**判据链本身**定出来的约定，不是随手挑的。
    /// 契约里的 `forward_axis` 被映射到"这个正面"，映射关系只有这一处（`declared(up:forward:)`）。
    public static let canonicalForward = SIMD3<Float>(0, 0, 1)

    /// 由**原始网格**的 AABB 尺寸与回执里声明的两根轴定出摆正旋转。
    ///
    /// - 声明合法 ⇒ 按声明（`workflowDeclared`）；声明非法/缺失 ⇒ 看主轴；
    /// - 主轴说不出话 ⇒ 原样保留 + 可见说明（`unresolved`），**绝不硬掰**。
    public static func resolve(
        sourceExtent: WorldVector3,
        declaredUpAxis: String? = nil,
        declaredForwardAxis: String? = nil
    ) -> WorldPropOrientation {
        let values = [sourceExtent.x, sourceExtent.y, sourceExtent.z]
        guard values.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 100 }) else {
            return WorldPropOrientation(
                rotation: .identity,
                source: .unresolved,
                notice: "网格尺寸无效，朝向保留原样。"
            )
        }
        if let declared = declared(up: declaredUpAxis, forward: declaredForwardAxis) {
            return declared
        }
        return infer(sourceExtent: sourceExtent)
    }

    /// 声明合法时的旋转。返回 nil = "没有可用的声明"（缺失或越界），由主轴推断接手。
    ///
    /// 白名单只有 `±Y` / `±Z,±X`，所以这一条**永远只是一个绕竖轴的旋转**（含 180°）。
    /// 真机那把剑修不了就是因为这里 —— 契约不允许"我的 up 是 +X"。
    static func declared(up: String?, forward: String?) -> WorldPropOrientation? {
        guard let up, let forward,
              acceptedUpAxes.contains(up), acceptedForwardAxes.contains(forward)
        else { return nil }
        // 先把"声明里的 up"转到世界 +Y。
        let upright: WorldQuaternion = up == "+Y" ? .identity : WorldPropRotation.axisAngle(
            axis: SIMD3(1, 0, 0), angle: .pi
        )
        // 再看转正之后"声明里的 forward"落在哪，绕 Y 把它带到 -Z。
        let forwardNow = WorldPropRotation.rotate(
            WorldPropRotation.forwardAxisVector(forward), by: upright
        )
        let yaw = WorldPropRotation.yaw(bringingForwardToCanonical: forwardNow)
        guard yaw.isFinite else {
            return WorldPropOrientation(
                rotation: .identity,
                source: .unresolved,
                notice: "工作流声明的朝向读不出角度，朝向保留原样。"
            )
        }
        // 先转正、再绕世界 Y 对齐正面（矩阵写法是 `Ry(yaw) · upright`）：
        // `multiply(lhs, rhs)` 的语义是"先 lhs 后 rhs"（见 `WorldPropRotation.multiply` 的断言），
        // 所以这里先 upright、再 Ry(yaw)。顺序写反时 `up = +Y` 的那些用例看不出来
        // （upright 是单位四元数），只有 `up = -Y` 会差 180° —— 这一条有断言钉着。
        let rotation = WorldPropRotation.multiply(
            upright, WorldPropRotation.axisAngle(axis: SIMD3(0, 1, 0), angle: yaw)
        )
        let notice = WorldPropRotation.isIdentity(rotation)
            ? "工作流声明 up_axis=\(up)、forward_axis=\(forward)，网格本来就是立着的。"
            : "已按工作流声明的 up_axis=\(up)、forward_axis=\(forward) 摆正。"
        return WorldPropOrientation(rotation: rotation, source: .workflowDeclared, notice: notice)
    }

    /// ② 由网格自身的主轴推断；③ 说不清就原样保留 + 说明。
    static func infer(sourceExtent: WorldVector3) -> WorldPropOrientation {
        let horizontal = max(sourceExtent.x, sourceExtent.z)
        // 已经是立着的：Y 就是最长边。无需转动，也无需解释（绝大多数物件走这条）。
        if sourceExtent.y >= horizontal {
            return WorldPropOrientation(rotation: .identity, source: .alreadyUpright, notice: nil)
        }
        let aspect = horizontal / sourceExtent.y
        guard aspect > lyingDownAspectLimit else {
            // **不瞎掰**：扁/方的东西（地毯、盘子、矮柜）横着可能就是它本来的样子。
            return WorldPropOrientation(
                rotation: .identity,
                source: .unresolved,
                notice: String(
                    format: "朝向无法确定（最长水平边 %.2f m / 高度 %.2f m = %.2f ≤ %.0f，不像躺着生成），保留原始朝向。",
                    horizontal, sourceExtent.y, aspect, lyingDownAspectLimit
                )
            )
        }
        // 躺着：把最长的那根**水平**轴立起来当高度。剩下的那根水平轴朝向无法从 AABB 判定，
        // 所以说明里如实写出来，而不是假装知道。
        let lyingAxis: String
        let rotation: WorldQuaternion
        if sourceExtent.x >= sourceExtent.z {
            lyingAxis = "X"
            rotation = WorldPropRotation.axisAngle(axis: SIMD3(0, 0, 1), angle: .pi / 2)
        } else {
            lyingAxis = "Z"
            rotation = WorldPropRotation.axisAngle(axis: SIMD3(1, 0, 0), angle: -.pi / 2)
        }
        let longest = max(sourceExtent.x, sourceExtent.z)
        return WorldPropOrientation(
            rotation: rotation,
            source: .inferredPrincipalAxis,
            notice: String(
                format: "网格最长边在 %@ 轴（%.2f m）、高度只有 %.2f m（比值 %.2f > %.0f）⇒ 判定为躺着生成，已摆正；绕竖轴的朝向无法从网格判定。",
                lyingAxis, longest, sourceExtent.y, aspect, lyingDownAspectLimit
            )
        )
    }

    /// 原始 AABB 经过摆正旋转之后的 AABB（= 判据/尺寸/渲染共用的那一份）。
    ///
    /// 用**八个角**精确求，而不是"交换分量"：声明里的 forward 对齐是一个任意角度的 yaw，
    /// 交换分量只在 90° 的整数倍下才对。恒等旋转时逐位返回原值。
    public static func orientedBounds(
        minimum: SIMD3<Float>,
        maximum: SIMD3<Float>,
        by orientation: WorldPropOrientation
    ) -> (minimum: SIMD3<Float>, maximum: SIMD3<Float>) {
        orientedBounds(minimum: minimum, maximum: maximum, rotation: orientation.rotation)
    }

    /// 同上，只吃四元数：渲染矩阵/碰撞代理手上只有旋转这一份数据，不该为了调它去合成一个
    /// `WorldPropOrientation`（那会造出一个假的"出处"）。
    public static func orientedBounds(
        minimum: SIMD3<Float>,
        maximum: SIMD3<Float>,
        rotation: WorldQuaternion
    ) -> (minimum: SIMD3<Float>, maximum: SIMD3<Float>) {
        guard !WorldPropRotation.isIdentity(rotation) else { return (minimum, maximum) }
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for x in [minimum.x, maximum.x] {
            for y in [minimum.y, maximum.y] {
                for z in [minimum.z, maximum.z] {
                    let rotated = WorldPropRotation.rotate(SIMD3(x, y, z), by: rotation)
                    low = SIMD3(Swift.min(low.x, rotated.x), Swift.min(low.y, rotated.y), Swift.min(low.z, rotated.z))
                    high = SIMD3(Swift.max(high.x, rotated.x), Swift.max(high.y, rotated.y), Swift.max(high.z, rotated.z))
                }
            }
        }
        return (low, high)
    }

    /// AABB **尺寸**经过摆正旋转之后的那一份（`orientedBounds` 的差）。
    public static func orientedExtent(
        of extent: WorldVector3,
        by orientation: WorldPropOrientation
    ) -> WorldVector3 {
        guard !orientation.isIdentity else { return extent }
        // 以原点为中心的盒子：角点就是 ±extent/2，尺寸即差值。
        let half = SIMD3(extent.x / 2, extent.y / 2, extent.z / 2)
        let bounds = orientedBounds(
            minimum: -half, maximum: half, by: orientation
        )
        return WorldVector3(
            x: bounds.maximum.x - bounds.minimum.x,
            y: bounds.maximum.y - bounds.minimum.y,
            z: bounds.maximum.z - bounds.minimum.z
        )
    }
}

public extension WorldQuaternion {
    static let identity = WorldQuaternion(x: 0, y: 0, z: 0, w: 1)
}

/// 四元数算术的**唯一**一份小工具（本文件私有语义，公开只为让判据与渲染共用一个实现）。
///
/// 为什么不塞进 `WorldGeometry`：那里是**世界契约类型**（与守护进程逐字对齐的数据形状），
/// 加算术会让"数据形状"与"怎么转"混在一起。这里只做几何，不新增任何世界类型。
public enum WorldPropRotation {
    public static func axisAngle(axis: SIMD3<Float>, angle: Float) -> WorldQuaternion {
        let lengthSquared = axis.x * axis.x + axis.y * axis.y + axis.z * axis.z
        guard lengthSquared.isFinite, lengthSquared > 0.0000001, angle.isFinite else { return .identity }
        let inverse = 1 / lengthSquared.squareRoot()
        let half = angle / 2
        let sine = sin(half)
        return WorldQuaternion(
            x: axis.x * inverse * sine,
            y: axis.y * inverse * sine,
            z: axis.z * inverse * sine,
            w: cos(half)
        )
    }

    /// `lhs` 之后再作用 `rhs`（即 `rhs · lhs` 的矩阵语义：先 lhs 后 rhs）。
    public static func multiply(_ lhs: WorldQuaternion, _ rhs: WorldQuaternion) -> WorldQuaternion {
        WorldQuaternion(
            x: rhs.w * lhs.x + rhs.x * lhs.w + rhs.y * lhs.z - rhs.z * lhs.y,
            y: rhs.w * lhs.y - rhs.x * lhs.z + rhs.y * lhs.w + rhs.z * lhs.x,
            z: rhs.w * lhs.z + rhs.x * lhs.y - rhs.y * lhs.x + rhs.z * lhs.w,
            w: rhs.w * lhs.w - rhs.x * lhs.x - rhs.y * lhs.y - rhs.z * lhs.z
        )
    }

    public static func isIdentity(_ q: WorldQuaternion) -> Bool {
        let values = [q.x, q.y, q.z, q.w]
        guard values.allSatisfy(\.isFinite) else { return false }
        let lengthSquared = values.reduce(0) { $0 + $1 * $1 }
        guard lengthSquared > 0.000001 else { return false }
        // q 与 -q 是同一个旋转，两个符号都算恒等。
        let sign: Float = q.w < 0 ? -1 : 1
        return abs(sign * q.x) < 0.0001 && abs(sign * q.y) < 0.0001
            && abs(sign * q.z) < 0.0001 && abs(sign * q.w) > 0.9999
    }

    public static func rotate(_ vector: SIMD3<Float>, by q: WorldQuaternion) -> SIMD3<Float> {
        let values = [q.x, q.y, q.z, q.w]
        guard values.allSatisfy(\.isFinite) else { return vector }
        let lengthSquared = values.reduce(0) { $0 + $1 * $1 }
        guard lengthSquared > 0.000001 else { return vector }
        let inverse = 1 / lengthSquared.squareRoot()
        let x = q.x * inverse, y = q.y * inverse, z = q.z * inverse, w = q.w * inverse
        // v' = v + 2 * cross(q.xyz, cross(q.xyz, v) + w * v)
        let u = SIMD3(x, y, z)
        let uv = SIMD3(
            u.y * vector.z - u.z * vector.y,
            u.z * vector.x - u.x * vector.z,
            u.x * vector.y - u.y * vector.x
        )
        let uuv = SIMD3(
            u.y * uv.z - u.z * uv.y,
            u.z * uv.x - u.x * uv.z,
            u.x * uv.y - u.y * uv.x
        )
        return vector + 2 * (uv * w + uuv)
    }

    /// 契约里那四个 forward 字面量 → 单位向量（`-Z` 是"正面"）。
    static func forwardAxisVector(_ literal: String) -> SIMD3<Float> {
        switch literal {
        case "+X": return SIMD3(1, 0, 0)
        case "-X": return SIMD3(-1, 0, 0)
        case "+Z": return SIMD3(0, 0, 1)
        default: return SIMD3(0, 0, -1)
        }
    }

    /// 绕世界 Y 的 yaw，把 `forward` 转到 `WorldPropOrientationPolicy.canonicalForward`（+Z）。
    ///
    /// 只取水平投影：竖直分量交给 up 轴（`up_axis` 那一步已经处理过）。
    static func yaw(bringingForwardToCanonical forward: SIMD3<Float>) -> Float {
        let length = (forward.x * forward.x + forward.z * forward.z).squareRoot()
        guard length > 0.0001, forward.x.isFinite, forward.z.isFinite else { return .nan }
        // 令 alpha = atan2(fz, fx)：`Ry(θ)·(fx, fz)` 的两个分量是
        //   r·cos(alpha - θ), r·sin(alpha - θ)
        // 要它等于 (0, 1) ⇒ alpha - θ = π/2 ⇒ θ = alpha - π/2。
        // （`ResidentPropPlacementMatrix` 的 Ry 与本文件的四元数同一个右手系：
        //   Ry(θ)·x̂ = (cos θ, 0, -sin θ)。代入验证：f=+Z ⇒ yaw=0，f=+X ⇒ yaw=-π/2。）
        return atan2(forward.z, forward.x) - .pi / 2
    }
}

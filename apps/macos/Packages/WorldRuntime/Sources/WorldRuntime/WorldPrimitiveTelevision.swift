import CryptoKit
import Foundation

/// **已停用（2026-10-02）**：原因 —— 用户要求物件一律来自素材生成（图 → 3D），
/// 不再由我们手拼一个固定造型。**产品路径零调用**；类型与判据保留，只为本文件自身的
/// 离线断言、以及历史存档 metadata（`WorldGeneratedProp.primitive`）读得回来。
///
/// 一台**由基础几何拼出来**的平面电视：扁平面板 + 边框 + 底座。
///
/// ## 为什么要它（真机 2026-10-01「平面电视」）
///
/// 用户发了一张平面电视的产品图，并给了完整规格 `1443 x 862 x 302 mm`。生成器交回来的
/// 是**一个大立方体**（参考图被贴在各面上）。这不是"参数没调好"，而是两件事同时发生：
///
/// 1. 契约只能表达"一根轴 + 一个米数"（见 `WorldPropSizeMillimeters` 的注释）；
/// 2. 电视这种**规格确定**的物件本来就不该指望生成器 —— 它的形状是"一个扁平面板 + 一圈
///    边框 + 一个底座"，是**基础几何**，按三轴数字直接拼出来就是对的，而且屏幕面天生
///    就是那个大平面。
///
/// ## 它是一个**正常物件**
///
/// 产出的几何与资产走的是生成道具**同一条路**，不另造存储：
///
/// - `size` 就是 `WorldGeneratedProp.size`（同一个类型、同一个语义），于是摆放判定、承托、
///   手持、挂点、碰撞盒读到的都是它；
/// - 资产是**内容寻址**的 GLB 字节（`assetID == "sha256:" + sha256(assetBytes)`），
///   与生成产物同一个引用形式；
/// - 局部包围盒约定与生成道具完全一致：`x`/`z` 以落地点为中心、`y` 从 0 到 `size.y`
///   （见 `WorldScreenFace.quad` 的注释）。
///
/// ## 屏幕几何推断不会失败
///
/// app 侧 `WorldScreenResolution` 的两条推断判据都可以在这里**预先算出来**
/// （`thinnestToLongestRatio` / `largestFaceAreaSquareMeters` / `screen`）：
/// 整体包围盒是"板形"（最薄轴 / 最长轴 = 302/1443 ≈ 0.21 ≤ 0.25），最大平坦面就是
/// **正面**（宽 × 高 = 1.443 × 0.862 ≈ 1.24 m² ≥ 0.04），而面板的前表面正好落在
/// `z = size.z / 2` —— 与 `.front` 那一面推断出的四边形**同一个平面**。
public struct WorldPrimitiveTelevision: Equatable, Sendable {
    /// 一块基础几何（轴对齐盒）。局部坐标，单位米。
    public struct Part: Equatable, Sendable {
        public enum Role: String, Equatable, Sendable, CaseIterable {
            /// 屏幕面板：**那块大平面**，屏幕就长在它的前表面上。
            case panel
            /// 边框（上下左右四根）。
            case bezel
            /// 底座立柱。
            case standNeck
            /// 底座底板：它决定整体进深（用户给的第三个数是它）。
            case standBase
        }

        public let role: Role
        public let name: String
        public let center: WorldVector3
        public let size: WorldVector3

        /// 这一块零件在画面里的**外观**（颜色 / 金属度 / 粗糙度）。
        ///
        /// 派生自 `role`，不新增输入：**盒子数量与尺寸判据一个字都没变**，变的只是
        /// "这一块涂成什么颜色"（见 `WorldPrimitiveTelevisionFinish`）。这一份也是
        /// GLB 里 `materials` 的唯一来源 —— 写字节的那一处不再自己挑颜色。
        public var finish: WorldPrimitiveTelevisionFinish {
            switch role {
            case .panel: return .screen
            case .bezel: return .body
            case .standNeck, .standBase: return .stand
            }
        }

        public var minimum: WorldVector3 {
            WorldVector3(x: center.x - size.x / 2, y: center.y - size.y / 2, z: center.z - size.z / 2)
        }
        public var maximum: WorldVector3 {
            WorldVector3(x: center.x + size.x / 2, y: center.y + size.y / 2, z: center.z + size.z / 2)
        }
        public init(role: Role, name: String, center: WorldVector3, size: WorldVector3) {
            self.role = role; self.name = name; self.center = center; self.size = size
        }
    }

    /// 屏幕那一面（最大平坦面）。法向恒为 `+Z`（本仓正面），位置与 `.front` 推断同口径。
    public struct ScreenPanel: Equatable, Sendable {
        public let center: WorldVector3
        public let width: Float
        public let height: Float
        /// 屏幕面外法向。只有 `+Z` 一种：这台电视是"面板朝前"拼出来的。
        public let normal: WorldVector3
        public var areaSquareMeters: Float { width * height }
        public init(center: WorldVector3, width: Float, height: Float) {
            self.center = center; self.width = width; self.height = height
            self.normal = WorldVector3(x: 0, y: 0, z: 1)
        }
    }

    /// 拼不出来时的**具名**原因（绝不静默给一台尺寸不对的电视）。
    public enum BuildError: Error, Equatable, Sendable {
        /// 三轴不在 `10–3000 mm`，或某根轴非正有限数。
        case invalidMillimeters
        /// 三轴合法但拼出来的零件退化了（例如高度被底座与边框吃光）。
        case degenerateParts
    }

    /// 渲染/资产里标识"这台电视是基础几何拼的"的那一个名字。
    public static let rendererName = "primitive-television-v1"
    public static let defaultDisplayName = "平面电视"

    public let millimeters: WorldPropSizeMillimeters
    public let displayName: String
    public let parts: [Part]
    /// 整体包围盒尺寸（米）。**与用户给的三轴逐位对齐**：`x` 宽、`y` 高、`z` 深。
    public let size: WorldVector3
    /// 整体包围盒最小角（局部坐标）：`x`/`z` 居中、`y == 0`。
    public let minimum: WorldVector3
    public let screen: ScreenPanel
    /// 面板（含边框那一层）的厚度，米。用户要纠正"302 到底是厚度还是底座进深"时看这个数。
    public let panelThicknessMeters: Float
    /// 内容寻址的资产字节（真实可解码的 glTF 2.0 二进制 `.glb`）。
    public let assetBytes: Data
    /// 资产的**内容寻址**引用，形式与生成产物一致：`sha256:<hex>`。
    public let assetID: String

    /// 底座进深（米）—— 与整体进深**同一个数**：用户给的 302 mm 是它，不是面板厚度。
    public var standDepthMeters: Float { size.z }
    /// 最薄轴 / 最长轴。app 侧 `WorldScreenResolution.maximumPanelThicknessRatio` 吃这个数。
    public var thinnestToLongestRatio: Float {
        let longest = WorldPropSizePolicy.longestEdge(of: size)
        guard longest > 0 else { return .infinity }
        return min(size.x, min(size.y, size.z)) / longest
    }
    /// 最大平坦面的面积（m²）。app 侧 `WorldScreenResolution.minimumFaceArea` 吃这个数。
    public var largestFaceAreaSquareMeters: Float {
        max(size.x * size.y, max(size.z * size.y, size.x * size.z))
    }
    /// 用户原话的三轴（毫米）与场景里的实际尺寸（米）放在一起，给面板逐位核对。
    public var dimensionsSummary: String {
        let expected = millimeters.edges
            .map { $0 == $0.rounded() ? String(Int($0)) : String($0) }
            .joined(separator: " × ")
        let actual = "\(metersText(size.x)) × \(metersText(size.y)) × \(metersText(size.z))"
        let depth = metersText(standDepthMeters)
        let thickness = metersText(panelThicknessMeters)
        return "\(displayName)：你说的 \(expected) 毫米 ⇒ 场景里 \(actual) 米（宽 × 高 × 深）。"
            + "整体进深 \(depth) 米 = 你说的第三个数（**底座进深**）；"
            + "面板厚度 \(thickness) 米是拼出来的。"
    }

    public init(millimeters: WorldPropSizeMillimeters,
                displayName: String = WorldPrimitiveTelevision.defaultDisplayName) throws {
        guard millimeters.isValid else { throw BuildError.invalidMillimeters }
        guard let parts = Self.parts(for: millimeters) else { throw BuildError.degenerateParts }
        let width = millimeters.x / 1000
        let height = millimeters.y / 1000
        let depth = millimeters.z / 1000
        let thickness = Self.panelThickness(depth: depth)
        let panel = parts.first { $0.role == .panel } ?? parts[0]

        self.millimeters = millimeters
        self.displayName = displayName
        self.parts = parts
        // 整体包围盒由零件**算出来**，不是另抄一份三轴：抄一份就会有两个真相。
        let minimum = WorldVector3(
            x: parts.map(\.minimum.x).min() ?? 0,
            y: parts.map(\.minimum.y).min() ?? 0,
            z: parts.map(\.minimum.z).min() ?? 0
        )
        let maximum = WorldVector3(
            x: parts.map(\.maximum.x).max() ?? 0,
            y: parts.map(\.maximum.y).max() ?? 0,
            z: parts.map(\.maximum.z).max() ?? 0
        )
        self.minimum = minimum
        self.size = WorldVector3(
            x: maximum.x - minimum.x,
            y: maximum.y - minimum.y,
            z: maximum.z - minimum.z
        )
        self.panelThicknessMeters = thickness
        // 屏幕面：宽度/高度取**面板**那一块，中心的前表面落在整体正面（z = size.z / 2）——
        // 与 `WorldScreenFace.front.quad` 的约定同一个平面。
        self.screen = ScreenPanel(
            center: WorldVector3(x: panel.center.x, y: panel.center.y, z: maximum.z),
            width: panel.size.x,
            height: panel.size.y
        )
        let bytes = PrimitiveGLBWriter.encode(parts: parts)
        self.assetBytes = bytes
        let digest = SHA256.hash(data: bytes)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        self.assetID = "sha256:" + hex

        // 自检（构造即证明）：包围盒必须**逐位**等于用户给的三轴，否则这台电视是错的，
        // 而错的电视比没有电视更糟（用户会以为"它照做了"）。
        let widthMatches = abs(self.size.x - width) <= 1e-5
        let heightMatches = abs(self.size.y - height) <= 1e-5
        let depthMatches = abs(self.size.z - depth) <= 1e-5
        let sitsOnFloor = abs(minimum.y) <= 1e-5
        guard widthMatches, heightMatches, depthMatches, sitsOnFloor,
              self.screen.areaSquareMeters > 0 else {
            throw BuildError.degenerateParts
        }
    }

    /// 这台电视在权威里的**正常物件**记录：与生成产物**同一个类型**，于是摆放/手持/挂点/
    /// 屏幕推断读的都是同一份 `size`，不另造存储。
    ///
    /// `sizeLocked = true`：三轴是**定死的**（拼出来的几何就是它），不许被"自动基线"重算覆盖。
    /// `sizeIntent` 留空是**有意的**：意图回答的是"这个尺寸是从哪一句话推出来的"，
    /// 而这里的尺寸不是推的，是拼的 —— 由 `dimensionsSummary` 如实说给用户听。
    public func generatedProp(objectID: String, sourceWishID: String) -> WorldGeneratedProp {
        WorldGeneratedProp(
            objectID: objectID,
            sourceWishID: sourceWishID,
            assetID: assetID,
            displayName: displayName,
            size: size,
            sourceHeight: size.y,
            sizeLocked: true,
            // 三根轴**连同那句解释**一起落进世界状态的 metadata：面板要能逐位回读
            // 「你说的 1443 × 862 × 302 毫米 ⇒ 场景里 1.443 × 0.862 × 0.302 米」，
            // 以及「z 是底座进深、面板厚度是拼出来的」—— 后者是 `panelThickness(depth:)`
            // 派生的，只有拼几何的这一处说得准，存下来就没有第二份算法。
            primitive: record
        )
    }

    /// 这台电视在**世界状态 metadata** 里的可回读记录（见 `WorldGeneratedProp.primitive`）。
    public var record: WorldPrimitiveTelevisionRecord {
        WorldPrimitiveTelevisionRecord(
            renderer: Self.rendererName,
            millimeters: millimeters,
            sizeMeters: size,
            panelThicknessMeters: panelThicknessMeters,
            standDepthMeters: standDepthMeters,
            summary: dimensionsSummary
        )
    }

    // MARK: - 几何：三轴 → 零件

    /// 面板（含边框那一层）的厚度。派生而不是硬编码：深的那一维要是很薄，面板也必须更薄。
    static func panelThickness(depth: Float) -> Float { min(0.04, depth * 0.2) }

    /// 三轴 → 七块基础几何。**失败返回 nil**（尺寸退化时绝不硬拼一台错的）。
    ///
    /// 布局（局部坐标；`x`/`z` 居中、`y` 从 0 到 `height`）：
    ///
    /// ```text
    ///        +-------------------+  y = height
    ///        |  bezel.top        |
    ///        | +---------------+ |
    ///        | |               | |   panel = 屏幕（前表面在 z = +depth/2）
    ///        | |    panel      | |
    ///        | +---------------+ |
    ///        |  bezel.bottom     |
    ///   ---- +---------+---------+  y = standTop
    ///             | neck |            ← 立柱的**前表面**顶在面板的背面上（不悬在空气里）
    ///   ========= +------+ =========  stand.base（进深 = depth）
    /// ```
    ///
    /// 「每块零件长什么样」不在这里：那是 `Part.finish` →
    /// `WorldPrimitiveTelevisionFinish`，本函数产生的**块数、位置、尺寸**全部照旧。
    static func parts(for millimeters: WorldPropSizeMillimeters) -> [Part]? {
        let width = millimeters.x / 1000
        let height = millimeters.y / 1000
        let depth = millimeters.z / 1000
        let thickness = panelThickness(depth: depth)
        let baseThickness = min(0.02, height * 0.05)
        let neckHeight = min(0.09, height * 0.15)
        let panelBottom = baseThickness + neckHeight
        let panelHeight = height - panelBottom
        let bezelWidth = min(0.012, min(width, height) * 0.02)
        let baseWidth = min(width * 0.45, 0.8)
        let neckWidth = min(max(width * 0.06, 0.02), width)
        let neckDepth = min(max(depth * 0.2, 0.02), depth)

        guard width > 0, height > 0, depth > 0,
              baseThickness > 0, baseThickness < height,
              neckHeight > 0, neckWidth > 0, neckDepth > 0,
              panelHeight > 0, panelHeight - 2 * bezelWidth > 0, width - 2 * bezelWidth > 0,
              thickness > 0, thickness < depth
        else { return nil }

        // 正面（前表面）就在 z = +depth/2：屏幕面与整体正面同平面。
        let slabCenterZ = depth / 2 - thickness / 2
        let panelCenterY = panelBottom + panelHeight / 2
        // 立柱的**前表面**必须顶到面板的**背面**（`panel.min.z`）。不顶上去，立柱就悬在
        // 面板后面 `0.081 m` 的空气里：面板看着像"支在半个底座前面的斜板"，那正是真机
        // 2026-10-02 那句「歪着/后仰」的观感来源（姿态数据本身是正的，见文件头）。
        //
        // 上下夹一层只是**防御**：立柱永远不许越过底板的前后沿。越过了，整体进深就不再是
        // 用户给的第三个数。所以这一步**不产生任何尺寸**，只是在已有尺寸里挑一个 z。
        let panelBackZ = slabCenterZ - thickness / 2
        let lowestNeckCenterZ = -depth / 2 + neckDepth / 2
        let highestNeckCenterZ = depth / 2 - neckDepth / 2
        let neckCenterZ = min(
            max(panelBackZ - neckDepth / 2, lowestNeckCenterZ), highestNeckCenterZ
        )
        return [
            Part(role: .standBase, name: "stand.base",
                 center: WorldVector3(x: 0, y: baseThickness / 2, z: 0),
                 size: WorldVector3(x: baseWidth, y: baseThickness, z: depth)),
            Part(role: .standNeck, name: "stand.neck",
                 center: WorldVector3(x: 0, y: baseThickness + neckHeight / 2, z: neckCenterZ),
                 size: WorldVector3(x: neckWidth, y: neckHeight, z: neckDepth)),
            Part(role: .bezel, name: "bezel.top",
                 center: WorldVector3(x: 0, y: height - bezelWidth / 2, z: slabCenterZ),
                 size: WorldVector3(x: width, y: bezelWidth, z: thickness)),
            Part(role: .bezel, name: "bezel.bottom",
                 center: WorldVector3(x: 0, y: panelBottom + bezelWidth / 2, z: slabCenterZ),
                 size: WorldVector3(x: width, y: bezelWidth, z: thickness)),
            Part(role: .bezel, name: "bezel.left",
                 center: WorldVector3(x: -(width / 2 - bezelWidth / 2), y: panelCenterY, z: slabCenterZ),
                 size: WorldVector3(x: bezelWidth, y: panelHeight - 2 * bezelWidth, z: thickness)),
            Part(role: .bezel, name: "bezel.right",
                 center: WorldVector3(x: width / 2 - bezelWidth / 2, y: panelCenterY, z: slabCenterZ),
                 size: WorldVector3(x: bezelWidth, y: panelHeight - 2 * bezelWidth, z: thickness)),
            Part(role: .panel, name: "panel.screen",
                 center: WorldVector3(x: 0, y: panelCenterY, z: slabCenterZ),
                 size: WorldVector3(x: width - 2 * bezelWidth, y: panelHeight - 2 * bezelWidth,
                                    z: thickness)),
        ]
    }

    private func metersText(_ value: Float) -> String { String(format: "%.3f", value) }
}

/// 一台**基础几何**电视在世界状态 metadata 里的可回读记录（`WorldGeneratedProp.primitive`）。
///
/// 为什么要有它、而不是只存三个毫米数：
///
/// - 「用户说的三个数」与「场景里的三个数」必须**逐位**放在一起（`1443 × 862 × 302 毫米`
///   ⇒ `1.443 × 0.862 × 0.302 米`），用户才能一眼看出"它到底照做了没有"；
/// - 「**z 被解释成底座进深、面板厚度是拼出来的**」这句话只有在拼几何的那一处才说得准
///   （厚度是 `WorldPrimitiveTelevision.panelThickness(depth:)` 派生的）。存下这句原文，
///   面板与回执就都读它 —— 换一个地方再算一遍厚度就是第二份真相。
///
/// 可选、纯增量：为 nil 时合成 `Codable` 不会编码这个键（`encodeIfPresent`），于是
/// 不是基础几何拼出来的物件（绝大多数）其元数据 JSON 与改造前逐字节相同。
public struct WorldPrimitiveTelevisionRecord: Codable, Equatable, Sendable {
    /// 拼出这件几何的那份渲染器名（`WorldPrimitiveTelevision.rendererName`）。
    public let renderer: String
    /// 用户原话的三个毫米数（宽 × 高 × 深，单位在键名上）。
    public let millimeters: WorldPropSizeMillimeters
    /// 场景里的实际尺寸（米）。**逐位**是 `millimeters` 的 1/1000。
    public let sizeMeters: WorldVector3
    /// 面板（含边框那一层）的厚度，米。用户要纠正"302 到底是厚度还是进深"时看这个数。
    public let panelThicknessMeters: Float
    /// 整体进深，米 —— 与用户给的第三个数**同一个数**（底座进深）。
    public let standDepthMeters: Float
    /// 逐位回读那一句（原文来自 `WorldPrimitiveTelevision.dimensionsSummary`）。
    public let summary: String

    public init(renderer: String, millimeters: WorldPropSizeMillimeters, sizeMeters: WorldVector3,
                panelThicknessMeters: Float, standDepthMeters: Float, summary: String) {
        self.renderer = renderer; self.millimeters = millimeters; self.sizeMeters = sizeMeters
        self.panelThicknessMeters = panelThicknessMeters; self.standDepthMeters = standDepthMeters
        self.summary = summary
    }

    /// 存在时**必须**合法：一份坏记录不能被当成"没有记录"（那样面板会退回"最长边"那一行，
    /// 而用户明明给过三轴 —— 那正是 fail-open）。
    public var isValid: Bool {
        renderer == WorldPrimitiveTelevision.rendererName
            && millimeters.isValid
            && WorldPropSizePolicy.isFinite(sizeMeters)
            && sizeMeters.x > 0 && sizeMeters.y > 0 && sizeMeters.z > 0
            && panelThicknessMeters.isFinite && panelThicknessMeters > 0
            && standDepthMeters.isFinite && standDepthMeters > 0
            && !summary.isEmpty && summary.count <= 512
    }
}

// MARK: - 资产字节：把零件拼成一个真实的 glTF 2.0 二进制

/// 极简 glTF 2.0 `.glb` 写入器：一块 mesh（所有盒子合并成一份三角形表）、一个节点，
/// 外加**每个部件一份材质**（`materials` + 每个 primitive 的 `material` 索引）。
///
/// 为什么盒子仍合并成**一块 mesh、一个节点**：资产只需要"能解码、包围盒对、面是平的"。
/// 零件的**结构**（哪块是面板、哪块是底座）由 `WorldPrimitiveTelevision.parts` 承载，
/// 那是审计与面板读的地方；在 GLB 里再存一份就是第二个真相。
///
/// 为什么现在**要**写材质（真机 2026-10-02「什么玩意儿」）：一个 `materials` 都不写，
/// 七块盒子就全都落回渲染器的缺省材质（白 + 全金属 + 全粗糙），在中性灰环境光下呈现为
/// **一整块灰板** —— 边框、屏幕、底座一个都分不出来。材质是**外观**，不是判据：
/// 盒子的数量、位置、尺寸与三角形一个都没动（`parts` 是唯一来源），屏幕推断那条路
/// 读的是 `size`，与这里无关。
///
/// 分组是**确定性**的：按 `WorldPrimitiveTelevisionFinish.allCases` 的顺序，只留这台电视
/// 真的有零件的那些 finish。于是同样的三轴永远得到同样的字节、同样的 `sha256:` 引用
/// （`JSONSerialization` 的 `sortedKeys`、无时间戳、无随机数）。内容寻址要求这一点。
enum PrimitiveGLBWriter {
    /// 一个 finish 一组：盒子 + 这一组的三角形表。
    private struct Group {
        let finish: WorldPrimitiveTelevisionFinish
        var positions: [Float] = []
        var indices: [UInt32] = []
    }

    static func encode(parts: [WorldPrimitiveTelevision.Part]) -> Data {
        // 分组：finish 的顺序取自 `allCases`（与 `parts` 的排列无关 ⇒ 确定性）。
        var groups: [Group] = []
        for finish in WorldPrimitiveTelevisionFinish.allCases {
            let members = parts.filter { $0.finish == finish }
            guard !members.isEmpty else { continue }
            var group = Group(finish: finish)
            for part in members {
                let base = UInt32(group.positions.count / 3)
                let minimum = part.minimum
                let maximum = part.maximum
                let corners: [WorldVector3] = [
                    WorldVector3(x: minimum.x, y: minimum.y, z: minimum.z),
                    WorldVector3(x: maximum.x, y: minimum.y, z: minimum.z),
                    WorldVector3(x: maximum.x, y: maximum.y, z: minimum.z),
                    WorldVector3(x: minimum.x, y: maximum.y, z: minimum.z),
                    WorldVector3(x: minimum.x, y: minimum.y, z: maximum.z),
                    WorldVector3(x: maximum.x, y: minimum.y, z: maximum.z),
                    WorldVector3(x: maximum.x, y: maximum.y, z: maximum.z),
                    WorldVector3(x: minimum.x, y: maximum.y, z: maximum.z),
                ]
                for corner in corners {
                    group.positions.append(corner.x)
                    group.positions.append(corner.y)
                    group.positions.append(corner.z)
                }
                // glTF 的正面是逆时针；每个盒子 6 个面 × 2 个三角形。
                for face in [
                    [0, 2, 1, 0, 3, 2], // -Z
                    [4, 5, 6, 4, 6, 7], // +Z（屏幕那一面朝这里）
                    [0, 1, 5, 0, 5, 4], // -Y
                    [3, 7, 6, 3, 6, 2], // +Y
                    [0, 4, 7, 0, 7, 3], // -X
                    [1, 2, 6, 1, 6, 5], // +X
                ] {
                    group.indices.append(contentsOf: face.map { base + UInt32($0) })
                }
            }
            groups.append(group)
        }

        // 二进制：一组一段（顶点表 + 索引表）。两段都是 4 的整数倍（VEC3 float / UInt32），
        // 所以顺序摆放天然满足 glTF 的对齐要求，不需要补零。
        var binary = Data()
        var accessors: [[String: Any]] = []
        var bufferViews: [[String: Any]] = []
        var primitives: [[String: Any]] = []
        var materials: [[String: Any]] = []
        for group in groups {
            let positionBytes = group.positions.withUnsafeBufferPointer { Data(buffer: $0) }
            let indexBytes = group.indices.withUnsafeBufferPointer { Data(buffer: $0) }
            let positionView = bufferViews.count
            let indexView = positionView + 1
            let positionAccessor = accessors.count
            let indexAccessor = positionAccessor + 1
            let positionOffset = binary.count
            binary.append(positionBytes)
            let indexOffset = binary.count
            binary.append(indexBytes)

            let xs = stride(from: 0, to: group.positions.count, by: 3).map { group.positions[$0] }
            let ys = stride(from: 1, to: group.positions.count, by: 3).map { group.positions[$0] }
            let zs = stride(from: 2, to: group.positions.count, by: 3).map { group.positions[$0] }
            bufferViews.append([
                "buffer": 0, "byteOffset": positionOffset,
                "byteLength": positionBytes.count, "target": 34962,
            ])
            bufferViews.append([
                "buffer": 0, "byteOffset": indexOffset,
                "byteLength": indexBytes.count, "target": 34963,
            ])
            accessors.append([
                "bufferView": positionView, "componentType": 5126,
                "count": group.positions.count / 3, "type": "VEC3",
                "min": [xs.min() ?? 0, ys.min() ?? 0, zs.min() ?? 0],
                "max": [xs.max() ?? 0, ys.max() ?? 0, zs.max() ?? 0],
            ])
            accessors.append([
                "bufferView": indexView, "componentType": 5125,
                "count": group.indices.count, "type": "SCALAR",
            ])
            let color = group.finish.baseColor
            materials.append([
                "name": group.finish.name,
                "pbrMetallicRoughness": [
                    "baseColorFactor": [color.x, color.y, color.z, color.w],
                    "metallicFactor": group.finish.metallic,
                    "roughnessFactor": group.finish.roughness,
                ],
                "doubleSided": false,
            ])
            primitives.append([
                "attributes": ["POSITION": positionAccessor],
                "indices": indexAccessor, "mode": 4, "material": materials.count - 1,
            ])
        }

        let document: [String: Any] = [
            "asset": ["version": "2.0", "generator": WorldPrimitiveTelevision.rendererName],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": [["mesh": 0, "name": WorldPrimitiveTelevision.rendererName]],
            "meshes": [[
                "name": WorldPrimitiveTelevision.rendererName,
                "primitives": primitives,
            ]],
            "materials": materials,
            "accessors": accessors,
            "bufferViews": bufferViews,
            "buffers": [["byteLength": binary.count]],
        ]
        var json = (try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]))
            ?? Data("{}".utf8)
        while json.count % 4 != 0 { json.append(0x20) }
        while binary.count % 4 != 0 { binary.append(0) }

        var glb = Data()
        appendUInt32(&glb, 0x4654_6C67) // "glTF"
        appendUInt32(&glb, 2)
        appendUInt32(&glb, UInt32(12 + 8 + json.count + 8 + binary.count))
        appendUInt32(&glb, UInt32(json.count))
        appendUInt32(&glb, 0x4E4F_534A) // "JSON"
        glb.append(json)
        appendUInt32(&glb, UInt32(binary.count))
        appendUInt32(&glb, 0x004E_4942) // "BIN\0"
        glb.append(binary)
        return glb
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}

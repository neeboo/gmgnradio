import CryptoKit
import Foundation
import Testing
@testable import WorldRuntime

/// 三轴尺寸意图（`WorldPropSizePolicy.intended(sourceExtent:millimeters:)`）与
/// **基础几何电视**（`WorldPrimitiveTelevision`）的判据。
///
/// 现场：用户发了一张**平面电视**的产品图并给了 `1443 x 862 x 302 mm`；旧契约只能表达
/// "一根轴 + 一个米数"，另外两维没有位置 ⇒ 生成器交回一个大立方体。
@Suite("三轴尺寸意图与基础几何电视")
struct WorldPrimitiveTelevisionTests {
    /// 用户原话，逐字。
    private let television = WorldPropSizeMillimeters(x: 1443, y: 862, z: 302)!

    // MARK: - 1. 三轴 → 世界尺寸：按最长边**等比**，另外两维只是期望值

    @Test("三轴意图按最长边等比归一，绝不非等比拉伸")
    func threeAxisIntentScalesUniformly() throws {
        // 生成器交回来的那个**立方体**（真机现象）。
        let cube = WorldVector3(x: 0.5, y: 0.5, z: 0.5)
        let fromCube = try #require(WorldPropSizePolicy.intended(sourceExtent: cube, millimeters: television))
        #expect(fromCube.basis == .longestEdge)
        #expect(abs(WorldPropSizePolicy.longestEdge(of: fromCube.size) - 1.443) <= 1e-4,
                "最长边必须是用户说的 1443 mm（实测 \(fromCube.size)）")
        // 立方体 → 仍然是立方体：三个轴同一个因子。
        #expect(abs(fromCube.size.x - fromCube.size.y) <= 1e-5)
        #expect(abs(fromCube.size.y - fromCube.size.z) <= 1e-5)

        // 真实生成网格（细长）：三个轴的因子**必须逐位相同**，否则碰撞盒与画面就分叉了。
        let sword = WorldVector3(x: 1.005, y: 0.133, z: 0.057)
        let resolution = try #require(WorldPropSizePolicy.intended(sourceExtent: sword, millimeters: television))
        let fx = resolution.size.x / sword.x
        let fy = resolution.size.y / sword.y
        let fz = resolution.size.z / sword.z
        #expect(abs(fx - fy) <= 1e-6 && abs(fy - fz) <= 1e-6,
                "三个轴必须是同一个比例（实测 \(fx) / \(fy) / \(fz)）")
        // 唯一一份等比缩放的存在性判据（生产里拒绝非等比 `size` 用的就是它）。
        #expect(WorldPropSizePolicy.uniformFactor(from: sword, to: resolution.size) != nil,
                "三轴归一的结果必须能过 `uniformFactor`（等比）")
        // 另外两维是**期望值**，必须在 reason 里说出来 —— 不说就是静默丢掉。
        let reason = try #require(resolution.reason)
        #expect(reason.contains("期望"), "reason 必须说明另外两维只是期望值（实测 \(reason)）")
        #expect(reason.contains("等比"), "reason 必须说明是等比归一（实测 \(reason)）")
    }

    @Test("三轴归一的夹取仍然是夹取，而且给得出理由")
    func threeAxisIntentClampsWithAReadableReason() throws {
        // 下夹取**够得着**：契约允许到 10 mm（0.01 m），而渲染可见下限是 20 mm（0.02 m）。
        let smallest = WorldPropSizeMillimeters(x: 10, y: 10, z: 10)!
        let raised = try #require(WorldPropSizePolicy.intended(
            sourceExtent: WorldVector3(x: 0.5, y: 0.5, z: 0.5), millimeters: smallest))
        #expect(raised.basis == .clampedMinimum,
                "低于可见下限必须被夹取（实测 \(raised.basis)）")
        #expect(abs(WorldPropSizePolicy.longestEdge(of: raised.size)
                    - WorldPropSizePolicy.minimumExtentMeters) <= 1e-5)
        #expect(raised.reason?.contains("低于下限") == true, "夹取必须给理由（实测 \(raised.reason ?? "nil")）")

        // 上夹取**够不着**：契约上界与渲染上界**是同一个数**（3000 mm = 3 m），
        // 所以从三轴入口走进来的最长边永远不可能 "> 3"。这一条是**否定断言**：
        // 端点不该被误判成越界（否则 3000 mm 的合法规格会被悄悄缩到 3 m 之下）。
        let largest = WorldPropSizeMillimeters(x: 1443, y: 862, z: 3000)!
        let atLimit = try #require(WorldPropSizePolicy.intended(
            sourceExtent: WorldVector3(x: 0.5, y: 0.5, z: 0.5), millimeters: largest))
        #expect(atLimit.basis == .longestEdge, "闭区间端点不该被夹取（实测 \(atLimit.basis)）")
        #expect(abs(WorldPropSizePolicy.longestEdge(of: atLimit.size) - 3) <= 1e-5)
        // 而契约里的三轴**永远**不会超过渲染上限，所以 `clampedMaximum` 在这条路上不可达。
        #expect(WorldPropSizeMillimeters.maximumMillimeters
                    == WorldPropSizePolicy.maximumExtentMeters * 1000)
    }

    @Test("三轴的毫米边界就是契约的米数边界（与渲染夹取的上下限不是同一条）")
    func threeAxisBoundsMatchTheLegacyMeterBounds() {
        // 契约（守护进程 `SIZE_INTENT_MIN_METERS` / `SIZE_INTENT_MAX_METERS`）：0.01–3 m。
        // 这里**不**引 `WorldPropSizePolicy.minimumExtentMeters` —— 那是**渲染可见**的下限
        // （0.02 m），比契约更严；把两者当成同一条正是本次要避免的那种"两个真相"。
        #expect(WorldPropSizeMillimeters.minimumMillimeters == 0.01 * 1000)
        #expect(WorldPropSizeMillimeters.maximumMillimeters == 0.01 * 1000 * 300)
        #expect(WorldPropSizeMillimeters.maximumMillimeters
                    == WorldPropSizePolicy.maximumExtentMeters * 1000)
        #expect(WorldPropSizeMillimeters.minimumMillimeters
                    < WorldPropSizePolicy.minimumExtentMeters * 1000,
                "契约必须比渲染可见下限**更宽**，否则合法的小尺寸根本进不来")
        // 闭区间的两个端点都收。
        #expect(WorldPropSizeMillimeters(x: 10, y: 10, z: 10)?.isValid == true)
        #expect(WorldPropSizeMillimeters(x: 3000, y: 3000, z: 3000)?.isValid == true)
        // 越界 / 非正 / 非有限：**具名**拒绝（返回 nil，不夹取、不默认）。
        for illegal in [(Float(9.999), Float(862), Float(302)), (0, 862, 302),
                        (1443, -862, 302), (1443, 862, 3000.5), (.nan, 862, 302),
                        (.infinity, 862, 302), (1443, 862, .nan)] {
            #expect(WorldPropSizeMillimeters(x: illegal.0, y: illegal.1, z: illegal.2) == nil,
                    "非法三轴 \(illegal) 被接受了")
        }
    }

    // MARK: - 2. 基础几何电视：数字与用户给的对齐

    @Test("这台电视在场景里的实际尺寸就是用户给的三轴")
    func televisionMatchesTheUsersMillimeters() throws {
        let tv = try WorldPrimitiveTelevision(millimeters: television)
        // 米，宽 × 高 × 深。
        #expect(abs(tv.size.x - 1.443) <= 1e-5, "宽必须是 1443 mm（实测 \(tv.size.x)）")
        #expect(abs(tv.size.y - 0.862) <= 1e-5, "高必须是 862 mm（实测 \(tv.size.y)）")
        #expect(abs(tv.size.z - 0.302) <= 1e-5, "深必须是 302 mm（实测 \(tv.size.z)）")
        // 局部包围盒约定与生成道具一致：x/z 居中、y 从 0 到 size.y。
        #expect(abs(tv.minimum.x + tv.size.x / 2) <= 1e-5)
        #expect(abs(tv.minimum.y) <= 1e-5, "y 必须从地面起算（实测 \(tv.minimum.y)）")
        #expect(abs(tv.minimum.z + tv.size.z / 2) <= 1e-5)

        // 用户给的第三个数是**底座进深**，不是面板厚度。
        #expect(abs(tv.standDepthMeters - 0.302) <= 1e-5)
        #expect(tv.panelThicknessMeters < tv.standDepthMeters,
                "面板厚度必须小于整体进深（实测 \(tv.panelThicknessMeters) vs \(tv.standDepthMeters)）")
        #expect(abs(tv.panelThicknessMeters - 0.04) <= 1e-6)

        // 七块基础几何：面板 + 四根边框 + 立柱 + 底板。
        #expect(tv.parts.count == 7)
        #expect(tv.parts.filter { $0.role == .panel }.count == 1)
        #expect(tv.parts.filter { $0.role == .bezel }.count == 4)
        #expect(tv.parts.filter { $0.role == .standBase }.count == 1)
        #expect(tv.parts.filter { $0.role == .standNeck }.count == 1)
        #expect(tv.parts.contains { $0.name == "panel.screen" })

        // 面板是**最扁**的那一块，而且明显是最大的一维在前。
        let panel = try #require(tv.parts.first { $0.role == .panel })
        #expect(panel.size.z < panel.size.x && panel.size.z < panel.size.y)
        #expect(panel.size.x > 1.4 && panel.size.y > 0.7, "屏幕面必须够大（实测 \(panel.size)）")
    }

    @Test("面板显示的一句话里有用户的原话与场景里的米数")
    func thePanelReadbackShowsBothUnits() throws {
        let tv = try WorldPrimitiveTelevision(millimeters: television)
        let summary = tv.dimensionsSummary
        #expect(summary.contains("1443 × 862 × 302"), "必须原话回显毫米（实测 \(summary)）")
        #expect(summary.contains("1.443") && summary.contains("0.862") && summary.contains("0.302"),
                "必须给出场景里的米数（实测 \(summary)）")
        #expect(summary.contains("底座进深"), "必须说清第三个数是哪个轴（实测 \(summary)）")
    }

    // MARK: - 3. 资产：内容寻址、真实可解码、确定性

    @Test("资产字节是内容寻址的，而且能被本仓的 GLB 解码器解出来")
    func theAssetIsContentAddressedAndDecodable() throws {
        let tv = try WorldPrimitiveTelevision(millimeters: television)
        let digest = SHA256.hash(data: tv.assetBytes).map { String(format: "%02x", $0) }.joined()
        #expect(tv.assetID == "sha256:" + digest, "引用必须**就是**字节的 sha256")
        #expect(tv.assetBytes.count > 100)

        // 同一个形状的解码器（生产里量碰撞盒用的就是它）读回来，包围盒必须逐位相等。
        let triangles = try GLBColliderDecoder().decode(data: tv.assetBytes)
        #expect(!triangles.isEmpty)
        var minimum = WorldVector3(x: .greatestFiniteMagnitude, y: .greatestFiniteMagnitude,
                                   z: .greatestFiniteMagnitude)
        var maximum = WorldVector3(x: -.greatestFiniteMagnitude, y: -.greatestFiniteMagnitude,
                                   z: -.greatestFiniteMagnitude)
        for triangle in triangles {
            for point in [triangle.first, triangle.second, triangle.third] {
                minimum = WorldVector3(x: Swift.min(minimum.x, point.x),
                                       y: Swift.min(minimum.y, point.y),
                                       z: Swift.min(minimum.z, point.z))
                maximum = WorldVector3(x: Swift.max(maximum.x, point.x),
                                       y: Swift.max(maximum.y, point.y),
                                       z: Swift.max(maximum.z, point.z))
            }
        }
        let extent = WorldVector3(x: maximum.x - minimum.x, y: maximum.y - minimum.y,
                                  z: maximum.z - minimum.z)
        #expect(abs(extent.x - tv.size.x) <= 1e-4, "GLB 的宽与 `size` 不一致（\(extent) vs \(tv.size)）")
        #expect(abs(extent.y - tv.size.y) <= 1e-4, "GLB 的高与 `size` 不一致（\(extent) vs \(tv.size)）")
        #expect(abs(extent.z - tv.size.z) <= 1e-4, "GLB 的深与 `size` 不一致（\(extent) vs \(tv.size)）")

        // 内容寻址要求确定性：同样的三轴 ⇒ 同样的字节 ⇒ 同样的引用。
        let again = try WorldPrimitiveTelevision(millimeters: television)
        #expect(again.assetBytes == tv.assetBytes)
        #expect(again.assetID == tv.assetID)
    }

    // MARK: - 4. 它是一个**正常物件**，而且推断得出屏幕

    @Test("基础几何电视在权威里是一个正常物件，且屏幕推断选中的就是那个大平面")
    func theTelevisionIsANormalPropWithAnInferableScreen() throws {
        let tv = try WorldPrimitiveTelevision(millimeters: television)
        let prop = tv.generatedProp(objectID: "primitive-tv-1", sourceWishID: "primitive-tv-1")
        // 与生成产物**同一个类型**、同一个 `size` 出口：摆放/承托/手持/挂点读的就是它。
        #expect(prop.size == tv.size)
        #expect(prop.effectiveSize == tv.size, "定死的尺寸不许被自动基线覆盖")
        #expect(prop.isSizeLocked)
        #expect(abs(prop.longestEdge - 1.443) <= 1e-5)

        // 屏幕几何推断的两条判据（阈值取自 `WorldScreenResolution`，见该文件的
        // `maximumPanelThicknessRatio` / `minimumFaceArea`）：这台电视两条都过。
        #expect(tv.thinnestToLongestRatio <= 0.25,
                "板形判据不过：最薄/最长 = \(tv.thinnestToLongestRatio)")
        #expect(tv.largestFaceAreaSquareMeters >= 0.04,
                "面积判据不过：最大面 = \(tv.largestFaceAreaSquareMeters) m²")
        // 最大平坦面必须是**正面**（宽 × 高），否则屏幕会推断到侧面或顶面上去。
        #expect(tv.largestFaceAreaSquareMeters == tv.size.x * tv.size.y,
                "最大面不是正面：\(tv.largestFaceAreaSquareMeters) vs 正面 \(tv.size.x * tv.size.y)")

        // 屏幕面与 `.front` 那一面**同一个平面**（推断把屏幕放在 z = size.z / 2，
        // 生产侧再自己加 1 mm 的防共面偏移）。
        #expect(abs(tv.screen.center.z - tv.size.z / 2) <= 1e-6,
                "屏幕面必须在整体正面上（实测 \(tv.screen.center.z) vs \(tv.size.z / 2)）")
        #expect(tv.screen.normal == WorldVector3(x: 0, y: 0, z: 1))
        #expect(tv.screen.width < tv.size.x && tv.screen.height < tv.size.y, "屏幕必须落在边框里面")
        #expect(tv.screen.areaSquareMeters > 1.0, "1443 x 862 的电视屏幕面积应大于 1 m²")
        // 屏幕的中心高 = **面板**中心高（底座占了下半截），所以它必然在整体中高之上。
        #expect(tv.screen.center.y > tv.size.y / 2,
                "屏幕中心必须高于整体中高（底座把整体拉低了）：\(tv.screen.center.y) vs \(tv.size.y / 2)")
    }

    @Test("三轴的闭区间端点上也能拼出一台合法的电视")
    func theTelevisionBuildsAtTheContractBounds() throws {
        let smallest = try #require(WorldPropSizeMillimeters(x: 10, y: 10, z: 10))
        let tv = try WorldPrimitiveTelevision(millimeters: smallest)
        #expect(abs(tv.size.x - 0.01) <= 1e-5)
        #expect(abs(tv.size.y - 0.01) <= 1e-5)
        #expect(abs(tv.size.z - 0.01) <= 1e-5)
        // 再小就进不了契约（越界由 `WorldPropSizeMillimeters` 具名拒绝）。
        #expect(WorldPropSizeMillimeters(x: 9.999, y: 10, z: 10) == nil)
    }
}

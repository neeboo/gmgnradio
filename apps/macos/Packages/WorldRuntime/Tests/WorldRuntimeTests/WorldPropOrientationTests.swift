import Foundation
import Testing

@testable import WorldRuntime

// ===========================================================================
// 朝向归一：**唯一**一份策略的判据
// ===========================================================================
//
// 全部数字都来自真机那把「2B 白色长剑（外形摆件）」的 GLB 字节级重算
// （`tools/test-resident-prop-size.swift` 记的就是同一组数）：AABB = 1.005432 × 0.133493 ×
// 0.056566 m（长 × 高 × 厚）。网格是**躺着**的 —— 这就是用户说的"打横"。

private let swordExtent = WorldVector3(
    x: 1.005432426929474, y: 0.1334928721189499, z: 0.05656638368964195
)

@Test("躺着生成的网格（真机那把剑的真实尺寸）必须被摆正：最长边从 X 轴转到 Y 轴")
func lyingDownMeshIsStoodUp() {
    let orientation = WorldPropOrientationPolicy.resolve(sourceExtent: swordExtent)
    #expect(orientation.source == .inferredPrincipalAxis, "主轴说得这么清楚，必须判成躺着生成")
    #expect(!orientation.isIdentity)
    #expect(orientation.notice != nil, "摆了就必须说出来")

    let oriented = WorldPropOrientationPolicy.orientedExtent(of: swordExtent, by: orientation)
    // 摆正后：高度 = 原来的 1.005432（最长边），厚度/宽度是另外两根。
    #expect(abs(oriented.y - 1.005432426929474) < 1e-5, "摆正后高度必须是原最长边（实测 \(oriented.y)）")
    #expect(abs(oriented.x - 0.1334928721189499) < 1e-5, "摆正后 X 必须是原高度（实测 \(oriented.x)）")
    #expect(abs(oriented.z - 0.05656638368964195) < 1e-5)
    // "立着"的判据：高度 >= 所有水平边。
    #expect(oriented.y >= oriented.x && oriented.y >= oriented.z, "摆正后 Y 必须是立起来的那根轴")
}

@Test("摆正之后尺寸策略回到主路：1.1 m 的请求得到一把**立着的 1.1 m 剑**（不再是 8.28 m 横棍）")
func standingSwordGoesBackToTheHeightBasis() {
    // 先钉住"不摆正会怎样"。尺寸策略已经把**面积那一面**修了（细长物件按最长边归一），
    // 所以今天的 `automatic` 给出的最长边就是 1.1 —— 但那把剑仍然是**躺着**的：
    // 高度只有 0.146 m，是一根 1.1 m 长的横棍（真机用户看到的"打横"）。
    let legacy = WorldPropSizePolicy.automatic(sourceExtent: swordExtent, requestedHeight: 1.1)
    #expect(legacy != nil)
    #expect(abs(legacy!.longestEdge - 1.1) < 1e-4)
    #expect(abs(legacy!.size.y - 0.1461) < 0.001,
            "不摆正时它只有 0.146 m 高 —— 这就是'打横'（实测 \(legacy!.size.y)）")
    // 更早的算法（只按高度轴归一、没有尺寸策略）则是 8.2848 m 长，这里一并钉住，
    // 免得将来有人把尺寸策略摘掉还以为"回归到了旧行为"。
    let prePolicyLongest = 1.005432426929474 * (1.1 / swordExtent.y)
    #expect(abs(prePolicyLongest - 8.2848) < 0.002, "旧标定必须复现 8.28 m（实测 \(prePolicyLongest)）")

    let orientation = WorldPropOrientationPolicy.resolve(sourceExtent: swordExtent)
    let oriented = WorldPropOrientationPolicy.orientedExtent(of: swordExtent, by: orientation)
    let resolved = WorldPropSizePolicy.automatic(sourceExtent: oriented, requestedHeight: 1.1)
    #expect(resolved != nil)
    #expect(resolved!.basis == .height, "摆正后高度就是最长边 ⇒ 必须回到 height 主路（实测 \(resolved!.basis)）")
    #expect(abs(resolved!.size.y - 1.1) < 1e-4, "请求 1.1 m ⇒ 立起来 1.1 m（实测 \(resolved!.size.y)）")
    #expect(abs(resolved!.longestEdge - 1.1) < 1e-4)
    #expect(resolved!.size.y > resolved!.size.x && resolved!.size.y > resolved!.size.z, "剑是立着的")
}

@Test("工作流声明优先，而且白名单只有 ±Y / ±Z,±X")
func declaredAxesTakePriority() {
    let canonical = WorldPropOrientationPolicy.canonicalForward

    // 声明"我就是立着的、正面朝 +Z"（= 本项目的正面）⇒ 不动，且出处是"工作流声明"。
    let declared = WorldPropOrientationPolicy.resolve(
        sourceExtent: WorldVector3(x: 0.4, y: 0.9, z: 0.3),
        declaredUpAxis: "+Y", declaredForwardAxis: "+Z"
    )
    #expect(declared.source == .workflowDeclared)
    #expect(declared.isIdentity, "声明与网格一致时不该有旋转")

    // up = -Y ⇒ 绕 X 转 180°，模型的"下"变成世界的"上"。
    let flipped = WorldPropOrientationPolicy.resolve(
        sourceExtent: WorldVector3(x: 0.4, y: 0.9, z: 0.3),
        declaredUpAxis: "-Y", declaredForwardAxis: "+Z"
    )
    #expect(flipped.source == .workflowDeclared)
    let up = WorldPropRotation.rotate(SIMD3(0, -1, 0), by: flipped.rotation)
    #expect(abs(up.y - 1) < 1e-5, "声明 up=-Y ⇒ 旋转后它必须朝 +Y（实测 \(up)）")

    // 每一个合法 forward 都必须落到**正面**（+Z）。
    for (literal, vector) in [
        ("+Z", SIMD3<Float>(0, 0, 1)), ("-Z", SIMD3<Float>(0, 0, -1)),
        ("+X", SIMD3<Float>(1, 0, 0)), ("-X", SIMD3<Float>(-1, 0, 0)),
    ] {
        let resolved = WorldPropOrientationPolicy.resolve(
            sourceExtent: WorldVector3(x: 0.4, y: 0.9, z: 0.3),
            declaredUpAxis: "+Y", declaredForwardAxis: literal
        )
        #expect(resolved.source == .workflowDeclared)
        let forward = WorldPropRotation.rotate(vector, by: resolved.rotation)
        #expect(abs(forward.x - canonical.x) < 1e-5
            && abs(forward.z - canonical.z) < 1e-5
            && abs(forward.y) < 1e-5,
            "声明 forward=\(literal) ⇒ 它必须落到正面 +Z（实测 \(forward)）")
    }

    // up=-Y 时 forward 要先跟着翻过去，再对齐正面（顺序错了会差 180°）。
    let flippedX = WorldPropOrientationPolicy.resolve(
        sourceExtent: WorldVector3(x: 0.4, y: 0.9, z: 0.3),
        declaredUpAxis: "-Y", declaredForwardAxis: "+X"
    )
    let flippedForward = WorldPropRotation.rotate(SIMD3(1, 0, 0), by: flippedX.rotation)
    #expect(abs(flippedForward.z - 1) < 1e-5 && abs(flippedForward.x) < 1e-5,
            "up=-Y + forward=+X ⇒ 立面朝 +Y、正面朝 +Z（实测 \(flippedForward)）")

    // 越界字面量**不许**被当成声明（契约白名单只有 ±Y / ±Z,±X）。
    for (up, forward) in [("up", "-Z"), ("+X", "-Z"), ("+Y", "-W"), ("+Y", "front")] {
        let invalid = WorldPropOrientationPolicy.resolve(
            sourceExtent: WorldVector3(x: 0.4, y: 0.9, z: 0.3),
            declaredUpAxis: up, declaredForwardAxis: forward
        )
        #expect(invalid.source != .workflowDeclared, "\(up)/\(forward) 越界，不能当成声明")
    }
}

@Test("不瞎掰：朝向无法确定时保留原样 + 可见说明（绝不硬掰）")
func ambiguousOrientationIsLeftAloneWithAnExplanation() {
    // 一台咖啡机（0.3 × 0.42 × 0.4）：横竖差不多，没有证据说它躺着。
    let coffee = WorldPropOrientationPolicy.resolve(
        sourceExtent: WorldVector3(x: 0.3, y: 0.42, z: 0.4)
    )
    #expect(coffee.source == .alreadyUpright, "Y 已经是最长边 ⇒ 立着，什么都不用做")
    #expect(coffee.isIdentity)
    #expect(coffee.notice == nil, "本来就立着的资产不该每次都弹一句说明")

    // 一块扁平的地毯/盘子（0.6 × 0.02 × 0.5）：最长水平边 / 高度 = 30 > 4，
    // 但"地毯平铺"正是它该有的样子 —— 这一条会**摆**它。所以这里用"横竖比不够大"的那种：
    let ambiguous = WorldPropOrientationPolicy.resolve(
        sourceExtent: WorldVector3(x: 0.55, y: 0.35, z: 0.4)
    )
    #expect(ambiguous.source == .unresolved, "说不出话就必须说'说不出话'")
    #expect(ambiguous.isIdentity, "**保留原样**：不许硬掰")
    #expect(ambiguous.notice != nil, "无法确定时必须**可见地说明**")
    #expect(ambiguous.notice!.contains("保留原始朝向"))
    #expect(ambiguous.shouldArchive, "这个决定本身要留档（审计事实）")

    // 非法的尺寸不许被当成"一个可以摆平的盒子"。
    let broken = WorldPropOrientationPolicy.resolve(
        sourceExtent: WorldVector3(x: .nan, y: 1, z: 1)
    )
    #expect(broken.source == .unresolved && broken.isIdentity)
}

@Test("存档口径：立着的资产不写这个键（老元数据逐字节不变）")
func archiveStaysByteIdenticalForUprightAssets() throws {
    func prop(_ orientation: WorldPropOrientation?) -> WorldGeneratedProp {
        WorldGeneratedProp(
            objectID: "o", sourceWishID: "w", assetID: "a", displayName: "n",
            size: WorldVector3(x: 0.3, y: 0.42, z: 0.4), sourceHeight: 2,
            orientation: orientation
        )
    }
    let upright = WorldPropOrientationPolicy.resolve(
        sourceExtent: WorldVector3(x: 0.3, y: 0.42, z: 0.4)
    )
    #expect(!upright.shouldArchive)
    let encoder = JSONEncoder()
    let plain = String(decoding: try encoder.encode(prop(nil)), as: UTF8.self)
    #expect(!plain.contains("orientation"), "没有朝向时不得编码这个键")

    // 躺着的剑：必须写进去，而且解码回来是同一个旋转（渲染/碰撞都读它）。
    let lying = WorldPropOrientationPolicy.resolve(sourceExtent: swordExtent)
    #expect(lying.shouldArchive)
    let data = try encoder.encode(prop(lying))
    let decoded = try JSONDecoder().decode(WorldGeneratedProp.self, from: data)
    #expect(decoded.orientation == lying)
    #expect(decoded.orientationRotation == lying.rotation)
    #expect(decoded.isOrientationNormalized)
    #expect(decoded.isValid)
}

@Test("坏掉的朝向不许被当成'不用摆正'")
func brokenOrientationIsInvalid() {
    let broken = WorldGeneratedProp(
        objectID: "o", sourceWishID: "w", assetID: "a", displayName: "n",
        size: WorldVector3(x: 0.3, y: 0.42, z: 0.4), sourceHeight: 2,
        orientation: WorldPropOrientation(
            rotation: WorldQuaternion(x: 0, y: 0, z: 0, w: 0),
            source: .inferredPrincipalAxis, notice: nil
        )
    )
    #expect(!broken.isValid, "退化的四元数必须判无效 ⇒ 走既有的可见拒绝，而不是静默不转")
}

@Test("orientedBounds 对任意角度都按八个角算（不是交换分量）")
func orientedBoundsIsExactForArbitraryAngles() {
    let rotation = WorldPropRotation.axisAngle(axis: SIMD3(0, 1, 0), angle: .pi / 4)
    let bounds = WorldPropOrientationPolicy.orientedBounds(
        minimum: SIMD3(-1, 0, -1), maximum: SIMD3(1, 2, 1), rotation: rotation
    )
    // 绕 Y 转 45° 的 2×2 方块：水平包围盒边长 = 2√2。
    let expected = 2 * Float(2).squareRoot()
    #expect(abs((bounds.maximum.x - bounds.minimum.x) - expected) < 1e-4)
    #expect(abs((bounds.maximum.z - bounds.minimum.z) - expected) < 1e-4)
    #expect(abs(bounds.minimum.y - 0) < 1e-6 && abs(bounds.maximum.y - 2) < 1e-6)
}

@Test("四元数算术：先 lhs 后 rhs，且与右手系 Ry 一致")
func rotationArithmeticMatchesTheRightHandedConvention() {
    let yaw = WorldPropRotation.axisAngle(axis: SIMD3(0, 1, 0), angle: .pi / 2)
    let x = WorldPropRotation.rotate(SIMD3(1, 0, 0), by: yaw)
    // 右手系绕 +Y 转 +90°：x̂ ⇒ (0, 0, -1)（与 ResidentPropPlacementMatrix 同一条）。
    #expect(abs(x.x) < 1e-6 && abs(x.y) < 1e-6 && abs(x.z + 1) < 1e-6, "实测 \(x)")

    let first = WorldPropRotation.axisAngle(axis: SIMD3(0, 0, 1), angle: .pi / 2)
    let second = WorldPropRotation.axisAngle(axis: SIMD3(0, 1, 0), angle: .pi / 2)
    let composed = WorldPropRotation.multiply(first, second)
    let direct = WorldPropRotation.rotate(
        WorldPropRotation.rotate(SIMD3(1, 0, 0), by: first), by: second
    )
    let viaComposed = WorldPropRotation.rotate(SIMD3(1, 0, 0), by: composed)
    #expect(abs(viaComposed.x - direct.x) < 1e-5
        && abs(viaComposed.y - direct.y) < 1e-5
        && abs(viaComposed.z - direct.z) < 1e-5,
        "compose 必须等于连续两次 rotate（实测 \(viaComposed) vs \(direct)）")
}

import Foundation
import Testing
@testable import WorldRuntime

// ===========================================================================
// 尺寸意图（`size_intent`）：**提交前就说清楚"哪根轴、多少米"**
// ===========================================================================
//
// 真机那把剑（2026-10-01「2B 白色长剑（外形摆件）」）的根因不是"没夹取"，而是**轴说错了**：
// 网格是 1.005 × 0.133 × 0.057 m（长 × 高 × 厚），请求高度 1.1 m 被算成"厚度 1.1 m"
// ⇒ 场景里 8.28 × 1.10 × 0.47 m，比舱室还长，被摆放判定拒绝后退回库存。
// 用户说的是"一把 1.1 米的剑"，他要的是**最长边 1.1 m**。这一组断言钉住：
//
// 1. `axis: longest` ⇒ 场景内最长边 = 1.1 m（不是 8.28）；
// 2. `axis: height` ⇒ 按高度归一（老的语义仍然表达得出来）；
// 3. 没有意图 ⇒ 与今天的自动推断**逐位相同**；
// 4. 越界/非法 ⇒ 可读原因或 fail-closed，不静默；
// 5. 优先级：手动 > 意图 > 权威 > 推断，而且只有**一份** `effectiveSize` 出口。

/// 真机那把剑的实测三维（服务回执 `inspection.bounds.dimensions` 与 GLB 字节级重算一致）。
private let swordExtent = WorldVector3(x: 1.005, y: 0.133493, z: 0.057)
/// 已摆好的咖啡机（最长边 / 高度 = 1.348，旧行为里"高度就是它的大小"的那一类）。
private let machineExtent = WorldVector3(x: 0.62, y: 0.46, z: 0.51)

private func f(_ value: Float) -> String { String(format: "%.4f", value) }

// MARK: - 1/2. 两根轴各自归一

@Test func longestAxisIntentMakesTheSwordOnePointOneMetresLong() throws {
    let resolution = try #require(WorldPropSizePolicy.intended(
        sourceExtent: swordExtent, axis: .longest, meters: 1.1))
    #expect(abs(resolution.longestEdge - 1.1) <= 1e-5,
            "「一把 1.1 米的剑」⇒ 场景内最长边必须是 1.1 m（实测 \(f(resolution.longestEdge))）")
    #expect(resolution.basis == .longestEdge, "走的是最长边归一（实测 \(resolution.basis)）")
    // 等比：三个轴一起缩，横纵比不失真。
    let scale = resolution.size.x / swordExtent.x
    #expect(abs(resolution.size.y - swordExtent.y * scale) <= 1e-6
            && abs(resolution.size.z - swordExtent.z * scale) <= 1e-6,
            "必须等比缩放，不能拉伸任何一个轴：\(f(resolution.size.y)) / \(f(swordExtent.y * scale))")
    // 修复前那个数字是"按高度归一"：scale = 1.1 / 0.133493 ⇒ 剑长 8.2848 m（比舱室还长）。
    let heightOnlyLongest = swordExtent.x * (1.1 / swordExtent.y)
    #expect(abs(heightOnlyLongest - 8.28) <= 0.01, "旧缺陷那个数字（实测 \(f(heightOnlyLongest))）")
    #expect(resolution.longestEdge < heightOnlyLongest,
            "意图（最长边 1.1 m）必须远小于按高度归一那个 8.28 m")
}

@Test func heightAxisIntentStillMeansWhatItAlwaysMeant() throws {
    // 「高 35 厘米的咖啡机」：高度就是它的大小，逐位等于旧行为。
    let intended = try #require(WorldPropSizePolicy.intended(
        sourceExtent: machineExtent, axis: .height, meters: 0.35))
    let automatic = try #require(WorldPropSizePolicy.automatic(
        sourceExtent: machineExtent, requestedHeight: 0.35))
    #expect(intended == automatic, "方形/矮物件上「按高度」与今天的自动推断必须逐位相同")
    #expect(abs(intended.size.y - 0.35) <= 1e-6, "高度必须是 0.35 m（实测 \(f(intended.size.y))）")

    // 细长物件上「高 1.1 米」仍然可表达：那根轴真的按高度算（剑立起来会很高，于是夹到上限）。
    let tallSword = try #require(WorldPropSizePolicy.intended(
        sourceExtent: swordExtent, axis: .height, meters: 1.1))
    #expect(tallSword.basis == .clampedMaximum && abs(tallSword.longestEdge - 3) <= 1e-5,
            "「高 1.1 米」的细长物件按高度归一后最长边超过房间上限 ⇒ 夹到 3 m 并给原因")
    #expect(tallSword.reason?.contains("太长了") == true, "夹取必须给读得懂的原因")
    // 不夹取的「高 0.35 米」：高度 0.35，最长边 = 0.35 × (1.005 / 0.133493) ≈ 2.635。
    let shortSword = try #require(WorldPropSizePolicy.intended(
        sourceExtent: swordExtent, axis: .height, meters: 0.35))
    #expect(abs(shortSword.size.y - 0.35) <= 1e-6, "按高度归一：高度 = 0.35（实测 \(f(shortSword.size.y))）")
    #expect(abs(shortSword.longestEdge - 0.35 * (1.005 / 0.133493)) <= 1e-4,
            "按高度归一：最长边跟着高度走（实测 \(f(shortSword.longestEdge))）")
}

// MARK: - 3. 没有意图 = 今天

@Test func withoutAnIntentTheAutomaticInferenceIsUnchanged() throws {
    // 细长物件：今天的自动推断改判为最长边归一（剑 1.005 长 ⇒ 最长边 = 请求高度）。
    let sword = try #require(WorldPropSizePolicy.automatic(sourceExtent: swordExtent, requestedHeight: 1.1))
    #expect(sword.basis == .longestEdge && abs(sword.longestEdge - 1.1) <= 1e-5,
            "细长物件今天已按最长边归一（实测 \(sword.basis) / \(f(sword.longestEdge))）")
    // 非细长物件：按高度，逐位等于"请求高度 / 高度"这一步。
    let machine = try #require(WorldPropSizePolicy.automatic(sourceExtent: machineExtent, requestedHeight: 0.5))
    #expect(machine.basis == .height)
    let scale = 0.5 / machineExtent.y
    #expect(machine.size == WorldVector3(x: machineExtent.x * scale, y: 0.5, z: machineExtent.z * scale),
            "没有意图时自动推断必须逐位等于旧公式")
    // 非法输入仍然 fail-closed。
    #expect(WorldPropSizePolicy.automatic(sourceExtent: swordExtent, requestedHeight: 0) == nil)
    #expect(WorldPropSizePolicy.intended(sourceExtent: swordExtent, axis: .longest, meters: 0) == nil)
    #expect(WorldPropSizePolicy.intended(sourceExtent: .init(x: 0, y: 1, z: 1), axis: .longest, meters: 1) == nil)
    #expect(WorldPropSizePolicy.intended(sourceExtent: swordExtent, axis: .longest, meters: .nan) == nil)
}

// MARK: - 4. 越界：可读原因，不静默

@Test func outOfRangeIntentIsClampedWithAReadableReason() throws {
    let tooBig = try #require(WorldPropSizePolicy.intended(sourceExtent: swordExtent, axis: .longest, meters: 3.5))
    #expect(tooBig.basis == .clampedMaximum && abs(tooBig.longestEdge - 3) <= 1e-5)
    #expect(tooBig.reason?.contains("超过上限") == true && tooBig.reason?.contains("3.00") == true,
            "越界必须给读得懂的原因（实测 \(tooBig.reason ?? "nil")）")
    let tooSmall = try #require(WorldPropSizePolicy.intended(sourceExtent: swordExtent, axis: .longest, meters: 0.001))
    #expect(tooSmall.basis == .clampedMinimum && abs(tooSmall.longestEdge - 0.02) <= 1e-6)
    #expect(tooSmall.reason?.contains("低于下限") == true, "太小也给原因（实测 \(tooSmall.reason ?? "nil")）")
}

// MARK: - 5. 优先级：手动 > 意图 > 权威 > 推断，一份 `effectiveSize` 出口

private func intent(_ axis: WorldPropSizeAxis, _ meters: Float, _ source: WorldPropSizeIntent.Source = .user) -> WorldPropSizeIntent {
    .init(axis: axis, meters: meters, source: source)
}

private let authoritative = WorldPropAuthoritativeSize(
    dimensions: .init(x: 9, y: 9, z: 9), units: "m", upAxis: "+Y", forwardAxis: "+Z")

private func prop(sizeIntent: WorldPropSizeIntent? = nil,
                  authoritativeSize: WorldPropAuthoritativeSize? = nil,
                  sizeLocked: Bool? = nil,
                  size: WorldVector3 = .init(x: 1.1, y: 0.146, z: 0.062)) -> WorldGeneratedProp {
    WorldGeneratedProp(objectID: "wish-prop-sword", sourceWishID: "wish", assetID: "sha256:x",
                       displayName: "2B 白色长剑", size: size, sourceHeight: 1,
                       sizeLocked: sizeLocked, collision: nil,
                       authoritativeSize: authoritativeSize, sizeIntent: sizeIntent)
}

@Test func sizeIntentOutranksTheWorkflowAuthoritativeSizeButLosesToAManualOverride() throws {
    // 意图 > 权威：尺寸读 `size`（提交时按意图算出来的那一份），不是权威尺寸。
    let intended = prop(sizeIntent: intent(.longest, 1.1), authoritativeSize: authoritative)
    #expect(intended.effectiveSize == intended.size, "意图必须压过权威尺寸")
    #expect(intended.effectiveSize != authoritative.dimensions)
    #expect(intended.sizeSource == .submitIntent)
    #expect(intended.sizeProvenance == .submitIntent)
    #expect(intended.sizeProvenanceSummary.contains("用户指定") && intended.sizeProvenanceSummary.contains("最长边"),
            "出处必须可读（实测 \(intended.sizeProvenanceSummary)）")

    // 手动 > 意图：用户拖过尺寸之后，`size` 是唯一定稿，出处变成"手动改过"。
    let manualSize = WorldVector3(x: 1.6, y: 0.2125, z: 0.0905)
    let manuallyResized = intended.withSize(manualSize)
    #expect(manuallyResized.effectiveSize == manualSize, "手动值必须优先")
    #expect(manuallyResized.isSizeLocked)
    #expect(manuallyResized.sizeProvenance == .manual)
    // 手动改尺寸**不改写历史**：当初的意图仍然可查。
    #expect(manuallyResized.sizeIntent == intended.sizeIntent, "审计事实不能被一次改尺寸抹掉")
    #expect(manuallyResized.sizeSource == .appMeasured,
            "手动改过的数字仍然来自 app 量的那一份（`sizeSource` 说数据来自哪里）")

    // 权威 > 推断：没有意图时才轮到权威尺寸。
    let authoritativeOnly = prop(authoritativeSize: authoritative)
    #expect(authoritativeOnly.effectiveSize == authoritative.dimensions)
    #expect(authoritativeOnly.sizeProvenance == .workflowAuthoritative)
    // 什么都没有 ⇒ 与今天逐位相同。
    let plain = prop()
    #expect(plain.effectiveSize == plain.size && plain.sizeSource == .appMeasured
            && plain.sizeProvenance == .appMeasured)
}

@Test func aPropWithAnIntentNeverDisappearsOnReRegistration() {
    // 意图改了自动基线：重新登记时 `size` 与存档里那一份不等，但那不是"资产换了"
    // （否则那件物件会从房间里消失 —— 正是这一轮要修的观感缺陷）。
    let stored = prop(sizeIntent: nil, size: .init(x: 8.2848, y: 1.1, z: 0.47))
    let rebased = prop(sizeIntent: intent(.longest, 1.1), size: .init(x: 1.1, y: 0.146, z: 0.062))
    #expect(stored.matchesIdentity(of: rebased) && rebased.matchesIdentity(of: stored),
            "带意图的物件重新登记不得被判成资产归属不一致")
    let other = WorldGeneratedProp(objectID: "wish-prop-sword", sourceWishID: "wish", assetID: "sha256:OTHER",
                                   displayName: "2B 白色长剑", size: .init(x: 1.1, y: 0.146, z: 0.062),
                                   sourceHeight: 1, sizeIntent: intent(.longest, 1.1))
    #expect(!rebased.matchesIdentity(of: other), "换了资产仍然是另一件物件")
}

// MARK: - 契约字面量与 Codable 兼容

@Test func theIntentVocabularyIsExactlyTheDaemonsContractVocabulary() throws {
    // 轴与出处就是守护进程契约里的那五个字面量（`model.rs` 的 serde rename）。
    #expect(WorldPropSizeAxis.longest.rawValue == "longest")
    #expect(WorldPropSizeAxis.height.rawValue == "height")
    #expect(WorldPropSizeIntent.Source.user.rawValue == "user")
    #expect(WorldPropSizeIntent.Source.suggested.rawValue == "suggested")
    #expect(WorldPropSizeIntent.Source.fallback.rawValue == "default")
    // 从线上的原始三元组构造 ⇒ 解析结果就是策略吃的那个类型。
    let parsed = try #require(WorldPropSizeIntent(axis: "longest", meters: 1.1, source: "user"))
    #expect(parsed.axis == .longest && abs(parsed.meters - 1.1) <= 1e-6 && parsed.source == .user)
    #expect(parsed.wire.axis == "longest" && abs(parsed.wire.meters - 1.1) <= 1e-6 && parsed.wire.source == "user")
    // 越界/非法 ⇒ nil（fail-closed，不静默换一根轴）。
    #expect(WorldPropSizeIntent(axis: "width", meters: 1.1, source: "user") == nil)
    #expect(WorldPropSizeIntent(axis: "longest", meters: 1.1, source: "guess") == nil)
    #expect(WorldPropSizeIntent(axis: "longest", meters: 0, source: "user") == nil)
    // 编解码走的就是契约那三个键。
    let json = String(decoding: try JSONEncoder().encode(parsed), as: UTF8.self)
    #expect(json.contains("\"axis\":\"longest\"") && json.contains("\"source\":\"user\""),
            "线上形状必须是 {axis, meters, source}（实测 \(json)）")
}

@Test func aPropWithoutAnIntentKeepsByteForByteTodaysMetadata() throws {
    let object = prop()
    let encoded = String(decoding: try JSONEncoder().encode(object), as: UTF8.self)
    #expect(!encoded.contains("sizeIntent"), "没有意图时不得编码这个键：\(encoded)")
    // 旧存档（没有这个键）必须照旧解出来。
    let legacy = """
    {"objectID":"wish-prop-sword","sourceWishID":"wish","assetID":"sha256:x","displayName":"剑","size":{"x":1,"y":0.2,"z":0.1},"sourceHeight":1}
    """
    let decoded = try JSONDecoder().decode(WorldGeneratedProp.self, from: Data(legacy.utf8))
    #expect(decoded.sizeIntent == nil && decoded.effectiveSize == decoded.size)
    #expect(decoded.sizeProvenance == .appMeasured)
    // 带意图的一件：编码 → 解码 → 意图还在（面板与优先级都靠它）。
    let roundTrip = try JSONDecoder().decode(WorldGeneratedProp.self, from: JSONEncoder().encode(prop(sizeIntent: intent(.longest, 1.1))))
    #expect(roundTrip.sizeIntent == intent(.longest, 1.1))
    #expect(roundTrip.effectiveSize == roundTrip.size)
    // 非法意图不能被当成"没有意图"（那会退回"让 app 猜"）。
    let broken = WorldGeneratedProp(objectID: "x", sourceWishID: "w", assetID: "a", displayName: "n",
                                    size: .init(x: 1, y: 1, z: 1), sourceHeight: 1,
                                    sizeIntent: .init(axis: .longest, meters: -1, source: .user))
    #expect(!broken.isValid)
}

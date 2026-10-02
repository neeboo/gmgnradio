import Foundation

// ===========================================================================
// 「这台电视的每一块零件长什么样」—— 外观的**唯一**一份取值
// ===========================================================================
//
// ## 为什么要有这一份（真机 2026-10-02「什么玩意儿」）
//
// 用户看到的是一块**灰板 + 一个大的黑色矩形**：GLB 里**一个 `materials` 都没有**，
// 于是七块盒子全都落回渲染器的缺省材质（`GLTFMaterialUniforms`：
// `baseColorFactor = (1,1,1,1)`、`metallic = 1`、`roughness = 1`），在中性灰的环境光下
// 就是一整块灰；而正面那块屏幕被**未播放的黑底 web 视图**整个盖住 —— 所以既没有边框，
// 也没有"关着的屏幕"该有的那种深灰偏黑＋一点反光。
//
// ## 它管什么、不管什么
//
// **只管外观**：颜色（线性空间 RGBA）、金属度、粗糙度。它与
// `WorldPrimitiveTelevision.parts(for:)` 的**盒子数量与尺寸**没有任何关系 ——
// 三轴 `1.443 × 0.862 × 0.302`、"最大平坦面 = 正面"这条屏幕推断、承托与碰撞全部照旧，
// 这一份改不动它们（它连尺寸都不读）。
//
// ## 为什么单独一个文件而不是塞进 `WorldPrimitiveTelevision.swift`
//
// 取值必须能被**离线 harness 单独编译并逐位断言**（`tools/test-resident-tv-look.swift`
// 把"注入回旧材质 ⇒ 必须变红"跑在真源码文本上）。本文件刻意**不依赖本包任何类型**
// （只用标准库的 `SIMD4<Float>`），于是它可以被单独编出来喂给断言，不必先编整个模块。
public enum WorldPrimitiveTelevisionFinish: String, CaseIterable, Equatable, Sendable {
    /// 屏幕那一块：**深灰偏黑**，但**不是纯黑**，而且粗糙度低 ⇒ 有一点点反光
    /// （"关着的屏幕"是块玻璃，不是个黑洞）。
    case screen
    /// 边框（上下左右四根）：**深色机身**，比屏幕更暗、更哑 —— 这是"一眼是电视"的那一圈。
    case body
    /// 底座（立柱 + 底板）：比机身略亮一点的深色，于是"这台电视站在一个底座上"看得见。
    case stand

    /// 线性空间基色（glTF 的 `pbrMetallicRoughness.baseColorFactor` 就是这个口径）。
    public var baseColor: SIMD4<Float> {
        switch self {
        // 0.060 线性 ≈ sRGB 0.27（约 #464a4f）：深灰偏黑，绝不是 (0,0,0)。
        case .screen: return SIMD4<Float>(0.060, 0.066, 0.076, 1)
        // 0.030 线性 ≈ sRGB 0.19（约 #313338）：近黑的机身。
        case .body: return SIMD4<Float>(0.030, 0.032, 0.036, 1)
        // 0.075 线性 ≈ sRGB 0.30（约 #4e5157）：底座比机身亮一档。
        case .stand: return SIMD4<Float>(0.075, 0.078, 0.086, 1)
        }
    }

    public var metallic: Float {
        switch self {
        case .screen: return 0.0
        case .body: return 0.15
        case .stand: return 0.35
        }
    }

    /// 粗糙度。屏幕这一块**低**（0.22）是刻意的：光滑表面才有那"一点点反光"，
    /// 纯黑的哑面则是死黑 —— 两者在画面上的差别就是这个数。
    public var roughness: Float {
        switch self {
        case .screen: return 0.22
        case .body: return 0.42
        case .stand: return 0.32
        }
    }

    /// glTF `materials[]` 里的名字（与用例同名，便于人读字节时对上号）。
    public var name: String { "primitive-television-\(rawValue)" }

    /// 判定"这是不是一块哑的、没有材质的灰板"用的判据：机身/边框必须**明显不是**白。
    /// 断言（`tools/test-resident-tv-look.swift`）读它，产品代码不读。
    public var isDarkBodyColor: Bool {
        baseColor.x < 0.2 && baseColor.y < 0.2 && baseColor.z < 0.2
    }

    /// 判定"这块屏幕面是不是纯黑"。纯黑 = 三个通道全是 0，那种面在画面里没有反光可言。
    public var isPureBlack: Bool {
        baseColor.x == 0 && baseColor.y == 0 && baseColor.z == 0
    }
}

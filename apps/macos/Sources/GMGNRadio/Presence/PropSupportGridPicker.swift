import Foundation
import simd

/// 建造模式的光标拾取：把光标投到摆放层的平面上，取**最近的**命中格子。
///
/// 为什么不做 GPU readback、也不对三角形求交：每个摆放层就是一个水平平面
/// `y = supportHeight`，射线与平面求交是闭式解。命中点的 (x, z) 落在哪个格子，
/// 就决定了拾取结果。纯数学 ⇒ 可离线单测（见 `tools/test-resident-prop-render.swift`）。
///
/// 本文件**刻意只依赖 Foundation + simd，不 import WorldRuntime**，这样离线 harness
/// 可以只编译这一个文件来验证它（沿用 `ResidentPropProjection` 的既有做法）。
/// 调用方负责把 `PropSupportGrid.layers` 映射成 `Candidate`。
enum PropSupportGridPicker {
    /// 一个可拾取的格子。
    ///
    /// 坐标约定与 `WorldRuntime` 一致：格子 `(columnX, columnZ)` 覆盖
    /// `[columnX*spacing, (columnX+1)*spacing] × [columnZ*spacing, (columnZ+1)*spacing]`，
    /// 即列坐标是**最小角**，不是格心。
    struct Candidate: Equatable, Sendable {
        let columnX: Int
        let columnZ: Int
        let layer: Int
        let supportHeight: Float

        init(columnX: Int, columnZ: Int, layer: Int, supportHeight: Float) {
            self.columnX = columnX
            self.columnZ = columnZ
            self.layer = layer
            self.supportHeight = supportHeight
        }
    }

    /// 反投影出光标射线：近平面点 + 近→远方向。
    ///
    /// 与 `ResidentPropProjection.point` 共用同一套约定：`normalized` 以左上为原点、
    /// 取值为 `0...1`；Metal 深度约定下近平面对应 z=0、远平面对应 z=1。
    static func ray(
        normalized: SIMD2<Float>,
        inverseViewProjection: simd_float4x4
    ) -> (origin: SIMD3<Float>, direction: SIMD3<Float>)? {
        guard normalized.x.isFinite, normalized.y.isFinite,
              (0...1).contains(normalized.x), (0...1).contains(normalized.y) else { return nil }
        let xy = SIMD2<Float>(normalized.x * 2 - 1, 1 - normalized.y * 2)
        let a = inverseViewProjection * SIMD4(xy.x, xy.y, 0, 1)
        let b = inverseViewProjection * SIMD4(xy.x, xy.y, 1, 1)
        guard abs(a.w) > 0.000001, abs(b.w) > 0.000001 else { return nil }
        let origin = SIMD3(a.x, a.y, a.z) / a.w
        let end = SIMD3(b.x, b.y, b.z) / b.w
        let direction = end - origin
        guard direction.x.isFinite, direction.y.isFinite, direction.z.isFinite else { return nil }
        return (origin, direction)
    }

    /// 光标 → 最近的可拾取格子；没有命中返回 `nil`。
    ///
    /// 判据：
    /// 1. 平面求交只接受 `t >= 0` 且有限的解（背后的层不算命中）；
    /// 2. 命中点的 (x, z) 必须真的落在**该层自己的格子**里 —— 否则这次求交是
    ///    "瞄到墙、天花板或网格外"，必须丢弃而不是四舍五入到最近的格子；
    /// 3. 沿射线距离不得超过 `maximumDistance`；
    /// 4. 多个候选层命中时取**最近**的那个（这正是不用 GPU readback 也能得到
    ///    正确层的关键：射线先穿过近处的桌面，就不该选中后面的地面）。
    ///
    /// 同高度的格子会被合并成一次平面求交，因此开销是"不同高度数"量级，
    /// 与格子总数基本无关（真实生活舱过滤后只有少数几个高度）。
    static func pick(
        normalized: SIMD2<Float>,
        inverseViewProjection: simd_float4x4,
        candidates: [Candidate],
        spacing: Float,
        maximumDistance: Float
    ) -> Candidate? {
        guard spacing.isFinite, spacing > 0,
              maximumDistance.isFinite, maximumDistance > 0,
              !candidates.isEmpty,
              let ray = ray(normalized: normalized, inverseViewProjection: inverseViewProjection)
        else { return nil }

        // 高度 -> (列 -> 该高度的层号)。列用打包后的整数键，避免为每层建字典。
        var byHeight: [Float: [Int64: Int]] = [:]
        for candidate in candidates {
            guard candidate.supportHeight.isFinite else { continue }
            byHeight[candidate.supportHeight, default: [:]][pack(candidate.columnX, candidate.columnZ)] = candidate.layer
        }

        let directionLength = simd_length(ray.direction)
        guard directionLength > 0.000001 else { return nil }

        var best: (distance: Float, candidate: Candidate)?
        // 按高度排序只为让结果与输入顺序无关（确定性）。
        for height in byHeight.keys.sorted() {
            guard abs(ray.direction.y) > 0.000001 else { continue }
            let t = (height - ray.origin.y) / ray.direction.y
            guard t >= 0, t.isFinite else { continue }
            let distance = t * directionLength
            guard distance <= maximumDistance else { continue }
            if let current = best, current.distance <= distance { continue }

            let hit = ray.origin + ray.direction * t
            guard hit.x.isFinite, hit.z.isFinite else { continue }
            let columnX = Int((hit.x / spacing).rounded(.down))
            let columnZ = Int((hit.z / spacing).rounded(.down))
            guard let layer = byHeight[height]?[pack(columnX, columnZ)] else { continue }
            best = (distance, Candidate(columnX: columnX, columnZ: columnZ,
                                        layer: layer, supportHeight: height))
        }
        return best?.candidate
    }

    private static func pack(_ x: Int, _ z: Int) -> Int64 {
        (Int64(x) << 32) ^ (Int64(z) & 0xFFFF_FFFF)
    }
}

import Foundation
import simd

@MainActor final class ResidentPropRenderOwner {}

/// A shared store can have multiple views. Only the visible world renderer
/// owns prepare/status hooks; a character-only view cannot clear another view.
@MainActor final class ResidentPropRenderOwnership {
    private weak var owner: ResidentPropRenderOwner?
    private var worldID: String?
    private var revision: UInt64 = 0
    func claim(owner candidate: ResidentPropRenderOwner, worldID: String?, drawsWorld: Bool, isVisible: Bool) -> UInt64? {
        guard drawsWorld,isVisible,let worldID else { return nil }
        guard owner == nil || owner === candidate else { return nil }
        if owner !== candidate || self.worldID != worldID { revision &+= 1;owner=candidate;self.worldID=worldID }
        return revision
    }
    func accepts(owner candidate: ResidentPropRenderOwner, worldID: String?, revision: UInt64) -> Bool {
        owner === candidate && self.worldID == worldID && self.revision == revision
    }
    @discardableResult func release(owner candidate: ResidentPropRenderOwner) -> Bool {
        guard owner === candidate else { return false }
        invalidate();return true
    }
    func invalidate() { revision &+= 1;owner=nil;worldID=nil }
}

struct ResidentPropRenderDescriptor: Equatable, Sendable {
    let objectID: String
    let worldID: String
    let assetID: String
    let modelURL: URL
    let targetHeightMeters: Float
    var position: SIMD3<Float>
    var yaw: Float
    var assetKey: String { assetID + "|" + modelURL.standardizedFileURL.path }
}

extension ResidentPropRenderDescriptor {
    /// 「一个物件状态 → 渲染描述符」的**唯一一份**换算：位置直接取，朝向从四元数取 yaw。
    ///
    /// 宿主（`GMGNRadioApp.residentPropDescriptor`）只负责把关（`generatedProp` 有效、
    /// `asset.prop == prop` 的资产归属），换算在**这里** —— 于是已摆那一件与在手预览走的是
    /// 同一行代码，**不可能**出现"已摆的画得出来、预览被判据挡掉"这种不对称（真机 2026-09-29
    /// 排查时的第一嫌疑）。它只依赖 Foundation + simd，离线 harness 能直接跑。
    static func residentProp(objectID: String, worldID: String, assetID: String, modelURL: URL,
                             targetHeightMeters: Float, position: SIMD3<Float>,
                             rotation: SIMD4<Float>) -> Self {
        .init(objectID: objectID, worldID: worldID, assetID: assetID, modelURL: modelURL,
              targetHeightMeters: targetHeightMeters, position: position,
              yaw: atan2(2 * rotation.w * rotation.y, 1 - 2 * rotation.y * rotation.y))
    }
}

struct ResidentPropPreparedAsset: Equatable, Sendable {
    let minimum: SIMD3<Float>
    let maximum: SIMD3<Float>
    let sourceHeight: Float
    let size: SIMD3<Float>
}

enum ResidentPropRenderSelection {
    /// 只做**去重**（同一 objectID 保留一次）与 preview 替换，**不再截断件数**。
    ///
    /// 这里曾经硬编码 4 件：`.prefix(4)` 会把第 5 件及以后直接丢掉，而
    /// `result.count < 4` 会让超出上限的 preview 不出现。两者都是**静默丢数据**——
    /// 用户摆好的家具会凭空消失。件数如果要有上限，必须由世界模型给出**可见的拒绝**，
    /// 而渲染端只按自己的预算决定"这一帧画多少"。
    static func resolve(_ objects: [ResidentPropRenderDescriptor], preview: ResidentPropRenderDescriptor?, worldID: String?) -> [ResidentPropRenderDescriptor] {
        var seen = Set<String>()
        var result = objects.filter { $0.worldID == worldID && seen.insert($0.objectID).inserted }
        if let preview, preview.worldID == worldID {
            if let index = result.firstIndex(where: { $0.objectID == preview.objectID }) { result[index] = preview }
            else { result.append(preview) }
        }
        return result
    }
}

enum ResidentPropPlacementMatrix {
    static func transform(minimum: SIMD3<Float>, maximum: SIMD3<Float>, targetHeight: Float, position: SIMD3<Float>, yaw: Float) throws -> simd_float4x4 {
        guard yaw.isFinite else { throw WishMachineOutputError.invalidDimensions }
        let normalized = try WishMachineOutputPlacement.transform(minimum: minimum, maximum: maximum, targetHeight: targetHeight, outlet: .zero)
        var rotation = matrix_identity_float4x4
        let c = cos(yaw), s = sin(yaw)
        rotation.columns.0 = SIMD4(c, 0, -s, 0)
        rotation.columns.2 = SIMD4(s, 0, c, 0)
        rotation.columns.3 = SIMD4(position, 1)
        guard position.x.isFinite, position.y.isFinite, position.z.isFinite else { throw WishMachineOutputError.invalidDimensions }
        return rotation * normalized
    }
}

enum ResidentPropProjection {
    static func point(normalized: SIMD2<Float>, surfaceY: Float, inverseViewProjection: simd_float4x4) -> SIMD3<Float>? {
        guard normalized.x.isFinite, normalized.y.isFinite, surfaceY.isFinite,
              (0...1).contains(normalized.x), (0...1).contains(normalized.y) else { return nil }
        let xy = SIMD2<Float>(normalized.x * 2 - 1, 1 - normalized.y * 2)
        let a = inverseViewProjection * SIMD4(xy.x, xy.y, 0, 1)
        let b = inverseViewProjection * SIMD4(xy.x, xy.y, 1, 1)
        guard abs(a.w) > 0.000001, abs(b.w) > 0.000001 else { return nil }
        let origin = SIMD3(a.x,a.y,a.z)/a.w, end = SIMD3(b.x,b.y,b.z)/b.w
        let direction = end-origin
        guard abs(direction.y) > 0.000001 else { return nil }
        let t = (surfaceY-origin.y)/direction.y
        guard t >= 0, t.isFinite else { return nil }
        return origin + direction*t
    }
}

/// Presentation only: callers supply a verified, downloaded local GLB.
struct WishMachineOutputDescriptor: Equatable, Sendable {
    let id: String
    let worldID: String
    let modelURL: URL
    let targetHeightMeters: Float
}

enum WishMachineOutputStatus: Equatable, Sendable {
    case empty
    case loading(id: String)
    case ready(id: String)
    case failed(id: String, message: String)
}

enum WishMachineOutputError: LocalizedError {
    case invalidAsset, invalidDimensions, renderUnavailable, textureBudget, invalidTexture
    var errorDescription: String? {
        switch self {
        case .invalidAsset: "许愿机产物文件不可用，请重新生成。"
        case .invalidDimensions: "许愿机产物的尺寸无效，暂时无法显示。"
        case .renderUnavailable: "许愿机产物暂时无法显示，请重新进入空间。"
        case .textureBudget: "许愿机产物贴图超出显示预算：最多 8 张，单边最多 2048 像素，总计最多 1600 万像素。"
        case .invalidTexture: "许愿机产物贴图损坏或缺失，暂时无法领取，请重新生成。"
        }
    }
}

enum WishMachineOutputPlacement {
    /// Respect GLB node transforms (the loader supplies world bounds), centre
    /// X/Z on the tray and place the lowest Y at the suspended output anchor.
    static func transform(minimum: SIMD3<Float>, maximum: SIMD3<Float>,
                          targetHeight: Float, outlet: SIMD3<Float>) throws -> simd_float4x4 {
        guard [minimum.x,minimum.y,minimum.z,maximum.x,maximum.y,maximum.z,
               outlet.x,outlet.y,outlet.z,targetHeight].allSatisfy(\.isFinite),
              targetHeight > 0, targetHeight <= 10,
              maximum.x >= minimum.x, maximum.z >= minimum.z,
              maximum.y - minimum.y > 0.00001
        else { throw WishMachineOutputError.invalidDimensions }
        let scale = targetHeight / (maximum.y - minimum.y)
        let centre = (minimum + maximum) / 2
        var matrix = matrix_identity_float4x4
        matrix.columns.0.x = scale; matrix.columns.1.y = scale; matrix.columns.2.z = scale
        matrix.columns.3 = SIMD4(outlet.x-centre.x*scale, outlet.y-minimum.y*scale, outlet.z-centre.z*scale, 1)
        return matrix
    }

    /// Same clip-space conversion as the existing marble depth prepass.
    static func projection(_ forward: simd_float4x4, reversedDepth: Bool) -> simd_float4x4 {
        guard reversedDepth else { return forward }
        var conversion = matrix_identity_float4x4
        conversion.columns.2.z = -1
        conversion.columns.3.z = 1
        return conversion * forward
    }
}

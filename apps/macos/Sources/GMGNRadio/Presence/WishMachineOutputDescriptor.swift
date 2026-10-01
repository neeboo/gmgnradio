import Foundation
import simd
import WorldRuntime

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
    /// **资产级**摆正旋转（`WorldGeneratedProp.orientationRotation`）。
    ///
    /// 它与 `yaw` 是两件事、也是两份数据：`yaw` 是"用户在房间里把它转到哪边"（放置级，
    /// 存在 `transform.rotation` 里），这里是"这件网格生成出来就是躺着的"（资产级，
    /// 存在物件元数据里）。缺省 = 单位四元数 ⇒ 与改造前逐字节相同。
    var orientation: WorldQuaternion = .identity
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
                             rotation: SIMD4<Float>,
                             orientation: WorldQuaternion = .identity) -> Self {
        .init(objectID: objectID, worldID: worldID, assetID: assetID, modelURL: modelURL,
              targetHeightMeters: targetHeightMeters, position: position,
              yaw: atan2(2 * rotation.w * rotation.y, 1 - 2 * rotation.y * rotation.y),
              orientation: orientation)
    }
}

struct ResidentPropPreparedAsset: Equatable, Sendable {
    let minimum: SIMD3<Float>
    let maximum: SIMD3<Float>
    let sourceHeight: Float
    /// 只按**高度轴**归一的尺寸（`请求高度 / 高度`）。
    ///
    /// ⚠️ 它**不是**最终尺寸：把"生成请求的高度"落成世界尺寸的只有一处
    /// （`WorldPropSizePolicy.automatic`，在生成入库那一处调用）。细长物件（剑）在这一份
    /// 里会是 8.28 m —— 那是真机缺陷本身，任何消费方都必须走策略，而不是直接读这里。
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
    /// 已摆物件在世界里的**唯一**一份变换：
    /// `T(position) · Ry(yaw) · orientation · 归一化(原始包围盒)`。
    ///
    /// `orientation` 是**资产级**的摆正旋转（`WorldGeneratedProp.orientationRotation`）：
    /// 网格躺着生成时把它转正，`yaw` 才是用户在房间里选的那个朝向。两者相乘**只在这里**
    /// 发生一次 —— 判据/碰撞盒读的是已经转正的那一份 `effectiveSize` + 同一个 `yaw`，
    /// 所以画面与判定不可能各转各的。
    ///
    /// `orientation` 为单位四元数时走的仍是原来那一行（`rotation * normalized`），
    /// 逐位不变：已经立着的资产（绝大多数）画面一个像素都不差。
    static func transform(minimum: SIMD3<Float>, maximum: SIMD3<Float>, targetHeight: Float,
                          position: SIMD3<Float>, yaw: Float,
                          orientation: WorldQuaternion = .identity) throws -> simd_float4x4 {
        guard yaw.isFinite else { throw WishMachineOutputError.invalidDimensions }
        guard !WorldPropRotation.isIdentity(orientation) else {
            let normalized = try WishMachineOutputPlacement.transform(minimum: minimum, maximum: maximum, targetHeight: targetHeight, outlet: .zero)
            var rotation = matrix_identity_float4x4
            let c = cos(yaw), s = sin(yaw)
            rotation.columns.0 = SIMD4(c, 0, -s, 0)
            rotation.columns.2 = SIMD4(s, 0, c, 0)
            rotation.columns.3 = SIMD4(position, 1)
            guard position.x.isFinite, position.y.isFinite, position.z.isFinite else { throw WishMachineOutputError.invalidDimensions }
            return rotation * normalized
        }
        // 转正之后重新量一次包围盒：缩放/居中必须按**转正后**的盒算，否则躺着的物件
        // 会被按"原始 Y 跨度"缩放（真机那把剑：1.1 / 0.133 = 8.24 倍，8.28 m 长）。
        let oriented = WorldPropOrientationPolicy.orientedBounds(
            minimum: minimum, maximum: maximum, rotation: orientation)
        let height = oriented.maximum.y - oriented.minimum.y
        guard height.isFinite, height > 0.00001,
              targetHeight.isFinite, targetHeight > 0, targetHeight <= 10,
              [position.x, position.y, position.z, oriented.minimum.x, oriented.maximum.x,
               oriented.minimum.z, oriented.maximum.z, oriented.minimum.y].allSatisfy(\.isFinite)
        else { throw WishMachineOutputError.invalidDimensions }
        let scale = targetHeight / height
        guard scale.isFinite, scale > 0 else { throw WishMachineOutputError.invalidDimensions }
        let centreX = (oriented.minimum.x + oriented.maximum.x) / 2
        let centreZ = (oriented.minimum.z + oriented.maximum.z) / 2
        var translation = matrix_identity_float4x4
        translation.columns.3 = SIMD4(position, 1)
        var yawRotation = matrix_identity_float4x4
        let c = cos(yaw), s = sin(yaw)
        yawRotation.columns.0 = SIMD4(c, 0, -s, 0)
        yawRotation.columns.2 = SIMD4(s, 0, c, 0)
        var recentre = matrix_identity_float4x4
        recentre.columns.3 = SIMD4(-centreX * scale, -oriented.minimum.y * scale, -centreZ * scale, 1)
        var scaling = matrix_identity_float4x4
        scaling.columns.0.x = scale; scaling.columns.1.y = scale; scaling.columns.2.z = scale
        var upright = matrix_identity_float4x4
        let (x, y, z, w) = (orientation.x, orientation.y, orientation.z, orientation.w)
        upright.columns.0 = SIMD4(1 - 2 * (y * y + z * z), 2 * (x * y + z * w), 2 * (x * z - y * w), 0)
        upright.columns.1 = SIMD4(2 * (x * y - z * w), 1 - 2 * (x * x + z * z), 2 * (y * z + x * w), 0)
        upright.columns.2 = SIMD4(2 * (x * z + y * w), 2 * (y * z - x * w), 1 - 2 * (x * x + y * y), 0)
        return translation * yawRotation * recentre * scaling * upright
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
    /// `true` = 这个高度是**生成请求**的高度，渲染前必须过一遍尺度策略
    /// （`WorldPropSizePolicy`：细长物件按最长边归一）。托盘上那件还没登记的产物走这条。
    ///
    /// `false`（缺省）= 已经是**定稿的世界高度**（已登记物件的 `size.y`）：渲染端只做等比
    /// 归一，**不再**重复应用策略 —— 策略不幂等，重复套用会把细长物件每帧再缩一次。
    var heightIsGenerationRequest: Bool = false
    /// 提交时声明的**尺寸意图**。有它时（且 `heightIsGenerationRequest == true`）渲染端按
    /// 用户说的那根轴归一：`longest` ⇒ 最长边 = `meters`，`height` ⇒ 高度 = `meters`；
    /// 没有它才走今天的自动推断。可选、纯增量：nil ⇒ 与今天逐字节相同。
    var sizeIntent: PropSizeIntent?
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

import Foundation
import Metal
import simd

// MARK: - 渲染器的取帧接缝：世界坐标四边形 + 原生视频纹理

/// 场景渲染器读原生视频帧的**唯一**接缝。
///
/// 数据流只有一个方向：`WorldScreenStore`（几何 + 播放器）登记一个 provider，
/// `MarbleSpatialView` 每帧读一次。渲染器**不**知道 `WKWebView`、**不**知道解析器、
/// 也不知道 URL —— 它只拿到"世界四角 + 一张纹理"。
///
/// 没有登记任何屏幕时 `frames()` 为空，渲染器**一个 pass 都不加**：既有画面逐字节不变。
@MainActor
final class WorldScreenNativeVideoRegistry {
    struct Frame {
        let objectID: String
        /// 解码出来的一张 `MTLTexture`。`nil` = 还没出第一帧。
        let texture: MTLTexture?
        /// 世界四角（BL, BR, TR, TL）。
        let quad: [SIMD3<Float>]
        /// 是不是已经真的有画面了。`false` 时渲染器不画（避免一块黑矩形）。
        let isReady: Bool
    }

    private var providers: [String: @MainActor () -> Frame?] = [:]

    /// 有没有登记任何屏幕（渲染器据此快速跳过）。
    var isEmpty: Bool { providers.isEmpty }

    func register(_ objectID: String, provider: @escaping @MainActor () -> Frame?) {
        providers[objectID] = provider
    }

    func unregister(_ objectID: String) {
        providers[objectID] = nil
    }

    func removeAll() {
        providers.removeAll()
    }

    func frames() -> [Frame] {
        providers.keys.sorted().compactMap { providers[$0]?() }
    }
}

import Foundation

/// 单轮（per-run）居民视觉调用的强类型图片暂存。
/// `AdditionalTool.handle` 在 `ResidentVisionToolbox.handleImage` 成功时把
/// `ResidentVisionImage` 按 callID 存入；外层 `call` 闭包总是先
/// `await session.call`（租约/取消/次数/deadline 都走会话账本），
/// 回执成功才取出图片随原生图片通道送达；失败或会话取消即清除。
/// 图片字节绝不进入文本 JSON。
@MainActor
final class ResidentVisionImageBox {
    private var images: [String: ResidentVisionImage] = [:]

    func store(callID: String, image: ResidentVisionImage) {
        images[callID] = image
    }

    /// 取出并移除；仅当该调用经 session.call 成功回执时返回图片。
    func take(callID: String, succeeded: Bool) -> ResidentVisionImage? {
        let image = images.removeValue(forKey: callID)
        return succeeded ? image : nil
    }

    func removeAll() {
        images.removeAll()
    }
}

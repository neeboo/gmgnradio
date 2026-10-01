// 挂点（slot）**映射**的 harness 替身：两条 `PropAttachmentPoint ⇄ WorldPropSlot` 的映射。
//
// 编了 `ResidentPropEditorState.swift` 的离线 harness 需要它（那里有一行"已挂载就读世界状态"：
// `held.hand.attachmentPoint`）。真定义在 `Presence/PropAttachmentSlot.swift`，那份文件要用
// `PropGripInference`（标定构造），离线 harness 编不动。
//
// 这里**没有**任何数值/骨名/默认姿势 —— 那些留在生产源码里，由
// `tools/test-resident-prop-hold.swift` / `tools/test-prop-attachment.swift` 切真源码断言。
// 本文件配合 `tools/fixtures/PropAttachmentPointShim.swift`（三个 case）一起编。
import WorldRuntime

extension PropAttachmentPoint {
    var worldSlot: WorldPropSlot {
        switch self {
        case .rightHand: .rightHand
        case .back: .back
        case .waist: .waist
        }
    }
}

extension WorldPropSlot {
    var attachmentPoint: PropAttachmentPoint {
        switch self {
        case .rightHand: .rightHand
        case .back: .back
        case .waist: .waist
        }
    }
}

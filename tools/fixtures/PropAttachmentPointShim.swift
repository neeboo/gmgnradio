// 挂点（slot）**类型**的 harness 替身：只有三个 case，没有任何数值/骨名/默认姿势。
//
// 为什么需要它：`ResidentPropPlacementService` / `ResidentPropEditorState` / 工具桥的签名里
// 出现 `PropAttachmentPoint`，而它的真定义在 `Presence/PropAttachment.swift` 里 —— 那份文件
// 依赖 app 目标的渲染侧类型（`StageAvatarAsset` 等），离线 harness 编不动。
//
// 数值（默认偏移、朝向、骨名、净空）**都不在这里**：它们留在生产源码里，由
// `tools/test-resident-prop-hold.swift` / `tools/test-prop-attachment.swift` 直接切**真源码**
// 编译并逐条断言（三个 case、`rightHand` 的原始值、旧名别名、`hand` 字段名、净空数字都在
// 那两条断言里钉着）。谁给生产加了第四个挂点，那两条先红，这里也就知道要跟着改。
//
// 需要 `WorldPropSlot.attachmentPoint` 那条映射的 harness（编了 `ResidentPropEditorState.swift`
// 的那些），再一起编 `tools/fixtures/PropAttachmentSlotShim.swift`。
enum PropAttachmentPoint: String, CaseIterable, Equatable, Sendable {
    case rightHand
    case back
    case waist
}

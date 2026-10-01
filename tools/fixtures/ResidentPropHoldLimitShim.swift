// 手持尺寸上限 + 挂点（slot）的 harness 替身。
//
// 上限的**唯一一处定义**在
// `apps/macos/Sources/GMGNRadio/Presence/PropAttachment.swift` 的
// `ResidentPropAttachmentEligibility.holdableLongestEdgeMeters`。而 `PropAttachment.swift`
// 依赖 app 目标的渲染侧类型（`StageAvatarAsset` 等），离线 harness 编不动它；编了
// 真 `ResidentPropPlacementService.swift`（它的判据与拒绝文案读那份上限）的 harness
// 于是缺这个符号。这个文件把它补上，做法与 `tools/test-resident-prop-grid-placement.swift`
// 的内联 shim 相同 —— 只是抽出来共用一份：**从生产源码那一行取值**。
//
// 为什么是运行期读源码、而不是在这里抄一个常量：抄一份就出现第二个出处，生产改了值
// 这里不会跟着变（那正是"两种真相"）。harness 本来就在读生产源码，多读一行不多。
import Foundation
import WorldRuntime

enum ResidentPropAttachmentEligibility {
    /// 生产源码里那一刻的唯一一份上限。读不出来就直接崩（fail-closed），
    /// 不许悄悄退回某个默认值 —— 那会让"上限是多少"变成两处。
    static let holdableLongestEdgeMeters: Float = productionHoldableLongestEdgeMeters()

    /// 与生产同一份格式（`PropAttachment.swift` 里那一行）。生产如果改了格式，
    /// 断言它的 harness 会立刻红，而不是静默放过。
    static var holdableLongestEdgeText: String { String(format: "%.1f 米", holdableLongestEdgeMeters) }
}

private func productionHoldableLongestEdgeMeters() -> Float {
    let path = "apps/macos/Sources/GMGNRadio/Presence/PropAttachment.swift"
    guard let text = try? String(contentsOfFile: path, encoding: .utf8),
          let line = text.split(separator: "\n")
              .map({ $0.trimmingCharacters(in: .whitespaces) })
              .first(where: { $0.hasPrefix("static let holdableLongestEdgeMeters") }),
          let literal = line.split(separator: "=").last.map({ $0.trimmingCharacters(in: .whitespaces) }),
          let meters = Float(literal)
    else {
        fatalError("读不出生产源码 \(path) 里的手持上限（那一行改了写法？）—— 替身不许猜默认值")
    }
    return meters
}

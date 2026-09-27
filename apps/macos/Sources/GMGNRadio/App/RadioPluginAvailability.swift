import Foundation

/// 电台插件门禁：单一事实来源，**默认关闭**。
///
/// 它门禁的是电台的**呈现面**：
///   - 电台人格 / 实时语音 DJ；
///   - 歌词舞台、节目单；
///   - 播放器面板（舞台设置面板的「播放器」分区）与菜单栏「打开播放器」；
///   - 光球（`OrbWindowController`，播放器的桌面身体）。
///
/// 门禁关闭时以上代码**全部保留**，只是默认不出现；把持久化键写成 true 即可原样打开：
///
///     defaults write ai.gmgn.radio radio.plugin.enabled.v1 -bool YES
///
/// 这里是 P1 的"默认呈现面"开关，不是 `RadioPlugin` 模块拆分：不删除任何类型。
///
/// 空间的可用性不受门禁影响：活动、点唱机、`music.listen`、角色与动作全部照旧。
enum RadioPluginAvailability {
    /// 持久化键。缺省（从未写入）即关闭，因此冷启动默认是空间优先。
    static let defaultsKey = "radio.plugin.enabled.v1"

    /// 纯逻辑判据：注入任意持久化值即可断言两种状态。
    /// 离线 harness 用这个入口，不碰真实 `UserDefaults`。
    static func isEnabled(storedValue: Bool?) -> Bool {
        storedValue ?? false
    }

    /// 生产读取路径：只有显式写入 true 才打开插件。
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        isEnabled(storedValue: defaults.object(forKey: defaultsKey) as? Bool)
    }
}

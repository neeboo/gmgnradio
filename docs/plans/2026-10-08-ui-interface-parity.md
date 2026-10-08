# 2026-10-08 UI 跨语言接口对齐清单（Rust ⇄ Swift/Unity ⇄ taskd）

工作目录 `/Users/ghostcorn/.codex/worktrees/rust-full-migration/gmgnradio`，分支
`codex/rust-full-migration`，HEAD `88bb67a`。本文只做**机械核对**，不改产品源码。
协作者的未提交改动一律保留（`git status` 与核对开始时逐项一致）。

## 0. 口径（先说清楚什么算数）

- **只算 production 源码**：`apps/gpui-ui/src/**.rs` 里 `#[cfg(test)] mod …` 之前的代码。
  这是相对旧门禁的最重要一次收紧：`stage_panels.rs` 的测试模块从 342 行开始、
  `props.rs` 从 788、`settings.rs` 从 4399、`program.rs` 从 605、`lyrics.rs` 从 3153，
  旧 `op_coverage.rs` 把测试里写的 op 当成 UI 命令面，于是它盯的 100 个 op 里有 27 个
  只存在于测试。切割后真实命令面是 **73 个 op / 92 个发出点**。
- **字段名**取自 `json!({...})` 字面量的键（值形态：string / number / bool / null / expr）。
  `"op": if … {…} else {…}`、`format!("stage.props.{action}")` 这类运行时拼接单独列出。
- **处理者读到的字段**只认命令字典上的下标：接收者必须是
  `value` / `command` / `params` / `p` / `input` / `fields` / `arguments` / `body` /
  `payload` / `obj` / `json` / `incoming` / `envelope` / `request` 之一。
  `operations["prop"]` 这种普通字典下标不算。
- **必填**＝该字段出现在 `guard let x = dict["f"] … else { … return false/nil … }` 里，
  且条件里没有 `== nil`／`!= nil`（后者表示「缺省也合法」，是可选）。
- **模式区分**：产品宿主链 = `apps/macos/ProductHost/**` +
  `apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift` 的 `gpui*Command`；
  Unity 宿主链 = `apps/macos/UnityHost/**`（含各 bridge 的 `supportedCommands`）。

## 1. 表 1：UI op 接口清单（73 条）

列义：**发出点**＝`json!` 字面量所在文件:行；**UI 实发字段**＝键:值形态；
**宿主处理者**＝真正读到这些字段的函数；**处理者实际读取的字段**＝字段 → 文件:行；
**必填**＝guard-else-return 的字段；**结论**只列不对齐项。

| # | op | 发出点 UI (file:line) | UI 实发字段 (名:类型) | 宿主处理者 (file:line) | 处理者实际读取的字段 (file:line) | 必填 | 结论 |
|---:|---|---|---|---|---|---|---|
| 1 | `agent.login` | `apps/gpui-ui/src/settings.rs:3466` | — | `apps/macos/ProductHost/ProductHost.swift` → `func command(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityMediaHost.swift` → `private func settingsCommand(_ value: [String: Any])` | — | — | 对齐 |
| 2 | `agent.logout` | `apps/gpui-ui/src/settings.rs:3466` | — | `apps/macos/ProductHost/ProductHost.swift` → `func command(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityMediaHost.swift` → `private func settingsCommand(_ value: [String: Any])` | — | — | 对齐 |
| 3 | `agent.save` | `apps/gpui-ui/src/settings.rs:1160`<br>`apps/gpui-ui/src/settings.rs:1579`<br>`apps/gpui-ui/src/settings.rs:1716`<br>`apps/gpui-ui/src/settings.rs:3547`<br>`apps/gpui-ui/src/settings.rs:3590` | planningModel:expr, hostPrompt:expr, residentPersona:expr | `apps/macos/ProductHost/ProductHost.swift` → `func command(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityMediaHost.swift` → `private func settingsCommand(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityProductSettings.swift` → `func command(_ value: [String: Any])` | autoSpeak → apps/macos/ProductHost/ProductHost.swift:512<br>autonomyEnabled → apps/macos/ProductHost/ProductHost.swift:514<br>backendID → apps/macos/ProductHost/ProductHost.swift:500<br>backgroundTurnsPerHour → apps/macos/ProductHost/ProductHost.swift:513<br>hostPrompt → apps/macos/ProductHost/ProductHost.swift:508<br>planningModel → apps/macos/ProductHost/ProductHost.swift:510<br>residentPersona → apps/macos/ProductHost/ProductHost.swift:504<br>takeoverEnabled → apps/macos/ProductHost/ProductHost.swift:509<br>autoSpeak → apps/macos/UnityHost/UnityProductSettings.swift:125<br>backgroundTurnsPerHour → apps/macos/UnityHost/UnityProductSettings.swift:125<br>residentPersona → apps/macos/UnityHost/UnityProductSettings.swift:125 | — | 对齐 |
| 4 | `app.language` | `apps/gpui-ui/src/i18n.rs:47` | locale:expr | `apps/macos/UnityHost/UnityProductSettings.swift` → `func command(_ value: [String: Any])` | locale → apps/macos/UnityHost/UnityProductSettings.swift:120 | locale | 对齐 |
| 5 | `generation.check` | `apps/gpui-ui/src/settings.rs:2159` | — | `apps/macos/UnityHost/UnityGenerationConfigurationBridge.swift` → `func settingsCommand(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityMediaHost.swift` → `private func settingsCommand(_ value: [String: Any])` | — | — | 对齐 |
| 6 | `generation.save` | `apps/gpui-ui/src/settings.rs:2176` | endpoint:expr, token:expr | `apps/macos/UnityHost/UnityGenerationConfigurationBridge.swift` → `func settingsCommand(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityMediaHost.swift` → `private func settingsCommand(_ value: [String: Any])` | endpoint → apps/macos/UnityHost/UnityGenerationConfigurationBridge.swift:39<br>token → apps/macos/UnityHost/UnityGenerationConfigurationBridge.swift:40 | endpoint | 对齐 |
| 7 | `inbox.open` | `apps/gpui-ui/src/inbox.rs:202` | id:expr, scope:expr, expectedEventID:expr | `apps/macos/ProductHost/ProductHost.swift` → `func settingsCommand(_ value: [String: Any])` | expectedEventID → apps/macos/ProductHost/ProductHost.swift:315<br>id → apps/macos/ProductHost/ProductHost.swift:314<br>scope → apps/macos/ProductHost/ProductHost.swift:314 | expectedEventID, id, scope | 对齐 |
| 8 | `music.connect` | `apps/gpui-ui/src/settings.rs:2825` | id:expr | `apps/macos/ProductHost/ProductSettingsParity.swift` → `func command(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityMediaHost.swift` → `private func settingsCommand(_ value: [String: Any])` | id → apps/macos/ProductHost/ProductSettingsParity.swift:184 | — | 对齐 |
| 9 | `music.disconnect` | `apps/gpui-ui/src/settings.rs:2825` | id:expr | `apps/macos/ProductHost/ProductSettingsParity.swift` → `func command(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityMediaHost.swift` → `private func settingsCommand(_ value: [String: Any])` | id → apps/macos/ProductHost/ProductSettingsParity.swift:184 | — | 对齐 |
| 10 | `music.sync` | `apps/gpui-ui/src/settings.rs:543` | id:expr | `apps/macos/ProductHost/ProductSettingsParity.swift` → `func command(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityMediaHost.swift` → `private func settingsCommand(_ value: [String: Any])` | id → apps/macos/ProductHost/ProductSettingsParity.swift:184 | — | 对齐 |
| 11 | `presence.activate` | `apps/gpui-ui/src/settings.rs:2366` | id:expr | `apps/macos/ProductHost/ProductSettingsParity.swift` → `func command(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityPresenceSettingsBridge.swift` → `func command(_ value: [String: Any])` | id → apps/macos/ProductHost/ProductSettingsParity.swift:143<br>id → apps/macos/UnityHost/UnityPresenceSettingsBridge.swift:151 | — | 对齐 |
| 12 | `presence.catalog` | `apps/gpui-ui/src/settings.rs:1134`<br>`apps/gpui-ui/src/settings.rs:2579` | url:expr | `apps/macos/ProductHost/ProductSettingsParity.swift` → `func command(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityPresenceSettingsBridge.swift` → `func command(_ value: [String: Any])` | id → apps/macos/ProductHost/ProductSettingsParity.swift:155<br>url → apps/macos/ProductHost/ProductSettingsParity.swift:156<br>id → apps/macos/UnityHost/UnityPresenceSettingsBridge.swift:170<br>url → apps/macos/UnityHost/UnityPresenceSettingsBridge.swift:172 | — | 对齐 |
| 13 | `presence.import` | `apps/gpui-ui/src/settings.rs:4056` | — | `apps/macos/ProductHost/ProductSettingsParity.swift` → `func command(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityPresenceSettingsBridge.swift` → `func command(_ value: [String: Any])` | id → apps/macos/ProductHost/ProductSettingsParity.swift:141<br>id → apps/macos/UnityHost/UnityPresenceSettingsBridge.swift:149 | — | 对齐 |
| 14 | `presence.import.link` | `apps/gpui-ui/src/settings.rs:988` | url:expr | `apps/macos/ProductHost/ProductSettingsParity.swift` → `func command(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityPresenceSettingsBridge.swift` → `func command(_ value: [String: Any])` | id → apps/macos/ProductHost/ProductSettingsParity.swift:163<br>url → apps/macos/ProductHost/ProductSettingsParity.swift:164<br>id → apps/macos/UnityHost/UnityPresenceSettingsBridge.swift:177<br>url → apps/macos/UnityHost/UnityPresenceSettingsBridge.swift:179 | url | 对齐 |
| 15 | `presence.load` | `apps/gpui-ui/src/settings.rs:1276` | — | `apps/macos/ProductHost/ProductSettingsParity.swift` → `func command(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityPresenceSettingsBridge.swift` → `func command(_ value: [String: Any])` | id → apps/macos/ProductHost/ProductSettingsParity.swift:140<br>id → apps/macos/UnityHost/UnityPresenceSettingsBridge.swift:148 | — | 对齐 |
| 16 | `presence.motion` | `apps/gpui-ui/src/settings.rs:2524` | id:expr | `apps/macos/ProductHost/ProductSettingsParity.swift` → `func command(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityMediaHost.swift` → `private func settingsCommand(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityPresenceSettingsBridge.swift` → `func command(_ value: [String: Any])` | id → apps/macos/ProductHost/ProductSettingsParity.swift:149<br>id → apps/macos/UnityHost/UnityMediaHost.swift:1472<br>id → apps/macos/UnityHost/UnityPresenceSettingsBridge.swift:161 | id | 对齐 |
| 17 | `presence.motion.import` | `apps/gpui-ui/src/settings.rs:4064` | — | `apps/macos/ProductHost/ProductSettingsParity.swift` → `func command(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityPresenceSettingsBridge.swift` → `func command(_ value: [String: Any])` | id → apps/macos/ProductHost/ProductSettingsParity.swift:142<br>id → apps/macos/UnityHost/UnityPresenceSettingsBridge.swift:150 | — | 对齐 |
| 18 | `presence.motion.install` | `apps/gpui-ui/src/settings.rs:2652` | catalogIdentity:expr | `apps/macos/ProductHost/ProductSettingsParity.swift` → `func command(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityPresenceSettingsBridge.swift` → `func command(_ value: [String: Any])` | catalogIdentity → apps/macos/ProductHost/ProductSettingsParity.swift:160<br>id → apps/macos/ProductHost/ProductSettingsParity.swift:159<br>catalogIdentity → apps/macos/UnityHost/UnityPresenceSettingsBridge.swift:175<br>id → apps/macos/UnityHost/UnityPresenceSettingsBridge.swift:173 | catalogIdentity | 对齐 |
| 19 | `presence.motion.remove` | `apps/gpui-ui/src/settings.rs:2540` | id:expr | `apps/macos/ProductHost/ProductSettingsParity.swift` → `func command(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityPresenceSettingsBridge.swift` → `func command(_ value: [String: Any])` | id → apps/macos/ProductHost/ProductSettingsParity.swift:152<br>id → apps/macos/UnityHost/UnityPresenceSettingsBridge.swift:167 | — | 对齐 |
| 20 | `presence.orb.color` | `apps/gpui-ui/src/settings.rs:1166` | red:expr, green:expr, blue:expr | `apps/macos/ProductHost/ProductSettingsParity.swift` → `func command(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityPresenceSettingsBridge.swift` → `func command(_ value: [String: Any])` | blue → apps/macos/ProductHost/ProductSettingsParity.swift:177<br>flowIntensity → apps/macos/ProductHost/ProductSettingsParity.swift:181<br>green → apps/macos/ProductHost/ProductSettingsParity.swift:177<br>id → apps/macos/ProductHost/ProductSettingsParity.swift:176<br>red → apps/macos/ProductHost/ProductSettingsParity.swift:177<br>value → apps/macos/ProductHost/ProductSettingsParity.swift:182<br>blue → apps/macos/UnityHost/UnityPresenceSettingsBridge.swift:186<br>flowIntensity → apps/macos/UnityHost/UnityPresenceSettingsBridge.swift:190<br>green → apps/macos/UnityHost/UnityPresenceSettingsBridge.swift:186<br>id → apps/macos/UnityHost/UnityPresenceSettingsBridge.swift:184<br>red → apps/macos/UnityHost/UnityPresenceSettingsBridge.swift:186<br>value → apps/macos/UnityHost/UnityPresenceSettingsBridge.swift:190 | — | 对齐 |
| 21 | `presence.orb.intensity` | `apps/gpui-ui/src/settings.rs:1173` | value:expr | `apps/macos/ProductHost/ProductSettingsParity.swift` → `func command(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityPresenceSettingsBridge.swift` → `func command(_ value: [String: Any])` | blue → apps/macos/ProductHost/ProductSettingsParity.swift:177<br>flowIntensity → apps/macos/ProductHost/ProductSettingsParity.swift:181<br>green → apps/macos/ProductHost/ProductSettingsParity.swift:177<br>id → apps/macos/ProductHost/ProductSettingsParity.swift:176<br>red → apps/macos/ProductHost/ProductSettingsParity.swift:177<br>value → apps/macos/ProductHost/ProductSettingsParity.swift:182<br>blue → apps/macos/UnityHost/UnityPresenceSettingsBridge.swift:186<br>flowIntensity → apps/macos/UnityHost/UnityPresenceSettingsBridge.swift:190<br>green → apps/macos/UnityHost/UnityPresenceSettingsBridge.swift:186<br>id → apps/macos/UnityHost/UnityPresenceSettingsBridge.swift:184<br>red → apps/macos/UnityHost/UnityPresenceSettingsBridge.swift:186<br>value → apps/macos/UnityHost/UnityPresenceSettingsBridge.swift:190 | — | 对齐 |
| 22 | `presence.position` | `apps/gpui-ui/src/settings.rs:1856` | worldID:expr, expectedRevision:expr, expectedLayoutRevision:expr, requestID:expr, position:expr | `apps/macos/UnityHost/UnityCharacterPositionBridge.swift` → `func command(_ value: [String: Any]) -> Bool`<br>`apps/macos/UnityHost/UnityMediaHost.swift` → `private func settingsCommand(_ value: [String: Any])` | expectedLayoutRevision → apps/macos/UnityHost/UnityCharacterPositionBridge.swift:79<br>expectedRevision → apps/macos/UnityHost/UnityCharacterPositionBridge.swift:78<br>position → apps/macos/UnityHost/UnityCharacterPositionBridge.swift:92<br>requestID → apps/macos/UnityHost/UnityCharacterPositionBridge.swift:77<br>worldID → apps/macos/UnityHost/UnityCharacterPositionBridge.swift:76 | — | 对齐 |
| 23 | `presence.position.reset` | `apps/gpui-ui/src/settings.rs:1883` | worldID:expr, expectedRevision:expr, expectedLayoutRevision:expr, requestID:expr | `apps/macos/UnityHost/UnityCharacterPositionBridge.swift` → `func command(_ value: [String: Any]) -> Bool`<br>`apps/macos/UnityHost/UnityMediaHost.swift` → `private func settingsCommand(_ value: [String: Any])` | expectedLayoutRevision → apps/macos/UnityHost/UnityCharacterPositionBridge.swift:79<br>expectedRevision → apps/macos/UnityHost/UnityCharacterPositionBridge.swift:78<br>position → apps/macos/UnityHost/UnityCharacterPositionBridge.swift:92<br>requestID → apps/macos/UnityHost/UnityCharacterPositionBridge.swift:77<br>worldID → apps/macos/UnityHost/UnityCharacterPositionBridge.swift:76 | — | 对齐 |
| 24 | `presence.remove` | `apps/gpui-ui/src/settings.rs:2382` | id:expr | `apps/macos/ProductHost/ProductSettingsParity.swift` → `func command(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityPresenceSettingsBridge.swift` → `func command(_ value: [String: Any])` | id → apps/macos/ProductHost/ProductSettingsParity.swift:146<br>id → apps/macos/UnityHost/UnityPresenceSettingsBridge.swift:158 | — | 对齐 |
| 25 | `settings.load` | `apps/gpui-ui/src/settings.rs:1201` | — | `apps/macos/ProductHost/ProductHost.swift` → `func command(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityMediaHost.swift` → `private func settingsCommand(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityProductSettings.swift` → `func command(_ value: [String: Any])` | — | — | 对齐 |
| 26 | `shortcuts.cancel` | `apps/gpui-ui/src/settings.rs:403`<br>`apps/gpui-ui/src/settings.rs:1243`<br>`apps/gpui-ui/src/settings.rs:1328` | — | `apps/macos/ProductHost/ProductSettingsParity.swift` → `func command(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityShortcutSettingsBridge.swift` → `func command(_ value: [String: Any])` | id → apps/macos/ProductHost/ProductSettingsParity.swift:215 | — | 对齐 |
| 27 | `shortcuts.capture` | `apps/gpui-ui/src/settings.rs:480` | keyCode:expr, keyLabel:expr, modifiers:expr | `apps/macos/UnityHost/UnityShortcutSettingsBridge.swift` → `func command(_ value: [String: Any])` | keyCode → apps/macos/UnityHost/UnityShortcutSettingsBridge.swift:46<br>keyLabel → apps/macos/UnityHost/UnityShortcutSettingsBridge.swift:47<br>modifiers → apps/macos/UnityHost/UnityShortcutSettingsBridge.swift:48 | keyCode, keyLabel, modifiers | 对齐 |
| 28 | `shortcuts.global` | `apps/gpui-ui/src/settings.rs:3343` | value:expr | `apps/macos/ProductHost/ProductSettingsParity.swift` → `func command(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityShortcutSettingsBridge.swift` → `func command(_ value: [String: Any])` | id → apps/macos/ProductHost/ProductSettingsParity.swift:220<br>value → apps/macos/ProductHost/ProductSettingsParity.swift:221<br>value → apps/macos/UnityHost/UnityShortcutSettingsBridge.swift:62 | value | 对齐 |
| 29 | `shortcuts.media` | `apps/gpui-ui/src/settings.rs:3358` | value:expr | `apps/macos/ProductHost/ProductSettingsParity.swift` → `func command(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityShortcutSettingsBridge.swift` → `func command(_ value: [String: Any])` | id → apps/macos/ProductHost/ProductSettingsParity.swift:220<br>value → apps/macos/ProductHost/ProductSettingsParity.swift:221<br>value → apps/macos/UnityHost/UnityShortcutSettingsBridge.swift:62 | value | 对齐 |
| 30 | `shortcuts.record` | `apps/gpui-ui/src/settings.rs:3321` | id:expr, scope:expr | `apps/macos/ProductHost/ProductSettingsParity.swift` → `func command(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityShortcutSettingsBridge.swift` → `func command(_ value: [String: Any])` | id → apps/macos/ProductHost/ProductSettingsParity.swift:209<br>scope → apps/macos/ProductHost/ProductSettingsParity.swift:211<br>id → apps/macos/UnityHost/UnityShortcutSettingsBridge.swift:41<br>scope → apps/macos/UnityHost/UnityShortcutSettingsBridge.swift:42 | id, scope | 对齐 |
| 31 | `shortcuts.reset` | `apps/gpui-ui/src/settings.rs:3380` | — | `apps/macos/ProductHost/ProductSettingsParity.swift` → `func command(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityShortcutSettingsBridge.swift` → `func command(_ value: [String: Any])` | id → apps/macos/ProductHost/ProductSettingsParity.swift:216 | — | 对齐 |
| 32 | `space.default` | `apps/gpui-ui/src/settings.rs:1576` | value:expr | `apps/macos/ProductHost/ProductSettingsParity.swift` → `func command(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityMediaHost.swift` → `private func settingsCommand(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnitySpaceLibraryBridge.swift` → `func settingsCommand(_ value: [String: Any])` | id → apps/macos/ProductHost/ProductSettingsParity.swift:194<br>value → apps/macos/ProductHost/ProductSettingsParity.swift:195<br>value → apps/macos/UnityHost/UnitySpaceLibraryBridge.swift:98 | value | 对齐 |
| 33 | `space.key.clear` | `apps/gpui-ui/src/settings.rs:2932` | — | `apps/macos/ProductHost/ProductSettingsParity.swift` → `func command(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityProductSettings.swift` → `func command(_ value: [String: Any])` | id → apps/macos/ProductHost/ProductSettingsParity.swift:201 | — | 对齐 |
| 34 | `space.key.save` | `apps/gpui-ui/src/settings.rs:2955` | apiKey:expr | `apps/macos/ProductHost/ProductSettingsParity.swift` → `func command(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityProductSettings.swift` → `func command(_ value: [String: Any])` | apiKey → apps/macos/ProductHost/ProductSettingsParity.swift:198<br>id → apps/macos/ProductHost/ProductSettingsParity.swift:197<br>apiKey → apps/macos/UnityHost/UnityProductSettings.swift:110 | apiKey | 对齐 |
| 35 | `space.library.load` | `apps/gpui-ui/src/settings.rs:1247`<br>`apps/gpui-ui/src/settings.rs:2982` | — | `apps/macos/UnityHost/UnityMediaHost.swift` → `private func settingsCommand(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnitySpaceLibraryBridge.swift` → `func settingsCommand(_ value: [String: Any])` | — | — | 对齐 |
| 36 | `space.library.select` | `apps/gpui-ui/src/settings.rs:3019` | id:expr | `apps/macos/UnityHost/UnityMediaHost.swift` → `private func settingsCommand(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnitySpaceLibraryBridge.swift` → `func settingsCommand(_ value: [String: Any])` | id → apps/macos/UnityHost/UnitySpaceLibraryBridge.swift:106 | id | 对齐 |
| 37 | `space.prop.cancel` | `apps/gpui-ui/src/settings.rs:1142`<br>`apps/gpui-ui/src/settings.rs:1149`<br>`apps/gpui-ui/src/settings.rs:1240`<br>`apps/gpui-ui/src/settings.rs:1326` | clearNotice:bool | `apps/macos/ProductHost/ProductSettingsParity.swift` → `func command(_ value: [String: Any])` | clearNotice → apps/macos/ProductHost/ProductSettingsParity.swift:207<br>id → apps/macos/ProductHost/ProductSettingsParity.swift:205 | — | 对齐 |
| 38 | `space.prop.check` | `apps/gpui-ui/src/settings.rs:2244` | endpoint:expr | `apps/macos/ProductHost/ProductSettingsParity.swift` → `func command(_ value: [String: Any])`<br>`apps/macos/ProductHost/ProductSettingsParity.swift` → `private func checkProps(_ value: [String: Any])` | id → apps/macos/ProductHost/ProductSettingsParity.swift:208<br>endpoint → apps/macos/ProductHost/ProductSettingsParity.swift:294 | — | 对齐 |
| 39 | `space.prop.save` | `apps/gpui-ui/src/settings.rs:2267` | endpoint:expr, apiKey:expr | `apps/macos/ProductHost/ProductSettingsParity.swift` → `func command(_ value: [String: Any])`<br>`apps/macos/ProductHost/ProductSettingsParity.swift` → `private func saveProps(_ value: [String: Any]) -> Bool` | id → apps/macos/ProductHost/ProductSettingsParity.swift:204<br>apiKey → apps/macos/ProductHost/ProductSettingsParity.swift:232<br>endpoint → apps/macos/ProductHost/ProductSettingsParity.swift:229 | endpoint | 对齐 |
| 40 | `speech.settings.cancel` | `apps/gpui-ui/src/settings.rs:1124`<br>`apps/gpui-ui/src/settings.rs:1237`<br>`apps/gpui-ui/src/settings.rs:1329` | clearVoices:bool, cancelCapabilities:bool | `apps/macos/ProductHost/ProductHost.swift` → `func command(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityProductSettings.swift` → `func command(_ value: [String: Any])` | cancelCapabilities → apps/macos/ProductHost/ProductHost.swift:560<br>clearVoices → apps/macos/ProductHost/ProductHost.swift:563<br>cancelCapabilities → apps/macos/UnityHost/UnityProductSettings.swift:181<br>clearVoices → apps/macos/UnityHost/UnityProductSettings.swift:182 | — | 对齐 |
| 41 | `speech.settings.load` | `apps/gpui-ui/src/settings.rs:1279` | — | `apps/macos/ProductHost/ProductHost.swift` → `func command(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityProductSettings.swift` → `func command(_ value: [String: Any])` | — | — | 对齐 |
| 42 | `stage.program.back` | `apps/gpui-ui/src/stage_panels/program.rs:1620` | — | `apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift` → `func gpuiProgramCommand(_ command: [String: Any], selection: StageProgramRailSelection)` | — | — | 对齐 |
| 43 | `stage.program.load` | `apps/gpui-ui/src/stage_panels/program.rs:1012` | — | `apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift` → `func gpuiProgramCommand(_ command: [String: Any], selection: StageProgramRailSelection)` | — | — | 对齐 |
| 44 | `stage.program.more` | `apps/gpui-ui/src/stage_panels/program.rs:1530` | — | `apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift` → `func gpuiProgramCommand(_ command: [String: Any], selection: StageProgramRailSelection)` | — | — | 对齐 |
| 45 | `stage.program.play` | `apps/gpui-ui/src/stage_panels/program.rs:1200` | slotIndex:expr | `apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift` → `func gpuiProgramCommand(_ command: [String: Any], selection: StageProgramRailSelection)` | slotIndex → apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift:373 | slotIndex | 对齐 |
| 46 | `stage.program.replan` | `apps/gpui-ui/src/stage_panels/program.rs:1643`<br>`apps/gpui-ui/src/stage_panels/program.rs:1727` | — | `apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift` → `func gpuiProgramCommand(_ command: [String: Any], selection: StageProgramRailSelection)` | — | — | 对齐 |
| 47 | `stage.program.video` | `apps/gpui-ui/src/stage_panels/program.rs:1202`<br>`apps/gpui-ui/src/stage_panels/program.rs:1408` | trackID:expr | `apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift` → `func gpuiProgramCommand(_ command: [String: Any], selection: StageProgramRailSelection)` | trackID → apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift:378 | trackID | 对齐 |
| 48 | `stage.props.fold` | `apps/gpui-ui/src/stage_panels/props.rs:443`<br>`apps/gpui-ui/src/stage_panels/props.rs:475` | group:expr, folded:bool | `apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift` → `func gpuiPropCommand(_ command: [String: Any])` | folded → apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift:439<br>group → apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift:439 | folded, group | 对齐 |
| 49 | `stage.props.hold` | `apps/gpui-ui/src/stage_panels/props.rs:662` | point:expr | `apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift` → `func gpuiPropCommand(_ command: [String: Any])` | objectID → apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift:472<br>point → apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift:475 | — | 对齐 |
| 50 | `stage.props.load` | `apps/gpui-ui/src/stage_panels/props.rs:261` | — | `apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift` → `func gpuiPropCommand(_ command: [String: Any])` | — | — | 对齐 |
| 51 | `stage.props.resize` | `apps/gpui-ui/src/stage_panels/props.rs:239`<br>`apps/gpui-ui/src/stage_panels/props.rs:699` | value:expr | `apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift` → `func gpuiPropCommand(_ command: [String: Any])` | objectID → apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift:487<br>value → apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift:489 | value | 对齐 |
| 52 | `stage.props.select` | `apps/gpui-ui/src/stage_panels/props.rs:498` | objectID:expr | `apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift` → `func gpuiPropCommand(_ command: [String: Any])` | objectID → apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift:447 | — | 对齐 |
| 53 | `stage.video.bind` | `apps/gpui-ui/src/stage_panels.rs:329` | id:expr | `apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift` → `func gpuiStageCommand(_ command: [String: Any])` | id → apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift:904 | id | 对齐 |
| 54 | `stage.video.pending.dismiss` | `apps/gpui-ui/src/lyrics.rs:2722`<br>`apps/gpui-ui/src/lyrics.rs:2818` | id:expr | `apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift` → `func gpuiBoundVideoPromptCommand(_ command: [String: Any])` | id → apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift:570 | id | 对齐 |
| 55 | `stage.video.pending.play` | `apps/gpui-ui/src/lyrics.rs:2802` | id:expr | `apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift` → `func gpuiBoundVideoPromptCommand(_ command: [String: Any])` | id → apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift:569 | id | 对齐 |
| 56 | `stage.video.remove` | `apps/gpui-ui/src/stage_panels.rs:333` | id:expr | `apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift` → `func gpuiStageCommand(_ command: [String: Any])` | id → apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift:904 | id | 对齐 |
| 57 | `stage.video.toggle` | `apps/gpui-ui/src/stage_panels.rs:318` | id:expr | `apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift` → `func gpuiStageCommand(_ command: [String: Any])` | id → apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift:904 | id | 对齐 |
| 58 | `stage.video.unbind` | `apps/gpui-ui/src/stage_panels.rs:329` | id:expr | `apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift` → `func gpuiStageCommand(_ command: [String: Any])` | — | — | UI 多发字段：id |
| 59 | `tts.stop` | `apps/gpui-ui/src/settings.rs:1116`<br>`apps/gpui-ui/src/settings.rs:1565` | — | `apps/macos/ProductHost/ProductHost.swift` → `func command(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityProductSettings.swift` → `func command(_ value: [String: Any])` | — | — | 对齐 |
| 60 | `video.bind` | `apps/gpui-ui/src/settings.rs:2030` | id:expr, trackID:expr | `apps/macos/UnityHost/UnityMediaHost.swift` → `private func settingsCommand(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityScreenVideoBridge.swift` → `func command(_ value: [String: Any])` | id → apps/macos/UnityHost/UnityScreenVideoBridge.swift:297<br>trackID → apps/macos/UnityHost/UnityScreenVideoBridge.swift:296 | id, trackID | 对齐 |
| 61 | `video.bound.dismiss` | `apps/gpui-ui/src/settings.rs:2057` | id:expr | `apps/macos/UnityHost/UnityMediaHost.swift` → `private func settingsCommand(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityScreenVideoBridge.swift` → `func command(_ value: [String: Any])` | id → apps/macos/UnityHost/UnityScreenVideoBridge.swift:304 | id | 对齐 |
| 62 | `video.bound.play` | `apps/gpui-ui/src/settings.rs:2051` | id:expr | `apps/macos/UnityHost/UnityMediaHost.swift` → `private func settingsCommand(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityScreenVideoBridge.swift` → `func command(_ value: [String: Any])` | id → apps/macos/UnityHost/UnityScreenVideoBridge.swift:304 | id | 对齐 |
| 63 | `video.brightness` | `apps/gpui-ui/src/settings.rs:1181` | value:expr | `apps/macos/UnityHost/UnityMediaHost.swift` → `private func settingsCommand(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityScreenVideoBridge.swift` → `func command(_ value: [String: Any])` | value → apps/macos/UnityHost/UnityScreenVideoBridge.swift:293 | value | 对齐 |
| 64 | `video.choose` | `apps/gpui-ui/src/settings.rs:1914` | — | `apps/macos/UnityHost/UnityMediaHost.swift` → `private func settingsCommand(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityScreenVideoBridge.swift` → `func command(_ value: [String: Any])` | — | — | 对齐 |
| 65 | `video.load` | `apps/gpui-ui/src/settings.rs:1317` | — | `apps/macos/UnityHost/UnityMediaHost.swift` → `private func settingsCommand(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityScreenVideoBridge.swift` → `func command(_ value: [String: Any])` | — | — | 对齐 |
| 66 | `video.mode` | `apps/gpui-ui/src/settings.rs:2077` | value:expr | `apps/macos/UnityHost/UnityMediaHost.swift` → `private func settingsCommand(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityScreenVideoBridge.swift` → `func command(_ value: [String: Any])` | value → apps/macos/UnityHost/UnityScreenVideoBridge.swift:290 | value | 对齐 |
| 67 | `video.pause` | `apps/gpui-ui/src/settings.rs:1943` | — | `apps/macos/UnityHost/UnityMediaHost.swift` → `private func settingsCommand(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityScreenVideoBridge.swift` → `func command(_ value: [String: Any])` | — | — | 对齐 |
| 68 | `video.play` | `apps/gpui-ui/src/settings.rs:1943` | — | `apps/macos/UnityHost/UnityMediaHost.swift` → `private func settingsCommand(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityScreenVideoBridge.swift` → `func command(_ value: [String: Any])` | — | — | 对齐 |
| 69 | `video.recoverStop` | `apps/gpui-ui/src/settings.rs:1967` | — | `apps/macos/UnityHost/UnityScreenVideoBridge.swift` → `func command(_ value: [String: Any])` | — | — | 对齐 |
| 70 | `video.remove` | `apps/gpui-ui/src/settings.rs:2018` | id:expr | `apps/macos/UnityHost/UnityMediaHost.swift` → `private func settingsCommand(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityScreenVideoBridge.swift` → `func command(_ value: [String: Any])` | id → apps/macos/UnityHost/UnityScreenVideoBridge.swift:280 | id | 对齐 |
| 71 | `video.select` | `apps/gpui-ui/src/settings.rs:2009` | id:expr | `apps/macos/UnityHost/UnityMediaHost.swift` → `private func settingsCommand(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityScreenVideoBridge.swift` → `func command(_ value: [String: Any])` | id → apps/macos/UnityHost/UnityScreenVideoBridge.swift:277 | id | 对齐 |
| 72 | `video.stop` | `apps/gpui-ui/src/settings.rs:1956` | — | `apps/macos/UnityHost/UnityMediaHost.swift` → `private func settingsCommand(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityScreenVideoBridge.swift` → `func command(_ value: [String: Any])` | — | — | 对齐 |
| 73 | `video.unbind` | `apps/gpui-ui/src/settings.rs:2030` | id:expr, trackID:expr | `apps/macos/UnityHost/UnityMediaHost.swift` → `private func settingsCommand(_ value: [String: Any])`<br>`apps/macos/UnityHost/UnityScreenVideoBridge.swift` → `func command(_ value: [String: Any])` | trackID → apps/macos/UnityHost/UnityScreenVideoBridge.swift:300 | trackID | UI 多发字段：id |

## 2. 表 2：Rust 方法面（authority 接受 246 个方法 × 客户端发出点）

`services/gmgn-taskd/src/daemon.rs:104-888` 的 `match method {` 交出 **236** 个方法
（多行 `|` 臂必须续行累加，单行正则只数出 79 个）。事件流另有
`subscribe` / `subscribe_messages` / `world_subscribe`（`daemon.rs:896` `stream_events`），
`voice_*` 走 `http.rs:459` 的 `voice_reply`（不经 `match method`），合计 **246**。

客户端发出的方法名绝大多数经变量传递（`transport.call(method: method, …)`），
所以按「方法位字面量」扫描（`method: "x"` / `"method": "x"` /
`request("x")` / `rpc("x")` / `transport("x")` / `subscribe("x")` / `perform("x")`），
共扫到 **157** 条字面量。下表给出每个被接受方法在客户端可见的字面量发出点；
「经变量传递」表示该方法族由子模块委派（`self.<module>.request(method, …)`），
客户端字面量出现在子模块的调用方而不是信封处。

| `ack_message` | daemon.rs:600 | —（经变量/子模块委派传递） |
| `activity_catalog_build` | daemon.rs:354 | —（经变量/子模块委派传递） |
| `activity_manifest_build` | daemon.rs:354 | —（经变量/子模块委派传递） |
| `activity_seat_definition` | daemon.rs:354 | —（经变量/子模块委派传递） |
| `agent_chat_cancel` | daemon.rs:114 | —（经变量/子模块委派传递） |
| `agent_chat_import` | daemon.rs:114 | —（经变量/子模块委派传递） |
| `agent_chat_read` | daemon.rs:114 | —（经变量/子模块委派传递） |
| `agent_chat_reset` | daemon.rs:114 | —（经变量/子模块委派传递） |
| `agent_chat_start` | daemon.rs:114 | —（经变量/子模块委派传递） |
| `agent_claude_authorize` | daemon.rs:121 | —（经变量/子模块委派传递） |
| `agent_claude_cancel` | daemon.rs:121 | —（经变量/子模块委派传递） |
| `agent_claude_read` | daemon.rs:121 | —（经变量/子模块委派传递） |
| `agent_claude_start` | daemon.rs:121 | —（经变量/子模块委派传递） |
| `agent_claude_tool_receipt` | daemon.rs:121 | —（经变量/子模块委派传递） |
| `agent_cli_authorize` | daemon.rs:299 | —（经变量/子模块委派传递） |
| `agent_cli_cancel` | daemon.rs:299 | —（经变量/子模块委派传递） |
| `agent_cli_read` | daemon.rs:299 | —（经变量/子模块委派传递） |
| `agent_cli_reset` | daemon.rs:299 | —（经变量/子模块委派传递） |
| `agent_cli_start` | daemon.rs:299 | —（经变量/子模块委派传递） |
| `agent_cli_tool_receipt` | daemon.rs:299 | —（经变量/子模块委派传递） |
| `agent_dsh_authorize` | daemon.rs:135 | —（经变量/子模块委派传递） |
| `agent_dsh_cancel` | daemon.rs:135 | —（经变量/子模块委派传递） |
| `agent_dsh_read` | daemon.rs:135 | —（经变量/子模块委派传递） |
| `agent_dsh_start` | daemon.rs:135 | —（经变量/子模块委派传递） |
| `agent_dsh_tool_receipt` | daemon.rs:135 | —（经变量/子模块委派传递） |
| `agent_loop_cancel` | daemon.rs:360 | —（经变量/子模块委派传递） |
| `agent_loop_claim` | daemon.rs:360 | —（经变量/子模块委派传递） |
| `agent_loop_complete` | daemon.rs:360 | —（经变量/子模块委派传递） |
| `agent_loop_configure` | daemon.rs:360 | —（经变量/子模块委派传递） |
| `agent_loop_confirm_cancel` | daemon.rs:360 | —（经变量/子模块委派传递） |
| `agent_loop_enqueue` | daemon.rs:360 | —（经变量/子模块委派传递） |
| `agent_loop_read` | daemon.rs:360 | —（经变量/子模块委派传递） |
| `agent_loop_reconcile` | daemon.rs:360 | —（经变量/子模块委派传递） |
| `agent_loop_steer_admit` | daemon.rs:360 | —（经变量/子模块委派传递） |
| `agent_loop_steer_finish` | daemon.rs:360 | —（经变量/子模块委派传递） |
| `agent_runtime_authorize` | daemon.rs:330 | —（经变量/子模块委派传递） |
| `agent_runtime_cancel` | daemon.rs:330 | —（经变量/子模块委派传递） |
| `agent_runtime_configure` | daemon.rs:330 | —（经变量/子模块委派传递） |
| `agent_runtime_read` | daemon.rs:330 | —（经变量/子模块委派传递） |
| `agent_runtime_reconcile` | daemon.rs:330 | —（经变量/子模块委派传递） |
| `agent_runtime_start` | daemon.rs:330 | —（经变量/子模块委派传递） |
| `agent_runtime_steer` | daemon.rs:330 | —（经变量/子模块委派传递） |
| `agent_runtime_tool_receipt` | daemon.rs:330 | —（经变量/子模块委派传递） |
| `agent_tool_begin` | daemon.rs:339 | —（经变量/子模块委派传递） |
| `agent_tool_finish` | daemon.rs:339 | —（经变量/子模块委派传递） |
| `agent_tool_inspect` | daemon.rs:339 | —（经变量/子模块委派传递） |
| `cancel` | daemon.rs:500 | —（经变量/子模块委派传递） |
| `capability_contract` | daemon.rs:655 | —（经变量/子模块委派传递） |
| `chat_attachments_close` | daemon.rs:391 | —（经变量/子模块委派传递） |
| `chat_attachments_finish` | daemon.rs:391 | —（经变量/子模块委派传递） |
| `chat_attachments_open` | daemon.rs:391 | —（经变量/子模块委派传递） |
| `chat_attachments_read` | daemon.rs:391 | —（经变量/子模块委派传递） |
| `chat_attachments_register` | daemon.rs:391 | —（经变量/子模块委派传递） |
| `chat_attachments_remove` | daemon.rs:391 | —（经变量/子模块委派传递） |
| `chat_attachments_restore` | daemon.rs:391 | —（经变量/子模块委派传递） |
| `chat_attachments_take` | daemon.rs:391 | —（经变量/子模块委派传递） |
| `chat_speech_event` | daemon.rs:109 | —（经变量/子模块委派传递） |
| `chat_speech_read` | daemon.rs:109 | —（经变量/子模块委派传递） |
| `configure` | daemon.rs:465 | —（经变量/子模块委派传递） |
| `configured` | daemon.rs:470 | —（经变量/子模块委派传递） |
| `entries` | daemon.rs:655 | —（经变量/子模块委派传递） |
| `event_read` | daemon.rs:788 | apps/macos/Sources/GMGNRadio/Agent/ResidentStateClient.swift:164 |
| `failover` | daemon.rs:509 | —（经变量/子模块委派传递） |
| `inbox` | daemon.rs:655 | —（经变量/子模块委派传递） |
| `inbox_control_deliver` | daemon.rs:157 | —（经变量/子模块委派传递） |
| `inbox_control_import` | daemon.rs:157 | —（经变量/子模块委派传递） |
| `inbox_control_mark_read` | daemon.rs:157 | —（经变量/子模块委派传递） |
| `inbox_control_post` | daemon.rs:157 | —（经变量/子模块委派传递） |
| `inbox_control_read` | daemon.rs:157 | —（经变量/子模块委派传递） |
| `invalid_state_commit` | daemon.rs:655 | —（经变量/子模块委派传递） |
| `invalid_token` | daemon.rs:470 | —（经变量/子模块委派传递） |
| `jukebox_begin` | daemon.rs:427 | —（经变量/子模块委派传递） |
| `jukebox_claim` | daemon.rs:427 | —（经变量/子模块委派传递） |
| `jukebox_read` | daemon.rs:427 | —（经变量/子模块委派传递） |
| `jukebox_receipt` | daemon.rs:427 | —（经变量/子模块委派传递） |
| `marble_control_action_claim` | daemon.rs:168 | —（经变量/子模块委派传递） |
| `marble_control_action_receipt` | daemon.rs:168 | —（经变量/子模块委派传递） |
| `marble_control_command` | daemon.rs:168 | —（经变量/子模块委派传递） |
| `marble_control_read` | daemon.rs:168 | —（经变量/子模块委派传递） |
| `marble_geometry_invalid_proof` | daemon.rs:199 | —（经变量/子模块委派传递） |
| `marble_geometry_plan` | daemon.rs:199 | —（经变量/子模块委派传递） |
| `marble_geometry_resolve` | daemon.rs:181 | —（经变量/子模块委派传递） |
| `marble_geometry_sample_plan` | daemon.rs:175 | —（经变量/子模块委派传递） |
| `marble_geometry_unavailable` | daemon.rs:199 | —（经变量/子模块委派传递） |
| `media_cancel` | daemon.rs:372 | —（经变量/子模块委派传递） |
| `media_playlist_advance` | daemon.rs:372 | —（经变量/子模块委派传递） |
| `media_playlist_commit` | daemon.rs:372 | —（经变量/子模块委派传递） |
| `media_playlist_import` | daemon.rs:372 | —（经变量/子模块委派传递） |
| `media_playlist_read` | daemon.rs:372 | —（经变量/子模块委派传递） |
| `media_playlist_release` | daemon.rs:372 | —（经变量/子模块委派传递） |
| `media_prepare` | daemon.rs:372 | —（经变量/子模块委派传递） |
| `media_release` | daemon.rs:372 | —（经变量/子模块委派传递） |
| `media_status` | daemon.rs:372 | —（经变量/子模块委派传递） |
| `memory_ingest` | daemon.rs:869 | —（经变量/子模块委派传递） |
| `memory_pending` | daemon.rs:869 | —（经变量/子模块委派传递） |
| `memory_query` | daemon.rs:853 | apps/macos/Sources/GMGNRadio/Agent/ResidentMemoryClient.swift:171 |
| `memory_read` | daemon.rs:845 | apps/macos/Sources/GMGNRadio/Agent/ResidentMemoryClient.swift:158 |
| `memory_recall` | daemon.rs:872 | apps/macos/Sources/GMGNRadio/Agent/ResidentMemoryClient.swift:195 |
| `memory_status` | daemon.rs:837 | —（经变量/子模块委派传递） |
| `memory_turn` | daemon.rs:869 | —（经变量/子模块委派传递） |
| `message_ack` | daemon.rs:821 | apps/macos/Sources/GMGNRadio/Agent/ResidentStateClient.swift:188 |
| `message_read` | daemon.rs:802 | apps/macos/Sources/GMGNRadio/Agent/ResidentStateClient.swift:177 |
| `music_cache_claim` | daemon.rs:441 | —（经变量/子模块委派传递） |
| `music_cache_prepare` | daemon.rs:441 | —（经变量/子模块委派传递） |
| `music_cache_read` | daemon.rs:441 | —（经变量/子模块委派传递） |
| `music_cache_receipt` | daemon.rs:441 | —（经变量/子模块委派传递） |
| `music_dj_candidates` | daemon.rs:409 | —（经变量/子模块委派传递） |
| `music_dj_command` | daemon.rs:409 | —（经变量/子模块委派传递） |
| `music_dj_discovery` | daemon.rs:409 | —（经变量/子模块委派传递） |
| `music_dj_plan` | daemon.rs:408 | —（经变量/子模块委派传递） |
| `music_dj_playlist_plan` | daemon.rs:409 | —（经变量/子模块委派传递） |
| `music_dj_read` | daemon.rs:409 | —（经变量/子模块委派传递） |
| `music_import` | daemon.rs:457 | —（经变量/子模块委派传递） |
| `music_knowledge_event` | daemon.rs:306 | —（经变量/子模块委派传递） |
| `music_knowledge_ingest` | daemon.rs:306 | —（经变量/子模块委派传递） |
| `music_knowledge_read` | daemon.rs:306 | —（经变量/子模块委派传递） |
| `music_library_commit` | daemon.rs:447 | —（经变量/子模块委派传递） |
| `music_library_edit` | daemon.rs:450 | —（经变量/子模块委派传递） |
| `music_library_page_begin` | daemon.rs:450 | —（经变量/子模块委派传递） |
| `music_library_page_end` | daemon.rs:450 | —（经变量/子模块委派传递） |
| `music_library_read` | daemon.rs:457 | —（经变量/子模块委派传递） |
| `music_playback_begin` | daemon.rs:319 | —（经变量/子模块委派传递） |
| `music_playback_clear` | daemon.rs:319 | —（经变量/子模块委派传递） |
| `music_playback_commit` | daemon.rs:319 | —（经变量/子模块委派传递） |
| `music_playback_navigate` | daemon.rs:319 | —（经变量/子模块委派传递） |
| `music_playback_read` | daemon.rs:319 | —（经变量/子模块委派传递） |
| `music_playback_receipt` | daemon.rs:319 | —（经变量/子模块委派传递） |
| `music_playback_replace_upcoming` | daemon.rs:319 | —（经变量/子模块委派传递） |
| `music_program_list` | daemon.rs:457 | —（经变量/子模块委派传递） |
| `music_program_playback_command` | daemon.rs:313 | —（经变量/子模块委派传递） |
| `music_program_save` | daemon.rs:447 | —（经变量/子模块委派传递） |
| `placement_derive` | daemon.rs:688 | —（经变量/子模块委派传递） |
| `placement_evaluate` | daemon.rs:680 | —（经变量/子模块委派传递） |
| `presence_selection_bind_catalog` | daemon.rs:400 | —（经变量/子模块委派传递） |
| `presence_selection_event` | daemon.rs:400 | —（经变量/子模块委派传递） |
| `presence_selection_read` | daemon.rs:400 | —（经变量/子模块委派传递） |
| `presence_selection_remove_claim` | daemon.rs:400 | —（经变量/子模块委派传递） |
| `presence_selection_remove_intent` | daemon.rs:400 | —（经变量/子模块委派传递） |
| `presence_selection_remove_receipt` | daemon.rs:400 | —（经变量/子模块委派传递） |
| `product_settings_apply` | daemon.rs:417 | —（经变量/子模块委派传递） |
| `product_settings_bind_catalog` | daemon.rs:417 | —（经变量/子模块委派传递） |
| `product_settings_import` | daemon.rs:417 | —（经变量/子模块委派传递） |
| `product_settings_music_receipt` | daemon.rs:417 | —（经变量/子模块委派传递） |
| `product_settings_read` | daemon.rs:417 | —（经变量/子模块委派传递） |
| `product_settings_shortcut_event` | daemon.rs:417 | —（经变量/子模块委派传递） |
| `product_settings_stage_event` | daemon.rs:417 | —（经变量/子模块委派传递） |
| `product_settings_stage_import` | daemon.rs:417 | —（经变量/子模块委派传递） |
| `provider_probe` | daemon.rs:555 | —（经变量/子模块委派传递） |
| `providers_status` | daemon.rs:530 | —（经变量/子模块委派传递） |
| `publish_message` | daemon.rs:575 | —（经变量/子模块委派传递） |
| `replayed` | daemon.rs:655 | —（经变量/子模块委派传递） |
| `resident_intent_drain` | daemon.rs:142 | —（经变量/子模块委派传递） |
| `resident_intent_enqueue` | daemon.rs:142 | —（经变量/子模块委派传递） |
| `resident_intent_pause` | daemon.rs:142 | —（经变量/子模块委派传递） |
| `resident_intent_restore` | daemon.rs:142 | —（经变量/子模块委派传递） |
| `resident_intent_update` | daemon.rs:142 | —（经变量/子模块委派传递） |
| `retry` | daemon.rs:500 | —（经变量/子模块委派传递） |
| `revision` | daemon.rs:655 | —（经变量/子模块委派传递） |
| `screen_playback_attach` | daemon.rs:128 | —（经变量/子模块委派传递） |
| `screen_playback_begin` | daemon.rs:128 | —（经变量/子模块委派传递） |
| `screen_playback_read` | daemon.rs:128 | —（经变量/子模块委派传递） |
| `screen_playback_receipt` | daemon.rs:128 | —（经变量/子模块委派传递） |
| `screen_playback_resume` | daemon.rs:128 | —（经变量/子模块委派传递） |
| `screen_playback_stop` | daemon.rs:128 | —（经变量/子模块委派传递） |
| `screen_state_import` | daemon.rs:105 | —（经变量/子模块委派传递） |
| `screen_state_mutate` | daemon.rs:105 | —（经变量/子模块委派传递） |
| `screen_state_read` | daemon.rs:105 | —（经变量/子模块委派传递） |
| `snapshot` | daemon.rs:470 | —（经变量/子模块委派传递） |
| `speech_delivery_cancel` | daemon.rs:109 | —（经变量/子模块委派传递） |
| `speech_delivery_enqueue` | daemon.rs:109 | —（经变量/子模块委派传递） |
| `speech_delivery_read` | daemon.rs:109 | —（经变量/子模块委派传递） |
| `speech_delivery_receipt` | daemon.rs:109 | —（经变量/子模块委派传递） |
| `speech_delivery_wait` | daemon.rs:109 | —（经变量/子模块委派传递） |
| `stage_video_command` | daemon.rs:163 | —（经变量/子模块委派传递） |
| `stage_video_import` | daemon.rs:163 | —（经变量/子模块委派传递） |
| `stage_video_read` | daemon.rs:163 | —（经变量/子模块委派传递） |
| `stage_video_receipt` | daemon.rs:163 | —（经变量/子模块委派传递） |
| `state_commit` | daemon.rs:642 | apps/macos/Sources/GMGNRadio/Agent/ResidentStateClient.swift:152 |
| `state_read` | daemon.rs:626 | apps/macos/Sources/GMGNRadio/Agent/ResidentStateClient.swift:129 |
| `storage_unavailable` | daemon.rs:655 | —（经变量/子模块委派传递） |
| `submit` | daemon.rs:494 | —（经变量/子模块委派传递） |
| `subscribe` | daemon.rs:914 stream_events | —（经变量/子模块委派传递） |
| `subscribe_messages` | daemon.rs:914 stream_events | —（经变量/子模块委派传递） |
| `voice_asr_commit` | http.rs:459 voice_reply（非 match method 臂） | apps/macos/Sources/GMGNRadio/Agent/RustVoiceClient.swift:321 |
| `voice_asr_start` | http.rs:459 voice_reply（非 match method 臂） | apps/macos/Sources/GMGNRadio/Agent/RustVoiceClient.swift:113 |
| `voice_audio_append` | http.rs:459 voice_reply（非 match method 臂） | apps/macos/Sources/GMGNRadio/Agent/RustVoiceClient.swift:319 |
| `voice_cancel` | http.rs:459 voice_reply（非 match method 臂） | —（经变量/子模块委派传递） |
| `voice_capabilities` | http.rs:459 voice_reply（非 match method 臂） | apps/macos/Sources/GMGNRadio/Agent/RustVoiceClient.swift:281 |
| `voice_list` | http.rs:459 voice_reply（非 match method 臂） | apps/macos/Sources/GMGNRadio/Agent/RustVoiceClient.swift:267 |
| `voice_tts_start` | http.rs:459 voice_reply（非 match method 臂） | apps/macos/Sources/GMGNRadio/Agent/RustVoiceClient.swift:86<br>apps/macos/Sources/GMGNRadio/Agent/RustVoiceClient.swift:90 |
| `wish_control_claim` | daemon.rs:287 | —（经变量/子模块委派传递） |
| `wish_control_command` | daemon.rs:287 | —（经变量/子模块委派传递） |
| `wish_control_commit` | daemon.rs:287 | —（经变量/子模块委派传递） |
| `wish_control_discard_unproven_pauses` | daemon.rs:287 | —（经变量/子模块委派传递） |
| `wish_control_event_ack` | daemon.rs:287 | —（经变量/子模块委派传递） |
| `wish_control_open` | daemon.rs:287 | —（经变量/子模块委派传递） |
| `wish_control_pause` | daemon.rs:287 | —（经变量/子模块委派传递） |
| `wish_control_read` | daemon.rs:287 | —（经变量/子模块委派传递） |
| `wish_control_resume` | daemon.rs:287 | —（经变量/子模块委派传递） |
| `wish_control_retry_authorize` | daemon.rs:287 | —（经变量/子模块委派传递） |
| `wish_reference_complete` | daemon.rs:384 | —（经变量/子模块委派传递） |
| `wish_reference_prepare` | daemon.rs:384 | —（经变量/子模块委派传递） |
| `wish_reference_search` | daemon.rs:378 | —（经变量/子模块委派传递） |
| `world_activity_approach_places` | daemon.rs:238 | —（经变量/子模块委派传递） |
| `world_activity_approach_plan` | daemon.rs:238 | —（经变量/子模块委派传递） |
| `world_activity_approach_resolve` | daemon.rs:238 | —（经变量/子模块委派传递） |
| `world_activity_bind_catalog` | daemon.rs:273 | —（经变量/子模块委派传递） |
| `world_activity_continue` | daemon.rs:273 | —（经变量/子模块委派传递） |
| `world_activity_move` | daemon.rs:273 | —（经变量/子模块委派传递） |
| `world_activity_prepare` | daemon.rs:273 | —（经变量/子模块委派传递） |
| `world_activity_read` | daemon.rs:273 | —（经变量/子模块委派传递） |
| `world_activity_receipt` | daemon.rs:273 | —（经变量/子模块委派传递） |
| `world_activity_replan` | daemon.rs:273 | —（经变量/子模块委派传递） |
| `world_activity_route` | daemon.rs:348 | —（经变量/子模块委派传递） |
| `world_activity_start` | daemon.rs:273 | —（经变量/子模块委派传递） |
| `world_activity_stop` | daemon.rs:273 | —（经变量/子模块委派传递） |
| `world_blob_get` | daemon.rs:781 | —（经变量/子模块委派传递） |
| `world_blob_put` | daemon.rs:771 | —（经变量/子模块委派传递） |
| `world_commit` | daemon.rs:703 | apps/macos/Sources/GMGNRadio/Presence/WorldAuthorityClient.swift:490 |
| `world_control_bind_catalog` | daemon.rs:152 | —（经变量/子模块委派传递） |
| `world_control_command` | daemon.rs:152 | —（经变量/子模块委派传递） |
| `world_control_ui_intent` | daemon.rs:152 | —（经变量/子模块委派传递） |
| `world_cursors` | daemon.rs:761 | —（经变量/子模块委派传递） |
| `world_device_catalog_install` | daemon.rs:243 | —（经变量/子模块委派传递） |
| `world_device_command` | daemon.rs:243 | —（经变量/子模块委派传递） |
| `world_device_preview` | daemon.rs:243 | —（经变量/子模块委派传递） |
| `world_device_refresh` | daemon.rs:243 | —（经变量/子模块委派传递） |
| `world_device_ui_intent` | daemon.rs:243 | —（经变量/子模块委派传递） |
| `world_facts_read` | daemon.rs:741 | apps/macos/Sources/GMGNRadio/Presence/WorldAuthorityClient.swift:400 |
| `world_import` | daemon.rs:722 | apps/macos/Sources/GMGNRadio/Presence/WorldAuthorityClient.swift:546 |
| `world_prop_capability_plan` | daemon.rs:199 | —（经变量/子模块委派传递） |
| `world_prop_capability_resolve` | daemon.rs:199 | —（经变量/子模块委派传递） |
| `world_prop_command` | daemon.rs:257 | —（经变量/子模块委派传递） |
| `world_prop_observe` | daemon.rs:257 | —（经变量/子模块委派传递） |
| `world_prop_output_preview` | daemon.rs:257 | —（经变量/子模块委派传递） |
| `world_prop_preview` | daemon.rs:257 | —（经变量/子模块委派传递） |
| `world_prop_read` | daemon.rs:257 | —（经变量/子模块委派传递） |
| `world_prop_rebase` | daemon.rs:257 | —（经变量/子模块委派传递） |
| `world_prop_receipt` | daemon.rs:257 | —（经变量/子模块委派传递） |
| `world_prop_register` | daemon.rs:257 | —（经变量/子模块委派传递） |
| `world_prop_surfaces` | daemon.rs:257 | —（经变量/子模块委派传递） |
| `world_prop_system_avatar_return` | daemon.rs:257 | —（经变量/子模块委派传递） |
| `world_prop_ui_intent` | daemon.rs:257 | —（经变量/子模块委派传递） |
| `world_records` | daemon.rs:751 | —（经变量/子模块委派传递） |
| `world_snapshot` | daemon.rs:696 | apps/macos/Sources/GMGNRadio/Presence/WorldAuthorityClient.swift:379<br>apps/macos/UnityHost/UnityWorldBridge.swift:117 |
| `world_subscribe` | daemon.rs:896 stream_events | apps/macos/Sources/GMGNRadio/Presence/WorldAuthorityClient.swift:666 |
## 3. 表 3：agent tool schema（宿主产出 × `supported_schema` 校验能力）

### 3.1 校验器词表（`services/gmgn-taskd/src/agent_tools.rs`，含未提交改动）

`register_authorization` 逐条检查：`inputSchema["type"] == "object"` 且
`schema_defect(&inputSchema, 0, "$.inputSchema").is_ok()`；任一条不过就
`return Err("agent_tool_invalid_authority")`，**整批注册失败**（`agent_tools.rs:75-90`）。
`SchemaViolation` 只把 `code` 放到线上，结构化定位进 stderr。

`schema_defect`（`agent_tools.rs:200-303`）现行词表：

| 维度 | 现行实现（工作树） | 88bb67a（HEAD） |
|---|---|---|
| `type` 字符串 | object/array/string/boolean/integer/number/null | 同 |
| `type` 数组（联合） | **接受** 1..=7 个互不重复的已知类型名 | **拒绝**：`!matches!(s["type"].as_str(), …)` |
| 允许的关键字 | type, description, title, properties, required, additionalProperties, enum, items, minimum, maximum, minLength, maxLength, minItems, maxItems | 同 |
| `additionalProperties` | 出现时必须**恰好** `false` | 同 |
| 深度 | >16 拒绝 | 同 |
| 数组上限 | 调用时 128 项 | 同 |

调用期 `match_defect` 额外强制：对象里出现未在 `properties` 声明的键即拒绝
（`agent_tools.rs:403-412`）；`required` 逐项存在性检查（`:398-402`）。

### 3.2 生产工具 schema 的联合类型

全树 `"type": [ … ]` 只有 **4 处**，全在
`apps/macos/Sources/GMGNRadio/Agent/ResidentWishMachineTools.swift:61,67,74,76`，
形态都是 `["object","null"]`，属于 `submit_wish_generation`
（`ResidentWishMachineTools.swift:49-105`，经 `UnityWishMachineBridge.swift:37` 原样保留）。

- 在 **HEAD 88bb67a** 上：`type` 必须是单个字符串 ⇒ 这 4 处全部被拒 ⇒ 整批工具注册失败
  ⇒ DSH 会话起不来 ⇒ Swift 侧只看到 `UnityMediaHost.RustDSHSessionClient.ClientError error 3`
  （交接 §5.3 记录的现象）。
- 在**当前工作树**上：联合类型已支持，这 4 处通过（门禁 `tool_schema_types_are_supported_by_the_authority` 绿）。

### 3.3 宿主自己的校验器（反向分歧）

`ResidentDSHOriginalSchemaValidator.allowedSchemaKeys`
（`ResidentDSHAgentToolBridge.swift:273-276`）＝
type, description, enum, properties, required, additionalProperties, items,
minItems, maxItems, minLength, maxLength —— **没有** `title`/`minimum`/`maximum`。
Rust 侧允许这三个关键字。当前生产工具 schema 一个都没用（已 grep 全树确认），
所以是**潜在**分歧，不是现行故障。

## 4. 表 4：快照契约

### 4.1 ABI 根（overlay 侧）

`tools/fixtures/gpui-unity-overlay-probe/src/lib.rs:466-473` 的投影白名单决定
哪些根键能进 UI（`gmgn_gpui_chat_snapshot`）。overlay 自身读根键 **64 处**，
全部在白名单内（门禁绿）。白名单外的键 UI 永远读到 null。

### 4.2 settings 子根（`SettingsPane`）

`SettingsPane`（`apps/gpui-ui/src/settings.rs`）读 13 个一级键。
生产者：`GPUIProductSettings.snapshot`（`ProductHost.swift:399`）、
`GPUISettingsParity.snapshot`（`ProductSettingsParity.swift:52`）、
`UnityProductSettings.snapshot`（`UnityProductSettings.swift:32`）。

`SettingsPane` 读的 13 个一级键里，**7 个由产品宿主写出，6 个只有 Unity 宿主写**：

| 键 | 产品宿主 | Unity 宿主 | 结论 |
|---|---|---|---|
| agent, tts, asr | ✅ `ProductHost.swift:399-461`（`GPUIProductSettings.snapshot`） | ✅ `UnityProductSettings.swift:60-103` | 对齐 |
| presence, music, space, shortcuts | ✅ `ProductSettingsParity.swift:52-131` | ✅ 各 bridge | 对齐 |
| notice | ✅ `ProductHost.swift:425,435` | ✅ | 对齐 |
| **locale** | ❌ 全文件无 `"locale"` | ✅ `UnityProductSettings.swift:72` | **产品模式无此键** ⇒ `settings.rs` 的语言菜单 `.disabled(true)`（与 `app.language` 登记同源） |
| characterPosition | ❌ | ✅ `UnityMediaHost.swift:1534` | **产品模式无此键** ⇒ 角色位置表单无数据 |
| generation | ❌ | ✅ `UnityMediaHost.swift:1536` | **产品模式无此键**（改用 `space.propEndpoint`/`propCredentialConfigured`） |
| video | ❌ | ✅ `UnityMediaHost.swift:1537` | **产品模式无此键** ⇒ 视频页只在 `unity_external` 渲染 |
| spaceLibrary | ❌ | ✅ `UnityMediaHost.swift:1538` | **产品模式无此键** ⇒ `space.library.*` 不再渲染 |
| unity | ❌ | ✅ `UnityMediaHost.swift:1548` | **产品模式无 `unity.availableSections`** |

这 6 个键逐条登记在门禁的 `UNITY_ONLY_SNAPSHOT_KEYS` 里，登记项必须仍被对应 Unity 文件写出，
否则算过期（红）。

## 5. 对不上的清单（按「会导致功能不可用」排序）

### 5.1 必坏（发起即 `unknown_method` / 必被拒）

| # | 症状 | 证据 | 最小修法 |
|---:|---|---|---|
| 1 | **音乐账号 6 个方法权威不认**：`music_account_session_state`、`music_account_session`、`music_account_import`、`music_account_connect`、`music_account_disconnect`、`music_account_apple_authorization` 全部返回 `unknown_method`。连接/断开/会话/Apple 授权、`MusicAccountCommandService`、`RustMusicProviderSessionStore`、`UnityMusicLibraryBridge` 全部走这条链。 | 客户端：`MusicSources/RustMusicAccountClient.swift:38,41,45,49,55,61`；实现：`services/gmgn-taskd/src/music_account.rs:149`；**`main.rs` 的 57 个 `mod` 里没有 `music_account`**（`music_account.rs`、`music_account_http.rs` 是孤儿文件，全仓无 `mod music_account;`、无 `music_account::`） | 改 Rust：`main.rs` 加 `mod music_account;`（及 `music_account_http`），并在 `daemon.rs:104` 的 `match method` 里加 `music_account_*` 分支委派到 `music_account::request` |
| 2 | **许愿机配置 3 个方法权威不认**：`generation_configuration_read/save/import` 返回 `unknown_method`。`space.prop.save`（保存许愿机 endpoint/密钥）与 `space.prop.check`（检测连接）因此必失败；`wishMachineConfigurationAuthority`、`PropGenerationSettingsSection` 同链。 | 客户端：`Presence/RustGenerationConfigurationClient.swift:72,81,91,95,111`；实现：`services/gmgn-taskd/src/generation_configuration.rs:114,129,137`；**`main.rs` 里没有 `mod generation_configuration;`** | 改 Rust：`main.rs` 加 `mod generation_configuration;`，`daemon.rs` 接上方法族 |
| 3 | **`submit_wish_generation` 的 `["object","null"]` 在 HEAD 上被拒 ⇒ 52 项工具整批注册失败 ⇒ DSH 会话起不来（error 3）** | `ResidentWishMachineTools.swift:61,67,74,76` × `git show HEAD:services/gmgn-taskd/src/agent_tools.rs`(`s["type"].as_str()`) | 已由协作者在工作树修（`agent_tools.rs:200-303`）；**尚未提交/回归**。修法：保留联合类型支持并补一条 catalog 回归测试 |
| 4 | **17 个 op 只有产品宿主有处理者，Unity 模式下发起必被拒**：`inbox.open`、`space.prop.cancel`、`space.prop.check`、`space.prop.save`、`stage.program.{load,play,back,more,replan,video}`、`stage.props.{load,select,fold,hold,resize}`、`stage.video.pending.{play,dismiss}` | §7 模式表；产品链：`ProductHost.swift:269-320` + `GMGNRadioApp.swift:355-517`；Unity 链：`UnityMediaHost.swift:1433-1481` 的 `default:` 落到 `UnityProductSettings.command`，那里没有这些 op | 改宿主：正式运行的是哪一侧，就把另一侧的 `gpui*Command` 接进该侧（或让 UI 在对应模式下停渲染这些入口），并逐条登记 |
| 5 | **22 个 op 只有 Unity 宿主有处理者，产品模式下发起必被拒**：`app.language`、`generation.{check,save}`、`presence.position{,.reset}`、`shortcuts.capture`、`space.library.{load,select}`、`video.{load,choose,select,remove,play,pause,stop,recoverStop,mode,brightness,bind,unbind,bound.play,bound.dismiss}`（14 个） | §7 模式表；产生来源 `ProductSettingsParity.command` / `GMGNRadioApp.gpuiStageCommand` 里没有这些 op。**旁证（旧门禁的假阴性）**：`video.bind` 被 `op_coverage.rs` 判成「产品链可达」，因为它的「产品链」是 `apps/macos/ProductHost/**` + `apps/macos/Sources/**` 拼起来的**纯文本子串搜索**，而 `GMGNRadioApp.swift:903` 的 `case "stage.video.toggle", "stage.video.bind", …` 里包含子串 `video.bind`；`video.mode`/`video.unbind` 同理（`:886`/`:911`）。于是这 10 个 `video.*` op 既没有产品处理者、也没进 `UNITY_HOST_ONLY_OPS` | 修法同 #4；另外把 `video.*` 补进 `UNITY_HOST_ONLY_OPS`（或按 #4 在选定的宿主编译进去） |

### 5.2 语义对不上（名字对，字段/数据对不上）

| # | 症状 | 证据 | 最小修法 |
|---:|---|---|---|
| 6 | `video.unbind`：UI 发 `{op,id,trackID}`，Unity 处理者只校验 `trackID`，`id` 无人读 | 读 `apps/gpui-ui/src/settings.rs:2030`；处理者 `UnityScreenVideoBridge.swift:296-299` | 改 UI：`video.unbind` 不必发 `id`（或改宿主校验 id 与 boundAsset 一致） |
| 7 | `stage.video.unbind`：UI 发 `id`，处理者把它丢掉，改用 `programStore.activeSlot?.track.id` | 读 `apps/gpui-ui/src/stage_panels.rs:329`；处理者 `GMGNRadioApp.swift:911-913` | 改 UI：与该 op 的语义一致地不发 `id`，或改宿主接受 UI 指定的 track |
| 8 | 6 个 settings 子根键只有 Unity 宿主产出（§4.2 表），产品模式下这些设置页读到 nil 却仍可渲染 | `UnityMediaHost.swift:1534,1536,1537,1538,1548`；UI 读点 `settings.rs`（见表 4.2） | 改宿主：产品模式补写这 5 个键，或改 UI 按 `unity.availableSections` 停渲染 |
| 9 | 宿主 schema 校验器不认 `title`/`minimum`/`maximum`，Rust 认 ⇒ 哪天工具 schema 用上就只在宿主侧被拒 | `ResidentDSHAgentToolBridge.swift:273-276` × `agent_tools.rs:215-235` | 改宿主：把这三个关键字加进 `allowedSchemaKeys` 并实现，或改 Rust：拒掉它们（当前生产未使用） |

### 5.3 只是多发字段（不会坏功能，但字段面不对齐）

无。表 1 的 73 个 op 里，除 #6/#7 两条外全部对齐：UI 发出的每个字段都有处理者读，
处理者 guard 的每个字段 UI 都发（门禁两向都绿）。

## 6. 机械门禁

位置：`apps/gpui-ui/tests/interface_parity.rs`（5 个 `#[test]`，纯文件系统读，无新依赖，`--offline` 可跑）。

| 测试 | 断言 |
|---|---|
| `op_field_sets_match_the_source_and_are_read` | ① UI 的 op 集合 = `OPS` 表（双向，新增/失效都红）；② 每个 op 的字段集合 = 源码实测；③ 每个发出字段必须在声明的宿主函数里出现 `["字段"]` 读取，否则必须在 `UNREAD_FIELDS_OK` 里逐条登记理由 |
| `required_fields_are_emitted_by_the_ui` | 宿主 `guard … else { return false/nil }` 的字段必须被 UI 发出（`== nil`/`!= nil` 的可选条件排除） |
| `snapshot_keys_read_by_the_ui_are_produced_by_a_host` | `SettingsPane` 的 13 个 `self.snapshot["k"]` ⊆ 三个宿主快照生产者写入的键 ∪ `UNITY_ONLY_SNAPSHOT_KEYS`（登记项须仍被 Unity 宿主写出，否则算过期）；overlay 的 64 处 ABI 根键读取 ⊆ 投影白名单 ∪ 合成键 |
| `client_rpc_methods_are_accepted_by_the_authority` | 方法位字面量 ⊆ `daemon.rs` 的 236 臂 ∪ 事件流/voice 方法 ∪ `NON_TASKD_METHODS`（写明别的协议）∪ `SUB_OPERATIONS` ∪ `KNOWN_UNKNOWN_METHODS`；`KNOWN_UNKNOWN_METHODS` 的条目必须**仍然**是没有 `mod` 声明的孤儿模块，修好即红 |
| `tool_schema_types_are_supported_by_the_authority` | 生产者树里的每个 `"type": [ … ]` 联合必须在 `agent_tools.rs` 的 `known` 类型词表内、非空且 ≤7 项 |

失败信息一律带 op / 字段 / 快照键 / 方法名 + 文件:行，不只报计数。


## 7. 模式可达性表（73 个 production op × 两个宿主链）

「✅」= 该宿主链里有 `case`／`supportedCommands` 命中该 op。判定来源：
产品链 `apps/macos/ProductHost/ProductHost.swift`、`ProductHost/ProductSettingsParity.swift`、
`Sources/GMGNRadio/App/GMGNRadioApp.swift`（`gpui*Command`）；
Unity 链 `apps/macos/UnityHost/**`（含各 bridge 的 `supportedCommands`）。

统计：**产品链 51 / Unity 链 56 / 只有产品 17 / 只有 Unity 22 / 两边都无 0**。

| op | 产品宿主链 | Unity 宿主链 |
| `agent.login` | ✅ apps/macos/ProductHost/ProductHost.swift | ✅ apps/macos/UnityHost/UnityAgentConnectionBridge.swift;apps/macos/UnityHost/UnityMediaHost.swift |
| `agent.logout` | ✅ apps/macos/ProductHost/ProductHost.swift | ✅ apps/macos/UnityHost/UnityAgentConnectionBridge.swift;apps/macos/UnityHost/UnityMediaHost.swift |
| `agent.save` | ✅ apps/macos/ProductHost/ProductHost.swift | ✅ apps/macos/UnityHost/UnityMediaHost.swift;apps/macos/UnityHost/UnityProductSettings.swift |
| `app.language` | ❌ | ✅ apps/macos/UnityHost/UnityProductSettings.swift |
| `generation.check` | ❌ | ✅ apps/macos/UnityHost/UnityGenerationConfigurationBridge.swift;apps/macos/UnityHost/UnityMediaHost.swift |
| `generation.save` | ❌ | ✅ apps/macos/UnityHost/UnityGenerationConfigurationBridge.swift;apps/macos/UnityHost/UnityMediaHost.swift |
| `inbox.open` | ✅ apps/macos/ProductHost/ProductHost.swift | ❌ |
| `music.connect` | ✅ apps/macos/ProductHost/ProductSettingsParity.swift | ✅ apps/macos/UnityHost/UnityMediaHost.swift |
| `music.disconnect` | ✅ apps/macos/ProductHost/ProductSettingsParity.swift | ✅ apps/macos/UnityHost/UnityMediaHost.swift |
| `music.sync` | ✅ apps/macos/ProductHost/ProductSettingsParity.swift | ✅ apps/macos/UnityHost/UnityMediaHost.swift |
| `presence.activate` | ✅ apps/macos/ProductHost/ProductSettingsParity.swift | ✅ apps/macos/UnityHost/UnityPresenceSettingsBridge.swift |
| `presence.catalog` | ✅ apps/macos/ProductHost/ProductSettingsParity.swift | ✅ apps/macos/UnityHost/UnityPresenceSettingsBridge.swift |
| `presence.import` | ✅ apps/macos/ProductHost/ProductSettingsParity.swift | ✅ apps/macos/UnityHost/UnityPresenceSettingsBridge.swift |
| `presence.import.link` | ✅ apps/macos/ProductHost/ProductSettingsParity.swift | ✅ apps/macos/UnityHost/UnityPresenceSettingsBridge.swift |
| `presence.load` | ✅ apps/macos/ProductHost/ProductSettingsParity.swift | ✅ apps/macos/UnityHost/UnityPresenceSettingsBridge.swift |
| `presence.motion` | ✅ apps/macos/ProductHost/ProductSettingsParity.swift | ✅ apps/macos/UnityHost/UnityMediaHost.swift;apps/macos/UnityHost/UnityPresenceSettingsBridge.swift |
| `presence.motion.import` | ✅ apps/macos/ProductHost/ProductSettingsParity.swift | ✅ apps/macos/UnityHost/UnityPresenceSettingsBridge.swift |
| `presence.motion.install` | ✅ apps/macos/ProductHost/ProductSettingsParity.swift | ✅ apps/macos/UnityHost/UnityPresenceSettingsBridge.swift |
| `presence.motion.remove` | ✅ apps/macos/ProductHost/ProductSettingsParity.swift | ✅ apps/macos/UnityHost/UnityPresenceSettingsBridge.swift |
| `presence.orb.color` | ✅ apps/macos/ProductHost/ProductSettingsParity.swift | ✅ apps/macos/UnityHost/UnityPresenceSettingsBridge.swift |
| `presence.orb.intensity` | ✅ apps/macos/ProductHost/ProductSettingsParity.swift | ✅ apps/macos/UnityHost/UnityPresenceSettingsBridge.swift |
| `presence.position` | ❌ | ✅ apps/macos/UnityHost/UnityMediaHost.swift |
| `presence.position.reset` | ❌ | ✅ apps/macos/UnityHost/UnityMediaHost.swift |
| `presence.remove` | ✅ apps/macos/ProductHost/ProductSettingsParity.swift | ✅ apps/macos/UnityHost/UnityPresenceSettingsBridge.swift |
| `settings.load` | ✅ apps/macos/ProductHost/ProductHost.swift | ✅ apps/macos/UnityHost/UnityMediaHost.swift;apps/macos/UnityHost/UnityProductSettings.swift |
| `shortcuts.cancel` | ✅ apps/macos/ProductHost/ProductSettingsParity.swift | ✅ apps/macos/UnityHost/UnityShortcutSettingsBridge.swift |
| `shortcuts.capture` | ❌ | ✅ apps/macos/UnityHost/UnityShortcutSettingsBridge.swift |
| `shortcuts.global` | ✅ apps/macos/ProductHost/ProductSettingsParity.swift | ✅ apps/macos/UnityHost/UnityShortcutSettingsBridge.swift |
| `shortcuts.media` | ✅ apps/macos/ProductHost/ProductSettingsParity.swift | ✅ apps/macos/UnityHost/UnityShortcutSettingsBridge.swift |
| `shortcuts.record` | ✅ apps/macos/ProductHost/ProductSettingsParity.swift | ✅ apps/macos/UnityHost/UnityShortcutSettingsBridge.swift |
| `shortcuts.reset` | ✅ apps/macos/ProductHost/ProductSettingsParity.swift | ✅ apps/macos/UnityHost/UnityShortcutSettingsBridge.swift |
| `space.default` | ✅ apps/macos/ProductHost/ProductSettingsParity.swift | ✅ apps/macos/UnityHost/UnityMediaHost.swift;apps/macos/UnityHost/UnitySpaceLibraryBridge.swift |
| `space.key.clear` | ✅ apps/macos/ProductHost/ProductSettingsParity.swift | ✅ apps/macos/UnityHost/UnityProductSettings.swift |
| `space.key.save` | ✅ apps/macos/ProductHost/ProductSettingsParity.swift | ✅ apps/macos/UnityHost/UnityProductSettings.swift |
| `space.library.load` | ❌ | ✅ apps/macos/UnityHost/UnityMediaHost.swift;apps/macos/UnityHost/UnitySpaceLibraryBridge.swift |
| `space.library.select` | ❌ | ✅ apps/macos/UnityHost/UnityMediaHost.swift;apps/macos/UnityHost/UnitySpaceLibraryBridge.swift |
| `space.prop.cancel` | ✅ apps/macos/ProductHost/ProductSettingsParity.swift | ❌ |
| `space.prop.check` | ✅ apps/macos/ProductHost/ProductSettingsParity.swift | ❌ |
| `space.prop.save` | ✅ apps/macos/ProductHost/ProductSettingsParity.swift | ❌ |
| `speech.settings.cancel` | ✅ apps/macos/ProductHost/ProductHost.swift | ✅ apps/macos/UnityHost/UnityProductSettings.swift |
| `speech.settings.load` | ✅ apps/macos/ProductHost/ProductHost.swift | ✅ apps/macos/UnityHost/UnityProductSettings.swift |
| `stage.program.back` | ✅ apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift | ❌ |
| `stage.program.load` | ✅ apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift | ❌ |
| `stage.program.more` | ✅ apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift | ❌ |
| `stage.program.play` | ✅ apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift | ❌ |
| `stage.program.replan` | ✅ apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift | ❌ |
| `stage.program.video` | ✅ apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift | ❌ |
| `stage.props.fold` | ✅ apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift | ❌ |
| `stage.props.hold` | ✅ apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift | ❌ |
| `stage.props.load` | ✅ apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift | ❌ |
| `stage.props.resize` | ✅ apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift | ❌ |
| `stage.props.select` | ✅ apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift | ❌ |
| `stage.video.bind` | ✅ apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift | ✅ apps/macos/UnityHost/UnityScreenVideoBridge.swift |
| `stage.video.pending.dismiss` | ✅ apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift | ❌ |
| `stage.video.pending.play` | ✅ apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift | ❌ |
| `stage.video.remove` | ✅ apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift | ✅ apps/macos/UnityHost/UnityScreenVideoBridge.swift |
| `stage.video.toggle` | ✅ apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift | ✅ apps/macos/UnityHost/UnityScreenVideoBridge.swift |
| `stage.video.unbind` | ✅ apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift | ✅ apps/macos/UnityHost/UnityScreenVideoBridge.swift |
| `tts.stop` | ✅ apps/macos/ProductHost/ProductHost.swift | ✅ apps/macos/UnityHost/UnityProductSettings.swift |
| `video.bind` | ❌ | ✅ apps/macos/UnityHost/UnityMediaHost.swift;apps/macos/UnityHost/UnityScreenVideoBridge.swift |
| `video.bound.dismiss` | ❌ | ✅ apps/macos/UnityHost/UnityMediaHost.swift;apps/macos/UnityHost/UnityScreenVideoBridge.swift |
| `video.bound.play` | ❌ | ✅ apps/macos/UnityHost/UnityMediaHost.swift;apps/macos/UnityHost/UnityScreenVideoBridge.swift |
| `video.brightness` | ❌ | ✅ apps/macos/UnityHost/UnityMediaHost.swift;apps/macos/UnityHost/UnityScreenVideoBridge.swift |
| `video.choose` | ❌ | ✅ apps/macos/UnityHost/UnityMediaHost.swift;apps/macos/UnityHost/UnityScreenVideoBridge.swift |
| `video.load` | ❌ | ✅ apps/macos/UnityHost/UnityMediaHost.swift;apps/macos/UnityHost/UnityScreenVideoBridge.swift |
| `video.mode` | ❌ | ✅ apps/macos/UnityHost/UnityMediaHost.swift;apps/macos/UnityHost/UnityScreenVideoBridge.swift |
| `video.pause` | ❌ | ✅ apps/macos/UnityHost/UnityMediaHost.swift;apps/macos/UnityHost/UnityScreenVideoBridge.swift |
| `video.play` | ❌ | ✅ apps/macos/UnityHost/UnityMediaHost.swift;apps/macos/UnityHost/UnityScreenVideoBridge.swift |
| `video.recoverStop` | ❌ | ✅ apps/macos/UnityHost/UnityScreenVideoBridge.swift |
| `video.remove` | ❌ | ✅ apps/macos/UnityHost/UnityMediaHost.swift;apps/macos/UnityHost/UnityScreenVideoBridge.swift |
| `video.select` | ❌ | ✅ apps/macos/UnityHost/UnityMediaHost.swift;apps/macos/UnityHost/UnityScreenVideoBridge.swift |
| `video.stop` | ❌ | ✅ apps/macos/UnityHost/UnityMediaHost.swift;apps/macos/UnityHost/UnityScreenVideoBridge.swift |
| `video.unbind` | ❌ | ✅ apps/macos/UnityHost/UnityMediaHost.swift;apps/macos/UnityHost/UnityScreenVideoBridge.swift |

## 8. 无法机械判定的部分（如实列出）

1. **运行时拼接的 op**（9 个发出点）不在这条门禁的字面量口径内，只能人工追踪：
   `settings.rs:597/611/613/615`（`marble_command` 的 `json!({"op": op, …})`，
   实参来自调用点 `space.marble.{generate,resume,import,cancel}`）、
   `settings.rs:1572`（`format!("{section}.provider")`）、
   `stage_panels.rs:702/1174`、`stage_panels/program.rs:1198`（`json!({"op": op, "id": …})`，
   `op` 来自按钮表）、`stage_panels/props.rs:607`（`format!("stage.props.{action}")`）。
   这些分支的取值我逐条读过并记在 §5，但门禁只能用字面量集合近似。
2. **一个 op 的字段由哪个模式读**：门禁只能证明「有人读」，不能证明「当前运行的宿主读」。
   §7 的模式表是文本级判定（`case`/`supportedCommands` 命中），不含运行时分支
   （例如 `if unity_external`、`snapshot["x"]` 是否非空才渲染）。
3. **字段的语义/取值域**：门禁比的是字段名存在性，不比取值域。例如
   `stage.video.brightness` 的 `value` 在 `GMGNRadioApp.swift:888` 被限定
   `(0.15...1)`、在 `UnityScreenVideoBridge.swift:290` 被限定 `(0...1)` ——
   **同一个 op 在两个宿主的合法区间不同**，UI 发 `value=0.2` 在 Unity 侧会被拒。
   这类「同名字段、不同取值域」需要人读常量，本轮没有机械化。
4. **类型一致性**：`apps/gpui-ui/src` 的 JSON 是动态 `Value`，门禁只能记录
   `expr`/`string`/`number`/`bool`，不能证明 Swift 侧 `as? Double` 一定成功。
   例如 `presence.orb.color` 的 `red/green/blue` 在 UI 是 `expr`（`f32` 渲染成 JSON
   number），宿主读 `as? NSNumber`；这类需要跑起来才能确认。
5. **taskd 方法名字面量之外的调用点**：157 条字面量之外的调用都用变量传递
   （`transport.call(method: method, …)`），变量最终取值在子模块里。门禁只能验证
   字面量；`daemon.rs` 里那 236 个臂与子模块方法族的**语义**对应关系是人工核对的。
6. **孤儿模块是否真的会被链接**：我用的是「`main.rs` 的 `mod` 列表里没有」这一机械证据。
   若构建脚本另有 `--cfg` 或另一个 bin target 引入它们，结论要改；本仓 `Cargo.toml`
   只有一个默认 bin（`src/main.rs`），没有 `[[bin]]`。
7. **旧门禁 `op_coverage.rs` 的 `UNITY_HOST_ONLY_OPS` 与新口径的差集**（机械算出，供后续收口）：
   该表 16 条里有 **4 条**（`space.marble.{generate,resume,import,cancel}`）指向的字面量已经
   不在 production op 面里（`settings.rs:597-615` 是 `json!({"op": op, …})` 的运行时拼接，
   实参在调用点；`settings.rs:4469-4488` 的显式字面量全部落在 `#[cfg(test)]` 内）；
   而 production 面上的 10 个 `video.*` op 一条都没登记（原因见 §5.1 #5 的子串假阴性）。
8. **SwiftUI/AppKit 侧的下游**：op 进入宿主后是否真的落到 authority（taskd 方法）
   只对「显式调用 taskd 客户端」的那部分做了证据；纯本地模型（`presence.*`、
   `shortcuts.*`、`space.default`）的终端是 `UserDefaults`/系统 API，不在本文范围。
9. **Unity `.cs` 侧**：`apps/unity-player/Assets/**` 只有本地化资源与 `ProjectSettings`，
   本轮的 op 处理者全在 Swift/Rust；C# 侧没有独立的 op 分支可对齐。

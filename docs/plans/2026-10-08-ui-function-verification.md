# UI 全功能清单 · 接线与验收状态（2026-10-08）

本文件只做两件事：把这一层 UI **所有用户可执行操作**逐条抽出来，并给每一条一个**可审计的验收状态**。
所有行都来自代码抽取（脚本见附录 A），不是印象。**已验 = 0**：本轮全程只读、未启动 app，唯一在案的真机证据见 §7。

工作目录 `/Users/ghostcorn/.codex/worktrees/rust-full-migration/gmgnradio`，分支 `codex/rust-full-migration`，HEAD `88bb67a`。
审计时该 worktree **正被协作者并发修改**（同一会话内 `inventory_ui.rs` 从 113 行变为 1183 行、后又变更一次）。为可复现，抽取针对 2026-10-08T11:47Z 起建立的只读快照 `/tmp/ui-audit-snapshot`（289 个文件，逐个 sha256 见 `/tmp/ui-audit-snapshot.sha256`）：

| 文件 | sha256（审计快照） |
| --- | --- |
| `apps/gpui-ui/src/settings.rs` | `355b7479864750d8a93696becaa51cf2a54634b493b8c0a0676ec1692c1bde87` |
| `apps/gpui-ui/src/stage_panels.rs` | `223992a6ed18209e92952922068d8dadb34749208066c56b75c89ab7ba326f40` |
| `apps/gpui-ui/src/stage_panels/props.rs` | `3ad702e94a4d6c6e84e20aa9b5615c5c2e2ec98a8f8213497ecd7346ff26b734` |
| `apps/gpui-ui/src/stage_panels/program.rs` | `35ea1a917a7a294940df1b02232c5c2530a04033b1e257df2fa4e4eae46fb5a6` |
| `apps/gpui-ui/src/chat.rs` | `8f3133a760eeaa470bee9b411370f4c4d858075598948ad9636de0115632ed55` |
| `apps/gpui-ui/src/inbox.rs` | `7be46cf5aa61f7fd47ea66d89969c32b9ef14bcb74d85d7b6de6e313df47f43d` |
| `apps/gpui-ui/src/lyrics.rs` | `1fc54c233d60fcca91fac34d3881d0609c364b5070b28fd2fa9dbdfda0c12d25` |
| `apps/gpui-ui/src/i18n.rs` | `667b0d862fb6ffc0a3bdb8618c26725b1cac210a0406b98c3ca1b5cced92bbcf` |
| `tools/fixtures/.../src/lib.rs` | `3a05a54f60b8e8635b5bf2d47a7bb1c7b2bf71081b21c271daa1f5ffb8610d79` |
| `tools/fixtures/.../src/shell_ui.rs` | `25a5b2e9cd87c4db9f7ff29b5c0d6363f03be5854915e704636aaad74b6fc79f` |
| `tools/fixtures/.../src/settings_ui.rs` | `abd72dde41fea737017c2633f36854f26780a76aa53b682c3b8f6cd39c275c36` |
| `tools/fixtures/.../src/media_ui.rs` | `7c9285c534ff778b42ceac8b43c9bbe1e22cf2241ba49b09bc8fd961062f96df` |
| `tools/fixtures/.../src/inventory_ui.rs` | `0667dca67f3bdcaf2427d3ba8a4e95bba5525e60ab371fa549d8cd7a9d042140` |
| `apps/macos/UnityHost/UnityMediaHost.swift` | `0981f92a93c92888048865ad08a4947ba13ea61e4b55310d6146cf6c83afc7b8` |

> 若这些哈希与当前工作区不一致，本文的行号与结论只对快照成立，必须重跑 `tools/audit-ui-function-inventory.py`。
> 交接时（2026-10-08 19:5x）复核：289 个快照文件中只有 `OV/inventory_ui.rs` 又被协作者改动（1218 行，sha256 `606a9bc9e097a195069d21ff35031f4b0cd94f460a1e48050a73d55b98c47778`）；其 `translate` 臂集合与快照相同，但行号整体 +7。因此 §3.5/§4 里所有 `inventory_ui.rs` 行号仅对快照版本 `0667dca6…` 成立，结论（含 `_ => None` 丢弃 `stage.props.resize`/`stage.props.close`）不变。

文件名缩写：`UI/` = `apps/gpui-ui/src/`；`OV/` = `tools/fixtures/gpui-unity-overlay-probe/src/`；`UH/` = `apps/macos/UnityHost/`；`PH/` = `apps/macos/ProductHost/`；`APP/` = `apps/macos/Sources/GMGNRadio/App/`；`CS/` = `apps/unity-player/Assets/GMGN/`。

---

## 1. 验收口径（本标准先于结论）

一条 UI 功能只有在**三层全部有真机读回**时才算过；缺任何一层都是未达标。

| 层 | 含义 | 可用的读回证据 |
| --- | --- | --- |
| L1 点得着 | 控件在真实窗口里可命中、可点击/可输入 | 截图 + 命中日志（如 `[GPUIOverlay] geometry`、`hasHitTest`） |
| L2 发得出 | 命令真的离开 UI 队列并到达宿主处理链 | `Player.log` 的宿主日志/回执、`unityUICommandResult`、`settingsCommandResult` |
| L3 读得回 | **权威/生产状态发生可见变化**：真实回复、真实歌曲、目录与世界一致、重启后仍生效、歌词真显隐、摆放真的落位 | 生产 authority 的快照/日志变化，重启后复现 |

**明确不算通过**（写进标准，防止"假装验收"）：

- UI 渲染出来（截图上看得见）—— 只算 L1，不算功能。
- 命令被 UI 自己收下（写入 `UiCommandQueue`、`take_commands()` 返回了值、单元测试断言了 JSON）—— 只算 L2 的一半。
- 编译通过、`cargo check`/`xcodebuild` 成功、单测通过 —— 与用户可用无关。
- `return true` / `"accepted"` / "请求已发送，等待回执" —— 只是**受理**，不是**完成**；必须等到对应 authority 的确认快照。
- 只改本地 UI 状态（选中行、折叠、路由）而不改生产状态的操作，不能标"已验"，只能标"已接未验（本地）"。

三态定义：

- **未接**：UI 有控件/会发出 op，但当前正式路径里没有任何处理者会把它变成生产动作（被白名单挡住、被适配层丢弃、组件根本未挂载）。
- **已接未验**：有处理者且确实调用 authority，但**没有真机读回证据**。
- **已验**：有真机读回证据证明 L1+L2+L3 都成立。

---

## 2. 正式路径（判定"接没接"的前提）

正式包路径（交接 §3）：

```
Unity Player
  → apps/macos/UnityHost（生产快照 / 命令 / DSH）
  → tools/fixtures/gpui-unity-overlay-probe
      host/OverlayHost.m        NSView 挂载、命中区、透明、resize
      src/lib.rs                同一 GPUI runtime；快照投影；独立设置窗；队列
      src/shell_ui.rs           浮动栏 / 目的地 / 面板
      src/media_ui.rs           音乐库·队列·节目·电视·消息·愿望
      src/inventory_ui.rs       物品（内嵌 ResidentPropEditorPane）
      src/settings_ui.rs        设置窗（内嵌 AgentSettingsPane + StagePanelsPane）
  → apps/gpui-ui（新组件）
```

命令回程：UI 队列 → `gmgn_gpui_chat_take_command`（`OV/lib.rs:566`）→ Unity `CS/GPUIChat2Probe.cs:97` 轮询 → 本地面板/放置/相机重置，其余 `backend.SendGPUICommand`（`CS/GPUIChat2Probe.cs:142`）→ `gmgn_unity_host_command` → `UH/UnityMediaHost.swift:1011 command(_:)` 或 `:1433 settingsCommand(_:)`。

**实际挂载的组件**（`OV/lib.rs:256-266`、`OV/settings_ui.rs:31-36`、`OV/media_ui.rs:341-342`、`OV/inventory_ui.rs:570`）：

| 组件 | 挂载点 | 状态 |
| --- | --- | --- |
| `ResidentChatPane`（UI/chat.rs） | lib.rs:256 | 已挂载 |
| `AgentSettingsPane`（UI/settings.rs） | settings_ui.rs:32 | 已挂载（在独立设置窗内） |
| `StagePanelsPane`（UI/stage_panels.rs） | settings_ui.rs:31 | 已挂载（设置窗“舞台设置”页） |
| `StageProgramRailPane`（UI/stage_panels/program.rs） | media_ui.rs:341 | 已挂载 |
| `InboxPane`（UI/inbox.rs） | media_ui.rs:342 | 已挂载 |
| `ResidentPropEditorPane`（UI/stage_panels/props.rs） | inventory_ui.rs:570 | 已挂载 |
| `StageLyricsPane` / `StageBoundVideoPromptPane`（UI/lyrics.rs） | 只在 `apps/gpui-app/src/main.rs:1422-1423` | **未挂载**（正式路径没有） |

`apps/gpui-app` 与 `PH/ProductHost.swift`、`APP/GMGNRadioApp.swift` 是独立实验入口，**不是** Unity 正式包入口；本文把它们的 case 只当"另一条路径的参考处理者"，不算正式路径已接。

**设置窗的硬白名单**：`OV/settings_ui.rs:80-83` 只转发出现在快照 `supportedCommands` 里的 op，其余提示“当前运行时不支持此操作”后 `continue`。
白名单来自 `UH/UnityMediaHost.swift:1572-1581` + 5 个 bridge 的 `supportedCommands`（共 **92** 条），运行时另由 Unity 追加 `stage.camera.reset`（`CS/GPUIChat2Probe.cs:80-81`）。

---

## 3. 功能清单（按面）

状态列只取三态；"本地"表示该 op 只改 UI 自己的状态。全部 157 条顶层 op 见附录 B。

### 3.1 聊天（UI/chat.rs 视图 + UI/state.rs 命令 + OV/lib.rs:432-457 翻译）

| # | 操作 | 控件 id | op | UI 发出点 | 处理者（文件:行） | authority | 状态 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 发送消息（回车/发送键） | `stage.resident-input`（chat.rs:766） | `chat.send` | `UI/state.rs:131` → `OV/lib.rs:435` | `UH/UnityMediaHost.swift:1181`（`case "chat.send"`） | `chat`（RustDSHSessionClient 会话） | 已接未验（真机读回为失败：Player.log:354-356） |
| 2 | 停止本轮回复 | `stage.resident-stop`/`resident-stop`（chat.rs:664/674） | `chat.cancel` | `UI/state.rs:209,292` → `OV/lib.rs:442,449` | `UH/UnityMediaHost.swift:1239` | `chat.cancel(requestID:)` + `residentAutonomy.humanTurnDidFinish` | 已接未验 |
| 3 | 选择图片附件 | `resident-attachment`（chat.rs:628） | `chat.attachments.pick` | `UI/state.rs:253` → `OV/lib.rs:443` | `UH/UnityMediaHost.swift:1036` → `UH/UnityChatImageBridge.swift:22,90` | NSOpenPanel + `ResidentAttachmentStore` | 已接未验 |
| 4 | 粘贴图片 | （快捷键/控件） | `chat.attachments.paste` | `UI/state.rs:258` → `OV/lib.rs:444` | 同上 | NSPasteboard → store | 已接未验 |
| 5 | 移除附件 | `resident-attachments`（chat.rs:524） | `chat.attachments.remove` | `UI/state.rs:270` → `OV/lib.rs:445` | 同上 | store.remove | 已接未验 |
| 6 | 拖入图片（拖拽区） | `stage.resident-image-drop-hint`（chat.rs:728） | `ui.chat.dropRegion` | `OV/lib.rs:210` | `CS/GPUIChat2Probe.cs:113` → `gmgn_unity_chat_image_drop_region` → `UH/UnityChatImageBridge` | 原生拖拽命中区 | 已接未验 |
| 7 | 按住说话 | 浮动栏 `voice`（shell_ui.rs:221） | `voice.press` | `OV/shell_ui.rs:414`、`UI/state.rs:276`→`OV/lib.rs:446` | `UH/UnityMediaHost.swift:1278` → `UH/UnityPushToTalkBridge.swift:44` | push-to-talk ASR | 已接未验（真机读回失败：Player.log:399 `asr_connect_failed`） |
| 8 | 松开结束录音 | 同上 | `voice.release` | 同上 | `UH/UnityPushToTalkBridge.swift:45` | push-to-talk | 已接未验 |
| 9 | 停止朗读 | （回复朗读态） | `tts.stop` | `UI/state.rs:286` → `OV/lib.rs:448` | `UH/UnityMediaHost.swift:1039` → `UnityProductSettings.command` | reply speech | 已接未验 |
| 10 | 复制居民回复 | `copy-resident-reply`（chat.rs:485） | 无 op | `UI/chat.rs:495` `write_to_clipboard` | GPUI 平台剪贴板 | 系统剪贴板 | 已接未验（本地，无 authority） |
| 11 | 聚焦输入框 | `stage.resident-input` | 无 op（`FocusInput`） | `UI/state.rs:296` → `OV/lib.rs:453` 返回 `None` | `UI/chat.rs` 本地聚焦 | 本地窗口焦点 | 已接未验（本地） |
| 12 | 输入上下文同步（光标/输入法态） | — | `ui.textInput` | `OV/lib.rs:163` | `UH/UnityMediaHost.swift:1038` → `UnityShortcutSettingsBridge.updateTextInput:21` | `GMGNShortcutCoordinator.setTextInputActive` | 已接未验（真机仅 `hostFocus:accepted`，见 §7） |
| 13 | 通过路径导入附件 | — | 无 op（`ImportAttachments`） | `UI/state.rs:263` → `OV/lib.rs:455` 明确 `None` | 无（注释：只接受原生拖拽/选择） | — | **未接**（设计上无通道） |
| 14 | 系统消息/送达/状态提示 | `stage.resident-status-notice`（738）、`stage.resident-delivery-notice`（743） | 无 op | 渲染自快照 | 只读投影 | — | 非操作（只读展示） |

### 3.2 系统消息（UI/inbox.rs + OV/media_ui.rs:107-148,400,417）

| # | 操作 | 控件 id | op | UI 发出点 | 处理者 | authority | 状态 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 打开消息页（拉列表） | `media-sections`（media_ui.rs:742） | `inbox.list` | `OV/media_ui.rs:400` | `UH/UnityMediaHost.swift:1086` → `UH/UnityInboxBridge.swift:117` | `inbox.command`（InboxAuthority） | 已接未验 |
| 2 | 打开一条消息（已读） | `resident.system-inbox.open`（inbox.rs:494/498） | `inbox.open`→`inbox.read` | `UI/inbox.rs:202` → `OV/media_ui.rs:417,142` | `UH/UnityMediaHost.swift:1086` → `UH/UnityInboxBridge.swift:81` | `inbox.command`（taskKey+expectedEventID） | 已接未验 |
| 3 | 刷新 | `media-refresh`（media_ui.rs:757） | `inbox.list` | 同上 | 同上 | 同上 | 已接未验 |
| 4 | 消息详情/正文 | `resident.system-inbox.detail`（438）、`.detail-text`（488）、`.list`（382） | 无 op | 只读投影 | — | — | 非操作 |

### 3.3 设置五页（UI/settings.rs，经 OV/settings_ui.rs 白名单）

页签：角色 / 音乐 / 空间 / 快捷键 / DJ（`UI/settings.rs:124-150` `settings_tabs()`）。全部经同一队列 `OV/settings_ui.rs:94` 包成 `ui.settings.command`，宿主 `UH/UnityMediaHost.swift:1012` 处理，`settingsCommand`（:1433）分发。

| 页 | 操作 | 控件 id | op | UI 发出点 | 正式路径处理者 | authority | 状态 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 全部 | 打开/重新读取设置 | `settings-refresh`（settings_ui.rs:222）、`settings-root`（settings.rs:4328） | `settings.load` | `UI/settings.rs:1201` | `UH/UnityMediaHost.swift:1445` | musicLibrary/presence/agent/productSettings 重载 | 已接未验 |
| 角色 | 导入角色模型 | `presence-import`（4039）、`presence.import`（4045） | `presence.import` | `UI/settings.rs:4056` | `UnityPresenceSettingsBridge.swift:18,147` | PresencePackageStore | 已接未验 |
| 角色 | 从链接导入 | `import-link`（979）、`settings.presence.import.url`（937） | `presence.import.link` | `UI/settings.rs:988` | `UnityPresenceSettingsBridge.swift:175` | 下载 + PresencePackageStore | 已接未验 |
| 角色 | 刷新目录 | `catalog-refresh`（2569）、`settings.presence.catalog`（2564） | `presence.catalog` | `UI/settings.rs:1134,2579` | `UnityPresenceSettingsBridge.swift:168` | 目录 registry | 已接未验 |
| 角色 | 切换动作 | `motion-categories`（stage_panels.rs:865）/角色页动作行 | `presence.motion` | `UI/settings.rs:2524` | `UH/UnityMediaHost.swift:1467` | `presenceSettings.command` + `worldSession.prepareManualMotionSelection` | 已接未验 |
| 角色 | 导入/安装/移除动作 | 角色页动作区 | `presence.motion.import` / `.install` / `.remove` | `UI/settings.rs:4064,2652,2540` | `UnityPresenceSettingsBridge.swift:148,171,165` | MotionPackageStore | 已接未验 |
| 角色 | 应用/删除角色 | 角色页列表 | `presence.activate` / `presence.remove` | `UI/settings.rs:2366,2382` | `UnityPresenceSettingsBridge.swift:149,156` | 角色运行时 | 已接未验 |
| 角色 | 光球颜色/强度 | 角色页光球区 | `presence.orb.color` / `.intensity` | `UI/settings.rs:1166,1173` | `UnityPresenceSettingsBridge.swift:182` | 视觉方向 | 已接未验 |
| 角色 | 角色站位应用/复位 | `character-position-apply`（1828）/`-reset`（1869） | `presence.position` / `.reset` | `UI/settings.rs:1856,1883` | `UH/UnityMediaHost.swift:1035,1440` → `UnityCharacterPositionBridge.swift:73` | 世界角色位置 | 已接未验 |
| 音乐 | 连接/断开/同步账号 | 音乐页 provider 行 | `music.connect` / `disconnect` / `sync` | `UI/settings.rs:2826,543` | `UH/UnityMediaHost.swift:1474` → `UnityMusicLibraryBridge` | 音乐账号 authority | 已接未验 |
| 空间 | 载入/选择空间库 | 空间页列表 | `space.library.load` / `.select` / `space.default` | `UI/settings.rs:1247,3019,1576` | `UH/UnityMediaHost.swift:1442` → `UnitySpaceLibraryBridge` | 空间库 | 已接未验 |
| 空间 | 保存/清除 Marble key | `marble-save`（2937） | `space.key.save` / `.clear` | `UI/settings.rs:2955,2932` | `UH/UnityProductSettings.swift:109,115` | 私有文件 key 存储 | 已接未验 |
| 空间 | Marble 生成/续跑/导入/取消 | `marble-*`（2937-3171） | `space.marble.*` | `UI/settings.rs:4469-4488` | `UnityMarbleWorldBridge.swift:35,83-85` | Rust marble control（`services/gmgn-taskd/src/marble_control.rs:729`） | 已接未验 |
| 空间 | 许愿机 endpoint/key 保存 | `prop-save`（2248） | `space.prop.save` | `UI/settings.rs:2267` | **无**：不在 92 条白名单 → `OV/settings_ui.rs:80-83` 拦下 | —（只在 PH/ProductSettingsParity.swift:203） | **未接（白名单拦）** |
| 空间 | 许愿机连通性检查 | `prop-check`（2226） | `space.prop.check` | `UI/settings.rs:2244` | **无**（同上；PH/ProductSettingsParity.swift:207） | — | **未接（白名单拦）** |
| 空间 | 取消许愿机编辑 | （dismissed） | `space.prop.cancel` | `UI/settings.rs:1142,1149,1240` | **无**（同上；PH/ProductSettingsParity.swift:204） | — | **未接（白名单拦）** |
| 空间 | 生成服务 endpoint/key/检查 | `generation-save`（2164）/`generation-check`（2141） | `generation.save` / `generation.check` | `UI/settings.rs:2176,2159` | `UnityGenerationConfigurationBridge.swift:35,40` | Rust generation authority | 已接未验 |
| 快捷键 | 录制/捕获/取消/重置 | shortcuts 页行 | `shortcuts.record` / `.capture` / `.cancel` / `.reset` | `UI/settings.rs:3321,480,403,3380` | `UnityShortcutSettingsBridge.swift:12,40,56` | `GMGNShortcutSettingsStore` | 已接未验 |
| 快捷键 | 全局/媒体键开关 | `settings.shortcuts.global`（3333）/`.media`（3348） | `shortcuts.global` / `.media` | `UI/settings.rs:3343,3358` | `UnityShortcutSettingsBridge.swift:61` | 快捷键协调器 | 已接未验 |
| DJ | Codex 登录/退出 | `codex-login`（3448） | `agent.login` / `agent.logout` | `UI/settings.rs:3468,3470` | `UnityAgentConnectionBridge.swift:16` + `UH/UnityMediaHost.swift:1450` | Codex 账号服务 | 已接未验 |
| DJ | 保存人格/规划模型/自主行动 | `save-resident`（3582）/`save-dj`（3539）/`settings.agent.*` | `agent.save` | `UI/settings.rs:1160,1579,1716` | `UH/UnityMediaHost.swift:1451` → `UnityAgentConnectionBridge.swift:44` + `UnityProductSettings` | 账号 + 产品设置 | 已接未验 |
| DJ | 语音 provider/模型/试听/刷新 | `save-tts`（3843）/`preview-tts`（3725）/`refresh-voices`（3716） | `tts.save` / `.preview` / `.refresh` | `UI/settings.rs:3850,3760,3722` | `UH/UnityProductSettings.swift:159,162` | Rust 语音能力 + 试听 | 已接未验 |
| DJ | 保存 ASR 配置 | `save-asr`（3908） | `asr.save` | `UI/settings.rs:3917` | `UH/UnityProductSettings.swift:145` | 语音配置 | 已接未验 |
| DJ | 语音能力读取/取消 | — | `speech.settings.load` / `.cancel` | `UI/settings.rs:1279,1124,1237,1329` | `UH/UnityProductSettings.swift:122,179` | 能力目录 | 已接未验 |
| DJ | 界面语言 | `settings-language`（4081）/`settings.language`（4085） | `app.language` | `UI/i18n.rs:47 language_command`（由 `UI/settings.rs:4095` 调用） | `UH/UnityProductSettings.swift:119` | 产品设置 locale | 已接未验 |
| DJ | 触发“让居民去取”等待入口 | `settings.stage-sections`（3956）、`unity-video-*`（1918/1961） | `settings.open.presence` | `UI/stage_panels.rs:980` | **无**：不在白名单；只在 `PH/ProductHost.swift:298` | — | **未接（白名单拦）** |

> 说明：设置五页共抽取到 85 条 op（`settings.rs` 与 `stage_panels.rs`），其中 **12 条被白名单拦下**（上表 4 条 + §3.4 的 8 条）。

### 3.4 舞台设置四分区（UI/stage_panels.rs，挂在设置窗内）

分区（`UI/stage_panels.rs:72` `STAGE_TABS`）：播放器 / 空间 / 角色 / 活动。

| 分区 | 操作 | 控件 id | op | UI 发出点 | 处理者 | authority | 状态 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 播放器 | 歌词视觉模式 | `stage-tabs`/player 模式选择（1543） | `stage.player.lyrics` | `UI/stage_panels.rs:1103` | `UH/UnityMediaHost.swift:1088,1476` → `settingsVisualCommand` | `lyricsStore.setVisualMode` | 已接未验 |
| 播放器 | 点云风格 | `stage-particle-size`（1212）区 | `stage.player.cloud` | `UI/stage_panels.rs:1117` | `UH/UnityMediaHost.swift:1090,1477` | `visualDirection.selectPointCloud` | 已接未验 |
| 播放器 | 粒子大小 | `stage-particle-size`（1212） | `stage.player.particles` | `UI/stage_panels.rs:414` | `UH/UnityMediaHost.swift:1090,1479` | `visualDirection.setParticleSizeMultiplier` | 已接未验 |
| 播放器 | 视频加载/绑定/解绑 | `stage-video-*`、`video-assets-menu`（1385） | `stage.video.toggle`/`bind`/`unbind` | `UI/stage_panels.rs:318,329,353-370` | `UH/UnityMediaHost.swift:1443` → `UnityScreenVideoBridge` | 屏幕视频 store | 已接未验 |
| 播放器 | 视频播放/停止/恢复/模式/亮度/导入/移除 | `stage-video-brightness`（1352）、`stage-video-authority-notice`（1319）等 | `stage.video.import`/`mode`/`stop`/`recoverStop`/`brightness`/`bind`/`unbind`/`toggle`；播放控制为 `video.play`（设置页） | `UI/stage_panels.rs:1255-1328`；`UI/settings.rs:1947`（`video.play`） | `UnityScreenVideoBridge.swift:12,231-300` | 同上 | 已接未验 |
| 空间 | 载入舞台 | — | `stage.load` | `UI/stage_panels.rs:425` | `UH/UnityMediaHost.swift:1087,1475` `case "stage.load": return true` | **无（假成功，见 §4）** | 已接未验（受理但无动作） |
| 空间 | 进入世界 | `stage-world-menu`（673） | `stage.world.enter` | `UI/stage_panels.rs:692` | **无**：不在白名单（只在 `APP/GMGNRadioApp.swift:830`） | — | **未接（白名单拦）** |
| 空间 | 激活世界 | `stage-world-menu`（673） | `stage.scene.activate` | `UI/stage_panels.rs:693` | **无**（`APP/GMGNRadioApp.swift:838`） | — | **未接（白名单拦）** |
| 空间 | 打开角色页 | — | `settings.open.presence` | `UI/stage_panels.rs:980` | **无**（`PH/ProductHost.swift:298`） | — | **未接（白名单拦）** |
| 角色 | 角色位置/复位 | — | `stage.avatar.position` / `.reset` | `UI/stage_panels.rs:413,790` | **无**（`APP/GMGNRadioApp.swift:846,853`） | — | **未接（白名单拦）** |
| 角色 | 刷新动作列表 | `motion-categories`（865） | `stage.motion.refresh` | `UI/stage_panels.rs:450,846,1566` | **无**（`PH/ProductHost.swift:284`） | — | **未接（白名单拦）** |
| 角色 | 应用动作 | — | `stage.motion.activate` | `UI/stage_panels.rs:941` | **无**（`PH/ProductHost.swift:287`） | — | **未接（白名单拦）** |
| 角色 | 复位相机 | — | `stage.camera.reset`（包在 `ui.settings.command` 内） | `UI/stage_panels.rs:808` | `CS/GPUIChat2Probe.cs:105-110`（Unity 本地）→ `world.ResetPresentationCamera()` | Unity 表现相机 | 已接未验（白名单由 Unity 运行时补入） |
| 活动 | 运行/停止活动 | — | `stage.activity.run` / `.stop` | `UI/stage_panels.rs:1043,1057` | **无**（`APP/GMGNRadioApp.swift:860,864`） | — | **未接（白名单拦）** |

### 3.5 我的物件（UI/stage_panels/props.rs ← OV/inventory_ui.rs:429-546）

| # | 操作 | 控件 id | op | UI 发出点 | 处理者 | authority | 状态 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 载入/刷新物件 | — | `stage.props.load` | `props.rs:261` | `OV/inventory_ui.rs:436` → `wish.status` | `UnityWishMachineBridge.swift:63,71` | 已接未验 |
| 2 | 选择一行 | `resident.ownership-row.{id}`（props.rs:510，动态） | `stage.props.select` | `props.rs:498` | `OV/inventory_ui.rs:445` 只改 `LocalState.selected` | 本地 | 已接未验（本地） |
| 3 | 我的物件/房间里 筛选 | `props-filter`（1105） | `stage.props.filter` | `props.rs:1128` | `OV/inventory_ui.rs:437` 本地 | 本地 | 已接未验（本地） |
| 4 | 折叠/展开“已结束” | `props-ended-fold`（464） | `stage.props.fold` | `props.rs:443,475` | `OV/inventory_ui.rs:441` 本地 | 本地 | 已接未验（本地） |
| 5 | 领取物件 | `resident.ownership-row.{id}.claim`（动态） | `stage.props.claim` | `props.rs:607`（`format!`） | `OV/inventory_ui.rs:449-458` → `wish.claim` | `UnityWishMachineBridge.swift:63,96` | 已接未验 |
| 6 | 重试生成 | `.retry`（动态） | `stage.props.retry` | `props.rs:607` | `inventory_ui.rs:449` → `wish.retry` | 同上:91 | 已接未验 |
| 7 | 重试入库 | `.retry-inventory`（动态） | `stage.props.retryInventoryRegistration` | `props.rs:607` | `inventory_ui.rs:449` → `wish.inventory.retry` | 同上:63 | 已接未验 |
| 8 | 删除（二次确认） | `prop-delete`（1297）/`prop-confirm-delete`（344） | `stage.props.delete` | `props.rs:607` | `inventory_ui.rs:459` → `inventory.delete` | `UH/UnityMediaHost.swift:1046` → `worldSession.command` | 已接未验 |
| 9 | 收回 | `.withdraw`（动态）/持有行 | `stage.props.withdraw` | `props.rs:607`、`props.rs:1268` | `inventory_ui.rs:470` → `world.prop.command{withdraw}` | `UH/UnityMediaHost.swift:1091` → Rust `world_prop.rs:1258` | 已接未验 |
| 10 | 挂点（右手/背后/腰间） | `prop-hold-points`（647） | `stage.props.hold{point}` | `props.rs:662` | `inventory_ui.rs:474` → `world.prop.command{hold}` | Rust `world_prop.rs:1263` | 已接未验 |
| 11 | 拿着看（进入摆放） | 持有行按钮（props.rs:1258） | `stage.props.hold`（无 point） | `props.rs:1260` | `inventory_ui.rs:486` → `ui.inventory.place` | `CS/GPUIChat2Probe.cs:125-128` → `world.BeginInventoryPlacement` | 已接未验 |
| 12 | 放回 | — | `stage.props.return` | `props.rs:1236` | `inventory_ui.rs:491` → `world.prop.command{returnHeld}` | Rust world prop | 已接未验 |
| 13 | 微调 Y/Z | — | `stage.props.nudge` | `props.rs:1207` | `inventory_ui.rs:495` → `adjustGrip`（需持久化 grip） | Rust world prop | 已接未验 |
| 14 | 左转/右转 15° | — | `stage.props.rotate` | `props.rs:1219,1227` | `inventory_ui.rs:516` → `adjustGrip` | Rust world prop | 已接未验 |
| 15 | 撤销布局 | — | `stage.props.undo` | `props.rs:1404` | `inventory_ui.rs:539` → `world.prop.command{undo}` | Rust `world_prop.rs:1209` | 已接未验 |
| 16 | 尺寸滑块 / ±1cm / ±10cm | `prop-size-slider`（729） | `stage.props.resize` | `props.rs:239,699` | `inventory_ui.rs:543`（`_ => None`） | **无** | **未接（静默丢弃）** |
| 17 | 关闭物件面板 × | `props-close`（1443） | `stage.props.close` | `props.rs:1458` | `inventory_ui.rs:543`（`_ => None`） | **无** | **未接（静默丢弃）** |
| 18 | 让居民去取（置灰） | `props-{id}-claim-unavailable`（props.rs:588） | 不发出 | `props.rs:585-596` `.disabled(true)` | — | — | 非操作（禁用态，注释明确无 Unity op） |

### 3.6 节目轨道（UI/stage_panels/program.rs ← OV/media_ui.rs:408-498）

| # | 操作 | 控件 id | op | UI 发出点 | 处理者 | authority | 状态 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 面板初始化请求 | `stage-program-rail`（1563/1748） | `stage.program.load` | `program.rs:1012` | `OV/media_ui.rs:425` `=> {}` | **无**（有意 no-op，改由面板 refresh 发 `music.library`/`music.program.history`） | 已接未验（受理无动作） |
| 2 | 打开节目/歌单目录 | 目录行（program.rs:1737/1738） | `stage.program.open` / `stage.playlist.open` | `program.rs:1737-1738` | `media_ui.rs:426,441`（本地路由 + `music.playlist`） | 生产目录快照 | 已接未验 |
| 3 | 返回目录 | — | `stage.program.back` | `program.rs:1620` | `media_ui.rs:455` 本地路由 | 本地 | 已接未验（本地） |
| 4 | 加载更多 | — | `stage.program.more` | `program.rs:1530` | `media_ui.rs:461` → `music.playlist` | `UnityMediaHost.swift:1113` | 已接未验 |
| 5 | 播放某一轨 | 投影卡片（`stage-program-card-prepare`154） | `stage.program.play` | `program.rs:1200` | `media_ui.rs:466` → `music.program.play` 或 `music.playlist.play` | `UH/UnityMediaHost.swift:1101`（`djProgram.selectProgram`）/`:1116`（`musicLibrary.play`） | 已接未验 |
| 6 | 播放该轨绑定视频 | 同上 | `stage.program.video` | `program.rs:1202,1408` | `media_ui.rs:476` → `video.bound.play`（仅当 `pendingBoundVideo.trackID` 匹配；否则静默） | `UH/UnityMediaHost.swift:1443` | 已接未验（条件性静默丢弃） |
| 7 | 重新编排 | — | `stage.program.replan` | `program.rs:1643,1727` | `media_ui.rs:492` 只写提示 | **无**（注释：生产 replan 由居民代理工具 `replan_program` 执行） | **未接（无 host op）** |

### 3.7 产品外壳（浮动栏 / 目的地 / 任务状态 / 小窗 / 命中区）

实现：`UI/shell.rs`（共享 chrome）+ `OV/shell_ui.rs`（行为）+ `OV/host/OverlayHost.m`（挂载/命中/透明）。

| # | 操作 | 控件 id | op | UI 发出点 | 处理者 | authority | 状态 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 播放/暂停 | `stage.transport`（shell.rs:143）/ `TransportControl::new(id,id,…)`（shell_ui.rs:265） | `music.play` / `music.pause` | `OV/shell_ui.rs:16-31,194` | `UH/UnityMediaHost.swift:1168,1171` | `player.play/pause` + `musicPlayback` | 已接未验 |
| 2 | 上一首 / 下一首 | 同上（`previous`/`next`） | `music.previous` / `music.next` | `shell_ui.rs:15-16` | `UH/UnityMediaHost.swift:1164,1155` | `musicPlayback.navigate` / `musicLibrary.select` | 已接未验 |
| 3 | 音量滑块 | 媒体面板内 Slider（shell_ui.rs:348） | `music.volume` | `shell_ui.rs:83` | `UH/UnityMediaHost.swift:1177` | `graph.musicVolume` | 已接未验 |
| 4 | 聊天面板开关 | `chat` 控件（shell_ui.rs:222） | 本地面板切换 + `ui.overlay.panel` | `shell_ui.rs:105-108,190` | `CS/GPUIChat2Probe.cs:118-120` → `gmgn_overlay_set_panel_expanded` | OverlayHost 命中/尺寸 | 已接未验 |
| 5 | 音乐与节目面板 | `program`（shell_ui.rs:209） | `ui.overlay.panel` + `select_media_section("programs")` | `shell_ui.rs:174-188` | 同上 + `OV/lib.rs:225` | 同上 | 已接未验 |
| 6 | 通知/消息面板 | `inbox`（shell_ui.rs:223） | 同上（section `inbox`） | 同上 | 同上 | 同上 | 已接未验 |
| 7 | 电视面板 | `screen`（shell_ui.rs:226） | 同上（section `screen`） | 同上 | 同上 | 同上 | 已接未验 |
| 8 | 物品面板 | `props`（shell_ui.rs:225） | 本地面板切换 | `shell_ui.rs:191` | `OV/inventory_ui.rs` | 见 §3.5 | 已接未验 |
| 9 | 设置（独立窗口） | `visual`（shell_ui.rs:227，face_text“设置”） | `ui.settings.open` | `shell_ui.rs:192` → `lib.rs:591-593` | `OV/lib.rs:377-415 open_settings_window`（同 runtime 860×700） | 独立 GPUI 窗口 | 已接未验 |
| 10 | 歌词显隐 | `lyrics`（shell_ui.rs:224）+ 媒体面板 `media-lyrics`（352） | `ui.lyrics.toggle` | `shell_ui.rs:193,358` | `CS/PlayerScreen.cs:105` → `ToggleLyrics()` | Unity 歌词渲染 | 已接未验（交接 §5.4：候选 221 尚无该按钮） |
| 11 | 全屏/窗口切换 | `mode`（shell_ui.rs:229） | `ui.window.fullscreen` | `shell_ui.rs:194` | `CS/PlayerScreen.cs:108` → `compactWindow.ToggleFullscreen()` | Unity 窗口模式 | 已接未验 |
| 12 | 小窗 | `media-compact`（shell_ui.rs:363） | `ui.window.compact` | `shell_ui.rs:369` | `CS/PlayerScreen.cs:109` → `compactWindow.Toggle()` | Unity 窗口模式 | 已接未验 |
| 13 | 目的地“切换空间” | 目的地按钮（shell.rs:262） | `ui.space.toggle` | `shell_ui.rs:421-428` | `CS/PlayerScreen.cs:106` → `worldRuntime.Toggle()` / `EnterLivecamSpace()` | Unity 世界运行时 | 已接未验 |
| 14 | 按住说话（浮动栏） | `voice`（shell_ui.rs:221） | `voice.press` / `voice.release` | `shell_ui.rs:410-419` | 见 §3.1 #7/#8 | push-to-talk | 已接未验 |
| 15 | Esc 关闭面板 | — | 无 op | `shell_ui.rs:305-314` | `close_panel` → `ui.overlay.panel` | OverlayHost | 已接未验 |
| 16 | 任务状态/错误提示 | — | 无 op | `shell_ui.rs:431-448`（`ui.error`/队列满） | 只读投影 | — | 非操作（只读展示） |
| 17 | 挂载/透明/命中区/尺寸跟随 | — | `ui.overlay.panel`、`ui.overlay.*` C ABI | `OverlayHost.m` / `lib.rs:217-223` | `probe_attach_view` / `probe_native_set_hit_regions` | NSView 层级 | **已验（平台层）**：Player.log:56,57 真机读到 host/donor/mounted=2048×1152、720×450、scale 2、layerOpaque 0 |

### 3.8 歌词（UI/lyrics.rs）

| # | 操作 | 控件 id | op | UI 发出点 | 处理者 | authority | 状态 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 播放绑定视频（提示条） | `bound-video-play`（2795） | `stage.video.pending.play` | `lyrics.rs:2802` | 正式路径**无**；只在 `APP/GMGNRadioApp.swift:569` | — | **未接（组件未挂载）** |
| 2 | 关闭绑定视频提示 | `bound-video-dismiss`（2809） | `stage.video.pending.dismiss` | `lyrics.rs:2722,2818` | 正式路径**无**；`APP/GMGNRadioApp.swift:570` | — | **未接（组件未挂载）** |
| 3 | 歌词显隐 | 见 §3.7 #10 | `ui.lyrics.toggle` | shell_ui | `CS/PlayerScreen.cs:105` | Unity 歌词 | 已接未验 |
| 4 | 歌词动态渲染 | `stage-lyrics-render`（2246） | 无 op（渲染管线） | `lyrics.rs` | 原生 GPU 路径（非本层） | — | 非本层 |

### 3.9 播放器与音乐（OV/media_ui.rs + UH 音乐处理）

| # | 操作 | 控件 id | op | UI 发出点 | 处理者 | authority | 状态 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 进入音乐库（拉歌单目录） | `media-sections`（742）+ 刷新 | `music.library` | `media_ui.rs:387` | `UH/UnityMediaHost.swift:1093` | `musicLibrary.refresh` | 已接未验 |
| 2 | 节目历史 | 同上 | `music.program.history` | `media_ui.rs:388` | `UH/UnityMediaHost.swift:1094` | `djProgram.refreshHistory` | 已接未验（221 截图里出现过真实节目名，但那时渲染的是旧列表） |
| 3 | 选歌（队列） | `queue:{index}`（media_ui.rs:576） | `music.select` | `media_ui.rs:578` | `UH/UnityMediaHost.swift:1159` | `musicPlayback.navigate` | 已接未验 |
| 4 | 选择本地音乐 | `choose-music`（586） | `music.choose` | `media_ui.rs:589` | `UH/UnityMediaHost.swift:1119` → `music.queue` | NSOpenPanel → 播放队列 | 已接未验 |
| 5 | 播放歌单某曲 | 轨道卡片 | `music.playlist.play` | `media_ui.rs:165` | `UH/UnityMediaHost.swift:1116` | `musicLibrary.play` | 已接未验 |
| 6 | 播放节目槽位 | 轨道卡片 | `music.program.play` | `media_ui.rs:162` | `UH/UnityMediaHost.swift:1101` | `djProgram.selectProgram` | 已接未验 |
| 7 | 加载歌单 | 歌单行 | `music.playlist` | `media_ui.rs:452,463` | `UH/UnityMediaHost.swift:1113` | `musicLibrary.readPlaylist` | 已接未验 |
| 8 | 刷新 | `media-refresh`（757） | `music.library`/`music.program.history` | `media_ui.rs:396-398` | 同上 | 同上 | 已接未验 |
| 9 | 播放/暂停/上下一首/音量 | 见 §3.7 | `music.*` | shell_ui | 同上 | 同上 | 已接未验 |

### 3.10 电视与愿望（OV/media_ui.rs + UH/UnityScreenVideoBridge + UnityWishMachineBridge）

| # | 操作 | 控件 id | op | UI 发出点 | 处理者 | authority | 状态 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 列出屏幕 | `media-sections`（电视页） | `screen.list` | `media_ui.rs:399` | `UnityScreenVideoBridge.swift:12,240` | 屏幕播放协调器 | 已接未验 |
| 2 | 选屏 | `screen:{id}`（media_ui.rs:609） | 无 op（本地选中） | `media_ui.rs:614-617` | 本地 | — | 已接未验（本地） |
| 3 | 播放视频链接 | `screen-play`（627） | `screen.play` | `media_ui.rs:631` | `UnityScreenVideoBridge.swift:241` | `NativeScreenPlaybackCoordinator` | 已接未验 |
| 4 | 停止播放 | `screen-stop`（633） | `screen.stop` | `media_ui.rs:633` | `UnityScreenVideoBridge.swift:258` | 同上 | 已接未验 |
| 5 | 视频页操作（加载/选择/播放/暂停/停止/恢复/模式/亮度/绑定/解绑/移除/提示播放/忽略） | `unity-video-play`（settings.rs:1918）、`video-*` 菜单 | `video.load` / `choose` / `select` / `play` / `pause` / `stop` / `recoverStop` / `mode` / `brightness` / `bind` / `unbind` / `bound.play` / `bound.dismiss` | `settings.rs:1181,1317,1914-2077`、`media_ui.rs:485` | `UH/UnityMediaHost.swift:1443` → `UnityScreenVideoBridge.swift:240-300` | 屏幕视频 store | 已接未验 |
| 6 | 愿望状态/列表 | 愿望页 | `wish.status` | `media_ui.rs:401`、`inventory_ui.rs:436` | `UnityWishMachineBridge.swift:63,71` | `coordinator.refresh` + 入库读回 | 已接未验 |
| 7 | 领取物品 | `claim:{wishID}`（media_ui.rs:659） | `wish.claim` | `media_ui.rs:661` | `UnityWishMachineBridge.swift:63,96` | `coordinator.claim` + `confirmInventory` | 已接未验 |
| 8 | 重试加入物品列表 | 同上 | `wish.inventory.retry` | `media_ui.rs:661` | `UnityWishMachineBridge.swift:63` | `confirmInventory` | 已接未验 |
| 9 | 重试生成 | 物件面板 | `wish.retry` | `inventory_ui.rs:452` | `UnityWishMachineBridge.swift:63,91` | `coordinator.retry` | 已接未验 |
| 10 | 在聊天中许愿 | `wish-open-chat`（673） | `ui.chat.open` | `media_ui.rs:676` | `OV/lib.rs:588-607`（本地开面板） | 本地面板 | 已接未验（本地） |

---

## 4. 静默 no-op 清单（最容易"假装通过"的一类）

判定标准：op 有处理串，但处理者 `return false` / `default` 吞掉 / 只改本地 UI / 只回 `true` 而无生产动作。

### 4.1 会被吞掉、用户看得见按钮却什么也不会发生（18 条）

| 类别 | op / 数量 | 吞掉的位置（文件:行） | 现象 |
| --- | --- | --- | --- |
| 设置白名单拦截 | `space.prop.save`、`space.prop.check`、`space.prop.cancel`、`settings.open.presence`、`stage.activity.run`、`stage.activity.stop`、`stage.avatar.position`、`stage.avatar.reset`、`stage.motion.refresh`、`stage.motion.activate`、`stage.scene.activate`、`stage.world.enter`（12） | `OV/settings_ui.rs:80-83`（`continue`，只发本地 notice） | 点“保存/进入世界/应用动作”等只得到“当前运行时不支持此操作”，生产状态不变 |
| 组件未挂载 | `stage.video.pending.play`、`stage.video.pending.dismiss`（2） | 正式路径无处理者（只有 `APP/GMGNRadioApp.swift:569-570`） | `lyrics.rs` 的提示条按钮在正式包里根本不挂载；若挂载也无人处理 |
| 物件适配层丢弃 | `stage.props.resize`、`stage.props.close`（2） | `OV/inventory_ui.rs:543`（`_ => None`，见 :540 注释）；发出点 `props.rs:239,699,1458` | 尺寸滑块/±厘米、面板 × 点了没有任何生产或面板效果 |
| 节目适配层丢弃 | `stage.program.load`、`stage.program.replan`（2） | `OV/media_ui.rs:425`（`=> {}`）、`:492-495`（只写提示） | “重新编排”只弹提示，真正的 replan 在居民代理工具里 |

### 4.2 受理成功但没有任何生产动作（假成功）

| op | 位置 | 说明 |
| --- | --- | --- |
| `stage.load` | `UH/UnityMediaHost.swift:1087` 与 `:1475`：`case "stage.load": return true` | 宿主回 `true`（受理），但不加载任何东西；UI 会认为成功 |

### 4.3 只改本地 UI、不写生产状态（4 条）

| op | 位置 | 影响 |
| --- | --- | --- |
| `stage.props.filter` | `OV/inventory_ui.rs:437-440` | 只改 `LocalState.placed_only` |
| `stage.props.fold` | `OV/inventory_ui.rs:441-444` | 只改 `LocalState.ended_folded` |
| `stage.props.select` | `OV/inventory_ui.rs:445-448` | 只改 `LocalState.selected` |
| `ChatCommand::FocusInput` | `OV/lib.rs:453`（`return None`） | 只在 GPUI 内部移动焦点 |

### 4.4 条件性静默丢弃（有处理者但可能什么都不做）

| op | 位置 | 条件 |
| --- | --- | --- |
| `stage.program.video` | `OV/media_ui.rs:476-488` | 仅当 `screenVideo.pendingBoundVideo.trackID == trackID` 且 prompt 有 `id` 时才发 `video.bound.play`，否则静默 |
| `inbox.open` | `OV/media_ui.rs:417-419` → `inbox_read_command`（:142-148） | 缺 `expectedEventID` 或 id 为空时静默不下发，也不提示 |
| 未知子命令 | `OV/media_ui.rs:496`（`_ => {}`）、`OV/inventory_ui.rs:543`（`_ => None`） | 任何新增/拼错的组件命令都被无声丢弃 |
| 未知设置命令 | `UH/UnityMediaHost.swift:1481` → `UnityProductSettings.swift:183`（`default: return false`） | 不是静默，但只回 `settingsCommandResult.status=failed`，UI 只有通用“设置未保存” |

### 4.5 明确返回 false（不是静默，但值得盯）

| op | 位置 | 说明 |
| --- | --- | --- |
| `music.seek` | `UH/UnityMediaHost.swift:1180` | 当前无 UI 控件发出；若以后加进度条会直接失败 |
| `agent.backend` / `agent.status` | `UH/UnityProductSettings.swift:131` | 该路径在 Unity 正常流程里被 `UH/UnityMediaHost.swift:1450` 提前接管，属死分支 |
| `ChatCommand::ImportAttachments` | `OV/lib.rs:455` → `None` | 注释明确：只接受原生拖拽/选择，不接受任意路径 |

---

## 5. 计数汇总

| 项 | 数量 |
| --- | --- |
| 抽取到的 op 字面量（含伪条目/嵌套 payload 子命令） | **166** |
| 其中：伪条目（只存在于测试/永不发出） | 4（`stage.props.askResidentToFetch`、`stage.props.escape`、`stage.props.toggle`、`stage.props.invented`） |
| 其中：嵌套 payload 子命令（`world.prop.command` 内） | 5（`hold`、`withdraw`、`returnHeld`、`undo`、`adjustGrip`） |
| **顶层 UI op（进入命令队列）** | **157** |
| 控件 id（`.id`/`.accessibility_id`/构造器首参，另含动态 id） | **114** |
| 宿主处理点（case/==/contains/supportedCommands/array-contains） | 1970 |
| 设置窗白名单条目 | 92（运行时 +1 = `stage.camera.reset`） |
| **已验** | **0** |
| **已接未验** | **139** |
| **未接** | **18**（白名单拦 12 + 组件未挂载 2 + 适配层静默丢弃 4） |
| 静默 no-op 类别 | 4 类（4.1 吞掉 18 条、4.2 假成功 1 条、4.3 本地不落生产 4 条、4.4 条件丢弃 3 类） |
| **必须真机才能验** | **139**（已接未验全部）；另有 18 条必须先修接线，修好后同样要真机 |

按面计数（顶层 op；面边界按 op 命名空间，`music.*` 全部归“播放器与音乐”，`stage.video.pending.*` 归“歌词”）：

| 面 | op 数 | 未接 | 已接未验 |
| --- | --- | --- | --- |
| 聊天/输入 | 10 | 0 | 10 |
| 系统消息 | 3 | 0 | 3 |
| 设置五页 | 46 | 4 | 42 |
| 舞台设置四分区 | 22 | 8 | 14 |
| 我的物件 | 20 | 2 | 18 |
| 节目轨道 | 8 | 2 | 6 |
| 产品外壳（含 `ui.settings.command` 包装） | 10 | 0 | 10（含 1 条平台层已验，未计入 op 数） |
| 歌词 | 2 | 2 | 0 |
| 播放器与音乐 | 15 | 0 | 15 |
| 电视与愿望 | 21 | 0 | 21 |
| 合计 | **157** | **18** | **139** |

> §3 各面表格的行数是“用户操作数”，不是 op 数（一个操作可能对应多个 op，如“播放某一轨”对应 `music.program.play`/`music.playlist.play`；无 op 的本地操作如“复制回复”也占一行）。
> 设置窗两个组件（`settings.rs` + `stage_panels.rs`）实际发出 **85** 条 op（含 `music.*`、`video.*`），其中 **12** 条被白名单拦下（§4.1）。

---

## 6. 未覆盖 / 待确认（诚实列出，不装作抽全了）

1. **动态构造的 op 无法从字面量完整抽出**：`props.rs:607` 用 `format!("stage.props.{action}")` 生成 `stage.props.claim/retry/retryInventoryRegistration` 等；`OV/media_ui.rs:661` 用条件表达式生成 `wish.claim`/`wish.inventory.retry`。脚本靠对应的 match 臂/`translate` 反推，`retryInventoryRegistration` 仍被判为“只在测试里出现”。
2. **运行时注入**：`CS/GPUIChat2Probe.cs:80-81` 会把 `stage.camera.reset` 追加进白名单；脚本的静态白名单不含它，本文按“已接”处理。
3. **`services/**` 的 op 处理**：Rust 服务主要接收内层 payload（`world.prop.command` 的 `hold`/`withdraw`/`undo`/`adjustGrip` 等），不是顶层 UI op。本文只标注了 `world_prop.rs`、`marble_control.rs` 的命中的行号，未逐个展开 Rust 内部 authority。
4. **Unity C# 侧只扫了 `apps/unity-player/Assets/GMGN/**/*.cs`**：`PlayerScreen.cs`、`GPUIChat2Probe.cs`、`NativePlayerBackend.cs`、`ChatVoiceInputChecks.cs` 已覆盖；Unity 场景中其它脚本若也消费 op，未纳入。
5. **`APP/GMGNRadioApp.swift`、`PH/ProductHost.swift` 是实验入口**：其中大量 case（如 `stage.props.*`、`stage.activity.*`）在 Unity 正式路径没有对应处理者。本文把它们记为“另一路径处理者”，并因此把相关设置项标成未接；若产品决定走实验入口，结论要重算。
6. **控件 id 覆盖不完整**：共享组件（`shell.rs` 的 `TransportControl`、`primitives.rs` 的 `icon_button`）用运行时 id，脚本只抽到 114 个静态 id；表内以“操作名 + 发出点”为主键，控件 id 缺失的写“—”。
7. **未验证的运行时行为**：`window.has_active_dialog` 命中区、跨屏 DPI（交接 §5.1）、独立设置窗关闭时的 `can_close` 依赖回执（`settings_ui.rs:169-176`）、`ui.settings.command` 队列上限 32（`settings_ui.rs:13,59-62`）都只做了代码阅读，未经真机。
8. **未启动 app / 未播放音频 / 未改系统设置**，因此没有新的截图或日志产生；真机证据全部来自既有 `Player.log`（见 §7），它是候选 221 时代的数据，**不覆盖当前未提交改动**。

---

## 7. 既有真机证据（只读采集，不新增运行）

来源：`/Users/ghostcorn/Library/Logs/DefaultCompany/GMGN Unity Sample/Player.log`（2026-10-08 19:18-19:25，进程 64839）与 `Player-prev.log`（19:07-19:08，进程 61091）；截图 `/Users/ghostcorn/Desktop/screenshot-2026-10-08_19-21-52-w108929|108931|109014.png`。

| 证据 | 位置 | 能证明 | 不能证明 |
| --- | --- | --- | --- |
| `聊天2: actual GPUI mounted in existing Unity window` | Player.log:56 | 正式路径确实挂载了 GPUI overlay（L1） | 任何业务功能 |
| `[GPUIOverlay] geometry host={2048,1152} donor={2048,1152} mounted={2048,1152} layerOpaque=0 scale=2.00` | Player.log:57 | 全屏挂载尺寸/透明/命中区跟随（平台层） | 控件命中与业务 |
| 同款 geometry `{720,450}`，随后 `fullscreen=False/Windowed` `1440x900` | Player.log:451,453,455 | 窗口/紧凑模式尺寸跟随生效（平台层） | 是哪个按钮触发的（该次是 `[LiveCamPointer] fullscreen clicked`，Player.log:450，属 Unity 输入，不是 GPUI 浮动栏按钮） |
| `[UnityChat] failure code=connection_failure_unclassified` + `unmatched_event kind=failure request=1` | Player.log:354-356 | `chat.send` 真的发出并到达会话层（L2），但**失败** | 真实回复（L3）。交接 §5.3 记录同一失败在截图里显示为 `error 3`，根因是 `submit_wish_generation` 的 nullable union schema 被 taskd 拒绝 |
| `[UnityASR] phase=authorization failure=asr_connect_failed` | Player.log:399 | `voice.press` 链路到达 ASR 授权阶段（L2），失败 | 语音转写可用 |
| `[Chat2Input] phase=hostFocus:accepted focused=1` / `phase=inputContext:present focused=1`（128 次） | Player-prev.log:199-328、Player.log:313-322 | 原生输入上下文存在且宿主接受焦点（L1 的焦点部分） | 字符真的落入输入框、中文输入法、光标可见（全程 `length=0`） |
| 221 截图（三张） | Desktop | 外壳/浮动栏/媒体页签渲染、节目名列表可见、提示“请求已发送，等待回执” | 任何 L3 读回；且交接 §5.4 判定该列表是旧样式，不是新 `StageProgramRailPane` |

结论：**没有任何一条功能达到"已验"**；上表只把 1 条平台能力（overlay 挂载/几何跟随）推进到已验，把 2 条链路（chat、ASR）证明为"已接但失败"。

---

## 附录 A：抽取脚本

`tools/audit-ui-function-inventory.py`（Python 3，无第三方依赖，只读）。

它实际做的事：

1. 扫描 UI 层 17 个文件（`apps/gpui-ui/src/**`、`tools/fixtures/gpui-unity-overlay-probe/src/**`、`host/OverlayHost.m`），抽出：
   - 所有 `"op": "…"` 字面量（含 file:line 与所在函数）；
   - 所有 `.id()` / `.accessibility_id()` / `.name()` / 组件构造器首参的控件 id；
   - 所有 `on_click` / `cx.listener` 站点与附近 40 行内出现的 op；
   - 组件内部的 match 臂（`"op" => …`）与 `matches!(… Some("op"))`，即"UI 适配层自己把命令吃掉"的位置；
   - 用括号配对识别 `#[cfg(test)]` 区间，把测试里出现的 op 标成 `test_only`（避免把测试当接线）。
2. 扫描宿主侧 6 棵目录（`apps/macos/UnityHost`、`ProductHost`、`GMGNRadioApp`、`services/**/*.rs`、overlay `host/*.m`、`apps/unity-player/Assets/GMGN/**/*.cs`），抽出：`case "…"`、`== "…"`、`hasPrefix("…")`、`.contains("…")`、`["…"].contains(`、`supportedCommands = […]`，并标记方向（`outbound` = 宿主主动发给下位的 `command(["op": …])`，不算 UI op 的处理者）。
3. 从 `UH/UnityMediaHost.swift` 的 `"supportedCommands": [` 表达式 + 5 个 bridge 的 `supportedCommands` 常量求并集，得到设置窗白名单（92 条），用于判定"被拦下的设置项"。
4. 在每个处理点后 30 行抓 authority 调用名（`xxx.command/settingsCommand/play/load/…`）。
5. 输出 JSON（`--out`）或 Markdown 表（`--markdown`）。

复现命令（针对本文快照）：

```sh
python3 tools/audit-ui-function-inventory.py --out /tmp/ui-inventory.json
GMGN_AUDIT_ROOT=/tmp/ui-audit-snapshot python3 tools/audit-ui-function-inventory.py --markdown > /tmp/ui-inventory.md
```

脚本的环境变量 `GMGN_AUDIT_ROOT` 可把只读扫描指向任意快照目录（本文用它锁定并发修改前的状态）。

## 附录 B：原始抽取表（166 条，自动生成，未人工润色）

见文末表格

| op | UI file:line (scope) | adapter consumer | host handler | authority | in settings gate |
| --- | --- | --- | --- | --- | --- |
| `adjustGrip` | `inventory_ui.rs:509`(translate), `inventory_ui.rs:532`(translate) | - | `world_prop.rs:1258`[eq], `world_prop.rs:1263`[eq] | - | no |
| `agent.login` | `settings.rs:3470`(agent_page) | - | `ProductHost.swift:472`[case], `ProductHost.swift:477`[eq] | `agent.refresh`@ProductHost.swift:479, `asr.save`@ProductHost.swift:485 | yes |
| `agent.logout` | `settings.rs:3468`(agent_page) | - | `ProductHost.swift:472`[case], `ProductHost.swift:478`[eq] | `agent.refresh`@ProductHost.swift:479, `asr.save`@ProductHost.swift:485 | yes |
| `agent.save` | `settings.rs:1160`(new), `settings.rs:1579`(selection) | - | `ProductHost.swift:497`[case], `UnityAgentConnectionBridge.swift:44`[eq] | `agent.save`@ProductHost.swift:497, `agent.save`@UnityAgentConnectionBridge.swift:44 | yes |
| `app.language` | `i18n.rs:47`(language_command), `i18n.rs:451`(host_locale_changes_copy_without_changing_routes) | - | `UnityProductSettings.swift:119`[case] | `settings.load`@UnityProductSettings.swift:122, `agent.save`@UnityProductSettings.swift:123 | yes |
| `asr.save` | `settings.rs:3917`(agent_page) | - | `ProductHost.swift:485`[case], `UnityProductSettings.swift:145`[case] | `asr.save`@ProductHost.swift:485, `speech.save`@ProductHost.swift:495 | yes |
| `chat.attachments.paste` | `lib.rs:444`(translate_command) | - | `GMGNRadioApp.swift:718`[case], `ProductHost.swift:305`[case] | `attachments.remove`@GMGNRadioApp.swift:728, `store.remove`@GMGNRadioApp.swift:731 | yes |
| `chat.attachments.pick` | `lib.rs:443`(translate_command) | - | `GMGNRadioApp.swift:717`[case], `ProductHost.swift:305`[case] | `attachments.remove`@GMGNRadioApp.swift:728, `store.remove`@GMGNRadioApp.swift:731 | yes |
| `chat.attachments.remove` | `lib.rs:445`(translate_command) | - | `GMGNRadioApp.swift:728`[case], `ProductHost.swift:305`[case] | `attachments.remove`@GMGNRadioApp.swift:728, `store.remove`@GMGNRadioApp.swift:731 | yes |
| `chat.cancel` | `lib.rs:442`(translate_command), `lib.rs:451`(translate_command) | - | `UnityMediaHost.swift:1239`[case], `NativePlayerBackend.cs:55`[eq] | - | no |
| `chat.send` | `lib.rs:435`(translate_command), `lib.rs:573`(navigation_command) | - | `ProductHost.swift:301`[case], `UnityMediaHost.swift:1181`[case] | `attachments.import`@ProductHost.swift:305, `speech.stop`@ProductHost.swift:309 | no |
| `generation.check` | `settings.rs:2159`(wish_machine_section) | - | `UnityGenerationConfigurationBridge.swift:40`[case], `UnityMediaHost.swift:1444`[case] | `authority.load`@UnityGenerationConfigurationBridge.swift:49, `authority.save`@UnityGenerationConfigurationBridge.swift:68 | yes |
| `generation.save` | `settings.rs:2176`(wish_machine_section) | - | `UnityGenerationConfigurationBridge.swift:35`[case], `UnityMediaHost.swift:1444`[case] | `generation.save`@UnityGenerationConfigurationBridge.swift:35, `authority.load`@UnityGenerationConfigurationBridge.swift:49 | yes |
| `hold` | `inventory_ui.rs:482`(translate) | - | `GMGNRadioApp.swift:5588`[array-contains], `UnityWorldBridge.swift:187`[array-contains] | - | no |
| `inbox.list` | `media_ui.rs:400`(refresh) | - | `UnityInboxBridge.swift:82`[array-contains], `UnityInboxBridge.swift:117`[eq] | `inbox.command`@UnityMediaHost.swift:1086, `stage.load`@UnityMediaHost.swift:1087 | no |
| `inbox.open` | `inbox.rs:202`(open), `inbox.rs:588`(explicit_open_carries_current_scope_without_optimistic_ack) | `media_ui.rs:417` | `ProductHost.swift:312`[case] | `settings.command`@ProductHost.swift:319 | no |
| `inbox.read` | `media_ui.rs:147`(inbox_read_command), `media_ui.rs:819`(inbox_open_becomes_the_existing_read_op_with_its_confirmed_event_only) | - | `UnityInboxBridge.swift:82`[array-contains], `UnityMediaHost.swift:1086`[case] | `inbox.command`@UnityMediaHost.swift:1086, `stage.load`@UnityMediaHost.swift:1087 | no |
| `inventory.delete` | `inventory_ui.rs:464`(translate), `inventory_ui.rs:991`(delete_and_withdraw_use_the_existing_world_ops_and_payloads) | - | `UnityMediaHost.swift:1046`[eq], `UnityWorldSessionComposition.swift:819`[eq] | `worldSession.command`@UnityMediaHost.swift:1047, `presenceSettings.command`@UnityMediaHost.swift:1070 | no |
| `music.choose` | `media_ui.rs:72`(command_icon), `media_ui.rs:589`(queue) | `media_ui.rs:72` | `UnityMediaHost.swift:1119`[case] | `self.command`@UnityMediaHost.swift:1131, `music.load`@UnityMediaHost.swift:1137 | no |
| `music.connect` | `settings.rs:2826`(music_page) | - | `ProductSettingsParity.swift:183`[case], `UnityMediaHost.swift:1474`[case] | `choice.save`@ProductSettingsParity.swift:195, `key.save`@ProductSettingsParity.swift:196 | yes |
| `music.disconnect` | `settings.rs:2826`(music_page) | - | `ProductSettingsParity.swift:183`[case], `ProductSettingsParity.swift:189`[eq] | `choice.save`@ProductSettingsParity.swift:195, `key.save`@ProductSettingsParity.swift:196 | yes |
| `music.library` | `media_ui.rs:387`(load_catalog) | - | `UnityMediaHost.swift:1093`[case] | `musicLibrary.refresh`@UnityMediaHost.swift:1093, `musicLibrary.showProgramHistory`@UnityMediaHost.swift:1097 | no |
| `music.next` | `shell_ui.rs:16`(action_command), `shell_ui.rs:481`(transport_routes_existing_host_commands_and_distinct_media_sections) | - | `UnityMediaHost.swift:1155`[case] | `music.play`@UnityMediaHost.swift:1168, `player.play`@UnityMediaHost.swift:1169 | no |
| `music.pause` | `shell_ui.rs:19`(action_command), `shell_ui.rs:469`(transport_routes_existing_host_commands_and_distinct_media_sections) | - | `UnityMediaHost.swift:1171`[case] | `music.stop`@UnityMediaHost.swift:1174, `player.stop`@UnityMediaHost.swift:1175 | no |
| `music.play` | `shell_ui.rs:21`(action_command), `shell_ui.rs:473`(transport_routes_existing_host_commands_and_distinct_media_sections) | - | `UnityMediaHost.swift:1168`[case] | `music.play`@UnityMediaHost.swift:1168, `player.play`@UnityMediaHost.swift:1169 | no |
| `music.playlist` | `media_ui.rs:452`(dispatch_child_command), `media_ui.rs:463`(dispatch_child_command) | - | `UnityMediaHost.swift:1113`[case] | `musicLibrary.readPlaylist`@UnityMediaHost.swift:1115, `playlist.play`@UnityMediaHost.swift:1116 | no |
| `music.playlist.play` | `media_ui.rs:165`(rail_play_command), `media_ui.rs:833`(rail_play_resolves_onto_the_open_production_source) | - | `UnityMediaHost.swift:1116`[case] | `playlist.play`@UnityMediaHost.swift:1116, `musicLibrary.play`@UnityMediaHost.swift:1118 | no |
| `music.previous` | `shell_ui.rs:15`(action_command), `shell_ui.rs:477`(transport_routes_existing_host_commands_and_distinct_media_sections) | - | `UnityMediaHost.swift:1164`[case] | `music.play`@UnityMediaHost.swift:1168, `player.play`@UnityMediaHost.swift:1169 | no |
| `music.program.history` | `media_ui.rs:388`(load_catalog) | - | `UnityMediaHost.swift:1094`[case] | `musicLibrary.showProgramHistory`@UnityMediaHost.swift:1097, `musicLibrary.reportProgramSelectionFailure`@UnityMediaHost.swift:1098 | no |
| `music.program.play` | `media_ui.rs:162`(rail_play_command), `media_ui.rs:829`(rail_play_resolves_onto_the_open_production_source) | - | `UnityMediaHost.swift:1101`[case] | `program.play`@UnityMediaHost.swift:1101, `djProgram.selectProgram`@UnityMediaHost.swift:1109 | no |
| `music.select` | `media_ui.rs:578`(queue) | - | `UnityMediaHost.swift:1159`[case] | `music.play`@UnityMediaHost.swift:1168, `player.play`@UnityMediaHost.swift:1169 | no |
| `music.sync` | `settings.rs:543`(music_sync_command), `settings.rs:4563`(provider_sync_busy_blocks_only_that_provider_without_disconnect) | - | `ProductSettingsParity.swift:183`[case], `ProductSettingsParity.swift:188`[eq] | `choice.save`@ProductSettingsParity.swift:195, `key.save`@ProductSettingsParity.swift:196 | yes |
| `music.volume` | `shell_ui.rs:83`(new) | - | `UnityMediaHost.swift:1177`[case] | - | no |
| `presence.activate` | `settings.rs:2366`(presence_page) | - | `ProductSettingsParity.swift:142`[case], `UnityPresenceSettingsBridge.swift:18`[supported-array] | `presence.activate`@ProductSettingsParity.swift:142, `presence.activate`@ProductSettingsParity.swift:144 | yes |
| `presence.catalog` | `settings.rs:1134`(new), `settings.rs:2579`(presence_page) | - | `ProductSettingsParity.swift:154`[case], `UnityPresenceSettingsBridge.swift:18`[supported-array] | `catalog.refresh`@ProductSettingsParity.swift:154, `presence.import`@ProductSettingsParity.swift:162 | yes |
| `presence.import` | `settings.rs:4056`(import_menu) | - | `ProductSettingsParity.swift:140`[case], `UnityPresenceSettingsBridge.swift:18`[supported-array] | `presence.import`@ProductSettingsParity.swift:140, `motion.import`@ProductSettingsParity.swift:141 | yes |
| `presence.import.link` | `settings.rs:988`(open_import_link) | - | `ProductSettingsParity.swift:162`[case], `UnityPresenceSettingsBridge.swift:18`[supported-array] | `presence.import`@ProductSettingsParity.swift:162, `music.load`@ProductSettingsParity.swift:182 | yes |
| `presence.load` | `settings.rs:1276`(select_page) | - | `ProductSettingsParity.swift:139`[case], `UnityPresenceSettingsBridge.swift:18`[supported-array] | `presence.load`@ProductSettingsParity.swift:139, `presence.import`@ProductSettingsParity.swift:140 | yes |
| `presence.motion` | `settings.rs:2524`(presence_page) | - | `ProductSettingsParity.swift:148`[case], `UnityMediaHost.swift:1467`[case] | `motion.remove`@ProductSettingsParity.swift:151, `catalog.refresh`@ProductSettingsParity.swift:154 | yes |
| `presence.motion.import` | `settings.rs:4064`(import_menu) | - | `ProductSettingsParity.swift:141`[case], `UnityPresenceSettingsBridge.swift:18`[supported-array] | `motion.import`@ProductSettingsParity.swift:141, `presence.activate`@ProductSettingsParity.swift:142 | yes |
| `presence.motion.install` | `settings.rs:2652`(presence_page) | - | `ProductSettingsParity.swift:158`[case], `UnityPresenceSettingsBridge.swift:18`[supported-array] | `presence.import`@ProductSettingsParity.swift:162, `music.load`@ProductSettingsParity.swift:182 | yes |
| `presence.motion.remove` | `settings.rs:2540`(presence_page) | - | `ProductSettingsParity.swift:151`[case], `UnityPresenceSettingsBridge.swift:18`[supported-array] | `motion.remove`@ProductSettingsParity.swift:151, `catalog.refresh`@ProductSettingsParity.swift:154 | yes |
| `presence.orb.color` | `settings.rs:1166`(new) | - | `ProductSettingsParity.swift:175`[case], `UnityPresenceSettingsBridge.swift:18`[supported-array] | `music.load`@ProductSettingsParity.swift:182, `choice.save`@ProductSettingsParity.swift:195 | yes |
| `presence.orb.intensity` | `settings.rs:1173`(new) | - | `ProductSettingsParity.swift:175`[case], `ProductSettingsParity.swift:181`[eq] | `music.load`@ProductSettingsParity.swift:182, `choice.save`@ProductSettingsParity.swift:195 | yes |
| `presence.position` | `settings.rs:1856`(character_position_form) | - | `UnityCharacterPositionBridge.swift:73`[eq], `UnityMediaHost.swift:1035`[eq] | `position.reset`@UnityCharacterPositionBridge.swift:73, `position.reset`@UnityCharacterPositionBridge.swift:92 | yes |
| `presence.position.reset` | `settings.rs:1883`(character_position_form) | - | `UnityCharacterPositionBridge.swift:73`[eq], `UnityCharacterPositionBridge.swift:92`[eq] | `position.reset`@UnityCharacterPositionBridge.swift:73, `position.reset`@UnityCharacterPositionBridge.swift:92 | yes |
| `presence.remove` | `settings.rs:2382`(presence_page) | - | `ProductSettingsParity.swift:145`[case], `UnityPresenceSettingsBridge.swift:18`[supported-array] | `presence.remove`@ProductSettingsParity.swift:145, `presence.remove`@ProductSettingsParity.swift:147 | yes |
| `returnHeld` | `inventory_ui.rs:493`(translate) | - | `GMGNRadioApp.swift:5588`[array-contains], `UnityWorldBridge.swift:187`[array-contains] | - | no |
| `screen.list` | `media_ui.rs:399`(refresh) | - | `UnityScreenVideoBridge.swift:12`[supported-array], `UnityScreenVideoBridge.swift:240`[case] | `screen.play`@UnityScreenVideoBridge.swift:12, `video.load`@UnityScreenVideoBridge.swift:240 | yes |
| `screen.play` | `media_ui.rs:631`(screen) | - | `UnityScreenVideoBridge.swift:12`[supported-array], `UnityScreenVideoBridge.swift:241`[case] | `screen.play`@UnityScreenVideoBridge.swift:12, `screen.play`@UnityScreenVideoBridge.swift:241 | yes |
| `screen.stop` | `media_ui.rs:73`(command_icon), `media_ui.rs:633`(screen) | `media_ui.rs:73` | `UnityScreenVideoBridge.swift:12`[supported-array], `UnityScreenVideoBridge.swift:258`[case] | `screen.play`@UnityScreenVideoBridge.swift:12, `screen.stop`@UnityScreenVideoBridge.swift:258 | yes |
| `settings.load` | `settings.rs:1201`(new), `settings.rs:4805`(pane_draws_every_original_tab_and_keeps_host_command_semantics) | - | `ProductHost.swift:467`[case], `UnityMediaHost.swift:1445`[case] | `settings.load`@ProductHost.swift:467, `parity.load`@ProductHost.swift:471 | yes |
| `settings.open.presence` | `stage_panels.rs:980`(motions) | - | `ProductHost.swift:298`[case] | `attachments.import`@ProductHost.swift:305, `speech.stop`@ProductHost.swift:309 | no |
| `shortcuts.cancel` | `settings.rs:403`(shortcut_capture_command), `settings.rs:1243`(select_page) | - | `ProductSettingsParity.swift:214`[case], `UnityShortcutSettingsBridge.swift:12`[supported-array] | `shortcuts.reset`@ProductSettingsParity.swift:215, `shortcuts.save`@ProductSettingsParity.swift:216 | yes |
| `shortcuts.capture` | `settings.rs:480`(shortcut_capture_command), `settings.rs:4496`(shortcut_capture_preserves_native_codes_and_modifiers) | - | `UnityShortcutSettingsBridge.swift:12`[supported-array], `UnityShortcutSettingsBridge.swift:44`[case] | `shortcuts.record`@UnityShortcutSettingsBridge.swift:12, `coordinator.start`@UnityShortcutSettingsBridge.swift:19 | yes |
| `shortcuts.global` | `settings.rs:3343`(shortcuts_page) | - | `ProductSettingsParity.swift:219`[case], `ProductSettingsParity.swift:221`[eq] | `props.save`@ProductSettingsParity.swift:236, `shortcuts.record`@UnityShortcutSettingsBridge.swift:12 | yes |
| `shortcuts.media` | `settings.rs:3358`(shortcuts_page) | - | `ProductSettingsParity.swift:219`[case], `UnityShortcutSettingsBridge.swift:12`[supported-array] | `props.save`@ProductSettingsParity.swift:236, `shortcuts.record`@UnityShortcutSettingsBridge.swift:12 | yes |
| `shortcuts.record` | `settings.rs:3321`(shortcuts_page) | - | `ProductSettingsParity.swift:208`[case], `UnityShortcutSettingsBridge.swift:12`[supported-array] | `shortcuts.record`@ProductSettingsParity.swift:208, `shortcuts.reset`@ProductSettingsParity.swift:215 | yes |
| `shortcuts.reset` | `settings.rs:3380`(shortcuts_page) | - | `ProductSettingsParity.swift:215`[case], `UnityShortcutSettingsBridge.swift:12`[supported-array] | `shortcuts.reset`@ProductSettingsParity.swift:215, `shortcuts.save`@ProductSettingsParity.swift:216 | yes |
| `space.default` | `settings.rs:1576`(selection) | - | `ProductSettingsParity.swift:193`[case], `UnityMediaHost.swift:1442`[case] | `choice.save`@ProductSettingsParity.swift:195, `key.save`@ProductSettingsParity.swift:196 | yes |
| `space.key.clear` | `settings.rs:1743`(command_button), `settings.rs:1745`(command_button) | - | `ProductSettingsParity.swift:200`[case], `UnityProductSettings.swift:115`[case] | `prop.save`@ProductSettingsParity.swift:203, `shortcuts.record`@ProductSettingsParity.swift:208 | yes |
| `space.key.save` | `settings.rs:2955`(space_page) | - | `ProductSettingsParity.swift:196`[case], `UnityProductSettings.swift:109`[case] | `key.save`@ProductSettingsParity.swift:196, `marble.save`@ProductSettingsParity.swift:198 | yes |
| `space.library.load` | `settings.rs:1247`(select_page), `settings.rs:2982`(space_page) | - | `UnityMediaHost.swift:1442`[case], `UnitySpaceLibraryBridge.swift:104`[case] | `library.load`@UnityMediaHost.swift:1442, `video.load`@UnityMediaHost.swift:1443 | yes |
| `space.library.select` | `settings.rs:3019`(space_page) | - | `UnityMediaHost.swift:1442`[case], `UnitySpaceLibraryBridge.swift:105`[case] | `library.load`@UnityMediaHost.swift:1442, `video.load`@UnityMediaHost.swift:1443 | yes |
| `space.marble.cancel` | `settings.rs:596`(marble_command), `settings.rs:3179`(space_page) | - | `marble_control.rs:726`[array-contains], `marble_control.rs:729`[eq] | `marble.import`@UnityMarbleWorldBridge.swift:35 | yes |
| `space.marble.generate` | `settings.rs:603`(marble_command), `settings.rs:3067`(space_page) | - | `UnityMarbleWorldBridge.swift:35`[supported-array], `UnityMarbleWorldBridge.swift:83`[case] | `marble.import`@UnityMarbleWorldBridge.swift:35, `marble.import`@UnityMarbleWorldBridge.swift:85 | yes |
| `space.marble.import` | `settings.rs:614`(marble_command), `settings.rs:3127`(space_page) | - | `UnityMarbleWorldBridge.swift:35`[supported-array], `UnityMarbleWorldBridge.swift:85`[case] | `marble.import`@UnityMarbleWorldBridge.swift:35, `marble.import`@UnityMarbleWorldBridge.swift:85 | yes |
| `space.marble.resume` | `settings.rs:613`(marble_command), `settings.rs:3155`(space_page) | - | `marble_control.rs:726`[array-contains], `UnityMarbleWorldBridge.swift:35`[supported-array] | `marble.import`@UnityMarbleWorldBridge.swift:35, `marble.import`@UnityMarbleWorldBridge.swift:85 | yes |
| `space.prop.cancel` | `settings.rs:1142`(new), `settings.rs:1149`(new) | - | `ProductSettingsParity.swift:204`[case] | `shortcuts.record`@ProductSettingsParity.swift:208, `shortcuts.reset`@ProductSettingsParity.swift:215 | no |
| `space.prop.check` | `settings.rs:2244`(wish_machine_section) | - | `ProductSettingsParity.swift:207`[case] | `shortcuts.record`@ProductSettingsParity.swift:208, `shortcuts.reset`@ProductSettingsParity.swift:215 | no |
| `space.prop.save` | `settings.rs:2267`(wish_machine_section) | - | `ProductSettingsParity.swift:203`[case] | `prop.save`@ProductSettingsParity.swift:203, `shortcuts.record`@ProductSettingsParity.swift:208 | no |
| `speech.settings.cancel` | `settings.rs:1124`(new), `settings.rs:1237`(select_page) | - | `ProductHost.swift:558`[case], `UnityProductSettings.swift:179`[case] | `settings.load`@ProductHost.swift:564, `parity.command`@ProductHost.swift:565 | yes |
| `speech.settings.load` | `settings.rs:1279`(select_page), `settings.rs:4835`(pane_draws_every_original_tab_and_keeps_host_command_semantics) | - | `ProductHost.swift:564`[case], `UnityProductSettings.swift:122`[case] | `settings.load`@ProductHost.swift:564, `parity.command`@ProductHost.swift:565 | yes |
| `stage.activity.run` | `stage_panels.rs:1043`(activities) | - | `GMGNRadioApp.swift:860`[case] | `activity.stop`@GMGNRadioApp.swift:864, `stageLyrics.setVisualMode`@GMGNRadioApp.swift:869 | no |
| `stage.activity.stop` | `stage_panels.rs:1057`(activities) | - | `GMGNRadioApp.swift:864`[case] | `activity.stop`@GMGNRadioApp.swift:864, `stageLyrics.setVisualMode`@GMGNRadioApp.swift:869 | no |
| `stage.avatar.position` | `stage_panels.rs:413`(new) | - | `GMGNRadioApp.swift:846`[case] | `avatar.reset`@GMGNRadioApp.swift:853, `camera.reset`@GMGNRadioApp.swift:859 | no |
| `stage.avatar.reset` | `stage_panels.rs:790`(avatar_placement) | - | `GMGNRadioApp.swift:853`[case] | `avatar.reset`@GMGNRadioApp.swift:853, `camera.reset`@GMGNRadioApp.swift:859 | no |
| `stage.camera.reset` | `stage_panels.rs:808`(avatar_placement) | - | `GMGNRadioApp.swift:859`[case], `GPUIChat2Probe.cs:81`[contains] | `camera.reset`@GMGNRadioApp.swift:859, `activity.stop`@GMGNRadioApp.swift:864 | no |
| `stage.load` | `stage_panels.rs:425`(new) | - | `GMGNRadioApp.swift:829`[case], `UnityMediaHost.swift:1087`[case] | `stage.load`@GMGNRadioApp.swift:829, `scene.activate`@GMGNRadioApp.swift:838 | yes |
| `stage.motion.activate` | `stage_panels.rs:941`(motions) | - | `ProductHost.swift:287`[eq] | `motion.activate`@ProductHost.swift:287, `settings.command`@ProductHost.swift:290 | no |
| `stage.motion.refresh` | `stage_panels.rs:450`(select_tab), `stage_panels.rs:846`(motions) | - | `ProductHost.swift:284`[eq] | `motion.refresh`@ProductHost.swift:284, `settings.command`@ProductHost.swift:285 | no |
| `stage.player.cloud` | `stage_panels.rs:1117`(player) | - | `GMGNRadioApp.swift:872`[case], `UnityMediaHost.swift:1090`[case] | `stageVisualDirections.selectPointCloud`@GMGNRadioApp.swift:876, `stageVisualDirections.setParticleSizeMultiplier`@GMGNRadioApp.swift:883 | yes |
| `stage.player.lyrics` | `i18n.rs:450`(host_locale_changes_copy_without_changing_routes), `i18n.rs:508`(player_catalogs_translate_all_builtin_modes_without_touching_custom_names) | - | `GMGNRadioApp.swift:865`[case], `UnityMediaHost.swift:1088`[case] | `stageLyrics.setVisualMode`@GMGNRadioApp.swift:869, `stageVisualDirections.selectPointCloud`@GMGNRadioApp.swift:876 | yes |
| `stage.player.particles` | `stage_panels.rs:414`(new) | - | `GMGNRadioApp.swift:879`[case], `UnityMediaHost.swift:1090`[case] | `stageVisualDirections.setParticleSizeMultiplier`@GMGNRadioApp.swift:883, `video.stop`@GMGNRadioApp.swift:892 | yes |
| `stage.playlist.open` | `program.rs:1738`(render), `media_ui.rs:441`(dispatch_child_command) | `media_ui.rs:441` | `GMGNRadioApp.swift:362`[case], `ProductHost.swift:280`[eq] | `program.play`@GMGNRadioApp.swift:372, `selection.activate`@GMGNRadioApp.swift:376 | no |
| `stage.program.back` | `program.rs:1447`(icon_button), `program.rs:1620`(render) | `media_ui.rs:455` | `GMGNRadioApp.swift:365`[case] | `program.play`@GMGNRadioApp.swift:372, `selection.activate`@GMGNRadioApp.swift:376 | no |
| `stage.program.load` | `program.rs:1012`(new), `media_ui.rs:425`(dispatch_child_command) | `media_ui.rs:425` | `GMGNRadioApp.swift:358`[case] | `program.load`@GMGNRadioApp.swift:358, `program.play`@GMGNRadioApp.swift:372 | no |
| `stage.program.more` | `program.rs:1530`(render), `media_ui.rs:461`(dispatch_child_command) | `media_ui.rs:461` | `GMGNRadioApp.swift:366`[case] | `program.play`@GMGNRadioApp.swift:372, `selection.activate`@GMGNRadioApp.swift:376 | no |
| `stage.program.open` | `program.rs:1737`(render), `media_ui.rs:426`(dispatch_child_command) | `media_ui.rs:426` | `GMGNRadioApp.swift:359`[case] | `program.play`@GMGNRadioApp.swift:372, `selection.activate`@GMGNRadioApp.swift:376 | no |
| `stage.program.play` | `program.rs:1200`(projected_card), `program.rs:1704`(render) | `media_ui.rs:466` | `GMGNRadioApp.swift:372`[case] | `program.play`@GMGNRadioApp.swift:372, `selection.activate`@GMGNRadioApp.swift:376 | no |
| `stage.program.replan` | `program.rs:1445`(icon_button), `program.rs:1643`(render) | `media_ui.rs:492` | `GMGNRadioApp.swift:369`[case] | `program.play`@GMGNRadioApp.swift:372, `selection.activate`@GMGNRadioApp.swift:376 | no |
| `stage.program.video` | `program.rs:1202`(projected_card), `program.rs:1408`(projected_card) | `media_ui.rs:476` | `GMGNRadioApp.swift:377`[case] | - | no |
| `stage.props.askResidentToFetch` | `inventory_ui.rs:1149`(unsupported_component_commands_are_refused_not_invented) | - | `GMGNRadioApp.swift:449`[case] | - | no |
| `stage.props.claim` | `inventory_ui.rs:449`(translate), `inventory_ui.rs:451`(translate) | `inventory_ui.rs:449`, `inventory_ui.rs:451` | `GMGNRadioApp.swift:449`[case] | - | no |
| `stage.props.close` | `props.rs:1458`(render), `inventory_ui.rs:1150`(unsupported_component_commands_are_refused_not_invented) | - | `GMGNRadioApp.swift:434`[case] | - | no |
| `stage.props.delete` | `props.rs:414`(control_with_a11y), `props.rs:799`(cancellation_never_emits_delete_and_clears_confirmation) | `inventory_ui.rs:459` | `GMGNRadioApp.swift:462`[case], `GMGNRadioApp.swift:464`[eq] | - | no |
| `stage.props.escape` | `inventory_ui.rs:1152`(unsupported_component_commands_are_refused_not_invented) | - | `GMGNRadioApp.swift:435`[case] | - | no |
| `stage.props.filter` | `props.rs:1128`(render), `inventory_ui.rs:437`(translate) | `inventory_ui.rs:437` | `GMGNRadioApp.swift:436`[case] | - | no |
| `stage.props.fold` | `props.rs:443`(section_heading), `props.rs:475`(section_heading) | `inventory_ui.rs:441` | `GMGNRadioApp.swift:438`[case] | - | no |
| `stage.props.hold` | `props.rs:662`(slot_picker), `props.rs:1260`(render) | `inventory_ui.rs:474` | `GMGNRadioApp.swift:471`[case] | - | no |
| `stage.props.invented` | `inventory_ui.rs:1153`(unsupported_component_commands_are_refused_not_invented) | - | **NONE** | - | no |
| `stage.props.load` | `props.rs:261`(new), `inventory_ui.rs:436`(translate) | `inventory_ui.rs:436` | `GMGNRadioApp.swift:429`[case] | `props.load`@GMGNRadioApp.swift:429 | no |
| `stage.props.nudge` | `props.rs:1207`(render), `inventory_ui.rs:495`(translate) | `inventory_ui.rs:495` | `GMGNRadioApp.swift:478`[case] | - | no |
| `stage.props.resize` | `props.rs:239`(new), `props.rs:699`(size_control) | - | `GMGNRadioApp.swift:486`[case] | - | no |
| `stage.props.retry` | `inventory_ui.rs:449`(translate), `inventory_ui.rs:452`(translate) | `inventory_ui.rs:449`, `inventory_ui.rs:452` | `GMGNRadioApp.swift:449`[case] | - | no |
| `stage.props.retryInventoryRegistration` | `inventory_ui.rs:957`(claim_retry_and_inventory_retry_use_the_existing_wish_ops) | `inventory_ui.rs:449` | `GMGNRadioApp.swift:449`[case] | - | no |
| `stage.props.return` | `props.rs:1236`(render), `inventory_ui.rs:491`(translate) | `inventory_ui.rs:491` | `GMGNRadioApp.swift:477`[case] | - | no |
| `stage.props.rotate` | `props.rs:1219`(render), `props.rs:1227`(render) | `inventory_ui.rs:516` | `GMGNRadioApp.swift:483`[case] | - | no |
| `stage.props.select` | `props.rs:498`(ownership_row), `inventory_ui.rs:445`(translate) | `inventory_ui.rs:445` | `GMGNRadioApp.swift:446`[case] | - | no |
| `stage.props.toggle` | `inventory_ui.rs:1151`(unsupported_component_commands_are_refused_not_invented) | - | `GMGNRadioApp.swift:431`[case] | - | no |
| `stage.props.undo` | `props.rs:1404`(render), `inventory_ui.rs:539`(translate) | `inventory_ui.rs:539` | `GMGNRadioApp.swift:489`[case] | - | no |
| `stage.props.withdraw` | `props.rs:1268`(render), `inventory_ui.rs:470`(translate) | `inventory_ui.rs:470` | `GMGNRadioApp.swift:462`[case] | - | no |
| `stage.scene.activate` | `stage_panels.rs:693`(world_selection) | - | `GMGNRadioApp.swift:838`[case] | `scene.activate`@GMGNRadioApp.swift:838, `marbleWorldLibrary.activate`@GMGNRadioApp.swift:843 | no |
| `stage.video.bind` | `stage_panels.rs:329`(video_asset_actions), `stage_panels.rs:370`(no_track_omits_binding_and_inactive_asset_loads) | - | `GMGNRadioApp.swift:903`[case], `UnityScreenVideoBridge.swift:12`[supported-array] | `video.remove`@GMGNRadioApp.swift:903, `video.remove`@GMGNRadioApp.swift:906 | yes |
| `stage.video.brightness` | `stage_panels.rs:415`(new) | - | `GMGNRadioApp.swift:889`[case], `UnityScreenVideoBridge.swift:12`[supported-array] | `video.stop`@GMGNRadioApp.swift:892, `video.import`@GMGNRadioApp.swift:894 | yes |
| `stage.video.import` | `stage_panels.rs:1255`(music_video) | - | `GMGNRadioApp.swift:894`[case], `UnityScreenVideoBridge.swift:12`[supported-array] | `video.import`@GMGNRadioApp.swift:894, `video.remove`@GMGNRadioApp.swift:903 | yes |
| `stage.video.mode` | `stage_panels.rs:1281`(music_video) | - | `GMGNRadioApp.swift:886`[case], `UnityScreenVideoBridge.swift:12`[supported-array] | `video.stop`@GMGNRadioApp.swift:892, `video.import`@GMGNRadioApp.swift:894 | yes |
| `stage.video.pending.dismiss` | `lyrics.rs:2722`(update_snapshot), `lyrics.rs:2818`(render) | - | `GMGNRadioApp.swift:570`[case] | - | no |
| `stage.video.pending.play` | `lyrics.rs:2802`(render) | - | `GMGNRadioApp.swift:569`[case] | `pending.play`@GMGNRadioApp.swift:569 | no |
| `stage.video.recoverStop` | `stage_panels.rs:1328`(music_video) | - | `GMGNRadioApp.swift:893`[case], `UnityScreenVideoBridge.swift:12`[supported-array] | `video.import`@GMGNRadioApp.swift:894, `video.remove`@GMGNRadioApp.swift:903 | yes |
| `stage.video.remove` | `stage_panels.rs:333`(video_asset_actions), `stage_panels.rs:364`(no_track_omits_binding_and_inactive_asset_loads) | - | `GMGNRadioApp.swift:903`[case], `GMGNRadioApp.swift:906`[eq] | `video.remove`@GMGNRadioApp.swift:903, `video.remove`@GMGNRadioApp.swift:906 | yes |
| `stage.video.stop` | `stage_panels.rs:1303`(music_video) | - | `GMGNRadioApp.swift:892`[case], `UnityScreenVideoBridge.swift:12`[supported-array] | `video.stop`@GMGNRadioApp.swift:892, `video.import`@GMGNRadioApp.swift:894 | yes |
| `stage.video.toggle` | `stage_panels.rs:318`(video_asset_actions), `stage_panels.rs:353`(asset_submenu_preserves_active_toggle_and_bound_track_commands) | - | `GMGNRadioApp.swift:903`[case], `GMGNRadioApp.swift:905`[eq] | `video.remove`@GMGNRadioApp.swift:903, `video.remove`@GMGNRadioApp.swift:906 | yes |
| `stage.video.unbind` | `stage_panels.rs:329`(video_asset_actions), `stage_panels.rs:355`(asset_submenu_preserves_active_toggle_and_bound_track_commands) | - | `GMGNRadioApp.swift:911`[case], `UnityScreenVideoBridge.swift:12`[supported-array] | `screen.play`@UnityScreenVideoBridge.swift:12, `video.load`@UnityScreenVideoBridge.swift:240 | yes |
| `stage.world.enter` | `stage_panels.rs:692`(world_selection) | - | `GMGNRadioApp.swift:830`[case] | `scene.activate`@GMGNRadioApp.swift:838, `marbleWorldLibrary.activate`@GMGNRadioApp.swift:843 | no |
| `tts.preview` | `settings.rs:3760`(agent_page) | - | `ProductHost.swift:538`[case], `UnityProductSettings.swift:162`[case] | `tts.save`@ProductHost.swift:538, `tts.save`@ProductHost.swift:544 | yes |
| `tts.refresh` | `settings.rs:3722`(agent_page) | - | `ProductHost.swift:533`[case], `UnityProductSettings.swift:159`[case] | `tts.refresh`@ProductHost.swift:533, `tts.save`@ProductHost.swift:538 | yes |
| `tts.save` | `settings.rs:3850`(agent_page) | - | `ProductHost.swift:538`[case], `ProductHost.swift:544`[eq] | `tts.save`@ProductHost.swift:538, `tts.save`@ProductHost.swift:544 | yes |
| `tts.stop` | `settings.rs:1116`(new), `settings.rs:1565`(selection) | - | `ProductHost.swift:557`[case], `UnityMediaHost.swift:1039`[eq] | `tts.stop`@ProductHost.swift:557, `settings.load`@ProductHost.swift:564 | yes |
| `ui.chat.dropRegion` | `lib.rs:210`(probe_native_normalize_chat_rect) | - | `GPUIChat2Probe.cs:113`[eq] | `world.BeginInventoryPlacement`@GPUIChat2Probe.cs:128, `world.BeginDevicePlacement`@GPUIChat2Probe.cs:133 | no |
| `ui.chat.open` | `lib.rs:553`(navigation_command), `lib.rs:588`(navigation_command) | `lib.rs:553`, `lib.rs:588` | **NONE** | - | no |
| `ui.device.place` | `inventory_ui.rs:338`(notice), `inventory_ui.rs:550`(device_place_command) | `lib.rs:486` | `GPUIChat2Probe.cs:125`[eq] | `world.BeginInventoryPlacement`@GPUIChat2Probe.cs:128, `world.BeginDevicePlacement`@GPUIChat2Probe.cs:133 | no |
| `ui.inventory.place` | `inventory_ui.rs:338`(notice), `inventory_ui.rs:488`(translate) | `lib.rs:486` | `GPUIChat2Probe.cs:125`[eq], `GPUIChat2Probe.cs:127`[eq] | `world.BeginInventoryPlacement`@GPUIChat2Probe.cs:128, `world.BeginDevicePlacement`@GPUIChat2Probe.cs:133 | no |
| `ui.lyrics.toggle` | `shell_ui.rs:25`(action_command), `shell_ui.rs:498`(transport_routes_existing_host_commands_and_distinct_media_sections) | - | `PlayerScreen.cs:105`[case] | `compactWindow.ToggleFullscreen`@PlayerScreen.cs:108 | no |
| `ui.music.open` | `lib.rs:553`(navigation_command), `lib.rs:588`(navigation_command) | `lib.rs:553`, `lib.rs:588` | **NONE** | - | no |
| `ui.overlay.panel` | `shell_ui.rs:108`(set_panel) | - | `GPUIChat2Probe.cs:118`[eq] | `world.BeginInventoryPlacement`@GPUIChat2Probe.cs:128, `world.BeginDevicePlacement`@GPUIChat2Probe.cs:133 | no |
| `ui.settings.command` | `settings_ui.rs:94`(dispatch) | - | `UnityMediaHost.swift:1012`[eq], `GPUIChat2Probe.cs:105`[eq] | `settings.command`@UnityMediaHost.swift:1012, `self.settingsCommand`@UnityMediaHost.swift:1022 | no |
| `ui.settings.open` | `lib.rs:553`(navigation_command), `lib.rs:588`(navigation_command) | `lib.rs:553`, `lib.rs:588` | **NONE** | - | no |
| `ui.space.toggle` | `shell_ui.rs:427`(render) | - | `PlayerScreen.cs:106`[case] | `compactWindow.ToggleFullscreen`@PlayerScreen.cs:108 | no |
| `ui.textInput` | `lib.rs:163`(report_kit_text_input) | - | `UnityMediaHost.swift:1038`[eq] | `shortcutSettings.updateTextInput`@UnityMediaHost.swift:1038, `tts.stop`@UnityMediaHost.swift:1039 | no |
| `ui.window.compact` | `shell_ui.rs:26`(action_command), `shell_ui.rs:502`(transport_routes_existing_host_commands_and_distinct_media_sections) | - | `PlayerScreen.cs:109`[case] | - | no |
| `ui.window.fullscreen` | `shell_ui.rs:24`(action_command), `shell_ui.rs:485`(transport_routes_existing_host_commands_and_distinct_media_sections) | - | `PlayerScreen.cs:108`[case] | `compactWindow.ToggleFullscreen`@PlayerScreen.cs:108 | no |
| `ui.wish.open` | `lib.rs:553`(navigation_command), `lib.rs:588`(navigation_command) | `lib.rs:553`, `lib.rs:588` | **NONE** | - | no |
| `undo` | `inventory_ui.rs:539`(translate) | - | `world_prop.rs:1209`[eq], `GMGNRadioApp.swift:5588`[array-contains] | - | no |
| `video.bind` | `settings.rs:2030`(video_page) | - | `UnityMediaHost.swift:1443`[case], `UnityScreenVideoBridge.swift:12`[supported-array] | `video.load`@UnityMediaHost.swift:1443, `generation.load`@UnityMediaHost.swift:1444 | yes |
| `video.bound.dismiss` | `settings.rs:2057`(video_page) | - | `UnityMediaHost.swift:1443`[case], `UnityScreenVideoBridge.swift:12`[supported-array] | `video.load`@UnityMediaHost.swift:1443, `generation.load`@UnityMediaHost.swift:1444 | yes |
| `video.bound.play` | `settings.rs:2051`(video_page), `media_ui.rs:485`(dispatch_child_command) | - | `UnityMediaHost.swift:1443`[case], `UnityScreenVideoBridge.swift:12`[supported-array] | `video.load`@UnityMediaHost.swift:1443, `generation.load`@UnityMediaHost.swift:1444 | yes |
| `video.brightness` | `settings.rs:1181`(new) | - | `UnityMediaHost.swift:1443`[case], `UnityScreenVideoBridge.swift:12`[supported-array] | `video.load`@UnityMediaHost.swift:1443, `generation.load`@UnityMediaHost.swift:1444 | yes |
| `video.choose` | `settings.rs:1914`(video_page) | - | `UnityMediaHost.swift:1443`[case], `UnityScreenVideoBridge.swift:12`[supported-array] | `video.load`@UnityMediaHost.swift:1443, `generation.load`@UnityMediaHost.swift:1444 | yes |
| `video.load` | `settings.rs:1317`(select_section), `settings.rs:4860`(pane_draws_every_original_tab_and_keeps_host_command_semantics) | - | `UnityMediaHost.swift:1443`[case], `UnityScreenVideoBridge.swift:12`[supported-array] | `video.load`@UnityMediaHost.swift:1443, `generation.load`@UnityMediaHost.swift:1444 | yes |
| `video.mode` | `settings.rs:2077`(video_page) | - | `UnityMediaHost.swift:1443`[case], `UnityScreenVideoBridge.swift:12`[supported-array] | `video.load`@UnityMediaHost.swift:1443, `generation.load`@UnityMediaHost.swift:1444 | yes |
| `video.pause` | `settings.rs:1945`(video_page) | - | `UnityMediaHost.swift:1443`[case], `UnityScreenVideoBridge.swift:12`[supported-array] | `video.load`@UnityMediaHost.swift:1443, `generation.load`@UnityMediaHost.swift:1444 | yes |
| `video.play` | `settings.rs:1947`(video_page) | - | `UnityMediaHost.swift:1443`[case], `UnityScreenVideoBridge.swift:12`[supported-array] | `video.load`@UnityMediaHost.swift:1443, `generation.load`@UnityMediaHost.swift:1444 | yes |
| `video.recoverStop` | `settings.rs:1967`(video_page) | - | `UnityScreenVideoBridge.swift:12`[supported-array], `UnityScreenVideoBridge.swift:285`[case] | `screen.play`@UnityScreenVideoBridge.swift:12, `bound.play`@UnityScreenVideoBridge.swift:300 | yes |
| `video.remove` | `settings.rs:2018`(video_page) | - | `UnityMediaHost.swift:1443`[case], `UnityScreenVideoBridge.swift:12`[supported-array] | `video.load`@UnityMediaHost.swift:1443, `generation.load`@UnityMediaHost.swift:1444 | yes |
| `video.select` | `settings.rs:2009`(video_page) | - | `UnityMediaHost.swift:1443`[case], `UnityScreenVideoBridge.swift:12`[supported-array] | `video.load`@UnityMediaHost.swift:1443, `generation.load`@UnityMediaHost.swift:1444 | yes |
| `video.stop` | `settings.rs:1956`(video_page) | - | `UnityMediaHost.swift:1443`[case], `UnityScreenVideoBridge.swift:12`[supported-array] | `video.load`@UnityMediaHost.swift:1443, `generation.load`@UnityMediaHost.swift:1444 | yes |
| `video.unbind` | `settings.rs:2030`(video_page) | - | `UnityMediaHost.swift:1443`[case], `UnityScreenVideoBridge.swift:12`[supported-array] | `video.load`@UnityMediaHost.swift:1443, `generation.load`@UnityMediaHost.swift:1444 | yes |
| `voice.press` | `lib.rs:446`(translate_command), `shell_ui.rs:414`(render) | - | `UnityMediaHost.swift:1278`[case], `UnityPushToTalkBridge.swift:44`[case] | `pushToTalk.command`@UnityMediaHost.swift:1278 | no |
| `voice.release` | `lib.rs:447`(translate_command), `shell_ui.rs:414`(render) | - | `UnityMediaHost.swift:1278`[case], `UnityPushToTalkBridge.swift:45`[case] | `pushToTalk.command`@UnityMediaHost.swift:1278 | no |
| `wish.claim` | `inventory_ui.rs:352`(notice), `inventory_ui.rs:451`(translate) | `media_ui.rs:74` | `UnityWishMachineBridge.swift:63`[array-contains], `UnityWishMachineBridge.swift:96`[eq] | `coordinator.refresh`@UnityWishMachineBridge.swift:75 | no |
| `wish.inventory.retry` | `inventory_ui.rs:354`(notice), `inventory_ui.rs:453`(translate) | `media_ui.rs:75` | `UnityWishMachineBridge.swift:63`[array-contains] | `coordinator.refresh`@UnityWishMachineBridge.swift:75 | no |
| `wish.retry` | `inventory_ui.rs:353`(notice), `inventory_ui.rs:452`(translate) | - | `UnityWishMachineBridge.swift:63`[array-contains], `UnityWishMachineBridge.swift:91`[eq] | `coordinator.refresh`@UnityWishMachineBridge.swift:75 | no |
| `wish.status` | `inventory_ui.rs:355`(notice), `inventory_ui.rs:436`(translate) | - | `UnityWishMachineBridge.swift:63`[array-contains], `UnityWishMachineBridge.swift:71`[eq] | `coordinator.refresh`@UnityWishMachineBridge.swift:75 | no |
| `withdraw` | `inventory_ui.rs:472`(translate) | `props.rs:572`, `props.rs:581` | `UnityWorldBridge.swift:187`[array-contains] | - | no |
| `world.prop.command` | `inventory_ui.rs:385`(prop_command), `inventory_ui.rs:1003`(delete_and_withdraw_use_the_existing_world_ops_and_payloads) | - | `UnityMediaHost.swift:1091`[case], `UnityWorldBridge.swift:63`[array-contains] | `prop.command`@UnityMediaHost.swift:1091, `world.command`@UnityMediaHost.swift:1092 | no |

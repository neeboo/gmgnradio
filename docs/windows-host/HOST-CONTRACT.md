# Windows 宿主接口规格（第二宿主契约）

> 机器可校验的那一份在 `apps/windows-host/src/registry.rs`；本文是它的可读投影。
> **单一事实来源**是 `apps/gpui-ui/tests/interface_parity.rs` 的 `OPS` 表 —— 本文、
> registry、门禁全部从它派生，谁都不许再抄一份。

## 0. 形态决定：**甲 —— Unity 继续当外壳，另写一层 Windows 宿主**

不是偏好，是实测逼出来的：

| 证据 | 命令 | 结果 |
|---|---|---|
| GPUI 整层在 Windows 目标上编得过 | `cd apps/gpui-ui && cargo check --target aarch64-pc-windows-msvc --lib` | **EXIT=0**（只有一条 dead-code warning） |
| 现在的窗口开启者 **按构造** 是 macOS 专属 | `apps/gpui-app/build.rs` 无条件 `cc::Build` 编 4 个 `.m` 并 `link-lib=framework=AppKit/QuartzCore/Metal` | ObjC 441 行 + `lyrics_layer.m` 155 行 |
| 嵌入式 overlay 宿主写死了 macOS | `tools/fixtures/gpui-unity-overlay-probe/build.rs:3` `assert_eq!(CARGO_CFG_TARGET_OS, "macos")`，并直连 `gpui-fast-macos` + `host/OverlayHost.m` | 硬断言，非 macOS 直接炸 |
| Windows 侧的平台类型**存在** | `gpui-fast-windows-0.1.2/src/platform.rs:54` `pub struct WindowsPlatform`，是 `MacPlatform`（`gpui-fast-macos-0.1.2/src/platform.rs:181`）的结构对应物 | 可移植，但未在 Windows 上验证 |

**甲比乙少付的账**（这些今天全在 Unity 或 Swift 里，乙要全部重写）：

| 子树 | 文件数 | 行数 |
|---|---|---|
| `Sources/GMGNRadio/VisualEngine` | 47 | 23,330 |
| `Sources/GMGNRadio/Screen` | 29 | 9,413 |
| `Sources/GMGNRadio/MMD` | 8 | 5,022 |
| `Sources/GMGNRadio/DesktopPresence` | 7 | 3,575 |
| `Sources/GMGNRadio/AudioEngine` | 10 | 2,258 |
| **小计** | **101** | **43,598** |
| 另有 Unity 侧 C# | 115 | 14,451 |

甲今天要付的是：一层 Windows 宿主 + 8 个 `DllImport` 声明的 Windows 实现
（见 §4）。这就是选甲的理由。

**甲尚未验证的一步（诚实标注）**：GPUI 在 Windows 上能否挂进**外部父 HWND**
（macOS 侧是 `OverlayHost.m` 把 GPUI view 塞进 Unity NSWindow 的 contentView）。
`WindowsPlatform` 存在，但没有 Windows 机器跑过。这是甲唯一的架构性未知。

## 1. op 契约表（95 条）

列含义：
- **必填字段** = UI 发出该 op 时携带的字段（`handlers` 侧被 `guard let` 读取的才算"必填"，
  由 `interface_parity.rs::required_fields_are_emitted_by_the_ui` 反推）。
- **改写** = 宿主预期把它改写成另一个 op（字段原样带过去），读取算在目标身上。
- **本宿主状态** = `built` / 未建的原因分类。

| op | UI 发出的字段 | 改写 | 本宿主状态 |
|---|---|---|---|
| `agent.login` | — | — | daemon wire |
| `agent.logout` | — | — | daemon wire |
| `agent.save` | `hostPrompt`, `planningModel`, `residentPersona` | — | daemon wire |
| `app.language` | `locale` | — | **built** |
| `generation.check` | — | — | daemon wire |
| `generation.save` | `endpoint`, `token` | — | daemon wire |
| `inbox.open` | `expectedEventID`, `id`, `scope` | — | daemon wire |
| `music.connect` | `id` | — | daemon wire |
| `music.disconnect` | `id` | — | daemon wire |
| `music.sync` | `id` | — | daemon wire |
| `presence.activate` | `id` | — | daemon wire |
| `presence.catalog` | `url` | — | daemon wire |
| `presence.import` | — | — | daemon wire |
| `presence.import.link` | `url` | — | daemon wire |
| `presence.load` | — | — | daemon wire |
| `presence.motion` | `id` | — | daemon wire |
| `presence.motion.import` | — | — | daemon wire |
| `presence.motion.install` | `catalogIdentity` | — | daemon wire |
| `presence.motion.remove` | `id` | — | daemon wire |
| `presence.orb.color` | `blue`, `green`, `red` | — | daemon wire |
| `presence.orb.intensity` | `value` | — | daemon wire |
| `presence.position` | `expectedLayoutRevision`, `expectedRevision`, `position`, `requestID`, `worldID` | — | daemon wire |
| `presence.position.reset` | `expectedLayoutRevision`, `expectedRevision`, `requestID`, `worldID` | — | daemon wire |
| `presence.remove` | `id` | — | daemon wire |
| `settings.load` | — | — | local settings |
| `settings.open.presence` | — | — | local settings |
| `shortcuts.cancel` | — | — | platform hotkey |
| `shortcuts.capture` | `keyCode`, `keyLabel`, `modifiers` | — | platform hotkey |
| `shortcuts.global` | `value` | — | platform hotkey |
| `shortcuts.media` | `value` | — | platform hotkey |
| `shortcuts.record` | `id`, `scope` | — | platform hotkey |
| `shortcuts.reset` | — | — | platform hotkey |
| `space.default` | `value` | — | local settings |
| `space.key.clear` | — | — | **built** |
| `space.key.save` | `apiKey` | — | **built** |
| `space.library.load` | — | — | daemon wire |
| `space.library.select` | `id` | — | daemon wire |
| `space.prop.cancel` | `clearNotice` | — | daemon wire |
| `space.prop.check` | `endpoint` | — | daemon wire |
| `space.prop.save` | `apiKey`, `endpoint` | — | daemon wire |
| `speech.settings.cancel` | `cancelCapabilities`, `clearVoices` | — | local settings |
| `speech.settings.load` | — | — | local settings |
| `stage.activity.run` | `id` | — | unity scene |
| `stage.activity.stop` | — | — | unity scene |
| `stage.avatar.position` | `axis`, `value` | — | unity scene |
| `stage.avatar.reset` | — | — | unity scene |
| `stage.camera.reset` | — | — | unity scene |
| `stage.motion.activate` | `id` | → `presence.motion` | unity scene |
| `stage.motion.refresh` | — | — | unity scene |
| `stage.player.particles` | `value` | — | unity scene |
| `stage.program.back` | — | — | unity scene |
| `stage.program.load` | — | — | unity scene |
| `stage.program.more` | — | — | unity scene |
| `stage.program.play` | `slotIndex` | — | unity scene |
| `stage.program.replan` | — | — | unity scene |
| `stage.program.video` | `trackID` | — | unity scene |
| `stage.props.close` | — | — | unity scene |
| `stage.props.delete` | `objectID` | — | unity scene |
| `stage.props.filter` | `placedOnly` | — | unity scene |
| `stage.props.fold` | `folded`, `group` | — | unity scene |
| `stage.props.hold` | `point` | — | unity scene |
| `stage.props.load` | — | — | unity scene |
| `stage.props.nudge` | `y`, `z` | — | unity scene |
| `stage.props.resize` | `value` | — | unity scene |
| `stage.props.return` | — | — | unity scene |
| `stage.props.rotate` | `direction` | — | unity scene |
| `stage.props.select` | `objectID` | — | unity scene |
| `stage.props.undo` | — | — | unity scene |
| `stage.props.withdraw` | — | — | unity scene |
| `stage.video.bind` | `id` | — | unity scene |
| `stage.video.brightness` | `value` | — | unity scene |
| `stage.video.import` | — | — | unity scene |
| `stage.video.mode` | `id` | — | unity scene |
| `stage.video.pending.dismiss` | `id` | — | unity scene |
| `stage.video.pending.play` | `id` | — | unity scene |
| `stage.video.recoverStop` | — | — | unity scene |
| `stage.video.remove` | `id` | — | unity scene |
| `stage.video.stop` | — | — | unity scene |
| `stage.video.toggle` | `id` | — | unity scene |
| `stage.video.unbind` | — | — | unity scene |
| `tts.stop` | — | — | platform audio |
| `video.bind` | `id`, `trackID` | — | unity scene |
| `video.bound.dismiss` | `id` | — | unity scene |
| `video.bound.play` | `id` | — | unity scene |
| `video.brightness` | `value` | — | unity scene |
| `video.choose` | — | — | unity scene |
| `video.load` | — | — | unity scene |
| `video.mode` | `value` | — | unity scene |
| `video.pause` | — | — | unity scene |
| `video.play` | — | — | unity scene |
| `video.recoverStop` | — | — | unity scene |
| `video.remove` | `id` | — | unity scene |
| `video.select` | `id` | — | unity scene |
| `video.stop` | — | — | unity scene |
| `video.unbind` | `trackID` | — | unity scene |

## 2. 返回与错误码

两层，**不要混**：

### 2.1 命令的返回

宿主命令面沿用 macOS 的形状：`func command(_ value: [String: Any]) -> Bool`
（`UnityProductSettings.swift:105`、`ProductSettingsParity.swift`）——
**接受 / 拒绝**。Rust 侧对应
`handlers::dispatch(op, &fields, &store, &mut state) -> Result<Outcome, CommandError>`。
被接受的变更**不通过返回值**回传，而是进入状态，由快照投影
（`interface_parity.rs` 的第 4 条断言：UI 读的 ABI 根键必须在 overlay 的快照投影白名单里）
给 UI 读。这一点必须照抄：第二宿主若想"顺手把结果 return 回去"，UI 读不到。

### 2.2 错误码分两套

| 套 | 出处 | 规模 | 谁负责 |
|---|---|---|---|
| **权威错误码** | `services/gmgn-taskd/src/contract.rs` 的 `ERROR_CODES` | **779** 条 | 由 daemon 自己的测试从源码反推校验（`the_published_codes_are_exactly_the_authoritys_own`）。宿主只是忠实翻译者，**不许改名**。 |
| **宿主级拒绝码** | `apps/windows-host/src/refusals.rs` | **4** 条 | 本规格。 |

宿主级 4 条，且**必须再分两半**（这一点是被测试逼出来的，见 §2.3）：

| 码 | 作者 | 理由 |
|---|---|---|
| `presence_selection_busy` | **仅宿主** | marker 只有宿主持有 |
| `presence_selection_stale_cleared` | **仅宿主** | 诊断日志，不是拒绝 |
| `presence_renderer_pending` | **mirror** | daemon 已发布（`contract.rs:584`） |
| `presence_renderer_receipt_stale` | **mirror** | daemon 已发布（`contract.rs:585`） |

### 2.3 一个被测试纠正过的假设

`tests/host_refusals.rs` 的第一版断言"宿主码与权威码**不相交**"，跑出来红了：
`presence_renderer_pending` 是 daemon 发布的。正确的不变量是**划分**而不是互斥 ——
每个码要么是已发布权威码的忠实镜像，要么在"仅宿主"表里显式登记并写明理由。
**沉默是唯一错误答案**（和 `op_coverage.rs::UNITY_HOST_ONLY_OPS` 同一口径）。

## 3. 第二宿主一致性测试（入口）

任何**非 Swift** 宿主，过了这套测试就算接上。

```
apps/windows-host/                       # 本 crate 自带 workspace，根 Cargo.toml 不动
  Cargo.toml                             # 零依赖：所以 --target 检查真的会编到 Windows 专属代码
  src/
    contract.rs                          # 从 interface_parity.rs 解析 OPS（注释感知）
    registry.rs                          # 95 条 op 的登记（由契约生成后手工冻结）
    handlers/mod.rs                       # 真正实现了的 handler
    credential.rs                         # 私有文件凭据存储（见 §5）
    windows_acl.rs                         # #[cfg(windows)] 显式 owner-only DACL
    refusals.rs                           # 宿主级拒绝码
    lib.rs                                # check() —— 门禁本体
    main.rs                               # `gmgn-windows-host contract|check`
  tests/
    second_host_contract.rs               # 门禁 11 条
    credential_store.rs                   # 凭据 15 条
    host_refusals.rs                      # 拒绝码 3 条
```

### 3.1 门禁判据（`lib.rs::check`）

| Gap | 含义 |
|---|---|
| `MissingRegistration` | UI 能发的 op，本宿主没登记 → 这一下点击什么也不会发生 |
| `UnknownRegistration` | 本宿主登记了 UI 发不出的 op |
| `FieldNotDeclared` | UI 发的字段，本宿主没声明读 |
| `UnreadDeclaredField` | 本宿主声明读的字段，UI 从不发（永远读到 nil） |
| `ImplementedWithoutHandler` | 自称已实现，`src/handlers/` 里没有任何文件提到它 |

最后一条是关键：**"已实现"不是勾选框**，必须是 handler 树里有那个 op 字面量。

### 3.2 跑法

```bash
cargo test  --manifest-path apps/windows-host/Cargo.toml    # 29 条
cargo run   --manifest-path apps/windows-host/Cargo.toml -- check      # 退出码 0/1
cargo run   --manifest-path apps/windows-host/Cargo.toml -- contract   # 打印规格
```

### 3.3 能失败（真实输出，非声称）

```
$ cargo test -p ... --test second_host_contract
injected: dropped `space.key.save`
  - no registration for `space.key.save` (the UI emits it with ["apiKey"]) -- this click would do nothing
injected: registered `not.a.real.op`
  - registered `not.a.real.op`, which is not in the contract
injected: `agent.save` declares only `hostPrompt`
  - `agent.save` sends `planningModel`, which this host does not declare reading
  - `agent.save` sends `residentPersona`, which this host does not declare reading
injected: `agent.login` declares reading `inventedField`
  - `agent.login` declares reading `inventedField`, which the UI never sends
injected: `agent.login` marked implemented with no handler
  - `agent.login` is marked implemented and no handler in `src/handlers/` mentions it
```

## 4. Windows 宿主要替换的原生面（逐文件）

Unity 侧 `DllImport` 共 **8 个 C# 文件**，这是 Windows 上要一一对上的清单：

| 文件 | 导入的库 | 内容 |
|---|---|---|
| `GPUIChat2Probe.cs` | `gmgn_gpui_overlay_probe` | overlay 挂载/几何/命令 ABI（16 个 extern） |
| `NativePlayerBackend.cs` | `UnityMediaHost` | 宿主 create/command/placement/snapshot（7 个 extern） |
| `NativeUIScale.cs` | `UnityMediaHost` | 窗口尺寸/屏幕像素 |
| `UnityCompactWindowController.cs` | `UnityMediaHost` | 紧凑窗口模式（7 个 extern） |
| `FullscreenMouseReleaseBridge.cs` | `UnityMediaHost` | 光标位置 |
| `WorldCameraController.cs` | `/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics` | **直接调 macOS 系统框架** |
| `Editor/GPUIProductControlChecks.cs` | 反射读 `DllImport` | 编辑器期校验 |
| `Editor/StageVideoOrientationChecks.cs` | `/usr/lib/libSystem.B.dylib` (`dlopen`/`dlsym`) | 编辑器期校验 |

后两个是 Editor-only（不进 player）。前六个里，`WorldCameraController.cs` 是**唯一直接
调 macOS 系统框架**的运行时文件 —— Windows 等价物必须是 Win32（`GetCursorPos` 一类）。

Rust 侧另有 **macOS 专属**、必须写 Windows 等价物的：
- `tools/fixtures/gpui-unity-overlay-probe/build.rs`（硬断言 macOS）+ `host/OverlayHost.m`
- `apps/gpui-app/build.rs` + `native/{window_surface.m, program_backdrop.m, system_symbol.m}`（441 行）

## 5. 凭据：只放用户私有配置，不用钥匙串/凭据管理器

### 5.1 现状（macOS，已确认）

| 凭据 | 位置 | 权限 |
|---|---|---|
| world-labs / Marble API key | `~/Library/Application Support/ai.gmgn.radio/secrets/world-labs-api-key` | 目录 0700、文件 0600（`MarbleWorldClient.swift:18-22,63-71`） |
| 语音 provider key（bailian/elevenlabs/fish） | **`~/Library/Application Support/secrets/`**`speech-<provider>.key`（+`.imported`） | 目录 0700、文件 0600、临时文件+`rename` 原子替换、≤8192 字节、拒 NUL、`lstat` 拒符号链接（`ProductSpeechSecretStore.swift`） |
| 音乐 provider 会话 | `~/Library/Application Support/ai.gmgn.radio/secrets/music-sessions/` | 0700 / 0600 |
| 生成配置 | `RustGenerationConfigurationClient.swift:38-39` | `chmod 0700` |
| 居民 host-tools grant/plugin/bootstrap | `ResidentDSHHostToolsBridge.swift:610,641,650,782` | 0700 / 0600 |

注意 `MusicSources/KeychainMusicProviderSessionStore.swift` **只是历史文件名**：里面的实现是
`LocalMusicProviderSessionStore`，注释写明 "uses only local files; it never attempts to migrate
old system credentials"。也就是说**生产路径里没有任何钥匙串调用**——全仓
`SecItemAdd/CopyMatching/Update/Delete` 只出现在那条禁止它们的测试里。指令 1（不存钥匙串）
现状已经是满足的，本轮的活是**在 Windows 上保持并机器强制它**。

**禁止钥匙串已有测试**：`apps/macos/Tests/GMGNRadioTests/AppSmokeTests.swift:28`
`backgroundCredentialReadsCanNeverShowAKeychainPasswordPrompt` 扫描 4 个源文件，
禁止 `SecItemAdd/CopyMatching/Update/Delete`、`KeychainSpeechSecretStore(`、
`find-generic-password`、`add-generic-password`。

### 5.1.1 一个必须先拍板的分歧：macOS 现在有**两个** secrets 根

`ProductSpeechSecretStore.swift:15` 的默认目录是从
`WorldAuthorityEndpoint.taskServiceRoot` 连做两次 `deletingLastPathComponent()` 得来的
（`AuthorityWorldStatePersistence.swift:221-235`）：

```
taskServiceRoot                      = <base>/gmgn radio/TaskService
  .deletingLastPathComponent()       ->  <base>/gmgn radio
  .deletingLastPathComponent()       ->  <base>
  .appendingPathComponent("secrets") ->  <base>/secrets
```

所以语音密钥落在 `<AppSupport>/secrets/`，而 Marble key 与音乐会话落在
`<AppSupport>/ai.gmgn.radio/secrets/`。**两个根，都是历史，都不是笔误。**

`src/credential.rs` 把它们**统一**到 `<用户私有基目录>/ai.gmgn.radio/secrets`。这是刻意的
分歧：应用的用户私有秘密散在两个同级目录里，任何"备份/清理/加固"脚本都只会覆盖一个；
而 `Application Support/secrets` 还是所有应用共享的命名空间。

**需要人拍板**：Windows 要么跟 macOS 一样分两个根（逐字节兼容），要么两边一起收敛到一个根
（要一次 macOS 侧迁移）。本轮选了后者，于是**两侧文件布局暂时不一致**——Windows 真正发版前
必须收口。这是本轮明确**未完成**的一条。

### 5.2 Windows 对应位置

```
%LOCALAPPDATA%\ai.gmgn.radio\secrets\
    world-labs-api-key
    speech-bailian.key
    speech-elevenlabs.key
    speech-fish.key
    speech-<provider>.imported
```

- **`%LOCALAPPDATA%` 而不是 `%APPDATA%`**：后者是漫游配置，会同步到域服务器 ——
  提供商密钥最不该去的地方。`%LOCALAPPDATA%` 是每机器每用户。
- Windows 默认给 `%LOCALAPPDATA%` 的继承 ACL 只授权本用户 + SYSTEM + Administrators。
  `src/windows_acl.rs` 在此之上用 `SetEntriesInAclW` + `SetNamedSecurityInfoW`
  （`DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION`）把继承 ACL 换成
  **显式 owner-only**，对应 macOS 侧的 `chmod 0700`。
- **明确不使用**：钥匙串、**Windows 凭据管理器**（`CredReadW`/`CredWriteW`/
  `CredDeleteW`/`CredEnumerateW`）、DPAPI（`CryptProtectData`/`CryptUnprotectData`）。
  这份禁用清单在 `tests/credential_store.rs::FORBIDDEN_CREDENTIAL_APIS`，并且有一条
  测试**从 macOS 测试文件里把禁用串读出来**，断言 Windows 的清单是它的超集 ——
  两个平台不许各自漂移。

## 6. 本轮"实测"与"推断"的边界

**实测**（本机，命令+退出码见 §0 与汇报）：
`gmgn-taskd --target x86_64-pc-windows-gnu` 通过；`gpui-ui --target aarch64-pc-windows-msvc`
通过；`gmgn-windows-host` 本机 29 条测试全绿；`gmgn-windows-host --target x86_64-pc-windows-gnu`
检查通过（含 `windows_acl.rs` 真的被编到）。

**未实测**：
`aarch64-pc-windows-msvc` 全链路（本机无 MSVC Windows SDK，卡在 `ring`/`aws-lc-sys` 的 C 编译）；
`windows_acl.rs` 的**运行**（只 `cargo check` 过，没在 Windows 上执行，`check` 也不链接，
所以导入库名是靠对照 Win32 文档核对的，不是加载器验证的）；
GPUI 挂进外部父 HWND；Unity Windows player 的实际产出。

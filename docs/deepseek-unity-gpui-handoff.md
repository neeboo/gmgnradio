# DeepSeek 交接：Unity 正式工程接入全部新 GPUI 组件

记录时间：2026-10-08。用户已停止 Codex 开发；本文件仅交接，不表示功能已经完成。

## 1. 唯一工作目录和分支

```sh
cd /Users/ghostcorn/.codex/worktrees/rust-full-migration/gmgnradio
git branch --show-current
git status --short
git log -3 --oneline
```

- 工作分支：`codex/rust-full-migration`
- upstream：`origin/codex/rust-full-migration`
- remote：`git@github.com:neeboo/gmgnradio.git`
- 当前 HEAD：`88bb67a4b063c8e7473f4fd69f9dfdc98d846b95`
- HEAD 标题：`feat: the UI layer over the space, rebuilt on one foundation`，DeepSeek 的新 UI 提交。
- 前一提交：`886bd0b WIP: preserve Rust and embedded GPUI migration state`。
- **当前存在大量未提交改动。只 checkout 这个提交或只拉远端分支，会漏掉本次工作。**
- `/Users/ghostcorn/dev/gmgnradio` 是另一个旧 checkout，不能用它构建此次交接版本，也不要在 main 上覆盖这些改动。

本机交接直接让 DeepSeek 使用上述现有 worktree，不需要新建或切换分支。先读取本地 Git 状态和差异，禁止 reset、clean 或回退他人改动。本次没有新 commit、push、merge。

## 2. 用户最终需求

**把 DeepSeek 已做的全部新 UI 组件接入当前 Unity 正式工程，替换旧 UI，完整保留生产功能接线。**

- 视觉使用 DeepSeek 的风格和共享标准组件；不能仅给旧菜单换背景。
- Unity 继续提供真实生产场景、2B、物件和世界运行时。
- 完整覆盖聊天、系统消息、设置、舞台设置、物件编辑、节目轨道和产品外壳。
- 外壳包含浮动栏、目的地、任务状态、小窗和命中区；不能仅接浮动栏。
- 设置按钮打开独立设置窗口，不嵌在 Unity 场景里。
- 全屏和窗口模式均需正确定位；聊天实际可见底部贴近浮动栏。
- 歌词保留原动态效果，但浮动栏必须有可见开关和正确状态接线。
- 音乐库应能进入实际歌曲列表，队列、节目、电视、消息、愿望应保留完整操作。
- 修复聊天输入光标及实际 DSH 会话接线。
- 修好并逐项实际验证后再打正式包、安装；不能每发现一个问题就交一个包。
- 不运行会出声的音频测试，不改音量、设备、分辨率，不触发钥匙串。

## 3. DeepSeek 已完成组件与正式产品入口

| 新组件 | 源码 | 当前 Unity 嵌入状态 / 要做的事 |
| --- | --- | --- |
| ResidentChatPane | apps/gpui-ui/src/chat.rs | 已被嵌入层使用；输入光标及 DSH 接线失败仍需验证修复 |
| InboxPane | apps/gpui-ui/src/inbox.rs | 尚未完整替换 media_ui 的旧消息菜单 |
| AgentSettingsPane | apps/gpui-ui/src/settings.rs | SettingsPane 已复用；独立窗口新增代码尚未实际点击验收 |
| StagePanelsPane | apps/gpui-ui/src/stage_panels.rs | SettingsPane 已复用，需检查各页生产功能与窗口布局 |
| ResidentPropEditorPane | apps/gpui-ui/src/stage_panels/props.rs | inventory_ui 仍是独立旧适配面，尚未完整替换成此组件 |
| StageProgramRailPane | apps/gpui-ui/src/stage_panels/program.rs | media_ui 尚未接入，需适配 catalog、歌单/歌曲导航、队列/节目 |
| GMGNProductUI 新外壳 | apps/gpui-app/src/main.rs | 嵌入 shell 只复用了部分共享 chrome，完整外壳行为尚未搬齐 |

**重要：`apps/gpui-app` 是独立实验入口，不是此次 Unity 正式包入口。** 不要为了得到新 UI 把正式包换成 standalone SceneKit 应用，那会丢失用户期望的 Unity 生产素材和世界。

正式嵌入实现：

```text
Unity Player
  → apps/macos/UnityHost（生产快照、命令、媒体、DSH 桥接）
  → tools/fixtures/gpui-unity-overlay-probe
      host/OverlayHost.m（NSView 挂载、透明、尺寸、事件）
      src/lib.rs（同一 GPUI runtime、快照/队列、独立设置窗口）
      src/shell_ui.rs（Unity 内嵌外壳）
      src/media_ui.rs / inventory_ui.rs / settings_ui.rs（适配面）
  → apps/gpui-ui（应复用的 DeepSeek 新组件）
```

不能复制出第二套世界、账号、播放上下文或生产数据。新组件的快照和操作应适配现有 authority。

## 4. 当前未提交文件逐项说明

交接时 `git status --short` 有以下项目；请以实际 diff 为准，包含协作者改动：

| 文件 | 当前内容 / 注意事项 |
| --- | --- |
| Makefile | 新增 env 配置入口、release-install、install-built；正式默认入口保持 Unity |
| config/release.env（未跟踪） | 当前版本配置 221、Release、单 Cargo job、offline 和安装目录 |
| docs/release-build.md（未跟踪） | 简短构建安装说明 |
| apps/macos/GMGNRadio.xcodeproj/project.pbxproj | 构建生成的项目变化，不能随意回退 |
| apps/unity-player/Assets/GMGN/Localization/LocalizationSettings.asset | Unity 生成变化，需审阅归属 |
| apps/macos/UnityHost/UnityMusicSessions.swift | 补 authority 保存及 isDisabled，解决原调用缺成员的编译问题 |
| tools/build-gpui-product-app.sh | 其他协作者的 lipo 参数顺序修正，保留 |
| host/OverlayHost.h、host/OverlayHost.m | 全视口挂载、真实 hit regions、透明层、resize、延迟初次 resize；另有尚未打包的 caret 激活同步修复 |
| src/lib.rs | AllAssets、透明 Root、快照/命令适配；移除内嵌设置，新增同 runtime 独立设置窗 |
| src/shell_ui.rs | 新共享浮动栏/目的地、内容大小聊天、导航、命中区；最新歌词按钮改动尚未打包 |
| src/media_ui.rs | 部分共享卡片/按钮及歌曲导航改动；仍未实际导入新 rail/inbox 组件，不能宣称完成 |
| src/inventory_ui.rs | 共享卡片、标准按钮/状态、滚动边界；仍未完整迁移到 ResidentPropEditorPane |
| src/settings_ui.rs | 共享外壳和 can_close，保留待提交编辑，Settings 页面仍复用新组件 |
| services/gmgn-taskd/src/agent_tools.rs | nullable type union 校验的半成品修改，尚未补完回归验证 |

表内 host/src 简写均位于 `tools/fixtures/gpui-unity-overlay-probe/`。本交接文件本身也是新增未跟踪文件。

## 5. 已定位的缺陷与修复状态

### 5.1 全屏聊天离浮动栏很远

原因：shell 给聊天外层固定 320 高度，ResidentChatPane 只有 max-height、实际内容较短；可见聊天靠容器顶部，下面留空。

当前源代码改为聊天内容自适应高度、去掉 flex_1 撑高，底部锚点为 `TRANSPORT_INSET + TRANSPORT_HEIGHT + COMPOSER_GAP`。图片拖拽/命中 bounds 同步真实容器。

纯布局回归测试已实际通过 1 项。候选 221 全屏截图看到聊天贴近浮动栏；**这仅证明间距，不能证明聊天业务可用**。

当前全屏日志 host/donor/mounted 均 2048×1152，scale 2，Unity framebuffer 4096×2304。另有跨屏 DPI 风险：隐藏 donor 的 screen/倍率可能仍在原屏；尚未复现，不应直接宣称已修。

### 5.2 聊天输入光标不显示

原因已定位：gpui-kit InputState 的 caret 条件包含 `window.is_window_active()`；隐藏 donor 未同步真实 Unity key window 状态。

最新 OverlayHost.m 修改把 donor `isKeyWindow` 映射到宿主，并同步 key/resign 通知到 GPUI delegate，detach 恢复原 class。clang 语法和无窗口 ABI smoke 已通过。

**此修改发生在候选 221 构建后，未进入该包，也未进行实际输入光标验收。** 需重新构建后验证焦点、打字、光标、中文输入、独立设置激活后的失焦。

### 5.3 聊天没有业务接线 / error 3

截图真实显示 `UnityMediaHost.RustDSHSessionClient.ClientError error 3`。

诊断记录：2026-10-08 19:19:53 taskd 拒绝 `agent_dsh_invalid_tools`。生产 52 项工具中 `submit_wish_generation` 的 destination/position/size_intent/millimeters 使用标准 JSON Schema `type: ["object", "null"]`，Rust `supported_schema` 原只接受单字符串，整组注册被拒绝，会话无法启动。

`services/gmgn-taskd/src/agent_tools.rs` 已落地 union 类型校验/值校验部分，但暂停时尚未完成真实 catalog 回归测试、正式 daemon 重建和端到端验证。Swift request 把业务拒绝压成 transport，需保留结构化错误定位真正失败，不能仅替换提示文字。

### 5.4 子菜单未替换、歌曲列表不对、歌词入口缺失

截图证实旧 media 子菜单透明、旧列表/按钮呈现，歌单与歌曲导航未完整对齐。最终必须复用 DeepSeek 的 StageProgramRailPane、InboxPane 和物件组件，完整适配生产快照/命令。

shell 最新源码新增可见 lyrics 控制，接 `ui.lyrics.toggle`、active 读 `ui.lyricsVisible`；**当前候选 221 尚无该新增按钮**。

最新 inventory/settings 检查被 media_ui.rs 的 Rgba/Hsla 类型冲突阻断（约 545 行、`cx.theme().danger`，行号会随修改变化）；继续前先跑整体 check，不能把之前旧状态 check 通过当成当前通过。

### 5.5 独立设置窗口

lib.rs 新增 SETTINGS_WINDOW，点击 `ui.settings.open` 创建标题“设置”的 860×700 GPUI 窗口，使用同一 Application runtime。更新使用自身 Window；重复点击激活，关闭/重开/unmount 有处理。

settings_ui.rs 的 can_close 在依赖前一条回执的编辑尚未发送完时暂缓关闭，避免丢编辑。需要实际验证窗口独立打开、关闭重开、保存及回执；仅 API 编译通过不能代替验收。

## 6. DeepSeek 原清单中的剩余事项

用户提供的 DeepSeek 自述列出了：

1. `apps/gpui-ui/src/lyrics.rs` 的 StageLyricsPane / StageBoundVideoPromptPane：动态歌词豁免，但“播放”和“×”文字按钮还需统一标准按钮。
2. `apps/gpui-app/src/bin/gmgn-unity-settings.rs` 的 UnitySettings 独立窗外壳未按新基础整理。当前正式嵌入新增独立设置窗在 overlay lib.rs；要明确正式运行哪个入口，避免维护两套没有实际挂载的外壳。
3. `i18n.rs` 缺“请按一个完整的按键组合。”及页签 DJ 的 en/ja 条目。
4. kit TabBar/Slider/Spinner 内部颜色无注入点，以及投影节目卡片保留 role(Button)，为 DeepSeek 已说明的约束，不能当成随意复制旧 UI 的理由。

这些是用户提供的清单，尚未在本交接轮逐项验收。projective_card.rs / state.rs 的数学与状态逻辑不要为换风格无关重写。

## 7. 版本、产物和生产数据

- 已安装正式包：`/Users/ghostcorn/Applications/gmgn radio.app`，读回 CFBundleVersion **220**。
- 最近候选：`apps/macos/Build.noindex/Build/Products/Release/gmgn radio.app`，读回版本 **221**。
- 221 已构建、签名及 metadata 校验，并启动截图过，但未安装；后续源码修复没有进入 221。
- 主应用进程在交接核查时未运行；不要把候选自动启动当必要交接步骤。
- Bundle ID：`ai.gmgn.unity-sample.player`；Unity 可执行名 `GMGN Unity Sample`。
- 当前正式安装路径是用户 Applications，不能再同时往 `/Applications` 放另一份同名包。
- 旧 `/Applications/gmgn radio.app` standalone 已移入可恢复的 Trash：`/Users/ghostcorn/.Trash/gmgn-standalone-unused.noindex.EiDeMo/gmgn radio.app`。
- 生产资源在 `/Users/ghostcorn/Library/Application Support/gmgn radio/PresencePackages`、MotionPackages 等既有目录，复用，不清空/迁移。
- 存在两个既有 daemon root：`/Users/ghostcorn/Library/Application Support/gmgn radio/TaskService` 和 `/Users/ghostcorn/Library/Application Support/TaskService`。安装器默认管理前者，Unity 还可能使用后者。替换包时确认 app-owned helper 是否仍映射旧二进制；不要本轮擅自合并数据目录。
- Player.log：`/Users/ghostcorn/Library/Logs/DefaultCompany/GMGN Unity Sample/Player.log`。

## 8. 构建与安装：使用 Make + env

先完成源码和检查，再构建；不要从另一个 checkout 打包。

```sh
cd /Users/ghostcorn/.codex/worktrees/rust-full-migration/gmgnradio
git branch --show-current
git status --short
make release
```

`config/release.env` 为 Make 语法，不是 shell source 文件；路径带空格时不加引号。当前配置：build 221、version 0.1.0、Release、CARGO_INCREMENTAL=0、CARGO_BUILD_JOBS=1、CARGO_NET_OFFLINE=true。下一次实际发布应递增版本号（例如 222），不要继续发同号不同内容的包。

入口：

```sh
make release         # 构建/签名/封印候选，不安装，不启动
make install-built   # 验证并安装已有候选，不重编，不启动主应用
make release-install # 构建后立即安装；未完成视觉验收前不要用这条
```

需要本机不同配置时：`make release BUILD_ENV=/absolute/path/local.env`。配置文件禁止保存凭据。当前默认安装到 `/Users/ghostcorn/Applications/gmgn radio.app`。

正式流水线：`tools/build-unity-product-app.sh` → Unity CLI PlayerBuild → Swift UnityMediaHost → Rust taskd → Rust GPUI overlay dylib → package-gpui-chat2-probe → metadata/manifest → codesign strict verification。

依赖：本机 Unity CLI/与 ProjectVersion.txt 匹配的 Editor、Xcode/xcodegen、Rust +1.95.0、现有离线 Cargo 与 SwiftPM 缓存、Python3、已缓存 yt-dlp/deno helpers。缺依赖应明确报告，不自动下载大包或清缓存。当前正式脚本只支持 Release/当前架构；旧 install-debug/install-universal 不可直接视为此 Unity 路径可用。

编译同一 target 的任务按顺序运行，勿同时多路 cargo/xcodebuild。构建证据保留在 `tmp/ReleaseArtifacts.noindex/unity-product.*`；旧候选可恢复移动到同产品目录 `.unity-previous.*`，不要递归清整个 worktree。

## 9. 检查命令与验收边界

这些是可复用命令，**当前新增改动仍需重新执行**：

```sh
CARGO_TARGET_DIR=tools/gpui-scenekit-probe/target cargo +1.95.0 check --release --lib --manifest-path tools/fixtures/gpui-unity-overlay-probe/Cargo.toml --offline --locked -j1
CARGO_TARGET_DIR=tools/gpui-scenekit-probe/target cargo +1.95.0 test --release --lib --manifest-path tools/fixtures/gpui-unity-overlay-probe/Cargo.toml --offline --locked -j1
python3 -m unittest discover -s tools/tests -p test_gpui_product_entry.py
python3 -m unittest discover -s tools/tests -p test_unity_product_entry.py
python3 tools/unity-product-metadata.py --verify 'apps/macos/Build.noindex/Build/Products/Release/gmgn radio.app'
codesign --verify --deep --strict 'apps/macos/Build.noindex/Build/Products/Release/gmgn radio.app'
```

另需给 agent_tools nullable union 补回归测试并按 services/gmgn-taskd Cargo manifest 跑目标测试。先确认具体包/测试名，不把没执行的命令记成通过。不要直接 `make test-all`：它含更宽的测试/清理范围，用户禁止扰动音频，先审查各目标。

此前通过：overlay 11 项旧逻辑测试；新增聊天布局 1 项；product entry 5 项；installer 41 项、1 skipped；原生无窗口 ABI smoke。它们不覆盖当前最后一批暂停中的改动，也不等于业务/视觉验收。

实际验收清单：

- 窗口/全屏来回切换，浮动栏、目的地、每个菜单的可见位置和点击命中一致。
- 聊天贴浮动栏；点击后光标可见、输入可编辑、中文输入正常；发送后会话确实启动并收到真实回复，error 3 不再阻断。
- 音乐库进入歌单后出现歌曲、返回正确、队列与节目选择使用生产状态。
- Inbox、物件编辑和节目轨道确实使用 DeepSeek 组件，不是旧列表换皮。
- 设置独立窗口打开、保存、关闭重开；各页全部操作对应 production authority。
- 电视、愿望、目的地、任务状态、小窗等用户要求入口完整；歌词按钮可见、active 与开关一致。
- 不播放测试音频，不修改系统设备、音量、画面分辨率或钥匙串。
- 验证候选之后才安装；安装后核对正式路径、版本、component manifest、daemon 和截图，不能把 build success 作为运行成功。

现场截图：`/Users/ghostcorn/Desktop/screenshot-2026-10-08_19-21-52-w108929.png`（另有 w108931、w109014）。截图显示旧节目子菜单透明样式，作为未完成证据，不作为验收截图。

## 10. 可直接发送给 DeepSeek 的交接文本

> 请在现有 worktree `/Users/ghostcorn/.codex/worktrees/rust-full-migration/gmgnradio`、分支 `codex/rust-full-migration` 继续；先完整阅读 `docs/deepseek-unity-gpui-handoff.md` 和实际未提交 diff。HEAD 是你的新 UI 提交 88bb67a，后面有未提交的嵌入、构建、输入焦点和 nullable schema 半成品。把你做好的全部新组件真正接入当前 Unity 正式工程，保留生产场景、2B、数据和完整业务命令，视觉用你的风格。不要换成 standalone SceneKit，不要仅给旧菜单换背景。完成全部入口和子菜单、DSH 会话/光标/歌曲列表/歌词入口/独立设置，并先逐项真实验证，再用 Make+env 构建安装到用户 Applications。禁止音频扰动、分辨率变化、钥匙串和破坏性清理。保护现有改动，不在 main 上覆盖。提交/推送/合并按用户后续明确指令执行。

## 11. 远程交接注意

当前未提交文件只在本机 worktree。若 DeepSeek 在别的机器，需要用户指定传递方式或明确要求提交推送；单独给分支名不够。未跟踪的 config/docs 也必须包含。不要随便 `git add -A` 把生产凭据、缓存、包或生成文件全部提交；先审阅逐项选择。

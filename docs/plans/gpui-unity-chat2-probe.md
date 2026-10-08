# “聊天2”同窗口可行性验收

## 当前实施范围（2026-10-08，覆盖下文实验约束）

用户已确认同窗操作可用，授权替换全部 Unity UI，歌词保留。使用锁定 `gpui-kit` revision `c1bda59e67f46266991a230ae94f749af496af2a` 的文档与标准组件；已阅读 Getting Started、Design Guides、Window 和组件目录。应用保留原生产 TaskService、2B、世界与播放上下文，界面只消费同一快照及命令通道。凭据平台钩子禁止转交 Keychain。

聊天、物品、设置、媒体及播放器 shell 已整合，GPUI 离线锁定构建通过，5 项投影/传输测试通过；Rust 服务 512 项通过、5 项跳过。尚在补图片拖拽、内部导航与本地窗口/相机桥，并进行正式包运行验收。旧 Unity UI 在替代入口实际挂载并核验前保留。构建和私有测试不代表用户功能已全部验收。

以下原型段落是历史记录，不再限制当前生产数据接线。

用户要求先验证，再迁移界面。本实验不接模型、TTS、音乐、正式数据库或生产 AppDelegate。

## 最小原型

使用当前锁定 gpui-kit 的标准消息列表/滚动容器、文本输入和发送按钮。本地发送只回显输入内容。面板标题为“聊天2”，原生宿主必须是 Unity 自身主窗口内的覆盖视图；独立窗口贴窗不算通过。

## 必须分别记录的证据

- 真实 GPUI 面板在 Unity 场景上可见，双方视图属于同一个 NSWindow。
- 点按发送可回显，面板外点按仍进入 Unity 场景交互。
- 英文输入、中文输入法组合与提交、删除、粘贴可用；失焦后场景快捷键恢复。
- 调整尺寸、Retina backing scale、进入/退出全屏后位置与点击坐标正确。
- 连续挂载、卸载不留下视图、回调或 GPUI 临时窗口；不替换 Unity 的 NSApplication delegate。
- 未创建第二世界、聊天事件消费器或播放上下文。

编译通过只证明源代码和链接；AppKit 测试宿主通过不替代真实 Unity Player 的运行验证。隐藏 donor GPUI 视图若用于实验，须单列其原窗口事件/生命周期限制，不能据此认定生产外部窗口适配完成。

## 当前状态

正式 v211 已实际运行原生产 TaskService；角色恢复 SQL 与设置接口确认原 2B 选择、PMX `ready`，Player 日志 `[CharacterSelection] ready revision=2 character=pmx.2b-miss-0414-standard`。真实全屏截图同时显示 2B、原场景物件与同窗聊天2。物件恢复 JValue 异常与红字不再出现。所有应用凭据钥匙串调用已退役，详见 `docs/key-storage-audit-2026-10-08.md`；既有条目未读未删。

标准 kit Root/深色主题挂载补齐后，v211 中文粘贴在输入框即时可见，发送后消息区真实回显。键入 `hello` 仍未进入输入框，不能宣称键盘/IME验收通过。限量无文本内容的 native 事件诊断插件已编译退出 0，日志 `/tmp/gmgn-chat2-input-diag-build.log`，尚未安装复现。

正式 v208 已签名校验、替换 `/Users/ghostcorn/Applications/gmgn radio.app` 并静音启动，原 v207 完整备份保留于 `tmp/ReleaseArtifacts.noindex/pre-chat2-v207.04fMWb/`。实际 Unity 主窗口截图确认 GPUI 聊天2可见；中文粘贴后点击发送，消息区出现真实输入内容。未使用测试数据 root 或私有 settings suite。当前生产选择读回为 `builtin.orb`，用户要求恢复现有 2B，数据路由/选择恢复尚在排查，不认定生产验收通过。

实际运行暴露两项缺陷：GPUI 输入时 Unity 镜头仍响应键盘；世界恢复和 LateUpdate 对合法 JSON null 的 heldProp 继续取字段，触发 JValue 异常并显示“新物件暂未载入”。两项正在修复；输入即时重绘已补源代码，待统一构建与正式包复验。日志 `/tmp/gmgn-v208-chat2-player.log`。下文为此前构建记录，安装状态以本段为准。

实际 Unity 第四轮构建退出 0，产物 `tmp/ReleaseArtifacts.noindex/unity-player-chat2-v208.app`，日志 `/tmp/gmgn-unity-chat2-player-build-cli-4.log`；包含现工具栏聊天2入口。UnityMediaHost 最新完整构建退出 0，日志 `/tmp/gmgn-chat2-unity-media-host-build-2.log`。taskd Release 构建退出 0，日志 `/tmp/gmgn-chat2-taskd-release-build.log`。单实例 native 帧驱动、鼠标坐标及 IME 候选位置修复后 probe 再次编译退出 0，日志 `/tmp/gmgn-chat2-probe-native-adapter-build.log`；实际窗口输入仍待验证。当前 package-unity-media-host 进行中，日志 `/tmp/gmgn-chat2-unity-package.log`，尚未正式安装。

用户已明确授权修改正式包并启动测试。当前 Applications/gmgn radio.app 读回确认为 `ai.gmgn.unity-sample.player`、可执行文件 `GMGN Unity Sample`，与现工程一致；尚未替换。PlayerScreen 已常规注册组件并在现工具栏提供“聊天2”打开/关闭按钮，环境开关仅控制自动打开。正式更新前须保留原包备份、核验包内代码/资源，再静音启动；不能把编译通过当作实际界面通过。

用户随后明确要求直接在当前 GPUI+Unity 工程验证。现工程新增 `GPUIChat2Probe`，由原 `PlayerScreen` 在同一 WorldRuntimeBridge 就绪后挂载，`GMGN_GPUI_CHAT2_PROBE=1` 启用，不新建世界/业务/音频上下文。

真实 GPUI dylib 首轮构建退出 0，7 个导出符号已核验。外部宿主试运行退出时实际暴露 AsyncApp 提前释放崩溃，已改宿主进程全生命周期保留单一 ApplicationHandle，卸载仅移除面板/donor；修复重新编译退出 0，仍须实际 Unity 运行核验。

现工程 Unity 第一轮真实构建发现 `.meta` GUID 33 位导致脚本被忽略，修正为 32 位后第二轮脚本编译通过。第二轮 BuildMac 因迁移 worktree 缺少现有 Gaussian Cabin.prefab 未完成，正在核实原工程已有生成资源，不采用空场景替代。两轮日志 `/tmp/gmgn-unity-chat2-player-build.log`、`/tmp/gmgn-unity-chat2-player-build-2.log`。

接口审计确认 Unity 插件可取得主窗口/contentView；当前 GPUI 核心提供外部平台接口，但 stock MacPlatform 会运行自己的应用循环，stock MacWindow 不接受外部窗口。

隔离原型源位于 `tools/fixtures/gpui-unity-overlay-probe/`，包含真实 kit Input/Button、本地消息回显、保留宿主应用循环的 Platform wrapper，以及隐藏 donor 的真实 GPUIView 挂载。原生桥、独立启动器及使用真实 Unity 程序集的 C# 挂载脚本均已编译通过。主代理重新编译并执行无窗口 ABI 空参数负控，退出 0；此检查未创建 NSApplication 或视图。

审阅修复了返回值反向判断：native register/attach/detach 成功为 1；Rust mount 成功为 0。失败路径不保留 ApplicationHandle，卸载先 detach 再 remove_window。GPUI 动态库尚待编译、符号核验和实际窗口试验；全部显示/输入验收项仍未证明。

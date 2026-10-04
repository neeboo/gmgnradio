# Swift UI → GPUI Kit 完整对齐与真实 App 验收

更新时间：2026-10-04。此文档来自当前 Swift/GPUI 源码只读审计；不代表运行验收通过。

### 本轮字体、间距与图标修复（v46）

#### v50：按 GPUI Kit 尺寸 API 修正

用户实测指出 v47 舞台按钮大于正文、四页签 padding 错误。本轮阅读官方 0.7.0 Design Guides、Button、Tabs、Theme，并核对本地组件源码：Button 的标签字号按 Size 单独设置，外层字体无法覆盖；Tab 自有内部 padding，额外固定宽高会冲突。舞台按钮统一 small，四页签采用 segmented/small/w_full、子项 label/flex_1/min_w_0；去掉固定133宽、24高与标签强制字号。正文采用 text_sm，与 small 按钮一致；状态说明 text_xs。提示区采用 semantic muted/warning、text_xs 和 xsmall 恢复按钮，去掉手工按钮宽高与9/10px字号。

UI完整114项通过，Release v50构建退出0。PID19735核对隔离根与 mounted=true，实际截图确认提示区新字号、颜色与说明生效。CUA读到了舞台设置入口，但AX点击未展开、坐标点击报 noWindowsAvailable；四页签和角色按钮实际视觉复验尚未通过，不将构建/样式回归算最终验收。v50测试App保留运行供用户查看；未修改安装版或清数据。

规范来源：https://gpui-kit.com/docs/design-guides/ 、https://gpui-kit.com/component/button/ 、https://gpui-kit.com/docs/components/tabs/ 。

- 2D UI 接入 Kit 原生系统字体，统一正文14/说明12/分组16/标题20，行高20/16，间距4/8/12/16/24；保留小窗尺寸、原布局与歌词艺术字体。使用 frontend-design 技能整理共享视觉规范，没有新增字体包。
- SF Symbols 原位图绘制格式无法建立有效 CGContext，曾返回全透明像素；修复预乘绘制与 GPUI BGRA 上传，4个符号×3种颜色非零像素验证通过。App测试16项及ABI1项通过，Release v46构建退出0。
- v46 PID17009启动后核对隔离数据根与 mounted=true，实际截图确认聊天图标和右上播放器图标已显示；随后聊天点击遇到 noWindowsAvailable，聊天/设置全部排版与空间反向图标尚未完成实际复验，不标整体通过。
- 节目卡片主线程SVG/模糊/投影后台化仍在集成验证，歌词/换歌卡顿未验收通过。未覆盖安装版，未清用户数据。
- 后续刷新窗口绑定并使用原生“抬升”和 Cmd+,，实际设置页已显示系统字体层级及一致卡片间距；坐标点击仍遇到工具窗口绑定错误，不能据此标聊天全流程通过。
- 后台节目卡片实现已冻结，UI完整113项通过；有界12个待处理ID/24个完成结果，旧代次拒绝，绘制与命中共用已完成投影。局部debug窗口绘制11.3ms/滚动5.3ms仅为回归数据。v47整包Release构建成功，实际播放采样待复验。

## 完成定义

### 2026-10-04 新设计授权：统一分类设置（v51）

用户明确要求改为 ChatGPT 式左分类/二级菜单/右内容；取代此前两套设置窗口和原顶部tab的布局约束。现在底栏设置与 Cmd+, 打开同一880×640窗口（最小760×540），使用Kit Sidebar。一级播放器、空间、角色、音乐、对话与语音、应用；二级只曝光现有真实功能，角色管理/动作管理、Agent连接/语音播放/按住说话等真正过滤各自分组。默认空间仍在“我的空间”内可达。音乐账号和同步共用真实provider卡，未新增空白设置页。活动保留应用菜单“角色活动…”操作入口；物件摆放、小窗原入口保留。所属GPUI设置文案改称角色，内部协议DJ标识保留。

实际隔离Release v51 PID23816 root/mounted核对成功，Cmd+,截图已显示六类侧栏与歌词设置，旧舞台浮层不再打开。CUA二级点击遇到 noWindowsAvailable，分类切换与全部业务端到端仍待实测；UI115/115、App16+ABI1、Host和Release构建退出0。

同时整合：普通聊天提交通过正式close生命周期结束隐藏装修，不删除已摆放物件；世界写guard保留，提交回归19项通过。自主默认缺键true、保留已保存false，已完成摆放清旧暂停且不新增授权/重放事件，Coordinator205项通过。另一旧聊天harness在新增用例前voice-source断言失败，未标通过。主代理审阅发现GPUI启动绕过Swift App.init默认注册，已要求补正式Host/AppDelegate两启动入口；默认自主和实际恢复尚未标App通过。已知旧错误提示转换成用户可读状态，不隐藏未保存事实。

补漏完成：GPUI创建与AppDelegate实际启动入口均在隔离bootstrap后注册default，新回归通过，Host build28退出0，新Release v52已打包包含此修复。未覆盖用户已保存false，不重放历史暂停委托；真实恢复/聊天全流程仍待验收。

### v53：分类菜单整行展开修复

用户反馈父菜单点不动。核对 Kit 0.7.0 源码，`SidebarMenuItem` 默认 `click_to_toggle=false`，此前父项没有导航回调，只有箭头可展开。设置父项 `.click_to_toggle(true)`，并 `.default_open(active)` 默认展开当前分类。

新增导航配置回归先失败再通过；全套 UI 测试 115 通过、1 项歌词任务边界等待失败，单独复跑该歌词测试通过，不宣称整套首次全绿。Release 构建与签名验证退出 0，日志 `/tmp/gmgn-v53-build.log`。真实隔离 App v53 已打开：CUA 点击“视觉效果”切换至 3D 点阵页；点击“角色”整行展开三个子项；点击“角色管理”切换并出现导入、选择和当前角色更多按钮。上述菜单交互通过，不代表所有设置功能完成验收。运行日志 `/tmp/gmgn-v53-runtime.log`，数据根沿用隔离副本，未修改已安装 App。

迁移对象为真实 gmgn 主应用的全部 2D UI，保留 SceneKit/Metal/人物/音乐和世界业务行为。用户最新明确要求布局也与原 Swift 对齐，不改变原布局；使用 GPUI Kit 成熟组件不能改入口位置、面板结构、窗口大小或显隐规则。原有功能、状态、快捷键、数据持久化和错误恢复不得丢失。独立 probe 的叠放、聊天或构建结果仅作技术证据。

### 布局硬约束（原源代码与本轮真实 Swift App 对照）

| 区域 | 原布局，迁移必须保留 |
| --- | --- |
| 舞台 | 初始 1180×760、最小 760×520；SceneKit 全窗，不能加常驻左栏挤压场景 |
| 底栏 | 原 11 个控件顺序与分组；529×48，距右、下各 22 |
| 聊天 | 原右下显隐面板；优选 620 宽、最高 320，距底栏 16；历史 132 高，复制在历史右侧 |
| 目的地 | 原右上 112×38，距右 22、顶 28 |
| 任务状态 | 原左上 280 宽，距左、顶 22；保留自主关闭／恢复状态与入口 |
| 舞台设置 | 原播放器／空间／角色／活动四分区与分组顺序，右侧弹出，不替换成独立侧栏 |
| 节目轨道／物件 | 原右侧节目 350×430、物件 340 宽，距原底栏相同位置；互斥显隐规则不变 |
| 系统设置 | 原 580×500，最小 540×440；顶部 330 宽五分段（角色／音乐／空间／快捷键／DJ），顶 14、下 8 |
| 通知 | 原独立 720×460 窗口，列表 300 宽，右侧详情／打开；选择不标已读 |
| 小窗 | 原 224×336；右侧六个竖排入口、原显隐输入区与回复气泡；不能用永久下半黑栏或放大窗口替代 |

上轮 340 宽左栏与 720×760 独立 Agent 设置窗不符合本要求，已从当前入口移除；其聊天技术验证保留，但不作为布局通过。

以下清单的“首次审计差距”列保留最初审计基线，**不代表当前实现状态**。当前进度以本文运行证据及下述断点为准；未逐项完整验收的条目仍不得整体标通过。首次审计时 `apps/gpui-ui/src/lib.rs` 只有 `ResidentChatPane`，图片入口禁用、`apps/gpui-app` 尚未出现；后续正式产品宿主及 Kit 页面已实现，独立宿主历史结果不能升级为正式 App 验收。

源文件路径下文相对仓库根目录。验收必须同时验证可见控件与实际业务结果，逐项记录截图、操作、状态读回和失败；不能以构建成功或静态状态值标通过。

## 设置五页

总入口：`apps/macos/Sources/GMGNRadio/Settings/GMGNSettingsView.swift` 的 `GMGNSettingsView`；角色、音乐、空间、快捷键、DJ 五个页签。菜单/人物资产管理入口必须打开同一设置状态；切页、窗口关闭重开、缩放、长内容滚动均须验收。

| ID | Swift 功能与源入口 | 首次审计差距 | 真实 App 验收动作 |
| --- | --- | --- | --- |
| S01 | `PresenceSettingsView.swift`：角色列表、预览、激活、内置不可删/外部删除、渲染器不可用原因 | 缺失 | 从菜单打开角色页，切换现有 VRM/PMX/Orb；查看实际人物与选中态一致；非破坏性取消删除确认 |
| S02 | 同文件 header：本地模型导入、本地动作导入、角色链接下载并安装/取消、进度与错误 | 缺失 | 用授权测试模型和动作导入并激活；无效链接给可读错误并可重试，取消不遗留忙态 |
| S03 | 同文件：动作分类、兼容/不兼容状态、选择、外部删除、不同角色各自记忆动作 | 缺失 | PMX/VRM 切换并播放兼容动作；不兼容不可误触；检查站立与椅子坐姿各自正确支撑，不把椅子坐姿悬空判成地面穿模 |
| S04 | 同文件：动作目录地址、刷新公开列表、下载安装、空列表/安装状态 | 缺失 | 刷新实际目录、安装一个动作、回到舞台使用；失败不破坏已装列表 |
| S05 | 同文件：Orb 颜色和流光强度 | 缺失 | 改颜色/强度，实际渲染立即变化，重开保留 |
| S06 | `MusicAccountsView.swift`/`MusicAccountsModel.swift`：网易云、QQ、Apple Music 连接/同步/断开；authorizing/connected/expired/denied/unavailable/disconnected 状态 | 缺失 | 已有账号只读显示，不重新授权或断开用户账号；授权测试账号真实同步后曲库更新；失败/不可用状态明确且不伪造成功 |
| S07 | `GMGNSettingsView.swift` 的 `SpaceSettingsView`：默认生活舱/最近 Marble 空间、无可用空间提示 | 缺失 | 改测试配置、关闭重启真实 App，进入选定空间；选项无内容时不能误选 |
| S08 | 同入口：Marble Key 已配置状态、替换保存、清除 | 缺失 | UI 不回显密钥；仅授权测试配置验证保存与读取状态，取消清除无变化；不读取/操作用户 Keychain |
| S09 | `PropGenerationSettingsSection.swift`：生成服务地址、保留现有密钥的替换输入、检测、保存、检测中/失败/成功 | 缺失 | 保存授权测试地址，检测真实服务；空替换输入不清已有密钥，失败保留地址草稿 |
| S10 | `GMGNKeyboardShortcuts.swift` 的 `GMGNShortcutSettingsView`：八类动作应用内/全局组合键录制、冲突提示、启用全局、系统媒体键、恢复默认 | 缺失 | 验证播放/上一首/下一首/音量±/语音/舞台/歌词；输入框编辑不误触播放快捷键；录制取消与冲突不覆盖旧值 |
| S11 | `AgentSettingsView.swift`：DJ 内核登录状态/登录/退出、允许 DJ 自动接管、相关配置输入 | 缺失 | 现有登录状态读回；不重登用户账号；允许开关真实影响业务，失败不冒充成功 |
| S12 | 同文件：DJ 人格与偏好、居民人格分别编辑保存 | 缺失 | 两份文本独立保存，重开后一致；实际会话使用对应人格，不混入另一个角色 |
| S13 | 同文件：聊天后端下拉、后端可用状态、空间/Live Cam 共用同一 Agent | 缺失 | 选择现有 DSH，不注入 API key；正常舞台发送后在小窗继续同会话，回复/取消作用于当前 App 会话 |
| S14 | 同文件：居民自主安排活动开关、每小时后台轮数限制（含 0） | 缺失 | 保存/重开保留；后台状态变化不强制切小窗，不抢输入焦点；停止确实停止当前任务 |
| S15 | `RustSpeechConfigurationFields(purpose: "tts")`：百炼/ElevenLabs/Fish provider 下拉、模型下拉、capabilities 加载/错误/旧模型失效 | 缺失 | 逐 provider 切换显示 Rust 提供模型，不能手填模型替代下拉；Fish 包含实际 capabilities 支持选项；旧模型明确要求重选，不静默换服务 |
| S16 | 同入口：每 provider 独立密钥保存、声音下拉/刷新/加载中/错误、当前自定义声音保留 | 缺失 | 切换 provider 不复用另一家 key/音色；实际目录显示名称及 ID，刷新失败可恢复；不在日志/界面明文输出 key |
| S17 | 同入口：自定义音色展开填写 Voice ID/Fish Reference ID，百炼 VC 模型匹配说明 | 缺失 | 填已有授权音色 ID，保存重开仍保留，真实 Rust 合成使用此 ID；无效 ID 保留文字并报错 |
| S18 | 同入口：试听/停止试听、自动朗读 Agent 回复、保存配置/已保存反馈 | 缺失 | 正式 App → Rust TTS → 输出实际可听声音；停止立即生效，改模型/声音停止旧试听；自动朗读关闭不出声 |
| S19 | `RustSpeechConfigurationFields(purpose: "asr")`：百炼/ElevenLabs provider、模型、保存、录音状态和取消录音 | 缺失，真人麦克风验收仍遵循用户暂缓指令 | 先验证控件、配置、取消状态；只有用户恢复授权后做按住/松开实际转写，不加入 LiveKit 或双向通话 |

## 舞台与生活空间

入口：`VisualEngine/StageWindowController.swift`、`VisualEngine/StageOverlayView.swift`、`App/GMGNRadioApp.swift`。原控制器持有真实业务依赖，迁移必须对接这些实例，不能另外创建只会聊天的服务替代应用状态。

| ID | Swift 入口与功能 | 首次审计差距 | 真实 App 验收动作 |
| --- | --- | --- | --- |
| W01 | `StageResidentComposer`：文字草稿、发送/停止、复制最新回复、回复状态、居民头顶状态/语音错误 | 文字控件部分存在；正式业务连接待验 | 中文输入法组合期间 Enter 不提前发送；多行/长回复滚动、忙时禁用、错误保留草稿、停止后立即重发、旧回复不能覆盖新请求 |
| W02 | 同入口：选图、直接粘贴图、预览/移除、最多四张、准备中/无文字附件提交、提交失败恢复附件 | 当前图片按钮禁用 | 正式 App 上传授权测试图至实际 DSH，同会话识别；移除与重试不丢草稿，不接受禁用占位按钮为迁移完成 |
| W03 | 同入口：按住说话/松开发送、录音/识别/朗读中状态、开麦停止旧朗读、停止说话/停止任务不同动作 | 缺失 | 控件状态先验；实际麦克风暂缓。实际 TTS 必须正式 App 朗读，停止任务和停止朗读各自验证 |
| W04 | `WishMachineTaskStatusView`：生成排队/准备/失败/完成、自动继续、恢复自主行动、连接状态 | 缺失 | 实际生成提交到实际服务，状态同步，失败可恢复；不能用静态 fixture 生成结果 |
| W05 | `ResidentPropEditorView.swift`：我的物件/房间里、所有权分组/结束折叠、领取/让居民去取/生成重试/入库重试 | 缺失 | 真实生成→入库→领取→目录更新与世界状态读回，退出重开仍一致；只读取成功返回不算摆放成功 |
| W06 | 同入口：选物件、指针携带/射线选位置、左键放下、右键45°、Esc放回、地面/墙面吸附图例与拒绝原因 | 缺失 | 实际空间放置、旋转、取消，UI 叠层之外场景可接收鼠标；UI 内点击不能穿透为场景摆放 |
| W07 | 同入口：人物手持挂点分段选择、拿着看/放回/收回、前后上下2cm、左右15°、尺寸拖动松手提交、范围拒绝、撤销 | 缺失 | 手持姿态真实可见；更换挂点、微调、缩放、撤销后读回，重启恢复；手持与指针携带不混同 |
| W08 | 同入口：永久删除确认、忙时禁用、收场后删除、取消 | 缺失 | 只用授权测试资产，先取消确认确保不删除；真实删除后目录/场景一致。不得删用户资产 |
| W09 | `StageVisualPickerView`：播放器/空间/动作/活动四分区，空间模式播放器效果说明 | 缺失 | 每个分区完整可达，缩放滚动无遮挡；切模式保留设置，选中态和实际渲染一致 |
| W10 | 同入口：公开/生成 Marble 世界选择、加载/生成消息、人物XYZ持久化、位置重置、镜头复位、WASD镜头 | 缺失 | 切实际世界、调整角色、重启恢复；鼠标缩放/镜头围绕电视性能取实际帧率与操作录像，不用静态截图判断流畅 |
| W11 | 同入口：兼容动作、刷新、管理角色与动作入口；当前空间活动运行/停止/不可用原因 | 缺失 | 触发活动实际走到目标并动作，不穿地；停止恢复正确姿态；打开管理跳到同一设置角色页 |
| W12 | `WorldScreenOverlayController.swift`/`Screen/NativeMedia/NativeLinkPlayer.swift`：电视链接播放、操作模式、Esc退出、画面/声音 | 缺少操作 UI 对齐 | 用真实链接验证原生播放画面与真实输出音频；镜头靠近/远离，进入/退出操作模式；不重新引入 WKWebView 播放作为默认实现 |
| W13 | `Presence/ResidentSystemInboxUI.swift` 与 `ResidentSystemInbox`：邮件徽标、未读数、列表时间/状态、详情、双击/打开/Return、已读持久化 | 缺失 | 单击选中只看详情，不标已读；显式打开实际通知后核对未读减少，舞台/小窗同步，重启不反弹；长标题换行/列表滚动正常 |
| W14 | `StageWindowController` 底栏：播放/暂停、上一首/下一首、语音、舞台设置、通知、全屏 | 缺失 | 所有按钮影响真实业务并显示真实忙/可用状态；全屏退出后布局、焦点、SceneKit尺寸恢复 |

## 音乐播放器与视觉

| ID | Swift 功能与入口 | 首次审计差距 | 真实 App 验收动作 |
| --- | --- | --- | --- |
| M01 | `StageProgramRailView`：DJ节目/同步歌单列表、曲目列表、返回、当前与待切换后台编排状态 | 缺失 | 真实账号同步曲库进入列表；选歌单/曲目实际播放，当前标记随曲目变化，空列表正确引导 |
| M02 | `StageProgramRailView`/`AppDelegate`：曲目选择、上一首/下一首、播放暂停、音量、播放结束/失败状态 | 缺失 | 实际声音、时间与 UI 对齐；暂停无声、恢复连续，失败有可操作错误，系统媒体键相同行为 |
| M03 | `StageLyricsView` 与各 LyricsFrame：flowing/foldingVerse/cinematicSplit/orbit/posterRail/editorial/cloudSteps/chorusChat/pendulum/diorama/depth 等歌词视觉 | 缺失；须保持已有动态视觉 | 真实歌曲时间驱动歌词，高亮/换行/无歌词状态、切风格与缩放；2D GPUI覆盖不压住或替代原3D效果；实际录屏检查动画 |
| M04 | `StageVisualPickerView`：歌词风格、点云选择/参数、视频选择/亮度/模式、视频素材库菜单、当前歌曲绑定/解绑、移出素材库 | 缺失 | 每个选项真实生效；绑定歌曲后下一次播放出现播放提示，取消提示与亮度值持久化正确；删除仅测试素材 |
| M05 | `StageBoundVideoPromptView`：歌曲绑定视频提示播放/关闭；曲目视频入口 | 缺失 | 正式播放器播放绑定视频并验证图像/声音/恢复音乐状态，关闭提示不误开始视频 |

## 小窗、系统菜单与排版

| ID | Swift 功能与入口 | 首次审计差距 | 真实 App 验收动作 |
| --- | --- | --- | --- |
| L01 | `DesktopPresence/LiveCamPanel.swift`：224×336小窗、人物视图、进入空间/播放器/聊天/通知/设置入口 | 独立compact文字组件不等于正式小窗 | 正式小窗真实人物可见，所有入口可点击；普通/小窗/全屏连续切换，业务会话及播放不重建、不丢失 |
| L02 | 同入口/`LiveCamWindowController`：聊天显隐、点击回复展开输入、关闭回复气泡、焦点、附件、发送/停止、按住说话 | 部分compact文字控件，其他缺失 | 点击聊天获取焦点、键盘输入不中断；长回复滚动不遮控件，关闭/恢复保留草稿与状态，附件正确适配小窗 |
| L03 | 同入口：播放器菜单与上一首/播放暂停/下一首，后台任务/通知状态 | 缺失 | 小窗控制影响同一播放器；后台生成/活动/回复不得自动顶出小窗或改变当前窗口形态 |
| L04 | `App/GMGNRadioApp.swift`：菜单栏显示Live Cam、进入空间、装修/停止装修、打开播放器、设置、退出；显式窗口触发策略 | 缺失 | 所有实际菜单入口保留；启动/活动不强制切小窗；退出只回收自有窗口与服务；设置重复打开复用正确窗口 |
| L05 | `LiveCamWindowController`：遮挡/隐藏/恢复/关闭、呈现revision、渲染表面共享 | 待正式集成 | 反复隐藏/恢复/切窗，人物不会空白、不重复Agent请求；关闭时自有任务回收，应用不崩溃 |
| L06 | 所有面板：GPUI Kit统一主题、文本/字段/按钮/滚动/弹窗/选项可访问性 | 尚无全量布局 | 正常窗口与最小允许尺寸、小窗、Retina、全屏分别截图；中文长名称/错误/选项/音色ID不裁切；Tab/ShiftTab/Enter/Esc、中文IME、复制粘贴、菜单焦点恢复逐项操作 |
| L07 | Swift宿主与GPUI叠放：SceneKit input/resize、窗口拖动、透明区、弹窗覆盖与hit-test | 独立probe仅技术证据 | 真实 gmgn 上UI点击不穿透；场景空白区能旋转/缩放/摆放；弹窗抢焦点结束后回场景；窗口resize不拉伸3D或留下旧遮罩 |

## 证据登记与交付门槛

### 原布局恢复与 v12 实际检查（进行中）

原 Swift 对照 App 使用同一业务根，运行日志 `/tmp/gmgn-gpui-layout-swift-reference-runtime.log`；CUA 逐页查看角色、音乐、空间、快捷键与 DJ，确认原窗口 580×500、五段导航、各页标题和原分组位置。⌘, 能打开原设置。未更改账号、密钥或录音状态；对照 App 已正常退出。

v12 实际包 `tmp/gpui-product-app-v12/gmgn radio.app` 已通过完整构建，运行日志 `/tmp/gmgn-gpui-parity-v12-runtime.log`。真实船舱、2B、生成物件正常渲染，舞台恢复全窗，聊天点击后在原右下展开，通知打开真实独立 720×460 窗口并显示已有实际消息；单击选择可查看详情。本根该消息已经已读，因此本次不计“未读→已读持久化”通过。

本次真实失败：底栏所有 SVG 图标空白，⌘, 无响应，左上缺自主关闭卡；通知行的 Kit ListItem 内部容器将子项竖排，时间越出 44 高行。图标资源、设置快捷入口、任务卡已返工；通知行已改显式横排。组件状态测试 19 项退出 0（`/tmp/gmgn-gpui-parity-inbox-test.log`）；这些修复仍待新包实际复验，不把 v12 当作原布局已通过。

当前源代码已实现五页 Kit 设置、真实附件/PTT/通知桥与原舞台布局，以及四分区舞台设置组件。节目轨道和物件组件已连接真实原宿主接口、实时能量字段和彩色图例，相关实际业务仍待逐项验收；原 3D 曲目卡旋转尚未完整对齐。v16 小窗崩溃已在 v17 往返复验修复；最新 v18 实际失败为进入播放器丢失原 Metal 点云、显隐不一致及小窗自主按钮文字溢出，继续返工。ASR 实际麦克风仍按用户要求暂缓。

v13 完整包构建退出 0（`/tmp/gmgn-gpui-product-app-build-v13.log`），运行 `/tmp/gmgn-gpui-parity-v13-runtime.log`。CUA 实际确认底栏 SVG 全部显示、⌘, 打开 Kit 五页设置、右上正确显示回到播放器、左上出现自主关闭与恢复入口；这些 v12 故障已复验修复。未打开自主行动，避免测试自动消耗模型额度。

设置真实检查继续发现布局差异：页签 32 高而原为 24；角色/音乐标题被放进卡片，原在卡外；空间页面横行被改为纵排，快捷键列宽/行高与原不同。已发返工并据原源码恢复尺寸及组结构。角色原缩略图/Orb 渐变预览、链接导入原弹层仍待补，不能据五页可达称完整对齐。

舞台四区实际打开，空间菜单实际显示公开空间/生成场景并可 Esc 取消（未切世界）。物件目录显示原业务根真实 E2E 电视，点击后实际原编辑器进入选中状态、显示手持入口；关闭面板成功清理。Esc 未取消选择，判失败并返工。XYZ 改成中文标签及行距变化也不符合原布局，已返工。手持挂点原当前源码为 156 宽小号 segmented，与拿着看/收回在同一横行；v13 独立按钮和随后下拉返工均不符合当前原源码，已纠正为 Kit 分段控件。未点击领取、删除、撤销或移动现有资产。节目轨道可展开，本根实际无节目/歌单；不造曲目或 fixture，不将空目录显示计播放通过。

### v14 原布局实际复验与下一包修正

完整包构建退出 0，日志 `/tmp/gmgn-gpui-product-app-build-v14.log`；真实业务根不变，运行日志 `/tmp/gmgn-gpui-parity-v14-runtime.log`。CUA 确认角色 Orb 渐变预览、角色描述、卡外标题、空间横行与原挂点分段控件可见。物件选择后 Esc 实际退出选择，此前 v13 故障此路径复验通过，未移动或删除资产。通知行时间回到 44 高行内；详情为原消息纯文本，尝试输入未改变内容。此处消息已读，不计未读转已读持久化通过。

链接导入实际打开 Kit 弹窗，输入 `not-a-url` 后返回原宿主 HTTPS 校验提示，草稿保留、按钮可再次使用；取消按钮可关闭。Esc 未关闭弹窗、角色分类末项裁切、音乐卡高度超过原界面，均记录失败。最新源码已补显式弹窗 Esc、等宽页签和原音乐行密度，待 v15 实际复验。Stage 与设置外框尺寸分别按原窗口样式修正；通知与小窗不做统一减高。新窗口类型切换、真实命中区域和上述尺寸仍待新包验证。

节目和物件已连接原宿主真实接口、实时音频字段和彩色图例。节目轨道的原 3D 卡旋转尚未完整复刻；本业务根无节目和歌单，不以空目录显示代替播放验收。五页完整功能、附件、通知未读持久化、小窗切换和声音仍有待验项，当前不报告完整对齐。

### v15 窗口尺寸与操作复验

完整包 `/Users/ghostcorn/dev/gmgnradio/tmp/gpui-product-app-v15/gmgn radio.app` 构建退出 0，日志 `/tmp/gmgn-gpui-product-app-build-v15.log`，运行 `/tmp/gmgn-gpui-parity-v15-runtime.log`。实际截图舞台 2360×1520、设置 1160×1000（Retina），与原 1180×760、580×500 对齐；音乐三行卡约 181pt 高，原密度此视觉子项复验通过。底栏全屏切换及返回窗口可用。

动作分类末项仍裁切；导入弹窗输入框获得焦点后 Esc 仍不关闭，均继续失败。设置源码已再次修标签独立字号与窗口限定 keystroke 拦截，编译通过，待下一完整包。菜单“显示小窗”点击后仍原舞台，实际切换尚未达成，已交原生窗口代理排查。上述故障与尚未执行的业务操作均不写通过。

### v16 两项修复复验通过，小窗崩溃返工

v16 完整包构建退出 0，日志 `/tmp/gmgn-gpui-product-app-build-v16.log`；实际运行 `/tmp/gmgn-gpui-parity-v16-runtime.log`。设置动作五类文字全部可见；链接弹窗输入框获得焦点后 Esc 实际移除弹窗，日志 `GMGN_GPUI_SETTINGS_LINK_ESCAPE closed=true`，这两项此前失败现通过。

实际菜单“显示小窗”接受导航后崩溃，进程退出 134。日志明确 `cannot update gmgn_gpui_app::GMGNProductUI while it is already being updated`。小窗切换判失败，继续返工生命周期，不以导航 accepted 算完成。当前源代码和既有证据已提交推送 `57c6e32`；该提交不代表完整 UI 验收通过。

### v17 小窗往返不再崩溃，视觉仍需返工

v17 构建退出 0（`/tmp/gmgn-gpui-product-app-build-v17.log`），运行 `/tmp/gmgn-gpui-parity-v17-runtime.log`。实际菜单切小窗成功，448×672 Retina、真实 2B 继续渲染，六个 Kit 入口可达；点击空间恢复 2360×1520 舞台、同世界人物与物件，生命周期崩溃此往返路径复验修复。仍不能算小窗完整通过：背景显示白色、白色图标对比不足，提示黑框遮人物且文本裁切，已继续返工。人物朝向与灯光需原小窗对照，未作完成结论。

### v17 真实文字、图片与复制流程

结束装修（Esc 实际关闭）后，正式 Kit 输入中文，实际收到“界面对齐测试正常”。同一会话通过原 NSOpenPanel 选取已人工核对的咖啡机测试图 `tmp/generated-props/espresso-machine-v1/reference.png`，Kit 显示真实缩略图及移除按钮。提交后原 DSH 返回“意式浓缩咖啡机”；日志 request_id=1、2 均 accepted→reply。点击复制最新回复，再粘贴到未发送草稿，AX 与回复一致，随后清除草稿。此处 W01/W02 的文字、选图、提交识别、复制子路径通过；多图上限、直接图片粘贴、拖入、取消/失败恢复仍单列，W02 不整体通过。

聊天历史手动滚动实际可读最新回复。原 StageResidentComposer 238–287 为固定 132 高 ScrollView，没有自动末尾逻辑，因此不为本次对齐新增自动滚动行为。当前测试根未配置语音凭据，实际语音缺配置提示不影响文字；TTS 本轮未通过，ASR 实际录音仍暂停。

只读复查还确认 M03/M05 原歌词视觉、DJ cue、绑定视频提示留在隐藏 Swift overlay，L03 小窗播放菜单、L02 关闭回复气泡缺少对应入口。已分配原宿主真实状态投影与 Kit 实现，不以保留 SceneKit 认定这些 2D UI 已迁移。

### 原小窗和播放器对照，以及 v18 实际失败

主代理实际运行原完整 Swift App 同一业务根（未与 GPUI 同时运行），日志 `/tmp/gmgn-gpui-original-compact-reference.log`。原小窗单窗截图也显示白色 matte 与同一人物朝向/灯光，因此不据 v17 白截图认定原生透明合成故障；不修改原 Scene 背景。原六个按钮有深灰圆底/白边，播放菜单真实包含暂无节目、上一首、播放、下一首、进入播放器，前三实际不可用。

v18 完整包构建成功，日志 `/tmp/gmgn-gpui-product-app-build-v18.log`；运行 `/tmp/gmgn-gpui-parity-v18-runtime.log`，真实圆按钮对比恢复、原五项音乐菜单出现，点击进入播放器新窗口成功。但 viewport 持续白空、原自主状态仍显示、聊天和装修未按原播放器状态禁用；小窗自主按钮文字还溢出原边界，均失败。此包未完成接线的 bitmap 拖拽不可计通过。

随后原 Swift 同根 Stage→播放器实际显示原 Metal 点云黑背景，自主状态隐藏、聊天和装修禁用（`/tmp/gmgn-gpui-original-player-reference.log`）。源码定位为 GPUI 未搬原 StageContentView 私有 MetalStageView；共享 MarbleSpatialView 挂载成功不能代表播放器渲染面已挂载。已交原宿主代理搬同一 MetalStageView 并补真实显隐投影，不改引擎或新造渲染器。歌词绘图与绑定视频提示原状态投影已实现初版，仍存在排版、透视等明确差异，正在继续修复，未计视觉通过。

### v9 正式产品入口实际复验

实际运行 `tmp/gpui-product-app-v9/gmgn radio.app/Contents/MacOS/gmgn-gpui-app`，沿用下文真实业务验收根。Swift 宿主与产品包构建均成功；日志分别为 `/tmp/gmgn-gpui-product-host-build-v9.log`、`/tmp/gmgn-gpui-product-app-build-v9.log`。运行日志 `/tmp/gmgn-gpui-product-v9-runtime.log` 记录 `mounted=true compact=false`。CUA 实际看到 Kit 左栏与原生活舱、2B 人物、已有物件同窗显示；实际拖动镜头与滚轮缩放可用，属于 L07 部分通过，摆放、窗口缩放与跨窗恢复仍待验。

通过原设置显式选择 DSH 后，在正式 Kit 输入连续两轮：要求记住“白桦58”，再询问暗号。实际界面分别收到“已记住白桦58”和“白桦58”；运行日志 request_id=1、2 均为 accepted→reply。W01 文字发送与同会话续聊部分通过，附件、输入法、取消竞争仍单独验收。长回复实际进入有界历史，不能据此宣称整项完成。v8 实际 Cmd+Q 正常退出，仅该退出操作通过。

实际 request_id=4 在 accepted 后点击停止，日志记录 cancelled；立即重发 request_id=5 收到四字真实回复。取消与重发链路本轮通过，中文输入法仍待验。v9 Cmd+Q 正常退出，随后使用 `GMGN_GPUI_COMPACT=1` 启动同一 App 与存档，日志 `/tmp/gmgn-gpui-product-v9-compact-runtime.log` 显示 mounted=true，但 CUA 上半窗白色、人物不可见，L01 失败。小窗导航入口也缺失，不能因挂载成功算小窗通过，已发起返工。小窗 Kit 实际输入并收到“小窗连接正常”，日志 accepted→reply、界面文本一致；仅文字链路通过，人物区域持续白色。

### v10 Kit 设置页与小窗修复

运行 `tmp/gpui-product-app-v10/gmgn radio.app`，日志 `/tmp/gmgn-gpui-product-v10-runtime.log`。正式 Kit Agent／回复语音窗口实际显示原居民人格、DJ 人格、DSH 后端、开关与后台预算，以及 Rust 返回的语音服务与模型。CUA 在预算菜单选择 0 并保存，语音 provider 选择 Fish，模型菜单实际包含免费开发者档、S2.1 Pro 付费、S2 Pro 付费；选择免费档保存，界面反馈“已保存”。退出重启，同一真实设置仍为预算 0、Fish 免费档，保存／重启读取部分通过。

此根未配置 Fish 凭据，声音目录与实际试听尚未通过，不借用用户 Keychain。原凭据仍由原偏好／环境保存，跨桥只传是否配置。GPUI 凭据新输入尚未实现，S16 未完成；ASR 配置仍在原页，实际麦克风验收仍暂停。人格多行编辑框实际高度不足，已发起布局返工，不将 rows 配置或构建成功算排版通过。

v11 固定两个人格框高度并禁止父布局收缩。实际运行 `tmp/gpui-product-app-v11/gmgn radio.app`，日志 `/tmp/gmgn-gpui-product-v11-runtime.log`；CUA 看到原人格多行完整显示、DJ 长文区域可显示多行。实际添加新行“验收草稿”，AX 显示新行；Cmd+Z 恢复原文，未保存该草稿。此前裁切故障此路径复验通过，长文内部滚动、中文 IME 和所有窗口尺寸仍分别待验。

小窗仍为 224×336，设置使用独立正常尺寸窗口。`GMGN_STAGE=1` 启动原舞台会抢共享渲染面，产品 bootstrap 已取消原自动窗口呈现；原空间异步更新不得抢 GPUI owner，显式打开原空间时才释放并接回。修复宿主构建 `/tmp/gmgn-gpui-product-host-settings-ownership-build.log` 成功；v10 带相同启动参数复验，真实人物出现（`/tmp/gmgn-gpui-product-v10-compact-runtime.log`），小窗设置入口实际可用，并读取上述重启设置。人物朝向、灯光、聊天显隐／原气泡、其余小窗入口仍待对齐，L01 不整体标通过。

其余设置仍是原 Swift 页面；导航可达不计 S01–S19 整体 GPUI 迁移完成。图片按钮仍禁用，W02 未完成。11 项组件状态、3 项正式宿主协议测试通过；与本段真实界面证据分别记账。

### 原 Swift 主应用运行基准

主代理本轮实际执行 `tools/e2e-app-build.sh --configuration Release`，构建与 helpers 校验完成，日志 `/tmp/gmgn-gpui-product-baseline-build.log`。启动完整 `tmp/e2e-app-build/DerivedData/Build/Products/Release/gmgn radio.app`，复用既有真实业务验收根 `/private/tmp/gmgn-rust-core-final-business-20261004`，保留已有 PMX 人物、动作、生成物件与世界存档；未启动或覆盖装机版。运行日志 `/tmp/gmgn-gpui-swift-reference-runtime.log`。

CUA 实际看到生活舱、2B 人物与已有物件。展开聊天可见原文字输入、添加图片、按住说话、发送按钮和既有状态提示；打开舞台设置可见播放器/空间/角色/活动四区、公开空间菜单、人物 XYZ 位置、重置、镜头复位。此为原界面的运行对照证据，不计 GPUI 通过；GPUI 必须对齐这些真实入口和状态。

原聊天输入实际提交“只回复‘主应用连接正常’，不调用工具、不生成或移动物件”，收到居民真实回复“主应用连接正常”，历史与复制回复按钮出现、忙态结束。原设置在此隔离根未配置语音服务，界面显示“请先在语音设置中填写服务密钥；文字回复不受影响。”此为语音配置提示，不代表 DSH 需要 API key，不计 TTS 通过；不得将两种认证混用。

### 正式 GPUI 首轮失败与返工

`tmp/gpui-product-app-v4/gmgn radio.app` 实际启动同一真实业务根；日志 `/tmp/gmgn-gpui-product-v4-runtime.log` 明确 `mounted=false`，CUA 右侧白屏。根因是窗口构造回调中原生视图尚未完成挂载；移至首个已显示窗口 tick 后执行。左栏导航与长状态挤占空间，返工为有界滚动与固定底部聊天输入。Cmd+Q 未退出，补标准菜单与快捷键；首轮经原 E2E quit 控制面正常退出，不能记为快捷键通过。

GPUI 导航实际打开原完整 Agent/语音设置，确认原五页仍可达；这些页面仍是 Swift，不能标为 GPUI 迁移完成。该测试根原后端为 Codex，本轮通过原设置下拉显式选择 DSH，仅改变此测试根偏好，不指定 key。声音/模型列表报加载失败时发现该根仍运行凌晨旧 taskd（PID81044）；退出测试 App 后仅对已核实绑定此测试根的旧 helper 发 TERM，保留存档与全部数据，以便新构建启动当前 helper 后复验。未触碰装机版 helper 或生产数据。

每项状态只能为：缺失、已实现待验、真实 App 通过、真实 App 失败、环境阻断。需记录：对应 source commit、运行的实际 App 路径/PID、UI入口及操作、截图/录像、必要业务读回、失败与修复复验。复用用户实际 gmgn 业务实例；如保护数据必须隔离存储，明确记录隔离内容，仍运行正式主应用完整启动链，不新建独立业务宿主充当验收。

所有入口对齐、所有可执行用例通过之前，不报告“全部UI迁移完成”。ASR实际录音暂缓须单列，环境阻断不可写通过。未实现入口不得仅靠禁用按钮/占位文案算对齐。源代码、计划与有效证据索引提交推送；凭据、用户运行数据、构建产物不提交。

### v19 原播放器恢复与真实 Fish 试听

源码 `99e0ffb88c9b603d317fcc6ff8bed96592548b38` 已提交推送，远端现有分支 SHA 核对一致。完整包 `tmp/gpui-product-app-v19/gmgn radio.app`，PID 76100，继续同一真实业务根；构建日志 `/tmp/gmgn-gpui-product-app-build-v19.log`、运行日志 `/tmp/gmgn-gpui-parity-v19-runtime.log`。CUA 小窗圆按钮与自主活动文本无此前溢出；实际菜单进入播放器后，原独立 MetalStageView 点云动画可见，自主状态隐藏，聊天/摆放禁用与原 Swift 条件一致。此前 v18 持续白色播放器故障在此路径复验通过，歌词逐模式及所有播放器功能仍待验。

真实 DJ 设置滚动到回复语音，刷新 Fish Audio 目录后，下拉框实际显示服务返回的音色列表，选择 `Energetic Male`，模型保持 `S2.1 Pro · 免费开发者档`。点击“试听声音”后变为“停止试听”，完成后恢复“试听声音”。复用已授权环境凭据，未输入、输出或保存新密钥，未读取 Keychain。主代理同时执行现有 CoreAudio 采样工具 `--pid 76100 --seconds 20 --jsonl`，仅此测试进程输出；退出码 0，观察到播放前零样本、试听期间连续非零样本（峰值 0.38449186086654663）、结束后恢复零样本。因此真实 GPUI 设置→原 Swift 宿主→Rust Fish 请求→App 实际输出声音的试听路径通过，不能扩展为所有 provider、自动朗读或全部语音验收完成。ASR 麦克风仍未测试。

尚需真实验证：图片粘贴与位图拖入、中文输入法、歌词全部模式的排版/动画、各设置功能与重启、各窗口缩放/切换、通知及原世界操作。保持原布局，不以组件实现或测试通过替代完整 App 验收。

### v19 真实位图粘贴与拒绝恢复

主代理用原生 Preview 打开同一已授权咖啡机测试 PNG，Cmd+A/C 复制真实图像，在 Kit 聊天输入 Cmd+V；界面出现真实咖啡机缩略图及 `paste-6EA38779-72EB-4E2E-BB62-341E817E5463.png` 移除按钮。提交时测试根仍在原装修状态，request_id=1–3 的原业务拒绝为“请先结束摆放，再发送给居民；输入内容会保留。”文字和图片实际保留。仅关闭聊天未结束装修；实际打开装修再 Esc 后结束原装修，重新打开聊天，保留的同一草稿和图片仍在。request_id=4 accepted→reply，界面实际回复“意式半自动咖啡机（家用浓缩咖啡机）。”，成功后文字与附件清空。真实位图粘贴→原 AttachmentStore→真实 DSH 识别及业务拒绝恢复子路径通过；位图拖入、多图上限及其他失败仍待验。

发现拒绝状态下聊天底部错误文案溢出容器，已交给 main.rs 负责代理按原 Swift 有界布局修复，不能改原历史高度或新增自动跟随。成功状态历史实际显示用户与居民文本，先前空白不证明历史丢失。自动朗读本轮报语音请求失败，尚未将刚试听音色保存为原配置；先核对保存/试听差异，再真实复验，不能借试听成功宣称自动朗读通过。

### v19 保存音色后实际自动朗读

CUA 使用原 Cmd+, 打开 Kit 设置→DJ，保存当前 Fish / Energetic Male / S2.1 Pro 免费模型，界面显示“已保存。”，空密钥替换字段未填，原凭据未变。关闭设置回到同一 DSH 会话，提交“只回复：语音界面对齐测试正常。不要调用工具。”，request_id=5 accepted→reply（11字符）。原 Swift 自动朗读读取已保存配置，与试听临时配置路径有明确区别；保存后语音错误提示实际消失。现有 PID 限定 CoreAudio 工具 `--pid 76100 --seconds 30 --jsonl` 退出0，`AUDIBLE`，219个非零buffer，peak=0.36439359188079834、RMS=0.016712411413447606；证据 `/tmp/gmgn-gpui-v19-auto-tts-audio.jsonl`。本次正式 Kit 配置保存→DSH真实回复→原Swift调用Rust→App输出声音子路径通过。未测试麦克风、其他provider、停止朗读或重启后的自动朗读，仍不计全部语音完成。

### 下一完整包返工节点

聊天源码已修无记录时不显示原132pt历史区、移除重复外层padding、限制溢出并保留不同消息；App测试8/8通过，真实错误状态仍待新包复验。歌词字重/字距、spring与轮廓透视改动的UI测试37/38通过，唯一失败暴露CoreText字体名回落导致字重相同，正在修真实descriptor，不能删测试或计全部通过。

只读设置审计发现并下发三项原行为返工：`AgentSettingsView.swift:64,95`更换音色/模型应停止旧试听，当前Kit草稿更新未停止；`PropGenerationSettingsSection.swift:118`检测应比对地址草稿与保存值，当前Kit只检测旧地址；原字段编辑及离开页取消检测，Kit切页/关闭未取消。仅补试听/检测生命周期，不改布局或保存时机，不取消实际生成任务。新包须等待相关源码冻结后统一构建，逐项真实复验。

v19通知窗口实际打开已有“E2E端到端电视已摆放”消息，选择后详情及打开按钮出现；仅证明入口和详情可达。既有消息无未读标记，点击打开无可见变化，不能据此宣称未读→已读及重启持久化通过，仍待具备真实未读消息时验收。

v19真实聊天输入验证：粘贴第一行→Shift+Return→粘贴第二行，AX明确包含两行；Cmd+Z撤销第二行，第一行及换行保留。随后Cmd+A/Backspace清除未发送草稿；运行日志最后提交仍为request_id=5，没有此草稿的新请求。多行换行与撤销子路径通过，不能当中文IME组合验收。歌词字体descriptor修复后完整UI测试38/38通过；设置窄修仍在编译验证，统一完整包暂不构建，以免混入未冻结源码。

### v20 统一构建与真实验收起点

设置源码冻结后 Rust UI 39/39、Swift 宿主构建、检测生命周期回归8项均通过；聊天App测试8/8已通过。主代理统一完整包构建退出0，路径 `tmp/gpui-product-app-v20/gmgn radio.app`，日志 `/tmp/gmgn-gpui-product-app-build-v20.log`，helper manifest验证通过。v19仅测试App经Cmd+Q正常退出0；v20使用同一真实业务根及已授权环境凭据启动，PID80003，日志 `/tmp/gmgn-gpui-parity-v20-runtime.log`。不覆盖装机版、不改Keychain、不清数据、不测试麦克风。v20目前仅已启动，聊天错误状态与设置窄修尚未真实复验，不因构建或测试通过宣称完成。

歌词下一批精确差异已按原Swift源码定位：翻译样式每模式字号/字重/字距/行数不同，Diorama面板背景/边框/阴影需整体投影，Fold应恢复整组锚点/最小缩放，11模式转场不能共用统一scale与spring。现有轮廓透视/交叉淡出仍为部分实现，M03不整体通过。

### v20 真实聊天错误布局与检测地址复验

PID80003完整App实际打开聊天：无历史时132pt空白区域已消失。沿原测试根未结束装修状态，用真实剪贴板咖啡机位图及中文草稿提交，原业务拒绝“请先结束摆放”，草稿与缩略图保留，全部提示、输入、附件、发送与麦克风控件实际在聊天容器内，未再溢出至下方transport。此拒绝+一张附件子路径的布局复验通过；有历史、四张附件、长错误及缩窗仍单列待验。未发送测试草稿及附件随后实际清除。

CUA Cmd+,→空间→许愿机，将原8191地址草稿改8192，不保存，点检测；实际提示“请先保存服务配置，再检测连接。”。恢复原8191草稿再检测，真实服务返回“许愿机已就绪，可以生成道具。”。未保存地址草稿，不改变服务或凭据。未保存地址不得检测旧服务及真实原服务检测子路径通过；本次服务响应很快，未证明检测进行中取消或late-response屏蔽，仍待真实状态下验证，不用回归替代。

### v20 试听草稿变更停止行为

真实DJ页显示上轮保存的Energetic Male与S2.1 Pro免费模型。点击试听，按钮实际变“停止试听”；展开自定义音色后修改未保存ID，按钮恢复“试听声音”，随后恢复原ID。再次开始免费模型试听，打开模型菜单选择另一模型草稿，按钮从“停止试听”恢复“试听声音”；立即恢复原免费模型，不保存，不对付费模型发起试听或语音请求。真实自定义音色编辑及模型变更停止状态子路径通过。

仅测试PID80003输出的30秒CoreAudio采样 `/tmp/gmgn-gpui-v20-preview-stop-audio.jsonl` exit0、AUDIBLE、445个非零buffer、peak0.4847826361656189、RMS0.027615622792555975，确认正式试听确有App音频输出。采样没有记录点击时间标记，不能用总AUDIBLE或结束静音声称精确停止延迟；音色下拉变更、停止延迟、关设置停止仍需分别验证。未输入新凭据或测试麦克风。

### v20 快捷键捕获及 v21 构建

真实Kit快捷键页点播放/暂停应用内空格绑定，进入“请按快捷键”；Esc恢复空格。再次录制后切角色页再返回快捷键，仍为空格，离页取消子路径通过。重新进入捕获并获取新AX后按Ctrl+Option+J，按钮实际更新⌃⌥J；再录制并按空格，原空格绑定恢复。未使用恢复默认覆盖其他绑定、未触发麦克风，未修改全局开关。本次真实捕获/更新、Esc及离页取消通过；冲突交换、全局热键、实际播放动作及重启持久化仍单列待验。

歌词下一批源码冻结后完整UI测试45/45通过；按各模式修译文weight/tracking/wrap，Diorama整面板轮廓投影，Fold整组锚点/字距/minscale，分模式transition/trigger及沿原store时间推进旧场景，不新增业务时钟。主代理完整包 `tmp/gpui-product-app-v21/gmgn radio.app` 构建exit0，日志 `/tmp/gmgn-gpui-product-app-build-v21.log`。尚未启动v21，不计实际视觉通过；阴影/渐变投影和confession等原场景细节仍需补齐与真实11模式对照。

### v21 实际重启与音乐同步

源码38f0ec1完整包启动同一真实存档，PID83689，日志 `/tmp/gmgn-gpui-parity-v21-runtime.log`；v20仅测试App经Cmd+Q退出0，未触碰装机版。CUA真实设置读取原空格播放绑定、DSH、预算0、Fish Energetic Male及S2.1 Pro免费模型，前轮临时模型/音色草稿未污染保存值。角色仍实际选择2B PMX、原飞船及世界物件显示；仅这些读取路径通过，不能扩展为全部状态恢复。

Kit音乐页实际显示网易云/QQ未连接、Apple Music已连接；主代理点击已有Apple Music同步，真实反馈“音乐服务没有返回任何歌单，已保留原有本地歌单。”。未重新授权、断开或读取Keychain。此为空结果提示实际可用，不是曲库/播放成功。正在查原正常歌曲搜索/准备入口以进行真实歌词验收，不注入fixture或伪造歌词。M03真实11模式尚未通过。

### v21 角色恢复及设置多窗口失败

同一PID83689实际角色页选择Breathing Orb：当前角色标记更新，动作区域提示先选择VRM/PMX，世界2B消失；重新选择已有2B后，原人物位置和世界物件恢复。原PresencePackageStore对orb/live2D返回空3D avatar，AppDelegate另经OrbWindowController显示独立桌面光球，因此世界未出现光球不能判为迁移缺陷；独立桌面光球与小窗入口仍待核对，不计整项通过。生活动作分类实际显示BONES椅子坐姿和当前BONES自然待机，随后恢复全部分类；未触发坐姿或录音，不以分类可达代表动作验收。

实际已有设置页时再次Cmd+,，关闭顶层设置后仍出现同标题完整角色设置，再关闭才回主窗口。原Swift和GPUI源码意图均为单例，此实际多窗口记为失败，已交main.rs负责人最小修复与回归；不改原布局或允许重复窗口。原完整对齐目标持续有效，角色/动作、窗口、歌词、通知等尚未全通过。

### v22 单例及无角色引导复验

设置缓存按实际窗口inventory判断是否存活，延迟激活，避免dispatch借用时update失败被误判为已关闭。App测试9/9、check、Swift宿主build17通过。完整包v22构建exit0，日志`/tmp/gmgn-gpui-product-app-build-v22.log`。v21测试进程Cmd+Q退出0，v22 PID85622继续同一业务根，日志`/tmp/gmgn-gpui-parity-v22-runtime.log`。

CUA实际打开设置、再次Cmd+,、关闭一次，直接回到主窗口，没有残留第二设置；此复现路径通过，菜单重复及所有窗口生命周期仍待验。实际选择Orb后从应用菜单“显示小窗”，Kit显示原“还没有可显示的角色”与原指导文案，没有切到空Marble小窗；点击“打开角色设置”进入角色页，恢复原2B并关闭设置。此无人物检查与跳设置子路径通过；取消、初始compact无人物、独立Orb及原弹窗视觉仍未整体通过。弹窗期间CUA原生场景区域呈灰色，背景合成是否与原Swift一致须继续对照，不将功能入口通过扩大为视觉通过。误点主界面“窗口”实际进入全屏，尚未将此次操作算完整全屏验收。

### v22 渲染所有权故障定位与下一批返工

继续真实复验，恢复2B并关闭设置后场景持续白色，退出全屏仍白，点击回播放器报告“本次操作未完成，原状态保持不变”。日志明确PID85622在08:25:41由gpuiFullStage持有surface，08:27:00原StageWindowController.show把owner改为fullStage。此时主代理曾按Ctrl+Cmd+F尝试退出全屏；原GMGNKeyboardShortcuts定义该组合为toggleStage，因此触发旧Swift舞台抢占渲染面，证据支持入口路由故障，不能将本次白屏单独归因于Kit弹窗遮罩。已把GPUI启动模式下原showStage/showPlayer/显式showLiveCam及toggleStage接回同一产品导航；宿主build19通过，实际快捷键往返仍待新包复验。

另源码确认Kit modal/sheet未参与原生hit-region控制，有UI点击透场景风险。已按Kit真实WindowState栈设置全窗交互区域，关闭任一路径自动恢复，不新增独立modal标记，不改颜色或布局；App测试10/10、check通过，真实点击/场景复验仍待新包。

当前五页设置对原源码审计补齐：ASR换provider仅草稿、显式保存才持久化；新TTS key编辑取消试听/声音列表而保留能力请求，离页/关闭取消三者；下拉默认模型、旧模型失效、当前自定义声音与加载禁用；动作空分类及不兼容配色、链接错误图标、DJ说明和真实后端状态。settings测试4项与生产回调10断言、宿主final2构建通过；这些是回归/构建证据，未运行录音，也未把真实ASR或所有设置写通过。

节目轨道审计仍有确定遗漏：cos缩窄卡片改变排版，不能替代原绘制层3D投影；原右对齐、负间距、header重排入口、角落视频图标、滚动居中等位置/行为必须恢复。歌词confession及waiting/passed光效也有精确差异，正在按原参数修复。所有UI完整对齐仍未完成。

### v23/v24 实际导航、语音设置与窄布局复验

v23完整包构建exit0，PID89187同一业务根；v22测试App退出0。CUA按原Ctrl+Cmd+F从正常窗切224×336小窗，2B实际可见，再按同组合回1180×760生活空间，原人物与物件实际恢复，没有再出现旧舞台抢面导致白屏。日志`/tmp/gmgn-gpui-parity-v23-runtime.log`三次mount依次compact=false/true/false且成功；此复现路径通过，不扩为全部窗口/热键通过。原空戏剧动作分类实际显示“这个分类下暂无当前角色可用的动作。”，随后恢复全部分类。DJ原terminal图标、说明、真实DSH可用状态及默认模型标签实际可见。

实际ASR下拉从百炼改ElevenLabs草稿，模型显示Scribe v2 Realtime默认，不点保存。隔离UserDefaults域ai.gmgn.radio.e2e.c0105cb25be9a920的plist存在，单字段`speech.rust.asr.provider`仍不存在（原默认百炼），证明此实际草稿操作没有提前持久化provider；随后恢复百炼草稿。未读取整域、任何密钥或Keychain，未录音。实际Fish免费模型开始试听按钮变停止试听，立即切角色页，返回DJ按钮为试听声音。仅PID89187的20秒音频采样exit0、audible=true、410个非零buffer、peak0.5005599856376648，末窗口零样本，证据`/tmp/gmgn-gpui-v23-leave-preview-audio.jsonl`。未记录精确点击时间，不能据此报告停止延迟；实际离页状态恢复子路径通过。

v23发现居民人格说明挤出保存按钮，原HStack换行约束仍有差异；已窄修两个人格footer允许文字收缩换行、保存按钮不收缩，不改文本/窗口。v24完整包构建exit0，PID89871同一业务根；v23仅测试App退出0。日志`/tmp/gmgn-gpui-product-app-build-v24.log`与`/tmp/gmgn-gpui-parity-v24-runtime.log`。CUA在580×500及实际拖到540×440（Retina1080×880）看到居民说明两行、保存按钮完整留在卡内；此长说明布局复验通过，DJ footer及全部小尺寸页面仍待完整验收。

v24实际选择Orb→应用菜单显示小窗，Kit引导覆盖真实船舱且背景仍可见；取消后原场景恢复无白屏。重开角色设置恢复2B，关闭后人物与世界继续实际可见。这证明此前白屏修复及此模态取消/角色恢复子路径通过，尚未用正在携带资产的场景证明所有模态点击不穿透，相关命中控制仍需业务验收。设置重开恢复原580×500窗口。

本批歌词confession按原整体投影/实际行高/斜体/分段参数及glyph phase补齐；节目恒294×76/306×74、右对齐负间距、header重排、角落视频与实际当前曲目居中已实现。完整UI50测试通过的前轮证据不等于真实歌词和曲目视觉；真3D卡投影、渐隐/层级/吸附、歌词seek退出及投影前滤镜、真实歌曲11模式、其余全部业务验收仍未完成。继续保持完整目标，不能报告所有UI对齐完成。

本批最终源代码复验：gpui-ui完整50测试通过、gpui-app完整10测试通过，均exit0；日志分别为`/tmp/gmgn-gpui-v24-ui-tests.log`和`/tmp/gmgn-gpui-v24-app-tests.log`。`git diff --check`通过。上述单测与真实App子路径证据分别记录，不替代尚未完成的完整布局和功能验收。ASR录音仍暂停。

### 原菜单与物件确认继续对齐

上一轮属于实际进展：源代码dcbd203a222f6a2f752a6c83380bb7e2d830efe0已推送并远端读回一致，工作区干净。继续在v24/PID89871真实App打开装修→现有E2E端到端电视→删除确认，只点击取消；资产行与世界均保留。选中该资产后出现挂点/尺寸等原业务控件，按Esc后选中控件消失，恢复原摆放，未放置、修改尺寸或删除。实际确认当前为内嵌红块，与原Swift confirmationDialog有布局差异，已分配props.rs改用Kit真实弹窗；此项不能计完整对齐。

源代码核对原StageDecorationEntryAction要求已装修时只关闭、不重新呈现空间；ProductHost原无条件navigate已修为复用原helper，并恢复原显示Live Cam文案和设置/退出前分隔线。原helper19checks与GPUI接线合同测试exit0，宿主build20 exit0，日志`/tmp/gmgn-gpui-decoration-menu-test.log`、`/tmp/gmgn-gpui-menu-build20.log`；新包实际菜单复验尚待执行。节目滚动/3D与歌词退出生命周期仍继续返工，未扩大完成声明。

v25完整包构建exit0，日志`/tmp/gmgn-gpui-product-app-build-v25.log`；实际启动路径`tmp/gpui-product-app-v25/gmgn radio.app`、PID92957，同一业务数据根，日志`/tmp/gmgn-gpui-parity-v25-runtime.log`。只退出v24测试包，不碰安装版。CUA实际打开摆放，物件两格标签已为segmented；删除弹窗独立显示真实资产名、原不可恢复说明、取消及危险确认，底下面板未再被红块撑长。实际Escape关闭，重开后点取消也关闭；同一资产行、原人物与世界继续可见。没有执行永久删除。此取消/布局子路径通过，不代表全部摆放/手持或模态穿透验收通过。

节目补原列表4pt间距、保序绘制层级、真实ScrollHandle停滚边界吸附；歌词confession补退出段生命周期、倒退/重入/换scope清理，使用实际snapshot而非生产fixture。最终完整UI测试exit0，日志`/tmp/gmgn-gpui-v25-ui-tests.log`。真实节目目录为空，这些卡片/歌词视觉仍未业务验收。原速度限幅、真3D投影/磨砂与alpha渐隐、歌词其他模式细节仍欠；props行横排/状态色、分组头及滑块草稿读数仍欠。菜单新包实际状态项未操作，继续待验。下一批真实投影可走Rust整卡RGBA+inverse homography合成，但只是只读可行性结论，尚未实现或实测。

### v26 对齐继续实施

上一轮b4a82669321d6dbb3a6da18c0a239cc1599e66b8实际提交推送并核对远端，属于进展。生产props投影补原row.state.rawValue，避免根据中文状态猜颜色；宿主build21 exit0（`/tmp/gmgn-gpui-owner-state-host-build21.log`），原ownership投影回归exit0（`/tmp/gmgn-gpui-owner-state-projection.log`）。props补原名称/状态同排、状态色/icon/check、分组头及SliderState拖动草稿读数，原尺寸保持；新包实际视觉仍待验。

v25/PID92957实际设置Cmd+逗号可达。居民人格追加测试行保存、关闭设置重开，居民字段保留该行，DJ字段可见文本未被改写；随后删除测试行保存恢复原人格，AX读回一致。未改登录、后台开关、凭据或麦克风。隔离suite单字段resident.persona.v1未返回值，这次仅证实设置重开状态，不能当进程重启持久化证明；待后续独立验证原默认存储实际路径。

Rust整RGBA卡片投影模块已实现真实homography、trailing anchor/perspective.72、8%/92%alpha rail mask及inverse hit，直接image依赖复用已锁0.25.10无版本升级，模块9测试与App check exit0。节目生产接入仍在整合测试；不能把模块数学/纹理测试算真实卡片视觉或性能通过，磨砂、blur/shadow、scrollTransition与键盘/AX仍需核验。歌词contextual字体/对齐/宽度/渐变/滤镜按原参数继续补齐，未把源码实现计11模式验收。

v26完整包构建exit0、最终UI73测试exit0，日志`/tmp/gmgn-gpui-product-app-build-v26.log`、`/tmp/gmgn-gpui-v26-ui-tests.log`。实际路径`tmp/gpui-product-app-v26/gmgn radio.app`、PID96477，同一业务根。真实物件横排/颜色/选中check已可见，但AX缺行标签及尺寸最长边同行裁切，已追加窄修且待v27复验。CUA只选择/按Esc，无resize/删除。

v26从装修Esc取消预览后点击节目出现白屏，进程实际退出；runtime3293记录GPUI window.rs5250 panic“this method can only be called during paint”。独立日志/源码定位program.rs Render::render直接注册window.on_mouse_event，非Swift窗口抢面；已返工移到合法paint阶段。单测73通过未覆盖真实pane挂载，不能据此计节目可用。本轮真实发现失败，未报告完成。恢复原居民人格后单字段`ai.gmgn.radio.e2e/resident.persona.v1`读回原文字，原ResidentPreferences默认使用该测试包standard域，非语音用的每root suite；不读取整域或凭据。

v27完整包构建exit0（`/tmp/gmgn-gpui-product-app-build-v27.log`），实际路径`tmp/gpui-product-app-v27/gmgn radio.app`、PID97960，同一业务根（`/tmp/gmgn-gpui-parity-v27-runtime.log`）。CUA打开节目空列表、收起、再次打开，进程仍运行，第二次场景/人物与空提示同屏，没有再次abort；首个启动后的打开截图背景暂白，随后船舱恢复，未将首帧加载状态当永久白屏，也未证明启动全时无空白。props真实AX行名称恢复“E2E端到端电视，已摆放”，点击后包含已选中，横排check可见；实际滚动到尺寸四按钮，最长边0.40m与滑块右0.40m完整显示，原340宽未改。按Esc退出预览，未改变尺寸/摆放/删除。行键盘选择及拖动草稿尚未实际操作。

program直接render事件注册已改成熟div.capture_any_mouse_down（实际paint注册），新增GPUI test-support dev-only回归真的创建Root/Pane并执行draw，空目录及整卡两帧draw通过；完整75测试通过的worker结果与主代理最终日志另记。新test依赖只新增锁项，没有升级已有crate。实际完整节目曲目/歌词仍因无真实曲目未验收；磨砂、blur/shadow、scrollTransition、原动画/限幅、歌单真实封面仍欠。没有把正常打开空目录计完整播放视觉通过。

主代理最终复跑UI75/75、App10/10均exit0，日志`/tmp/gmgn-gpui-v27-ui-tests.log`、`/tmp/gmgn-gpui-v27-app-tests.log`；差异检查及敏感模式扫描通过。UI原布局完整对齐目标继续，真实完整业务与视觉验收未完成。

### v28 滚动效果、设置保存与快捷键继续对齐

上一轮56794d964b73f56a8f856ebd6511285cbf8ab13d已提交推送并核对远端。v27实际录制应用内播放快捷键后按Esc，原空格保留；系统消息现有电视通知详情点击后输入字母无变化，源码Textarea.readonly(true)。未创建新未读消息，不能计未读减少或重启恢复通过。

整卡投影补原内卡缩放/Y旋转/偏移与外层scrollTransition的顺序组合、真实视口phase、X轴与Y分量旋转、透明padding、整RGBA模糊和阴影；阴影不参与点击。新增缓存及线性大半径滤镜后，完整测试从初版77项30.10秒降至83项2.79秒，单独真实GPUI Window绘制回归3.36秒。两次整套case数不同，这些debug测试耗时不能当实际App帧率。原磨砂、歌单封面、动画曲线、速度限幅与真实曲目视觉仍待完成。

设置补成功revision回执才清除未被重新编辑的密钥草稿、规范服务地址回填；失败保留输入，不实际写测试凭据。动作目录Enter提交及id@version精确安装接线、原音色provider说明、配置状态图标/配色、保存/清除样式、DJ真实登录状态文字均补。纯内存生产save回调及8项health回调通过。快捷键生产回调补全局无modifier拒绝、持续录制及旧值保留，本地字母允许、Esc取消；独立回归通过。

主代理App10/10、保存回调、health回调和快捷键回调均exit0；宿主构建exit0，日志`/tmp/gmgn-gpui-v28-app-tests.log`、`/tmp/gmgn-gpui-v28-host-build.log`。v28完整包构建exit0（`/tmp/gmgn-gpui-product-app-build-v28.log`），路径`tmp/gpui-product-app-v28/gmgn radio.app`，PID1856，仍用同一真实业务根，runtime`/tmp/gmgn-gpui-parity-v28-runtime.log`。仅退出v27测试App，不碰安装版。

CUA实际进入580×500设置、快捷键页，点击全局播放组合后输入a，显示原“全局快捷键至少需要一个修饰键。”并继续录制；Esc后原⌥⌘P恢复，未保存新组合。随后DJ页真实状态“策划引擎未登录”与原说明可见，没有登录或录音。此路径通过；截图另揭示validation仍为灰check底栏，原Swift为橙色纯文案且与恢复默认同行，录制cyan视觉也需复核，不能计完整快捷键视觉通过。真实保存凭据、动作下载安装、节目滚动帧率等未在本包实际操作，目标继续。

### v29 快捷键样式、消息键盘与真实封面接线

上一轮5e1037c898e18167d0931d99dd55deb58f31b617已推送并核对远端。快捷键校验改为独立validationMessage字段，恢复默认同行橙色纯文字；移除原Swift没有的录制指导底栏，按钮恢复cyan与Menlo等宽文字，reset清校验。系统消息分别投影列表相对时间与详情完整日期；补上下键选择、边界限制及选中行自动滚入可见区，选择不发ACK；新窗初始聚焦原同一个pane，列表具原“系统消息列表”可访问名称。消息状态5项回归通过。

节目歌单真实artworkURL及provider展示名从原musicLibraryStore投影；成熟ImageAssetLoader异步加载，42×42中心scaledToFill裁切、12点圆角、合入整RGBA后投影，缓存包含图片identity。App补同版本成熟GPUI HTTP client，lock仅增加必要依赖，已有版本未升级。真实loopback HTTP请求回归通过，仅说明HTTP客户端可用，不能当正式封面网络显示验收。原磨砂/动画曲线/速度限幅继续欠缺。

主代理完整UI85/85 exit0（`/tmp/gmgn-gpui-v29-ui-tests.log`，4.15秒），worker独立最终完整85/85 exit0（`/tmp/gmgn-program-artwork-ui-tests.log`，4.66秒）；App11/11、快捷键生产回调、宿主构建均exit0。宿主日志`/tmp/gmgn-gpui-v29-final-host-build.log`。完整v29包构建exit0（`/tmp/gmgn-gpui-product-app-build-v29.log`）；仅退出v28测试App，启动`tmp/gpui-product-app-v29/gmgn radio.app` PID7632，同一真实业务数据根，runtime`/tmp/gmgn-gpui-parity-v29-runtime.log`。

CUA实际全局录制按钮呈青色等宽文字；录制激活后输入a、滚到表单底部，橙色“全局快捷键至少需要一个修饰键。”与恢复默认同行，无灰check底栏。Esc取消，不写新键位。打开系统消息列表显示“9小时前”，不点行直接Down后原电视消息选中，详情显示完整2026年10月4日1:23，打开按钮启用，AX读回list“系统消息列表”。这里只有一条已读通知，不能据此计多行滚动/未读减少/重启恢复通过。没有操作录音、凭据、登录或永久删除。

### v30/v31 视频库布局、分页与小窗回复

上一轮49cd35bd89178128050b7be3b19ef399b3927c15已提交推送并远端核对。原视频库的单菜单/逐素材子菜单替换当前常驻所有素材行，复用真实加载/歌曲绑定/解绑/危险移除命令；亮度恢复38宽百分比和可访问标签，不改变picker尺寸。节目补原标题数量、playlist loaded/total、空轨道无header、96顶部空态、Spinner及末4卡进入实际viewport自动分页；按真实playlistID/count/loading避免每帧重复加载。原速度限幅、动画曲线及磨砂仍欠，实际完整曲库为空不能报分页通过。

小窗原latestReply允许后台/自主回复不在用户历史；此前GPUI仅读历史导致漏显示，已接真实state.reply与宿主交付revision，展开原规则只追加与最后居民回复不同的独立文本，不造历史；同文字新交付可重新呈现。新增回归包括无历史后台回复、同回复去重、不同回复追加。完整UI88/88、App12/12和宿主构建exit0，日志`/tmp/gmgn-gpui-v30-ui-tests.log`、`/tmp/gmgn-gpui-v30-app-tests.log`、`/tmp/gmgn-gpui-v30-host-build.log`。

v30完整包exit0，实际PID12373，runtime`/tmp/gmgn-gpui-parity-v30-runtime.log`。CUA同一真实业务根在224×336小窗提交文字；原启动摆放状态拒绝且保留草稿。回空间打开装修按Esc后重试，request2 accepted→reply，真实DSH返回“小窗对齐验收。”，切小窗保持同一回复。截图揭示展开用户长文本撑出气泡并挤出关闭按钮，真实失败；补内容min_w(0)，原窗口/气泡宽高保持。

v31完整包exit0（`/tmp/gmgn-gpui-product-app-build-v31.log`），PID12710，同一数据根，runtime`/tmp/gmgn-gpui-parity-v31-runtime.log`。CUA先通过原装修面板Esc结束摆放，再小窗提交同一句真实请求，request1 accepted→reply；截图文字在气泡内换行，右侧关闭X和六圆入口完整可见。此用户回复换行子路径通过，不计自主后台交付实际通过。未注入语音密钥，本轮原语音提示缺凭据，声音未验收；未录音/登录/删除资产。最后源码复核去掉展开时绕过dismiss的条件，保留关闭语义；此最后窄修仍需新包真实关闭/恢复复验，不能把v31截图扩大为该行为通过。

### 歌词渲染后台背压阶段修复（GPU 迁移继续）

用户报告v39 Release歌词仍严重卡顿，真实采样 `/tmp/gmgn-gpui-v39-lyrics-stutter-sample.txt` 主线程1517样本，其中1317在StageLyricsPane.render、1299在SVG/resvg光栅，进程footprint6.1GB；不计性能通过，已恢复Swift UI使用。随后核实误开的Swift进程未带隔离根，已纠正至PID97010、原 `/private/tmp/gmgn-rust-core-final-business-20261004`，未导入/删除/重试入库用户资产。

用户明确继续修GPUI歌词。当前阶段Scene、CoreText、SVG解析/光栅移单工作线程；仅执行中1帧+最新待处理1帧+至多1完成结果，歌曲/模式/尺寸generation拒旧帧，同generation完成帧仍可发布防持续输入饿死。隐藏/释放关队列，等待旧worker结束才重建，旧纹理明确drop_image，main接小窗可见生命周期。完整UI102/102、App13/13+ABI1/1、cargo check及Release build均exit0；日志 `/tmp/gmgn-gpui-lyrics-async-app-tests.log`、`/tmp/gmgn-gpui-lyrics-async-release-build.log`。此阶段仍整屏CPU绘制，尚未真实歌曲性能/RSS验收，不宣称最终修好、不切换正在使用的Swift。

独立GPU歌词基础模块正在 `tools/gpui-lyrics-metal-probe` 实现被动透明CAMetalLayer、受限字形atlas和GPU形变/光效；现GPUI公共paint_glyph没有glyph blur/glow与透视，paint_surface仅YCbCr不透明，不能直接忠实代换全部11模式。基础模块与最终全部模式视觉/真实业务验收分开，不用探针代替端到端。

### 歌单与歌词严重卡顿：性能优先，未通过就恢复 Swift UI

用户实际登录网易云后已有50歌单，报告全界面、滚动和歌词卡住；暂停外观对齐，优先性能修复。v36 PID83263五秒采样 `/tmp/gmgn-gpui-v36-playlist-scroll-sample.txt`：主线程100ms tick/poll重复执行settings.snapshot→installedBackends→可执行目录扫描。已加5秒安装元信息缓存及显式刷新，不缓存凭据/连接，实际启动仍即时检查。另修登录重复全量歌单请求，真实账号轻量验证保留；排序/编码/写盘/读回移后台，每provider同步状态独立，失败保持连接，取消与迟到覆盖受控。

节目仅为可见卡片准备source/封面，50行真实Window首屏5行，远滚累计12；投影纯平移缓存复用，形变改变仍重算，保留原像素/渐隐/命中。完整UI最终99/99（worker）、主代理前次98/98、App13/13+ABI1/1均exit0。新包v37构建exit0并以相同真实根启动PID86476，空间画面恢复且实际50歌单入口可读；一次CUA入口操作仍用时13秒，不能称真实流畅或歌词通过。

关键构建缺口：原打包脚本Rust使用debug未优化、Swift宿主Debug。两脚本现改Release，bash语法检查通过；Release宿主session38387日志 `/tmp/gmgn-gpui-perf-release-host.log`、Rust session47694日志 `/tmp/gmgn-gpui-perf-release-rust.log` 已启动，尚未完成/启动Release包。下一步先读这两个实际会话结果，再打包新隔离版本、关闭仅测试实例并验证同50歌单滚动/实际歌词时间和界面响应。不能将debug缓存微秒数当FPS；真实修复不达标则用户授权恢复Swift UI，保留Rust核心、原播放/3D及测试数据。不录音、不重登、不触Keychain或已安装App。旧材质/系统图标partial dirty保留，未完整验证，不计对齐完成。

### v36 后续实际控件状态差异

上一轮空态修复及桥接契约已推送，远端当前 `fe17d0afde2e45b0da55842f4999d3a5b03290bd`。本轮在仍运行的 v36 隔离 App 中点击聊天，输入区出现，但 AX 聊天按钮仍为“聊天”，没有原 `StageResidentChatButton.setExpanded` 的“收起聊天”和展开值；确认交互状态尚未对齐。只读原源码另确认目的地缺12pt系统符号、底栏缺6+1×20+6分隔、自主横幅缺状态符号。正在修复原系统图标和被动 ultraThinMaterial；未将派发工作当完成，未录音、重新授权或删除素材。

### v36 修复原空态布局与同帧延迟卡材料

按原Swift真实条件修复空态：内容自然宽141.501945pt、height64/radius22，根右对齐，42+96顶部偏移，无header/ScrollView/contentMargins/railMask。native增加fade_fraction setter，0保留viewport矩形裁剪而不渐隐，轨道.08保留原fade；非法值拒绝，native结构测试通过。材质发布改为最高priority deferred prepaint，保证所有延迟卡真实矩阵收集后、任何前景paint前整批apply，修原tracks frame0生产问题。绑定视频26×26/r13材质使用卡matrix*T(259,8)，同帧失效恢复完整背景，布局/命中/键盘不变。UI93/93 exit0（worker session14866，6.18秒，新增多阶段draw不能与旧测试总时长直接比性能）。App13/13+ABI1/1 exit0（`/tmp/gmgn-gpui-v36-app-tests.log`），完整v36包exit0（`/tmp/gmgn-gpui-product-app-build-v36.log`）。

仅退出原隔离Swift测试App，v36 PID60270同一根，runtime`/tmp/gmgn-gpui-parity-v36-runtime.log`。真实CUA空间打开节目，AX仅“暂无节目”无额外header/refresh；截图约142×64空卡右边及纵向位置与原对照一致，旧306错误消失。仍有waveform形状/字体细节及material候选视觉差异，不能报完整材质一致。主窗口目的地恢复原“播放器/空间”文案、AX/tooltip、112×38/19圆角/原色边框；原系统图标尚未恢复，不能报该按钮全部像素对齐。非空曲库/圆视频按钮仍仅生产draw验证，未真实歌曲验收。

### 原 Swift 同根空态视觉对照发现布局失败

仅退出v35测试App后，启动原Swift隔离Release包`tmp/e2e-app-build/DerivedData/Build/Products/Release/gmgn radio.app` PID47128，仍用同一隔离真实业务根；原安装App未操作，runtime`/tmp/gmgn-swift-ui-parity-original-runtime.log`。CUA小窗进入空间并打开节目，原截图空态仅waveform与“暂无节目”、约142×64内容宽卡，无“歌单·0”header和刷新按钮；GPUI v35先前306×64大卡及额外header是实际布局失败，不能算空态对齐。当前Swift源码3627–3659确认programList空catalog直接emptyState.padding(top96)，4031–4046仅height64和horizontal20，无306宽约束。正在修准确内容宽与原显隐/外层排布，不缩小完成定义。

材质源码审计确认AppKit HUDWindow没有公开一对一ultraThin映射；候选随背后场景取色仅证明真实背景采样，未证明视觉同等。更忠实候选是复用原被动SwiftUI系统material primitive，GPUI继续负责全部控件、文字、布局与交互，仍需混合原场景实测。视频圆按钮material尚未完成。

### v35 同帧节目磨砂与小窗附件/聚焦

节目卡material接口从真实前景prepaint发布viewport和每卡source→window同源矩阵，native桥整批同帧apply；成功才用透明前景，失败同paint恢复完整不透明纹理，命中仍原圆角逆投影。main按当前原窗口挂载创建/关闭清理context，切profile重建，未改变原布局。真实空catalog卡306×64 radius22不旋转，未注入曲库。projective15/15及完整UI93/93 exit0（`/tmp/gmgn-gpui-v35-final-ui-tests.log`），App13/13及ABI1/1 exit0（`/tmp/gmgn-gpui-v35-final-app-tests.log`）；v35完整包exit0（`/tmp/gmgn-gpui-product-app-build-v35.log`），PID34475同隔离根，runtime`/tmp/gmgn-gpui-parity-v35-runtime.log`。CUA实际空间打开节目，空库“暂无节目”卡可见真实背后场景取色与模糊；尚无原Swift同根对照，HUDWindow候选不能称ultraThin材质完全一致，非空曲目滚动/视频圆按钮material仍欠。

小窗恢复原添加图片入口、54×46缩略图/移除、准备和错误；内部/外层按附件/准备/错误70→140同步。公开真实Kit输入focus，展开动作下一帧聚焦。CUA小窗点聊天后不点击输入框直接paste，AX读回“聚焦验收草稿”（首个同批paste早于下一帧，后续不点击输入框paste成功）。原文件选择器选仓库playing.png，实际缩略图和移除按钮出现，224×336不变、composer140；移除待发送附件后缩略图消失、高度70、草稿保留。未发送图片给居民，未删除源文件，未录音/操作密钥。附件准备/失败状态测试通过，但未制造真实provider错误，不扩大验收范围。

### v34 生命周期修复及危险菜单真实复验

GPUI编译配置下强持有原MetalStageView，普通Swift路径仍weak；原同实例未重建。生产attach/restore容器释放8次回归及宿主build22 exit0（`/tmp/gmgn-gpui-player-lifecycle-build22.log`）。v34完整包exit0（`/tmp/gmgn-gpui-product-app-build-v34.log`），PID23483同一隔离根。真实CUA full→compact→space→compact→player后原点阵播放器画面可见，每次runtime均PRODUCT_SURFACE mounted=true（`/tmp/gmgn-gpui-parity-v34-runtime.log`），本次先前重复切窗挂载失败子路径通过。素材保留一段，菜单AX实际读到“加载”和“移出素材库”；点击加载读回真实素材名已加载，未点击移除。截图点阵与视频叠加背景变化可见，但未独立核对视频连续帧，不报完整视频播放验收。

独立原生背景磨砂桥新增NSVisualEffectView withinWindow，场景与GPUI之间、被动hitTest、实际projective矩阵/viewport mask接口。native8项结构测试、严编译警告、App12/12及ABI1/1 exit0；桥尚未接入节目卡，HUDWindow候选未经原ultraThinMaterial实际视觉对照，不计磨砂通过。下一步接真实每卡几何和主窗生命周期，不改变原布局。

### 后续视频库实际复验与多次切窗失败

使用仓库已有 playing-10s.mov 经ffmpeg正常转码为隔离临时 `/tmp/gmgn-ui-parity-playing-10s.mp4`，通过真实系统文件选择器选中MPEG-4后导入。v32 AX读回真实素材名“gmgn-ui-parity-playing-10s，已加载”、视频亮度0.68；实际滚动到原底部，截图百分比68%，单素材胶囊、二级菜单取消加载及红色移出素材库均可见。取消加载后读回“未加载视频，1段”。未点击移除，未绑定歌曲（真实曲库为空）。危险item截图可见但AX欠标签，源码窄修已补MenuItem及原名称，菜单2测试/App构建通过，待新包AX复验。

真实失败：v32多次full→compact→space→compact→player后仅MOUNT_STRUCTURE accepted，无PRODUCT_SURFACE mounted；播放器持续白底“正在连接原应用场景…”，视频虽入库及状态更新，不能计视频画面通过。检查原StageContentView weak metalView发现旧GPUI container释放、新容器挂载之前可能丢失唯一播放器view实例；修复范围限定GPUI编译配置的生命周期，待构建及反复切窗验证。原背景磨砂独立真实NSVisualEffectView桥正在开发，尚未接入/验收，不计完成。

### v33 手势结算及 v32 小窗真实复验

v32真实CUA复验：切回空间后原房间与2B人物渲染可见，之前启动白底已恢复。小窗request1因遗留摆放状态拒绝并保留草稿；通过原装修面板打开后Esc结束摆放，回小窗重试request2 accepted→reply，实际回复“回复关闭验收。”。关闭回复气泡后AX关闭按钮消失且截图气泡隐藏；聊天入口收起再展开，同一回复及关闭按钮重新出现。原224×336布局、136高历史、六圆入口均保持，未录音或注入语音凭据，不能扩大为音频验收。

节目滚动修复：Started/Moved手指仍按住时不创建140ms结算timer，Ended后等待，无phase鼠标滚轮与后续动量Moved延后结算；Cancelled及route/active切换清手势状态。未发明固定单卡限制。worker完整UI90/90 exit0（session71400，1.71秒），含原Window draw回归及手势状态测试；主代理已审阅差异。原.always精确限制及真实非空曲库触控板表现仍待验收。v33测试包构建日志`/tmp/gmgn-gpui-product-app-build-v33.log`，未启动即不计该包运行通过。

### v32 原居中动画与减少动态效果

节目 active 切换恢复原 240ms easeOut(0,0,0.58,1) 居中动画；首次出现与路由进入仍立即居中。系统减少动态效果由原 NSWorkspace 设置投影，滚轮、新 active、路由切换取消旧任务，并以 generation 阻止旧 next-frame 回调覆盖新位置。小窗重新打开输入区清除已关闭回复 revision，符合原重新展开恢复回复行为，不改变窗口与气泡布局。

完整 UI89/89（`/tmp/gmgn-gpui-v32-ui-tests.log`，1.71秒）、App12/12（`/tmp/gmgn-gpui-v32-app-tests.log`）通过；宿主构建及 v32完整包均exit0，日志`/tmp/gmgn-gpui-v32-host-build.log`、`/tmp/gmgn-gpui-product-app-build-v32.log`。仅退出v31测试App，v32 PID14204使用同一隔离真实业务根，runtime`/tmp/gmgn-gpui-parity-v32-runtime.log`；CUA实际切回播放器后原点阵渲染可见。启动空间首次截图白底，尚未验证其恢复，不能报空间渲染通过。误点窗口入口进入全屏，尚未完成本轮小窗关闭/恢复视觉复验。

CUA实际从原系统文件选择器选择已有 playing-10s.mov 并导入，但素材库未出现新素材；该输入为MOV，原入口限定MP4，不能据此报视频导入成功，后续需有效MP4复验。未删除素材、录音、登录或改凭据。原滚动速度限幅、背景磨砂、真实非空节目切换动画与封面/分页继续待验收；完整UI对齐仍未完成。
### v41 GPU 歌词真实运行失败，继续返工

v44独立bundle id测试启动被现有E2ERuntime保护拒绝（exit78，`/tmp/gmgn-gpui-v44-runtime.log`）；随后CUA选择App自动启动了未带隔离变量的PID13410，已立即退出该测试进程。其屏幕及歌词观察全部排除验收证据，未清理或恢复生产数据。撤销自定义bundle id构建选项，后续沿用原专用测试bundle id，必须先验证进程存活、正确root与mounted，再绑定CUA，避免自动启动。

v43 Release 构建 exit0（`/tmp/gmgn-gpui-v43-build.log`），App14+ABI1、UI108测试exit0。真实PID10890同业务根启动，实际歌词与SceneKit共显，但用户确认莫奈不显示、换歌及切风格仍严重卡顿，明确不通过。真实日志 `/tmp/gmgn-gpui-v43-runtime.log` 新增证据：luminous过渡depth9超过native8，以及gpu_atlas_tile_exceeds_page；此前测试未覆盖真实长句及过渡组合。继续修native有界深度、atlas长句分块与提交热路径。

用户此前授权修不好回Swift UI，本轮已回同业务根Swift Release，PID11427（`/tmp/gmgn-swift-ui-fallback-v43-runtime.log`），环境只读核验root正确，CUA实际点击进入空间，AX读回360°舞台及完整原控件。未安装覆盖、未清数据，不把回退当GPUI修复完成；后续GPUI包由主代理先验后再供用户测试。

v42 Release 构建 exit0（`/tmp/gmgn-gpui-v42-build.log`），真实测试 PID9862，同业务根。最终 presentation 清屏透明度修补后，CUA 实际截图中歌词、SceneKit 空间及设置面板同时可见，黑底遮挡子问题通过。卡顿尚未通过：真实 70 batch 中文帧原生同步验证约155ms（包括GPU等待，不能当App帧率），继续优化滤镜全屏重复计算；v42进程采样证据 `/tmp/gmgn-gpui-v42-lag.sample.txt`。快照缓存 Release build26 exit0已合入该包，尚需采样比较。

Release 包构建 exit0：`/tmp/gmgn-gpui-v41-build.log`，实际测试 App PID8642，沿用 `/private/tmp/gmgn-rust-core-final-business-20261004`。App 14 项及 ABI 1 项测试通过，UI 104 项通过；这些不能替代实际运行验收。真实歌单播放时用户确认严重卡顿、歌词出现后底层空间被黑底遮挡，本轮明确不通过。

采样证据 `/tmp/gmgn-gpui-v41-lag.sample.txt` 显示原生 GPU render_frame 已在真实 App 调用，同时主线程 gmgnProductHostSnapshot 存在大量 Foundation JSON 序列化。原生模块确认最终 drawable renderpass 未显式设置透明 clearColor，默认 alpha=1；此前离屏测试未覆盖最终 presentation。正在分别修最终合成透明度、补真实中文 Scene presentation 验证，并检查快照热路径。未清数据、未覆盖安装 App。

# GPUI Kit / SceneKit 同窗口叠放验证

## 范围

用户要求先实际尝试 SceneKit 上的 GPUI 叠放，再决定 UI 迁移。不迁移设置窗口，不替换现有 SceneKit/Metal、人物或音乐播放器。原型独立于生产 App 与 Rust workspace，使用单独 bundle 和构建目录；不读取生产配置、凭据或用户资产。

## 必须验证的行为

- 同一窗口中持续渲染 SceneKit 动态画面，上方可见真实 GPUI Kit 控件；静态图片及两个并列窗口不能算通过。
- 点击 GPUI 按钮及弹窗，确认计数/状态变化，场景继续动画；弹窗不被原生场景挡住。
- 输入框正常输入，焦点不误触场景；退出输入后可继续操作场景。
- 空白处的场景拖动/缩放与控件区域的事件隔离。
- 窗口缩放、最小化恢复、关闭，检查布局、生命周期和异常。
- 记录实现是否依赖透明原生视图、私有 API、GPUI fork 或 GPU 共享纹理；逐帧 CPU 读回不可作为推荐方案。

## 当前产品集成边界

StageWindowController.swift 中多个 NSHostingView 覆盖层承担聊天、节目、摆放及反馈；输入链显式依赖 AppKit 子视图顺序及 hitTest。MarbleSpatialView.swift 的主渲染面是 MTKView，内部 SCNRenderer 与 Metal 组合；因此简单 SCNView 原型通过仍不能等同完整世界集成或性能验收。

## 结果

第一轮：GPUI Kit 0.7.0 / gpui-pre 0.3.7；项目默认 Rust 1.91 在 slice_as_array 依赖处构建失败，独立原型固定本机已有 Rust 1.95 后构建通过。生产工具链未改。

主代理通过 computer use 绑定 ai.gmgn.gpui-scenekit-probe（PID40209）进行真实窗口检查：GPUI 按钮计数从0变1，但整窗白色底挡住SceneKit，叠放失败；点击输入框后中文及ASCII输入未出现可见文本，输入未通过。SceneKit运行日志仍有递增帧计数（例如frames812至2488），但计数不能证明屏幕可见。运行日志 /tmp/gpui-scenekit-probe-runtime.log，构建 /tmp/gpui-scenekit-probe-build.log。正在修复根视图背景与原生焦点桥接；尚未开始产品 UI 迁移。

第二至四轮：透明Base Root实例覆盖主题背景后，真实窗口可见SceneKit旋转立方体、地面和上层GPUI Kit panel，按钮计数可增加。原生场景收到mouseDown/drag/scroll（v2日志pointer0→4）；切Raw路由后同样鼠标操作在v3日志pointer保持0，明确需要命中区域桥接。v3窗口缩放后场景和panel仍可见。输入局部黑字修复后v4 ASCII、回删和方向键可用，但Cmd-A及中文粘贴失败，AX控件树缺失，不能批准正式迁移。

同v4 artifact的纯Kit对照（GMGN_PROBE_NATIVE=0，PID51871）无SceneKit或重挂桥接，主代理CUA执行相同输入、Cmd-A、中文粘贴后，AX正确返回输入值“场景叠放测试”、六个字符及各按钮。证据为本线程原生界面截图/AX记录、/tmp/gpui-scenekit-probe-runtime-kit-control.log。此对照证明问题来自原型桥接路径，不能归因Kit缺键绑定；正在收敛桥接，不实现自制控件或快捷键替代。

## 第五轮真实窗口复验

v5保留原始AccessKit content-view wrapper和GPUIView父层级，将SCNView插入为下层兄弟视图。前四轮替换wrapper破坏了键盘等价事件和可访问性，纯Kit对照与修正版共同确认这个原因。输入、按钮和弹窗仍使用原生GPUI Kit组件，无自制快捷键替代。

主代理通过computer use操作PID53699，运行证据 `/tmp/gpui-scenekit-probe-runtime-v5.log` 与本线程截图/AX记录：

- 中文全选粘贴、回删通过；重新从场景返回输入框后AX值为“叠放验证完成”，字符数6，按钮计数2。
- Kit弹窗可见；弹窗期间向场景区域滚动，pointer保持0。Escape关闭弹窗后modal=0。
- 关闭弹窗后场景拖动/滚动产生mouseDown、drag、scroll，pointer由0增加到4；切Raw路由后重复操作保持4，恢复路由仍可操作控件。
- 原生窗口zoom后截图尺寸3840×1912，场景立方体与Kit面板均可见；恢复原尺寸仍正常。此截图不等于4K真实业务性能测试。
- 已执行最小化与Raise恢复，恢复后场景和中文输入可见；AX未暴露最小化状态，暂不作为严格生命周期通过证据。

结论：SCNView最小场景的同窗口叠放与关键交互可行。尚未覆盖生产MTKView/SCNRenderer合成、中文输入法组合态、复杂资产、人物、电视音频、真实场景帧耗时和跨平台运行。固定420逻辑像素命中边界与动态NSView子类仅供探针，不可直接用于正式界面。

最终增量构建 `/tmp/gpui-scenekit-probe-bundle-final.log` 成功，锁定依赖构建；fmt、bash语法、plist及签名验证通过。主代理再次实际输入“最终桥接测试”、点击按钮、打开弹窗并Escape退出；点击原生关闭按钮后session40212正常exit0，日志 `/tmp/gpui-scenekit-probe-runtime-final.log` 最后一条为 `PROBE_SCENE_CLOSED timerInvalidated=1 sceneStopped=1`。关闭后调用CUA getAXState会重新启动该独立bundle，因此再次关闭，不以重新打开的窗口误判关闭失败。

## 小窗与正式迁移门禁

用户补充明确要求保留小窗。当前产品LiveCamLayout.compactPortrait为224×336、圆角28；LiveCamPanel为透明floating窗口、跨Spaces、失焦不隐藏，只有聊天输入活跃时成为key窗口。大窗口成功不能代替该模式的布局、焦点和原生事件验收。

下一步先验证独立小窗以及生产MTKView/SCNRenderer接入。门禁通过后，直接使用GPUI Kit对应组件与现成主题迁移2D界面，保持现有3D渲染与音乐特效。不把probe固定命中边界或当前手写诊断面板主题搬入正式产品。

小窗第一轮实际运行PID68992，session54196，日志 `/tmp/gpui-scenekit-probe-compact-runtime.log`：截图为448×672 Retina，真实224×336小窗，圆角与Kit Dark主题可见；中文全选粘贴为“小窗通过”（4字符），发送本地计数1，场景拖动/滚动pointer0→4，复位并返回输入后为“场景返回输入”（6字符）。发送仅本地诊断，不算taskd消息验收。标题拖动已尝试但没有窗口位置证据，未判通过；默认启动激活/键盘窗口语义尚未与生产匹配，继续修复。

小窗焦点修正版：使用创建时即为nonactivating的GPUI PopUp/NSPanel，并设floating level、非聊天不可key、始终不可main，启动不activate。实际PID70754/session12337：启动日志key=0/main=0/appActive=0/canKey=0/canMain=0/nonactivating=1/level=3；点击聊天后中文全选粘贴“聊天焦点测试”，key=1/main=0；场景拖动/滚动pointer0→4后chatActive=0/key=0/main=0/appActive=0，截图窗口仍显示。再次点击聊天输入“再次聊天”成功。关闭按钮使进程exit0并记录释放。证据 `/tmp/gpui-scenekit-probe-compact-focus-runtime.log`。该策略仍是probe动态NSPanel子类适配，尚未实现完整小窗轮廓透传、标题位置读回或生产真实消息提交。

生产接入审计核对gpui-pre0.3.7源码：Application::run_embedded仍进入MacPlatform::run，后者配置GPUI专属NSApplication/委托并run；窗口创建API不提供接收现有NSWindow的入口。不得直接把Swift运行中的NSHostingView替换为GPUIView并视为受支持嵌入。当前接入方向为GPUI拥有App/窗口、Swift原渲染宿主以C ABI导出生产StageRenderSurfaceController及MarbleSpatialView；此桥接尚未实现/验收。原有SceneKit/Metal管线不改。

## 生产渲染宿主实现断点

独立 `apps/macos/gpui-render-host.yml`、`RenderHost/RenderHost.swift` 和 `tools/build-gpui-render-host.sh` 已开始实现。复用生产Swift源/包/Metal shader，排除应用@main，显式注入隔离defaults、缓存、人物/动作store，以本地LivingPod避免预热下载。未使用共享avatar runtime，不实例化ResidentChatState，不读Keychain或麦克风。

实际构建日志 `/tmp/gpui-render-host-build.log`、`build2.log`、`build3.log`、`build4.log` 均记录首次拆分暴露的编译问题：@main同文件中的ProductIdentity和菜单声明依赖，以及Swift6 raw-pointer跨MainActor闭包约束。继续修复，不能将这些失败记录为门禁通过。菜单编译支持副本未实例化，不构成生产业务迁移。新的GPUI接线只允许显式指定真实dylib、隔离数据根和defaults suite，加载失败不得回退SCNView并假报生产验证。

第六轮 `/tmp/gpui-render-host-build6.log` 实际BUILD SUCCEEDED/exit0；产物 `tmp/gpui-render-host/DerivedData/Build/Products/Debug/GPUIRenderHost.dylib`（无lib前缀）及 `default.metallib`。主代理nm核对8个C ABI导出齐全，otool确认全量编译源还链接LiveKit两个framework，仅供当前验证目标打包，并未启用实时通话。下一门禁为GPUI进程实际加载该库并显示生产LivingPod/真实MTKView，尚未通过。隔离人物store首轮为空，不算人物或小窗完整业务验证。

## 真实生产渲染面第一轮通过范围

主代理执行受限打包脚本；负向对compact-focus bundle执行被bundle ID门禁拒绝，未改其内容。正向production bundle实际打包与签名exit0，日志 `/tmp/gpui-render-host-package.log`。生产探针missing/partial/NATIVE0启动均exit78，日志 `/tmp/gpui-production-negative-{missing,partial,native0}.log`，不会以fixture代替真实宿主。

主代理正向运行PID75384/session99071，使用mktemp隔离数据根与唯一defaults suite，日志 `/tmp/gpui-production-render-runtime.log`：真实LivingPod房间可见（床、舱门、电视与灯），Kit Dark主题面板叠在同一窗口；AX中文全选粘贴“生产渲染测试”、字符6、按钮1，Kit弹窗可见并Escape关闭。zoom后截图3840×1912，真实drawable3840×1848，控件与房间可见。诊断surfaceClass=MarbleSpatialView/owner=fullStage/attached=true/hasWindow=true/loopActive=true，未替换渲染器或复制静态场景截图。

120样本的一次窗口采样：CPU encoding p95约1.98ms，GPU p95约3.92ms，drawable间隔p50约16.67ms/p95约33.34ms；启动前两帧world encoding约140/94ms。仅空人物、无视频内容/无splat的LivingPod，不宣称复杂场景或输入延迟达标。关闭实际exit0，destroy accepted=1，计时器停止；Swift库保留至进程退出，避免未结束Task执行卸载代码。

基础生产叠放通过后按用户授权开始首个GPUI Kit聊天面板组件迁移；生产窗口最小化停帧/恢复、完整小窗轮廓与人物、世界操作输入和真实taskd聊天接线仍需逐项验证，未宣布全部UI迁移完成。

生产生命周期修正版PID78832/session74602实际复验：Kit“最小化宿主窗口”触发visible=0、diagnostics.loopActive=false；CUA Raise恢复后visible=1/loopActive=true，真实房间仍显示。“隐藏4秒后恢复”期间日志采样两次loopActive=false，4秒后visible=1/loopActive=true。关闭exit0/destroy accepted=1。证据 `/tmp/gpui-production-lifecycle-runtime.log` 与 `/tmp/gpui-production-lifecycle-package.log`。此项生产停帧/恢复门禁通过。

首个2D切片 `apps/gpui-ui`：实际Kit Input/Button/scroll与内置theme tokens，Typed Send/Cancel事件及草稿、回调、进度/失败恢复状态。主代理Rust1.95测试7项通过（失败保留、accepted后失败恢复、并发编辑保留、过期回复拒绝、重复回调拒绝、空白/重复发送拒绝）。从根目录误用默认Rust1.91首次编译失败slice_as_array，显式cargo+1.95复验exit0；生产工具链未改。组件尚未连真实transport，图片附件明确不可用；不删除原Swift界面/附件能力。继续在真实渲染宿主中实际验证此组件，不用假回复充当端到端通过。

## Rust同构候选的名称边界

### 用户纠正后端：直接连接现有 DSH Agent

用户明确要求“不指定 key，直接连 agent”。上一轮 Codex/OpenAI API 密钥失败是主代理选错验证后端，不能代表产品 DSH 链路不可用，也不要求用户配置 OpenAI 密钥。

本轮删除 GPUI 宿主的 OpenAI runner/custom provider/key guards，默认连接现有 DeepSeek Harness 原生 ACP。继续复用生产 `ResidentDSHComposition` 与 `ResidentDSHConnector`，由 Harness 自己管理认证；不指定/复制/输出 key，不调用 DeepSeek HTTP API，不回退 headless。独立验证窗口只隔离会话、composition、workspace 和渲染数据，保留现有 agent 的认证方式。`makeResidentSandbox` 增加可选rootDirectory，默认生产行为不变，测试会话可归属隔离根。

新版宿主实际构建成功。`/tmp/gpui-dsh-final-runtime.log` 中 request1 收到真实回复、request2 正确续聊，request3 实际停止后 request4 立即重发并收到真实回复；均未指定 key。此结果仅证明独立宿主的 DSH 连接和回复展示，不能作为主应用 UI、世界功能或完整迁移验收。

### 用户要求转入真实产品验收

独立宿主验收停止扩展。正式接入必须保留原 `AppDelegate`、`ResidentAgentLoop`、空间工具、持久化、音频与人物状态，不能复用 probe 的独立业务 stores 或 chat service。GPUI 管理应用窗口，Swift 产品运行时通过窄 C ABI 接入；默认 SwiftUI 入口继续保留，避免提前删除尚未迁移的设置、附件和播放器功能。

当前实现分工：Rust 正式入口与打包；Swift 产品运行时、编译目标及原菜单/设置入口适配。主代理负责实际主应用的聊天、普通窗口/小窗、缩放、设置和播放操作复验。正式业务验收产物沿用已有 E2ERuntime 的数据隔离机制保护用户数据，业务代码与状态链保持完整。未完成的界面与功能不得标为通过。

### 真实对话接线续作门禁

已核对 taskd 当前仅提供任务、状态、记忆与语音接口，未实现模型对话 RPC。现阶段 GPUI 复用 Swift `AgentConversationService.send`，返回最终整段回复；不声称 token 流式或 Rust 对话核心替换完成。独立验证宿主显式启用后端，使用隔离 cwd、独立配置、环境凭据和只读运行策略，不读取 Keychain 或复制用户认证目录。

继续验收项目：真实全尺寸发送和回复、二轮上下文、取消并恢复草稿、拒绝迟到回复、窗口关闭回收后端进程、小窗真实回复可见及滚动、未启用后端时明确失败。状态测试已增至9项并由主代理复跑通过，真实后端接线门禁仍待产物与窗口验证。

实际首轮接线 `GPUI Chat Connected Probe.app`，主代理受限打包、显式codex启动PID91187，日志 `/tmp/gpui-chat-connected-runtime.log`。真实中文输入request1收到accepted并实际启动后端，最终failure，界面恢复完整草稿；没有真实回复，因此成功门禁未通过。request2按钮重试启动子进程PID91488，实际点击Kit停止后cancel accepted=1、收到cancelled，原稿恢复且PID91488及宿主直接子进程均消失。关闭宿主exit0。4项事件解析测试通过，含缺回复不得成功、非法JSON/交付类型拒绝和精确64位请求ID。继续定位安全错误分类并复验，不把accepted或失败恢复当云端成功。

最终版本关闭前先停止GPUI轮询，再取消并销毁原生宿主。主代理补正过期cancel返回0，`chat-build3.log`构建exit0。诊断修正版`chat-build4.log`构建exit0，Codex显式环境key provider/`requires_openai_auth=false`，不login、不复制auth、不读Keychain；失败仅在内存按auth/model/network/rate/config/unknown分类，原始CLI输出不进入UI/日志。

Final真实复验PID91872：request1界面收到固定安全auth提示并恢复草稿，当前环境API凭证未获接受；并非配置已经正常或完整成功。request2已accepted且CLI PID92398仍运行时实际关闭窗口，App exit0、PID91872及92398均消失，destroy accepted=1。证据 `/tmp/gpui-chat-diagnostic-runtime.log`、`/tmp/gpui-chat-diagnostic-package.log`。另一后端claude-code PID91700也实际accepted后failure、保留草稿并关闭exit0，证据 `/tmp/gpui-chat-claude-runtime.log`；未查出该分支具体云端失败因，不能推广Codex的auth分类。

Final小窗PID92798实际224×336：中文发送、accepted清稿、真实auth失败恢复；32px stock scroll内可滚动读完安全错误，输入和发送按钮一直可见。关闭exit0，证据 `/tmp/gpui-chat-final-compact-runtime.log`。未能收到云端真实回复，因此最新reply滚动展示仅实现/状态测试验证，尚无真实回复视觉验收；空人物liveCam依旧不能算人物视觉通过。默认未启用、缺host配置与非法后端三项CLI负向均exit78：`/tmp/gpui-chat-negative-{missing,backend-missing,backend-invalid}.log`。

当前断点：代码接通真实文本服务、实际失败/停止/关闭回收已经验证；成功回复与二轮上下文仍被凭据可用性阻断。需要可用的环境API配置才可继续此成功门禁，不使用fixture或装机认证替代，也不扩大到世界工具/附件/自动TTS/ASR。其余正式产品入口与设置面板迁移尚未完成。

### 首个聊天切片真实窗口验收

`GPUI Chat Migration Probe.app` 实际打包签名通过。全尺寸 PID80847 使用独立数据根/defaults suite，真实 LivingPod 与 ResidentChatPane 同时显示；中文粘贴、回车发送、按钮重试后显示真实未接入提示，原文字保留，未生成假回复。关闭 exit0。证据 `/tmp/gpui-chat-migration-package.log`、`/tmp/gpui-chat-migration-runtime.log`。

紧凑模式 PID80879 实际224×336（Retina截图448×672），Kit关闭按钮、输入与发送/停止控件可见；“小窗中文测试”回车失败与按钮重试后草稿仍在，错误区域限高滚动，发送按钮保持可见。关闭 exit0。证据 `/tmp/gpui-chat-compact-runtime.log`。生产 liveCam 渲染面已挂载、循环运行，但隔离人物库为空，截图场景区为空白；不算人物、小窗完整视觉或业务验收通过。中文仅测试粘贴与编辑，未验证输入法组合输入。

当前交付是可复用 Kit 聊天组件与独立真实渲染宿主接线，保留原Swift产品入口。真实taskd对话、附件、人物/世界操作及复杂场景性能仍待接入验收；不能将此验证App标记为正式产品UI迁移完成。

用户提供的 https://docs.rs/scenekit/latest/scenekit/ 对应scenekit0.1.0，是独立Rust/wgpu场景框架，并非Apple SceneKit绑定。未来采用它需另做引擎与资产兼容验收，当前不替换引擎。https://docs.rs/objc2-scene-kit/latest/objc2_scene_kit/ 才是Apple SceneKit的Rust绑定；能统一调用语言，不会使Apple渲染后端跨平台。

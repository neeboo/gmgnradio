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

## Rust同构候选的名称边界

用户提供的 https://docs.rs/scenekit/latest/scenekit/ 对应scenekit0.1.0，是独立Rust/wgpu场景框架，并非Apple SceneKit绑定。未来采用它需另做引擎与资产兼容验收，当前不替换引擎。https://docs.rs/objc2-scene-kit/latest/objc2_scene_kit/ 才是Apple SceneKit的Rust绑定；能统一调用语言，不会使Apple渲染后端跨平台。

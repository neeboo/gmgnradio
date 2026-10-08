# Rust / rutis 迁移执行边界

基线：main `9e9adb99e1fda9e6c9865788d9a54a9591d0f9c3`；独立分支 `codex/rust-full-migration`。
2026-10-08 用户指定 `arcships/rutis` 并授权接入。上游固定为
`330ff51b65c0178ab205abb377f6d9dbcd7225fd`，MIT；不得依赖浮动 main。

## 所有权

- Rust / rutis-agent：模型和工具回合；GMGN 负责授权、预算、业务事实、事件消费与持久恢复。
- SQLite / taskd：唯一持久权威，继续使用鉴权本机 HTTP；不新增第二数据库或裸 TCP/UDS。
- Unity：现有输入、场景执行、动作与渲染，回报实际到达和执行结果。
- GPUI：Rust 业务切换完成后的界面迁移；不重复实现 Unity 已有输入。
- 平台接口：文件选择、剪贴板、权限、音视频设备输出；不承担 agent 业务状态。

不使用 rutis-dsh 的 Node/Unix 宿主；不注册 rutis-agent 的 minimal_tools、bash 或 replace_text。
GMGN 工具必须显式列入当轮授权，不能由模型文本生成授权。
已移除本次迁移期间未接入的自写 gmgn-agent-core 试验模块，统一使用 Rutis 模型循环。

## 当前实际状态

### 当前核验基准

用户已要求停止实现并提交推送当前工作树。此提交为未完成的 WIP：运行截图确认 v216 右下角黑色 GPUI 区域且控件不可用，UI 未对齐、未通过实际交互验收；应用已正常退出并确认主进程不存在。生成配置 schema35、音乐账号 schema36 及账号 HTTP 模块仍处于中央注册/统一编译前，不能按已完成迁移使用。所有子代理已中断，不再实现、包装、安装或启动。仅推送 `codex/rust-full-migration`，不合并 main。

最新安装：v216 已安装到 `/Users/ghostcorn/Applications/gmgn radio.app`，实际 plist 版本读回 216；安装回执 `/tmp/gmgn-v216-install-receipt-2.json` 的 daemon_verified 与 registration_clean 均为 true，app_stopped 为 false，未启动应用。v213 可恢复备份为 `/Users/ghostcorn/Applications/.gmgn-install-jdw49omv/previous.backup`。首轮安装因旧正式 daemon 带媒体参数未被精确匹配而失败并回滚，安装器现匹配锁定 hash 验证后的完整生产 argv；41 项隔离测试通过，真机注册表测试跳过。已移除全系统注册库重建。

新增 GPUI ASR 安全错误投影：实际 overlay 11 项纯逻辑测试通过，Kit 错误提示专项 1 项通过；没有录音、播放或设备操作。该新增源码尚未进入已安装的 v216。最终审计仍发现生成配置和音乐账号业务权威残留，正在迁往 schema35/36；音乐账号 HTTP/WeAPI 编码同步迁 Rust，不将原生过渡路径当作完成。

最新交付核验：v216 完整 Unity + 同窗口 GPUI Release 构建退出 0，日志 `/tmp/gmgn-unity-gpui-v216-formal-release.log`。候选为 `apps/macos/Build.noindex/Build/Products/Release/gmgn radio.app`，实际版本 216；组件 SHA256 清单校验及 `codesign --verify --deep --strict` 均退出 0。尚未安装或启动，Applications 仍为 v213；不将候选构建当作运行验收。

退役 realtime 默认偏好和独立 Unity 设置窗口后，完整 Main `build-for-testing` 再次退出 0（`/tmp/gmgn-schema34-settings-retired-tests-compile-2.log`），UnityHost 再构建退出 0（`/tmp/gmgn-embedded-settings-only-host-build.log`）。正式 GPUI Release 构建通过，包含实际 ASR 转写、焦点/IME、局部视觉刷新及 Escape 一次消费；相关纯逻辑测试 10 项通过。正式入口及带空格路径回归 12 项通过。用户明确禁止影响耳机：不运行播放、录音、设备切换测试，不自动启动应用，不修改系统音量。真实界面交互和最终全范围验收仍待完成。

2026-10-08 最新源码已将回复→语音选择移至 Rust `chat_speech`（schema34），jukebox 复合编排移至 Rust `jukebox`（schema33），同链接播放由 Rust begin 判定。最新完整 workspace 串行测试 645 通过、0 失败、5 跳过（`/tmp/gmgn-schema34-workspace-serial-tests.log`），其中 taskd 为 512 项通过。debug daemon 及 UnityHost 构建成功。jukebox 实际 typed-client 私有验收已通过：原夹具缺少 objects 权威记录，修正夹具后保留合法空动作字段完成真实 HTTP/SQLite 验收。schema34 回复语音生产消费者私有验收也通过，设备/provider 为受控模拟，不代表实际声音验收。

当前正式包仍为 v213，原生产数据及 2B 已运行确认。用户已授权全面 GPUI 替换（歌词保留），四组标准组件已整合，组件测试 131 项通过，GPUI Release 与 v214 Unity 候选构建通过；同窗口命令使用唯一原宿主，所有平台凭据钩子禁止 Keychain。正在补齐真实 ASR 转写版本进入新输入框及视觉变化刷新；包装、新正式包安装、图片拖拽及完整真实交互仍待验收。以下状态按历史顺序保留，不可用旧段落覆盖此基准。

用户进一步要求删除旧 Unity UI，不保留隐藏控件和旧界面回退；歌词、视频渲染与世界操控继续保留。当前正在清退旧 UI 源码及迁移相关行为检查。新 GPUI 转写、导航白名单、焦点/IME 与视觉差异测试 9 项通过，Escape 一次消费新增源尚待统一编译。完整 Main `build-for-testing` 正在执行，仅编译、不运行测试宿主；用户明确禁止影响耳机，后续不启动播放、录音或音频设备测试。

最新完整 Main `build-for-testing` 已退出 0（`/tmp/gmgn-schema34-main-tests-compile.log`），包含两架构应用、Rust 辅助程序及 XCTest 编译，不代表 XCTest 实际运行。旧 Unity 操作 UI 已删除，全部运行时和 Editor 离线编译通过；对应真实资产、库存、视频、歌词、错误状态检查保留，纯旧控件布局检查退役，新增实际 GPUI ABI/唯一宿主/生命周期契约。控制器旧节点判断已清除，GPUI 输入门禁保留并补齐点云防穿透。正在清退 `AgentSettingsModel` 旧 realtime 默认偏好路径及隔离设置测试；修改后须再次统一编译。

全量 Python 分组检查已有 304 项通过。导航夹具缺失独立 worktree 未跟踪下载的修复后，发现现有许愿机碰撞高度与烘焙来源失配；已用真实生产网格验证 643 个落地点和 2354 条双向路径后由工具同步来源，导航 3 项通过。设置 XCTest 仍有旧同步 defaults 断言及未隔离设备/默认配置构造，待编译终态后迁移；另发现 `AgentSettingsModel` 启动读取退役的 realtime defaults 密钥路径，需清退，不能将当前范围声明为完整迁移完成。

正式 Unity 消费者追加只读审计仍发现三项 Rust 迁移边界未完成：UnityMediaHost snapshot 根据本地 reply 请求 ID/原生事件选择 TTS、去重与取消；UnityWorldSessionComposition.performJukebox 编排活动→播放及失败停止补偿；NativeScreenPlaybackCoordinator.play 根据旧本地 session 提前拒绝同 URL 请求、未交 Rust begin。摆放/拾取放下已注入 Rust tool 且旧分支不可达，坐下 approach/bind/arrival 消费 Rust 路径，playlist 接续和预取消费 Rust；不将这些已迁项重列为缺口。此轮未改上述源码，先完成用户当前正式包聊天2验证，再继续这些跨域权威迁移；不能以632测试通过宣称完整Rust迁移完成。

用户最新明确授权直接整合当前 GPUI+Unity 工程、更新正式包并启动测试。Applications 当前实际为 Unity v207（`ai.gmgn.unity-sample.player`，`GMGN Unity Sample`），旧包已完整备份至 `tmp/ReleaseArtifacts.noindex/pre-chat2-v207.04fMWb/gmgn-radio-v207.bundle-backup`，正式路径尚未替换。Unity v208 候选真实构建、UnityMediaHost、taskd Release 与 GPUI probe 均已成功；包装日志 `/tmp/gmgn-chat2-unity-package.log` 正在执行。GPUI 最终窗口识别改为本机真实 PlayerWindow/PlayerWindowView，须包装 Cargo 结束后重编该插件。回复 TTS 新增进程级 TEST_MUTED 门禁，未改持久偏好或系统音量；该 Swift 窄改须重建宿主再装入最终候选。完整迁移尚未完成，显示/输入/正式运行均待实际验收。

为优先验证用户要求的“聊天2”同窗口原型，主代理对本轮自有 Main build-for-testing PID 85181 发 SIGINT，session10434 确认退出 75；本轮编译未完成，不记通过。随后启动隔离 GPUI probe 离线构建，日志 `/tmp/gmgn-chat2-probe-build-2.log`，session25188。产品锁文件不变；实验复制产品锁后离线裁剪本地实验依赖，不更新上游版本。原生桥/启动器严格编译、真实 Unity C# 程序集编译与无窗口 ABI 拒绝测试已通过，实际 GPUI 编译、显示与输入仍待核验。

用户明确当前先验证 Unity 主窗口上 GPUI 同窗口覆盖的可行性，不先迁移聊天组件。已有 UnityWindowModeBridge 可取得自身 NSWindow/contentView；独立 GPUI 进程的 NSView 地址不可跨进程使用。真正覆盖需要 GPUI 同进程外部视图适配或真实离屏共享输出，尚无运行验收，透明独立窗口贴窗不得作为完成证据。生产接线保持冻结，仅准备隔离实验。

canonical 修复后完整 Rust workspace 已退出 0：632 通过、0 失败、5 忽略，日志 `/tmp/gmgn-schema32-canonical-workspace-tests.log`。完整 Main build-for-testing 已启动，日志 `/tmp/gmgn-schema32-main-tests-build.log`；仅编译，不启动测试宿主、正式应用或播放音频。该构建包含 Cargo 阶段，期间禁止另起 Cargo 构建。

最新 canonical 修复已覆盖 product_settings、presence_selection 和 agent_cli 工具摘要；taskd 全量 499 通过、0 失败、5 忽略。新 taskd binary 构建退出 0 后，设置真实 HTTP/SQLite 连续十轮双导入顺序验收退出 0：20 次丢回执重试、20 次重启均通过，40 个私有 PID/进程组及临时根目录已回收，日志 `/tmp/gmgn-stage-settings-canonical-10.log`。GPUI App 全量 24 项通过。完整 workspace 新一轮日志 `/tmp/gmgn-schema32-canonical-workspace-tests.log` 正在执行。

本机 Unity 6000.6 MacStandaloneSupport 只核实到 standalone PlayerMain 启动入口，未发现可嵌入视图或输入 API；已有外部纹理接口方向为视频进入 Unity。最终同窗口画面共享/输入转发，或 Unity 主窗口加 GPUI 独立控制界面的产品选择待用户确认；两条路线均须唯一世界、播放及事件消费上下文，不能用旧 CPU 检测作为正式 Unity 路线的完成证据。

正式消费者路线审计发现关键未完成项：GPUI launcher→ProductHost→AppDelegate 默认仍创建 StageRenderSurfaceController/MarbleSpatialView（MTKView、PMX SceneKit），输入由 AppKit StageWorldInteractionView，App 仍安装 CPU TriangleMeshCollisionWorld；Unity PhysX 仅独立 UnityMediaHost composition，正式包没有 Unity Player/UnityMediaHost 或实际宿主选择。既定 Unity 输入/执行/渲染要求尚未成立，当前不得以正式 GPUI 包入口或独立 UnityHost 构建认定迁移完成。正在核对实际 macOS Unity embedding/ABI 与 GPUI Host 正式消费者接线，不采用原生兼容路线替代该要求。

设置幂等修复后的全量 taskd 测试退出 0，497 通过、0 失败、5 忽略，日志 `/tmp/gmgn-schema32-canonical-settings-full-tests.log`。进一步只读审计确认 presence_selection 原始参数 journal 及 agent_cli 工具 schema 摘要仍受嵌套键序影响，正在最小修复；固定 typed 字符串包装、语义 Value 回执和字节 SHA 未作无关改动。
正式 GPUI Make/build/release 候选入口代码已完成，继承原正式产品标识、版本、隐私及资源；纯元数据/构建链五项测试实际退出 0。安装器私有测试退出 0，33 项运行、1 项原有跳过，日志 `/tmp/gmgn-gpui-installer-private-tests-final.log`，覆盖 GPUI 实际 executable、路径拒绝、helper manifest/hash 与 ditto 签名元数据保留。均未执行正式安装、启动或停用应用。
最新 GPUI App 全量测试已启动，日志 `/tmp/gmgn-schema32-gpui-app-tests.log`；正式完整候选包装、Main 测试构建及设备交互仍待完成。

最新 GPUIHost 完整构建退出 0，日志 `/tmp/gmgn-schema32-confirmed-consumers-gpui-host-build-2.log`；恢复按钮后的 UI 128 项再次通过，日志 `/tmp/gmgn-gpui-video-stop-ui-tests.log`。
设置消费者重复验收已真实复现首轮冲突：同 requestID/内容及 encoded SHA 不变，Foundation HTTP JSON 重编码键顺序变化，而 Rust journal 使用未排序 Value 序列化。已改设置五类 journal 使用递归 canonical_json，仅对象键排序，数组、数字及接口身份仍严格；新增真实 SQLite 回归，最新全量日志 `/tmp/gmgn-schema32-canonical-settings-full-tests.log` 正在执行。旧未发布摘要不自动改写或宽松接纳。完整应用测试构建顺延，其他账本同类摘要风险正在审计。
正式默认入口审计确认现 Makefile/install 仍走旧 SwiftUI，GPUI 包仅 E2E identity；正式 GPUI 构建、产品元数据与安装验证代码正迁移，不执行安装或启动正式应用。

完整 Rust workspace `/tmp/gmgn-schema32-workspace-tests.log` 已退出 0，22 个测试组汇总 629 通过、0 失败、5 忽略，包含 taskd、mcpd、protocol、voice-core、agent-runtime 及实际私有进程回收测试。此项不替代 GPUI App、完整 Swift 测试构建或真实设备验收。
设置客户端 stage-first/global-import 的 bootstrap 已修复并冻结：确认仍未 imported 时允许一次旧全局配置导入，先等待现有 mutation；实际原生提取消费者的私有 SQL 验收正在进行。最新全部确认消费者 GPUIHost 构建日志 `/tmp/gmgn-schema32-confirmed-consumers-gpui-host-build.log`，恢复按钮 UI 测试日志 `/tmp/gmgn-gpui-video-stop-ui-tests.log`，均待核对结果。

视频停止恢复真实私有生产消费者复验退出 0，日志 `/tmp/gmgn-stage-video-stop-authority-actual-2.log`：28 项 HTTP/SQLite 检查与 10 项真实 daemon 重启检查通过；丢命令回执只读同步确认投影，同实例真实受控停止一次，丢停止回执重试无重复停止。未执行 AVPlayer.play，不代表实际视频呈现验收。
音乐缓存真实私有消费者退出 0，日志 `/tmp/gmgn-music-cache-f5a495ec-e1db-413f-80c3-93e2abab78f9.log`：实际客户端、文件下载、坏 ready 修复、QQ prefix、格式变化复用、独立 HTML 拒绝、哈希拒绝及重启 unknown 不重领通过；SQL 核验 ready3/unknown2，无 signedURL/headers/cookie 持久。原生 canonical 路径修复未放宽目录或 symlink 校验，实际 daemon/进程组及临时目录已回收。此修复后源待再次宿主构建。

最新 schema32 UnityHost 第三轮完整编译链接退出 0（BUILD SUCCEEDED），日志 `/tmp/gmgn-schema32-unity-physics-settings-host-build-3.log`。覆盖异步物理消费者及设置/歌词/缓存接线的该冻结快照，不代表实际 PhysX 或声音验收。
新二进制实际消费者已发现三项需修：Swift 缓存 URL 标准化使 `/private/var` 与 `/var` 严格比较误拒；视频命令回执丢失后未只读同步 Rust pending 投影，恢复按钮不可达；舞台设置先导入时客户端 bootstrap 因已有 confirmed 跳过尚未 imported 的旧全局配置。均保留实际断言修复，原生编译已解冻，完整 workspace `/tmp/gmgn-schema32-workspace-tests.log` 仍在执行且 Rust 源冻结。

schema32 第三轮 taskd 全量测试退出 0：496 通过、0 失败、5 忽略，日志 `/tmp/gmgn-schema32-music-cache-full-tests-3.log`。覆盖音乐缓存真实私有文件与格式复用、舞台设置/歌词及视频停止核验；新服务二进制构建已启动，日志 `/tmp/gmgn-schema32-taskd-build.log`，真实新增消费者待该构建完成。
真实 57 个 Unity 运行时 C# 源已离线完整编译退出 0，日志 `/private/tmp/gmgn-unity-runtime-offline-compile.log`，含 NativePlayerBackend、WorldRuntimeBridge、物理桥及实际 RecoveryItem，无 DTO shim；Editor 排除，GaussianBridge 使用其所属真实第三方程序集。此项不代表 PhysX 已运行。
UnityHost 第二轮构建退出 65，错误为 SpatialStageStore/StagePresentationModel 回执 observer 闭包需显式 self，已修复；第三轮 `/tmp/gmgn-schema32-unity-physics-settings-host-build-3.log` 正在执行，当前最新宿主联编未证明通过。

音乐文件缓存已登记 schema32，四个 RPC 复用同一 SQLite 权威，文件哈希与发布在 storage worker 外执行。首轮 `/tmp/gmgn-schema32-music-cache-full-tests.log` 编译退出 101：新模块 canonical_json 序列化错误缺公开错误映射，已交回修复；当前 schema32 不具备构建通过证据。
舞台视频停止核验六项 Rust SQL 测试退出 0，日志 `/tmp/gmgn-stage-video-stop-sql-tests.log`，覆盖精确原执行器身份、真实停止事实及丢回执重试。随后 taskd 全量 `/tmp/gmgn-stage-settings-stop-full-tests.log` 491 通过、1 失败、5 忽略；唯一歌词测试误将合法空 trackID 复用为空 requestID，夹具已独立编号，待重验。
设置客户端受控回执回归退出 0，日志 `/tmp/gmgn-stage-settings-client-regression-2.log`；补齐新增确认投影字段和 E2E 根接口，不代表真实 SQL 验收。

GPUI 视频通知投影后的 UI 全量测试退出 0：128 通过、0 失败，日志 `/tmp/gmgn-gpui-video-notice-ui-tests.log`。这是 Rust UI 测试证据，尚非真实窗口交互验收。
异步活动生产消费者真实私有 HTTP/SQLite 流水线退出 0，日志 `/tmp/gmgn-activity-async-physics-private-http.log`，包括测量 provider 错误原样终止且 SQL 无新启动命令，确认没有 CPU 回退；物理测量为受控原始事实，真实 PhysX 尚未运行。
新增审计确认歌词模式（含自动模式选择）及实际 MusicRuntime 文件缓存仍由 Swift 决策/保存，已分配迁移。角色位置/点阵消费者及三份既有测试已冻结并去旧 writer，最新 taskd 与完整宿主验收仍待歌词与物理接线冻结后执行。

新增实际活跃范围审计发现角色位置与点阵选择/粒径仍由 Swift 范围裁决及直接 UserDefaults 保存，已分配 Rust product_settings 和原生确认投影消费者切片；当前完整 Rust 迁移仍未实现此项。GPUI 对应入口已存在，不能把界面迁移当作业务权威已迁移。
Unity 原始探测桥已补实际注册版本：先取得已登记场景 generation，再测量并严格核验；世界、宿主、布局、环境、持握及实际物件 pose 改变均使旧测量失效。使用真实 Unity Core/Physics 引用的离线 C# 编译退出 0，Swift 注册/测量协议夹具退出 0；真实 Unity PhysX 及消费者联编仍未验收。

最新 StageVideo 错误投影接线的 GPUIProductHost 完整构建退出 0（BUILD SUCCEEDED），日志 `/tmp/gmgn-schema31-video-projection-gpui-host-build.log`。证明当前 Swift 原生叶子宿主编译链接，不代表 GPUI Rust 界面或实际交互验收；视频通知的 GPUI UI 全量测试已启动，日志 `/tmp/gmgn-gpui-video-notice-ui-tests.log`。
Unity 专用真实物理场景及 typed 异步探测桥源已产出，独立 Swift 协议夹具运行通过。现处于消费者接线阶段，C# 编译、实际 PhysX 与最新 UnityHost 联编均待完成，不能提前称导航已使用 Unity 实际物理。

新增旧视频绑定恢复后的 taskd 全量测试退出 0：487 通过、0 失败、5 忽略，日志 `/tmp/gmgn-schema31-orphan-binding-full-tests.log`。此项覆盖暂缺文件保留绑定、实际重新登记资产后恢复绑定及显式删除清理；未知资产的新绑定仍拒绝。agent-runtime 取消测试已调整独立 echo 检查顺序，保留原 3 秒期限及全部进程回收断言，定向复验日志 `/tmp/gmgn-cli-transport-cancellation-fixed-tests.log`，结果待核对。

完整 workspace 测试 `/tmp/gmgn-schema31-workspace-tests.log` 退出 101：agent-runtime 私有 launcher 取消测试在读取独立 echo 响应时 TimedOut（cli_transport.rs:135），已分配诊断，尚不能声称完整 workspace 通过。StageVideo 旧字段及两条 GPUI 错误提示投影已修复并冻结，最新宿主重编日志 `/tmp/gmgn-schema31-video-projection-gpui-host-build.log`；旧绑定暂缺文件的保留/重新添加测试正在独立 taskd 全量重验。
碰撞调用链核验确认：Unity 当前发布实际网格三角几何，只有鼠标候选射线；导航 ground/capsule 仍由 Swift CPU 网格测量。现有导入器移除视觉模型 Collider，不能直接宣称已有可用 PhysX 地面。正在增加来自真实登记几何和 pose 的专用 Unity physicsScene/collider 生命周期及带身份版本的异步原始探测桥；Rust 保持路线、支撑与摆放规则权威，未注册场景不得返回可通行。

最新 schema31 GPUIProductHost 完整构建退出 65，日志 `/tmp/gmgn-schema31-gpui-product-host-build.log`：StageOverlayView 仍引用已退役的 StageVideo `activeAsset`，正在更新消费者，当前不得以旧宿主构建证明最新源码通过。
StageVideo 生产 Store/客户端的真实私有 HTTP/SQLite 流水线退出 0，日志 `/tmp/gmgn-stage-video-actual-authority-6.log`：23 项原链路检查、10 项真实 daemon 重启检查及四个 scope 数据核验通过。设备执行为受控回执，未播放音视频；未知旧动作保持 pending 且不重放，显式恢复界面尚未完成。
Presence 删除真实消费者第二轮退出 0，日志 `/tmp/gmgn-presence-removal-http-2.log`，覆盖实际私有文件删除、重启不执行、身份与回执冲突；所有生产同步 activate/remove 旧入口及调用已清理，旧测试适配后的 Main 完整测试构建仍待执行。

当前已登记 schema31（StageVideo）；最新已核验全量 Rust 快照测试退出 0，486 通过、0 失败、5 忽略，
日志 `/tmp/gmgn-schema31-replay-full-tests.log`，含舞台视频重放当前状态与四项规则、删除六项规则、活动准备及 Float/完整 quaternion、提前解析、Marble 到期轮询与分页 SHA 几何证据。
此前 schema30 服务构建退出 0，日志 `/tmp/gmgn-rust-schema30-notdue-taskd-build.log`；分页接口的新服务构建正在执行，日志 `/tmp/gmgn-geometry-paged-taskd-build.log`。
真实私有 Marble Library 轮询、未知提交、恢复不重复付费已通过，日志 `/tmp/gmgn-marble-library-e8d1996e-46a7-4b69-8381-923439b27492.log`。
实际 SPZ/GLB 包流水线、Rust 注册及同 SQL 重启恢复通过，日志 `/tmp/gmgn-rust-marble-pipeline-e2e-5.log`；此验收尚未覆盖新分页几何消费者。
后续分页消费者完整流水线也已退出 0，日志 `/tmp/gmgn-rust-marble-pipeline-e2e-geometry-proof.log`：实际原生 CPU 三角网格 ground/occupancy→Rust 选点→包注册→只读回执→重启，确认同 SQL 两条 SHA 几何证据且仅一个世界。此项不代表 Unity PhysX 或角色视觉操作验收。
独立实际 HTTP 分页拒绝/成功测试退出 0，日志 `/tmp/gmgn-rust-marble-geometry-http.log`，覆盖损坏、越界、错序、缺页、错索引与伪造证明。
Unity 原生宿主完整编译链接通过，日志 `/tmp/gmgn-rust-schema30-unity-host-build-2.log`；其后注册标记顺序修复仍需再次联编。
GPUI 宿主编译发现 App Marble lazy 初始化隔离错误，已改为显式 MainActor 工厂，语法检查通过，完整联编待重试。正式应用、真实界面与音频验收尚未完成。
重试已越过上述错误，但发现 ProductHost C 导出创建入口调用 MainActor 默认登记未进入隔离区，已将登记移入既有 assumeIsolated 区域；第二次完整重试退出 0（BUILD SUCCEEDED），日志 `/tmp/gmgn-geometry-gpui-product-host-build-2.log`。此项证明新几何消费者及 GPUI 原生叶子宿主的完整编译链接，不证明界面运行；随后地点/活动与死模型清理变更仍需再次构建。
全面审计发现 Context 仍以 Swift 决定活动入口/approach/yaw，且历史设备地点绑定依靠种子位置匹配；这些尚未完成迁移。地点绑定改为作者资源显式声明并由可信目录保存，活动 prepare/确认流程仍在实现，不能据 474 项基准声称最新活动变更已验证。
地点缓存接线和退役导航兜底删除已完成：快照、路线、朝向使用 Rust 确认的当前 pose，并按布局/碰撞版本拒绝过期缓存。原生 raw 碰撞、缓存、插值保留。语法与差异检查通过，最新源完整构建待活动准备一起冻结。
旧 Marble provider DTO、轮询模型、排序/默认生成策略已删除；替换的六项真实 Rust 消费测试通过。生活舱本地资源存在隐式 Decodable 依赖，正在改为严格本地资产 codec，当前不得将前次 GPUI 构建成功当作这些最新改动的证明。
严格本地生活舱资产 codec 已完成并通过真实 bundled marble.json / cabin 集成测试（含 identity、semantics、准确点数与无默认值回退负控）；删除旧模型后的 Library 完整真实验收再次退出 0，日志 `/tmp/gmgn-marble-library-8287ab9d-ee75-405b-9dc9-6988da6fa142.log`。源码冻结，仍待最新中央宿主联编。
活动准备新增 `world_activity_prepare` 与八个公开错误码已登记；该实现消费原始路线、活动声明和真实物理证明，start 仅接受确认计划 SHA，不接受宿主 path/yaw。核心及 Swift 接线尚未整体冻结，最新完整测试不可提前宣称覆盖此项。
活动 Swift 接线现冻结，私有实际客户端边界测试退出 0（`tools/test-rust-activity-prepare-client.py`，服务回执为受控夹具，非 Rust 业务验收）。最新完整 Rust 测试 `/tmp/gmgn-activity-prepare-full-tests.log` 退出 101：470 通过、7 失败、5 忽略，七项统一夹具缺少可达入口图，正在补原始路线与实际 capability 证明，生产规则未放宽。当前服务构建 `/tmp/gmgn-places-activity-taskd-build.log` 退出 0；新宿主完整构建 `/tmp/gmgn-activity-gpui-product-host-build.log` 正在执行，正式运行验收仍未开始。
后续最新 GPUI 完整构建退出 0，日志 `/tmp/gmgn-activity-gpui-product-host-build.log`；Unity 宿主复编 `/tmp/gmgn-activity-unity-host-build.log` 仍在执行。第二轮完整 Rust 测试 475 通过、2 失败、5 忽略，剩余夹具漏布局版本及重启目录导航图，已补齐原事实；第三轮 `/tmp/gmgn-activity-prepare-full-tests-3.log` 已启动，结果待核对。
Unity 宿主复编现退出 0（BUILD SUCCEEDED）。第三轮完整 Rust 测试退出 101：475 通过、2 失败、5 忽略；恢复目录图测试已通过，能力活动夹具仍返回不可达，另出现播放列表并发预取测试观察窗口失败。分别继续核查真实物理事实与测试同步，不放宽生产 gate 或删除提前解析断言。当前不可宣称完整测试全绿。
后续第四轮全量退出 0：478 通过、0 失败、5 忽略，日志 `/tmp/gmgn-activity-prepare-full-tests-4.log`。活动 rawproof 比较修复真实 Swift Float/JSON 表示差异，使用精确 f32 比较并拒绝 overflow；未放宽 epsilon。视频并发测试通过可控真实 HTTP 正文闸门观察提前解析，原两秒及并发/取消断言保留。最新服务构建 `/tmp/gmgn-activity-float-fixed-taskd-build.log` 仍在执行，真实活动消费者待此构建重验。
GPUI 死设置面板删除后的完整构建退出 0，日志 `/tmp/gmgn-gpui-dead-settings-cleanup-build.log`。
新只读审计确认仍有活跃 Swift 业务权威：本地舞台 MP4 目录/歌曲绑定/随机接续，以及角色和动作包删除资格/执行回执。已分域实施 Rust 权威与原生设备/文件操作接线；StageVideo 预留 schema31，尚未登记，不能认为 Rust 完整迁移已经完成。
活动完整四分量 quaternion 朝向回归已补，定向活动域测试退出 0，14 通过（`/tmp/gmgn-activity-full-quaternion-tests.log`）；原简化 y/w 公式已移除。最新服务构建 `/tmp/gmgn-activity-quaternion-presence-taskd-build.log` 退出 0，包含此修复和下述删除接口。
Presence 删除复用现有 SQLite 状态/请求日志，无新增 schema。三 RPC `presence_selection_remove_intent/claim/receipt` 和六错误码已登记；内置资格、待删除阻塞、幂等 claim 与实际路径结果核验由 Rust 决定，Swift 五个消费者只执行授权安全文件删除并回执。源码语法及真实客户端类型检查通过，SQL/HTTP 删除验收和完整宿主联编仍待完成，不能声明删除流程已验收。
最新完整 quaternion/Float 服务真实活动 HTTP 验收退出 0，日志 `/tmp/gmgn-activity-prepare-private-http.log`：含实际倾斜 authored anchor、canonical capability、远距离到达拒绝、几何/宿主计划拒绝、精确重放，SQLite 只记五条实际命令和两条运行，准备/拒绝/重放不增行。
Presence 第一轮真实 typed 客户端 HTTP/SQLite 删除验收退出 0，日志 `/tmp/gmgn-presence-removal-http.log`；私有角色/动作删除、Rust 回退、内置拒绝、错会话、重启不重删均通过且进程/目录回收。定向 SQL 4 通过、2 路径夹具失败，已将夹具根规范化，未放宽生产安全门禁；同时请求摘要加入 method，持久状态 execute 恒 false、仅新领取回执可为 true。第二轮定向日志 `/tmp/gmgn-presence-removal-sql-tests-2.log` 正在执行，最新版真实 HTTP 尚待重跑。
Presence 第二轮定向退出 0，6 通过；最后 method/restart execute 收口仍待新 binary 的真实 HTTP 复验。
StageVideo module、schema31 两表、四 RPC 和五错误码已实际登记；未构建验证，模块测试与 Swift 消费者正在实现，中央验证待冻结后执行。该部分沿用同一 SQLite，不新增宿主权威或持久写入 UserDefaults。
StageVideo 客户端已加入主 PBX 工程，plutil 通过。schema31 第一轮完整测试退出 101：485 通过、1 错误码列表排序失败、5 忽略；四项 StageVideo 实际 SQLite 规则测试均通过。码表顺序已修，第二轮 `/tmp/gmgn-schema31-second-full-tests.log` 正在执行。Swift 目录/绑定/接续旧规则已删除，播放器接线使用串行 command→claim→native action→receipt；宿主真实 DI 与私有消费验收仍待完成。
schema31 第二轮现退出 0：486 通过、0 失败、5 忽略。后续 StageVideo 请求重放返回当前权威状态的收口正在补回归，不能把此快照当作后续修改已通过；旧视频及包删除单元测试正在适配真实 Rust 接口，最新完整 Main 测试构建仍待执行。
StageVideo 重放收口已完成，最新全量 `/tmp/gmgn-schema31-replay-full-tests.log` 退出 0：486/0/5；最新服务 `/tmp/gmgn-schema31-replay-taskd-build.log` 构建退出 0。真实舞台视频消费者 Swift6 独立编译链接通过，最新 binary 的实际私有消费及 Presence 第二轮删除 HTTP 验收已启动，结果待核对。
旧 StageVideoPlaybackTests 和两份包 StoreTests 已全部适配私有 Rust 异步权威，语法/差异检查通过，尚未执行 Main 测试；最后 SettingsModel/tool 同步激活调用仍由测试迁移代理处理中，旧同步接口待零调用后删除。
生产 typed 地点客户端真实 HTTP/SQLite 验收退出 0，日志 `/tmp/gmgn-rust-approach-places-http-2.log`：原始导入、可信目录、移动/90°旋转、禁用/移除、过期布局及真实旧回执、异常绑定拒绝均通过。私有 daemon/进程组/目录已回收，不代表 UI 或真实物理操作已验。
GPUI 实际调用链只读审计未发现仍挂载的旧业务 SwiftUI；托盘 NSMenu、系统文件选择、设备输出、Metal/Unity 渲染、被动材质属于保留原生边界。焦点、拖拽、上传取消、缩放/全屏输入、歌词播放和重复打开设置尚缺实际交互证据。
独立真实 DJ 15 项、准备/队列消费者 53 项通过，日志分别为
`/tmp/gmgn-rust-dj-actual-http-2.log`、`/tmp/gmgn-music-prepare-owner-actual-http.log`。
附件实际链路退出 0，记录 `tools/fixtures/rust-chat-attachments-acceptance.md`；
居民记忆实际 41 项通过，日志 `/tmp/gmgn-resident-memory-actual-intent-5.log`。
知识库真实消费者与重启恢复通过，日志 `/tmp/gmgn-schema27-knowledge-consumer.log`。
完整轮次真实消费者 274 项全部通过，日志 `/tmp/gmgn-resident-loop-actual-intent-16.log`；
预算恢复后续调用仅一次，保留续接不会重复投递。后台物品编辑暂停的真实 SQL 验收亦通过。
主应用 Release 构建退出 0，日志 `/tmp/gmgn-rust-schema27-main-app-build-2.log`；
候选包四个 helper 的锁定哈希核验通过，播放工具复用本机已校验缓存，未联网下载。
Host Release 编译与链接退出 0，日志 `/tmp/gmgn-rust-schema29-preview-host-build.log`；
Host 设置切换异步确认测试通过。收件箱 root URL 可选类型接线已修复。日志 `/tmp/gmgn-rust-schema29-app-tests-build-2.log` 的生产 App 和双架构 helper 编译成功，完整测试构建退出 65：旧 AgentConversation/DJ/Stage 测试仍引用退役或改为异步的接口，正在适配并保留行为断言，不能称完整构建通过。
正式应用、音频、用户数据库未切换；GPUI 已补设置命令回执等待及未知状态文案，
完整界面迁移仍未完成。

schema29 首轮的错误码发布失败已修复并通过重验。
Unity 注册/Agent 物品工具/UI 删除/换角色重绑已补实际 Rust 接线；动态能力读取改成有界异步刷新。
普通世界替换不再可改已绑定的天气、相机、目标完成字段；收件箱外部整 DTO 提交已关闭。
通知续办分类迁 Rust，宿主完成回执持久确认后才 ACK。
世界控制、三套收件箱、动态能力和通知续办的真实 HTTP/SQLite 私有消费者均已退出 0；
输出预览真实服务验收退出 0，日志 `/tmp/gmgn-schema29-prop-authority-private.log`：预览不改变整世界快照或数据库行数，远距拿取、非法握持和未确认角色重绑被拒绝，有效重绑保留完整 returnState。主应用及真实界面验收尚未完成。
GPUI 主入口测试 22 项通过，日志 `/tmp/gmgn-gpui-app-full-tests.log`；
GPUI UI 测试 127 项通过，日志 `/tmp/gmgn-gpui-ui-inbox-event-tests.log`，包含已展示事件的已读门禁。
GPUI 非阻塞音乐错误弹窗接线已完成，实际 Swift 双分支验收退出 0 `/tmp/gmgn-gpui-error-notice.log`；最新 GPUI App 全量测试退出 0，18+5+1 共 24 项通过 `/tmp/gmgn-gpui-error-notice-app-tests.log`，实际界面仍未启动验收。
参考图正向登记的真实领取/工具账本/Swift handler/HTTP/SQLite 验收退出 0 `/tmp/gmgn-schema25-reference-positive.log`，重复请求只下载、登记一次；Commons 搜索正向未触网验收。
Marble 生命周期、目录合并和默认选择已接 schema30；两个宿主消费同一 Rust action/receipt，真实服务验收尚待新二进制。功能点/座位接近选择、座位标定与定义已接 Rust，基础包原始声明及座位标定已补权威登记。Marble 几何模块测试通过，但原生构建消费者尚未改为 Rust 计划/实际物理回执。当前 Rust 范围不能标记完整完成。
GPUI 路径已退役隐藏旧 SwiftUI 控件树，专用宿主只构造渲染、场景输入及电视网页叶子；双宏语法和无窗口私有测试通过，正式完整类型检查和真实挂载仍待验收。

### 早期快照记录（以下不是当前全量状态）

当前核验基准：taskd schema18 全量 **369 通过、0 失败、5 忽略**，
日志 `/tmp/gmgn-rust-device-intent-full-tests.log`；随后 schema19 daemon 构建成功，
日志 `/tmp/gmgn-rust-schema19-taskd-build.log`。schema19 音乐库及意图丢回执新增修复
尚需下一轮全量测试；以下旧快照失败计数仅为历史记录，不代表当前失败。
完整 Wish 生产消费者最新为 204 项通过，日志
`/tmp/gmgn-wish-control-command-consumer-8.log`。Unity C# 编译成功且未进入播放模式，
日志 `/tmp/gmgn-rust-props-unity-csharp-compile.log`；最新 Host 构建成功，日志
`/tmp/gmgn-rust-props-default-host-build-2.log`。其后新增消费者尚需重新构建。
完整物品真实 Swift → 私有 daemon 的摆放、持握、就近放下、放回与重启恢复已通过；
普通聊天记忆消费者 32 项通过，日志 `/tmp/gmgn-rust-memory-consumer-test.log`。
默认旧调度开关已移除，缺少 Rust 调度绑定时不再由 Swift 自行启动轮次。
正在迁移音乐库/节目、产品设置、附件与角色动作选择；基础设备移动和原生活动
无权威回退路径仍需完成。正式应用、音频与用户数据库保持不变，GPUI 尚未开始。

- Rust runtime 57 项通过，包括 Unix 独占进程组的取消、deadline、EOF 子树回收、
  原生单次进程、普通 DSH ACP 图片与 Claude 结果协议；Windows 回收行为未验证。
  日志 `/tmp/gmgn-rust-chat-dsh-runtime-tests.log`。
- taskd 330 项通过、5 项外部验收忽略；覆盖 schema v15、活动阶段与移动、usage 投影保护、
  持久生命周期事实、视频会话及 Rust URL 列表分类、Claude/DSH 工具授权与账本。
  日志 `/tmp/gmgn-rust-schema15-full-tests-3.log`。后续普通 DSH ACP 新增生命周期测试
  单独通过，覆盖真实图片、同进程会话复用、取消回收与 EOF unknown 阻止重发；
  日志 `/tmp/gmgn-rust-chat-dsh-actor-tests.log`，尚待下一次完整快照重验。
- 语音真实私有 taskd HTTP/SSE → 生产 Swift 客户端 → 模拟 PCM 设备验收通过，
  覆盖 EOF、FIFO、停止门禁、重复与旧代际回执；日志
  `/tmp/gmgn-speech-delivery-actual-http-test.log`。未使用真实音频设备。
- 新增普通聊天、屏幕元数据与语音接线后的主应用 Release 构建退出码 0；
  日志 `/tmp/gmgn-rust-schema15-main-app-build.log`，未安装正式包。
- 屏幕元数据真实私有 HTTP 保存、退出、同数据库重启恢复均退出 0；
  旧 JSON 字节未改变，SQLite revision 5、命令 4、导入记录 1，两个服务进程已回收。
  证据 `/private/tmp/gmgn-screen-state-http.ui9p1r/acceptance.md`。
- schema v16 已登记物品权威与六条 RPC；物品规则、握点 13 项及契约 8 项
  在全量快照通过。全量为 343 通过、1 项旧领取测试缺真实活动绑定失败、5 项忽略；
  日志 `/tmp/gmgn-rust-schema16-full-tests.log`。注册、缩放等入口仍在迁移。
- 工具结果未知保留 `unknown`，三个 CLI 生产消费者隔离测试共 14 项通过。
  App、Unity 调度构造与发送层已移除默认旧模式开关，真实 claim 缺失时明确拒绝；
  当前源码尚需统一构建和默认模式行为重验，不能视为正式包已切换。
- 完整物品注册、重测、缩放、能力模块已登记，服务构建退出 0；
  全量新快照 360 项通过、1 项领取 fixture 的阶段回执不匹配失败、5 项忽略。
  日志 `/tmp/gmgn-rust-props-wish-complete-full-tests-2.log`。私有 Swift/真实 daemon
  消费与 Unity 宿主构建仍在执行；基础设备旧摆放入口仍需 Rust 权威迁移。
- Wish 所有变更消费已异步等待 Rust 回执，生产同步控制接口已删除；加载、并发串行、
  未确认投影及副作用门禁的真实临时服务验收通过。UUID 往返、恢复幂等和旧暂停解除持久事实
  共 9 项规则测试通过，作用域仍严格匹配。完整 Coordinator 207 项检查通过；
  日志 `/tmp/gmgn-wish-coordinator-migration.log`，原生动作完成部分仍是受控回执。
- Codex/DSH 实际消费者及可信工具绑定已接入显式迁移模式；默认旧模式尚未退役。
  Claude 原生 Rust 服务、MCP 与实际 Swift 宿主接线完成，私有完整 HTTP 端到端通过；
  不将私有 HTTP 测试作为正式 CLI 验收。
- UnityMediaHost Release 构建通过（`/tmp/gmgn-rust-async-authority-host-build-4.log`）；
  主应用 Release 构建通过（`/tmp/gmgn-rust-screen-dsh-main-app-build-4.log`），
  该构建后的新增 Claude Swift 接线仍需独立重验。
- 新增屏幕元数据与语音接线的 UnityMediaHost Release 构建退出码 0；
  日志 `/tmp/gmgn-rust-schema15-host-build.log`。后续工具调用身份与 DSH 图片修改仍需构建重验。
- 正式安装包、音频和用户数据库未切换。以下完整范围仍有效，GPUI 尚未切换。
- 最新真实 Swift → 私有 taskd 验收通过：活动阶段、usage 日期及身份消费、持久事件回调、
  replaceState/upsertObject 伪造 usage 拒绝；日志 `/tmp/gmgn-rust-world-activity-real-consumer.log`。
  视频会话 begin/playing/EOF 幂等及迟到回执通过，SQLite commands 恰三条且媒体缓存为零，
  未下载或播放媒体；证据 `/private/tmp/gmgn-screen-http.0HBCKR/acceptance.md`。

- 新增持久调度模块及 taskd 八个 HTTP RPC；claimed 重启后转 unknown，不自动重放。
  取消请求不提前释放执行槽，必须得到实际取消回执或可信核验结果。
- 新增工具账本；工具授权、业务 operationID 和未知结果核验仅由可信内部接口提供。
  工具请求先落盘，重复写操作不能因换 callID 再次执行。
- 新增活动目录纯规则及三个 RPC；已接入迁移分支的 Swift 消费路径。
  独立临时 daemon → 生产 HTTP 客户端 → Swift Codable 测试通过，200 次相同输入不产生额外 RPC。
  WorldRuntime 构建及 Host 修改语法检查通过；完整 Host 类型检查、主线程首次请求等待仍待处理。
- 新增 gmgn-agent-runtime，通过上游 Ctx / ToolsPlugin / AgentDriverPlugin 装配。
  已验证真实本机 HTTP/SSE 模型 fixture、工具宿主回执队列及后续模型回合，未连接公网供应商或正式 Unity 执行器。
- 已将 vendored 上游的 TUI 依赖改为可选，GMGN 不启用；来源和补丁见 vendor/rutis/GMGN-PATCHES.md。
- 已修复建立流之前的取消及缺少 Finish 的 EOF；contextual 工具回执身份、异常及取消测试共 10 项通过。
- taskd 隔离进程重启与取消恢复、禁止模型注册工具权限及完整 HTTP 模型/工具回合的 3 项测试通过。
- 新依赖启用 JSON preserve_order 后触发的持久编码、幂等与对象事件顺序回归已恢复旧字典序。
  生产媒体逻辑未改；补齐既有错误码契约，媒体测试计数纳入既有索引前缀请求。
- 最新统一回归：runtime 22 项通过；taskd 260 项通过、0 失败、2 项外部验收忽略。
- SQLite 工具账本与 RuntimeService 已接线六个认证宿主 RPC；未知结果需绑定原会话和实际状态核验，逐项核验完再解除阻塞。
- Swift 后台调度接缝可显式注入，HTTP 在主线程外，最多一轮并发且轮询至少 1 秒。
  默认旧模式 274 项检查及真实私有 daemon 调度验收通过；正式默认尚未启用。
- 真实图片输入、工具图片回执、同轮 steering、动态宿主审批及前台控制 schema v8 已实现并通过 Rust 回归。
  服务入口已登记授权、steering 和两条持久引导 RPC；Swift RuntimeClient 已登记进 Xcode 工程。
  既有 CLI 登录后端等价消费及正式模型路径切换尚未完成；GPUI 未开始。
- 完整 UnityMediaHost Release 构建恢复后成功，类型检查及链接通过；未安装或启动正式应用。
- 已清理本次增量缓存和重复的两个本地 crate 构建产物，源码、日志及正式用户数据未动。
  新增切片完整 UnityMediaHost Release 编译和链接通过（日志 /tmp/gmgn-rust-phase-b-host-build.log）；
  真实私有 daemon 前台验收退出码 0，覆盖前台预算豁免、消息幂等、图片 FIFO、
  unknown 引导不重发、停止及迟到回执、scope/session 换代和异步 claim 竞态。
  未替换正式应用或用户数据库。

## 切换门禁

1. 真正使用 rutis-agent 执行模型 → 工具 → 结果 → 下一轮；不得另写并行循环。
2. 流式文本、图片输入、引导、取消保持现有语义；不支持的接口明确阻止切换。
3. world/session/run/call 身份分别校验；旧会话回执拒收，同结果幂等，冲突拒绝。
4. 未知工具执行结果先核验，不能将取消或断流解释为副作用未发生。
5. 通知必须在同轮实际读取并成功处理后 ACK；UI 展示、入队和模型开始不代表完成。
6. 预算、用户停止、编辑暂停、抢占和重启恢复逐例覆盖；旧 Swift 调度切换时关闭。
7. 动作目录、任务授权、物件及播放业务命令逐域接线，移除旧业务写路径。
8. 正式运行时、声音、场景动作和恢复验收单列；单测或构建不替代这些验收。

当前不修改 Applications 正式包、不启动真实模型、不迁移正式用户数据库。

## 当前剩余迁移与验收

- Rust：Marble 场景生成生命周期与业务持久记录仍需迁移；固定功能点/座位的接近路点排序和目标选择仍在 Swift，已分配独立迁移准备。Marble 包构建的出生点候选规则也须继续核对。已迁模块的私有消费者通过，不等于正式运行已验收。
- 构建：最新 schema29 生产 App 编译通过，旧测试目标接口适配后需重建；正式音频、场景和原生窗口未启动。
- GPUI：音乐错误提示已接可关闭的非阻塞弹窗，纯测试和 Swift 实际方法验收通过；正式 Host/Main 构建及界面验收待执行，继续核对实际可达设置、弹窗、布局和输入。
- 实机：全屏/歌词、物品摆放及坐下/拿放、图片输入、完整 TTS 和 playlist 接续仍需分别验收。

### 早期范围记录（以下进度表述不是当前状态）

- CLI 后端：Codex/DSH/Claude 的实际世界工具消费者已接入显式迁移模式；
  Claude 原生 MCP → 私有 HTTP → 账本及终态两项验收通过，日志
  `/tmp/gmgn-rust-claude-native-mcp-http-tests.log`。普通聊天六后端的固定协议四项测试通过，
  schema v13 五条聊天 RPC 及取消、去重、恢复三项测试通过，实际 Swift 消费仍在迁移。
  普通 DSH 图片的原生 ACP 路径正在迁移，不能以文字接口代替这项旧能力。
- 居民调度：后台和人类输入都必须走 Rust claim/finish；前台 UI 取消不能作为实际执行结束。
  正式构造点绑定正在实现，显式迁移门禁只是过渡，最终移除旧 Swift 决策路径。
- 世界活动、导航与物件命令：Rust 接管规则、阶段与业务状态；Unity 保留运动/动作执行和实际回报。
- Wish：Rust 授权、领取、暂停恢复与通知消费已接实际异步宿主；旧 JSON 写入已退役。
  草稿期限、匹配和摆放委派规则正在迁入原始参数命令，剩余提交流程仍逐项审查。
- 音乐：Rust 持久队列、索引与导航及实际 UnityHost/LibraryBridge 投影已接入；
  Swift 保留设备输出。私有真实 HTTP/重启及旧回执拒收通过，正式音频仍需单列验收。
- 视频：Rust 每屏会话、列表 URL 分类与 EOF 推进已接真实客户端；
  ScreenState.json 元数据正在迁到 schema v14，异步持久确认后再发布状态。
- TTS/硬件：云合成、语音 FIFO、替换与代际取消、PCM 窗口和实际播放回执裁决
  已接 schema v15 的生产消费者。平台设备输出保留；provider EOF 不能证明播放完成。
  私有 HTTP/SSE 与模拟设备完整链路通过，真实设备声音仍需单列验收。
- GPUI：上述 Rust 权威切换及旧业务路径退役完成后，迁移界面、弹窗、布局、交互与应用包装，
  验证全屏、歌词、物件列表、图片输入和播放体验。当前尚未完成 GPUI 迁移。

构建和候选接口测试不能证明这些条目已被实际应用采用；每项需补调用接线和对应行为验收。

新增 control_authority_process.py 的两项真实私有 daemon HTTP/SQLite 重启验收通过：
音乐持久队列与旧回执拒收、Wish 持久控制与旧会话写入拒收。

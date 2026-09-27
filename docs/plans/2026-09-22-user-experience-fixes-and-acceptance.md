# 普通用户体验修复与验收（2026-09-22）

本轮只处理普通用户能直接感知、且不依赖真实模型/GPU 就能定位的问题。范围：第一批
「动作接地」「连接失败文案」「Agent 工具进度」；本轮继续修掉上一轮留下的三项
（首次语音授权、图片能力误报、宿主内部原因上屏），并顺手修掉一个高频感知缺口
（后台/自驱回合抢开聊天、收起用户面板）。第三轮（同文档，见第三·续节）继续修
P1-7 过期状态与失败恢复、首次使用引导、回复连续性，以及发送/停止误停自主生活。
所有结论区分「已修」「未修」「需真机」。

## 一、P0 清单与状态

| 编号 | 问题 | 状态 | 证据 |
| --- | --- | --- | --- |
| P0-1 | 动作垂直位移与接地冲突导致人物下沉/穿地 | 逻辑修复，真机画面待验 | 离线 FK 实测 + `tools/test-avatar-grounding.swift` |
| P0-2 | 连接/重连失败文案含退出码、远端错误码、原始 CLI 输出，且无下一步 | 已修 | `tools/test-agent-failure-messages.swift`、`tools/test-resident-dsh-world-loop.swift` |
| P0-3 | Agent 工具进度文案机械化（「正在调用工具…」），未覆盖真实工具名 | 已修 | `tools/test-resident-agent-loop.swift` |
| P0-4 | 首次语音授权超时、shutdown 挂起、重试失效 | 已修（纯逻辑回归；真机授权弹窗待验） | `tools/test-resident-voice-authorization.swift`、`docs/plans/evidence/2026-09-22-voice-authorization-hang-repro.txt` |

## 二、P1 清单

| 编号 | 问题 | 状态 | 证据 |
| --- | --- | --- | --- |
| P1-1 | 无图片的 DSH 世界回合被报成「不支持图片输入」 | 已修 | `tools/test-resident-dsh-world-loop.swift`（+7 项） |
| P1-2 | 宿主工具桥接错误把路径/errno/原始诊断插值上屏 | 已修 | `tools/test-resident-tool-bridge-errors.swift` |
| P1-3 | 后台/自驱回合抢开聊天、收起用户正在看的面板 | 已修 | `tools/test-resident-background-presentation.swift`、`tools/test-resident-agent-loop.swift` |
| P1-4 | `MarblePMXFraming.viewMatrix` 未传 `soleReferenceY`（当前无调用方） | 未修（潜在） | 代码路径 |
| P1-5 | `bounds == nil` 且 `soleReferenceY` 较大时缩放退化 | 未修（当前发货模型不触发） | 代码路径 |
| P1-6 | 接地采样单帧延迟约 1.3 cm | 未修（穿地后果已消除） | 代码路径 |
| P1-7 | 过期状态与失败恢复提示的完整口径 | 已修（纯逻辑回归；真机多表面待验，见第三·续节） | `tools/test-resident-status-lifecycle.swift` |

## 三、逐项根因与修复

### P0-1 动作接地

根因（已证实，非推断）：`preparedMotion` 会保留动作里所有作者编排的根位移
（含垂直方向），且不读取 `rootMotionEnabled`；而全身取景
`MarblePMXFraming.modelTransform` 以「静止脚底」`restFootReferenceY` 贴到
`placement.position.y`。两者叠加后，唯一补偿通道
`PMXFullStageGroundingPolicy.offset` 在默认 `rootMotionEnabled == false` 时直接返回
0，于是动作自带的向下位移没有任何补偿：

```
世界坐标下沉量（米）≈ 0.080085 × placement.scale × (restSole − animatedLow)
```

离线 FK 实测（`tools/motion/recovery_ground.py`，rig `na_2b_0414.pmx`，
`mpu = 0.080085`）：用户 `preferred.pmx` 默认动作
`gmgn.motion.bones.arpg.recovery-faint-pmx` 的脚底低于地面 0.2445 m、整体网格
0.4924 m；`stairs-walk-down-loop-pmx` 可达 1.8026 m。生活舱内置动作
（walk-loop、jumping-jacks、backflip）与 3 个 ResidentMotions 资源
（`センター` 垂直分量恒为 0、VRMA 仅旋转通道）反而略微悬浮，所以问题只在安装的
BONES 动作上出现。

修复（`apps/macos/Sources/GMGNRadio/MMD/PMXStageAvatarRenderer.swift`）：

1. `PMXFullStageGroundingPolicy.offset`：根运动开启时保留完整有符号补偿；关闭时改为
   单向 `max(0, animatedOffset)`。只抬升、绝不下压，因此跳跃、悬浮和根上升保持原样。
2. `updateAnimatedGroundingOffset`：采样从「脚底带」扩展到
   `max(soleOffset, rootDrop)`，其中 `rootDrop = -animatedRootOffset.y`。
3. `installMotion`：新动作安装时清零 `localGroundingOffsetY`，与 `clearMotion` 对称。

冲突说明：`apps/macos/Tests/GMGNRadioTests/MMD/PMXStageAvatarRendererTests.swift`
中名为 `fullStageGroundingDoesNotFeedSoleMotionBackIntoRootLockedDance` 的基线用例
显式断言了旧缺陷。本轮已改名为 `fullStageGroundingLiftsRootLockedClipsOneSidedly`
并断言新的单向语义。该文件属宿主测试目标，本轮未运行（禁止 `xcodebuild test`）。

### P0-2 连接失败与恢复

根因：失败文案由 `AgentConversationError.errorDescription` 等直接拼装，
`ResidentAgentLoop.reportFailure(error.localizedDescription)` 把它交给宿主，
最终显示为「本轮未完成：…」。其中包含原始技术字段：

- `dshExecutionFailed` / `claudeExecutionFailed`：显式插值退出码。
- `CodexCLIError.commandFailed`：把 `result.output`（原始 stderr）直接当文案返回。
- `ResidentCodexTransportError.remoteError(Int)`：插值远端错误码。
- `ResidentDSHTransportError.turnNotCompleted(String)`：插值 ACP `stopReason`。

修复：

1. DSH/Claude 执行失败改为复用已分类的 `reason.userMessage` / 固定可行动文案。
2. `CodexCLIError.commandFailed` 用户文案改为通用且可行动的说明。
3. `remoteError` / `turnNotCompleted` 不再插值，连接类失败补充「系统会在下一条消息时
   重建连接，请重新发送」。
4. `DSHExecutionFailureReason.unknown` 补充具体退路。

恢复操作边界：失败时宿主已把文字和图片还原到输入框（`restoreResidentSubmission`），
用户可直接重新发送。

### P0-3 Agent 工具进度

根因：`ResidentAgentLoop.recordToolProgress` 的 `switch` 只覆盖 7 个工具。
修复：新增纯映射 `ResidentToolProgressNarration.phrase(for:)`，覆盖 34 个真实工具名，
未知工具回落通用文案，绝不显示原始标识符。

### P0-4 首次语音授权（本轮已修）

根因（代码可证，并已离线复现）：`connectRealtimeVoice` 先置 `.connecting`，再在 12 秒
连接超时窗口内惰性调用 `requestMicrophoneAccess`。该函数直接
`await AVCaptureDevice.requestAccess`，**没有超时、不响应 `Task` 取消，也没有可注入
接缝**。首次授权时若用户未及时回答系统弹窗：

1. 12 秒超时触发 `disconnectRealtimeVoice()`，取消挂起任务，但权限 continuation 不会
   因取消而恢复；
2. `enqueueResidentVoiceShutdown` 中的 `await connectingTask.value` 因此不落地，而其
   任务链 `residentVoiceShutdownTask` 从不清零；
3. 之后每次连接都阻塞在 `await previousShutdown?.value`，重试实际失效。

离线复现证据（`docs/plans/evidence/2026-09-22-voice-authorization-hang-repro.txt`）：
抽取**生产**的 `enqueueResidentVoiceShutdown`，用永不恢复的 continuation 精确建模旧
`requestMicrophoneAccess`，取消连接任务后 2 秒内 shutdown 未落地、
`residentVoiceShutdownTask` 仍非空。这排除了「只是慢」的解释。

修复（`apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift`），没有靠延长超时掩盖：

1. 新增顶层 `@MainActor final class MicrophoneAuthorizationGate`：状态与系统请求都是
   可注入闭包（纯逻辑，可离线测试）。`resolve(deadline:onSystemPrompt:)` 语义：
   - 已授权/已拒绝：立即返回，不触碰系统请求；
   - 首次未决定：只在**真正发起**系统请求时回调一次 `onSystemPrompt`，最多等待
     `deadline`；等待被取消或超时都立即返回，但系统请求**继续存在**；
   - 迟到结果写入缓存，下一次 `resolve` 直接复用，绝不弹第二次。
2. `resolveOrFail` 把结果映射为固定用户文案：`.denied` →
   `RealtimeVoiceSetupError.microphoneDenied`；`.awaitingSystemPrompt` → 新 case
   `microphoneAuthorizationPending`（文案只谈系统权限弹窗，不谈连接/图片）；
   `.cancelled` → `CancellationError`（静默收尾，不覆盖状态）。
3. `connectRealtimeVoice`：授权在连接超时之外单独有界等待
   （`residentVoiceAuthorizationDeadline = 60s`，仅限制「等用户回答授权」这一段）；
   12 秒连接超时任务改为**授权通过后**才启动；新增
   `catch is CancellationError { return }`。
4. `enqueueResidentVoiceShutdown`：用代次 `residentVoiceShutdownGeneration` 在落地后
   清零 `residentVoiceShutdownTask`，下一次连接不必再穿过历史链；只有最新一代能清空。

允许 / 拒绝 / 迟到结果 / 取消 / 重试的矩阵由
`tools/test-resident-voice-authorization.swift`（30 项）覆盖，包括：取消后 shutdown
一定落地、迟到授权被复用且不二次弹窗、拒绝后不再发起系统请求。

### P1-1 纯文字连接故障与图片能力故障分离（本轮已修）

根因：`goNative` 在 `worldTools?.visionCapable == true && runtimeScope != "chat"` 时对
**无图片**回合也为真；`acquireDSHImageRuntime` 在缺少 `node`/`dsh-acp-demo` 时抛
`imageTransportUnavailable`，于是纯文字回合被报成「当前居民连接暂不支持图片输入」。

修复（`apps/macos/Sources/GMGNRadio/Agent/AgentConversationService.swift`）：

1. 新增 `AgentConversationError.dshTextTransportUnavailable`，用户文案只谈连接未就绪与
   下一步，绝不提「图片」。
2. `acquireDSHImageRuntime` 增加 `requiresImageTransport: Bool`；缺原生组件时按是否带图
   选择 `.imageTransportUnavailable` 或 `.dshTextTransportUnavailable`。
3. DSH 分支里，无图片回合遇到 `.dshTextTransportUnavailable` 时回落到既有纯文字工具
   路径（`sendViaDSHWithTools` / `sendViaDSH`）；此时尚未发生任何工具调用或模型提交，
   回落不重复执行。

先失败后通过：临时把分类还原成旧行为（始终抛 `imageTransportUnavailable`）后，
`tools/test-resident-dsh-world-loop.swift` 以未捕获的 image 错误退出（exit 5）；恢复
分类后通过。

### P1-2 宿主内部原因上屏（本轮已修）

根因：`ResidentDSHHostToolsError.errorDescription` 与
`ResidentClaudeMCPBridgeError.errorDescription` 把 `reason` 直接插值，而 reason 由
throw 点拼装，可能含私有目录/socket 路径、errno、原始诊断；`WorldAgentToolDispatcher`
的兜底分支还用 `String(describing: error)`，会把枚举关联值（含退出码等）回显。

修复：

1. `ResidentDSHHostToolsBridge.swift`：`errorDescription` 改为固定分类文案（清单无效 /
   配置无效 / 启动失败 / 尚未就绪），绝不插值 reason；新增
   `diagnostic`（`dsh_host_tools/<分类>: <脱敏原因>`）供日志。
2. `ResidentClaudeToolBridge.swift`：同样固定分类 + `claude_mcp/<分类>` 诊断码，
   受限工具名也不再上屏。
3. 新增共享 `ResidentToolDiagnosticRedaction.redact`：把绝对路径替换为 `<path>`，压平
   控制字符，限长 240。用户文案与诊断是两个不同边界。
4. `WorldAgentToolDispatcher.errorMessage` 兜底改为固定可行动文案，移除
   `String(describing:)`。

先失败后通过：临时还原 `startupFailed` 的旧插值后，65 项里有 5 项失败（路径、errno、
凭据、原始 reason、缺少下一步）；恢复固定文案后全过。

### P1-3 后台/自驱回合抢开聊天、收起面板（本轮已修）

根因：`StageWindowController.showResidentChat()` 会展开居民聊天并隐藏节目单/视觉选择
面板；而 `setResidentThinking(true)`、`finishResidentReply`、`showResidentChatStatus`
都在有内容时无条件调用它。后台/自驱回合（用户没发消息）开始、回复或失败时因此抢开
聊天、收起用户正在看的面板。回合结束时 `activeRunIsBackground` 已被清零，回调里读
不到归属，所以旧代码无法区分。

修复（最小改动 + 默认参数保持所有旧调用兼容）：

1. `ResidentAgentLoop`：新增只读 `private(set) var lastFinishedRunWasBackground`，在
   `finishIfReady` 里、调用 `onReply`/`onFailure` **之前**记录本轮归属。
2. `StageWindowController`：`setResidentThinking` / `finishResidentReply` /
   `showResidentChatStatus` 增加 `autoRevealsChat: Bool = true`；为 `false` 时状态照常
   更新，但不展开聊天、不动用户面板。
3. `GMGNRadioApp`：
   - `synchronizeResidentLoopPresentation` 用 `snapshot.isBackgroundRun` 决定是否自动
     展开（回合进行中仍可读到）；
   - `presentResidentReply` 用 `lastFinishedRunWasBackground` 决定；
   - 新增 `presentResidentLoopFailure`，`onFailure` 走它：后台失败只写状态，前台失败
     仍立即展开方便重试。

测试：`tools/test-resident-background-presentation.swift`（抽取生产三个方法 + 源码接线
断言，10 项）；`tools/test-resident-agent-loop.swift` 新增 6 项回合归属断言
（后台回复/失败上报 `true`，用户回合 `false`）；`tools/test-stage-resident-chat.swift`
也补了对应断言，但该文件在本环境因外部宏插件失败无法运行（见第四节）。

## 三·续、P1-7、首次使用与回复连续性（2026-09-22 第三轮）

第三轮把「状态生命周期」「首次使用」「回复连续性」拆成可离线验证的纯逻辑与少量
有界 UI 接线。所有修复都是生产代码；下面每条给出根因、先失败后通过的回归与真机待验
边界。

### P1-7-a 补充消息「未确认送达」永不清除

根因：`ResidentAgentLoop.unconfirmedMessages` 是给模型的长期核对上下文（交付结果
未知的 steering 补充消息，不能自动重发），只在追加、从不移除；而宿主
`synchronizeResidentLoopPresentation` 每次都用它拼出「有补充消息尚未确认送达」的
界面提示。用户下一条消息、停止、换空间都不会清掉这条提示，于是永久滞留。

修复：
- 新增纯类型 `ResidentUnconfirmedNoticePolicy`（`Agent/ResidentAgentLoop.swift`）：
  只管理**界面提示**；`acknowledge` 在用户真实接手后隐藏旧提示，`reset` 在上下文
  切换后重新开始，`pending` 保持原顺序。模型上下文 `unconfirmedUserMessages` 不变。
- `GMGNRadioApp`：新提交消息、主动停止、换空间、换后端时 `acknowledge`/`reset`；
  提示文案改为可执行口径（「如需重来，请在下一条消息里说明，或切换到别的对话
  后端新建会话」），**不声称会自动重建会话**。

回归：`tools/test-resident-status-lifecycle.swift` 第 4 组（旧行为下 `pending` 永不减少，
用户接手后提示仍滞留）。

### P1-7-b 切世界/切后端/断麦旧状态残留

根因：两个聊天表面各自持有 `statusNotice`/`progress`/`deliveryNotice`，只在
`begin()`/新回合时清；`spatialStage.onWorldSelectionChanged` 只停了循环并置空
`residentAgentLoop`，没有清表面状态；后端切换只在 `AgentConversationService.selectBackend`
里重置会话，没有任何宿主通知。

修复：
- `ResidentStatusNoticeMerge`（同上文件）定义状态行类别与合并规则；`StageResidentChatState`
  与 `LiveCamInteractionView` 各自接入（`showStatus`/`showVoiceStatus`/`showFailureStatus`/
  `dismissStatus`/`dismissVoiceStatus`/`clearTransient`）。
- 换空间：`onWorldSelectionChanged` 清两个表面的瞬时状态与交付提示；
  换后端：`selectBackend` 发 `.agentConversationBackendDidChange` 通知，宿主观察后同样清理。

回归：`test-resident-status-lifecycle.swift` 状态机与 `clearTransient` 组；接线断言
`App clears stale status on world/backend switch`。

### P1-7-c 语音已连接仍显示「连接中」

根因：`StageWindowController.setVoiceState` 只在进入 `.connecting` 时
`showResidentChatStatus("正在连接语音转写…")`，之后无论变成 `.listening`、
`.failed` 还是 `.disconnected` 都不清除；该状态行会一直留在空间聊天里。

修复：`setVoiceState` 记录上一次状态，状态**发生变化且新状态不是 `.connecting`**
时调用 `residentChat.dismissVoiceStatus()`；只清除 `.voice` 类别，真正的失败提示
（`.failure`）不受影响。重复的同一状态不清除，避免每次收音事件闪掉 listening 提示。
`LiveCamInteractionView.setVoiceState` 同样处理。

回归：`test-resident-status-lifecycle.swift` 第 3 组。**首次运行即失败**
（`FAIL: mic off clears the listening voice notice`，exit 1），补上「状态变化才清除」
后通过——这条就是先失败后通过的直接证据。

### P1-7-d 多行错误被裁掉

根因：`LiveCamPanel.updateResidentStatusNotice` 用固定公式
`42 + (行数-1)*22` 估算高度，只按 `\n` 计数；一条很长的错误自动换行成多行时
仍只给一行高度，被裁掉。

修复：改为 `updateDeliveryNoticeHeight()`，用
`deliveryLabel.cell?.cellSize(forBounds:)` 按真实排版宽度测量，并在 `layout()` 中
复算；空文本高度 0。

回归：`test-resident-status-lifecycle` 接线断言要求 `cellSize(forBounds:` 且不再有
`prefix(240)`/旧公式（旧公式已被删除）。真机长错误排版待验。边界：语音失败提示
`ResidentSpeechErrorNotice` 仍是 3 行 + `help` 全文 tooltip 的有意上限，本轮不改，
避免在无法运行 AppKit harness 的情况下调整其高度。

### P1-7-e 错误被普通信息覆盖

根因：`showChatStatus`/`showResidentChatStatus` 对失败和普通信息一视同仁，后到的
「点唱机开始播放音乐。」等普通信息会盖掉「本轮未完成」的失败提示。

修复：失败走 `showFailureStatus`（`.failure` 类别），普通信息走 `showStatus`
（`.info`）。合并规则：info 不覆盖 voice/failure；voice 不覆盖 failure；failure
可覆盖并保持到新回合/显式清除。回填失败（`restoreResidentSubmission`）、
回合失败（`presentResidentLoopFailure`）、语音失败（`showResidentVoiceFailure`）
全部改走失败类别。

回归：`test-resident-status-lifecycle.swift` 第 1、2 组；第 7 组用旧逻辑复刻证明
「无条件覆盖」会被这些断言判失败（回归判别力）。

### 首次使用：无后端、无角色、技术配置不上屏

- **无后端**：新增纯 `ResidentBackendReadiness`（`AgentConversationService.swift`）
  给出真实设置路径「设置 → DJ → Agent 聊天后端」；`AgentConversationError.backendNotInstalled`
  文案改为指向该路径。新增 `hasUsableConversationBackend`，把 DSH 原生 ACP 入口
  也算作可用，避免对已配置好的 DSH 误报。宿主 5 秒调度与循环呈现都会在表面空闲
  且无其他提示时先显示该引导，不再等到用户输入后才失败。
- **无角色**：新增纯 `LiveCamPresentationRequest.resolve(hasAvatar:)`
  （`StageCameraCoordinator.swift`）。`showLiveCam()` 在没有角色时弹出一个
  信息型 `NSAlert`（「还没有可显示的角色」+「设置 → 角色」路径），不再只是把
  光球显示出来、看起来毫无反应。不引入默认角色、不新增权限。
- **技术配置不上屏**：长期记忆缺配置的界面文案不再列出
  `GMGN_MEMORY_*` 环境变量名与端点，改为用户可读的「本机还没有可用的记忆服务」
  并提示联系维护者；环境变量名只写进 `livingWorldLogger`（仅日志）。

回归：`tools/test-first-use-guidance.swift`（9 项，含「引导文本不得含 `GMGN_`/
`/Users/`/`环境变量`」）；接线断言确认 `showLiveCam` 走
`LiveCamPresentationRequest.resolve` 且带 `NSAlert` 引导。

### 回复连续性（LiveCam 单条）

- **文本级去重吞合法重复 / dismiss 后新回合不显示**：`show()` 原来只比较文本，
  同一文本在同一回合被重复观察与「新回合说了同样的话」无法区分。新增
  `replyTurn`/`latestReplyTurn`：`setResidentThinking` 检测到 `false→true` 时
  进入新回合；`shouldPresentReply` 的判据是「文本不同、presentation 不同、或回合
  不同」。同一回合内重复观察仍去重（不撤销用户关闭），新回合的相同回复一定重新
  显示。
- **240 字静默截断**：`replyLabel.stringValue` 不再 `prefix(240)`；改由标签自身的
  `maximumNumberOfLines = 3` + `.byTruncatingTail` 显示省略号，完整文本始终在
  可展开的 `fullReplyScroll` 里。
- **最小 transcript 边界（第二轮未做，第四轮已做进程内部分）**：当时两个表面各自只有
  单个 `reply`/`latestReplyText` 与 `ResidentDraftRecovery`，没有按回合的历史存储，
  `ResidentAgentLoop` 也不保留可见回复列表；本轮第四轮补了进程内最近对话（见
  第三·续二节）。**重进/重启恢复仍未做**，原因见该节「持久层评估」。

回归：`test-resident-status-lifecycle.swift` 第 5 组（回合内去重 / 新回合重复 /
同回合不同文本）与第 7 组旧文本级去重判别力。

### 发送/停止误停自主生活

根因：`LiveCamPanel.updateComposerActions` 的 `primaryStops = canStopResident && !hasDraft`，
而 `canStopResident` 包含 `residentCanStop`（后台自主生活开启即长期为真）。于是空
输入时「发送」按钮变成「停止当前任务」，用户点发送会误停自主生活。

修复：新增纯函数 `composerPrimaryActionStops(isThinking:isSpeaking:hasDraft:)`，
只有真正在进行的人类可见回合（思考中/说话中）才让主按钮变停止；独立停止按钮
保留（`!canStopResident || primaryStops` 时隐藏），静默拥有的活动仍有明确停止入口。

回归：`test-resident-status-lifecycle.swift` 第 6 组 + 接线断言。真机按钮语义待验。

## 三·续二、最近对话 transcript（2026-09-22 第四轮）

第四轮聚焦最后一个明显的消费体验缺口：`LiveCam` / 空间聊天只保留最后一条回复，
用户发出的消息和较早的回复无法回看，重进聊天失去连续感。目标是最小、可靠的
**最近对话 transcript**：用户/居民按回合可滚动查看，至少进程内 3 轮；清楚区分
真正送达与失败回填/取消；不重复显示同一回合；不泄漏别的世界或后端会话内容。

### 根因

- 两个表面各自只有单条快照：`StageResidentChatState.reply` 与
  `LiveCamInteractionView.latestReplyText`。新回复直接覆盖旧回复，用户消息只进
  `ResidentAgentLoop` 的私有队列（`messages`/`activeRunMessages`），从不回到
  界面，所以「发出的消息」和「较早的回复」都不可回看。
- `ResidentAgentLoop` 的 `onReply` 只回传回复文本，不告诉宿主本轮覆盖了哪些用户
  提交；宿主无法把「真正送达 / 失败回填 / 取消」落到正确的回合上。
- 失败回填（`onFailure` → `restoreResidentSubmission`）与排队未送达
  （`onUndelivered`）只把图文放回输入框，界面历史里没有对应的「未送达」结论，
  看起来像没发生过。

### 修复（最小改动，不动模型记忆语义，不做巨型 UI 重构）

1. **纯数据层**（`Agent/ResidentAgentLoop.swift` 新增，Foundation-only，可离线测试）：
   - `ResidentChatTurn`：一次真实用户提交 = 一个回合（`id` = 提交身份）。
     `Delivery` 四态：`sending` / `delivered` / `failed` / `cancelled`。
   - `ResidentChatTranscript`：有界（默认 8，至少 3）、按提交 id 去重、按提交顺序。
     `beginTurn` 对同 id 幂等；`markDelivered/markFailed/markCancelled` 只更新仍处于
     `sending` 的回合，迟到/重复观察不覆盖已有结论、未知 id 不臆造回合；
     `cancelPendingTurns` 把明确停止时仍无结论的回合收尾为取消。
   - `ResidentChatTranscriptLine`：两个表面共用的渲染行与固定话术（`你`/`居民`、
     等待/未送达标记），并提供 `plainText`（LiveCam 展开视图）与
     `standaloneReply`（后台回复不在历史里时仍显示且不重复）。
2. **循环只增加两个只读事实**：`receiveUserMessage` 接受稳定的 `submissionID`（默认
   nil，旧调用不受影响）；`finishIfReady` 在回调前记录
   `lastFinishedTurnSubmissionIDs`（本批次 + 轮内引导）。
3. **宿主（`GMGNRadioApp`）持有唯一一份 transcript**，两个表面只渲染同一快照：
   - 提交（键盘/图片）与语音最终转写都 `beginTurn`；
   - `presentResidentReply` 用 `lastFinishedTurnSubmissionIDs` 标记**真正送达**；
   - `presentResidentLoopFailure` 在同一失败终态边界标记**失败回填**；
   - `cancelResidentMessage` / `onUndelivered` 标记**取消/未送达**。
4. **作用域隔离**：transcript 键 = 世界 + 居民会话 scope + 当前对话后端
   （`effectiveBackendID`）。换空间（`onWorldSelectionChanged`）与换后端
   （`.agentConversationBackendDidChange`）都会 `activate(scopeKey:)` 清空旧对话，
   不会显示别的世界或别的后端会话内容。
5. **两个表面口径一致**：
   - 空间聊天（`StageResidentComposer`）：把原来的单条回复块换成按回合的
     `ScrollView` 列表（含未送达/取消标记），后台独有回复用 `standaloneReply`
     单独补一行；复制按钮仍复制最新回复。
   - LiveCam（`LiveCamInteractionView`）：展开聊天后的原「完整回复」滚动视图改为
     渲染整份 transcript（按回合、可滚动）；收起时的紧凑气泡保持只显示最新回复
     （有意的小面板限制，真机待验）。两者使用同一份快照与同一套未送达话术。

### 真正送达 / 失败回填 / 取消的口径

| 结论 | 触发边界 | 历史里的呈现 |
| --- | --- | --- |
| 真正送达 | `onReply`（回复已写入可见表面），按 `lastFinishedTurnSubmissionIDs` | 用户行 + 居民回复行，无未送达标记 |
| 静默完成 | 获准的无文字结束（模型只更新了意图/等待），`lastFinishedTurnWasSilent` | 用户行 + 「本轮已完成，居民没有回复文字。」 |
| 失败回填 | `onFailure`（图文已回到输入框、未自动重发） | 用户行 + 「未送达：本轮未完成，文字和图片已回到输入框，未自动重发。」 |
| 取消/停止 | 用户主动停止、或排队消息 `onUndelivered` | 用户行 + 「未送达：已停止，未自动重发。」 |
| 等待中 | 已提交、尚无结论 | 用户行 + 「已发出，等待回应…」 |

同一提交只产生一个回合：迟到回复不会把已取消的回合改成已送达，重复观察不会
重写已送达的回复，也不会出现第二条相同回合。

### 持久层评估：为什么没有做「重进恢复」（如实保留为未修边界）

按要求先评估了现有持久层能否安全读回，结论是**不能安全复用它来恢复界面历史**：

- 唯一按回合持久化的是 VoiceMem 长期记忆（`ResidentConversationMemory`）。它是
  **模型记忆**，冻结合同明确要求 Swift 侧只转发、不做双路排序/二次融合，也不
  暴露 `memory_read`/`memory_turn`；把融合后的记忆文本倒灌成用户可见历史会改变
  其语义，属于「盲改模型记忆存储语义」，本轮不做。
- `ResidentMemoryStore` 只存意图/暂停标记/有依据事实，不含回合文本；
  `ResidentSystemInboxStateStorage` 只存系统收件箱条目。
- `ResidentStateDomain` 虽然声明了 `.conversation`，但代码里**零写入、零读取**
  （`conversationStorageScope` 实际只用于绑定 VoiceMem；全仓库检索确认没有
  `domain: .conversation` 的提交）。要读回就必须先新增一条回合记录的写入路径，
  那是**新的持久化与隐私设计**，不是「安全复用现有数据」。
- Codex/DSH/Claude 的原生会话文件是各自后端的私有格式，跨后端读取既不稳定也会
  造成后端泄漏，不采用。

因此本轮只保证**进程内**最近对话（≥3 轮，默认 8），重进/重启恢复如实列为未修；
若要做，建议新增一条显式的界面历史记录（独立 key、世界+会话+后端作用域、
只存已终态回合、失败可见且不阻塞聊天），并在真机上验证。

### 内部字段/JSON 话术约束（本轮补充）

检查结论：居民 prompt 里此前没有「不要向用户复述内部 ID/工具名/参数/JSON/坐标」
的明确约束。本轮在 `ResidentWorldContext.prompt(for:toolsAvailable:persona:)`
（Codex 与 DSH 共用）追加一条简短指令：

> 向用户解释你的行动时，只描述用户看得见的动作、结果与感受；不要复述内部标识、
> 工具名、参数、原始 JSON 或坐标数值，需要说位置时用日常说法。

边界：**不删除任何诊断信息，也不对模型输出做盲清洗**。工具桥接的脱敏诊断
（`ResidentDSHHostToolsBridge.diagnostic` 等）保持原样；transcript 原样保留回复
文本（测试显式断言含 JSON/路径的回复逐字保留）。

### 先失败后通过

新增 `tools/test-resident-chat-transcript.swift`（39 项行为 + 20 项接线）。
第一次运行即失败：

```
FAIL: missing production behavior struct ResidentChatTurn:   （exit 1）
```

实现后通过：

```
PASS: 39 resident chat transcript checks, 0 failures         （exit 0）
```

覆盖：提交即可见、至少 3 轮且有界保序、送达/静默完成/失败/取消四种结论互不冒充、
同 id 幂等与迟到重复不覆盖、未知 id 不臆造、已送达不降级、明确停止收尾、
换世界/换后端清空、回复原文逐字保留、图片-only 可读、后台回复 `standaloneReply`
不重复、两表面共用说话人标签与未送达话术，以及旧行为（只留最后一条/失败静默/
永久等待）的判别力复刻。

## 四、测试与退出码

本轮实际运行（仓库根目录，纯逻辑，无宿主/GPU/授权）。最终一轮结果：

| 命令 | 结果 | 退出码 |
| --- | --- | --- |
| `swift tools/test-resident-voice-authorization.swift` | 30 项授权矩阵 + shutdown 落地 | 0 |
| `swift tools/test-resident-dsh-world-loop.swift` | 21 + 119 项 | 0 |
| `swift tools/test-resident-tool-bridge-errors.swift` | 65 项文案/脱敏边界 | 0 |
| `swift tools/test-resident-background-presentation.swift` | 10 项后台呈现 + 7 项接线 | 0 |
| `swift tools/test-resident-agent-loop.swift` | 255 项（含 6 项回合归属） | 0 |
| `swift tools/test-resident-voice-input.swift` | 17 项 | 0 |
| `swift tools/test-resident-image-transport.swift` | 181 项 | 0 |
| `swift tools/test-resident-vision-channel.swift` | 27 项（需 `--disable-sandbox`，见下） | 0 |
| `swift tools/test-resident-conversation-memory-app.swift` | 33 项 | 0 |
| `swift tools/test-resident-claude-tool-bridge.swift` | 163 项 | 0 |
| `swift tools/test-resident-dsh-host-channel.swift` | 89 项 | 0 |
| `swift tools/test-resident-claude-prepare-failure.swift` | 通过 | 0 |
| `swift tools/test-agent-failure-messages.swift` | 16 项 | 0 |
| `swift tools/test-avatar-grounding.swift` | 10 项 + 残留检查 | 0 |
| `swift tools/test-resident-visible-progress.swift` | 通过 | 0 |
| `swift tools/test-resident-submission-recovery.swift` | 16 项 | 0 |
| `cd apps/macos/Packages/WorldRuntime && swift test --disable-sandbox` | 143 项 | 0 |
| `swift tools/test-resident-voice-authorization.swift`（修复前） | `FAIL: missing production behavior MicrophoneAuthorizationGate` | 1 |
| `swift tools/test-resident-tool-bridge-errors.swift`（旧插值临时还原） | 5 项失败 | 1 |
| `swift tools/test-resident-background-presentation.swift`（旧无条件展开） | 4 项失败 | 1 |
| `swift tools/test-resident-dsh-world-loop.swift`（旧图片分类） | 抛 `imageTransportUnavailable` | 5 |

其余上一轮清单也已复跑通过：`test-resident-claude-service`（260）、
`test-resident-dsh-transport`（36）、`test-resident-codex-policy`（33）、
`test-livecam-avatar-framing`、`test-pmx-frame-diagnostics`（7）、
`test-walking-adaptation`（13 组）、`test-resident-world-motion-sources`、
`test-world-motion-feedback`（11）、`test-resident-dsh-agent-tool-bridge`（41）、
`test-resident-dsh-tool-channel`（15）、`test-resident-dsh-process`。

第三轮实际运行（仓库根目录，纯逻辑，无宿主/GPU/授权；第三轮最终一轮复跑）：

| 命令 | 结果 | 退出码 |
| --- | --- | --- |
| `swift tools/test-resident-status-lifecycle.swift` | 30 项（状态合并/语音清除/未确认策略/回复回合/发送停止） | 0 |
| `swift tools/test-resident-status-lifecycle.swift`（修复前，第一次运行） | `FAIL: mic off clears the listening voice notice` | 1 |
| `swift tools/test-first-use-guidance.swift` | 9 项（无角色/无后端/不上屏） | 0 |
| `swift tools/test-resident-visible-progress.swift` | 通过（按新状态机更新 mock） | 0 |
| `swift tools/test-resident-loop-app.swift` | 通过（新增未确认策略依赖） | 0 |
| `swift tools/test-resident-loop-app.swift`（修复前，mock 缺依赖） | `cannot find 'residentUnconfirmedNotice' in scope` | 1 |
| `swift tools/test-resident-voice-input.swift` | 17 项 | 0 |
| `swift tools/test-resident-voice-authorization.swift` | 30 项 | 0 |
| `swift tools/test-resident-background-presentation.swift` | 10 项 | 0 |
| `swift tools/test-resident-agent-loop.swift` | 255 项 | 0 |
| `swift tools/test-resident-dsh-world-loop.swift` | 119 项 | 0 |
| `swift tools/test-resident-tool-bridge-errors.swift` | 65 项 | 0 |
| `swift tools/test-agent-failure-messages.swift` | 16 项 | 0 |
| `swift tools/test-resident-conversation-memory-app.swift` | 33 项 | 0 |
| `swift tools/test-resident-conversation-memory-config-app.swift` | 通过（新增日志 stub） | 0 |
| `swift tools/test-resident-submission-recovery.swift` | 16 项 | 0 |
| `swift tools/test-resident-prop-editor-loop.swift` | 通过 | 0 |
| `swift tools/test-resident-prop-startup.swift` | 18 项 | 0 |
| `swift tools/test-resident-autonomy-preferences-app.swift` | 6 项 | 0 |
| `swift tools/test-resident-world-observations.swift` | 36 项 | 0 |
| `swift tools/test-world-motion-feedback.swift` | 11 项 | 0 |
| `swift tools/test-music-library-app.swift` | 通过 | 0 |
| `swift tools/test-ai-program-selection.swift` | 通过 | 0 |
| `swift tools/test-livecam-control-style.swift` | 通过 | 0 |
| `swift tools/test-stage-control-panels.swift` | 通过 | 0 |
| `cd apps/macos/Packages/WorldRuntime && swift test --disable-sandbox` | 143 项 | 0 |

第四轮实际运行（仓库根目录，纯逻辑，无宿主/GPU/授权/daemon）：

| 命令 | 结果 | 退出码 |
| --- | --- | --- |
| `swift tools/test-resident-chat-transcript.swift` | 39 项 transcript + 20 项接线 | 0 |
| `swift tools/test-resident-chat-transcript.swift`（实现前，第一次运行） | `FAIL: missing production behavior struct ResidentChatTurn:` | 1 |
| `swift tools/test-resident-status-lifecycle.swift` | 30 项 | 0 |
| `swift tools/test-resident-agent-loop.swift` | 257 项（新增 2 项提交/静默归属断言） | 0 |
| `swift tools/test-resident-background-presentation.swift` | 10 项 | 0 |
| `swift tools/test-resident-visible-progress.swift` | 通过 | 0 |
| `swift tools/test-resident-submission-recovery.swift` | 16 项（补新签名 mock） | 0 |
| `swift tools/test-resident-loop-app.swift` | 通过（补 transcript 依赖与 voice 路径索引） | 0 |
| `swift tools/test-resident-voice-input.swift` | 17 项 | 0 |
| `swift tools/test-resident-dsh-world-loop.swift` | 119 项（新增 prompt 约束后复跑） | 0 |
| `swift tools/test-resident-tool-bridge-errors.swift` | 65 项（诊断未被删除） | 0 |
| `swift tools/test-first-use-guidance.swift` | 9 项 | 0 |
| `swift tools/test-resident-world-observations.swift` | 36 项 | 0 |
| `swift tools/test-livecam-control-style.swift` | 通过 | 0 |
| `swift tools/test-resident-speech-notice.swift` | 环境失败（`ObservationIgnored` 外部宏 malformed response，与本轮无关） | 1 |
| `swift tools/test-resident-world-retention-longrun.swift` | 48 项 | 0 |
| `swift tools/test-resident-memory-restore-retry.swift` | 71 项 | 0 |
| `swift tools/test-resident-memory.swift` | 41 项 | 0 |
| `swift tools/test-resident-prop-editor-loop.swift` | 通过 | 0 |
| `swift tools/test-resident-voice-authorization.swift` | 30 项 | 0 |
| `swift tools/test-agent-failure-messages.swift` | 16 项 | 0 |
| `swift tools/test-resident-conversation-memory-app.swift` | 33 项（补 transcript 依赖） | 0 |
| `swift tools/test-resident-conversation-memory-config-app.swift` | 通过 | 0 |
| `swift tools/test-resident-autonomy-preferences-app.swift` | 6 项 | 0 |
| `swift tools/test-agent-conversation-memory-service.swift` | 79 项（prompt 约束后复跑） | 0 |
| `swift tools/test-resident-codex-agent.swift` | 189 项 | 0 |
| `swift tools/test-resident-conversation-tools.swift` | 20 项 | 0 |
| `swift tools/test-resident-dsh-agent-tool-bridge.swift` | 41 项 + swift6 typecheck | 0 |
| `cd apps/macos/Packages/WorldRuntime && swift test --disable-sandbox` | 143 项 | 0 |
| `swiftc -parse`（7 个改动文件） | 语法解析 | 0 |

第四轮环境失败/未运行（沿用并补充，与本轮逻辑无关）：

- `tools/test-stage-resident-chat.swift`：已按生产新增的 `ResidentChatTranscriptLine`
  与 `state.transcript` 补依赖，仍因 `@Observable` 外部宏
  （`swift-plugin-server` malformed response）无法编译。
- `tools/test-livecam-panel-sizing.swift`：harness 自身 `color: .white` 类型推断失败
  （既有），未运行。
- `tools/test-living-resident-loop.swift`：`TaskLocal()` 外部宏在本会话不可用。
- `tools/test-space-presentation.swift`：其他协作者未提交改动新增的
  `residentTaskFeedback` 与 harness mock 既有漂移，与本轮无关。
- `tools/test-resident-dsh-service-native-assembly.swift`：需 `MOCK_BASE_URL`
  环境（脚本前置），本会话未提供。

第三轮未运行的 UI harness（沿用环境限制，未改动其断言结论）：

- `tools/test-stage-resident-chat.swift`：仍因 `@Observable` 外部宏
  （`swift-plugin-server` malformed response）无法编译；已按生产新类型补上
  `ResidentStatusNoticeKind/Decision/Merge` 依赖，宏问题一旦消失应可直接跑。
- `tools/test-livecam-panel-sizing.swift`：仍因 harness 依赖缺
  `ResidentSystemMailBadgeButton` 与 `@Observable` 宏而失败；已补
  `ResidentStatusNotice*` 依赖。属 harness/环境问题，非本轮生产逻辑失败。
- `tools/test-stage-control-actions.swift`：断言要求
  `context.manifest.activityDefinitions.filter { ... }`，而 `HEAD` 与工作区都已是
  `context.activityCatalog.definitions.filter { ... }`，是其它协作者改动与 harness
  的既有漂移，与本轮无关。
- `tools/test-living-resident-loop.swift`、`tools/test-resident-jukebox-outcome.swift`、
  `tools/test-wish-machine-app-runtime.swift`：因 `TaskLocal()`/`Observable()` 外部宏
  在本会话不可用而失败，与本轮改动无关。

`tools/test-resident-vision-channel.swift` 需要把内部的 `swift build` 加上
`--disable-sandbox`（本会话 `sandbox-exec` 被拒，`swift build` 报
`sandbox_apply: Operation not permitted`）。本轮已给该 harness 加上该标志，使其从
环境失败变为可运行（27 项通过）。这是测试基础设施修复，不改生产代码。

未运行的测试（如实记录）：

- `apps/macos/Tests/**`（Swift Testing 目标，含本轮更新的
  `PMXStageAvatarRendererTests`）：禁止宿主 `xcodebuild test`，未运行。
- `swift test`（不带 `--disable-sandbox`）：因本会话 `sandbox-exec` 被拒而失败，
  属环境限制，不是代码失败。
- 本环境无法编译含 `@Observable` / `@ObservationIgnored` 外部宏的 harness
  （`swift-plugin-server` 在沙箱下返回 malformed response），因此以下与本轮相关的
  harness 未能运行：
  - `tools/test-stage-resident-chat.swift`（本轮已按生产新签名补断言）；
  - `tools/test-resident-speech-ducking.swift`；
  - `tools/test-living-resident-loop.swift`。
  为不依赖该宏，本轮另建 `tools/test-resident-background-presentation.swift` 直接抽取
  生产方法体进行验证。
- `tools/test-space-presentation.swift`：本轮之前就已失败，原因是其他协作者未提交改动
  在 `StageWindowController.swift` 新增了 `residentTaskFeedback`（`HEAD` 中不存在），
  而该 harness 的 mock 未同步；与本轮改动无关。
- `tools/test-livecam-panel-sizing.swift`：harness 自身 AppKit 代码
  （`color: .white`）类型推断失败，与本轮改动无关。
- `tools/test-motion-playback-lifecycle.swift`、`tools/test-resident-thinking.swift`：
  本轮之前就已失败（外部宏 / 过期抽取式 harness），与本轮改动无关。

## 五、未修项与建议方案

1. P1-4/P1-5/P1-6：`MarblePMXFraming.viewMatrix` 缺 `soleReferenceY`、极端缩放退化、
   接地采样单帧延迟。前两者当前无触发路径，第三者后果已被 P0-1 消除；需要真机长时间
   观察再决定是否值得改动。
2. P1-7 已在第三轮修复（见第三·续节），第四轮补了进程内最近对话（见第三·续二节）；
   以下边界如实保留：
   - **重进/重启恢复最近 N 轮未做**：进程内 transcript 已完成（≥3 轮、按回合、有界、
     作用域隔离），但没有任何现有持久层保存过「按回合的用户可见历史」——唯一按回合
     存储的是模型长期记忆（其冻结合同禁止 Swift 侧重组为界面历史），`.conversation`
     状态域零写入零读取。要恢复就必须新增一条显式的界面历史记录（独立 key、
     世界+会话+后端作用域、只存终态回合），属新的持久化与隐私设计，本轮按「最小、
     可靠」不做；建议下轮以独立变更 + 真机验证推进。
   - **LiveCam 紧凑态只显示最新一条回复**：展开聊天后才是完整、可滚动的最近对话。
     这是小面板的有意限制，真机排版待验；若体验不足，再考虑在紧凑态显示最后两轮。
   - **后台预算/状态提示语义不一致未做**：`backgroundTurnsPerHour`、`residentCanStop`
     与状态行文案之间的语义仍不完全对齐（例如预算为 0 与「已停止」的区别没有单独
     文案）。这需要产品口径，未在本轮改动，避免在没有口径时改大文件。
   - 失败后的真实可选操作已明确（重新发送 / 切换后端新建会话），但**没有**新增
     「一键新建会话」按钮，也没有任何自动重建会话的假称。

## 六、端到端验收（需用户真机执行）

1. 纯逻辑门（可离线，用户可复跑）：
   `swift tools/test-resident-status-lifecycle.swift && swift tools/test-first-use-guidance.swift && swift tools/test-resident-chat-transcript.swift && swift tools/test-resident-voice-authorization.swift && swift tools/test-resident-dsh-world-loop.swift && swift tools/test-resident-tool-bridge-errors.swift && swift tools/test-resident-background-presentation.swift && swift tools/test-resident-agent-loop.swift`
2. 首次语音授权：首次点麦克风时观察系统弹窗；分别在「允许」「拒绝」「弹窗放着不管
   >60 秒」「弹窗期间再点一次取消」后重试，确认：不出现假的「连接超时」、取消后能立即
   再次录音、允许后无需二次弹窗；这一步必须由用户在真机系统弹窗上各选一次才能验证。
3. 图片能力误报：连接一个声明视觉能力的 DSH 世界，在缺少 `dsh-acp-demo` 组件的机器上
   发送**纯文字**消息，确认不再出现「暂不支持图片输入」，而是纯文字连接说明或正常
   回落；再发送带图消息，确认仍得到明确的图片能力说明。
4. 内部原因上屏：制造一次工具通道启动失败（如私有目录不可写），确认界面文案是固定
   中文说明，不含 `/Users/...`、`errno`、socket 路径。
5. 后台回合：开启居民自主，让后台/自驱回合自行产生回复或失败，确认不会替你展开聊天、
   不会收起节目单/视觉面板；用户自己发消息时仍会展开。
6. 动作接地：选择 `gmgn.motion.bones.arpg.recovery-faint-pmx`，观察脚底/躯干是否仍沉入
   地面；切换跳跃/后空翻类动作确认未被压回地面。

第三轮新增真机待验：

7. 过期状态：连接语音，观察空间聊天从「正在连接语音转写…」变为「正在听…」后不再
   残留「连接中」；关麦后「正在听…」消失。
8. 切世界/切后端：制造一条失败提示后切换空间或切换 Agent 后端，确认旧空间的进度/
   失败/交付提示不再显示。
9. 未确认送达：在补充消息交付结果未知时确认提示出现；随后发下一条消息或停止，确认
   提示消失，且不会自动重发。
10. 多行错误：制造一条很长的失败文案，确认 LiveCam 交付提示完整换行显示而不是被裁掉。
11. 首次使用：在没有已安装后端的机器上打开聊天，确认先出现「设置 → DJ → Agent 聊天
    后端」指引；在 `设置 → 角色` 没有角色时点「显示 Live Cam」，确认出现可见提示而
    不是毫无反应；确认长期记忆缺配置的提示里不再出现 `GMGN_MEMORY_*` 环境变量名。
12. 回复连续性：关闭一条回复气泡后，让居民在新回合再说一句完全相同的话，确认气泡
    重新出现；发送一条超过 240 字的回复，确认紧凑气泡带省略号且点开可看到全文。
13. 发送/停止：开启居民自主生活、清空输入框，确认「发送」按钮不再变成「停止当前
    任务」，而独立停止按钮仍可停止正在进行的活动。

第四轮新增真机待验：

14. 最近对话：连发三条消息，确认展开聊天后能按回合回看你自己发的每一条与较早的
    回复（不止最后一条），并能在列表内滚动；LiveCam 展开态确认同样可见整段历史。
15. 未送达口径：制造一次失败（如断开后端），确认对应回合显示「未送达：本轮未完成，
    文字和图片已回到输入框，未自动重发。」；再发一条后立刻点停止，确认显示
    「未送达：已停止，未自动重发。」；两条都不应显示成已送达或重复出现。
16. 隔离与恢复边界：切换空间、切换 Agent 后端，确认看不到上一个空间/后端的对话；
    完全退出并重开 App，确认最近对话**不**恢复（当前已知未修边界，见第五节）。
17. 内部字段话术：让居民执行一次空间动作，确认回复描述的是可见行动而不是复述
    `worldID`/活动 id/工具名/坐标 JSON；工具失败时确认界面仍是固定中文说明。

真机脚本：`tools/verify-resident-ux-real-device.sh`（只做只读日志与逻辑门，不启动、
不构建、不安装宿主；需用户手动操作界面并回车逐步确认）。

## 七、修改文件

本轮（2026-09-22 第四轮）：

- `apps/macos/Sources/GMGNRadio/Agent/ResidentAgentLoop.swift`（新增纯类型
  `ResidentChatTurn/Delivery`、`ResidentChatTranscriptLine`、`ResidentChatTranscript`；
  `receiveUserMessage` 增加 `submissionID`；`finishIfReady` 记录
  `lastFinishedTurnSubmissionIDs`）
- `apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift`（持有唯一 transcript；
  提交/送达/失败/取消四个边界；世界/后端切换清空；语音转写进入历史；
  `residentTranscriptScopeKey`/`publishResidentTranscript`）
- `apps/macos/Sources/GMGNRadio/VisualEngine/StageOverlayView.swift`
  （`StageResidentChatState.transcript/setTranscript`；`StageResidentComposer` 按回合
  滚动列表 + 后台回复 `standaloneReply`）
- `apps/macos/Sources/GMGNRadio/VisualEngine/StageWindowController.swift`
  （`setResidentTranscript` 透传）
- `apps/macos/Sources/GMGNRadio/DesktopPresence/LiveCamPanel.swift`
  （`setResidentTranscript`；展开态渲染整份 transcript，紧凑气泡仍只显示最新回复）
- `apps/macos/Sources/GMGNRadio/DesktopPresence/LiveCamWindowController.swift`
  （`setResidentTranscript` 透传）
- `apps/macos/Sources/GMGNRadio/Agent/AgentConversationService.swift`（`prompt(for:)`
  追加「不复述内部 ID/工具名/参数/JSON/坐标」的简短约束；未删除任何诊断）
- `tools/test-resident-chat-transcript.swift`（新增，34 项行为 + 17 项接线）
- `tools/test-resident-submission-recovery.swift`、
  `tools/test-resident-loop-app.swift`、
  `tools/test-resident-conversation-memory-app.swift`、
  `tools/test-stage-resident-chat.swift`（按新签名补 mock/依赖）
- `tools/verify-resident-ux-real-device.sh`（加入 transcript 逻辑门与真机清单）

本轮（2026-09-22 第三轮）：

- `apps/macos/Sources/GMGNRadio/Agent/ResidentAgentLoop.swift`（新增纯类型
  `ResidentStatusNoticeKind/Decision/Merge`、`ResidentUnconfirmedNoticePolicy`）
- `apps/macos/Sources/GMGNRadio/Agent/AgentConversationService.swift`
  （`ResidentBackendReadiness`、`hasUsableConversationBackend`、
  `.agentConversationBackendDidChange` 通知、`backendNotInstalled` 设置路径）
- `apps/macos/Sources/GMGNRadio/VisualEngine/StageCameraCoordinator.swift`
  （`LiveCamPresentationRequest`）
- `apps/macos/Sources/GMGNRadio/VisualEngine/StageOverlayView.swift`
  （`StageResidentChatState` 状态类别与生命周期）
- `apps/macos/Sources/GMGNRadio/VisualEngine/StageWindowController.swift`
  （语音状态变化清除临时提示；失败/语音/上下文切换透传）
- `apps/macos/Sources/GMGNRadio/DesktopPresence/LiveCamPanel.swift`
  （状态类别、回复回合去重、去掉 `prefix(240)`、按测量高度、语音清除、
  `composerPrimaryActionStops`）
- `apps/macos/Sources/GMGNRadio/DesktopPresence/LiveCamWindowController.swift`
  （失败类别、状态/语音透传）
- `apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift`
  （未确认提示生命周期、世界/后端切换清理、语音失败类别、无后端引导、
  `showLiveCam` 无角色 `NSAlert`、记忆缺配置文案去环境变量）
- `tools/test-resident-status-lifecycle.swift`（新增，30 项）
- `tools/test-first-use-guidance.swift`（新增，9 项）
- `tools/test-resident-visible-progress.swift`、`tools/test-resident-loop-app.swift`、
  `tools/test-resident-background-presentation.swift`、
  `tools/test-resident-conversation-memory-config-app.swift`、
  `tools/test-resident-submission-recovery.swift`、`tools/test-resident-voice-input.swift`、
  `tools/test-stage-resident-chat.swift`、`tools/test-livecam-panel-sizing.swift`
  （按新生产签名补 mock/依赖）

本轮（2026-09-22 第二轮）：

- `apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift`（`MicrophoneAuthorizationGate`、
  新错误 case、连接/关闭链路、后台回合呈现接线）
- `apps/macos/Sources/GMGNRadio/Agent/AgentConversationService.swift`（纯文字/图片连接
  故障分类、回落）
- `apps/macos/Sources/GMGNRadio/Agent/ResidentDSHHostToolsBridge.swift`（固定文案 + 脱敏诊断）
- `apps/macos/Sources/GMGNRadio/Agent/ResidentClaudeToolBridge.swift`（固定文案 + 脱敏诊断）
- `apps/macos/Sources/GMGNRadio/Agent/WorldAgentToolDispatcher.swift`（去掉
  `String(describing:)`）
- `apps/macos/Sources/GMGNRadio/Agent/ResidentAgentLoop.swift`（回合归属只读位）
- `apps/macos/Sources/GMGNRadio/VisualEngine/StageWindowController.swift`（
  `autoRevealsChat`，默认展开保持兼容）
- `tools/test-resident-voice-authorization.swift`（新增）
- `tools/test-resident-tool-bridge-errors.swift`（新增）
- `tools/test-resident-background-presentation.swift`（新增）
- `tools/test-resident-dsh-world-loop.swift`、`tools/test-resident-agent-loop.swift`、
  `tools/test-stage-resident-chat.swift`、`tools/test-resident-voice-input.swift`、
  `tools/test-resident-conversation-memory-app.swift`（更新断言/mock）
- `tools/test-resident-vision-channel.swift`（`swift build --disable-sandbox`）
- `docs/plans/evidence/2026-09-22-voice-authorization-hang-repro.txt`（新增复现证据）

上一轮（同文档首批，仍有效）：

- `apps/macos/Sources/GMGNRadio/Agent/CodexCLI.swift`、`ResidentCodexTransport.swift`、
  `ResidentDSHTransport.swift`（失败文案）
- `apps/macos/Sources/GMGNRadio/MMD/PMXStageAvatarRenderer.swift`（接地单向修复、残留清零）
- `apps/macos/Tests/GMGNRadioTests/MMD/PMXStageAvatarRendererTests.swift`（更新断言，未运行）
- `tools/test-avatar-grounding.swift`、`tools/test-agent-failure-messages.swift`、
  `tools/verify-resident-ux-real-device.sh`（新增）

未修改任何用户数据、未执行 `git reset`/`checkout`、未提交或推送。

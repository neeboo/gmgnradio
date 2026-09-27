# 居民阻塞修复与许愿异步三方反馈 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 修复当前居民请求、反馈、散步与许愿链路的确定阻塞，让许愿以异步任务和异步通知驱动世界、界面、agent。

**Architecture:** 保留现有 DSH、世界活动执行器和 WishMachineCoordinator；不新增通用任务平台。以每个任务的持久状态和事件作为事实来源，三方投影使用相同 wish_id，受理、生成完成、渲染可见、领取与摆放分别确认。导航先修连续走动与停止，并复用现有碰撞数据扩展路径覆盖；翻越必须单独满足轨迹和落点安全条件。

**Tech Stack:** Swift 6、SwiftUI/AppKit、WorldRuntime、JSON-RPC/ACP、离线 Swift fixture、BONES VMD/VRMA、现有 Python 导航几何工具。

## 执行约束与所有权

用户已要求实际修复、全面排查、明确规划并分开原生 subagent 执行。继续当前含既有改动的工作目录，不提交、不回退、不迁移工作树。只运行独立离线测试和禁自动签名构建；不启动或退出宿主、不操作宿主 UI、不访问钥匙串或系统授权、不发送真实模型或生产生成请求。

| 任务 | 负责人 | 独占生产文件 | 回归入口 |
| --- | --- | --- | --- |
| A 连接生命周期 | review_dsh_transport_source | Agent/ResidentDSHTransport.swift | tools/test-resident-dsh-transport.swift |
| B 对话上下文与取消 | dsh_reply_diagnosis | Agent/AgentConversationService.swift | tools/test-resident-dsh-world-loop.swift、tools/test-resident-image-transport.swift |
| C 进程与管道 | review_dsh_actual_entry | Agent/CodexCLI.swift | tools/test-resident-dsh-process.swift |
| D 反馈界面 | review_dsh_ui_source | VisualEngine/StageWindowController.swift、StageOverlayView.swift、DesktopPresence/LiveCamPanel.swift | tools/test-resident-visible-progress.swift、tools/test-stage-resident-chat.swift |
| E 导航与持续散步 | inspect_walk_planning | 先核查；方案确认后独占 Agent/WorldAgentContext.swift 及必要导航运行时文件 | tools/test-resident-world-tools.swift、WorldRuntime 对应测试 |
| F BONES 接线审计 | bones_resident_assets | 只读动作运行链路，修复另行分配 | 明确失败路径后确定 |
| G 许愿异步核心 | dsh_visible_progress | 方案确认后独占 Presence/WishMachineCoordinator.swift、Agent/ResidentWishMachineTools.swift | tools/test-wish-machine-coordinator.swift、tools/test-wish-machine-delivery-loop.swift |
| H 应用整合 | 主代理 | App/GMGNRadioApp.swift、Agent/ResidentActivityOutcome.swift；事件投递入口待核查 | tools/test-wish-machine-app-runtime.swift、tools/test-resident-jukebox-outcome.swift |

表中 Agent、Presence、VisualEngine、DesktopPresence 相对 `apps/macos/Sources/GMGNRadio/`。所有权之外的改动必须先协调；运行时、资源与界面不可同时覆盖同一文件。

## A–D：DSH 可确定修复

每项按同一顺序执行：补能复现真实生产方法的失败回归 → 运行确认原因 → 最小实现 → 相关完整回归 → 独立源码审查。

1. A：取消绑定原 pending request ID；已结束请求的迟到取消不得作用于下一轮，空闲取消不得启动硬关闭。保留有在途请求的有界取消和异常关闭。
2. B：新 native 会话只初始化一次历史；复用时只提交本次用户输入或新增工具结果/纠正。图片首包、切换会话、握手中取消和迟到返回单独回归。
3. C：stdout/stderr 分离并并行排空；成功回复仅 stdout，失败优先 stderr，无 stderr 时保留 stdout 诊断。测试大输入和双大输出同时流动、超时、取消、零退出码但已超时。
4. D：收起聊天区时仍有居民请求反馈；不反复抢走用户收起选择或输入焦点。当前轮错误不被重复 thinking 快照清空，应用错误不关闭仍在执行的取消入口。

运行：`swift tools/test-resident-dsh-transport.swift`、`swift tools/test-resident-dsh-world-loop.swift`、`swift tools/test-resident-image-transport.swift`、`swift tools/test-resident-dsh-process.swift`、`swift tools/test-resident-visible-progress.swift`、`swift tools/test-stage-resident-chat.swift`。预期各自零失败，不能用测试汇总代替源码审查。

## E–F：移动与动作

1. 先回归 move_to → stop → 继续 tick 不再位移；修停止对普通 movement 无效。
2. 单次 move_to 保持单段语义；home.walk 使用本地连续巡游，覆盖多个已验证可达点，到第一点后继续，停止/替换/切世界清理续行。
3. 正常移动按路段转向；到达/受阻产生真实反馈，有限重规划且不穿模，不每帧无限重试。
4. 导航资源复用现有三角面与烘焙器，保留活动锚点，并同步 authoring 源；生成图用生产胶囊碰撞逐边复验。先评估真实可达区域再承诺覆盖范围。
5. BONES 入库与运行接线分别检查：可选、实际播放、格式匹配、根位移与导航叠加、动作完成反馈。slap bass 和后空翻保留。
6. 翻越独立列项：起落点、完整胶囊净空、可承重落点、动画位移对齐、中断处理缺一不可；禁止提高步高或跳过碰撞伪装翻越。

## G–H：许愿机异步任务与三方通知

用户明确要求：**异步任务、异步通知；世界有反馈、界面有反馈、agent 有反馈。**

1. 提交先记录持久 wish_id，图像适配后等待 Rust 本地落盘确认即返回；POST、远端查询和下载由独立后台继续，不占用对话工具回路。后台具体合同以 `2026-09-07-rust-taskd-contract.md` 为准。
2. 同一任务贯穿受理、提交不确定、生成中、下载/准备、渲染可见、领取、摆放，以及失败/取消/中断。沿现有状态扩展最小缺项；不得将后台完成等同于场景可见或交付。
3. 世界按真实状态改变许愿机与产物；渲染器实际成功才发 outputReady。
4. Stage/LiveCam 展示对应 wish_id 的异步状态和具体失败，独立于当前聊天 thinking；旧任务通知不覆盖新一轮输入或居民原始回复。
5. Rust 持有 world、ui、agent 三路独立持久待收消息与确认；关键完成及失败事件进入通知性续办，不依赖 agent 轮询或默认后台闲聊开关。用户停止/暂停自动续办仍有效，通知不得恢复已撤销的动作委托。
6. 明确事件接收与业务副作用确认边界；重复刷新、重复通知、重启恢复不重复生成、领取或摆放。确认事件持久化失败不能吞掉成功回复。
7. 现有远端生成服务采用查询回执；由 Rust 后台查询并发布本机异步通知，不宣称外部服务已经支持推送。场景渲染事实另由应用发布，不与后台下载完成混用。

回归包含：POST 阻塞时提交仍返回、任务后台完成、失败通知、默认后台关闭时终态通知、暂停不擅自续办、重复投递、渲染失败不报 ready、换世界隔离、重启恢复、确认存盘失败保留成功回复。只用离线 fixture。

## 整合与验收

- H 对活动结果与世界工具使用同一个 300 秒 deadline，避免后半轮音乐立即过期。
- 主代理核对每个改动与失败路径，再分派需求符合性和代码质量审查；未解决的重要问题必须返回修复。
- 合并后运行受影响的居民循环、世界工具、许愿核心与应用整合回归；最后单次完整 Debug 构建（关闭自动签名）。
- 更新证据中的已修/未修/未验证状态。安装和真机视觉验收分开，不把构建成功或模拟事件当作宿主运行通过。

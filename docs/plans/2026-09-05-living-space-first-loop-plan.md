# 第一阶段：居民感知、行动与统一会话实施计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal：**用户通过文字或语音，向同一名居民发出“去点唱机放首歌”，居民根据实际环境行动，并据执行结果回答。

**Architecture：**复用 AgentConversationService、WorldAgentContext 和现有世界工具，不创建第二套活动执行器。先用一种提供方验证真实工具调用，再让语音转写进入同一会话；文字与 TTS 消费同一份回答。

**Tech Stack：**现有 Swift 应用、WorldRuntime、命令行 Agent 适配、当前语音输出接口，以及待接入的语音转写实现。

日期：2026-09-05。对应总计划阶段 1。本文件描述待执行任务；编写计划不代表任务已经实现或验证。当前代码基线为 `4cb6c32`。

## 范围与执行约束

- 一名居民、当前飞船生活舱、现有点唱机，不重新生成房间。
- 第一轮只做文字感知和动作；完成后再做语音输入、口型及六种提供方逐项验收。
- 不新增通用装修编辑器、云端世界服务器、物件市场和复杂人格系统。
- 本计划可在当前任务中分配给编码子任务逐项执行，由主任务审查；现阶段不自动启动实现。
- 下文仓库根目录为 `/Users/ghostcorn/dev/gmgnradio`；新文件是建议创建的位置，实施前核对当前代码组织，避免重建已有功能。
- 禁止读取真实密钥作诊断、操作钥匙串、启动桌面自动化、用宿主测试抢占用户电脑。真实模型测试、应用重启和任何付费调用须在执行时取得对应授权。

## 当前断点及证据

| 断点 | 当前入口（行号以本次检查为准） |
| --- | --- |
| 文字发送直接传用户文本，未附世界快照或工具 | `apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift:2833`，`sendLiveCamMessage` |
| 六种后端已有真实命令分支，但真实服务验收未齐 | `apps/macos/Sources/GMGNRadio/Agent/AgentConversationService.swift:375` |
| 当前快照有地点和活动，缺少通用物件清单 | `apps/macos/Sources/GMGNRadio/Agent/WorldAgentContext.swift:48`，`WorldAgentSnapshot` |
| 已有正式工具执行器 | `apps/macos/Sources/GMGNRadio/Agent/WorldAgentToolDispatcher.swift:89` |
| 世界工具挂在原 DJ 工具分发器，未接文字 CLI 会话 | `apps/macos/Sources/GMGNRadio/Agent/DJAgentToolDispatcher.swift:478`、`:710` |
| 麦克风转写进入原节目意图处理 | `apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift:2526` |
| 回答使用系统朗读，尚未统一此链的口型和打断 | `apps/macos/Sources/GMGNRadio/Agent/AgentSpeech.swift:29` |

## 任务 1：固定会话边界和验收样例

**文件：**

- 检查、修改：`apps/macos/Sources/GMGNRadio/Agent/AgentConversationService.swift`。
- 检查、修改：`apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift` 中 `sendLiveCamMessage`。
- 测试：`apps/macos/Tests/GMGNRadioTests/Agent/AgentConversationServiceTests.swift`。
- 新建轻量测试入口：`tools/test-living-resident-loop.swift`；需编译执行真实生产逻辑，不能只有字符串检查。
- 新建结果记录：`docs/plans/evidence/2026-09-05-living-resident-loop.md`。

**步骤：**

1. 写出“同一会话、多轮、失败、取消后再发”的测试；用替代进程输出模拟外部服务，只验证应用协议和状态。
2. 运行轻量测试，保存预期失败；如果现有行为已满足则只记录通过，不人为制造生产缺陷。
3. 用已有提供方选择和会话保存结构表达统一状态；错误状态不能显示为已连接，取消后旧结果不能覆盖新消息。
4. 重跑测试和既有 AgentConversationService 测试的可无宿主执行部分；注明未执行的宿主测试。
5. 审查并提交独立改动，不与语音或动作功能混在一起。

运行：`/usr/bin/nice -n 15 swift tools/test-living-resident-loop.swift`。预期：状态与会话测试通过，无真实模型请求。

## 任务 2：把当前空间信息交给会话

**文件：**

- 修改：`apps/macos/Sources/GMGNRadio/Agent/WorldAgentContext.swift`。
- 修改：`apps/macos/Sources/GMGNRadio/Agent/AgentConversationService.swift`。
- 必要时新增小型格式化器：`apps/macos/Sources/GMGNRadio/Agent/ResidentWorldContext.swift`。
- 测试入口：`tools/test-living-resident-loop.swift`。

**步骤：**

1. 加入失败测试：当前世界 ID、居民位置、活动状态、点唱机和可用操作能进入模型输入；切换世界后不携带旧活动清单。
2. 执行测试确认断点，不使用真实供应商请求验证字符串。
3. 从 WorldAgentContext 和正式世界清单生成精简描述；物件描述先覆盖已声明的点唱机，接口留出编号和状态，不从 SPZ 自动猜所有家具。
4. 验证没有密钥、本地账户目录和无关历史进入上下文；上下文随动作结果更新，不能只在会话首次打开时生成。
5. 回归、审查并提交。此时只验收“知道这里有什么”，不宣布已经能行动。

验收输入：“你现在在哪里？这里能做什么？”预期答案受当前清单约束，不把其他模板的设施当成当前房间物件。

## 任务 3：将一种提供方接到真实世界工具

**文件：**

- 修改：`apps/macos/Sources/GMGNRadio/Agent/AgentConversationService.swift`。
- 复用：`apps/macos/Sources/GMGNRadio/Agent/WorldAgentToolContract.swift`。
- 复用：`apps/macos/Sources/GMGNRadio/Agent/WorldAgentToolDispatcher.swift`。
- 复用、必要时抽出接线：`apps/macos/Sources/GMGNRadio/Agent/DJAgentToolDispatcher.swift`。
- 测试入口：`tools/test-living-resident-loop.swift`。

**步骤：**

1. 先用只读工具验证所选后端实际支持的工具传输方式。优先复用已有工具协议；具体命令参数须查当前已安装版本，不能沿用猜测参数。
2. 写失败测试：结构化请求含请求编号、当前世界和动作参数；调用只进入现有分发器；工具结果返回发起会话。
3. 实现最小桥接，第一批仅允许查看世界、列活动、开始活动和停止活动。工具通道未支持的后端明确降为只读聊天，不从普通自然语言回答中抽取命令执行。
4. 覆盖重复请求、不存在的活动、旧世界请求、取消、超时和执行失败；这些检查服务于真实执行，不新建游戏规则层。
5. 完成一次获授权的真实模型只读调用，再完成开始／停止活动调用；本地模拟通过与真实后端通过分别记录。

放行条件：日志能关联用户请求、工具请求、正式活动和实际结果；通用代码执行权限不因访问一个房间被授予。

必须另查后端进程自身的启动权限、工作目录和内置文件／命令工具。应用只暴露四个世界工具，并不能限制 CLI 自带的其他能力。真实验收包括：空间内容尝试要求读个人文件或执行系统命令时，不获得额外权限。用户另行明确授权的编码会话与居民空间会话区分管理。

## 任务 4：完成“去放首歌”的行动结果链

**文件：**

- 修改接线：`apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift:2280`，`performLivingCabinJukeboxEffect` 负责实际播放和结果回传。
- 复用：`apps/macos/Sources/GMGNRadio/App/LivingWorldBootstrap.swift` 中点唱机配置和效果去重结构。
- 复用：`apps/macos/Sources/GMGNRadio/Agent/WorldAgentContext.swift` 的活动阶段。
- 测试：`tools/test-living-resident-loop.swift`、`authoring/worlds/marble-living-cabin/probe-agent-interaction.swift`。

**步骤：**

1. 加入失败测试：“已接受”不能显示为播放成功；实际播放失败能返回会话；重复结果不触发第二次播放。
2. 执行测试，定位状态传递中缺失的环节。
3. 将接近、进入、操作结果与回答接通；继续调用原播放器，不新建播放服务。取消时终止相关活动，不能稍后补播旧请求。
4. 先运行 `/usr/bin/nice -n 15 swift test --package-path apps/macos/Packages/WorldRuntime --jobs 1` 生成当前版本对象文件，再运行 `/usr/bin/nice -n 15 swift authoring/worlds/marble-living-cabin/probe-agent-interaction.swift`；预期能走到设备并进入循环。探针依赖前者的编译产物，此测试本身不证明真实音乐已经发声。
5. 获授权后人工验收有曲目、无曲目、音乐账号失效和中途取消；结果写入验收记录再提交。

本任务完成即交付第一个可试玩增量，先请用户体验，不等全部语音提供方完成。

## 任务 5：让语音输入共用同一个会话

**文件：**

- 修改：`apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift` 的麦克风入口和转写处理。
- 检查并复用可拆分部分：`apps/macos/Sources/GMGNRadio/VoiceSession/RealtimeDJSessionController.swift`。
- 必要时新增：`apps/macos/Sources/GMGNRadio/Agent/ResidentSpeechInput.swift`。
- 测试入口：`tools/test-living-resident-loop.swift`。

**步骤：**

1. 编码前确认选定转写服务能只识别语音、不自行生成另一套回复；先支持一种服务，权限申请在用户点击麦克风后触发。
2. 写失败测试：最终转写只提交一次，与文字入口使用同一会话；中间转写、取消和空文本不发送。
3. 接入统一输入函数，显示录音、转写和 Agent 思考的不同状态。保留旧实时 DJ 的其他用途时给清晰独立入口，居民麦克风不能同时驱动两个 Agent。
4. 用模拟转写跑测试，再经用户同意实际说一句话，随后用文字追问；验证上下文连续。
5. 检查拒绝麦克风权限、转写断网和取消后恢复，提交独立改动。

## 任务 6：统一回答、TTS、口型与打断

**文件：**

- 修改：`apps/macos/Sources/GMGNRadio/Agent/AgentSpeech.swift`。
- 修改接线：`apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift`。
- 检查并复用：`apps/macos/Sources/GMGNRadio/Presence/StageAvatarRuntime.swift`。
- 设置入口：`apps/macos/Sources/GMGNRadio/Settings/AgentSettingsView.swift`、`AgentSettingsModel.swift`。
- 测试：`apps/macos/Tests/GMGNRadioTests/Agent/AgentSpeechTests.swift`、`tools/test-living-resident-loop.swift`。

**步骤：**

1. 写失败测试：一条回答只显示一次、朗读一次；TTS 失败保留文本；新输入可停止旧朗读；关闭声音不影响思考。
2. 跑测试确认失败，区分朗读状态与实时麦克风会话状态。
3. 先使系统 TTS 完整可用，再加一种可选云端 TTS；沿用角色现有嘴型／说话状态输入，结束、取消、失败时都恢复。没有音素输入时明确使用近似口型，不声称精准同步。
4. 将居民提示词、思考后端、转写、TTS 分开保存和展示；换声线不换会话，换后端明确是否开启新会话。
5. 验证开关、说话打断、静音回复和口型结束，记录实际音画体验后提交。

## 任务 7：逐个提供方验收并交付阶段 1

**文件：**

- 实现与测试沿用任务 1—6 的相关文件。
- 记录：`docs/plans/evidence/2026-09-05-living-resident-loop.md`。

按 Codex、Claude Code、dsh、WorkBuddy、Qoder、pi 逐个填写下表；顺序可随用户当前账户可用性调整，禁止一次并发启动六个真实模型。

| 后端 | 文字与续聊 | 世界工具 | 取消／失败 | 语音共用会话 | 验收版本和证据 |
| --- | --- | --- | --- | --- | --- |
| Codex | 待验收 | 待实现／验收 | 待验收 | 待实现／验收 | 待填写 |
| Claude Code | 待验收 | 待实现／验收 | 待验收 | 待实现／验收 | 待填写 |
| dsh | 待验收；当前内存六条历史 | 待实现／验收 | 待验收 | 待实现／验收 | 待填写 |
| WorkBuddy | 待验收 | 待实现／验收 | 待验收 | 待实现／验收 | 待填写 |
| Qoder | 待验收 | 待实现／验收 | 待验收 | 待实现／验收 | 待填写 |
| pi | 待验收 | 待实现／验收 | 待验收 | 待实现／验收 | 待填写 |

所有真实调用记录耗时、用量（服务支持时）与失败类型，不记录密钥或完整私人会话。不可用的服务留为明确缺口，不阻止已经验收的提供方交付试玩，但不能把六种都标成完整支持。

## 每个交付增量的回归

按顺序运行，避免多个重型任务并发：

```sh
/usr/bin/nice -n 15 swift tools/test-living-resident-loop.swift
/usr/bin/nice -n 15 swift tools/test-camera-elevation.swift
/usr/bin/nice -n 15 swift tools/test-space-presentation.swift
/usr/bin/nice -n 15 swift tools/test-stage-control-panels.swift
/usr/bin/nice -n 15 swift tools/test-stage-control-actions.swift
/usr/bin/nice -n 15 swift test --package-path apps/macos/Packages/WorldRuntime --jobs 1
git diff --check
```

预期：所有执行的断言通过；确切测试数量以当次输出为准。新脚本尚未创建时属于待实施步骤，不能报告已通过。

必要的完整应用构建使用：

```sh
/usr/bin/nice -n 15 xcodebuild build \
  -project apps/macos/GMGNRadio.xcodeproj -scheme GMGNRadio \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -jobs 1 CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS='$(inherited) -j1'
```

预期：`BUILD SUCCEEDED`。不运行 Xcode 宿主测试；构建不等于实际模型、播放和画面验收。用户授权安装时仅替换 `/Applications/gmgn radio.app`，旧包可恢复，并核对安装产物与构建一致。

## 阶段结束条件

用户亲自完成：说话或打字询问房间 → 要求放歌 → 看见走路与操作 → 听见或看见结果 → 叫停 → 追问刚才的经历。模型、工具、播放器和角色表现指向同一次真实过程。

通过后进入阶段 2：接通自主活动选择、补充少量日常物件、保存活动经历。暂不启动新房间、市场或多人开发。

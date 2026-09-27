# 许愿机从交图到摆放的完整交付计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 用户给居民一张图片和一句要求，居民生成道具、去托盘领取、按委托摆放；用户能移动、旋转、收回，保存后重新进入仍保持一致。

**Architecture:** 沿用同一个居民循环、DGX 生成服务、许愿机协调器和物件摆放服务。先补图片传输、跨异步委托和完整验收三个断点，已有模型加载器及编辑器优先复用。界面与居民使用同一份物件状态和提交规则。

**Tech Stack:** Swift、AppKit、SwiftUI、Metal、WorldRuntime、DSH 原生视觉输入、Codex、DGX Comfy、GLB。

日期：2026-09-06。状态：已开始执行，完整流程尚未通过。Claude 实际编码会话负责任务 1，DSH 实际编码会话负责任务 2 和任务 5，主代理负责公共接线、服务检测及整合。本文收敛近期交付顺序；总产品路线及远期设想继续保留，不能据单项通过记录将本流程标为完成。

### 本轮进展

- 任务 3 部分完成：使用现存本机配置只读检测，生成服务返回 `api_ready`、`generation.ready=true`；此次未提交生成任务，未重启服务。
- 设置增加“检测连接”，区分保存配置和实际生成就绪。检测使用已保存地址与密钥，五秒超时；修改配置或收起设置后丢弃迟到结果，不将密钥转发到尚未保存的地址。
- 验证：生成客户端 52 项、配置 19 项、实际设置回调 9 项通过；设置及其依赖独立类型检查通过。任务恢复沿用原实现；连接管理、任务 3 整体放行和新的完整生成验证仍待完成。
- 2026-09-07 最终新包已安装至 `/Applications/gmgn radio.app`，签名及安装字节核对通过；没有启动宿主。真实窗口体验与模型自主完成整条流程均未标记通过。
- 2026-09-07：跨轮图片主机接线与固定同任务连续测试通过，覆盖真实 GLB 绘制、Marble 碰撞导航抵达、领取、原委托后台摆放、旋转、JSON 重载，以及世界已提交但许愿完成标记漏写的恢复。生成接口使用历史录制响应，尚未完成新的 DSH 图文生成。详见 `docs/plans/evidence/2026-09-07-wish-delivery-integration-progress.md`。
- 同日后续：DSH 原生真实看图、无图追问与同一会话只读工具通过，最终专项 90／57／17 项通过；另只提交一次真实新咖啡机生成，正式导航、领取、后台有限摆放、旋转和重载全部通过。后者是脚本驱动正式工具，尚未与模型制作决策及完成事件续办合为一次自主居民验收。下一批优先补这一条串联，不新增第二次生成来替代原任务验证。

## 一、先交付这一段能玩的流程

固定一个生活舱、一名居民、一个许愿托盘、两处可靠支持面。

```text
上传／粘贴图片，说明“做一个 42 厘米高的摆件，完成后放到展示台上”
  → 居民实际收到图片，理解描述
  → 调用生成工具，立即返回可查询任务
  → 生成期间可以继续聊天或生活
  → 同一任务完成，真实 GLB 出现在托盘上方
  → 原居民收到完成事件，走到托盘领取
  → 同一物件进入物件库，依照原委托摆在展示台
  → 用户打开“摆放”，移动、左转／右转、确认或取消
  → 保存，再加载，物件身份、位置、方向和尺寸一致
```

首件采用已有自制咖啡机参考图作对照，验证复杂带贴图道具；另做一次真实新生成，不能只反复展示缓存模型。生成的咖啡机先是装饰道具，不承诺能煮咖啡。新生成只提交一次，超时先查原任务，不能重复收费。

这批暂不做：CAD 拆装、任意房间自由装修、通用手持、战斗、更多角色、网页商城、支付、RL、新引擎迁移。现有有限手持保留但不扩展。下载与 Story 录制排在完整摆放流程之后。

## 二、已经查实的断点

| 位置 | 当前代码事实 | 本批要解决什么 |
| --- | --- | --- |
| DSH 图文入口 | `AgentConversationService.validateImageSupport` 只接受 Codex；App 在附件登记前拒绝 DSH 图片 | 真正传入图像内容，不能只移除拒绝检查 |
| DSH 模型与传输 | 本机 DSH 源码及编译产物已有原生视觉模型；gmgn 调用的 headless 入口只创建文本消息 | 选择视觉模型并接通结构化图文入口，两项分别验证 |
| 图片多轮确认 | 生成授权依赖本轮图片；后续单独说“按刚才那张做”没有授权 | 保留会话附件引用，制作授权来自当前明确委托；看图不自动生成 |
| 异步摆放 | 完成事件是后台轮；App 对后台固定禁用布局修改 | 保存只针对本次产物的有限摆放委托，完成后可续办 |
| 服务到客户端 | 有真实生成、下载和模型离屏证据；连接使用过临时隧道 | 检查实际连接、任务恢复及重连；服务在线不能仅凭历史记录判断 |
| 领取与显示 | 已有托盘、GPU 完成门限、真实到达检查、幂等领取与库存同步 | 将这些步骤与同一真实模型委托连续执行，并串联证据 |
| 手工编辑 | 已有列表选择、地面／展示台、45°旋转、10 厘米微调、指针选点、保存、收回和一次撤销 | 验证对真实领取物件有效；补可发现入口和最新布局画面的验收 |
| 直接拖放 | 目前要先选清单、按“移动”；并无房内点选物件后拖动、松手落下 | 基础交付先保留可靠的点选落位；直接拖放单列下一增量 |

历史服务探针 `tools/probe-wish-machine-service.swift` 直接调用协调器提交，且不执行领取。这只能证明生成服务及下载；不能替代“聊天 → 模型工具 → 领取 → 摆放”的验证。

## 三、DeepSeek 视觉模型的配置结论

官方当前 API 图片模型为 `deepseek-v4-flash-vision-exp`，支持文本和图片。接口为 `https://api.deepseek.com`，图片须以实际图像内容块传入。模型支持图片与当前账号可成功调用仍须分别验证。[DeepSeek 官方视觉文档](https://api-docs.deepseek.com/guides/vision/)

本机 DSH 已有 `deepseek-official` 路由，且原生目录将该模型声明为 `inputModalities: [text, image]`；无需先安装社区看图桥接插件。配置语义如下，实施时通过 DSH 正式设置接口保存，不覆盖整个配置文件：

```yaml
agent-default-model:
  provider: deepseek-official
  model: deepseek-v4-flash-vision-exp
```

注意：这是默认模型配置示意，不是“改完即可让 gmgn 看图”的承诺。模型目录若被用户自定义列表覆盖，需要保留其他条目并补齐该模型的图片能力。优先为 gmgn 的居民会话设置模型，不擅自改变用户其他 DSH 会话；若仅能修改全局默认，明确记录影响后再实施。本轮没有修改设置。

原生集成采用 DSH 官方 ACP 图文输入。已核对本机源码与编译产物：`session/prompt` 支持 `{type: "image", mimeType: "image/png", data: "<base64>"}`，经过模型能力校验后存为正式附件。当前 `headless` 只接受任务文本，不能把图片路径或 base64 拼成普通提示词冒充图片。

本机可用的 ACP 入口是 `packages/examples/acp-demo/lib/bin.js`，支持 `--config` 指定组合；它不等同于 `dsh --profile headless`。实施时必须创建专用受限组合，明确挂载附件存储与视觉模型，并重新核验允许组件。默认 demo 含命令工具，不能直接采用；现有 headless 的 23 项配置核验也不能原样宣称覆盖另一套组合。

模型仍通过 gmgn 正式工具改变世界，ACP 负责会话与图文运输。不为看图恢复 Bash、任意文件读取或网络工具。不静默换成其他模型，不另建一名视觉聊天居民。

依据：

- `/Users/ghostcorn/dev/deepseek-harness/packages/llm/llm-deepseek/src/index.ts`
- `/Users/ghostcorn/dev/deepseek-harness/packages/llm/llm-deepseek/lib/index.js`
- `/Users/ghostcorn/dev/deepseek-harness/packages/llm/llm-deepseek/src/serialize.ts`
- `/Users/ghostcorn/dev/deepseek-harness/packages/core/agent-default-model/src/index.ts`
- `/Users/ghostcorn/dev/deepseek-harness/packages/bundle/headless/src/index.ts`
- `/Users/ghostcorn/dev/deepseek-harness/packages/examples/acp-demo/lib/bin.js`
- `/Users/ghostcorn/dev/deepseek-harness/packages/acp/acp/src/content.ts`
- `/Users/ghostcorn/dev/deepseek-harness/packages/acp/acp/lib/index.js`

模型看图和附件交给生成服务仍应分开表达。纯文字模型可以按用户清楚的描述转交授权附件，但不得声称已看懂图片；这是后续兼容方式，不替代本批 DSH 原生视觉目标。

## 四、交付顺序与任务

路径均以 `/Users/ghostcorn/dev/gmgnradio` 为根。以下是执行清单，均未因写入计划而视为完成。每项先加失败用例，再改最少代码，跑相关回归；每个交付门通过后只提交明确属于该门的改动，禁止把当前脏工作树整体提交。

### 任务 1：打通 DSH 原生图片输入

**修改：**`apps/macos/Sources/GMGNRadio/Agent/AgentConversationService.swift`、`apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift`。

**新增：**`apps/macos/Sources/GMGNRadio/Agent/ResidentDSHTransport.swift`、`apps/macos/Sources/GMGNRadio/Agent/ResidentDSHConfiguration.swift`，负责原生 ACP 传输与受限组合；不创建第二套居民循环。

**测试：**`tools/test-resident-image-transport.swift`、`tools/test-resident-dsh-world-loop.swift`；新增 `tools/probe-resident-dsh-vision.swift`。

1. 加用例：DSH 收到真实图片块及文本，取消不送出迟到内容；文本模型不能宣称看图。
2. 为官方 ACP 入口组装受限配置，建立组件白名单测试；默认 demo 工具必须排除。握手须报告 `promptCapabilities.image`，且当前选中模型声明图片输入；缺任一项即报告配置不满足，不静默丢图。
3. 保留图片原始身份，通过正式附件层发送，后续工具结果不能丢失图片上下文。
4. 执行 `nice -n 15 swift tools/test-resident-image-transport.swift` 和 `nice -n 15 swift tools/test-resident-dsh-world-loop.swift`，要求全部通过且保留旧拒绝／不丢图断言的语义。
5. 在不继承终端凭证的环境中用两张不同的自有测试图验证实际视觉识别；答案须对应图片中未写进提示词的内容。再执行一次只读空间工具，证明看图和工具调用可以在同一会话衔接。

**放行条件：**已有模型能力、选中模型、实际图片输入和真实看图回执同时成立。只改模型下拉框不放行。

### 任务 2：让图片与制作委托跨轮保留

**修改：**`apps/macos/Sources/GMGNRadio/Presence/ResidentImageAttachment.swift`、`apps/macos/Sources/GMGNRadio/Presence/WishMachineCoordinator.swift`、`apps/macos/Sources/GMGNRadio/Agent/ResidentWishMachineTools.swift`、`apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift`。

**测试：**`tools/test-resident-image-attachments.swift`、`tools/test-wish-machine-coordinator.swift`、`tools/test-living-resident-loop.swift`。

1. 加失败用例：“交图询问 → 用户补充尺寸并确认制作”仍能引用同一附件；单纯看图不产生任务。
2. 将附件引用限定到原会话／居民／空间，不让模型传任意本地文件路径。
3. 当前人类制作指令产生一次生成授权；有明确尺寸与用途时直接提交，无需重复确认。
4. 发送失败保留图片及草稿；重试沿用同一个提交标识；图片确实失效才要求重新提供。
5. 执行上述三个脚本，核对重复调用只生成一件，取消不会扩大旧授权。

**放行条件：**用户可以先讨论，再说“做这个”，不会因图片不在本轮而卡住。

### 任务 3：生成服务与任务状态可恢复

**修改：**`apps/macos/Sources/GMGNRadio/Presence/PropGenerationClient.swift`、`PropGenerationStore.swift`、`PropGenerationConfiguration.swift`、`apps/macos/Sources/GMGNRadio/Settings/PropGenerationSettingsSection.swift`。服务确有问题时才修改 `tools/assets/prop_service.py` 和其部署文件。

**测试：**`tools/test-prop-generation-client.swift`、`tools/test-prop-generation-configuration.swift`、`tools/assets/test_prop_service.py`。

1. 加断开连接、提交结果不明、重连恢复和重新加载任务的用例。
2. 检查既有 DGX 地址与连接方式；显示“未连接／排队／生成／下载／待领取／失败”的真实状态。服务返回什么就显示什么，不伪造百分比。
3. 连接恢复后先查询已存任务。临时隧道改为可管理连接时使用项目专用配置，不修改用户其他服务或全局端口。
4. UI 展示可处理的失败原因；凭证留在本机受限权限存储，不进入聊天、截图和诊断包。
5. 跑客户端测试；只有修改了远端服务才追加 `python3 -m pytest tools/assets/test_prop_service.py`。真实验证阶段只提交一件新物件，资源繁忙则等待或报告，不停止其他 GPU 任务。

**放行条件：**关闭面板、网络断开和进程重建都不会丢失已受理任务或重复提交。

### 任务 4：托盘显示、完成通知、走近领取成为同一条流程

**修改：**`apps/macos/Sources/GMGNRadio/Presence/WishMachineScene.swift`、`WishMachineCoordinator.swift`、`WishMachineOutputRenderer.swift`、`apps/macos/Sources/GMGNRadio/Agent/ResidentWishMachineTools.swift`、`apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift`。

**测试：**`tools/test-wish-machine-app-runtime.swift`、`tools/test-wish-machine-world.swift`、`tools/test-wish-machine-output-gpu.swift`；新增 `tools/test-wish-machine-delivery-loop.swift`。

1. 用固定真实 GLB 加失败用例：仅下载完成不能触发领取；同一模型实际绘制完成才产生可领取事件。
2. 使用现有正式工具查询活动、到达领取点和登记领取，不在测试中直接写“已到达”。
3. 检查原居民收到事件后继续行动，途中仍能接受用户中断；被暂停时物件留在托盘。
4. 领取后核对同一 `objectID` 入库、托盘展示移除，无复制和丢失；重复通知不重复领。
5. 运行现有三个测试及新增循环测试。输出含托盘、抵达、领取后三个阶段的真实渲染帧及对应状态，明确它们来自无宿主验收程序。

**放行条件：**同一任务、同一文件、同一物件从生成回执连到领取回执，不能拼接无关测试证明完成。

### 任务 5：居民能够完成“做好后放到桌上”的原委托

**修改：**`apps/macos/Sources/GMGNRadio/Presence/WishMachineCoordinator.swift`、`apps/macos/Sources/GMGNRadio/Agent/ResidentPropToolBridge.swift`、`apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift`；必要时扩展 `Presence/ResidentPropPlacementService.swift` 的授权入参。

**测试：**`tools/test-resident-prop-tools.swift`、`tools/test-wish-machine-coordinator.swift`、`tools/test-wish-machine-delivery-loop.swift`。

1. 加失败用例：人类授权生成并摆放，后台完成轮可以只摆本次产物；无委托的后台轮仍拒绝改布局。
2. 在原任务记录有限委托：原授权、世界、居民、物件、允许支持面，以及用户明确指定的位置／朝向。生成请求成功后才能绑定实际物件身份。
3. 完成轮通过现有查询、预检和提交工具执行；不能借此移动其他物件、收回或撤销其他操作。放不下时尝试该委托允许范围内的其他落点；仍无合法点则留在库中并简短说明。
4. 使用稳定请求标识和绝对位置／朝向防止重试累加；记录完成结果。停止撤销未完成委托，重新启动或切换空间不自动恢复已撤销的委托。
5. 跑测试，覆盖重复事件、保存后崩溃再恢复、用户中断、版本冲突、无合法位置和跨世界拒绝。

**放行条件：**完成生成后不用用户再说一遍“去领取、摆上去”；居民也不能获得无限制装修权限。

### 任务 6：交付简单可发现的移动、旋转、放置操作

**修改：**`apps/macos/Sources/GMGNRadio/VisualEngine/ResidentPropEditorView.swift`、`StageWindowController.swift`、`apps/macos/Sources/GMGNRadio/Presence/ResidentPropEditorState.swift`、`ResidentPropRenderer.swift`。

**测试：**`tools/test-resident-prop-editor.swift`、`tools/test-resident-prop-editor-loop.swift`、`tools/test-resident-prop-render-gpu.swift`、`tools/test-resident-prop-surfaces.swift`。

1. 加界面用例：右下角“摆放”展开，领取到的物件立即出现在清单，空列表能指向许愿机状态。
2. 第一版明确操作：选物件 → 选地面／展示台 → 移动指针预览 → 左转／右转 45° → 确认；取消恢复旧位置。先复用已有操作，不强行加入三轴专业工具。
3. 镜头滚轮继续缩放，不兼任物件旋转；编辑与聊天有焦点时不透传 WASD；面板能收起。
4. 确认后显示“已保存”，失败时保留预览与具体原因；收回和一次撤销可见。把实际帧与最新布局版本关联，避免旧帧冒充新的移动结果。
5. 跑四个测试，至少覆盖旋转前后投影改变、碰撞同步、取消不落盘、保存中 Esc、清单和房间同一物件身份。仅调用状态函数的测试不能记作完整鼠标操作验收。

**放行条件：**真实生成物件可移动和旋转，保存重建后的世界变换一致，画面也对应相同版本。

下一增量才做房内点选拾取、按住拖动、松手放下，以及连续旋转环；单独增加命中检测和真实事件测试，不与本批生成阻塞交织。

### 任务 7：完整验收包与最终安装

**新增：**`tools/probe-wish-machine-delivery.swift`、`docs/plans/evidence/2026-09-06-wish-machine-complete-delivery.md`。

1. 先用固定真实产物完成自动循环验证，再让同一入口接一次真实 DSH 看图和 DGX 新生成。新探针必须经过生产提交入口及模型工具，不复用绕过聊天的旧探针作为完成证明。
2. 产出一份回执，关联：`submissionID → wishID → remoteJobID → GLB SHA256 → objectID → layoutRevision → frame`。记录每个真实结果及失败原因，不记录密钥和私人聊天。
3. 录下或导出验收程序自身渲染的连续画面：托盘出现、居民抵达、领取、摆放、旋转、重载。禁止截图用户桌面冒充自动验收。离屏帧要清楚标识来源。
4. 重新创建世界上下文并读存档，断言物件数量不增加、位置和朝向一致、托盘不残留已领物件。额外覆盖暂停、断连、重放完成通知和不支持图片模型。
5. 全部自动门通过后单路低优先级构建，只替换 `/Applications/gmgn radio.app`；核对签名和产物哈希。未经当前明确授权不启动／退出宿主，不操作系统权限。

**自动放行条件：**一件真实新生成物件从输入到保存读回连续通过，并有可看的帧序列。用户不必坐在电脑前帮忙逐项点测。

**最终体验验收边界：**现阶段没有自动操作真实宿主的授权。无宿主／离屏验证可完成上述技术交付，但真实窗口的完整鼠标手感及入口切换仍需授权后的独立宿主验收；不能把这部分写成通过，也不把用户当前无法点测作为停止其余工作的理由。

## 五、分工与推进纪律

- 主代理：居民流程、跨异步委托、证据串联、最终整合。
- 图片代理：DSH 原生模型选择和图文传输，仅拥有会话传输相关文件。
- 服务代理：DGX 任务连接、恢复、输入输出校验，不修改居民界面。
- 编辑代理：清单、移动旋转、渲染与存档一致性，不改生成授权。
- 审查代理：独立检查一次委托、暂停和重复事件；检查测试有没有绕过真实入口。

`GMGNRadioApp.swift` 由主代理统一合并接线，避免多个代理同时改。并行审计和独立实现可以进行，整包构建单路执行。每次更新只报告“完成哪个交付门、证据在哪里、哪一步未过”，不累计测试条数包装进度。

## 六、后续顺序

本流程通过 → 直接拖放与更顺手的旋转 → 有限手持和设备能力绑定 → 录制／下载分享 → 更多动作与可进入空间 → 网页和素材经营。原来的长期方向保留，当前不再扩展支线。

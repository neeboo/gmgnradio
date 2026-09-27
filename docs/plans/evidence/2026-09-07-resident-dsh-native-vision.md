# 居民 DSH 原生视觉验证回执

时间：2026-09-07（Asia/Shanghai）。生产文件已冻结；未启动宿主、未操作钥匙串、未修改 deepseek-harness 或全局模型配置。

## 真实实现来源

主体由真实 Claude 持久会话实现，调用方式：

```text
acpx --cwd /Users/ghostcorn/dev/gmgnradio --approve-all --format text --timeout 1800 claude -s wish-vision-20260906 <任务正文>
```

- acpx 会话名称：`wish-vision-20260906`
- acpx record：`549f89d7-c3c2-4d6a-a092-8161cc9de55b`
- Claude ACP session：`db45a374-8c36-47f1-a445-fcc5928afa4a`
- 适配器：`@agentclientprotocol/claude-agent-acp@^0.36.1`
- 会话报告模型：`opus`

Claude 实现配置、传输、服务接线、专项测试和探针主体。主代理补充 prompt 返回时保留互斥标记直至 defer 的整合修复。经主代理授权，操作员最后直接整合：包查找路径分量严格递减、固定源码安装四包路径与 package.json.name 验证、根目录失败测试、探针传入实际 entry 创建 sandbox，以及零模型握手模式。没有冒充 Claude 执行者。

## 最终文件

- `apps/macos/Sources/GMGNRadio/Agent/ResidentDSHConfiguration.swift`（新增）
- `apps/macos/Sources/GMGNRadio/Agent/ResidentDSHTransport.swift`（新增）
- `apps/macos/Sources/GMGNRadio/Agent/AgentConversationService.swift`（修改）
- `tools/test-resident-image-transport.swift`（修改）
- `tools/test-resident-dsh-world-loop.swift`（修改）
- `tools/test-resident-dsh-transport.swift`（新增）
- `tools/probe-resident-dsh-vision.swift`（新增）

App 入口、项目文件及其他业务文件由主代理或其他执行者负责，不计入此子任务实现归属。

## 最终专项命令与实际退出码

以下三个命令均直接取进程退出码，没有用输出过滤管道的退出码代替：

```text
nice -n 15 /opt/homebrew/bin/gtimeout 120 swift tools/test-resident-image-transport.swift
PASS: 90 resident image routing checks
exit=0

nice -n 15 /opt/homebrew/bin/gtimeout 120 swift tools/test-resident-dsh-world-loop.swift
PASS: 57 DSH world-loop checks, 0 failures
exit=0

nice -n 15 /opt/homebrew/bin/gtimeout 120 swift tools/test-resident-dsh-transport.swift
PASS: 17 resident DSH transport checks
exit=0

nice -n 15 /opt/homebrew/bin/gtimeout 240 swift tools/probe-resident-dsh-vision.swift --compile-only
PROBE_BINARY: /tmp/gmgn-dsh-vision-probe
compile-only: runtime disabled; run the binary above when the real-model lane opens
exit=0
```

图文专项有测试用的无异步 await 警告；最终探针编译没有错误或警告。17 项传输专项包含真实本地替身子进程的阻塞 stdin、有界取消、宽限取消后同会话复用、跨会话迟到块、同一 stdout 写入中 response 后迟到块、重叠 prompt 拒绝。

## 官方无模型握手

```text
nice -n 15 /opt/homebrew/bin/gtimeout 25 /tmp/gmgn-dsh-vision-probe --handshake-only
== probe-resident-dsh-vision ==
fixture: probe 自有 fixture 空间（probe-fixture-cabin），不代表真实宿主运行
config: read-back/whitelist/model-lock PASS (official loader validation follows at boot)
env: child environment is allowlist-scrubbed; the key is only read by credentials-local
PASS: official initialize image=true; session/new=3ce439a1-ac0c-49bd-9447-91651d483a40; zero prompts
exit=0
```

实际配置落盘后读回校验；原官方入口成功加载四个限制后的插件。另直接调用官方 llm-deepseek Config 与 attachment-local default.Config 验证相应配置，ACP Config 由主代理独立验证。配置保持 workspaceContext/toolBash/toolJobs/goals=false、skills.enabled=false；图片模型固定为 deepseek-v4-flash-vision-exp。仅将四个允许包链接到私有 sandbox，未链接整个依赖目录。

## 真实模型探针原始输出

命令：`nice -n 15 /opt/homebrew/bin/gtimeout 1300 /tmp/gmgn-dsh-vision-probe`

```text
== probe-resident-dsh-vision ==
fixture: probe 自有 fixture 空间（probe-fixture-cabin），不代表真实宿主运行
config: read-back/whitelist/model-lock PASS (official loader validation follows at boot)
env: child environment is allowlist-scrubbed; the key is only read by credentials-local
image A sha256 a3533caf537b6328… (expect 1 red square)
image B sha256 b83c4508ee1040d7… (expect 3 blue circles)
turn1 reply: 这张图片里有一个红色的正方形，背景是白色。具体来说：颜色是红色（正方形）和白色（背景）；形状是正方形；数量是1个红色正方形。
turn2 reply: 刚才第一张图里有一个红色的正方形，背景是白色。颜色是红色（正方形）和白色（背景）；形状是正方形；数量是1个红色正方形。
turn3 reply: 这张新的图片里有3个蓝色的圆形，背景是白色。
turn4 reply: 当前空间有两个可前往地点：一个是“窗边”，另一个是“展示架”。
== RECEIPT ==
result: PASS
model: deepseek-v4-flash-vision-exp @ deepseek-official
handshake: image=true (advertised at initialize, enforced by the production image gate)
transport: production ResidentDSHConnector through a transparent recording wrapper; probe-dedicated sandbox (the service default connector-factory path is not exercised by this probe)
session_id: e454e3ac-e704-409b-ac20-cb7c0a7bd833
wire_requests: 5, human_turns: 4, image_counts: [1, 0, 1, 0, 0], all on session_id above
config_sha256: c0752f5541bb8bfbbcb4051158a0aa4fcfdc688aa76436ff0cf153b5d40e0cbf
image_a_sha256: a3533caf537b63282f37902d8479085966a4d46688f9f6eacd6e40f2ee7db114
image_b_sha256: b83c4508ee1040d73587dfea44e9c74ab4ec2305d1d254c3c23c749960c93292
session_continuity: no-image recall passed and the space tool turn ran in the same real session
tool_calls: ["list_places"]
fixture: probe-owned space probe-fixture-cabin; not a real host run
env: child scrubbed of terminal credentials; key only via credentials-local; never printed
elapsed_seconds: 9
exit=0
```

两张图片由 CoreGraphics/ImageIO 在本次探针内生成，提示不泄漏颜色、形状、数量。图片以原生 ACP image 内容块发送。实际调用的只读空间工具为 list_places；没有调用生成、导航或宿主工具。

## 失败证据与覆盖边界

- 首次真实探针在握手前 connectionClosed；脱敏诊断明确官方 loader 从临时配置目录解析四包时 ERR_MODULE_NOT_FOUND。这是实际运行失败，修复私有四包链接后官方握手和真实图片均通过。
- 新增缺包测试曾暴露 URL 向上遍历无根终止；自有测试 PID 76803 单核忙循环，短栈位于 locateInstalledPackage，样本保留在 `/tmp/gmgn-dsh-boot-diagnostic.SAzlrM/test-76803.sample.txt`。核验身份后仅终止该测试。现改为路径分量严格递减，缺包/根目录测试在外层硬超时下通过。
- 更早两次挂起的直接原因是测试替身第二轮 gate 未释放，不能当作生产取消实测失败。生产同步写与取消缺口源自独立源码审查，随后由真实替身子进程专项验证。
- 实际模型使用生产 ResidentDSHConnector，但通过透明记录包装器，工作目录显式固定为探针已创建的专用 sandbox。服务默认工厂路径仅有生产源码接线、专项及编译证据，未声称其已随宿主实测。
- 只读空间为探针自有 fixture，未启动真实宿主。因此本回执证明原生图片、真实视觉模型、连续会话与只读空间工具回路，不证明宿主 UI/运行状态。
- 子进程与图片/配置临时 sandbox 已按探针正常退出清理；未输出或保存凭证。

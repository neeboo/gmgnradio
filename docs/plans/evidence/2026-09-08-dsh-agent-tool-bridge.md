# 居民 DSH Agent 协议修复 · 真实原生宿主工具链实现与离线组装验证（2026-09-08）

当前状态：共享服务接线已由 DSH 实际应用，原生工具装配已进入
`AgentConversationService`。下文第三轮的独占文件、未应用补丁等记录保留为历史，
不代表当前集成状态。

## 最终集成回归（主代理复核，2026-09-08）

- `swift tools/test-resident-dsh-world-loop.swift`：112 checks、0 failures；
  其中调用真实安装 DSH 的离线推理优先级验证另报 21 cases PASS。
- `swift tools/test-resident-dsh-tool-channel.swift`：15 checks、0 failures。
  读取本次生成的私有授权文件，确认原生注册名称恰好等于本轮声明的 15 个 `gmgn_` 工具。
- `bash tools/test-resident-dsh-service-native-assembly.sh`：37 checks、0 failures、
  exit 0；真实 Service + ACP runtime + 回环 mock，捕获 8 次请求。
- `swift tools/test-agent-conversation-memory-service.swift`：79 checks、0 failures。
- 最终 `xcodebuild build-for-testing`：exit 0，应用、正式测试目标及 Rust helper
  编译通过，禁用签名；没有执行测试宿主。编译前后 Sources + Tests 内容摘要一致：
  `979b99645c8d4aae3ecdb6bb19164003ec72b980e31d25acb4d25e66d556f007`。

两份旧测试已更新到当前协议：普通模型正文原样返回，正文里的工具 JSON 不执行，
不再依赖文本信封解析或格式纠正重启。保留安全配置拒绝、私有文件防篡改、错误脱敏、
历史、取消及真实子进程超时恢复断言；显式注入的旧连接器兼容测试单独标识，
不将其当作真实 ACP 验证。

本轮回归先检出两条静默结束失败：`validateDSHExecution` 在检查
`allowsSilentCompletion` 之前无条件拒绝空输出。DSH 已作最小修复：仅工具回合
传入实时静默许可；无工具空回复仍拒绝，非零退出仍分类报错。原失败断言保留并通过。

验证未启动 App、测试宿主或语音，未触碰真实用户数据库；组装测试只使用本地 mock。
不据此宣称真实模型搜图、许愿生成、空间动作或声音已经完成运行验收。

---

## 1. 协作边界与本轮独占交付

并行协作：Swift DSH(PID 32283/记忆 72121) 独占 AgentConversationService.swift /
GMGNRadioApp.swift / AgentSpeech.swift / ResidentConversationMemory.swift / 工程文件及
相应 tests/scripts（记忆接线，其进行中改动全部保留）；Rust DSH(PID 33261) 独占
services/gmgn-taskd。本轮**未修改上述任何文件**（git 中它们的 M/?? 状态来自 owner 自身
改动），未 stash/reset/checkout/commit/push，未终止任何进程，不改 Speech。

| 文件 | 动作 |
| --- | --- |
| `apps/macos/Sources/GMGNRadio/Agent/ResidentDSHHostToolsBridge.swift` | 修改（独占）：Swift6 数据竞争修复、执行前取消竞态修复（MainActor 边界重核验同一授权代/secret）、有界生命周期（poll accept、单连接线程、SO_RCVTIMEO/SNDTIMEO、stop 唤醒、并发上限）、启动失败回收、跨轮可重绑定 handler 容器 |
| `apps/macos/Sources/GMGNRadio/Agent/ResidentDSHConfiguration.swift` | 修改（本轮获准）：ACP composition 支持私有 gmgn-host-tools 插件行（发射 + 读回校验），签名兼容（默认参数） |
| `apps/macos/Sources/GMGNRadio/Agent/ResidentDSHTransport.swift` | 修改（本轮获准）：`environmentOverrides` / `stderrFileURL` 测试口（默认空/nil，生产环境面不变） |
| `tools/resident-dsh-host-tools-support.swift` | 修改：客户端 SO_NOSIGPIPE |
| `tools/test-resident-dsh-host-channel.swift` | 修改：编译门改为真实 `-swift-version 6` 编译并运行；新增 C13–C17 竞态/生命周期/绑定回归（79→89 checks） |
| `tools/resident-dsh-acp-mock.mjs` | 新增：真实 ACP 组装用的内容驱动本地 mock provider（仅 loopback） |
| `tools/test-resident-dsh-acp-native-assembly.swift` | 新增：真实 ACP runtime 组装 harness（同会话多轮 + revoke + cancel + re-arm） |
| `tools/test-resident-dsh-acp-native-assembly.sh` | 新增：一键 ACP 组装验证 |
| `docs/plans/evidence/2026-09-08-dsh-agent-tool-bridge.md` | 本文档 |
| `/tmp/gmgn-acs-snapshot3.swift` | 共享文件快照（只读，补丁基座，2026-09-08 13:01 取） |
| `/tmp/gmgn-acs-headless-integrated.swift` | 快照 + 拟定改动的完整副本（不进仓库；headless+ACP 全部拟改已含） |
| `/tmp/gmgn-dsh-agent-protocol-integration-20260908.patch` | 独立集成补丁（**未应用**；dry-run/实应用通过；结果文件与集成副本逐字节一致；集成文件经 `swiftc -swift-version 6 -parse-as-library` 全依赖编译 exit 0） |
| `/tmp/gmgn-dsh-agent-protocol-integration-20260908.patch.previous-worker-v1` | 上一轮补丁备份 |

未做：不启动 App/test-host/真实语音/窗口探测；不调用真实模型（mock 只回环）；不接触真实
用户 DB / 凭据 / 钥匙串；只监听 127.0.0.1 与私有 UDS；无 commit/push/部署；不全 App
build / 不 cargo build / 不改 deepseek-harness 仓库与全局 DSH 配置。

## 2. 事故复述与第一轮被拒原因（保留）

2026-09-08 12:12–12:13 用户：「你能去搜索个月光大剑吗，然后去许愿机生成」。两次 DSH
均被宿主「整串必须是单一 JSON 信封」解析拒绝、格式纠正重启后仍未执行空间工具
（`trusted_tool_transcript` 为空）。

第一轮修正方向被主代理拒绝的原因：把工具执行退化成「等 typed 事件」+ 占位 = 空间能力
退化；只做宿主语义机而无真实注册 = 无调用者状态机；误推「DSH 不支持宿主工具」。

## 3. 真实 DSH 原生工具注册能力核验（保留，补 ACP 实测）

- `deepseek-harness/docs/cookbook/adding-a-tool.zh.md`：工具以插件在 DSH 进程内
  `ctx.tools.register(defineTool({...}))` 注册；`packages/mcp/mcp-client/src/tools.ts`
  syncTools 同源；`--patch` insert / 普通 composition 行两种挂载形态。
- headless 通道：`packages/bundle/headless` 一次性通道原生 Function Calling（tools mode
  native），工具结果在同一运行内 role=tool 回灌后到 final（§6 实测）。
- **ACP 通道（本轮实测）**：`packages/examples/acp-demo`（`@deepseek-ai/dsh-acp-demo`）
  经 `--config` 加载 composition 行，DSH agent spine 在 `session/prompt` 里原生执行
  `ctx.tools` 工具并回灌同一会话，直到 `end_turn`（§10 实测；DSH ACP 服务器在
  session/cancel 时对挂起的 prompt 返回 stopReason `cancelled`，宿主侧以
  CancellationError 呈现）。

## 4. 实现：ResidentDSHHostToolsBridge.swift（真实原生宿主工具通道）

模块自包含（Foundation + Darwin）；复用 Bridge 的 `ResidentDSHOriginalSchemaValidator`
与 registry/分类语义。

- `ResidentDSHHostToolSet.parse`：fail-closed 解析 schemasJSON → gmgn_ 注册集。
- `ResidentDSHHostToolsChannel.start(configuration:)`：短名私有目录（0700）、插件与
  grant（0600）、UDS 监听；`arm(worldRevision:)` 每轮换 secret、`revoke()` 删 grant 关
  闸、`stop()` 清理（幂等）；敏感凭据只存内存与 0600 私有文件。
- 真实 JS 插件（内嵌源码）：ACP/headless composition 里 `ctx.tools.register` 原生注册
  gmgn_*；execute 每调重读 grant（state != armed → 拒绝）；私有 UDS+本轮 secret 回宿主；
  图片回执经 attachments 准入（MCP tools.ts 同款投影），无法准入退化为诊断文本。
- 宿主分类：secret → 名称边界 → 原 schema 复核 → 授权闸 → handler → 规范 JSON 回写。

### 4.1 第三轮修复一：Swift6 严格并发编译失败（主代理真实复现）

主代理命令（真实门，默认 Swift5 / 仅 `-typecheck` 不能替代）：

```text
swiftc -swift-version 6 -parse-as-library \
  apps/macos/Sources/GMGNRadio/Agent/ResidentDSHAgentToolBridge.swift \
  apps/macos/Sources/GMGNRadio/Agent/ResidentDSHHostToolsBridge.swift \
  tools/resident-dsh-host-tools-support.swift \
  /tmp/gmgn-host-tool-revoke-race-20260908.swift -o /tmp/gmgn-host-tool-revoke-race-20260908
```

修复前错误：`ResidentDSHHostToolsBridge.swift:709: sending 'reply' risks causing data
races` —— 旧 `authorizeAndExecute` 把 `var reply` 捕获进 `Task { @MainActor }` 闭包写、
socket 线程 semaphore 后读，属于未同步共享。

修复：结果经**锁 + 信号量配对的 `HostExecutionBox`** 回传（内存访问全部在箱内锁与
信号量下；投递/等待由信号量配对，stop/超时后迟到投递被 finished 守卫丢弃），不再把
`var` 直接捕获进 @Sendable 任务闭包。修复后该命令零 error（§7 逐字输出）。上一轮 evidence
「swift6 strict-concurrency typecheck exit=0」按真实命令更正为本节命令。

### 4.2 第三轮修复二：执行前取消竞态（主代理独立复现 exit1）

主代理只读测试 `/tmp/gmgn-host-tool-revoke-race-20260908.swift`（断言不可改）：请求已
通过分类并排队到 MainActor 后 `revoke()`，随后旧请求仍执行 handler（`calls.count == 1`）。

根因：旧实现把「分类时校验 secret」当作执行许可；revoke 发生在分类之后、MainActor 真正
调用 handler 之前时，排队的 handler 任务照常执行。

修复：授权以「调用时」快照为准 —— 分类只抓 `(authorizationEpoch, secret)` 快照；**真正
调用 handler 的 MainActor 边界（`executeOnMainActor`）用同一把锁重新核验该快照仍等于
当前 (epoch, secret)**。`arm()`/`revoke()`/`stop()` 都推进 epoch：
- revoke 后轮到执行的排队请求 → 拒绝（0 次 handler）；
- revoke 后马上 re-arm（新代/新 secret）→ 旧请求依然无法借新授权通过（epoch 不匹配）；
- 已越过复核、副作用已开始的执行不被 revoke 中断（完成并回执）—— 取消只作用于「尚未
  开始副作用」的排队请求；预执行取消保证 0 次 handler。

修复后主代理测试连续多轮 exit 0（§7）。

### 4.3 第三轮修复三：通道资源生命周期有界回收

- accept 循环由 `poll(fd, POLLIN, 200ms)` 驱动；`stop()` 只置 stopped + 对已登记客户端
  fd `shutdown(SHUT_RDWR)`（在同一把锁内 shutdown，规避 fd 复用竞态），accept 线程最迟
  一个心跳自行 close 监听 fd 退出 —— 监听 fd 从创建到关闭单线程所有，无跨线程 close 与
  poll/accept 竞态；
- 每个已接受连接由独立线程处理（并发上限 4，`DispatchSemaphore` 控制；超出立即关闭，
  不无界排队）：单个慢/挂死客户端只占自己的线程，绝不堵死 accept 或其它调用；
- 连接读/写各有 SO_RCVTIMEO/SO_SNDTIMEO（30s）上界，peer 不读不写也不能永久占用线程；
  客户端 fd 设 SO_NOSIGPIPE（peer 提前关闭不杀进程）；
- 等 MainActor 的 handler 有 `handlerExecutionTimeout`（120s，与 JS 插件 rpc deadline
  对齐）上界且每 50ms 检查 stopped —— stop() 后有界唤醒等待中的排队调用；
- 启动中途失败（arm 抛错）也 stop() 通道，不留强引用。

### 4.4 跨轮可重绑定 handler（ACP 持久会话）

`ResidentDSHHostToolsBinding`：通道 `Configuration.handler` 只委托到该容器一次
（`channelHandler()`）；每轮 arm() 前 `bind(...)` 本轮 worldTools 调用包装，结束/取消
`clear()`。通道永不闭包捕获第一轮已取消的 tools；未绑定/已 clear 时返回规范工具错误
（handler_unbound），绝不执行旧轮 handler。

## 5. ResidentDSHConfiguration / ResidentDSHTransport 的 ACP 原生装配支持

- `residentYAML(... hostToolsPluginPath: String? = nil)` 与
  `makeResidentSandbox(... hostToolsPluginPath: String? = nil)`：带插件时在 composition
  末尾发射普通行 `- id: gmgn-host-tools` + `name: '<插件绝对路径>'`（无 config；grant 由
  插件按 import.meta.url 同目录解析），否则输出与旧版逐字节一致（签名兼容，既有调用点
  不变）。
- `validateComposedConfig(_ output:, hostToolsPluginPath: String? = nil)`：无插件时要求
  不含该行（计数不变）；带插件时要求恰好一行、name 精确等于插件路径、无 config/嵌套/
  models；篡改（改名、加 config、加第二行、未请求带行）一律 false。生产 `declaresImageInput`
  语义不变。
- 挂载链：插件是绝对 .mjs 文件，不进入 node_modules @deepseek-ai 链接集；mounted 集合
  不变。
- `ResidentDSHTransport.swift`：ACP 子进程环境保持严格 allowlist；新增默认关闭的
  `environmentOverrides`（离线测试把 DEEPSEEK_BASE_URL/KEY 与私有 DSH_HOME 指到
  loopback mock，生产不传则行为不变）与 `stderrFileURL`（默认 nil，诊断落盘）。同一会话
  与真实 turn 完成语义（session/prompt → end_turn、session/cancel → cancelled）原样保留。

## 6. 离线验证命令与退出码（headless）

```text
# 1) 纯 Swift 通道回归（生产源文件真实编译运行；无 DSH/无网络/无模型）
swift tools/test-resident-dsh-host-channel.swift
PASS: 89 resident DSH host-tools channel checks, 0 failures
swift6 (-swift-version 6) compile+run exit=0

# 2) headless 组装验证（真实 dsh + 受限 overlay + 本地 mock provider + 宿主 IPC 全链）
bash tools/test-resident-dsh-native-assembly.sh
[1/3] PASS: 89 ... checks, 0 failures        swift6 compile+run exit=0
[3/3] mock provider ready: http://127.0.0.1:xxxxx
  [evidence] 模型请求里的工具列表: gmgn_read_wish_generation, gmgn_submit_wish_generation, web_search
PASS: 12 resident DSH native-assembly checks, 0 failures
assembly(native) exit=0
ASSEMBLY EXIT=0
```

通道单元覆盖（C1…）：清单解析 fail-closed；armed→合法调用（宿主执行一次、canonical 名
正确）；错误 secret/未知工具/剥前缀/web 原生名 → 拒绝且零执行；缺必需/未声明属性 →
invalid_arguments 零执行；schema 无法核验 → schema_unsupported 零执行；工具领域错误与
成功分开；revoke → 拒绝且 grant 删除；re-arm 轮换 secret → 旧 secret 拒绝、新 secret 生效；
图片回执（真实 PNG base64）；stop 清理与幂等；overlay 行无 config、插件/grant/目录权限
0700/0600。

## 7. 第三轮验收：Swift6 零 error + 独立竞态回归

```text
$ swiftc -swift-version 6 -parse-as-library \
    apps/macos/Sources/GMGNRadio/Agent/ResidentDSHAgentToolBridge.swift \
    apps/macos/Sources/GMGNRadio/Agent/ResidentDSHHostToolsBridge.swift \
    tools/resident-dsh-host-tools-support.swift \
    /tmp/gmgn-host-tool-revoke-race-20260908.swift \
    -o /tmp/gmgn-host-tool-revoke-race-20260908
(零输出，exit 0)

$ /tmp/gmgn-host-tool-revoke-race-20260908        # 连续 5 轮
PASS: revocation prevents queued handler execution   （每轮 exit 0）
```

新增确定性回归（`tools/test-resident-dsh-host-channel.swift` C13–C17，全部 @MainActor
同步占住/信号量确定序，非忙等猜时序）：
- C13 revoke 后排队调用零执行且客户端收到 grant_revoked（主代理场景复刻）；
- C14 revoke 后立即 re-arm：旧排队调用零执行、不借新授权；本轮新 secret 调用成功一次；
- C15a 执行中请求的取消语义：已越过复核的 handler 完成并回执、revoke 后新请求拒绝；
- C15b stop() 有界唤醒等待中的排队调用（客户端限时返回 EOF、零执行、arm 抛 notStarted、
  新连接无回复）；
- C16 三个挂死客户端不堵死正常调用；并发超限连接被快速关闭、有界返回、恢复后可用；
- C17 跨轮绑定容器：未绑定→tool_error 零调用；绑定一轮执行一轮；revoke+re-arm 换绑定后
  旧轮 handler 不被调用；clear 后零调用。

## 8. 真实离线 ACP 组装验证（本轮交付，非 headless 形态/非单元 fake）

运行真实安装 DSH ACP runtime（`@deepseek-ai/dsh-acp-demo` 的 ACP 入口
`--config` 指向生产 `ResidentDSHComposition.makeResidentSandbox(... hostToolsPluginPath:)`
产出的 composition）+ 内容驱动本地 mock provider（`tools/resident-dsh-acp-mock.mjs`，
只监听 127.0.0.1）+ 生产 `ResidentDSHConnector` 驱动，同 ACP 会话连续多轮：

```text
$ bash tools/test-resident-dsh-acp-native-assembly.sh
== [1/2] 真实 DSH ACP runtime + mock provider（原生宿主工具链，同会话多轮）==
mock provider ready: http://127.0.0.1:xxxxx
PASS: 24 resident DSH ACP native-assembly checks, 0 failures
assembly(acp) exit=0
ACP ASSEMBLY EXIT=0        （连续 3 轮均 PASS）
```

场景与断言（真实 ACP 进程 + 真实插件 + 真实宿主 IPC）：
- composition 含 gmgn-host-tools 私有行且指向真实插件路径、通过生产读回校验；
- ACP 会话建立（服务端声明 image prompt 能力，原生图片通道保留）；
- R1（armed）原生工具调用：宿主执行恰好一次 read_wish_generation，模型请求里工具列表
  = [gmgn_read_wish_generation, gmgn_submit_wish_generation, web_fetch, web_search]，
  出现 role=tool 消息且内容为宿主规范值（{"ok":true,"running":false,...}），同运行继续到
  普通 final（end_turn 文本）；
- R2（revoke 后）同一会话再发：模型仍发起原生调用但插件/授权已撤销 → 宿主零执行，会话
  仍正常结束到普通 final —— 撤销后旧授权调用零执行；
- cancel 轮（mock 对带 gmgn 工具的首个请求只开流不回写 + ACP session/cancel）：
  prompt 以 CancellationError 结束、取消轮零宿主执行、settle 后同会话连接仍可用；
- R3（重新 arm 新代/新 secret）同一会话：宿主再次执行一次并到普通 final（新轮可用、
  同 sessionID 连续两轮原生工具结果回同会话）；
- 安全 overlay：请求工具列表无 bash/write/edit/read/grep/glob/run_code 等本地工具。

图片原生回执：宿主通道 C10 已覆盖真实 PNG base64 回执；插件 attachments 准入代码与
finalizeContent 投影保留（MCP 同款）。真实 ACP 组装的本地 mock provider 不驱动图片工具
结果（纯文本/工具链），因此 ACP 图片回执分支本轮未实测 —— 如实报告，不作为已完成。

## 9. 共享文件集成补丁（未应用）

`/tmp/gmgn-dsh-agent-protocol-integration-20260908.patch`（基座 =
`/tmp/gmgn-acs-snapshot3.swift`，13:01 快照；对基座 dry-run/实应用通过，结果文件与
`/tmp/gmgn-acs-headless-integrated.swift` 逐字节一致；集成文件连同 Agent 目录相关生产
文件一起 `swiftc -swift-version 6 -parse-as-library` 编译 exit 0）。改动分两部分：

**A. headless 世界工具轮（第一轮方案重新修齐）**：调用点补 `scope: runtimeScope`；
`sendViaDSHWithTools` 全量改单次 `dsh --profile headless --patch`（宿主通道 + 插件
insert；无信封循环/格式纠正重启；旧 parse/envelope 结构保留未引用便于回退）；
`prepareDSHRestrictedPatch(extraRows:)` 与验证函数增加 hostPluginURL 认证。

**B. ACP 持久会话原生工具轮（本轮新增）**：`acquireDSHImageRuntime(scope:worldTools:)`
在真实 runtime 创建时按需建宿主通道 + 跨轮绑定容器并嵌入 composition 插件行；
`sendViaDSHNative` 世界工具分支改走 `runDSHNativeToolTurn`（每轮 bind → arm → 普通文字
prompt 单次 → revoke + clear；工具调用由 runtime 原生执行并回灌同会话）；`closeDSHImageRuntime`
stop 通道 + clear 绑定；工具装载与 runtime 不一致时先等取消 settle 再销毁重建；注入式
连接器保留既有受信回送语义（测试专用，不冒充 ACP 交付）。

集成前置：AgentConversationService.swift 若被 owner 继续修改需以最终文件重建 hunks；
四个 ResidentDSH*.swift 桥文件纳入 Xcode target（xcodegen/工程属 owner）。

## 10. 诚实边界与剩余项

1. **共享集成（待 owner 结束后主代理安排）**：应用 `/tmp/gmgn-dsh-agent-protocol-
   integration-20260908.patch` 到最终 AgentConversationService.swift（必要时重建
   hunks）；xcodegen 收录桥文件；编译回归 + 三条离线回归（host-channel / headless
   native-assembly / ACP native-assembly）。
2. **共享文件在途**：记忆 DSH(PID72121) 仍在改 AgentConversationService.swift 与其记忆
   类型（ResidentStateScope / ResidentMemorySource 等）；因此 `tools/test-resident-image-
   transport.swift`、`tools/test-resident-dsh-transport.swift` 等把共享 AgentConversation-
   Service.swift 纳入编译集的测试驱动，当前会因 owner 在途 API（其类型分散在记忆 DSH 未
   纳入该驱动编译集的文件中）编译失败 —— 失败点与本次两个桥文件的改动无关；本轮对
   Configuration/Transport 的改动已在独立编译集（含 stubs 或全部相关生产文件）下
   `-swift-version 6` 验证 exit 0。集成时由 owner 收口这些驱动。
3. **图片回执**：真实 ACP 组装未驱动 mock 图片分支（见 §8），如实报告；插件与宿主
   通道的图片路径在单元层保留覆盖。
4. 授权边界：未开发新空间能力；web 仍只读；无日志/UserDefaults 泄露敏感能力；未新增
   常驻 daemon/通用网络框架。

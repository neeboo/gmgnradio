# 居民 DSH「真实 AgentConversationService 原生 ACP 层」装配验证（2026-09-08）

状态：**PASS（收窄复核 37 checks、0 failures、exit 0；此前基线连续 5 轮 exit 0）**。
真实 `AgentConversationService.send`（backend `.dsh`、独立 UserDefaults suite、
`visionCapable=true` 的 `ResidentConversationTools` 强制原生 ACP）+ 真实安装的 acp-demo
ACP runtime + 本地内容驱动 mock provider（只监听 127.0.0.1）同 scope 两轮原生工具调用：
37 checks、0 failures、`SERVICE NATIVE ASSEMBLY EXIT=0`。

协作边界：只新增以下文件，未修改任何生产源码 / 工程 / Rust / 其它测试，未触碰他人
独占文件（`test-resident-dsh-world-loop.swift`、`test-resident-dsh-tool-channel.swift`
只读参考），无 commit / push、不调用其它代理。

| 文件 | 动作 |
| --- | --- |
| `tools/test-resident-dsh-service-native-assembly.swift` | 新增：driver（复用 conversation-memory-service 的完整生产编译列表） |
| `tools/test-resident-dsh-service-native-assembly.sh` | 新增：一键启动（mock + env-shim 入口 + 私有 DSH_HOME + 有界回收） |
| `docs/plans/evidence/2026-09-08-dsh-service-native-assembly.md` | 本文档 |

复用：`tools/test-agent-conversation-memory-service.swift` 的**完整生产编译文件列表**
（已补齐两个 bridge + 记忆依赖）与 `ResidentWorldContext` 构造；`tools/test-resident-dsh-acp-
native-assembly.swift/.sh` 与 `tools/resident-dsh-acp-mock.mjs` 的真实 runtime 启动 / 假
凭据 / 本地 BASE_URL / 控制文件逻辑。未重复造 headless 第二套，未做图片全场景。

## 1. 环境机制：为什么需要一个 env-shim 入口（诚实说明）

Service 的 `acquireDSHImageRuntime` 创建生产 `ResidentDSHConnector` 时**不传
`environmentOverrides`**（`AgentConversationService.swift` 内唯一构造点，约 L1262），而
connector 的子进程环境是严格 allowlist（`ResidentDSHTransport.residentEnvironment`，仅
HOME/TMPDIR/LANG/LC_ALL/USER/LOGNAME + 固定 PATH），`DEEPSEEK_BASE_URL` /
`DEEPSEEK_API_KEY` / `DSH_HOME` 不会进入 ACP 子进程（harness 进程内断言该事实，与
`probe-resident-dsh-vision.swift` Gate 2 同源）。connector 级离线测试（ACP native-assembly
24 checks）能指到 mock，是因为它直接构造 connector 并显式传 `environmentOverrides`；这条
路在 **Service 层不存在**。

因此启动脚本通过既有发现 seam `GMGN_DSH_ACP_ENTRY` 指向一个**测试专用 env-shim 入口**
（脚本在临时锚点目录生成 `lib/bin.mjs`）：它只设置 loopback mock 的
`DEEPSEEK_BASE_URL=<mock>/v1`、`DEEPSEEK_API_KEY=mock-key`、全新私有
`DSH_HOME=<tmp>/private-dsh-home`，然后 `await import` **真实** acp-demo `bin.js`。node
仍为 `command -v node` 的真实路径；runtime / composition / gmgn-host-tools 插件 / 宿主
UDS 通道全部是生产代码；锚点目录只对真实安装的 8 个挂载包做只读软链（供
`makeResidentSandbox` 的入口祖先解析）。shim 不读真实凭据、不写真实 DSH_HOME；allowlist
本身仍被进程内断言验证。这是本 harness 在不改生产代码前提下把「假 key + 127.0.0.1
BASE_URL + 临时 DSH_HOME」送进 Service 原生 ACP 子进程的唯一通道。

## 2. 验证命令与真实输出

```text
$ bash tools/test-resident-dsh-service-native-assembly.sh
== 真实 AgentConversationService.send + 真实 DSH ACP runtime + 本地 mock provider（同 scope 两轮）==
mock provider ready: http://127.0.0.1:xxxxx
env-shim entry: …/gmgn-dsh-service-native-assembly-run.XXXXXX/entry/packages/examples/acp-demo/lib/bin.mjs
real acp-demo entry: /Users/ghostcorn/dev/deepseek-harness/packages/examples/acp-demo/lib/bin.js
== test-resident-dsh-service-native-assembly ==
env: node=/Users/ghostcorn/.nvm/versions/node/v25.5.0/bin/node dsh=/Users/ghostcorn/.local/bin/dsh
entry: shim=…/gmgn-dsh-service-native-assembly-run.XXXXXX/entry/packages/examples/acp-demo/lib/bin.mjs
entry: real acp-demo=/Users/ghostcorn/dev/deepseek-harness/packages/examples/acp-demo/lib/bin.js
mock: http://127.0.0.1:xxxxx
r1 reply: GMGN_SERVICE_NATIVE_ASSEMBLY_FINAL_OK
r2 reply: GMGN_SERVICE_NATIVE_ASSEMBLY_FINAL_OK
r3 reply: GMGN_SERVICE_NATIVE_ASSEMBLY_FINAL_OK
S4 cancel result: cancelled
r5 reply: GMGN_SERVICE_NATIVE_ASSEMBLY_FINAL_OK
PASS: 37 resident DSH service native-assembly checks, 0 failures
service-native assembly exit=0
mock(service) 捕获请求数: 8
service-native assembly exit=0
SERVICE NATIVE ASSEMBLY EXIT=0
```

（上方临时锚点路径 / mock 端口按实际输出省略随机串与端口号；复核输出不再有
`session-evidence:` 行 —— 该可选扫描已删除。）

此前基线连续 5 轮（含 1 次 `KEEP_TMP=1`）均 `PASS: 37 … 0 failures`、exit 0；收窄修订
（删除可选 sandbox 扫描、exit 前显式清理本测试自建 UserDefaults suite）后复核一轮仍为
上方输出：37 checks、0 failures、exit 0（复核时不再出现 `session-evidence:` 行）。

## 3. 场景与断言（真实 Service + 真实 ACP 持久会话 + 真实插件 + mock）

每轮 `service.send(text, worldContext: 同一 cabin, worldTools: 本轮新 tools 实例)`；正式
工具 = `read_wish_generation`（canonical schema 与 `ResidentDSHHostSupportSchema.read`
同形，DSH 侧暴露为 `gmgn_read_wish_generation`）；实例 handler 只计数并回规范假 JSON
（`{"ok":true,"running":false,"wish_id":null,"scope":"world.cabin","instance":…}`），绝不
触碰真实空间。

- **S1（armed，实例 A）**：mock 原生 function call → 插件 execute → 宿主执行 A 恰好一次 →
  role=tool 结果回同轮 → 普通 final。断言：reply 含
  `GMGN_SERVICE_NATIVE_ASSEMBLY_FINAL_OK`；A=1；总执行 1。
- **S2（同 scope，新实例 B）**：同一 ACP 会话第二轮；断言：B=1、A 仍=1（A 不再执行）、
  执行序列 `[A, B]`（跨轮重绑定：通道 handler 容器每轮 bind 本轮实例，无首轮闭包捕获）。
- **S3（纯文字轮，实例 C）**：mock 直接回普通 final 文本；`{"type":"tool_call",…}`
  片段只放在**用户输入**里（不是 mock 模型输出）；断言：C=0、总执行不变 —— 纯文字
  （含文字里的 JSON 片段）绝不被当作动作执行。诚实边界：本 harness **不测**「模型输出
  JSON 文本信封被当作动作执行」——那是旧文本信封 fixture 的行为，由另一 DSH 测试覆盖；
  此处 mock 只回普通 final，不把本项夸大成已测模型输出 JSON 信封。
- **S4（取消轮，实例 D）**：控制文件切 `stall` → mock 对该请求只开 SSE 不回写；等
  REQUESTS_FILE 出现该 stall 请求后 `service.cancel()`。断言：send 以 cancelled 结束
  （`Service currentCancellationHandler` 先调 `worldTools.cancel` 与
  `connector.cancelActivePrompt()`，`channel.revoke/binding.clear` 在 prompt defer 完成）；
  取消轮零宿主执行、无旧工具副作用。
- **S5（取消后新轮，实例 E）**：控制切回 `tool`；断言：新实例 E=1；A=1,B=1,C=0,D=0；总
  执行序列 `[A, B, E]` —— 取消 settle 后同 scope 新轮可用。
- **同会话/同轮证据（不靠文案猜）**：
  - R2 的 mock 请求消息历史含 R1 用户文字与 R1 的 role=tool 结果（同一 agent session 的
    服务端累积 —— 新会话不会带 R1 历史）。该历史是 Service 每轮发给 provider 的真实
    请求体：Service bootstrap 只把已累积历史拼进请求文本，不会伪造 role=tool，因此
    mock 捕获到的 R1 原生工具结果回显即为已验证的同会话证据；
  - 每轮工具结果以 role=tool 出现在该轮最后 user 之后（同轮回灌，观测次数 ≥2）。
  - 不再扫描 Service sandbox 的持久化 `session.jsonl` 或任何其它临时目录/持久文件：
    `FileManager.temporaryDirectory` 指向系统 `/var/folders`，即使按 creationDate 过滤
    也不能保证只读本测试资源（给 shell 设 TMPDIR 也不改变 Foundation 的该路径），故
    删除该项可选尽力扫描，37 项断言不受影响。
  - 另：allowlist 裁剪断言（DEEPSEEK_*/DSH_HOME/DSH_SNAPSHOT 不进子进程环境）、
    `locateNativeTransport` 经 locator 找到真实 transport、composition 声明图片模型。

### mock 捕获的 8 个请求（wire 摘要，控制值=当次策略）

| # | control | 轮 | 说明 |
| --- | --- | --- | --- |
| 0 | tool | R1 | system+user(R1)；tools=[gmgn_read_wish_generation, web_fetch, web_search] |
| 1 | tool | R1 | +assistant+tool：`{"instance":"A","ok":true,…}`（同轮回灌） |
| 2 | tool | R2 | R1 全历史 + user(R2)（同一持久会话） |
| 3 | tool | R2 | +tool：`{"instance":"B",…}`；A 无再执行 |
| 4 | final | R3 | 纯文字 final；无新 tool 消息 |
| 5 | stall | R4 | 取消轮请求（挂起 → session/cancel） |
| 6 | tool | R5 | 取消后新轮请求 |
| 7 | tool | R5 | +tool：`{"instance":"E",…}` |

## 4. 诚实边界

1. **工具名/实例语义**：每轮 tools 是**同一已注册工具的新实例**（通道/插件注册表在
   runtime 创建时固定 —— 这是生产设计：世界工具集按 world 固定，轮次间只重绑定
   handler）。「tool A → tool B」以实例 A/B 的执行计数证明：A 只在 R1、B 只在 R2、E 只在
   R5，序列 `[A,B,E]`。
2. **取消窗口的「旧调用迟到副作用」子场景**：本 harness 用确定 stall（mock 不发出任何
   tool_call）验证取消轮零执行。若要在「cancelActivePrompt 已发、prompt defer 尚未
   revoke」的窗口内观察旧插件 rpc 是否仍被 armed 通道执行，需要 mock 先发完整 tool_call
   再挂起、且与宿主取消精确对齐 —— 在真实 runtime 上不可确定复现；该子场景如实报告为
   「未观测/未断言」，不在 mock stall 布局里造假。channel 侧的 revoke-race 语义已由他人
   独占文件（host-channel C13–C17）在单元层覆盖。
3. **同 session 证据口径**：只用本测试 mock 的 REQUESTS_FILE（provider 级请求体消息
   历史累积），验证 R2 历史含 R1 用户文字与 R1 的 role=tool 原生工具结果；未新增生产
   接口去读内部 ACP session id。不扫描任何临时目录 / 持久文件（含 Service 自有 sandbox
   的持久化目录），不声称 JSONL 证据。
4. env-shim 入口是本 harness 对「真实 acp-demo 入口」字面的唯一偏离：它**委托**真实
   bin.js（进程内断言 shim 内容含真实入口路径、只含 mock 值、不含真实凭据形态），node /
   composition / 插件 / 宿主通道均为生产代码。若未来获准在 Service 侧把 connector 的
   `environmentOverrides` 透传出来（ResidentDSHTransport 已具备该默认关闭的测试口），
   本 harness 可直接改为真实 bin.js 直连，无需 shim。

## 5. 安全与回收

- 子进程只经 shim 拿到 `mock-key` + `127.0.0.1 BASE_URL/v1` + 全新临时 `DSH_HOME`
  （0700）；不读真实凭据 / 用户 DB / ~/.dsh；无 App / test-host / 语音 / GPU / 钥匙串 /
  security / AppleScript / 窗口；无全 App build / cargo。
- harness 总看门狗 250 s、单轮界 90 s、driver 编译 240 s / 执行 300 s；成功 / 失败 /
  看门狗任一退出路径都先经 `service.resetSession()` 关闭 connector（terminate + SIGKILL
  兜底）并删除 Service sandbox；`printResult()` 的 `exit()` 不执行 defer，故在 exit 前由
  `cleanupService()` 一并显式 `removePersistentDomain` 本测试自建的独立 UserDefaults
  suite 域（只动该自建域，绝不操作未知域；已生成的旧测试域无需全局扫描清理）；.sh
  结束时 TERM→KILL mock、trap 删除临时目录。
- UserDefaults suite 清理口径（复核验证）：域内数据在退出前被清空 —— 复核运行后本机
  只留下 cfprefsd 的空 `{}` 备份文件、**不含任何键**；而修订前基线运行（exit() 绕过
  defer）留下的 6 个旧域文件内含 `agentConversation.backend = dsh` 数据。空 `{}`
  备份文件属 macOS cfprefsd 行为，进程内 UserDefaults API 无法删除（删除后会在进程
  存活期间被重新写回），按协作边界不做全局扫描 / 未知域清理。
- 不扫描全局临时目录 / 持久文件：本测试读取的仅限 .sh 自建 TMP 内的 mock
  REQUESTS_FILE/CONTROL_FILE 与产物；删除对 `FileManager.default.temporaryDirectory`
  下 `gmgn-resident-dsh-*` 的可选扫描（即使按 creationDate 过滤也不能保证只读本测试
  资源）。
- 未改动 deepseek-harness 仓库与全局 DSH 配置。

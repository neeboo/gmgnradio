# 许愿机参数收成一个 agent 能读的接口

日期：2026-10-02　基线：`7a0876a`　需求原话：「许愿机的参数要变成 skill 或者 mcp 让 agent 读吧，
如果尺寸不确定，要让 agent 反馈给用户」

**本文只描述接口与取舍；实现范围与实测见文末 §7。**

---

## 1. MCP 还是 skill：**选 MCP 那一侧，而且不新开服务器 —— 用已有的 `gmgn-host-tools` 挂载点**

| 事实（可核对） | 含义 |
| --- | --- |
| `ResidentDSHConfiguration.swift:92-96`：composition 明确写 `skills: enabled: false`、`tools: mode: native` | 本会话**没有** skill 能力；要用 skill 就得先打开它 |
| `ResidentDSHConfiguration.swift:18-28`、`:176-180`：composition 是**自签白名单**，`mountedPluginPackages` 之外一律不挂，读回逐字节校验 | 加一行 skill/MCP 服务器 = 改安全声明与白名单，是**能力面**变更，不是参数整理 |
| skill 是**磁盘上的静态文本** | 回答不了「这台后端现在收不收 `longest`」，也无法 fail-closed、无法返回结构化 `needs`；它会变成第三份会漂的副本 —— 正是今天出事的形状 |
| `ResidentDSHHostToolsBridge.swift:253-419`：插件在 DSH 进程内 `ctx.tools.register(name, description, parameters)`，模型原生函数调用 → 受限 UDS → 宿主复核 → 回执 | 这**就是** DSH 原生等价于 MCP 的东西：带 JSON Schema 的工具面、按需调用、按调用返回 |
| `ResidentClaudeToolBridge.swift:86,96-100`：Claude 那条路把**同一份**注册集挂成真 MCP（`gmgn-resident-tools` + `--mcp-config`，`--allowedTools` 逐项由注册表推导） | 在这一个接口上定义一次，**两个 runtime 同时拿到**，不新增传输、进程或凭据 |

结论：接口形状按 MCP（被查询的、带 schema 的、按调用返回结构化错误的工具面），挂载点用现成的
`gmgn-host-tools` 私有插件行；**不**打开 skill，**不**新增 MCP 服务器。

## 2. 接口面

新增**一个只读工具** `read_wish_machine_contract`（空参数）。它返回：

```jsonc
{ "ok": true, "contract_version": 1,
  "instruction": "许愿机的参数与尺寸规则只有一处定义：填任何参数之前先调用 read_wish_machine_contract（空参数）读取，不要凭记忆填。",
  "instruction": "许愿机参数只有这一处定义；填之前先读它，不要凭记忆。",
  "size_intent": {
    "required": "size_intent 与旧字段 height_meters 二选一",
    "axes":   [{"id":"longest","title":"最长边","ask":"…","example":"…"},
               {"id":"height","title":"高度","ask":"…","example":"…"}],
    "sources":[{"id":"user","title":"用户原话"},{"id":"suggested","title":"生成服务建议"}],
    "rejected_sources":["default"],           // 「猜的」不被接受
    "min_meters":0.01, "max_meters":3.0,
    "when_unknown": {"code":"insufficient_input","ask":"只问一句，不要猜、不要默认按高度"} },
  "codes": { "insufficient_input":"信息不足，不是错误（成功通道）", "invalid_size_intent":"尺寸畸形", … },
  "service":     {"configured":true,"notice":"…"},
  "capability":  {"readable":false,"axes":[],"min_meters":null,"max_meters":null,"applies":null},
  "local_normalization": {"by":"app","axes":["longest","height"]},
  "open_drafts": [{"pending_id":"…","name":"…","attachment_id":"…","needs":["size"],"attempt":1}] }
```

* `capability.readable == false` ⇒ `axes: []`、`applies: null`：**读不到就不声称支持**（见 §4）。
* `local_normalization.by == "app"`：轴归一是 app 做的（`WorldPropSizePolicy.intended`），
  与「生成服务是否 echo」无关 —— 这两件事不许混成一句。
* `open_drafts` 同时挂进 `read_wish_generation` 的发现回执（那里已经有 `attachments`/`jobs`）。

动作面沿用既有六个工具，只把 `submit_wish_generation` 改成三态，并加一个可选入参：

| 工具 | 变化 |
| --- | --- |
| `submit_wish_generation` | 入参加 `pending_id?`；出参三态之一：`accepted`（含 `size_intent` 回读、`authorization`）／`insufficient_input`（§2.1）／错误 |
| `read_wish_generation` | 不变 + 回执加 `open_drafts` |
| `retry/cancel/claim/resume_wish_continuation` | **本轮不动**（留接口不实现的部分见 §7） |

### 2.1 「信息不足」是一种结构化**成功**返回，不是错误

```jsonc
{ "ok": false, "code": "insufficient_input", "status": "insufficient_input",
  "needs": ["size"],                     // 只缺什么，按优先级排序
  "reason": "unspecified",               // / axis_not_declared / meters_out_of_range / ambiguous_delegation
  "question": "你要的这把剑大约多大？说一个数就行（例如「1 米」或「35 厘米」），我按最长边算。",
  "missing": [ {"field":"size_intent.axis","why":"…","ask":"按哪根轴：…？","choices":["longest","height"]},
               {"field":"size_intent.meters","why":"…","ask":"多少米？","choices":[]} ],
  "options": {"axes":[{"id":"longest","title":"最长边","example":"…"}, …], "min_meters":0.01, "max_meters":3.0},
  "pending_id": "…", "attempt": 1, "ask_again": true,
  "draft": {"pending_id":"…","attachment_id":"…","name":"…"},
  "action": "把 question 这一句问给用户（只问这一句），拿到答案后用同一个 pending_id 再调一次 submit_wish_generation" }
```

`missing[].field` 与工具 schema 路径逐字一致（可直接照着拼补丁），`question` 永远只有**一句**：
结构化给模型、一句话给人。码名 `insufficient_input` 是对齐另一条设计线
（[`2026-10-02-rust-world-authority-and-mcp.md`](2026-10-02-rust-world-authority-and-mcp.md) §6.4/§6.5）
已经写下的词汇 —— 同一个语义在两个面上不许叫两个名字。

为什么必须是 `isError: false`：`ResidentDSHHostToolsBridge.swift:989-999` 把 `isError` 翻成
协议级 `ok:false + error.message`，插件随即 `throw new Error(message)`
（`ResidentDSHHostToolsBridge.swift:391-395`）。走错误通道的话，结构化体只会变成一段异常文本，
"信息不足"就退化成"工具挂了"。**成功通道 + `needs` 字段**才是可被 agent 消费的契约。

## 3. 单一真相：只有这个接口有参数；提示词与 schema 只说「去读它」

要改写/删除的位置（实现后逐一核对）：

| 位置 | 现状 | 改成 |
| --- | --- | --- |
| `Agent/ResidentWishMachineTools.swift:37-46` | `size_intent` schema 里写着轴枚举、米数范围、两个例子 | 一句话指针：参数与规则在 `read_wish_machine_contract`，填之前先读 |
| `Agent/ResidentWishMachineTools.swift:47` | `height_meters` 描述里重复范围与等价关系 | 指针 + 「旧字段」这一条事实 |
| `Agent/ResidentWishMachineTools.swift:58` | `submit_wish_generation` 描述里重复轴/范围/例子/"先问一句" | 指针 + 不重复任何参数事实 |
| `Agent/ResidentWishMachineTools.swift:120-165` | `sizeIntentProblem` 里的 `["longest","height"]`、`0.01...3`、"先问一句" 等字面量 | 全部改由 `WishMachineContract` / `PropSizeIntent` 常量推导，本文件不再出现轴名与米数 |
| `App/GMGNRadioApp.swift:6169` | 提示词里整整一段尺寸规则（轴、范围、例子、"先问一句"） | 一行指针 |
| `docs/plans/2026-10-02-dgx-size-axis-negotiation.md` | 同一套参数的第三份（历史记录，**非** agent 可见） | 顶部加唯一真相指针；历史原文保留（它是 DGX 侧落盘记录，不是活参数文档） |

唯一真相落在 `Agent/WishMachineContract.swift`，而且**不是**新抄一份常量：轴的 id 取自
`PropSizeIntent.Axis.allCases`（该 enum 是字面量的唯一拥有者），米数取自已有的
`PropSizeIntent.minimumMeters/maximumMeters`，来源取自 `PropSizeIntent.Source`。

## 4. 失败与不可用（一律 fail-closed）

| 情形 | 返回 | 纪律 |
| --- | --- | --- |
| 生成服务未配置 | `read_wish_machine_contract` 照常答 `service.configured=false`；提交仍按今天的拒绝 | 只读面永不因后端不可用而消失 |
| 能力**读不到** | `capability.readable=false`、`axes=[]`、`applies=null` | **读不到 ≠ 支持**：不声称、不据此放行；线上键由守护进程按「没声明就不发」处理（字节与今天逐位相同），提交照常、局部归一照常 |
| 轴是契约词但**服务声明不收** | `insufficient_input`（`needs:["size_axis"]` + `unsupported_axis` + `service_declared_axes`） | 不发提交：发了就是 HTTP 400 ⇒ 整件任务失败 |
| 轴**不是**契约词 | 错误 `invalid_size_intent` | 畸形输入 ≠ 信息不足，不伪装成"再问一句" |
| 米数越出**契约**范围（0.01—3） | 错误 `invalid_size_intent` | 与守护进程同一个码、同一条边界；**不夹取、不落默认值** |
| 米数在契约内、但越出**服务声明**的窄范围 | `insufficient_input`（`needs:["size_meters"]` + 服务的真实上下界） | 不发提交（发了就是远端 400） |
| 尺寸全缺 / 缺轴（给了米数没给轴） | `insufficient_input` | 同上 |
| 两个尺寸字段都给 | 错误 `invalid_size_intent` | 两份真相 |
| 草稿的授权已消失/已被消费 | 错误 `delegation_expired` / `delegation_already_submitted`（带 `wish_id`） | 绝不因此新建一次生成 |
| 说不清是哪一件（`pending_id` 与 name/附件对不上） | `insufficient_input`（`needs:["pending_id"]` + `missing[].choices` 列候选） | 不猜是哪一件 |

## 5. 回问用户的路径：一句话，并且**续上同一次委托**

1. 工具返回 `needs:["size"]` + `question` + `pending_id`；宿主同时把这次未完成的提交记成
   **草稿**（`WishMachinePendingDraft`：原授权 `authorityID`、原工具调用 `requestID`、
   `attachment_id`、`name`、`destination`、world/scope、`attempt`），并落盘。
2. agent **只问一句**：问「轴 + 米数」，用自然语言（"大约多长？"），并带上真实上下界；
   不连问五个问题、不替用户挑轴。
3. 用户作答 ⇒ agent 用**同一个 `pending_id`** 再调 `submit_wish_generation`（`draft` 里已给出
   `attachment_id`/`name`，原样回填）。
4. 宿主用**草稿里的** `authorityID` + `requestID` 去 `coordinator.submit`，**不用**本轮新授权：
   `WishMachineCoordinator.swift:466-479` 按 `authorizationID` 幂等 —— 同 `requestID` 直接返回原任务，
   不同 `requestID` 报 `consumedAuthorization`。所以：
   * 只会存在**一个** job；重复提交是重放，不重复生成；
   * 本轮人类消息新开的那份授权**不被消费**（回执里明写 `authorization.reused=true, source=pending_draft`）；
   * 草稿**提交成功之后仍然留着**并记上 `submittedJobID`：同一个 `pending_id` 的第 N 次调用
     先查"这份授权下有没有任务"，有就**回同一个任务**（`authorization.replayed=true`），
     **根本不进 submit**。崩在标记之前也一样查得出（判据是任务本身，不是标记）。
     标记的作用只是让"按名字+图自动续"不再命中已提交的那份 —— 否则用户过一会儿真心
     想再做一件同名同图的，会被误当重放。
5. 已提交的草稿不参与自动命中；只有显式 `pending_id` 才能碰它。对不上号时 fail-closed 要求先选（§4）。
6. `attempt` 累计；已问两轮仍没有尺寸 ⇒ 回执带 `ask_again:false` 与一段指引（改成给选项的
   一句问话，或说明"必须给尺寸才能做"后停下），仍然**绝不**替用户猜。

## 6. 风险

| 风险 | 处理 |
| --- | --- |
| 会话重启 | 草稿随 `wishes.json` 落盘（`Archive` 用可选字段，旧档案照常解码，读到 `nil` 即无草稿）；重启后 `pending_id` 仍有效 |
| 世界切换 | 草稿带 `worldID`/`residentScope`，换世界即不可见、不可续；回执里 `open_drafts` 也只列本 scope |
| 暂停状态 | 草稿只是"未完成的提交"，**不是**自动续办；`auto_continuation_paused` 语义完全不动（仍需本轮人类明确指令才领取） |
| 多件同时待定 | 已提交的草稿不参与自动命中；`pending_id` 与 name/附件对不上时要求先选定（不猜） |
| 重试已完成的续办 | 查"这份授权下有没有任务"⇒ 回同一个 job，**不进 submit**；任意次重试都只有一件产物 |
| 问了两轮还没答 | `attempt` 计数 + `ask_again:false` 指引；24h TTL 之外视作 `delegation_expired`，fail-closed |
| 草稿的授权被别的路径消费 | 检出 `jobs` 里已有该 `authorizationID` ⇒ 报 `delegation_already_submitted` + `wish_id`，不新建生成 |
| 旧 agent 不读接口 | 提示词只剩"去读它"一句，且 `insufficient_input` 自带 `question`/`action`，不读也能照做 |

## 7. 实现范围（本切片）

做：`read_wish_machine_contract`（只读、含能力/草稿）、`submit_wish_generation` 的结构化
`insufficient_input` + `pending_id` 续办、提示词/schema 去重、草稿落盘。

留接口不实现：`cancel/retry/claim/resume` 的行为不变（它们的入参/出参/错误码已在 §2 表里冻结）；
能力探测**不**做实时 `provider_probe`（那要打网络到 DGX，且属另一条线）——本轮
`capability.readable` 恒为 `false`，这正是"读不到 ⇒ 不当成支持"的诚实实现，接上探测只需替换
注入的那个闭包。

---

## 8. 实测（2026-10-02，落盘内容 `fb1a2ce` 的文件状态）

门禁：

```
make build           → ** BUILD SUCCEEDED **   （error: 0 条）
swift tools/test-resident-agent-loop.swift        → PASS: 274 resident loop checks, 0 failures
swift tools/test-wish-machine-coordinator.swift   → PASS: 203 wish machine coordinator checks
swift tools/test-resident-prop-size-intent.swift  → PASS: 73 size-intent checks
make test-harnesses  → EXIT=0 PASS=77 FAIL=0
```

四条断言都用**注入法**实测过能抓缺陷（注入 → FAIL → 还原 → PASS，注入标记已全部清除）：

| 断言 | 注入 | FAIL 原话 |
| --- | --- | --- |
| 尺寸缺失 ⇒ 结构化信息不足、不发提交、不填默认值 | `sizeIntentVerdict` 里把"没说尺寸"改成 `.ok(heightMeters: 0.5, intent: nil)`（落一个默认值） | `FAIL: 信息不足回执没有可用的 pending_id，无法续办（实测 ["auto_continuation_paused": 0, "wish_id": 39D22B73-…, "accepted": 1, "authorization": {…source = "this_turn";}, "object_id": wish-prop-785e448f-…, "size_intent_forwarding": legacy_height_only, … "size_intent": {summary = "未声明尺寸意图：按生成请求高度自动推断"}…]）` |
| 参数只有一处定义 | ①工具 schema 的 axis 描述里塞回 `axis=longest / axis=height` | `FAIL: 工具 schema/文案里**又**存了一份尺寸参数 ["axis=longest", "axis=height"]：参数只允许在 WishMachineContract 一处` |
| 同上（提示词那一半） | ②系统提示里塞回 `axis=longest / axis=height，0.01—3 米` | `FAIL: 系统提示里**又**存了一份尺寸参数 ["axis=longest", "axis=height", "0.01"]：参数只允许在 WishMachineContract 一处` |
| 能力读不到 ⇒ 当作不支持 | `capabilityPayload(.unreadable)` 改成 `readable: true` + `axes: axes.map(\.id)` | `FAIL: 能力读不到时只读接口必须明确 readable=false、axes=[]（读不到 ≠ 支持，实测 ["max_meters": <null>, "min_meters": <null>, "axes": <__NSArrayI 0xbfd01c6a0>(…` |
| 续上同一次委托（幂等、不重复生成、不消耗新授权） | 续办改用**用户回答那一轮**新开的授权与新的 callID 提交 | `FAIL: 续办之后本空间只许有**一件**产物（实测 0 件）` / `FAIL: 产物必须挂在**原来**那一份授权上（实测 nil）` / `FAIL: 回答那一轮的新授权**不许**被消耗` / `FAIL: 任务的 requestID 必须是原委托那一个` / `FAIL: 重复续办必须标成幂等重放` |

顺带修掉一个 harness 自身的缺陷：注入后 `resumedJobs[0]` / `readSubmits(scratch)[baseline]`
会先崩在下标越界上，而 `check` 的 FAIL 是**攒到 finish() 才打印**的 ⇒ 一条 FAIL 都看不到。
已加 `submitRow()` 与 `guard let pendingID`，让缺陷以可读 FAIL 出现（check 数 72 → 73）。

# 本地 Rust 服务做权威 + MCP 面：提案

日期：2026-10-02　状态：**提案，待讨论**（只出设计，不含实现）

触发问题（用户原话）：

> rust 那边能提供 mcp server 吗，是不是能打通啊，现在所有动作啊、物件啊、这些是不是都放在 rust 那边做管理好

随后收敛为：

> 既然已经有 sqlite 了，也有 rust server 了，是不是就让这些的存储都放到后端去做，状态权威都让 rust server 去管，
> 后面我们再做云端备份的，就可以直接 rust 和云端通讯同步了对吧，就像 capcut 一样

又补了一条交互约束：

> 就是事件驱动的情况下再去找 rust 做

以及两个具体域：**消息投递、通知**（它们今天已经暴露出重复投递）。

本文只回答这四件事：**Rust 能不能/该不该**、**权威边界画在哪**、**怎么按域迁过去**、**MCP 面长什么样**。
它**不是**实现补丁，也**不是**"把渲染搬到 Rust"。

---

## 0. 结论摘要（RL；每行一句话）

| 问题 | 结论 |
| --- | --- |
| Rust 侧能不能提供 MCP server？ | **能，而且是低风险的一次纯加法**。仓库里已经有官方的 "写一个 JS 插件 + 私有 UDS + 行分隔 JSON" 的既成做法（`apps/macos/Sources/GMGNRadio/Agent/ResidentDSHHostToolsBridge.swift:245`），MCP 只是把这套私有协议换成公开协议。 |
| 用官方 `rmcp` 还是手写 JSON-RPC？ | **用 `rmcp`**（[docs.rs/rmcp](https://docs.rs/rmcp/latest/rmcp/)，当前 3.5.0，`transport-io` 提供 server 侧 stdio，`auth` 提供 OAuth）。手写只在"不想引依赖"这一条上赢，而我们已经有 11 个直接依赖，多一个官方 SDK 不是风险。 |
| MCP server 是同一个进程还是第二个面？ | **第二个进程、第三个面**。`gmgn-taskd` 保持"每私根独占一把锁"（`services/gmgn-taskd/src/main.rs:47`），**不**在它内部再开一个 MCP 面；新进程 `gmgn-mcpd` 走 **stdio**，由 MCP 客户端（agent 宿主）拉起，它自己再用 UDS 连 `gmgn-taskd`。MCP 进程随时被杀都不影响权威。 |
| Rust 该不该做权威？ | **该，而且这是唯一能兑现"云端同步只写一遍"的形状**。今天权威在 Swift：`gmgn-taskd` 已经有一张能做权威的表（`resident_states` + `resident_events` + `resident_requests`，`services/gmgn-taskd/src/resident.rs:170`），但**没人把它当权威用**——世界状态仍是 `state.json`（`apps/macos/Sources/GMGNRadio/App/LivingWorldBootstrap.swift:363`）。 |
| 交互模型？ | **两条通道，职责分离**：事件通道（Rust→客户端，推送 + 每消费者游标 + 可重放）+ 命令通道（客户端→Rust，只在"意图"发生时调一次）。**渲染路径永不同步 RPC**；"每次变更都要往返"这个悲观假设作废。 |
| 先做哪一步？ | **第一步做"消息投递 + 通知"这一个域**（顺手**删掉**本地直达捷径 `projectLocalWishFacts`，`GMGNRadioApp.swift:6048`），**同时**补上"状态写入也发事件"这一个缺口（今天 `state_commit` 不触发 `changed`，见 §2.10）。两件都是纯收益、可独立回滚。 |
| 判定放哪？ | **判定留在 Swift/Metal，但必须从 Rust 的权威数据派生，且派生结果打上世代号**；Rust 只做**记录、校验、去重、传播**，不重跑几何。理由见 §4.6。 |
| 云同步？ | **只在 Rust 里实现一次**，云端是**副本**。大文件（GLB / 动作包）走**内容寻址 + sha256 引用**，不进 SQLite 行。本地优先：云不可达时本地一切照常。 |
| 最大的代价？ | 每一次**意图**多一次本地往返（毫秒级，可接受）；**订阅不可用时的降级必须显式设计**（§8）。 |

---

## 1. 非目标（先说清楚，防止范围蔓延）

1. **不**改渲染路径。每帧读取的仍是 Swift 内存里的只读投影与派生几何，绝不每帧问后端。
2. **不**搬 Metal / 每帧判定 / 命中测试 / 承托网格的**求解**。搬的是它的**输入**与**结果**。
3. **不**本轮做云同步实现。本轮只定**记录形状**与**冲突策略**，让未来的同步有地方挂（§7）。
4. **不**碰在跑的两条实现线：
   - **"许愿机 MCP/skill 化"**：他负责 agent 侧工具入口的重构；本文只给 **MCP 面的接口与边界**（§6），不写它的实现，也不改 `ResidentWishMachineTools.swift`。
   - **"走姿交接"**：动作域迁移（§5.3）**只迁目录与"当前分配"这一事实**，不碰 walking/locomotion 的求解与交接逻辑。
5. **不**删除任何现有 JSON 文件，直到对应域的"唯一写入方"验证通过并观察满一个周期（§5 每阶段的回滚）。
6. **不**动 `Makefile`，**不**提交 git，**不**碰 DGX。

---

## 2. 现状证据

### 2.1 `gmgn-taskd` 是什么（协议面）

| 事实 | 证据 |
| --- | --- |
| 传输是 **UDS + 每行一个 JSON 对象**，收发帧上限 12 MiB | `services/gmgn-taskd/src/daemon.rs:33`（`Request{id,method,params}`）、`README.md:39` |
| 启动参数固定，root 与 socket 必须在同一私根内 | `services/gmgn-taskd/src/main.rs:13`、`main.rs:38-46` |
| 单实例：私根独占 `flock`，第二实例 `already_running` | `main.rs:47-48` |
| 权限：目录 0700 / 文件与 socket 0600；`umask(0o077)` 在开线程前设 | `main.rs:16-19`、`main.rs:64` |
| SQLite 由**专属存储线程单写** | `README.md:24` |
| 方法面约 21 个，全部在一个 `match` 里 | `daemon.rs:79-401` |

方法清单（`daemon.rs` 行号）：`configure` 79、`snapshot` 95、`submit` 108、`cancel|retry` 114、
`failover` 123、`providers_status` 141、`provider_probe` 166、`publish_message` 184、`ack_message` 209、
`state_read` 235、`state_commit` 251、`event_read` 275、`message_read` 289、`message_ack` 308、
`memory_status` 324、`memory_read` 332、`memory_query` 340、`memory_turn` 350、`memory_pending` 360、
`memory_ingest` 368、`memory_recall` 385。

**结论**：它今天是"任务执行器 + 一个通用 KV（`state_*`）+ 两条消息/事件读取面"。协议的**形状**已经够做权威，
缺的是**权限归属**（谁有权写）与**推送覆盖**（哪些写会发事件）。

### 2.2 通用状态域今天已经具备权威所需的全部机制

| 机制 | 证据 |
| --- | --- |
| scope = `(worldID, residentScope)`，domain ∈ {resident, world, wish, inbox, conversation} | `services/gmgn-taskd/src/resident.rs:40`、`resident.rs:69` |
| 每 (scope,domain,key) 一条记录，带单调递增 **revision** | `resident.rs:170-179` |
| **乐观并发**：`expectedRevision` 不匹配 ⇒ 拒 | `resident.rs:130`（`CommitRequest`）、`daemon.rs:261` |
| **幂等**：`(scope,domain,key,requestID)` 落 `resident_requests` + 内容 hash | `resident.rs:180-190` |
| **追加即事实**的日志：`resident_events(sequence PK, kind, payload)` | `resident.rs:191-201` |
| 每消费者 ack：`resident_message_acks(consumer ∈ world/ui/agent)` | `resident.rs:213-219` |
| 读取窗口：`after + limit(≤?)`，返回 `nextCursor` | `resident.rs:546`（`read_window`）、`event_read`/`message_read` |

> 这就是"事件日志 + 每消费者游标"的**雏形**，已经落库、已经有进程测试。
> 提案要做的是**把更多域搬到这张表上**，不是新建一套。

### 2.3 但权威其实在 Swift

| 事实 | 证据 |
| --- | --- |
| 世界持久状态是 `state.json`（Swift 写） | `apps/macos/Sources/GMGNRadio/App/LivingWorldBootstrap.swift:363`、`:371`、`:383` |
| 内含 **两套 revision**：`revision` + `layoutRevision` | `apps/macos/Packages/WorldRuntime/Sources/WorldRuntime/WorldState.swift:54-55` |
| 摆放回执 `layoutReceipts[requestID] = command`（幂等） | `WorldState.swift:56`、`WorldSimulation.swift:110-112` |
| `expectedLayoutRevision` 不匹配 ⇒ `staleRevision` | `WorldSimulation.swift:114-116` |
| 物件本体被**当成字符串塞进 metadata** | `WorldSimulation.swift:129-133`（key `"gmgn.generated-prop.v1"`） |
| 物件尺寸/来源/碰撞代理/权威尺寸/意图都在这个 blob 里 | `WorldRuntime/.../WorldPropLayout.swift:4-31` |

**结论**：Swift 侧今天有 `layoutRevision` + `layoutReceipts` + `expectedLayoutRevision`，
**和 `gmgn-taskd` 的 `revision` + `resident_requests` + `expectedRevision` 是同一个设计**。
两份同名机制并存而没有主从关系 —— 这是"第二份真相"的结构性来源。

### 2.4 今天的病症（不泛泛而谈）

**(a) 同一事实存多份**

- 授权/许可一次生成这件事，至少有 6 处副本：
  `WishMachineJob.authorizationID`（`Presence/WishMachineCoordinator.swift:13`）、
  `WishPlacementDelegation.authorizationID`（`WishMachineCoordinator.swift:111`）、
  `WishMachineCoordinator.authorizations[]`（`WishMachineCoordinator.swift:258`）、
  agent 循环持有的 `authorizationID`（`Agent/ResidentWishMachineTools.swift:9`）、
  事件载荷 `resumeAuthorizationID`（`WishMachineCoordinator.swift:146`；投递见
  `App/GMGNRadioApp.swift:6000-6001`）、以及 UI 侧读同一布尔的两份投影
  （`VisualEngine/StageOverlayView.swift:232`、`DesktopPresence/LiveCamPanel.swift:294`）。
- 全局"自动续办已停"这一条**授权**，同时存在于 store（`App/GMGNRadioApp.swift:5829` 提到的
  `store.isAutonomyStoppedByUser`）、任务行字段 `autoContinuationStoppedByUser`
  （`WishMachineCoordinator.swift:39`）、每个任务的 `continuationResumeAuthorizationIDs`
  （`WishMachineCoordinator.swift:44`）与两个窗口控制器（`VisualEngine/StageWindowController.swift:380`、
  `DesktopPresence/LiveCamWindowController.swift:212`）。
- 任务状态确实分四层落：`PropGenerationStore`（`Presence/PropGenerationStore.swift`）→
  `WishMachineCoordinator`（内存 `jobs`）→ `PropTaskDaemonClient` 快照（`Presence/PropTaskDaemonClient.swift:354`）
  → 面板投影（`App/GMGNRadioApp.swift:5731-5850` 那一段 `switch job.stage`）。

**(b) 失败不可见（真实缺陷，有日期有物件名）**

注释本身把病历写下来了：`App/GMGNRadioApp.swift:5754-5770`。
`2B 白色长剑` 那次的现场是：`wishes.json` `stage=claimed`、资产校验通过、
`layoutReceipts` 里**没有** `claimed.<jobID>`、`state.json` 的 `objectStates` 里**也没有它**，
而任务行与系统消息写着"已领取并入库"（30 秒后连那句假话都过期消失）。
根因：面板读的是 `residentOwnedPropAssets`（**模型已备好**），不是入库事实。
现在改成了读 `objectStates[job.objectID]?.generatedProp != nil`（`App/GMGNRadioApp.swift:5767-5771`）——
**方向对了，但仍然是 Swift 在问一份 Swift 自己的数据**。这就是"权威必须只有一个"的实证理由。

**(c) 判定与服务曾经不一致**

`Presence/ResidentPropPlacementService.swift:283-287` 记着实测：
格子说"可放"的 273 个去重格被服务**拒绝 273/273**，理由全是 `blockedRoute(...)`；
同期存档 9 条摆放回执**全部**落在展示台 y=0.52。
也就是说同一件事（能不能摆）在"格子着色"和"落地校验"两条路上曾经各算一遍。
今天收敛成了**同一个函数**（`previewState` 与 `commit` 都走 `validate`，`ResidentPropPlacementService.swift:180-209`），
但函数仍在 Swift，而**它的输入**（`WorldLayoutObstacles.resolve`、`WorldPlacementRouteMap`、
`PropPlacementEvaluator`）也仍在 Swift 且**不在任何 Rust 表里**。

**(d) 消息投递今天投两遍（本提案的首选迁移域）**

- 通道 A：守护进程消息 → `App/GMGNRadioApp.swift:6014-6036`
  （`residentWishMessages` + `residentWishConsumed` + `residentWishAcknowledgements`）。
- 通道 B：**本地直达捷径** → `App/GMGNRadioApp.swift:6037-6063`
  （`projectLocalWishFacts` + `residentWishLocalFactsQueued`，字段声明在 `:3552`）。
  加它的理由写在 `:6038`：「守护进程消息往返只是**其中一条**通道。事实本身早就耐久地躺在协调器里，
  所以这里再走一条**本地直达**：守护进程/隧道不可用时……仍然送进居民循环」。
- 于是**同一事实有两条投递路径、两套幂等记账**（`residentWishConsumed` vs `residentWishLocalFactsQueued`），
  判据还得手工对齐（`:6045-6047` 的注释就是在解释"两条通道上的分工必须一致"）。
- 消费侧还有第三份记账：`acknowledgeWishEvents` 里按 observation id 反查 delivery 再 ack
  （`App/GMGNRadioApp.swift:6105-6117`）。

**(e) 通知/已读今天两套**

- 统一状态域的 inbox 条目：`Presence/ResidentSystemInboxStateStorage.swift:4-5`（domain=`inbox`，key=`entries`），
  条目自带 `isRead` / `readAt`（`Presence/ResidentSystemInbox.swift:42-43`）。
- 未读数由**遍历算出来**：`ResidentSystemInbox.swift:189-191`（`filter { !$0.isRead }.count`）——
  这一点是**对的**（就是本提案要的"由游标 vs 日志算出"）。
- 但"看没看/存没存成功"另有一份：`markRead` 要求**durably persisted** 才算成功
  （`ResidentSystemInbox.swift:193-202`），于是"已读"这件事同时活在内存 bucket、
  状态域记录、UI 蓝点、以及窗口控制器的 badge 回调里
  （`App/GMGNRadioApp.swift:5596-5600` 把它推给两个窗口）。

### 2.5 动作域（motion）今天的权威

| 事实 | 证据 |
| --- | --- |
| 目录 = **文件系统目录 + 每包 `manifest.json`**，运行时枚举 | `Presence/MotionPackageStore.swift:146-172`、`:489-513` |
| "当前播哪条" = 一个本地 `.selection.json` | `MotionPackageStore.swift:453-455`、`:461-483` |
| 选择文件带 `selectionVersion = 3` 与硬编码内置 id | `MotionPackageStore.swift:51-55` |
| 目录根在 Application Support，不经过任何后端 | `MotionPackageStore.swift:106-119` |
| 活动→动作的解析与"世界声明了什么"分离 | `Presence/StageAvatarRuntime.swift:297-330` |

**结论**：动作域今天是"**目录即权威（文件系统）** + 一个选择文件"，与任务/世界域没有任何共同记账。
它是**最适合先集中**的域之一（结构简单、副作用只有"播哪条"）。

### 2.6 许愿机参数散在三处（与在跑实现线的边界）

| 位置 | 证据 |
| --- | --- |
| 工具 schema | `Agent/ResidentWishMachineTools.swift:37-52`（`size_intent` 对象、`axis` enum、`meters` 0.01—3、`source` enum） |
| 手写校验 + 文案 | `ResidentWishMachineTools.swift:124-166`（每个非法分支一条中文长句） |
| Rust 强类型 + 能力协商 | `services/gmgn-taskd/src/model.rs:60`（`SizeIntent`）、`model.rs:302`（`sizeIntent`/别名 `size_intent`）、`model.rs:437`（`parsed_size_intent`）、`model.rs:418`（`size_intent_conflict`） |
| 服务端能力声明 | `services/gmgn-taskd/src/provider.rs:372`（`size_intent_support`）、`docs/plans/2026-10-02-dgx-size-axis-negotiation.md:243`（`applies: "echo"`） |

**额外发现（本文新增，值得单列）**：同一件事在**同一个仓库里用了两种键名**——
到守护进程是 snake_case（`size_intent`，`model.rs:302`），到世界状态是 camelCase
（`WorldPropSizeIntent` / `sizeIntent`，`WorldPropLayout.swift:31`）。
这不是"三种位置"，这是**同一份 schema 的两个序列化面**，迁移时必须挑一个作为唯一真名。

### 2.7 agent 接口现状：私有插件已经就是"半个 MCP"

`Agent/ResidentDSHHostToolsBridge.swift` 在**运行期生成**一个 JS 插件：

- `moduleID = "gmgn-host-tools"`，文件名 `gmgn-host-tools.mjs`（`:254-255`）；
- 授权握手用 `gmgn-host-tools.grant.json`（`:256`），**每条调用都重读授权**并校验 `state === 'armed'`（`:377-378`）；
- 工具白名单按轮开放（`:384`）；
- 传输是**一个私有 UDS** `gmgn-host-tools.sock`（`:257`、`:387`），
  行分隔 JSON、8 MiB 上限（`:305`、`:310`）。

**结论**：要提供的 MCP server 在形状上与它**同构**，只差"协议是公开的"。
这也意味着 MCP 面必须**继承**这套授权模型（grant 文件 / 按轮白名单），不能另起一套权限。

### 2.8 事件面现状：有推送，但只覆盖任务

| 事实 | 证据 |
| --- | --- |
| `subscribe`（任务事件）/ `subscribe_messages`（按 scope 的消息） | `daemon.rs:493`、`daemon.rs:524-532` |
| 客户端从 `after` 游标开始，先读一次再订阅（避免读订阅之间的窗口） | `daemon.rs:519-528` |
| 有 `watch` 信号才去读库，**慢订阅者从数据库继续按序读** | `daemon.rs:579-602`、`README.md:24` |
| 任务事件源 = `events` 表，一行一个 job 快照 | `store.rs:297-315` |
| 快照分页 + "所有页来自同一 sequence 边界" | `store.rs:223-247`、`README.md:41` |
| Swift 客户端接上：`subscribe(after: sequence)` + `subscribe_messages` | `Presence/PropTaskDaemonClient.swift:336-338` |

### 2.9 缺口清单（本提案要补的洞，全部有行号）

| # | 缺口 | 证据 |
| --- | --- | --- |
| G1 | `state_commit` **不**触发 `changed` ⇒ 状态写入没有推送 | 全仓只有两处 `send_modify`：`daemon.rs:204`（`publish_message`）、`store.rs:220`（任务 `save`）；`daemon.rs:251` 的 `state_commit` 没有 |
| G2 | `resident_events` 不能按**域**读，只能按 scope 顺序读 | `resident.rs:594`（`read_events` 只按 scope+sequence） |
| G3 | Swift 侧对统一状态域**只有拉、没有订阅** | `Agent/ResidentStateClient.swift:155`（`eventRead(after:)`）、`:167`（`messageRead(after:)`）都是请求-响应 |
| G4 | 两个事件序列（任务 `events.sequence` 与 `resident_events.sequence`）互不可比 | `store.rs:98` vs `resident.rs:191` |
| G5 | 没有"设备/生产者"身份 ⇒ 云同步时无法区分自己的回环事件 | 全仓 grep 无 deviceId/origin 字段 |
| G6 | 世界/物件/动作**完全没有**进 `resident_states` | `resident.rs:40` 的 domain 枚举里没有 world-object / motion |

### 2.10 一句话证据小结

> 今天不是"没有权威存储"，而是**有两个各自完备的权威存储**（`taskd` 的 SQLite 与 Swift 的 JSON/SQLite 混合），
> 谁也不知道谁是主；于是每个域都各自发明了补丁（本地直达捷径、四层状态、六份授权、四处派生几何）。

---

## 3. 目标架构：谁是权威

### 3.1 一句话

> **`gmgn-taskd` 的 SQLite 是所有持久领域状态的唯一权威与唯一写入方；
> Swift 只保留"只读缓存 + 由权威数据派生的几何/界面状态"，并且缓存不是权威；
> 云端是副本，同步逻辑只在 Rust 里写一遍。**

### 3.2 分层与每层的权威边界

```
┌──────────────────────────── 云（副本，非权威） ────────────────────────────┐
│  账号作用域的记录副本 + 内容寻址的大文件（GLB / 动作包，按 sha256 去重）        │
└───────────────▲──────────────────────────────────────────┬─────────────────┘
                │ 同步（只在 Rust 实现一次）                 │ 拉取/推送
                │ 记录级 LWW + 字段级 revision + 墓碑        │
┌───────────────┴──────────────────────────────────────────▼─────────────────┐
│  gmgn-taskd（本地 Rust 守护进程）  ★唯一写入方 · 唯一权威★                    │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │ SQLite（权威存储）                                                    │  │
│  │  · worlds / rooms        世界与房间的持久事实                          │  │
│  │  · objects               物件身份/尺寸/归属/摆放/碰撞代理引用           │  │
│  │  · motions               动作目录 + 当前分配（"播哪条"）                │  │
│  │  · tasks / wishes        任务与许愿生命周期                            │  │
│  │  · facts（事件日志）      追加即事实；每消费者一个游标                   │  │
│  │  · blobs（引用表）        sha256 + bytes + mime + 本地路径（大文件外置）  │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│  命令通道（按需）: 意图 → 一次调用 → 新 revision                             │
│  事件通道（推送）: 权威变更 → 事件（带 revision + 幂等键）                    │
└───────────────▲──────────────────────────────┬─────────────────────────────┘
                │ ①命令（只在"要做一件事"时）    │ ②事件（推送，永不被渲染路径调用）
                │   放置/改尺寸/领取/播放/提交    │   带 revision/世代号
┌───────────────┴──────────────────────────────▼─────────────────────────────┐
│  Swift 宿主（★非权威★）                                                     │
│  · AuthorityCache        只读投影（记录 + 各自 revision）    ← 缓存不是权威  │
│  · DerivedGeometry       承托网格/红绿格/碰撞代理本地表示     ← 带 basedOnRev  │
│  · 判定（validate/preview）从上面两者派生，陈旧即拒             ← 不复制规则   │
│  · Metal 渲染 / 命中测试 / 情感手感           每帧只读内存，永不同步 RPC       │
└───────────────▲──────────────────────────────────────────────┬─────────────┘
                │ ③MCP（只读资源 + 动作工具）                    │ 私有 UDS
┌───────────────┴──────────────────────────────────────────────▼─────────────┐
│  gmgn-mcpd（第二个进程，stdio，由 MCP 客户端按需拉起）                        │
│  只做协议翻译 + 授权继承；被杀不影响权威；不占 taskd 的独占锁                 │
└────────────────────────────────────────────────────────────────────────────┘
```

### 3.3 权威归属表

| 事实 | 今天的权威 | 目标权威 | 为什么不搬的理由 / 为什么搬的理由 |
| --- | --- | --- | --- |
| 物件身份（objectID / sourceWishID / assetID） | Swift `metadata` blob（`WorldSimulation.swift:129`） | **Rust `objects`** | 三处（任务、协调器、世界）都要引用它 |
| 物件尺寸（含 `sizeIntent` / `authoritativeSize` / `sizeLocked`） | Swift blob（`WorldPropLayout.swift:9-31`） | **Rust `objects`** | 尺寸是"这件东西多大"的唯一答案，出处与优先级规则必须在数据旁边 |
| 归属（在哪件库存里、属于谁） | Swift 推导（`GMGNRadioApp.swift:5767`） | **Rust `objects.owner` + 库存视图** | 缺陷 (b) 的根因就是归属被"推导"而不是被"记录" |
| 摆放（transform / 承托层 / 是否 isEnabled） | Swift `state.json`（`LivingWorldBootstrap.swift:363`） | **Rust `objects.placement`** | 跨设备/云端要同步的正是这份 |
| 碰撞代理**引用** | Swift blob（`WorldPropLayout.swift:20`） | **Rust `objects.collider_ref`**（sha256 指针） | 引用是数据；**代理的求解与本地表示**留在 Swift |
| 任务生命周期 | 四层（§2.4a） | **Rust `tasks`** | `gmgn-taskd` 本来就在管它，Swift 那三层是投影 |
| 动作目录 | 文件系统目录（`MotionPackageStore.swift:146`） | **Rust `motions`**（+ blob 引用） | 目录需要被 agent、托盘、云同步同时读 |
| "当前播哪条" | `.selection.json`（`MotionPackageStore.swift:453`） | **Rust `motions.assignment`** | 单值事实，多端一致性要求很高 |
| 世界与房间的持久事实（worldID、manifest 引用、天气、时间基准） | Swift `state.json` | **Rust `worlds`** | 世界里的一切外键都指它 |
| 事实日志 + 每消费者游标 | 分散（§2.4d/2.4e） | **Rust `facts` + `cursors`** | 这是"投递不重复"的唯一实现方式 |
| **每帧渲染** | Swift/Metal | **Swift/Metal（不动）** | 帧率纪律 |
| **承托网格派生** | Swift `PropSupportGrid` | **Swift 派生 + 带世代号** | 输入在 Rust，求解在 Swift（§4.6） |
| **手感判定 / 命中测试** | Swift | **Swift（不动）** | 每帧/每次鼠标移动都跑 |
| **几何判定（能不能摆）** | Swift `ResidentPropPlacementService.validate` | **Swift，但从 Rust 权威数据派生 + 世代号** | §4.6 详述 |

### 3.4 硬规则（要能写成断言）

- **R1（唯一写入方）**：除 `gmgn-taskd` 外，任何进程/模块**不得**持久写权威记录。
  断言建议：`state_commit` 之外的写路径必然产生一条 `facts` 事件；给投影层注入一个"偷偷写盘"的缺陷，
  断言必须失败。
- **R2（缓存不是权威）**：Swift 侧持有的每一份记录都必须带 `revision` 与 `basedOnGeneration`；
  投影层发起命令时必须携带它读到的 `expectedRevision`。
  断言建议：构造"本地缓存 rev=N，权威已到 N+1"的场景，命令必须被拒（`revision_conflict`）而不是静默覆盖。
- **R3（判定跟着权威走）**：判定函数的**输入**必须整体来自权威投影；`WorldRuntime` 里**不得**再存
  与权威重复的规则数据（例如"物件尺寸"不能再从网格现量一份作为第二真名）。
  断言建议：把权威尺寸改掉（不通知 Swift 求解代码），重跑判定，判定结果必须随之变化。
- **R4（陈旧即拒）**：任何派生几何都标注 `basedOnRevision`；当投影 revision 前进，
  `basedOnRevision < current` 的派生结果**必须**被丢弃或重算，不得用旧几何做落地判定。
- **R5（同一 schema 只有一个真名）**：`size_intent` vs `sizeIntent` 二选一（建议保留线格式 snake_case，
  Rust 内部类型仍叫 `SizeIntent`），另一个只做兼容别名，且别名不能出现在新代码里。

---

## 4. 交互模型：事件驱动 + 命令按需

### 4.1 两条通道，职责分离

| | **事件通道**（Rust → 客户端） | **命令通道**（客户端 → Rust） |
| --- | --- | --- |
| 何时 | 权威变更时**推送** | **只在意图发生时**（用户/agent 要做一件事） |
| 谁发起 | Rust | 客户端 |
| 调用频率 | 与变更次数同阶 | 与人类/agent 的动作次数同阶，**与帧率无关** |
| 载荷 | 事件（类型 + 载荷 + revision + 幂等键 + 生产者 + 时间） | 命令（意图 + `expectedRevision` + `requestID`） |
| 返回 | 无（fire and forget，客户端凭游标追） | 新 revision + 结果 |
| 渲染路径 | **允许**读它维护的只读投影 | **禁止**出现 |

一句话记法：**命令改世界，事件说世界。**

**取代的悲观假设**：上一版担心的"每次变更都要往返"不成立。
往返只发生在意图上（一次拖动结束、一次按下"领取"），而且全部是**本地 UDS**（毫秒级），
不经过网络。**渲染路径永不同步 RPC**。

### 4.2 统一成"一条世界事件流"（而不是每域一条）

今天有两条互不可比的序列（G4）：任务事件 `events.sequence`（`store.rs:98`）与
`resident_events.sequence`（`resident.rs:191`）。
**提案：在权威库里只保留一条日志**，任务事件成为它的一种 `kind`。

```
fact := {
  seq        : INTEGER PRIMARY KEY AUTOINCREMENT   -- 全局单调，跨域可比
  id         : TEXT UNIQUE                          -- 幂等键（生产方给，重复追加返回既有 seq）
  kind       : TEXT                                 -- 命名空间化，见下表
  scope      : TEXT                                 -- 账号 / 世界 / 居民
  subject    : {domain, key}                        -- 这条事实改了哪条记录
  revision   : INTEGER                              -- 该记录变更后的 revision
  payload    : TEXT(JSON)
  producer   : TEXT                                 -- "taskd" | "device:<uuid>" | "cloud"
  at_ms      : INTEGER
}
```

**迁移方式**：`resident_events` 加列并改名/视图化，`events`（任务）改为把 job 快照作为
`kind = "task.stateChanged"` 写入同一条日志。**不新建第二张日志表**。

### 4.3 事件清单（类型 / 载荷 / 幂等键 / revision 语义）

| `kind` | 何时发 | 载荷（要点） | 幂等键 | revision 语义 |
| --- | --- | --- | --- | --- |
| `object.registered` | 物件进库存 | objectID, sourceWishID, assetRef, sizeIntent, colliderRef | `register:<objectID>` | `objects.revision` +1 |
| `object.placed` | 摆放落地 | objectID, transform, supportLayer, isEnabled | `place:<requestID>` | `objects.revision` +1 |
| `object.resized` | 改尺寸 | objectID, from, to, source(user/authority/intent) | `resize:<requestID>` | `objects.revision` +1 |
| `object.withdrawn` | 收回 | objectID | `withdraw:<requestID>` | `objects.revision` +1 |
| `motion.catalogChanged` | 目录增删 | motionID, action(add/remove), blobRef | `motion:<motionID>:<action>` | `motions.catalogRevision` +1 |
| `motion.assigned` | 改"当前播哪条" | motionID, previous, scope | `assign:<requestID>` | `motions.assignmentRevision` +1 |
| `task.stateChanged` | 任务阶段变化 | jobID, stage, remoteState, cancelRequested, lastError | `task:<jobID>:<stage>:<lastError>` | `tasks.revision` +1 |
| `wish.authorized` | 本轮人类授权成立/撤销 | authorizationID, attachments, world, scope | `authz:<authorizationID>` | `wishes.revision` +1 |
| `wish.claimed` | 真的入库（不是"资产备好"） | objectID, jobID, evidence | `claim:<jobID>` | `objects.revision` +1 **且** `wishes.revision` +1（同一事务） |
| `world.factChanged` | 天气/时间基准/房间事实 | worldID, key, value | `world:<worldID>:<key>:<hash>` | `worlds.revision` +1 |
| `inbox.fact` | 一条面向界面的通知**事实** | taskKey, kind, title, status, detail, terminal | `inbox:<taskKey>:<lastEventID>` | 不参与记录 revision（它是日志本身） |
| `device.cursorAdvanced` | 某消费者处理到哪（可选持久化） | consumer, seq | `cursor:<consumer>:<seq>` | 仅游标 |

**注意两处纪律**：

1. `wish.claimed` 必须与"物件入库"在**同一个事务**里提交——这正是缺陷 (b) 的解药：
   不可能出现"任务说已入库、库存里没有它"。
2. `inbox.fact` **不是**"通知状态"，它就是日志里的那条事实；
   界面蓝点 = `fact.seq > cursor(ui)`，**不是**另一个 `isRead` 字段（§4.7）。

### 4.4 每个消费者一个游标；投递 = 推进游标

消费者（今天的与将来的）：

| consumer | 今天在哪 | 迁移后 |
| --- | --- | --- |
| `agent` | `residentWishMessages` + `residentWishConsumed/Acknowledgements`（`GMGNRadioApp.swift:6014-6036`） | 游标 `agent@seq` |
| `ui`（收件箱/托盘） | `ResidentSystemInboxEntry.isRead/readAt`（`ResidentSystemInbox.swift:42-43`） | 游标 `ui@seq` |
| `world` | 同上（message consumer `world`） | 游标 `world@seq` |
| `cloud`（将来） | 无 | 游标 `cloud@seq`（§7） |

**机制（"至少一次但不重复生效"）**：

1. 日志只追加，`id` 唯一 ⇒ **重复追加等价于没追加**（`resident_requests` 已是这个模式，
   `resident.rs:180`，扩展成按 `id` 全表唯一即可）。
2. 消费者本地记 `lastAppliedID` + `lastAppliedSeq`。
3. 处理完成才推进游标；推进本身是**幂等的**（`cursor = max(cursor, seq)`）。
4. 断线重连：客户端发 `subscribe{consumer, after: cursor}`；服务端**先**从库里读 `seq > cursor` 的批次
   （今天已经是这个形状，`daemon.rs:519-528`），再切换到推送。
5. 乱序保护：客户端**拒绝**应用 `seq <= cursor` 的事件（丢弃并计数），
   并**要求**同一 `subject.key` 的 `revision` 严格递增——出现回退即视为协议错并触发一次全量重同步。

**断言建议**（每条都要能被注入缺陷抓住）：

- **A1 一次追加**：让两个通道各投一次同一 `id`，`facts` 表该 `id` 只能有一行。
  注入缺陷：让本地捷径用新 UUID 重投 —— 断言必须失败。
- **A2 恰好生效一次**：把处理函数计数，投一次事件后计数必须 =1；
  断开再重连同一游标，计数不变。
- **A3 不丢**：`kill` 订阅进程后写入 3 条事件，重连必须补到 3 条。
- **A4 不重**：重放整段日志（游标归零）后，每个消费者的可观察状态与只放一次完全相同
  （幂等律：`apply(apply(S,f),f) == apply(S,f)`）。
- **A5 单调**：任一 `subject.key` 的 revision 序列在生产端与消费端都严格递增。

### 4.5 重放与追赶

**已有（任务域）**：快照分页 + 同一 sequence 边界（`store.rs:223-247`）+ `subscribe{after}`。
**已有（统一状态域）**：`event_read{after, limit}`（`resident.rs:594`）。
**缺**：从任意 `revision` 追上来（而非从 seq）。

**最小方案**：

- **按 seq 追**（不按 revision）：日志是全局有序的，`after: cursor` 就够了。
  revision 只用于**命令的乐观并发**与**纪录级冲突判定**，不用于追赶。
- **冷启动顺序（先订阅再快照，且用 seq 夹住）**：
  1. 客户端先 `subscribe{consumer, after: ownCursor}`（服务端会先回放 `seq > ownCursor` 的批次）；
  2. 同时并发拉 `snapshot`，返回里带一个 `boundarySeq`；
  3. 客户端**丢弃**回放流里 `seq <= boundarySeq` 的事件（它们已被快照包含），
     应用 `seq > boundarySeq` 的事件；
  4. 之后按 seq 单调应用。
  **为什么不能"先快照再订阅"**：那两步之间的写入会永久丢失。
  **为什么不能"先订阅再快照"而不夹 boundary**：会重复应用（无害但不幂等的地方会出问题）。
- **本地方案**：`ownCursor` 持久化在**权威库**里（`cursors` 表），不在 Swift 侧。
  这样换设备/重装 App 也不丢追赶位置；但**云同步时游标是每设备一份**（§7.4）。

**代价（诚实说）**：需要 `snapshot` 支持返回 `boundarySeq`（今天任务快照返回 `sequence`，
`PropTaskDaemonClient.swift:364` 已经在用它做版本一致性校验——形状已经对了）。
统一状态域的 `state_read` 是**单条**读取（`resident.rs:339`），
要支持世界级冷启动需要**批量快照**方法，这是新增项。

### 4.6 派生几何的陈旧判定

**问题**：承托网格（`PropSupportGrid`，`WorldRuntime/PropSupportGrid.swift`）、
红绿格、碰撞代理的本地表示都不是数据库行，是**派生**出来的。派生需要时间（BFS、SAT），
不能每帧重算，于是它必然被缓存 —— 缓存就可能陈旧。

**方案：派生结果是一等对象，带 `basedOnRevision` 与 `fingerprint`。**

```
DerivedGeometry {
  kind            : "supportGrid" | "placementVerdict" | "colliderLocalForm"
  basedOnRevision : objects.revision / worldManifestHash / colliderRef
  fingerprint     : hash(权威输入)          // 权威输入变了，指纹必变
  value           : 网格 / 判定 / 本地表示
}
```

**陈旧判据（可写成断言）**：

- **D1**：`derived.basedOnRevision != current.revision` ⇒ **必须失效**（丢弃或重算）。
  断言建议：改一次权威尺寸，让派生不重算，落地判定**必须**给出"陈旧"错误码而不是旧结论。
- **D2**：`derived.fingerprint != hash(当前权威输入)` ⇒ 必须失效（防止"revision 没变但输入变了"，
  例如 manifest 引用换了内容）。
- **D3**：**渲染路径允许读陈旧派生**（一帧的视觉延迟可接受），
  **落地/命令路径禁止**（写操作必须用当前 revision 的判定）。
  这条是"手感"与"正确"的分界线，必须写进代码注释与断言名里。
- **D4**：同一判定不得由两段代码各算一遍。今天 `previewState` 与 `commit` 已经共用一个 `validate`
  （`ResidentPropPlacementService.swift:180-209`），这条要**保持**并**上升为断言**：
  注入"给预览单独写一份判定"的缺陷，断言必须失败。

### 4.7 通知 = 同一份日志 + 每消费者自己的已读/已处理

- 通知**不另存**：`inbox.fact` 就是日志里的行。
- 蓝点/红点数 = `count(facts where kind ∈ 通知类 and seq > cursor(ui))`。
  今天 `unreadCount` 已经是"遍历算"的形状（`ResidentSystemInbox.swift:189-191`），
  只是数据源换掉：`entries.filter { !$0.isRead }` → `facts since cursor`。
- `isRead` / `readAt` **删除**（`ResidentSystemInbox.swift:42-43`）。
  "已读"不再是一条状态，而是一次 `cursor` 推进（命令通道调用，按需，低频）。
- UI 今天要求"先选中再点打开"才消蓝点（`ResidentSystemInbox.swift:193` 的注释），
  语义不变：**推进游标是显式动作**。

### 4.8 重入/并发：滑块的抖动、幂等、以及"事件回流别撕扯界面"

这是这类架构**最常见的坑**。三个机制一起上：

**(a) 合并/防抖（客户端）**
- 拖动尺寸滑块：本地产出一个 **pending intent**，只保留**最后一条**（`intentID` 固定，参数覆盖）。
  松手后（或 150 ms 静默后）才发一次命令。
- 命令带 `requestID = "resize:<objectID>:<intentSeq>"`：**同一 intentSeq 重发是幂等的**，
  服务端返回既有结果（`resident_requests` 已经是这个形状，`resident.rs:180`）。

**(b) 事件回流不撕扯界面（关键）**
- 客户端为每个 `subject.key` 维护 `pendingIntents[]`（未收敛的意图）与 `appliedRevision`。
- **只有当 `pendingIntents` 为空时**，该 key 的**远端事件才允许覆盖本地显示**。
- `pendingIntents` 非空时，远端事件只用来更新 `authorityRevision` 与"是否存在冲突"，
  不改变正在被操作的值。
- 超时（例如 2 s）或服务端明确报错（`revision_conflict` / 校验失败）时，
  **丢弃 pending，切回权威值，并显示原因**（不静默、不假装成功）。
- 断言建议：拖动滑块期间注入 5 条来自权威的 `object.resized`，
  界面显示值**必须**等于最后一次本地意图（不跳回），且收敛后必须等于权威值。

**(c) 乱序/重复**
- 见 §4.4 第 5 条：`seq <= cursor` 丢弃；`revision` 回退触发重同步。

### 4.9 命令通道的形状（与今天对齐）

今天已经在用的命令（`daemon.rs`）与提案的关系：

| 今天 | 提案 |
| --- | --- |
| `state_commit{expectedRevision, requestID}`（`resident.rs:126`） | **保留为唯一的写记录命令**；新增的 `objects`/`motions`/`worlds` 写都走它（同一张表、扩展 domain） |
| `submit` / `cancel` / `retry`（`daemon.rs:108-122`） | 保留；但**放弃第二份 `events` 序列**（G4），改为向统一日志追加 |
| `publish_message` / `ack_message`（`daemon.rs:184-231`） | **删除**（被 §4.7 的事实 + 游标取代） |
| `state_read` / `event_read` / `message_read` / `message_ack` | `state_read` 保留（加批量）；`event_read` 保留为**冷启动追赶**入口；`message_*` 删除 |

**命令的返回与事件不打架**：命令返回的 `revision` 是**权威在那一刻的 revision**；
随后客户端可能先收到事件、后收到返回（同一连接上不会，但断线重连会）。
规则：**以 `seq`/`revision` 的**单调比较**为准，不以到达顺序为准**。

---

## 5. 分阶段迁移（按域，每域一步）

### 5.0 域顺序（含理由）

| 批次 | 域 | 为什么这个顺序 |
| --- | --- | --- |
| **P0** | 事件面基础（补 G1，统一日志） | 所有后续域都依赖"写就发事件" |
| **P1** | **消息投递 + 通知** | 域小；**今天已有重复投递的真实缺陷可做前后对照**；能顺手**删掉**补偿机制（收敛判据） |
| **P2** | 物件（身份/尺寸/归属/摆放/碰撞代理引用） | 缺陷 (b) 的正主；世界可视化的核心 |
| **P3** | 动作（motion 目录与当前分配） | 结构简单、副作用单一（"播哪条"）；与走姿交接**划界** |
| **P4** | 任务与许愿 | 今天已经在 Rust 里，主要是**删掉 Swift 的三层投影**与六份授权副本 |
| **P5** | 世界/房间持久事实 | 最后，因为它是所有外键的根，动它影响面最大 |
| **P6** | 云同步（独立立项） | 依赖 P1-P5 的记录形状 |

**P1 与 P2 可以并行**（互不依赖）。

### 5.1 P0：事件面基础（**纯收益，先做**）

**改什么**
1. `state_commit` 成功后触发 `changed`（补 G1；今天只有 `daemon.rs:204` 与 `store.rs:220` 两处）。
2. 把任务 `events` 与 `resident_events` 合并为**一条日志**（§4.2），旧表转只读视图。
3. 日志行加上 `producer` 与全局唯一 `id`（补 G5 的一半）；`id` 冲突返回既有 seq（幂等）。

**成功判据**
- 写入任意 domain/key 后，一个只挂着 `subscribe` 的观察者**必在 1 s 内**收到对应事件（今天收不到，G1）。
- `facts` 表里同一 `id` 只有一行（A1）。
- 旧的两张表在只读视图下仍能被现有读取路径读到（回归不破）。

**风险**：低。合并日志会触及 `store.rs` 与 `resident.rs` 的读取路径。
**回滚**：保留双写一个周期的开关；出问题直接改回读旧表（新表只是多写）。
**可独立交付**：是。

### 5.2 P1：消息投递 + 通知（**纯收益，先做**）

**改什么**
1. 许愿事实只往**统一日志**追加一次（命令通道提交时同事务写入）。
2. 消费者游标入库（`cursors` 表）：`agent` / `ui` / `world`。
3. **删除**本地直达捷径：
   - `projectLocalWishFacts`（`GMGNRadioApp.swift:6048`）与它的调用（`:6041`）；
   - `residentWishLocalFactsQueued`（`:3552`）；
   - `residentWishConsumed` / `residentWishAcknowledgements` / `residentWishAcknowledging`
     三套记账（`:6034-6035`、`:6110-6124`）；
   - `publish_message` / `ack_message` / `message_read` / `message_ack` 四个方法
     （`daemon.rs:184`、`:209`、`:289`、`:308`）与 `messages.rs` 的消息表/ack 表
     （`messages.rs:56-70`）——**下线**（保留迁移期只读）。
4. **删除** `ResidentSystemInboxEntry.isRead` / `readAt`（`ResidentSystemInbox.swift:42-43`）
   与 `markRead` 里的状态写入（`:193-202`），改为推进 `ui` 游标。
   未读数改读"日志 since cursor"。

**成功判据**（本批次是否真的收敛，看这些）
- **同一事实在 `facts` 只有一行**（A1），且**没有任何代码路径**再写第二份投递记账。
- 断网/隧道不可用期间产生的事实，恢复后**一条不少**（A3）；
  且 `agent` 只**生效一次**（A2）——这一条今天无法证明，因为有两个消费者。
- 收件箱蓝点数 == `count(facts kind∈通知类 and seq > ui.cursor)`；
  打开一条后蓝点恰好减 1（A2 的界面版）。
- **删除清单里的每一个符号都不再存在**（`grep` 为空）——这是"补偿机制被删掉"的机械判据。

**风险**
- 中。今天"本地直达"是为了**抵御守护进程不可用**而加的（理由写在 `GMGNRadioApp.swift:6038`）。
  删掉它之前必须确认：**事实本身已经耐久**（`WishMachineCoordinator` 的 `wishes.json` 今天确实耐久，
  `WishMachineCoordinator.swift:221`），而**新的日志与它同事务**。
  换句话说：先做 P2 的物件入库同事务，或者至少在 P1 里保证"许愿事实"也在同一事务里追加。
- UI 蓝点从"状态"变成"计算"，需要处理"日志很长时不要遍历全表"（§8 增长问题）。

**回滚**：把 `projectLocalWishFacts` 的调用恢复（代码保留一个周期、标记 deprecated）；
消息表只读不删，可随时切回。
**可独立交付**：是。**这一批是本提案"最该先做"的一步。**

### 5.3 P2：物件域

**改什么**
1. Rust 新增 `objects` 记录（身份/尺寸/归属/摆放/碰撞代理引用），
   domain 落在统一状态表的 `world` 域下的新 key 命名空间（或新表 + 视图）。
2. `register` / `place` / `withdraw` / `resize` / `hold` 等**意图**改走命令通道；
   `WorldSimulation.applyPropLayout`（`WorldSimulation.swift:108`）**语义保留**，
   但权威状态从 `WorldState.objectStates` 迁到 Rust；Swift 侧改为**只读投影**。
3. `state.json` 的 `objectStates` / `layoutReceipts` **转只读**，
   新增启动时**一次性导入**（导入器只跑一次，记 `migrations` 表，形状见 `store.rs:100`）。
4. `wish.claimed` 与 `object.registered` 同事务（解缺陷 (b)）。
5. `size_intent` vs `sizeIntent` 收敛为一个真名（R5）。

**成功判据**
- 真机跑一次"生成 → 领取 → 摆放"：`wishes.json` 的 stage 与库存事实**不可能**互相矛盾，
  且"已领取并入库"这句话只有在 `objects` 里有对应行且 `isEnabled` 状态明确时才出现。
- 断线期间本地摆放不丢（命令失败要显式报错，不能静默）；恢复后与权威一致。
- 导入器幂等：跑两次不产生第二份数据。

**风险**：**最高**。这是世界里最活跃的数据，且今天几何判定直接读它。
- 若判定输入与权威不同步，会出现"格子说能放、落地被拒"的**老毛病复发**（§2.4c）。
  因此 P2 必须与 §4.6 的世代号**同时**上线，不能分两次。
- 尺寸语义（手动 > 意图 > 权威 > 自动，`WorldPropLayout.swift:23-31`）必须**原样**搬，
  一次搬错就是物件大小全错。

**回滚**：双写一个周期（Rust 写 + Swift 仍写 `state.json`，但**只有 Rust 的结果被读**）；
出问题改读回 `state.json`。
**可独立交付**：是，但**建议与 P1 一起评估**（P1 的收敛判据依赖"事实与记录同事务"）。

### 5.4 P3：动作域

**改什么**
1. `motions` 目录入库（id/name/format/blobRef/sha256），blob 走内容寻址（§7.2）。
2. "当前播哪条"入库，`.selection.json`（`MotionPackageStore.swift:453`）转只读 + 一次性导入。
3. Swift 侧 `MotionPackageStore.listMotions` / `activeMotion` 改为读投影
   （形状保留，返回类型不变，减少改动面）。
4. **边界**：`StageAvatarRuntime` 的 playback 解析、locomotion 交接、
   `StageLocomotionGait` 的 retime **全部不动**（属于在跑的"走姿交接"线）。

**成功判据**
- 当前动作在**两个窗口**（舞台 + LiveCam）读到同一个 motionID，且与权威一致。
- 目录增删后两个窗口在 1 s 内收敛（事件驱动，不靠重启）。
- 删除 `.selection.json` 的写入路径后，重启 App 仍恢复同一动作。

**风险**：低。动作域无并发写、无几何耦合。
**唯一风险**：内置动作 id 是硬编码（`MotionPackageStore.swift:51-55`），
搬家时**不能改 id**，否则用户的当前选择会失效（今天已有 `retiredBuiltInMotionIDs` 迁移逻辑，要保留）。
**回滚**：选择文件保留只读，改回读它。**可独立交付**：是。

### 5.5 P4：任务与许愿

**改什么**
1. 删掉 Swift 侧的任务投影层（`PropGenerationStore` 的 job 数组、
   `WishMachineCoordinator.jobs`）中的**权威语义**，改为只读投影；
   `WishMachineCoordinator` 收敛为"意图网关 + 事务边界"。
2. 六份授权副本收敛为**一条记录**（`wish.authorized` 事件 + `authorizations` 记录），
   其余五处改为**引用**（只存 id，不存内容）。
3. 面板的 `switch job.stage`（`GMGNRadioApp.swift:5731`）改为读投影的 stage
   （语义不变；三个轴 `ResidentTaskAxisProjection` 的推导也保留，它已经是"派生"而不是"存储"）。

**成功判据**
- 任务阶段只有**一个**写入方；Swift 侧对 stage 的任何改动都会在下一次权威事件后被纠正（不是静默不一致）。
- 授权副本数从 6 降到 1（机械判据：`grep -c 'authorizationID'` 的落点从 4 个文件降到记录 + 引用）。
- 生成→失败→重试→取消的全链路，Swift 不再自己判定终态。

**风险**：中。授权是安全边界，删副本时**不能减小**权限强度；
"单次使用"语义（`WishMachineCoordinator.swift:43` 的注释）必须在记录层实现，不能丢。
**回滚**：授权记录只读保留，写路径切回内存（安全性不变，收敛性退回）。**可独立交付**：是。

### 5.6 P5：世界/房间持久事实

**改什么**：`worlds` 记录（manifest 引用 + hash、天气、时间基准、lastObservedWallTime），
`state.json` 转只读 + 导入。

**成功判据**：换一次世界/房间，权威与 Swift 投影的 worldID/manifest hash 一致，
且 `state.json` 不再被写（可观察其 mtime 不变）。

**风险**：中。`state.json` 是**所有外键的根**，导入失败会让世界起不来。
**回滚**：导入器带 dry-run；写入切回 Swift。**可独立交付**：是（放最后）。

### 5.7 过渡期铁律：绝不产生第二份真相

每个域迁移都必须满足**三条同时成立**（缺一条就会长出第二份真相）：

1. **唯一写入方**：迁移那一刻起，只有 Rust 写这个域。
   旧存储立刻转**只读**（不是"双写"，除非是明确的、有期限的回滚窗口）。
2. **只读投影**：Swift 侧对同一事实**只能**通过投影读，投影带 `revision`（R2）。
   禁止"从别的源推导同一事实"（缺陷 (b) 就是这么长出来的）。
3. **一次性导入 + 世代号**：导入器幂等，导入后记录一个 `importedAt`/世代号；
   投影记录 `basedOnGeneration`，世代不匹配即视为陈旧（R4）。

**双写窗口的纪律（如果非用不可）**：
- 双写必须有**明确的截止时间**与**一个开关**；
- 读取**只能**读一边（Rust），另一边只写不读——这样即使不一致也不产生第二个"用户看见的真相"；
- 双写期间必须有一个**对账断言**：两边内容哈希必须相等，不等即告警。

---

## 6. MCP 面清单

### 6.1 三个面的关系与硬边界

```
MCP 客户端（agent 宿主 / Claude / Codex / DSH …）
        │  stdio（JSON-RPC 2.0）
        ▼
gmgn-mcpd（新进程，薄的协议翻译层）
        │  私有 UDS（现有协议，行分隔 JSON）
        ▼
gmgn-taskd（权威；独占私根锁）
```

**硬边界（不可越）**：

| 约束 | 理由 |
| --- | --- |
| MCP server **不**嵌进 `gmgn-taskd` | `main.rs:47` 的 `flock` 意味着同私根只能有一个 `taskd`；把 MCP 塞进去会让"MCP 客户端重启"影响权威进程 |
| MCP server 用 **stdio**（不由 app 常驻拉起） | 它由 MCP 客户端按需 spawn；被杀不影响权威；不新增本地端口与认证面 |
| MCP server **不**持有凭据 | 凭据只在 `taskd` 进程内存（`daemon.rs:25`、README:3）；`gmgn-mcpd` 只知道 socket 路径 |
| MCP server **不**绕过授权 | 继承 `gmgn-host-tools` 的 grant 模型（`ResidentDSHHostToolsBridge.swift:377-384`）：每条调用校验"armed + 本轮白名单" |
| MCP server 只读资源**不**要求授权；动作工具**要求** | 读是安全的方向；写必须有人/轮的授权 |

**为什么不用 HTTP/SSE**：本 app 的消费者全在本机（DSH 插件已在用 UDS）。
HTTP 会带来：一个本地端口（与 app 其它本地服务冲突的可能）、一套本地认证、
以及"谁负责拉起/重启它"的新问题。**在本地 stdio + UDS 已经够用的前提下，HTTP 是纯增成本。**
（`rmcp` 也支持 Streamable HTTP，将来若真需要远程 agent 再开，不推翻本设计。）

### 6.2 只读资源（resources）

| URI | 返回 | 说明 |
| --- | --- | --- |
| `gmgn://worlds` | `[{worldID, name, manifestRef, revision}]` | 世界列表 |
| `gmgn://world/{worldID}` | `{worldID, manifestRef, weather, timeBase, revision}` | 世界事实 |
| `gmgn://world/{worldID}/objects` | `[{objectID, name, size, sizeSource, owner, placement, colliderRef, revision}]` | 物件视图 |
| `gmgn://world/{worldID}/object/{objectID}` | 单物件 + `revision` + `colliderRef`（**不含 GLB 字节**） | |
| `gmgn://motions` | `[{motionID, name, format, blobRef, sha256, bytes}]` | 动作目录 |
| `gmgn://motions/assignment/{worldID}` | `{motionID, revision}` | "当前播哪条" |
| `gmgn://tasks?worldID=&limit=` | `[{jobID, stage, remoteState, lastError, revision}]` | 任务列表 |
| `gmgn://task/{jobID}` | 单任务 + 事件尾部 | |
| `gmgn://facts?after=&limit=` | `[{seq, id, kind, subject, revision, payload, at}]` | **事件流**（agent 用它追赶） |
| `gmgn://cursors/{consumer}` | `{consumer, seq}` | 消费者游标 |

**共同形状（每个资源都必须有）**：

```json
{
  "revision": 17,
  "seq": 4211,
  "value": { "...": "..." },
  "basedOn": { "worldGeneration": "b1c2...", "manifestHash": "9f3a..." }
}
```

`basedOn` 是给客户端做**陈旧判定**用的（§4.6 D1/D2），不是装饰。

### 6.3 动作工具（tools）

| 工具名 | 入参 | 出参 | 幂等键 |
| --- | --- | --- | --- |
| `place_object` | `worldID, objectID, surfaceLayer, position{x,y,z}, yaw, expectedRevision, requestID` | `{objectID, revision, seq}` | `requestID` |
| `resize_object` | `worldID, objectID, size{x,y,z}, source(user/intent/authority), expectedRevision, requestID` | `{objectID, size, revision, seq}` | `requestID` |
| `withdraw_object` | `worldID, objectID, expectedRevision, requestID` | `{objectID, revision, seq}` | `requestID` |
| `claim_wish_output` | `worldID, jobID, expectedRevision, requestID` | `{objectID, revision, seq}` | `requestID` |
| `submit_wish_generation` | **本文不定义**（见 §6.5 边界） | | |
| `assign_motion` | `worldID, motionID, expectedRevision, requestID` | `{motionID, revision, seq}` | `requestID` |
| `advance_cursor` | `consumer, seq` | `{consumer, seq}` | `consumer+seq` |
| `open_inbox_item` | `worldID, taskKey, expectedRevision, requestID` | `{cursor, unreadCount}` | `requestID` |

**共同纪律**：
- 每个**写**工具都必须带 `expectedRevision`（乐观并发，对应 `resident.rs:130`）与 `requestID`（幂等）。
- 返回**必须**带新的 `revision` 与 `seq`（客户端据此知道"命令生效在哪一点"）。
- 工具**不**返回大文件（GLB）：返回 `blobRef`/`sha256`，取字节是另一个动作。

### 6.4 "信息不足"的结构化返回

agent 经常问得不够具体。**不允许**用自然语言说"请提供更多信息"——必须结构化，
让 agent 能直接补参数重试。

```json
{
  "error": {
    "code": "insufficient_input",
    "missing": [
      { "field": "size_intent.meters",
        "why": "没有尺寸就无法决定物件多大；用户已说「长剑」但没说长度",
        "ask": "要多长？（0.01—3 米）",
        "choices": null },
      { "field": "size_intent.axis",
        "why": "「长剑」既可以按最长边也可以按高度",
        "ask": "按最长边还是按高度？",
        "choices": ["longest", "height"] }
    ],
    "hint": "先问用户，再用同样的 requestID 重试；不要自己猜一个尺寸"
  }
}
```

约定：
- `missing[]` 里的字段名**必须**与工具 schema 的路径逐字一致（可直接拼补丁）。
- `ask` 是给**人**看的一句话；`why` 是给**模型**看的一句。
- 与今天的既有做法对齐：`sizeIntentProblem` 已经返回"还差一个尺寸：先问用户…"
  （`ResidentWishMachineTools.swift:129`），本提案只是把它**结构化**，并把"该问什么"从散句
  收敛成 schema 派生的可用字段列表。

### 6.5 错误码（与现有码对齐，不新造同义词）

| 码 | 何时 | 今天在哪 |
| --- | --- | --- |
| `insufficient_input` | 参数不足（见 §6.4） | 新（今天用长句，`ResidentWishMachineTools.swift:129`） |
| `revision_conflict` | `expectedRevision` 不匹配 | `resident.rs:130` 语义（今天返回什么码由 `daemon.rs:261` 决定，需对齐） |
| `invalid_object` | objectID 不存在/不合法 | `WorldPropLayoutError.invalidObject`（Swift 侧今天在用） |
| `collision_rejected` | 判定拒绝（摆在障碍/承托面外） | 今天在 Swift `ResidentPropPlacementError`；MCP 面把**原因字符串**原样透传，不重新分类 |
| `blocked_route` | 堵死唯一通路 | `ResidentPropPlacementError.blockedRoute` |
| `environment_not_ready` | 承托/碰撞数据未就绪（fail-closed） | `ResidentPropPlacementError.environmentNotReady` |
| `asset_not_ready` | 资产还没备好（不是"已入库"） | 解缺陷 (b) 的关键码 |
| `stale_derivation` | 派生几何基于旧 revision（§4.6 D1） | 新 |
| `unauthorized` | 本轮没有授权 | `WishMachineError.unauthorized` |
| `consumed_authorization` | 授权已被用掉 | `WishMachineError.consumedAuthorization` |
| `invalid_size_intent` / `size_intent_conflict` | 尺寸意图非法/冲突 | `model.rs:88`、`model.rs:418`（**必须复用**） |
| `provider_not_ready` | 生成服务不可用 | `provider.rs`（已有） |
| `unknown_resource` / `unknown_tool` | 协议层 | 新 |
| `subject_not_found` | 记录不存在 | 新 |

**纪律**：同一个错误在两个面上**必须**是同一个码。例如尺寸意图非法，
MCP 面返回 `invalid_size_intent`，不能自己改叫 `bad_size`——
否则又长出一套需要同步的词汇表。

### 6.6 与"许愿机 MCP/skill 化"实现线的边界

| 归他 | 归本文（设计） |
| --- | --- |
| agent 侧工具入口的重构（skill 化、工具发现、系统提示组织） | **MCP 面的资源/工具形状、错误码、幂等与 revision 纪律** |
| 许愿机参数在提示/schema/文档三处的收敛实现 | 指出这**三处必须由一份 schema 派生**（§2.6 + §6.4），并给出结构化返回的形状 |
| `ResidentWishMachineTools.swift` 的具体改动 | **不改这个文件**；只在需要时引用它的现状作为证据 |
| skill 的 payload / 触发条件 | `submit_wish_generation` 的 MCP 入参（**本文不定义**，交由他定义后再对齐错误码） |

**一句话**：本文提供 MCP 的**底座与协议纪律**；许愿机那条线提供**它自己的工具语义**。
两者在 `insufficient_input`、`invalid_size_intent`、`revision_conflict` 三个码上必须对齐。

---

## 7. 云端是副本：记录形状、冲突、大文件、账号边界

### 7.1 记录形状（同步的最小单位）

```
Record {
  id            : TEXT       -- 稳定身份（UUID 或 content-derived）
  scope         : TEXT       -- account:<uuid>（同步作用域；本机数据可为 local:<device>）
  domain        : TEXT       -- objects | motions | tasks | wishes | worlds | facts
  key           : TEXT
  revision      : INTEGER    -- 本地单调递增（每记录）
  updatedAt     : INTEGER    -- 本地时钟（ms）
  updatedBy     : TEXT       -- device:<uuid>（谁最后改的）
  tombstone     : BOOLEAN    -- 删除是"值 = 墓碑"，不是"行消失"
  hash          : TEXT       -- 值的内容哈希（对账用，见 §5.7）
  value         : JSON
}
```

- **删除用墓碑**：否则"删了又被另一台设备推回来"是必然的。
- **`hash` 是对账的抓手**：`§5.7` 的双写对账断言就是比它。
- **`facts` 也同步**（作为 append-only）：这让"远端设备的动作"能出现在本机 agent 的历史里。
  但只要 `id` 幂等（§4.2），重复同步就无害。

### 7.2 冲突解决策略

| 情况 | 策略 |
| --- | --- |
| 不同记录 | 各自独立（`id` 不同 ⇒ 无冲突） |
| 同一记录、不同字段 | **字段级合并**：每个字段带自己的 `updatedAt`（值内部是 `{v, at, by}`） |
| 同一记录、同一字段 | **LWW**（last-write-wins，按 `updatedAt`，平局按 `deviceID` 字典序定序保证确定性） |
| 删除 vs 修改 | 墓碑胜出，除非修改的 `updatedAt` 比墓碑**更新**（"删除后又被编辑"= 复活） |
| 摆放 transform（易冲突） | **不平滑、不插值**：整体取 LWW 的一个赢家。理由：插值出来的位置可能落在承托面外（非法状态） |
| 尺寸（`sizeLocked=true`） | 手动尺寸**优先**，云端不得覆盖（对应 `WorldPropLayout.swift:23-31` 的优先级） |
| 任务生命周期 | 状态机合并：**终态不可逆**（`placed`/`failed`/`cancelled` 不被 `generating` 覆盖） |
| `expectedRevision` 冲突 | 本机由 Rust 拒绝（§6.5）；云端冲突不暴露给 Swift，由 Rust 收敛后再发事件 |

**为什么不用 CRDT**：物件摆放的可视化语义要求"就一个确定的位置"，
而 CRDT 的收敛中间态在渲染上会表现为物件乱飘。LWW + 墓碑 + 状态机约束更符合本 app。

### 7.3 内容寻址的大文件（GLB / 动作包）

**不进 SQLite 行**。理由：模型今天上限 8 MiB（README:43），动作包相当；
把它们塞进行会让每次状态读取都背负字节（今天 Swift 已经把物件 JSON 塞进 metadata，
`WorldSimulation.swift:129`，这就是一个要被纠正的小型先例）。

```
blob := {
  sha256 : TEXT PRIMARY KEY     -- 内容即身份
  bytes  : INTEGER
  mime   : TEXT                 -- model/gltf-binary | application/x-vmd | ...
  local  : TEXT                 -- 本机私有路径（0600，位于 taskd 私根内）
  remote : TEXT NULL            -- 云端 object key（上传后填）
}
```

- 记录里存 **`blobRef`（= sha256）**，不存路径、不存字节。
  对应今天的 `local_model_path`（`store.rs` 的关键字面在 `model.rs` 的 `Stored`）与
  `local_collision_path`（`daemon.rs:666` 附近）——**这两条要从 job 里挪到 blob 表**。
- **去重**：同一 sha256 上传一次；碰撞代理、同一动作的重复安装都自然去重。
- **断点续传**：`blob` 行先写 `remote=NULL` 的"待上传"状态，上传按分片推进，完成后回填 `remote`。
- **完整性**：本地已有 `files::publish` 与 GLB 校验（README:43），复用同一套校验，
  下载到本地后**先校验 sha256 再入库**。

### 7.4 本地优先

- **权威在本地**：云不可达时，所有命令照常（本地 UDS），所有事件照常（本地日志）。
- **联网后收敛**：Rust 后台任务按游标推送/拉取；失败退避重试，不阻塞任何用户操作。
- **冲突只在 Rust 解决**：Swift 永远看不到"两个版本"，它只看到事件流。
- **游标跨设备（选择与理由）**：
  - `cursors` 是**每设备一份**（`scope = device:<uuid>`），**不**同步。
    理由：游标表达的是"**这台设备**处理到哪"，同步它会让另一台设备跳过来还没看过的通知。
  - 但 `cloud` 这个消费者本身是**账号一份**（它是"云端副本已到哪"），
    所以 `cursors(consumer=cloud)` 属于账号作用域。
  - 断言建议：设备 A 读完通知，设备 B 的蓝点**必须**还在（证明游标是每设备的）。

### 7.5 账号/隐私边界（判断标准 + 默认值）

**判断标准**（三条里满足两条才上云）：
1. **可重建性**：丢了能不能从别处重建？不能重建的（用户意图、手工尺寸、摆放）→ 上云。
2. **跨设备有用性**：换台机器还会想要吗？想要 → 上云。
3. **可外泄性**：泄漏的伤害有多大？大 → 不上云（或必须显式同意）。

| 数据 | 默认 | 理由 |
| --- | --- | --- |
| 物件身份/尺寸/归属/摆放 | **上云** | 三条全中 |
| 动作目录与当前分配 | **上云** | 跨设备有用；目录本身可由 blob 重建（可只上"分配"） |
| 世界/房间持久事实 | **上云** | 换设备要恢复房间 |
| 任务/许愿历史（含失败原因） | **上云** | 跨设备历史有价值 |
| 生成的 GLB / 动作包字节 | **上云但延迟**（按需，可设"仅 Wi-Fi"） | 大；内容寻址天然安全（哈希即身份） |
| 事实日志 | **上云（可选开关）** | 便于云端侧 resume；否则至少上"终态事实" |
| **对话原文 / 语音** | **默认不上云** | 隐私最高；README:33 明确"原始对话文本永不落盘"，上云违背现状 |
| **凭据 / token** | **永不** | 今天只在进程内存（`daemon.rs:25`、README:3）——这条**不能**因为是"备份"就破 |
| 参考图片（用户上传） | **默认不上云**（本地路径 + sha256 引用） | 图片含人脸/隐私；上云需显式同意 |
| 长期记忆快照 | **默认不上云** | README:33 说明了它的易失性与边界 |

**一条硬规则**：云同步的**默认值必须是"不上云"**，上云必须是显式的、可撤销的、按类的开关。

---

## 8. 代价（诚实列出）

### 8.1 延迟与可用性

- **每次意图多一次本地往返**：UDS 往返在毫秒级，但**不是零**。
  影响面：拖拽结束、点击领取、切换动作。**不影响**渲染（§4.1）。
- **守护进程不可达时**：这是真问题，必须显式设计，不能假装没有。

| 情况 | 行为 |
| --- | --- |
| `taskd` 正在重启（< 2 s） | 命令**排队重试**（有界，例如 3 次 / 2 s）；UI 显示"正在同步"而非失败 |
| `taskd` 长时间不可用 | **只读降级**：渲染继续（用最后一份投影 + 世代号），**所有写意图被拒并明确报错** |
| 投影不存在（首次冷启动且 taskd 挂了） | **不启动世界**（fail-closed），显示可读原因——不能"先编一个空世界"（那会变成第二份真相） |
| 订阅断开但命令可用 | 世界照常；UI 标注"可能不是最新"；重连后按游标追赶（§4.5） |

**"只读降级"是唯一可接受的降级形态**：允许看，不允许写。
理由：允许写就必然产生本地权威副本 → 回到今天的问题。

### 8.2 事件模型的真正风险（取代"每帧往返"）

| 风险 | 说明 | 缓解 |
| --- | --- | --- |
| **事件丢失** | 推送是"通知去看库"，不是唯一数据流（`daemon.rs:587-601` 先读库再看 watch）⇒ 丢 watch 不等于丢事件 | 已有；断言 A3 |
| **事件重复** | 重连、重放、云同步都会造成重复 | `id` 幂等（A1）+ 应用幂等（A4） |
| **事件乱序** | 同一连接内有序；跨连接/重放后不保证 | 丢弃 `seq <= cursor`；`revision` 回退触发重同步 |
| **追赶期间的空窗** | 从 cursor 追到 head 之间，UI 可能显示过期状态 | 追赶期间 UI 打"同步中"标记；**不**在追赶期间允许写（或写带 `expectedRevision` 自然被拒） |
| **订阅服务不可用** | 见 §8.1 降级 |
| **日志无限增长** | 见 §8.3 |
| **派生几何陈旧** | 见 §4.6 D1-D3 |

### 8.3 日志无限增长（保留/压缩）

- **事实日志**要长期保留（它是"事实"），但**载荷可以压缩**：
  1. 同 `subject.key` 的连续同类事件可折叠（snapshot 式合并），
     保留**最早与最新**两条 + 中间合计条数。
  2. 终态事实（`task.stateChanged` 到 `placed/failed/cancelled`）**永久保留**，
     因为它们回答了"这东西为什么没出现"。
  3. 中间进度事实（`remoteRunning` 之类）保留 N 天（建议 30）后折叠。
- **断言建议**：剪枝后 `state_read` 的结果必须与剪枝前逐位相同
  （即剪枝只能剪"已被最新值覆盖"的中间态，不能剪出语义差异）。
- **今天的对照**：任务事件表 `events` **没有任何保留策略**（`store.rs:98`），
  `snapshot` 靠 `GROUP BY json_extract(job,'$.id')` 取每 id 最新（`store.rs:254-256`）。
  提案的折叠策略就是在 DB 侧把这个"取每个 id 最新"物化下来。

### 8.4 迁移期特有代价

- **两处数据并存**：双写窗口内两侧都可能不一致（§5.7 的三条铁律是对冲）。
- **导入器**要写、要测、要能幂等重跑——这是纯粹的净增工作量。
- **回滚窗口**必须留足（建议每个域一个发布周期）。

### 8.5 不做的取舍（说清楚为什么省了）

| 省掉 | 为什么 |
| --- | --- |
| 不在 Rust 做几何判定 | 判定输入（承托网格 3,000+ 层、三角形 SAT、BFS 路由图）**已经是 Swift 派生**；搬过去意味着把派生**和**判定一起搬，成本数倍，收益只有"规则唯一"——而规则唯一可以用"从权威数据派生 + R4 陈旧即拒"达成（§4.6） |
| 不做实时协同编辑 | 单用户、单机为主；LWW 足够 |
| 不做 CRDT | 摆放语义要求确定位置（§7.2） |
| 不做远程 MCP（HTTP/SSE） | 消费者全在本机（§6.1） |
| 不做"每帧同步" | 明确不是这个模型（§4.1） |

---

## 9. 迁移检查清单（每个域都要过一遍）

- [ ] 该域的**唯一写入方**是谁？（写进代码注释与 PR 描述）
- [ ] 旧存储在迁移那一刻是否**转只读**？写路径是否真的删掉（不是注释掉）？
- [ ] 一次性导入器是否**幂等**？跑两次是否产生第二份数据？
- [ ] 投影是否带 `revision` / `basedOnGeneration`？（R2/R4）
- [ ] 是否有**对账断言**（两边 hash 相等）在双写窗口里跑？
- [ ] 事件是否带**全局唯一 id**（幂等键）与 `subject`？（§4.2）
- [ ] 每个消费者是否有**游标**？重放是否幂等（A4）？
- [ ] 该域是否有**补偿机制**要被删除？（补偿机制的存在＝还没收敛）
- [ ] 回滚路径是否**被实际演练过**（不只是写下来）？
- [ ] 云同步是否只需要**改 Rust**（若需要改 Swift，说明权威没搬干净）？

---

## 10. 明确不做的事

1. **不**在 `gmgn-taskd` 进程里开 MCP 面（会与独占锁冲突，且让 MCP 客户端重启波及权威）。
2. **不**把渲染、命中测试、Metal 相关代码搬到 Rust。
3. **不**在 Rust 里重实现一遍承托网格/碰撞判定（取舍见 §8.5）。
4. **不**为每个域各建一条事件流（必须一条，§4.2）。
5. **不**保留 `publish_message` / `message_read` / `message_ack` 作为长期机制（P1 后下线）。
6. **不**保留 `isRead` / `readAt` 作为独立存储（改为游标）。
7. **不**保留本地直达捷径（`projectLocalWishFacts` 系列）作为长期机制（P1 后删除）。
8. **不**改 `Makefile`、不动 `tools/`、不碰 DGX、不提交 git。
9. **不**与"许愿机 MCP/skill 化"重叠：不改 `Agent/ResidentWishMachineTools.swift`，
   不定义 `submit_wish_generation` 的 MCP 入参（§6.6）。
10. **不**与"走姿交接"重叠：动作域只搬目录与"当前分配"，不碰 locomotion 求解与交接。
11. **不**在本轮实现云同步（只定形状，§7）。
12. **不**为了"看起来先进"引入 CRDT、远程 MCP、或跨设备实时协同。
13. **不**在 `taskd` 不可达时允许写（只读降级，§8.1）。
14. **不**修改 `docs/plans/2026-10-02-dgx-size-axis-negotiation.md` 与其补丁（在跑的实现线），
    只引用它作为 `applies: "echo"` 的证据。

---

## 附：本文引用的外部资料

- `rmcp`（官方 Rust MCP SDK，3.5.0）：<https://docs.rs/rmcp/latest/rmcp/>
  —— 提供 `transport-io`（server 侧 stdio）、`transport-streamable-http-server`、`auth`（OAuth）、
  `#[tool]` / `#[tool_router]` 宏与 `serve_server`。
- MCP 规范：<https://modelcontextprotocol.io/specification/2026-07-28>

---

## 附：最容易被推翻的一个判断（自我标注证据不足）

**判断**：「动作域（P3）是低风险、可以独立先做的一步」。

**为什么它最脆弱**：

1. 我只读到 `MotionPackageStore` 的目录与选择文件路径（`MotionPackageStore.swift:146-172`、`:453-483`），
   **没有**读完 `StageAvatarRuntime`（631 行）与 `StageAvatarActivityExecutor`（436 行）
   里"世界声明了什么 vs 实际播了什么"的全部分支（`StageAvatarRuntime.swift:297-330` 只是开头）。
   如果"当前播哪条"实际上是**每帧按活动/相位重算**而不是读 `.selection.json`，
   那么把"当前分配"搬进 Rust 的收益就会小很多，甚至引入一个与运行时不一致的新真名 ——
   这正是本文要消灭的东西，会变成自己打自己。
2. "走姿交接"这条在跑的线就在这个域里。我对它的**边界**（它改哪些文件）只有文档级间接证据，
   **没有**代码级确认。若它恰好也要动 `MotionPackageStore`，P3 就不是"低风险"而是"撞车"。
3. 我据以判断"低风险"的理由是"副作用只有播哪条"——这个理由在**只有选择文件是权威**时成立。
   若实际还有别的地方（例如每个动作包的 `manifest.json` 里的默认动作、或活动的 motion 映射）
   也在决定"播什么"，那副作用面比我估的大。

**建议**：P3 上马前，先做一次**只读**的动作链全量走查（`StageAvatarRuntime` →
`StageAvatarActivityExecutor` → `ActivityExecutor` → `ActivityCatalog`），
确认"当前播哪条"的**唯一来源**；若确认不了，就把 P3 排到 P2 之后并与"走姿交接"线对齐时点。

**次要怀疑排序**（按证据强度从弱到强）：

| 判断 | 证据强度 | 说明 |
| --- | --- | --- |
| "动作域低风险" | **弱** | 见上 |
| "任务状态存四层" | 中 | 我看到 4 个落点（§2.4a），但层与层之间可能有我未读的条件分支 |
| "授权六份副本" | 中 | 我数到 6 个落点（§2.4a），但"副本"的**内容范围**是否真的一致只做了抽样核对 |
| "`state_commit` 不触发 changed"（G1） | **强** | 全仓只有 2 处 `send_modify`，可直接 grep 证伪 |
| "判定已在 Swift 且输入也在 Swift" | **强** | `ResidentPropPlacementService.validate` 全文已读 |
| "消息投递今天投两遍" | **强** | 两条投递函数 + 两套记账集合都能指到行号 |

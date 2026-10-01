# 记忆（compaction）与生成结果（库记事实 / 文件留盘）搬进 Rust 权威：设计 + 分阶段计划

> ## ⚠️ 最终口径（2026-10-01，用户拍板）——本文的 A 域**不执行**
>
> **存储范围**：只持久化**空间状态**（世界 + 物件 + 资产引用）到本地 Rust 权威；
> 长期记忆、消息投递迁移、云端同步均**不在计划内**。
>
> 具体到本文：
> - **A 域（agent 记忆）= 用户决定「不要搞」** ⇒ **P-A / P-A1 / P-A2 一律不执行**；
>   本文 A 域的全部内容（compaction、pins、压缩后处理器、保留/折叠策略、第三方会话同步）
>   **只作为调研与设计记录保留**，不代表计划。
> - **B 域（生成结果）= 已在做的"空间状态"这条线内** ⇒ `artifact` / `blob` /
>   内容寻址 / "文件缺失必须可见"**保留并已落地**（`services/gmgn-taskd/src/artifact.rs`
>   的 `blob_verify`、`tools/reconcile-generation-results.py` 的只读对账器，以及
>   `world_blobs`）。
> - 主设计的 **P1 / P3 / P4 / P5 / P6 也一律不做**（消息投递迁移、动作域、任务与许愿、
>   世界/房间持久事实的迁移、云同步）——只有"空间状态 + 物件 + 资产引用"这一条在计划内。
>
> 日期：2026-10-02　状态：**设计；其中 A 域已被用户决定不做（not planned）**

本文是 [`2026-10-02-rust-world-authority-and-mcp.md`](2026-10-02-rust-world-authority-and-mcp.md)（下称**主设计**）的**补章**：
主设计定了两条通道、每消费者一个游标、唯一写入方、缓存不是权威、判定从权威数据派生并带世代号、
记录形状、大文件内容寻址、本地优先——**本文不重新论证这些，全部沿用**，只做两件事：

1. 在它的 **P 序列**里补上 **P-A（agent 记忆）** 与 **P-B（生成结果）** 两个此前没有归属的域；
2. 按用户新定的两条决策把这些域**收敛掉**，而不是设计"无限增长的原文归档"或"把大文件塞进数据库行"。

> **修订记录**：A 域（agent 记忆）**已于 2026-10-01 由用户决定不做**（见上方最终口径）。
> 下面 A 域的全部设计与分析作为**调研记录**保留——它的证据（原文层从未有活数据、
> 三张记忆表 0 行、`memory_compact` 从未有 dispatch）仍然是"为什么不做"的依据。

触发原话（用户，本轮）：

> 这样 rust 就能全面接管存储和世界信息了，包括所有投递的消息以及 agent memory 和所有生成的结果

随后两条设计决策（用户原话）：

> 记忆做 compaction 就好了，生成结果这个数据库里记录数据，然后其余文件保存在本地磁盘？像 capcut？

**"所有投递的消息"不在本文范围**（主设计 §5.2 / P1 已归属，另一条线在做）。本文只写 **A. agent 记忆** 与 **B. 所有生成结果**。

---

## 0. 结论摘要（RL；每行一句话）

| 问题 | 结论 |
| --- | --- |
| 记忆今天在哪？ | **分两层、且两层都不完整**：耐久层只有一条记录 `resident_states(domain=resident,key=plan)`（意图 + 暂停标记 + **最近 24 条**有依据事实，`ResidentAgentLoop.swift:815`）；原文层是 **易失** `memory_ingest` 的进程内 200 回合 FIFO（`memory.rs:75`），重启即丢。 |
| 为记忆准备的表用上了吗？ | **没有**。`memory_snapshots` / `memory_requests` / `memory_vec_rows` **真实库中 0 行**（已实测），写入侧 `memory::commit` 是 `#![allow(dead_code)]`（`memory.rs:50-53`）。**合同里有 `memory_compact`（`voicemem-rust-contract.md:219`），实现里连 dispatch 分支都不存在**（`daemon.rs` 中 grep `memory_compact` = 0）。 |
| Swift 侧七个记忆方法用了几个？ | **两个**。`memoryRecall` / `memoryIngest` 各 1 处调用；`memoryRead` / `memoryQuery` / `memoryTurn` / `memoryPending` **各 0 处**（全仓 grep 已验）。 |
| 所以"记忆"今天等于什么？ | 等于 **`plan` 那一条记录 + 一个 24 条的滑动窗口**。溢出的旧事实被 `suffix(limit)` **静默丢掉**（`ResidentAgentLoop.swift:815`）——这就是"没有 compaction、只有截断"。 |
| 生成结果今天在哪？ | **至少 4 处各存一份同名事实**：taskd `jobs.data`（JSON blob）、`wishes.json`（`WishMachine/`）、世界状态 `state.json` 的 `metadata["gmgn.generated-prop.v1"]`、以及文件系统里的扁平目录 `TaskService/`（`<id>.glb` / `<id>.png`，**不是内容寻址**）。 |
| 有多严重？ | 工件 `4210DB95`（2B 白色长剑）在 `wishes.json` 里 `stage=claimed`、收件箱写着"**已领取并入库**"，而 `state.json` 的 `objectStates` **没有它**、`layoutReceipts` 里也只有另外两件的 `claimed.*`。**但这条缺陷在 Swift 侧已经修好了**：`ResidentPropInventoryBacklog`（`GMGNRadioApp.swift:7021-7100`）现在把"已入库"字样**只**绑在 `isInInventory` 上，而 `isInInventory` 就是 `objectStates[objectID]?.generatedProp != nil`（`:5777-5780`）——与「我的物件」列表**同一份事实**。**本文因此把它定位为回归护栏，而不是待修缺陷**：真正的缺口在测试侧（见 §8 B-1 的三条断言）。 |
| 哈希对不对？ | **对，四方一致**。`inspection.sha256` = 磁盘 GLB 实测 sha256 = 世界状态 `assetID` 的后缀（3/3 已核对）。**输入图哈希是同一条记录里的另一个字段**（`job.imageSHA256`）——两者是**两个不同的键，永不混用**。**已更正**：本文初稿曾误称"`assetID` 用错哈希"，那是我把 `imageSHA256` 错认成 `assetID` 的来源（见 §4.4 注与 §9）。 |
| 最该先做哪一步？ | **P-B1（工件登记 + 文件缺失可见）**：不搬任何写入方、纯加法、能把上面那个真机缺陷变成"面板上一句可读的话"，并且它是 P2（物件域）的前置。记忆侧原建议的 **P-A1/P-A2 已由用户决定不做**（见文首最终口径）。 |
| 最大代价？ | `blob` 内容寻址要**加一道读时校验**（今天已经在读时全校验，`GMGNRadioApp.swift:3760-3768`，所以不是新增负担，而是把它从"prepare 那一次"推广到"每次取用"）。 |
| 最不确定的一条？ | **已由实测收敛**（§9）：初稿最不确定的是"`memory_ingest` 原文窗口是否真被用过"。只读探针（`memory_recall`）返回 `pendingTurns=0` / `revision=0` / `facts,notes` 空，而同 scope 的 `resident/plan` 已 **revision 158** ⇒ 通路是通的、唯独 ingest 无活数据 ⇒ **原文层保留价值为零，决定删**。**现在最不确定的换成了**：压缩层的三个触发阈值（原 20 回合 / 24k 字符 / 24h）是我拍的，无实测分布支撑。 |

---

## 1. 与主设计的对齐（先声明，防重复论证）

本文**逐条沿用**主设计的结论，不新增通道、不新增日志、不新增第二数据库：

| 主设计的定论 | 本文怎么用 |
| --- | --- |
| §3.1 唯一权威 = `gmgn-taskd` 的 SQLite，唯一写入方 | A、B 两域都落同一张 `resident_states` / 同一条事实日志；**不建第二张日志表** |
| §4.2 一条世界事件流（`facts`：`seq/id/kind/scope/subject/revision/payload/producer/at_ms`） | A、B 的事件都是这条流里的 `kind`（§7） |
| §4.4 每消费者一个游标 | A、B 的消费方（agent / ui / cloud）沿用主设计 §4.4 的游标表 |
| §7.1 记录形状 `id/scope/domain/key/revision/updatedAt/updatedBy/tombstone/hash/value` | A、B 的记录**原样**用这个形状（§4.1） |
| §7.3 大文件内容寻址（`sha256/bytes/mime/local/remote`）+ 不进数据库行 | **B 的核心**，本文把它落成可断言的 `blobs` 表（§4.2） |
| §7.5 凭据永不进权威库 | 适用于 A、B 全部（§5.3） |
| §5.0 域顺序 P0→P1→…→P6 | A、B 的位置见 §6.1，**不重排已有批次** |
| §5.7 过渡期三条铁律（唯一写入方 / 只读投影 / 一次性导入 + 世代号） | §6.4 逐阶段照做 |
| §8.1 只读降级：`taskd` 挂了只允许看、不允许写 | 对 B 特别重要：**文件在、库不在 ⇒ 不许启动世界**（fail-closed） |

**一条纪律**：本文提出的任何新方法、新表、新错误码，都必须能回答主设计 §9 的十条检查清单。

---

## 2. 现状勘察（只读，带证据）

### 2.1 A 域：agent 记忆今天的全部落点

#### (a) 耐久层：**唯一一条** `resident_states` 记录

| 事实 | 证据 |
| --- | --- |
| Swift 侧耐久记忆是 `ResidentMemoryStore`，明确声明"按统一状态合同持久化当前计划与有依据事实" | `Agent/ResidentMemoryStore.swift:4-6` |
| 它只写一条记录：`domain = .resident`、`key = "plan"` | `ResidentMemoryStore.swift:32`（`planKey`）、`:179-181`（`stateCommit(scope:domain:key:…)`） |
| 值形状 `PlanValue { intent, intentPausedByUser, groundedEvents }` | `ResidentMemoryStore.swift:43-47` |
| 窗口上限 = **24 条** | `ResidentMemoryStore.swift:31`（`maximumGroundedEvents = 24`） |
| 事件条目是 `Event { id, kind, summary }`——**只有一行摘要字符串**，不是结构化事实 | `Agent/ResidentAgentLoop.swift:428-432` |
| 真机确认：该记录存在且 revision 已很高 | 实测 `resident_states` 2 行：`inbox/entries` rev 79、`resident/plan` rev 158（`~/Library/Application Support/gmgn radio/TaskService/tasks.sqlite3`） |
| 真机 `plan` 的值确实是 `{"groundedEvents":[{id,kind,summary},…]}` | 实测 `select substr(value,1,600)` |
| 提交带幂等键 + CAS + 失败可见 | `ResidentMemoryStore.swift:170-205`（`request_id_conflict` / `revision_conflict` 分支）、`:225-241`（中文可读报错） |
| **溢出即静默丢**：`recentEvents = Array(recentEvents.suffix(limit))`，`limit = maximumQueuedEvents`（默认 24） | `ResidentAgentLoop.swift:811-815`、`:541` |
| 恢复路径：`restoreMemory()` 读回 `plan`，注入 `intent` / `intentPausedByUser` / `recentEvents` | `ResidentAgentLoop.swift:1104-1147` |
| 绑定/换 scope：先把旧 scope 写回，再绑新 scope（**计划不跨世界继承**） | `ResidentAgentLoop.swift:1064-1089` |

#### (b) 原文层：`memory_ingest` 的**进程内易失**缓冲

| 事实 | 证据 |
| --- | --- |
| 转发层是"薄适配器"，只转发 `memory_recall` / `memory_ingest` | `Agent/ResidentConversationMemory.swift:6-19` |
| 只有「已确认真实交付」的成对 user/agent 文本才入队 | `ResidentConversationMemory.swift:168-196`；调用点 `App/GMGNRadioApp.swift:4870`（交付完成才 `confirmDeliveredTurn`） |
| Rust 侧：原文**只在进程内存**，上限 200 回合 FIFO，`(scope, requestID)` 幂等也只在内存（每 scope 最近 200） | `services/gmgn-taskd/src/memory.rs:75`（`PENDING_TURNS_LIMIT = 200`）、`:74-79`（`INGEST_RECEIPTS_LIMIT = 200`）、`:1072-1080`（"Raw text is never…"） |
| 崩溃语义写明：**易失 pending 原文丢失**，只有已提交快照与水位跨重启 | `memory.rs:22-28`、`docs/plans/2026-09-08-voicemem-rust-contract.md:104-106` |
| 真机：pending 无表可查（内存），`memory_snapshots` **0 行** | 实测三张表 count 全为 0 |
| 单条回合文本上限 2000 Unicode 字符 | `memory.rs:72`（`TURN_TEXT_LIMIT`） |

#### (c) 为记忆建好但**从未被写过**的耐久表

| 表 | 真实行数 | 谁写 | 证据 |
| --- | --- | --- | --- |
| `memory_snapshots` | **0** | 只有 `memory::commit`（死代码） | `memory.rs:240-252`（DDL）、`:646`（唯一的 INSERT）、`:50-53`（`#![allow(dead_code)]` 的理由） |
| `memory_requests` | **0** | 同上 | `memory.rs:254-263`、`:1404`（测试断言表名） |
| `memory_vec_rows` | **0** | 无人（provider 拆除后不再写向量） | `memory.rs:33-39`、`README.md`（"不再写入向量"） |
| `memory_compact` 这个**方法** | 不存在 | 无 | `daemon.rs` grep `memory_compact` = **0**；Swift 侧 grep = **0**；合同在 `voicemem-rust-contract.md:219` |

> **这是本文最重要的一条现状结论**：记忆域今天**不是"存得不对"，而是"耐久那一层根本没有生产写入方"**。
> 合同、表、校验、幂等账本、CAS、错误码**全都写好了**，只是拆掉外部 provider 时把唯一写入方一起摘掉了。
> 于是现状 = 一条 `plan` 记录 + 一个 24 条窗口 + 一段重启即丢的原文。

#### (d) 仅本机 / 将来可能上云

| 数据 | 今天在哪 | 作用域 | 判断 |
| --- | --- | --- | --- |
| `plan`（意图/暂停/最近 24 条事实摘要） | taskd `resident_states` | `(worldID, residentScope)` | **仅本机**；`intent`/暂停是"用户对我下了什么指令"，跨设备有用但泄漏伤害中等 → §8 表里定"默认不上云，可显式开" |
| `memory_ingest` 原文窗口 | taskd **进程内存** | 同上 | **永不落盘**（今天如此，且 `README.md:33` 明确"原始对话文本永不落盘"） |
| 对话显示历史 `ResidentChatTranscript` | Swift **进程内存**，有界，换世界/换后端即清 | `worldID + sessionScope + backend` | 明确"不做持久化"（`GMGNRadioApp.swift:780-783`），**不搬** |
| DSH/Claude 会话历史 | `dshHistoryByScope` / `claudeHistoryByScope`（内存） | per scope | **第三方的**，不搬（§5.3） |
| DSH 会话文件 | `$TMPDIR/gmgn-resident-dsh-<uuid>/sessions/…/session.jsonl` | 沙箱临时目录 | **只读、非权威**（§5.3） |
| 后端 session id | `UserDefaults`（`saveSessionID`） | per backend + scope | 是**指向第三方的指针**，不是记忆内容；不搬 |
| 凭据 | Keychain / taskd 进程内存 | — | **永不进记忆库**（主设计 §3.4 / 本文 §5.3） |
| 用户上传的参考图 | `Application Support/gmgn radio/ResidentAttachments/*.png` | — | 属 B 的文件面（§5.2），**不是** A 的记忆条目 |

**(d-补充) 第三方会话文件的实测边界（这一条很重要，且是负面证据）**

| 事实 | 证据 |
| --- | --- |
| 沙箱根是**临时目录**，`sessions/` 是其中的 `persistenceRoot` | `Agent/ResidentDSHConfiguration.swift:135` |
| 会话由第三方组件落成 `session.jsonl`（一行一 JSON） | 实测：`.../sessions/--var-folders-…-workspace--/<uuid>/session.jsonl`，**1194 行 / 421,928 字节**，首行字段 `type/version/id/createdAt/cwd/delegationDepth` |
| 代码里**有**清理：runtime 销毁时 `sandbox.removeAll()` | `AgentConversationService.swift:1639`（`closeDSHImageRuntime`）、`:1604`（握手失败路径） |
| 但真机上**残留 20 个**沙箱目录，其中 **16 个带 `session.jsonl`** | 实测 `ls -d $TMPDIR/gmgn-resident-dsh-*` = 20；`find … -name session.jsonl` = 16 |
| 结论 | 这些文件是"第三方原文"，**不是权威**，且**清理不可靠**。本文对它的立场见 §5.3：**不进权威库、不承诺保留期、由 Rust 只登记"存在/大小/hash"，删除走文件面** |

### 2.2 B 域：一次生成的全部产物，今天分别落在哪

#### (a) 一次生成的产物清单（含各自的 sha256 与元数据）

| # | 产物 | 今天落在哪 | 身份/摘要 | 证据 |
| --- | --- | --- | --- | --- |
| 1 | **输入图 PNG**（用户上传，或经 `PropImagePreparation` 归一） | taskd 私根扁平目录 `<id>.png` | `job.imageSHA256`（= 该 PNG 的 sha256） | `daemon.rs`（`files::publish` 到 `<root>/<id>.png`）、`model.rs:155`（`image_sha256`）；真机 4 个 PNG 的 sha256 **与库里 `imageSHA256` 逐位相等** |
| 2 | **产物 GLB** | taskd 私根扁平目录 `<id>.glb` | 回执 `result.inspection.sha256` + `bytes` + `triangles` + `bounds` | `daemon.rs:666-668`（`format!("{}.glb", id)`）、`model.rs:774-780`（`validate_glb` 验 magic/version/长度/sha256/bytes）；真机 3 个 GLB 的实测 sha256 **与回执逐位相等** |
| 3 | **碰撞代理 GLB** | `<id>.collider.glb`（同目录） | 回执 `result.collision_sha256` / `collision_bytes` / `collision_triangles` | `daemon.rs:669-676`、`model.rs:785-800`（`validate_collider_glb`）；**真机全部为 nil**（当前 DGX 不发这五个字段，见 `workflow-side-collision-proxy-checklist.md`） |
| 4 | **权威尺寸** | 只在回执里（不进文件） | `result.authoritative_size` | `model.rs:437-520`；真机为 `null` |
| 5 | 任务状态/阶段 | taskd `jobs.data`（JSON blob，`backend_stage`） | — | `store.rs:97`（`jobs(id TEXT PRIMARY KEY, data TEXT)`）、`model.rs`（`backend_stage`，默认 `interrupted`） |
| 6 | 任务事件流 | taskd `events(sequence, job)` | 每行一个 job 快照 | `store.rs:98-99` |
| 7 | 回执全文 | taskd `jobs.data` 里的 `receipt`（`Option<Value>`） | 含 `inspection`/`result` | `model.rs:161-162` |
| 8 | 元数据（尺寸/来源/意图/碰撞描述/权威尺寸） | **两处**：世界状态 `state.json` 的 `metadata["gmgn.generated-prop.v1"]`，以及 taskd 的 `jobs.data` | — | `WorldSimulation.swift:129-133`、`WorldPropLayout.swift:4-31` |
| 9 | 摆放回执 | 世界状态 `state.json.layoutReceipts[requestID]` | — | `WorldState.swift:56`、`WorldSimulation.swift:110-112` |
| 10 | 摆放入库事实 | 世界状态 `state.json.objectStates[objectID]` | — | 实测 `marble-living-cabin/1.2.0/state.json`：`objectStates` 2 项 |
| 11 | 许愿档案 + 授权 + 事件 + 委托 + 网页参考图登记 | `WishMachine/wishes.json`（单文件，`posixPermissions 0600`，rename 提交） | — | `WishMachineCoordinator.swift:262`（文件名）、`:1067-1082`（临时文件 + rename = 唯一提交点） |
| 12 | 用户上传的参考图原件 | `Application Support/gmgn radio/ResidentAttachments/<uuid>.png` | 无哈希索引 | `ResidentImageAttachment.swift:238-240` |
| 13 | 居民自检到的公开参考图 | `Application Support/gmgn radio/ResidentWishReferences/<uuid>.png` | 无哈希索引 | `ResidentWishReferenceTools.swift:188-190` |
| 14 | 碰撞代理的**内存**三角形 | `WorldPropCollisionProxyStore`（进程内、按 sha256 索引） | — | `WorldPropLayout.swift:267`、`WorldPropCollisionProxy.swift:676`（`mesh(forSHA256:)`） |

#### (b) **"第二份真相"清单**（具体到字段，这是本文要消灭的东西）

以下每条都是"同一个事实被存了两份或更多，且没有任何主从关系"。

| 事实 | 副本 1 | 副本 2 | 副本 3 | 副本 4 | 实测证据 |
| --- | --- | --- | --- | --- | --- |
| **产物文件路径** | taskd `jobs.data.local_model_path` | `wishes.json` 的 `jobs[].modelPath` | — | — | 实测两者**字符串完全相同**（`/Users/…/TaskService/02BFEE6E-….glb`）；且 Swift 侧必须**手写相等断言**才能用：`job.modelPath == path`（`GMGNRadioApp.swift:3758`） |
| **产物内容摘要（GLB）** | 回执 `inspection.sha256`（taskd） | 世界状态 `assetID` 的后缀（**同一个 sha256** ✅） | 内存 `WorldPropCollisionProxyMesh.sourceSHA256`（当前为空） | 渲染缓存 key（`assetID + "|" + modelURL.path`） | **已更正**：实测 `02BFEE6E` 的 `assetID` 后缀 = `9d50e3d7…` = 回执 `inspection.sha256` = 磁盘 GLB 实测 sha256 —— **四方一致，没有用错哈希**。哈希**不同**的那个字段是 `job.imageSHA256` = `35c3b4f6…`（**输入 PNG** 的哈希），它是**另一个键**，用途是校验输入图。`GMGNRadioApp.swift:3781`（`assetID: "sha256:" + inspection.sha256`）与 `WorldPropLayout.swift:4-6` 因此**不矛盾**。（本文初稿此处判断错误。） |
| **输入图内容摘要（PNG）** | 回执旁路：`job.imageSHA256`（taskd） | 磁盘 `<id>.png` 的实测 sha256 | — | — | 实测 4/4 逐位相等；`model.rs:155`。它与 GLB 的哈希**必须**是两个不同的键（见 §8 B-4 的第三条护栏） |
| **尺寸（世界用）** | 世界状态 `size` | 回执 `authoritative_size`（当前 null） | 提交时 `size_intent` | app 现量的 `sourceHeight` | `WorldPropLayout.swift:23-31`（优先级注释）、`:55-58`（`effectiveSize`） |
| **尺寸（提交用）** | taskd `jobs.data.heightMeters` | `wishes.json` 的 `jobs[].heightMeters` | 世界状态 `metadata` 里的 `size.y` | — | 实测 `02BFEE6E`：taskd `heightMeters=0.7`；`wishes.json` `heightMeters=0.7`；`state.json` `size.y=0.7` —— **三个 0.7** |
| **任务阶段** | taskd `backend_stage` | `wishes.json` 的 `jobs[].stage`（9 态状态机） | `wishes.json` 的 `jobs[].remoteState` | 面板 `switch job.stage` 的投影 | `WishMachineCoordinator.swift:3-4`、`:26-27`；`GMGNRadioApp.swift:5731-5850` |
| **"已领取/已入库"** | `wishes.json` `stage=claimed` | 世界状态 `objectStates[objectID]` | 收件箱 `entries[].status`（"已领取并入库"） | `layoutReceipts["claimed.<jobID>"]` | **历史现场：四处互相矛盾**（`4210DB95` 实测：stage=claimed + 收件箱说已入库，但 objectStates 无它、`claimed.*` 回执也不存在）。**Swift 侧已修**：`ResidentPropInventoryBacklog.status(isInInventory:)` 把"已入库"字样绑在 `objectStates` 上（`GMGNRadioApp.swift:7021-7100`、`:5777-5780`）。**残留风险**：`isInInventory` 仍由 Swift 的 `state.json` 派生，权威未在 Rust ⇒ 本条的断言必须钉在"派生源"上（§8 B-1） |
| **taskd jobID** | taskd `jobs.id` | `wishes.json` `jobs[].jobID` | — | — | 实测相等（4/4） |
| **objectID** | `wishes.json` `jobs[].objectID` | 世界状态 `objectStates` 的 key | 收件箱 `taskKey`（= jobID，不是 objectID） | — | 三种标识混用 |
| **N 个不同哈希的同一张图** | `ResidentAttachments/` 里 **4 份相同 sha256** 的 PNG | `ResidentWishReferences/` 1 份 | taskd 私根 `<id>.png` 1 份 | — | 实测：`shasum` 得 `8649fe93…` **出现 4 次**（1.8 MB × 4）；`ResidentWishReferences/A76FF3E0-….png`（2,377,784 B）与 taskd 根下的 `B8594EB9-….png`（2,377,784 B）**同尺寸同 sha 前缀 `2377…`** |

#### (c) 真机实测：那个缺陷的现场（可复现）

```
taskd jobs（4 行）                      wishes.json（4 jobs / 32 authorizations / 38 events）
  EBFC07BE… ready  → EBFC07BE….glb        EBFC07BE… claimed  modelPath=…/EBFC07BE….glb
  B8594EB9… submission_uncertain (无 glb) B8594EB9… submissionUncertain  modelPath=null
  02BFEE6E… ready  → 02BFEE6E….glb        02BFEE6E… claimed  modelPath=…/02BFEE6E….glb
  4210DB95… ready  → 4210DB95….glb        4210DB95… claimed  modelPath=…/4210DB95….glb
                                          ↑ 收件箱条目："2B 白色长剑（外形摆件）" / "已领取并入库" / terminal=true

世界状态 state.json（worldID=84503420-…，layoutRevision=16，layoutReceipts=16）
  objectStates:   wish-prop-02bfee6e-…（斧头）  ✅
                  wish-prop-ebfc07be-…（咖啡机）✅
                  ← 没有 4210DB95 ❌
  layoutReceipts: claimed.02BFEE6E-…  ✅
                  claimed.EBFC07BE-…  ✅
                  claimed.4210DB95-…  ❌ 不存在
```

> 也就是说：**任务行与系统消息写着"已领取并入库"，而库存里没有它**。
> 这与 `GMGNRadioApp.swift:5754-5770` 的注释描述**逐字一致**（同一天、同一个物件名），
> 说明那是**真缺陷的复发**，不是历史记录。本文把它的判据写成 §8 的 **B-1**。

#### (d) 文件面的其他实测数字（增长与去重）

| 目录 | 大小 | 备注 |
| --- | --- | --- |
| `TaskService/`（工件+输入图+DB+socket+lock） | **17 MB** | 扁平命名，无内容寻址；`tasks.sqlite3` 618 KB 也在里面 |
| `MotionPackages/` | **82 MB**（360 个子目录） | 属主设计的 P3，本文不碰 |
| `ResidentAttachments/` | **7.5 MB** | 其中 **4 份完全相同的 PNG**（约 5.4 MB 是重复） |
| `ResidentWishReferences/` | **4.4 MB** | 与 taskd 私根里的输入图有重复 |
| `WishMachine/wishes.json` | 44 KB | 单文件全量重写（rename 提交） |

---

## 3. 目标归属：谁拥有什么

### 3.1 一句话

> **A（记忆）**：权威 = Rust 里**压缩后的记忆**（钉住的事实 + 有界最近窗口），原文只是**窗口内的输入**、永不成为长期权威；
> **B（生成结果）**：权威 = Rust 里的**事实行**（身份/状态/尺寸/摘要/**文件引用**），字节留在**本地内容寻址目录**，
> 同一内容只有一份；**"文件在不在"必须能被断言，且必须与事实行同生共死**。

### 3.2 权威归属表（A、B 的每一件事）

| 事实 | 今天的权威 | 目标权威 | 为什么不搬 / 为什么搬 |
| --- | --- | --- | --- |
| 记忆：钉住的事实（身份/承诺/偏好/在办） | 不存在（散在 `plan.groundedEvents` 摘要里） | **Rust `memory` 域 `facts` 记录 + `pinned` 标记** | 今天 24 条窗口一溢出就丢；承诺丢了是**产品级事故** |
| 记忆：压缩层（facts/notes 两段） | 表已建、**0 行** | **Rust `memory` 域 `snapshot` 记录** | 复用已冻结的形状（`voicemem-rust-contract.md:75-95`），不新造 |
| 记忆：压缩账本（何时/按什么规则/压掉哪段/产出什么） | 不存在 | **Rust 事实日志 `memory.compacted`**（§7） | "丢了什么要能查"要求它是**追加即事实**，不是状态 |
| 记忆：最近窗口原文 | taskd **进程内存** | **Rust 进程内存**（不变）+ 窗口有界 | 今天就是易失的，**保持易失**；不进库（见 §5.3） |
| 记忆：`plan`（意图/暂停标记） | Rust `resident_states(resident,plan)` | **Rust `memory` 域 `intent` 记录**（同库，键位归位） | 语义不变，只把它从"顺带塞在 plan 里"变成一等记录 |
| 记忆：对话显示历史 | Swift 内存 | **Swift 内存（不动）** | 是"界面当前显示什么"，不是权威 |
| 生成：工件身份（artifactID） | `wishes.json.jobs[].jobID` + taskd `jobs.id` | **Rust `artifacts.artifactID`** | 同一身份两个写入方 |
| 生成：任务状态机 | 四层（taskd + wishes + remoteState + 面板） | **Rust `artifacts.state`** | 主设计 §5.5（P4）已定，本文只声明归属 |
| 生成：**字节所在的位置** | 路径字符串存在两处（taskd 行 + wishes 行） | **Rust `blobs.sha256` + `blobs.local`（唯一的路径权威）** | 路径是"字节在哪"的答案，只能有一个 |
| 生成：内容摘要（sha256/bytes/mime） | 回执里一份 + 世界里命名成 `assetID` 一份（**且用错哈希**） | **Rust `blobs` 行（`sha256` 即主键）** | 内容寻址的本质就是"摘要即身份" |
| 生成：尺寸/意图/回执/来源 | taskd `jobs.data` + `wishes.json` + 世界 metadata | **Rust `artifacts` 记录**（世界/物件侧是主设计 P2 的 `objects`） | 三方都要读它 |
| 生成：摆放与入库事实 | 世界状态 `state.json` | **Rust `objects`**（主设计 P2，本文不重复） | 但 `wish.claimed` **必须与工件登记同事务**（§8 B-1） |
| 生成：碰撞代理的**内存三角形** | Swift `WorldPropCollisionProxyStore`（进程内） | **Swift 派生（不动）**，输入是 blob 引用 | 三角形是派生几何（主设计 §4.6） |
| 生成：输入图/参考图 | `ResidentAttachments/`、`ResidentWishReferences/`、taskd 根 | **本地内容寻址目录（同一 `blobs`）** | 同一张图今天有 4 份副本 |
| 生成：用户上传的原始参考图 | 同上 | **本地，但可标记 `private`** | §5.3 |
| 每帧渲染 / 判定 / 命中测试 | Swift | **Swift（不动）** | 主设计 §4.1 |

### 3.3 硬规则（A、B 版，都写成断言）

- **RA1（记忆只有一个耐久出口）**：任何"长期事实"必须落在 `memory` 域的记录里，
  不得只活在窗口/截断数组/Swift 内存里。
  *断言*：注入"只 append 到 `recentEvents` 不提交"的缺陷 ⇒ **必须失败**。
- **RA2（钉住的事实不可压缩）**：`pinned=true` 的条目**永远**出现在压缩后快照里，文本逐字不变。
  *断言*：注入"压缩把 pinned 条目当普通条目丢掉"的缺陷 ⇒ **必须失败**。
- **RA3（压缩可追溯、丢弃可查）**：每次压缩产生一条 `memory.compacted` 事实，
  含 `trigger / ruleVersion / inputFrom..inputTo / keptIDs / droppedIDs / pinnedKept / outputRevision`。
  *断言*：注入"压缩不记账"的缺陷 ⇒ **必须失败**。
- **RB1（事实与字节同生共死）**：`artifacts` 行声明可用的 blob **必须**能按 sha256 打开并通过校验；
  否则该行**必须**进入 `missing` 状态并发事件，且**任何界面不得显示"已入库/可用"**。
  *断言*：删掉一个 GLB 文件 ⇒ 面板/任务行**必须**出现可读失败原因，且 `wish.claimed` 不成立（§8 B-1）。
- **RB2（内容寻址、同内容一份）**：同一 sha256 在磁盘上**只有一份**文件。
  *断言*：连续写入同一份字节两次 ⇒ 目录里文件数 +1（不是 +2），且 `blobs` 表只有一行。
- **RB3（引用与文件生命周期一致）**：GC 只删"引用计数为 0 且已过宽限期"的 blob；
  有引用的 blob 被删 ⇒ **必须失败**。
  *断言*：注入"删掉仍被引用的 blob"的缺陷 ⇒ **必须失败**。
- **RB4（云同步按需）**：大文件不在同步路径上全量传；`hydrate` 是显式、幂等、可断点续传的动作。
  *断言*：断开网络 ⇒ 已有本地的 blob 一切照常；缺本地的 blob 报 `blob_not_local`（不是"文件坏了"）。

---

## 4. 记录形状、幂等键、revision 语义

### 4.1 与主设计一致的记录形状

A、B 的记录**原样**使用主设计 §7.1 的形状，落同一张 `resident_states`：

```
Record {
  id : TEXT;  scope : TEXT;  domain : TEXT;  key : TEXT
  revision : INTEGER;  updatedAt : INTEGER;  updatedBy : TEXT
  tombstone : BOOLEAN;  hash : TEXT;  value : JSON
}
```

**域（domain）取值**：今天 `resident_states` 的 domain 是运行时字符串（`resident.rs:40`、`:69`），
Swift 侧枚举是 `resident | world | wish | inbox | conversation`（`ResidentStateClient.swift:47`）。
本文新增两个值，**不新增表**：

| domain | key 形状 | value |
| --- | --- | --- |
| `memory` | `snapshot`（每 scope 一条） | `{ schemaVersion, revision, sections:{facts[],notes[]}, embedding:{model,dimensions}, processedWatermark, nextWatermark, compaction:{lastSeq, ruleVersion} }` |
| `memory` | `intent`（每 scope 一条） | `{ intent, intentPausedByUser, updatedAt }` |
| `memory` | `fact/<entryID>`（可选细粒度；默认只写 `snapshot`） | 单条 entry（含 `pin`） |
| `artifact` | `<artifactID>` | 见 §4.2 |
| `blob` | `<sha256>` | 见 §4.2 |

> **为什么放 `resident_states` 而不建新表**：主设计 §2.2 已指出这张表**已经具备权威所需的全部机制**
> （CAS、`revision`、`resident_requests` 幂等、`resident_events` 追加快照）。
> 建新表就要重写一遍 CAS 与幂等——正是主设计要消灭的"两份同名机制"。
> 需要新表时只加**索引视图**（见 §4.2 的 `blobs` 视图），不新建写入路径。

### 4.2 B 域：`artifact` 与 `blob`

**(1) `artifact` 记录（每个产物一行；库只记事实，不记字节）**

```jsonc
// domain=artifact, key="<artifactID>"（= 今天的 jobID，UUID 规范化为大写连字符，沿用 model::identity）
{
  "artifactID": "4210DB95-…",
  "sourceWishID": "4210DB95-…",          // 与主设计 P4 对齐
  "name": "2B 白色长剑（外形摆件）",
  "state": "queued|generating|ready|failed|cancelled|interrupted",
  "idempotencyKey": "<uuid>",            // 沿用 job.idempotency_key
  "endpoint": "https://…",               // 不含 token
  "heightMeters": 1.1,
  "sizeIntent": { "axis": "longest", "meters": 1.1, "source": "user" },
  "generationProfile": "gmgn-mesh-v1;resolution=…;decimation=…;texture_size=…;remesh=…",
  "receipt": { /* 远端回执全文，只读审计 */ },
  "input":  { "blobRef": "<sha256 of input PNG>", "mime": "image/png", "private": true },
  "outputs": [
    { "role": "model",    "blobRef": "<sha256>", "bytes": 4239476, "mime": "model/gltf-binary",
      "inspection": { "triangles": 19206, "bounds": {…}, "primitives": …, "materials": … } },
    { "role": "collider", "blobRef": null, "format": null, "triangles": null }   // 今天恒为 null
  ],
  "authoritativeSize": null,             // 今天恒为 null（DGX 还不发）
  "lastError": null,
  "jobRevision": 12                      // 与 records.revision 同源
}
```

**关键纪律**：
- 里面**没有**路径字段。路径只在 `blob` 行里（§4.2(2)）。这是消灭"路径存两份"的机制，不是风格。
- `state` 是**唯一**的阶段权威；`wishes.json` 与面板都改为只读投影（主设计 §5.7 铁律 2）。
- `receipt` 保留全文（审计），但**派生字段**（`sha256`/`bytes`）以 `blob` 行为准，
  不一致即 `receipt_blob_mismatch`（可见，不静默取一边）。

> **(1-补) 已存在一张同形的表，本文不新建第二张。** 勘察发现 `world.rs`（另一条线本轮新增，v4
> `world-authority-v1`）里已经有 `world_blobs(sha256 PK, bytes, mime, local_path, remote_key,
> created_at_ms)`，并且 `world.rs` 的模块文档写明它服务的正是"GLB、碰撞代理"与
> "记录携带 `blobRef`，**绝不携带字节**"。**这就是本文 §4.2(2) 要的那张表**——所以 P-B1/P-B2
> **复用 `world_blobs`，不另开 `blob` 域、不建第二张 blob 表**（否则重演主设计要消灭的
> "两份同名机制"）。`blob_put` 已实现内容寻址与三项校验（`invalid_blob_hash` /
> `blob_outside_private_root` / `blob_hash_mismatch`），并有一条"同内容第二次 put 不产生第二行"的测试。
>
> **但它今天有两个必须修的缺口**（P-B1 的正是要补这里）：
> 1. **读时不校验（这是"文件缺失必须可见"的正缺口）**：`blob_get` 只 `SELECT` 出 `local_path`
>    就返回，**既不 `stat` 也不重算 sha256**。于是"行在、文件被删/被截断"会让调用方**看起来成功**，
>    直到渲染那一步才炸——这正是用户点名要消灭的形状。本文要求：读路径必须返回
>    `localState`（`present|missing|corrupt|not_local`）并在后两者发 `blob.missing` 事实
>    （§7），也就是本文 §8 的 **B-2**。
> 2. **落的是绝对路径**：`blob_put` 存 `path.to_string_lossy()`（绝对路径）。本文 §4.2(2) 的设计
>    是"私根内**相对**路径"，因为绝对路径在换设备/换用户名/云同步后失效，而 `blob` 行的用途
>    正是跨设备定位同一份内容。**建议**：存储层保留绝对（本地寻址需要），
>    **同步出去的记录里必须转相对**（P6 的输入形状）。
>
> `world_blobs` 也**没有引用计数**（删一个 blob 不知道谁还在用）——§5.5 的 GC 判据要求
> 引用计数必须**派生**出来（由 `artifacts`/`objects` 的 `blobRef` 反查），不是另存一列。

**(2) `blob` 记录（内容寻址；一个 sha256 一行）**

```jsonc
// domain=blob, key="<sha256>"
{
  "sha256": "9d50e3d7…",
  "bytes": 4239476,
  "mime": "model/gltf-binary",
  "local": "blobs/9d/50/9d50e3d7….glb",   // 私根内**相对**路径（0600）；仅本机
  "localState": "present|missing|not_local",   // not_local = 只在云上（§5.4）
  "remote": null,                        // 上云后填 object key；null = 未上云
  "verifiedAt": 1790819429853,           // 最近一次"校验通过"的时间
  "refCount": 2,                          // 派生（由 artifacts/objects 引用算出，不独立存）
  "tombstone": false
}
```

**磁盘布局（内容寻址，同内容一份）**：

```
<TaskService 私根>/blobs/<ab>/<cd>/<sha256>.<ext>       # 0600，ab/cd = 前 4 位分片
```

> 今天的布局是 `<root>/<id>.glb`——**按身份命名，不按内容命名**。
> 后果：同一件产物重新生成一次就是第二个文件；同一张图上传两次就是第二份字节。
> 实测 `ResidentAttachments/` 里 **4 份完全相同的 PNG** 就是这个后果。

### 4.3 幂等键 / revision 语义 / 事件（A、B 一张表）

| 动作 | 命令（沿用主设计 §4.9：唯一写记录命令 `state_commit`） | 幂等键 | revision 语义 | 事件 `kind` |
| --- | --- | --- | --- | --- |
| 写入最近窗口/意图 | `state_commit(domain=memory,key=intent,expectedRevision,…)` | `memory-intent:<scope>:<hash>` | `records.revision` +1（每次成功提交计数，沿用冻结语义） | `memory.intentChanged` |
| **提交压缩结果** | `memory_compact`（**恢复合同的 §3.7 方法**，实现落 `memory::commit`） | `(scope, requestID)` + 内容 digest（表已建：`memory_requests`） | `memory_snapshots.revision` +1 **且** `vector_generation` +1（同事务，合同 §2.5） | `memory.compacted` |
| 压缩中某个事实被钉住/解除 | 同 `memory_compact` 请求的一部分 | 同 requestID | 不单独 +1 | `memory.pinned` |
| 显式忘记（用户删） | `memory_forget(scope, target, requestID)` | `forget:<scope>:<target>` | 快照 revision +1（写新快照，不删行） | `memory.forgotten` |
| 登记工件（提交） | `artifact_register`（或 `submit` 的扩展，见 §6） | `register:<artifactID>` | `artifact.revision` +1 | `artifact.registered` |
| 工件状态变化 | 由 `submit/cancel/retry/failover` 触发的同事务写入 | `artifact:<artifactID>:<state>:<lastError>` | `artifact.revision` +1 | `artifact.stateChanged` |
| 字节落盘/校验通过 | `blob_publish`（daemon 内部，与 `files::publish` 同事务点） | `blob:<sha256>` | `blob.revision` +1（只第一次） | `blob.available` |
| 字节缺失/损坏 | `blob_verify` 的后台扫描 | `blob:<sha256>:<epoch>` | `blob.revision` +1 | `blob.missing` |
| 按需拉取 | `blob_hydrate` | `hydrate:<sha256>` | `blob.revision` +1 | `blob.available` |
| 删除（GC / 用户删） | `blob_forget` | `forget:<sha256>` | `tombstone=true`，revision +1 | `blob.forgotten`（**带删除凭据**，§5.5） |

### 4.4 内容寻址大文件怎么引用（GLB、碰撞代理、贴图、音频）

| 类型 | 引用方式 | 上限/口径（沿用今天） | 证据 |
| --- | --- | --- | --- |
| 产物 GLB | `outputs[role=model].blobRef = <sha256>` | 32 MiB（`MODEL_LIMIT`），GLB magic/version/声明长度 + sha256 + bytes 全核验 | `model.rs:760-780` |
| 碰撞代理 GLB | `outputs[role=collider].blobRef = <sha256>` | 4 MiB（`COLLIDER_LIMIT`）、三角形 ≤ 4096 | `model.rs:785-800`、`WorldPropCollisionProxy.swift:59-61` |
| 输入图 PNG | `input.blobRef = <sha256>`，`private:true` | 8 MiB / 2048²（README:43） | `daemon.rs`（PNG 上限） |
| 贴图 / 音频 / 动作包 | `blobRef` + `mime`（`image/png`、`audio/*`、动作包） | 各自单独上限，写进 `blob` 行 | 动作包属主设计 P3，本文只提供 `blob` 机制 |
| **世界状态里的引用** | `WorldGeneratedProp.assetID` **必须**是 **`sha256:<产物 GLB 的 sha256>`**（**今天已经是对的**，见下方更正） | — | `WorldPropLayout.swift:4-6`、`GMGNRadioApp.swift:3781`；实测四方一致 |

> **更正（本文初稿在此判断错误）**：初稿称"`assetID` 错用成输入图哈希"。
> 复核实测：`02BFEE6E` 的 `assetID` 后缀是 **`9d50e3d7…`**，与回执 `inspection.sha256`、磁盘 GLB 实测 sha256
> **逐位相等**；`35c3b4f6…` 是 **`job.imageSHA256`（输入 PNG）**，那是**另一个键**。
> 我错在把 `imageSHA256` 当成了 `assetID` 的来源。
> **所以这里要的不是修 bug，而是一条回归护栏（B-4）**：
> `assetID == "sha256:" + <产物 blob 的 sha256>` 且 `== artifact.outputs[role=model].blobRef` 且 **`!= job.imageSHA256`**
> —— 最后一条正是防我犯过的那个混淆：**输入与产物必须是两个不同的键，永不混用**。
> 它在 P-B1 有独立价值：`blob` 表引入后，"图省事让 `assetID` 指向输入 blob"的做法会被立刻抓住。

---

## 5. 边界：哪些**不**搬

### 5.1 明确不搬（渲染与界面侧）

| 不搬 | 理由 | 证据 |
| --- | --- | --- |
| 渲染缓存（`ResidentPropRenderer` 的 `assetID|path` 缓存） | 是派生缓存，不是权威 | `ResidentPropRenderer.swift:39-41` |
| 碰撞代理的**三角形表示** | 派生几何（主设计 §4.6 D1-D3） | `WorldPropCollisionProxy.swift:640-680` |
| 对话显示历史 `ResidentChatTranscript` | "界面当前显示什么"，明确不做持久化 | `GMGNRadioApp.swift:780-783` |
| `residentOwnedPropAssets` / `residentPropAssetFailures` | Swift 内存投影 | `GMGNRadioApp.swift:3562`、`:3736` |
| Metal / 命中测试 / 承托网格 / 几何判定 | 主设计 §1 非目标 | 主设计 §1.1-1.2、§8.5 |
| 30 Hz 的坐标/时间流 | 主设计 §6 开放点 5 明确禁止 | `resident-storage-contract.md` §6.5 |

### 5.2 `blob` 的**分类**（哪一类文件进内容寻址、哪一类不进）

| 类别 | 进 `blobs`？ | 上云默认 | 理由 |
| --- | --- | --- | --- |
| 产物 GLB | **是** | 按需（§5.4） | 跨设备有用；内容寻址天然安全 |
| 碰撞代理 GLB | **是** | 按需 | 小（≤4 MiB），且可由模型重建（可只上模型） |
| 贴图 / 音频 | **是** | 按需 | 同上 |
| **用户上传的参考图** | **是，但 `private:true`** | **默认不上云** | 含人脸/隐私（主设计 §7.5 已定"默认不上云"） |
| 居民自检到的公开图 | 是（可标 `public:true`） | 默认不上云 | 是公开内容，但"用户看过什么"仍属隐私 |
| 动作包 | 是（归主设计 P3） | 按需 | 目录可由 blob 重建 |
| DSH/第三方 `session.jsonl` | **否** | 否 | §5.3 |
| 凭据 / token / 密钥 | **永不进任何库或 blob** | 否 | 主设计 §7.5、`resident-storage-contract.md:100-102`（`state_commit` 里出现已配置 token ⇒ 整体拒绝） |

### 5.3 第三方原文（DSH/模型会话文件）——**边界与保留期**

用户明确要求"**不要把第三方会话文件原样当权威**"。本文的立场，逐条可执行：

1. **不进权威库。** `session.jsonl` 永不写入 `resident_states`、永不写入 `facts`。
   理由：它不是我们的数据模型，格式由第三方版本决定，把它当权威等于把 schema 的控制权交出去。
2. **只登记"存在性事实"，不登记内容。** 允许在 `blob` 里登记
   `{sha256, bytes, mime: application/x-dsh-session, source: "third-party", path_is_ephemeral: true}`。
   这样"删了要能证明删干净"（§5.5）能覆盖它，而内容不进我们的库。
3. **保留期由第三方目录决定，不由我们承诺。** 今天的现实是：代码**有**清理
   （`AgentConversationService.swift:1639` 的 `sandbox.removeAll()`），但真机残留 **20 个沙箱 / 16 份 jsonl**。
   本文要求把它变成**可断言的事实**而非承诺：
   - 每次 runtime 关闭后 60 s，`blob_verify` 必须报告该 `session.jsonl` 是否仍存在；
   - 存在 ⇒ 发 `blob.stale`（**可见**），由宿主真删；
   - 状态为 `third-party-ephemeral` 的 blob **不参与云同步**、**不参与"用户可删"之外的生命周期管理**。
4. **不做"第三方会话的 compaction"。** 我们压我们自己的记忆；第三方的历史压缩是它自己的事。
5. **进 prompt 的边界不变**：`memory_recall` 的 context 永远不含宿主 prompt、工具结果、图片字节、凭据
   （合同 `voicemem-rust-contract.md:262`）。

### 5.4 云同步：按需传（CapCut 形状的最小方案）

用户说的是"像 capcut"——CapCut 的形状是**代理 + 按需下载**。最小方案（**不实现，只定形状**）：

| 层次 | 形状 | 代价（诚实说） |
| --- | --- | --- |
| 记录 | `artifact` / `memory` **全部上云**（小，KB 级） | 记录级 LWW + 墓碑（主设计 §7.2），成本低 |
| 大文件 | `blob.remote` 填上 object key，**`localState` 可为 `not_local`** | 需要在 UI 上区分"还没下载"与"坏了" |
| 拉取 | `blob_hydrate{sha256}`：显式、幂等、分片、断点续传（复用 `files::publish` 的临时文件 + rename） | 多一个状态机；离线时必须给 `blob_not_local` |
| 代理 | **不生成第二个低模**。CapCut 的"代理"是给**视频流预览**用的；我们的分发单位是**成品 GLB**（≤32 MiB），没有"边下边剪"的需求 | **这是与 CapCut 最本质的差别，必须说清楚**：抄"按需"是对的，抄"代理文件"是无用成本 |
| 预取 | 可选：`objects` 视图里"当前房间 + 可见"的工件优先 hydrate | 需要"哪些是可见的"这一输入，而它在 Swift（主设计 §4.1 禁止渲染路径同步 RPC）⇒ **预取必须由 Rust 侧的策略表驱动，不能由渲染路径触发** |
| 默认值 | **不上云**；上云是显式、可撤销、按类的开关 | 主设计 §7.5 的硬规则 |

### 5.5 保留 / 折叠 / 导出 / 用户可删（含"删了要能证明删干净"）

**(1) 记忆（A）**

| 项 | 策略 |
| --- | --- |
| 最近窗口（原文） | **有界**：`turns ≤ max(20, 2× 单话题平均回合数)`，且 `chars ≤ 24 000`，且 `age ≤ 24 h`——**三条任一先到即触发一次压缩**。窗口只在进程内存（今天如此，保持） |
| 压缩层（facts/notes） | 快照式整合；`FACTS_LIMIT=200` / `NOTES_LIMIT=80` / `ENTRY_TEXT_LIMIT=400` 沿用冻结合同（`memory.rs:76-80`） |
| **钉住的事实（pinned）** | **压缩永不压掉**（§4.3 / RA2）。四类必须 pinned：① 身份/自我设定；② **对用户的承诺**；③ 用户偏好；④ **在办的事**（未完成的意图/委托/任务） |
| 压缩账本 | `memory.compacted` 事实，永久保留（它是"事实"，同主设计 §8.3 的终态事实） |
| 被压掉的原文 | **不保留**（今天也没保留）。但**"压掉了什么"可查**：账本记 `inputFrom..inputTo` 水位 + `droppedIDs`；原文对应哪个水位 ⇒ 可从 `facts` 里那条 `memory.turnAccepted`（可选）定位。**明确承认：原文本身不可恢复**——这是"compaction 不是归档"的必然代价，必须写进 UI 文案，不能偷偷假装能恢复 |
| 导出 | `gmgn-taskd memory export --scope … --format jsonl`（只导出压缩层 + 账本，**不含原文**） |
| 用户可删 | `memory_forget{scope, target: all\|entry:<id>\|range:<fromSeq..toSeq>}`；写新快照 + 墓碑 + `memory.forgotten` 事实 |

**(2) 生成结果（B）**

| 项 | 策略 |
| --- | --- |
| 事实行 | 永久保留（体积极小） |
| 产物字节 | **引用计数 + 宽限期**：`refCount==0` 且 `age > 30 d` ⇒ 候选 GC；GC 前写 `blob.forgotten` + 墓碑 |
| 失败工件的输入图 | 失败后 `age > 7 d` ⇒ 输入图降级为 `not_local`（可再取，若有 remote）或删除 |
| 用户可删 | `artifact_forget{artifactID}` ⇒ 墓碑 + 其独占 blob 进入 GC 候选；**"删除"不删事实行**（否则又变成"东西为什么不见了"无法回答） |

**(3) "删了要能证明删干净"的判据（可执行）**

删除动作返回一张**删除凭据**，并且可以被独立复核：

```jsonc
// delete receipt（blob_forget / memory_forget 的返回）
{
  "target": "blob:9d50e3d7…",
  "requestID": "…",
  "deletedAt": 1790819429853,
  "localPath": "blobs/9d/50/9d50e3d7….glb",   // 已删；复核时必须 ENOENT
  "verified": { "pathGone": true, "refCount": 0, "remoteState": "deleted|not_uploaded", "tombstone": true },
  "witness": { "factsSeq": 4212, "recordRevision": 87 }
}
```

**判据（全部可断言）**：
1. **本地**：该路径 `stat` 必须 `ENOENT`；父目录若空必须已移除。
2. **派生索引**：`blobs` 行 `tombstone=true`；任何 `artifacts`/`objects` 对它的引用必须已清空（`refCount==0`）。
3. **云**：`remote` 必须为 `not_uploaded` 或 `deleted`；并且墓碑已入同步队列（否则"删了又被另一台推回来"——主设计 §7.1 已指出这是必然）。
4. **第三方残留**（§5.3）：`session.jsonl` 类必须额外报告"该沙箱目录是否已整体消失"，残留即 `blob.stale` 告警。
5. **不变量**：删除**不**删事实行；`memory.compacted` / `artifact.stateChanged` 的历史必须仍在（否则"为什么不见了"无法回答）。
6. **反例断言**：注入"只删本地文件、不清引用"的缺陷 ⇒ **必须失败**（否则下次 `artifact` 读会"看起来可用但打不开"）。

**凭据永不进这两个库**（主设计 §7.5；`resident-storage-contract.md:100-102` 还给了机械判据：
`state_commit` 入参若含任一已配置 origin 的 token ⇒ 整体拒绝）。

---

## 6. 分阶段计划

### 6.1 在 P 序列里的位置与顺序（**不重排已有批次**）

| 批次 | 域 | 与主设计的相对位置 | 为什么这个位置 |
| --- | --- | --- | --- |
| **P0** | 事件面基础（补 G1 / 统一日志 / `producer`+`id`） | 主设计原样 | 所有后续域的依赖 |
| ~~**P-A1**~~ | ~~记忆：压缩 + 钉住事实 + 账本~~ **⇒ 不执行**（用户决定不做长期记忆） | — | 保留为调研记录；见文首最终口径 |
| **P1** | 消息投递 + 通知 | 主设计原样 | 另一条线在做，本文不碰 |
| **P-B1** | **生成结果：`artifact` + `blobs` + 文件缺失可见（只读、影子）** | **紧跟 P0/P-A1**（纯收益，可独立交付） | 不搬写入方就能解掉 §2.2(c) 那个真机缺陷；且它是 **P2 的前置**（P2 要读物件的 blob 引用） |
| **P2** | 物件域（主设计原样） | 主设计原样 | `wish.claimed` 与 `artifact` 同事务（§8 B-1） |
| **P-B2** | **生成结果：切换唯一写入方（库记事实 / 文件内容寻址 / 云按需）** | **P2 之后** | 依赖 P2 把 `objects` 建起来，才能保证"事实与引用同事务" |
| **P3** | 动作域 | 主设计原样 | 本文不碰（走姿交接线在跑） |
| **P4** | 任务与许愿 | 主设计原样 | A、B 的 `wishes.json` 退役在这里收口（六份授权副本也在这里） |
| ~~**P-A2**~~ | ~~记忆：切换唯一写入方~~ **⇒ 不执行**（同上） | — | 保留为调研记录 |
| **P5** | 世界/房间持久事实 | 主设计原样 | — |
| **P6** | 云同步（独立立项） | 主设计原样 | A、B 的形状在这一批被真正消费（§5.4） |

**可以早做的纯收益、低风险三步**（按推荐顺序）：

1. **P-B1** —— 不搬任何写入方，就能把"已领取并入库但没有它"变成**面板上一句可读的话**（§8 B-1）。
2. **P-A1** —— 今天耐久层是空表；建起压缩账本与钉住事实**只增不减**，且能立刻回答"我之前答应过他什么"。
3. **P0** —— 主设计已判为纯收益；它是上面两步的推送依赖。

### 6.2 唯一写入方的切换（S0→S3 四步，每个域都走一遍）

以 B 域为例（A 域同构）：

| 步 | 做什么 | 谁写 | 谁读 | 成功判据 | 回滚 |
| --- | --- | --- | --- | --- | --- |
| **S0 只读勘察 / 导出 / 等价性证明** | 写一个**只读**导入器 + 对账器：把 `jobs.data`、`wishes.json`、`state.json`、磁盘文件**全部读一遍**，输出三方差异报告 | 无人写 Rust | 无人 | 报告能**逐件**回答："这件产物在几处出现、路径是否一致、sha256 是否一致、文件是否存在"；对 §2.2(c) 那件必须报 ✗ | 无（纯只读） |
| **S1 Rust 侧表 + 事件 + 命令** | `artifact` / `blob` 记录 + `blob` 内容寻址目录 + `blob_publish/verify/hydrate` + 事件 | **Rust 写新表**；旧三处**照旧写**（不读新表） | 无人读新表 | 对账器在**双写窗口**里两边 `hash` 必须相等（主设计 §5.7 的对账断言）；不等即告警 | 停掉新表写入即可（旧路未动） |
| **S2 Swift 只读** | 面板/任务行/渲染**改为读新表投影**（带 `revision` + `basedOnGeneration`） | 旧三处**仍在写**，但**没人读** | Swift 读新表 | 面板显示与 S1 的对账报告逐件一致；`grep` 证明旧读路径已删 | 切回读 `jobs.data`（旧路仍在写，数据未丢） |
| **S3 切写** | 旧三处的**写入路径删掉**（不是注释掉）；旧文件转只读 + 一次性导入器（幂等） + 世代号 | **只有 Rust** | Swift 读投影 | 主设计 §9 十条检查清单全过；旧文件 mtime **不再变化**（可观察）；导入器跑两次不产生第二份数据 | 一条命令切回（§6.5） |

### 6.3 各阶段风险与回滚

| 阶段 | 风险 | 回滚 |
| --- | --- | --- |
| **P-A1** | 低。只加记录与事实，不改任何现有读路径 | 删除新记录（旧 `plan` 未动） |
| **P-B1** | 低-中。要新增 `blobs` 目录与一次全量校验扫描，**会读所有 GLB**（真机 17 MB，可接受）；注意 `taskd` 是单写存储线程，**校验必须走后台、分批、不得阻塞命令通道** | 停扫描 + 不读新表 |
| **P-A2** | **中**。压缩是"丢数据"的动作；一旦规则错，会丢掉用户承诺。**必须**先有 pinned 与账本（P-A1 已交付），再有压缩 | 压缩开关关掉 ⇒ 回到"窗口 + `plan`"形态（今天的行为），**新快照保留**（不删历史快照，见 §5.5） |
| **P-B2** | **中-高**。动的是"文件在哪"：错一次就是"物件从房间消失"（`WorldPropLayout.swift:23-31` 的注释已经踩过一次） | 双写一个周期（旧路径仍写，**只有新路径被读**），出问题改读旧路径；blob 目录只增不删一个周期 |
| 一次性导入器 | 中。`state.json` 是外键根（主设计 P5 的风险） | 导入器带 `--dry-run`；导入前备份 `wishes.json`（`AppBackups/` 已有这个目录） |

### 6.4 过渡期如何保证不出现两份真相（每阶段必须同时满足）

沿用主设计 §5.7 的三条铁律，A/B 的具体落法：

1. **唯一写入方**：切换那一刻起，只有 Rust 写该域；旧存储**立刻转只读**。
   - B：`wishes.json` 的 `jobs[].modelPath` 从"写入"变为"只读遗留"；`jobs.data.local_model_path` 从"权威"变为"遗留字段"。
   - A：`plan.groundedEvents` 从"权威"变为"`memory` 域的一个投影"。
2. **只读投影 + `revision`**：Swift 对同一事实只能从投影读，禁止从别的源推导同一事实。
   - **反例**：`GMGNRadioApp.swift:3758` 的 `job.modelPath == path` 就是"从两个源推导同一事实"——
     切写后必须变成"读一个 `blob` 行"。
3. **一次性导入 + 世代号**：导入器幂等；投影带 `basedOnGeneration`；不匹配即陈旧。

**双写窗口的纪律（如果非用不可）**：明确截止时间 + 一个开关；读取**只能**读一边（Rust）；
另一边只写不读；对账断言（两边 `hash` 相等）在窗口内持续跑。

### 6.5 回滚：一条命令退回旧形态

**方案（可行、且不依赖改代码）**：给 `gmgn-taskd` 加一个**只影响"接受哪些域的写"**的开关，
加上 Swift 侧一个**读源开关**：

```
# 1) 关掉 Rust 对该域的写权威（daemon 拒绝该域的 state_commit / 命令，返回 authority_disabled）
gmgn-taskd authority --domain memory=legacy --domain artifact=legacy     # 立即生效，无需重启
# 或启动参数：--authority-domains memory=legacy,artifact=legacy

# 2) Swift 侧切回旧读源（不改代码，读已有的功能开关）
defaults write ai.gmgn.radio gmgn.authority.readSource legacy
```

**为什么这样能"一条命令退回"**：
- 旧存储在整个过渡期**只读保留、不删除**（主设计 §1.5 的不删原则）；
- 写入路径在 S3 被删掉，但**旧写的等价数据仍在**（S2 期间旧路径仍在写）；
- 因此"退回"= 停止新写 + 切回读旧 = 一份旧形态 + 一份新形态（**新形态不再被任何人读**，
  不会产生用户可见的第二份真相）。**代价要说清楚**：S3 之后新产生的事实（只有 Rust 有）
  在退回后会**看不见**——所以回滚窗口必须有截止时间，且退回前要导出新表。

**演练要求**：回滚**必须被实际演练过**（主设计 §9 最后一条）。演练判据：
退一步后重启 App，世界照常起来、四件产物状态与 §2.2(c) 的对照表一致。

### 6.2.1 S0 对账器已经落地：`tools/reconcile-generation-results.py`

P-B1 的 S0 不是一个待办，而是一份**已实现、已跑过真机、已自测**的只读工具：

```sh
python3 tools/reconcile-generation-results.py            # 真机对账（只读；FAIL 时退出码 1）
python3 tools/reconcile-generation-results.py --json out.json
python3 tools/reconcile-generation-results.py --self-test # 自证：每条判据的反例都必须 FAIL
```

**只读纪律（可核验）**：SQLite 以 `mode=ro` 打开；文件只 `stat`/`read`；
从不写、不删、不改名、不建目录；不连 taskd socket、不启动 app、不碰凭据。

**它在做的事**：把四处事实（taskd `jobs`+回执 / `wishes.json` / 世界状态 `metadata` /
磁盘文件）逐件对齐，并把本文的三条核心判据变成**会自动 FAIL 的检查项**：
`claimed_but_not_in_inventory`（B-1）、`model_file_missing` / `model_hash_mismatch`（B-2）、
`asset_id_is_input_hash` / `input_output_hash_collision`（B-4 护栏）。

**真机首次运行结论（2026-10-01 14:32，只读）**：

| 项 | 值 |
| --- | --- |
| taskd jobs / wishes jobs / world `state.json` | 4 / 4 / 7 |
| 磁盘文件（跨 3 个目录，去重后内容种数） | 16 / 9 |
| **FAIL** | **1** —— `4210DB95` 的 `claimed_but_not_in_inventory`（**缺陷抓手命中**） |
| WARN / 孤立文件 | 0 / 0 |
| 重复内容组 | 4（**全是 cross-dir**，私根内 `leftover=0`） |
| 登记了却从未提交生成的人类授权 | **28**（32 份授权 vs 4 个任务） |

重复内容里最重的一组：`8649fe93…` **× 5**（taskd 私根 1 份输入图 +
`ResidentAttachments/` **4 份完全相同的用户原件**，各 1,817,530 B）。
**注意它的性质**：这是 **cross-dir** 而非 `leftover` —— 用户原件与"提交给生成服务的副本"
各有一份。所以处置必须保守（原件可能仍需保留），**P-B2 才能动**，且判据是
"引用计数为 0 才可删"（§5.5），不是"看起来一样就删"。
对账器按 `kind` 把两者分开（`leftover` / `cross_dir`），就是为了不让这条边界被误读成"删掉 4 份"。

**自测（证明检查真的会 FAIL，而不是永远 PASS）**：6/6 通过 ——
`healthy`（必须无 FAIL）/ `claimed_but_not_in_inventory` / `claimed_without_receipt` /
`model_file_missing` / `model_hash_mismatch` / `asset_id_is_input_hash`。
**这一步很关键**：一个"从不 FAIL"的对账器等于没有对账器（本文 §9 反复强调的
"没有断言的修复可以被静默退回"）。

---

## 7. 统一世界事件流：新增的 8 类

主设计 §4.3 已有 12 类。A、B 新增 8 类，**不新建第二条流**：

| `kind` | 何时发 | 载荷（要点） | 幂等键 | revision 语义 |
| --- | --- | --- | --- | --- |
| `memory.turnAccepted`（可选，默认关） | 已交付回合进入窗口 | turnID, watermark, role, chars, source | `turn:<scope>:<watermark>` | 不参与记录 revision（窗口是易失的） |
| `memory.compacted` | 压缩**成功提交** | from, to, ruleVersion, trigger(user/timer/size/manual), inputWatermarks, keptIDs, droppedIDs, pinnedKept, snapshotRevision | `compact:<scope>:<requestID>` | `memory_snapshots.revision` +1 **且** `vector_generation` +1（同事务） |
| `memory.pinned` | 一条事实被钉住/解除 | entryID, pin, reason, groundedIn | `pin:<scope>:<entryID>:<pin>` | 快照 revision +1 |
| `memory.forgotten` | 用户显式删除 | target(all/entry/range), deletedEntryIDs, receipt | `forget:<scope>:<target>` | 快照 revision +1（墓碑） |
| `artifact.registered` | 工件登记（= 原 `submit` 的持久 ACK） | artifactID, sourceWishID, inputBlobRef, idempotencyKey | `register:<artifactID>` | `artifact.revision` +1 |
| `artifact.stateChanged` | 阶段变化 | artifactID, state, remoteState, outputBlobRefs, lastError | `artifact:<artifactID>:<state>:<lastError>` | `artifact.revision` +1 |
| `blob.available` | 字节落盘且校验通过（或 hydrate 完成） | sha256, bytes, mime, local, origin(local/download/cloud) | `blob:<sha256>` | `blob.revision` +1 |
| `blob.missing` | 校验失败/文件缺失 | sha256, expectedBytes, foundState(missing/corrupt/not_local), referencedBy[] | `blob:<sha256>:<epoch>` | `blob.revision` +1 |

（另外两个**复用**主设计的类，不新增：`wish.claimed` 必须与 `artifact.registered` **同事务**；
`inbox.fact` 承载"文件缺失/恢复"这类面向界面的通知。）

**错误码（新增，不新造同义词；与主设计 §6.5 同一张表）**：
`blob_not_found` / `blob_missing` / `blob_corrupt` / `blob_not_local` / `blob_too_large` /
`receipt_blob_mismatch` / `artifact_not_found` / `memory_snapshot_missing` /
`compaction_unavailable` / `compaction_rejected`（**复用合同已有码**，`memory.rs:483-503`） /
`memory_conflict` / `memory_request_conflict` / `pin_violation`（压缩试图丢掉 pinned ⇒ 拒） /
`forget_target_not_found`。

---

## 8. 断言建议（每条都要能被"注入缺陷"抓住）

> 写法沿用主设计 §4.4 的风格：**先写缺陷怎么注入，再写断言必须失败**。这些是验收的机械判据。

### A 域

- **A-1（记忆不能只活在窗口里）**
  *注入*：让 `ResidentAgentLoop` 只 `append` 到 `recentEvents`，不走 `ResidentMemoryStore.save`。
  *断言*：重启后 `/memory/recall` 必须仍能回答该条事实 ⇒ **注入后必须失败**。
- **A-2（钉住的事实压不掉）** ← 用户明确要求
  *注入*：在压缩的输入里把一条 `pinned=true`（例如"答应过他周五之前做好那把剑"）当普通条目，
  让 provider 输出里**不含**它。
  *断言*：`memory_compact` 必须返回 `pin_violation` 并**整体回滚**（快照不变、窗口不清空）⇒ **注入后必须失败**。
- **A-3（"我之前答应过他什么"必须能回答）** ← 用户明确要求的判据
  *断言*（可机械执行）：给定一份含 ≥1 条 `pin.kind=commitment` 的 scope，
  连续压缩 N=10 次（每次输入都不同），
  `memory_recall(query: "我之前答应过他什么")` 的结果里**必须**包含全部 commitment 条目的原文，
  且逐字不变（含日期/数字/名字）。*注入*：任何一次压缩丢掉它 ⇒ 必须失败。
- **A-4（丢的要能查）**
  *断言*：压缩后，`facts` 里 `kind=memory.compacted` 的那条必须能**完整重建**"这次压掉了哪些 entryID、
  输入水位区间是多少、用了哪个 ruleVersion"。*注入*：压缩不写账本 ⇒ 必须失败。
- **A-5（删除可证明）**
  *断言*：`memory_forget` 返回的凭据必须通过 §5.5 的 5 条复核。
  *注入*：只标 `tombstone` 但快照里仍留着该条文本 ⇒ 必须失败。
- **A-6（窗口有界，且触发压缩而不是静默截断）**
  *断言*：连续投喂 3×窗口大小的回合，`recentEvents` 不得被 `suffix()` 静默丢；
  必须观察到**恰好一次** `memory.compacted`（或一条明确的"未压缩"原因）。
  *注入*：保留今天的 `suffix(limit)` 截断 ⇒ 必须失败。
- **A-7（凭据不进库）**
  *断言*：`state_commit(domain=memory)` 的 value/事件载荷里出现任一已配置 origin 的 token ⇒ 整体拒绝
  （复用 `resident-storage-contract.md:100-102` 的既有机制）。

### B 域

- **B-1（"已入库"必须等于库存里有它）** ← 用户明确要求；**这是本次的缺陷抓手**
  **现状更正**：Swift 侧**已经修好**（`ResidentPropInventoryBacklog.status`，`GMGNRadioApp.swift:7021-7100`），
  所以它不是"待修缺陷"，而是**一条必须补上的断言**——因为**断言存在之前，修复可以被静默退回**。
  三层断言，从弱到强：
  1. **函数层（今天就有）**：`status(isInInventory:)` 只在 `isInInventory == true` 时返回含"已入库"的字样。
     *注入*：让它无条件返回"已领取并入库" ⇒ 必须失败。
  2. **派生源层（今天缺失，`4210DB95` 现场就在这一层）**：`isInInventory` **必须**由
     `objectStates[job.objectID]?.generatedProp != nil` 派生（`:5777-5780`），
     **不得**由 `residentOwnedPropAssets` / `record.localModelPath` / `layoutReceipts` 派生。
     *注入*：把派生源改回 `residentOwnedPropAssets != nil` ⇒ **必须失败**
     （这正是原始缺陷的形状：模型备好了、库存里没有）。
  3. **权威层（P2 之后）**：`objects` 里有该 `objectID` **⇔** `layoutReceipts["claimed.<jobID>"]` 存在
     **⇔** 面板说"已入库"。三者**必须**同时成立或同时不成立。
     *注入*：造 `stage=claimed` + 收件箱"已领取并入库" 但 `objectStates` 无它的现场 ⇒ **必须失败**。
  **机械判据**：修复前真机四源矛盾（`wishes.json` claimed / 收件箱"已入库" / `objectStates` 无 / `layoutReceipts` 无
  `claimed.4210DB95-…`）；修复后与修复前的**唯一**差别必须是"面板不再说已入库"，而不是"数据被补上了"。

- **B-2（文件缺失必须可见）** ← 用户明确要求
  *注入*：把 `blobs/<ab>/<cd>/<sha256>.glb` 删掉（或改成只留前 1 KB），库里不动。
  *断言*：下一次 `artifact` 读取/`blob_verify` 必须产生 `blob.missing` + `blob_missing`/`blob_corrupt`，
  面板必须出现可读原因，且**该工件不得被标为可用**。
  *反向*：不允许"静默退回降级表示"（例如没有碰撞代理就静默退回 yaw 盒子——
  这正是 `WorldPropCollisionProxy.swift:38-42` 明确禁止的 fail-open）。
- **B-3（内容寻址去重）**
  *断言*：把同一份 GLB 字节以两个不同 artifactID 登记 ⇒ `blobs` 只有一行、磁盘只有一份文件
  （今天会是两份 `<id>.glb`）。*注入*：按 identity 命名文件 ⇒ 必须失败。
- **B-4（`assetID` 必须指向产物字节）** ← **回归护栏**（不是缺陷复现；今天已是对的）
  *断言*：`objects[objectID].generatedProp.assetID` 必须 `== "sha256:" + <产物 GLB 的实测 sha256>`，
  且必须 `== artifact.outputs[role=model].blobRef`，
  且**必须 `!= "sha256:" + job.imageSHA256`**（输入与产物是两个不同的键，永不混用）。
  *注入*：让 `assetID` 指向 `input.blobRef`（**本文初稿就犯过这个混淆**）⇒ 必须失败。
  **为什么今天它仍然值钱**：`blob` 表引入后"产物 blob"成为一等公民，
  图省事复用一个哈希的做法会立刻被这条抓住。
- **B-5（引用与文件生命周期一致）**
  *断言*：GC 之后，任何 `artifact` 引用的 blob 仍必须可读（引用计数 > 0 ⇒ 不许删）。
  *注入*：删掉仍被引用的 blob ⇒ 必须失败。
- **B-6（同一事实只有一个位置）**
  *断言*：`grep -r "localModelPath\|local_model_path\|modelPath"` 的**读取落点**从 N 处降到
  "`blob` 投影 + 一个访问器"；`wishes.json` 的 `jobs[].modelPath` 在 S3 后**不再被读**。
- **B-7（云同步按需、且不阻塞本地）**
  *断言*：断网时，已在本地的 blob 一切照常；缺本地且 `localState=not_local` 的 blob
  必须返回 `blob_not_local`（**不是** `blob_corrupt`），UI 文案必须区分两者。
- **B-8（DSH 第三方会话不得成为权威）**
  *断言*：`resident_states` 与 `facts` 里**不得**出现 `session.jsonl` 的内容或路径；
  只允许出现 `blob` 的 `{sha256,bytes,mime}` 登记行。
  *注入*：把 `session.jsonl` 原文写进 `state_commit` 的 value ⇒ 必须失败。

---

## 9. 我最不确定的一条（按证据强度排序，写法沿用主设计末尾）

### 判断：「`memory_ingest` 的原文窗口**存在过**，因此值得为它设计"保留 N 天 / 水位区间 / 导出"这一层」

**为什么它最脆弱**：

1. **真机证据是"0 行"**。`memory_snapshots` / `memory_requests` / `memory_vec_rows` **全为 0**，
   而原文窗口是**进程内存**——我**无法**从磁盘上证明它曾经被写过。
   我的证据只有**代码路径**（`App/GMGNRadioApp.swift:4870` → `confirmDeliveredTurn` →
   `memory_ingest`）和 `README.md` 里"原始对话文本永不落盘"的说明。
   如果真机上 `residentConversationMemory` 从未真正接线成功（例如 daemon 版本/scope 不匹配），
   那么**整个 P-A2 的价值会小很多**——因为根本没有原文窗口要压。
2. **合同与实现已经脱节一年**：`memory_compact` 在合同里是三年前冻结的（文件日期 2026-09-08），
   实现里连 dispatch 都没有。这说明**当初那条线被砍的时候，没人确认过它有没有真的在跑**。
   我据此推断"设计一个 compaction 是补上缺口"，但也可能真相是"这层从来没用过，应该直接删掉"。
   **两种结论会导向完全相反的方案**：一个是"加 compaction"，一个是"删掉 `memory` 域，
   只保留 `plan` 那条记录"。
3. **我据以判断"窗口有界"的三个数字都是我在本文里**新定**的**（20 回合 / 24 000 字符 / 24 h），
   没有任何实测数据支撑"用户的真实对话长度分布"。如果实际单话题回合数远大于 20，
   窗口会频繁触发压缩（成本）；如果远小于，窗口会长期不压缩（原文堆积）。
4. **"钉住的事实"的四类分类是我从用户原话反推的**（身份/承诺/偏好/在办），
   **没有**任何产品文档或用户研究支撑这个划分。承诺与偏好的边界在有的话里并不清晰
   （"我喜欢安静的咖啡店"是偏好还是承诺？）。
5. 我在 §2.1(c) 说"表建好但从未被写"，这个**事实**证据很强（DDL + 0 行 + dead_code 注释三重）；
   但由它推出的**规范结论**（"所以我们应该把它接上"）证据很弱——
   它同样支持"所以我们应该把它删掉，别维护死代码"。

**建议**（在上马 P-A2 之前必须先做的**只读**确认）：
1. 在真机上**实际跑一次** `memory_provider_configuration` / `memory_status` / `memory_pending`
   （`daemon.rs:324-366` 都有），确认 pending 缓冲是否真的收到过回合。
   若恒为 0 ⇒ **先停下来问用户**："原文窗口今天没有数据，是要接上还是删掉？"
2. 读一遍 `2026-09-08-voicemem-rust-port.md` 与 `2026-09-08-voicemem-rust-orchestration.md`
   的"偏差记录"章节，确认当初拆除 provider 时对"本地抽取接手"的**产品决定**原话；
   本文的 `README.md` 引文说"为后续在 Rust 内自行实现语义抽取，表结构与代次账本原样保留"——
   如果这个"后续"已经被取消，P-A 应该降级为"只保留 `plan` + 加钉住语义"，而不是全量 compaction。

**次要怀疑排序**（按证据强度从弱到强）：

| 判断 | 证据强度 | 说明 |
| --- | --- | --- |
| "原文窗口存在且值得保留策略" | ~~弱~~ → **已由实测判定** | 只读 `memory_recall` 探针（2026-10-01 14:18:59，scope = 实测 `resident/plan` 那条）返回 `pendingTurns=0` / `revision=0` / `vectorGeneration=0` / `facts,notes` 空——**四重一致**。严格表述：**此刻没有 pending、且从未有过已提交快照**（≠ 已证明从未成功过：pending 设计上易失）。**独立强化证据**：同一 scope/transport/`.state_commit` 通路写出的 `resident/plan` 已 **revision 158** ⇒ 通路是通的，唯独 ingest 没有活数据。**决定：删原文层**（用户已定口径） |
| "窗口三个上限（20/24k/24h）合理" | **弱** | 完全是我定的，无实测；**原文层删掉后，前两个上限随之失去对象**，只剩压缩触发策略需要重定 |
| "pinned 四类分类正确" | **弱-中** | 从用户原话反推，无产品文档 |
| ~~"`assetID` 用错哈希是真缺陷"~~ | **已证伪（我错了）** | 实测 `assetID` 后缀 = `inspection.sha256` = 磁盘 GLB sha256，**四方一致**。我把 `job.imageSHA256`（输入 PNG）错认成 `assetID` 的来源。教训已固化成 **B-4 的第三条**（输入与产物必须是两个不同的键）——**这条错误本身产出了一条有价值的护栏** |
| "四处各存一份同名事实" | **强** | taskd / wishes / state.json / 文件系统四处的具体字段与数值逐条对过 |
| "任务说已入库而库存没有它（真机现场）" | **强** | 三个独立数据源同一天同一物件的三角对账（§2.2(c)）。**但"Swift 侧已修"这一条是中等强度**：我读了 `ResidentPropInventoryBacklog.status` 与 `isInInventory` 的派生（`:5777-5780`、`:7021-7100`），**没有**端到端跑一次真机来确认面板此刻真的不再说"已入库" |
| "`memory_compact` 从未实现" | **强** | 合同有、`daemon.rs` grep=0、Swift grep=0、表 0 行 |
| "taskd 存的 sha256 与磁盘 GLB 逐位相等" | **强** | 3/3 实测 |

**同时标注一条"我可能低估了"的**：本文把"第三方会话文件"判为不进权威（§5.3）。
但如果用户真正想要的是"**换台机器接着跟同一个居民聊**"，那么第三方会话的**连续性**
（`sessionID` + 它的 `session.jsonl`）就是**跨设备有用的**，而我把它划到"不进库"。
这个边界应该由用户确认，而不是由我按"它不是我们的数据模型"单方面决定。

**另标注一条本轮新发现、已升格为独立工作项的缺陷**：**ingest 的结果不可观测**——
成功只把 `replayed`/`pendingTurns` 交给 `onStatus`，错误只走到一行日志
（`App/GMGNRadioApp.swift:4772` 的 `livingWorldLogger.notice`），**既不持久、也不上屏、也不计数**。
这正是"三张表 0 行"能长期无人发现的原因。**压缩层落地时必须给每次接受/拒绝一个可见出口**
（计数器或 `memory.turnAccepted` / `memory.rejected` 事实），并且要能从界面上看出"记忆到底进没进去"。

---

## 附：本文引用的本仓文件（按引用密度）

- 主设计：[`2026-10-02-rust-world-authority-and-mcp.md`](2026-10-02-rust-world-authority-and-mcp.md)
- 记忆合同：[`2026-09-08-voicemem-rust-contract.md`](2026-09-08-voicemem-rust-contract.md)、
  [`2026-09-08-voicemem-rust-orchestration.md`](2026-09-08-voicemem-rust-orchestration.md)、
  [`2026-09-08-voicemem-rust-port.md`](2026-09-08-voicemem-rust-port.md)
- 统一状态合同：[`2026-09-08-resident-storage-contract.md`](2026-09-08-resident-storage-contract.md)
- 碰撞代理清单：[`2026-10-02-workflow-side-collision-proxy-checklist.md`](2026-10-02-workflow-side-collision-proxy-checklist.md)
- Rust：`services/gmgn-taskd/src/{memory,daemon,model,store,resident,files}.rs`
- Swift：`apps/macos/Sources/GMGNRadio/{Agent,Presence,App}/…`、
  `apps/macos/Packages/WorldRuntime/Sources/WorldRuntime/{WorldPropLayout,WorldPropCollisionProxy,WorldSimulation}.swift`

## 附：本文的只读勘察命令（可复现）

```sh
# 记忆表是否真的空
sqlite3 "file:$HOME/Library/Application Support/gmgn radio/TaskService/tasks.sqlite3?mode=ro" \
  "select 'snapshots',count(*) from memory_snapshots union all
   select 'requests',count(*) from memory_requests union all
   select 'vec_rows',count(*) from memory_vec_rows;"

# 产物哈希三方对账（库 vs 磁盘）
sqlite3 "file:$DB?mode=ro" "select id, json_extract(data,'\$.job.receipt.result.inspection.sha256') from jobs;"
shasum -a 256 "$HOME/Library/Application Support/gmgn radio/TaskService"/*.glb

# "已入库"与库存的对账
python3 - <<'PY'
import json,os
a=json.load(open(os.path.expanduser('~/Library/Application Support/gmgn radio/WishMachine/wishes.json')))
st=json.load(open(os.path.expanduser('~/Library/Application Support/ai.gmgn.radio/LivingWorld/marble-living-cabin/1.2.0/state.json')))
for j in a['jobs']:
    print(j['stage'], j['objectID'], 'inInventory=', j['objectID'] in st['objectStates'],
          'claimedReceipt=', ('claimed.'+j['id']) in st['layoutReceipts'])
PY
```
